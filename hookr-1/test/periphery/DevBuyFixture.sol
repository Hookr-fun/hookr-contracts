// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRules} from "../../src/interfaces/IHookrRules.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {PeripheryFixture} from "./PeripheryFixture.sol";
import {ModuleErrors} from "../utils/ModuleErrors.sol";
import {IHookrRootState} from "../../src/interfaces/IHookrRootState.sol";
import {IHookrRulesState} from "../../src/interfaces/IHookrRulesState.sol";

/// @notice Launches with a dev buy: new-token families whose members open at price 1 (tick 0) with their band on the
///         subject's side of that price, so the band holds only subject and a buy walks straight into it. Members are
///         guarded for 100 parent blocks with a 50% Snipe and a per-block buy cap, on PeripheryFixture's rules
///         (base 0.3%, Auto Burn 1%, LP Rewards 2%, royalty 5% of their net, 25% protocol share).
abstract contract DevBuyFixture is PeripheryFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant SUPPLY = 1e24;
    uint128 internal constant CAP = 1e23;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    bytes32 internal constant SWAP_TOPIC = IPoolManager.Swap.selector;
    bytes32 internal constant HOOK_FEE_TOPIC = IHookrRootState.HookFee.selector;
    bytes32 internal constant DEV_BUY_TOPIC = IHookrLauncher.DevBuyExecuted.selector;
    uint256 internal nextSalt = 1;

    /// @dev A new token of SUPPLY, its salt picked so the subject sorts before `quote` when `subjectFirst` (any
    ///      order against the native quote, which always sorts first).
    function _newToken(Currency quote, bool subjectFirst)
        internal
        returns (IHookrLauncher.Token memory t, address subject)
    {
        t = IHookrLauncher.Token(address(0), "Dev", "DEV", SUPPLY, bytes32(0));
        for (;;) {
            t.salt = bytes32(nextSalt++);
            subject = launcher.predictToken(address(this), t);
            if (Currency.unwrap(quote) == address(0) || (subject < Currency.unwrap(quote)) == subjectFirst) {
                return (t, subject);
            }
        }
    }

    /// @dev A guarded member of `subject`'s family opening at price 1 whose band, [0, 60,000] when the subject is
    ///      currency0 and [-60,000, 0] when it is currency1, holds 99.9% of `amount` in subject and no quote.
    function _devMember(address subject, Currency quote, uint256 amount)
        internal
        view
        returns (IHookrLauncher.Member memory m)
    {
        return _devMemberAt(subject, quote, amount, 0, 60_000);
    }

    /// @dev `_devMember` opening at `tick`, a multiple of 60, with a band `width` ticks wide on the subject's side.
    function _devMemberAt(address subject, Currency quote, uint256 amount, int24 tick, int24 width)
        internal
        view
        returns (IHookrLauncher.Member memory m)
    {
        m = _member(quote);
        bool subjectIs0 = uint160(subject) < uint160(Currency.unwrap(quote));
        m.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        m.tickLower = subjectIs0 ? tick : tick - width;
        m.tickUpper = subjectIs0 ? tick + width : tick;
        uint160 lower = TickMath.getSqrtPriceAtTick(m.tickLower);
        uint160 upper = TickMath.getSqrtPriceAtTick(m.tickUpper);
        uint128 liquidity = subjectIs0
            ? LiquidityAmounts.getLiquidityForAmount0(lower, upper, amount)
            : LiquidityAmounts.getLiquidityForAmount1(lower, upper, amount);
        m.liquidity = liquidity / 1000 * 999;
        m.amount0Max = subjectIs0 ? uint128(amount) : 0;
        m.amount1Max = subjectIs0 ? 0 : uint128(amount);
        m.rules.guardEndBlock = uint40(vm.getBlockNumber() + 100);
        m.rules.snipeTaxPips = 500_000;
        m.rules.maxBuyQuoteAmount = CAP;
    }

    /// @dev One member holding the whole supply.
    function _one(address subject, Currency quote) internal view returns (IHookrLauncher.Member[] memory members) {
        members = new IHookrLauncher.Member[](1);
        members[0] = _devMember(subject, quote, SUPPLY);
    }

    /// @dev The native value a launch needs: the native member's quote budget, plus the dev buy on it.
    function _value(IHookrLauncher.Member[] memory members, IHookrLauncher.DevBuy memory buy)
        internal
        pure
        returns (uint256 value)
    {
        for (uint256 i; i < members.length; ++i) {
            if (Currency.unwrap(members[i].quote) != address(0)) continue;
            // The native quote is always currency0.
            value = members[i].amount0Max;
            if (buy.member == i) value += buy.quoteIn;
        }
    }

    function _launchWithBuy(
        IHookrLauncher.Token memory t,
        IHookrLauncher.Member[] memory members,
        IHookrLauncher.DevBuy memory buy
    ) internal returns (bytes32 family, address subject, uint256 out) {
        (family, subject, out) = launcher.launchWithBuy{value: _value(members, buy)}(
            t, address(root), members, new bytes[](members.length), buy, vm.getBlockTimestamp()
        );
    }

    /// @dev The PoolManager's wrapping of a revert `inner` raised by the root in `hookSelector`.
    function _hookError(bytes4 hookSelector, bytes memory inner) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(root),
            hookSelector,
            inner,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// @dev A buy refused by the member's guard cap, from the outcome of its call: the Rules revert
    ///      GuardBuyLimit(spent, limit) in settleSwap, which the root carries in ModuleCallReverted from afterSwap and
    ///      the PoolManager wraps. Asserts that shape and spent above limit, and returns both.
    function _capRefusal(bool ok, bytes memory ret) internal view returns (uint256 spent, uint256 limit) {
        assertFalse(ok, "the buy is refused");
        (bool wrapped, address hook, bytes4 callback, bytes memory inner) = ModuleErrors.unwrap(ret);
        assertTrue(wrapped, "a hook refusal");
        assertEq(hook, address(root), "the root's");
        assertEq(callback, IHooks.afterSwap.selector, "in afterSwap");
        (bool found, address module, bytes4 selector, bytes memory reason) = ModuleErrors.reverted(inner);
        assertTrue(found, "ModuleCallReverted");
        assertEq(module, address(rules), "the member's Rules");
        assertEq(selector, IHookrRules.settleSwap.selector, "settleSwap");
        assertEq(bytes4(reason), IHookrRulesState.GuardBuyLimit.selector, "GuardBuyLimit");
        (spent, limit) = abi.decode(ModuleErrors.body(reason), (uint256, uint256));
        assertGt(spent, limit, "above the cap");
    }

    /// @dev A router buy `s` of `value` native by `who`, refused by the member's guard cap (`_capRefusal`).
    function _capRefused(address who, IHookrRouter.Swap memory s, uint256 value)
        internal
        returns (uint256 spent, uint256 limit)
    {
        vm.prank(who);
        (bool ok, bytes memory ret) =
            address(router).call{value: value}(abi.encodeCall(IHookrRouter.swap, (s, address(0), new uint256[](0))));
        return _capRefusal(ok, ret);
    }

    /// @dev The DevBuyExecuted logs in `logs`, and the index of the first.
    function _devBuyLogs(Vm.Log[] memory logs) internal view returns (uint256 count, uint256 first) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(launcher) && logs[i].topics[0] == DEV_BUY_TOPIC) {
                if (count == 0) first = i;
                ++count;
            }
        }
    }

    /// @dev The PoolManager Swap logs sent by `sender` in `logs`.
    function _swapsFrom(Vm.Log[] memory logs, address sender) internal view returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC
                    && address(uint160(uint256(logs[i].topics[2]))) == sender
            ) ++count;
        }
    }

    /// @dev The member's pool id.
    function _id(bytes32 family, uint8 member) internal view returns (PoolId) {
        return launcher.position(family, member).key.toId();
    }

    function _price(bytes32 family, uint8 member) internal view returns (uint160 price) {
        (price,,,) = manager.getSlot0(_id(family, member));
    }
}
