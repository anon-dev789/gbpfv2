// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Vault} from "../src/Vault.sol";
import {MockSUsds} from "./mocks/MockSUsds.sol";
import {MockUsds} from "./mocks/MockUsds.sol";
import {MockSSRAuthOracle} from "./mocks/MockSSRAuthOracle.sol";
import {MockPSM3} from "./mocks/MockPSM3.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";

import {GBPF} from "../src/GBPF.sol";

/// @dev Vault unit tests for the V4 6909-claim flow.
contract VaultTest is Test {
    uint256 internal constant RAY = 1e27;

    Vault internal vault;
    GBPF internal gbpf;
    MockSUsds internal sUsds;
    MockUsds internal usds;
    MockSSRAuthOracle internal oracle;
    MockPSM3 internal psm;
    MockPoolManager internal pm;

    address internal hook;
    address internal beneficiary;
    address internal user;

    function setUp() public {
        hook = makeAddr("hook");
        beneficiary = makeAddr("beneficiary");
        user = makeAddr("user");

        sUsds = new MockSUsds();
        usds = new MockUsds();
        oracle = new MockSSRAuthOracle(RAY);
        psm = new MockPSM3(address(usds), address(sUsds), RAY);
        pm = new MockPoolManager();
        gbpf = new GBPF();

        vault = new Vault(
            beneficiary, address(sUsds), address(usds), address(gbpf), address(oracle), address(psm), address(pm)
        );
        vault.initialize(hook);
        gbpf.initialize(hook, address(vault));
    }

    // ============================================================
    // Construction
    // ============================================================

    function test_constructor_seeds_lastSettledChi_from_oracle() public view {
        assertEq(vault.lastSettledChi(), RAY);
    }

    function test_constructor_pendings_start_zero() public view {
        assertEq(vault.pendingBeneficiarySUsds(), 0);
        assertEq(vault.principalSUsds(), 0);
        assertEq(vault.pendingUsdsClaim(), 0);
        assertEq(vault.pendingGbpfClaim(), 0);
        assertEq(vault.pendingBeneficiaryUsdsClaim(), 0);
    }

    function test_constructor_approves_psm() public view {
        assertEq(usds.allowance(address(vault), address(psm)), type(uint256).max);
    }

    // ============================================================
    // Initialize
    // ============================================================

    function test_initialize_sets_HOOK() public view {
        assertEq(vault.HOOK(), hook);
    }

    function test_initialize_revertsOnSecondCall() public {
        vm.expectRevert(Vault.AlreadyInitialized.selector);
        vault.initialize(makeAddr("other"));
    }

    function test_initialize_revertsOnZero() public {
        Vault fresh = new Vault(
            beneficiary, address(sUsds), address(usds), address(gbpf), address(oracle), address(psm), address(pm)
        );
        vm.expectRevert(Vault.ZeroHook.selector);
        fresh.initialize(address(0));
    }

    // ============================================================
    // recordMint access control
    // ============================================================

    function test_recordMint_revertsIfNotHook() public {
        vm.expectRevert(Vault.NotHook.selector);
        vault.recordMint(1e18, 0);
    }

    function test_recordMint_revertsBeforeInitialize() public {
        Vault fresh = new Vault(
            beneficiary, address(sUsds), address(usds), address(gbpf), address(oracle), address(psm), address(pm)
        );
        vm.expectRevert(Vault.NotInitialized.selector);
        fresh.recordMint(1e18, 0);
    }

    function test_recordMint_zero_reverts() public {
        vm.prank(hook);
        vm.expectRevert(Vault.ZeroAmount.selector);
        vault.recordMint(0, 0);
    }

    function test_recordMint_feeExceedsAmount_reverts() public {
        vm.prank(hook);
        vm.expectRevert(abi.encodeWithSelector(Vault.FeeExceedsAmount.selector, 11e18, 10e18));
        vault.recordMint(10e18, 11e18);
    }

    function test_recordMint_accumulates_claim_and_fee() public {
        vm.prank(hook);
        vault.recordMint(100e18, 2e18);
        assertEq(vault.pendingUsdsClaim(), 100e18);
        assertEq(vault.pendingBeneficiaryUsdsClaim(), 2e18);
    }

    function test_recordMint_multiple_accumulate() public {
        vm.startPrank(hook);
        vault.recordMint(100e18, 2e18);
        vault.recordMint(50e18, 1e18);
        vm.stopPrank();
        assertEq(vault.pendingUsdsClaim(), 150e18);
        assertEq(vault.pendingBeneficiaryUsdsClaim(), 3e18);
    }

    // ============================================================
    // recordRedeem access control + behaviour
    // ============================================================

    function test_recordRedeem_revertsIfNotHook() public {
        vm.expectRevert(Vault.NotHook.selector);
        vault.recordRedeem(1e18, 1e18, 0);
    }

    function test_recordRedeem_zero_reverts() public {
        vm.prank(hook);
        vm.expectRevert(Vault.ZeroAmount.selector);
        vault.recordRedeem(0, 1e18, 0);
    }

    function test_recordRedeem_blockedWhenExceedsBacking() public {
        // No principal seeded; any redeem should hit InsufficientBackingForRedeem.
        vm.prank(hook);
        vm.expectRevert(abi.encodeWithSelector(Vault.InsufficientBackingForRedeem.selector, 1e18, 0));
        vault.recordRedeem(1e18, 1e18, 0);
    }

    function test_recordRedeem_transfers_sUsds_and_records_claim() public {
        // Seed principalSUsds by running a real flush cycle.
        _seedPrincipal(100e18);

        vm.prank(hook);
        vault.recordRedeem(40e18, 30e18, 1e18); // 40 sUSDS to hook, 30 GBPF claim, 1 sUSDS fee

        assertEq(sUsds.balanceOf(hook), 40e18, "hook didn't receive sUSDS");
        assertEq(vault.pendingGbpfClaim(), 30e18);
        assertEq(vault.pendingBeneficiarySUsds(), 1e18);
        assertEq(vault.principalSUsds(), 100e18 - 40e18 - 1e18);
    }

    // ============================================================
    // flush
    // ============================================================

    function test_flush_revertsWhenNothingPending() public {
        vm.expectRevert(Vault.NothingToFlush.selector);
        vault.flush();
    }

    function test_flush_converts_usds_claim_to_sUsds() public {
        // Simulate a mint: hook records a 100 USDS claim with 2 USDS fee.
        _simulateMintRecord(100e18, 2e18);

        vault.flush();

        // Vault should have ~100 sUSDS (PSM3 1:1 in this test setup).
        assertEq(sUsds.balanceOf(address(vault)), 100e18);
        // Principal = 98 (post-fee), pendingBeneficiary = 2.
        assertEq(vault.principalSUsds(), 98e18);
        assertEq(vault.pendingBeneficiarySUsds(), 2e18);
        // Claims cleared.
        assertEq(vault.pendingUsdsClaim(), 0);
        assertEq(vault.pendingBeneficiaryUsdsClaim(), 0);
    }

    function test_flush_burns_gbpf_claim() public {
        // First mint a GBPF supply that PM holds (it'll be transferred to the vault during flush).
        // Then seed the vault's pendingGbpfClaim directly via storage so flush has work to do.
        vm.prank(hook);
        gbpf.mint(address(pm), 100e18); // PM holds the GBPF that flush will take from it
        pm.mintClaim(address(vault), uint256(uint160(address(gbpf))), 100e18);
        _writePendingGbpfClaim(100e18);

        uint256 supplyBefore = gbpf.totalSupply();
        vault.flush();

        assertEq(vault.pendingGbpfClaim(), 0);
        // GBPF supply dropped by 100e18.
        assertEq(gbpf.totalSupply(), supplyBefore - 100e18);
    }

    // ============================================================
    // withdrawBeneficiary
    // ============================================================

    function test_withdrawBeneficiary_revertsWhenNothingPending() public {
        vm.expectRevert(Vault.NothingToWithdraw.selector);
        vault.withdrawBeneficiary();
    }

    function test_withdrawBeneficiary_sendsTo_beneficiary() public {
        // Build up some pendingBeneficiarySUsds via a mint+flush cycle.
        _simulateMintRecord(100e18, 5e18);
        vault.flush();
        assertEq(vault.pendingBeneficiarySUsds(), 5e18);

        vault.withdrawBeneficiary();
        assertEq(sUsds.balanceOf(beneficiary), 5e18);
        assertEq(vault.pendingBeneficiarySUsds(), 0);
    }

    // ============================================================
    // Yield settlement (unchanged math, exercised under new flow)
    // ============================================================

    function test_yield_settle_after_principal_seeded() public {
        _seedPrincipal(1000e18);

        // Bump oracle by 10%.
        oracle.setConversionRate(RAY * 110 / 100);
        vault.settle();

        // Yield over the interval = principal * chiDelta / RAY = 1000 * 0.1 = 100 USDS.
        // Beneficiary's half is now tracked in USDS (path-independent), not in shares.
        assertEq(vault.beneficiaryYieldUsds(), 50e18, "beneficiary half of 100 USDS yield");
        // Flat-fee bucket is untouched by yield.
        assertEq(vault.pendingBeneficiarySUsds(), 0, "no flat fees");
        assertEq(vault.lastSettledChi(), RAY * 110 / 100);

        // Converted to shares at the new chi (1.1): 50 / 1.1 ≈ 45.4545 sUSDS — matches the
        // single-step value of the previous formula (which was only correct for a single step).
        uint256 expectedShares = uint256(50e18) * RAY / (RAY * 110 / 100);
        (, uint256 pendingBeneficiary,,) = vault.previewSolvencyInputs();
        assertEq(pendingBeneficiary, expectedShares, "yield in shares at live chi");
    }

    /// @dev The core property the fix establishes: settling the SAME chi interval in many small
    ///      steps credits the beneficiary the SAME USDS amount as settling once (modulo sub-wei
    ///      flooring). The previous in-shares incremental formula over-credited here.
    function test_yield_settle_is_step_count_invariant() public {
        _seedPrincipal(1000e18);

        // Single-step reference: 1.0 -> 1.05 in one settle.
        oracle.setConversionRate(RAY * 105 / 100);
        vault.settle();
        uint256 singleStep = vault.beneficiaryYieldUsds();

        // Reset a fresh vault and do the same interval in 50 steps.
        setUp();
        _seedPrincipal(1000e18);
        for (uint256 i = 1; i <= 50; i++) {
            uint256 chi = RAY + (RAY * 5 / 100) * i / 50; // linearly from RAY to 1.05*RAY
            oracle.setConversionRate(chi);
            vault.settle();
        }
        uint256 multiStep = vault.beneficiaryYieldUsds();

        // Equal to within a handful of wei of flooring — NOT the ~0.6%+ drift of the old formula.
        assertApproxEqAbs(multiStep, singleStep, 100, "USDS credit is step-count invariant");
    }

    // ============================================================
    // Helpers
    // ============================================================

    /// @dev Helper to put `amount` of sUSDS principal in the vault by running a mint+flush.
    function _seedPrincipal(uint256 amountUsds) internal {
        _simulateMintRecord(amountUsds, 0);
        vault.flush();
    }

    /// @dev Simulate a hook calling `vault.recordMint` after PM has minted a claim.
    function _simulateMintRecord(uint256 amount, uint256 fee) internal {
        // Mock PM gives the vault a 6909 USDS claim.
        pm.mintClaim(address(vault), uint256(uint160(address(usds))), amount);
        // Pre-fund PM with real USDS so the subsequent take in flush works.
        pm.fund(address(usds), amount);
        // Hook records the claim.
        vm.prank(hook);
        vault.recordMint(amount, fee);
    }

    /// @dev Direct storage write into pendingGbpfClaim for tests that build state synthetically.
    ///      Slot ordering of public state: 0=HOOK, 1=pendingBeneficiarySUsds, 2=principalSUsds,
    ///      3=beneficiaryYieldUsds, 4=lastSettledChi, 5=pendingUsdsClaim,
    ///      6=pendingBeneficiaryUsdsClaim, 7=pendingGbpfClaim, 8=_unlocking. Slot 7 is pendingGbpfClaim.
    function _writePendingGbpfClaim(uint256 amount) internal {
        vm.store(address(vault), bytes32(uint256(7)), bytes32(amount));
    }
}
