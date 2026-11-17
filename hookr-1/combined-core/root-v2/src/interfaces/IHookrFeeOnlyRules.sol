// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IHookrFeeOnlyRules
/// @notice Optional Rules extension. A root reads it once at binding; Rules without it are never skipped.
interface IHookrFeeOnlyRules {
    /// @notice Returns the parent-clock block from which every swap on the pool is fee-only, or zero for never.
    /// @dev From that block beforeSwap quotes zero for every context, and settleSwap of an all-zero settlement
    ///      credits nothing and changes no state. The root then skips both calls.
    /// @param id The pool.
    /// @return fromBlock The first parent-clock block of fee-only swaps, or zero for never.
    function feeOnlyFrom(PoolId id) external view returns (uint256 fromBlock);
}
