// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

/// @title MatchMath
/// @notice Full-range liquidity from one side of a pool, and the exact amounts a mint of that liquidity pulls.
/// @dev `sqrtP` is the pool's price, `sqrtA` and `sqrtB` the sqrt prices of the lowest and highest usable tick, with
///      sqrtA < sqrtP < sqrtB. Amounts use Uniswap v4's own SqrtPriceMath with its rounding for an added position (up),
///      so they equal what the PoolManager charges for the mint.
library MatchMath {
    /// @notice The most liquidity `amount0` of currency0 funds at `sqrtP` (rounded down).
    function liquidityForAmount0(uint160 sqrtP, uint160 sqrtB, uint256 amount0) internal pure returns (uint256) {
        return FullMath.mulDiv(amount0, FullMath.mulDiv(sqrtP, sqrtB, FixedPoint96.Q96), sqrtB - sqrtP);
    }

    /// @notice The most liquidity `amount1` of currency1 funds at `sqrtP` (rounded down).
    function liquidityForAmount1(uint160 sqrtA, uint160 sqrtP, uint256 amount1) internal pure returns (uint256) {
        return FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtP - sqrtA);
    }

    /// @notice The currency0 and currency1 a mint of `liquidity` over the full range pulls at `sqrtP` (rounded up).
    function amountsForLiquidity(uint160 sqrtP, uint160 sqrtA, uint160 sqrtB, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        amount0 = SqrtPriceMath.getAmount0Delta(sqrtP, sqrtB, liquidity, true);
        amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtP, liquidity, true);
    }

    /// @notice The absolute difference of two ticks.
    function tickDistance(int24 a, int24 b) internal pure returns (uint256) {
        return a > b ? uint256(int256(a) - int256(b)) : uint256(int256(b) - int256(a));
    }
}
