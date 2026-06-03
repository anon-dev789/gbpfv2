// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title GBPF spread curve
/// @notice Pure functions for the immutable mint/redeem spread mechanism.
///         spread(s) = S_MAX * tanh( ((1 - s) / D_50)^2 ) * sign(1 - s)
///         All values are in WAD (1e18 fixed-point).
library SpreadCurve {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant TWO_WAD = 2e18;

    /// @notice Cap on one-sided spread: 5% = 0.05 WAD
    uint256 internal constant S_MAX = 0.05e18;

    /// @notice Deviation at which tanh argument equals 1: 5% = 0.05 WAD
    uint256 internal constant D_50 = 0.05e18;

    /// @notice 1 / D_50^2, precomputed in WAD. D_50 = 0.05, D_50^2 = 0.0025, 1/0.0025 = 400.
    ///         Stored as 400 * WAD so multiplying a WAD value by it and dividing by WAD gives the result.
    uint256 internal constant INV_D_50_SQUARED = 400e18;

    /// @notice Upper bound on solvencyWad accepted by spread(). 1000% solvency is far beyond any
    ///         realistic operating regime; the curve saturates well before this.
    uint256 internal constant MAX_SOLVENCY_WAD = 10e18;

    /// @notice Reverts if solvencyWad is outside the supported range.
    error SolvencyOutOfRange(uint256 solvencyWad);

    /// @notice Compute the one-sided spread (excluding the flat fee) as a function of solvency.
    /// @param  solvencyWad Solvency ratio in WAD. 1e18 == 100% solvency. Bounded to [0, MAX_SOLVENCY_WAD].
    /// @return spreadWad Signed spread in WAD.
    ///         Positive when solvency < 1 (under-collateralised: redeem favourable, mint expensive).
    ///         Negative when solvency > 1 (over-collateralised: mint favourable, redeem expensive).
    ///         Zero when solvency == 1.
    ///
    /// Rounding: mulWad rounds down. Net precision loss is at the sub-wei (1e-15 WAD) level —
    /// far below any economically meaningful threshold. The compounding of rounds in spread()
    /// vs tanhWad() partly cancels; the net direction is bounded but unspecified at sub-wei.
    /// For bulletproof safety in callers, the consumer must apply rounding in the protocol's
    /// favour when converting the returned spread to a final mint/redeem price.
    function spread(uint256 solvencyWad) internal pure returns (int256 spreadWad) {
        if (solvencyWad > MAX_SOLVENCY_WAD) revert SolvencyOutOfRange(solvencyWad);

        // |1 - solvency| computed in uint256 (no signed arithmetic needed).
        bool undercollateralised = solvencyWad < WAD;
        uint256 absD;
        if (undercollateralised) {
            absD = WAD - solvencyWad;
        } else if (solvencyWad > WAD) {
            absD = solvencyWad - WAD;
        } else {
            return 0;
        }

        uint256 dSquared = FixedPointMathLib.mulWad(absD, absD);
        uint256 arg = FixedPointMathLib.mulWad(dSquared, INV_D_50_SQUARED);

        uint256 t = tanhWad(arg);
        uint256 mag = FixedPointMathLib.mulWad(t, S_MAX);

        // Safety: mag <= S_MAX = 5e16, far below 2^255. Casting mag to int256 is sound.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 magSigned = int256(mag);
        spreadWad = undercollateralised ? magSigned : -magSigned;
    }

    /// @notice tanh(x) for x in [0, +inf), result in WAD on [0, 1).
    ///         Identity used: tanh(x) = 1 - 2 / (exp(2x) + 1)
    ///         Saturates to ~WAD long before overflow because exp(2x) explodes.
    ///
    /// Rounding: divWad(2, denom) rounds down, making 2/denom slightly smaller than true,
    /// making the returned tanh slightly LARGER than true (by at most 1 wei). This is the
    /// dominant precision source in spread(); see notes there.
    function tanhWad(uint256 xWad) internal pure returns (uint256) {
        // For very large x, tanh(x) saturates to 1. Clamp to avoid pointless expWad work
        // and to stay inside expWad's safe input range. tanh(20) is 1 - ~4e-18, indistinguishable
        // from WAD at our precision.
        if (xWad >= 20e18) return WAD;

        // Safety: xWad < 20e18 by the clamp above, so xWad * 2 < 40e18, far below 2^255.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 twoX = int256(xWad * 2);

        int256 e2x = FixedPointMathLib.expWad(twoX);

        // Safety: expWad input is non-negative (twoX >= 0), so expWad returns a value >= WAD,
        // which is well within uint256 range. Cast cannot wrap.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 denom = uint256(e2x) + WAD;

        // tanh = 1 - 2/denom
        uint256 frac = FixedPointMathLib.divWad(TWO_WAD, denom);
        return WAD - frac;
    }
}
