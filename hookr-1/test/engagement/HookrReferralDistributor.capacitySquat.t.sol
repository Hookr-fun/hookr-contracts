// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IHookrReferralDistributor} from "../../src/interfaces/IHookrReferralDistributor.sol";
import {ReferralSecurityFixture} from "../utils/ReferralSecurityFixture.sol";

/// @notice L-21 follow-up (independent review of 1b61b81): the first stacking cap counted bps, not cash, and any
///         campaign could use it. An attacker campaign with its own attestor and reviewer proposed a 1-wei fee
///         for a payer that had joined it, self-approved at once, credited first and used the payer's whole
///         9,999-bps capacity while paying 0; an honest 2000/1000 campaign then paid that payer and its referrer
///         0 on 1e15 of fees (unfixed base: 300,000,000,000,000), and the attacker's 1 wei came back. Honest
///         stacking lost too: a 9,999-bps campaign capped at 100 wei of fees zeroed a 3,000-bps campaign on 1e15
///         (99 wei reimbursed in total).
///         Now every campaign names the pinned attestor, capacity is used only by cash actually credited against
///         the largest fee amount credited, and credits open only when a version's review window has ended.
contract HookrReferralDistributorCapacitySquatTest is ReferralSecurityFixture {
    address private attacker = address(0xBAD);
    address private attA = address(0xBAD1);
    address private attR = address(0xBAD2);
    address private attRef = address(0xBAD3);
    address private creatorB = address(0xF00D);

    function _honestAndEvil(bool ownAttestor)
        private
        returns (uint256 honest, uint256 evil, IHookrReferralDistributor.Terms memory t)
    {
        t = _terms();
        t.dailyBudget = 1e18;
        t.walletFeeCap = type(uint128).max;
        honest = distributor.createCampaign(t);
        IHookrReferralDistributor.Terms memory b = _terms();
        b.referrerBps = 6000;
        b.cashbackBps = 3999;
        b.dailyBudget = 1;
        b.walletFeeCap = type(uint128).max;
        b.reviewer = attR;
        if (ownAttestor) {
            b.attestor = attA;
            vm.expectRevert(abi.encodeWithSelector(IHookrReferralDistributor.InvalidAttestor.selector, attA));
            distributor.createCampaign(b);
            return (honest, 0, t);
        }
        evil = _createAs(attacker, b);
    }

    function _joinBoth(uint256 honest, uint256 evil) private returns (uint64 first) {
        vm.startPrank(trader);
        referrals.register(distributor.campaign(honest).programKey, referrer, bytes32(0));
        if (evil != 0) referrals.register(distributor.campaign(evil).programKey, attRef, bytes32(0));
        vm.stopPrank();
        vm.roll(vm.getBlockNumber() + 1);
        first = uint64(vm.getBlockNumber());
    }

    function _honestPays(uint256 honest, IHookrReferralDistributor.Terms memory t, uint64 first, uint128 fees)
        private
        returns (uint256)
    {
        distributor.proposeDay(honest, 0, _leaf(honest, 0, trader, referrer, first, fees), fees, COVERAGE, COLLECTIONS);
        vm.warp(distributor.epoch(honest, 0).finalizeAfter);
        distributor.finalizeDay(honest, 0);
        distributor.creditDay(honest, 0, trader, referrer, first, fees, _noProof());
        return distributor.claimable(t.currency, trader) + distributor.claimable(t.currency, referrer);
    }

    /// @dev The review PoC as written: the attacker's campaign cannot even be created with its own attestor.
    function testSquat_OwnAttestorCampaignIsRefused() public {
        (uint256 honest,, IHookrReferralDistributor.Terms memory t) = _honestAndEvil(true);
        uint64 first = _joinBoth(honest, 0);
        vm.warp(t.end);
        uint256 got = _honestPays(honest, t, first, 1e15);
        emit log_named_uint("honest commission + cashback (1b61b81: 0)", got);
        assertEq(got, 3e14);
    }

    /// @dev Defense in depth: even if the pinned attestor attested the attacker's 1-wei leaf (a bypassed ledger)
    ///      and the attacker's reviewer approved it at once, the credit waits for its review window and pays 0,
    ///      so it uses no capacity and the honest campaign still pays in full. The attacker cannot propose.
    function testSquat_OneWeiLeafUsesNoCapacityAndApprovalGivesNoHeadStart() public {
        (uint256 honest, uint256 evil, IHookrReferralDistributor.Terms memory t) = _honestAndEvil(false);
        uint64 first = _joinBoth(honest, evil);
        vm.warp(t.end);
        bytes32 dust = _leaf(evil, 0, trader, attRef, first, 1);
        vm.prank(attacker);
        vm.expectRevert(IHookrReferralDistributor.NotReady.selector);
        distributor.proposeDay(evil, 0, dust, 1, COVERAGE, COLLECTIONS);
        distributor.proposeDay(evil, 0, dust, 1, COVERAGE, COLLECTIONS);
        vm.prank(attR);
        distributor.approveDay(evil, 0, 1);
        uint64 opens = distributor.epoch(evil, 0).finalizeAfter;
        vm.expectRevert(abi.encodeWithSelector(IHookrReferralDistributor.CreditNotOpen.selector, evil, 0, opens));
        distributor.creditDay(evil, 0, trader, attRef, first, 1, _noProof());
        vm.warp(opens);
        distributor.creditDay(evil, 0, trader, attRef, first, 1, _noProof());
        (uint256 basis, uint256 paid) =
            distributor.stackedRebate(t.poolId, t.feeSource, uint256(t.start) / 1 days, trader);
        assertEq(basis, 1);
        assertEq(paid, 0, "a credit that pays nothing uses no capacity (1b61b81: 9999 bps used)");
        uint256 got = _honestPays(honest, t, first, 1e15);
        emit log_named_uint("honest commission + cashback (1b61b81: 0)", got);
        assertEq(got, 3e14);
        vm.prank(attacker);
        assertEq(distributor.releaseRemainder(evil, 0, attacker), 1);
    }

    /// @dev Honest stacking: a 9,999-bps campaign capped at 100 wei of fees no longer zeroes a 3,000-bps campaign
    ///      covering 1e15 of fees (1b61b81: 0 allocated, 99 wei reimbursed in total).
    function testSquat_CapacityFollowsTheFeeAmount() public {
        IHookrReferralDistributor.Terms memory a = _terms();
        a.referrerBps = 6000;
        a.cashbackBps = 3999;
        a.dailyBudget = 1e18;
        a.walletFeeCap = 100;
        uint256 idA = distributor.createCampaign(a);
        IHookrReferralDistributor.Terms memory b = _terms();
        b.dailyBudget = 1e18;
        b.walletFeeCap = type(uint128).max;
        uint256 idB = _createAs(creatorB, b);
        vm.startPrank(trader);
        referrals.register(distributor.campaign(idA).programKey, referrer, bytes32(0));
        referrals.register(distributor.campaign(idB).programKey, referrer, bytes32(0));
        vm.stopPrank();
        vm.roll(vm.getBlockNumber() + 1);
        uint64 first = uint64(vm.getBlockNumber());
        vm.warp(a.end);
        distributor.proposeDay(idA, 0, _leaf(idA, 0, trader, referrer, first, 100), 100, COVERAGE, COLLECTIONS);
        distributor.proposeDay(idB, 0, _leaf(idB, 0, trader, referrer, first, 1e15), 1e15, COVERAGE, COLLECTIONS);
        _finalizeAfterDelay(idA, 0);
        distributor.finalizeDay(idB, 0);
        distributor.creditDay(idA, 0, trader, referrer, first, 100, _noProof());
        distributor.creditDay(idB, 0, trader, referrer, first, 1e15, _noProof());
        uint256 total = distributor.claimable(a.currency, trader) + distributor.claimable(a.currency, referrer);
        emit log_named_uint("total reimbursed of a 1e15 fee (1b61b81: 99)", total);
        assertEq(distributor.epoch(idA, 0).allocated, 99);
        assertEq(distributor.epoch(idB, 0).allocated, 3e14);
        assertEq(total, 3e14 + 99);
    }

    /// @dev Whatever the order and amounts, two campaigns never pay more than 9,999 bps of the larger attested
    ///      fee, the first credited always pays in full, and the second is cut only to the remaining room.
    function testFuzz_squat_CapIsCashWeightedAndOrderBounded(
        uint16 r1,
        uint16 c1,
        uint16 r2,
        uint16 c2,
        uint128 f1,
        uint128 f2
    ) public {
        r1 = uint16(bound(r1, 1, 9998));
        c1 = uint16(bound(c1, 0, 9999 - r1));
        r2 = uint16(bound(r2, 1, 9998));
        c2 = uint16(bound(c2, 0, 9999 - r2));
        f1 = uint128(bound(f1, 1, 1e18));
        f2 = uint128(bound(f2, 1, 1e18));
        IHookrReferralDistributor.Terms memory t = _terms();
        t.dailyBudget = 1e18;
        t.walletFeeCap = type(uint128).max;
        t.referrerBps = r1;
        t.cashbackBps = c1;
        uint256 id1 = distributor.createCampaign(t);
        t.referrerBps = r2;
        t.cashbackBps = c2;
        uint256 id2 = _createAs(creatorB, t);
        vm.startPrank(trader);
        referrals.register(distributor.campaign(id1).programKey, referrer, bytes32(0));
        referrals.register(distributor.campaign(id2).programKey, referrer, bytes32(0));
        vm.stopPrank();
        vm.roll(vm.getBlockNumber() + 1);
        uint64 first = uint64(vm.getBlockNumber());
        vm.warp(t.end);
        distributor.proposeDay(id1, 0, _leaf(id1, 0, trader, referrer, first, f1), f1, COVERAGE, COLLECTIONS);
        distributor.proposeDay(id2, 0, _leaf(id2, 0, trader, referrer, first, f2), f2, COVERAGE, COLLECTIONS);
        _finalizeAfterDelay(id1, 0);
        distributor.finalizeDay(id2, 0);
        distributor.creditDay(id1, 0, trader, referrer, first, f1, _noProof());
        uint256 p1 = distributor.epoch(id1, 0).allocated;
        assertEq(p1, uint256(f1) * r1 / 10_000 + uint256(f1) * c1 / 10_000);
        distributor.creditDay(id2, 0, trader, referrer, first, f2, _noProof());
        uint256 p2 = distributor.epoch(id2, 0).allocated;
        uint256 larger = f1 > f2 ? f1 : f2;
        uint256 limit = larger * 9999 / 10_000;
        assertLe(p1 + p2, limit);
        uint256 nominal2 = uint256(f2) * r2 / 10_000 + uint256(f2) * c2 / 10_000;
        uint256 room = limit - p1;
        if (nominal2 <= room) assertEq(p2, nominal2);
        else assertGe(p2 + 1, room); // cut pro rata; the two floors lose at most one unit
    }
}
