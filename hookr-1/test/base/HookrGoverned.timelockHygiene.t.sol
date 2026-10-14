// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IHookrGoverned} from "../../src/interfaces/IHookrGoverned.sol";
import {ComplianceTestBase} from "../compliance/ComplianceTestBase.sol";

/// @notice F-049: HookrGoverned's timelock hygiene differed from the Registry's: cancelling an unknown id succeeded
///         silently, an expired operation blocked its own re-queue for good, and nothing disclosed expiresAt. Any kind
///         and any argument encoding could also be queued.
contract HookrGovernedTimelockHygieneTest is ComplianceTestBase {
    event OperationQueued(
        bytes32 indexed operation, bytes32 indexed kind, bytes arguments, uint48 readyAt, uint48 expiresAt
    );

    function test_cancelUnknownReverts() public {
        bytes32 unknown = keccak256("never queued");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NotQueued.selector, unknown));
        compliance.cancel(unknown);
    }

    function test_expiredOperationCanBeQueuedAgain() public {
        bytes32 kind = compliance.GRANT_OFFICER();
        address next = makeAddr("nextOfficer");
        vm.prank(owner);
        bytes32 op = compliance.queue(kind, abi.encode(next));
        uint48 ready = compliance.readyAt(op);
        assertEq(compliance.expiresAt(op), ready + compliance.GRACE());
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.AlreadyQueued.selector, op));
        compliance.queue(kind, abi.encode(next));
        uint48 grace = compliance.GRACE();
        vm.warp(uint256(ready) + grace + 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Expired.selector, op, ready + grace));
        compliance.grantOfficer(next);
        uint48 again = uint48(vm.getBlockTimestamp()) + DELAY;
        vm.expectEmit(true, true, false, true, address(compliance));
        emit OperationQueued(op, kind, abi.encode(next), again, again + grace);
        vm.prank(owner);
        compliance.queue(kind, abi.encode(next));
        vm.warp(again);
        vm.prank(owner);
        compliance.grantOfficer(next);
        assertTrue(compliance.isOfficer(next));
        assertEq(compliance.expiresAt(op), 0);
    }

    function test_unknownKindAndNonCanonicalArgumentsRefused() public {
        bytes32 bogus = keccak256("SELF_DESTRUCT");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.UnknownOperation.selector, bogus));
        compliance.queue(bogus, "");
        bytes32 kind = compliance.GRANT_OFFICER();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NonCanonicalArguments.selector, kind));
        compliance.queue(kind, abi.encodePacked(abi.encode(officer), uint256(1)));
    }
}
