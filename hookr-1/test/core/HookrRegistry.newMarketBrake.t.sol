// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {GovernanceSecurityBase} from "../utils/GovernanceSecurityBase.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";

/// @notice L-15: there was no instant way to stop new markets. freezeRoot only sealed admissions, and retiring a
///         root or removing a launcher waited the full timelock.
/// @dev Original exploit (base b7aeae64, ReproGovernance.testL15_FreezeDoesNotStopLaunchesAndRetireIsDelayed):
///      after freezeRoot and a queued RETIRE_ROOT, 2 funded markets were opened on the admitted Rules (one at
///      delay - 1 s). The fix is a guardian/owner brake that only stops new pool initialisation and launches.
contract HookrRegistryNewMarketBrakeTest is GovernanceSecurityBase {
    using PoolIdLibrary for PoolKey;

    address internal guardianAccount = address(0x6A7D);

    function setUp() public {
        _setUpPeriphery();
        registry.queue(registry.SET_GUARDIAN(), abi.encode(guardianAccount));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setGuardian(guardianAccount);
    }

    function testGuardianBrakeStopsNewMarketsAtOnce() public {
        (bytes32 family, PoolKey memory existing,, Currency quote) = _launch(true, false);
        registry.freezeRoot(address(root));
        registry.queue(registry.RETIRE_ROOT(), abi.encode(address(root)));

        vm.prank(guardianAccount);
        registry.pauseNewMarkets();
        assertTrue(registry.newMarketsPaused());
        assertFalse(registry.rootOpen(address(root)));
        assertTrue(registry.isRoot(address(root)));

        // Old: this launch and one at delay - 1 s both succeeded.
        vm.expectRevert(IHookrLauncher.InvalidFamily.selector);
        this.launchExternal(address(root), address(rules), 60);
        vm.warp(vm.getBlockTimestamp() + registry.delay() - 1);
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

        // Existing pools keep trading, claims stay payable and the LP can exit.
        IHookrRouter.Swap memory buy = _swap(existing, true, true, 1e18);
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

    function testOnlyOwnerOrGuardianCanPause() public {
        vm.prank(trader);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.pauseNewMarkets();
        registry.pauseNewMarkets();
        assertTrue(registry.newMarketsPaused());
        // Idempotent for either brake holder.
        vm.prank(guardianAccount);
        registry.pauseNewMarkets();
        assertTrue(registry.newMarketsPaused());
    }

    function testResumeIsTimelockedAndOnlyQueuedWhilePaused() public {
        bytes32 resume = registry.RESUME_NEW_MARKETS();
        vm.expectRevert(IHookrRegistry.NewMarketsNotPaused.selector);
        registry.queue(resume, "");
        vm.prank(guardianAccount);
        registry.pauseNewMarkets();
        // The guardian cannot lift it, and the owner cannot lift it without notice.
        vm.prank(guardianAccount);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.resumeNewMarkets();
        bytes32 op = registry.operationHash(resume, "");
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, op));
        registry.resumeNewMarkets();
        registry.queue(resume, "");
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.resumeNewMarkets();
        assertFalse(registry.newMarketsPaused());
        assertTrue(registry.rootOpen(address(root)));
        _launchOn(address(root), address(rules), 60);
    }

    /// The PoC's workaround (a RETIRE_ROOT pre-armed 400 days earlier) no longer stays armed: operations expire.
    function testPreArmedRetirementExpiresBrakeReplacesIt() public {
        bytes32 op = registry.queue(registry.RETIRE_ROOT(), abi.encode(address(root)));
        uint48 eta = registry.readyAt(op);
        vm.warp(vm.getBlockTimestamp() + 400 days);
        vm.expectRevert(
            abi.encodeWithSelector(IHookrRegistry.OperationExpired.selector, op, eta + registry.GRACE_PERIOD())
        );
        registry.retireRoot(address(root));
        registry.pauseNewMarkets();
        vm.expectRevert(IHookrLauncher.InvalidFamily.selector);
        this.launchExternal(address(root), address(rules), 120);
    }

    /// Removing the guardian is itself timelocked; the owner keeps the brake.
    function testGuardianRemovalIsTimelocked() public {
        registry.queue(registry.SET_GUARDIAN(), abi.encode(address(0)));
        vm.prank(guardianAccount);
        registry.pauseNewMarkets();
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setGuardian(address(0));
        assertEq(registry.guardian(), address(0));
        registry.queue(registry.RESUME_NEW_MARKETS(), "");
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.resumeNewMarkets();
        vm.prank(guardianAccount);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.pauseNewMarkets();
    }
}
