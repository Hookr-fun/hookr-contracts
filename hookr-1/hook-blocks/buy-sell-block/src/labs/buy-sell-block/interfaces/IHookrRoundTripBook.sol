// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title Round-trip record book
/// @notice Read surface of a Rules module that records, per pool and trader key, the directions traded in the
///         current block.
interface IHookrRoundTripBook {
    /// @notice Whether the Rules module records round trips for the pool.
    function recordsRoundTrips(PoolId id) external view returns (bool);

    /// @notice The trader's last recorded block on the pool and the directions it traded in that block.
    /// @return word `blockNumber << 2 | sold << 1 | bought`; zero when nothing was recorded.
    function roundTripWord(PoolId id, bytes32 trader) external view returns (uint256 word);
}
