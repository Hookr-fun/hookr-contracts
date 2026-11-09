// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Uniswap v3 pool, the subset the state view reads for a position's fees
/// @notice The pool's current tick, its global fee growth on each side and each tick's fee growth outside.
/// @dev Fee growth is a Q128.128 accumulator per unit of liquidity that wraps; the state view reads it as
///      HookrV3Fees does the math.
interface IUniswapV3PoolFees {
    /// @notice The pool's price, tick, oracle cursor, protocol fee and lock.
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
    /// @notice The fee growth of token0 per unit of liquidity over the pool's life.
    function feeGrowthGlobal0X128() external view returns (uint256);
    /// @notice The fee growth of token1 per unit of liquidity over the pool's life.
    function feeGrowthGlobal1X128() external view returns (uint256);
    /// @notice What the pool keeps for `tick`, among it the fee growth on the other side of it.
    function ticks(int24 tick)
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128,
            int56 tickCumulativeOutside,
            uint160 secondsPerLiquidityOutsideX128,
            uint32 secondsOutside,
            bool initialized
        );
}
