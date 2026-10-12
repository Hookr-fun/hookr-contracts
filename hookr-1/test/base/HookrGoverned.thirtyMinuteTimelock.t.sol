// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {HookrRegistry} from "../../src/core/HookrRegistry.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrGoverned} from "../../src/interfaces/IHookrGoverned.sol";
import {HookrCompliance} from "../../src/compliance/HookrCompliance.sol";
import {HookrFeeAdvisory} from "../../src/extensions/HookrFeeAdvisory.sol";
import {HookrLiquidityVault} from "../../src/extensions/HookrLiquidityVault.sol";
import {HookrSessionAdvisory} from "../../src/extensions/HookrSessionAdvisory.sol";
import {HookrPaymaster} from "../../src/gasless/HookrPaymaster.sol";
import {HookrTreasury} from "../../src/support/HookrTreasury.sol";
import {IHookrTreasury} from "../../src/interfaces/IHookrTreasury.sol";
import {MockEntryPoint} from "../gasless/GaslessMocks.sol";
import {GovernanceSecurityBase} from "../utils/GovernanceSecurityBase.sol";

/// @notice Owner decision: every owner timelock is a short fixed wait of 30 minutes. The registry's and
///         HookrGoverned's MIN_DELAY are 30 minutes, the release deploys both at exactly that, and the treasury's
///         TARGET_DELAY is 30 minutes. At each boundary one second before readiness reverts and readiness executes;
///         the registry's own boundary is in HookrRegistry.minDelay.t.sol. A brake still holds for a full delay.
contract ThirtyMinuteTimelockTest is GovernanceSecurityBase {
    uint48 internal constant WAIT = 30 minutes;
    bytes32 internal constant LIST = keccak256("hookr.list.kyc");

    function setUp() public {
        _setUpPeriphery();
    }

    /// The brake holds for a full 30 minutes: RESUME_NEW_MARKETS is queueable only while paused, so the pause
    /// cannot be lifted sooner than 30 minutes after it was applied.
    function test_registry_brakeHoldsThirtyMinutes() public {
        HookrRegistry r = new HookrRegistry(address(this), manager, WAIT);
        r.pauseNewMarkets();
        uint256 brakedAt = vm.getBlockTimestamp();
        r.queue(r.RESUME_NEW_MARKETS(), "");
        vm.warp(brakedAt + WAIT - 1);
        vm.expectPartialRevert(IHookrRegistry.NotReady.selector);
        r.resumeNewMarkets();
        assertTrue(r.newMarketsPaused());
        vm.warp(brakedAt + WAIT);
        r.resumeNewMarkets();
        assertFalse(r.newMarketsPaused());
    }

    /// Every HookrGoverned contract inherits the one bound: 30 minutes less one second is refused, 30 minutes is not.
    function test_governed_everyContractRefusesLessThanThirtyMinutes() public {
        address ep = address(new MockEntryPoint());
        HookrSessionAdvisory session = new HookrSessionAdvisory(address(this), WAIT);
        assertEq(session.MIN_DELAY(), WAIT);
        assertEq(session.delay(), WAIT);
        assertEq(new HookrCompliance(address(this), WAIT).delay(), WAIT);
        assertEq(new HookrFeeAdvisory(address(this), WAIT, registry, address(session)).delay(), WAIT);
        assertEq(new HookrLiquidityVault(manager, address(0x7E), address(this), WAIT, 0).delay(), WAIT);
        assertEq(new HookrPaymaster(ep, address(0), address(this), WAIT, address(0x7E)).delay(), WAIT);
        bytes memory refused = abi.encodeWithSelector(IHookrGoverned.InvalidDelay.selector, WAIT - 1);
        vm.expectRevert(refused);
        new HookrSessionAdvisory(address(this), WAIT - 1);
        vm.expectRevert(refused);
        new HookrCompliance(address(this), WAIT - 1);
        vm.expectRevert(refused);
        new HookrFeeAdvisory(address(this), WAIT - 1, registry, address(session));
        vm.expectRevert(refused);
        new HookrLiquidityVault(manager, address(0x7E), address(this), WAIT - 1, 0);
        vm.expectRevert(refused);
        new HookrPaymaster(ep, address(0), address(this), WAIT - 1, address(0x7E));
    }

    function test_governed_executesAtThirtyMinutesNotASecondEarlier() public {
        HookrCompliance c = new HookrCompliance(address(this), WAIT);
        bytes32 op = c.queue(c.CREATE_LIST(), abi.encode(LIST));
        uint256 queuedAt = vm.getBlockTimestamp();
        assertEq(c.readyAt(op), queuedAt + WAIT);
        vm.warp(queuedAt + WAIT - 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NotReady.selector, op, uint48(queuedAt + WAIT)));
        c.createList(LIST);
        vm.warp(queuedAt + WAIT);
        c.createList(LIST);
        assertTrue(c.list(LIST).exists);
    }

    /// A guardian's suspension voids a resume queued before it, and the resume queued after it waits a full
    /// 30 minutes.
    function test_governed_brakeHoldsThirtyMinutes() public {
        HookrCompliance c = new HookrCompliance(address(this), WAIT);
        address guardian = makeAddr("guardian");
        c.queue(c.CREATE_LIST(), abi.encode(LIST));
        c.queue(c.GRANT_GUARDIAN(), abi.encode(guardian));
        vm.warp(vm.getBlockTimestamp() + WAIT);
        c.createList(LIST);
        c.grantGuardian(guardian);
        vm.prank(guardian);
        c.suspendList(LIST);
        c.queue(c.RESUME_LIST(), abi.encode(LIST));
        vm.warp(vm.getBlockTimestamp() + WAIT);
        // Pre-armed: the matured resume is voided by a second suspension.
        vm.prank(guardian);
        c.suspendList(LIST);
        uint256 brakedAt = vm.getBlockTimestamp();
        vm.expectPartialRevert(IHookrGoverned.NotReady.selector);
        c.resumeList(LIST);
        c.queue(c.RESUME_LIST(), abi.encode(LIST));
        vm.warp(brakedAt + WAIT - 1);
        vm.expectPartialRevert(IHookrGoverned.NotReady.selector);
        c.resumeList(LIST);
        assertTrue(c.list(LIST).suspended);
        vm.warp(brakedAt + WAIT);
        c.resumeList(LIST);
        assertFalse(c.list(LIST).suspended);
    }

    function test_treasury_targetMovesAtThirtyMinutesNotASecondEarlier() public {
        HookrTreasury t = new HookrTreasury(address(this), address(0xBEEF), manager);
        assertEq(t.TARGET_DELAY(), WAIT);
        t.proposeTarget(address(0xBAD));
        uint256 readyAt = vm.getBlockTimestamp() + WAIT;
        assertEq(t.targetReadyAt(), readyAt);
        vm.warp(readyAt - 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrTreasury.TargetNotReady.selector, address(0xBAD), readyAt));
        t.acceptTarget();
        assertEq(t.target(), address(0xBEEF));
        vm.warp(readyAt);
        t.acceptTarget();
        assertEq(t.target(), address(0xBAD));
    }
}
