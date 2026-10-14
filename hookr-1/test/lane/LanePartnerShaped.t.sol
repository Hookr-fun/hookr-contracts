// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {IHookrLaneRoot} from "../../src/interfaces/IHookrLaneRoot.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {ScriptedExecutor} from "./mocks/ScriptedExecutor.sol";
import {LaneRootFixture} from "./utils/LaneRootFixture.sol";
import {PartnerShapedFixture} from "./utils/PartnerShapedFixture.sol";
import {IHookrLaneEvents} from "../../src/interfaces/IHookrLaneEvents.sol";

contract LanePartnerShapedTest is PartnerShapedFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    HookrToken internal subject;
    Currency internal s;
    Currency internal qb;
    PoolKey internal a;
    PoolKey internal b;
    PoolKey internal refA;
    PoolKey internal refB;
    PoolKey internal conn;

    function setUp() public {
        _setUpPartnerShaped();
        subject = _newSubject();
        subject.approve(address(venue), type(uint256).max);
        s = Currency.wrap(address(subject));
        qb = Currency.wrap(address(tokenB));
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _laneMemberAt(ETH);
        members[1] = _laneMemberAt(qb);
        (, PoolKey[] memory keys) = _launch(subject, members);
        (a, b) = (keys[0], keys[1]);
        refA = _hookless(a.currency0, a.currency1);
        refB = _hookless(b.currency0, b.currency1);
        conn = _hookless(ETH, qb);
        ex.setTrigger(a, 1e22);
        ex.addVenue(a, refA, PAIR_GAP);
        ex.addCycle(a, b, conn, CYCLE_GAP);
        ex.setTrigger(b, 1e22);
        ex.addVenue(b, refB, PAIR_GAP);
        ex.addCycle(b, a, conn, CYCLE_GAP);
        _nextBlock();
    }

    /// One call closes the gap a large buy opens against the outside venue and against the sibling, inside the 3M cap.
    function test_oneCallRunsSeveralArbitragesAndCycles_at3M() public {
        uint256 partnerBefore = partner.balance;
        uint256 protocolBefore = rules.claimable(ETH, protocol);
        vm.recordLogs();
        _buy(a, ETH, whale, 5e22);
        uint256 swapGas = vm.lastCallGas().gasTotalUsed;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Outcome memory o = _outcome(logs);
        assertEq(o.succeeded, 2, "both phases returned");
        assertEq(o.pushedBefore, 0, "nothing to recapture before the buy");
        assertGt(ex.lastArbs(), 0, "arbitrage chunks against the outside venue");
        assertGt(ex.lastCycles(), 0, "cycles through the sibling");
        assertGt(ex.lastArbs() + ex.lastCycles(), 2, "several chunks in one call");
        assertLt(ex.lastGas(), CAP, "the executor stopped inside the cap");
        uint256 profit = ex.lastProfit();
        assertEq(partner.balance - partnerBefore, profit * PARTNER_BPS / 10_000, "the partner kept its 25%");
        assertEq(o.pushedAfter, profit - profit * PARTNER_BPS / 10_000, "the rest was pushed");
        // The root reads the profit back from the push at the pinned 25%: the stand-in's own, or one wei above it.
        assertEq(o.profitAfter, _profitOf(o.pushedAfter));
        assertTrue(o.profitAfter == profit || o.profitAfter == profit + 1, "the profit read back from the push");
        Splits memory sp = _splits(logs);
        assertEq(sp.count, 1);
        assertEq(sp.protocol, _cut(o.profitAfter, o.pushedAfter), "the protocol's 25% of that profit first");
        assertEq(sp.trader, (o.pushedAfter - sp.protocol) * 2000 / 10_000, "then the trader who opened the gap");
        assertEq(sp.lastTrader, whale);
        assertGe(rules.claimable(ETH, protocol) - protocolBefore, sp.protocol);
        uint256 gapVenue = _gapBps(_px(a, s), _px(refA, s));
        uint256 gapFamily = _gapBps(_px(a, s), FullMath.mulDiv(_px(b, s), _px(conn, qb), 1e18));
        console2.log("chunks: arbitrages, cycles", ex.lastArbs(), ex.lastCycles());
        console2.log("profit, pushed, executor gas", profit, o.pushedAfter, ex.lastGas());
        console2.log("gap after (bps): venue, family", gapVenue, gapFamily);
        console2.log("GAS arb recapture buy, 2 routes, 3M cap", swapGas);
        assertLt(gapVenue, 300, "the venue gap is closed to within a chunk");
        assertLt(gapFamily, 300, "the family gap is closed to within a chunk");
    }

    /// The executor has no partnerBps() and the root never asks: the pinned 2,500 is what the push is checked against.
    function test_noPartnerBpsGetter_andTheRootNeverAsks() public {
        (bool ok,) = address(ex).staticcall(abi.encodeWithSignature("partnerBps()"));
        assertFalse(ok, "no partnerBps() getter");
        vm.expectCall(address(ex), abi.encodeWithSignature("partnerBps()"), 0);
        vm.recordLogs();
        _buy(a, ETH, whale, 5e22);
        assertGt(_outcome(vm.getRecordedLogs()).pushedAfter, 0);
    }

    /// An outside move is closed before the next swap is quoted, and that before-phase push credits no trader.
    function test_outsideMoveIsClosedBeforeTheSwap_withNoTraderCredit() public {
        // The subject runs up on the outside venue: currency1 is the subject, so buying it is zeroForOne.
        venue.swap{value: 3e22}(refA, true, 3e22, 0);
        uint256 gapBefore = _gapBps(_px(a, s), _px(refA, s));
        vm.recordLogs();
        _sell(a, ETH, minnow, 1e15);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Outcome memory o = _outcome(logs);
        assertGt(o.pushedBefore, 0, "the before-phase closed the outside gap");
        assertGt(ex.calls(), 0);
        uint256 gapAfter = _gapBps(_px(a, s), _px(refA, s));
        console2.log("outside gap before / after (bps)", gapBefore, gapAfter);
        assertLt(gapAfter, gapBefore / 4);
        // Only an after-phase push that undid the minnow's own move can credit it: its dust opened none, so whatever
        // the after-phase closed of the outside gap goes to the LP accrual.
        assertEq(rules.claimable(ETH, minnow), 0, "the dust seller is credited nothing");
    }

    /// A buy on the sibling recaptures in the sibling's quote, legging on the ETH member as the sibling.
    function test_anArbRecaptureTriggeredOnTheSiblingLegsOnTheFirstMember() public {
        uint256 partnerBefore = tokenB.balanceOf(partner);
        (uint160 aBefore,,,) = manager.getSlot0(a.toId());
        vm.recordLogs();
        _buy(b, qb, whale, 5e22);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertGt(o.pushedAfter, 0);
        assertGt(ex.lastCycles(), 0, "cycles legged on the ETH member");
        (uint160 aAfter,,,) = manager.getSlot0(a.toId());
        assertTrue(aAfter != aBefore, "the ETH member moved as a sibling");
        assertEq(tokenB.balanceOf(partner) - partnerBefore, ex.lastProfit() * PARTNER_BPS / 10_000, "kept in tokenB");
        assertEq(o.pushedAfter, ex.lastProfit() - ex.lastProfit() * PARTNER_BPS / 10_000);
    }

    /// With nothing to recapture each phase costs the executor a few slot0 reads per route.
    function test_anIdleCallIsCheap() public {
        vm.recordLogs();
        _sell(a, ETH, whale, 1e15);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertEq(o.succeeded, 2);
        assertEq(o.pushedBefore + o.pushedAfter, 0);
        console2.log("executor gas, idle after-phase (2 routes)", ex.lastGas());
        assertLt(ex.lastGas(), 60_000);
    }

    function sellWithGasOn(PoolKey memory key, address who, uint256 amount, uint256 g) external {
        require(msg.sender == address(this));
        IHookrRouter.Swap memory p = _swapParams(key, ETH, false, true, amount, who);
        vm.prank(who);
        router.swap{gas: g}(p, address(0), new uint256[](0));
    }

    /// The least gas a recapturing swap succeeds with (what eth_estimateGas returns) funds the 3M floor at both lane
    /// calls, and both arb recaptures run at it.
    function test_theLeastSucceedingGasFundsBothArbRecapturesAt3M() public {
        venue.swap{value: 3e22}(refA, true, 3e22, 0);
        (,,,,, uint32 cap, uint256 floor) = IHookrLaneRoot(address(root)).laneOf(a.toId());
        assertEq(cap, CAP);
        assertEq(floor, _entryFloor(CAP), "the floor at 3M");
        uint256 lo = 100_000;
        uint256 hi = 10_000_000;
        while (hi - lo > 1_000) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            try this.sellWithGasOn(a, whale, 1e18, mid) {
                hi = mid;
            } catch {
                lo = mid;
            }
            vm.revertToState(snap);
        }
        console2.log("least succeeding gas at the 3M cap, floor", hi, floor);
        assertGt(hi, floor, "below the floor the swap reverts");
        uint256 snap2 = vm.snapshotState();
        vm.recordLogs();
        this.sellWithGasOn(a, whale, 1e18, hi);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertEq(o.succeeded, 2, "both arb recaptures ran at the estimate");
        assertEq(o.failed, 0);
        assertGt(o.pushedBefore, 0, "the before-phase recaptured at the estimate");
        vm.revertToState(snap2);
        vm.expectRevert();
        this.sellWithGasOn(a, whale, 1e18, lo);
    }
}

