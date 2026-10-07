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
