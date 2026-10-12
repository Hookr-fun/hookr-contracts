// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHookrReferralDistributor} from "../../src/interfaces/IHookrReferralDistributor.sol";
import {ReferralSecurityFixture} from "../utils/ReferralSecurityFixture.sol";

/// @notice L-24: referral cash for one currency sits in one pool. Unfixed (ReferralRepro.t.sol at 877cfb9):
///         a 1-wei wipe of 2000 pooled made both campaigns' claims and releases and every new campaign revert
///         BudgetExceeded; releaseRemainder could only pay the creator, so a creator blocked by the issuer could
///         not redirect it (the transfer reverted "BLACKLISTED").
///         Now owners settle pro rata instead of freezing (see L-19), and the creator may redirect its remainder
///         exactly as a beneficiary may redirect its claim. A beneficiary's redirect is kept by design: the
///         contract has no sanctions policy (documented).
contract HookrReferralDistributorSharedCurrencyPoolTest is ReferralSecurityFixture {
    address private creator2 = address(0x4444);
    address private clean = address(0xC1EA);

    function testOneWeiWipeNoLongerHaltsEveryCampaign() public {
        IHookrReferralDistributor.Terms memory t = _terms();
        address cur = t.currency;
        uint256 id1 = distributor.createCampaign(t);
        uint256 id2 = _createAs(creator2, t);
        uint64 first = _enroll(id1, trader, referrer);
        vm.warp(t.end);
        distributor.proposeDay(id1, 0, _leaf(id1, 0, trader, referrer, first, 1000), 1000, COVERAGE, COLLECTIONS);
        distributor.proposeDay(id2, 0, bytes32(0), 0, COVERAGE, COLLECTIONS);
        _finalizeAfterDelay(id1, 0);
        distributor.finalizeDay(id2, 0);
        distributor.creditDay(id1, 0, trader, referrer, first, 1000, _noProof());
        deal(cur, address(distributor), IERC20(cur).balanceOf(address(distributor)) - 1);
        // Unrelated creator 2 exits with its whole day, minus its pro-rata share of 1 wei (floored).
        vm.prank(creator2);
        assertEq(distributor.releaseRemainder(id2, 0, creator2), 1000);
        assertEq(IERC20(cur).balanceOf(creator2), 999);
        // The floored 0.5 wei stayed in the pool, so the pool is whole again and the referrer is paid in full.
        vm.prank(referrer);
        distributor.claim(cur, referrer, referrer, 0);
        assertEq(IERC20(cur).balanceOf(referrer), 200);
        distributor.releaseRemainder(id1, 0, address(this));
        vm.prank(trader);
        distributor.claim(cur, trader, trader, 0);
        assertEq(distributor.reservedCash(cur), 0);
    }

    function testCreatorCanRedirectARemainderTheIssuerBlocks() public {
        IHookrReferralDistributor.Terms memory t = _terms();
        uint256 id = _createAs(creator2, t);
        vm.warp(t.end);
        distributor.proposeDay(id, 0, bytes32(0), 0, COVERAGE, COLLECTIONS);
        _finalizeAfterDelay(id, 0);
        vm.mockCallRevert(t.currency, abi.encodeWithSelector(IERC20.transfer.selector, creator2, 1000), "BLACKLISTED");
        vm.expectRevert(bytes("BLACKLISTED"));
        distributor.releaseRemainder(id, 0, creator2);
        // Only the creator may choose another recipient.
        vm.expectRevert(abi.encodeWithSelector(IHookrReferralDistributor.NotCreator.selector, address(this)));
        distributor.releaseRemainder(id, 0, clean);
        vm.prank(creator2);
        vm.expectRevert(IHookrReferralDistributor.Unauthorized.selector);
        distributor.releaseRemainder(id, 0, address(distributor));
        vm.prank(creator2);
        vm.expectRevert(IHookrReferralDistributor.Unauthorized.selector);
        distributor.releaseRemainder(id, 0, address(0));
        vm.prank(creator2);
        assertEq(distributor.releaseRemainder(id, 0, clean), 1000);
        assertEq(IERC20(t.currency).balanceOf(clean), 1000);
        vm.clearMockedCalls();
    }

    function testBeneficiaryRedirectIsTheBeneficiarysRight() public {
        IHookrReferralDistributor.Terms memory t = _terms();
        uint256 id = distributor.createCampaign(t);
        uint64 first = _enroll(id, trader, referrer);
        vm.warp(t.end);
        distributor.proposeDay(id, 0, _leaf(id, 0, trader, referrer, first, 1000), 1000, COVERAGE, COLLECTIONS);
        _finalizeAfterDelay(id, 0);
        distributor.creditDay(id, 0, trader, referrer, first, 1000, _noProof());
        vm.expectRevert(IHookrReferralDistributor.Unauthorized.selector);
        distributor.claim(t.currency, referrer, clean, 0); // nobody else may redirect
        vm.prank(referrer);
        distributor.claim(t.currency, referrer, clean, 0);
        assertEq(IERC20(t.currency).balanceOf(clean), 200);
    }
}
