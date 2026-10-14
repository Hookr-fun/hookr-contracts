// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPriceFeed
/// @notice The one function of a price feed the bench calls: the shape Market Guard reads.
interface IPriceFeed {
    /// @notice The feed's latest round. `answer` is the price with the feed's decimals (8 for ETH / USD).
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
