// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {console2} from "forge-std/console2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {IHookrRules} from "../../src/interfaces/IHookrRules.sol";
import {IHookrLanes} from "../../src/interfaces/IHookrLanes.sol";
import {IHookrLaneRoot} from "../../src/interfaces/IHookrLaneRoot.sol";
import {HookrLauncher} from "../../src/periphery/HookrLauncher.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrRouter} from "../../src/periphery/HookrRouter.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {IHookrRecaptureRules} from "../../src/interfaces/IHookrRecaptureRules.sol";
import {MockIdleExecutor} from "../mocks/MockIdleExecutor.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TwoVenueExecutor} from "./mocks/TwoVenueExecutor.sol";
import {ScriptedExecutor} from "./mocks/ScriptedExecutor.sol";
import {Actor} from "./mocks/Actors.sol";
import {FamilyArbExecutor} from "./mocks/FamilyArbExecutor.sol";
import {LaneRootFixture} from "./utils/LaneRootFixture.sol";
import {IHookrLaneEvents} from "../../src/interfaces/IHookrLaneEvents.sol";

/// @notice One transaction of a creator-controlled washer across a token's family: buy the subject on the King of the
///         Pool member A (taking the crown), sell it on the sibling B for B's quote, and swap that quote back to ETH on
///         the hookless connector. It holds no subject and no B quote afterwards.
contract FamilyWasher {
    uint160 internal constant MAX_PRICE = 1461446703485210103287273052203988822378723970341;

    function run(
        Actor a,
        IHookrRouter.Swap memory buyA,
        uint256 value,
        IHookrRouter.Swap memory sellB,
        PoolKey memory c
    ) external {
        (, uint256 s) = a.routerSwap(buyA, value);
        sellB.amountSpecified = -int128(int256(s));
        (, uint256 q) = a.routerSwap(sellB, 0);
        // The connector is ETH / B quote: the quote is currency1, so selling it is oneForZero.
        a.directSwap(c, false, -int256(q), MAX_PRICE - 1);
    }
}

/// @dev Launches a lane family and swaps on it in the same transaction.
contract LaunchThenSwap {
    function run(HookrLauncher launcher, HookrRouter router, address root, IHookrLauncher.Member[] calldata members)
        external
        payable
        returns (PoolKey memory key)
    {
        HookrToken t = new HookrToken("C", "C", 1e30, address(this));
        t.approve(address(launcher), type(uint256).max);
        (bytes32 family,) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(t), "", "", 0, bytes32(0)), root, members, block.timestamp
        );
        key = launcher.position(family, 0).key;
        IHookrRouter.Swap memory p =
            IHookrRouter.Swap(key, true, -int128(1e18), 1, 4295128740, address(this), block.timestamp);
        router.swap{value: 1e18}(p, address(0), new uint256[](0));
    }

    receive() external payable {}
}

