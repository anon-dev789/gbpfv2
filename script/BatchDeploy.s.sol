// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {BatchMinter} from "../src/periphery/BatchMinter.sol";
import {BatchRedeemer} from "../src/periphery/BatchRedeemer.sol";

/// @title BatchDeploy
/// @notice Deploy the two batching periphery contracts against the LIVE core (DEPLOYMENT.md):
///           - BatchMinter   (pool USDS → batched mint → GBPF back, pro-rata)
///           - BatchRedeemer (pool GBPF → batched redeem → USDS back, pro-rata)
///         Both are owned by the broadcaster, fund a permissionless runner from an ETH gas tank,
///         and are pure periphery — they touch no immutable core state. See BATCHMINTER_DESIGN.md.
///
///         There is no pool to create or initialise: both contracts bind to the already-live
///         hook/pool. Deployment is just `new` + (optionally) seeding each ETH tank.
///
///         Seed the tanks: set SEED_ETH_WEI (default 0). If > 0, the broadcaster must hold at
///         least 2 × SEED_ETH_WEI and each contract's tank is funded that amount via fundTank().
///         The tanks are self-sustaining from fees thereafter; a small seed just lets the first
///         runner be reimbursed before the first batch's fees land.
///
///         Usage (simulate first — NO --broadcast):
///           forge script script/BatchDeploy.s.sol:BatchDeploy \
///             --rpc-url https://mainnet.base.org --sender 0xYourWallet
///
///         Broadcast (+ verify on Basescan):
///           SEED_ETH_WEI=2000000000000000 \
///           forge script script/BatchDeploy.s.sol:BatchDeploy \
///             --rpc-url https://mainnet.base.org --broadcast --slow \
///             --account deployer --sender 0xYourWallet \
///             --verify --etherscan-api-key $BASESCAN_API_KEY
///
///         If you skip --verify at broadcast, verify after the fact (constructor args must match):
///           forge verify-contract <BatchMinter addr> src/periphery/BatchMinter.sol:BatchMinter \
///             --chain base --etherscan-api-key $BASESCAN_API_KEY --watch \
///             --constructor-args $(cast abi-encode \
///               "constructor(address,address,address,address,address,address,address,address,address)" \
///               <owner> 0x498581fF718922c3f8e6A244956aF099B2652b2b \
///               0x5613c279E8Db9815DBD0CdFbd10515EAbD350088 \
///               0x1817FD23ceF7Da47DF934fdc880d72e653786770 \
///               0x820C137fa70C8691f0e44Dc420a5e53c168921Dc \
///               0x1601843c5E9bC251A3272907010AFa41Fa18347E \
///               0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
///               0x4200000000000000000000000000000000000006 \
///               0xd0b53D9277642d899DF5C87A3966A349A798F224)
///           (BatchRedeemer adds the Vault as the 4th arg — see CONSTRUCTOR ARG ORDER below.)
contract BatchDeploy is Script {
    // Core addresses (GBPF, HOOK, VAULT) are read from env at runtime — set them to the freshly
    // deployed core (GBPF_ADDR, HOOK_ADDR, VAULT_ADDR). No defaults: a missing env var reverts
    // rather than binding the periphery to a stale core.
    address internal constant V4_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant USDS = 0x820C137fa70C8691f0e44Dc420a5e53c168921Dc;

    // Base infra: PSM3 (USDS↔USDC, no fee), USDC, WETH, and the deep Uniswap V3 USDC/WETH 0.05%
    // pool. The USDC/WETH route is proven live in test/fork/BatchMinter.fork.t.sol.
    address internal constant PSM3 = 0x1601843c5E9bC251A3272907010AFa41Fa18347E;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC_WETH_POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224;

    function run() external returns (address minter, address redeemer) {
        uint256 seedEth = vm.envOr("SEED_ETH_WEI", uint256(0));
        address owner = msg.sender;

        address GBPF = vm.envOr("GBPF_ADDR", address(0));
        address HOOK = vm.envOr("HOOK_ADDR", address(0));
        address VAULT = vm.envOr("VAULT_ADDR", address(0));
        require(GBPF != address(0), "set GBPF_ADDR env to the new GBPF");
        require(HOOK != address(0), "set HOOK_ADDR env to the new Hook");
        require(VAULT != address(0), "set VAULT_ADDR env to the new Vault");

        // Preflight: the addresses we wire must actually be contracts (catches a wrong address or a
        // wrong-chain RPC before we spend gas).
        _requireCode(GBPF, "GBPF");
        _requireCode(HOOK, "HOOK");
        _requireCode(VAULT, "VAULT");
        _requireCode(V4_POOL_MANAGER, "PoolManager");
        _requireCode(USDS, "USDS");
        _requireCode(PSM3, "PSM3");
        _requireCode(USDC, "USDC");
        _requireCode(WETH, "WETH");
        _requireCode(USDC_WETH_POOL, "USDC/WETH pool");
        if (seedEth > 0) {
            require(owner.balance >= 2 * seedEth, "broadcaster ETH < 2 x SEED_ETH_WEI");
        }

        vm.startBroadcast();

        // CONSTRUCTOR ARG ORDER:
        //   BatchMinter  (owner, poolManager, hook,        gbpf, usds, psm3, usdc, weth, usdcWethPool)
        //   BatchRedeemer(owner, poolManager, hook, vault, gbpf, usds, psm3, usdc, weth, usdcWethPool)
        BatchMinter m = new BatchMinter(owner, V4_POOL_MANAGER, HOOK, GBPF, USDS, PSM3, USDC, WETH, USDC_WETH_POOL);
        BatchRedeemer r =
            new BatchRedeemer(owner, V4_POOL_MANAGER, HOOK, VAULT, GBPF, USDS, PSM3, USDC, WETH, USDC_WETH_POOL);

        if (seedEth > 0) {
            m.fundTank{value: seedEth}();
            r.fundTank{value: seedEth}();
        }

        vm.stopBroadcast();

        minter = address(m);
        redeemer = address(r);

        console2.log("=== BATCHERS DEPLOYED (Base) ===");
        console2.log("Owner (broadcaster):", owner);
        console2.log("BatchMinter   (USDS -> GBPF):", minter);
        console2.log("BatchRedeemer (GBPF -> USDS):", redeemer);
        console2.log("Tank seed each (wei):", seedEth);
        console2.log("");
        console2.log("Next:");
        console2.log(" - Verify on Basescan (see the verify command in this script's header).");
        console2.log(" - Tune fees/bonus per contract via setParams() if the defaults need adjusting.");
        console2.log(" - Record both addresses + tx hashes in DEPLOYMENT.md.");
    }

    function _requireCode(address a, string memory name) internal view {
        require(a.code.length > 0, string.concat("no code at ", name));
    }
}
