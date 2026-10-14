// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IHookrReferralDistributor} from "../../src/interfaces/IHookrReferralDistributor.sol";
import {ReferralSecurityFixture} from "../utils/ReferralSecurityFixture.sol";

/// @notice L-22: self-referral through a second wallet turns a cash campaign into a rebate of
///         referrerBps + cashbackBps. No onchain check separates a second wallet from a real referrer (a code
///         owned by the referrer does not: unfixed PoC, 1e15 fees -> 3e14 to the same owner at 2000/1000).
///         This remains a documented limit. What is now bounded onchain: the rebate stays strictly below the
///         fee per campaign (existing) AND across every campaign in the distributor (new, L-21), so self-referral
///         in several stacked campaigns can no longer reimburse more than 99.99% of a fee (was 19,998 bps).
contract HookrReferralDistributorSelfReferralTest is ReferralSecurityFixture {
    address private alt = address(0xA17);

    function _selfRefer(uint256 id) private {
        bytes32 pk = distributor.campaign(id).programKey;
        vm.prank(trader);
        referrals.register(pk, alt, keccak256("alt-code"));
    }

    function testSingleCampaignRebateIsTheDisclosedRate() public {
        IHookrReferralDistributor.Terms memory t = _terms();
        t.dailyBudget = 1e18;
        t.walletFeeCap = type(uint128).max;
        uint256 id = distributor.createCampaign(t);
        vm.prank(alt);
        referrals.registerCode(keccak256("alt-code"));
        _selfRefer(id);
        vm.roll(vm.getBlockNumber() + 1);
        uint64 first = uint64(vm.getBlockNumber());
        vm.warp(t.end);
        uint128 fees = 1e15;
        distributor.proposeDay(id, 0, _leaf(id, 0, trader, alt, first, fees), fees, COVERAGE, COLLECTIONS);
        _finalizeAfterDelay(id, 0);
        distributor.creditDay(id, 0, trader, alt, first, fees, _noProof());
        uint256 got = distributor.claimable(t.currency, trader) + distributor.claimable(t.currency, alt);
        // Documented residual: exactly referrerBps + cashbackBps of the attested fee, never more.
        assertEq(got, uint256(fees) * 3000 / 10_000);
    }

    function testSelfReferralAcrossStackedCampaignsStaysBelowTheFee() public {
        IHookrReferralDistributor.Terms memory t = _terms();
        t.dailyBudget = 1e18;
        t.walletFeeCap = type(uint128).max;
        t.referrerBps = 6000;
        t.cashbackBps = 3999;
        uint256[] memory ids = new uint256[](3);
        vm.prank(alt);
        referrals.registerCode(keccak256("alt-code"));
        // Three funders, each with its own reviewer; every campaign names the one pinned attestor, which here
        // (as if its single-reservation ledger were bypassed) attests the same fee for all three.
        for (uint256 i; i < ids.length; ++i) {
            t.reviewer = address(uint160(0xB000 + i));
            ids[i] = _createAs(address(uint160(0xC000 + i)), t);
            _selfRefer(ids[i]);
        }
        vm.roll(vm.getBlockNumber() + 1);
        uint64 first = uint64(vm.getBlockNumber());
        vm.warp(t.end);
        uint128 fees = 1e15;
        for (uint256 i; i < ids.length; ++i) {
            _proposeAs(distributor.attestor(), ids[i], 0, _leaf(ids[i], 0, trader, alt, first, fees), fees);
        }
        _finalizeAfterDelay(ids[0], 0);
        for (uint256 i; i < ids.length; ++i) {
            if (i != 0) distributor.finalizeDay(ids[i], 0);
            distributor.creditDay(ids[i], 0, trader, alt, first, fees, _noProof());
        }
        uint256 got = distributor.claimable(t.currency, trader) + distributor.claimable(t.currency, alt);
        emit log_named_uint("self-referral rebate bps over 3 campaigns (unfixed: 29997)", got * 10_000 / fees);
        assertLe(got * 10_000, uint256(fees) * distributor.MAX_STACKED_BPS());
    }
}
