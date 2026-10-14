// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title LiquidityAdder
/// @notice Adds one liquidity position to a pool whose two currencies are ERC-20s, paid from a payer's balances after
///         an approval. The bench uses it for the hookless twin's position and for the extra positions of the dynamic
///         fee pools. It is setup, never measured.
contract LiquidityAdder is IUnlockCallback {
    /// @notice The PoolManager the positions are added to.
    IPoolManager public immutable manager;

    /// @param manager_ The PoolManager the positions are added to.
    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    /// @notice Adds `liquidity` over [`lower`, `upper`] to `key` for this contract, funded by `payer`.
    function add(PoolKey calldata key, int24 lower, int24 upper, uint256 liquidity, address payer) external {
        manager.unlock(abi.encode(key, lower, upper, liquidity, payer));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager");
        (PoolKey memory key, int24 lower, int24 upper, uint256 liquidity, address payer) =
            abi.decode(data, (PoolKey, int24, int24, uint256, address));
        (BalanceDelta delta,) =
            manager.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, int256(liquidity), bytes32(0)), "");
        _pay(key.currency0, delta.amount0(), payer);
        _pay(key.currency1, delta.amount1(), payer);
        return "";
    }

    /// @dev Settles what the position owes in `currency` from `payer`; a position that is owed nothing pays nothing.
    function _pay(Currency currency, int128 amount, address payer) private {
        if (amount >= 0) return;
        manager.sync(currency);
        IERC20(Currency.unwrap(currency)).transferFrom(payer, address(manager), uint256(int256(-amount)));
        manager.settle();
    }
}
