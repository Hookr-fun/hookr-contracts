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

/// Old numbers: 1.809e24 credited to the router contract, 0 to the trader.
/// Audit finding L-09.
contract GenericRefundStrandingTest is RootSecurityBase {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    function setUp() public {
        _setUpRootSecurity();
    }

    function testGenericPartialFillWithRefundReverts() public {
        PoolKey memory key = _open(_config(address(rules)), abi.encode(_rulesConfig()), 60);
        _addLiquidity(key, -600, 600, 1e22);
        bool zeroForOne = _isBuyZeroForOne(key);
        uint160 limit =
            zeroForOne ? uint160(uint256(SQRT_ONE) * 9990 / 10_000) : uint160(uint256(SQRT_ONE) * 10_010 / 10_000);
        vm.expectRevert();
        _genericSwap(key, true, -1e24, limit);
    }

    function testGenericFullFillLeavesNoRefund() public {
        PoolKey memory key = _open(_config(address(rules)), abi.encode(_rulesConfig()), 60);
        _addLiquidity(key, -600, 600, 1e22);
        _genericSwap(key, true, -1e18, 0);
        assertEq(rules.claimable(Currency.wrap(address(tokenB)), address(generic)), 0);
        assertTrue(rules.accountingInvariant(Currency.wrap(address(tokenB))));
    }
}
