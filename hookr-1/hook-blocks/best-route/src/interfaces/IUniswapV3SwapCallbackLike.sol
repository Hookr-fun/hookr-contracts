// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Uniswap v3 swap callback
interface IUniswapV3SwapCallbackLike {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}
