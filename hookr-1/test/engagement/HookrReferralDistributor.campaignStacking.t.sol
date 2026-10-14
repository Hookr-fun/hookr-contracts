// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {HookrReferralDistributor} from "../../src/engagement/HookrReferralDistributor.sol";
import {IHookrReferralDistributor} from "../../src/interfaces/IHookrReferralDistributor.sol";
import {ReferralSecurityFixture} from "../utils/ReferralSecurityFixture.sol";

/// @notice L-21: two independently funded campaigns on the same pool and fee source could each reimburse the
///         same collected fee. Unfixed (ReferralRepro.t.sol at 877cfb9): two 6000/3999 campaigns with two
///         different attestors credited 199,980,000,000,000 against one 100,000,000,000,000 fee, i.e. 19,998 bps.
///         Now (1) every campaign must name the one attestor pinned at deployment, whose ledger reserves each fee
///         lot once, so the second attestor of the original PoC is refused; and (2) as defense in depth, combined
///         payouts on one payer's fees for one pool, fee source and UTC day are capped at 9,999 bps of the
///         largest fee amount credited for them across every campaign, and the later campaign's unpaid share
///         returns to its creator.
contract HookrReferralDistributorCampaignStackingTest is ReferralSecurityFixture {
    address private funder2 = address(0xF00D);
    address private attestor2 = address(0xA77E);
    address private reviewer2 = address(0x4E71);
    address private alt = address(0xA17);

    function _pairOfCampaigns(uint16 r1, uint16 c1, uint16 r2, uint16 c2)
        private
        returns (uint256 id1, uint256 id2, IHookrReferralDistributor.Terms memory t)
    {
        t = _terms();
        t.dailyBudget = 1e18;
        t.walletFeeCap = type(uint128).max;
        t.referrerBps = r1;
        t.cashbackBps = c1;
        id1 = distributor.createCampaign(t);
        t.referrerBps = r2;
        t.cashbackBps = c2;
        t.reviewer = reviewer2;
        id2 = _createAs(funder2, t);
    }

    function _creditBoth(uint256 id1, uint256 id2, uint128 fees) private {
        uint64 first = _finalizeBoth(id1, id2, fees);
        distributor.creditDay(id1, 0, trader, alt, first, fees, _noProof());
        distributor.creditDay(id2, 0, trader, alt, first, fees, _noProof());
    }

    /// @dev The pinned attestor proposes the same fee lot for both campaigns, as if its single-reservation
    ///      ledger were bypassed; the onchain cap is what remains.
    function _finalizeBoth(uint256 id1, uint256 id2, uint128 fees) private returns (uint64 first) {
        first = _bindBoth(id1, id2);
        uint64 end = distributor.dayEnd(id1, 0);
        vm.warp(end);
        distributor.proposeDay(id1, 0, _leaf(id1, 0, trader, alt, first, fees), fees, COVERAGE, COLLECTIONS);
        distributor.proposeDay(id2, 0, _leaf(id2, 0, trader, alt, first, fees), fees, COVERAGE, COLLECTIONS);
        _finalizeAfterDelay(id1, 0);
        distributor.finalizeDay(id2, 0);
    }

    function _bindBoth(uint256 id1, uint256 id2) private returns (uint64 first) {
        bytes32 pk1 = distributor.campaign(id1).programKey;
        bytes32 pk2 = distributor.campaign(id2).programKey;
        vm.startPrank(trader);
        referrals.register(pk1, alt, bytes32(0));
        referrals.register(pk2, alt, bytes32(0));
        vm.stopPrank();
        vm.roll(vm.getBlockNumber() + 1);
        first = uint64(vm.getBlockNumber());
    }

    function _paid(IHookrReferralDistributor.Terms memory t, uint256 utcDay, address payer)
        private
        view
        returns (uint256 paid)
    {
        (, paid) = distributor.stackedRebate(t.poolId, t.feeSource, utcDay, payer);
    }

    /// @dev The original PoC's second campaign named its own attestor; that is now refused at creation.
    function testSecondAttestorIsRefused() public {
        IHookrReferralDistributor.Terms memory t = _terms();
        t.attestor = attestor2;
        t.reviewer = reviewer2;
        vm.expectRevert(abi.encodeWithSelector(IHookrReferralDistributor.InvalidAttestor.selector, attestor2));
        distributor.createCampaign(t);
        assertEq(distributor.campaignCount(), 0);
        assertEq(distributor.attestor(), address(this));
        vm.expectRevert(abi.encodeWithSelector(IHookrReferralDistributor.InvalidAttestor.selector, address(0)));
        new HookrReferralDistributor(address(referrals), address(registry), address(0));
    }

    function testSameFeeCannotBeReimbursedTwice() public {
        (uint256 id1, uint256 id2, IHookrReferralDistributor.Terms memory t) = _pairOfCampaigns(6000, 3999, 6000, 3999);
        uint128 fees = 1e14;
        uint64 first = _finalizeBoth(id1, id2, fees);
        distributor.creditDay(id1, 0, trader, alt, first, fees, _noProof());
        uint256 nominal = uint256(fees) * 6000 / 10_000 + uint256(fees) * 3999 / 10_000;
        vm.expectEmit(true, true, true, true, address(distributor));
        emit IHookrReferralDistributor.StackingCapApplied(id2, 0, trader, nominal, 0);
        distributor.creditDay(id2, 0, trader, alt, first, fees, _noProof());
        uint256 got = distributor.claimable(t.currency, trader) + distributor.claimable(t.currency, alt);
        emit log_named_uint("reimbursed bps of one fee (was 19998)", got * 10_000 / fees);
        assertEq(got, nominal);
        assertLe(got * 10_000, uint256(fees) * distributor.MAX_STACKED_BPS());
        (uint256 basis, uint256 paid) =
            distributor.stackedRebate(t.poolId, t.feeSource, uint256(t.start) / 1 days, trader);
        assertEq(basis, fees);
        assertEq(paid, got);
        // The second funder's day settles and its whole budget comes back.
        vm.prank(funder2);
        assertEq(distributor.releaseRemainder(id2, 0, funder2), t.dailyBudget);
        assertTrue(distributor.epoch(id2, 0).released);
    }

    function testLaterCampaignPaysOnlyRemainingCapacityProRata() public {
        (uint256 id1, uint256 id2, IHookrReferralDistributor.Terms memory t) = _pairOfCampaigns(2000, 1000, 6000, 3000);
        uint128 fees = 1e14;
        _creditBoth(id1, id2, fees);
        // Campaign 1 paid 3000 bps of the fee; campaign 2 asked 9000 bps and gets the 6999 left, split 6000:3000.
        uint256 room = uint256(fees) * 9999 / 10_000 - uint256(fees) * 3000 / 10_000;
        uint256 c2Commission = room * 6000 / 9000;
        uint256 c2Cashback = room * 3000 / 9000;
        assertEq(distributor.claimable(t.currency, alt), uint256(fees) * 2000 / 10_000 + c2Commission);
        assertEq(distributor.claimable(t.currency, trader), uint256(fees) * 1000 / 10_000 + c2Cashback);
        assertEq(distributor.epoch(id2, 0).allocated, c2Commission + c2Cashback);
        uint256 total = distributor.claimable(t.currency, alt) + distributor.claimable(t.currency, trader);
        assertLe(total * 10_000, uint256(fees) * 9999);
    }

    function testCapacityIsPerPayerPerDayAndPerFeeSource() public {
        IHookrReferralDistributor.Terms memory t = _terms();
        t.dailyBudget = 1e18;
        t.walletFeeCap = type(uint128).max;
        t.referrerBps = 6000;
        t.cashbackBps = 3999;
        uint256 protocolId = distributor.createCampaign(t);
        t.feeSource = IHookrReferralDistributor.FeeSource.CreatorRoyalty;
        uint256 royaltyId = distributor.createCampaign(t);
        uint64 first = _bindBoth(protocolId, royaltyId);
        vm.warp(t.end);
        uint128 fees = 1e14;
        distributor.proposeDay(
            protocolId, 0, _leaf(protocolId, 0, trader, alt, first, fees), fees, COVERAGE, COLLECTIONS
        );
        distributor.proposeDay(royaltyId, 0, _leaf(royaltyId, 0, trader, alt, first, fees), fees, COVERAGE, COLLECTIONS);
        _finalizeAfterDelay(protocolId, 0);
        distributor.finalizeDay(royaltyId, 0);
        distributor.creditDay(protocolId, 0, trader, alt, first, fees, _noProof());
        distributor.creditDay(royaltyId, 0, trader, alt, first, fees, _noProof());
        // Protocol fee and royalty are different fee bases: each is reimbursed at most 99.99% of itself.
        assertEq(distributor.epoch(royaltyId, 0).allocated, distributor.epoch(protocolId, 0).allocated);
        uint256 utcDay = uint256(t.start) / 1 days;
        uint256 full = uint256(fees) * 6000 / 10_000 + uint256(fees) * 3999 / 10_000;
        IHookrReferralDistributor.Terms memory p = t;
        p.feeSource = IHookrReferralDistributor.FeeSource.Protocol;
        assertEq(_paid(p, utcDay, trader), full);
        assertEq(_paid(t, utcDay, trader), full);
        assertEq(_paid(p, utcDay + 1, trader), 0);
        assertEq(_paid(p, utcDay, alt), 0);
    }

    function testFuzz_stackedRebateNeverReachesTheFee(uint16 r1, uint16 c1, uint16 r2, uint16 c2, uint128 fees) public {
        r1 = uint16(bound(r1, 1, 9998));
        c1 = uint16(bound(c1, 0, 9999 - r1));
        r2 = uint16(bound(r2, 1, 9998));
        c2 = uint16(bound(c2, 0, 9999 - r2));
        fees = uint128(bound(fees, 1, 1e18));
        (uint256 id1, uint256 id2, IHookrReferralDistributor.Terms memory t) = _pairOfCampaigns(r1, c1, r2, c2);
        _creditBoth(id1, id2, fees);
        uint256 got = distributor.claimable(t.currency, trader) + distributor.claimable(t.currency, alt);
        assertLe(got * 10_000, uint256(fees) * 9999);
        assertEq(_paid(t, uint256(t.start) / 1 days, trader), got);
        // The first campaign credited always takes its full nominal amount.
        assertEq(distributor.epoch(id1, 0).allocated, uint256(fees) * r1 / 10_000 + uint256(fees) * c1 / 10_000);
    }
}
