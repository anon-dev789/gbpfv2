// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SpreadCurve} from "../src/SpreadCurve.sol";

contract SpreadCurveTest is Test {
    // Tolerance for sanity-table assertions: 0.5 bp (0.005%) in WAD = 5e13.
    // The committed sanity values in project_gbpf_curve.md are rounded to the nearest bp,
    // so we allow up to half a bp of drift between the rounded reference and the exact tanh.
    uint256 internal constant TOL_WAD = 5e13;

    // ============================================================
    // Sanity-table assertions — reproducing project_gbpf_curve.md
    // ============================================================

    function test_spread_at_100pct_is_zero() public pure {
        assertEq(SpreadCurve.spread(1e18), 0);
    }

    // Under-collateralised → spread is NEGATIVE (GBPF discounted: cheaper mint, redeem haircut).
    function test_spread_at_99pct_is_about_minus20bp() public {
        // expected: ~ -20 bp = -0.002 WAD = -2e15
        int256 s = SpreadCurve.spread(0.99e18);
        _assertCloseSigned(s, -int256(2e15), TOL_WAD, "99%");
    }

    function test_spread_at_97pct_is_about_minus173bp() public {
        // expected: -tanh(0.36) * 5% ~ -172.6 bp = -0.01726 WAD
        int256 s = SpreadCurve.spread(0.97e18);
        _assertCloseSigned(s, -int256(17260701706776044), TOL_WAD, "97%");
    }

    function test_spread_at_95pct_is_about_minus381bp() public {
        // expected: -tanh(1) * 5% ~ -380.8 bp = -0.03808 WAD
        int256 s = SpreadCurve.spread(0.95e18);
        _assertCloseSigned(s, -int256(38079707797788244), TOL_WAD, "95%");
    }

    function test_spread_at_90pct_is_about_minus500bp() public {
        // expected: -tanh(4) * 5% ~ -499.7 bp = -0.04997 WAD (very close to -S_MAX cap)
        int256 s = SpreadCurve.spread(0.9e18);
        _assertCloseSigned(s, -int256(49966464986953352), TOL_WAD, "90%");
    }

    function test_spread_at_80pct_is_capped_negative() public {
        // expected: saturated at -S_MAX = -500 bp = -0.05 WAD
        int256 s = SpreadCurve.spread(0.8e18);
        _assertCloseSigned(s, -int256(SpreadCurve.S_MAX), TOL_WAD, "80%");
    }

    // Over-collateralised → no spread at all (one-sided curve: a surplus is not a risk to defend).
    function test_spread_at_103pct_is_zero() public pure {
        assertEq(SpreadCurve.spread(1.03e18), 0, "no spread above peg");
    }

    function test_spread_at_120pct_is_zero() public pure {
        assertEq(SpreadCurve.spread(1.2e18), 0, "no spread above peg");
    }

    // ============================================================
    // Property tests
    // ============================================================

    /// Spread is always bounded by ±S_MAX. Fuzz across all reasonable solvencies.
    function testFuzz_spread_bounded(uint256 solvencyWad) public pure {
        // Constrain to a plausible range: 0% to 1000% solvency.
        solvencyWad = bound(solvencyWad, 0, 10e18);
        int256 s = SpreadCurve.spread(solvencyWad);
        int256 cap = int256(SpreadCurve.S_MAX);
        assertLe(s, cap, "spread exceeds +S_MAX");
        assertGe(s, -cap, "spread exceeds -S_MAX");
    }

    /// One-sided: the spread is exactly zero at and above peg (no surplus-side intervention).
    function testFuzz_spread_zero_at_or_above_peg(uint256 solvencyWad) public pure {
        solvencyWad = bound(solvencyWad, 1e18, 10e18);
        assertEq(SpreadCurve.spread(solvencyWad), 0, "spread must be zero at/above 100% solvency");
    }

    /// Sign: spread(s<1) <= 0 (discount), spread(s>=1) == 0. The curve is never positive.
    /// Note: very close to peg the curve genuinely rounds to zero in WAD precision —
    /// this is correct behaviour (a sub-wei spread is meaningless) and we allow it here.
    function testFuzz_spread_sign(uint256 solvencyWad) public pure {
        solvencyWad = bound(solvencyWad, 1, 10e18);
        int256 s = SpreadCurve.spread(solvencyWad);
        if (solvencyWad < 1e18) {
            assertLe(s, 0, "spread should be non-positive (discount) when undercollateralised");
        } else {
            assertEq(s, 0, "spread should be zero at/above peg");
        }
    }

    /// Monotonicity: as solvency decreases below 1, the spread becomes MORE negative
    /// (deeper discount). So for a < b (both below peg), spread(a) <= spread(b).
    function testFuzz_spread_monotonic_below_peg(uint256 a, uint256 b) public pure {
        a = bound(a, 1, 1e18 - 1);
        b = bound(b, 1, 1e18 - 1);
        if (a == b) return;
        if (a > b) (a, b) = (b, a); // a < b, both below 1e18
        int256 sa = SpreadCurve.spread(a); // lower solvency -> more negative (deeper discount)
        int256 sb = SpreadCurve.spread(b);
        assertLe(sa, sb, "spread should be non-decreasing in solvency below peg");
    }

    /// Near peg the spread is small (the "nearly flat" property).
    /// At solvency 99.9% (d = 0.1%), spread should be a tiny discount: 0 > s > -1 bp.
    function test_spread_near_peg_is_small() public pure {
        int256 s = SpreadCurve.spread(0.999e18);
        // 1 bp = 1e14 WAD
        assertGt(s, -int256(1e14), "spread magnitude at 99.9% should be < 1bp");
        assertLt(s, 0, "spread at 99.9% should be a (tiny) discount");
    }

    // ============================================================
    // Economic-direction guards — prevent regression of the spread sign
    // ============================================================
    //
    // The original deployment had this sign inverted: it paid redeemers a PREMIUM at a shortfall,
    // which drains the vault (ds = (dS/S)·(s − r) < 0 when payout r > solvency s) and violates the
    // "solvent by construction" invariant. These tests pin the protective direction so it cannot
    // silently regress. Note: with the ±S_MAX = 5% cap, the haircut at a deep shortfall is NOT a
    // full backing-haircut (redeem stays above true backing) — these guards assert "discount, not
    // premium", which is the necessary direction; a full backing guarantee is a separate cap design.

    uint256 internal constant FLAT_FEE_WAD = 2e15; // mirrors Hook.FLAT_FEE_WAD (20bp), for price-multiplier checks

    /// At a shortfall the spread must DISCOUNT GBPF (negative), never add a premium.
    function test_shortfall_spread_is_discount() public pure {
        assertLt(SpreadCurve.spread(0.95e18), 0, "shortfall spread must be negative (discount)");
        assertLt(SpreadCurve.spread(0.76e18), 0, "deep shortfall spread must be negative (discount)");
    }

    /// At a surplus there is NO spread (one-sided curve: we don't intervene when over-collateralised).
    function test_surplus_spread_is_zero() public pure {
        assertEq(SpreadCurve.spread(1.05e18), 0, "surplus must have no spread");
        assertEq(SpreadCurve.spread(2e18), 0, "large surplus must have no spread");
    }

    /// THE anti-drain guard: at a (deep) shortfall the redeem price multiplier
    /// (WAD + spread − flatFee) must be strictly BELOW peg, so a redeemer is haircut rather than
    /// paid a premium. This is the property whose inversion drained the vault.
    function test_shortfall_redeem_priced_below_peg() public pure {
        int256 s = SpreadCurve.spread(0.8e18); // -S_MAX
        int256 redeemMul = int256(1e18) + s - int256(FLAT_FEE_WAD);
        assertLt(redeemMul, int256(1e18), "redeem must be priced below peg at a shortfall");
    }

    /// At a (deep) shortfall, minting should also be discounted (below peg) to pull collateral in —
    /// never carry a shortfall premium. (Holds once |spread| > flatFee, i.e. beyond a marginal dip.)
    function test_shortfall_mint_not_premium() public pure {
        int256 s = SpreadCurve.spread(0.8e18); // -S_MAX
        int256 mintMul = int256(1e18) + s + int256(FLAT_FEE_WAD);
        assertLt(mintMul, int256(1e18), "mint must not carry a premium at a shortfall");
    }

    // ============================================================
    // tanhWad direct tests
    // ============================================================

    function test_tanh_zero() public pure {
        assertEq(SpreadCurve.tanhWad(0), 0);
    }

    function test_tanh_one() public {
        // tanh(1) ~ 0.7615941559557649
        uint256 t = SpreadCurve.tanhWad(1e18);
        _assertCloseUnsigned(t, 761594155955764880, 1e10, "tanh(1)");
    }

    function test_tanh_two() public {
        // tanh(2) ~ 0.9640275800758169
        uint256 t = SpreadCurve.tanhWad(2e18);
        _assertCloseUnsigned(t, 964027580075816884, 1e10, "tanh(2)");
    }

    function test_tanh_saturates() public pure {
        // tanh(20) and above must equal exactly WAD by our saturation clamp.
        assertEq(SpreadCurve.tanhWad(20e18), 1e18);
        assertEq(SpreadCurve.tanhWad(100e18), 1e18);
        assertEq(SpreadCurve.tanhWad(type(uint128).max), 1e18);
    }

    function testFuzz_tanh_bounded(uint256 x) public pure {
        // Keep x within a range where expWad won't revert, even before our 20e18 clamp.
        x = bound(x, 0, 50e18);
        uint256 t = SpreadCurve.tanhWad(x);
        assertLe(t, 1e18, "tanh > 1");
    }

    function testFuzz_tanh_monotonic(uint256 a, uint256 b) public pure {
        a = bound(a, 0, 19e18);
        b = bound(b, 0, 19e18);
        if (a > b) (a, b) = (b, a);
        uint256 ta = SpreadCurve.tanhWad(a);
        uint256 tb = SpreadCurve.tanhWad(b);
        assertLe(ta, tb, "tanh not monotonic");
    }

    // ============================================================
    // Helpers
    // ============================================================

    function _assertCloseSigned(int256 actual, int256 expected, uint256 tol, string memory label) internal {
        int256 diff = actual - expected;
        uint256 absDiff = uint256(diff < 0 ? -diff : diff);
        if (absDiff > tol) {
            emit log_named_int("actual  ", actual);
            emit log_named_int("expected", expected);
            emit log_named_uint("|diff|  ", absDiff);
            emit log_named_uint("tol     ", tol);
            emit log_named_string("label   ", label);
            revert("value outside tolerance");
        }
    }

    function _assertCloseUnsigned(uint256 actual, uint256 expected, uint256 tol, string memory label) internal {
        uint256 absDiff = actual > expected ? actual - expected : expected - actual;
        if (absDiff > tol) {
            emit log_named_uint("actual  ", actual);
            emit log_named_uint("expected", expected);
            emit log_named_uint("|diff|  ", absDiff);
            emit log_named_uint("tol     ", tol);
            emit log_named_string("label   ", label);
            revert("value outside tolerance");
        }
    }
}
