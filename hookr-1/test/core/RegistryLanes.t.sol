// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {HookrRegistry} from "../../src/core/HookrRegistry.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrLanes} from "../../src/interfaces/IHookrLanes.sol";
import {MockIdleExecutor} from "../mocks/MockIdleExecutor.sol";
import {LaneExecutorStub, LaneExecutorStubV2} from "../utils/LaneExecutorStub.sol";

/// @dev An executor whose reported share can change after it is queued.
contract MutableRateExecutor {
    uint16 public partnerBps;

    constructor(uint16 rate_) {
        partnerBps = rate_;
    }

    function setPartnerBps(uint16 rate_) external {
        partnerBps = rate_;
    }
}

/// @notice The registry's recapture lane slot: a timelocked, codehash-pinned `OPEN_LANE` per root, checked when queued
///         and again when executed, a brake that closes it at once and outlives every opening queued before it, and a
///         view that reads zeros once the lane is closed, its executor's code drifts or its switch is off; and the
///         per-(root, executor) switch open pools read on every swap: off or lowered at once by the owner or the
///         guardian, on or raised only through a `LANE_ON` queued after the last brake, bounded 50,000 to 5,000,000.
///         The executor's own `partnerBps()` is never read.
contract RegistryLanesTest is PeripheryFixture {
    bytes32 internal constant OPEN_LANE = keccak256("OPEN_LANE");
    uint32 internal constant GAS = 600_000;
    /// @dev The share the cases open the lane at: WTH's production share, 25%, the registry's cap. Shares below it
    ///      (0, 800, 900, 1,000, 1,500) and the refused 2,501 are named where a case tests them.
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

    // ───────────────────────────── helpers ─────────────────────────────

    function _args(address r, address e, bytes32 h, uint32 g, uint16 b) internal pure returns (bytes memory) {
        return abi.encode(r, e, h, g, b);
    }

    function _queue(address e, uint32 g, uint16 b) internal returns (bytes32) {
        return registry.queue(OPEN_LANE, _args(address(root), e, e.codehash, g, b));
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

    function _expectQueueRevert(bytes memory reason, address e, bytes32 h, uint32 g, uint16 b) internal {
        vm.expectRevert(reason);
        registry.queue(OPEN_LANE, _args(address(root), e, h, g, b));
    }

    function _retire() internal {
        registry.queue(registry.RETIRE_ROOT(), abi.encode(address(root)));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.retireRoot(address(root));
    }

    // ───────────────────────────── opening ─────────────────────────────

    function test_open_setsTheLaneOnlyAfterTheDelay() public {
        _assertNoLane();
        bytes32 op = _queue(address(exec), GAS, PARTNER_BPS);
        assertEq(
            op,
            registry.operationHash(
                OPEN_LANE, _args(address(root), address(exec), address(exec).codehash, GAS, PARTNER_BPS)
            )
        );
        uint48 eta = registry.readyAt(op);
        assertEq(eta, vm.getBlockTimestamp() + registry.delay());
        vm.warp(uint256(eta) - 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, op));
        registry.openLaneOf(address(root), address(exec), address(exec).codehash, GAS, PARTNER_BPS);
        _assertNoLane();
        vm.warp(eta);
        vm.expectEmit(true, true, true, true, address(registry));
        emit IHookrLanes.LaneOpened(address(root), address(exec), address(exec).codehash, GAS, PARTNER_BPS);
        registry.openLaneOf(address(root), address(exec), address(exec).codehash, GAS, PARTNER_BPS);
        _assertLane(address(exec), GAS, PARTNER_BPS);
        assertEq(registry.readyAt(op), 0);
    }

    function test_open_executesUntilTheLastSecondOfGrace() public {
        bytes32 op = _queue(address(exec), GAS, PARTNER_BPS);
        vm.warp(uint256(registry.expiresAt(op)));
        registry.openLaneOf(address(root), address(exec), address(exec).codehash, GAS, PARTNER_BPS);
        _assertLane(address(exec), GAS, PARTNER_BPS);
    }

    function test_open_expiresPastGrace() public {
        bytes32 op = _queue(address(exec), GAS, PARTNER_BPS);
        uint48 expiry = registry.expiresAt(op);
        vm.warp(uint256(expiry) + 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.OperationExpired.selector, op, expiry));
        registry.openLaneOf(address(root), address(exec), address(exec).codehash, GAS, PARTNER_BPS);
        _assertNoLane();
        // An expired opening may be queued again, for a full delay.
        _open(address(exec), GAS, PARTNER_BPS);
        _assertLane(address(exec), GAS, PARTNER_BPS);
    }

    function test_open_isConsumedOnce() public {
        _open(address(exec), GAS, PARTNER_BPS);
        bytes32 op = registry.operationHash(
            OPEN_LANE, _args(address(root), address(exec), address(exec).codehash, GAS, PARTNER_BPS)
        );
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, op));
        registry.openLaneOf(address(root), address(exec), address(exec).codehash, GAS, PARTNER_BPS);
    }

    function test_open_isOwnerOnly() public {
        bytes memory args = _args(address(root), address(exec), address(exec).codehash, GAS, PARTNER_BPS);
        vm.prank(guardianAccount);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.queue(OPEN_LANE, args);
        registry.queue(OPEN_LANE, args);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.prank(guardianAccount);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.openLaneOf(address(root), address(exec), address(exec).codehash, GAS, PARTNER_BPS);
        vm.prank(stranger);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.openLaneOf(address(root), address(exec), address(exec).codehash, GAS, PARTNER_BPS);
    }

    function test_open_executesOnlyTheQueuedArguments() public {
        _queue(address(exec), GAS, PARTNER_BPS);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        bytes32 other = registry.operationHash(
            OPEN_LANE, _args(address(root), address(exec), address(exec).codehash, GAS + 1, PARTNER_BPS)
        );
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, other));
        registry.openLaneOf(address(root), address(exec), address(exec).codehash, GAS + 1, PARTNER_BPS);
    }

    function test_queue_refusesNonCanonicalArguments() public {
        bytes memory args = _args(address(root), address(exec), address(exec).codehash, GAS, PARTNER_BPS);
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NonCanonicalArguments.selector, OPEN_LANE));
        registry.queue(OPEN_LANE, abi.encodePacked(args, uint256(0)));
        // A gas cap word with bits above uint32 does not decode.
        bytes memory dirty =
            abi.encode(address(root), address(exec), address(exec).codehash, uint256(1) << 32 | GAS, PARTNER_BPS);
        vm.expectRevert();
        registry.queue(OPEN_LANE, dirty);
    }

    function test_open_replacesTheLaneWithNoGap() public {
        _open(address(exec), GAS, PARTNER_BPS);
        LaneExecutorStub next = new LaneExecutorStub(800);
        _queue(address(next), 900_000, 800);
        // The live lane stays while the replacement waits out the delay.
        _assertLane(address(exec), GAS, PARTNER_BPS);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.openLaneOf(address(root), address(next), address(next).codehash, 900_000, 800);
        _assertLane(address(next), 900_000, 800);
    }

    function test_open_allowedOnAClosedRootAwaitingReopening() public {
        vm.prank(guardianAccount);
        registry.closeRoot(address(root));
        _open(address(exec), GAS, PARTNER_BPS);
        _assertLane(address(exec), GAS, PARTNER_BPS);
    }

    // ───────────────────────────── refusals ─────────────────────────────

    function test_refuses_anExecutorWithoutCode() public {
        address eoa = address(0xE0A);
        _expectQueueRevert(
            abi.encodeWithSelector(IHookrRegistry.NotAContract.selector, eoa), eoa, bytes32(0), GAS, PARTNER_BPS
        );
        _expectQueueRevert(
            abi.encodeWithSelector(IHookrRegistry.NotAContract.selector, eoa), eoa, keccak256(""), GAS, PARTNER_BPS
        );
    }

    function test_refuses_aDelegatedExecutor() public {
        address delegated = address(0xDE1E);
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(exec)));
        _expectQueueRevert(
            abi.encodeWithSelector(IHookrRegistry.DelegatedAccount.selector, delegated),
            delegated,
            delegated.codehash,
            GAS,
            PARTNER_BPS
        );
    }

    function test_refuses_anExecutorThatBecomesDelegatedBeforeExecution() public {
        MutableRateExecutor e = new MutableRateExecutor(PARTNER_BPS);
        bytes32 pinned = address(e).codehash;
        _queue(address(e), GAS, PARTNER_BPS);
        vm.etch(address(e), abi.encodePacked(hex"ef0100", address(exec)));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.DelegatedAccount.selector, address(e)));
        registry.openLaneOf(address(root), address(e), pinned, GAS, PARTNER_BPS);
    }

    function test_refuses_aCodeHashMismatch() public {
        _expectQueueRevert(
            abi.encodeWithSelector(IHookrRegistry.CodeHashMismatch.selector, address(exec)),
            address(exec),
            keccak256("other"),
            GAS,
            PARTNER_BPS
        );
        // Code that changes between queueing and execution no longer matches the queued hash.
        bytes32 pinned = address(exec).codehash;
        _queue(address(exec), GAS, PARTNER_BPS);
        vm.etch(address(exec), address(new LaneExecutorStubV2()).code);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.CodeHashMismatch.selector, address(exec)));
        registry.openLaneOf(address(root), address(exec), pinned, GAS, PARTNER_BPS);
    }

    function test_refuses_anUnregisteredRoot() public {
        vm.expectRevert(IHookrRegistry.InvalidRoot.selector);
        registry.queue(OPEN_LANE, _args(address(0xBEEF), address(exec), address(exec).codehash, GAS, PARTNER_BPS));
        vm.expectRevert(IHookrRegistry.InvalidRoot.selector);
        registry.openLaneOf(address(0xBEEF), address(exec), address(exec).codehash, GAS, PARTNER_BPS);
    }

    function test_refuses_aRetiredRoot_whenQueuedAndWhenExecuted() public {
        bytes memory args = _args(address(root), address(exec), address(exec).codehash, GAS, PARTNER_BPS);
        registry.queue(OPEN_LANE, args);
        _retire();
        vm.expectRevert(IHookrRegistry.InvalidRoot.selector);
        registry.openLaneOf(address(root), address(exec), address(exec).codehash, GAS, PARTNER_BPS);
        LaneExecutorStub next = new LaneExecutorStub(PARTNER_BPS);
        _expectQueueRevert(
            abi.encodeWithSelector(IHookrRegistry.InvalidRoot.selector),
            address(next),
            address(next).codehash,
            GAS,
            PARTNER_BPS
        );
    }

    function test_refuses_aFrozenRoot_whenQueuedAndWhenExecuted() public {
        _queue(address(exec), GAS, PARTNER_BPS);
        registry.freezeRoot(address(root));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.expectRevert(IHookrRegistry.RootFrozen.selector);
        registry.openLaneOf(address(root), address(exec), address(exec).codehash, GAS, PARTNER_BPS);
        LaneExecutorStub next = new LaneExecutorStub(PARTNER_BPS);
        _expectQueueRevert(
            abi.encodeWithSelector(IHookrRegistry.RootFrozen.selector),
            address(next),
            address(next).codehash,
            GAS,
            PARTNER_BPS
        );
    }

    function test_refuses_theRootAsItsOwnExecutor() public {
        _expectQueueRevert(
            abi.encodeWithSelector(IHookrRegistry.InvalidLane.selector), address(root), address(root).codehash, GAS, 0
        );
    }

    function test_bounds_gasCap() public {
        bytes memory invalid = abi.encodeWithSelector(IHookrRegistry.InvalidLane.selector);
        _expectQueueRevert(invalid, address(exec), address(exec).codehash, 49_999, PARTNER_BPS);
        _expectQueueRevert(invalid, address(exec), address(exec).codehash, 5_000_001, PARTNER_BPS);
        _expectQueueRevert(invalid, address(exec), address(exec).codehash, 0, PARTNER_BPS);
        _queue(address(exec), 50_000, PARTNER_BPS);
        _queue(address(exec), 5_000_000, PARTNER_BPS);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.openLaneOf(address(root), address(exec), address(exec).codehash, 50_000, PARTNER_BPS);
        _assertLane(address(exec), 50_000, PARTNER_BPS);
        registry.openLaneOf(address(root), address(exec), address(exec).codehash, 5_000_000, PARTNER_BPS);
        _assertLane(address(exec), 5_000_000, PARTNER_BPS);
    }

    function test_bounds_partnerShare() public {
        LaneExecutorStub greedy = new LaneExecutorStub(2_501);
        _expectQueueRevert(
            abi.encodeWithSelector(IHookrRegistry.InvalidLane.selector),
            address(greedy),
            address(greedy).codehash,
            GAS,
            2_501
        );
        LaneExecutorStub none = new LaneExecutorStub(0);
        _open(address(none), GAS, 0);
        _assertLane(address(none), GAS, 0);
        _open(address(exec), GAS, 1_000);
        _assertLane(address(exec), GAS, 1_000);
        _open(address(exec), GAS, 1_500);
        _assertLane(address(exec), GAS, 1_500);
        _open(address(exec), GAS, 2_500);
        _assertLane(address(exec), GAS, 2_500);
    }

    function testFuzz_bounds(uint32 gasCap, uint16 partnerBps) public {
        MutableRateExecutor e = new MutableRateExecutor(partnerBps);
        bool valid = gasCap >= 50_000 && gasCap <= 5_000_000 && partnerBps <= 2_500;
        if (!valid) vm.expectRevert(IHookrRegistry.InvalidLane.selector);
        registry.queue(OPEN_LANE, _args(address(root), address(e), address(e).codehash, gasCap, partnerBps));
    }

    /// The executor's own `partnerBps()` is never read: the queued share is the pinned rate a push is checked against.
    function test_partnerRead_isNeverMade() public {
        // Reports another share.
        _open(address(exec), GAS, 900);
        _assertLane(address(exec), GAS, 900);
        // No partnerBps().
        MockIdleExecutor none = new MockIdleExecutor();
        _open(address(none), GAS, PARTNER_BPS);
        _assertLane(address(none), GAS, PARTNER_BPS);
    }

    function test_partnerRead_aChangedReportDoesNotBlockExecution() public {
        MutableRateExecutor e = new MutableRateExecutor(PARTNER_BPS);
        _queue(address(e), GAS, PARTNER_BPS);
        e.setPartnerBps(PARTNER_BPS - 1);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.record();
        registry.openLaneOf(address(root), address(e), address(e).codehash, GAS, PARTNER_BPS);
        (bytes32[] memory reads,) = vm.accesses(address(e));
        assertEq(reads.length, 0, "the executor's storage is never read");
        _assertLane(address(e), GAS, PARTNER_BPS);
    }

    // ───────────────────────────── brake ─────────────────────────────

    function test_close_isImmediateForOwnerOrGuardianOnly() public {
        _open(address(exec), GAS, PARTNER_BPS);
        vm.prank(stranger);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.closeLaneOf(address(root));
        vm.expectEmit(true, true, true, true, address(registry));
        emit IHookrLanes.LaneClosed(address(root), guardianAccount);
        vm.prank(guardianAccount);
        registry.closeLaneOf(address(root));
        _assertNoLane();
        vm.expectEmit(true, true, true, true, address(registry));
        emit IHookrLanes.LaneClosed(address(root), address(this));
        registry.closeLaneOf(address(root));
        _assertNoLane();
    }

    function test_close_refusesAnUnregisteredRoot() public {
        vm.prank(guardianAccount);
        vm.expectRevert(IHookrRegistry.InvalidRoot.selector);
        registry.closeLaneOf(address(0xBEEF));
    }

    function test_close_refusesOpeningsQueuedBeforeIt() public {
        _open(address(exec), GAS, PARTNER_BPS);
        LaneExecutorStub next = new LaneExecutorStub(PARTNER_BPS);
        // One matured before the brake, one still waiting.
        bytes32 early = _queue(address(next), GAS, PARTNER_BPS);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        bytes32 late = _queue(address(exec), 700_000, PARTNER_BPS);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(guardianAccount);
        registry.closeLaneOf(address(root));
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.LaneQueuedBeforeClose.selector, early));
        registry.openLaneOf(address(root), address(next), address(next).codehash, GAS, PARTNER_BPS);
        vm.warp(uint256(registry.readyAt(late)));
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.LaneQueuedBeforeClose.selector, late));
        registry.openLaneOf(address(root), address(exec), address(exec).codehash, 700_000, PARTNER_BPS);
        _assertNoLane();
    }

    function test_close_withNoLaneOpenStillRefusesQueuedOpenings() public {
        bytes32 op = _queue(address(exec), GAS, PARTNER_BPS);
        vm.prank(guardianAccount);
        registry.closeLaneOf(address(root));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.LaneQueuedBeforeClose.selector, op));
        registry.openLaneOf(address(root), address(exec), address(exec).codehash, GAS, PARTNER_BPS);
    }

    function test_close_refusesAnOpeningQueuedInTheSameSecond() public {
        vm.prank(guardianAccount);
        registry.closeLaneOf(address(root));
        bytes32 op = _queue(address(exec), GAS, PARTNER_BPS);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.LaneQueuedBeforeClose.selector, op));
        registry.openLaneOf(address(root), address(exec), address(exec).codehash, GAS, PARTNER_BPS);
    }

    function test_close_holdsForAtLeastOneFullDelay() public {
        _open(address(exec), GAS, PARTNER_BPS);
        vm.prank(guardianAccount);
        registry.closeLaneOf(address(root));
        uint256 closedAt = vm.getBlockTimestamp();
        vm.warp(closedAt + 1);
        LaneExecutorStub next = new LaneExecutorStub(PARTNER_BPS);
        bytes32 op = _queue(address(next), GAS, PARTNER_BPS);
        vm.warp(closedAt + registry.delay());
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, op));
        registry.openLaneOf(address(root), address(next), address(next).codehash, GAS, PARTNER_BPS);
        _assertNoLane();
        vm.warp(closedAt + 1 + registry.delay());
        registry.openLaneOf(address(root), address(next), address(next).codehash, GAS, PARTNER_BPS);
        _assertLane(address(next), GAS, PARTNER_BPS);
    }

    function test_close_aStaleOpeningMustBeCancelledToQueueAgain() public {
        bytes memory args = _args(address(root), address(exec), address(exec).codehash, GAS, PARTNER_BPS);
        bytes32 op = registry.queue(OPEN_LANE, args);
        vm.prank(guardianAccount);
        registry.closeLaneOf(address(root));
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.AlreadyQueued.selector, op));
        registry.queue(OPEN_LANE, args);
        registry.cancel(op);
        registry.queue(OPEN_LANE, args);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.openLaneOf(address(root), address(exec), address(exec).codehash, GAS, PARTNER_BPS);
        _assertLane(address(exec), GAS, PARTNER_BPS);
    }

    function test_close_survivesALaterOpeningOfAnotherLane() public {
        // An opening queued after the brake executes, but one queued before it stays dead afterwards too.
        LaneExecutorStub next = new LaneExecutorStub(PARTNER_BPS);
        bytes32 stale = _queue(address(exec), GAS, PARTNER_BPS);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(guardianAccount);
        registry.closeLaneOf(address(root));
        vm.warp(vm.getBlockTimestamp() + 1);
        _open(address(next), GAS, PARTNER_BPS);
        _assertLane(address(next), GAS, PARTNER_BPS);
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.LaneQueuedBeforeClose.selector, stale));
        registry.openLaneOf(address(root), address(exec), address(exec).codehash, GAS, PARTNER_BPS);
        _assertLane(address(next), GAS, PARTNER_BPS);
    }

    function test_close_worksOnFrozenAndRetiredRoots_andFreezeSealsOpenings() public {
        _open(address(exec), GAS, PARTNER_BPS);
        registry.freezeRoot(address(root));
        // Freezing keeps the open lane and seals new openings.
        _assertLane(address(exec), GAS, PARTNER_BPS);
        LaneExecutorStub next = new LaneExecutorStub(PARTNER_BPS);
        _expectQueueRevert(
            abi.encodeWithSelector(IHookrRegistry.RootFrozen.selector),
            address(next),
            address(next).codehash,
            GAS,
            PARTNER_BPS
        );
        vm.prank(guardianAccount);
        registry.closeLaneOf(address(root));
        _assertNoLane();
        _retire();
        vm.prank(guardianAccount);
        registry.closeLaneOf(address(root));
        _assertNoLane();
    }

    // ───────────────────────────── drift ─────────────────────────────

    function test_drift_readsZerosWhileTheExecutorCodeDiffers() public {
        _open(address(exec), GAS, PARTNER_BPS);
        bytes memory original = address(exec).code;
        vm.etch(address(exec), address(new LaneExecutorStubV2()).code);
        _assertNoLane();
        // The record is kept: the lane reads again once the pinned code is back.
        vm.etch(address(exec), original);
        _assertLane(address(exec), GAS, PARTNER_BPS);
        // Code removed entirely reads zeros too.
        vm.etch(address(exec), "");
        _assertNoLane();
    }

    function test_drift_toADelegationDesignatorReadsZeros() public {
        _open(address(exec), GAS, PARTNER_BPS);
        vm.etch(address(exec), abi.encodePacked(hex"ef0100", address(new LaneExecutorStub(PARTNER_BPS))));
        _assertNoLane();
    }

    // ───────────────────────────── dispatch ─────────────────────────────

    /// @dev The dispatcher compares selectors in ascending order, so a new selector below a hot one costs every call to
    ///      that one. Every lane selector sorts after every registry read on a launch, swap or pair-root deployment.
    function test_dispatch_laneSelectorsSortAfterEveryOnChainRegistryCall() public pure {
        bytes4[7] memory hot = [
            HookrRegistry.isRoot.selector,
            HookrRegistry.admission.selector,
            HookrRegistry.isQuote.selector,
            HookrRegistry.rootOpen.selector,
            HookrRegistry.isLauncher.selector,
            HookrRegistry.rootFactoryOf.selector,
            HookrRegistry.registerFactoryRoot.selector
        ];
        bytes4[7] memory lane = [
            HookrRegistry.activeLaneOf.selector,
            HookrRegistry.openLaneOf.selector,
            HookrRegistry.closeLaneOf.selector,
            HookrRegistry.executorLane.selector,
            HookrRegistry.stopExecutorLane.selector,
            HookrRegistry.tuneExecutorLane.selector,
            HookrRegistry.startExecutorLaneAt.selector
        ];
        for (uint256 i; i < hot.length; ++i) {
            for (uint256 j; j < lane.length; ++j) {
                assertLt(uint32(hot[i]), uint32(lane[j]));
            }
        }
    }
}
