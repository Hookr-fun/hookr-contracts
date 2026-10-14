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
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";

/// Old numbers: end-tick JIT recaptured 999,900 ppm of the LP Reward; trader cost cut 142 / 999 bps.
/// Root side: no donate() and no Root-held quote. The LP Reward itself moves into the LP fee in PART A.
/// Audit finding M-02.
contract LpRewardJitRecaptureTest is RootSecurityBase {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    bytes32 private constant DONATE = keccak256("Donate(bytes32,address,uint256,uint256)");

    function setUp() public {
        _setUpRootSecurity();
    }

    function testBuysNeverDonateOrHoldQuote() public {
        (, PoolKey memory key,, Currency quote) = _launch(true, false);
        IHookrRouter.Swap memory exactIn = _swap(key, true, true, 1e21);
        IHookrRouter.Swap memory exactOut = _swap(key, true, false, 1e19);
        vm.recordLogs();
        vm.startPrank(trader);
        router.swap(exactIn, address(0), new uint256[](0));
        router.swap(exactOut, address(0), new uint256[](0));
        vm.stopPrank();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertFalse(logs[i].emitter == address(manager) && logs[i].topics[0] == DONATE);
        }
        assertEq(manager.balanceOf(address(root), quote.toId()), 0);
        assertEq(manager.balanceOf(address(root), Currency.wrap(address(tokenA)).toId()), 0);
    }
}
