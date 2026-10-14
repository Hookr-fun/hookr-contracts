// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrRouter} from "../../src/periphery/HookrRouter.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {IHookrRules} from "../../src/interfaces/IHookrRules.sol";
import {ModuleErrors} from "../utils/ModuleErrors.sol";
import {PeripheryFixture} from "./PeripheryFixture.sol";
import {DevBuyFixture} from "./DevBuyFixture.sol";
import {Vm} from "forge-std/Vm.sol";
import {IHookrRulesState} from "../../src/interfaces/IHookrRulesState.sol";

/// @notice I-07, documented behaviour. Original PoC (B13Verify testC1, unfixed source): a 2-member family with
/// the tokenB member priced 20% off and a 5% snipe tax let an arbitrageur turn 30,000 tokenB into 31,649.30 ETH
/// (profit 1,649.30 at 1:1); with consistent prices the same round trip lost 4,465.10 (3,188.87 without a guard);
/// mispriced without a guard it gained 3,215.54. Without an oracle the contract has no neutral price to check the
/// creator's input against, so this is documented (NatSpec, README) and left to SDK/app price derivation. Pinned
/// here: consistent prices leak nothing, the value comes only from the creator's own mispricing, and each member
/// keeps its own per-block Anti-Snipe cap, so a family's total cap is the sum of member caps.
contract HookrLauncherCrossMemberPricingTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    function setUp() public {
        _setUpPeriphery();
    }

    function _family(uint256 num, uint256 den, uint24 snipe, uint128 cap, bytes32 salt)
        internal
        returns (bytes32 family, address subject)
    {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _member(Currency.wrap(address(0)));
        members[1] = _member(Currency.wrap(address(tokenB)));
        for (uint256 i; i < 2; ++i) {
            if (snipe != 0) {
                members[i].rules.guardEndBlock = uint40(vm.getBlockNumber() + 100_000);
                members[i].rules.snipeTaxPips = snipe;
                members[i].rules.maxBuyQuoteAmount = cap;
            }
        }
        IHookrLauncher.Token memory token = IHookrLauncher.Token(address(0), "Fam", "FAM", 1e27, salt);
        address predicted = launcher.predictToken(address(this), token);
        bool subjectFirst = predicted < address(tokenB);
        members[1].sqrtPriceX96 =
            subjectFirst ? uint160(uint256(SQRT_ONE) * num / den) : uint160(uint256(SQRT_ONE) * den / num);
        members[1].amount0Max = 2e24;
        members[1].amount1Max = 2e24;
        (family, subject) = launcher.launch{value: 1e24}(token, address(root), members, block.timestamp);
    }

    function _roundTrip(bytes32 family, address subject, bytes32 salt) internal returns (uint256 spend, uint256 out) {
        PoolKey memory k0 = launcher.position(family, 0).key;
        PoolKey memory k1 = launcher.position(family, 1).key;
        address arb = address(uint160(uint256(keccak256(abi.encode(salt)))));
        tokenB.transfer(arb, 1e24);
        vm.startPrank(arb);
        tokenB.approve(address(router), type(uint256).max);
        IERC20(subject).approve(address(router), type(uint256).max);
        vm.stopPrank();
        spend = 3e22;
        IHookrRouter.Swap memory b = _swap(k1, true, true, uint128(spend));
        b.recipient = arb;
        vm.prank(arb);
        router.swap(b, address(0), new uint256[](0));
        IHookrRouter.Swap memory s = _swap(k0, false, true, uint128(IERC20(subject).balanceOf(arb)));
        s.recipient = arb;
        uint256 before = arb.balance;
        vm.prank(arb);
        router.swap(s, address(0), new uint256[](0));
        out = arb.balance - before;
    }

    function testConsistentFamilyLeaksNothingMispricedFamilyPaysForItsOwnPriceError() public {
        uint256 snap = vm.snapshotState();
        (bytes32 family, address subject) = _family(1000, 1000, 50_000, 0, bytes32(uint256(10)));
        (uint256 spend, uint256 out) = _roundTrip(family, subject, bytes32(uint256(10)));
        assertLt(out, spend, "consistent prices: arbitrage loses (was a 4,465.10 loss)");
        vm.revertToState(snap);
        (family, subject) = _family(894, 1000, 50_000, 0, bytes32(uint256(9)));
        (spend, out) = _roundTrip(family, subject, bytes32(uint256(9)));
        assertGt(out, spend, "20% creator mispricing: the creator's liquidity pays (was a 1,649.30 gain)");
    }

    function testAntiSnipeCapIsPerMember() public {
        uint128 cap = 1e20;
        (bytes32 family,) = _family(1000, 1000, 50_000, cap, bytes32(uint256(11)));
        PoolKey memory k0 = launcher.position(family, 0).key;
        PoolKey memory k1 = launcher.position(family, 1).key;
        IHookrRouter.Swap memory b0 = _swap(k0, true, true, cap);
        IHookrRouter.Swap memory b1 = _swap(k1, true, true, cap);
        vm.startPrank(trader);
        router.swap{value: cap}(b0, address(0), new uint256[](0));
        router.swap(b1, address(0), new uint256[](0));
        vm.stopPrank();
        // Both members' full caps were spent in the same parent block: the family cap is their sum.
        IHookrRouter.Swap memory more = _swap(k1, true, true, 1e18);
        vm.prank(trader);
        (bool ok, bytes memory ret) =
            address(router).call(abi.encodeCall(HookrRouter.swap, (more, address(0), new uint256[](0))));
        assertFalse(ok);
        (,,, bytes memory inner) = ModuleErrors.unwrap(ret);
        (bool found, address module, bytes4 selector, bytes memory reason) = ModuleErrors.reverted(inner);
        assertTrue(found && module == address(rules) && selector == IHookrRules.settleSwap.selector, "in settleSwap");
        assertEq(bytes4(reason), IHookrRulesState.GuardBuyLimit.selector, "refused by the member's own GuardBuyLimit");
        (uint256 spent, uint256 limit) = abi.decode(ModuleErrors.body(reason), (uint256, uint256));
        assertEq(limit, cap, "the member's own cap");
        assertGt(spent, cap);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(trader);
        router.swap(more, address(0), new uint256[](0));
    }
}

