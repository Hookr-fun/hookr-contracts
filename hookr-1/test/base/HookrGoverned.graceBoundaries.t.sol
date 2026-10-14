// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IHookrGoverned} from "../../src/interfaces/IHookrGoverned.sol";
import {ComplianceTestBase} from "../compliance/ComplianceTestBase.sol";

/// @notice The two edges of a queued operation's grace: it can still be executed at the last second of the window
///         (ready + GRACE) and it cannot be queued again until the second after, when it has expired. Mutation gate GV-1
///         (an operation could be queued again in the last second) and GV-4 (it expired in the last second).
contract HookrGovernedGraceBoundariesTest is ComplianceTestBase {
    function _queue() internal returns (bytes32 kind, address next, bytes32 op, uint256 lastSecond) {
        kind = compliance.GRANT_OFFICER();
        next = makeAddr("nextOfficer");
        vm.prank(owner);
        op = compliance.queue(kind, abi.encode(next));
        lastSecond = uint256(compliance.readyAt(op)) + compliance.GRACE();
    }

    function test_executesAtTheLastSecondOfItsGrace() public {
        (, address next,, uint256 lastSecond) = _queue();
        vm.warp(lastSecond);
        vm.prank(owner);
        compliance.grantOfficer(next);
        assertTrue(compliance.isOfficer(next));
    }

    function test_cannotBeQueuedAgainAtTheLastSecondOfItsGrace() public {
        (bytes32 kind, address next, bytes32 op, uint256 lastSecond) = _queue();
        vm.warp(lastSecond);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.AlreadyQueued.selector, op));
        compliance.queue(kind, abi.encode(next));
        vm.warp(lastSecond + 1);
        vm.prank(owner);
        compliance.queue(kind, abi.encode(next));
    }
}