/// @notice An eight-member family (the most a family holds): a large buy on the ETH member opens a gap against all
///         seven siblings, and one partner-shaped call at the 3M cap cycles through every one of them, each sibling
///         one direction, inside the cap.
contract LanePartnerShapedEightMembersTest is PartnerShapedFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    HookrToken internal subject;
    PoolKey[] internal keys;
    PoolKey[] internal connectors;

    function setUp() public {
        _setUpPartnerShaped();
        subject = _newSubject();
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](8);
        members[0] = _laneMemberAt(ETH);
        members[1] = _laneMemberAt(Currency.wrap(address(tokenA)));
        members[2] = _laneMemberAt(Currency.wrap(address(tokenB)));
        for (uint256 i = 3; i < 8; ++i) {
            HookrToken q = new HookrToken("Q", "Q", 1e30, address(this));
            _catalogQuote(address(q));
            q.approve(address(launcher), type(uint256).max);
            q.approve(address(venue), type(uint256).max);
            members[i] = _laneMemberAt(Currency.wrap(address(q)));
        }
        (, PoolKey[] memory k) = _launch(subject, members);
        for (uint256 i; i < 8; ++i) {
            keys.push(k[i]);
        }
        ex.setTrigger(keys[0], 4e21);
        for (uint256 i = 1; i < 8; ++i) {
            PoolKey memory c = _hookless(ETH, members[i].quote);
            connectors.push(c);
            ex.addCycle(keys[0], keys[i], c, CYCLE_GAP);
        }
        _nextBlock();
    }

    function test_oneCallCyclesThroughAllSevenSiblings_insideTheCap() public {
        uint160[] memory before = new uint160[](8);
        for (uint256 i; i < 8; ++i) {
            (before[i],,,) = manager.getSlot0(keys[i].toId());
        }
        vm.recordLogs();
        _buy(keys[0], ETH, whale, 5e22);
        uint256 swapGas = vm.lastCallGas().gasTotalUsed;
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertEq(o.succeeded, 2);
        assertEq(o.failed, 0, "no frame ran out of its cap");
        assertGt(o.pushedAfter, 0);
        assertGe(ex.lastCycles(), 7, "at least one cycle through each sibling");
        for (uint256 i = 1; i < 8; ++i) {
            (uint160 p,,,) = manager.getSlot0(keys[i].toId());
            assertTrue(p != before[i], "every sibling legged");
        }
        assertLt(ex.lastGas(), CAP);
        console2.log("8 members: cycles, executor gas, whole swap gas", ex.lastCycles(), ex.lastGas(), swapGas);
        console2.log("pushed", o.pushedAfter);
    }
}

