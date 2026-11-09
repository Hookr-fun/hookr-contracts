// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Exact upward rounding on price (sqrt price squared), never on sqrt price itself.
library HookrSandwichMath {
    uint256 internal constant PIPS = 1_000_000;
    error InvalidSandwichPrice();
    error InvalidSandwichCap();

    /// @dev Charge only a swap that moves toward the window's opening price. Input price orientation cancels:
    /// zeroForOne lowers the sqrt price and oneForZero raises it, regardless of which currency is the quote.
    function charge(uint160 current, uint160 opening, bool zeroForOne, uint8 mostPercent) internal pure returns (uint24) {
        if (mostPercent < 5 || mostPercent > 15) revert InvalidSandwichCap();
        if (current < TickMath.MIN_SQRT_PRICE || opening < TickMath.MIN_SQRT_PRICE ||
            current >= TickMath.MAX_SQRT_PRICE || opening >= TickMath.MAX_SQRT_PRICE) revert InvalidSandwichPrice();
        if (zeroForOne ? current <= opening : current >= opening) return 0;
        uint160 small = current < opening ? current : opening;
        uint160 large = current > opening ? current : opening;
        uint256 pips = PIPS - floorPriceRatio(small, large);
        uint256 cap = uint256(mostPercent) * 10_000;
        return uint24(pips < cap ? pips : cap);
    }

    /// @dev floor(PIPS * small^2 / large^2), valid for v4 sqrt prices with small<=large.
    /// A first division loses <1 sqrt unit. Since large>=MIN_SQRT_PRICE>PIPS, the resulting pip error is <1;
    /// the estimate is therefore exact or one low. One exact 512-bit product comparison corrects that last pip.
    function floorPriceRatio(uint160 small, uint160 large) internal pure returns (uint256 ratio) {
        if (small < TickMath.MIN_SQRT_PRICE || small > large || large >= TickMath.MAX_SQRT_PRICE) revert InvalidSandwichPrice();
        ratio = FullMath.mulDiv(FullMath.mulDiv(small, small, large), PIPS, large);
        if (ratio == PIPS) return ratio;
        (uint256 rightHigh, uint256 rightLow) = _squareTimes(small, PIPS);
        (uint256 leftHigh, uint256 leftLow) = _squareTimes(large, ratio + 1);
        if (leftHigh < rightHigh || (leftHigh == rightHigh && leftLow <= rightLow)) ++ratio;
    }

    /// @dev A uint160 square needs at most 320 bits; multiplying by at most PIPS needs at most 340. The upper
    /// product therefore fits one uint256 word. The low-word carry comes from the standard mulmod identity.
    function _squareTimes(uint160 value, uint256 multiplier) private pure returns (uint256 high, uint256 low) {
        assembly ("memory-safe") {
            value := and(value, sub(shl(160, 1), 1))
            let squareLow := mul(value, value)
            let mm := mulmod(value, value, not(0))
            let squareHigh := sub(sub(mm, squareLow), lt(mm, squareLow))
            low := mul(squareLow, multiplier)
            let scaledMm := mulmod(squareLow, multiplier, not(0))
            let carry := sub(sub(scaledMm, low), lt(scaledMm, low))
            high := add(mul(squareHigh, multiplier), carry)
        }
    }
}
