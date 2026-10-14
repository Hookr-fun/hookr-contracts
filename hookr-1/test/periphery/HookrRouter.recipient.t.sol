// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookrRouter} from "../../src/periphery/HookrRouter.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrRegistry} from "../../src/core/HookrRegistry.sol";
import {IHookrForwarder} from "../../src/interfaces/IHookrForwarder.sol";
import {GasBenchFixture} from "../utils/GasBenchFixture.sol";

/// @notice F-057: output sent to the PoolManager or the forwarder is stranded, so the Router refuses both
///         recipients on direct and relayed swaps. The Router also pins the registry's PoolManager.
contract HookrRouterRecipientTest is GasBenchFixture {
    function test_directSwapToPoolManagerRefused() public {
        IHookrRouter.Swap memory p = _params(feeKey, true, 1e21);
        p.recipient = address(manager);
        vm.prank(trader);
        vm.expectRevert(IHookrRouter.InvalidSwap.selector);
        router.swap(p, address(0), new uint256[](0));
    }

    function test_directSwapToForwarderRefused() public {
        IHookrRouter.Swap memory p = _params(fullKey, false, 1e21);
        p.recipient = address(fwd);
        vm.prank(trader);
        vm.expectRevert(IHookrRouter.InvalidSwap.selector);
        router.swap(p, address(0), new uint256[](0));
    }

    function test_relayedSwapToPoolManagerRefused() public {
        IHookrForwarder.HookrSwapIntent memory i = _intent(feeKey, false, 1e21, 9);
        i.recipient = address(manager);
        bytes memory sig = _sign(i);
        uint256 before = subject.balanceOf(owner);
        vm.prank(RELAYER);
        vm.expectRevert(IHookrRouter.InvalidSwap.selector);
        fwd.execute(i, owner, sig);
        assertEq(subject.balanceOf(owner), before);
    }

    function test_routerPinsTheRegistryPoolManager() public {
        IPoolManager other = IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        HookrRegistry foreign = new HookrRegistry(address(this), other, 1 days);
        vm.expectRevert(IHookrRouter.InvalidPool.selector);
        new HookrRouter(manager, foreign, address(0));
    }
}
