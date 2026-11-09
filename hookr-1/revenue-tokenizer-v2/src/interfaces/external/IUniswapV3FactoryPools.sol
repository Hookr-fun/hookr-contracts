// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Uniswap v3 factory, the subset the state view reads
/// @notice The pool of two tokens at a fee.
interface IUniswapV3FactoryPools {
    /// @notice The pool of `tokenA` and `tokenB` (either order) at `fee`, or zero when there is none.
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}