/// @notice The live switch: the brake reaches open pools and never redirects them, the cap is read live (lowered at
///         once, raised through the timelock) and once per swap, the gas floor follows it; no arb recapture in the
///         transaction that creates the pool; the before-phase credits no trader.
contract LaneRootSwitchTest is LaneRootFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    TwoVenueExecutor internal arb;
    PoolKey internal key;
    PoolKey internal plain;
    bytes32 internal family;

    function setUp() public {
        _setUpLane();
        // A first leg large enough that the before-phase closes a 3% gap in full.
        arb = new TwoVenueExecutor(manager, address(root), partner, PARTNER_BPS, 3000, 60, address(0), 1e24);
        _openLane(address(arb), LANE_GAS);
        HookrToken s = _newSubject();
        (family, key) = _one(s, true, false, 0);
        _seedRef(key);
        (, plain) = _one(_newSubject(), false, false, 0);
        _buy(key, ETH, minnow, 1e18);
        _nextBlock();
    }

    function _recapturingSell() internal returns (Outcome memory o) {
        _moveReference(key, 1.03e18);
        vm.recordLogs();
        _sell(key, ETH, whale, 1e18);
        o = _outcome(vm.getRecordedLogs());
    }

    function test_switch_isReadOncePerLaneSwap_andNeverOnAPoolWithoutALane() public {
        _moveReference(key, 1.03e18);
        vm.expectCall(address(registry), abi.encodeCall(IHookrLanes.executorLane, (address(root), address(arb))), 1);
        _sell(key, ETH, whale, 1e18);
        vm.expectCall(address(registry), abi.encodeWithSelector(IHookrLanes.executorLane.selector), 0);
        _sell(plain, ETH, whale, 1e18);
    }

    function test_brake_stopReachesOpenPools_andOnlyTheTimelockRestartsThem() public {
        Outcome memory o = _recapturingSell();
        assertEq(o.succeeded, 2, "live: both phases recapture");
        registry.stopExecutorLane(address(root), address(arb));
        (address executor, bool on,, uint256 floor) = _laneOf(key);
        assertEq(executor, address(arb), "the pool keeps its frozen executor");
        assertFalse(on);
        assertEq(floor, 0, "no floor while off");
        o = _recapturingSell();
        assertEq(o.succeeded + o.failed, 0, "off: no lane call on the open pool");
        // Without the lane the swap needs no floor.
        uint256 snap = vm.snapshotState();
        this.sellWithGas(key, 400_000);
        vm.revertToState(snap);
        vm.warp(vm.getBlockTimestamp() + 1);
        _switchOn(address(arb), LANE_GAS);
        o = _recapturingSell();
        assertGt(o.succeeded, 0, "switched on again through the timelock");
    }

    function test_brake_neverRedirectsAnOpenPool() public {
        registry.stopExecutorLane(address(root), address(arb));
        vm.warp(vm.getBlockTimestamp() + 1);
        TwoVenueExecutor next =
            new TwoVenueExecutor(manager, address(root), partner, PARTNER_BPS, 3000, 60, address(0), 1e22);
        _openLane(address(next), LANE_GAS);
        (address executor, bool on,,) = _laneOf(key);
        assertEq(executor, address(arb), "an opening never reaches an open pool");
        assertFalse(on);
        Outcome memory o = _recapturingSell();
        assertEq(o.succeeded + o.failed, 0);
        (, PoolKey memory fresh) = _one(_newSubject(), true, false, 0);
        (executor, on,,) = _laneOf(fresh);
        assertEq(executor, address(next), "new pools freeze the new lane");
        assertTrue(on);
    }

    function test_brake_closeStopsNewRecaptureLaunchesButNotOpenPools() public {
        registry.closeLaneOf(address(root));
        Outcome memory o = _recapturingSell();
        assertEq(o.succeeded, 2, "a close does not reach open pools");
        HookrToken s = _newSubject();
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(ETH, true, false, 0);
        vm.expectRevert();
        launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(s), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
    }

    function test_cap_isLive_lowerAtOnce_raiseByTimelock_andTheFloorFollows() public {
        _moveReference(key, 1.03e18);
        uint256 at600k = _leastGas(key);
        (,, uint32 cap, uint256 floor) = _laneOf(key);
        assertEq(cap, LANE_GAS);
        assertEq(floor, _entryFloor(LANE_GAS));
        registry.tuneExecutorLane(address(root), address(arb), 400_000);
        (,, cap, floor) = _laneOf(key);
        assertEq(cap, 400_000, "lowered at once on the open pool");
        assertEq(floor, _entryFloor(400_000));
        uint256 at400k = _leastGas(key);
        assertLt(at400k, at600k, "a lower cap lowers the gas a lane swap must carry");
        vm.warp(vm.getBlockTimestamp() + 1);
        _switchOn(address(arb), 3_000_000);
        (,, cap, floor) = _laneOf(key);
        assertEq(cap, 3_000_000, "raised through the timelock");
        uint256 at3m = _leastGas(key);
        assertGt(at3m, floor, "the least succeeding gas funds the floor");
        console2.log("least succeeding gas at a 400k / 600k / 3M cap", at400k, at600k, at3m);
        // At the least succeeding gas both phases run their arb recapture.
        vm.recordLogs();
        this.sellWithGas(key, at3m);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertEq(o.succeeded, 2, "both arb recaptures ran at the estimated gas");
        vm.expectRevert();
        this.sellWithGas(key, at600k);
    }

    function test_cap_gasUsedDoesNotDependOnTheCap() public {
        _moveReference(key, 1.03e18);
        uint256 snap = vm.snapshotState();
        _sell(key, ETH, whale, 1e18);
        uint256 used600k = vm.lastCallGas().gasTotalUsed;
        vm.revertToState(snap);
        _switchOn(address(arb), 5_000_000);
        _sell(key, ETH, whale, 1e18);
        uint256 used5m = vm.lastCallGas().gasTotalUsed;
        console2.log("arb recapture sell gas used at a 600k / 5M cap", used600k, used5m);
        assertEq(used5m, used600k);
    }

    function test_creationTx_devBuyRunsNoArbRecapture() public {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        IHookrLauncher.Member memory m = _member(ETH, true, true, 0);
        m.tickLower = -60_000;
        m.tickUpper = 0;
        uint160 lower = TickMath.getSqrtPriceAtTick(-60_000);
        m.liquidity = LiquidityAmounts.getLiquidityForAmount1(lower, SQRT_ONE, 1e27) / 1000 * 999;
        m.amount0Max = 0;
        m.amount1Max = 1e27;
        members[0] = m;
        vm.recordLogs();
        launcher.launchWithBuy{value: 1e21}(
            IHookrLauncher.Token(address(0), "New", "NEW", 1e27, bytes32(uint256(77))),
            address(root),
            members,
            new bytes[](1),
            IHookrLauncher.DevBuy(0, 1e21, 1, 0),
            vm.getBlockTimestamp()
        );
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertEq(o.succeeded + o.failed, 0, "no arb recapture in the launch transaction");
    }

    function test_creationTx_aSwapInTheLaunchTransactionRunsNoArbRecapture_theNextOneDoes() public {
        LaunchThenSwap l = new LaunchThenSwap();
        vm.deal(address(l), 1e25);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(ETH, true, false, 0);
        vm.recordLogs();
        PoolKey memory k = l.run(launcher, router, address(root), members);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertEq(o.succeeded + o.failed, 0, "no arb recapture in the transaction that created the pool");
        _nextBlock();
        vm.deal(whale, 1e28);
        vm.recordLogs();
        _buy(k, ETH, whale, 1e18);
        o = _outcome(vm.getRecordedLogs());
        assertEq(o.succeeded + o.failed, 2, "the next transaction runs both phases");
    }

    /// The judge's dust poke: a gap the trader did not open is closed by the before-phase, which credits no trader,
    /// and whatever of it the after-phase closes is not the poke's move either, so it is credited nothing.
    function test_rebate_aDustPokeCollectsNothingFromAGapItDidNotOpen() public {
        _moveReference(key, 1.03e18);
        uint256 accruedBefore = _accrued(key);
        vm.recordLogs();
        _sell(key, ETH, attacker, 1e15);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertGt(o.pushedBefore, 0, "the before-phase closed the gap");
        // What a before-phase trader leg would have paid it: 20% of the push net of the protocol's cut.
        uint256 oldRule = (o.pushedBefore - _cut(o.profitBefore, o.pushedBefore)) * 2000 / 10_000;
        assertEq(rules.claimable(ETH, attacker), 0, "nothing of the gap it did not open");
        console2.log("poke credit under a before-phase trader leg", oldRule);
        uint256 accrued = _accrued(key);
        uint256 rest = o.pushedBefore - _cut(o.profitBefore, o.pushedBefore);
        uint256 afterRest = o.pushedAfter - _cut(o.profitAfter, o.pushedAfter);
        assertEq(accrued - accruedBefore, rest + afterRest, "every push's trader share went to the LP accrual");
        console2.log(
            "before-phase push / after-phase push / poke credit",
            o.pushedBefore,
            o.pushedAfter,
            rules.claimable(ETH, attacker)
        );
    }

    function test_rebate_theAfterPhaseCreditsTheTraderWhoOpenedTheGap() public {
        vm.recordLogs();
        _buy(key, ETH, whale, 5e22);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertEq(o.pushedBefore, 0);
        assertGt(o.pushedAfter, 0, "the after-phase closed the gap the buy opened");
        uint256 rest = o.pushedAfter - _cut(o.profitAfter, o.pushedAfter);
        assertEq(rules.claimable(ETH, whale), rest * 2000 / 10_000);
    }
}

