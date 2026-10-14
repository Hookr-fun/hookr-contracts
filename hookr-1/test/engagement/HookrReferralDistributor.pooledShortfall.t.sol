// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHookrReferralDistributor} from "../../src/interfaces/IHookrReferralDistributor.sol";
import {ReferralSecurityFixture} from "../utils/ReferralSecurityFixture.sol";

/// @notice L-19 (distributor side): reservedCash is pooled per currency, and any balance shortfall made every
///         claim, release and new funding in that currency revert BudgetExceeded until someone donated the
///         whole shortfall. Unfixed (ReferralRepro.t.sol at 877cfb9): a 1-wei issuer wipe on 2000 of pooled
///         liabilities froze both campaigns' claims and releases and every new campaign in the currency.
///         Now each owner's own claim or release settles at the prevailing balance/liabilities ratio, so the
///         loss is shared pro rata instead of freezing everyone; nobody else can force that haircut and nobody
///         can extinguish a claim for nothing.
contract HookrReferralDistributorPooledShortfallTest is ReferralSecurityFixture {
    address private creator2 = address(0x4444);
    address private payer2 = address(0x5555);
    address private referrer2 = address(0x6666);

    function _twoCreditedCampaigns()
        private
        returns (address cur, uint256 id1, uint256 id2, IHookrReferralDistributor.Terms memory t)
    {
        t = _terms();
        cur = t.currency;
        id1 = distributor.createCampaign(t);
        id2 = _createAs(creator2, t);
        uint64 first1 = _enroll(id1, trader, referrer);
        uint64 first2 = _enroll(id2, payer2, referrer2);
        vm.warp(t.end);
        distributor.proposeDay(id1, 0, _leaf(id1, 0, trader, referrer, first1, 1000), 1000, COVERAGE, COLLECTIONS);
        distributor.proposeDay(id2, 0, _leaf(id2, 0, payer2, referrer2, first2, 2000), 2000, COVERAGE, COLLECTIONS);
        _finalizeAfterDelay(id1, 0);
        distributor.finalizeDay(id2, 0);
        distributor.creditDay(id1, 0, trader, referrer, first1, 1000, _noProof());
        distributor.creditDay(id2, 0, payer2, referrer2, first2, 2000, _noProof());
    }

    function testShortfallSettlesProRataInsteadOfFreezingEveryCampaign() public {
        (address cur, uint256 id1, uint256 id2,) = _twoCreditedCampaigns();
        // Liabilities: campaign 1 = 200 + 100 credited + 700 remainder; campaign 2 = 400 + 200 + 400 remainder.
        assertEq(distributor.reservedCash(cur), 2000);
        deal(cur, address(distributor), 1000); // issuer wipes half the pooled balance
        // A third party can no longer force anyone to accept the haircut (and cannot trigger it at all).
        vm.expectRevert(abi.encodeWithSelector(IHookrReferralDistributor.CashShortfall.selector, cur, 2000, 1000));
        distributor.claim(cur, referrer, referrer, 0);
        vm.expectRevert(abi.encodeWithSelector(IHookrReferralDistributor.CashShortfall.selector, cur, 2000, 1000));
        distributor.releaseRemainder(id2, 0, creator2);
        // Each owner can still exit, at the same 50% ratio whatever the order.
        vm.prank(referrer2);
        distributor.claim(cur, referrer2, referrer2, 0);
        assertEq(IERC20(cur).balanceOf(referrer2), 200);
        vm.prank(creator2);
        assertEq(distributor.releaseRemainder(id2, 0, creator2), 400);
        vm.prank(referrer);
        distributor.claim(cur, referrer, referrer, 0);
        assertEq(IERC20(cur).balanceOf(referrer), 100);
        distributor.releaseRemainder(id1, 0, address(this));
        vm.prank(payer2);
        distributor.claim(cur, payer2, payer2, 0);
        assertEq(IERC20(cur).balanceOf(payer2), 100);
        vm.prank(trader);
        distributor.claim(cur, trader, trader, 0);
        assertEq(distributor.reservedCash(cur), 0);
        assertEq(IERC20(cur).balanceOf(address(distributor)), 0);
    }

    function testDonationStillHealsAndNewFundingNeverAbsorbsOldLoss() public {
        (address cur,,, IHookrReferralDistributor.Terms memory t) = _twoCreditedCampaigns();
        uint256 bal = IERC20(cur).balanceOf(address(distributor));
        deal(cur, address(distributor), bal - 1);
        IHookrReferralDistributor.Terms memory t3 = _terms();
        vm.expectRevert(IHookrReferralDistributor.BudgetExceeded.selector);
        distributor.createCampaign(t3); // new cash must not top up the old shortfall
        IERC20(cur).transfer(address(distributor), 1);
        distributor.claim(cur, referrer, referrer, 0); // third-party trigger works again when solvent
        assertEq(IERC20(cur).balanceOf(referrer), 200);
        distributor.createCampaign(t3);
        assertEq(distributor.reservedCash(cur), 2000 - 200 + uint256(t.dailyBudget));
    }

    function testNobodyCanBurnAClaimForNothing() public {
        (address cur,,,) = _twoCreditedCampaigns();
        deal(cur, address(distributor), 0);
        vm.prank(referrer);
        vm.expectRevert(abi.encodeWithSelector(IHookrReferralDistributor.CashShortfall.selector, cur, 2000, 0));
        distributor.claim(cur, referrer, referrer, 0);
        assertEq(distributor.claimable(cur, referrer), 200);
    }

    function testFuzz_proRataIsOrderIndependent(uint16 wipeBps, bool refererFirst) public {
        (address cur,,,) = _twoCreditedCampaigns();
        wipeBps = uint16(bound(wipeBps, 1, 9000)); // a total wipe pays nothing and reverts (tested below)
        uint256 bal = IERC20(cur).balanceOf(address(distributor));
        uint256 left = bal - bal * wipeBps / 10_000;
        deal(cur, address(distributor), left);
        address a = refererFirst ? referrer : referrer2;
        address b = refererFirst ? referrer2 : referrer;
        uint256 owedA = distributor.claimable(cur, a);
        uint256 owedB = distributor.claimable(cur, b);
        vm.prank(a);
        distributor.claim(cur, a, a, 0);
        vm.prank(b);
        distributor.claim(cur, b, b, 0);
        // Each receives its owed share of the surviving balance (floor), within one unit of rounding.
        assertApproxEqAbs(IERC20(cur).balanceOf(a), owedA * left / bal, 1);
        assertApproxEqAbs(IERC20(cur).balanceOf(b), owedB * left / bal, 1);
        assertLe(IERC20(cur).balanceOf(a) + IERC20(cur).balanceOf(b), left);
    }
}
