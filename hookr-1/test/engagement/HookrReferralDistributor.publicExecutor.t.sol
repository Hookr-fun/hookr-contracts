// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHookrReferralDistributor} from "../../src/interfaces/IHookrReferralDistributor.sol";
import {ReferralSecurityFixture} from "../utils/ReferralSecurityFixture.sol";

contract PublicExecutor {
    function execute(address target, bytes calldata data) external payable returns (bytes memory r) {
        bool ok;
        (ok, r) = target.call{value: msg.value}(data);
        require(ok, "exec");
    }
}

/// @notice I-16 (documented, no contract change): a contract that performs arbitrary calls for anyone has no
///         owner, so anyone can bind it and redirect its cashback. Unfixed PoC: the attacker bound a public
///         executor to itself and took 300 of 300 credited. Blocking contract payers from `register` would also
///         block Safes and EIP-7702 accounts on 4663, so the limit is documented instead (registry NatSpec,
///         the release's referral docs): services attribute only EOAs and reviewed smart-account code. This test pins the
///         bound: the take never exceeds the executor's own attested rebate, and no other payer is touched.
contract HookrReferralDistributorPublicExecutorTest is ReferralSecurityFixture {
    function testTakeIsBoundedToTheExecutorsOwnRebate() public {
        IHookrReferralDistributor.Terms memory t = _terms();
        uint256 id = distributor.createCampaign(t);
        bytes32 pk = distributor.campaign(id).programKey;
        PublicExecutor exec = new PublicExecutor();
        address attacker = address(0xBAD);
        vm.prank(attacker);
        exec.execute(address(referrals), abi.encodeCall(referrals.register, (pk, attacker, bytes32(0))));
        uint64 honestFirst = _enroll(id, trader, referrer);
        uint64 first = honestFirst;
        vm.warp(t.end);
        bytes32 le = _leaf(id, 0, address(exec), attacker, first, 1000);
        bytes32 lt = _leaf(id, 0, trader, referrer, honestFirst, 1000);
        distributor.proposeDay(id, 0, _pair(le, lt), 2000, COVERAGE, COLLECTIONS);
        _finalizeAfterDelay(id, 0);
        bytes32[] memory p = new bytes32[](1);
        p[0] = lt;
        distributor.creditDay(id, 0, address(exec), attacker, first, 1000, p);
        p[0] = le;
        distributor.creditDay(id, 0, trader, referrer, honestFirst, 1000, p);
        vm.prank(attacker);
        exec.execute(address(distributor), abi.encodeCall(distributor.claim, (t.currency, address(exec), attacker, 0)));
        vm.prank(attacker);
        distributor.claim(t.currency, attacker, attacker, 0);
        assertEq(IERC20(t.currency).balanceOf(attacker), 300); // 30% of the executor's own 1000 fees, as before
        assertEq(distributor.claimable(t.currency, referrer), 200); // the honest payer's referral is untouched
        assertEq(distributor.claimable(t.currency, trader), 100);
    }
}