/// @notice The launch guard applies to the lane: during it an executor buy leg pays what a trader pays (Snipe, the
///         per-block cap and every other rule) and sell legs stay base-fee legs; after it every leg is a base-fee leg.
contract LaneRootGuardTest is LaneRootFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    ScriptedExecutor internal exec;
    PoolKey internal key;
    HookrToken internal subject;

    function setUp() public {
        _setUpLane();
        exec = new ScriptedExecutor(manager);
        exec.setRoot(address(root));
        vm.deal(address(exec), 1e28);
        // The cap the lane opens at on deploy day: room for several full-path legs per frame.
        _openLane(address(exec), 3_000_000);
        subject = _newSubject();
        (, key) = _one(subject, true, true, 0);
        subject.transfer(address(exec), 1e27);
        exec.set(ScriptedExecutor.Mode.NOTHING, 0);
        _nextBlock();
    }

    function _plan(bool buy, uint256 amount, uint256 count, bool strict) internal {
        ScriptedExecutor.Step[] memory steps = new ScriptedExecutor.Step[](count);
        // ETH is currency0: a buy pays currency0.
        for (uint256 i; i < count; ++i) {
            steps[i] = ScriptedExecutor.Step(key, buy, amount);
        }
        exec.setPlan(steps, strict, false, ETH);
        exec.set(ScriptedExecutor.Mode.PLAN, 0);
    }

    function test_guard_aBuyLegPaysSnipeLikeATrader() public {
        uint256 snap = vm.snapshotState();
        uint256 outside = exec.outsideSwap(key, 1e20);
        vm.revertToState(snap);
        _plan(true, 1e20, 1, true);
        vm.recordLogs();
        _sell(key, ETH, whale, 1e15);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertEq(o.succeeded, 2);
        assertEq(exec.planOuts(0), outside, "the leg got exactly what an outside buy gets under Snipe");
        assertLt(exec.planOuts(0), 1e20 * 6 / 10, "Snipe (50%) was paid");
    }

    function test_guard_buyLegsReachRules() public {
        _plan(true, 1e20, 1, true);
        // The outer sell plus one buy leg per phase.
        vm.expectCall(address(rules), abi.encodeWithSelector(IHookrRules.settleSwap.selector), 3);
        _sell(key, ETH, whale, 1e15);
    }

    function test_guard_sellLegsStayBaseFeeLegs() public {
        _plan(false, 1e18, 1, true);
        // Only the outer sell reaches Rules.
        vm.expectCall(address(rules), abi.encodeWithSelector(IHookrRules.settleSwap.selector), 1);
        _sell(key, ETH, whale, 1e15);
        assertGt(exec.planOuts(0), 1e18 * 98 / 100, "base fee (1%) only");
    }

    /// The judge's bypass: the lane bought 6x the per-block cap untaxed in one parent block. Now every guarded buy leg
    /// counts against the cap: across both phases of any number of swaps, legs buy at most the cap per parent block.
    function test_guard_legsCannotBuyPastThePerBlockCap() public {
        _plan(true, 2.5e21, 6, false);
        uint256 blockAtStart = vm.getBlockNumber();
        for (uint256 round; round < 3; ++round) {
            _sell(key, ETH, attacker, 1e15);
        }
        assertEq(vm.getBlockNumber(), blockAtStart, "one parent block");
        uint256 bought;
        uint256 n;
        for (uint256 i; i < 36; ++i) {
            uint256 out = exec.planOuts(i);
            if (out != 0) n++;
        }
        bought = n * 2.5e21;
        console2.log("buy legs that cleared in one parent block", n);
        assertLe(bought, 1e22 + 3 * 1e15, "legs bought at most the cap (plus what the pokes sold)");
        assertEq(exec.planErrorCount(), 36 - n);
        // A trader's buy in the same parent block finds the cap used.
        exec.set(ScriptedExecutor.Mode.NOTHING, 0);
        vm.expectRevert();
        _buy(key, ETH, minnow, 1e18);
        _nextBlock();
        _buy(key, ETH, minnow, 1e18);
    }

    function test_guard_afterTheGuardBuyLegsAreBaseFeeLegs() public {
        vm.roll(vm.getBlockNumber() + 100_001);
        vm.warp(vm.getBlockTimestamp() + 3600);
        _plan(true, 1e20, 1, true);
        vm.expectCall(address(rules), abi.encodeWithSelector(IHookrRules.settleSwap.selector), 1);
        _sell(key, ETH, whale, 1e15);
        assertGt(exec.planOuts(0), 1e20 * 98 / 100, "base fee (1%) only");
    }
}

