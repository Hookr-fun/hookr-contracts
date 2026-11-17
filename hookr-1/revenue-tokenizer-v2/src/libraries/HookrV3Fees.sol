// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";

/// @title Hookr v3 fees
/// @notice What a Uniswap v3 NonfungiblePositionManager `collect` would pay a position now, one side at a time: the
///         fees already owed to it plus its liquidity times the fee growth inside its range since its last snapshot.
/// @dev The math of Uniswap v3-core's `Tick.getFeeGrowthInside` and v3-periphery's `PositionValue.fees`, by Uniswap
///      Labs, restated for this compiler: fee growth is a Q128.128 accumulator that wraps, so every subtraction is
///      unchecked, as v3 does it. The manager's `collect` pokes the pool first, which brings the position's snapshot
///      to the same fee growth inside, so the two figures match to the wei.
library HookrV3Fees {
    /// @notice The fee growth per unit of liquidity inside `[tickLower, tickUpper)` for one side, with the pool's
    ///         current tick, its global fee growth and each bound's fee growth outside.
    function feeGrowthInside(
        int24 tickLower,
        int24 tickUpper,
        int24 tickCurrent,
        uint256 feeGrowthGlobalX128,
        uint256 lowerOutsideX128,
        uint256 upperOutsideX128
    ) internal pure returns (uint256 insideX128) {
        unchecked {
            uint256 below = tickCurrent >= tickLower ? lowerOutsideX128 : feeGrowthGlobalX128 - lowerOutsideX128;
            uint256 above = tickCurrent < tickUpper ? upperOutsideX128 : feeGrowthGlobalX128 - upperOutsideX128;
            insideX128 = feeGrowthGlobalX128 - below - above;
        }
    }

    /// @notice What a collection pays for one side: `tokensOwed` plus `liquidity` times the growth inside since
    ///         `insideLastX128`, floored.
    function owed(uint128 liquidity, uint256 insideX128, uint256 insideLastX128, uint128 tokensOwed)
        internal
        pure
        returns (uint256)
    {
        uint256 delta;
        unchecked {
            delta = insideX128 - insideLastX128;
        }
        return FullMath.mulDiv(delta, liquidity, FixedPoint128.Q128) + tokensOwed;
    }
}
