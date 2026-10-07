// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Zap math
/// @notice Price-impact limits and liquidity sizing for the zap vault.
library ZapMath {
    uint256 internal constant BPS = 10_000;
    uint256 private constant ONE = 1e18;

    /// @notice The sqrt-price limit that stops a subject buy once the subject's quote price has risen by `impactBps`.
    /// @dev With the quote as currency0 a buy is zeroForOne and the pool price (currency1 per currency0) falls, so the
    ///      subject price (1 / p) rises by at most (1 + i) when sqrtP' >= sqrtP / sqrt(1 + i). With the quote as currency1
    ///      the pool price is the subject price and sqrtP' <= sqrtP * sqrt(1 + i). sqrt(1 + i) is floored, which makes the
    ///      limit stricter; the final mulDiv floors by at most one Q64.96 unit. Clamped strictly inside v4's price range.
    /// @param sqrtPriceX96 Current pool sqrt price.
    /// @param quoteIsCurrency0 Whether the quote is the pool's currency0 (native ETH always is).
    /// @param impactBps Allowed subject-price rise in basis points (1..2000 in the vault).
    /// @return limit The sqrtPriceLimitX96 to pass to the swap.
    function buyLimit(uint160 sqrtPriceX96, bool quoteIsCurrency0, uint16 impactBps)
        internal
        pure
        returns (uint160 limit)
    {
        uint256 factor = Math.sqrt((BPS + impactBps) * ONE * ONE / BPS);
        if (quoteIsCurrency0) {
            uint256 l = FullMath.mulDiv(sqrtPriceX96, ONE, factor);
            if (l <= TickMath.MIN_SQRT_PRICE) l = TickMath.MIN_SQRT_PRICE + 1;
            // l <= sqrtPriceX96 (factor >= 1e18), so it fits uint160.
            // forge-lint: disable-next-line(unsafe-typecast)
            limit = uint160(l);
        } else {
            uint256 l = FullMath.mulDiv(sqrtPriceX96, factor, ONE);
            if (l >= TickMath.MAX_SQRT_PRICE) l = TickMath.MAX_SQRT_PRICE - 1;
            // l < MAX_SQRT_PRICE after the clamp, so it fits uint160.
            // forge-lint: disable-next-line(unsafe-typecast)
            limit = uint160(l);
        }
    }

    /// @notice Largest liquidity that `amount0` and `amount1` can fund on [sqrtA, sqrtB] at sqrtP (rounded down).
    /// @dev The standard v3/v4 periphery formula, written here because this code has no v4-periphery dependency.
    ///      Capped at int128 max so the result is always a valid positive liquidityDelta.
    function liquidityForAmounts(uint160 sqrtP, uint160 sqrtA, uint160 sqrtB, uint256 amount0, uint256 amount1)
        internal
        pure
        returns (uint128)
    {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        uint256 l;
        if (sqrtP <= sqrtA) {
            l = _forAmount0(sqrtA, sqrtB, amount0);
        } else if (sqrtP < sqrtB) {
            uint256 l0 = _forAmount0(sqrtP, sqrtB, amount0);
            uint256 l1 = _forAmount1(sqrtA, sqrtP, amount1);
            l = l0 < l1 ? l0 : l1;
        } else {
            l = _forAmount1(sqrtA, sqrtB, amount1);
        }
        uint256 cap = uint256(uint128(type(int128).max));
        return uint128(l > cap ? cap : l);
    }

    function _forAmount0(uint160 a, uint160 b, uint256 amount0) private pure returns (uint256) {
        if (b == a || amount0 == 0) return 0;
        uint256 intermediate = FullMath.mulDiv(a, b, FixedPoint96.Q96);
        return _mulDivSaturating(amount0, intermediate, b - a);
    }

    function _forAmount1(uint160 a, uint160 b, uint256 amount1) private pure returns (uint256) {
        if (b == a || amount1 == 0) return 0;
        return _mulDivSaturating(amount1, FixedPoint96.Q96, b - a);
    }

    /// @dev mulDiv that saturates instead of reverting when the 512-bit quotient does not fit 256 bits.
    function _mulDivSaturating(uint256 x, uint256 y, uint256 d) private pure returns (uint256) {
        (bool ok, uint256 hi) = _highWordFits(x, y, d);
        return ok ? FullMath.mulDiv(x, y, d) : hi;
    }

    function _highWordFits(uint256 x, uint256 y, uint256 d) private pure returns (bool, uint256) {
        uint256 prod1;
        assembly ("memory-safe") {
            let mm := mulmod(x, y, not(0))
            let prod0 := mul(x, y)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }
        return (d > prod1, type(uint256).max);
    }
}
