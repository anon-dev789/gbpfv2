// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

/// @title Minimal Chainlink AggregatorV3Interface surface.
/// @notice We only need latestRoundData and decimals. The full interface includes round-id-by-id
///         lookups which we don't use.
interface IChainlinkFeed {
    /// @return roundId         The latest round id.
    /// @return answer          The reported value (signed; for GBP/USD it's price * 10^decimals).
    /// @return startedAt       Block timestamp when this round started.
    /// @return updatedAt       Block timestamp when this round was updated.
    /// @return answeredInRound Round id of the round answer was computed in.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function decimals() external view returns (uint8);
}
