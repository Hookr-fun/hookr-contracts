// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrLanes} from "../../src/interfaces/IHookrLanes.sol";
import {LaneExecutorStub} from "../utils/LaneExecutorStub.sol";

/// @notice The registry's per-(root, executor) lane switch, which the root reads on every swap of a pool that froze the
///         executor: an opening turns it on at the opening's gas cap; the owner or the guardian switches it off, or
///         lowers its cap, at once, reaching every open pool that froze it and refusing every opening or switch-on of
///         it queued until then; switching it on and raising its cap is a `LANE_ON` operation through the timelock,
///         bounded 50,000 to 5,000,000, allowed on frozen and retired roots since it only restores open pools. No
///         brake points a pool at another executor.
contract RegistryLaneSwitchTest is PeripheryFixture {
    bytes32 internal constant OPEN_LANE = keccak256("OPEN_LANE");
    uint32 internal constant GAS = 600_000;
    /// @dev The share the cases open the lane at: WTH's production share, 25%, the registry's cap (RegistryLanes
    ///      covers the shares below it and the refused 2,501).
    uint16 internal constant PARTNER_BPS = 2_500;
    address internal guardianAccount = address(0x6A7D);
    address internal stranger = address(0x5757);
    LaneExecutorStub internal exec;

    function setUp() public {
        _setUpPeriphery();
        registry.queue(registry.SET_GUARDIAN(), abi.encode(guardianAccount));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setGuardian(guardianAccount);
        exec = new LaneExecutorStub(PARTNER_BPS);
    }

    function _queue(address e, uint32 g, uint16 b) internal returns (bytes32) {
        return registry.queue(OPEN_LANE, abi.encode(address(root), e, e.codehash, g, b));
    }

    function _open(address e, uint32 g, uint16 b) internal {
        _queue(e, g, b);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.openLaneOf(address(root), e, e.codehash, g, b);
    }

    function _assertLane(address e, uint32 g, uint16 b) internal view {
        (address executor, bytes32 codeHash, uint32 gasCap, uint16 partnerBps) = registry.activeLaneOf(address(root));
        assertEq(executor, e, "executor");
        assertEq(codeHash, e == address(0) ? bytes32(0) : e.codehash, "codeHash");
        assertEq(gasCap, g, "gasCap");
        assertEq(partnerBps, b, "partnerBps");
    }

    function _assertNoLane() internal view {
        _assertLane(address(0), 0, 0);
    }

    function _retire() internal {
        registry.queue(registry.RETIRE_ROOT(), abi.encode(address(root)));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.retireRoot(address(root));
    }

    // ───────────────────────────── executor switch ─────────────────────────────

    bytes32 internal constant LANE_ON = keccak256("LANE_ON");

    function _assertSwitch(address e, bool on, uint32 g) internal view {
        (bool isOn, uint32 gasCap) = registry.executorLane(address(root), e);
        assertEq(isOn, on, "switch");
        assertEq(gasCap, g, "switch gasCap");
    }

    function _queueOn(address e, uint32 g) internal returns (bytes32) {
        return registry.queue(LANE_ON, abi.encode(address(root), e, g));
    }

    function _switchOn(address e, uint32 g) internal {
        _queueOn(e, g);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.startExecutorLaneAt(address(root), e, g);
    }

    function test_switch_neverOpenedReadsZeros() public view {
        _assertSwitch(address(exec), false, 0);
    }

    function test_switch_openingTurnsTheExecutorOnAtTheOpeningCap() public {
        _queue(address(exec), 3_000_000, PARTNER_BPS);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.expectEmit(true, true, true, true, address(registry));
        emit IHookrLanes.ExecutorLaneSet(address(root), address(exec), true, 3_000_000, address(this));
        registry.openLaneOf(address(root), address(exec), address(exec).codehash, 3_000_000, PARTNER_BPS);
        _assertSwitch(address(exec), true, 3_000_000);
        _assertLane(address(exec), 3_000_000, PARTNER_BPS);
    }

    function test_switch_stopIsImmediateForOwnerOrGuardianOnly() public {
        _open(address(exec), GAS, PARTNER_BPS);
        vm.prank(stranger);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.stopExecutorLane(address(root), address(exec));
        vm.expectEmit(true, true, true, true, address(registry));
        emit IHookrLanes.ExecutorLaneSet(address(root), address(exec), false, GAS, guardianAccount);
        vm.prank(guardianAccount);
        registry.stopExecutorLane(address(root), address(exec));
        _assertSwitch(address(exec), false, GAS);
        // New pools cannot freeze a stopped executor either.
        _assertNoLane();
        registry.stopExecutorLane(address(root), address(exec));
        _assertSwitch(address(exec), false, GAS);
    }

    function test_switch_stopRefusesAnUnregisteredRoot() public {
        vm.prank(guardianAccount);
        vm.expectRevert(IHookrRegistry.InvalidRoot.selector);
        registry.stopExecutorLane(address(0xBEEF), address(exec));
        vm.prank(guardianAccount);
        vm.expectRevert(IHookrRegistry.InvalidRoot.selector);
        registry.tuneExecutorLane(address(0xBEEF), address(exec), 60_000);
    }

    /// A close stops new pools only; the executor's switch, which open pools read, stays on until a stop.
    function test_switch_closeLeavesOpenPoolsOn_stopReachesThem() public {
        _open(address(exec), GAS, PARTNER_BPS);
        vm.prank(guardianAccount);
        registry.closeLaneOf(address(root));
        _assertNoLane();
        _assertSwitch(address(exec), true, GAS);
        vm.prank(guardianAccount);
        registry.stopExecutorLane(address(root), address(exec));
        _assertSwitch(address(exec), false, GAS);
    }

    /// A replaced executor keeps its switch for the pools that froze it; stopping it does not touch the new lane.
    function test_switch_isPerExecutor() public {
        _open(address(exec), GAS, PARTNER_BPS);
        LaneExecutorStub next = new LaneExecutorStub(PARTNER_BPS);
        _open(address(next), 900_000, PARTNER_BPS);
        _assertSwitch(address(exec), true, GAS);
        _assertSwitch(address(next), true, 900_000);
        vm.prank(guardianAccount);
        registry.stopExecutorLane(address(root), address(exec));
        _assertSwitch(address(exec), false, GAS);
        _assertSwitch(address(next), true, 900_000);
        _assertLane(address(next), 900_000, PARTNER_BPS);
    }

    function test_switch_onOnlyThroughTheTimelock_ownerOnly() public {
        _open(address(exec), GAS, PARTNER_BPS);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(guardianAccount);
        registry.stopExecutorLane(address(root), address(exec));
        vm.warp(vm.getBlockTimestamp() + 1);
        bytes memory args = abi.encode(address(root), address(exec), uint32(3_000_000));
        bytes32 op = registry.operationHash(LANE_ON, args);
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, op));
        registry.startExecutorLaneAt(address(root), address(exec), 3_000_000);
        vm.prank(guardianAccount);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.queue(LANE_ON, args);
        registry.queue(LANE_ON, args);
        vm.warp(vm.getBlockTimestamp() + registry.delay() - 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, op));
        registry.startExecutorLaneAt(address(root), address(exec), 3_000_000);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(guardianAccount);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.startExecutorLaneAt(address(root), address(exec), 3_000_000);
        vm.expectEmit(true, true, true, true, address(registry));
        emit IHookrLanes.ExecutorLaneSet(address(root), address(exec), true, 3_000_000, address(this));
        registry.startExecutorLaneAt(address(root), address(exec), 3_000_000);
        _assertSwitch(address(exec), true, 3_000_000);
        _assertLane(address(exec), 3_000_000, PARTNER_BPS);
        // Consumed once.
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, op));
        registry.startExecutorLaneAt(address(root), address(exec), 3_000_000);
    }

    function test_switch_onQueuedAtOrBeforeTheBrakeIsRefused() public {
        _open(address(exec), GAS, PARTNER_BPS);
        bytes32 early = _queueOn(address(exec), 3_000_000);
        vm.prank(guardianAccount);
        registry.stopExecutorLane(address(root), address(exec));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.QueuedBeforeBrake.selector, early));
        registry.startExecutorLaneAt(address(root), address(exec), 3_000_000);
        _assertSwitch(address(exec), false, GAS);
        registry.cancel(early);
        _switchOn(address(exec), 3_000_000);
        _assertSwitch(address(exec), true, 3_000_000);
    }

    function test_switch_openingQueuedBeforeTheBrakeIsRefused() public {
        // Even for an executor never opened: the brake blocks its pending opening.
        bytes32 op = _queue(address(exec), GAS, PARTNER_BPS);
        vm.prank(guardianAccount);
        registry.stopExecutorLane(address(root), address(exec));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.QueuedBeforeBrake.selector, op));
        registry.openLaneOf(address(root), address(exec), address(exec).codehash, GAS, PARTNER_BPS);
        _assertNoLane();
        _assertSwitch(address(exec), false, 0);
        vm.warp(vm.getBlockTimestamp() + 1);
        registry.cancel(op);
        _open(address(exec), GAS, PARTNER_BPS);
        _assertSwitch(address(exec), true, GAS);
    }

    function test_switch_brakeHoldsForAtLeastOneFullDelay() public {
        _open(address(exec), GAS, PARTNER_BPS);
        vm.prank(guardianAccount);
        registry.stopExecutorLane(address(root), address(exec));
        uint256 stoppedAt = vm.getBlockTimestamp();
        vm.warp(stoppedAt + 1);
        bytes32 op = _queueOn(address(exec), GAS);
        vm.warp(stoppedAt + registry.delay());
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, op));
        registry.startExecutorLaneAt(address(root), address(exec), GAS);
        vm.warp(stoppedAt + 1 + registry.delay());
        registry.startExecutorLaneAt(address(root), address(exec), GAS);
        _assertSwitch(address(exec), true, GAS);
    }

    function test_tune_lowersAtOnce_raisesOnlyThroughTheTimelock() public {
        _open(address(exec), 3_000_000, PARTNER_BPS);
        bytes32 early = _queueOn(address(exec), 5_000_000);
        vm.prank(stranger);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.tuneExecutorLane(address(root), address(exec), 600_000);
        vm.expectEmit(true, true, true, true, address(registry));
        emit IHookrLanes.ExecutorLaneSet(address(root), address(exec), true, 600_000, guardianAccount);
        vm.prank(guardianAccount);
        registry.tuneExecutorLane(address(root), address(exec), 600_000);
        _assertSwitch(address(exec), true, 600_000);
        _assertLane(address(exec), 600_000, PARTNER_BPS);
        // Only lower, never below the floor.
        vm.prank(guardianAccount);
        vm.expectRevert(IHookrRegistry.InvalidLane.selector);
        registry.tuneExecutorLane(address(root), address(exec), 600_000);
        vm.prank(guardianAccount);
        vm.expectRevert(IHookrRegistry.InvalidLane.selector);
        registry.tuneExecutorLane(address(root), address(exec), 49_999);
        registry.tuneExecutorLane(address(root), address(exec), 50_000);
        _assertSwitch(address(exec), true, 50_000);
        // A raise queued before the brake is refused; one queued after it executes.
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.QueuedBeforeBrake.selector, early));
        registry.startExecutorLaneAt(address(root), address(exec), 5_000_000);
        registry.cancel(early);
        _switchOn(address(exec), 5_000_000);
        _assertSwitch(address(exec), true, 5_000_000);
    }

    function test_tune_keepsAStoppedExecutorOff() public {
        _open(address(exec), GAS, PARTNER_BPS);
        vm.startPrank(guardianAccount);
        registry.stopExecutorLane(address(root), address(exec));
        registry.tuneExecutorLane(address(root), address(exec), 100_000);
        vm.stopPrank();
        _assertSwitch(address(exec), false, 100_000);
        _assertNoLane();
    }

    function test_tune_refusesAnExecutorNeverOpened() public {
        vm.prank(guardianAccount);
        vm.expectRevert(IHookrRegistry.InvalidLane.selector);
        registry.tuneExecutorLane(address(root), address(exec), 60_000);
    }

    function test_switchOn_bounds() public {
        bytes memory invalid = abi.encodeWithSelector(IHookrRegistry.InvalidLane.selector);
        // Never opened on the root.
        vm.expectRevert(invalid);
        registry.queue(LANE_ON, abi.encode(address(root), address(exec), uint32(GAS)));
        _open(address(exec), GAS, PARTNER_BPS);
        vm.expectRevert(invalid);
        registry.queue(LANE_ON, abi.encode(address(root), address(exec), uint32(49_999)));
        vm.expectRevert(invalid);
        registry.queue(LANE_ON, abi.encode(address(root), address(exec), uint32(5_000_001)));
        vm.expectRevert(IHookrRegistry.InvalidRoot.selector);
        registry.queue(LANE_ON, abi.encode(address(0xBEEF), address(exec), uint32(GAS)));
        bytes memory args = abi.encode(address(root), address(exec), uint32(GAS));
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NonCanonicalArguments.selector, LANE_ON));
        registry.queue(LANE_ON, abi.encodePacked(args, uint256(0)));
        _queueOn(address(exec), 50_000);
        _queueOn(address(exec), 5_000_000);
    }

    function testFuzz_switchOn_bounds(uint32 gasCap) public {
        _open(address(exec), GAS, PARTNER_BPS);
        bool valid = gasCap >= 50_000 && gasCap <= 5_000_000;
        if (!valid) vm.expectRevert(IHookrRegistry.InvalidLane.selector);
        registry.queue(LANE_ON, abi.encode(address(root), address(exec), gasCap));
    }

    /// The switch only restores or shrinks pools already open, so it works on frozen and retired roots.
    function test_switch_worksOnFrozenAndRetiredRoots() public {
        _open(address(exec), GAS, PARTNER_BPS);
        registry.freezeRoot(address(root));
        vm.prank(guardianAccount);
        registry.stopExecutorLane(address(root), address(exec));
        vm.warp(vm.getBlockTimestamp() + 1);
        _switchOn(address(exec), 3_000_000);
        _assertSwitch(address(exec), true, 3_000_000);
        _retire();
        vm.prank(guardianAccount);
        registry.tuneExecutorLane(address(root), address(exec), 1_000_000);
        _assertSwitch(address(exec), true, 1_000_000);
        vm.warp(vm.getBlockTimestamp() + 1);
        _switchOn(address(exec), 2_000_000);
        _assertSwitch(address(exec), true, 2_000_000);
    }
}
