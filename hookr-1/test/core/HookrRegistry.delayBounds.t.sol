// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {HookrRegistry} from "../../src/core/HookrRegistry.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {GovernanceSecurityBase} from "../utils/GovernanceSecurityBase.sol";

/// @notice I-12: the registry accepted any delay of at least one hour. type(uint48).max made every queue() panic
///         and a delay just below it produced an unreachable readyAt.
/// @dev Original exploit (base b7aeae64, ReproGovernance.testI12_HugeDelayBricksQueue): the uint48-max registry
///      deployed and queue() reverted with an arithmetic panic; a second registry queued with
///      readyAt = 281474976710655 (never reachable).
contract HookrRegistryDelayBoundsTest is GovernanceSecurityBase {
    function setUp() public {
        _setUpPeriphery();
    }

    function testUnusableDelaysRefusedAtDeployment() public {
        vm.expectRevert(IHookrRegistry.InvalidDelay.selector);
        new HookrRegistry(address(this), manager, type(uint48).max);
        vm.expectRevert(IHookrRegistry.InvalidDelay.selector);
        new HookrRegistry(address(this), manager, type(uint48).max - uint48(vm.getBlockTimestamp()));
        vm.expectRevert(IHookrRegistry.InvalidDelay.selector);
        new HookrRegistry(address(this), manager, 30 days + 1);
        vm.expectRevert(IHookrRegistry.InvalidDelay.selector);
        new HookrRegistry(address(this), manager, 30 minutes - 1);
    }

    function testBoundaryDelaysQueueAndMature() public {
        HookrRegistry longest = new HookrRegistry(address(this), manager, 30 days);
        assertEq(longest.MAX_DELAY(), 30 days);
        bytes32 op = longest.queue(longest.SET_LAUNCHER(), abi.encode(address(launcher), true));
        assertEq(longest.readyAt(op), vm.getBlockTimestamp() + 30 days);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        longest.setLauncher(address(launcher), true);
        assertTrue(longest.isLauncher(address(launcher)));
        HookrRegistry shortest = new HookrRegistry(address(this), manager, 30 minutes);
        assertEq(shortest.delay(), shortest.MIN_DELAY());
        assertEq(shortest.MIN_DELAY(), 30 minutes);
    }

    function testFuzz_everyAcceptedDelayMatures(uint48 delay_) public {
        delay_ = uint48(bound(delay_, 30 minutes, 30 days));
        HookrRegistry r = new HookrRegistry(address(this), manager, delay_);
        bytes32 op = r.queue(r.SET_LAUNCHER(), abi.encode(address(launcher), true));
        assertEq(r.readyAt(op), vm.getBlockTimestamp() + delay_);
        vm.warp(vm.getBlockTimestamp() + delay_);
        r.setLauncher(address(launcher), true);
    }
}
