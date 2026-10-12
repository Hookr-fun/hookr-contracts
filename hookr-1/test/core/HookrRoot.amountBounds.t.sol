// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {RootSecurityBase} from "../utils/RootSecurityBase.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRootState} from "../../src/interfaces/IHookrRootState.sol";

/// @notice The root takes any swap amount up to and including int128.max and refuses what is above or zero: the
///         amount is a magnitude that must fit the int128 the PoolManager's deltas carry. Mutation gate RT-11 (the
///         bound read `>=`, refusing exactly int128.max).
contract RootAmountBoundsTest is RootSecurityBase {
    function setUp() public {
        _setUpRootSecurity();
    }

    function _pool() internal returns (PoolKey memory key) {
        key = _open(_config(address(mock)), bytes("m"), 60);
        _addLiquidity(key, -600, 600, 1e22);
        mock.setQuotes(HookrTypes.FeeQuote(0, 0, 0), HookrTypes.FeeQuote(0, 0, 0));
    }

    function _outOfRange(bytes4 callback) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(root),
            callback,
            abi.encodeWithSelector(IHookrRootState.AmountOutOfRange.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// An exact-input buy of int128.max fills what the pool holds up to its price limit, as any amount above the pool's
    /// depth does.
    function test_aSwapOfInt128MaxIsTaken() public {
        PoolKey memory key = _pool();
        uint256 before = tokenA.balanceOf(address(this));
        _genericSwap(key, true, -int256(type(int128).max), 0);
        assertGt(tokenA.balanceOf(address(this)), before, "the pool's depth was bought");
    }

    function test_aSwapAboveInt128MaxIsRefused() public {
        PoolKey memory key = _pool();
        vm.expectRevert(_outOfRange(IHooks.beforeSwap.selector));
        _genericSwap(key, true, -(int256(type(int128).max) + 1), 0);
    }
}
