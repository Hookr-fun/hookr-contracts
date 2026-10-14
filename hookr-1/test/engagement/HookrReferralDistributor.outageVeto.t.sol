// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IHookrReferralDistributor} from "../../src/interfaces/IHookrReferralDistributor.sol";
import {ReferralSecurityFixture} from "../utils/ReferralSecurityFixture.sol";

/// @notice L-23: the veto window could be 1 hour and challengeDay stopped at finalizeAfter, so a sequencer
///         outage or censorship longer than the rest of the window removed the veto. Unfixed
///         (ReferralRepro.t.sol at 877cfb9, reviewDelay 1 hour): the challenge at finalizeAfter reverted and
///         anyone finalized the bad day.
///         Now the window is at least 6 days (two days above chain 4663's 4-day forced-inclusion delay), and a
///         veto is accepted for one forced-inclusion delay and a day more (VETO_GRACE, 5 days) after the window
///         unless someone finalized first, so a veto held back by an outage still lands. After that grace a mature day can
///         no longer be voided (independent review: an unbounded veto let a reviewer void a mature day 88 days
///         late and lapse it back to the creator).
contract HookrReferralDistributorOutageVetoTest is ReferralSecurityFixture {
    function testOneHourWindowIsRejected() public {
        IHookrReferralDistributor.Terms memory t = _terms();
        t.reviewDelay = 1 hours;
        vm.expectRevert(IHookrReferralDistributor.InvalidCampaign.selector);
        distributor.createCampaign(t);
        t.reviewDelay = distributor.MIN_REVIEW_DELAY() - 1;
        vm.expectRevert(IHookrReferralDistributor.InvalidCampaign.selector);
        distributor.createCampaign(t);
        t.reviewDelay = distributor.MAX_REVIEW_DELAY() + 1;
        vm.expectRevert(IHookrReferralDistributor.InvalidCampaign.selector);
        distributor.createCampaign(t);
        t.reviewDelay = distributor.MIN_REVIEW_DELAY();
        distributor.createCampaign(t);
        assertEq(distributor.MIN_REVIEW_DELAY() - 4 days, 2 days);
    }

    function testVetoLandingAfterAnOutageStillBeatsFinalization() public {
        IHookrReferralDistributor.Terms memory t = _terms();
        t.end = t.start + 2 days;
        uint256 id = distributor.createCampaign(t);
        vm.warp(t.end);
        distributor.proposeDay(id, 0, keccak256("bad0"), 1000, COVERAGE, COLLECTIONS);
        distributor.proposeDay(id, 1, keccak256("bad1"), 1000, COVERAGE, COLLECTIONS);
        uint64 fa = distributor.epoch(id, 1).finalizeAfter;
        // The first block after an outage that covered the rest of the window (unfixed: this veto reverted).
        vm.warp(fa);
        vm.prank(royalty);
        distributor.challengeDay(id, 1, keccak256("landed after the gap"));
        vm.expectRevert(IHookrReferralDistributor.NotReady.selector);
        distributor.finalizeDay(id, 1);
        // A veto held back for up to one forced-inclusion delay after the window still lands.
        vm.warp(fa + distributor.VETO_GRACE() - 1);
        vm.prank(royalty);
        distributor.challengeDay(id, 0, keccak256("late but first"));
        vm.expectRevert(IHookrReferralDistributor.NotReady.selector);
        distributor.finalizeDay(id, 0);
        assertFalse(distributor.epoch(id, 0).finalized);
        assertFalse(distributor.epoch(id, 1).finalized);
    }

    /// @dev Independent review (testLateVetoVoidsMatureDay): a proposal nobody finalized could be vetoed 88 days
    ///      after its window and lapsed, returning the full 1000 to the creator while the trader's credit reverted.
    ///      Now the veto closes at finalizeAfter + VETO_GRACE and the mature day still finalizes and pays.
    function testMatureDayCannotBeVoidedAfterTheGrace() public {
        IHookrReferralDistributor.Terms memory t = _terms();
        uint256 id = distributor.createCampaign(t);
        uint64 first = _enroll(id, trader, referrer);
        vm.warp(t.end);
        distributor.proposeDay(id, 0, _leaf(id, 0, trader, referrer, first, 1000), 1000, COVERAGE, COLLECTIONS);
        uint256 closedAt = uint256(distributor.epoch(id, 0).finalizeAfter) + distributor.VETO_GRACE();
        vm.warp(closedAt);
        vm.prank(royalty);
        vm.expectRevert(abi.encodeWithSelector(IHookrReferralDistributor.VetoClosed.selector, id, 0, closedAt));
        distributor.challengeDay(id, 0, keccak256("late"));
        vm.warp(t.end + 90 days);
        vm.prank(royalty);
        vm.expectRevert(abi.encodeWithSelector(IHookrReferralDistributor.VetoClosed.selector, id, 0, closedAt));
        distributor.challengeDay(id, 0, keccak256("late"));
        vm.expectRevert(abi.encodeWithSelector(IHookrReferralDistributor.PendingProposal.selector, id, 0, uint64(1)));
        distributor.lapseDay(id, 0);
        distributor.finalizeDay(id, 0);
        distributor.creditDay(id, 0, trader, referrer, first, 1000, _noProof());
        assertEq(distributor.claimable(t.currency, referrer) + distributor.claimable(t.currency, trader), 300);
        assertEq(distributor.releaseRemainder(id, 0, address(this)), 700);
    }

    /// @dev Each re-proposal restarts the review window, and with it the veto window.
    function testReproposalReopensTheVeto() public {
        IHookrReferralDistributor.Terms memory t = _terms();
        uint256 id = distributor.createCampaign(t);
        vm.warp(t.end);
        distributor.proposeDay(id, 0, keccak256("v1"), 1000, COVERAGE, COLLECTIONS);
        vm.warp(uint256(distributor.epoch(id, 0).finalizeAfter) + distributor.VETO_GRACE());
        distributor.proposeDay(id, 0, keccak256("v2"), 1000, COVERAGE, COLLECTIONS);
        vm.prank(royalty);
        distributor.challengeDay(id, 0, keccak256("v2 is wrong"));
        assertTrue(distributor.epoch(id, 0).challenged);
    }

    function testForcedInclusionWithinTheMinimumWindowLandsInTime() public {
        IHookrReferralDistributor.Terms memory t = _terms();
        uint256 id = distributor.createCampaign(t);
        vm.warp(t.end);
        distributor.proposeDay(id, 0, keccak256("bad"), 1000, COVERAGE, COLLECTIONS);
        uint64 fa = distributor.epoch(id, 0).finalizeAfter;
        // Censored reviewer submits at once through the delayed inbox; it lands 4 days later, before the end.
        vm.warp(vm.getBlockTimestamp() + 4 days);
        assertLt(vm.getBlockTimestamp(), fa);
        vm.prank(royalty);
        distributor.challengeDay(id, 0, keccak256("forced inclusion"));
        vm.warp(fa);
        vm.expectRevert(IHookrReferralDistributor.NotReady.selector);
        distributor.finalizeDay(id, 0);
    }

    function testFinalizedDayCannotBeVetoedAfterwards() public {
        IHookrReferralDistributor.Terms memory t = _terms();
        uint256 id = distributor.createCampaign(t);
        vm.warp(t.end);
        distributor.proposeDay(id, 0, bytes32(0), 0, COVERAGE, COLLECTIONS);
        _finalizeAfterDelay(id, 0);
        vm.prank(royalty);
        vm.expectRevert(IHookrReferralDistributor.NotReady.selector);
        distributor.challengeDay(id, 0, keccak256("too late"));
    }
}
