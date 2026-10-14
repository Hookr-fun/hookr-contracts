// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {HookrReferralDistributor} from "../../src/engagement/HookrReferralDistributor.sol";
import {IHookrReferralDistributor} from "../../src/interfaces/IHookrReferralDistributor.sol";
import {ReferralSecurityFixture} from "../utils/ReferralSecurityFixture.sol";

contract FakeRoot {
    address public rulesAddr;
    address public quote;
    bytes32 public ph;

    constructor(address q, bytes32 h) {
        quote = q;
        ph = h;
    }

    function setRules(address r) external {
        rulesAddr = r;
    }

    function knownPool(PoolId) external pure returns (bool) {
        return true;
    }

    function policyHash(PoolId) external view returns (bytes32) {
        return ph;
    }

    function poolConfig(PoolId) external view returns (HookrTypes.PoolConfig memory c) {
        c.rules = rulesAddr;
        c.quote = Currency.wrap(quote);
    }
}

contract FakeRules {
    address public trustedRoot;

    constructor(address r) {
        trustedRoot = r;
    }
}

/// @notice I-15: the canonical distributor accepted a campaign on a real PoolId behind a caller-supplied
///         imitation root and rules. Unfixed (ReferralRepro.t.sol at 877cfb9): createCampaign succeeded and
///         the campaign carried the real PoolId. Now the root must be registered in the Hookr registry.
contract HookrReferralDistributorFakeRootTest is ReferralSecurityFixture {
    function testImitationRootIsRejected() public {
        IHookrReferralDistributor.Terms memory t = _terms();
        FakeRoot fr = new FakeRoot(t.currency, keccak256("anything"));
        FakeRules fl = new FakeRules(address(fr));
        fr.setRules(address(fl));
        t.root = address(fr);
        t.rules = address(fl);
        t.configHash = keccak256("anything");
        vm.expectRevert(abi.encodeWithSelector(IHookrReferralDistributor.UnregisteredRoot.selector, address(fr)));
        distributor.createCampaign(t);
        assertEq(distributor.campaignCount(), 0);
    }

    function testRegisteredRootStillAccepted() public {
        uint256 id = distributor.createCampaign(_terms());
        assertEq(distributor.campaign(id).terms.root, address(root));
        assertEq(address(distributor.registry()), address(registry));
    }

    function testConstructorRequiresBothRegistries() public {
        vm.expectRevert(IHookrReferralDistributor.InvalidCampaign.selector);
        new HookrReferralDistributor(address(referrals), address(0xdead), address(this));
        vm.expectRevert(IHookrReferralDistributor.InvalidCampaign.selector);
        new HookrReferralDistributor(address(0xdead), address(registry), address(this));
    }
}
