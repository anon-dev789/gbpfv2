// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {BufferVault} from "../src/periphery/BufferVault.sol";
import {IUniswapV3Factory, IUniswapV3Pool} from "../src/periphery/interfaces/IUniswapV3.sol";
import {OracleAdapter} from "../src/OracleAdapter.sol";

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/// @title GatewayDeploy
/// @notice Phase 2 of GATEWAY_DESIGN.md: stand up the public V3 GBPF/USDS Gateway pool and
///         its BufferVault, fund it, and run the first rebalance (which seeds the band by
///         minting half the funding into GBPF at the live hook).
///
///         Idempotent where possible: skips pool creation/initialisation if already done
///         (e.g. a partial earlier run, or someone front-ran pool creation — harmless, the
///         first rebalance slides the spot onto the oracle price regardless).
///
///         Funding: set FUND_USDS_WEI in the env (default 0.1e18 = 0.1 USDS). The broadcaster
///         must hold at least that much USDS. More capital can be added at ANY later time by
///         simply transferring GBPF/USDS to the BufferVault and calling rebalance().
///
///         Usage (simulate first — NO --broadcast):
///           FUND_USDS_WEI=100000000000000000 forge script script/GatewayDeploy.s.sol:GatewayDeploy \
///             --rpc-url https://mainnet.base.org --sender 0xYourWallet
///
///         Broadcast:
///           FUND_USDS_WEI=100000000000000000 forge script script/GatewayDeploy.s.sol:GatewayDeploy \
///             --rpc-url https://mainnet.base.org --broadcast --slow \
///             --account deployer --sender 0xYourWallet
contract GatewayDeploy is Script {
    // Live core (Base 8453, commit 60d3895 — DEPLOYMENT.md).
    address internal constant ORACLE = 0x9c66F3F8a102d6Bf3EeaEAAe5d9ECAe88985eB2F;
    address internal constant GBPF = 0x1817FD23ceF7Da47DF934fdc880d72e653786770;
    address internal constant HOOK = 0x5613c279E8Db9815DBD0CdFbd10515EAbD350088;
    address internal constant V4_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant USDS = 0x820C137fa70C8691f0e44Dc420a5e53c168921Dc;

    // Base Uniswap V3 infra (fork-test proven: test/fork/Gateway.fork.t.sol).
    address internal constant V3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address internal constant POSM = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;

    uint24 internal constant V3_FEE = 500;

    function run() external {
        uint256 fundUsds = vm.envOr("FUND_USDS_WEI", uint256(0.1e18));
        address operator = msg.sender;

        // Preflight: oracle must be healthy (the seed rebalance needs a live price) and the
        // operator must hold the funding.
        //
        // NOTE: the LIVE OracleAdapter instance has a known preview() bug — its twapWad is
        // amplified when an un-ingested Chainlink observation is older than the TWAP window
        // (see test/OracleAdapterPreviewRegression.t.sol; fixed in source after deploy, but the
        // deployed instance is immutable). We use preview() ONLY for the health flag (which is
        // unaffected) and take the pool init price from latestPriceWad() — the raw live feed
        // value. The init price is superseded by the first rebalance() anyway, whose pricing
        // goes through update() (correct on the live instance).
        (, bool healthy,) = OracleAdapter(ORACLE).preview();
        require(healthy, "oracle unhealthy - cannot seed the Gateway now");
        uint256 priceWad = OracleAdapter(ORACLE).latestPriceWad();
        require(IERC20Like(USDS).balanceOf(operator) >= fundUsds, "operator USDS balance < FUND_USDS_WEI");

        vm.startBroadcast();

        // 1. Create the V3 pool if it does not exist yet.
        address poolAddr = IUniswapV3Factory(V3_FACTORY).getPool(GBPF, USDS, V3_FEE);
        if (poolAddr == address(0)) {
            poolAddr = IUniswapV3Factory(V3_FACTORY).createPool(GBPF, USDS, V3_FEE);
            console2.log("Gateway pool created:", poolAddr);
        } else {
            console2.log("Gateway pool already exists:", poolAddr);
        }

        // 2. Initialise at the live oracle price if not yet initialised.
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(poolAddr).slot0();
        if (sqrtPriceX96 == 0) {
            IUniswapV3Pool(poolAddr).initialize(_sqrtX96FromTwap(priceWad));
            console2.log("Gateway pool initialised at oracle price. latestPriceWad:", priceWad);
        } else {
            console2.log("Gateway pool already initialised; first rebalance will repeg the spot.");
        }

        // 3. Deploy the BufferVault, owned by the broadcaster.
        BufferVault buffer = new BufferVault(operator, V4_POOL_MANAGER, ORACLE, POSM, poolAddr, GBPF, USDS, HOOK);
        console2.log("BufferVault deployed:", address(buffer));

        // 4. Fund it (deposits are plain transfers) and seed the band.
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20Like(USDS).transfer(address(buffer), fundUsds);
        buffer.rebalance();

        vm.stopBroadcast();

        console2.log("=== GATEWAY LIVE ===");
        console2.log("Pool (V3 GBPF/USDS 0.05%):", poolAddr);
        console2.log("BufferVault (owner = broadcaster):", address(buffer));
        console2.log("Position tokenId:", buffer.positionTokenId());
        console2.log("");
        console2.log("Operations:");
        console2.log(" - Add capital: transfer GBPF/USDS to the BufferVault, then call rebalance().");
        console2.log(" - Keep pegged: call rebalance() on a heartbeat (no-ops are cheap reverts).");
        console2.log("   Pair it with the core Vault.flush() call in the same keeper.");
        console2.log(" - Withdraw: exitAndWithdrawAll(to) from the owner wallet.");
    }

    /// @dev Same math as BufferVault._sqrtPriceX96FromTwap (token0 = lower address).
    function _sqrtX96FromTwap(uint256 twapWad) internal pure returns (uint160) {
        bool gbpfIsToken0 = GBPF < USDS;
        uint256 priceWad = gbpfIsToken0 ? twapWad : FixedPointMathLib.mulDiv(1e18, 1e18, twapWad);
        uint256 result = (FixedPointMathLib.sqrt(priceWad) << 96) / 1e9;
        // Safety: GBP/USD is ~1.27e18 WAD; result ~8.9e28 is far below 2^160.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(result);
    }
}