/// @notice Family-aware legs: inside a frame, the executor's legs on the lane siblings of the pool under arb recapture
///         (same launcher family, same root, same frozen executor) are legs like those on the pool itself: base LP
///         fee, no rule, one direction per pool per frame, their quotes settled when the frame ends. Legs on any other
///         pool are ordinary swaps, including a sibling that opted out and a lane pool of another family.
contract LaneRootFamilyTest is LaneRootFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    ScriptedExecutor internal exec;
    HookrToken internal subject;
    PoolKey[] internal fam;
    PoolKey internal stranger;

    function setUp() public {
        _setUpLane();
        exec = new ScriptedExecutor(manager);
        exec.setRoot(address(root));
        vm.deal(address(exec), 1e28);
        tokenA.transfer(address(exec), 1e27);
        tokenB.transfer(address(exec), 1e27);
        _openLane(address(exec), 3_000_000);
        subject = _newSubject();
        subject.transfer(address(exec), 1e27);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _member(ETH, true, false, 200);
        members[1] = _member(Currency.wrap(address(tokenB)), true, false, 200);
        (, PoolKey[] memory keys) = _launch(subject, members);
        fam.push(keys[0]);
        fam.push(keys[1]);
        HookrToken other = _newSubject();
        other.transfer(address(exec), 1e27);
        (, stranger) = _one(other, true, false, 200);
        exec.set(ScriptedExecutor.Mode.NOTHING, 0);
        _nextBlock();
    }

    /// @dev Exact-input sell of the subject on `k`.
    function _sellStep(PoolKey memory k, uint256 amount) internal view returns (ScriptedExecutor.Step memory) {
        return ScriptedExecutor.Step(k, Currency.unwrap(k.currency0) == address(subject), amount);
    }

    function _runPlan(ScriptedExecutor.Step[] memory steps, bool strict, bool leave, Currency leaveIn)
        internal
        returns (Outcome memory o)
    {
        exec.setPlan(steps, strict, leave, leaveIn);
        exec.set(ScriptedExecutor.Mode.PLAN, 0);
        exec.clearPlanRecord();
        vm.recordLogs();
        _sell(fam[0], ETH, whale, 1e15);
        o = _outcome(vm.getRecordedLogs());
    }

    function test_family_siblingsShareTheScopedFamily() public view {
        (,,, bytes32 f0,,,) = IHookrLaneRoot(address(root)).laneOf(fam[0].toId());
        (,,, bytes32 f1,,,) = IHookrLaneRoot(address(root)).laneOf(fam[1].toId());
        (,,, bytes32 fs,,,) = IHookrLaneRoot(address(root)).laneOf(stranger.toId());
        assertTrue(f0 != bytes32(0));
        assertEq(f0, f1);
        assertTrue(fs != f0);
        assertEq(f0, keccak256(abi.encode(address(launcher), launcher.poolFamily(fam[0].toId()))));
    }

    /// @dev Exact-input buy of the subject on `k`, paying its quote.
    function _buyStep(PoolKey memory k, uint256 amount) internal view returns (ScriptedExecutor.Step memory) {
        return ScriptedExecutor.Step(k, Currency.unwrap(k.currency0) != address(subject), amount);
    }

    function test_family_aSiblingLegPaysTheBaseFeeAndRunsNoRule() public {
        ScriptedExecutor.Step[] memory steps = new ScriptedExecutor.Step[](1);
        steps[0] = _buyStep(fam[1], 1e21);
        // The same buy as an ordinary swap pays the pool's full rules (LP Rewards: LP part and quote take).
        uint256 snap = vm.snapshotState();
        uint256 ordinary = _ordinary(fam[1], steps[0].zeroForOne, 1e21);
        vm.revertToState(snap);
        Currency quoteB = Currency.wrap(address(tokenB));
        uint256 protocolB = rules.claimable(quoteB, protocol);
        // Only the outer sell reaches Rules: the sibling legs of both phases do not.
        vm.expectCall(address(rules), abi.encodeWithSelector(IHookrRules.settleSwap.selector), 1);
        Outcome memory o = _runPlan(steps, true, false, ETH);
        assertEq(o.succeeded, 2, "both frames legged on the sibling");
        assertEq(rules.claimable(quoteB, protocol), protocolB, "no quote take on a sibling leg");
        assertGt(exec.planOuts(0), ordinary, "a sibling leg pays less than the pool's full rules");
        console2.log("sibling leg out / ordinary out", exec.planOuts(0), ordinary);
    }

    function _ordinary(PoolKey memory k, bool zeroForOne, uint256 amount) internal returns (uint256 out) {
        Actor a = _newActor();
        subject.transfer(address(a), amount);
        a.approveAll(address(subject));
        (uint160 p0,,,) = manager.getSlot0(k.toId());
        a.directSwap(k, zeroForOne, -int256(amount), zeroForOne ? MIN_PRICE + 1 : MAX_PRICE - 1);
        (uint160 p1,,,) = manager.getSlot0(k.toId());
        assertTrue(p0 != p1);
        int256 d = zeroForOne ? a.lastDelta1() : a.lastDelta0();
        out = uint256(d);
    }

    function test_family_oneDirectionPerSiblingPerFrame() public {
        ScriptedExecutor.Step[] memory steps = new ScriptedExecutor.Step[](2);
        steps[0] = _sellStep(fam[1], 1e20);
        steps[1] = ScriptedExecutor.Step(fam[1], !steps[0].zeroForOne, 1e18);
        Outcome memory o = _runPlan(steps, false, false, ETH);
        assertEq(o.succeeded, 2);
        assertEq(exec.planErrorCount(), 2, "the reverse leg on the sibling was refused in each frame");
        assertGt(exec.planOuts(0), 0);
        assertEq(exec.planOuts(1), 0);
    }

    function test_family_legsOnAnotherFamilyAreOrdinarySwaps() public {
        ScriptedExecutor.Step[] memory steps = new ScriptedExecutor.Step[](1);
        // Sells the other family's subject (currency1: ETH is currency0) on its lane pool.
        steps[0] = ScriptedExecutor.Step(stranger, false, 1e20);
        // The outer sell and one ordinary swap per phase reach Rules.
        vm.expectCall(address(rules), abi.encodeWithSelector(IHookrRules.settleSwap.selector), 3);
        Outcome memory o = _runPlan(steps, true, false, ETH);
        assertEq(o.succeeded, 2);
    }

    function test_family_anOptedOutMemberIsAnOrdinaryPool() public {
        HookrToken s = _newSubject();
        s.transfer(address(exec), 1e27);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _member(ETH, true, false, 200);
        members[1] = _member(Currency.wrap(address(tokenB)), false, false, 200);
        (, PoolKey[] memory keys) = _launch(s, members);
        (address e1,,, bytes32 f1,,,) = IHookrLaneRoot(address(root)).laneOf(keys[1].toId());
        assertEq(e1, address(0), "the opted-out member has no lane");
        assertEq(f1, bytes32(0));
        _nextBlock();
        ScriptedExecutor.Step[] memory steps = new ScriptedExecutor.Step[](1);
        steps[0] = ScriptedExecutor.Step(keys[1], Currency.unwrap(keys[1].currency0) == address(s), 1e20);
        exec.setPlan(steps, true, false, ETH);
        exec.set(ScriptedExecutor.Mode.PLAN, 0);
        vm.expectCall(address(rules), abi.encodeWithSelector(IHookrRules.settleSwap.selector), 3);
        vm.recordLogs();
        _sell(keys[0], ETH, whale, 1e15);
        assertEq(_outcome(vm.getRecordedLogs()).succeeded, 2);
    }

    function test_family_aDeltaLeftInASiblingQuoteUnwindsTheFrame() public {
        ScriptedExecutor.Step[] memory steps = new ScriptedExecutor.Step[](1);
        steps[0] = _sellStep(fam[1], 1e20);
        (uint160 before,,,) = manager.getSlot0(fam[1].toId());
        Outcome memory o = _runPlan(steps, true, true, Currency.wrap(address(tokenB)));
        assertEq(o.failed, 2);
        assertEq(o.lastReason, IHookrLaneEvents.LaneLeftDelta.selector);
        (uint160 afterPrice,,,) = manager.getSlot0(fam[1].toId());
        assertEq(afterPrice, before, "the sibling leg was unwound with the frame");
    }

    function test_family_eightMembers_legsOnEverySibling() public {
        HookrToken s = _newSubject();
        s.transfer(address(exec), 1e27);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](8);
        members[0] = _member(ETH, true, false, 200);
        members[1] = _member(Currency.wrap(address(tokenA)), true, false, 200);
        members[2] = _member(Currency.wrap(address(tokenB)), true, false, 200);
        for (uint256 i = 3; i < 8; ++i) {
            HookrToken q = new HookrToken("Q", "Q", 1e30, address(this));
            _catalogQuote(address(q));
            q.approve(address(launcher), type(uint256).max);
            q.transfer(address(exec), 1e27);
            members[i] = _member(Currency.wrap(address(q)), true, false, 200);
        }
        (, PoolKey[] memory keys) = _launch(s, members);
        _nextBlock();
        ScriptedExecutor.Step[] memory steps = new ScriptedExecutor.Step[](7);
        uint160[] memory prices = new uint160[](8);
        for (uint256 i = 1; i < 8; ++i) {
            steps[i - 1] = ScriptedExecutor.Step(keys[i], Currency.unwrap(keys[i].currency0) == address(s), 1e20);
            (prices[i],,,) = manager.getSlot0(keys[i].toId());
        }
        exec.setPlan(steps, true, false, ETH);
        exec.set(ScriptedExecutor.Mode.PLAN, 0);
        vm.expectCall(address(rules), abi.encodeWithSelector(IHookrRules.settleSwap.selector), 1);
        vm.recordLogs();
        s.transfer(whale, 1e18);
        vm.prank(whale);
        s.approve(address(router), type(uint256).max);
        _sell(keys[0], ETH, whale, 1e15);
        console2.log("GAS 8-member family, 7 sibling legs per phase", vm.lastCallGas().gasTotalUsed);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertEq(o.succeeded, 2, "every sibling legged in both frames");
        for (uint256 i = 1; i < 8; ++i) {
            (uint160 p,,,) = manager.getSlot0(keys[i].toId());
            assertTrue(p != prices[i], "each sibling moved");
        }
    }

    function test_family_aGuardedSiblingBuyLegRunsTheFullPath() public {
        HookrToken s = _newSubject();
        s.transfer(address(exec), 1e27);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _member(ETH, true, true, 0);
        members[1] = _member(Currency.wrap(address(tokenB)), true, true, 0);
        (, PoolKey[] memory keys) = _launch(s, members);
        _nextBlock();
        ScriptedExecutor.Step[] memory steps = new ScriptedExecutor.Step[](1);
        // A buy of the subject on the sibling pays tokenB in.
        steps[0] = ScriptedExecutor.Step(keys[1], Currency.unwrap(keys[1].currency0) == address(tokenB), 1e20);
        exec.setPlan(steps, true, false, ETH);
        exec.set(ScriptedExecutor.Mode.PLAN, 0);
        vm.expectCall(address(rules), abi.encodeWithSelector(IHookrRules.settleSwap.selector), 3);
        vm.recordLogs();
        _sell(keys[0], ETH, whale, 1e15);
        assertEq(_outcome(vm.getRecordedLogs()).succeeded, 2);
        assertLt(exec.planOuts(0), 1e20 * 6 / 10, "the sibling's Snipe was paid");
    }
}

