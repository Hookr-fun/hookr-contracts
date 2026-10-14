// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {HookrTypes} from "../../../src/types/HookrTypes.sol";
import {IHookrRouter} from "../../../src/interfaces/IHookrRouter.sol";
import {LaneFixture} from "../LaneFixture.sol";
import {ScriptedExecutor} from "../mocks/ScriptedExecutor.sol";
import {Actor} from "../mocks/Actors.sol";
import {IHookrRecaptureEvents} from "../../../src/interfaces/IHookrRecaptureEvents.sol";

/// @notice Fuzz over every amount path: the split (protocol share first, then trader, pot and LP) and its rounding,
///         the prize cap and carry, leader selection, epoch alignment, and the exact backing of every liability, for
///         native and ERC-20 quotes, on HookrRoot's lane with HookrRules' recapture module.
contract KothFuzzTest is LaneFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    ScriptedExecutor internal exec;
    Currency internal tb;

    function setUp() public {
        _setUpLane();
        exec = new ScriptedExecutor(manager);
        vm.deal(address(exec), 1e30);
        tokenB.transfer(address(exec), 1e27);
        exec.setRoot(address(root));
        _openLane(address(exec));
        tb = Currency.wrap(address(tokenB));
    }

    /// @dev A split inside every bound: trader 0 to 5,000, pot 1 to 5,000 with King of the Pool (zero without), the
    ///      rest to the LP accrual.
    function _cfg(uint256 t, uint256 p, bool koth)
        internal
        pure
        returns (HookrTypes.RulesConfig memory r, HookrTypes.RecaptureConfig memory c)
    {
        r = _laneRules(koth);
        c = koth ? _kothRc() : _recaptureOnlyRc();
        c.traderBps = uint16(bound(t, 0, 5_000));
        r.potBps = koth ? uint16(bound(p, 1, 5_000)) : 0;
        c.lpBps = uint16(10_000 - uint256(c.traderBps) - r.potBps);
    }

    function _assertBacked(Currency q) internal view {
        assertEq(
            manager.balanceOf(address(rules), q.toId()), rules.totalLiability(q), "claims exactly back liabilities"
        );
        assertEq(manager.balanceOf(address(root), q.toId()), 0, "root holds no claims");
    }

    /// The legs of each push sum to it: the protocol takes the pool's share first, the pot its share of the rest, the
    /// trader named on the after-phase its share of the part its own swap accounts for (none here: the scripted
    /// executor legs nowhere, so no push undid the trader's move), and the LP accrual the rest with the rounding dust.
    /// Each leg lands in its ledger and nothing is donated, whether or not liquidity was added in the same
    /// transaction.
    function testFuzz_splitConservation(
        uint256 amount,
        uint256 t,
        uint256 p,
        bool koth,
        bool authenticated,
        bool jit,
        bool erc20
    ) public {
        amount = bound(amount, 1, 1e24);
        (HookrTypes.RulesConfig memory r, HookrTypes.RecaptureConfig memory c) = _cfg(t, p, koth);
        Currency q = erc20 ? tb : ETH;
        PoolKey memory key = _openPool(q, r, c);
        exec.set(ScriptedExecutor.Mode.PUSH, amount);
        Actor a = _newActor(key);
        uint256 traderBefore = rules.claimable(q, address(a));
        vm.recordLogs();
        bool quoteIs0 = Currency.unwrap(key.currency0) == Currency.unwrap(q);
        if (jit) {
            a.jitSwap(key, quoteIs0, -1e18, quoteIs0 ? MIN_PRICE : MAX_PRICE, -600, 600, 1e24);
        } else if (authenticated) {
            a.routerSwap(_swapParams(key, q, true, true, 1e18, address(a)), q.isAddressZero() ? 1e18 : 0);
        } else {
            a.directSwap(key, quoteIs0, -1e18, quoteIs0 ? MIN_PRICE : MAX_PRICE);
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 splits;
        uint256 named;
        Splits memory sum;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(rules) || logs[i].topics[0] != IHookrRecaptureEvents.RecaptureSplit.selector)
            {
                continue;
            }
            splits++;
            address trader = address(uint160(uint256(logs[i].topics[2])));
            (uint256 tr, uint256 lp, uint256 pot, uint256 pro,, uint256 reported) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, Currency, uint256));
            assertEq(tr + lp + pot + pro, amount, "legs sum to the push");
            assertEq(reported, _profitOf(amount), "the split reports the profit the push stands for");
            // The root reads the profit back from the push at the pinned 25%: the protocol takes 25% of it on every
            // pool, at most the push.
            uint256 expProtocol = _cut(_profitOf(amount), amount);
            uint256 rest = amount - expProtocol;
            // The scripted executor legs nowhere, so no push undid the trader's move: no trader leg, even when named.
            uint256 expTrader = 0;
            uint256 expPot = rest * r.potBps / 10_000;
            assertEq(pro, expProtocol, "the protocol share first");
            assertEq(tr, expTrader);
            assertEq(pot, expPot);
            assertEq(lp, rest - expTrader - expPot, "the LP leg takes the rest");
            if (trader != address(0)) {
                assertEq(trader, address(a));
                named++;
            }
            sum.trader += tr;
            sum.lp += lp;
            sum.pot += pot;
            sum.protocol += pro;
        }
        assertEq(splits, 2, "one push per phase");
        assertEq(named, authenticated && !jit ? 1 : 0, "a trader only on an authenticated swap's after-phase");
        assertEq(rules.claimable(q, address(a)) - traderBefore, sum.trader);
        (,,, uint128 potNow) = _hill(key);
        assertEq(potNow, sum.pot);
        assertEq(_accrued(key), sum.lp);
        _assertBacked(q);
    }

    /// The Rules' split of one push with any trader basis and any profit: the protocol leg is 25% of the profit, at
    /// most the push, whatever the pool's protocolShareBps; the pot leg ignores the basis; the trader leg
    /// is traderBps of min(push, basis) net of the protocol cut as the push is, never above the uncapped trader leg;
    /// and the legs sum to the push.
    function testFuzz_traderBasisSplit(uint256 amount, uint256 basis, uint256 profit, uint256 t, uint256 p, bool koth)
        public
    {
        amount = bound(amount, 1, 1e30);
        basis = bound(basis, 0, type(uint256).max);
        profit = bound(profit, 0, 2e31);
        (HookrTypes.RulesConfig memory r, HookrTypes.RecaptureConfig memory c) = _cfg(t, p, koth);
        PoolKey memory key = _openPool(ETH, r, c);
        vm.recordLogs();
        vm.prank(address(root));
        _recap().settleRecapture(key, ETH, minnow, amount, basis, profit);
        Splits memory s = _splits(vm.getRecordedLogs());
        uint256 pro = profit * PROTOCOL_BPS / 10_000;
        if (pro > amount) pro = amount;
        uint256 rest = amount - pro;
        uint256 part = basis < amount ? basis : amount;
        uint256 tr = part * rest / amount * c.traderBps / 10_000;
        assertEq(s.protocol, pro);
        assertEq(s.pot, rest * r.potBps / 10_000);
        assertEq(s.trader, tr);
        assertLe(s.trader, rest * c.traderBps / 10_000, "never above the uncapped trader leg");
        assertEq(s.trader + s.lp + s.pot + s.protocol, amount);
        assertEq(s.reported, profit, "the split reports the profit it was given");
        assertEq(rules.claimable(ETH, minnow), tr);
        assertEq(_accrued(key), s.lp);
    }

    /// The prize is min(pot, leaderAmount * maxPrizeBps / 10,000); 1 - potReleaseBps of the rest carries, rounded
    /// down by at most one unit, exactly half at 5,000, and pendingPrize predicts it.
    function testFuzz_prizeCapAndCarry(uint256 buy, uint256 push, uint256 prizeBps, uint256 releaseBps, bool erc20)
        public
    {
        buy = bound(buy, MIN_BUY, 1e23);
        push = bound(push, 0, 1e24);
        HookrTypes.RecaptureConfig memory c = _kothRc();
        c.maxPrizeBps = uint16(bound(prizeBps, 1, 50));
        c.potReleaseBps = uint16(bound(releaseBps, 2_500, 10_000));
        Currency q = erc20 ? tb : ETH;
        PoolKey memory key = _openKoth(c, q);
        exec.set(push == 0 ? ScriptedExecutor.Mode.NOTHING : ScriptedExecutor.Mode.PUSH, push);
        _buy(key, q, whale, buy);
        (uint64 start, address leader, uint128 amount, uint128 pot) = _hill(key);
        assertEq(leader, whale);
        assertEq(amount, buy, "an exact-input buy's gross spend is its input");
        uint256 before = rules.claimable(q, whale);
        (, uint256 predictedPrize, uint256 predicted) = _recap().pendingPrize(key.toId());
        vm.warp(uint256(start) + PERIOD);
        _recap().settleEpoch(key.toId());
        uint256 prize = buy * c.maxPrizeBps / 10_000;
        if (prize > pot) prize = pot;
        assertEq(rules.claimable(q, whale) - before, prize);
        assertEq(predictedPrize, prize);
        (,,, uint128 carried) = _hill(key);
        uint256 exact = (pot - prize) * (10_000 - c.potReleaseBps) / 10_000;
        assertLe(carried, exact, "never carries more than the exact share");
        assertGe(uint256(carried) + 1, exact, "rounds down by at most one unit");
        if (c.potReleaseBps == 5_000) assertEq(carried, (pot - prize) / 2);
        assertEq(predicted, carried, "pendingPrize predicts the carry");
        _assertBacked(q);
    }

    /// Fills the pot of a fresh pool through an unauthenticated swap, so no leader and no prize, and returns it.
    function _fillPot(HookrTypes.RecaptureConfig memory c, uint256 push)
        internal
        returns (PoolKey memory key, uint64 start, uint256 pot)
    {
        key = _openKoth(c, ETH);
        exec.set(ScriptedExecutor.Mode.PUSH, push);
        _newActor(key).directSwap(key, true, -1e9, MIN_PRICE);
        exec.set(ScriptedExecutor.Mode.NOTHING, 0);
        uint128 p;
        (start,,, p) = _hill(key);
        pot = p;
    }

    /// For every release share in [2,500, 10,000] and any number of epochs closed in one rollover, the carried pot never
    /// exceeds pot * (1 - r)^n, stays within two units of it where it is computable exactly, is zero from 256 epochs
    /// or at r = 10,000, and the rest joins the LP accrual: the pot stays bounded by its inflow.
    function testFuzz_potRelease_boundedByInflowForEveryShare(uint256 push, uint256 releaseBps, uint256 closed) public {
        HookrTypes.RecaptureConfig memory c = _kothRc();
        c.potReleaseBps = uint16(bound(releaseBps, 2_500, 10_000));
        uint256 n = bound(closed, 1, 300);
        (PoolKey memory key, uint64 start, uint256 pot) = _fillPot(c, bound(push, 1, 1e27));
        uint256 lpBefore = _accrued(key);
        vm.warp(uint256(start) + n * PERIOD + (push % PERIOD));
        _recap().settleEpoch(key.toId());
        (uint64 next,,, uint128 carried) = _hill(key);
        assertEq(next, uint256(start) + n * PERIOD);
        assertLe(carried, pot, "the carried pot never exceeds the inflow");
        assertEq(_accrued(key) - lpBefore, pot - carried, "every released unit joined the LP accrual");
        uint256 kept = 10_000 - c.potReleaseBps;
        if (n >= 256 || kept == 0) {
            assertEq(carried, 0);
        } else if (n <= 19) {
            uint256 exact = FullMath.mulDiv(pot, kept ** n, uint256(10_000) ** n);
            assertLe(carried, exact);
            assertGe(uint256(carried) + 2, exact);
        } else {
            assertLe(carried, FullMath.mulDiv(pot, kept ** 19, uint256(10_000) ** 19));
            assertLe(carried, pot >> (2 * n / 5), "kept <= 0.75, and 0.75^n <= 2^(-2n/5)");
        }
        _assertBacked(ETH);
    }

    /// At 5,000 the rollover is an exact halving per closed epoch: the prize first, then pot >> closed, nothing from
    /// 256 closed epochs on, and PotReleased and EpochRolled report the release and the carry.
    function testFuzz_potRelease_fiveThousandMatchesHalving(uint256 push, uint256 buy, uint256 closed) public {
        HookrTypes.RecaptureConfig memory c = _kothRc();
        c.potReleaseBps = 5_000;
        uint256 n = bound(closed, 1, 400);
        (PoolKey memory key, uint64 start, uint256 pot) = _fillPot(c, bound(push, 1, 1e27));
        uint256 prize;
        if (buy % 2 == 0) {
            buy = bound(buy, MIN_BUY, 1e23);
            _buy(key, ETH, whale, buy);
            prize = buy * c.maxPrizeBps / 10_000;
            if (prize > pot) prize = pot;
        }
        uint256 left = pot - prize;
        uint256 halved = n > 255 ? 0 : left >> n;
        (,, uint256 predicted) = _recap().pendingPrize(key.toId());
        assertEq(predicted, left >> 1);
        vm.warp(uint256(start) + n * PERIOD);
        vm.recordLogs();
        _recap().settleEpoch(key.toId());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (,,, uint128 carried) = _hill(key);
        assertEq(carried, halved);
        bool released;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(rules)) continue;
            if (logs[i].topics[0] == IHookrRecaptureEvents.PotReleased.selector) {
                assertEq(abi.decode(logs[i].data, (uint256)), left - halved);
                released = true;
            } else if (logs[i].topics[0] == IHookrRecaptureEvents.EpochRolled.selector) {
                (,, uint256 potCarried) = abi.decode(logs[i].data, (uint64, uint64, uint256));
                assertEq(potCarried, halved);
            }
        }
        assertEq(released, left != halved);
    }

    /// The leader is the first payer of the strictly largest qualifying authenticated buy.
    function testFuzz_leaderIsLargestQualifyingBuy(uint96[6] memory sizes) public {
        PoolKey memory key = _openKoth(ETH);
        exec.set(ScriptedExecutor.Mode.NOTHING, 0);
        address best;
        uint256 bestAmount;
        for (uint256 i; i < sizes.length; ++i) {
            uint256 s = bound(uint256(sizes[i]), 1e6, 1e22);
            address who = address(uint160(0x3000 + i));
            vm.deal(who, 1e23);
            _buy(key, ETH, who, s);
            if (s >= MIN_BUY && s > bestAmount) (best, bestAmount) = (who, s);
        }
        (, address leader, uint128 amount,) = _hill(key);
        assertEq(leader, best);
        assertEq(amount, bestAmount);
    }

    /// Rollover keeps epochs aligned to the bind time for any period and any elapsed time.
    function testFuzz_rolloverAlignment(uint256 period, uint256 elapsed) public {
        HookrTypes.RecaptureConfig memory c = _kothRc();
        c.period = uint32(bound(period, 1 hours, 30 days));
        PoolKey memory key = _openKoth(c, ETH);
        (uint64 start,,,) = _hill(key);
        elapsed = bound(elapsed, 0, 365 days * 5);
        vm.warp(uint256(start) + elapsed);
        if (elapsed < c.period) {
            vm.expectRevert(IHookrRecaptureEvents.EpochOpen.selector);
            _recap().settleEpoch(key.toId());
        } else {
            _recap().settleEpoch(key.toId());
            (uint64 next,,,) = _hill(key);
            assertEq(next, uint256(start) + (elapsed / c.period) * c.period);
            assertLe(next, vm.getBlockTimestamp());
            assertGt(uint256(next) + c.period, vm.getBlockTimestamp());
        }
    }

    /// Any sequence of buy and sell sizes, exact input or output, keeps every liability exactly backed.
    function testFuzz_tradeSizesKeepBacking(uint96[4] memory sizes, uint8 shape, uint256 push, bool erc20) public {
        Currency q = erc20 ? tb : ETH;
        PoolKey memory key = _openKoth(q);
        push = bound(push, 0, 1e22);
        exec.set(push == 0 ? ScriptedExecutor.Mode.NOTHING : ScriptedExecutor.Mode.PUSH, push);
        for (uint256 i; i < sizes.length; ++i) {
            uint256 s = bound(uint256(sizes[i]), 1e6, 1e22);
            bool buy = (shape >> i) & 1 == 0;
            bool exactIn = (shape >> (i + 4)) & 1 == 0;
            IHookrRouter.Swap memory p = _swapParams(key, q, buy, exactIn, s, whale);
            uint256 value;
            if (!exactIn) p.amountBound = uint128(s * 3);
            if (buy && q.isAddressZero()) value = exactIn ? s : s * 3;
            vm.prank(whale);
            router.swap{value: value}(p, address(0), new uint256[](0));
        }
        _assertBacked(q);
        (, address leader, uint128 amount,) = _hill(key);
        assertTrue(leader == address(0) || (leader == whale && amount >= MIN_BUY));
    }
}
