// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title Hookr Kernel Router V2
/// @notice Coordinator-only entrypoint for a native-quote initial creator buy.
/// @dev The router derives buy direction from the frozen subject/quote identity. The creator is
///      both the authenticated hook payer and the output recipient; the coordinator supplies the
///      native input in the same transaction that creates the market.
interface IHookrKernelRouterV2 {
    /// @notice Parameters for an exact-input initial creator buy.
    struct InitialBuyParams {
        /// @notice Pool key for the newly initialized market.
        PoolKey key;
        /// @notice Address authenticated as the hook payer and receiving the subject output.
        address creator;
        /// @notice Exact native quote amount supplied to the swap.
        uint128 quoteAmountIn;
        /// @notice Minimum subject amount the creator must receive.
        uint128 subjectAmountOutMinimum;
        /// @notice Last block timestamp at which the swap may execute.
        uint256 deadline;
    }

    /// @notice Executes an exact-input initial creator buy for a newly created native-quote market.
    /// @dev The implementation must accept this call only from its bound coordinator and must
    ///      consume the full quote input or revert.
    /// @param params Pool, creator, amount, slippage, and deadline parameters.
    /// @param moduleData Encoded data forwarded to the market's immutable hook stack.
    /// @return quoteAmountIn Native quote amount consumed by the swap.
    /// @return subjectAmountOut Subject amount delivered to the creator.
    function exactInputInitialBuy(InitialBuyParams calldata params, bytes calldata moduleData)
        external
        payable
        returns (uint256 quoteAmountIn, uint256 subjectAmountOut);
}
