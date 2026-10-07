// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Hookr fee swap adapter
/// @notice One venue-specific exact-input swap. Holds no funds between calls.
interface IHookrFeeSwapAdapter {
    /// @notice Swaps exactly `amountIn` of `tokenIn` for at least `minAmountOut` of `tokenOut`, paid to `recipient`.
    /// @dev Native input arrives as `msg.value`; ERC-20 input is pulled from `msg.sender`, which must have approved it.
    function executeExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        bytes calldata routeData
    ) external payable returns (uint256 amountOut);
}
