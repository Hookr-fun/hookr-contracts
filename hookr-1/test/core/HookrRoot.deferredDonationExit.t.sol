// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {RootSecurityBase, MockRules} from "../utils/RootSecurityBase.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrRouter} from "../../src/periphery/HookrRouter.sol";

/// Old numbers: 2.8485e23 pending captured for 2 wei after the family exited. Pot half is PART A.
/// Audit finding L-11.
contract PotAndDeferredExitTest is RootSecurityBase {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    function setUp() public {
        _setUpRootSecurity();
    }

    function testNoDeferredBalanceAfterFamilyExit() public {
        PoolKey memory key = _open(_config(address(rules)), abi.encode(_rulesConfig()), 60);
        _addLiquidity(key, -600, 600, 1e21);
        _genericSwap(key, true, -1e18, 0);
        _addLiquidity(key, -600, 600, -1e21);
        assertEq(manager.balanceOf(address(root), Currency.wrap(address(tokenB)).toId()), 0);
        assertEq(manager.balanceOf(address(root), Currency.wrap(address(tokenA)).toId()), 0);
    }
}
