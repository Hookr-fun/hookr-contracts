// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {PartnerShapedFixture} from "./utils/PartnerShapedFixture.sol";
import {LegTaxFixture} from "./utils/LegTaxFixture.sol";
import {DynamicLegReads} from "./utils/DynamicLegReads.sol";
import {IHookrRulesEvents} from "../../src/interfaces/IHookrRulesEvents.sol";

/// @notice ATK-LF-5, fixed. Arb recapture legs that move a dynamic fee pool carry its dynamic fee state as an ordinary
///         swap with the same start price, end price and quote would: the anchor moves toward the leg's end (the
///         pool's minimum dynamic fee liquidity, the rounding toward the old anchor, the counted move that restarts the
///         windows), and the reference steps or joins it by the windows. The leg itself is charged no dynamic fee. At
///         63c549f the legs left the state where it was: a buy on a static sibling was carried into the dynamic fee
///         member by the arb recapture's legs, the member's anchor stayed behind, and the next buyer was charged from
///         the stale anchor and paid less than a buyer from the same price after an ordinary trade.
contract DynamicAnchorTest is DynamicLegReads, PartnerShapedFixture {
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
        members[0].rules.maxFeePips = 50_000;
        members[0].rules.dynamicFeeSens = 5;
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
        _buy(a, ETH, minnow, 1e18); // starts the member's dynamic fee state at the launch price
        _nextBlock();
    }

    /// The pinned test of r26, turned: a buy on the static sibling, the partner-shaped arb recapture's legs carry the
    /// dynamic fee member, and the member's dynamic fee state and the next buyer's fill are what an ordinary trade to
    /// each of the legs' prices, in the same second, leaves. Exact: the same prices, the same second, and anchors that
    /// reach the executed price in both paths (the member's liquidity is a hundred times its minimum dynamic fee
    /// liquidity), so no rounding separates them.
    function test_regression_legsCarryTheAnchor_andTheNextBuyerPaysAsAfterAnOrdinaryTrade() public {
        uint256 snap = vm.snapshotState();
        int24 anc0 = _anchorTick(a);
        vm.recordLogs();
        _buy(b, qb, attacker, 5e22);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Outcome memory o = _outcome(logs);
        assertGt(o.pushedAfter, 0, "the arb recapture ran and pushed");
        LegSwap[] memory legs = _legSwaps(logs, a, address(ex));
        assertGt(legs.length, 0, "the executor legged on the dynamic fee member");
        (uint160 p2, int24 t2,,) = manager.getSlot0(a.toId());
        assertEq(legs[legs.length - 1].sqrtPrice, p2, "the last leg left the member's price");
        (, int24 ref1, int24 anc1,,,) = rules.referenceState(a.toId());
        console2.log("legs on the member", legs.length);
        console2.log("anchor tick before the legs, after them, the member's tick");
        console2.logInt(anc0);
        console2.logInt(anc1);
        console2.logInt(t2);
        assertTrue(anc1 != anc0, "the legs moved the member's anchor");
        // To the member's price, its tick rounded toward where the anchor was, as for any swap.
        assertLe(anc1 > t2 ? anc1 - t2 : t2 - anc1, 1, "to the member's price");
        bytes32 legWord = _word(a);
        registry.stopExecutorLane(address(root), address(ex));
        uint256 outLeg = _buy(a, ETH, whale, 2e22);

        // An ordinary trade to each leg's price, in the same second.
        vm.revertToState(snap);
        registry.stopExecutorLane(address(root), address(ex));
        for (uint256 i; i < legs.length; ++i) {
            _ordinaryTo(a, legs[i].sqrtPrice);
        }
        (, int24 ref2, int24 anc2,,,) = rules.referenceState(a.toId());
        assertEq(abi.encode(ref1, anc1), abi.encode(ref2, anc2), "the reference and the anchor");
        assertEq(_word(a), legWord, "the whole dynamic fee state");
        uint256 outOrdinary = _buy(a, ETH, whale, 2e22);
        console2.log("next buyer (2e22 ETH) subject out: after the legs / after ordinary trades", outLeg, outOrdinary);
        assertEq(outLeg, outOrdinary, "the next buyer gets what it gets after an ordinary trade to the same price");
    }
}

