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

import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

/// Pins OD-5 (keep take to 0xdead). Old behaviour: only exact-in buys halted. Now every buy burns, so every buy halts.
/// Audit finding I-03.
contract BurnSinkIssuerTest is RootSecurityBase {
    function setUp() public {
        _setUpRootSecurity();
    }

    function testBlockedDeadHaltsAllBuysNotSells() public {
        PoolKey memory key = _open(_config(address(mock)), bytes("m"), 60);
        _addLiquidity(key, -600, 600, 1e22);
        mock.setQuotes(HookrTypes.FeeQuote(0, 10_000, 75), HookrTypes.FeeQuote(0, 0, 0));
        vm.mockCallRevert(
            address(tokenA), abi.encodeWithSelector(IERC20Minimal.transfer.selector, root.DEAD()), bytes("blocked")
        );
        vm.expectRevert();
        _genericSwap(key, true, -1e18, 0);
        vm.expectRevert();
        _genericSwap(key, true, 1e18, 0);
        _genericSwap(key, false, -1e18, 0);
        vm.clearMockedCalls();
        _genericSwap(key, true, -1e18, 0);
        _genericSwap(key, true, 1e18, 0);
    }
}
