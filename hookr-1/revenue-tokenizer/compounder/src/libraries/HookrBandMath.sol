// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

/// @title Hookr band math
/// @notice The grid of bands a compounder places its liquidity on, and the liquidity math of a band that lies entirely
///         on one side of the price: how much liquidity an amount of one currency places there, and what a band holds.
library HookrBandMath {
    /// @dev Most passes of the trim loop in `liquidityForAmount0` and `liquidityForAmount1`; two is the usual count.
    uint256 private constant TRIM_PASSES = 8;

    /// @notice The band holding `tick`. Bands are `width` ticks wide and aligned on multiples of `width`: band `k`
    ///         spans `k x width` to `(k + 1) x width`. Floors toward minus infinity, so every tick is in exactly one band.
    function bandOf(int24 tick, int24 width) internal pure returns (int256 k) {
        k = int256(tick) / int256(width);
        if (tick < 0 && int256(tick) % int256(width) != 0) --k;
    }

    /// @notice The ticks of band `k`, cut to the pool's usable ticks for `spacing`. `ok` is false when nothing of the
    ///         band is usable. `width` is a multiple of `spacing`, so both ticks are too.
    function ticksOf(int256 k, int24 width, int24 spacing)
        internal
        pure
        returns (int24 tickLower, int24 tickUpper, bool ok)
    {
        int256 lower = k * int256(width);
        int256 upper = lower + int256(width);
        int256 minTick = TickMath.minUsableTick(spacing);
        int256 maxTick = TickMath.maxUsableTick(spacing);
        if (lower < minTick) lower = minTick;
        if (upper > maxTick) upper = maxTick;
        if (lower >= upper) return (0, 0, false);
        return (int24(lower), int24(upper), true);
    }

    /// @notice The liquidity `amount0` of currency0 places in a band from `sqrtA` to `sqrtB` (`sqrtA < sqrtB`) that
    ///         lies entirely above the price, so the band takes currency0 only. Rounded down, then trimmed until the
    ///         pool's own rounding up asks for at most `amount0`.
    function liquidityForAmount0(uint160 sqrtA, uint160 sqrtB, uint256 amount0) internal pure returns (uint128) {
        // amount0 x sqrtA x sqrtB / (Q96 x (sqrtB - sqrtA)), the amount's factor first so a low price (a small
        // sqrtA x sqrtB / Q96) loses no precision.
        uint256 liquidity = FullMath.mulDiv(FullMath.mulDiv(amount0, sqrtA, sqrtB - sqrtA), sqrtB, FixedPoint96.Q96);
        if (liquidity > type(uint128).max) liquidity = type(uint128).max;
        for (uint256 i; i < TRIM_PASSES && liquidity != 0; ++i) {
            uint256 need = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, uint128(liquidity), true);
            if (need <= amount0) return uint128(liquidity);
            liquidity = _lessBy(liquidity, amount0, need);
        }
        return 0;
    }

    /// @notice The liquidity `amount1` of currency1 places in a band from `sqrtA` to `sqrtB` (`sqrtA < sqrtB`) that
    ///         lies entirely below the price, so the band takes currency1 only. Rounded down, then trimmed until the
    ///         pool's own rounding up asks for at most `amount1`.
    function liquidityForAmount1(uint160 sqrtA, uint160 sqrtB, uint256 amount1) internal pure returns (uint128) {
        uint256 liquidity = FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtB - sqrtA);
        if (liquidity > type(uint128).max) liquidity = type(uint128).max;
        for (uint256 i; i < TRIM_PASSES && liquidity != 0; ++i) {
            uint256 need = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, uint128(liquidity), true);
            if (need <= amount1) return uint128(liquidity);
            liquidity = _lessBy(liquidity, amount1, need);
        }
        return 0;
    }

    /// @notice What `liquidity` between `tickLower` and `tickUpper` holds with the pool at `sqrtP` and `tick`, by the
    ///         rule the pool applies: currency0 only below the band, currency1 only above it, both inside it.
    function amountsForLiquidity(
        uint160 sqrtP,
        int24 tick,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        bool roundUp
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (liquidity == 0) return (0, 0);
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);
        if (tick < tickLower) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liquidity, roundUp);
        } else if (tick < tickUpper) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtP, sqrtB, liquidity, roundUp);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtP, liquidity, roundUp);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liquidity, roundUp);
        }
    }

    /// @dev `liquidity` scaled down by `have / need`, and by at least one unit, so a band whose unit of liquidity takes
    ///      less than one unit of currency still converges.
    function _lessBy(uint256 liquidity, uint256 have, uint256 need) private pure returns (uint256) {
        uint256 scaled = FullMath.mulDiv(liquidity, have, need);
        return scaled < liquidity ? scaled : liquidity - 1;
    }
}
