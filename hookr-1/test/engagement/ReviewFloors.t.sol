// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {ReferralSecurityFixture} from "../utils/ReferralSecurityFixture.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrReferralRegistry} from "../../src/engagement/HookrReferralRegistry.sol";
import {IHookrReferralDistributor} from "../../src/interfaces/IHookrReferralDistributor.sol";
import {HookrPrograms} from "../../src/engagement/HookrPrograms.sol";
import {IHookrPrograms} from "../../src/interfaces/IHookrPrograms.sol";
import {HookrProgramValidator} from "../../src/engagement/HookrProgramValidator.sol";
import {HookrProgramTypes as P} from "../../src/types/HookrProgramTypes.sol";

/// @dev Chain 4663's forced-inclusion delay: its parent SequencerInbox's delayBlocks, 28,800 parent blocks, read at L1
///      block 26,063,772, four days at 12 s (more when parent slots are missed). A transaction the sequencer withholds
///      can be forced in through the delayed inbox once they have passed since the block it reached the inbox in, so
///      these tests include a forced transaction exactly this long after its send; on chain it lands at least one
///      parent block later.
uint256 constant FORCED_INCLUSION_DELAY = 4 days;
/// @dev The same inbox's maxTimeVariation futureSeconds and delaySeconds: the sequencer may stamp a block up to
///      FUTURE_SECONDS ahead of the parent chain's time and up to DELAY_SECONDS behind it.
uint256 constant FUTURE_SECONDS = 3_600;
uint256 constant DELAY_SECONDS = 345_600;

/// @dev A sequencer timeline that stamps L2 time only inside the inbox's bounds and never moves it back. A forced
///      transaction executes at the later of the parent-chain time it reached the inbox and the last L2 timestamp.
abstract contract SequencerClock {
    uint256 internal lastL2;

    function _stamp(uint256 l1, uint256 l2) internal {
        require(l2 >= lastL2, "L2 time never moves back");
        require(l2 <= l1 + FUTURE_SECONDS, "at most futureSeconds ahead of the parent chain");
        require(l2 + DELAY_SECONDS >= l1, "at most delaySeconds behind the parent chain");
        lastL2 = l2;
    }

    function _forcedAt(uint256 sentL1) internal view returns (uint256) {
        return sentL1 > lastL2 ? sentL1 : lastL2;
    }
}

