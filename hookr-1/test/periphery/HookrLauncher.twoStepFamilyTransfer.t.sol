// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {PeripheryFixture} from "./PeripheryFixture.sol";

/// @notice L-13 regression. Original PoC (B12Verify test_c4, unfixed source): transferFamily(family, PoolManager)
/// was accepted in one step, familyOwner became the PoolManager, and the original owner's withdraw and transfer
/// back both reverted NotOwner, permanently stranding a 1e24-liquidity position. Fixed: transferFamily only names
/// a pending owner (the PoolManager and the Launcher are refused outright); control moves when that address calls
/// acceptFamily, and until then the current owner keeps full control and can cancel or re-target.
/// Review follow-up: the form of the old owner's accrued fees (tokens or ERC-6909 claims) is chosen by the old owner
/// in transferFamily, not by the accepting party (which could previously force claims on it).
contract HookrLauncherTwoStepFamilyTransferTest is PeripheryFixture {
    function setUp() public {
        _setUpPeriphery();
    }

    function testTransferToPoolManagerOrLauncherIsRefused() public {
        (bytes32 family,,,) = _launch(true, true);
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.InvalidRecipient.selector, address(manager)));
        launcher.transferFamily(family, address(manager), 0);
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.InvalidRecipient.selector, address(launcher)));
        launcher.transferFamily(family, address(launcher), 0);
        assertEq(launcher.familyOwner(family), address(this));
    }

    function testUnusableTargetNeverTakesControl() public {
        (bytes32 family,,,) = _launch(true, true);
        uint128 liq = launcher.position(family, 0).liquidity;
        // A mistyped or unusable target (here a token contract) is only pending.
        launcher.transferFamily(family, address(tokenB), 0);
        assertEq(launcher.familyOwner(family), address(this));
        (address pending,) = launcher.pendingFamilyOwner(family);
        assertEq(pending, address(tokenB));
        // The owner still controls every position and can re-target the transfer.
        launcher.withdraw(family, 0, liq / 2, 0, 0, address(this), block.timestamp);
        launcher.transferFamily(family, trader, 0);
        vm.prank(address(tokenB));
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.NotPendingOwner.selector, family, address(tokenB)));
        launcher.acceptFamily(family);
        vm.prank(trader);
        launcher.acceptFamily(family);
        assertEq(launcher.familyOwner(family), trader);
        (pending,) = launcher.pendingFamilyOwner(family);
        assertEq(pending, address(0));
        vm.prank(trader);
        launcher.withdraw(family, 0, liq - liq / 2, 0, 0, trader, block.timestamp);
    }

    function testCancelAndEvents() public {
        (bytes32 family,,,) = _launch(true, false);
        vm.recordLogs();
        launcher.transferFamily(family, trader, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], IHookrLauncher.FamilyTransferStarted.selector);
        assertEq(address(uint160(uint256(logs[0].topics[2]))), address(this));
        assertEq(address(uint160(uint256(logs[0].topics[3]))), trader);
        assertEq(abi.decode(logs[0].data, (uint16)), 0);
        // Cancelling clears the pending owner; FamilyTransferred is never emitted.
        launcher.transferFamily(family, address(0), 0);
        (address pending,) = launcher.pendingFamilyOwner(family);
        assertEq(pending, address(0));
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.NotPendingOwner.selector, family, trader));
        launcher.acceptFamily(family);
        assertEq(launcher.familyOwner(family), address(this));
        // Only the owner can start or cancel.
        vm.prank(trader);
        vm.expectRevert(IHookrLauncher.NotOwner.selector);
        launcher.transferFamily(family, trader, 0);
        // Acceptance emits exactly one ownership change for indexers.
        launcher.transferFamily(family, trader, 0);
        vm.recordLogs();
        vm.prank(trader);
        launcher.acceptFamily(family);
        logs = vm.getRecordedLogs();
        uint256 transferred;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(launcher) && logs[i].topics[0] == IHookrLauncher.FamilyTransferred.selector)
            {
                ++transferred;
                assertEq(address(uint160(uint256(logs[i].topics[2]))), trader);
            }
        }
        assertEq(transferred, 1);
    }

    function testTransferRejectsClaimBitsBeyondMembers() public {
        (bytes32 family,,,) = _launch(true, false);
        vm.expectRevert(abi.encodeWithSelector(IHookrLauncher.InvalidClaims.selector, uint256(4)));
        launcher.transferFamily(family, trader, 4);
        launcher.transferFamily(family, trader, 3);
        (address pending, uint16 claims) = launcher.pendingFamilyOwner(family);
        assertEq(pending, trader);
        assertEq(claims, 3);
        vm.prank(trader);
        launcher.acceptFamily(family);
        assertEq(launcher.familyOwner(family), trader);
        (, claims) = launcher.pendingFamilyOwner(family);
        assertEq(claims, 0, "cleared on acceptance");
    }

    function _earnFees(PoolKey memory key) internal {
        IHookrRouter.Swap memory buy = _swap(key, true, true, 1e22);
        IHookrRouter.Swap memory sell = _swap(key, false, true, 1e21);
        vm.startPrank(trader);
        router.swap(buy, address(0), new uint256[](0));
        router.swap(sell, address(0), new uint256[](0));
        vm.stopPrank();
    }

    /// Review probe (was: acceptFamily(family, 3) by the new owner paid the old owner 2.999999999999999999 and
    /// 171.224999999999999999 as claims and no tokens). The accepting party no longer has a fee-form input.
    function testNewOwnerCannotChooseOldOwnersFeeForm() public {
        (bytes32 family, PoolKey memory key,,) = _launch(true, false);
        _earnFees(key);
        IERC20 t0 = IERC20(Currency.unwrap(key.currency0));
        IERC20 t1 = IERC20(Currency.unwrap(key.currency1));
        uint256 b0 = t0.balanceOf(address(this));
        uint256 b1 = t1.balanceOf(address(this));
        launcher.transferFamily(family, trader, 0);
        vm.prank(trader);
        launcher.acceptFamily(family);
        assertGt(t0.balanceOf(address(this)) + t1.balanceOf(address(this)), b0 + b1, "old owner paid in tokens");
        assertEq(manager.balanceOf(address(this), key.currency0.toId()), 0, "no claim forced on the old owner");
        assertEq(manager.balanceOf(address(this), key.currency1.toId()), 0, "no claim forced on the old owner");
    }

    function testOldOwnerMayChooseClaims() public {
        (bytes32 family, PoolKey memory key,,) = _launch(true, false);
        _earnFees(key);
        IERC20 t0 = IERC20(Currency.unwrap(key.currency0));
        IERC20 t1 = IERC20(Currency.unwrap(key.currency1));
        uint256 b0 = t0.balanceOf(address(this));
        uint256 b1 = t1.balanceOf(address(this));
        launcher.transferFamily(family, trader, 3);
        vm.prank(trader);
        launcher.acceptFamily(family);
        assertEq(t0.balanceOf(address(this)), b0, "claims chosen by the old owner, no tokens");
        assertEq(t1.balanceOf(address(this)), b1, "claims chosen by the old owner, no tokens");
        assertGt(
            manager.balanceOf(address(this), key.currency0.toId())
                + manager.balanceOf(address(this), key.currency1.toId()),
            0
        );
    }
}
