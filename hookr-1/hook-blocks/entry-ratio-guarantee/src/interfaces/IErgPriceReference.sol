// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title Entry Ratio Guarantee price reference
/// @notice A price the depositor cannot move inside its own transaction, used to bound the entry price.
/// @dev The hook calls `referenceSqrtPriceX96` through STATICCALL when a pool registers, at every deposit and at every
///      exit that asks for the entry ratio (in both removal callbacks: the exercise band check, then the leg's
///      reference amounts), and never during a swap or an exit that does not ask for it. A reference that reverts or
///      returns zero refuses registration and deposits into its pool and blocks every exercise until it answers again
///      (fail closed), so an option window that ends while it refuses lapses. Implementations must be manipulation
///      resistant across at least one block (a TWAP, not spot). `entrySqrtPriceX96` is read when a pool registers and
///      once per deposit, after `referenceSqrtPriceX96`, and stored with the position; exits read the stored value.
///      The hook reads `errorSqrtPips` once, when a pool registers, and sizes that pool's entry band as half the pool
///      fee less the declared tolerance, so that tolerance plus band never exceeds half the fee (the bound that makes
///      manufactured impermanent loss unprofitable). A pool whose fee leaves no band is refused. The declared
///      tolerance must be constant for the reference's life, because each pool freezes its band at registration.
interface IErgPriceReference {
    /// @notice Returns the reference sqrt price for `key`, as currency1 per currency0 in Q64.96.
    /// @param key The v4 pool being registered, entered or exercised
    /// @return sqrtPriceX96 The reference sqrt price, never zero on success
    function referenceSqrtPriceX96(PoolKey calldata key) external view returns (uint160 sqrtPriceX96);

    /// @notice Returns the price the hook records as a deposit's entry: the reference's estimate of the fair price
    ///         now, without the trailing its answer may carry after a genuine move. The hook caps an exit's cover at
    ///         the deficit the reference saw from this price to its answer at the exit, so an entry recorded
    ///         at a trailing answer turns the answer's catch-up into a deficit the market never had and
    ///         hides a genuine one from a deposit made at the market price. A reference whose answer does
    ///         not trail returns its answer. It must refuse whenever `referenceSqrtPriceX96` refuses.
    /// @param key The v4 pool being registered or entered
    /// @return sqrtPriceX96 The entry sqrt price, never zero on success
    function entrySqrtPriceX96(PoolKey calldata key) external view returns (uint160 sqrtPriceX96);

    /// @notice The reference's declared tolerance: the largest distance, in pips of sqrt price, between an answer it
    ///         gives and the fair price, under the manipulation model the reference documents. Constant for life.
    /// @return The declared tolerance in sqrt pips (1,000,000 = 100%)
    function errorSqrtPips() external view returns (uint24);
}
