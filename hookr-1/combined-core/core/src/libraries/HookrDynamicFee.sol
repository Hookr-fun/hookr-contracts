// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

/// @title HookrDynamicFee
/// @notice Prices Hookr dynamic fees on a swap's simulated move away from the pool's reference price.
/// @dev Internal library. A distance is measured in the coordinate the swap's input fills linearly at constant
///      liquidity: sqrt(ref) / sqrt(p) - 1 for a zeroForOne swap and sqrt(p) / sqrt(ref) - 1 for a oneForZero swap,
///      in WAD, positive on the side the swap moves toward. The marginal rate at distance d is min(1, (d / knee)^2)
///      of the pool's dynamic fee span, with knee = 1 / (2 * sensitivity). Unrelated to Uniswap v4's
///      DYNAMIC_FEE_FLAG, which every Hookr pool sets so its root can override the LP fee per swap.
library HookrDynamicFee {
    /// @notice Fixed-point unit for distances and rates.
    uint256 internal constant WAD = 1e18;
    /// @notice The reach bound a dynamic fee pool binds within (HookrRules.bind, `withinReach`). A swap is simulated
    ///         without its dynamic fee, so its charge leads the fee its executed move implies. On the dynamic fee suite's
    ///         four swap shapes (a fresh pool's first swap of 5% of its launch liquidity in, or of 4% of it out)
    ///         the lead stays within 5% when the pool's span (maxFeePips less its base fee, in pips) times its
    ///         sensitivity squared is at most MAX_REACH, which bounds the exact-input shapes, and its span times its
    ///         protocolShareBps times (RESERVE_SCALE - its sensitivity squared) is at most MAX_RESERVE x RESERVE_SCALE,
    ///         which bounds the exact-output sell: its simulation reserves the span times the share of its output,
    ///         and its own dynamic fee takes sensitivity squared over RESERVE_SCALE of that back, since that swap moves
    ///         the price 1/24 from the reference, where the average rate is 4/3 x (1/24)^2 = 1/432 of the span times
    ///         the sensitivity squared. An exact-output buy has no lead.
    uint256 internal constant MAX_REACH = 7_200_000;
    uint256 internal constant MAX_RESERVE = 230_000_000;
    uint256 internal constant RESERVE_SCALE = 432;

    /// @notice Whether a pool's dynamic fee is within the reach bound (MAX_REACH, MAX_RESERVE). A pool without dynamic
    ///         fees has no span and always is.
    /// @param span The pool's maxFeePips less its base fee, in pips.
    /// @param sens The pool's sensitivity, at most 10.
    /// @param share The pool's protocolShareBps.
    /// @return True when the pool may bind.
    function withinReach(uint256 span, uint256 sens, uint256 share) internal pure returns (bool) {
        uint256 sens2 = sens * sens;
        return span * sens2 <= MAX_REACH && span * share * (RESERVE_SCALE - sens2) <= MAX_RESERVE * RESERVE_SCALE;
    }

    /// @notice Signed distance of `sqrtPriceX96` from `sqrtRefX96` in the direction of a swap, in WAD.
    /// @param sqrtRefX96 The reference sqrt price.
    /// @param sqrtPriceX96 The sqrt price to measure.
    /// @param zeroForOne The swap direction; the distance grows as the swap moves the price.
    /// @return d The distance in WAD, negative on the side opposite the swap's direction.
    function distance(uint160 sqrtRefX96, uint160 sqrtPriceX96, bool zeroForOne) internal pure returns (int256 d) {
        uint256 ratio = zeroForOne
            ? FullMath.mulDiv(sqrtRefX96, WAD, sqrtPriceX96)
            : FullMath.mulDiv(sqrtPriceX96, WAD, sqrtRefX96);
        d = int256(ratio) - int256(WAD);
    }

    /// @notice The sqrt price at distance `d` from `sqrtRefX96` in the direction of a swap; the inverse of `distance`.
    /// @param sqrtRefX96 The reference sqrt price.
    /// @param d The distance in WAD, at least zero.
    /// @param zeroForOne The swap direction.
    /// @return sqrtPriceX96 The sqrt price at that distance.
    function priceAt(uint160 sqrtRefX96, uint256 d, bool zeroForOne) internal pure returns (uint160 sqrtPriceX96) {
        sqrtPriceX96 =
            uint160(zeroForOne ? FullMath.mulDiv(sqrtRefX96, WAD, WAD + d) : FullMath.mulDiv(sqrtRefX96, WAD + d, WAD));
    }

    /// @notice Average rate over the distances [a, b] from the reference, as a fraction of the span in WAD.
    /// @dev Integrates r(d) = min(1, (d / knee)^2) over [a, b] and divides by b - a. Below the knee this is
    ///      (a^2 + a * b + b^2) / (3 * knee^2), so at constant liquidity a move split into pieces pays the same total
    ///      as the move in one swap. Requires b > a.
    /// @param a Start distance in WAD, at least zero.
    /// @param b End distance in WAD, greater than `a`.
    /// @param sens The pool's sensitivity, 1 to 10.
    /// @return ratio The average rate in WAD, at most WAD.
    function averageRate(uint256 a, uint256 b, uint256 sens) internal pure returns (uint256 ratio) {
        uint256 knee = WAD / (2 * sens);
        if (a >= knee) return WAD;
        if (b <= knee) return 4 * sens * sens * (a * a + a * b + b * b) / (3 * WAD);
        // The quadratic part over [a, knee] is (knee^3 - a^3) / (3 * knee^2); the rate is 1 from knee to b.
        uint256 area = (knee - FullMath.mulDiv(a * a, a, knee * knee)) / 3 + (b - knee);
        ratio = FullMath.mulDiv(area, WAD, b - a);
        if (ratio > WAD) ratio = WAD;
    }

    /// @notice Moves the anchor from `sqrtAnchorX96` toward `sqrtEndX96` by the distance `quoteAmount` of the quote
    ///         pays at `minLiquidity`.
    /// @dev The anchor reaches the target price when the swap traded at least the quote that `minLiquidity` holds
    ///      between the two prices. A swap through thinner liquidity moves it only part of the way, however far the
    ///      price went.
    /// @param sqrtAnchorX96 The current anchor sqrt price.
    /// @param sqrtEndX96 The target sqrt price: the swap's executed price, or less far when the swap was charged less.
    /// @param minLiquidity The pool's minimum dynamic fee liquidity, nonzero.
    /// @param quoteAmount The quote the swap traded.
    /// @param quoteIsCurrency0 Whether the quote is the pool's currency0.
    /// @return next The new anchor sqrt price, between the two prices.
    /// @return reached Whether the anchor reached the end price.
    function advance(
        uint160 sqrtAnchorX96,
        uint160 sqrtEndX96,
        uint128 minLiquidity,
        uint256 quoteAmount,
        bool quoteIsCurrency0
    ) internal pure returns (uint160 next, bool reached) {
        if (sqrtAnchorX96 == sqrtEndX96) return (sqrtEndX96, true);
        uint256 required = quoteIsCurrency0
            ? SqrtPriceMath.getAmount0Delta(sqrtAnchorX96, sqrtEndX96, minLiquidity, true)
            : SqrtPriceMath.getAmount1Delta(sqrtAnchorX96, sqrtEndX96, minLiquidity, true);
        if (quoteAmount >= required) return (sqrtEndX96, true);
        bool down = sqrtEndX96 < sqrtAnchorX96;
        next = quoteIsCurrency0
            ? SqrtPriceMath.getNextSqrtPriceFromAmount0RoundingUp(sqrtAnchorX96, minLiquidity, quoteAmount, down)
            : SqrtPriceMath.getNextSqrtPriceFromAmount1RoundingDown(sqrtAnchorX96, minLiquidity, quoteAmount, !down);
        // One-wei rounding cannot carry the anchor past the end price.
        if (down ? next < sqrtEndX96 : next > sqrtEndX96) next = sqrtEndX96;
    }
}