/// @notice The same property with scripted legs: before and after phase, on a sibling and on the triggering pool, twice
///         on one pool in one arb recapture, on a pool without dynamic fees, from an unstarted state, on an advised
///         pool, into an empty range, and fuzzed over leg sizes against the Rules' own ordinary path.
contract DynamicLegsTest is DynamicLegReads, LegTaxFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    HookrToken internal subject;
    /// @dev The dynamic fee member (ETH quote, currency0) and its static sibling (tokenB quote).
    PoolKey internal dyn;
    PoolKey internal stat;
    Currency internal qb;

    function setUp() public {
        _setUpLegTax();
        qb = Currency.wrap(address(tokenB));
        tokenB.transfer(address(legEx), 1e27);
        (dyn, stat) = _dynamicFamily(address(0));
        _nextBlock();
    }

    function _dynRules() internal pure returns (HookrTypes.RulesConfig memory r) {
        r = _laneRules(false);
        r.maxFeePips = 50_000;
        r.dynamicFeeSens = 5;
    }

    /// @dev A two-member lane family of a fresh subject: a dynamic fee member against ETH (bound to `advisory` in both
    ///      phases when it is not zero) and a static one against tokenB. The executor holds the subject.
    function _dynamicFamily(address advisory) internal returns (PoolKey memory d, PoolKey memory st) {
        subject = _newSubject();
        subject.transfer(address(legEx), 1e26);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _laneMember(ETH, _dynRules(), _recaptureOnlyRc());
        members[1] = _laneMember(qb, _laneRules(false), _recaptureOnlyRc());
        bytes32 family;
        if (advisory == address(0)) {
            PoolKey[] memory keys;
            (family, keys) = _launchAs(creator, subject, members);
            return (keys[0], keys[1]);
        }
        members[0].config.advisory = advisory;
        members[0].config.advisoryGasLimit = 100_000;
        members[0].config.advisoryPhases = BOTH;
        bytes[] memory data = new bytes[](2);
        data[0] = hex"01";
        vm.prank(creator);
        (family,) = launcher.launchAdvised{value: 1e24}(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            data,
            vm.getBlockTimestamp()
        );
        d = launcher.position(family, 0).key;
        st = launcher.position(family, 1).key;
    }

    /// @dev Arms one leg on `key` in the given phase at the extreme price limit.
    function _leg(bool afterPhase, PoolKey memory key, bool zeroForOne, int256 amount) internal {
        legEx.add(afterPhase, key, zeroForOne, amount, zeroForOne ? LO + 1 : HI - 1, 0);
    }

    /// @dev A 1e18 authenticated buy by the whale on `trigger` with the armed legs; returns the executor's swaps on the
    ///      dynamic fee member.
    function _trigger(PoolKey memory trigger) internal returns (LegSwap[] memory legs) {
        vm.recordLogs();
        _buy(trigger, _poolQuote(trigger), whale, 1e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Outcome memory o = _outcome(logs);
        assertEq(o.failed, 0, "both frames passed");
        legs = _legSwaps(logs, dyn, address(legEx));
    }

    /// @dev The simulation an ordinary swap from `(sqrtBefore, tickBefore)` to the leg's end is priced on.
    function _sim(uint160 sqrtBefore, int24 tickBefore, LegSwap memory l)
        internal
        pure
        returns (HookrTypes.SwapSimulation memory m)
    {
        m = HookrTypes.SwapSimulation(sqrtBefore, tickBefore, l.sqrtPrice, l.tick);
    }

    function _quoteOf(LegSwap memory l) internal pure returns (uint256) {
        return uint256(int256(l.amount0 < 0 ? -l.amount0 : l.amount0));
    }

    /// @dev One leg of `amount` on the dynamic fee member, armed in `afterPhase` and triggered on the static sibling:
    ///      the leg's word must be the Rules' ordinary path from the same start, to the same end, with the same quote.
    function _legMatchesTheModel(bool afterPhase, bool zeroForOne, int256 amount) internal returns (LegSwap memory) {
        bytes32 start = _word(dyn);
        (uint160 p0, int24 t0,,) = manager.getSlot0(dyn.toId());
        legEx.clear();
        _leg(afterPhase, dyn, zeroForOne, amount);
        LegSwap[] memory legs = _trigger(stat);
        assertEq(legs.length, 1, "one leg on the member");
        bytes32 legWord = _word(dyn);
        bytes32 modelled =
            _modelWord(dyn, address(legEx), start, _sim(p0, t0, legs[0]), zeroForOne, amount, _quoteOf(legs[0]));
        assertEq(legWord, modelled, "the leg's state is the ordinary path's for its start, end and quote");
        return legs[0];
    }

    /// @dev After the armed legs moved the member, the member's state and the next buyer's fill equal what ordinary
    ///      trades to the legs' prices leave in the same second.
    function _nextBuyerAsAfterOrdinaryTrades(uint256 snap, LegSwap[] memory legs) internal {
        bytes32 legWord = _word(dyn);
        legEx.clear();
        uint256 outLeg = _buy(dyn, ETH, minnow, 3e21);
        bytes32 legNext = _word(dyn);
        vm.revertToState(snap);
        legEx.clear();
        for (uint256 i; i < legs.length; ++i) {
            _ordinaryTo(dyn, legs[i].sqrtPrice);
        }
        assertEq(_word(dyn), legWord, "the state ordinary trades to the same prices leave");
        uint256 outOrdinary = _buy(dyn, ETH, minnow, 3e21);
        assertEq(outLeg, outOrdinary, "the next buyer's fill");
        assertEq(_word(dyn), legNext, "and the state the next buyer leaves");
    }

    function _startState() internal {
        _buy(dyn, ETH, minnow, 1e18); // starts the member's dynamic fee state at the launch price
        _nextBlock();
    }

    /// A before-phase buy leg on the dynamic fee member, from the static sibling's arb recapture.
    function test_regression_beforePhaseLegOnASibling_carriesTheStateAsAnOrdinarySwap() public {
        _startState();
        uint256 snap = vm.snapshotState();
        int24 anc0 = _anchorTick(dyn);
        _legMatchesTheModel(false, true, -3e22);
        (, int24 tick,,) = manager.getSlot0(dyn.toId());
        int24 anc1 = _anchorTick(dyn);
        assertTrue(anc1 != anc0, "the anchor moved");
        assertLe(anc1 > tick ? anc1 - tick : tick - anc1, 1, "to the leg's end, rounded toward where it was");
        vm.revertToState(snap);
        legEx.clear();
        _leg(false, dyn, true, -3e22);
        LegSwap[] memory legs = _trigger(stat);
        _nextBuyerAsAfterOrdinaryTrades(snap, legs);
    }

    /// An after-phase sell leg on the dynamic fee member.
    function test_regression_afterPhaseLegOnASibling_carriesTheStateAsAnOrdinarySwap() public {
        _startState();
        uint256 snap = vm.snapshotState();
        _legMatchesTheModel(true, false, -3e22);
        vm.revertToState(snap);
        legEx.clear();
        _leg(true, dyn, false, -3e22);
        LegSwap[] memory legs = _trigger(stat);
        _nextBuyerAsAfterOrdinaryTrades(snap, legs);
    }

    /// Exact-output legs, both ways.
    function test_regression_exactOutputLegs_carryTheStateAsAnOrdinarySwap() public {
        _startState();
        uint256 snap = vm.snapshotState();
        _legMatchesTheModel(false, true, 2e22);
        vm.revertToState(snap);
        _legMatchesTheModel(true, false, 2e22);
    }

    /// A leg on the triggering pool itself: a before-phase sell leg ahead of the trigger's buy, and an after-phase sell
    /// leg behind it. The trigger and the next buyer are priced from the state the legs left, as after ordinary trades.
    function test_regression_legsOnTheTriggeringPool_carryTheStateInBothPhases() public {
        _startState();
        uint256 snap = vm.snapshotState();
        legEx.clear();
        _leg(false, dyn, false, -2e22);
        _leg(true, dyn, false, -1e22);
        vm.recordLogs();
        uint256 outTrigger = _buy(dyn, ETH, whale, 1e21);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_outcome(logs).failed, 0, "both frames passed");
        LegSwap[] memory legs = _legSwaps(logs, dyn, address(legEx));
        assertEq(legs.length, 2, "a leg in each phase");
        bytes32 legWord = _word(dyn);
        legEx.clear();
        uint256 outNext = _buy(dyn, ETH, minnow, 3e21);

        vm.revertToState(snap);
        legEx.clear();
        _ordinaryTo(dyn, legs[0].sqrtPrice);
        assertEq(_buy(dyn, ETH, whale, 1e21), outTrigger, "the trigger is priced from the carried state");
        _ordinaryTo(dyn, legs[1].sqrtPrice);
        assertEq(_word(dyn), legWord, "the state");
        assertEq(_buy(dyn, ETH, minnow, 3e21), outNext, "the next buyer");
    }

    /// A cycle that crosses the dynamic fee member twice in one arb recapture: buy on it, sell on the sibling, buy on it
    /// again. Each leg carries the state from where the one before left it, as two ordinary trades do.
    function test_regression_aCycleCrossingTheMemberTwice_carriesTheStateTwice() public {
        _startState();
        uint256 snap = vm.snapshotState();
        legEx.clear();
        bool statSell = Currency.unwrap(stat.currency0) == address(subject);
        _leg(true, dyn, true, -2e22);
        _leg(true, stat, statSell, -1e22);
        _leg(true, dyn, true, -4e22);
        LegSwap[] memory legs = _trigger(stat);
        assertEq(legs.length, 2, "two legs on the member in one frame");
        _nextBuyerAsAfterOrdinaryTrades(snap, legs);
    }

    /// Legs on a pool without dynamic fees touch no dynamic fee state: the static sibling's word stays zero, legs there
    /// from the member's own arb recapture leave it zero, and the member's word stays where legs elsewhere found it.
    function test_legsOnAPoolWithoutDynamicFees_touchNoState() public {
        _startState();
        legEx.clear();
        _leg(false, stat, true, -1e20);
        _leg(true, stat, false, -1e20);
        vm.recordLogs();
        _buy(dyn, ETH, whale, 1e18);
        assertEq(_legSwaps(vm.getRecordedLogs(), stat, address(legEx)).length, 2, "both legs ran");
        assertEq(_word(stat), bytes32(0), "the static sibling has no dynamic fee state");
        _nextBlock();
        bytes32 memberWord = _word(dyn);
        legEx.clear();
        _leg(false, stat, true, -1e20);
        _leg(true, stat, false, -1e20);
        vm.recordLogs();
        _buy(stat, qb, whale, 1e18);
        assertEq(_legSwaps(vm.getRecordedLogs(), stat, address(legEx)).length, 2, "both legs ran");
        assertEq(_word(stat), bytes32(0), "still none");
        assertEq(_word(dyn), memberWord, "the member's state is untouched by legs elsewhere");
    }

    /// The leg's own gas on the static sibling and on the dynamic fee member, from the same state, for the report. On
    /// the static sibling it is what 63c549f spends (54,400 for this exact-input sell of 1e20 at a 1% base fee).
    function test_legGas_staticAndDynamicMembers() public {
        _startState();
        string[4] memory shapes = ["exact-input sell", "exact-input buy", "exact-output buy", "exact-output sell"];
        bool[4] memory z = [false, true, true, false];
        int256[4] memory amt = [int256(-1e20), int256(-1e20), int256(1e20), int256(1e20)];
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 4; ++i) {
            vm.revertToState(snap);
            legEx.clear();
            _leg(false, stat, z[i], amt[i]);
            _buy(dyn, ETH, whale, 1e18);
            uint256 gStatic = legEx.legGas();
            vm.revertToState(snap);
            legEx.clear();
            _leg(false, dyn, z[i], amt[i]);
            _buy(stat, qb, whale, 1e18);
            uint256 gDynamic = legEx.legGas();
            console2.log(shapes[i]);
            console2.log("  leg gas: static member / dynamic fee member", gStatic, gDynamic);
            assertLt(gDynamic, gStatic + 60_000, "a dynamic fee leg's carry stays within 60,000 gas");
        }
    }

    /// The same for a dynamic fee member bound to the stand-in advisory (zero take, both phases): the advised leg's
    /// own gas, from the same state, for the report.
    function test_legGas_advisedDynamicMember() public {
        tax.set(0, 0);
        (dyn, stat) = _dynamicFamily(address(tax));
        _nextBlock();
        _startState();
        string[4] memory shapes = ["exact-input sell", "exact-input buy", "exact-output buy", "exact-output sell"];
        bool[4] memory z = [false, true, true, false];
        int256[4] memory amt = [int256(-1e20), int256(-1e20), int256(1e20), int256(1e20)];
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 4; ++i) {
            vm.revertToState(snap);
            legEx.clear();
            _leg(false, dyn, z[i], amt[i]);
            _buy(stat, qb, whale, 1e18);
            assertEq(legEx.legs(), 1, "the leg ran");
            console2.log(shapes[i]);
            console2.log("  leg gas: advised dynamic fee member", legEx.legGas());
        }
    }

    /// An unstarted state (no swap on the member since its launch): the leg starts it at its own start, as an ordinary
    /// swap would, and carries it.
    function test_regression_aLegOnAnUnstartedState_startsItAsAnOrdinarySwap() public {
        assertEq(_word(dyn) >> 248, bytes32(0), "unstarted");
        uint256 snap = vm.snapshotState();
        _legMatchesTheModel(false, true, -3e22);
        assertTrue(_word(dyn) >> 248 != bytes32(0), "started by the leg");
        vm.revertToState(snap);
        legEx.clear();
        _leg(false, dyn, true, -3e22);
        LegSwap[] memory legs = _trigger(stat);
        _nextBuyerAsAfterOrdinaryTrades(snap, legs);
    }

    /// A launch buy (the dev buy) leaves the state unstarted; a sell leg on the member in a later transaction starts it
    /// at the leg's start, where the launch buy left the price, and carries it, as an ordinary sell would.
    function test_regression_aLegAfterTheLaunchBuy_startsTheStateAsAnOrdinarySwap() public {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        IHookrLauncher.Member memory m = _laneMember(ETH, _dynRules(), _recaptureOnlyRc());
        m.rules.guardEndBlock = uint40(vm.getBlockNumber() + 100_000);
        m.rules.snipeTaxPips = 500_000;
        m.rules.maxBuyQuoteAmount = 1e22;
        m.tickLower = -60_000;
        m.tickUpper = 0;
        uint160 lower = TickMath.getSqrtPriceAtTick(-60_000);
        m.liquidity = LiquidityAmounts.getLiquidityForAmount1(lower, SQRT_ONE, 9.65e26) / 1000 * 999;
        m.amount0Max = 0;
        m.amount1Max = 9.65e26;
        members[0] = m;
        members[1] = _laneMember(qb, _laneRules(false), _recaptureOnlyRc());
        tokenB.approve(address(launcher), type(uint256).max);
        (bytes32 family,, uint256 devOut) = launcher.launchWithBuy{value: 1e21}(
            IHookrLauncher.Token(address(0), "New", "NEW", 1e27, bytes32(uint256(79))),
            address(root),
            members,
            new bytes[](2),
            IHookrLauncher.DevBuy(0, 1e21, 1, 0),
            vm.getBlockTimestamp()
        );
        dyn = launcher.position(family, 0).key;
        stat = launcher.position(family, 1).key;
        subject = HookrToken(Currency.unwrap(_subjectOf(dyn)));
        subject.transfer(address(legEx), devOut);
        _nextBlock();
        assertEq(_word(dyn) >> 248, bytes32(0), "the launch buy left the state unstarted");
        uint256 snap = vm.snapshotState();
        (uint160 p0,,,) = manager.getSlot0(dyn.toId());
        _legMatchesTheModel(false, false, -int256(devOut / 4));
        assertTrue(_word(dyn) >> 248 != bytes32(0), "started by the leg");
        (uint160 end,,,) = manager.getSlot0(dyn.toId());
        assertGt(end, p0, "the sell leg moved the price back up");
        assertEq(manager.getLiquidity(dyn.toId()) != 0, true, "inside the band");
        bytes32 legWord = _word(dyn);
        vm.revertToState(snap);
        legEx.clear();
        _ordinaryTo(dyn, end);
        assertEq(_word(dyn), legWord, "the state an ordinary sell to the same price leaves");
    }

    /// A leg on a dynamic fee member with an advisory takes the root's own path (its surcharge and take) and carries the
    /// state the same way.
    function test_regression_advisedLeg_carriesTheStateAsAnOrdinarySwap() public {
        tax.set(TAX, TAX);
        (dyn, stat) = _dynamicFamily(address(tax));
        _nextBlock();
        _startState();
        uint256 snap = vm.snapshotState();
        uint256 s0 = rules.claimable(ETH, tax.SELL_TO());
        _legMatchesTheModel(true, false, -3e22);
        assertGt(rules.claimable(ETH, tax.SELL_TO()), s0, "the leg paid the advisory's take");
        vm.revertToState(snap);
        legEx.clear();
        _leg(true, dyn, false, -3e22);
        LegSwap[] memory legs = _trigger(stat);
        _nextBuyerAsAfterOrdinaryTrades(snap, legs);
    }

    /// A leg that ends at its price limit in an empty range crossed that range for free: it carries the anchor no
    /// further than the last price with liquidity, the band's edge, as an ordinary swap to the same limit does.
    function test_regression_aLegIntoAnEmptyRange_carriesTheAnchorOnlyToTheBandsEdge() public {
        _startState();
        uint256 snap = vm.snapshotState();
        uint160 limit = TickMath.getSqrtPriceAtTick(-70_020);
        legEx.clear();
        legEx.add(false, dyn, true, -1e26, limit, 0); // a buy: ETH in, the price falls through the band's lower edge
        LegSwap[] memory legs = _trigger(stat);
        assertEq(legs.length, 1, "the leg ran");
        assertEq(legs[0].sqrtPrice, limit, "it stopped at its limit");
        assertEq(manager.getLiquidity(dyn.toId()), 0, "in an empty range");
        bytes32 legWord = _word(dyn);
        assertEq(_anchorTick(dyn), -60_000, "the anchor stops at the band's edge");
        vm.revertToState(snap);
        legEx.clear();
        _ordinaryTo(dyn, limit);
        assertEq(_word(dyn), legWord, "the state an ordinary swap to the same limit leaves");
    }

    /// The carry never fails a leg. With the Rules refusing it the leg runs, gets what it gets without the refusal,
    /// and the state stays where it was; with the empty range probe refused the leg runs and the state stays too.
    function test_theCarryIsFailOpen() public {
        _startState();
        uint256 snap = vm.snapshotState();
        bytes32 before = _word(dyn);
        legEx.clear();
        _leg(false, dyn, true, -3e22);
        _trigger(stat);
        int256 out = legEx.last1();
        vm.revertToState(snap);
        vm.mockCallRevert(address(rules), abi.encodePacked(CARRY_LEG), "refused");
        legEx.clear();
        _leg(false, dyn, true, -3e22);
        LegSwap[] memory legs = _trigger(stat);
        assertEq(legs.length, 1, "the leg ran");
        assertEq(legEx.last1(), out, "and got what it gets");
        assertEq(_word(dyn), before, "the state stayed");
        vm.clearMockedCalls();

        vm.revertToState(snap);
        uint160 limit = TickMath.getSqrtPriceAtTick(-70_020);
        (uint160 p0,,,) = manager.getSlot0(dyn.toId());
        vm.mockCallRevert(address(root), abi.encode(dyn, SwapParams(false, -1, p0), uint24(BASE_FEE)), "probe refused");
        legEx.clear();
        legEx.add(false, dyn, true, -1e26, limit, 0);
        legs = _trigger(stat);
        assertEq(legs.length, 1, "the leg into the empty range ran");
        assertEq(_word(dyn), before, "the state stayed");
    }

    /// Starving a leg that ends inside the pool's liquidity, which needs no probe: at every grant the leg either
    /// reverts or completes with the state carried. The carry is never skipped by such a leg that completes.
    function test_aStarvedInBandLegCannotSkipTheCarry() public {
        _startState();
        uint256 snap = vm.snapshotState();
        bytes32 before = _word(dyn);
        legEx.clear();
        _leg(false, dyn, true, -3e22);
        _trigger(stat);
        bytes32 carried = _word(dyn);
        assertTrue(carried != before, "carried");
        uint256 completed;
        uint256 reverted;
        for (uint256 g = 60_000; g <= 200_000; g += 500) {
            vm.revertToState(snap);
            legEx.clear();
            legEx.add(false, dyn, true, -3e22, LO + 1, g);
            _buy(stat, qb, whale, 1e18);
            if (legEx.legs() == 1) {
                ++completed;
                assertEq(_word(dyn), carried, "a completed leg carried the state");
            } else {
                ++reverted;
                assertEq(_word(dyn), before, "a reverted leg left it");
            }
        }
        console2.log("grants 60,000 to 200,000 by 500: completed, reverted", completed, reverted);
        assertGt(completed, 0);
        assertGt(reverted, 0);
    }

    struct Starved {
        uint256 carried;
        uint256 skipped;
        uint256 reverted;
        uint256 firstSkip;
        uint256 lastSkip;
        uint256 leastCarried;
        uint256 cost;
    }

    /// Starving a leg that stops at its price limit in an empty range, which runs the probe (a call with all but 1/64
    /// of the gas left, two frames down, over the empty bitmap the leg crossed): what it does, not a guarantee. A
    /// probe that runs out of gas finds no end, the carry is skipped as for a refused probe, and the gas left can
    /// finish the leg, so such a leg can complete with the state where it was. Only the executor sets a leg's gas.
    /// At every grant the leg's own swap is the unstarved leg's to the wei and the state is either carried in full or
    /// untouched. Skips and reverts interleave below the least grant that carries, and every grant from it up carries.
    /// A grant of exactly the gas the leg used with no cap can still starve the probe, since each call keeps 1/64 of
    /// the gas back; in these sweeps the least grant that carries is under a 63rd over that cost. Into the band's
    /// shallow empty range: the band's lower edge at -60,000 and the limit at -70,020.
    function test_aStarvedLegIntoAnEmptyRange_canCompleteWithoutTheCarry() public {
        _startState();
        Starved memory s = _starveIntoTheEmptyRange(TickMath.getSqrtPriceAtTick(-70_020), 150_000, 250);
        console2.log("carried, skipped, reverted", s.carried, s.skipped, s.reverted);
        console2.log("first skip, last skip, least carried grant", s.firstSkip, s.lastSkip, s.leastCarried);
        console2.log("the leg's unstarved cost", s.cost);
        assertGt(s.skipped, 0, "a starved probe can leave the leg standing without the carry");
    }

    /// The same to the price floor, where the probe scans the whole empty bitmap below the band.
    function test_aStarvedLegToThePriceFloor_canCompleteWithoutTheCarry() public {
        _startState();
        Starved memory s = _starveIntoTheEmptyRange(LO + 1, 400_000, 1_000);
        console2.log("carried, skipped, reverted", s.carried, s.skipped, s.reverted);
        console2.log("first skip, last skip, least carried grant", s.firstSkip, s.lastSkip, s.leastCarried);
        console2.log("the leg's unstarved cost", s.cost);
        assertGt(s.skipped, 0, "a starved probe can leave the leg standing without the carry");
    }

    /// Sweeps the leg's grant from `below` under its unstarved cost (the gas the leg used with no cap) to 40,000 over
    /// it in steps of `step`.
    function _starveIntoTheEmptyRange(uint160 limit, uint256 below, uint256 step) internal returns (Starved memory s) {
        uint256 snap = vm.snapshotState();
        bytes32 before = _word(dyn);
        legEx.clear();
        legEx.add(false, dyn, true, -1e26, limit, 0);
        LegSwap[] memory legs = _trigger(stat);
        assertEq(legs.length, 1, "the leg ran");
        assertEq(legs[0].sqrtPrice, limit, "it stopped at its limit");
        assertEq(manager.getLiquidity(dyn.toId()), 0, "in an empty range");
        bytes32 carried = _word(dyn);
        assertTrue(carried != before, "carried");
        (int256 out0, int256 out1, uint256 cost) = (legEx.last0(), legEx.last1(), legEx.legGas());
        s.cost = cost;
        for (uint256 g = cost - below; g <= cost + 40_000; g += step) {
            vm.revertToState(snap);
            legEx.clear();
            legEx.add(false, dyn, true, -1e26, limit, g);
            _buy(stat, qb, whale, 1e18);
            bytes32 word = _word(dyn);
            if (legEx.legs() == 0) {
                ++s.reverted;
                assertEq(s.carried, 0, "a revert only below every grant that carries");
                assertEq(word, before, "a reverted leg left the state");
                continue;
            }
            assertEq(legEx.last0(), out0, "the leg's swap is the unstarved leg's");
            assertEq(legEx.last1(), out1, "the leg's swap is the unstarved leg's");
            if (word == carried) {
                ++s.carried;
                if (s.leastCarried == 0) s.leastCarried = g;
            } else {
                assertEq(s.carried, 0, "a skip only below every grant that carries");
                assertEq(word, before, "a skipped carry left the state byte for byte");
                assertLt(g, cost + cost / 63, "from a 63rd over the leg's unstarved cost the carry is made");
                ++s.skipped;
                if (s.firstSkip == 0) s.firstSkip = g;
                s.lastSkip = g;
            }
        }
        vm.revertToState(snap);
    }

    /// Fuzzed over leg sizes, both directions and both shapes, in either phase: the leg's state is the Rules' ordinary
    /// path for the leg's start, end and quote, to the bit. Where the leg's quote pays the anchor's way to its end at
    /// the pool's minimum dynamic fee liquidity (the anchor then reaches the end; the member's liquidity is a hundred
    /// times that minimum, so all but the smallest legs do), an ordinary trade to the same price, whose quote is
    /// larger by its fees, carries it there too and leaves the same state. Below that the anchor moves only as far as
    /// the leg's own quote pays, less far than the ordinary trade's larger quote would, and the leg is held to the
    /// ordinary path at its own quote only.
    function testFuzz_legStateIsTheOrdinaryState(uint256 size, bool zeroForOne, bool exactInput, bool afterPhase)
        public
    {
        _startState();
        size = bound(size, 1e12, 3e23);
        int256 amount = exactInput ? -int256(size) : int256(size);
        uint256 snap = vm.snapshotState();
        (uint256 minLiquidity,, int24 anc0,,,) = rules.referenceState(dyn.toId());
        LegSwap memory l = _legMatchesTheModel(afterPhase, zeroForOne, amount);
        bytes32 legWord = _word(dyn);
        (uint160 end,,,) = manager.getSlot0(dyn.toId());
        uint256 required =
            SqrtPriceMath.getAmount0Delta(TickMath.getSqrtPriceAtTick(anc0), end, uint128(minLiquidity), true);
        if (_quoteOf(l) < required) return;
        vm.revertToState(snap);
        legEx.clear();
        _ordinaryTo(dyn, end);
        assertEq(_word(dyn), legWord, "the state an ordinary trade to the same price leaves");
    }

    /// carryLeg is the Rules' own code behind their fallback: not in the dispatcher (so every other pool dispatches as
    /// before), not the recapture module's, root only, and exact in its input.
    function test_carryLegIsTheRulesOwn_rootOnly() public {
        assertFalse(_has("HookrRules", CARRY_LEG), "not in the Rules' dispatcher");
        assertFalse(_has("HookrRecapture", CARRY_LEG), "not the module's");
        HookrTypes.SwapContext memory x;
        HookrTypes.SwapSimulation memory m;
        (bool ok, bytes memory err) = address(rules).call(abi.encodeWithSelector(CARRY_LEG, x, m, uint256(0)));
        assertFalse(ok);
        assertEq(bytes4(err), IHookrRulesEvents.UnknownPool.selector, "an unbound pool");
        x.id = dyn.toId();
        (ok, err) = address(rules).call(abi.encodeWithSelector(CARRY_LEG, x, m, uint256(0)));
        assertFalse(ok);
        assertEq(bytes4(err), IHookrRulesEvents.Unauthorized.selector, "a caller other than the root");
        vm.prank(address(root));
        (ok, err) = address(rules).call(abi.encodePacked(abi.encodeWithSelector(CARRY_LEG, x, m, uint256(0)), uint8(0)));
        assertFalse(ok);
        assertEq(bytes4(err), IHookrRulesEvents.InvalidSettlement.selector, "an input of another length");
    }

    function _has(string memory name, bytes4 selector) internal view returns (bool) {
        string memory json = vm.readFile(string.concat("out/", name, ".sol/", name, ".json"));
        string[] memory sigs = vm.parseJsonKeys(json, ".methodIdentifiers");
        for (uint256 i; i < sigs.length; ++i) {
            if (bytes4(keccak256(bytes(sigs[i]))) == selector) return true;
        }
        return false;
    }
}
