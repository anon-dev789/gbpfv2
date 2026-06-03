// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SpreadCurve} from "../../src/SpreadCurve.sol";

/// @dev Handler exposed to the invariant runner. Each public/external call is randomly
///      invoked with random calldata across the invariant campaign.
contract SpreadCurveHandler is Test {
    // Last successful results, so the invariant contract can read them.
    int256 public lastSpread;
    uint256 public lastTanh;

    // Track whether we've ever observed a value out of bounds.
    bool public spreadObservedOutOfBounds;
    bool public tanhObservedOutOfBounds;

    // Counter of successful calls per function — useful to confirm the campaign actually
    // exercised both functions.
    uint256 public spreadCalls;
    uint256 public tanhCalls;

    function callSpread(uint256 solvencyWad) external {
        // Bound to the valid input range; otherwise the call reverts and we learn nothing.
        solvencyWad = bound(solvencyWad, 0, SpreadCurve.MAX_SOLVENCY_WAD);

        int256 s = SpreadCurve.spread(solvencyWad);
        lastSpread = s;
        spreadCalls++;

        int256 cap = int256(SpreadCurve.S_MAX);
        if (s > cap || s < -cap) {
            spreadObservedOutOfBounds = true;
        }
    }

    function callTanh(uint256 xWad) external {
        // Constrain x so expWad cannot revert. 50e18 is well above the saturation clamp
        // inside SpreadCurve.tanhWad and well below the expWad ceiling (~135e18 / 2).
        xWad = bound(xWad, 0, 50e18);

        uint256 t = SpreadCurve.tanhWad(xWad);
        lastTanh = t;
        tanhCalls++;

        if (t > SpreadCurve.WAD) {
            tanhObservedOutOfBounds = true;
        }
    }
}

/// @dev Invariants exercised against random call sequences on SpreadCurveHandler.
///      A pure library has no state, but stateful fuzzing still finds bad input combinations
///      (e.g. solvency 0 followed by solvency MAX, then back, etc.) and establishes the
///      invariant-testing pattern for stateful modules that come later.
contract SpreadCurveInvariantsTest is Test {
    SpreadCurveHandler internal handler;

    function setUp() public {
        handler = new SpreadCurveHandler();
        targetContract(address(handler));
    }

    /// Spread can never escape its declared bounds, no matter what call sequence preceded.
    function invariant_spread_always_bounded() public view {
        assertFalse(handler.spreadObservedOutOfBounds(), "spread() returned a value outside [-S_MAX, +S_MAX]");
    }

    /// tanhWad can never exceed WAD.
    function invariant_tanh_always_bounded() public view {
        assertFalse(handler.tanhObservedOutOfBounds(), "tanhWad() returned a value > WAD");
    }

    // Note: confirming the campaign actually exercised the handlers is done by reading
    // Foundry's per-selector call count in the test output (visible above), not by an
    // in-test assertion — invariants are checked at every step including setUp, which
    // would fail a "made progress" assertion before any campaign step has run.
}