/// @notice An idle lane (the switch on, the executor finds nothing) leaves a pool's outcomes exactly those of the same
///         pool without a lane: every amount in and out, every claim and the final price, for every rule at once and
///         for a guarded launch; and a switched-off lane pool matches it too.
contract LaneRootIdleParityTest is LaneRootFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev Finds nothing: every lane call returns zero.
    MockIdleExecutor internal idle;

    function setUp() public {
        _setUpLane();
        idle = new MockIdleExecutor();
        _openLane(address(idle), LANE_GAS);
    }

    function _full(bool lane, bool guarded) internal view returns (IHookrLauncher.Member memory m) {
        m = _member(ETH, lane, guarded, 200);
        m.rules.burnBps = 100;
        m.rules.royaltyBps = 500;
        m.rules.royaltyTo = royalty;
        m.rules.maxFeePips = 50_000;
        m.rules.dynamicFeeSens = 5;
        if (guarded) {
            m.rules.snipeFloorPips = 10_000;
            m.rules.snipeDecaySeconds = 600;
        }
    }

    function _sequence(PoolKey memory key) internal returns (uint256[] memory v) {
        v = new uint256[](12);
        uint256 royaltyBefore = rules.claimable(ETH, royalty);
        uint256 protocolBefore = rules.claimable(ETH, protocol);
        v[0] = _buy(key, ETH, whale, 1e20);
        _nextBlock();
        v[1] = _sell(key, ETH, whale, 5e19);
        _nextBlock();
        v[2] = _buy(key, ETH, whale, 3e21);
        _nextBlock();
        v[3] = _sell(key, ETH, whale, 2e21);
        _nextBlock();
        v[4] = _buy(key, ETH, minnow, 7e18);
        (uint160 p, int24 t,,) = manager.getSlot0(key.toId());
        v[5] = p;
        v[6] = uint256(int256(t) + (1 << 32));
        v[7] = manager.getLiquidity(key.toId());
        v[8] = rules.claimable(ETH, royalty) - royaltyBefore;
        v[9] = rules.claimable(ETH, protocol) - protocolBefore;
        v[10] = rules.claimable(ETH, whale);
        v[11] = rules.claimable(ETH, minnow);
    }

    function _compare(bool guarded) internal {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _full(false, guarded);
        (, PoolKey[] memory a) = _launch(_newSubject(), members);
        members[0] = _full(true, guarded);
        (, PoolKey[] memory b) = _launch(_newSubject(), members);
        _nextBlock();
        uint256 snap = vm.snapshotState();
        uint256[] memory withoutLane = _sequence(a[0]);
        vm.revertToState(snap);
        vm.recordLogs();
        uint256[] memory withLane = _sequence(b[0]);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertEq(o.succeeded, 10, "the lane ran on every swap");
        for (uint256 i; i < withLane.length; ++i) {
            assertEq(withLane[i], withoutLane[i], "an idle lane changes no outcome");
        }
    }

    function test_idleLane_matchesNoLane_everyRule() public {
        _compare(false);
    }

    function test_idleLane_matchesNoLane_guardedLaunch() public {
        _compare(true);
    }
}

