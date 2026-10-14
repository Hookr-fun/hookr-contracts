// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {RootSecurityBase} from "../utils/RootSecurityBase.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";

/// @notice The root mints exactly the quote it takes to the Rules and requires the Rules to credit exactly that: a Rules
///         that credits more or less is refused, whichever way it is off. Mutation gate RT-5 (the check read
///         `credited < quoteTaken`, which let a Rules credit claims the root never minted).
contract RootModuleCreditTest is RootSecurityBase {
    function setUp() public {
        _setUpRootSecurity();
    }

    function _pool() internal returns (PoolKey memory key) {
        key = _open(_config(address(mock)), bytes("m"), 60);
        _addLiquidity(key, -600, 600, 1e22);
        mock.setQuotes(HookrTypes.FeeQuote(0, 3000, 0), HookrTypes.FeeQuote(0, 3000, 0));
    }

    function _refused() internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(root),
            IHooks.afterSwap.selector,
            abi.encodeWithSelector(IHookrRootEvents.InvalidModuleResult.selector, address(mock)),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function test_creditEqualToTheTakeSettles() public {
        PoolKey memory key = _pool();
        uint256 claimsBefore = manager.balanceOf(address(mock), Currency.wrap(address(tokenB)).toId());
        _genericSwap(key, true, -1e18, 0);
        assertGt(
            manager.balanceOf(address(mock), Currency.wrap(address(tokenB)).toId()), claimsBefore, "a take was minted"
        );
    }

    function test_creditAboveTheTakeIsRefused() public {
        PoolKey memory key = _pool();
        mock.setCreditSkew(1);
        vm.expectRevert(_refused());
        _genericSwap(key, true, -1e18, 0);
        vm.expectRevert(_refused());
        _genericSwap(key, false, -1e18, 0);
    }

    function test_creditBelowTheTakeIsRefused() public {
        PoolKey memory key = _pool();
        mock.setCreditSkew(-1);
        vm.expectRevert(_refused());
        _genericSwap(key, true, -1e18, 0);
        vm.expectRevert(_refused());
        _genericSwap(key, false, -1e18, 0);
    }
}
