// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @dev Direct PoolManager LP used as the fairness oracle: it holds the same liquidity in the same range at the same
///      times as a vault holder, so its collected fees are what that holder should earn.
contract ReferenceLP is IUnlockCallback {
    IPoolManager internal immutable m;

    constructor(IPoolManager _m) {
        m = _m;
    }

    /// @return principal0 Principal delta for currency0 (positive: received).
    /// @return principal1 Principal delta for currency1.
    /// @return fees0 Fees collected in currency0.
    /// @return fees1 Fees collected in currency1.
    function modify(PoolKey memory key, int24 lo, int24 hi, int256 liquidity)
        external
        returns (int256 principal0, int256 principal1, uint256 fees0, uint256 fees1)
    {
        return abi.decode(m.unlock(abi.encode(key, lo, hi, liquidity)), (int256, int256, uint256, uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, int24 lo, int24 hi, int256 liquidity) = abi.decode(data, (PoolKey, int24, int24, int256));
        (BalanceDelta d, BalanceDelta f) = m.modifyLiquidity(key, ModifyLiquidityParams(lo, hi, liquidity, 0), "");
        _settle(key.currency0, d.amount0());
        _settle(key.currency1, d.amount1());
        return abi.encode(
            int256(d.amount0()) - f.amount0(),
            int256(d.amount1()) - f.amount1(),
            uint256(uint128(f.amount0())),
            uint256(uint128(f.amount1()))
        );
    }

    function _settle(Currency c, int128 amount) internal {
        if (amount > 0) {
            m.take(c, address(this), uint256(uint128(amount)));
        } else if (amount < 0) {
            uint256 a = uint256(uint128(-amount));
            if (Currency.unwrap(c) == address(0)) {
                m.settle{value: a}();
            } else {
                m.sync(c);
                IERC20(Currency.unwrap(c)).transfer(address(m), a);
                m.settle();
            }
        }
    }

    receive() external payable {}
}
