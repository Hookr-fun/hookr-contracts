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

/// @notice ATK-LF-1 regression: trader-rebate farming with a dust swap against the partner-shaped executor at the 3M
///         cap. A gap the poker did not open (a third party's outside move, or the remainder of someone else's large
///         swap) is larger than one lane call closes; the before-phase closes what fits in its grant (no trader credit)
///         and the after-phase closes more of the same gap. Before the fix the after-phase credited that to whoever
///         swapped; now the trader leg is paid only on what the poke's own move accounts for, and only when the
///         arb recapture undid it, so the poke is credited nothing and the LP accrual keeps the trader share.
contract DustRebateTest is PartnerShapedFixture {
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

    struct Poke {
        uint256 gapBefore;
        uint256 gapAfter;
        uint256 pushedBefore;
        uint256 pushedAfter;
        uint256 credit;
        uint256 failed;
        uint256 cutAfter;
    }

    /// @dev The attacker's dust sell (1e15 subject, ~0.001 ETH) through the pinned router, with the claim it earns.
    function _poke() internal returns (Poke memory p) {
        p.gapBefore = _gapBps(_px(a, s), _px(refA, s));
        uint256 c0 = rules.claimable(ETH, attacker);
        vm.recordLogs();
        _sell(a, ETH, attacker, 1e15);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        p.pushedBefore = o.pushedBefore;
        p.pushedAfter = o.pushedAfter;
        p.cutAfter = _cut(o.profitAfter, o.pushedAfter);
        p.failed = o.failed;
        p.credit = rules.claimable(ETH, attacker) - c0;
        p.gapAfter = _gapBps(_px(a, s), _px(refA, s));
    }

    function _log(string memory what, Poke memory p) internal pure {
        console2.log(what);
        console2.log("  outside gap before / after the poke (bps)", p.gapBefore, p.gapAfter);
        console2.log("  pushed before-phase / after-phase (wei)", p.pushedBefore, p.pushedAfter);
        console2.log("  dust poker's trader credit (wei)", p.credit);
        uint256 total = p.pushedBefore + p.pushedAfter;
        console2.log("  after-phase share of all pushed (bps)", total == 0 ? 0 : p.pushedAfter * 10_000 / total);
    }

    /// Control: the same dust sell with no outside gap earns nothing.
    function test_control_dustPokeWithoutAGapEarnsNothing() public {
        Poke memory p = _poke();
        _log("control, no outside move", p);
        assertEq(p.credit, 0);
    }

    /// A third party moves the outside venue (the subject runs up there); the attacker's dust sell on the lane pool
    /// is credited nothing of a gap it did not open.
    function test_regression_dustPokeAfterAnOutsideMoveIsCreditedNothing() public {
        uint256[3] memory sizes = [uint256(3e22), 1e23, 2e23];
        for (uint256 i; i < sizes.length; ++i) {
            uint256 snap = vm.snapshotState();
            venue.swap{value: sizes[i]}(refA, true, sizes[i], 0);
            // The attacker's own dust opens essentially nothing: measure what the same dust opens on an aligned
            // pool (control) to bound the part of the credit it earned.
            Poke memory p = _poke();
            _log(i == 0 ? "outside buy 3e22 ETH" : i == 1 ? "outside buy 1e23 ETH" : "outside buy 2e23 ETH", p);
            console2.log("  poke size (wei subject) / credit per wei poked", uint256(1e15), p.credit / 1e15);
            console2.log("  executor gas of the after-phase call / cap", ex.lastGas(), uint256(CAP));
            console2.log("  after-phase chunks: arbitrages, cycles", ex.lastArbs(), ex.lastCycles());
            assertEq(p.failed, 0, "both frames succeeded");
            assertGt(p.pushedBefore, 0, "the before-phase recaptured, uncredited");
            assertGt(p.pushedAfter, 0, "the after-phase closed more of the gap");
            assertEq(p.credit, 0, "the dust poke collected no trader credit");
            vm.revertToState(snap);
        }
    }

    /// The mechanism: the partner-shaped executor's before-phase buys the subject on the triggering member (following
    /// the outside venue); closing the family gap that this opens needs a sell on the same member, which the
    /// one-direction rule refuses inside that frame, so the after-phase does it. It runs the same way as the poke's
    /// sell, so it undid nothing of the poke's move and credits it nothing. The
    /// PoolManager's Swap events on the member show it: every executor leg before the poke's own swap is a buy, every
    /// one after it a sell.
    function test_mechanism_oneDirectionRuleDefersTheFamilyLegToTheCreditedPhase() public {
        venue.swap{value: 1e23}(refA, true, 1e23, 0);
        vm.recordLogs();
        _sell(a, ETH, attacker, 1e15);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 swapTopic = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        uint256[2][2] memory n; // [phase][0 buy, 1 sell]
        uint256 phase;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != swapTopic || logs[i].topics[1] != PoolId.unwrap(a.toId())) continue;
            address sender = address(uint160(uint256(logs[i].topics[2])));
            (int128 amount0,) = abi.decode(logs[i].data, (int128, int128));
            if (sender != address(ex)) {
                phase = 1; // the poke's own swap on the member (through the router)
                continue;
            }
            // ETH is currency0: a buy of the subject pays ETH in (amount0 negative for the swapper).
            n[phase][amount0 < 0 ? 0 : 1]++;
        }
        console2.log("executor legs on the member, before-phase: buys, sells", n[0][0], n[0][1]);
        console2.log("executor legs on the member, after-phase:  buys, sells", n[1][0], n[1][1]);
        assertGt(n[0][0], 0);
        assertEq(n[0][1], 0, "no sell leg on the member in the before-phase");
        assertGt(n[1][1], 0, "the after-phase sells on the member");
        assertEq(rules.claimable(ETH, attacker), 0, "an arb recapture in the poke's own direction credits nothing");
    }

    /// Repeated dust pokes after one outside move: each poke's before-phase closes more of the venue gap uncredited,
    /// which reopens a family gap that the same poke's after-phase closes, credited to no one.
    function test_regression_repeatedDustPokesHarvestNothing() public {
        venue.swap{value: 1e23}(refA, true, 1e23, 0);
        uint256 credit;
        uint256 pushedB;
        uint256 pushedA;
        uint256 cutA;
        for (uint256 i; i < 8; ++i) {
            Poke memory p = _poke();
            credit += p.credit;
            pushedB += p.pushedBefore;
            pushedA += p.pushedAfter;
            cutA += p.cutAfter;
            console2.log("poke, venue gap after (bps), credit (wei)", i, p.gapAfter, p.credit);
        }
        uint256 lpShareOfAfter = pushedA - cutA - credit;
        console2.log("8 pokes: total pushed before / after", pushedB, pushedA);
        console2.log("  poker credit total (wei), cost of pokes ~ 8e15 subject", credit);
        console2.log("  poker credit as bps of all pushed", credit * 10_000 / (pushedB + pushedA));
        console2.log("  LP accrual share of the after-phase pushes", lpShareOfAfter);
        assertGt(pushedA, 0);
        assertEq(credit, 0, "eight dust pokes collect nothing");
    }

    /// Someone else's very large buy leaves a remainder its own after-phase could not close inside the cap; the next
    /// dust poke's after-phase closes part of it and the poke is credited nothing of it.
    function test_regression_dustPokeCollectsNothingOfSomeoneElsesLargeBuy() public {
        uint256 whaleBefore = rules.claimable(ETH, whale);
        vm.recordLogs();
        _buy(a, ETH, whale, 2e23);
        Outcome memory w = _outcome(vm.getRecordedLogs());
        uint256 whaleCredit = rules.claimable(ETH, whale) - whaleBefore;
        uint256 gapLeft = _gapBps(_px(a, s), _px(refA, s));
        console2.log(
            "whale buy 2e23: pushed after-phase, whale credit, venue gap left (bps)",
            w.pushedAfter,
            whaleCredit,
            gapLeft
        );
        console2.log("  executor gas of the whale's after-phase", ex.lastGas());
        _nextBlock();
        Poke memory p = _poke();
        _log("dust poke after the whale", p);
        assertGt(whaleCredit, 0, "the whale was credited for its own move");
        assertEq(p.credit, 0, "the poke collected nothing of the whale's gap");
    }
}

