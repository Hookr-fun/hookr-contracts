// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IHookrReferralDistributor} from "../../src/interfaces/IHookrReferralDistributor.sol";
import {ReferralSecurityFixture} from "../utils/ReferralSecurityFixture.sol";

/// @notice L-18 (distributor side): a reviewer veto was not sticky. proposeDay reset `challenged`, so the
///         attestor could re-propose the vetoed root at once and one missed review window finalized it.
///         Unfixed (test/security/ReferralRepro.t.sol at 877cfb9, 1-hour window): 24 veto/re-propose rounds,
///         then one lapse finalized a self-allocating root credited 999,999,999,999,999,999 of a 1e18 budget.
///         Now a veto survives every re-proposal; only reviewer approval of an exact version lifts it, and a day
///         left vetoed lapses to zero after the proposal window.
contract HookrReferralDistributorStickyVetoTest is ReferralSecurityFixture {
    address private attestor = address(0xA77E);
    address private creator = address(0xC0FFEE);

    function _pinnedAttestor() internal view override returns (address) {
        return attestor;
    }

    function _campaign() private returns (uint256 id, IHookrReferralDistributor.Terms memory t) {
        t = _terms();
        t.attestor = attestor;
        t.dailyBudget = 1e18;
        t.walletFeeCap = type(uint128).max;
        t.end = t.start + 2 days;
        id = _createAs(creator, t);
    }

    function testReproposingNeverClearsAVeto() public {
        (uint256 id, IHookrReferralDistributor.Terms memory t) = _campaign();
        uint64 first = _enroll(id, attestor, referrer);
        vm.warp(t.end);
        uint128 fees = uint128(uint256(t.dailyBudget) * 10_000 / 3000);
        bytes32 bad = _leaf(id, 0, attestor, referrer, first, fees);
        _proposeAs(attestor, id, 0, bad, fees);
        vm.prank(royalty);
        distributor.challengeDay(id, 0, keccak256("theft"));
        // The original loop re-proposed the identical commitment, then a varied evidence hash.
        _proposeAs(attestor, id, 0, bad, fees);
        assertTrue(distributor.epoch(id, 0).challenged);
        vm.prank(attestor);
        distributor.proposeDay(id, 0, bad, fees, COVERAGE, keccak256("varied evidence"));
        assertTrue(distributor.epoch(id, 0).challenged);
        assertEq(distributor.epoch(id, 0).version, 3);
        // No reviewer liveness is needed any more: however long the reviewer is away, the root never finalizes.
        vm.warp(vm.getBlockTimestamp() + 3650 days);
        vm.expectRevert(IHookrReferralDistributor.NotReady.selector);
        distributor.finalizeDay(id, 0);
        vm.expectRevert(IHookrReferralDistributor.InvalidProof.selector);
        distributor.creditDay(id, 0, attestor, referrer, first, fees, _noProof());
        assertEq(distributor.epoch(id, 0).allocated, 0);
    }

    function testReviewerApprovesACorrectedExactVersion() public {
        (uint256 id, IHookrReferralDistributor.Terms memory t) = _campaign();
        uint64 first = _enroll(id, trader, referrer);
        vm.warp(t.end);
        _proposeAs(attestor, id, 0, keccak256("bad"), 1000);
        vm.prank(royalty);
        distributor.challengeDay(id, 0, keccak256("wrong"));
        _proposeAs(attestor, id, 0, _leaf(id, 0, trader, referrer, first, 1000), 1000);
        // Only the reviewer approves, and only the current version.
        vm.prank(attestor);
        vm.expectRevert(abi.encodeWithSelector(IHookrReferralDistributor.NotReviewer.selector, attestor));
        distributor.approveDay(id, 0, 2);
        vm.prank(royalty);
        vm.expectRevert(abi.encodeWithSelector(IHookrReferralDistributor.StaleVersion.selector, id, 0, 2));
        distributor.approveDay(id, 0, 1);
        vm.prank(royalty);
        vm.expectRevert(abi.encodeWithSelector(IHookrReferralDistributor.StaleVersion.selector, id, 0, 2));
        distributor.approveDay(id, 0, 0);
        vm.prank(royalty);
        distributor.approveDay(id, 0, 2);
        IHookrReferralDistributor.Epoch memory e = distributor.epoch(id, 0);
        assertTrue(e.finalized);
        assertFalse(e.challenged);
        // Approval finalizes at once, but credits still wait for this version's review window to end.
        vm.expectRevert(
            abi.encodeWithSelector(IHookrReferralDistributor.CreditNotOpen.selector, id, 0, e.finalizeAfter)
        );
        distributor.creditDay(id, 0, trader, referrer, first, 1000, _noProof());
        vm.warp(e.finalizeAfter);
        distributor.creditDay(id, 0, trader, referrer, first, 1000, _noProof());
        assertEq(distributor.claimable(t.currency, referrer), 200);
        assertEq(distributor.claimable(t.currency, trader), 100);
        vm.prank(royalty);
        vm.expectRevert(abi.encodeWithSelector(IHookrReferralDistributor.DayFinalized.selector, id, 0));
        distributor.approveDay(id, 0, 2);
    }

    function testApprovalCannotBeRiddenByAReplacementProposal() public {
        (uint256 id, IHookrReferralDistributor.Terms memory t) = _campaign();
        vm.warp(t.end);
        _proposeAs(attestor, id, 0, bytes32(0), 0);
        // The attestor front-runs the reviewer's approval of version 1 with a different version 2.
        _proposeAs(attestor, id, 0, keccak256("swapped in"), 1000);
        vm.prank(royalty);
        vm.expectRevert(abi.encodeWithSelector(IHookrReferralDistributor.StaleVersion.selector, id, 0, 2));
        distributor.approveDay(id, 0, 1);
        assertFalse(distributor.epoch(id, 0).finalized);
    }

    function testUnresolvedVetoLapsesAndReturnsTheBudget() public {
        (uint256 id, IHookrReferralDistributor.Terms memory t) = _campaign();
        vm.warp(t.end);
        _proposeAs(attestor, id, 1, keccak256("bad"), 1000);
        vm.prank(royalty);
        distributor.challengeDay(id, 1, keccak256("wrong"));
        uint256 closes = uint256(distributor.dayEnd(id, 1)) + distributor.PROPOSAL_WINDOW();
        vm.warp(closes - 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrReferralDistributor.LapseNotOpen.selector, id, 1, closes));
        distributor.lapseDay(id, 1);
        vm.warp(closes);
        vm.expectRevert(abi.encodeWithSelector(IHookrReferralDistributor.ProposalWindowClosed.selector, id, 1, closes));
        _proposeAs(attestor, id, 1, keccak256("late"), 1000);
        distributor.lapseDay(id, 1);
        IHookrReferralDistributor.Epoch memory e = distributor.epoch(id, 1);
        assertTrue(e.finalized);
        assertEq(e.totalFees, 0);
        assertEq(e.merkleRoot, bytes32(0));
        vm.prank(royalty);
        vm.expectRevert(abi.encodeWithSelector(IHookrReferralDistributor.DayFinalized.selector, id, 1));
        distributor.approveDay(id, 1, e.version);
        assertEq(distributor.releaseRemainder(id, 1, creator), t.dailyBudget);
        assertTrue(distributor.epoch(id, 1).released);
        vm.expectRevert(abi.encodeWithSelector(IHookrReferralDistributor.DayFinalized.selector, id, 1));
        distributor.lapseDay(id, 1);
    }

    function testPendingUnvetoedProposalCannotLapse() public {
        (uint256 id, IHookrReferralDistributor.Terms memory t) = _campaign();
        uint256 closes = uint256(distributor.dayEnd(id, 0)) + distributor.PROPOSAL_WINDOW();
        vm.warp(closes - 1);
        _proposeAs(attestor, id, 0, bytes32(0), 0);
        uint64 fa = distributor.epoch(id, 0).finalizeAfter;
        vm.warp(closes + 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrReferralDistributor.LapseNotOpen.selector, id, 0, fa));
        distributor.lapseDay(id, 0);
        vm.warp(fa);
        vm.expectRevert(abi.encodeWithSelector(IHookrReferralDistributor.PendingProposal.selector, id, 0, 1));
        distributor.lapseDay(id, 0);
        distributor.finalizeDay(id, 0);
        assertEq(distributor.releaseRemainder(id, 0, creator), t.dailyBudget);
    }

    function testFuzz_noReproposalSequenceFinalizesAVetoedRoot(uint8 rounds, uint32 gap) public {
        (uint256 id, IHookrReferralDistributor.Terms memory t) = _campaign();
        vm.warp(t.end);
        _proposeAs(attestor, id, 0, keccak256("bad"), 1000);
        vm.prank(royalty);
        distributor.challengeDay(id, 0, keccak256("veto"));
        rounds = uint8(bound(rounds, 1, 24));
        for (uint256 i; i < rounds; ++i) {
            vm.warp(vm.getBlockTimestamp() + bound(gap, 1, 3 days));
            if (vm.getBlockTimestamp() >= uint256(distributor.dayEnd(id, 0)) + distributor.PROPOSAL_WINDOW()) break;
            vm.prank(attestor);
            distributor.proposeDay(id, 0, keccak256(abi.encode("bad", i)), 1000, COVERAGE, keccak256(abi.encode(i)));
            assertTrue(distributor.epoch(id, 0).challenged);
            vm.warp(vm.getBlockTimestamp() + t.reviewDelay);
            vm.expectRevert(IHookrReferralDistributor.NotReady.selector);
            distributor.finalizeDay(id, 0);
        }
        assertFalse(distributor.epoch(id, 0).finalized);
    }
}
