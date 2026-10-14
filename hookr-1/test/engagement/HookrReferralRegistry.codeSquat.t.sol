// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IHookrReferralRegistry} from "../../src/interfaces/IHookrReferralRegistry.sol";
import {IHookrReferralDistributor} from "../../src/interfaces/IHookrReferralDistributor.sol";
import {ReferralSecurityFixture} from "../utils/ReferralSecurityFixture.sol";

/// @notice I-17 (documented, no contract change): referral codes are first-come global labels, so a squatter
///         can take a well-known alias. Unfixed PoC: the real referrer's registerCode and a binding naming the
///         squatted code both reverted InvalidReferral. Owner-scoped codes would change the app's code->owner
///         lookup, so the label semantics are kept and documented; this test pins that a code has no economic
///         effect: a squatted code can neither capture a binding meant for the real referrer nor earn cash.
contract HookrReferralRegistryCodeSquatTest is ReferralSecurityFixture {
    function testSquattedCodeCannotRedirectBindingOrPayout() public {
        IHookrReferralDistributor.Terms memory t = _terms();
        uint256 id = distributor.createCampaign(t);
        bytes32 pk = distributor.campaign(id).programKey;
        bytes32 code = keccak256(bytes("influencer"));
        address squatter = address(0x5A7);
        vm.prank(squatter);
        referrals.registerCode(code);
        vm.prank(referrer);
        vm.expectRevert(IHookrReferralRegistry.InvalidReferral.selector);
        referrals.registerCode(code);
        // A binding naming the real referrer with the squatted code fails closed; it never binds the squatter.
        vm.prank(trader);
        vm.expectRevert(IHookrReferralRegistry.InvalidReferral.selector);
        referrals.register(pk, referrer, code);
        (address bound,,) = referrals.binding(pk, trader);
        assertEq(bound, address(0));
        // The address-based binding works and pays the real referrer; the code owner gets nothing.
        vm.prank(trader);
        referrals.register(pk, referrer, bytes32(0));
        vm.roll(vm.getBlockNumber() + 1);
        uint64 first = uint64(vm.getBlockNumber());
        vm.warp(t.end);
        distributor.proposeDay(id, 0, _leaf(id, 0, trader, referrer, first, 1000), 1000, COVERAGE, COLLECTIONS);
        _finalizeAfterDelay(id, 0);
        vm.expectRevert(IHookrReferralDistributor.InvalidProof.selector);
        distributor.creditDay(id, 0, trader, squatter, first, 1000, _noProof());
        distributor.creditDay(id, 0, trader, referrer, first, 1000, _noProof());
        assertEq(distributor.claimable(t.currency, referrer), 200);
        assertEq(distributor.claimable(t.currency, squatter), 0);
    }
}
