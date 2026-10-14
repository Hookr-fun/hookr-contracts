// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {PeripheryFixture} from "./PeripheryFixture.sol";

/// @notice The router's amount bounds at their edges, each with a mutation-gate id: the minimum output of an exact-input
///         swap and the maximum input of an exact-output swap hold to the unit (RO-2, RO-3), a native swap carries
///         exactly its input (RO-11), nine engagement campaigns are refused (RO-6) and a swap that buys nothing is
///         refused (RO-8).
contract HookrRouterBoundsTest is PeripheryFixture {
    function setUp() public {
        _setUpPeriphery();
    }

    /// RO-2: an exact-input swap that delivers exactly its minimum output settles, and with the minimum one unit above
    /// what it delivers it is refused.
    function test_exactInputMinimumOutHoldsToTheUnit() public {
        (, PoolKey memory key,,) = _launch(true, false);
        IHookrRouter.Swap memory p = _swap(key, true, true, 1e18);
        uint256 out = quoter.quote(p, trader).outputAmount;
        p.amountBound = uint128(out) + 1;
        vm.prank(trader);
        vm.expectRevert(IHookrRouter.Slippage.selector);
        router.swap(p, address(0), new uint256[](0));
        p.amountBound = uint128(out);
        vm.prank(trader);
        (, uint256 got) = router.swap(p, address(0), new uint256[](0));
        assertEq(got, out);
    }

    /// RO-3: an exact-output swap that spends exactly its maximum input settles, and with the maximum one unit below
    /// what it spends it is refused.
    function test_exactOutputMaximumInHoldsToTheUnit() public {
        (, PoolKey memory key,,) = _launch(true, false);
        IHookrRouter.Swap memory p = _swap(key, true, false, 1e18);
        uint256 spend = quoter.quote(p, trader).inputAmount;
        p.amountBound = uint128(spend) - 1;
        vm.prank(trader);
        vm.expectRevert(IHookrRouter.Slippage.selector);
        router.swap(p, address(0), new uint256[](0));
        p.amountBound = uint128(spend);
        vm.prank(trader);
        (uint256 paid,) = router.swap(p, address(0), new uint256[](0));
        assertEq(paid, spend);
    }

    /// RO-11: a swap of a native input is paid exactly its input in value: a surplus is refused, as a shortfall is.
    function test_aNativeSwapCarriesExactlyItsInput() public {
        (, PoolKey memory key,,) = _launch(false, true);
        IHookrRouter.Swap memory p = _swap(key, true, true, 1 ether);
        vm.prank(trader);
        vm.expectRevert(IHookrRouter.InvalidSwap.selector);
        router.swap{value: 1 ether + 1}(p, address(0), new uint256[](0));
        vm.prank(trader);
        vm.expectRevert(IHookrRouter.InvalidSwap.selector);
        router.swap{value: 1 ether - 1}(p, address(0), new uint256[](0));
        vm.prank(trader);
        router.swap{value: 1 ether}(p, address(0), new uint256[](0));
    }

    /// RO-6: a swap names at most eight engagement campaigns; nine are refused before anything moves.
    function test_nineCampaignsAreRefused() public {
        (, PoolKey memory key,,) = _launch(true, false);
        IHookrRouter.Swap memory p = _swap(key, true, true, 1e18);
        vm.prank(trader);
        vm.expectRevert(IHookrRouter.InvalidSwap.selector);
        router.swap(p, address(this), new uint256[](9));
    }

    /// RO-8: a swap that settles an input but buys nothing (a dust input rounds the output to zero) is refused.
    function test_aSwapThatBuysNothingIsRefused() public {
        (, PoolKey memory key,,) = _launch(true, false);
        IHookrRouter.Swap memory p = _swap(key, true, true, 1);
        vm.prank(trader);
        vm.expectRevert(IHookrRouter.InvalidSwap.selector);
        router.swap(p, address(0), new uint256[](0));
    }
}
