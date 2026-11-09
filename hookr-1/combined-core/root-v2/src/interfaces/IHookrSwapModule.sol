// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title IHookrSwapModule
/// @notice A Hook Block that fills part or all of a Hookr pool's swap from an outside venue, inside the root's
///         `beforeSwap`, the job Uniswap's BaseAggregatorHook does for a pool with no liquidity of its own. The root
///         returns the fill as its BeforeSwapDelta, so the pool's own liquidity fills only the rest, and every other
///         Hook Block (fees, Anti-Snipe, Wallet Cap, Auto Burn, arb recapture, King of the Pool) still runs on the
///         whole swap: the root adds the fill to the pool's own fill before its Rules settle.
/// @dev No owner, no setter, no proxy. A module is admitted the way a block's brake key is: a RULES part admission
///      under the core's part scope, with its runtime codehash pinned, its gas limit the most the root forwards to
///      `wouldFill` and `fill`, and `keccak256("IHookrSwapModule")` as its schema hash. Admission is read when a root
///      is built with the module and when a pool of such a root opens (HookrLane, NC34), never on a swap; a revocation
///      stops new roots and new pools, never an open pool.
///
///      The call, in the root's `beforeSwap` of an outer exact-input swap, after the Rules quote and the reservation:
///      0. The root asks `wouldFill` first. False (the module has no venue for the pair, or its venue does not beat
///         the pool after both fees) ends the fill there: nothing is minted and the pool fills the whole swap.
///      1. The root mints `budget` ERC-6909 claims of the swap's input currency to the module (the root's delta goes
///         down by `budget`).
///      2. The root calls `fill`. The module burns those claims (its delta goes up by `budget`), trades at most
///         `budget` of the input on its venue while it beats the pool after both fees, pays the venue from the
///         PoolManager (`take`), has the venue's output paid into the PoolManager after `sync` and credits it to the
///         root (`settleFor(root)`), and mints any unused input back to the root as claims. It must always end a
///         `sync` with a settle, even of nothing, so no synced currency is left behind for the next payer.
///      3. The root burns the claims the module returned, returns `amountIn` more on the specified side and
///         `amountOut` on the unspecified side as its BeforeSwapDelta, and checks the fill is no worse than the pool's
///         own price net of its LP fee.
///      The PoolManager checks most of the module's answers: the root carries the deltas the answers imply, the
///      module carries the deltas its PoolManager calls made, and both must be zero when the unlock ends. A module
///      that over- or under-reports `amountOut` leaves the root unsettled and the whole transaction reverts
///      (`CurrencyNotSettled`); one that over-reports `amountIn` to keep input is refused by the root's price check.
///      One answer nothing checks: the root burns `budget - amountIn` of its own claims after `fill`, trusting that the
///      module minted them back. A module that keeps them and reports less input passes, and the burn spends claims
///      the root already held, or reverts every exact-input swap of the root when it holds none. So admission review
///      must confirm the module mints all unused input back. A `wouldFill` that answers wrong only costs gas or leaves
///      the swap to the pool, and either call may spend at most the module's admitted gas: HookrFill requires every
///      exact-input swap to carry both calls' whole admitted gas (`HookrFill.gasFloor`).
interface IHookrSwapModule {
    /// @notice Whether `fill` would trade anything now for a swap of `input` for `output` on a Hookr pool at
    ///         `sqrtPriceX96` charging `lpFeePips`: false when the module has no venue for the pair or its venue,
    ///         after its own fee, does not beat the pool after its fee. Read by the root before it mints anything, so a
    ///         miss costs this view alone.
    function wouldFill(Currency input, Currency output, uint160 sqrtPriceX96, uint24 lpFeePips)
        external
        view
        returns (bool);

    /// @notice Fills up to `budget` of a swap of `input` for `output` from the outside venue, crediting the caller.
    /// @dev The module moves value only between itself and its caller: it burns claims the caller minted to it,
    ///      credits the output to the caller and mints unused input back to the caller. So it needs no caller check:
    ///      anyone calling it without minting the budget first reverts at the burn, and anyone who does only routes
    ///      their own swap. The direction on the pool is `input < output` (currency0 in), as v4 sorts a key.
    /// @param input The swap's input currency, which the caller minted `budget` of to this module as claims.
    /// @param output The swap's output currency.
    /// @param budget The input, net of the reservation.
    /// @param sqrtPriceX96 The Hookr pool's price before the swap.
    /// @param lpFeePips The LP fee the pool charges this swap (base and every surcharge), so the module fills
    ///        outside only while the venue, after its own fee, beats the pool after its fee.
    /// @return amountIn The input the venue used, at most `budget`.
    /// @return amountOut The output credited to the caller in the PoolManager.
    function fill(Currency input, Currency output, uint256 budget, uint160 sqrtPriceX96, uint24 lpFeePips)
        external
        returns (uint256 amountIn, uint256 amountOut);

    /// @notice The venue this module trades for a pool of `currency0` and `currency1`, zero when it has none (the
    ///         root then fills from the pool).
    function venueOf(Currency currency0, Currency currency1) external view returns (address venue);
}
