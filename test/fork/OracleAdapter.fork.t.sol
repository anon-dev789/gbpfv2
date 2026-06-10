// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {OracleAdapter} from "../../src/OracleAdapter.sol";
import {IChainlinkFeed} from "../../src/interfaces/IChainlinkFeed.sol";

/// @dev Deploys OracleAdapter against the real Chainlink feeds on Base and verifies its
///      behaviour with live data.
///
///      Run with:
///        forge test --match-contract OracleAdapterForkTest -vv
contract OracleAdapterForkTest is Test {
    uint256 internal constant BASE_FORK_BLOCK = 46_700_000;

    address internal constant CHAINLINK_GBP_USD = 0xCceA6576904C118037695eB71195a5425E69Fa15;
    address internal constant CHAINLINK_SEQUENCER_UPTIME = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;

    // Committed protocol parameters.
    uint256 internal constant TWAP_WINDOW = 5 minutes;
    uint256 internal constant MAX_STALENESS = 26 hours;
    uint256 internal constant MAX_STEP_WAD = 0.02e18;
    uint256 internal constant SEQUENCER_GRACE = 1 hours;
    uint256 internal constant COOLDOWN = 15 minutes;

    OracleAdapter internal oracle;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        vm.createSelectFork(rpc, BASE_FORK_BLOCK);

        oracle = new OracleAdapter(
            CHAINLINK_GBP_USD,
            CHAINLINK_SEQUENCER_UPTIME,
            TWAP_WINDOW,
            MAX_STALENESS,
            MAX_STEP_WAD,
            SEQUENCER_GRACE,
            COOLDOWN
        );
    }

    // ============================================================================================
    // Deploys and reads against real feeds
    // ============================================================================================

    function test_deploys_and_seeds_from_real_chainlink() public view {
        // Latest price should be in the plausible GBP/USD band, in WAD.
        uint256 priceWad = oracle.latestPriceWad();
        assertGt(priceWad, 0.8e18, "GBP/USD seed implausibly low");
        assertLt(priceWad, 2.0e18, "GBP/USD seed implausibly high");
    }

    function test_initial_update_during_warmup_is_unhealthy() public {
        // At the deploy block no full TWAP window exists yet, so the warmup gate reports unhealthy.
        (, bool healthy,) = oracle.update();
        assertFalse(healthy, "should be unhealthy during warmup window");
    }

    function test_update_returns_healthy_after_warmup() public {
        // Past the warmup window, with a healthy sequencer + recent Chainlink, update() is healthy.
        vm.warp(block.timestamp + TWAP_WINDOW + 1);
        (uint256 twap, bool healthy,) = oracle.update();
        assertTrue(healthy, "update unhealthy after warmup at fork block - bump BASE_FORK_BLOCK?");
        // No Chainlink update over the warp, so the TWAP equals the held latest price.
        assertEq(twap, oracle.latestPriceWad(), "post-warmup TWAP should equal latest price");
    }

    function test_preview_matches_real_state() public {
        // During warmup, preview reports unhealthy (mirrors update()).
        (, bool warmupHealthy,) = oracle.preview();
        assertFalse(warmupHealthy, "preview should be unhealthy during warmup");

        // After warmup, live Chainlink + sequencer at the pinned block report healthy.
        vm.warp(block.timestamp + TWAP_WINDOW + 1);
        (uint256 previewTwap, bool previewHealthy,) = oracle.preview();
        assertTrue(previewHealthy, "preview unhealthy after warmup at fork block");
        assertGt(previewTwap, 0.8e18, "preview TWAP implausibly low");
    }

    // ============================================================================================
    // Pause behaviour against real feeds
    // ============================================================================================

    function test_staleness_pauses_after_warping_past_max() public {
        // Warp past MAX_STALENESS — the Chainlink updatedAt does not advance, so staleness
        // should trigger.
        vm.warp(block.timestamp + MAX_STALENESS + 1);
        (, bool healthy,) = oracle.update();
        assertFalse(healthy, "staleness pause did not fire");
    }

    function test_sequencer_grace_pauses_immediately_after_recovery() public {
        // Mock the sequencer feed to "just recovered" by overwriting its latestRoundData
        // return values via vm.mockCall.
        vm.mockCall(
            CHAINLINK_SEQUENCER_UPTIME,
            abi.encodeWithSelector(IChainlinkFeed.latestRoundData.selector),
            abi.encode(uint80(1), int256(0), block.timestamp, block.timestamp, uint80(1))
        );

        (, bool healthy,) = oracle.update();
        assertFalse(healthy, "sequencer grace pause did not fire");
    }

    function test_sequencer_down_pauses() public {
        vm.mockCall(
            CHAINLINK_SEQUENCER_UPTIME,
            abi.encodeWithSelector(IChainlinkFeed.latestRoundData.selector),
            abi.encode(uint80(1), int256(1), block.timestamp - 5 minutes, block.timestamp, uint80(1))
        );

        (, bool healthy,) = oracle.update();
        assertFalse(healthy, "sequencer-down pause did not fire");
    }
}
