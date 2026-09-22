// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title WTH Arbitrage Executor V1
/// @notice The interface WTH (Shaper) supplied for their arbitrage-recapture executor.
/// @dev Restated here at this repository's pragma so the adapter can encode calls against it. Only
///      the ABI matters: the field types and their order fix the selector, the names do not. No
///      Hookr contract implements this interface, and nothing here asserts that WTH's contract
///      exists yet. `HookrWthExecutorAdapterV1` is the only caller, and WTH's deployment is
///      expected to hardcode that adapter as its approved caller.
interface IWthArbitrageExecutorV1 {
    /// @notice Shares of realized profit the caller names. The three fields must sum to 8000 bps;
    ///         the remaining 2000 bps is WTH's and Hookr's and is handled inside the executor.
    struct ProfitSplit {
        address creator;
        uint16 traderBps;
        uint16 creatorBps;
        uint16 triggerPoolBps;
    }

    /// @notice Runs one arbitrage against the pool that triggered it and pays out the split.
    /// @dev When `rebateRecipient` is the zero address, `traderBps` must be zero and its share must
    ///      already be allocated to the other two, with the total still 8000. `split.creator` may
    ///      be the zero address only when `creatorBps` is zero.
    function executeArbitrage(PoolKey calldata triggeringPool, address rebateRecipient, ProfitSplit calldata split)
        external
        returns (uint256 profit);

}
