// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {IHookrGoverned} from "../../src/interfaces/IHookrGoverned.sol";
import {HookrPaymaster} from "../../src/gasless/HookrPaymaster.sol";
import {IHookrCompliance} from "../../src/interfaces/IHookrCompliance.sol";
import {ComplianceTestBase} from "../compliance/ComplianceTestBase.sol";
import {MockEntryPoint} from "../gasless/GaslessMocks.sol";

/// @notice F-020: every guardian brake in a HookrGoverned contract had a timelocked inverse that could be queued at any
///         time, so an owner could pre-arm the restore and lift a later brake in the same block.
/// @dev PoC (final-core GovernanceLens P1/C1): UNPAUSE queued while live lifted a guardian pause in the same block;
///      RESUME_LIST queued while live lifted a suspension. A brake now advances the epoch of its restoring kind, so
///      operations queued before it are void; RESUME_LIST is only queueable while the list is suspended.
contract HookrComplianceRestoreTest is ComplianceTestBase {
    function test_resumeListNotQueueableWhileLive() public {
        bytes32 kind = compliance.RESUME_LIST();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IHookrCompliance.ListNotSuspended.selector, LIST));
        compliance.queue(kind, abi.encode(LIST));
    }

    /// A matured resume queued during one suspension cannot lift a later suspension.
    function test_matureResumeVoidedByNewSuspension() public {
        vm.prank(guardian);
        compliance.suspendList(LIST);
        _timelocked(compliance.RESUME_LIST(), abi.encode(LIST));
        vm.prank(guardian);
        compliance.suspendList(LIST);
        vm.prank(owner);
        vm.expectRevert();
        compliance.resumeList(LIST);
        assertTrue(compliance.list(LIST).suspended);
        // A resume queued after the brake waits its own full delay.
        uint256 brakedAt = vm.getBlockTimestamp();
        _timelocked(compliance.RESUME_LIST(), abi.encode(LIST));
        vm.prank(owner);
        compliance.resumeList(LIST);
        assertFalse(compliance.list(LIST).suspended);
        assertGe(vm.getBlockTimestamp(), brakedAt + DELAY);
    }

    /// GRANT_ATTESTER pre-armed while the attester is active re-grants it in the block of a guardian revocation on
    /// the old code; now the revocation voids it.
    function test_preArmedRegrantVoidedByRevocation() public {
        _timelocked(compliance.GRANT_ATTESTER(), abi.encode(LIST, attester));
        vm.prank(guardian);
        compliance.revokeAttester(LIST, attester);
        vm.prank(owner);
        vm.expectRevert();
        compliance.grantAttester(LIST, attester);
        assertEq(compliance.attesterSince(LIST, attester), 0);
    }

    function test_preArmedOfficerAndGuardianGrantsVoided() public {
        address other = makeAddr("otherGuardian");
        _timelocked(compliance.GRANT_OFFICER(), abi.encode(officer));
        vm.prank(guardian);
        compliance.revokeOfficer(officer);
        vm.prank(owner);
        vm.expectRevert();
        compliance.grantOfficer(officer);

        // Epochs are keyed by subject (AG-05): the revocation voids the re-grant of the same guardian only.
        _timelocked(compliance.GRANT_GUARDIAN(), abi.encode(guardian));
        _timelocked(compliance.GRANT_GUARDIAN(), abi.encode(other));
        vm.prank(owner);
        compliance.revokeGuardian(guardian);
        vm.prank(owner);
        vm.expectRevert();
        compliance.grantGuardian(guardian);
        assertFalse(compliance.isGuardian(guardian));
        vm.prank(owner);
        compliance.grantGuardian(other);
        assertTrue(compliance.isGuardian(other));
    }
}

/// @notice F-020 on the paymaster: the PoC's pre-armed UNPAUSE, SET_POLICY and GRANT_KEEPER.
contract HookrPaymasterRestoreTest is Test {
    MockEntryPoint internal ep;
    HookrPaymaster internal pm;
    address internal constant OWNER = address(0x0A);
    address internal constant GUARDIAN = address(0x6A);
    address internal constant KEEPER = address(0x6B);

    function setUp() public {
        vm.warp(1_000_000);
        ep = new MockEntryPoint();
        pm = new HookrPaymaster(address(ep), address(0), OWNER, 1 days, address(0x7E));
        _timelocked(keccak256("GRANT_GUARDIAN"), abi.encode(GUARDIAN));
        vm.prank(OWNER);
        pm.grantGuardian(GUARDIAN);
    }

    function _timelocked(bytes32 kind, bytes memory args) internal {
        vm.prank(OWNER);
        pm.queue(kind, args);
        vm.warp(vm.getBlockTimestamp() + 1 days);
    }

    function test_preArmedUnpauseCannotLiftGuardianPause() public {
        bytes32 armed = pm.operationHash(keccak256("UNPAUSE"), "");
        _timelocked(keccak256("UNPAUSE"), "");
        vm.warp(vm.getBlockTimestamp() + 13 days); // still inside GRACE
        vm.prank(GUARDIAN);
        pm.pause();
        bytes32 current = pm.operationHash(keccak256("UNPAUSE"), "");
        assertTrue(current != armed);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NotReady.selector, current, 0));
        pm.unpause();
        assertTrue(pm.paused());
        assertEq(pm.epoch(keccak256("UNPAUSE")), 1);
        // The void operation can still be cancelled by its old id.
        vm.prank(OWNER);
        pm.cancel(armed);
    }

    function test_preArmedKeeperGrantVoidedByRevocation() public {
        _timelocked(keccak256("GRANT_KEEPER"), abi.encode(KEEPER));
        vm.prank(GUARDIAN);
        pm.revokeKeeper(KEEPER);
        vm.prank(OWNER);
        vm.expectRevert();
        pm.grantKeeper(KEEPER);
    }
}
