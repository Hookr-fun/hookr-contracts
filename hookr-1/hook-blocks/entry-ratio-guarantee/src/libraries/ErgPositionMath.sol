// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

/// @title Entry Ratio Guarantee position math
/// @notice Read-only mirrors of the PoolManager's own liquidity arithmetic (v4-core `Pool.modifyLiquidity` and
///         `Position.update` at 46c68346), used to check a deposit's entry amounts and to preview an exit.
/// @dev The branch on the pool's current tick, not its sqrt price, matches `Pool.modifyLiquidity` exactly.
library ErgPositionMath {
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;

    /// @notice Amounts the PoolManager charges to add `liquidity` (rounded up), as `Pool.modifyLiquidity` does.
    /// @param tick The pool's current tick
    /// @param sqrtPriceX96 The pool's current sqrt price
    /// @param tickLower Lower tick of the position
    /// @param tickUpper Upper tick of the position
    /// @param liquidity Liquidity added
    /// @return amount0 currency0 owed by the depositor
    /// @return amount1 currency1 owed by the depositor
    function amountsForAdd(int24 tick, uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        return _amounts(tick, sqrtPriceX96, tickLower, tickUpper, liquidity, true);
    }

    /// @notice Principal the PoolManager releases when `liquidity` is removed (rounded down).
    /// @param tick The pool's current tick
    /// @param sqrtPriceX96 The pool's current sqrt price
    /// @param tickLower Lower tick of the position
    /// @param tickUpper Upper tick of the position
    /// @param liquidity Liquidity removed
    /// @return amount0 currency0 released
    /// @return amount1 currency1 released
    function amountsForRemoval(int24 tick, uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        return _amounts(tick, sqrtPriceX96, tickLower, tickUpper, liquidity, false);
    }

    /// @notice Fees a PoolManager position has accrued since it was last touched, as `Position.update` computes them.
    /// @param manager The PoolManager
    /// @param id The pool id
    /// @param owner The position owner (the vault)
    /// @param tickLower Lower tick
    /// @param tickUpper Upper tick
    /// @param salt The position salt
    /// @return fees0 currency0 fees
    /// @return fees1 currency1 fees
    function feesOwed(IPoolManager manager, PoolId id, address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        view
        returns (uint256 fees0, uint256 fees1)
    {
        (uint128 liquidity, uint256 last0, uint256 last1) =
            manager.getPositionInfo(id, owner, tickLower, tickUpper, salt);
        (uint256 inside0, uint256 inside1) = manager.getFeeGrowthInside(id, tickLower, tickUpper);
        unchecked {
            fees0 = FullMath.mulDiv(inside0 - last0, liquidity, FixedPoint128.Q128);
            fees1 = FullMath.mulDiv(inside1 - last1, liquidity, FixedPoint128.Q128);
        }
    }

    /// @notice The largest liquidity `amount0` and `amount1` can fund on `[tickLower, tickUpper)` at `sqrtPriceX96`.
    /// @dev A convenience for callers; the vault charges whatever the PoolManager charges for the liquidity asked.
    /// @param sqrtPriceX96 The pool's current sqrt price
    /// @param tickLower Lower tick
    /// @param tickUpper Upper tick
    /// @param amount0 Available currency0
    /// @param amount1 Available currency1
    /// @return liquidity The liquidity, reverting if it does not fit uint128
    function liquidityForAmounts(
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);
        if (sqrtPriceX96 <= sqrtA) {
            return _liquidity0(sqrtA, sqrtB, amount0);
        } else if (sqrtPriceX96 < sqrtB) {
            uint128 l0 = _liquidity0(sqrtPriceX96, sqrtB, amount0);
            uint128 l1 = _liquidity1(sqrtA, sqrtPriceX96, amount1);
            return l0 < l1 ? l0 : l1;
        }
        return _liquidity1(sqrtA, sqrtB, amount1);
    }

    function _amounts(
        int24 tick,
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        bool roundUp
    ) private pure returns (uint256 amount0, uint256 amount1) {
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);
        if (tick < tickLower) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liquidity, roundUp);
        } else if (tick < tickUpper) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtB, liquidity, roundUp);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtPriceX96, liquidity, roundUp);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liquidity, roundUp);
        }
    }

    function _liquidity0(uint160 sqrtA, uint160 sqrtB, uint256 amount0) private pure returns (uint128) {
        uint256 intermediate = FullMath.mulDiv(sqrtA, sqrtB, FixedPoint96.Q96);
        return FullMath.mulDiv(amount0, intermediate, sqrtB - sqrtA).toUint128();
    }

    function _liquidity1(uint160 sqrtA, uint160 sqrtB, uint256 amount1) private pure returns (uint128) {
        return FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtB - sqrtA).toUint128();
    }
}