/// @notice The Programs review floor is six days, two above the forced-inclusion delay. These cases model a reviewer
///         whose veto is forced in, with L2 time equal to parent-chain time unless a case says otherwise: (1) sent by
///         finalizeAfter - 4 days - 1 s it lands before anyone can finalize; (2) in a full outage every transaction is
///         forced in in L1 order, so a veto sent at the last second lands before a finalize sent at finalizeAfter (the
///         veto stays open until finalization); (3) under targeted censorship the sequencer includes a finalize at
///         finalizeAfter while the veto waits, and the veto is refused; (4) the delay bounds; (5) and (6) the hour the
///         sequencer may stamp ahead of the parent chain comes off the window; (7) and (8) a proposal stamped behind
///         parent-chain time shortens the window by its lag, which is why the window holds only under honest
///         timestamps.
contract ProgramsReviewFloorsTest is PeripheryFixture, SequencerClock {
    using PoolIdLibrary for PoolKey;

    HookrPrograms internal programs;
    HookrProgramValidator internal validator;
    PoolKey internal key;
    address internal attestor = address(0xA11);
    address internal reviewer = address(0xB22);
    bytes32 internal constant COVERAGE = keccak256("coverage");

    function setUp() public {
        _setUpPeriphery();
        (, key,,) = _launch(true, false);
        programs =
            new HookrPrograms(manager, address(router), address(this), 1e30, address(new HookrReferralRegistry()));
        validator = HookrProgramValidator(address(programs.validator()));
        tokenB.approve(address(programs), type(uint256).max);
    }

    function _terms(uint64 reviewDelay) internal view returns (P.Terms memory t) {
        t.mode = P.Mode.DailySwap;
        t.start = uint64((vm.getBlockTimestamp() / 1 days + 1) * 1 days);
        t.end = t.start + 1 days;
        t.pointBudget = 1000e18;
        t.walletPointCap = 1000e18;
        t.dailyPointBudget = 1000e18;
        t.rewardToken = address(tokenB);
        t.cashBudget = 100e18;
        t.walletCashCap = 100e18;
        t.dailyCashBudget = 100e18;
        t.attestor = attestor;
        t.reviewer = reviewer;
        t.reviewDelay = reviewDelay;
        t.sourcePolicyHash = keccak256("daily swap");
        t.name = "Daily";
        t.pointDecimals = 18;
    }

    function _scopes() internal view returns (P.Scope[] memory s) {
        s = new P.Scope[](1);
        s[0] = P.Scope(
            address(root),
            PoolId.unwrap(key.toId()),
            root.policyHash(key.toId()),
            Currency.unwrap(root.poolConfig(key.toId()).quote),
            1,
            1,
            0,
            0
        );
    }

    function _create(uint64 reviewDelay) internal returns (uint256) {
        return
            programs.createProgram(
                _terms(reviewDelay), _scopes(), new P.Milestone[](0), P.NFTMetadata("", "", "", false)
            );
    }

    /// @dev A program at the review floor with day 0 proposed; returns its id and the proposal's finalizeAfter.
    function _proposed() internal returns (uint256 id, uint256 finalizeAfter) {
        id = _create(validator.MIN_REVIEW_DELAY());
        vm.warp(programs.program(id).terms.end);
        vm.prank(attestor);
        programs.proposeDay(id, 0, keccak256("bad root"), 1, COVERAGE, keccak256("evidence"));
        finalizeAfter = programs.epoch(id, 0).finalizeAfter;
    }

    function test_floorIsTwoDaysAboveTheForcedInclusionDelay() public view {
        assertEq(validator.MIN_REVIEW_DELAY(), 6 days);
        assertEq(validator.MIN_REVIEW_DELAY() - FORCED_INCLUSION_DELAY, 2 days);
        assertEq(validator.MAX_REVIEW_DELAY(), 30 days);
        assertEq(FORCED_INCLUSION_DELAY, 345_600);
    }

    /// (1) A veto sent at finalizeAfter - 4 days - 1 s is forced in exactly 4 days later, one second before anyone can
    /// finalize: it lands and the day cannot be finalized.
    function test_vetoForcedInFromTheGuaranteedWindowLands() public {
        (uint256 id, uint256 finalizeAfter) = _proposed();
        uint256 sent = finalizeAfter - FORCED_INCLUSION_DELAY - 1;
        vm.warp(sent + FORCED_INCLUSION_DELAY);
        vm.expectRevert(IHookrPrograms.NotReady.selector);
        programs.finalizeDay(id, 0);
        vm.prank(reviewer);
        programs.challengeDay(id, 0, keccak256("forced in"));
        vm.warp(finalizeAfter);
        vm.expectRevert(IHookrPrograms.NotReady.selector);
        programs.finalizeDay(id, 0);
        assertTrue(programs.epoch(id, 0).challenged);
        assertFalse(programs.epoch(id, 0).finalized);
    }

    /// (2) A full outage: every transaction is forced in 4 days after it is sent, in L1 order. The veto sent at
    /// finalizeAfter - 1 s lands before the finalize sent at finalizeAfter, and the veto, open until finalization,
    /// holds.
    function test_outageForcesTheEarlierVetoInBeforeTheFinalize() public {
        (uint256 id, uint256 finalizeAfter) = _proposed();
        vm.warp(finalizeAfter - 1 + FORCED_INCLUSION_DELAY);
        vm.prank(reviewer);
        programs.challengeDay(id, 0, keccak256("sent at the last second"));
        vm.warp(finalizeAfter + FORCED_INCLUSION_DELAY);
        vm.expectRevert(IHookrPrograms.NotReady.selector);
        programs.finalizeDay(id, 0);
        assertTrue(programs.epoch(id, 0).challenged);
    }

    /// (3) Targeted censorship: the sequencer includes a finalize at finalizeAfter while the reviewer's veto, sent at
    /// finalizeAfter - 1 s, waits the 4 days of forced inclusion; it arrives after the finalize and is refused. Only a
    /// veto sent in the first reviewDelay - 4 days - 1 hour is sure to land, and only under honest timestamps.
    function test_censoredLateVetoLosesToAFinalizeIncludedFirst() public {
        (uint256 id, uint256 finalizeAfter) = _proposed();
        vm.warp(finalizeAfter);
        programs.finalizeDay(id, 0);
        vm.warp(finalizeAfter - 1 + FORCED_INCLUSION_DELAY);
        vm.prank(reviewer);
        vm.expectRevert(IHookrPrograms.NotReady.selector);
        programs.challengeDay(id, 0, keccak256("too late"));
        assertTrue(programs.epoch(id, 0).finalized);
        assertFalse(programs.epoch(id, 0).challenged);
    }

    /// (4) The review delay bounds: 6 days - 1 s and 30 days + 1 s are refused, 6 and 30 days accepted.
    function test_reviewDelayBounds() public {
        P.Scope[] memory s = _scopes();
        P.Terms memory t = _terms(6 days - 1);
        vm.expectRevert(IHookrPrograms.InvalidProgram.selector);
        programs.createProgram(t, s, new P.Milestone[](0), P.NFTMetadata("", "", "", false));
        t.reviewDelay = 30 days + 1;
        vm.expectRevert(IHookrPrograms.InvalidProgram.selector);
        programs.createProgram(t, s, new P.Milestone[](0), P.NFTMetadata("", "", "", false));
        assertEq(_create(6 days), 1);
        assertEq(_create(30 days), 2);
    }

    /// (5) Honest timestamps, the sequencer stamping as far ahead as it may: a veto sent at finalizeAfter - 4 days -
    /// 1 hour - 1 s is forced in at finalizeAfter - 1 hour - 1 s of parent-chain time, when no block can yet carry
    /// finalizeAfter, so it lands first and the day cannot be finalized.
    function test_vetoSentAnHourInsideTheWindowBeatsAFinalizeStampedAhead() public {
        (uint256 id, uint256 finalizeAfter) = _proposed();
        _stamp(vm.getBlockTimestamp(), vm.getBlockTimestamp());
        uint256 sent = finalizeAfter - FORCED_INCLUSION_DELAY - FUTURE_SECONDS - 1;
        uint256 l1 = sent + FORCED_INCLUSION_DELAY;
        _stamp(l1, l1 + FUTURE_SECONDS);
        vm.warp(l1 + FUTURE_SECONDS);
        vm.expectRevert(IHookrPrograms.NotReady.selector);
        programs.finalizeDay(id, 0);
        vm.warp(_forcedAt(sent));
        vm.prank(reviewer);
        programs.challengeDay(id, 0, keccak256("forced in"));
        _stamp(finalizeAfter - FUTURE_SECONDS, finalizeAfter);
        vm.warp(finalizeAfter);
        vm.expectRevert(IHookrPrograms.NotReady.selector);
        programs.finalizeDay(id, 0);
        assertTrue(programs.epoch(id, 0).challenged);
    }

    /// (6) Why the hour comes off: a veto sent at finalizeAfter - 4 days - 30 minutes arrives at finalizeAfter - 30
    /// minutes of parent-chain time, but the sequencer could stamp a block finalizeAfter from finalizeAfter - 1 hour and
    /// include a finalize in it, so the veto arrives after the finalize and is refused.
    function test_vetoSentInTheSequencersLeadLosesToAFinalizeStampedAhead() public {
        (uint256 id, uint256 finalizeAfter) = _proposed();
        _stamp(vm.getBlockTimestamp(), vm.getBlockTimestamp());
        uint256 sent = finalizeAfter - FORCED_INCLUSION_DELAY - 30 minutes;
        _stamp(finalizeAfter - FUTURE_SECONDS, finalizeAfter);
        vm.warp(finalizeAfter);
        programs.finalizeDay(id, 0);
        uint256 l1 = sent + FORCED_INCLUSION_DELAY;
        assertLt(l1, finalizeAfter, "the veto arrives before finalizeAfter in parent-chain time");
        _stamp(l1, _forcedAt(sent));
        vm.warp(_forcedAt(sent));
        vm.prank(reviewer);
        vm.expectRevert(IHookrPrograms.NotReady.selector);
        programs.challengeDay(id, 0, keccak256("forced in after the finalize"));
        assertTrue(programs.epoch(id, 0).finalized);
    }

    /// (7) A proposal stamped 46 hours behind parent-chain time: a veto sent the moment the proposal is published is
    /// forced in at publication + 4 days, an hour before any block can carry finalizeAfter, and lands.
    function test_aLagOf46HoursLeavesAVetoAtPublicationAnHour() public {
        (uint256 id, uint256 finalizeAfter) = _proposed();
        uint256 published = vm.getBlockTimestamp() + 46 hours;
        _stamp(published, vm.getBlockTimestamp());
        _stamp(published + FORCED_INCLUSION_DELAY, _forcedAt(published));
        vm.warp(_forcedAt(published));
        vm.prank(reviewer);
        programs.challengeDay(id, 0, keccak256("forced in"));
        assertEq(published + FORCED_INCLUSION_DELAY + 1 hours, finalizeAfter - FUTURE_SECONDS);
        _stamp(finalizeAfter - FUTURE_SECONDS, finalizeAfter);
        vm.warp(finalizeAfter);
        vm.expectRevert(IHookrPrograms.NotReady.selector);
        programs.finalizeDay(id, 0);
        assertTrue(programs.epoch(id, 0).challenged);
    }

    /// (8) A proposal stamped 47 hours behind parent-chain time, 2 days - 1 hour at this floor: the sequencer can
    /// stamp a block finalizeAfter by publication + 4 days, before a veto sent at publication can be forced in, so the
    /// veto loses. No veto sent after publication can land first.
    function test_aLagOf47HoursClosesTheWindowAtTheFloor() public {
        (uint256 id, uint256 finalizeAfter) = _proposed();
        uint256 published = vm.getBlockTimestamp() + 47 hours;
        _stamp(published, vm.getBlockTimestamp());
        assertEq(finalizeAfter - FUTURE_SECONDS, published + FORCED_INCLUSION_DELAY);
        _stamp(finalizeAfter - FUTURE_SECONDS, finalizeAfter);
        vm.warp(finalizeAfter);
        programs.finalizeDay(id, 0);
        _stamp(published + FORCED_INCLUSION_DELAY, _forcedAt(published));
        vm.warp(_forcedAt(published));
        vm.prank(reviewer);
        vm.expectRevert(IHookrPrograms.NotReady.selector);
        programs.challengeDay(id, 0, keccak256("forced in after the finalize"));
        assertTrue(programs.epoch(id, 0).finalized);
    }
}

