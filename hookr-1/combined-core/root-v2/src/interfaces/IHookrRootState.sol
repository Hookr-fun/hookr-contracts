// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title IHookrRootState
/// @notice A Hookr root's own surface beside IHookrRoot, IHookrRootRoute and IHooks: its router, quoter and curated
///         router pins, its constants, the hook fee event and the errors only the root raises. The root also serves
///         IHookrLaneRoot (quoteLeg from its own code, the rest from its lane module by DELEGATECALL) and emits
///         IHookrRootEvents and IHookrLaneEvents.
interface IHookrRootState {
    /// @notice The root's PoolManager, registry, router or other wiring is invalid.
    error InvalidWiring();
    /// @notice The swap's amount is zero or above the largest the pool can take.
    error AmountOutOfRange();
    /// @notice The rules and advisory together charge above the pool's cap.
    error AggregateCapExceeded();
    /// @notice An advisory or the compliance guard refused the swap.
    error SwapRejected();
    /// @notice The caller asked for a swap receipt the root did not hold for it.
    error NoReceipt();
    /// @notice The PoolManager called a hook callback the root's permission flags do not enable.
    error UnsupportedCallback();
    /// @notice The subject token is the PoolManager's synced currency, so Auto Burn cannot run.
    error UnsupportedBurnSync();
    /// @notice The subject token moved a different amount than the burn.
    error UnsupportedTokenTransfer();
    /// @notice Pool `id` owes `refund` to an unauthenticated swap, which has nobody to credit.
    error UnauthenticatedRefund(PoolId id, uint256 refund);
    /// @notice The exact output delivered `actual`, not the `required` amount.
    error ExactOutputShortfall(uint256 actual, uint256 required);
    /// @notice Pool `id`'s principal is locked until block `untilBlock`.
    error LiquidityLocked(PoolId id, uint256 untilBlock);
    /// @notice The call is not an arb recapture leg this root's lane opened.
    error NotALeg();
    /// @notice The executor refused the swap on the pool of `subject` and `quote`: the swapper is closing an arbitrage
    ///         inside a v3 pool's callback.
    error MevCallbackRefused(address subject, address quote);

    /// @notice The outcome of a simulated swap, the only way a simulation returns. sqrtPriceAfterX96 is the last price
    ///         with liquidity the swap reached.
    error SwapSimulated(uint160 sqrtPriceBeforeX96, int24 tickBefore, uint160 sqrtPriceAfterX96, int24 tickAfter);

    /// @notice URC-2: this hook's own token deltas in one swap, from the swapper's side in pool order, with the core
    ///         `Swap` sign convention (negative = paid by the swapper), so core `Swap` + `HookSwap` is the caller's
    ///         BalanceDelta. Emitted by `afterSwap` once per swap, only when the hook adds a delta: a quote take, an Auto
    ///         Burn (the dead claims), or an outside fill (one event for fill, take and burn together). Never for a
    ///         swap the hook adds nothing to, a quote or a simulation. Consumers must check the emitter is the pool
    ///         key's hook.
    /// @dev The quote take is gross: on an authenticated exact-input swap stopped by its price limit it includes the
    ///      refund the payer claims later, outside the swap's deltas; `HookFee.refund` beside it gives the net.
    ///      `swapFee` is the quote take rate in pips (the Rules' plus the advisory's), 0 with no take; a burn is not a
    ///      swap fee rate and the LP fee is in core `Swap.fee`.
    /// @param id The pool.
    /// @param sender The PoolManager's swap caller (often a router).
    /// @param amount0 Minus this hook's currency0 delta.
    /// @param amount1 Minus this hook's currency1 delta.
    /// @param swapFee The quote take rate in pips, or 0.
    event HookSwap(PoolId indexed id, address indexed sender, int128 amount0, int128 amount1, uint24 swapFee);

    /// @notice A swap's hook fee, refund and burn.
    /// @param id The pool.
    /// @param quote The pool's quote currency.
    /// @param earned The fee the swap paid.
    /// @param refund The quote refunded to the payer.
    /// @param burned The subject burned by Auto Burn.
    event HookFee(PoolId indexed id, Currency indexed quote, uint256 earned, uint256 refund, uint256 burned);

    /// @notice The low 14 bits every root's address carries: its Uniswap v4 hook permissions.
    /// @return The permission flags.
    function PERMISSION_FLAGS() external view returns (uint160);

    /// @notice Where Auto Burn sends the subject tokens it burns.
    /// @return The burn address.
    function DEAD() external view returns (address);

    /// @notice Returns the runtime codehash of the router the root pins.
    /// @return The router's codehash.
    function routerCodeHash() external view returns (bytes32);

    /// @notice Returns the runtime codehash of the quoter the root pins.
    /// @return The quoter's codehash.
    function quoterCodeHash() external view returns (bytes32);

    /// @notice Returns the runtime codehash of the curated router the root pins.
    /// @return The curated router's codehash.
    function curatedRouterCodeHash() external view returns (bytes32);
}