/// @notice Family-aware arb recaptures end to end, and the wash they could invite. A family-aware executor closes the
///         gap a trade opens between a token's own pools (A: ETH / S, B: tokenB / S) through a hookless ETH / tokenB
///         connector, legging on A and on its sibling B inside one frame. The model: a round trip on A moves value from
///         the pools' LPs to the arb recapture, and the arb recapture returns at most the trader and LP legs (the push
///         less Hookr's 25% of the profit: 50% of the profit, the partner keeping 25%) to whoever made the trip and
///         owns the launch position; the rest (partner, protocol, the connector's fees) leaves. So a creator's wash, as
///         sole LP or next to a third-party LP, ends below simply withdrawing.
contract LaneRootFamilyWashTest is LaneRootFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    FamilyArbExecutor internal fx;
    HookrToken internal subject;
    bytes32 internal family;
    PoolKey internal a;
    PoolKey internal b;
    PoolKey internal connector;

    function setUp() public {
        _setUpLane();
        fx = new FamilyArbExecutor(manager, address(root), partner, PARTNER_BPS);
        _openLane(address(fx), 3_000_000);
        subject = _newSubject();
        subject.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _member(ETH, true, false, 0);
        members[1] = _member(Currency.wrap(address(tokenB)), true, false, 0);
        members[0].rules.protocolShareBps = 2000;
        members[1].rules.protocolShareBps = 2000;
        PoolKey[] memory keys;
        (family, keys) = _launch(subject, members);
        (a, b) = (keys[0], keys[1]);
        connector = PoolKey(ETH, Currency.wrap(address(tokenB)), 3000, 60, IHooks(address(0)));
        seeder.seed{value: 1e24}(connector, SQRT_ONE, -60_000, 60_000, 1e24);
        fx.configure(b, connector, Currency.wrap(address(subject)), 1e21, 1e19);
        _nextBlock();
    }

    /// @dev Everything the creator holds, each asset marked at the launch price (1 ETH per S, 1 ETH per tokenB).
    function _wealth() internal view returns (int256) {
        return int256(address(this).balance) + int256(tokenB.balanceOf(address(this)))
            + int256(subject.balanceOf(address(this))) + int256(rules.claimable(ETH, address(this)))
            + int256(rules.claimable(Currency.wrap(address(tokenB)), address(this)));
    }

    function _exit() internal returns (int256) {
        for (uint8 i; i < 2; ++i) {
            try launcher.claimRecapture(family, i, address(this)) {} catch {}
            uint128 l = launcher.position(family, i).liquidity;
            launcher.withdraw(family, i, l, 0, 0, address(this), vm.getBlockTimestamp());
        }
        return _wealth();
    }

    function _roundTrip(uint256 size) internal returns (Outcome memory o) {
        vm.recordLogs();
        IHookrRouter.Swap memory p = _swapParams(a, ETH, true, true, size, address(this));
        (, uint256 got) = router.swap{value: size}(p, address(0), new uint256[](0));
        _nextBlock();
        p = _swapParams(a, ETH, false, true, got, address(this));
        router.swap(p, address(0), new uint256[](0));
        _nextBlock();
        o = _outcome(vm.getRecordedLogs());
    }

    function test_familyArbRecapture_legsOnTheSiblingCloseTheGap() public {
        (uint160 a0,,,) = manager.getSlot0(a.toId());
        (uint160 b0,,,) = manager.getSlot0(b.toId());
        // A 5% move on A: a gap above the cycle's fees (1% on each Hookr leg, 0.3% on the connector).
        vm.recordLogs();
        _buy(a, ETH, whale, 5e22);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertGt(o.pushedAfter, 0, "the after-phase recaptured across the family");
        assertGt(fx.cycles(), 0);
        (uint160 a1,,,) = manager.getSlot0(a.toId());
        (uint160 b1,,,) = manager.getSlot0(b.toId());
        assertTrue(b1 != b0, "the sibling moved: its legs ran in the frame");
        assertTrue(a1 != a0);
        uint256 rest = o.pushedAfter - _cut(o.profitAfter, o.pushedAfter);
        assertEq(rules.claimable(ETH, whale), rest * 2000 / 10_000, "the trader who opened the gap is credited");
        console2.log("family arb recapture push, cycles", o.pushedAfter, fx.cycles());
    }

    function test_attack_creatorWashAsSoleLpLosesAgainstWithdrawing() public {
        uint256 snap = vm.snapshotState();
        int256 baseline = _exit();
        vm.revertToState(snap);
        Outcome memory o = _roundTrip(5e22);
        int256 washed = _exit();
        console2.log("pushed (both trips)", o.pushedAfter + o.pushedBefore);
        console2.log("creator wealth: withdraw only / wash then withdraw");
        console2.logInt(baseline);
        console2.logInt(washed);
        console2.logInt(washed - baseline);
        assertGt(o.pushedAfter, 0, "the wash triggered family arb recaptures");
        assertLt(washed, baseline, "the wash loses");
    }

    function test_attack_creatorWashNextToAThirdPartyLpLoses() public {
        Actor lp = _newActor();
        subject.transfer(address(lp), 1e26);
        lp.approveAll(address(subject));
        lp.modify(a, -60_000, 60_000, 1e24);
        lp.modify(b, -60_000, 60_000, 1e24);
        _nextBlock();
        uint256 snap = vm.snapshotState();
        int256 baseline = _exit();
        vm.revertToState(snap);
        Outcome memory o = _roundTrip(5e22);
        int256 washed = _exit();
        console2.log("pushed (both trips)", o.pushedAfter + o.pushedBefore);
        console2.logInt(washed - baseline);
        assertGt(o.pushedAfter, 0);
        assertLt(washed, baseline, "the wash loses with a third-party LP too");
    }
}

