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
import {HookrRouter} from "../../src/periphery/HookrRouter.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";

/// Old numbers: a rulesGasLimit inside the 173,345-187,533 window could starve settleSwap.
/// Audit finding I-01.
contract RulesGasLimitPinTest is RootSecurityBase {
    function setUp() public {
        _setUpRootSecurity();
    }

    function testRulesGasLimitMustEqualAdmission() public {
        HookrTypes.PoolConfig memory pc = _config(address(rules));
        pc.rulesGasLimit = 180_439;
        PoolKey memory key = _key(60);
        vm.expectRevert(IHookrRootEvents.InvalidConfig.selector);
        root.initializePool(key, pc, abi.encode(_rulesConfig()), bytes(""), SQRT_ONE);
        pc.rulesGasLimit = 2_000_000;
        root.initializePool(key, pc, abi.encode(_rulesConfig()), bytes(""), SQRT_ONE);
    }
}
