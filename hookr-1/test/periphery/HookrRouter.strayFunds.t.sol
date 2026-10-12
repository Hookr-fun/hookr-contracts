// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

// N-03 old numbers: force-sent ETH and mistaken ERC20 transfers to the router were stranded forever.
// Fixed: an idle-only permissionless sweep to a caller-chosen address.

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {EconomicsSecurityBase} from "../utils/EconomicsSecurityBase.sol";

contract ForceSend {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}

/// @notice Audit finding N-03.
contract HookrRouterStrayFundsTest is EconomicsSecurityBase {
    function testStrayFundsSweepable() public {
        (PoolKey memory key,,) = _launchMember(_member(Currency.wrap(address(0))), true);
        new ForceSend{value: 1 ether}(payable(address(router)));
        tokenA.transfer(address(router), 7);
        _buyAs(trader, key, 1e18);
        address to = address(0x5151);
        assertEq(router.sweep(Currency.wrap(address(0)), to), 1 ether);
        assertEq(to.balance, 1 ether);
        assertEq(router.sweep(Currency.wrap(address(tokenA)), to), 7);
        assertEq(tokenA.balanceOf(to), 7);
        assertEq(address(router).balance, 0);
        _buyAs(trader, key, 1e18);
    }

    function testSweepRefusesBadTarget() public {
        vm.expectRevert(IHookrRouter.InvalidSwap.selector);
        router.sweep(Currency.wrap(address(0)), address(0));
        vm.expectRevert(IHookrRouter.InvalidSwap.selector);
        router.sweep(Currency.wrap(address(0)), address(router));
    }
}
