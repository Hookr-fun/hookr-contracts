// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrRouter} from "../../src/periphery/HookrRouter.sol";

/// @notice The router's selector pins: IHookrRouter, which the forwarder, the Programs validator and integrators call
///         through, keeps HookrRouter's own selectors.
contract RouterInterfaceTest is Test {
    /// @notice IHookrRouter is HookrRouter's own surface: `swapFor` (0x28672da5), the entry the forwarder calls,
    ///         `swap` (0x19b36adf) and `registry` (0x7b103999) keep HookrRouter's selectors, and each swap selector
    ///         covers the whole Swap tuple.
    function test_routerInterfaceMatchesTheRouter() public view {
        assertEq(IHookrRouter.swapFor.selector, HookrRouter.swapFor.selector);
        assertEq(IHookrRouter.swapFor.selector, bytes4(0x28672da5));
        assertEq(IHookrRouter.swap.selector, HookrRouter.swap.selector);
        assertEq(IHookrRouter.swap.selector, bytes4(0x19b36adf));
        assertEq(IHookrRouter.registry.selector, HookrRouter(payable(address(0))).registry.selector);
        assertEq(IHookrRouter.registry.selector, bytes4(0x7b103999));
    }

    /// @notice `forwarder` (0xf645d4f9), which the quoter reads for the router's swap preflight, keeps HookrRouter's
    ///         selector.
    function test_routerInterfaceDeclaresTheForwarder() public view {
        assertEq(IHookrRouter.forwarder.selector, HookrRouter(payable(address(0))).forwarder.selector);
        assertEq(IHookrRouter.forwarder.selector, bytes4(0xf645d4f9));
    }
}
