// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {PeripheryFixture} from "./PeripheryFixture.sol";

contract FamilyLifecycleTest is PeripheryFixture {
    function setUp() public {
        _setUpPeriphery();
    }

    function testTransferPaysEarnedFeesToOldOwner() public {
        (bytes32 family, PoolKey memory key,,) = _launch(true, false);
        IHookrRouter.Swap memory swap = _swap(key, true, true, 1e20);
        vm.prank(trader);
        router.swap(swap, address(0), new uint256[](0));
        uint256 beforeA = tokenA.balanceOf(address(this));
        uint256 beforeB = tokenB.balanceOf(address(this));
        // Two-step transfer (L-13): the old owner keeps control and earned fees until the new owner accepts.
        launcher.transferFamily(family, trader, 0);
        assertEq(launcher.familyOwner(family), address(this));
        (address pendingOwner, uint16 claims) = launcher.pendingFamilyOwner(family);
        assertEq(pendingOwner, trader);
        assertEq(claims, 0);
        vm.recordLogs();
        vm.prank(trader);
        launcher.acceptFamily(family);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // I-09: the event names the owner and the actual recipient.
        bytes32 topic = keccak256("LPFeesCollected(bytes32,uint8,bytes32,address,address,uint256,uint256)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(launcher) || logs[i].topics[0] != topic) continue;
            assertEq(address(uint160(uint256(logs[i].topics[3]))), address(this));
            (uint8 member, address recipient, uint256 fee0, uint256 fee1) =
                abi.decode(logs[i].data, (uint8, address, uint256, uint256));
            assertEq(member, 0);
            assertEq(recipient, address(this));
            assertGt(fee0 + fee1, 0);
            found = true;
        }
        assertTrue(found);
        assertGt(tokenA.balanceOf(address(this)) + tokenB.balanceOf(address(this)), beforeA + beforeB);
        assertEq(launcher.familyOwner(family), trader);
        vm.prank(trader);
        (uint256 a, uint256 b) = launcher.withdraw(family, 0, 0, 0, 0, trader, block.timestamp);
        assertEq(a + b, 0);
    }

    function testTopUpPreservesPreexistingAssetsAndCollectsFees() public {
        (bytes32 family, PoolKey memory key,,) = _launch(true, false);
        tokenA.transfer(address(launcher), 19);
        tokenB.transfer(address(launcher), 23);
        IHookrRouter.Swap memory swap = _swap(key, true, true, 1e20);
        vm.prank(trader);
        router.swap(swap, address(0), new uint256[](0));
        uint128 prior = launcher.position(family, 0).liquidity;
        (uint256 paid0, uint256 paid1) = launcher.addLiquidity(family, 0, 1e20, 1e22, 1e22, block.timestamp);
        assertGt(paid0 + paid1, 0);
        assertEq(launcher.position(family, 0).liquidity, prior + 1e20);
        assertEq(tokenA.balanceOf(address(launcher)), 19);
        assertEq(tokenB.balanceOf(address(launcher)), 23);
    }

    function testNativeTopUpRefundsUnusedFunding() public {
        (bytes32 family,,,) = _launch(true, true);
        uint256 beforeNative = address(this).balance;
        (uint256 paid0,) = launcher.addLiquidity{value: 1e22}(family, 0, 1e20, 1e22, 1e22, block.timestamp);
        assertEq(address(this).balance, beforeNative - paid0);
        assertEq(address(launcher).balance, 0);
    }

    function testTopUpFailureDoesNotChangePositionOrOwner() public {
        (bytes32 family,,,) = _launch(true, false);
        uint128 prior = launcher.position(family, 0).liquidity;
        vm.expectRevert(IHookrLauncher.Slippage.selector);
        launcher.addLiquidity(family, 0, 1e20, 0, 0, block.timestamp);
        assertEq(launcher.position(family, 0).liquidity, prior);
        assertEq(launcher.familyOwner(family), address(this));
        vm.prank(trader);
        vm.expectRevert(IHookrLauncher.NotOwner.selector);
        launcher.addLiquidity(family, 0, 1e20, 1e22, 1e22, block.timestamp);
    }

    function testNewTokenPredictionSurvivesOtherLaunches() public {
        IHookrLauncher.Token memory token =
            IHookrLauncher.Token(address(0), "Family", "FAM", 1e25, bytes32(uint256(42)));
        address predicted = launcher.predictToken(address(this), token);
        assertTrue(predicted != launcher.predictToken(trader, token));
        _launch(true, false);
        assertEq(predicted, launcher.predictToken(address(this), token));
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(0)));
        (, address subject) = launcher.launch{value: 1e24}(token, address(root), members, block.timestamp);
        assertEq(subject, predicted);
        vm.expectRevert();
        launcher.launch{value: 1e24}(token, address(root), members, block.timestamp);
    }
}
