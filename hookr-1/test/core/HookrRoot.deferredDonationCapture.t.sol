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

/// Old numbers: 7,401.17e18 of deferred rewards stolen for 2 wei; 55,256.30e18 at lpBps 1000.
/// Audit finding M-03.
contract DeferredDonationCaptureTest is RootSecurityBase {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    function setUp() public {
        _setUpRootSecurity();
    }

    function testPendingDonationViewIsGone() public view {
        (bool ok,) = address(root).staticcall(abi.encodeWithSignature("pendingDonation(bytes32)", bytes32(0)));
        assertFalse(ok);
    }

    function testRangeExhaustingBuyLeavesNothingToCapture() public {
        HookrTypes.RulesConfig memory c = _rulesConfig();
        c.lpBps = 1000 - c.burnBps;
        PoolKey memory key = _open(_config(address(rules)), abi.encode(c), 60);
        _addLiquidity(key, -600, 600, 1e21);
        IHookrRouter.Swap memory p = _swap(key, true, true, 1e24);
        p.sqrtPriceLimitX96 = p.zeroForOne ? uint160(uint256(SQRT_ONE) / 2) : uint160(uint256(SQRT_ONE) * 2);
        vm.prank(trader);
        router.swap(p, address(0), new uint256[](0));
        Currency quote = Currency.wrap(address(tokenB));
        assertEq(manager.balanceOf(address(root), quote.toId()), 0);
        _addLiquidity(key, 6000, 6060, 1e6);
        _genericSwap(key, true, -2, 0);
        assertEq(manager.balanceOf(address(root), quote.toId()), 0);
        assertTrue(rules.accountingInvariant(quote));
    }
}