/// @notice The referral review floor is six days and the veto grace five, two days and one day above the
///         forced-inclusion delay. The same cases, with the grace: a veto stays open until finalizeAfter + 5 days
///         unless someone finalized first, so the outage case lands inside it, and a veto at finalizeAfter + 5 days
///         is closed.
contract ReferralReviewFloorsTest is ReferralSecurityFixture, SequencerClock {
    function _proposed() internal returns (uint256 id, uint256 finalizeAfter) {
        IHookrReferralDistributor.Terms memory t = _terms();
        id = distributor.createCampaign(t);
        vm.warp(t.end);
        distributor.proposeDay(id, 0, keccak256("bad root"), 1000, COVERAGE, COLLECTIONS);
        finalizeAfter = distributor.epoch(id, 0).finalizeAfter;
    }

    function test_floorAndGraceAboveTheForcedInclusionDelay() public view {
        assertEq(distributor.MIN_REVIEW_DELAY(), 6 days);
        assertEq(distributor.MIN_REVIEW_DELAY() - FORCED_INCLUSION_DELAY, 2 days);
        assertEq(distributor.VETO_GRACE(), 5 days);
        assertEq(distributor.VETO_GRACE() - FORCED_INCLUSION_DELAY, 1 days);
        assertEq(distributor.MAX_REVIEW_DELAY(), 30 days);
    }

    /// (1) Sent at finalizeAfter - 4 days - 1 s and forced in 4 days later, the veto lands before anyone can finalize.
    function test_vetoForcedInFromTheGuaranteedWindowLands() public {
        (uint256 id, uint256 finalizeAfter) = _proposed();
        uint256 sent = finalizeAfter - FORCED_INCLUSION_DELAY - 1;
        vm.warp(sent + FORCED_INCLUSION_DELAY);
        vm.expectRevert(IHookrReferralDistributor.NotReady.selector);
        distributor.finalizeDay(id, 0);
        vm.prank(royalty);
        distributor.challengeDay(id, 0, keccak256("forced in"));
        vm.warp(finalizeAfter);
        vm.expectRevert(IHookrReferralDistributor.NotReady.selector);
        distributor.finalizeDay(id, 0);
        assertTrue(distributor.epoch(id, 0).challenged);
    }

    /// (2) A full outage: the veto sent at finalizeAfter - 1 s is forced in at finalizeAfter + 4 days - 1 s, inside the
    /// 5-day grace and before the finalize sent at finalizeAfter, which is then refused.
    function test_outageForcesTheEarlierVetoInBeforeTheFinalize() public {
        (uint256 id, uint256 finalizeAfter) = _proposed();
        vm.warp(finalizeAfter - 1 + FORCED_INCLUSION_DELAY);
        assertLt(vm.getBlockTimestamp(), finalizeAfter + distributor.VETO_GRACE());
        vm.prank(royalty);
        distributor.challengeDay(id, 0, keccak256("sent at the last second"));
        vm.warp(finalizeAfter + FORCED_INCLUSION_DELAY);
        vm.expectRevert(IHookrReferralDistributor.NotReady.selector);
        distributor.finalizeDay(id, 0);
        assertTrue(distributor.epoch(id, 0).challenged);
    }

    /// (3) Targeted censorship: a finalize included at finalizeAfter beats a veto sent at finalizeAfter - 1 s that waits
    /// the 4 days of forced inclusion; the veto arrives inside the grace and is still refused, the day being final.
    function test_censoredLateVetoLosesToAFinalizeIncludedFirst() public {
        (uint256 id, uint256 finalizeAfter) = _proposed();
        vm.warp(finalizeAfter);
        distributor.finalizeDay(id, 0);
        vm.warp(finalizeAfter - 1 + FORCED_INCLUSION_DELAY);
        vm.prank(royalty);
        vm.expectRevert(IHookrReferralDistributor.NotReady.selector);
        distributor.challengeDay(id, 0, keccak256("too late"));
        assertTrue(distributor.epoch(id, 0).finalized);
    }

    /// (4) The review delay bounds, and the grace's edge: a veto at finalizeAfter + 5 days - 1 s lands, one at
    /// finalizeAfter + 5 days is closed.
    function test_reviewDelayBoundsAndTheGraceEdge() public {
        IHookrReferralDistributor.Terms memory t = _terms();
        t.reviewDelay = 6 days - 1;
        vm.expectRevert(IHookrReferralDistributor.InvalidCampaign.selector);
        distributor.createCampaign(t);
        t.reviewDelay = 30 days + 1;
        vm.expectRevert(IHookrReferralDistributor.InvalidCampaign.selector);
        distributor.createCampaign(t);
        t.reviewDelay = 30 days;
        assertEq(distributor.createCampaign(t), 1);
        (uint256 id, uint256 finalizeAfter) = _proposed();
        assertEq(finalizeAfter, vm.getBlockTimestamp() + 6 days);
        uint256 closedAt = finalizeAfter + 5 days;
        uint256 snapshot = vm.snapshotState();
        vm.warp(closedAt - 1);
        vm.prank(royalty);
        distributor.challengeDay(id, 0, keccak256("last second of the grace"));
        assertTrue(distributor.epoch(id, 0).challenged);
        vm.revertToState(snapshot);
        vm.warp(closedAt);
        vm.prank(royalty);
        vm.expectRevert(abi.encodeWithSelector(IHookrReferralDistributor.VetoClosed.selector, id, 0, closedAt));
        distributor.challengeDay(id, 0, keccak256("grace over"));
    }

    /// (5) Honest timestamps, the sequencer stamping as far ahead as it may: a veto sent at finalizeAfter - 4 days -
    /// 1 hour - 1 s lands before any block can carry finalizeAfter.
    function test_vetoSentAnHourInsideTheWindowBeatsAFinalizeStampedAhead() public {
        (uint256 id, uint256 finalizeAfter) = _proposed();
        _stamp(vm.getBlockTimestamp(), vm.getBlockTimestamp());
        uint256 sent = finalizeAfter - FORCED_INCLUSION_DELAY - FUTURE_SECONDS - 1;
        uint256 l1 = sent + FORCED_INCLUSION_DELAY;
        _stamp(l1, l1 + FUTURE_SECONDS);
        vm.warp(l1 + FUTURE_SECONDS);
        vm.expectRevert(IHookrReferralDistributor.NotReady.selector);
        distributor.finalizeDay(id, 0);
        vm.warp(_forcedAt(sent));
        vm.prank(royalty);
        distributor.challengeDay(id, 0, keccak256("forced in"));
        _stamp(finalizeAfter - FUTURE_SECONDS, finalizeAfter);
        vm.warp(finalizeAfter);
        vm.expectRevert(IHookrReferralDistributor.NotReady.selector);
        distributor.finalizeDay(id, 0);
        assertTrue(distributor.epoch(id, 0).challenged);
    }

    /// (6) A veto sent at finalizeAfter - 4 days - 30 minutes arrives after a finalize the sequencer stamped
    /// finalizeAfter at finalizeAfter - 1 hour of parent-chain time, and is refused although the grace is open.
    function test_vetoSentInTheSequencersLeadLosesToAFinalizeStampedAhead() public {
        (uint256 id, uint256 finalizeAfter) = _proposed();
        _stamp(vm.getBlockTimestamp(), vm.getBlockTimestamp());
        uint256 sent = finalizeAfter - FORCED_INCLUSION_DELAY - 30 minutes;
        _stamp(finalizeAfter - FUTURE_SECONDS, finalizeAfter);
        vm.warp(finalizeAfter);
        distributor.finalizeDay(id, 0);
        uint256 l1 = sent + FORCED_INCLUSION_DELAY;
        assertLt(l1, finalizeAfter, "the veto arrives before finalizeAfter in parent-chain time");
        _stamp(l1, _forcedAt(sent));
        vm.warp(_forcedAt(sent));
        assertLt(vm.getBlockTimestamp(), finalizeAfter + distributor.VETO_GRACE());
        vm.prank(royalty);
        vm.expectRevert(IHookrReferralDistributor.NotReady.selector);
        distributor.challengeDay(id, 0, keccak256("forced in after the finalize"));
        assertTrue(distributor.epoch(id, 0).finalized);
    }

    /// (7) A proposal stamped 46 hours behind parent-chain time: a veto sent at publication still lands an hour before
    /// any block can carry finalizeAfter.
    function test_aLagOf46HoursLeavesAVetoAtPublicationAnHour() public {
        (uint256 id, uint256 finalizeAfter) = _proposed();
        uint256 published = vm.getBlockTimestamp() + 46 hours;
        _stamp(published, vm.getBlockTimestamp());
        _stamp(published + FORCED_INCLUSION_DELAY, _forcedAt(published));
        vm.warp(_forcedAt(published));
        vm.prank(royalty);
        distributor.challengeDay(id, 0, keccak256("forced in"));
        assertEq(published + FORCED_INCLUSION_DELAY + 1 hours, finalizeAfter - FUTURE_SECONDS);
        _stamp(finalizeAfter - FUTURE_SECONDS, finalizeAfter);
        vm.warp(finalizeAfter);
        vm.expectRevert(IHookrReferralDistributor.NotReady.selector);
        distributor.finalizeDay(id, 0);
        assertTrue(distributor.epoch(id, 0).challenged);
    }

    /// (8) A proposal stamped 47 hours behind parent-chain time closes the window at this floor: a finalize stamped
    /// finalizeAfter lands by publication + 4 days, before a veto sent at publication can be forced in.
    function test_aLagOf47HoursClosesTheWindowAtTheFloor() public {
        (uint256 id, uint256 finalizeAfter) = _proposed();
        uint256 published = vm.getBlockTimestamp() + 47 hours;
        _stamp(published, vm.getBlockTimestamp());
        assertEq(finalizeAfter - FUTURE_SECONDS, published + FORCED_INCLUSION_DELAY);
        _stamp(finalizeAfter - FUTURE_SECONDS, finalizeAfter);
        vm.warp(finalizeAfter);
        distributor.finalizeDay(id, 0);
        _stamp(published + FORCED_INCLUSION_DELAY, _forcedAt(published));
        vm.warp(_forcedAt(published));
        vm.prank(royalty);
        vm.expectRevert(IHookrReferralDistributor.NotReady.selector);
        distributor.challengeDay(id, 0, keccak256("forced in after the finalize"));
        assertTrue(distributor.epoch(id, 0).finalized);
    }
}
