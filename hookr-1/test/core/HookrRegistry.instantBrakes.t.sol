// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {GovernanceSecurityBase} from "../utils/GovernanceSecurityBase.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";

/// @notice F-023 / F-031: stopping one bad root or one bad launcher required the global new-market pause, and a
///         launcher could only be removed through the timelock.
/// @dev The owner or the guardian closes a root or deactivates a launcher at once. Both only stop new pools:
///      trading, claims and exits continue. Reopening and readmission are timelocked, and replacing the guardian
///      stays timelocked.
contract HookrRegistryInstantBrakesTest is GovernanceSecurityBase {
    using PoolIdLibrary for PoolKey;

    address internal guardianAccount = address(0x6A7D);

    function setUp() public {
        _setUpPeriphery();
        registry.queue(registry.SET_GUARDIAN(), abi.encode(guardianAccount));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setGuardian(guardianAccount);
    }

    function _assertExistingPoolLive(bytes32 family, PoolKey memory key, Currency quote) internal {
        IHookrRouter.Swap memory buy = _swap(key, true, true, 1e18);
        vm.prank(trader);
        (, uint256 out) = router.swap(buy, address(0), new uint256[](0));
        assertGt(out, 0);
        uint256 owed = rules.claimable(quote, protocol);
        assertGt(owed, 0);
        vm.prank(protocol);
        assertEq(rules.claim(quote), owed);
        uint128 liquidity = launcher.position(family, 0).liquidity;
        (uint256 a0, uint256 a1) = launcher.withdraw(family, 0, liquidity, 0, 0, address(this), vm.getBlockTimestamp());
        assertGt(a0 + a1, 0);
    }

    function testGuardianClosesOneRootAtOnce() public {
        (bytes32 family, PoolKey memory existing,, Currency quote) = _launch(true, false);
        HookrRoot second = _secondRoot();
        bytes32 secondHash = address(second).codehash;
        registry.queue(registry.REGISTER_ROOT(), abi.encode(address(second), secondHash));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.registerRoot(address(second), secondHash);

        vm.expectEmit(true, true, false, false, address(registry));
        emit IHookrRegistry.RootClosed(address(root), guardianAccount);
        vm.prank(guardianAccount);
        registry.closeRoot(address(root));
        // Old: only the global pause existed, which also closed `second`.
        assertTrue(registry.rootClosed(address(root)));
        assertFalse(registry.rootOpen(address(root)));
        assertTrue(registry.isRoot(address(root)));
        assertTrue(registry.rootOpen(address(second)));
        assertFalse(registry.newMarketsPaused());

        vm.expectRevert(IHookrLauncher.InvalidFamily.selector);
        this.launchExternal(address(root), address(rules), 120);
        // The root itself refuses initialisation even from an admitted launcher.
        registry.queue(registry.SET_LAUNCHER(), abi.encode(address(this), true));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setLauncher(address(this), true);
        IHookrLauncher.Member memory m = _member(quote);
        HookrTypes.PoolConfig memory config = root.poolConfig(existing.toId());
        PoolKey memory key = PoolKey(existing.currency0, existing.currency1, existing.fee, 200, existing.hooks);
        bytes memory rulesData = abi.encode(m.rules);
        vm.expectRevert(IHookrRootEvents.Unauthorized.selector);
        root.initializePool(key, config, rulesData, bytes(""), SQRT_ONE);

        _assertExistingPoolLive(family, existing, quote);
    }

    function testReopenIsTimelockedAndOnlyQueuedWhileClosed() public {
        bytes32 reopen = registry.REOPEN_ROOT();
        vm.expectRevert(IHookrRegistry.RootNotClosed.selector);
        registry.queue(reopen, abi.encode(address(root)));
        registry.closeRoot(address(root));
        // Idempotent for either brake holder.
        vm.prank(guardianAccount);
        registry.closeRoot(address(root));
        vm.prank(guardianAccount);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.reopenRoot(address(root));
        bytes32 op = registry.operationHash(reopen, abi.encode(address(root)));
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, op));
        registry.reopenRoot(address(root));
        registry.queue(reopen, abi.encode(address(root)));
        vm.warp(vm.getBlockTimestamp() + registry.delay() - 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, op));
        registry.reopenRoot(address(root));
        vm.warp(vm.getBlockTimestamp() + 1);
        registry.reopenRoot(address(root));
        assertFalse(registry.rootClosed(address(root)));
        assertTrue(registry.rootOpen(address(root)));
        _launchOn(address(root), address(rules), 60);
    }

    function testRetiredRootCannotBeReopened() public {
        registry.closeRoot(address(root));
        registry.queue(registry.RETIRE_ROOT(), abi.encode(address(root)));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.retireRoot(address(root));
        bytes32 reopen = registry.REOPEN_ROOT();
        vm.expectRevert(IHookrRegistry.InvalidRoot.selector);
        registry.queue(reopen, abi.encode(address(root)));
        assertFalse(registry.rootOpen(address(root)));
    }

    function testOnlyBrakeHoldersCloseRegisteredRoots() public {
        vm.prank(trader);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.closeRoot(address(root));
        vm.prank(guardianAccount);
        vm.expectRevert(IHookrRegistry.InvalidRoot.selector);
        registry.closeRoot(address(0xDEAD));
    }

    function testGuardianDeactivatesOneLauncherAtOnce() public {
        (bytes32 family, PoolKey memory existing,, Currency quote) = _launch(true, false);
        vm.expectEmit(true, true, false, false, address(registry));
        emit IHookrRegistry.LauncherDeactivated(address(launcher), guardianAccount);
        vm.prank(guardianAccount);
        registry.deactivateLauncher(address(launcher));
        // Old: removal waited a full delay behind a published SET_LAUNCHER.
        assertFalse(registry.isLauncher(address(launcher)));
        assertTrue(registry.rootOpen(address(root)));
        vm.expectRevert(IHookrRootEvents.Unauthorized.selector);
        this.launchExternal(address(root), address(rules), 120);
        _assertExistingPoolLive(family, existing, quote);
    }

    function testReadmissionIsTimelocked() public {
        registry.deactivateLauncher(address(launcher));
        // Idempotent.
        vm.prank(guardianAccount);
        registry.deactivateLauncher(address(launcher));
        vm.prank(trader);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.deactivateLauncher(address(launcher));
        bytes32 op = registry.operationHash(registry.SET_LAUNCHER(), abi.encode(address(launcher), true));
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, op));
        registry.setLauncher(address(launcher), true);
        registry.queue(registry.SET_LAUNCHER(), abi.encode(address(launcher), true));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setLauncher(address(launcher), true);
        _launchOn(address(root), address(rules), 60);
    }

    /// The guardian cannot be replaced or removed without notice, by the owner or anyone else.
    function testGuardianReplacementStaysTimelocked() public {
        address next = address(0x6A7E);
        bytes32 op = registry.operationHash(registry.SET_GUARDIAN(), abi.encode(next));
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, op));
        registry.setGuardian(next);
        vm.prank(guardianAccount);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.setGuardian(next);
        assertEq(registry.guardian(), guardianAccount);
    }
}
