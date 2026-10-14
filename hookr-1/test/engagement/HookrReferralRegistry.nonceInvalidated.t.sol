// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {IHookrReferralRegistry} from "../../src/interfaces/IHookrReferralRegistry.sol";
import {ReferralSecurityFixture} from "../utils/ReferralSecurityFixture.sol";

/// @notice N-02: invalidateNonce emitted no event, so indexers and relayers could not see cancellations.
///         Unfixed (ReferralRepro.t.sol at 877cfb9): 0 logs. Now NonceInvalidated(payer, nextNonce), and a
///         non-increasing request reverts with both values.
contract HookrReferralRegistryNonceInvalidatedTest is ReferralSecurityFixture {
    function testInvalidateNonceEmits() public {
        vm.recordLogs();
        vm.prank(trader);
        referrals.invalidateNonce(10);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], IHookrReferralRegistry.NonceInvalidated.selector);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(trader))));
        assertEq(abi.decode(logs[0].data, (uint256)), 10);
        assertEq(referrals.nonces(trader), 10);
    }

    function testNonIncreasingRequestRevertsWithValues() public {
        vm.prank(trader);
        referrals.invalidateNonce(10);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IHookrReferralRegistry.NonceNotRaised.selector, 10, 10));
        referrals.invalidateNonce(10);
    }
}