/// @notice The family-aware King of the Pool wash (REVIEW M-1 across a family). The creator owns every position of a
///         two-member family: A (ETH / S) with King of the Pool and B (tokenB / S) with recapture only. A washer it
///         controls takes A's crown with a buy, sells the subject on the sibling B and swaps B's quote back to ETH on
///         the connector, in one transaction, so every leg but the connector's pays the creator's own positions. The
///         family executor recaptures the gap the buy opens across A, B and the connector. With the prize capped by the
///         protocol fee of the winning buy, the creator ends behind rolling, claiming and withdrawing without the wash,
///         at the pre-wash prices.
contract LaneRootFamilyKothWashTest is LaneRootFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    FamilyArbExecutor internal fx;
    HookrToken internal subject;
    bytes32 internal family;
    PoolKey internal a;
    PoolKey internal b;
    PoolKey internal connector;
    Currency internal qb;

    function setUp() public {
        _setUpLane();
        fx = new FamilyArbExecutor(manager, address(root), partner, PARTNER_BPS);
        _openLane(address(fx), 3_000_000);
        subject = _newSubject();
        qb = Currency.wrap(address(tokenB));
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _member(ETH, true, false, KOTH_LP_REWARDS);
        members[0].rules.potBps = POT_BPS;
        members[0].recapture = _kothRc();
        members[1] = _member(qb, true, false, 0);
        PoolKey[] memory keys;
        (family, keys) = _launch(subject, members);
        (a, b) = (keys[0], keys[1]);
        connector = PoolKey(ETH, qb, 3000, 60, IHooks(address(0)));
        seeder.seed{value: 1e24}(connector, SQRT_ONE, -60_000, 60_000, 1e24);
        fx.configure(b, connector, Currency.wrap(address(subject)), 1e21, 1e19);
        _nextBlock();
        // Other traffic fills A's pot: unauthenticated round trips, each recaptured across the family.
        Actor filler = _newActor();
        subject.transfer(address(filler), 1e26);
        for (uint256 i; i < 5; ++i) {
            filler.directSwap(a, true, -5e22, MIN_PRICE);
            filler.directSwap(a, false, -filler.lastDelta1(), MAX_PRICE);
        }
        _buy(a, ETH, minnow, 1e20); // an honest leader
    }

    /// @dev ETH value of everything `who` holds and is owed, the subject at A's price and tokenB at the connector's.
    function _value(address who, uint160 sqrtA, uint160 sqrtC) internal view returns (int256) {
        uint256 s = subject.balanceOf(who);
        uint256 q = tokenB.balanceOf(who) + rules.claimable(qb, who);
        uint256 eth = who.balance + rules.claimable(ETH, who);
        return int256(eth + _inEth(s, sqrtA) + _inEth(q, sqrtC));
    }

    /// @dev `amount` of currency1 in currency0 at price sqrtPriceX96 (currency1 per currency0).
    function _inEth(uint256 amount, uint160 sqrtPriceX96) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(amount, 1 << 96, sqrtPriceX96), 1 << 96, sqrtPriceX96);
    }

    /// @dev Rolls A's epoch, moves both members' accruals into the creator's claim and withdraws both positions.
    function _exit(uint64 start) internal {
        vm.warp(uint256(start) + PERIOD);
        IHookrRecaptureRules(address(rules)).settleEpoch(a.toId());
        for (uint8 i; i < 2; ++i) {
            try launcher.claimRecapture(family, i, address(this)) {} catch {}
            uint128 l = launcher.position(family, i).liquidity;
            launcher.withdraw(family, i, l, 0, 0, address(this), vm.getBlockTimestamp());
        }
    }

    function test_attack_familyKothWashLosesAgainstWithdrawing() public {
        (uint64 start,,, uint128 pot) = _hillOf(a);
        (uint160 sqrtA,,,) = manager.getSlot0(a.toId());
        (uint160 sqrtC,,,) = manager.getSlot0(connector.toId());
        console2.log("A's carried pot before the wash", uint256(pot));
        uint256[2] memory sizes = [uint256(1e21), 4e22];
        for (uint256 k; k < sizes.length; ++k) {
            uint256 x = sizes[k];
            assertGe(pot, x / 100, "the carried pot covers the capped prize");
            uint256 snap = vm.snapshotState();
            Actor w = _newActor();
            w.approveAll(address(subject));
            int256 before = _value(address(this), sqrtA, sqrtC) + _value(address(w), sqrtA, sqrtC);
            vm.recordLogs();
            new FamilyWasher()
                .run(
                    w,
                    _swapParams(a, ETH, true, true, x, address(w)),
                    x,
                    _swapParams(b, qb, false, true, 1, address(w)),
                    connector
                );
            Outcome memory o = _outcome(vm.getRecordedLogs());
            (, address leader,,) = _hillOf(a);
            assertEq(leader, address(w), "the washer took A's crown through the family");
            assertEq(subject.balanceOf(address(w)), 0, "the washer keeps no subject");
            _exit(start);
            uint256 prize = rules.claimable(ETH, address(w));
            int256 washed = _value(address(this), sqrtA, sqrtC) + _value(address(w), sqrtA, sqrtC) - before;
            vm.revertToState(snap);
            int256 base = _value(address(this), sqrtA, sqrtC);
            _exit(start);
            int256 plain = _value(address(this), sqrtA, sqrtC) - base;
            vm.revertToState(snap);
            console2.log("family KOTH wash: buy, arb recaptures pushed, washer claims (prize + trader legs)");
            console2.log(x, o.pushedAfter + o.pushedBefore, prize);
            console2.log("creator and washer, wash then exit against exit only (wei):");
            console2.logInt(washed - plain);
            // A 1e21 buy stays inside the family's fee band (1% on each member, 0.3% on the connector); 4e22 does not.
            if (k == 1) assertGt(o.pushedAfter, 0, "the family executor recaptured the wash's gap");
            assertGe(prize, x * 50 / 10_000, "the capped prize was paid");
            assertLt(washed, plain, "the family wash loses");
        }
    }

    function _hillOf(PoolKey memory k)
        internal
        view
        returns (uint64 start, address leader, uint128 amount, uint128 pot)
    {
        (start,, leader, amount, pot) = IHookrRecaptureRules(address(rules)).hill(k.toId());
    }
}
