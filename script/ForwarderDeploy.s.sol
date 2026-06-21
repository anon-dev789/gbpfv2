// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {ForwarderMinter} from "../src/periphery/ForwarderMinter.sol";
import {ForwarderRedeemer} from "../src/periphery/ForwarderRedeemer.sol";

/// @title ForwarderDeploy
/// @notice Deploy the SEND-AND-FORGET forwarder batchers against the LIVE core (DEPLOYMENT.md):
///           - ForwarderMinter   (send USDS to your deposit address → batched mint → GBPF back)
///           - ForwarderRedeemer (send GBPF to your deposit address → batched redeem → USDS back)
///         Users deposit with a plain transfer to a per-user CREATE2 address; a keeper sweeps and
///         swaps. See BATCHMINTER_DESIGN.md ("Forwarder model") + keeper/ + web/index.html.
///
///         Pure periphery; binds to the already-live hook/pool — no pool to create or initialise.
///         Deploy is `new` + (optionally) seeding each ETH tank via SEED_ETH_WEI (default 0; the
///         first batch funds its own runner payout, so a seed is optional).
///
///         Simulate first (NO --broadcast):
///           FOUNDRY_PROFILE=ci forge script script/ForwarderDeploy.s.sol:ForwarderDeploy \
///             --rpc-url https://mainnet.base.org --sender 0xYourWallet
///
///         Broadcast (+ verify):
///           FOUNDRY_PROFILE=ci forge script script/ForwarderDeploy.s.sol:ForwarderDeploy \
///             --rpc-url https://mainnet.base.org --broadcast --slow \
///             --account deployer --sender 0xYourWallet \
///             --verify --etherscan-api-key $BASESCAN_API_KEY
///
///         After deploy, put the two addresses into: DEPLOYMENT.md, keeper/wrangler.toml
///         (MINTER/REDEEMER + START_BLOCK), and web/index.html (CFG.minter/CFG.redeemer).
///
///         Manual verify (if --verify is skipped). NOTE the constructor arg orders differ:
///           ForwarderMinter  (owner, poolManager, hook,        gbpf, usds, psm3, usdc, weth, usdcWethPool)
///           ForwarderRedeemer(owner, poolManager, hook, vault, gbpf, usds, psm3, usdc, weth, usdcWethPool)
contract ForwarderDeploy is Script {
    // Live core (Base 8453, commit 60d3895 — DEPLOYMENT.md).
    address internal constant GBPF = 0x1817FD23ceF7Da47DF934fdc880d72e653786770;
    address internal constant HOOK = 0x5613c279E8Db9815DBD0CdFbd10515EAbD350088;
    address internal constant VAULT = 0xA9a831a348D0Db372cf75dd7C082cFF67A453498;
    address internal constant V4_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant USDS = 0x820C137fa70C8691f0e44Dc420a5e53c168921Dc;

    // Base infra: PSM3, USDC, WETH, and the deep Uniswap V3 USDC/WETH 0.05% pool.
    address internal constant PSM3 = 0x1601843c5E9bC251A3272907010AFa41Fa18347E;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC_WETH_POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224;

    function run() external returns (address minter, address redeemer) {
        uint256 seedEth = vm.envOr("SEED_ETH_WEI", uint256(0));
        address owner = msg.sender;

        _requireCode(GBPF, "GBPF");
        _requireCode(HOOK, "HOOK");
        _requireCode(VAULT, "VAULT");
        _requireCode(V4_POOL_MANAGER, "PoolManager");
        _requireCode(USDS, "USDS");
        _requireCode(PSM3, "PSM3");
        _requireCode(USDC, "USDC");
        _requireCode(WETH, "WETH");
        _requireCode(USDC_WETH_POOL, "USDC/WETH pool");
        if (seedEth > 0) require(owner.balance >= 2 * seedEth, "broadcaster ETH < 2 x SEED_ETH_WEI");

        vm.startBroadcast();

        ForwarderMinter m =
            new ForwarderMinter(owner, V4_POOL_MANAGER, HOOK, GBPF, USDS, PSM3, USDC, WETH, USDC_WETH_POOL);
        ForwarderRedeemer r =
            new ForwarderRedeemer(owner, V4_POOL_MANAGER, HOOK, VAULT, GBPF, USDS, PSM3, USDC, WETH, USDC_WETH_POOL);

        if (seedEth > 0) {
            m.fundTank{value: seedEth}();
            r.fundTank{value: seedEth}();
        }

        vm.stopBroadcast();

        minter = address(m);
        redeemer = address(r);

        console2.log("=== FORWARDER BATCHERS DEPLOYED (Base) ===");
        console2.log("Owner (broadcaster):", owner);
        console2.log("ForwarderMinter   (USDS -> GBPF):", minter);
        console2.log("ForwarderRedeemer (GBPF -> USDS):", redeemer);
        console2.log("Tank seed each (wei):", seedEth);
        console2.log("");
        console2.log("Next:");
        console2.log(" - Verify on Basescan (see header), then record both addresses in DEPLOYMENT.md.");
        console2.log(" - Set MINTER/REDEEMER + START_BLOCK in keeper/wrangler.toml.");
        console2.log(" - Set CFG.minter/CFG.redeemer in web/index.html.");
    }

    function _requireCode(address a, string memory name) internal view {
        require(a.code.length > 0, string.concat("no code at ", name));
    }
}
