// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {OracleAdapter} from "../src/OracleAdapter.sol";
import {MockChainlinkFeed} from "./mocks/MockChainlinkFeed.sol";

contract OracleAdapterTest is Test {
    // Committed protocol parameters.
    uint256 internal constant TWAP_WINDOW = 5 minutes;
    uint256 internal constant MAX_STALENESS = 26 hours;
    uint256 internal constant MAX_STEP_WAD = 0.02e18; // 2%
    uint256 internal constant SEQUENCER_GRACE = 1 hours;
    uint256 internal constant COOLDOWN = 15 minutes;

    // Chainlink GBP/USD on Base has 8 decimals. 1 GBP = ~1.25 USD → 1.25e8.
    uint8 internal constant FEED_DECIMALS = 8;
    int256 internal constant INITIAL_PRICE = 1.25e8; // 1.25 GBP/USD
    uint256 internal constant INITIAL_PRICE_WAD = 1.25e18;

    OracleAdapter internal oracle;
    MockChainlinkFeed internal cl;
    MockChainlinkFeed internal seq;

    function setUp() public {
        // Start at a deterministic timestamp well past zero so we have room for
        // backward-looking time math.
        vm.warp(1_700_000_000);

        cl = new MockChainlinkFeed(FEED_DECIMALS, INITIAL_PRICE, block.timestamp);
        // Sequencer "up" (answer = 0) with startedAt well in the past so grace already expired.
        seq = new MockChainlinkFeed(0, 0, block.timestamp - 2 days);

        oracle = new OracleAdapter(
            address(cl), address(seq), TWAP_WINDOW, MAX_STALENESS, MAX_STEP_WAD, SEQUENCER_GRACE, COOLDOWN
        );
    }

    // ============================================================
    // Construction / initial state
    // ============================================================

    function test_constructor_seeds_chainlink_observation() public view {
        assertEq(oracle.latestPriceWad(), INITIAL_PRICE_WAD);
    }

    function test_constructor_not_paused_initially() public view {
        assertEq(oracle.pausedUntil(), 0);
    }

    // ============================================================
    // Healthy path
    // ============================================================

    function test_update_healthy_when_everything_ok() public {
        (uint256 twap, bool healthy,) = oracle.update();
        assertTrue(healthy);
        // No time has passed since deploy, so TWAP defaults to the latest price.
        assertEq(twap, INITIAL_PRICE_WAD);
    }

    function test_twap_constant_price_returns_that_price() public {
        // Advance time by 10 minutes with no Chainlink updates. The TWAP should be the price.
        vm.warp(block.timestamp + 10 minutes);
        (uint256 twap, bool healthy,) = oracle.update();
        assertTrue(healthy);
        assertEq(twap, INITIAL_PRICE_WAD);
    }

    function test_twap_step_change_is_time_weighted() public {
        // Price held at 1.25 for 5 minutes, then jumps to 1.26 and holds for 5 minutes.
        // We start with the seed observation at deploy time. Warp 5 min, push update.
        // Use absolute timestamps to dodge via_ir reordering of block.timestamp reads.
        uint256 t0 = 1_700_000_000; // matches setUp warp
        vm.warp(t0 + 300);
        cl.set(1.26e8, t0 + 300);

        oracle.update();

        // Warp another 5 min. Now the 5-min TWAP should be ~1.26 (the new price has been
        // in effect for the whole window).
        vm.warp(t0 + 600);
        (uint256 twap, bool healthy,) = oracle.update();
        assertTrue(healthy);
        // Allow tiny imprecision; expect very close to 1.26e18.
        assertApproxEqAbs(twap, 1.26e18, 1e15, "TWAP should equal 1.26 after window of new price");
    }

    function test_twap_step_change_mid_window_is_blend() public {
        // 2.5 minutes at 1.25, 2.5 minutes at 1.26 -> TWAP ≈ 1.255
        // Use absolute timestamps to dodge via_ir reordering / reread-on-block.timestamp surprises.
        uint256 t0 = 1_700_000_000; // matches setUp warp
        vm.warp(t0 + 150);
        cl.set(1.26e8, t0 + 150);
        oracle.update();
        vm.warp(t0 + 300);
        (uint256 twap,,) = oracle.update();
        // Expect TWAP between 1.25 and 1.26 — call it 1.255 ± 0.005.
        assertGe(twap, 1.252e18);
        assertLe(twap, 1.258e18);
    }

    // ============================================================
    // Staleness
    // ============================================================

    function test_staleness_pauses_when_chainlink_too_old() public {
        // No Chainlink updates for > MAX_STALENESS.
        vm.warp(block.timestamp + MAX_STALENESS + 1);
        (, bool healthy, uint64 pausedUntil) = oracle.update();
        assertFalse(healthy);
        assertEq(pausedUntil, block.timestamp + COOLDOWN);
    }

    function test_staleness_does_not_pause_within_window() public {
        vm.warp(block.timestamp + MAX_STALENESS - 1);
        (, bool healthy,) = oracle.update();
        assertTrue(healthy);
    }

    // ============================================================
    // Deviation circuit-breaker
    // ============================================================

    function test_deviation_triggers_on_large_step() public {
        // Push a >2% update: 1.25 → 1.30 = +4%.
        vm.warp(block.timestamp + 1 hours);
        cl.set(1.3e8, block.timestamp);

        (, bool healthy, uint64 pausedUntil) = oracle.update();
        assertFalse(healthy);
        assertEq(pausedUntil, block.timestamp + COOLDOWN);
    }

    function test_deviation_does_not_trigger_on_small_step() public {
        // Push a <2% update: 1.25 → 1.26 = +0.8%.
        vm.warp(block.timestamp + 1 hours);
        cl.set(1.26e8, block.timestamp);

        (, bool healthy,) = oracle.update();
        assertTrue(healthy);
    }

    function test_deviation_triggers_on_negative_step() public {
        // Push a >2% down update.
        vm.warp(block.timestamp + 1 hours);
        cl.set(1.2e8, block.timestamp); // -4%
        (, bool healthy,) = oracle.update();
        assertFalse(healthy);
    }

    // ============================================================
    // Sequencer
    // ============================================================

    function test_sequencer_down_pauses() public {
        // Set sequencer to "down": answer = 1.
        seq.setWithStartedAt(1, block.timestamp, block.timestamp);
        (, bool healthy, uint64 pausedUntil) = oracle.update();
        assertFalse(healthy);
        assertEq(pausedUntil, block.timestamp + COOLDOWN);
    }

    function test_sequencer_recently_recovered_within_grace_pauses() public {
        // Sequencer recovered just now — answer = 0, startedAt = now.
        seq.setWithStartedAt(0, block.timestamp, block.timestamp);
        (, bool healthy,) = oracle.update();
        assertFalse(healthy);
    }

    function test_sequencer_recovered_past_grace_is_ok() public {
        seq.setWithStartedAt(0, block.timestamp - SEQUENCER_GRACE - 1, block.timestamp - SEQUENCER_GRACE - 1);
        (, bool healthy,) = oracle.update();
        assertTrue(healthy);
    }

    // ============================================================
    // Hysteresis
    // ============================================================

    function test_pause_persists_for_full_cooldown() public {
        // Trigger a deviation pause.
        vm.warp(block.timestamp + 1 hours);
        cl.set(1.3e8, block.timestamp);
        oracle.update();

        // Even if the underlying problem clears immediately, the cooldown holds the pause.
        // (We can't really "unset" the deviation since it's about the historical step, but
        // staleness/sequencer triggers should also persist for the full cooldown.)
        vm.warp(block.timestamp + COOLDOWN - 1);
        (, bool healthy,) = oracle.update();
        assertFalse(healthy, "still paused 1s before cooldown ends");

        vm.warp(block.timestamp + 1);
        (, healthy,) = oracle.update();
        assertTrue(healthy, "ok at exact cooldown end");
    }

    function test_new_trigger_extends_cooldown_not_reduces() public {
        // First trigger: stale.
        vm.warp(block.timestamp + MAX_STALENESS + 1);
        oracle.update();
        uint64 firstPause = oracle.pausedUntil();

        // 5 min later, push a Chainlink update that's not a deviation. Pause should NOT reset to
        // a shorter window.
        vm.warp(block.timestamp + 5 minutes);
        cl.set(INITIAL_PRICE, block.timestamp);
        oracle.update();

        assertEq(oracle.pausedUntil(), firstPause, "innocuous update must not shorten pause");
    }

    function test_new_trigger_after_cooldown_arms_again() public {
        // Use absolute timestamps to dodge via_ir reordering of block.timestamp reads.
        uint256 t0 = 1_700_000_000; // matches setUp warp
        uint256 firstUpdate = t0 + 1 hours;
        vm.warp(firstUpdate);
        cl.set(1.3e8, firstUpdate);
        oracle.update();

        // Wait out the cooldown.
        uint256 afterCooldown = firstUpdate + COOLDOWN + 1;
        vm.warp(afterCooldown);

        // Now trigger another deviation.
        cl.set(1.2e8, afterCooldown); // 1.30 → 1.20 is ~-7.7%
        (, bool healthy, uint64 pausedUntil) = oracle.update();
        assertFalse(healthy);
        assertEq(pausedUntil, afterCooldown + COOLDOWN);
    }

    // ============================================================
    // Preview
    // ============================================================

    function test_preview_matches_update_when_nothing_changed() public {
        (uint256 twapU, bool healthyU,) = oracle.update();
        (uint256 twapP, bool healthyP,) = oracle.preview();
        assertEq(twapU, twapP);
        assertEq(healthyU, healthyP);
    }

    function test_preview_does_not_mutate_state() public {
        uint64 pausedBefore = oracle.pausedUntil();
        oracle.preview();
        assertEq(oracle.pausedUntil(), pausedBefore);
    }

    function test_preview_anticipates_staleness_pause() public {
        vm.warp(block.timestamp + MAX_STALENESS + 1);
        (, bool healthy,) = oracle.preview();
        assertFalse(healthy);
    }
}
