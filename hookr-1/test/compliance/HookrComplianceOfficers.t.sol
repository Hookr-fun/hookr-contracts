// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IHookrGoverned} from "../../src/interfaces/IHookrGoverned.sol";
import {IHookrCompliance} from "../../src/interfaces/IHookrCompliance.sol";
import {ComplianceTestBase} from "./ComplianceTestBase.sol";

/// @notice HookrCompliance.renounceOfficer: an officer gives up its own role at once and alone; everyone else is
///         refused. The sanctions it set stay set, other officers and the caller's other roles are untouched, and
///         regaining the role takes the owner's timelocked grant. It is a self-removal, not a brake, so unlike
///         revokeOfficer it voids no queued grant.
contract HookrComplianceOfficersTest is ComplianceTestBase {
    address internal listed = makeAddr("listed");

    function test_renounceOfficer_dropsTheRoleAtOnce() public {
        assertTrue(compliance.isOfficer(officer));
        vm.expectEmit(address(compliance));
        emit IHookrCompliance.OfficerSet(officer, false);
        vm.prank(officer);
        compliance.renounceOfficer();
        assertFalse(compliance.isOfficer(officer));
        address[] memory wallets = new address[](1);
        wallets[0] = listed;
        vm.prank(officer);
        vm.expectRevert(abi.encodeWithSelector(IHookrCompliance.NotOfficer.selector, officer));
        compliance.setSanctioned(wallets, true);
    }

    /// Only an officer can renounce the role: strangers, the owner, the guardian and an attester are refused, and so is
    /// a second renounce.
    function test_renounceOfficer_refusesEveryoneButAnOfficer() public {
        address[4] memory callers = [makeAddr("stranger"), owner, guardian, attester];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(IHookrCompliance.NotOfficer.selector, callers[i]));
            compliance.renounceOfficer();
        }
        assertTrue(compliance.isOfficer(officer));
        vm.prank(officer);
        compliance.renounceOfficer();
        vm.prank(officer);
        vm.expectRevert(abi.encodeWithSelector(IHookrCompliance.NotOfficer.selector, officer));
        compliance.renounceOfficer();
    }

    /// The sanctions the officer set stay set; another officer can still clear them.
    function test_renounceOfficer_keepsTheSanctionsItSet() public {
        _sanction(listed, true);
        address second = _grantSecondOfficer();
        vm.prank(officer);
        compliance.renounceOfficer();
        assertTrue(compliance.isSanctionedLocal(listed));
        assertEq(uint256(compliance.check(bytes32(0), listed, 0, 0)), uint256(IHookrCompliance.Decision.SANCTIONED));
        address[] memory wallets = new address[](1);
        wallets[0] = listed;
        vm.prank(second);
        compliance.setSanctioned(wallets, false);
        assertFalse(compliance.isSanctionedLocal(listed));
    }

    /// One officer's renounce leaves the other officers and the caller's other roles as they were.
    function test_renounceOfficer_touchesOnlyTheCallersOfficerRole() public {
        address second = _grantSecondOfficer();
        // The guardian also becomes an officer, then gives up only that role.
        _timelocked(compliance.GRANT_OFFICER(), abi.encode(guardian));
        vm.prank(owner);
        compliance.grantOfficer(guardian);
        vm.prank(guardian);
        compliance.renounceOfficer();
        assertFalse(compliance.isOfficer(guardian));
        assertTrue(compliance.isGuardian(guardian), "still a guardian");
        assertTrue(compliance.isOfficer(officer));
        assertTrue(compliance.isOfficer(second));
        vm.prank(guardian);
        compliance.suspendList(LIST);
        assertTrue(compliance.list(LIST).suspended);
    }

    /// Getting the role back takes the owner's grant after a full delay.
    function test_renounceOfficer_regainingTheRoleTakesATimelockedGrant() public {
        vm.prank(officer);
        compliance.renounceOfficer();
        bytes32 kind = compliance.GRANT_OFFICER();
        bytes32 op = compliance.operationHash(kind, abi.encode(officer));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NotReady.selector, op, uint48(0)));
        compliance.grantOfficer(officer);
        vm.prank(owner);
        compliance.queue(kind, abi.encode(officer));
        uint48 ready = uint48(vm.getBlockTimestamp()) + DELAY;
        vm.warp(ready - 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NotReady.selector, op, ready));
        compliance.grantOfficer(officer);
        vm.warp(ready);
        vm.prank(owner);
        compliance.grantOfficer(officer);
        assertTrue(compliance.isOfficer(officer));
    }

    /// The renounce advances no epoch, so a grant the owner queued before it still executes once ready; the guardian's
    /// revokeOfficer, a brake, voids such a grant instead.
    function test_renounceOfficer_voidsNoQueuedGrant_unlikeRevokeOfficer() public {
        bytes32 kind = compliance.GRANT_OFFICER();
        bytes32 subject = keccak256(abi.encode(kind, abi.encode(officer)));
        vm.prank(owner);
        bytes32 queued = compliance.queue(kind, abi.encode(officer));
        uint256 snap = vm.snapshotState();

        vm.prank(officer);
        compliance.renounceOfficer();
        assertEq(compliance.epoch(subject), 0);
        assertEq(compliance.operationHash(kind, abi.encode(officer)), queued);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        vm.prank(owner);
        compliance.grantOfficer(officer);
        assertTrue(compliance.isOfficer(officer));

        vm.revertToState(snap);
        vm.prank(guardian);
        compliance.revokeOfficer(officer);
        assertEq(compliance.epoch(subject), 1);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        bytes32 current = compliance.operationHash(kind, abi.encode(officer));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NotReady.selector, current, uint48(0)));
        compliance.grantOfficer(officer);
        assertFalse(compliance.isOfficer(officer));
    }

    function _grantSecondOfficer() internal returns (address second) {
        second = makeAddr("secondOfficer");
        _timelocked(compliance.GRANT_OFFICER(), abi.encode(second));
        vm.prank(owner);
        compliance.grantOfficer(second);
    }
}
