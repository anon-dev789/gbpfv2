// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Vault} from "../../src/Vault.sol";
import {ISSRAuthOracle} from "../../src/interfaces/ISSRAuthOracle.sol";

/// @dev Verifies the Vault constructor and yield read against the real Spark SSRAuthOracle on Base.
///      Full mint/redeem/flush flows are covered by Hook.fork.t.sol (which exercises the real
///      PoolManager); this suite is just the Vault-in-isolation against real Spark state.
contract VaultForkTest is Test {
    uint256 internal constant BASE_FORK_BLOCK = 46_700_000;

    address internal constant SPARK_SSR_AUTH_ORACLE = 0x65d946e533748A998B1f0E430803e39A6388f7a1;
    address internal constant SUSDS_TOKEN = 0x5875eEE11Cf8398102FdAd704C9E96607675467a;
    address internal constant USDS_TOKEN = 0x820C137fa70C8691f0e44Dc420a5e53c168921Dc;
    address internal constant SPARK_PSM3 = 0x1601843c5E9bC251A3272907010AFa41Fa18347E;
    address internal constant V4_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;

    Vault internal vault;
    address internal hook;
    address internal beneficiary;
    address internal gbpfPlaceholder;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        vm.createSelectFork(rpc, BASE_FORK_BLOCK);

        hook = makeAddr("hook");
        beneficiary = makeAddr("beneficiary");
        gbpfPlaceholder = makeAddr("gbpf-placeholder");

        vault = new Vault(
            beneficiary, SUSDS_TOKEN, USDS_TOKEN, gbpfPlaceholder, SPARK_SSR_AUTH_ORACLE, SPARK_PSM3, V4_POOL_MANAGER
        );
        vault.initialize(hook);
    }

    function test_constructor_seeds_lastSettledChi_from_real_oracle() public view {
        // Vault seeds from getConversionRate() (extrapolated chi), NOT getChi() (stored chi).
        uint256 expected = ISSRAuthOracle(SPARK_SSR_AUTH_ORACLE).getConversionRate();
        assertEq(vault.lastSettledChi(), expected);
        // Sanity: at this fork block, the conversion rate should be > 1 ray (sUSDS > USDS).
        assertGt(vault.lastSettledChi(), 1e27, "chi seed <= 1 ray, looks wrong");
        // Sanity: the conversion rate should be >= the stored chi (yield monotonic).
        assertGe(vault.lastSettledChi(), ISSRAuthOracle(SPARK_SSR_AUTH_ORACLE).getChi());
    }

    function test_constructor_max_approves_psm_for_usds() public view {
        (bool ok, bytes memory data) =
            USDS_TOKEN.staticcall(abi.encodeWithSignature("allowance(address,address)", address(vault), SPARK_PSM3));
        assertTrue(ok, "allowance() call failed");
        assertEq(abi.decode(data, (uint256)), type(uint256).max, "USDS->PSM3 max approval missing");
    }

    function test_yield_accrues_against_real_oracle() public {
        // No principal seeded, but settle should advance lastSettledChi anyway.
        uint256 chiBefore = vault.lastSettledChi();
        vm.warp(block.timestamp + 30 days);
        vault.settle();
        uint256 chiAfter = vault.lastSettledChi();
        assertGt(chiAfter, chiBefore, "chi did not advance after 30 days");
        // No principal => no beneficiary credit.
        assertEq(vault.pendingBeneficiarySUsds(), 0);
    }

    function test_solvencyInputs_against_real_oracle() public {
        (uint256 bal, uint256 pending, uint256 rate, uint256 claimBacking) = vault.solvencyInputs();
        assertEq(bal, 0, "vault balance non-zero at empty start");
        assertEq(pending, 0);
        assertGt(rate, 1e27, "ssr rate <= 1 ray");
        assertEq(claimBacking, 0);
    }
}
