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
    /// @notice Returns the current USDS-per-sUSDS conversion rate, in ray (27 decimals).
    /// @dev Extrapolates chi forward using the compounded SSR since last update.
    function getConversionRate() external view returns (uint256);

    /// @notice Returns the extrapolated cumulative index (chi) at the current block, in ray.
    /// @dev Equivalent to getConversionRate() — alias for callers thinking in chi-index terms.
    ///      Used by the Vault to drive its beneficiary-yield share accounting; chi is the
    ///      natural quantity because yield is proportional to (newChi - oldChi) / oldChi.
    function getChi() external view returns (uint256);

    /// @notice Returns the per-second savings rate currently in effect, in ray.
    function getSSR() external view returns (uint256);

    /// @notice Returns the timestamp of the last bridge-driven update.
    function getRho() external view returns (uint256);
}
