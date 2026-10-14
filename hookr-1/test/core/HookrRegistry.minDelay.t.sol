// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {HookrRegistry} from "../../src/core/HookrRegistry.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {GovernanceSecurityBase} from "../utils/GovernanceSecurityBase.sol";

/// @notice F-053: the registry accepted a one-hour delay against a one-day release policy.
/// @dev The release policy is now a fixed 30-minute wait: `MIN_DELAY` is 30 minutes and shorter delays are refused at
///      deployment.
contract HookrRegistryMinDelayTest is GovernanceSecurityBase {
    function setUp() public {
        _setUpPeriphery();
    }

    function testDelaysBelowThirtyMinutesRefused() public {
        assertEq(registry.MIN_DELAY(), 30 minutes);
        vm.expectRevert(IHookrRegistry.InvalidDelay.selector);
        new HookrRegistry(address(this), manager, 1 minutes);
        vm.expectRevert(IHookrRegistry.InvalidDelay.selector);
        new HookrRegistry(address(this), manager, 30 minutes - 1);
        HookrRegistry r = new HookrRegistry(address(this), manager, 30 minutes);
        bytes32 op = r.queue(r.SET_LAUNCHER(), abi.encode(address(launcher), true));
        assertEq(r.readyAt(op), vm.getBlockTimestamp() + 30 minutes);
        vm.warp(vm.getBlockTimestamp() + 30 minutes - 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, op));
        r.setLauncher(address(launcher), true);
        vm.warp(vm.getBlockTimestamp() + 1);
        r.setLauncher(address(launcher), true);
        assertTrue(r.isLauncher(address(launcher)));
    }
}
