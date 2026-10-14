// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {GovernanceSecurityBase} from "../utils/GovernanceSecurityBase.sol";

/// @notice L-17: the owner could not withdraw a registry owner nomination before the timelock expired, and no event
///         named the nominee.
/// @dev Original exploit (base b7aeae64, ReproGovernance.testL17_NominationEmitsNoNomineeAndCannotBeRevokedQuickly):
///      transferOwnership emitted exactly 1 log (OperationExecuted), a revoking TRANSFER_OWNER(self) was NotReady
///      for the full delay, and the nominee 0xB0B accepted at delay - 1 s and became the registry owner.
contract HookrRegistryOwnerNominationTest is GovernanceSecurityBase {
    address internal nominee = address(0xB0B);

    function setUp() public {
        _setUpPeriphery();
    }

    function _nominate() internal {
        registry.queue(registry.TRANSFER_OWNER(), abi.encode(nominee));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
    }

    function testNominationNamesTheNominee() public {
        _nominate();
        vm.recordLogs();
        registry.transferOwnership(nominee);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // Old: 1 log, OperationExecuted only.
        assertEq(logs.length, 2);
        assertEq(logs[0].topics[0], keccak256("OperationExecuted(bytes32)"));
        assertEq(logs[1].topics[0], keccak256("OwnershipTransferStarted(address,address)"));
        assertEq(address(uint160(uint256(logs[1].topics[1]))), address(this));
        assertEq(address(uint160(uint256(logs[1].topics[2]))), nominee);
        assertEq(registry.pendingOwner(), nominee);
    }

    function testOwnerWithdrawsNominationAtOnce() public {
        _nominate();
        registry.transferOwnership(nominee);
        vm.expectEmit(true, true, false, false, address(registry));
        emit IHookrRegistry.OwnershipTransferCancelled(address(this), nominee);
        registry.cancelOwnershipTransfer();
        assertEq(registry.pendingOwner(), address(0));
        // Old: the nominee accepted at delay - 1 s and took the registry.
        vm.prank(nominee);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.acceptOwnership();
        assertEq(registry.owner(), address(this));
    }

    function testOnlyOwnerCancelsAndOnlyWhenPending() public {
        vm.expectRevert(IHookrRegistry.InvalidAddress.selector);
        registry.cancelOwnershipTransfer();
        _nominate();
        registry.transferOwnership(nominee);
        vm.prank(nominee);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.cancelOwnershipTransfer();
        vm.prank(nominee);
        registry.acceptOwnership();
        assertEq(registry.owner(), nominee);
        assertEq(registry.pendingOwner(), address(0));
    }
}
