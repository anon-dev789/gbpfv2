// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Deploy} from "../../script/Deploy.s.sol";

import {OracleAdapter} from "../../src/OracleAdapter.sol";
import {Vault} from "../../src/Vault.sol";
import {GBPF} from "../../src/GBPF.sol";
import {Hook} from "../../src/Hook.sol";

import {IChainlinkFeed} from "../../src/interfaces/IChainlinkFeed.sol";
import {ISSRAuthOracle} from "../../src/interfaces/ISSRAuthOracle.sol";

/// @dev Runs the production deploy script against a Base mainnet fork and verifies the result.
///      Does NOT execute the post-deploy seed swap (that's an operator step; the design rationale
///      is in DEPLOY_DESIGN.md).
contract DeployForkTest is Test {
    uint256 internal constant BASE_FORK_BLOCK = 46_700_000;

    Deploy internal script;
    address internal beneficiary;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        vm.createSelectFork(rpc, BASE_FORK_BLOCK);

        beneficiary = makeAddr("beneficiary-multisig");
        vm.setEnv("BENEFICIARY", vm.toString(beneficiary));

        script = new Deploy();
    }

    function test_deploy_succeeds_and_returns_addresses() public {
        Deploy.Deployment memory d = script.run();
        assertTrue(d.oracle != address(0));
        assertTrue(d.gbpf != address(0));
        assertTrue(d.vault != address(0));
        assertTrue(d.hook != address(0));
    }

    function test_deploy_hook_address_encodes_required_flags() public {
        Deploy.Deployment memory d = script.run();
        // BEFORE_SWAP_FLAG (bit 7) | BEFORE_SWAP_RETURNS_DELTA_FLAG (bit 3) = 0x88.
        uint160 expectedFlags = (1 << 7) | (1 << 3);
        assertEq(uint160(d.hook) & 0x3fff, expectedFlags, "hook address flags wrong");
    }

    function test_deploy_wires_oracle_to_real_chainlink() public {
        Deploy.Deployment memory d = script.run();
        OracleAdapter oracle = OracleAdapter(d.oracle);
        // The constructor seeds latestPriceWad from Chainlink. Sanity check the value.
        uint256 priceWad = oracle.latestPriceWad();
        assertGt(priceWad, 0.8e18, "seed price implausibly low");
        assertLt(priceWad, 2.0e18, "seed price implausibly high");
    }

    function test_deploy_wires_vault_to_real_susds_and_ssr() public {
        Deploy.Deployment memory d = script.run();
        Vault vault = Vault(d.vault);
        assertEq(vault.BENEFICIARY(), beneficiary);
        assertEq(vault.SUSDS(), 0x5875eEE11Cf8398102FdAd704C9E96607675467a);
        assertEq(address(vault.SSR_ORACLE()), 0x65d946e533748A998B1f0E430803e39A6388f7a1);
        // lastSettledChi was seeded from getConversionRate() at deploy time.
        assertGt(vault.lastSettledChi(), 1e27, "lastSettledChi <= 1 ray");
    }

    function test_deploy_initialises_vault_and_gbpf_with_hook() public {
        Deploy.Deployment memory d = script.run();
        assertEq(Vault(d.vault).HOOK(), d.hook);
        assertEq(GBPF(d.gbpf).HOOK(), d.hook);
    }

    function test_deploy_initialize_cannot_be_called_again() public {
        Deploy.Deployment memory d = script.run();
        address attacker = makeAddr("attacker");
        vm.startPrank(attacker);
        vm.expectRevert(Vault.AlreadyInitialized.selector);
        Vault(d.vault).initialize(attacker);
        vm.expectRevert(GBPF.AlreadyInitialized.selector);
        GBPF(d.gbpf).initialize(attacker);
        vm.stopPrank();
    }

    function test_deploy_hook_immutables_match_real_addresses() public {
        Deploy.Deployment memory d = script.run();
        Hook hook = Hook(d.hook);
        assertEq(address(hook.POOL_MANAGER()), 0x498581fF718922c3f8e6A244956aF099B2652b2b);
        assertEq(address(hook.VAULT()), d.vault);
        assertEq(address(hook.ORACLE()), d.oracle);
        assertEq(address(hook.GBPF_TOKEN()), d.gbpf);
        assertEq(hook.USDS(), 0x820C137fa70C8691f0e44Dc420a5e53c168921Dc);
        assertEq(hook.SUSDS(), 0x5875eEE11Cf8398102FdAd704C9E96607675467a);
        assertEq(address(hook.PSM3()), 0x1601843c5E9bC251A3272907010AFa41Fa18347E);
    }

    function test_deploy_hook_has_max_approvals_to_psm() public {
        Deploy.Deployment memory d = script.run();
        Hook hook = Hook(d.hook);
        // Approvals are checked via balanceOf->allowance reads.
        (bool ok, bytes memory data) = hook.USDS()
            .staticcall(abi.encodeWithSignature("allowance(address,address)", address(hook), address(hook.PSM3())));
        assertTrue(ok);
        assertEq(abi.decode(data, (uint256)), type(uint256).max, "USDS->PSM3 max approval missing");
        (ok, data) = hook.SUSDS()
            .staticcall(abi.encodeWithSignature("allowance(address,address)", address(hook), address(hook.PSM3())));
        assertTrue(ok);
        assertEq(abi.decode(data, (uint256)), type(uint256).max, "sUSDS->PSM3 max approval missing");
    }
}
