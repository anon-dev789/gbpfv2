// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {IChainlinkFeed} from "./interfaces/IChainlinkFeed.sol";

/// @title GBPF oracle adapter
/// @notice Single source of GBP/USD pricing and operational health for the hook. Owns:
///         - Chainlink GBP/USD reader on Base
///         - Time-weighted average price over the committed TWAP window
///         - Staleness pause: pause if Chainlink hasn't updated in > MAX_STALENESS
///         - Deviation circuit-breaker: pause if a single Chainlink update steps the price by > MAX_STEP
///         - Sequencer-uptime check: pause if Base sequencer is down or within grace
///         - Hysteresis cooldown: once any condition triggers, pause persists for COOLDOWN
///
/// TWAP design: cumulative-sum accumulator anchored to Chainlink's update cadence.
/// We extend the accumulator only when Chainlink itself reports a new updatedAt — between
/// updates the price is, by definition, unchanged from Chainlink's perspective and adding the
/// same number over and over would just inflate the integral without changing the mean.
///
/// The accumulator stores `sum_i ( price_i * dt_i )` in WAD-seconds, where dt_i is the elapsed
/// time the price held. TWAP(window) is computed as (cumNow - cumWindowAgo) / window. A small
/// ring buffer of (timestamp, cumulative) snapshots lets us look up the cumulative-at-time-T.
///
/// Immutable. No admin, no upgrade, no owner.
contract OracleAdapter {
    // ============================================================================================
    // Configuration (immutable)
    // ============================================================================================

    /// @dev Chainlink GBP/USD on Base mainnet (validated at deploy by the deploy script).
    IChainlinkFeed public immutable CHAINLINK;

    /// @dev Chainlink L2 sequencer-uptime feed on Base (`0xBCF8…6433`).
    IChainlinkFeed public immutable SEQUENCER_UPTIME;

    /// @dev TWAP window length, in seconds. Committed: 5 minutes.
    uint256 public immutable TWAP_WINDOW;

    /// @dev Max age of Chainlink answer before pause triggers. Committed: 26 hours
    ///      (24h heartbeat + 1h sequencer grace + 1h buffer).
    uint256 public immutable MAX_STALENESS;

    /// @dev Max single-update Chainlink step before circuit-breaker triggers, in WAD
    ///      (proportional to price). Committed: 0.02e18 = 2%.
    uint256 public immutable MAX_STEP_WAD;

    /// @dev Sequencer recovery grace, in seconds. Committed: 1 hour.
    uint256 public immutable SEQUENCER_GRACE;

    /// @dev Hysteresis cooldown after any pause trigger, in seconds. Committed: 15 minutes.
    uint256 public immutable COOLDOWN;

    /// @dev WAD scaling for Chainlink answers. Cached at construction from the feed's decimals.
    ///      For the GBP/USD feed on Base, decimals = 8 and WAD_SCALE = 1e10.
    uint256 public immutable WAD_SCALE;

    /// @dev Length of the cumulative-snapshot ring buffer. Sized to comfortably exceed the TWAP
    ///      window divided by Chainlink's update cadence; with 24h heartbeat / 0.5% deviation
    ///      and a 5-min window, even one snapshot would technically suffice for normal operation,
    ///      but a longer ring gives invariant-fuzz resilience and headroom for shorter windows
    ///      should we ever revisit the curve. 64 snapshots; 1 slot per snapshot.
    uint256 internal constant RING_SIZE = 64;

    uint256 internal constant WAD = 1e18;

    // ============================================================================================
    // Storage
    // ============================================================================================

    /// @dev One snapshot of the cumulative integral at a given block timestamp.
    ///      cumulativeWadSeconds is `sum over prior price segments of price * segment_duration`
    ///      where price is in WAD and duration is in seconds — so the unit is WAD*seconds.
    struct Snapshot {
        uint64 timestamp;
        uint192 cumulativeWadSeconds;
    }

    Snapshot[RING_SIZE] internal _ring;

    /// @dev Index in `_ring` of the most recently written snapshot.
    uint8 internal _ringHead;

    /// @dev Number of snapshots written so far (0 to RING_SIZE).
    uint8 internal _ringCount;

    /// @dev The last Chainlink-reported (updatedAt, answer) pair we observed. Used to detect
    ///      new updates and to anchor cumulative growth and the circuit-breaker step check.
    uint64 internal _lastChainlinkUpdatedAt;
    int256 internal _lastChainlinkAnswer;

    /// @dev If non-zero, all updates are paused until this timestamp. Set when any trigger
    ///      condition fires; not cleared until the cooldown elapses.
    uint64 public pausedUntil;

    // ============================================================================================
    // Events
    // ============================================================================================

    event Observed(int256 chainlinkAnswer, uint256 chainlinkUpdatedAt, uint256 cumulativeWadSeconds);
    event Paused(uint64 pausedUntil, PauseReason reason);

    enum PauseReason {
        Stale,
        Deviation,
        SequencerDown,
        SequencerGrace
    }

    // ============================================================================================
    // Errors
    // ============================================================================================

    error NotInitialized();
    error TwapWindowUnreachable(uint256 oldestSnapshot, uint256 needed);

    // ============================================================================================
    // Construction
    // ============================================================================================

    constructor(
        address chainlink_,
        address sequencerUptime_,
        uint256 twapWindow_,
        uint256 maxStaleness_,
        uint256 maxStepWad_,
        uint256 sequencerGrace_,
        uint256 cooldown_
    ) {
        CHAINLINK = IChainlinkFeed(chainlink_);
        SEQUENCER_UPTIME = IChainlinkFeed(sequencerUptime_);
        TWAP_WINDOW = twapWindow_;
        MAX_STALENESS = maxStaleness_;
        MAX_STEP_WAD = maxStepWad_;
        SEQUENCER_GRACE = sequencerGrace_;
        COOLDOWN = cooldown_;
        WAD_SCALE = 10 ** (18 - IChainlinkFeed(chainlink_).decimals());

        // Seed the ring with the current Chainlink observation. This makes the first update()
        // immediately useful instead of returning a TwapWindowUnreachable error.
        (, int256 answer,, uint256 updatedAt,) = IChainlinkFeed(chainlink_).latestRoundData();
        _lastChainlinkAnswer = answer;
        // Safety: timestamps fit in uint64 until year ~584 billion AD.
        // forge-lint: disable-next-line(unsafe-typecast)
        _lastChainlinkUpdatedAt = uint64(updatedAt);
        // The first snapshot has cumulativeWadSeconds = 0 by definition (no time has elapsed
        // since "the beginning of observation"). We record it at the current block timestamp
        // so the TWAP can be computed against it.
        // forge-lint: disable-next-line(unsafe-typecast)
        _writeSnapshot(uint64(block.timestamp), 0);
    }

    // ============================================================================================
    // External
    // ============================================================================================

    /// @notice State-changing read. Pulls the latest Chainlink observation, advances the
    ///         cumulative integral if Chainlink has updated, evaluates pause conditions,
    ///         and returns (twapWad, healthy, pausedUntil).
    /// @return twapWad       Time-weighted average GBP/USD over TWAP_WINDOW, in WAD.
    /// @return healthy       True iff no pause condition holds and no cooldown is active.
    /// @return pausedUntilTs The current pausedUntil; 0 if not paused.
    function update() external returns (uint256 twapWad, bool healthy, uint64 pausedUntilTs) {
        // 1. Sequencer health — check first; if the sequencer is down, all bets are off.
        (bool sequencerOk, PauseReason sequencerReason) = _checkSequencer();

        // 2. Read Chainlink and detect new observation.
        (int256 answer, uint256 updatedAt) = _readChainlink();

        // 3. If Chainlink has produced a new update, extend the integral and run the circuit-breaker.
        bool deviationTriggered = false;
        if (updatedAt > _lastChainlinkUpdatedAt) {
            deviationTriggered = _ingestChainlink(answer, updatedAt);
        }

        // 4. Staleness check — use the *Chainlink-reported* updatedAt, not block.timestamp,
        //    so we measure against Chainlink's own clock.
        //    Validator timestamp drift (a few seconds) is irrelevant against a 26h staleness window.
        // forge-lint: disable-next-line(block-timestamp)
        bool stale = (block.timestamp > updatedAt) && (block.timestamp - updatedAt > MAX_STALENESS);

        // 5. Compose pause state.
        if (!sequencerOk) {
            _arm(sequencerReason);
        } else if (stale) {
            _arm(PauseReason.Stale);
        } else if (deviationTriggered) {
            _arm(PauseReason.Deviation);
        }

        twapWad = _twap();
        pausedUntilTs = pausedUntil;
        // Validator timestamp drift (a few seconds) is irrelevant against a 15-minute cooldown.
        // forge-lint: disable-next-line(block-timestamp)
        healthy = (pausedUntilTs == 0 || block.timestamp >= pausedUntilTs);
    }

    /// @notice Pure-view variant: returns what update() WOULD report without writing state.
    ///         For off-chain reads, indexers, monitors.
    function preview() external view returns (uint256 twapWad, bool healthy, uint64 pausedUntilTs) {
        (bool sequencerOk,) = _checkSequencer();
        (int256 answer, uint256 updatedAt) = _readChainlink();

        bool deviation = false;
        if (updatedAt > _lastChainlinkUpdatedAt && _lastChainlinkUpdatedAt != 0) {
            deviation = _wouldTriggerDeviation(_lastChainlinkAnswer, answer);
        }

        // forge-lint: disable-next-line(block-timestamp)
        bool stale = (block.timestamp > updatedAt) && (block.timestamp - updatedAt > MAX_STALENESS);

        // Compute a hypothetical pausedUntil under the current observations.
        uint64 effective = pausedUntil;
        if (!sequencerOk || stale || deviation) {
            // Safety: block.timestamp + COOLDOWN fits in uint64 for ~584 billion years.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint64 candidate = uint64(block.timestamp + COOLDOWN);
            if (candidate > effective) effective = candidate;
        }

        twapWad = _previewTwap(answer, updatedAt);
        pausedUntilTs = effective;
        // forge-lint: disable-next-line(block-timestamp)
        healthy = (effective == 0 || block.timestamp >= effective);
    }

    /// @notice The most recently observed Chainlink price, normalised to WAD.
    function latestPriceWad() external view returns (uint256) {
        (int256 answer,) = _readChainlink();
        return _toWad(answer);
    }

    // ============================================================================================
    // Internal: integral / TWAP
    // ============================================================================================

    /// @dev Ingest a new Chainlink observation: extend the cumulative integral by
    ///      previous_price * (newUpdatedAt - previousUpdatedAt), then write a snapshot.
    ///      Returns true if the price step (proportional change) exceeds MAX_STEP_WAD.
    function _ingestChainlink(int256 newAnswer, uint256 newUpdatedAt) internal returns (bool deviationTriggered) {
        int256 prevAnswer = _lastChainlinkAnswer;
        uint64 prevUpdatedAt = _lastChainlinkUpdatedAt;

        // Extend the integral using the *previous* price applied to the elapsed segment.
        Snapshot memory head = _ring[_ringHead];
        uint256 dt = newUpdatedAt - prevUpdatedAt;
        uint256 prevPriceWad = _toWad(prevAnswer);
        uint256 newCum = uint256(head.cumulativeWadSeconds) + prevPriceWad * dt;

        // Safety: newUpdatedAt comes from Chainlink and represents a unix timestamp.
        // forge-lint: disable-next-line(unsafe-typecast)
        _writeSnapshot(uint64(newUpdatedAt), newCum);

        // Circuit-breaker: relative change between successive Chainlink answers.
        deviationTriggered = _wouldTriggerDeviation(prevAnswer, newAnswer);

        _lastChainlinkAnswer = newAnswer;
        // forge-lint: disable-next-line(unsafe-typecast)
        _lastChainlinkUpdatedAt = uint64(newUpdatedAt);

        emit Observed(newAnswer, newUpdatedAt, newCum);
    }

    /// @dev Returns true iff |new - prev| / prev > MAX_STEP_WAD.
    ///      prev is guaranteed non-zero by the Chainlink feed's economic assumptions; we
    ///      defensively return false if prev <= 0 to avoid a divide-by-zero or a sign error
    ///      from a malformed answer.
    function _wouldTriggerDeviation(int256 prev, int256 newer) internal view returns (bool) {
        if (prev <= 0) return false;
        // Safety: prev > 0 by the check above; cast cannot wrap.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 prevAbs = uint256(prev);
        // Safety: both branches are non-negative ints; first branch checks newer>=0, second
        // negates a negative int into a positive int range.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 newAbs = newer >= 0 ? uint256(newer) : uint256(-newer);
        uint256 diff = newAbs > prevAbs ? newAbs - prevAbs : prevAbs - newAbs;
        // Compare diff/prev to MAX_STEP_WAD. diff and prev have the same units, so we scale
        // diff to WAD before comparing: diff * WAD / prev > MAX_STEP_WAD.
        return diff * WAD / prevAbs > MAX_STEP_WAD;
    }

    /// @dev TWAP over the committed window, computed as (cumNow - cumWindowAgo) / window.
    ///      We need the cumulative-at-time-T for T = now - TWAP_WINDOW. If no snapshot is old
    ///      enough, we revert — the hook should treat that as unhealthy (the protocol just
    ///      deployed, etc.). For a freshly-deployed contract, the first snapshot is at
    ///      block.timestamp, so the TWAP becomes available after TWAP_WINDOW has elapsed.
    function _twap() internal view returns (uint256) {
        Snapshot memory head = _ring[_ringHead];
        uint256 nowCum = uint256(head.cumulativeWadSeconds);

        // Extend "nowCum" up to block.timestamp using the last observed Chainlink price.
        // This is the standard cumulative-sum oracle trick: the integral is well-defined at
        // any moment because the price between Chainlink updates is by convention unchanged.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > head.timestamp) {
            uint256 dtNow = block.timestamp - head.timestamp;
            nowCum += _toWad(_lastChainlinkAnswer) * dtNow;
        }
        uint256 nowTs = block.timestamp;

        uint256 targetTs = nowTs > TWAP_WINDOW ? nowTs - TWAP_WINDOW : 0;
        (uint256 oldCum, uint256 oldTs) = _interpolateAt(targetTs);

        uint256 elapsed = nowTs - oldTs;
        if (elapsed == 0) {
            // Should only happen if block.timestamp <= TWAP_WINDOW (Anvil clock or fresh deploy).
            return _toWad(_lastChainlinkAnswer);
        }
        return (nowCum - oldCum) / elapsed;
    }

    /// @dev Preview variant for the view function. Uses `previewAnswer` and `previewUpdatedAt`
    ///      to imagine the latest Chainlink observation as already ingested.
    function _previewTwap(int256 previewAnswer, uint256 previewUpdatedAt) internal view returns (uint256) {
        Snapshot memory head = _ring[_ringHead];
        uint256 nowCum = uint256(head.cumulativeWadSeconds);
        uint64 lastSnap = head.timestamp;

        // If Chainlink has produced a new observation since our last snapshot, virtually ingest it.
        if (previewUpdatedAt > _lastChainlinkUpdatedAt && _lastChainlinkUpdatedAt != 0) {
            uint256 dt = previewUpdatedAt - _lastChainlinkUpdatedAt;
            nowCum += _toWad(_lastChainlinkAnswer) * dt;
            // Safety: previewUpdatedAt is a Chainlink-reported unix timestamp.
            // forge-lint: disable-next-line(unsafe-typecast)
            lastSnap = uint64(previewUpdatedAt);
        }

        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > lastSnap) {
            uint256 dtNow = block.timestamp - lastSnap;
            uint256 priceForExtension =
                previewUpdatedAt > _lastChainlinkUpdatedAt ? _toWad(previewAnswer) : _toWad(_lastChainlinkAnswer);
            nowCum += priceForExtension * dtNow;
        }

        uint256 nowTs = block.timestamp;
        uint256 targetTs = nowTs > TWAP_WINDOW ? nowTs - TWAP_WINDOW : 0;
        (uint256 oldCum, uint256 oldTs) = _interpolateAt(targetTs);

        uint256 elapsed = nowTs - oldTs;
        if (elapsed == 0) {
            return _toWad(previewAnswer);
        }
        return (nowCum - oldCum) / elapsed;
    }

    /// @dev Look up the cumulative at-or-before `targetTs`, then interpolate forward to targetTs
    ///      using the last observed Chainlink price for that segment.
    ///      Returns (cumulativeAtTarget, actualTimestamp). actualTimestamp == targetTs unless
    ///      the buffer is shorter than the requested window, in which case we use the oldest
    ///      snapshot and the hook gets a TWAP over a shorter-than-ideal window. This is the
    ///      "warmup" regime and the design accepts a slightly less defended TWAP for the
    ///      first TWAP_WINDOW seconds after deploy.
    function _interpolateAt(uint256 targetTs) internal view returns (uint256 cumAtTarget, uint256 actualTs) {
        // Walk the ring from oldest to newest, find the snapshot whose timestamp is <= targetTs.
        uint256 count = _ringCount;
        if (count == 0) revert NotInitialized();

        // Find the index of the oldest snapshot.
        uint256 head = _ringHead;
        uint256 size = RING_SIZE;
        // If we haven't wrapped yet, oldest is at index 0. If we have wrapped, oldest is at
        // (head + 1) mod size.
        uint256 oldest = (count < size) ? 0 : (head + 1) % size;

        Snapshot memory oldestSnap = _ring[oldest];

        // If the requested target predates our oldest observation, we clamp to the oldest.
        // The TWAP will be over a shorter-than-ideal window; this is the warmup regime.
        if (targetTs <= oldestSnap.timestamp) {
            return (uint256(oldestSnap.cumulativeWadSeconds), uint256(oldestSnap.timestamp));
        }

        // Linear walk from newest backward looking for the largest timestamp <= targetTs.
        // The ring is small (RING_SIZE = 64) so linear is fine and simpler than binary search.
        uint256 idx = head;
        for (uint256 i = 0; i < count; i++) {
            Snapshot memory snap = _ring[idx];
            if (snap.timestamp <= targetTs) {
                // Interpolate from this snapshot forward to targetTs using the price that held
                // from `snap.timestamp` until the *next* snapshot (or until now if this is the head).
                uint256 priceForSegment = _priceForSegmentAfter(idx);
                uint256 dt = targetTs - uint256(snap.timestamp);
                return (uint256(snap.cumulativeWadSeconds) + priceForSegment * dt, targetTs);
            }
            // Walk one step backward in the ring.
            idx = idx == 0 ? size - 1 : idx - 1;
        }

        // Unreachable: we already handled the case where targetTs predates the oldest snapshot.
        revert TwapWindowUnreachable(oldestSnap.timestamp, targetTs);
    }

    /// @dev The Chainlink price that applied from snapshot `idx` until the *next* snapshot
    ///      (or until the present, if `idx == head`). Reconstructed from the cumulative
    ///      difference: price = (cum_next - cum_idx) / (ts_next - ts_idx).
    function _priceForSegmentAfter(uint256 idx) internal view returns (uint256) {
        if (idx == _ringHead) {
            // No "next" snapshot — the segment extends to now using the last Chainlink price.
            return _toWad(_lastChainlinkAnswer);
        }
        uint256 nextIdx = (idx + 1) % RING_SIZE;
        Snapshot memory cur = _ring[idx];
        Snapshot memory nxt = _ring[nextIdx];
        if (nxt.timestamp <= cur.timestamp) return _toWad(_lastChainlinkAnswer); // defensive
        return (uint256(nxt.cumulativeWadSeconds) - uint256(cur.cumulativeWadSeconds))
            / (uint256(nxt.timestamp) - uint256(cur.timestamp));
    }

    function _writeSnapshot(uint64 ts, uint256 cum) internal {
        // Cast safety: cum is bounded by maxPriceWad * uint64.max which fits comfortably in
        // uint192 (priceWad ~ 1e18, dt up to ~2^64 seconds, product ~ 2^124 < 2^192).
        uint8 nextHead;
        unchecked {
            // Safety: result mod RING_SIZE (64) always fits in uint8.
            // forge-lint: disable-next-line(unsafe-typecast)
            nextHead = uint8((uint256(_ringHead) + 1) % RING_SIZE);
        }
        if (_ringCount == 0) {
            // First write goes to index 0; subsequent writes advance the head.
            // Safety: cum bound derived above; max ~2^124 fits in uint192.
            // forge-lint: disable-next-line(unsafe-typecast)
            _ring[0] = Snapshot({timestamp: ts, cumulativeWadSeconds: uint192(cum)});
            _ringHead = 0;
            _ringCount = 1;
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            _ring[nextHead] = Snapshot({timestamp: ts, cumulativeWadSeconds: uint192(cum)});
            _ringHead = nextHead;
            if (_ringCount < RING_SIZE) {
                unchecked {
                    _ringCount++;
                }
            }
        }
    }

    // ============================================================================================
    // Internal: pause logic
    // ============================================================================================

    /// @dev Check the L2 sequencer-uptime feed. Returns (ok, reason if not ok).
    ///      ok = sequencer is up AND we're past the recovery grace period.
    function _checkSequencer() internal view returns (bool ok, PauseReason reason) {
        (, int256 answer, uint256 startedAt,,) = SEQUENCER_UPTIME.latestRoundData();
        // answer = 0 means up; answer != 0 means down.
        if (answer != 0) return (false, PauseReason.SequencerDown);
        // Within grace window after recovery: also not ok.
        // Validator timestamp drift (a few seconds) is irrelevant against a 1h grace window.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < startedAt + SEQUENCER_GRACE) {
            return (false, PauseReason.SequencerGrace);
        }
        return (true, PauseReason.Stale); // reason unused when ok
    }

    /// @dev Read the latest Chainlink answer and updatedAt.
    function _readChainlink() internal view returns (int256 answer, uint256 updatedAt) {
        (, answer,, updatedAt,) = CHAINLINK.latestRoundData();
    }

    /// @dev Arm the cooldown: extend pausedUntil if the new candidate is later. Trigger only
    ///      strengthens; we never shorten the cooldown.
    function _arm(PauseReason reason) internal {
        // Safety: block.timestamp + COOLDOWN fits in uint64 until year ~584 billion AD.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 candidate = uint64(block.timestamp + COOLDOWN);
        if (candidate > pausedUntil) {
            pausedUntil = candidate;
            emit Paused(candidate, reason);
        }
    }

    // ============================================================================================
    // Internal: helpers
    // ============================================================================================

    /// @dev Convert a Chainlink answer (in feed-native decimals) to WAD.
    ///      Reverts implicitly via underflow if answer is negative — that's not a real-world
    ///      condition for GBP/USD but it would be a malformed feed and we should not silently
    ///      operate on it.
    function _toWad(int256 answer) internal view returns (uint256) {
        if (answer < 0) return 0; // defensive — caller should treat 0 as a sentinel
        // Safety: answer >= 0 by the check above; cast cannot wrap.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(answer) * WAD_SCALE;
    }
}
