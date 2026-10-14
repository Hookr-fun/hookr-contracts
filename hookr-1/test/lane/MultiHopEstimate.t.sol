// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {console2} from "forge-std/console2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {IHookrLaneRoot} from "../../src/interfaces/IHookrLaneRoot.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {PartnerShapedFixture} from "./utils/PartnerShapedFixture.sol";
import {LaneRootFixture} from "./utils/LaneRootFixture.sol";
import {ScriptedExecutor} from "./mocks/ScriptedExecutor.sol";
import {HopRoute, MultiHopRoutes} from "./utils/MultiHopRoutes.sol";

/// @notice VERIFY-1 regression (two or more lane swaps in one transaction). A route through two lane pools of one
///         family (tokenB -> subject on B, subject -> ETH on A) sent at its quiet `eth_estimateGas` limit reverted
///         InsufficientLaneGas once an outside move landed before inclusion (7,802,205 estimated against 8.10M to 9.41M
///         needed): the entry floor funded one lane swap, and B's arb recaptures, spending more when mined than when
///         estimated, took the difference out of A's entry floor. A later lane swap now also requires what the
///         transaction's earlier lane swaps could still have spent, which moves with what they did spend, so the
///         route's estimate funds the mined route in either direction. Every lane swap of the route still runs both of
///         its arb recaptures. The executor is the partner-shaped one at the 3M cap; a three-lane route adds a second
///         token's ETH pool (ETH -> subject2 on C).
contract MultiHopEstimateTest is PartnerShapedFixture, MultiHopRoutes {
    using PoolIdLibrary for PoolKey;

    HookrToken internal subject;
    HookrToken internal subject2;
    PoolKey internal a;
    PoolKey internal b;
    PoolKey internal c;
    PoolKey internal refA;
    PoolKey internal refB;
    PoolKey internal refC;
    PoolKey internal conn;

    function setUp() public {
        _setUpPartnerShaped();
        subject = _newSubject();
        subject.approve(address(venue), type(uint256).max);
        Currency qb = Currency.wrap(address(tokenB));
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _laneMemberAt(ETH);
        members[1] = _laneMemberAt(qb);
        (, PoolKey[] memory keys) = _launch(subject, members);
        (a, b) = (keys[0], keys[1]);
        subject2 = _newSubject();
        subject2.approve(address(venue), type(uint256).max);
        IHookrLauncher.Member[] memory one = new IHookrLauncher.Member[](1);
        one[0] = _laneMemberAt(ETH);
        (, keys) = _launch(subject2, one);
        c = keys[0];
        refA = _hookless(a.currency0, a.currency1);
        refB = _hookless(b.currency0, b.currency1);
        refC = _hookless(c.currency0, c.currency1);
        conn = _hookless(ETH, qb);
        ex.setTrigger(a, 1e22);
        ex.addVenue(a, refA, PAIR_GAP);
        ex.addCycle(a, b, conn, CYCLE_GAP);
        ex.setTrigger(b, 1e22);
        ex.addVenue(b, refB, PAIR_GAP);
        ex.addCycle(b, a, conn, CYCLE_GAP);
        ex.setTrigger(c, 1e22);
        ex.addVenue(c, refC, PAIR_GAP);
        hop = new HopRoute(manager);
        tokenB.transfer(address(hop), 1e26);
        vm.deal(address(hop), 1e20);
        // tokenB -> subject on B, subject -> ETH on A, then ETH -> subject2 on C.
        two.push(HopRoute.Hop(b, Currency.unwrap(b.currency0) == address(tokenB)));
        two.push(HopRoute.Hop(a, false));
        three.push(two[0]);
        three.push(two[1]);
        three.push(HopRoute.Hop(c, true));
        _nextBlock();
    }

    /// @dev Outside moves before inclusion: tokenB buys the subject on B's venue, ETH buys it on A's venue and
    ///      subject2 on C's venue (`size` of each input; zero skips a venue).
    function _move(uint256 onB, uint256 onA, uint256 onC) internal {
        if (onB != 0) {
            bool zb = Currency.unwrap(refB.currency0) == address(tokenB);
            venue.swap(refB, zb, onB, zb ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
        }
        if (onA != 0) venue.swap{value: onA}(refA, true, onA, 0);
        if (onC != 0) venue.swap{value: onC}(refC, true, onC, 0);
    }

    /// @dev Asserts every lane swap of the route ran both arb recaptures at `g`, and returns what B's before-phase
    /// pushed.
    function _allRecaptured(uint256 hops, uint256 g) internal returns (uint256 pushedOnB) {
        (uint256[] memory ran, uint256[] memory pushedBefore) = _ranAt(hops, g, address(root));
        for (uint256 h; h < ran.length; ++h) {
            assertEq(ran[h], 2, "both arb recaptures on every lane pool of the route");
        }
        pushedOnB = pushedBefore[0];
    }

    /// Outside moves on B's venue between the estimate and inclusion make B's before-phase arb recapture. The two-lane
    /// route sent at its quiet estimate, and at the estimate + 10%, succeeds, with both arb recaptures on both pools.
    function test_regression_aTwoLanePoolRouteSucceedsAtItsQuietEstimate() public {
        (,,,,, uint32 cap, uint256 floor) = IHookrLaneRoot(address(root)).laneOf(a.toId());
        uint256 quiet = _least(2);
        console2.log("cap, entry floor, quiet two-lane route estimate", cap, floor, quiet);
        assertEq(_tryAt(2, quiet), 0, "the quiet estimate succeeds in the quiet state");
        uint256[3] memory moves = [uint256(5e21), 3e22, 1e23];
        for (uint256 m; m < moves.length; ++m) {
            uint256 snap = vm.snapshotState();
            _move(moves[m], 0, 0);
            console2.log("outside tokenB buy on B's venue; least limit now", moves[m], _least(2));
            assertEq(_tryAt(2, quiet), 0, "the quiet estimate funds the mined route");
            assertEq(_tryAt(2, quiet * 110 / 100), 0, "and with the usual margin");
            assertGt(_allRecaptured(2, quiet), 0, "B's before-phase closed the outside gap at the quiet estimate");
            vm.revertToState(snap);
        }
    }

    /// The same with three lane swaps, every venue moved before inclusion.
    function test_regression_aThreeLanePoolRouteSucceedsAtItsQuietEstimate() public {
        uint256 quiet = _least(3);
        console2.log("quiet three-lane route estimate", quiet);
        assertEq(_tryAt(3, quiet), 0);
        uint256[3] memory moves = [uint256(5e21), 3e22, 1e23];
        for (uint256 m; m < moves.length; ++m) {
            uint256 snap = vm.snapshotState();
            _move(moves[m], moves[m], moves[m]);
            console2.log("outside buys on every venue; least limit now", moves[m], _least(3));
            assertEq(_tryAt(3, quiet), 0, "the quiet estimate funds the mined route");
            assertEq(_tryAt(3, quiet * 110 / 100), 0, "and with the usual margin");
            assertGt(_allRecaptured(3, quiet), 0);
            vm.revertToState(snap);
        }
    }

    /// The other direction: estimated while every pool had a gap to close, mined after someone else closed them. The
    /// earlier lane swaps spend less when mined, and the slack they leave rises by what the later check gains.
    function test_estimate_aRouteEstimatedWhileRecapturingSucceedsOnceQuiet() public {
        for (uint256 hops = 2; hops <= 3; ++hops) {
            uint256[3] memory moves = [uint256(5e21), 3e22, 1e23];
            for (uint256 m; m < moves.length; ++m) {
                uint256 snap = vm.snapshotState();
                _move(moves[m], moves[m], moves[m]);
                uint256 busy = _least(hops);
                vm.revertToState(snap);
                uint256 quiet = _least(hops);
                console2.log(
                    "lane swaps, outside buy; estimate while recapturing, least limit once quiet", hops, moves[m]
                );
                console2.log("  ", busy, quiet);
                assertEq(_tryAt(hops, busy), 0, "the estimate made while recapturing funds the quiet route");
                assertEq(_tryAt(hops, busy * 110 / 100), 0, "and with the usual margin");
                _allRecaptured(hops, busy);
            }
        }
    }

    /// Each lane swap of the route runs its own before-phase: a gap on A opened outside is closed before the route's
    /// swap on A is quoted, even behind a dust lane swap on B in the same transaction. No lane swap is skipped.
    function test_held_aLaterLaneSwapIsRecapturedToo() public {
        _move(0, 3e22, 0);
        (uint256[] memory ran, uint256[] memory pushedBefore) = _ranAt(2, 30_000_000, address(root));
        assertEq(ran[0], 2, "the first lane swap recaptured");
        assertEq(ran[1], 2, "the second lane swap recaptured");
        assertGt(pushedBefore[1], 0, "A's gap was closed before the route's swap on A");
        console2.log("pushed by A's before-phase inside the route", pushedBefore[1]);
    }

    function sellAt(uint256 g) external {
        require(msg.sender == address(this));
        IHookrRouter.Swap memory p = _swapParams(a, ETH, false, true, 1e18, whale);
        vm.prank(whale);
        router.swap{gas: g}(p, address(0), new uint256[](0));
    }

    function _leastSell() internal returns (uint256 hi) {
        uint256 lo = 100_000;
        hi = 20_000_000;
        while (hi - lo > 1_000) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            try this.sellAt(mid) {
                hi = mid;
            } catch {
                lo = mid;
            }
            vm.revertToState(snap);
        }
    }

    /// A due LP donation (an arb recapture's LP share from an earlier block) is donated at the start of the next lane
    /// swap, inside the swap's own work the entry floor funds: a sell and a two-lane route estimated with nothing due
    /// succeed at those limits with donations due on the pools they cross, and the donations happen.
    function test_estimate_aDueDonationIsFundedByTheQuietEstimate() public {
        uint256 quietSell = _leastSell();
        uint256 quietRoute = _least(2);
        _buy(a, ETH, whale, 3e22);
        _buy(b, Currency.wrap(address(tokenB)), whale, 3e22);
        _nextBlock();
        (uint256 d0, uint256 d1, uint256 f0, uint256 f1,) = _recap().pendingDonation(a.toId());
        assertGt(d0 + d1 + f0 + f1, 0, "a donation due on A");
        assertGt(_accrued(b), 0, "and on B");
        console2.log("quiet estimates: sell, two-lane route", quietSell, quietRoute);
        assertEq(_tryAt(2, quietRoute), 0, "the quiet route estimate funds the route with donations due");
        uint256 due0 = d0 + f0;
        uint256 due1 = d1 + f1;
        this.sellAt(quietSell);
        (d0, d1,,,) = _recap().pendingDonation(a.toId());
        // One parent block, 120 L2 blocks: 120/RELEASE of each part, rounded up.
        assertEq(
            d0, due0 - _releasedAfter(due0, RELEASE / RELEASE_PARENTS, RELEASE), "a part donated at the sell's start"
        );
        assertEq(
            d1, due1 - _releasedAfter(due1, RELEASE / RELEASE_PARENTS, RELEASE), "a part donated at the sell's start"
        );
    }

    /// The entry floor, and the least limits of a one-pool sell and of the two- and three-lane routes, at the 3M,
    /// 1.5M and 1M caps: a route carries about the entry floor of each lane swap.
    function test_gas_entryFloorAndLeastLimitsAt3M_1_5M_1M() public {
        uint32[3] memory caps = [uint32(3_000_000), 1_500_000, 1_000_000];
        for (uint256 i; i < caps.length; ++i) {
            if (i != 0) registry.tuneExecutorLane(address(root), address(ex), caps[i]);
            (,,,,, uint32 cap, uint256 floor) = IHookrLaneRoot(address(root)).laneOf(a.toId());
            assertEq(cap, caps[i]);
            assertEq(floor, _entryFloor(cap), "2 x cap + cap/63 + 755,000");
            uint256 one = _leastSell();
            uint256 route2 = _least(2);
            uint256 route3 = _least(3);
            console2.log("cap, entry floor", cap, floor);
            console2.log("  least limit: one-pool sell, two-lane route, three-lane route", one, route2, route3);
            assertGt(one, floor);
            assertGt(route2, 2 * floor, "a two-lane route carries both entry floors");
            assertGt(route3, 3 * floor, "a three-lane route carries all three");
        }
    }
}

