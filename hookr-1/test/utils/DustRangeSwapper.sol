// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Unauthenticated PoolManager caller: one swap, settles exact deltas.
contract DustRangeSwapper is IUnlockCallback {
    IPoolManager internal immutable m;

    constructor(IPoolManager m_) {
        m = m_;
    }

    function swap(PoolKey memory key, bool zeroForOne, int256 amount, uint160 limit)
        external
        returns (int128 a0, int128 a1)
    {
        (a0, a1) = abi.decode(m.unlock(abi.encode(key, zeroForOne, amount, limit)), (int128, int128));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(m));
        (PoolKey memory key, bool zeroForOne, int256 amount, uint160 limit) =
            abi.decode(data, (PoolKey, bool, int256, uint160));
        BalanceDelta d = m.swap(key, SwapParams(zeroForOne, amount, limit), "");
        _settle(key.currency0, d.amount0());
        _settle(key.currency1, d.amount1());
        return abi.encode(d.amount0(), d.amount1());
    }

    function _settle(Currency c, int128 amount) private {
        if (amount < 0) {
            m.sync(c);
            IERC20(Currency.unwrap(c)).transfer(address(m), uint128(-amount));
            m.settle();
        } else if (amount > 0) {
            m.take(c, address(this), uint128(amount));
        }
    }
}
