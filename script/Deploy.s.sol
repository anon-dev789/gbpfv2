// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {OracleAdapter} from "../src/OracleAdapter.sol";
import {Vault} from "../src/Vault.sol";
import {GBPF} from "../src/GBPF.sol";
import {Hook} from "../src/Hook.sol";

import {IChainlinkFeed} from "../src/interfaces/IChainlinkFeed.sol";
import {ISSRAuthOracle} from "../src/interfaces/ISSRAuthOracle.sol";

import {HookMiner} from "./HookMiner.sol";

/// @title Deploy
/// @notice Deploys the full GBPF protocol stack on Base mainnet.
///
///         See DEPLOY_DESIGN.md for the design rationale (especially the circular dependency
///         analysis and the seed-and-burn flow).
///
///         Usage:
///           BENEFICIARY=0xMultisig forge script script/Deploy.s.sol:Deploy \
///             --rpc-url base --broadcast --verify
///
///         Pre-flight: the deployer (msg.sender of the broadcast) must hold at least
///         1 USDS on Base for the seed swap, plus enough ETH for gas.
contract Deploy is Script {
    // ============================================================================================
    // Base mainnet addresses
    // ============================================================================================

    address internal constant CHAINLINK_GBP_USD = 0xCceA6576904C118037695eB71195a5425E69Fa15;
    address internal constant CHAINLINK_SEQUENCER_UPTIME = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    address internal constant SPARK_SSR_AUTH_ORACLE = 0x65d946e533748A998B1f0E430803e39A6388f7a1;
    address internal constant SUSDS_TOKEN = 0x5875eEE11Cf8398102FdAd704C9E96607675467a;
    address internal constant USDS_TOKEN = 0x820C137fa70C8691f0e44Dc420a5e53c168921Dc;
    address internal constant V4_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant SPARK_PSM3 = 0x1601843c5E9bC251A3272907010AFa41Fa18347E;

    /// Foundry's default CREATE2 deployer, present on every chain at the same address.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// Where seed GBPF goes. Standard "burn" address used by many protocols.
    address internal constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // ============================================================================================
    // Committed protocol parameters
    // ============================================================================================

    uint256 internal constant TWAP_WINDOW = 5 minutes;
    uint256 internal constant MAX_STALENESS = 26 hours;
    uint256 internal constant MAX_STEP_WAD = 0.02e18;
    uint256 internal constant SEQUENCER_GRACE = 1 hours;
    uint256 internal constant COOLDOWN = 15 minutes;

    /// BEFORE_SWAP_FLAG | BEFORE_SWAP_RETURNS_DELTA_FLAG.
    uint160 internal constant HOOK_FLAGS = (1 << 7) | (1 << 3);

    /// Mining cap. Empirically, mining a 2-bit pattern takes ~3000 iterations on average.
    uint256 internal constant MINING_LIMIT = 1_000_000;

    /// Bootstrap seed size, in USDS (18 decimals).
    uint256 internal constant SEED_USDS = 1e18;

    // ============================================================================================
    // Run
    // ============================================================================================

    struct Deployment {
        address oracle;
        address gbpf;
        address vault;
        address hook;
        bytes32 hookSalt;
    }

    function run() external returns (Deployment memory) {
        address beneficiary = vm.envAddress("BENEFICIARY");
        require(beneficiary != address(0), "BENEFICIARY env var unset or zero");

        // 1. Pre-flight verification: every hardcoded address must be live.
        _preflightChecks();

        vm.startBroadcast();

        // 2. Deploy OracleAdapter — no circular deps.
        OracleAdapter oracle = new OracleAdapter(
            CHAINLINK_GBP_USD,
            CHAINLINK_SEQUENCER_UPTIME,
            TWAP_WINDOW,
            MAX_STALENESS,
            MAX_STEP_WAD,
            SEQUENCER_GRACE,
            COOLDOWN
        );
        console2.log("OracleAdapter deployed at", address(oracle));

        // 3. Deploy GBPF (HOOK unset).
        GBPF gbpf = new GBPF();
        console2.log("GBPF deployed at", address(gbpf));

        // 4. Deploy Vault (HOOK unset). Vault needs USDS, GBPF, PSM3, PoolManager because it
        //    runs the deferred USDS→sUSDS conversion + GBPF burn during flush().
        Vault vault = new Vault(
            beneficiary, SUSDS_TOKEN, USDS_TOKEN, address(gbpf), SPARK_SSR_AUTH_ORACLE, SPARK_PSM3, V4_POOL_MANAGER
        );
        console2.log("Vault deployed at", address(vault));

        // 5. Mine a CREATE2 salt for the Hook such that its address encodes the required flags.
        bytes memory hookInitCode = abi.encodePacked(
            type(Hook).creationCode,
            abi.encode(
                V4_POOL_MANAGER, address(vault), address(oracle), address(gbpf), USDS_TOKEN, SUSDS_TOKEN, SPARK_PSM3
            )
        );
        (bytes32 salt, address predictedHook) =
            HookMiner.find(CREATE2_DEPLOYER, HOOK_FLAGS, hookInitCode, 0, MINING_LIMIT);
        console2.log("Hook salt mined:");
        console2.logBytes32(salt);
        console2.log("Hook predicted address:", predictedHook);

        // 6. Deploy the Hook via CREATE2 using the mined salt.
        Hook hook = new Hook{salt: salt}(
            V4_POOL_MANAGER, address(vault), address(oracle), address(gbpf), USDS_TOKEN, SUSDS_TOKEN, SPARK_PSM3
        );
        require(address(hook) == predictedHook, "hook landed at unexpected address");
        require((uint160(address(hook)) & 0x3fff) == HOOK_FLAGS, "hook address does not encode required flags");
        console2.log("Hook deployed at", address(hook));

        // 7. Wire HOOK into Vault and GBPF (one-shot initialise; reverts on re-call).
        vault.initialize(address(hook));
        gbpf.initialize(address(hook), address(vault));
        console2.log("Vault and GBPF initialised with hook address");

        // 8. Seed-and-burn deferred. On mainnet, the operator runs the seed swap as a
        //    separate transaction (see DEPLOY_DESIGN.md "seed on mainnet"). The script does
        //    NOT execute it because:
        //      a. The hook reverts on gbpfSupply == 0 (we'd need to pre-mint dust first).
        //      b. The swap path requires the V4 pool to be initialised on the PoolManager,
        //         which is a separate step.
        //    Operator instructions are emitted at the end of this script.

        vm.stopBroadcast();

        _printOperatorInstructions(address(vault), address(gbpf), address(hook), address(oracle), salt);

        return Deployment({
            oracle: address(oracle), gbpf: address(gbpf), vault: address(vault), hook: address(hook), hookSalt: salt
        });
    }

    // ============================================================================================
    // Pre-flight checks
    // ============================================================================================

    function _preflightChecks() internal view {
        require(CHAINLINK_GBP_USD.code.length > 0, "no code at Chainlink GBP/USD");
        require(CHAINLINK_SEQUENCER_UPTIME.code.length > 0, "no code at sequencer uptime");
        require(SPARK_SSR_AUTH_ORACLE.code.length > 0, "no code at Spark SSR oracle");
        require(SUSDS_TOKEN.code.length > 0, "no code at sUSDS");
        require(USDS_TOKEN.code.length > 0, "no code at USDS");
        require(V4_POOL_MANAGER.code.length > 0, "no code at V4 PoolManager");
        require(SPARK_PSM3.code.length > 0, "no code at Spark PSM3");
        require(CREATE2_DEPLOYER.code.length > 0, "no code at CREATE2 deployer");

        // Chainlink GBP/USD must report 8 decimals (OracleAdapter assumes this).
        require(IChainlinkFeed(CHAINLINK_GBP_USD).decimals() == 8, "Chainlink GBP/USD decimals != 8");

        // SSR oracle must report a sensible conversion rate.
        uint256 chi = ISSRAuthOracle(SPARK_SSR_AUTH_ORACLE).getConversionRate();
        require(chi >= 1e27 && chi < 2e27, "SSR conversion rate out of plausible range");
    }

    // ============================================================================================
    // Operator instructions
    // ============================================================================================

    function _printOperatorInstructions(
        address vaultAddr,
        address gbpfAddr,
        address hookAddr,
        address oracleAddr,
        bytes32 salt
    ) internal pure {
        console2.log("=== POST-DEPLOY MANUAL STEPS REQUIRED ===");
        console2.log("");
        console2.log("1. Initialise the V4 pool via PoolManager.initialize() with the canonical");
        console2.log("   PoolKey: { currency0: min(USDS, GBPF), currency1: max(USDS, GBPF),");
        console2.log("              fee: 0, tickSpacing: 1, hooks:", hookAddr);
        console2.log("            }");
        console2.log("");
        console2.log("2. Seed swap: perform an exact-input mint swap of 1 USDS via the V4");
        console2.log("   PoolManager. The deployer receives the resulting GBPF (~0.8 GBPF).");
        console2.log("   GBPF's constructor already minted 1 wei of dust to 0xdEaD, so the");
        console2.log("   gbpfSupply == 0 guard does not trip on this first user swap.");
        console2.log("");
        console2.log("3. Burn the seed: transfer all GBPF held by the deployer to 0xdEaD.");
        console2.log("");
        console2.log("After step 3, the protocol is fully bootstrapped and open for use.");
        console2.log("");
        console2.log("Deployed addresses:");
        console2.log("  OracleAdapter:", oracleAddr);
        console2.log("  Vault:        ", vaultAddr);
        console2.log("  GBPF:         ", gbpfAddr);
        console2.log("  Hook:         ", hookAddr);
        console2.log("  Hook salt:");
        console2.logBytes32(salt);
    }
}
