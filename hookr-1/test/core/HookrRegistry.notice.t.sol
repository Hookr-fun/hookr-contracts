// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {HookrLauncher} from "../../src/periphery/HookrLauncher.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {GovernanceSecurityBase} from "../utils/GovernanceSecurityBase.sol";

/// @notice L-14: queued registry operations were opaque hashes that never expired, and admissions could be
///         pre-queued for roots and Rules that did not exist yet.
/// @dev Original exploit (base b7aeae64, ReproGovernance.testL14_PrequeuedAdmissionForUndeployedRootAndRules):
///      an ADMIT for a CREATE2-predicted root and a CREATE-predicted Rules was queued, `OperationQueued` carried
///      2 topics and 32 data bytes (readyAt only), the operation sat for 3,650 days, and then root creation,
///      registration, Rules deployment, admission and a funded launch all happened in one block.
contract HookrRegistryNoticeTest is GovernanceSecurityBase {
    bytes32 private constant QUEUED_TOPIC = keccak256("OperationQueued(bytes32,bytes32,bytes,uint48,uint48)");

    function setUp() public {
        _setUpPeriphery();
    }

    /// Replays the original pre-queue: both the undeployed root and the undeployed Rules are refused at queue time.
    function testPrequeueForUndeployedRootAndRulesRefused() public {
        (bytes32 salt, address predictedRoot) = _rootSalt(address(router), address(quoter), address(0));
        // The root takes this contract's next nonce; the Rules the one after it.
        address predictedRules = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        uint256 snap = vm.snapshotState();
        new HookrRoot{salt: salt}(manager, registry, address(router), address(quoter), address(0));
        HookrRules probe = new HookrRules(manager, registry, protocol, predictedRoot, 0);
        assertEq(address(probe), predictedRules);
        bytes32 rulesHash = address(probe).codehash;
        bytes32 schema = probe.configSchemaHash();
        vm.revertToState(snap);
        assertEq(predictedRoot.code.length, 0);
        assertEq(predictedRules.code.length, 0);
        IHookrRegistry.Admission memory a = _rulesAdmission(predictedRules, rulesHash, schema);
        bytes32 admit = registry.ADMIT();
        bytes32 register = registry.REGISTER_ROOT();

        // The admission names a root that is not registered (and has no code): refused.
        vm.expectRevert(IHookrRegistry.InvalidRoot.selector);
        registry.queue(admit, abi.encode(predictedRoot, a));
        // The root registration names an address without code: refused.
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotAContract.selector, predictedRoot));
        registry.queue(register, abi.encode(predictedRoot, bytes32(0)));

        // Even after the root exists and is registered, the Rules must exist before its admission is queued.
        HookrRoot deployedRoot =
            new HookrRoot{salt: salt}(manager, registry, address(router), address(quoter), address(0));
        registry.queue(register, abi.encode(address(deployedRoot), address(deployedRoot).codehash));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.registerRoot(address(deployedRoot), address(deployedRoot).codehash);
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotAContract.selector, predictedRules));
        registry.queue(admit, abi.encode(predictedRoot, a));
    }

    /// The queue log now carries the kind and the exact ABI arguments, decodable without the calldata.
    function testQueueEventDisclosesKindArgumentsAndExpiry() public {
        HookrLauncher next = new HookrLauncher(manager, registry);
        bytes memory args = abi.encode(address(next), true);
        bytes32 kind = registry.SET_LAUNCHER();
        vm.recordLogs();
        bytes32 op = registry.queue(kind, args);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        // Old: 2 topics and 32 data bytes (readyAt only).
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], QUEUED_TOPIC);
        assertEq(logs[0].topics[1], op);
        assertEq(logs[0].topics[2], kind);
        (bytes memory published, uint48 readyAt, uint48 expiresAt) = abi.decode(logs[0].data, (bytes, uint48, uint48));
        assertEq(published, args);
        (address launcherArg, bool active) = abi.decode(published, (address, bool));
        assertEq(launcherArg, address(next));
        assertTrue(active);
        assertEq(readyAt, vm.getBlockTimestamp() + registry.delay());
        assertEq(expiresAt, readyAt + registry.GRACE_PERIOD());
        assertEq(registry.expiresAt(op), expiresAt);
        assertEq(op, registry.operationHash(kind, args));
    }

    /// Old: a matured operation stayed executable forever (3,650 days in the PoC). Now it expires after the grace period.
    function testMaturedOperationExpires() public {
        HookrLauncher next = new HookrLauncher(manager, registry);
        bytes memory args = abi.encode(address(next), true);
        bytes32 op = registry.queue(registry.SET_LAUNCHER(), args);
        uint48 eta = registry.readyAt(op);
        vm.warp(uint256(eta) + registry.GRACE_PERIOD() + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IHookrRegistry.OperationExpired.selector, op, eta + registry.GRACE_PERIOD())
        );
        registry.setLauncher(address(next), true);
        assertFalse(registry.isLauncher(address(next)));
        vm.warp(vm.getBlockTimestamp() + 3650 days);
        vm.expectRevert(
            abi.encodeWithSelector(IHookrRegistry.OperationExpired.selector, op, eta + registry.GRACE_PERIOD())
        );
        registry.setLauncher(address(next), true);
        // An expired operation must be published again and wait the full delay again.
        registry.queue(registry.SET_LAUNCHER(), args);
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, op));
        registry.setLauncher(address(next), true);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setLauncher(address(next), true);
        assertTrue(registry.isLauncher(address(next)));
    }

    /// The last second of the grace period still executes.
    function testExecutesUntilTheEndOfGrace() public {
        HookrLauncher next = new HookrLauncher(manager, registry);
        bytes32 op = registry.queue(registry.SET_LAUNCHER(), abi.encode(address(next), true));
        vm.warp(uint256(registry.readyAt(op)) + registry.GRACE_PERIOD());
        registry.setLauncher(address(next), true);
        assertTrue(registry.isLauncher(address(next)));
        assertEq(registry.readyAt(op), 0);
    }

    /// Arguments that the executing function would not re-derive are refused, so a published operation always
    /// corresponds to exactly one executable call.
    function testNonCanonicalAndUnknownOperationsRefused() public {
        bytes32 kind = registry.SET_LAUNCHER();
        bytes memory padded = bytes.concat(abi.encode(address(launcher), false), bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NonCanonicalArguments.selector, kind));
        registry.queue(kind, padded);
        bytes32 unknown = keccak256("SET_FACTORY");
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.UnknownOperation.selector, unknown));
        registry.queue(unknown, abi.encode(address(launcher), true));
        bytes32 resume = registry.RESUME_NEW_MARKETS();
        vm.expectRevert(IHookrRegistry.NewMarketsNotPaused.selector);
        registry.queue(resume, "");
    }
}
