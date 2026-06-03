// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

/// @title Minimal interface for Spark's SSRAuthOracle on Base.
/// @notice Deployed at 0x65d946e533748A998B1f0E430803e39A6388f7a1 on Base mainnet.
///         Source: github.com/sparkdotfi/xchain-ssr-oracle
///
///         Storage is a single packed slot mirroring the mainnet SSR module:
///         - ssr (uint96)  per-second savings rate (ray, 27 decimals)
///         - chi (uint120) cumulative index at last bridge update
///         - rho (uint40)  timestamp of last bridge update
///
///         getConversionRate() extrapolates chi forward locally on every read using
///         ssr × (block.timestamp - rho), so accrual is continuous on Base between
///         the (rare) bridge messages from mainnet.
interface ISSRAuthOracle {
    /// @notice Returns the current USDS-per-sUSDS conversion rate, in ray (27 decimals),
    ///         extrapolated forward to `block.timestamp` using the compounded SSR since the
    ///         last bridge update.
    /// @dev THIS is what callers should use to price sUSDS in USDS or to track yield over time —
    ///      it changes every block. `getChi()` is the underlying *stored* value (stale between
    ///      bridge updates) and should NOT be used for yield accounting.
    function getConversionRate() external view returns (uint256);

    /// @notice Returns the raw stored chi at the most recent bridge update, in ray.
    /// @dev DOES NOT extrapolate — this value only changes when the bridge pushes an update.
    ///      Combined with getSSR() and getRho() it lets callers reconstruct the conversion rate
    ///      manually, but most code should use getConversionRate() directly.
    function getChi() external view returns (uint256);

    /// @notice Returns the per-second savings rate currently in effect, in ray. Stored as
    ///         `(1 + per_second_rate)` in ray, so the neutral value is 1e27, not 0.
    /// @dev At 5% APY, getSSR() returns approximately 1.0000000015e27 ray.
    function getSSR() external view returns (uint256);

    /// @notice Returns the timestamp of the last bridge-driven update.
    function getRho() external view returns (uint256);
}
