// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrRegistry} from "./IHookrRegistry.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

/// @title IHookrPairRoot
/// @notice One immutable Uniswap v4 hook for exactly one dynamic-fee pool.
interface IHookrPairRoot {
    /// @notice Construction parameters. Every value is immutable for the life of the pool.
    struct Params {
        /// @notice The pool's lower-sorted currency; native ETH is address zero.
        Currency currency0;
        /// @notice The pool's higher-sorted currency.
        Currency currency1;
        /// @notice The pool's tick spacing.
        int24 tickSpacing;
        /// @notice The LP fee charged on every swap, written to the pool once at initialization.
        uint24 baseLpFeePips;
        /// @notice The ceiling on every fee the root returns, at least the base fee plus the advisory cap.
        uint24 maxLpFeePips;
        /// @notice The optional fee advisory, or zero for a fixed-fee pool.
        address advisory;
        /// @notice The ceiling on the advisory surcharge; zero without an advisory.
        uint24 advisoryCapPips;
        /// @notice The gas forwarded to the advisory; zero without an advisory.
        uint32 advisoryGasLimit;
        /// @notice On advisory failure, true charges the cap and false reverts the swap.
        bool advisoryFailOpen;
    }

    /// @notice The caller is not the factory.
    error Unauthorized();
    /// @notice The construction parameters are out of bounds.
    error InvalidParams();
    /// @notice The root's address does not carry the hook flags the PoolManager requires.
    error InvalidHookAddress();
    /// @notice The advisory `advisory` reverted, returned other than one word or a word above uint24.
    error AdvisoryFailed(address advisory);
    /// @notice The advisory `advisory` refused the swap.
    error AdvisoryRefused(address advisory);
    /// @notice Less gas is left than the advisory needs to run with its full gas limit.
    error InsufficientAdvisoryGas();

    /// @notice Returns the immutable Uniswap v4 PoolManager.
    /// @return The PoolManager.
    function poolManager() external view returns (IPoolManager);

    /// @notice Returns the Hookr registry the root was deployed for.
    /// @return The registry.
    function registry() external view returns (IHookrRegistry);

    /// @notice Returns the factory that deployed the root.
    /// @return The factory.
    function factory() external view returns (address);

    /// @notice Returns the one pool key this root serves.
    /// @return The pool key.
    function poolKey() external view returns (PoolKey memory);

    /// @notice Returns the id of the one pool this root serves.
    /// @return The pool id.
    function poolId() external view returns (PoolId);

    /// @notice Returns whether `id` is this root's pool.
    /// @param id The pool.
    /// @return True when `id` is this root's pool.
    function knownPool(PoolId id) external view returns (bool);

    /// @notice Returns the immutable construction parameters.
    /// @return The construction parameters.
    function params() external view returns (Params memory);

    /// @notice Binds the pool in the advisory with `advisoryData`, initializes the pool at `sqrtPriceX96` and writes
    ///         the base fee. Only the factory can call.
    /// @dev Without an advisory, `advisoryData` must be empty.
    /// @param sqrtPriceX96 The pool's opening price as a sqrt price in Q64.96.
    /// @param advisoryData The advisory's parameters for the pool; empty without an advisory.
    /// @return tick The pool's opening tick.
    function open(uint160 sqrtPriceX96, bytes calldata advisoryData) external returns (int24 tick);

    /// @notice Refuses every initialization the PoolManager reports.
    /// @dev The one pool this root serves is initialized from `open`, which the PoolManager does not report here.
    ///      Any other key naming this hook, and any other caller initializing this root's key, reverts.
    /// @param sender The account initializing the pool.
    /// @param key The pool key being initialized.
    /// @param sqrtPriceX96 The initial price as a sqrt price in Q64.96.
    /// @return Never returns: every call reverts.
    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96) external pure returns (bytes4);

    /// @notice Returns zero delta and the swap's LP fee. No storage is written.
    /// @dev Without an advisory the fee is 0 without the override flag, so the pool charges the slot0 base fee.
    /// @param sender The PoolManager caller, as the PoolManager reports it.
    /// @param key The pool key.
    /// @param swap The swap's parameters.
    /// @param hookData The swap's hook data, passed to the advisory.
    /// @return The selector of `beforeSwap`.
    /// @return A zero delta.
    /// @return The swap's LP fee in pips, with the override flag when an advisory prices it.
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata swap, bytes calldata hookData)
        external
        view
        returns (bytes4, BeforeSwapDelta, uint24);
}
