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
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {FixedAdvice} from "../utils/FixedAdvice.sol";

/// An exact-output sell carries its Rules and advisory quote takes like an exact-input sell: the Root reserves them
/// on top of the requested output, the seller still receives exactly that output, and each module is attributed
/// its own share.
/// Audit finding I-02.
contract ExactOutSellAdvisoryAttributionTest is RootSecurityBase {
    function setUp() public {
        _setUpRootSecurity();
    }

    function _wrapped(bytes4 callback, bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(root),
            callback,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _advisory(bool failOpen, HookrTypes.Advice memory before_) internal returns (FixedAdvice a) {
        a = new FixedAdvice(before_, HookrTypes.Advice(0, 0, address(0), false), failOpen, false);
        IHookrRegistry.Admission memory ad = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: address(a),
            codeHash: address(a).codehash,
            schemaHash: a.configSchemaHash(),
            caps: HookrTypes.Caps(10_000, failOpen ? 0 : 20_000, 0),
            gasLimit: 2_000_000,
            phaseMask: 3,
            feeOnly: failOpen,
            failOpen: failOpen
        });
        registry.queue(registry.ADMIT(), abi.encode(address(root), ad));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), ad);
    }

    function _openAdvised(address rulesModule, FixedAdvice a, bool failOpen, uint8 phases)
        internal
        returns (PoolKey memory key)
    {
        HookrTypes.PoolConfig memory pc = _config(rulesModule);
        pc.advisory = address(a);
        pc.advisoryGasLimit = 2_000_000;
        pc.advisoryPhases = phases;
        pc.advisoryFailOpen = failOpen;
        key = _key(60);
        root.initializePool(
            key, pc, rulesModule == address(rules) ? abi.encode(_rulesConfig()) : bytes("m"), bytes(""), SQRT_ONE
        );
    }

    function testExactOutSellCarriesRulesAndAdvisoryTakes() public {
        FixedAdvice a = _advisory(false, HookrTypes.Advice(0, 1000, address(0xabc), false));
        PoolKey memory key = _openAdvised(address(mock), a, false, 1);
        _addLiquidity(key, -600, 600, 1e22);
        mock.setQuotes(HookrTypes.FeeQuote(0, 0, 0), HookrTypes.FeeQuote(0, 3000, 0));
        Currency quote = Currency.wrap(address(tokenB));
        uint256 claimsBefore = manager.balanceOf(address(mock), quote.toId());
        uint256 quoteBefore = tokenB.balanceOf(address(this));
        uint256 out = 1e18;
        _genericSwap(key, false, int256(out), 0);
        uint256 reserved = (out * 4000 + (1e6 - 4000) - 1) / (1e6 - 4000);
        assertEq(tokenB.balanceOf(address(this)) - quoteBefore, out, "seller nets exactly the requested output");
        assertEq(manager.balanceOf(address(mock), quote.toId()) - claimsBefore, reserved, "whole take backed");
        (,,, uint256 rulesFee, uint256 advisoryFee,,, address recipient) = mock.lastSettlement();
        assertEq(rulesFee, reserved * 3000 / 4000, "Rules share");
        assertEq(advisoryFee, reserved - rulesFee, "advisory share");
        assertEq(recipient, address(0xabc));
    }

    function testExactOutSellRulesOnlyTakeLeavesNoAdvisoryRemainder() public {
        PoolKey memory key = _open(_config(address(mock)), bytes("m"), 60);
        _addLiquidity(key, -600, 600, 1e22);
        mock.setQuotes(HookrTypes.FeeQuote(0, 0, 0), HookrTypes.FeeQuote(0, 2345, 0));
        _genericSwap(key, false, 123_456_789_012_345, 0);
        (,,, uint256 rulesFee, uint256 advisoryFee,,,) = mock.lastSettlement();
        assertEq(advisoryFee, 0);
        assertEq(rulesFee, (uint256(123_456_789_012_345) * 2345 + (1e6 - 2345) - 1) / (1e6 - 2345));
    }

    function testExactOutSellShortFillReverts() public {
        PoolKey memory key = _open(_config(address(mock)), bytes("m"), 60);
        _addLiquidity(key, -600, 600, 1e22);
        mock.setQuotes(HookrTypes.FeeQuote(0, 0, 0), HookrTypes.FeeQuote(0, 3000, 0));
        // A price limit one tick away cannot fill the requested output plus its reserved take.
        bool zeroForOne = !_isBuyZeroForOne(key);
        uint160 limit = zeroForOne ? SQRT_ONE - SQRT_ONE / 20_000 : SQRT_ONE + SQRT_ONE / 20_000;
        vm.expectRevert();
        _genericSwap(key, false, 1e21, limit);
    }
}
