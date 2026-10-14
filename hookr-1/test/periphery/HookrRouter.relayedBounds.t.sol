// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {GasBenchFixture} from "../utils/GasBenchFixture.sol";

/// @notice The relayed entry of the router (swapFor, callable only by its pinned forwarder) at its edges, each with a
///         mutation-gate id: an output fee as large as the output is paid and one unit more is refused (RO-4), and a
///         forwarder whose runtime changed after the router pinned its code hash is no longer the forwarder (RO-5).
contract HookrRouterRelayedBoundsTest is GasBenchFixture {
    function _exactOut(uint128 out) internal view returns (IHookrRouter.Swap memory p) {
        bool zeroForOne = _zeroForOne(feeKey, true);
        p = IHookrRouter.Swap(
            feeKey,
            zeroForOne,
            int128(out),
            uint128(10 * uint256(out)),
            zeroForOne ? MIN_PRICE : MAX_PRICE,
            owner,
            vm.getBlockTimestamp() + 1000
        );
    }

    function _fundForwarder() internal {
        quoteFee.transfer(address(fwd), 1e22);
        vm.prank(address(fwd));
        quoteFee.approve(address(router), type(uint256).max);
    }

    /// RO-4: the relayer fee of an exact-output swap may be the whole output (the recipient then gets nothing) and not
    /// a unit more.
    function test_anOutputFeeEqualToTheOutputIsPaid() public {
        _fundForwarder();
        uint128 out = 1e18;
        vm.prank(address(fwd));
        (, uint256 got) = router.swapFor(_exactOut(out), owner, out, RELAYER, address(0), new uint256[](0));
        assertEq(got, out);
        assertEq(subject.balanceOf(RELAYER), out, "the relayer was paid the whole output");
        vm.prank(address(fwd));
        vm.expectRevert(abi.encodeWithSelector(IHookrRouter.FeeExceedsOutput.selector, uint256(out) + 1, uint256(out)));
        router.swapFor(_exactOut(out), owner, uint256(out) + 1, RELAYER, address(0), new uint256[](0));
    }

    /// RO-5: the router pinned its forwarder's runtime code hash at construction; the same address with other code is
    /// refused.
    function test_aForwarderWithChangedCodeIsRefused() public {
        _fundForwarder();
        vm.etch(address(fwd), hex"6000");
        vm.prank(address(fwd));
        vm.expectRevert(abi.encodeWithSelector(IHookrRouter.NotForwarder.selector, address(fwd)));
        router.swapFor(_exactOut(1e18), owner, 0, address(0), address(0), new uint256[](0));
    }
}
