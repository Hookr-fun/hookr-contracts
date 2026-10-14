// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {EconomicsSecurityBase, BandLp} from "../utils/EconomicsSecurityBase.sol";
import {DustRangeSwapper} from "../utils/DustRangeSwapper.sol";
import {RulesData} from "../utils/RulesData.sol";

/// DF-04: the anchor, the reference windows and the edges of liquidity.
/// - The anchor moves to the executed price, never past the distance the swap was charged to reach, so a free push
///   across an empty gap followed by a small real swap does not carry the anchor past the gap.
/// - The reference's windows count only anchor moves of at least `moveTicks`, so small back-and-forth swaps do not
///   hold it; its steps depend only on time, so dust swaps do not speed its decay.
/// - A simulation that runs out of liquidity is priced to the last price with liquidity, not to its price limit.
/// Pure dynamic fee pool unless stated: base 3,000, maxFee 100,000, sens 5, protocol share 2,500, launch liquidity
/// 1e24 at spacing 60, quote currency0 (a buy is zeroForOne and moves the price down).
contract HookrDynamicFeeAnchorAndEdgesTest is EconomicsSecurityBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    DustRangeSwapper internal swapper;
    BandLp internal lp;
    address internal attacker = address(0xBAD);
    address internal victim = address(0xB0B);

    function setUp() public override {
        super.setUp();
        swapper = new DustRangeSwapper(manager);
        lp = new BandLp(manager);
        tokenA.transfer(address(swapper), 1e18);
        tokenB.transfer(address(swapper), 1e18);
        tokenA.transfer(address(lp), 1e27);
        tokenB.transfer(address(lp), 1e27);
        _fund(attacker);
        _fund(victim);
    }

    function _fund(address who) internal {
        tokenA.transfer(who, 1e27);
        tokenB.transfer(who, 1e27);
        vm.startPrank(who);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _open(IHookrLauncher.Member memory m, bool subjectFirst) internal returns (PoolKey memory key) {
        (key,,) = _launchMember(m, subjectFirst);
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _swapAs(address who, PoolKey memory key, bool buy, bool exactInput, uint128 amount)
        internal
        returns (HookrTypes.ExecutionReceipt memory r, uint256 input, uint256 output)
    {
        IHookrRouter.Swap memory p = _swap(key, buy, exactInput, amount);
        p.recipient = who;
        r = quoter.quote(p, who);
        vm.prank(who);
        (input, output) = router.swap(p, address(0), new uint256[](0));
        assertEq(input, r.inputAmount, "quote input");
        assertEq(output, r.outputAmount, "quote output");
    }

    function _tick(PoolKey memory key) internal view returns (int24 t) {
        (, t,,) = manager.getSlot0(key.toId());
    }

    function _anchor(PoolKey memory key) internal view returns (int24 a) {
        (,, a,,,) = rules.referenceState(key.toId());
    }

    // ------------------------------------------------------------------------------------------------------------
    // 1. A free push across an empty gap, then a small real swap, does not move the anchor past the gap.
    // ------------------------------------------------------------------------------------------------------------

    struct Gap {
        uint256 ctlFee;
        uint256 ctlOut;
        uint256 atkBuyFee;
        uint256 victimFee;
        uint256 victimOut;
        int24 anchor;
    }

    /// Launch band [-60000, bandTop] with the price at tick 0: a gap of -bandTop ticks along the buy. Control: after
    /// `wait` the victim buys and crosses the gap itself. Attack: a 1-wei swap carries the price across the gap, the
    /// attacker buys `reanchor`, and after `wait` the victim buys.
    function _gapRun(int24 bandTop, uint128 reanchor, uint256 wait, uint128 victimAmt) internal returns (Gap memory g) {
        uint256 fresh = vm.snapshotState();
        IHookrLauncher.Member memory m = _dynamicFeeMember(Currency.wrap(address(0)));
        m.tickLower = -60_000;
        m.tickUpper = bandTop;
        PoolKey memory key = _open(m, false);
        uint256 snap = vm.snapshotState();
        vm.warp(vm.getBlockTimestamp() + wait);
        (HookrTypes.ExecutionReceipt memory c,, uint256 co) = _swapAs(victim, key, true, true, victimAmt);
        g.ctlFee = c.lpFeePips;
        g.ctlOut = co;
        vm.revertToState(snap);
        vm.prank(attacker);
        swapper.swap(key, true, -1, TickMath.getSqrtPriceAtTick(bandTop));
        assertApproxEqAbs(int256(_tick(key)), int256(bandTop), 1, "parked at the band top");
        (HookrTypes.ExecutionReceipt memory a,,) = _swapAs(attacker, key, true, true, reanchor);
        g.atkBuyFee = a.lpFeePips;
        g.anchor = _anchor(key);
        vm.warp(vm.getBlockTimestamp() + wait);
        (HookrTypes.ExecutionReceipt memory v,, uint256 vo) = _swapAs(victim, key, true, true, victimAmt);
        g.victimFee = v.lpFeePips;
        g.victimOut = vo;
        vm.revertToState(fresh);
    }

    function _logGap(Gap memory g) internal {
        emit log_named_uint("  control LP fee (victim crosses the gap)", g.ctlFee);
        emit log_named_uint("  attacker re-anchor buy LP fee", g.atkBuyFee);
        emit log_named_int("  anchor tick after the re-anchor buy", g.anchor);
        emit log_named_uint("  victim LP fee after push + re-anchor", g.victimFee);
        emit log_named_uint("  control subject out", g.ctlOut);
        emit log_named_uint("  victim subject out", g.victimOut);
    }

    /// Gaps of 600, 1,200 and 3,000 ticks, a 1e21 re-anchor buy, a 1e22 victim: the victim pays no more than a buyer
    /// who crosses the gap itself.
    function testGapPushThenSmallBuyDoesNotReanchor() public {
        int24[3] memory tops = [int24(-600), -1200, -3000];
        for (uint256 i; i < tops.length; ++i) {
            emit log_named_int("gap (ticks along the buy)", -tops[i]);
            Gap memory g = _gapRun(tops[i], 1e21, 0, 1e22);
            _logGap(g);
            assertLe(g.victimFee, g.ctlFee, "no more than the control");
            assertGe(g.victimOut, g.ctlOut, "no less subject than the control");
        }
    }

    /// The same on the 600-tick gap for re-anchor buys from 1e20 to 2e21, and for victims 29, 31, 119 and 121 seconds
    /// later.
    function testGapPushReanchorSizesAndWaits() public {
        uint128[4] memory sizes = [uint128(1e20), 3e20, 5e20, 2e21];
        for (uint256 i; i < sizes.length; ++i) {
            emit log_named_uint("re-anchor size", sizes[i]);
            Gap memory g = _gapRun(-600, sizes[i], 0, 1e22);
            _logGap(g);
            assertLe(g.victimFee, g.ctlFee, "no more than the control");
        }
        uint256[4] memory waits = [uint256(29), 31, 119, 121];
        for (uint256 i; i < waits.length; ++i) {
            emit log_named_uint("wait (s)", waits[i]);
            Gap memory g = _gapRun(-600, 1e21, waits[i], 1e22);
            _logGap(g);
            assertLe(g.victimFee, g.ctlFee, "no more than the control");
        }
    }

    /// Both directions and both exact-input and exact-output victims on a 600-tick gap along the victim's side.
    function testGapPushBothDirectionsAndExactOutput() public {
        bool[2] memory flags = [true, false];
        for (uint256 i; i < 2; ++i) {
            for (uint256 j; j < 2; ++j) {
                bool buy = flags[i];
                bool exactInput = flags[j];
                uint128 amount = exactInput ? 1e22 : 9e21;
                uint256 fresh = vm.snapshotState();
                IHookrLauncher.Member memory m = _dynamicFeeMember(Currency.wrap(address(0)));
                (m.tickLower, m.tickUpper) = buy ? (int24(-60_000), int24(-600)) : (int24(600), int24(60_000));
                PoolKey memory key = _open(m, false);
                uint256 snap = vm.snapshotState();
                (HookrTypes.ExecutionReceipt memory c,,) = _swapAs(victim, key, buy, exactInput, amount);
                vm.revertToState(snap);
                vm.prank(attacker);
                swapper.swap(key, buy, -1, TickMath.getSqrtPriceAtTick(buy ? int24(-600) : int24(600)));
                _swapAs(attacker, key, buy, true, 1e21);
                (HookrTypes.ExecutionReceipt memory v,,) = _swapAs(victim, key, buy, exactInput, amount);
                emit log_string(string.concat(buy ? "buy" : "sell", exactInput ? " exact in" : " exact out"));
                emit log_named_uint("  control LP fee", c.lpFeePips);
                emit log_named_uint("  after the push and the re-anchor buy", v.lpFeePips);
                assertLe(v.lpFeePips, c.lpFeePips, "no more than the control");
                vm.revertToState(fresh);
            }
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // 2. The anchor lands on the executed price, not on the simulation's end.
    // ------------------------------------------------------------------------------------------------------------

    /// An exact-input buy (whose simulation overstates its move) and an exact-output buy of the same executed move
    /// (whose simulation is exact) leave the same anchor, so the next buyer after the reset pays the same.
    function _overshoot(IHookrLauncher.Member memory m, uint128 first, uint128 second) internal {
        PoolKey memory key = _open(m, false);
        uint256 snap = vm.snapshotState();
        (HookrTypes.ExecutionReceipt memory a1,,) = _swapAs(attacker, key, true, true, first);
        int24 realA = _tick(key);
        int24 anchorA = _anchor(key);
        vm.warp(vm.getBlockTimestamp() + _dynamicFeeReset() + 1);
        (HookrTypes.ExecutionReceipt memory va,,) = _swapAs(victim, key, true, true, second);
        vm.revertToState(snap);
        _swapAs(attacker, key, true, false, uint128(a1.outputAmount));
        int24 realB = _tick(key);
        int24 anchorB = _anchor(key);
        vm.warp(vm.getBlockTimestamp() + _dynamicFeeReset() + 1);
        (HookrTypes.ExecutionReceipt memory vb,,) = _swapAs(victim, key, true, true, second);
        emit log_named_int("exact input: executed tick", realA);
        emit log_named_int("exact input: anchor tick  ", anchorA);
        emit log_named_int("exact output: executed tick", realB);
        emit log_named_int("exact output: anchor tick  ", anchorB);
        emit log_named_uint("next buyer after the reset, exact input first ", va.lpFeePips);
        emit log_named_uint("next buyer after the reset, exact output first", vb.lpFeePips);
        assertApproxEqAbs(realA, realB, 1, "same executed price");
        assertApproxEqAbs(anchorA, realA, 1, "the anchor is the executed price (exact input)");
        assertApproxEqAbs(anchorB, realB, 1, "the anchor is the executed price (exact output)");
        assertApproxEqRel(va.lpFeePips, vb.lpFeePips, 0.002e18, "the next buyer pays the same");
    }

    /// The widest span the reach bound admits at sensitivity 10 (HookrDynamicFee.withinReach).
    function testAnchorIsTheExecutedPriceAtTheWidestSpan() public {
        IHookrLauncher.Member memory m = _dynamicFeeMember(Currency.wrap(address(0)));
        m.rules.maxFeePips = uint24(3000 + RulesData.maxDynamicFeeSpan(10, 2_500, 3000));
        m.rules.dynamicFeeSens = 10;
        _overshoot(m, 5e22, 5e22);
    }

    function testAnchorIsTheExecutedPriceAtTheDefaults() public {
        _overshoot(_dynamicFeeMember(Currency.wrap(address(0))), 1e23, 1e23);
    }

    /// Launch band [-60000, -1500] with the price at tick 0 and a third-party band [-1200, -600]: empty gaps on both
    /// sides of that band along the buy. The attacker buys through the band with a price limit inside the far gap, so
    /// its swap ends in empty range it was not charged for. The anchor stops at the band's edge, where the charge
    /// stopped, and the next buyer pays no more than after the same buy with its limit at that edge.
    function _limitInGap(int24 limitTick) internal returns (int24 anchor, uint256 victimFee) {
        uint256 fresh = vm.snapshotState();
        IHookrLauncher.Member memory m = _dynamicFeeMember(Currency.wrap(address(0)));
        m.tickLower = -60_000;
        m.tickUpper = -1500;
        PoolKey memory key = _open(m, false);
        lp.modify(key, -1200, -600, 1e23);
        IHookrRouter.Swap memory p = _swap(key, true, true, 1e22);
        p.recipient = attacker;
        p.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(limitTick);
        vm.prank(attacker);
        router.swap(p, address(0), new uint256[](0));
        assertApproxEqAbs(_tick(key), limitTick, 1, "the attacker's buy ends at its limit");
        anchor = _anchor(key);
        (HookrTypes.ExecutionReceipt memory v,,) = _swapAs(victim, key, true, true, 1e22);
        victimFee = v.lpFeePips;
        vm.revertToState(fresh);
    }

    function testBuyEndingInAnEmptyGapDoesNotCarryTheAnchorIntoIt() public {
        (int24 edgeAnchor, uint256 edgeFee) = _limitInGap(-1200);
        (int24 gapAnchor, uint256 gapFee) = _limitInGap(-1400);
        emit log_named_int("anchor, limit at the band's edge", edgeAnchor);
        emit log_named_int("anchor, limit inside the gap    ", gapAnchor);
        emit log_named_uint("next buyer LP fee, limit at the edge", edgeFee);
        emit log_named_uint("next buyer LP fee, limit in the gap ", gapFee);
        assertGe(gapAnchor, -1201, "the anchor stays at the band's edge");
        assertLe(gapFee, edgeFee, "the next buyer pays no more");
    }

    // ------------------------------------------------------------------------------------------------------------
    // 3. Holding the reference with small swaps, and dust swaps, change nothing.
    // ------------------------------------------------------------------------------------------------------------

    function _quoteValue(PoolKey memory key, uint256 q0, uint256 s0) internal view returns (int256) {
        HookrTypes.PoolConfig memory pc = root.poolConfig(key.toId());
        int256 dq = int256(IERC20(Currency.unwrap(pc.quote)).balanceOf(attacker)) - int256(q0);
        int256 ds = int256(IERC20(Currency.unwrap(pc.subject)).balanceOf(attacker)) - int256(s0);
        (uint160 sp,,,) = manager.getSlot0(key.toId());
        uint256 mag = uint256(ds < 0 ? -ds : ds);
        // Quote is currency0: subject (currency1) is worth mag / p quote, with p = sp^2 / 2^192.
        int256 v = int256(FullMath.mulDiv(FullMath.mulDiv(mag, 1 << 96, sp), 1 << 96, sp));
        return dq + (ds < 0 ? -v : v);
    }

    /// After a 6e22 pump the attacker alternates `leg` sells and buys every 29 seconds. The next 1e21 buyer at each
    /// horizon pays what it pays with no hold.
    function _holdRun(uint256 horizon, bool hold, uint128 leg) internal returns (uint256 fee, int256 cost) {
        uint256 fresh = vm.snapshotState();
        PoolKey memory key = _open(_dynamicFeeMember(Currency.wrap(address(0))), false);
        _swapAs(victim, key, true, true, 6e22);
        uint256 t0 = vm.getBlockTimestamp();
        HookrTypes.PoolConfig memory pc = root.poolConfig(key.toId());
        uint256 q0 = IERC20(Currency.unwrap(pc.quote)).balanceOf(attacker);
        uint256 s0 = IERC20(Currency.unwrap(pc.subject)).balanceOf(attacker);
        if (hold) {
            bool sell = true;
            uint256 bought;
            while (vm.getBlockTimestamp() + 29 < t0 + horizon) {
                vm.warp(vm.getBlockTimestamp() + 29);
                vm.roll(vm.getBlockNumber() + 1);
                if (sell) {
                    (,, bought) = _swapAs(attacker, key, false, true, leg);
                } else {
                    _swapAs(attacker, key, true, true, uint128(bought));
                }
                sell = !sell;
            }
        }
        cost = -_quoteValue(key, q0, s0);
        vm.warp(t0 + horizon);
        vm.roll(vm.getBlockNumber() + 1);
        fee = _quoteBuy(key, 1e21).lpFeePips;
        vm.revertToState(fresh);
    }

    function testSmallSwapsDoNotHoldTheReference() public {
        uint256[4] memory horizons = [uint256(125), 245, 605, 1205];
        for (uint256 i; i < horizons.length; ++i) {
            (uint256 honest,) = _holdRun(horizons[i], false, 0);
            (uint256 held, int256 cost) = _holdRun(horizons[i], true, 3e20);
            emit log_named_uint("horizon (s)", horizons[i]);
            emit log_named_uint("  next 1e21 buyer LP fee, no hold", honest);
            emit log_named_uint("  next 1e21 buyer LP fee, held", held);
            emit log_named_int("  holder cost (quote value)", cost);
            assertLe(held, honest + 30, "the hold keeps no price memory");
        }
        uint128[2] memory legs = [uint128(6e19), 1e20];
        for (uint256 i; i < legs.length; ++i) {
            (uint256 honest,) = _holdRun(245, false, 0);
            (uint256 held,) = _holdRun(245, true, legs[i]);
            emit log_named_uint("leg", legs[i]);
            emit log_named_uint("  next 1e21 buyer LP fee at 245 s, held", held);
            assertLe(held, honest + 30, "the hold keeps no price memory");
        }
    }

    /// A 3e22 buy, then 1-wei exact-output buys at +30, +60 and +90 seconds, then a second 3e22 buy at +91: the second
    /// buy pays exactly what it pays with no dust swaps.
    function _pokeRun(bool poke) internal returns (uint256 secondFee, uint256 secondOut) {
        uint256 fresh = vm.snapshotState();
        PoolKey memory key = _open(_dynamicFeeMember(Currency.wrap(address(0))), false);
        _swapAs(victim, key, true, true, 3e22);
        uint256 t0 = vm.getBlockTimestamp();
        if (poke) {
            for (uint256 k = 1; k <= 3; ++k) {
                vm.warp(t0 + 30 * k);
                vm.prank(attacker);
                swapper.swap(key, true, 1, TickMath.MIN_SQRT_PRICE + 1);
            }
        }
        vm.warp(t0 + 91);
        HookrTypes.ExecutionReceipt memory r;
        (r,, secondOut) = _swapAs(victim, key, true, true, 3e22);
        secondFee = r.lpFeePips;
        vm.revertToState(fresh);
    }

    function testDustSwapsDoNotSpeedTheDecay() public {
        (uint256 plainFee, uint256 plainOut) = _pokeRun(false);
        (uint256 pokedFee, uint256 pokedOut) = _pokeRun(true);
        emit log_named_uint("second buy at +91 s, no dust swaps: LP fee", plainFee);
        emit log_named_uint("second buy at +91 s, 3 dust swaps: LP fee ", pokedFee);
        assertEq(pokedFee, plainFee, "same fee");
        assertEq(pokedOut, plainOut, "same fill");
    }

    // ------------------------------------------------------------------------------------------------------------
    // 4. A sandwicher who owns the in-range liquidity.
    // ------------------------------------------------------------------------------------------------------------

    function _book(PoolKey memory key) internal view returns (int256 q, int256 s) {
        HookrTypes.PoolConfig memory pc = root.poolConfig(key.toId());
        IERC20 quote = IERC20(Currency.unwrap(pc.quote));
        IERC20 subject = IERC20(Currency.unwrap(pc.subject));
        q = int256(quote.balanceOf(attacker) + quote.balanceOf(address(lp)));
        s = int256(subject.balanceOf(attacker) + subject.balanceOf(address(lp)));
    }

    function _mark(PoolKey memory key, int256 q0, int256 s0) internal view returns (int256) {
        (int256 q1, int256 s1) = _book(key);
        (uint160 sp,,,) = manager.getSlot0(key.toId());
        int256 ds = s1 - s0;
        uint256 mag = uint256(ds < 0 ? -ds : ds);
        int256 v = int256(FullMath.mulDiv(FullMath.mulDiv(mag, 1 << 96, sp), 1 << 96, sp));
        return (q1 - q0) + (ds < 0 ? -v : v);
    }

    /// The attacker's profit from a sandwich around a 1e22 victim over simply holding its band [-1200, 60].
    function _lpSandwich(bool dynamicPool, int256 bandL, uint128 front) internal returns (int256 increment) {
        uint256 fresh = vm.snapshotState();
        IHookrLauncher.Member memory m = _dynamicFeeMember(Currency.wrap(address(0)));
        if (!dynamicPool) {
            m.rules.maxFeePips = 3000;
            m.rules.dynamicFeeSens = 0;
        }
        PoolKey memory key = _open(m, false);
        uint256 snap = vm.snapshotState();
        (int256 q0, int256 s0) = _book(key);
        lp.modify(key, -1200, 60, bandL);
        _swapAs(victim, key, true, true, 1e22);
        lp.modify(key, -1200, 60, -bandL);
        int256 passive = _mark(key, q0, s0);
        vm.revertToState(snap);
        (q0, s0) = _book(key);
        lp.modify(key, -1200, 60, bandL);
        (,, uint256 got) = _swapAs(attacker, key, true, true, front);
        _swapAs(victim, key, true, true, 1e22);
        _swapAs(attacker, key, false, true, uint128(got));
        lp.modify(key, -1200, 60, -bandL);
        increment = _mark(key, q0, s0) - passive;
        vm.revertToState(fresh);
    }

    /// Dynamic fees deter a sandwicher who does not own the liquidity (DF-01). One who owns the in-range band keeps the
    /// LP part of the victim's raised fee and nets about what it nets on a pool without dynamic fees: within 2%.
    function testLiquidityOwningSandwichIsNotDeterred() public {
        int256[2] memory bands = [int256(1e24), 3e24];
        uint128[4] memory fronts = [uint128(3e21), 1e22, 2e22, 3e22];
        for (uint256 b; b < 2; ++b) {
            for (uint256 f; f < 4; ++f) {
                int256 dyn = _lpSandwich(true, bands[b], fronts[f]);
                int256 flat = _lpSandwich(false, bands[b], fronts[f]);
                emit log_named_int(string.concat("band ", vm.toString(bands[b]), ", front ", vm.toString(fronts[f])), 0);
                emit log_named_int("  sandwich over holding the band, dynamic", dyn);
                emit log_named_int("  sandwich over holding the band, flat   ", flat);
                assertGt(flat, 0, "profitable on the flat pool");
                assertApproxEqRel(dyn, flat, 0.02e18, "about the same with dynamic fees");
            }
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // 5. The end of liquidity.
    // ------------------------------------------------------------------------------------------------------------

    function _narrow() internal returns (PoolKey memory key) {
        IHookrLauncher.Member memory m = _dynamicFeeMember(Currency.wrap(address(0)));
        m.tickLower = -600;
        m.tickUpper = 0;
        key = _open(m, false);
    }

    function _endTick(PoolKey memory key, uint128 amount) internal returns (int24 t) {
        uint256 s = vm.snapshotState();
        IHookrRouter.Swap memory p = _swap(key, true, true, amount);
        p.recipient = victim;
        vm.prank(victim);
        router.swap(p, address(0), new uint256[](0));
        t = _tick(key);
        vm.revertToState(s);
    }

    /// The largest exact-input buy (router default limit) whose executed end stays in the range [-600, 0].
    function _largestInRange(PoolKey memory key) internal returns (uint256 lo) {
        lo = 1e18;
        uint256 hi = 1e24;
        for (uint256 k; k < 90; ++k) {
            uint256 mid = (lo + hi) / 2;
            if (_endTick(key, uint128(mid)) >= -600) lo = mid;
            else hi = mid;
        }
    }

    /// Buys that use nearly all of the range: the simulation runs out of liquidity and is priced to the range's edge,
    /// so the charge equals the charge with a price limit at the edge, never the full span.
    function testBuyNearTheEndOfLiquidityIsPricedToTheEdge() public {
        PoolKey memory key = _narrow();
        uint256 cap = _largestInRange(key);
        uint256[8] memory back = [uint256(0), 1, 100, 1000, 3000, 6000, 7000, 8000];
        uint256 lastOut = type(uint256).max;
        for (uint256 i; i < back.length; ++i) {
            uint128 amount = uint128(cap - cap * back[i] / 100_000);
            IHookrRouter.Swap memory p = _swap(key, true, true, amount);
            HookrTypes.ExecutionReceipt memory open = quoter.quote(p, victim);
            p.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(-600);
            HookrTypes.ExecutionReceipt memory limited = quoter.quote(p, victim);
            emit log_named_uint("per 100k below the largest in-range buy", back[i]);
            emit log_named_uint("  LP fee, default limit      ", open.lpFeePips);
            emit log_named_uint("  LP fee, limit at the edge  ", limited.lpFeePips);
            assertGe(_endTick(key, amount), -600, "the executed swap stays in the range");
            assertLt(open.lpFeePips, 75_750, "never the full span");
            assertLe(open.lpFeePips, limited.lpFeePips + 1, "no more than with a limit at the edge");
            assertLe(open.outputAmount, lastOut, "a smaller buy never buys more");
            lastOut = open.outputAmount;
        }
    }

    /// Above the largest in-range buy, more input never buys less subject.
    function testMoreInputNeverBuysLess() public {
        PoolKey memory key = _narrow();
        uint256 cap = _largestInRange(key);
        uint256 lastOut;
        for (uint256 k = 90_000; k <= 101_000; k += 500) {
            HookrTypes.ExecutionReceipt memory r =
                quoter.quote(_swap(key, true, true, uint128(cap * k / 100_000)), victim);
            assertGe(r.outputAmount, lastOut, "more input never buys less");
            lastOut = r.outputAmount;
        }
    }

    /// After a 1e22 buy on a single-sided pool, an exact-output sell of up to 99% of the quote that selling everything
    /// bought returns fills: the simulation is priced to the band's edge, so the real swap reserves only what its quote
    /// takes.
    function testExactOutputSellOfNearlyAllTheQuoteFills() public {
        IHookrLauncher.Member memory m = _dynamicFeeMember(Currency.wrap(address(0)));
        m.tickUpper = 0;
        PoolKey memory key = _open(m, false);
        (HookrTypes.ExecutionReceipt memory b,,) = _swapAs(attacker, key, true, true, 1e22);
        vm.warp(vm.getBlockTimestamp() + _dynamicFeeReset() + 1);
        HookrTypes.ExecutionReceipt memory all = quoter.quote(_swap(key, false, true, uint128(b.outputAmount)), victim);
        uint16[5] memory permille = [uint16(500), 900, 975, 980, 990];
        for (uint256 i; i < permille.length; ++i) {
            uint128 q = uint128(all.outputAmount * permille[i] / 1000);
            uint256 snap = vm.snapshotState();
            (HookrTypes.ExecutionReceipt memory r,, uint256 out) = _swapAs(victim, key, false, false, q);
            emit log_named_uint("exact-output sell, permille of the full sell's quote", permille[i]);
            emit log_named_uint("  LP fee", r.lpFeePips);
            assertEq(out, q, "filled");
            vm.revertToState(snap);
        }
    }
}
