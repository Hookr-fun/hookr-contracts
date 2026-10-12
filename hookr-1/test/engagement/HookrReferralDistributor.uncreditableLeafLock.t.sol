// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IHookrReferralDistributor} from "../../src/interfaces/IHookrReferralDistributor.sol";
import {ReferralSecurityFixture} from "../utils/ReferralSecurityFixture.sol";

/// @notice L-20: releaseRemainder required claimedFees == totalFees, so one uncreditable leaf locked the
///         whole day, and an unproposed day stayed locked until the attestor acted. Unfixed
///         (ReferralRepro.t.sol at 877cfb9): dailyBudget 1e18, totalFees 3001, one over-cap leaf; after 10
///         years 999,999,999,999,999,700 stayed locked, of which 999,999,999,999,999,100 could never be owed.
///         Now the never-owable part is released as soon as the day is finalized, and a day nobody proposes (or
///         that stays vetoed) lapses to zero after the 90-day proposal window, without the attestor.
contract HookrReferralDistributorUncreditableLeafLockTest is ReferralSecurityFixture {
    address private a = address(0xA11CE);
    address private b = address(0xB0B);

    function _overCapDay()
        private
        returns (uint256 id, IHookrReferralDistributor.Terms memory t, uint64 first, bytes32 la, bytes32 lb)
    {
        t = _terms();
        t.dailyBudget = 1e18;
        id = distributor.createCampaign(t);
        bytes32 pk = distributor.campaign(id).programKey;
        vm.prank(a);
        referrals.register(pk, referrer, bytes32(0));
        vm.prank(b);
        referrals.register(pk, referrer, bytes32(0));
        vm.roll(vm.getBlockNumber() + 1);
        first = uint64(vm.getBlockNumber());
        vm.warp(t.end);
        la = _leaf(id, 0, a, referrer, first, 1000);
        lb = _leaf(id, 0, b, referrer, first, 2001); // over walletFeeCap 2000: never creditable
        distributor.proposeDay(id, 0, _pair(la, lb), 3001, COVERAGE, COLLECTIONS);
        _finalizeAfterDelay(id, 0);
    }

    function testNeverOwableCashIsReleasedDespiteUncreditableLeaf() public {
        (uint256 id, IHookrReferralDistributor.Terms memory t, uint64 first, bytes32 la, bytes32 lb) = _overCapDay();
        bytes32[] memory p = new bytes32[](1);
        p[0] = lb;
        distributor.creditDay(id, 0, a, referrer, first, 1000, p);
        p[0] = la;
        vm.expectRevert(IHookrReferralDistributor.InvalidProof.selector);
        distributor.creditDay(id, 0, b, referrer, first, 2001, p);
        // max still owable = floor(2001 * 30%) = 600; allocated = 300.
        assertEq(distributor.releaseRemainder(id, 0, address(this)), 999_999_999_999_999_100);
        assertEq(distributor.reservedCash(t.currency), 900); // 300 claimable + 600 that could still be owed
        assertEq(distributor.refunded(id, 0), 999_999_999_999_999_100);
        assertFalse(distributor.epoch(id, 0).released);
        vm.expectRevert(abi.encodeWithSelector(IHookrReferralDistributor.NothingToRelease.selector, id, 0));
        distributor.releaseRemainder(id, 0, address(this));
    }

    function testReleaseBeforeCreditsNeverStarvesALegitimateCredit() public {
        (uint256 id, IHookrReferralDistributor.Terms memory t, uint64 first,, bytes32 lb) = _overCapDay();
        // Released first: 1e18 - floor(3001 * 30%) = 1e18 - 900.
        assertEq(distributor.releaseRemainder(id, 0, address(this)), 1e18 - 900);
        bytes32[] memory p = new bytes32[](1);
        p[0] = lb;
        distributor.creditDay(id, 0, a, referrer, first, 1000, p);
        assertEq(distributor.claimable(t.currency, referrer) + distributor.claimable(t.currency, a), 300);
        vm.expectRevert(abi.encodeWithSelector(IHookrReferralDistributor.NothingToRelease.selector, id, 0));
        distributor.releaseRemainder(id, 0, address(this));
        assertEq(distributor.reservedCash(t.currency), 900);
    }

    function testUnproposedDayLapsesAfterTheProposalWindowOnly() public {
        IHookrReferralDistributor.Terms memory t = _terms();
        uint256 id = distributor.createCampaign(t);
        uint256 closes = uint256(distributor.dayEnd(id, 0)) + distributor.PROPOSAL_WINDOW();
        vm.warp(closes - 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrReferralDistributor.LapseNotOpen.selector, id, 0, closes));
        distributor.lapseDay(id, 0);
        vm.expectRevert(IHookrReferralDistributor.NotReady.selector);
        distributor.releaseRemainder(id, 0, address(this));
        vm.warp(closes);
        distributor.lapseDay(id, 0); // anyone; the attestor is no longer needed
        assertEq(distributor.releaseRemainder(id, 0, address(this)), t.dailyBudget);
        assertEq(distributor.reservedCash(t.currency), 0);
        vm.expectRevert(IHookrReferralDistributor.NotReady.selector);
        distributor.proposeDay(id, 0, bytes32(0), 0, COVERAGE, COLLECTIONS);
    }

    function testLastMinuteProposalStillSettlesNormally() public {
        IHookrReferralDistributor.Terms memory t = _terms();
        t.reviewDelay = distributor.MAX_REVIEW_DELAY();
        uint256 id = distributor.createCampaign(t);
        uint64 first = _enroll(id, trader, referrer);
        uint256 closes = uint256(distributor.dayEnd(id, 0)) + distributor.PROPOSAL_WINDOW();
        vm.warp(closes - 1);
        distributor.proposeDay(id, 0, _leaf(id, 0, trader, referrer, first, 1000), 1000, COVERAGE, COLLECTIONS);
        uint64 fa = distributor.epoch(id, 0).finalizeAfter;
        vm.warp(closes + 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrReferralDistributor.LapseNotOpen.selector, id, 0, fa));
        distributor.lapseDay(id, 0);
        _finalizeAfterDelay(id, 0);
        distributor.creditDay(id, 0, trader, referrer, first, 1000, _noProof());
        assertEq(distributor.releaseRemainder(id, 0, address(this)), 700);
        assertTrue(distributor.epoch(id, 0).released);
    }

    /// @dev Whatever is released early, every credit a finalized root can still honour succeeds, and the
    ///      reserve always covers claimables plus the maximum still owable.
    function testFuzz_earlyReleaseKeepsEveryOwableCreditBacked(uint128 fa, uint128 fb, uint128 junk, bool early)
        public
    {
        IHookrReferralDistributor.Terms memory t = _terms();
        t.dailyBudget = 1e18;
        t.walletFeeCap = type(uint128).max;
        fa = uint128(bound(fa, 1, 1e18));
        fb = uint128(bound(fb, 1, 1e18));
        junk = uint128(bound(junk, 0, 1e18));
        uint256 id = distributor.createCampaign(t);
        bytes32 pk = distributor.campaign(id).programKey;
        vm.prank(a);
        referrals.register(pk, referrer, bytes32(0));
        vm.prank(b);
        referrals.register(pk, referrer, bytes32(0));
        vm.roll(vm.getBlockNumber() + 1);
        uint64 first = uint64(vm.getBlockNumber());
        vm.warp(t.end);
        bytes32 la = _leaf(id, 0, a, referrer, first, fa);
        bytes32 lb = _leaf(id, 0, b, referrer, first, fb);
        uint256 total = uint256(fa) + fb + junk; // junk: fees committed but never creditable
        distributor.proposeDay(id, 0, _pair(la, lb), total, COVERAGE, COLLECTIONS);
        _finalizeAfterDelay(id, 0);
        if (early) distributor.releaseRemainder(id, 0, address(this));
        bytes32[] memory p = new bytes32[](1);
        p[0] = lb;
        distributor.creditDay(id, 0, a, referrer, first, fa, p);
        if (early) {
            try distributor.releaseRemainder(id, 0, address(this)) {} catch {}
        }
        p[0] = la;
        distributor.creditDay(id, 0, b, referrer, first, fb, p);
        uint256 owed = distributor.claimable(t.currency, referrer) + distributor.claimable(t.currency, a)
            + distributor.claimable(t.currency, b);
        assertEq(owed, uint256(fa) * 3000 / 10_000 + uint256(fb) * 3000 / 10_000 - _splitDust(fa) - _splitDust(fb));
        if (junk * 3000 / 10_000 == 0) {
            // An early release may already have closed the day: once b's and junk's fees could earn nothing
            // (floor((fb + junk) * 30%) == 0), nothing more was owable and the release was final.
            if (!distributor.epoch(id, 0).released) distributor.releaseRemainder(id, 0, address(this));
            assertTrue(distributor.epoch(id, 0).released);
            assertEq(distributor.reservedCash(t.currency), owed);
        } else {
            try distributor.releaseRemainder(id, 0, address(this)) {} catch {}
            assertEq(distributor.reservedCash(t.currency), owed + junk * 3000 / 10_000);
        }
    }

    /// @dev Independent review counterexample (9 of 16 seeds failed on 1b61b81's test, not the contract): the
    ///      mid-test release closed the day because nothing more was owable, then the test released again.
    function testReviewCounterexampleEarlyReleaseClosedTheDay() public {
        testFuzz_earlyReleaseKeepsEveryOwableCreditBacked(1_502_786_671_252, 2, 1, true);
        assertTrue(distributor.epoch(1, 0).released);
    }

    /// @dev Commission and cashback are floored separately: 20% + 10% can be one unit below 30%.
    function _splitDust(uint128 f) private pure returns (uint256) {
        return uint256(f) * 3000 / 10_000 - (uint256(f) * 2000 / 10_000 + uint256(f) * 1000 / 10_000);
    }
}