/// @notice The launch-time variant: a family whose ETH member is still in its launch guard while its tokenB member is
///         not. Buys on the open member during the guard cannot be carried into the guarded member (a buy leg there
///         pays Snipe), so the family gap grows until the guard's public end block. The first dust poke after it has
///         its before-phase close part of the gap uncredited and its after-phase close more, now credited to no one.
contract GuardEndRebateTest is PartnerShapedFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    HookrToken internal subject;
    Currency internal s;
    Currency internal qb;
    PoolKey internal a;
    PoolKey internal b;
    PoolKey internal conn;
    uint256 internal guardEnd;

    function setUp() public {
        _setUpPartnerShaped();
        subject = _newSubject();
        subject.approve(address(venue), type(uint256).max);
        s = Currency.wrap(address(subject));
        qb = Currency.wrap(address(tokenB));
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _laneMemberAt(ETH);
        guardEnd = vm.getBlockNumber() + 50;
        members[0].rules.guardEndBlock = uint40(guardEnd);
        members[0].rules.snipeTaxPips = 500_000;
        members[0].rules.maxBuyQuoteAmount = 1e22;
        members[1] = _laneMemberAt(qb);
        (, PoolKey[] memory keys) = _launch(subject, members);
        (a, b) = (keys[0], keys[1]);
        conn = _hookless(ETH, qb);
        ex.setTrigger(a, 1e22);
        ex.addCycle(a, b, conn, CYCLE_GAP);
        ex.setTrigger(b, 1e22);
        ex.addCycle(b, a, conn, CYCLE_GAP);
        _nextBlock();
    }

    function _familyGap() internal view returns (uint256) {
        return _gapBps(_px(a, s), FullMath.mulDiv(_px(b, s), _px(conn, qb), 1e18));
    }

    /// Held with one route: the executor's before-phase closes the whole gap and nothing is credited.
    function test_held_oneRoute_beforePhaseClosesTheGuardBuiltGapUncredited() public {
        _run(false);
    }

    /// With an outside venue route as well, the first poke after the guard end is credited nothing either.
    function test_regression_withAVenueRoute_firstPokeAfterTheGuardEndIsCreditedNothing() public {
        _run(true);
    }

    function _run(bool withVenue) internal {
        if (withVenue) {
            PoolKey memory refA = _hookless(a.currency0, a.currency1);
            ex.addVenue(a, refA, PAIR_GAP);
        }
        for (uint256 i; i < 3; ++i) {
            _buy(b, qb, whale, 3e22);
            _nextBlock();
        }
        uint256 gapAtEnd = _familyGap();
        console2.log("family gap built during the ETH member's guard (bps)", gapAtEnd);
        assertGt(gapAtEnd, 500, "buy legs on the guarded member did not carry the demand");
        vm.roll(guardEnd);
        uint256 c0 = rules.claimable(ETH, attacker);
        vm.recordLogs();
        _sell(a, ETH, attacker, 1e15);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        uint256 credit = rules.claimable(ETH, attacker) - c0;
        console2.log("first poke after the guard: pushed before / after", o.pushedBefore, o.pushedAfter);
        console2.log("  poker credit (wei), family gap left (bps)", credit, _familyGap());
        assertGt(o.pushedBefore, 0, "the before-phase recaptured the guard-built gap, uncredited");
        assertEq(credit, 0, "the first poke after the guard end is credited nothing");
    }
}