/// @notice VERIFY-1 at its widest swing: an executor that burns its whole grant in both phases when mined and is idle
///         when estimated (or the reverse), on two- and three-lane routes at the 3M cap. Every lane call runs with its
///         full grant in both states (the burning frames fail open), and the estimate of either state funds the
///         other: the later check moves with exactly what the earlier lane swaps spent.
contract MultiHopWorstCaseTest is LaneRootFixture, MultiHopRoutes {
    using PoolIdLibrary for PoolKey;

    ScriptedExecutor internal burner;

    function setUp() public {
        _setUpLane();
        burner = new ScriptedExecutor(manager);
        burner.setRoot(address(root));
        _openLane(address(burner), 3_000_000);
        Currency qb = Currency.wrap(address(tokenB));
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _member(ETH, true, false, 0);
        members[1] = _member(qb, true, false, 0);
        (, PoolKey[] memory keys) = _launch(_newSubject(), members);
        IHookrLauncher.Member[] memory one = new IHookrLauncher.Member[](1);
        one[0] = _member(ETH, true, false, 0);
        (, PoolKey[] memory keys2) = _launch(_newSubject(), one);
        hop = new HopRoute(manager);
        tokenB.transfer(address(hop), 1e26);
        vm.deal(address(hop), 1e20);
        two.push(HopRoute.Hop(keys[1], Currency.unwrap(keys[1].currency0) == address(tokenB)));
        two.push(HopRoute.Hop(keys[0], false));
        three.push(two[0]);
        three.push(two[1]);
        three.push(HopRoute.Hop(keys2[0], true));
        _nextBlock();
    }

    function _ranEverywhere(uint256 hops, uint256 g) internal {
        (uint256[] memory ran,) = _ranAt(hops, g, address(root));
        for (uint256 h; h < ran.length; ++h) {
            assertEq(ran[h], 2, "both lane calls on every lane pool of the route");
        }
    }

    function test_regression_anIdleEstimateFundsARouteWhoseArbRecapturesBurnTheirGrants() public {
        for (uint256 hops = 2; hops <= 3; ++hops) {
            burner.set(ScriptedExecutor.Mode.NOTHING, 0);
            uint256 idle = _least(hops);
            burner.set(ScriptedExecutor.Mode.BURN_GAS, 0);
            uint256 burning = _least(hops);
            console2.log("lane swaps; least limit idle, burning", hops, idle, burning);
            assertEq(_tryAt(hops, idle), 0, "the idle estimate funds the burning route");
            assertEq(_tryAt(hops, idle * 110 / 100), 0);
            _ranEverywhere(hops, idle);
        }
    }

    function test_estimate_aBurningEstimateFundsAnIdleRoute() public {
        for (uint256 hops = 2; hops <= 3; ++hops) {
            burner.set(ScriptedExecutor.Mode.BURN_GAS, 0);
            uint256 burning = _least(hops);
            burner.set(ScriptedExecutor.Mode.NOTHING, 0);
            uint256 idle = _least(hops);
            console2.log("lane swaps; least limit burning, idle", hops, burning, idle);
            assertEq(_tryAt(hops, burning), 0, "the burning estimate funds the idle route");
            assertEq(_tryAt(hops, burning * 110 / 100), 0);
            _ranEverywhere(hops, burning);
        }
    }
}
