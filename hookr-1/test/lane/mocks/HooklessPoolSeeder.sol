// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {HookrSettlement} from "../../../src/libraries/HookrSettlement.sol";

/// @title HooklessPoolSeeder
/// @notice Test utility. Initializes a hookless v4 reference pool and adds liquidity to it from the caller, so the
///         two-venue executor has a second venue to arbitrage against. Refuses hooked keys. Positions are held by this
///         contract and are not withdrawable: rehearsal liquidity only.
contract HooklessPoolSeeder is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;
    address private _payer;

    error HookedPool();
    error InvalidCallback();

    constructor(IPoolManager _manager) {
        poolManager = _manager;
    }

    /// @notice Initializes `key` at `sqrtPriceX96` if needed and adds `liquidity` over the range, paid by the caller.
    /// @dev ERC-20 sides are pulled with transferFrom; the native side comes from `msg.value`, remainder refunded.
    function seed(PoolKey calldata key, uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint128 liquidity)
        external
        payable
    {
        if (address(key.hooks) != address(0)) revert HookedPool();
        (uint160 price,,,) = poolManager.getSlot0(key.toId());
        if (price == 0) poolManager.initialize(key, sqrtPriceX96);
        _payer = msg.sender;
        poolManager.unlock(abi.encode(key, tickLower, tickUpper, liquidity));
        _payer = address(0);
        if (address(this).balance != 0) {
            HookrSettlement.send(Currency.wrap(address(0)), msg.sender, address(this).balance);
        }
    }

    /// @notice Adds the requested liquidity and pays for it.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || _payer == address(0)) revert InvalidCallback();
        (PoolKey memory key, int24 lower, int24 upper, uint128 liquidity) =
            abi.decode(data, (PoolKey, int24, int24, uint128));
        (BalanceDelta delta,) =
            poolManager.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, int256(uint256(liquidity)), 0), "");
        _pay(key.currency0, delta.amount0());
        _pay(key.currency1, delta.amount1());
        return "";
    }

    function _pay(Currency currency, int128 amount) private {
        if (amount >= 0) return;
        address from = Currency.unwrap(currency) == address(0) ? address(this) : _payer;
        HookrSettlement.pay(poolManager, currency, from, uint256(uint128(-amount)));
    }

    receive() external payable {}
}
