// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {OracleAdapter} from "../src/OracleAdapter.sol";
import {MockChainlinkFeed} from "./mocks/MockChainlinkFeed.sol";

/// @dev Regression for the preview() TWAP amplification bug observed on the live Base
///      instance (2026-06-10): with zero swap volume nothing ever calls update(), so a new
///      Chainlink observation sits un-ingested. preview() virtually ingests it into the
///      integral's numerator, but the window-start interpolation only knows STORED snapshots
///      and extends the OLD price to the window start — inflating the TWAP by
///      (new − old) * (now − updatedAt) / window. Live: a 0.072% feed step, un-ingested for
///      ~9.6h, previewed as TWAP 1.4506 while the feed (and update()) said 1.34037.
contract OracleAdapterPreviewRegressionTest is Test {
    uint256 internal constant TWAP_WINDOW = 5 minutes;
    uint256 internal constant MAX_STALENESS = 26 hours;
    uint256 internal constant MAX_STEP_WAD = 0.02e18;
    uint256 internal constant SEQUENCER_GRACE = 1 hours;
    uint256 internal constant COOLDOWN = 15 minutes;

    uint256 internal constant T0 = 1_700_000_000;

    OracleAdapter internal oracle;
    MockChainlinkFeed internal cl;
    MockChainlinkFeed internal seq;

    function setUp() public {
        vm.warp(T0);
        // Constructor seeds the ring with (1.3394, T0) — mirroring the live deploy state.
        cl = new MockChainlinkFeed(8, 1.3394e8, T0);
        seq = new MockChainlinkFeed(0, 0, T0 - 2 days);
        oracle = new OracleAdapter(
            address(cl), address(seq), TWAP_WINDOW, MAX_STALENESS, MAX_STEP_WAD, SEQUENCER_GRACE, COOLDOWN
        );
    }

    /// @dev The live scenario: a small feed step lands at T0+12h, nobody calls update(), and
    ///      preview() is read ~10h later. The whole 5-minute window lies inside the new-price
    ///      segment, so the TWAP must be exactly the new price — and must equal what update()
    ///      (the hook's pricing path) would return.
    function test_preview_sparse_uningested_observation_no_amplification() public {
        // Feed steps +0.072% at T0 + 12h. No update() call ingests it.
        uint256 t1 = T0 + 12 hours;
        cl.set(1.34037e8, t1);

        // Read ~10h later (staleness 10h < 26h: still healthy).
        vm.warp(t1 + 10 hours);

        (uint256 twapPreview, bool healthyPreview,) = oracle.preview();
        assertTrue(healthyPreview, "preview should be healthy");
        assertEq(twapPreview, 1.34037e18, "preview TWAP must be the new price, not amplified");

        // And preview must agree with the state-mutating path the hook prices swaps with.
        (uint256 twapUpdate, bool healthyUpdate,) = oracle.update();
        assertTrue(healthyUpdate, "update should be healthy");
        assertEq(twapPreview, twapUpdate, "preview and update must agree");
    }

    /// @dev Window straddling the un-ingested observation: preview must time-weight the two
    ///      prices, identically to what update() computes after ingesting.
    function test_preview_window_straddles_uningested_observation() public {
        uint256 t1 = T0 + 12 hours;
        cl.set(1.34037e8, t1);

        // Read 2 minutes after the step: window = [now-5min, now] covers 3min of the old
        // price and 2min of the new one.
        vm.warp(t1 + 2 minutes);

        (uint256 twapPreview,,) = oracle.preview();
        uint256 expected = (1.3394e18 * 3 minutes + 1.34037e18 * 2 minutes) / (5 minutes);
        assertEq(twapPreview, expected, "straddling window must time-weight the step");

        (uint256 twapUpdate,,) = oracle.update();
        assertEq(twapPreview, twapUpdate, "preview and update must agree");
    }

    /// @dev No new observation at all: preview is the flat-price case and must equal update().
    function test_preview_no_new_observation_flat() public {
        vm.warp(T0 + 8 hours);
        (uint256 twapPreview,,) = oracle.preview();
        assertEq(twapPreview, 1.3394e18, "flat regime must return the only observed price");
        (uint256 twapUpdate,,) = oracle.update();
        assertEq(twapPreview, twapUpdate);
    }
}
