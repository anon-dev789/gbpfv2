// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Vault} from "../src/Vault.sol";
import {MockSUsds} from "./mocks/MockSUsds.sol";
import {MockSSRAuthOracle} from "./mocks/MockSSRAuthOracle.sol";

contract VaultTest is Test {
    // Base ray (10^27), matching how Sky / Spark express chi.
    uint256 internal constant RAY = 1e27;

    Vault internal vault;
    MockSUsds internal sUsds;
    MockSSRAuthOracle internal oracle;

    address internal hook;
    address internal beneficiary;
    address internal user;

    function setUp() public {
        hook = makeAddr("hook");
        beneficiary = makeAddr("beneficiary");
        user = makeAddr("user");

        sUsds = new MockSUsds();
        oracle = new MockSSRAuthOracle(RAY); // start chi at 1.0 in ray
        vault = new Vault(beneficiary, address(sUsds), address(oracle));
        vault.initialize(hook);
    }

    // ============================================================
    // Construction
    // ============================================================

    function test_constructor_seeds_lastSettledChi_from_oracle() public view {
        assertEq(vault.lastSettledChi(), RAY, "lastSettledChi seeded from oracle.getChi()");
    }

    function test_constructor_pendingBeneficiary_starts_zero() public view {
        assertEq(vault.pendingBeneficiarySUsds(), 0);
    }

    // ============================================================
    // initialize()
    // ============================================================

    function test_initialize_sets_HOOK() public view {
        assertEq(vault.HOOK(), hook, "initialize did not set HOOK");
    }

    function test_initialize_revertsOnSecondCall() public {
        vm.expectRevert(Vault.AlreadyInitialized.selector);
        vault.initialize(makeAddr("other"));
    }

    function test_initialize_revertsOnZeroAddress() public {
        Vault fresh = new Vault(beneficiary, address(sUsds), address(oracle));
        vm.expectRevert(Vault.ZeroHook.selector);
        fresh.initialize(address(0));
    }

    function test_deposit_revertsBeforeInitialize() public {
        Vault fresh = new Vault(beneficiary, address(sUsds), address(oracle));
        // Pre-initialize, deposit reverts NotInitialized for any caller.
        vm.expectRevert(Vault.NotInitialized.selector);
        fresh.deposit(1e18, 0);
    }

    function test_withdraw_revertsBeforeInitialize() public {
        Vault fresh = new Vault(beneficiary, address(sUsds), address(oracle));
        vm.expectRevert(Vault.NotInitialized.selector);
        fresh.withdraw(1e18, user, 0);
    }

    // ============================================================
    // Access control
    // ============================================================

    function test_deposit_revertsIfNotHook() public {
        sUsds.mint(address(vault), 1e18);
        vm.expectRevert(Vault.NotHook.selector);
        vault.deposit(1e18, 0);
    }

    function test_withdraw_revertsIfNotHook() public {
        sUsds.mint(address(vault), 1e18);
        vm.expectRevert(Vault.NotHook.selector);
        vault.withdraw(1e18, user, 0);
    }

    function test_settle_is_permissionless() public {
        // Anyone can call settle(). No assertion needed beyond "doesn't revert".
        vault.settle();
    }

    function test_withdrawBeneficiary_is_permissionless() public {
        // Seed some pending balance through a real deposit so the call doesn't no-op.
        sUsds.mint(address(vault), 1e18);
        vm.prank(hook);
        vault.deposit(1e18, 1e16); // 1% fee accrual

        uint256 pending = vault.pendingBeneficiarySUsds();
        assertGt(pending, 0);

        // A random caller can trigger it; funds go to BENEFICIARY regardless of caller.
        address randomCaller = address(0xDEAD);
        vm.prank(randomCaller);
        vault.withdrawBeneficiary();

        assertEq(sUsds.balanceOf(beneficiary), pending);
        assertEq(vault.pendingBeneficiarySUsds(), 0);
    }

    // ============================================================
    // Deposit
    // ============================================================

    function test_deposit_zero_reverts() public {
        vm.prank(hook);
        vm.expectRevert(Vault.ZeroAmount.selector);
        vault.deposit(0, 0);
    }

    function test_deposit_feeExceedsAmount_reverts() public {
        sUsds.mint(address(vault), 100e18);
        vm.prank(hook);
        vm.expectRevert(abi.encodeWithSelector(Vault.FeeExceedsAmount.selector, 101e18, 100e18));
        vault.deposit(100e18, 101e18);
    }

    function test_deposit_credits_fee_to_pending() public {
        sUsds.mint(address(vault), 100e18);
        vm.prank(hook);
        vault.deposit(100e18, 2e17); // 0.2 sUSDS fee
        assertEq(vault.pendingBeneficiarySUsds(), 2e17);
    }

    function test_deposit_zero_fee_pending_unchanged() public {
        sUsds.mint(address(vault), 100e18);
        vm.prank(hook);
        vault.deposit(100e18, 0);
        assertEq(vault.pendingBeneficiarySUsds(), 0);
    }

    // ============================================================
    // Withdraw
    // ============================================================

    function test_withdraw_pays_user_and_credits_fee() public {
        sUsds.mint(address(vault), 100e18);
        vm.prank(hook);
        vault.deposit(100e18, 0);

        vm.prank(hook);
        vault.withdraw(40e18, user, 1e17); // pay user 40, fee 0.1

        assertEq(sUsds.balanceOf(user), 40e18);
        assertEq(vault.pendingBeneficiarySUsds(), 1e17);
        // vault still holds (100 - 40) = 60
        assertEq(sUsds.balanceOf(address(vault)), 60e18);
    }

    function test_withdraw_blocked_when_exceeds_backing() public {
        sUsds.mint(address(vault), 100e18);
        vm.prank(hook);
        vault.deposit(100e18, 10e18); // 10 sUSDS owed to beneficiary

        // Backing = 100 - 10 = 90; ask for 91 should revert.
        vm.prank(hook);
        vm.expectRevert(abi.encodeWithSelector(Vault.InsufficientBackingForRedeem.selector, 91e18, 90e18));
        vault.withdraw(91e18, user, 0);
    }

    function test_withdraw_at_exact_backing_succeeds() public {
        sUsds.mint(address(vault), 100e18);
        vm.prank(hook);
        vault.deposit(100e18, 10e18);

        vm.prank(hook);
        vault.withdraw(90e18, user, 0);
        assertEq(sUsds.balanceOf(user), 90e18);
        // beneficiary share still there
        assertEq(vault.pendingBeneficiarySUsds(), 10e18);
        assertEq(sUsds.balanceOf(address(vault)), 10e18);
    }

    function test_withdraw_zero_reverts() public {
        vm.prank(hook);
        vm.expectRevert(Vault.ZeroAmount.selector);
        vault.withdraw(0, user, 0);
    }

    // ============================================================
    // Yield settlement
    // ============================================================

    /// chi bump should credit half the proportional growth, converted back to shares at new rate.
    function test_yield_settlement_credits_half_of_chi_growth() public {
        sUsds.mint(address(vault), 1000e18);
        vm.prank(hook);
        vault.deposit(1000e18, 0); // no fee, pending starts at 0

        // chi grows from 1.0 to 1.1 (in ray). USDS yield on principal = 1000 * 0.1 = 100 USDS.
        // Beneficiary's USDS claim = 50. Expressed in sUSDS shares at new rate 1.1:
        //   credit = 50 / 1.1 = 45.4545... sUSDS shares
        //   precisely: 1000 * 0.1 / (2 * 1.1) = 45.4545454545454545e18
        oracle.setChi(RAY * 110 / 100);

        vault.settle();
        uint256 expected = uint256(1000e18) * (RAY * 110 / 100 - RAY) / (2 * (RAY * 110 / 100));
        assertEq(vault.pendingBeneficiarySUsds(), expected);
        assertEq(vault.lastSettledChi(), RAY * 110 / 100);
    }

    /// Pending share is excluded from principal — no double-counting.
    function test_yield_settlement_excludes_pending_from_principal() public {
        sUsds.mint(address(vault), 1000e18);
        vm.prank(hook);
        vault.deposit(1000e18, 100e18); // 100 already owed to beneficiary

        // Principal that earns yield = 1000 - 100 = 900.
        // credit = 900 * 0.1 / (2 * 1.1) = 40.9090909...
        oracle.setChi(RAY * 110 / 100);

        vault.settle();
        uint256 expected = 100e18 + uint256(900e18) * (RAY * 110 / 100 - RAY) / (2 * (RAY * 110 / 100));
        assertEq(vault.pendingBeneficiarySUsds(), expected);
    }

    /// chi non-advance is a no-op (same block, or oracle paused).
    function test_yield_settlement_noop_when_chi_unchanged() public {
        sUsds.mint(address(vault), 1000e18);
        vm.prank(hook);
        vault.deposit(1000e18, 0);

        vault.settle();
        assertEq(vault.pendingBeneficiarySUsds(), 0, "no yield to credit when chi flat");
    }

    /// chi appearing to decrease is treated as a no-op (defensive).
    function test_yield_settlement_noop_when_chi_decreased() public {
        sUsds.mint(address(vault), 1000e18);
        vm.prank(hook);
        vault.deposit(1000e18, 0);

        oracle.setChi(RAY * 90 / 100); // less than initial
        vault.settle();
        assertEq(vault.pendingBeneficiarySUsds(), 0, "must not credit on chi decrease");
        // lastSettledChi should remain at the original value, not be moved backward.
        assertEq(vault.lastSettledChi(), RAY, "lastSettledChi must not roll back");
    }

    /// Repeated settlements between chi bumps credit each delta correctly.
    function test_yield_settlement_repeated_settles_credit_each_delta() public {
        sUsds.mint(address(vault), 1000e18);
        vm.prank(hook);
        vault.deposit(1000e18, 0);

        // Bump 1: chi 1.00 → 1.01. credit = 1000 * 0.01 / (2 * 1.01) ≈ 4.95049...
        oracle.setChi(RAY * 101 / 100);
        vault.settle();
        uint256 afterBump1 = vault.pendingBeneficiarySUsds();
        assertGt(afterBump1, 4.9e18);
        assertLt(afterBump1, 5e18);

        // Bump 2: chi 1.01 → 1.02. Principal = 1000 - afterBump1 ≈ 995.05;
        //   credit ≈ 995.05 * 0.01 / (2 * 1.02) ≈ 4.877...
        oracle.setChi(RAY * 102 / 100);
        vault.settle();
        uint256 pending = vault.pendingBeneficiarySUsds();
        // Sanity: between 9e18 and 10e18 (roughly two ~5e18 credits).
        assertGt(pending, 9e18);
        assertLt(pending, 10e18);
    }

    // ============================================================
    // Views (solvencyInputs / previewSolvencyInputs / backingBalance)
    // ============================================================

    function test_solvencyInputs_settles_first() public {
        sUsds.mint(address(vault), 1000e18);
        vm.prank(hook);
        vault.deposit(1000e18, 0);

        oracle.setChi(RAY * 110 / 100);
        uint256 expected = uint256(1000e18) * (RAY * 110 / 100 - RAY) / (2 * (RAY * 110 / 100));

        (uint256 bal, uint256 pending, uint256 rate) = vault.solvencyInputs();
        assertEq(bal, 1000e18);
        assertEq(pending, expected, "should be settled to fresh value");
        assertEq(rate, RAY * 110 / 100);
        // Storage was updated by the settlement
        assertEq(vault.pendingBeneficiarySUsds(), expected);
    }

    function test_previewSolvencyInputs_is_view_and_includes_unsettled() public {
        sUsds.mint(address(vault), 1000e18);
        vm.prank(hook);
        vault.deposit(1000e18, 0);

        oracle.setChi(RAY * 110 / 100);
        uint256 expected = uint256(1000e18) * (RAY * 110 / 100 - RAY) / (2 * (RAY * 110 / 100));

        (uint256 bal, uint256 pending, uint256 rate) = vault.previewSolvencyInputs();
        assertEq(bal, 1000e18);
        assertEq(pending, expected, "preview includes unsettled");
        assertEq(rate, RAY * 110 / 100);
        // Storage was NOT updated
        assertEq(vault.pendingBeneficiarySUsds(), 0);
    }

    function test_backingBalance_subtracts_unsettled() public {
        sUsds.mint(address(vault), 1000e18);
        vm.prank(hook);
        vault.deposit(1000e18, 0);

        oracle.setChi(RAY * 110 / 100); // would credit ~45.45 to beneficiary if settled
        uint256 expected = uint256(1000e18) * (RAY * 110 / 100 - RAY) / (2 * (RAY * 110 / 100));

        assertEq(vault.backingBalance(), 1000e18 - expected, "backing must exclude unsettled yield share");
    }

    // ============================================================
    // withdrawBeneficiary
    // ============================================================

    function test_withdrawBeneficiary_settles_first() public {
        sUsds.mint(address(vault), 1000e18);
        vm.prank(hook);
        vault.deposit(1000e18, 0);

        oracle.setChi(RAY * 110 / 100);
        uint256 expected = uint256(1000e18) * (RAY * 110 / 100 - RAY) / (2 * (RAY * 110 / 100));

        vault.withdrawBeneficiary();
        assertEq(sUsds.balanceOf(beneficiary), expected);
        assertEq(vault.pendingBeneficiarySUsds(), 0);
    }

    function test_withdrawBeneficiary_reverts_when_nothing_pending() public {
        sUsds.mint(address(vault), 1000e18);
        vm.prank(hook);
        vault.deposit(1000e18, 0);

        // No fees, no yield growth → nothing to withdraw
        vm.expectRevert(Vault.NothingToWithdraw.selector);
        vault.withdrawBeneficiary();
    }

    function test_withdrawBeneficiary_resets_pending() public {
        sUsds.mint(address(vault), 1000e18);
        vm.prank(hook);
        vault.deposit(1000e18, 50e18);

        vault.withdrawBeneficiary();
        assertEq(vault.pendingBeneficiarySUsds(), 0);
        assertEq(sUsds.balanceOf(beneficiary), 50e18);
    }

    // ============================================================
    // Fuzz: pendingBeneficiary never exceeds vault balance
    // ============================================================

    function testFuzz_pending_never_exceeds_balance(uint256 depositAmount, uint256 feeAmount, uint256 chiBumpPct)
        public
    {
        depositAmount = bound(depositAmount, 1, 1e30);
        feeAmount = bound(feeAmount, 0, depositAmount);
        chiBumpPct = bound(chiBumpPct, 0, 1000); // up to 10x growth

        sUsds.mint(address(vault), depositAmount);
        vm.prank(hook);
        vault.deposit(depositAmount, feeAmount);

        // Bump chi by the fuzzed percentage
        oracle.setChi(RAY * (100 + chiBumpPct) / 100);

        vault.settle();

        assertLe(vault.pendingBeneficiarySUsds(), sUsds.balanceOf(address(vault)), "pending exceeded vault balance");
    }

    // ============================================================
    // Fuzz: monotonic lastSettledChi
    // ============================================================

    function testFuzz_lastSettledChi_monotonic(uint256 chi1, uint256 chi2) public {
        // Both must be at-or-above the initial RAY so we don't trip the noop-on-decrease path
        // and then claim monotonicity for the noop case (already covered by a unit test).
        chi1 = bound(chi1, RAY, RAY * 100);
        chi2 = bound(chi2, chi1, RAY * 100);

        sUsds.mint(address(vault), 1000e18);
        vm.prank(hook);
        vault.deposit(1000e18, 0);

        oracle.setChi(chi1);
        vault.settle();
        uint256 a = vault.lastSettledChi();

        oracle.setChi(chi2);
        vault.settle();
        uint256 b = vault.lastSettledChi();

        assertGe(b, a, "lastSettledChi went backwards");
    }
}
