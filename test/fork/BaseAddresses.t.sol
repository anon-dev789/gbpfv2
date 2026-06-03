// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IChainlinkFeed} from "../../src/interfaces/IChainlinkFeed.sol";
import {ISSRAuthOracle} from "../../src/interfaces/ISSRAuthOracle.sol";

/// @dev Verifies every Base mainnet address we've hardcoded actually exists, responds, and
///      returns values in the expected shape.
///
///      Run with:
///        BASE_RPC_URL=<your-base-rpc>     # optional; falls back to public RPC
///        forge test --match-contract BaseAddressesForkTest -vv
///
///      Tests are pinned to a recent block for reproducibility. Bump BASE_FORK_BLOCK if any of
///      these contracts are upgraded / migrated and the fixed-block read needs refreshing.
///
///      CRITICAL: this whole suite is a deploy-time precondition. Every assertion below
///      represents an assumption baked into immutable contracts. If anything fails, the
///      design needs updating before we ship.
contract BaseAddressesForkTest is Test {
    // Pin to a block ~recent enough that all contracts are deployed but old enough not to
    // be churned away by reorgs. Bumped manually when feeds upgrade.
    uint256 internal constant BASE_FORK_BLOCK = 46_700_000;

    // ============================================================================================
    // Hardcoded Base mainnet addresses, mirrored from project_gbpf_base.md and design_doc.md
    // ============================================================================================

    // Chainlink GBP/USD on Base
    address internal constant CHAINLINK_GBP_USD = 0xCceA6576904C118037695eB71195a5425E69Fa15;

    // Chainlink L2 sequencer uptime feed on Base
    address internal constant CHAINLINK_SEQUENCER_UPTIME = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;

    // Spark SSRAuthOracle on Base (sUSDS conversion rate)
    address internal constant SPARK_SSR_AUTH_ORACLE = 0x65d946e533748A998B1f0E430803e39A6388f7a1;

    // sUSDS on Base (SkyLink-bridged)
    address internal constant SUSDS_TOKEN = 0x5875eEE11Cf8398102FdAd704C9E96607675467a;

    // USDS on Base (SkyLink-bridged)
    address internal constant USDS_TOKEN = 0x820C137fa70C8691f0e44Dc420a5e53c168921Dc;

    // Uniswap V4 PoolManager on Base
    address internal constant V4_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;

    // Uniswap Universal Router on Base
    address internal constant V4_UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        vm.createSelectFork(rpc, BASE_FORK_BLOCK);
    }

    // ============================================================================================
    // Chainlink GBP/USD
    // ============================================================================================

    function test_chainlink_gbp_usd_address_has_code() public view {
        assertGt(CHAINLINK_GBP_USD.code.length, 0, "no code at hardcoded Chainlink address");
    }

    function test_chainlink_gbp_usd_decimals_is_eight() public view {
        // Our OracleAdapter assumes decimals = 8 at deploy (used to derive WAD_SCALE).
        // If Chainlink ever updates this feed to a different precision, our hardcoded
        // adapter logic is wrong.
        assertEq(IChainlinkFeed(CHAINLINK_GBP_USD).decimals(), 8, "Chainlink GBP/USD decimals != 8");
    }

    function test_chainlink_gbp_usd_returns_sane_price() public view {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            IChainlinkFeed(CHAINLINK_GBP_USD).latestRoundData();

        assertGt(roundId, 0, "roundId is zero");
        assertEq(answeredInRound, roundId, "answeredInRound != roundId");

        // GBP/USD has historically traded between ~1.0 and ~1.7 since the 1990s.
        // At 8 decimals: 1.0 = 1e8, 1.7 = 1.7e8. Allow generous bounds for any plausible value.
        assertGt(answer, 0.8e8, "price implausibly low");
        assertLt(answer, 2.0e8, "price implausibly high");

        assertGt(updatedAt, 0, "updatedAt is zero");
        assertGt(startedAt, 0, "startedAt is zero");
    }

    function test_chainlink_gbp_usd_recent_enough_at_fork_block() public view {
        // At the pinned fork block, the feed should be no more than ~26h stale (within our
        // MAX_STALENESS pause threshold). If this fails, either the fork block is too far past
        // the last feed update or our MAX_STALENESS assumption is wrong.
        (,,, uint256 updatedAt,) = IChainlinkFeed(CHAINLINK_GBP_USD).latestRoundData();
        // forge-lint: disable-next-line(block-timestamp)
        uint256 age = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
        assertLt(age, 30 hours, "Chainlink price > 30h stale at fork block; bump BASE_FORK_BLOCK");
    }

    // ============================================================================================
    // Chainlink L2 sequencer uptime
    // ============================================================================================

    function test_sequencer_uptime_address_has_code() public view {
        assertGt(CHAINLINK_SEQUENCER_UPTIME.code.length, 0, "no code at sequencer uptime address");
    }

    function test_sequencer_uptime_reports_up_at_fork_block() public view {
        (, int256 answer,,,) = IChainlinkFeed(CHAINLINK_SEQUENCER_UPTIME).latestRoundData();
        // answer = 0 means "up". If this fails at a historical block, either the sequencer
        // was actually down at that moment (worth investigating) or we picked a bad block.
        assertEq(answer, 0, "sequencer reported as DOWN at fork block");
    }

    function test_sequencer_uptime_startedAt_in_past() public view {
        (,, uint256 startedAt,,) = IChainlinkFeed(CHAINLINK_SEQUENCER_UPTIME).latestRoundData();
        assertGt(startedAt, 0, "startedAt is zero");
        // forge-lint: disable-next-line(block-timestamp)
        assertLt(startedAt, block.timestamp, "startedAt in future");
    }

    // ============================================================================================
    // Spark SSRAuthOracle (sUSDS conversion rate)
    // ============================================================================================

    function test_spark_ssr_oracle_has_code() public view {
        assertGt(SPARK_SSR_AUTH_ORACLE.code.length, 0, "no code at SSRAuthOracle address");
    }

    function test_spark_ssr_oracle_getChi_returns_ray_scale() public view {
        uint256 chi = ISSRAuthOracle(SPARK_SSR_AUTH_ORACLE).getChi();
        // chi is in ray (10^27). Since SSR has been accruing, the value must be > 1 ray
        // (sUSDS > USDS). At the time of writing, chi is ~1.07-1.10 ray.
        // Allow generous bounds.
        assertGt(chi, 1e27, "chi <= 1 ray; sUSDS hasn't appreciated, looks wrong");
        assertLt(chi, 2e27, "chi >= 2 ray; either we've been running for ~10y or it's wrong");
    }

    function test_spark_ssr_oracle_getConversionRate_at_least_getChi() public view {
        // getChi() returns the raw stored chi (last bridge update). getConversionRate()
        // returns chi extrapolated forward to block.timestamp using SSR × elapsed.
        // The conversion rate must therefore be >= the stored chi (yield is monotonically
        // non-decreasing); usually it's strictly greater unless we're reading in the same
        // block as the bridge push.
        uint256 chi = ISSRAuthOracle(SPARK_SSR_AUTH_ORACLE).getChi();
        uint256 rate = ISSRAuthOracle(SPARK_SSR_AUTH_ORACLE).getConversionRate();
        assertGe(rate, chi, "conversion rate ran behind stored chi");
    }

    function test_spark_ssr_oracle_getSSR_returns_sensible_rate() public view {
        // SSR is stored as (1 + per_second_rate) in ray. Neutral value (0% APY) is 1e27.
        // At 5% APY, the per-second rate is ~1.55e-9, so SSR ≈ 1.00000000155 × 1e27.
        // We tolerate anything from neutral (1e27) up to ~50% APY (about 1.0000000128 × 1e27).
        uint256 ssr = ISSRAuthOracle(SPARK_SSR_AUTH_ORACLE).getSSR();
        assertGe(ssr, 1e27, "SSR < 1 ray (would imply negative yield)");
        assertLt(ssr, 1.00000002e27, "SSR implies APY > 50%, almost certainly wrong");
    }

    // ============================================================================================
    // sUSDS / USDS tokens
    // ============================================================================================

    function test_sUsds_token_has_code() public view {
        assertGt(SUSDS_TOKEN.code.length, 0, "no code at sUSDS address");
    }

    function test_usds_token_has_code() public view {
        assertGt(USDS_TOKEN.code.length, 0, "no code at USDS address");
    }

    function test_sUsds_token_totalSupply_positive() public view {
        // If totalSupply is 0, the bridge hasn't been initialised or the address is wrong.
        (bool ok, bytes memory data) = SUSDS_TOKEN.staticcall(abi.encodeWithSignature("totalSupply()"));
        assertTrue(ok, "totalSupply() call failed");
        uint256 supply = abi.decode(data, (uint256));
        assertGt(supply, 0, "sUSDS totalSupply is zero");
    }

    function test_usds_token_totalSupply_positive() public view {
        (bool ok, bytes memory data) = USDS_TOKEN.staticcall(abi.encodeWithSignature("totalSupply()"));
        assertTrue(ok, "totalSupply() call failed");
        uint256 supply = abi.decode(data, (uint256));
        assertGt(supply, 0, "USDS totalSupply is zero");
    }

    function test_sUsds_token_symbol_is_sUSDS() public view {
        (bool ok, bytes memory data) = SUSDS_TOKEN.staticcall(abi.encodeWithSignature("symbol()"));
        assertTrue(ok, "symbol() call failed");
        string memory sym = abi.decode(data, (string));
        assertEq(sym, "sUSDS", "sUSDS symbol unexpected");
    }

    function test_usds_token_symbol_is_USDS() public view {
        (bool ok, bytes memory data) = USDS_TOKEN.staticcall(abi.encodeWithSignature("symbol()"));
        assertTrue(ok, "symbol() call failed");
        string memory sym = abi.decode(data, (string));
        assertEq(sym, "USDS", "USDS symbol unexpected");
    }

    function test_sUsds_token_decimals_is_eighteen() public view {
        (bool ok, bytes memory data) = SUSDS_TOKEN.staticcall(abi.encodeWithSignature("decimals()"));
        assertTrue(ok, "decimals() call failed");
        uint8 d = abi.decode(data, (uint8));
        assertEq(d, 18, "sUSDS decimals != 18");
    }

    function test_usds_token_decimals_is_eighteen() public view {
        (bool ok, bytes memory data) = USDS_TOKEN.staticcall(abi.encodeWithSignature("decimals()"));
        assertTrue(ok, "decimals() call failed");
        uint8 d = abi.decode(data, (uint8));
        assertEq(d, 18, "USDS decimals != 18");
    }

    // ============================================================================================
    // Uniswap V4
    // ============================================================================================

    function test_v4_pool_manager_has_code() public view {
        assertGt(V4_POOL_MANAGER.code.length, 0, "no code at PoolManager address");
    }

    function test_v4_universal_router_has_code() public view {
        assertGt(V4_UNIVERSAL_ROUTER.code.length, 0, "no code at Universal Router address");
    }
}
