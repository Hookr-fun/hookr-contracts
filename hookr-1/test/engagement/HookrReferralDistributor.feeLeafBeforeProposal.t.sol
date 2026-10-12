// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IHookrReferralDistributor} from "../../src/interfaces/IHookrReferralDistributor.sol";
import {ReferralSecurityFixture} from "../utils/ReferralSecurityFixture.sol";

/// @notice I-18: feeLeaf() read the stored epoch hashes, so a leaf built before proposeDay used zero hashes
///         and could never verify. Unfixed (ReferralRepro.t.sol at 877cfb9): proposing that leaf finalized a
///         root nobody could credit and locked the 1000-wei day. Now feeLeaf() reverts until a proposal exists,
///         feeLeafFor() builds leaves from the exact hashes to be proposed, and (L-20) a finalized but
///         uncreditable day still returns the cash it can never owe.
contract HookrReferralDistributorFeeLeafBeforeProposalTest is ReferralSecurityFixture {
    function testHelperRefusesBeforeProposalAndExplicitBuilderMatches() public {
        IHookrReferralDistributor.Terms memory t = _terms();
        uint256 id = distributor.createCampaign(t);
        uint64 first = _enroll(id, trader, referrer);
        vm.warp(t.end);
        vm.expectRevert(abi.encodeWithSelector(IHookrReferralDistributor.NoLiveProposal.selector, id, 0));
        distributor.feeLeaf(id, 0, trader, referrer, first, 1000);
        bytes32 leaf = distributor.feeLeafFor(id, 0, COVERAGE, COLLECTIONS, trader, referrer, first, 1000);
        assertEq(leaf, _leaf(id, 0, trader, referrer, first, 1000));
        distributor.proposeDay(id, 0, leaf, 1000, COVERAGE, COLLECTIONS);
        assertEq(distributor.feeLeaf(id, 0, trader, referrer, first, 1000), leaf);
        _finalizeAfterDelay(id, 0);
        distributor.creditDay(id, 0, trader, referrer, first, 1000, _noProof());
        assertEq(distributor.claimable(t.currency, referrer), 200);
    }

    function testHelperFollowsTheLatestProposal() public {
        IHookrReferralDistributor.Terms memory t = _terms();
        uint256 id = distributor.createCampaign(t);
        vm.warp(t.end);
        distributor.proposeDay(id, 0, keccak256("x"), 1000, COVERAGE, COLLECTIONS);
        bytes32 before_ = distributor.feeLeaf(id, 0, trader, referrer, 1, 1000);
        distributor.proposeDay(id, 0, keccak256("x"), 1000, COVERAGE, keccak256("corrected collections"));
        bytes32 after_ = distributor.feeLeaf(id, 0, trader, referrer, 1, 1000);
        assertTrue(before_ != after_);
        assertEq(
            after_,
            distributor.feeLeafFor(id, 0, COVERAGE, keccak256("corrected collections"), trader, referrer, 1, 1000)
        );
    }

    function testABadlyBuiltFinalizedRootNoLongerLocksTheNeverOwedCash() public {
        IHookrReferralDistributor.Terms memory t = _terms();
        uint256 id = distributor.createCampaign(t);
        uint64 first = _enroll(id, trader, referrer);
        vm.warp(t.end);
        // A leaf with zero evidence hashes, as the old pre-proposal helper returned.
        bytes32 bad = distributor.feeLeafFor(id, 0, bytes32(0), bytes32(0), trader, referrer, first, 1000);
        distributor.proposeDay(id, 0, bad, 1000, COVERAGE, COLLECTIONS);
        _finalizeAfterDelay(id, 0);
        vm.expectRevert(IHookrReferralDistributor.InvalidProof.selector);
        distributor.creditDay(id, 0, trader, referrer, first, 1000, _noProof());
        assertEq(distributor.releaseRemainder(id, 0, address(this)), 700); // was: 1000 locked, NotReady
        assertEq(distributor.reservedCash(t.currency), 300);
    }
}
