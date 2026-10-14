// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {PartnerShapedFixture} from "./utils/PartnerShapedFixture.sol";

/// @notice RCM-1 regression: the after-phase trader credit for gaps the trader did not open. The frame rule "every leg
///         on a pool goes one direction per frame" means a before-phase cannot close two outside gaps that need opposite
///         legs on the triggering pool (the member sits between an outside venue and its own family sibling). The
///         before-phase closes one (no trader credit); the after-phase of the same swap, a fresh frame, closes the other.
///         Before the fix it credited that to whoever swapped, so a dust trade collected traderBps of a gap it never
///         opened. The trader leg is now paid on min(push, the trader's quote times its own price move), and only when
///         the arb recapture's legs on the pool ran against the trader's swap.
contract MoneyTraderCreditAttackTest is PartnerShapedFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    HookrToken internal subject;
    Currency internal s;
    Currency internal qb;
    PoolKey internal a;
    PoolKey internal b;
    PoolKey internal refA;
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
        conn = _hookless(ETH, qb);
        ex.setTrigger(a, 1e22);
        ex.addVenue(a, refA, PAIR_GAP);
        ex.addCycle(a, b, conn, CYCLE_GAP);
        _nextBlock();
    }

    function _familyPx() internal view returns (uint256) {
        return FullMath.mulDiv(_px(b, s), _px(conn, qb), 1e18);
    }

    /// Two outside moves, neither by the dust trader: the subject runs up on A's outside venue (A is cheap there: the
    /// arb recapture buys on A) and tokenB falls on the connector (A is dear against its sibling: the arb recapture
    /// sells on A). A 1e15 dust sell on A is credited nothing of the second gap's arb recapture.
    function test_regression_dustTraderIsCreditedNothingForAGapItDidNotOpen() public {
        // Nobody below is the minnow.
        venue.swap{value: 2e22}(refA, true, 2e22, 0); // subject up on A's outside venue (ETH -> subject)
        venue.swap(conn, false, 3e22, 0); // tokenB down against ETH (tokenB -> ETH)
        _nextBlock();
        uint256 pxA = _px(a, s);
        console2.log("before: A, venue, family (WAD ETH per subject)", pxA, _px(refA, s), _familyPx());
        console2.log("gaps (bps): A vs venue, A vs family", _gapBps(pxA, _px(refA, s)), _gapBps(pxA, _familyPx()));
        uint256 creditBefore = rules.claimable(ETH, minnow);
        vm.recordLogs();
        uint256 minnowEthBefore = minnow.balance;
        _sell(a, ETH, minnow, 1e15);
        uint256 dustOut = minnow.balance - minnowEthBefore;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Outcome memory o = _outcome(logs);
        Splits memory sp = _splits(logs);
        uint256 credit = rules.claimable(ETH, minnow) - creditBefore;
        console2.log("pushed before-phase / after-phase", o.pushedBefore, o.pushedAfter);
        console2.log("dust sell output (wei ETH)", dustOut);
        console2.log("trader credit to the dust seller (wei ETH)", credit);
        console2.log(
            "after: gaps (bps) A vs venue, A vs family",
            _gapBps(_px(a, s), _px(refA, s)),
            _gapBps(_px(a, s), _familyPx())
        );
        assertGt(o.pushedBefore, 0, "the before-phase closed one gap");
        assertGt(o.pushedAfter, 0, "the after-phase closed the other");
        // The after-phase names the dust seller and credits it nothing; the trader share joins the LP accrual.
        assertEq(credit, 0, "no credit for a gap the dust sell did not open");
        assertEq(sp.trader, 0);
        assertEq(sp.lastTrader, minnow);
        assertGt(dustOut, 0);
    }

    /// Only the outside-venue move (no opposing gap). The before-phase closes most of it; the residual the after-phase
    /// closes credited the dust seller about 0.5% of the total push before the fix, and nothing now.
    function test_regression_singleGapResidualCreditsTheDustTraderNothing() public {
        venue.swap{value: 2e22}(refA, true, 2e22, 0);
        _nextBlock();
        uint256 creditBefore = rules.claimable(ETH, minnow);
        vm.recordLogs();
        _sell(a, ETH, minnow, 1e15);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        uint256 credit = rules.claimable(ETH, minnow) - creditBefore;
        console2.log("control pushed before / after", o.pushedBefore, o.pushedAfter);
        assertGt(o.pushedBefore, 0);
        assertEq(credit, 0, "the residual of a gap the dust did not open credits it nothing");
    }

    /// The same dust trade repeated: each swap's before-phase closes the venue gap and its after-phase the family gap,
    /// which reopens the venue gap for the next swap, until the two outside prices meet. Before the fix the dust
    /// seller collected the trader leg of every after-phase; now none, and the LP accrual keeps it.
    function test_regression_repeatedDustFarmsNothing() public {
        venue.swap{value: 2e22}(refA, true, 2e22, 0);
        venue.swap(conn, false, 3e22, 0);
        _nextBlock();
        uint256 creditBefore = rules.claimable(ETH, minnow);
        uint256 lpBefore = _accrued(a);
        uint256 pushedBefore;
        uint256 pushedAfter;
        uint256 spent;
        for (uint256 i; i < 6; ++i) {
            vm.recordLogs();
            uint256 bal = minnow.balance;
            _sell(a, ETH, minnow, 1e15);
            spent += 1e15;
            Outcome memory o = _outcome(vm.getRecordedLogs());
            pushedBefore += o.pushedBefore;
            pushedAfter += o.pushedAfter;
            bal;
        }
        uint256 credit = rules.claimable(ETH, minnow) - creditBefore;
        uint256 lp = _accrued(a) - lpBefore;
        console2.log("6 dust sells: subject sold (wei)", spent);
        console2.log("pushed before-phases / after-phases", pushedBefore, pushedAfter);
        console2.log("dust seller credit / LP accrual (wei ETH)", credit, lp);
        console2.log(
            "final gaps (bps) A vs venue, A vs family",
            _gapBps(_px(a, s), _px(refA, s)),
            _gapBps(_px(a, s), _familyPx())
        );
        assertEq(credit, 0, "six dust sells collect nothing");
        assertGt(lp, 0, "the LP accrual keeps every after-phase's trader share");
    }

    /// Not family specific: two outside venues of A's own pair on opposite sides of A (one where the subject ran up,
    /// one where it fell) give the same result.
    function test_regression_twoOutsideVenuesOnOppositeSides() public {
        PoolKey memory v2 = PoolKey(a.currency0, a.currency1, 500, 10, a.hooks);
        v2.hooks = refA.hooks;
        venue.seed{value: 1e24}(v2, SQRT_ONE, -60_000, 60_000, 1e24);
        // A second trigger config would need the operator; add v2 as a venue of A.
        ex.addVenue(a, v2, PAIR_GAP);
        venue.swap{value: 2e22}(refA, true, 2e22, 0); // subject up on refA
        venue.swap(v2, false, 2e22, 0); // subject down on v2 (subject -> ETH)
        _nextBlock();
        console2.log("before: A, refA, v2", _px(a, s), _px(refA, s), _px(v2, s));
        uint256 creditBefore = rules.claimable(ETH, minnow);
        vm.recordLogs();
        _sell(a, ETH, minnow, 1e15);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        uint256 credit = rules.claimable(ETH, minnow) - creditBefore;
        console2.log("two venues: pushed before / after", o.pushedBefore, o.pushedAfter);
        assertGt(o.pushedAfter, 0);
        assertEq(credit, 0, "nothing for a 1e15 dust sell");
    }

    /// Steering: only one natural gap exists, on the family route (A dear against its sibling). The attacker first
    /// opens a small opposite gap on the route the executor runs first (buys the subject on A's outside venue), so the
    /// before-phase fixes A's direction to "buy" on that small gap and must leave the large family gap, which needs a
    /// sell on A, to the after-phase, where the attacker's dust sell is the named trader. The attacker then unwinds the
    /// steering position on the venue and claims.
    function _steer(uint256 steerEth) internal returns (uint256 credit, int256 net, uint256 pb, uint256 pa) {
        uint256 ethBefore = attacker.balance;
        uint256 sBefore = subject.balanceOf(attacker);
        vm.startPrank(attacker);
        subject.approve(address(venue), type(uint256).max);
        venue.swap{value: steerEth}(refA, true, steerEth, 0);
        vm.stopPrank();
        uint256 sBought = subject.balanceOf(attacker) - sBefore;
        console2.log("steer size (wei ETH), A vs venue gap (bps)", steerEth, _gapBps(_px(a, s), _px(refA, s)));
        uint256 c1 = rules.claimable(ETH, attacker);
        vm.recordLogs();
        _sell(a, ETH, attacker, 1e15);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        (pb, pa) = (o.pushedBefore, o.pushedAfter);
        credit = rules.claimable(ETH, attacker) - c1;
        vm.prank(attacker);
        venue.swap(refA, false, sBought, 0);
        if (rules.claimable(ETH, attacker) != 0) {
            vm.prank(attacker);
            rules.claim(ETH);
        }
        net = int256(attacker.balance) - int256(ethBefore);
    }

    function test_regression_steeringANaturalGapIntoTheAfterPhasePaysNothing() public {
        venue.swap(conn, false, 3e22, 0); // natural: tokenB falls, A is dear against its sibling by ~600 bps
        _nextBlock();
        uint256 snap = vm.snapshotState();
        uint256 c0 = rules.claimable(ETH, attacker);
        _sell(a, ETH, attacker, 1e15);
        uint256 unsteered = rules.claimable(ETH, attacker) - c0;
        console2.log("unsteered dust credit (wei ETH)", unsteered);
        vm.revertToState(snap);
        uint256[5] memory sizes = [uint256(3.4e21), 3.6e21, 4e21, 6e21, 1e22];
        int256 best = type(int256).min;
        uint256 bestCredit;
        for (uint256 i; i < sizes.length; ++i) {
            uint256 st = vm.snapshotState();
            (uint256 credit, int256 net, uint256 pb, uint256 pa) = _steer(sizes[i]);
            console2.log("  pushed before / after", pb, pa);
            console2.log("  steered credit (wei ETH)", credit);
            console2.log("  attacker net ETH (signed wei)");
            console2.logInt(net);
            if (net > best) (best, bestCredit) = (net, credit);
            vm.revertToState(st);
        }
        // A dust sell's own move on 1e24 of liquidity accounts for a few million wei at most: all it can be credited.
        assertLe(unsteered, 1e9, "the unsteered dust sell is credited at most its own move's share");
        assertLe(bestCredit, 1e9, "steering moves nothing into a credited phase");
        assertLt(best, 0, "the attacker ends behind at every steer size");
    }
}