/// @notice The largest gas limit a lane swap can need at the 3,000,000 cap: an executor that spends its whole grant in
///         both phases. The before-phase check funds its whole grant and the after-phase floor, so the least
///         succeeding limit is the same as with an idle executor; both frames fail open and the swap completes.
contract LaneWorstCaseLimitTest is LaneRootFixture {
    using PoolIdLibrary for PoolKey;

    ScriptedExecutor internal burner;
    PoolKey internal key;

    function setUp() public {
        _setUpLane();
        burner = new ScriptedExecutor(manager);
        burner.setRoot(address(root));
        _openLane(address(burner), 3_000_000);
        (, key) = _one(_newSubject(), true, false, 0);
        burner.set(ScriptedExecutor.Mode.BURN_GAS, 0);
        _nextBlock();
    }

    function test_worstCaseLimit_anExecutorThatBurnsItsGrantInBothPhases() public {
        uint256 least = _leastGas(key);
        (,,, uint256 floor) = _laneOf(key);
        console2.log("least succeeding gas, executor burning its 3M grant in both phases; floor", least, floor);
        assertGt(least, floor, "the swap reaches the lane with the entry floor");
        assertLt(least, 7_500_000);
        burner.set(ScriptedExecutor.Mode.NOTHING, 0);
        assertEq(_leastGas(key), least, "an idle executor needs the same limit: the estimate does not depend on it");
        burner.set(ScriptedExecutor.Mode.BURN_GAS, 0);
        vm.recordLogs();
        this.sellWithGas(key, least);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertEq(o.failed, 2, "both frames ran out of their grant and failed open");
        assertEq(o.lastReason, IHookrLaneEvents.LaneOutOfGas.selector);
    }
}