/// @notice I-07 with a dev buy. Members are priced independently, so a dev buy on the member the creator priced
///         cheapest gets more subject per quote than one on its sibling; that makes a misleading price signal, not a
///         larger holding: the 5% cap still binds. DevBuyExecuted carries the member's launch and post-buy prices so
///         an app can compare them with the siblings' in one unit, and the siblings' prices do not move.
contract HookrLauncherDevBuyCrossMemberPricingTest is DevBuyFixture {
    using PoolIdLibrary for PoolKey;

    function setUp() public {
        _setUpPeriphery();
    }

    /// @dev Two members, ETH at price 1 and tokenB with the subject 20% cheaper, and a dev buy of `quoteIn` on `k`.
    function _family(uint8 k, uint128 quoteIn) internal returns (bytes32 family, uint256 out, uint160 launchPrice) {
        (IHookrLauncher.Token memory t, address subject) = _newToken(Currency.wrap(address(0)), false);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _devMember(subject, Currency.wrap(address(0)), SUPPLY / 2);
        bool subjectFirst = subject < address(tokenB);
        // Subject 20% cheaper in tokenB: currency1 per currency0 is 0.8 when the subject is currency0, 1.25 when not.
        int24 tick = subjectFirst ? int24(-2220) : int24(2220);
        members[1] = _devMemberAt(subject, Currency.wrap(address(tokenB)), SUPPLY / 2, tick, 60_000);
        launchPrice = members[k].sqrtPriceX96;
        vm.recordLogs();
        (family,, out) = _launchWithBuy(t, members, IHookrLauncher.DevBuy(k, quoteIn, 1, 0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(launcher) && logs[i].topics[0] == IHookrLauncher.DevBuyExecuted.selector) {
                (,,, uint160 p0,,) = abi.decode(logs[i].data, (uint8, uint256, uint256, uint160, uint160, uint256));
                assertEq(p0, launchPrice, "the event carries the member's own launch price");
            }
        }
        assertEq(_price(family, 1 - k), members[1 - k].sqrtPriceX96, "the sibling's price does not move");
    }

    function testCheapMemberDevBuyIsASignalNotAHolding() public {
        uint256 snap = vm.snapshotState();
        (, uint256 fair,) = _family(0, 1e22);
        vm.revertToState(snap);
        (, uint256 cheap,) = _family(1, 1e22);
        assertGt(cheap, fair, "more subject per quote on the cheaper member");
        vm.revertToState(snap);
        (IHookrLauncher.Token memory t, address subject) = _newToken(Currency.wrap(address(0)), false);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _devMember(subject, Currency.wrap(address(0)), SUPPLY / 2);
        members[1] = _devMemberAt(
            subject,
            Currency.wrap(address(tokenB)),
            SUPPLY / 2,
            subject < address(tokenB) ? int24(-2220) : int24(2220),
            60_000
        );
        members[1].rules.maxBuyQuoteAmount = 1e24;
        vm.expectPartialRevert(IHookrLauncher.DevBuyAboveCap.selector);
        launcher.launchWithBuy(
            t, address(root), members, new bytes[](2), IHookrLauncher.DevBuy(1, 1e23, 1, 0), vm.getBlockTimestamp()
        );
    }
}
