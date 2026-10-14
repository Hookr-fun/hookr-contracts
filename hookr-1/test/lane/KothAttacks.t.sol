// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {LaneFixture} from "./LaneFixture.sol";
import {TwoVenueExecutor} from "./mocks/TwoVenueExecutor.sol";
import {ScriptedExecutor} from "./mocks/ScriptedExecutor.sol";
import {Actor} from "./mocks/Actors.sol";
import {IHookrRecaptureEvents} from "../../src/interfaces/IHookrRecaptureEvents.sol";

/// @notice Attack proofs of concept against the pot and the LP leg on a King of the Pool pool of HookrRoot. Each test
///         states the attack, runs it and asserts the defended outcome with the numbers logged.
contract KothAttacksTest is LaneFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    TwoVenueExecutor internal arb;
    PoolKey internal key;
    PoolId internal id;

    function setUp() public {
        _setUpLane();
        arb = _twoVenueExecutor(1e24);
        _openLane(address(arb));
        key = _openKoth(ETH);
        id = key.toId();
        _seedReference(key);
    }

    /// PoC 1, atomic wash. The attacker buys far more than the honest leader and sells it all back in the same
    /// transaction, holding nothing at the epoch's end. Defended: a sell voids every lead taken earlier in the same
    /// transaction and restores the leader.
    function test_poc_atomicWashCannotTakeTheCrown() public {
        _buy(key, ETH, minnow, 5e21);
        Actor a = _newActor(key);
        uint256 ethBefore = address(a).balance;
        IHookrRouter.Swap memory b = _swapParams(key, ETH, true, true, 2e23, address(a));
        IHookrRouter.Swap memory s = _swapParams(key, ETH, false, true, 1, address(a));
        (uint256 spent, uint256 returned) = a.routerRoundTrip(b, 2e23, s);
        (, address leader, uint128 amount,) = _hill(key);
        console.log("attacker buy (wei)          ", spent);
        console.log("attacker sold back for (wei)", returned);
        console.log("attacker round-trip loss    ", ethBefore - address(a).balance);
        assertEq(leader, minnow, "the honest leader keeps the crown");
        assertEq(amount, 5e21);
        assertGt(ethBefore, address(a).balance, "the round trip cost the attacker");
    }

    /// PoC 2, self-JIT. In one transaction the attacker adds 20x the pool's liquidity around the price, buys through
    /// the router (triggering an arb recapture whose LP leg it hopes to collect through its own position), and removes
    /// the liquidity. Defended: a buy whose path crosses liquidity added in the same transaction cannot lead, and the
    /// LP leg is never donated: it accrues to the pool's liquidity owner, the launch position. Control: the same
    /// liquidity standing across transactions may lead, as any LP and buyer may, and does not receive the LP leg.
    function test_poc_selfJitCannotCaptureCrownOrLpLeg() public {
        _buy(key, ETH, minnow, 5e21);
        uint256 snap = vm.snapshotState();
        Actor a = _newActor(key);
        IHookrRouter.Swap memory b = _swapParams(key, ETH, true, true, 5e23, address(a));
        (,,, uint128 potBefore) = _hill(key);
        uint256 accruedBefore = _accrued(key);
        vm.recordLogs();
        a.jitRouterSwap(b, 5e23, -600, 600, 2e25);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Outcome memory o = _outcome(logs);
        Splits memory t = _splits(logs);
        (, address leader,, uint128 pot) = _hill(key);
        uint256 pushed = o.pushedBefore + o.pushedAfter;
        console.log("JIT tx: pushed to the root      ", pushed);
        console.log("JIT tx: LP leg accrued to owner ", t.lp);
        console.log("JIT tx: credited to pot         ", t.pot);
        assertGt(pushed, 0, "the arb recapture ran and paid");
        assertEq(_accrued(key) - accruedBefore, t.lp, "the LP leg accrued to the pool's liquidity owner");
        assertEq(pot - potBefore, t.pot);
        (,, uint256 potB,) = _split(o.profitBefore, o.pushedBefore, false, POT_BPS, TRADER_BPS);
        (,, uint256 potA,) = _split(o.profitAfter, o.pushedAfter, false, POT_BPS, TRADER_BPS);
        assertEq(t.pot, potB + potA, "the pot takes only its own leg");
        assertEq(leader, minnow, "the JIT buyer did not take the crown");

        // Control, from the same starting state: the same position standing across transactions.
        vm.revertToState(snap);
        Actor c = _newActor(key);
        c.modify(key, -600, 600, 2e25);
        c.routerSwap(_swapParams(key, ETH, true, true, 5e23, address(c)), 5e23);
        (, leader,,) = _hill(key);
        assertEq(leader, address(c), "a standing LP that buys may lead");
    }

    /// PoC 3, two-transaction wash against a large pot. The attacker buys in one transaction, takes the crown, sells
    /// everything back in the next, and collects the prize at rollover. The pot (5,000 ETH) exceeds the round trip's
    /// cost, so an uncapped prize would pay. Defended: the prize is capped at maxPrizeBps of the winning buy, at most
    /// half the protocol fee that buy paid.
    function test_poc_twoTransactionWashLosesMoneyUnderTheCap() public {
        ScriptedExecutor exec = new ScriptedExecutor(manager);
        vm.deal(address(exec), 1e30);
        exec.setRoot(address(root));
        _openLane(address(exec));
        PoolKey memory k = _openKoth(ETH);
        // Fill the pot to at least 5,000 ETH through two pushes of an unauthenticated swap, then stop arb recaptures:
        // each push puts 40% of what the protocol's 25% cut of its profit leaves (about 26.7%) in the pot; sized at
        // 25%, they overfill it.
        exec.set(ScriptedExecutor.Mode.PUSH, uint256(5000e18) * 10_000 / 2500 / 2 + 1);
        _newActor(k).directSwap(k, true, -1e9, MIN_PRICE);
        exec.set(ScriptedExecutor.Mode.REVERT, 0);
        (uint64 start,,, uint128 pot) = _hill(k);
        assertGe(pot, 5000e18);
        Actor a = _newActor(k);
        uint256 ethBefore = address(a).balance;
        uint256 subjectBefore = _balance(k, address(a));
        (, uint256 got) = a.routerSwap(_swapParams(k, ETH, true, true, 1e22, address(a)), 1e22);
        IHookrRouter.Swap memory sell = _swapParams(k, ETH, false, true, got, address(a));
        a.routerSwap(sell, 0);
        assertEq(_balance(k, address(a)), subjectBefore, "no inventory kept");
        uint256 roundTripCost = ethBefore - address(a).balance;
        vm.warp(uint256(start) + PERIOD);
        _recap().settleEpoch(k.toId());
        uint256 prize = rules.claimable(ETH, address(a));
        vm.prank(address(a));
        rules.claim(ETH);
        int256 net = int256(address(a).balance) - int256(ethBefore);
        console.log("pot before the wash        ", uint256(pot));
        console.log("round-trip cost            ", roundTripCost);
        console.log("prize (0.5% of buy)        ", prize);
        console.log("attacker net loss          ", uint256(-net));
        assertGt(pot, roundTripCost, "uncapped, the wash would have paid");
        assertEq(prize, 1e22 * 50 / 10_000);
        assertLt(net, 0, "capped, the wash loses money");
    }

    /// PoC 4, revert-unless-win (the phase-one M-05 shape). A bot rolls the elapsed epoch and buys in the same
    /// transaction, hoping to be paid by its own buy. Defended: rollover pays the closed epoch's leader before any
    /// buy of the transaction counts, so a same-transaction buy can only lead the next epoch.
    function test_poc_rollAndBuyCannotWinTheClosedEpoch() public {
        _buy(key, ETH, whale, 2e22);
        (uint64 start,,, uint128 pot) = _hill(key);
        assertGt(pot, 0);
        uint256 whaleBefore = rules.claimable(ETH, whale);
        vm.warp(uint256(start) + PERIOD);
        Actor bot = _newActor(key);
        vm.recordLogs();
        bot.rollAndBuy(address(rules), PoolId.unwrap(id), _swapParams(key, ETH, true, true, 5e22, address(bot)), 5e22);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 botTraderLegs;
        address crowned;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(rules)) continue;
            if (
                logs[i].topics[0] == IHookrRecaptureEvents.RecaptureSplit.selector
                    && address(uint160(uint256(logs[i].topics[2]))) == address(bot)
            ) {
                (uint256 tr,,,,,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, Currency, uint256));
                botTraderLegs += tr;
            } else if (logs[i].topics[0] == IHookrRecaptureEvents.KingCrowned.selector) {
                crowned = address(uint160(uint256(logs[i].topics[2])));
            }
        }
        uint256 prize = uint256(2e22) / 100;
        if (prize > pot) prize = pot;
        assertEq(crowned, whale, "the closed epoch's leader was crowned");
        assertEq(rules.claimable(ETH, whale) - whaleBefore, prize);
        assertEq(rules.claimable(ETH, address(bot)), botTraderLegs, "the bot holds only its trader legs");
        (uint64 next, address leader,,) = _hill(key);
        assertEq(next, start + PERIOD);
        assertEq(leader, address(bot), "the bot leads only the new epoch");
    }

    /// PoC 5, griefing. Dust buys below the minimum never write the leader, and a pool left idle for a thousand epochs
    /// rolls in constant gas.
    function test_poc_dustAndIdleEpochsCannotGrief() public {
        _buy(key, ETH, whale, 2e21);
        for (uint256 i; i < 20; ++i) {
            _buy(key, ETH, attacker, MIN_BUY - 1);
        }
        (uint64 start, address leader,,) = _hill(key);
        assertEq(leader, whale);
        vm.warp(uint256(start) + uint256(PERIOD) * 1000 + 17);
        uint256 g = gasleft();
        _recap().settleEpoch(id);
        uint256 used = g - gasleft();
        console.log("settleEpoch gas after 1000 idle epochs", used);
        assertLt(used, 80_000);
        (uint64 next,,,) = _hill(key);
        assertEq(next, uint256(start) + uint256(PERIOD) * 1000);
    }

    function _balance(PoolKey memory k, address who) internal view returns (uint256) {
        return _subjectOf(k).balanceOf(who);
    }
}

/// @notice The same attacks against a pool with the smallest pot release, 2,500 per closed epoch.
contract KothAttacksMinReleaseTest is KothAttacksTest {
    function _potReleaseBps() internal pure override returns (uint16) {
        return 2_500;
    }
}

/// @notice The same attacks against a pool with the largest pot release: the whole pot at every rollover.
contract KothAttacksMaxReleaseTest is KothAttacksTest {
    function _potReleaseBps() internal pure override returns (uint16) {
        return 10_000;
    }
}
