// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {IChainlinkFeed} from "../../src/interfaces/IChainlinkFeed.sol";

/// @dev Configurable mock of a Chainlink aggregator. Tests set (answer, updatedAt, startedAt)
///      directly and the mock returns them via latestRoundData(). roundId/answeredInRound are
///      stubbed; the OracleAdapter doesn't read them.
contract MockChainlinkFeed is IChainlinkFeed {
    int256 internal _answer;
    uint256 internal _updatedAt;
    uint256 internal _startedAt;
    uint80 internal _roundId;
    uint8 internal immutable _decimals;

    constructor(uint8 decimals_, int256 initialAnswer, uint256 initialUpdatedAt) {
        _decimals = decimals_;
        _answer = initialAnswer;
        _updatedAt = initialUpdatedAt;
        _startedAt = initialUpdatedAt;
        _roundId = 1;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answer, _startedAt, _updatedAt, _roundId);
    }

    /// Push a new (answer, updatedAt) and increment the round id.
    function set(int256 answer_, uint256 updatedAt_) external {
        _answer = answer_;
        _updatedAt = updatedAt_;
        _startedAt = updatedAt_;
        _roundId++;
    }

    /// Push a new (answer, startedAt, updatedAt). Used to model the sequencer-uptime feed where
    /// startedAt is meaningful independently of updatedAt.
    function setWithStartedAt(int256 answer_, uint256 startedAt_, uint256 updatedAt_) external {
        _answer = answer_;
        _startedAt = startedAt_;
        _updatedAt = updatedAt_;
        _roundId++;
    }
}
