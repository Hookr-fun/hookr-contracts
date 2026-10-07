// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IV3ObservationSource
/// @notice The subset of a Uniswap v3 pool this reference reads.
interface IV3ObservationSource {
    /// @notice v3 `observe`: tick and seconds-per-liquidity accumulators at each `secondsAgo`.
    /// @param secondsAgos Seconds before now to read
    /// @return tickCumulatives The tick accumulators
    /// @return secondsPerLiquidityCumulativeX128s The seconds-per-liquidity accumulators
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

    /// @notice v3 token0.
    /// @return The lower-sorted token
    function token0() external view returns (address);

    /// @notice v3 token1.
    /// @return The higher-sorted token
    function token1() external view returns (address);
}
