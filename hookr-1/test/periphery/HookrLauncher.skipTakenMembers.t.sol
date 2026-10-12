// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {PeripheryFixture} from "./PeripheryFixture.sol";

/// F-029: on a public mempool anyone could open one member key of a pending existing-token launch first (3 wei,
/// quote-only range), and the whole family reverted PoolExists. An existing-token launch with salt SKIP_TAKEN
/// launches the members that are still free. A taken member's ERC-20 budgets are never pulled; a taken native
/// member's budget still arrives with msg.value and is refunded whole.
contract HookrLauncherSkipTakenMembersTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    address internal squatter = address(0xBAD);

    function setUp() public {
        _setUpPeriphery();
        tokenA.transfer(squatter, 1e20);
        tokenB.transfer(squatter, 1e20);
        vm.deal(squatter, 1e18);
        vm.startPrank(squatter);
        tokenA.approve(address(launcher), type(uint256).max);
        tokenB.approve(address(launcher), type(uint256).max);
        vm.stopPrank();
    }

    /// The squatter front-runs the native member (tokenA/ETH at spacing 60) with a dust ETH-only range above price.
    function _squatNative() internal returns (PoolId id) {
        IHookrLauncher.Member[] memory squat = new IHookrLauncher.Member[](1);
        squat[0] = _member(Currency.wrap(address(0)));
        squat[0].tickLower = 60;
        squat[0].tickUpper = 120;
        squat[0].liquidity = 1000;
        squat[0].amount0Max = 100;
        squat[0].amount1Max = 0;
        vm.prank(squatter);
        (bytes32 family,) = launcher.launch{value: 100}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), squat, vm.getBlockTimestamp()
        );
        id = launcher.position(family, 0).key.toId();
    }

    function _family() internal view returns (IHookrLauncher.Member[] memory members) {
        members = new IHookrLauncher.Member[](2);
        members[0] = _member(Currency.wrap(address(tokenB)));
        members[1] = _member(Currency.wrap(address(0)));
    }

    /// The squatter front-runs member 0 (tokenA/tokenB at spacing 60) with a dust quote-only range.
    function _squat() internal returns (PoolId id) {
        IHookrLauncher.Member[] memory squat = new IHookrLauncher.Member[](1);
        squat[0] = _member(Currency.wrap(address(tokenB)));
        bool quoteIs0 = address(tokenB) < address(tokenA);
        squat[0].tickLower = quoteIs0 ? int24(60) : int24(-120);
        squat[0].tickUpper = quoteIs0 ? int24(120) : int24(-60);
        squat[0].liquidity = 1000;
        squat[0].amount0Max = quoteIs0 ? 100 : 0;
        squat[0].amount1Max = quoteIs0 ? 0 : 100;
        vm.prank(squatter);
        (bytes32 family,) = launcher.launch(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), squat, vm.getBlockTimestamp()
        );
        id = launcher.position(family, 0).key.toId();
    }

    function testAtomicLaunchStillRevertsOnATakenMember() public {
        PoolId id = _squat();
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.PoolExists.selector, uint8(0), id));
        launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)),
            address(root),
            _family(),
            vm.getBlockTimestamp()
        );
    }

    function testSkipTakenLaunchesTheFreeMembersAndRefundsTheRest() public {
        PoolId taken = _squat();
        uint256 subjectBefore = tokenA.balanceOf(address(this));
        uint256 quoteBefore = tokenB.balanceOf(address(this));
        uint256 nativeBefore = address(this).balance;
        bytes32 skip = launcher.SKIP_TAKEN();
        vm.expectEmit(false, true, true, true, address(launcher));
        emit IHookrLauncher.MemberSkipped(bytes32(0), 0, taken);
        (bytes32 family,) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, skip), address(root), _family(), vm.getBlockTimestamp()
        );
        assertEq(launcher.memberCount(family), 2);
        assertEq(launcher.position(family, 0).liquidity, 0, "skipped member stays empty");
        IHookrLauncher.Position memory p = launcher.position(family, 1);
        assertEq(p.liquidity, 1e24);
        assertTrue(root.knownPool(p.key.toId()));
        assertEq(launcher.poolFamily(p.key.toId()), family);
        assertTrue(launcher.poolFamily(taken) != family, "the squatted pool is not part of the family");
        assertEq(tokenB.balanceOf(address(this)), quoteBefore, "taken member's quote budget never left");
        assertLt(tokenA.balanceOf(address(this)), subjectBefore, "the free member was funded");
        assertLt(address(this).balance, nativeBefore);
        // The empty member cannot be withdrawn from or topped up.
        vm.expectRevert(IHookrLauncher.InvalidFamily.selector);
        launcher.withdraw(family, 0, 0, 0, 0, address(this), vm.getBlockTimestamp());
    }

    /// The taken member's ERC-20 budgets are never pulled: the family launches with no allowance at all for the
    /// taken member's quote and a subject allowance of exactly the free member's subject budget, and the taken quote
    /// token never moves.
    function testSkipTakenPullsNoBudgetOfATakenMember() public {
        _squat();
        IHookrLauncher.Member[] memory members = _family();
        tokenB.approve(address(launcher), 0);
        // Member 1 quotes ETH, always currency0, so its subject budget is amount1Max.
        tokenA.approve(address(launcher), members[1].amount1Max);
        uint256 quoteBefore = tokenB.balanceOf(address(this));
        bytes32 skip = launcher.SKIP_TAKEN();
        vm.recordLogs();
        (bytes32 family,) = launcher.launch{value: members[1].amount0Max}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, skip), address(root), members, vm.getBlockTimestamp()
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].emitter != address(tokenB), "the taken member's quote token never moves");
        }
        assertEq(tokenB.balanceOf(address(this)), quoteBefore);
        assertEq(tokenA.allowance(address(this), address(launcher)), 0, "subject pulled for the free member only");
        assertEq(launcher.position(family, 0).liquidity, 0);
        assertEq(launcher.position(family, 1).liquidity, 1e24);
    }

    /// A taken native member keeps the native funding rule: msg.value is still its whole budget, which the launch
    /// refunds, and a launch that sends less reverts.
    function testSkipTakenNativeMemberStillTakesAndRefundsItsValue() public {
        PoolId taken = _squatNative();
        IHookrLauncher.Member[] memory members = _family();
        bytes32 skip = launcher.SKIP_TAKEN();
        vm.expectRevert(IHookrLauncher.InvalidFunding.selector);
        launcher.launch(
            IHookrLauncher.Token(address(tokenA), "", "", 0, skip), address(root), members, vm.getBlockTimestamp()
        );
        uint256 nativeBefore = address(this).balance;
        vm.expectEmit(false, true, true, true, address(launcher));
        emit IHookrLauncher.MemberSkipped(bytes32(0), 1, taken);
        (bytes32 family,) = launcher.launch{value: members[1].amount0Max}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, skip), address(root), members, vm.getBlockTimestamp()
        );
        assertEq(address(this).balance, nativeBefore, "the taken native budget is refunded whole");
        assertEq(address(launcher).balance, 0);
        assertEq(launcher.position(family, 0).liquidity, 1e24);
        assertEq(launcher.position(family, 1).liquidity, 0);
    }

    function testSkipTakenWithNoFreeMemberReverts() public {
        _squat();
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(tokenB)));
        bytes32 skip = launcher.SKIP_TAKEN();
        vm.expectRevert(IHookrLauncher.InvalidFamily.selector);
        launcher.launch(
            IHookrLauncher.Token(address(tokenA), "", "", 0, skip), address(root), members, vm.getBlockTimestamp()
        );
    }

    function testOtherExistingTokenSaltsStillRefused() public {
        vm.expectRevert(IHookrLauncher.InvalidFunding.selector);
        launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(uint256(2))),
            address(root),
            _family(),
            vm.getBlockTimestamp()
        );
    }
}
