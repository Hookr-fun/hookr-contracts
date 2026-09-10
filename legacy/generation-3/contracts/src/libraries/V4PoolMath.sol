// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title V4PoolMath
/// @notice The minimum Uniswap math a full-range v4 LP position needs: 512-bit mulDiv, the sqrt
///         price at a tick, and liquidity<->amounts conversions.
/// @dev Adapted from Uniswap `v3-core` FullMath, `v4-core` TickMath and `v4-periphery`
///      LiquidityAmounts (all MIT). Ported verbatim in semantics; only naming and pragma differ.
///      These functions SIZE a liquidity change — they never decide what is owed. The pool's own
///      `modifyLiquidity` deltas are the settlement authority, so an error here fails closed as a
///      settlement revert inside the PoolManager, never as silent mispricing.
library V4PoolMath {
    /// @dev `TickMath.MIN_TICK` / `MAX_TICK`.
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;
    uint256 internal constant Q96 = 0x1000000000000000000000000;

    error TickOutOfRange(int24 tick);
    error LiquidityOverflow();
    error MulDivOverflow();

    /// @notice Largest full-range position expressible at `tickSpacing`: the most extreme ticks
    ///         that are multiples of the spacing.
    function usableTickRange(int24 tickSpacing) internal pure returns (int24 tickLower, int24 tickUpper) {
        // The truncating division IS the point: round each bound toward zero to the nearest
        // multiple of the spacing, exactly like v4's TickMath.minUsableTick/maxUsableTick.
        // forge-lint: disable-next-line(divide-before-multiply)
        tickLower = (MIN_TICK / tickSpacing) * tickSpacing;
        // forge-lint: disable-next-line(divide-before-multiply)
        tickUpper = (MAX_TICK / tickSpacing) * tickSpacing;
    }

    /// @notice `sqrt(1.0001^tick) * 2^96`, the canonical Uniswap v3/v4 tick-to-price function.
    function getSqrtPriceAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        unchecked {
            uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
            if (absTick > uint256(int256(MAX_TICK))) revert TickOutOfRange(tick);

            uint256 ratio =
                absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
            if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
            if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
            if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
            if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
            if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
            if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
            if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
            if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
            if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
            if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
            if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
            if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
            if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
            if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
            if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
            if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
            if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
            if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
            if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

            if (tick > 0) ratio = type(uint256).max / ratio;

            // Round up on truncation from Q128.128 to Q64.96 so prices are monotone in the tick.
            // casting to 'uint160' is safe: the largest ratio (at MAX_TICK) shifted right by 32
            // fits in 160 bits by construction of the constants above.
            // forge-lint: disable-next-line(unsafe-typecast)
            sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
        }
    }

    /// @notice Floor(a * b / denominator) with full 512-bit intermediate precision.
    /// @notice Largest tick whose price is <= `sqrtPriceX96` — the inverse of `getSqrtPriceAtTick`.
    /// @dev Binary search over the same tick->price function rather than a second log
    ///      approximation, so the two directions can never disagree about a boundary. ~18
    ///      iterations over the usable range; only used off the swap path (graduation and fee
    ///      collection), where that cost is irrelevant.
    function getTickAtSqrtPrice(uint160 sqrtPriceX96) internal pure returns (int24 tick) {
        int24 low = MIN_TICK;
        int24 high = MAX_TICK;
        while (low < high) {
            // Round up so the loop always advances; with round-down, low == high - 1 stalls.
            int24 mid = low + (high - low + 1) / 2;
            if (getSqrtPriceAtTick(mid) <= sqrtPriceX96) low = mid;
            else high = mid - 1;
        }
        return low;
    }

    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            if (prod1 == 0) {
                if (denominator == 0) revert MulDivOverflow();
                assembly {
                    result := div(prod0, denominator)
                }
                return result;
            }

            if (denominator <= prod1) revert MulDivOverflow();

            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
            }
            assembly {
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            uint256 twos = (0 - denominator) & denominator;
            assembly {
                denominator := div(denominator, twos)
            }
            assembly {
                prod0 := div(prod0, twos)
            }
            assembly {
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;

            result = prod0 * inv;
        }
    }

    /// @notice The largest liquidity `amount0` of token0 can fund over `[sqrtPriceAX96, sqrtPriceBX96]`.
    function getLiquidityForAmount0(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount0)
        internal
        pure
        returns (uint128 liquidity)
    {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        uint256 intermediate = mulDiv(sqrtPriceAX96, sqrtPriceBX96, Q96);
        return _toUint128(mulDiv(amount0, intermediate, sqrtPriceBX96 - sqrtPriceAX96));
    }

    /// @notice The largest liquidity `amount1` of token1 can fund over `[sqrtPriceAX96, sqrtPriceBX96]`.
    function getLiquidityForAmount1(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount1)
        internal
        pure
        returns (uint128 liquidity)
    {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        return _toUint128(mulDiv(amount1, Q96, sqrtPriceBX96 - sqrtPriceAX96));
    }

    /// @notice The largest liquidity both amounts can jointly fund at the current price.
    function getLiquidityForAmounts(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }

        if (sqrtPriceX96 <= sqrtPriceAX96) {
            liquidity = getLiquidityForAmount0(sqrtPriceAX96, sqrtPriceBX96, amount0);
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            uint128 liquidity0 = getLiquidityForAmount0(sqrtPriceX96, sqrtPriceBX96, amount0);
            uint128 liquidity1 = getLiquidityForAmount1(sqrtPriceAX96, sqrtPriceX96, amount1);
            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        } else {
            liquidity = getLiquidityForAmount1(sqrtPriceAX96, sqrtPriceBX96, amount1);
        }
    }

    /// @notice The token amounts `liquidity` represents at the current price (rounded down).
    function getAmountsForLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }

        if (sqrtPriceX96 <= sqrtPriceAX96) {
            amount0 = _amount0ForLiquidity(sqrtPriceAX96, sqrtPriceBX96, liquidity);
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            amount0 = _amount0ForLiquidity(sqrtPriceX96, sqrtPriceBX96, liquidity);
            amount1 = _amount1ForLiquidity(sqrtPriceAX96, sqrtPriceX96, liquidity);
        } else {
            amount1 = _amount1ForLiquidity(sqrtPriceAX96, sqrtPriceBX96, liquidity);
        }
    }

    function _amount0ForLiquidity(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint128 liquidity)
        private
        pure
        returns (uint256)
    {
        return mulDiv(uint256(liquidity) << 96, sqrtPriceBX96 - sqrtPriceAX96, sqrtPriceBX96) / sqrtPriceAX96;
    }

    function _amount1ForLiquidity(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint128 liquidity)
        private
        pure
        returns (uint256)
    {
        return mulDiv(liquidity, sqrtPriceBX96 - sqrtPriceAX96, Q96);
    }

    function _toUint128(uint256 value) private pure returns (uint128) {
        if (value > type(uint128).max) revert LiquidityOverflow();
        // casting to 'uint128' is safe: bounds-checked on the line above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(value);
    }
}
