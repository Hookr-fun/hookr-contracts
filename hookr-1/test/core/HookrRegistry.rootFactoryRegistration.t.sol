// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {GovernanceSecurityBase} from "../utils/GovernanceSecurityBase.sol";

/// @dev Minimal root factory: forwards registration of a root it names.
contract MockRootFactory {
    IHookrRegistry public immutable registry;

    constructor(IHookrRegistry registry_) {
        registry = registry_;
    }

    function register(address root) external {
        registry.registerFactoryRoot(root, address(0));
    }
}

/// @dev A second factory build with different runtime code.
contract OtherRootFactory {
    IHookrRegistry public immutable registry;
    uint256 public constant VERSION = 2;

    constructor(IHookrRegistry registry_) {
        registry = registry_;
    }

    function register(address root) external {
        registry.registerFactoryRoot(root, address(0));
    }
}

/// @dev Reports a foreign registry.
contract ForeignRegistryRoot {
    function registry() external pure returns (address) {
        return address(0xBEEF);
    }
}

/// @notice Root factories: activation is a published, codehash-pinned `SET_ROOT_FACTORY`; an active factory
///         registers and opens the roots it deploys; the owner or guardian deactivates a factory at once.
contract RootFactoryRegistrationTest is GovernanceSecurityBase {
    address internal guardianAccount = address(0x6A7D);
    MockRootFactory internal factory;

    function setUp() public {
        _setUpPeriphery();
        factory = new MockRootFactory(registry);
        registry.queue(registry.SET_GUARDIAN(), abi.encode(guardianAccount));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setGuardian(guardianAccount);
    }

    function _activate(address f) internal {
        bytes32 codeHash = f.codehash;
        registry.queue(registry.SET_ROOT_FACTORY(), abi.encode(f, codeHash, true));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setRootFactory(f, codeHash, true);
    }

    function testActivationIsTimelockedAndPinned() public {
        bytes32 kind = registry.SET_ROOT_FACTORY();
        assertEq(kind, keccak256("SET_ROOT_FACTORY"));
        bytes32 codeHash = address(factory).codehash;
        bytes32 other = address(new OtherRootFactory(registry)).codehash;
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.CodeHashMismatch.selector, address(factory)));
        registry.queue(kind, abi.encode(address(factory), other, true));
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotAContract.selector, address(0xFAC7)));
        registry.queue(kind, abi.encode(address(0xFAC7), codeHash, true));
        vm.expectRevert(IHookrRegistry.InvalidAddress.selector);
        registry.queue(kind, abi.encode(address(0), codeHash, false));
        vm.prank(trader);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.queue(kind, abi.encode(address(factory), codeHash, true));

        bytes32 op = registry.queue(kind, abi.encode(address(factory), codeHash, true));
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, op));
        registry.setRootFactory(address(factory), codeHash, true);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.prank(guardianAccount);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.setRootFactory(address(factory), codeHash, true);
        vm.expectEmit(true, false, false, true, address(registry));
        emit IHookrRegistry.RootFactorySet(address(factory), codeHash, true);
        registry.setRootFactory(address(factory), codeHash, true);
        assertTrue(registry.isRootFactory(address(factory)));
        assertEq(registry.rootFactoryCodeHash(address(factory)), codeHash);
    }

    function testCodeChangedAfterQueueRefusedAtExecution() public {
        bytes32 codeHash = address(factory).codehash;
        registry.queue(registry.SET_ROOT_FACTORY(), abi.encode(address(factory), codeHash, true));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.etch(address(factory), address(new OtherRootFactory(registry)).code);
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.CodeHashMismatch.selector, address(factory)));
        registry.setRootFactory(address(factory), codeHash, true);
        assertFalse(registry.isRootFactory(address(factory)));
    }

    /// A factory whose runtime changed after its activation can no longer register a root: registration re-checks the
    /// code hash the activation pinned. Mutation gate RG-10 (registration trusted the address alone).
    function testChangedFactoryCodeCannotRegisterARoot() public {
        _activate(address(factory));
        HookrRoot second = _secondRoot();
        vm.etch(address(factory), address(new OtherRootFactory(registry)).code);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        OtherRootFactory(address(factory)).register(address(second));
        assertFalse(registry.isRoot(address(second)));
    }

    function testDelegatedFactoryRefused() public {
        address e = vm.addr(0xFAC7);
        vm.etch(e, abi.encodePacked(hex"ef0100", address(factory)));
        bytes32 kind = registry.SET_ROOT_FACTORY();
        bytes32 codeHash = e.codehash;
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.DelegatedAccount.selector, e));
        registry.queue(kind, abi.encode(e, codeHash, true));
    }

    function testActiveFactoryRegistersAndOpensARoot() public {
        _activate(address(factory));
        HookrRoot second = _secondRoot();
        vm.recordLogs();
        factory.register(address(second));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2);
        assertEq(logs[0].topics[0], keccak256("RootRegistered(address)"));
        assertEq(logs[1].topics[0], keccak256("FactoryRootRegistered(address,address)"));
        assertEq(address(uint160(uint256(logs[1].topics[1]))), address(factory));
        assertEq(address(uint160(uint256(logs[1].topics[2]))), address(second));
        assertTrue(registry.isRoot(address(second)));
        assertTrue(registry.rootOpen(address(second)));
        assertFalse(registry.rootFrozen(address(second)));
        // The factory root behaves like any registered root: brakes and retirement reach it.
        registry.pauseNewMarkets();
        assertFalse(registry.rootOpen(address(second)));
    }

    function testRegistrationRequirements() public {
        _activate(address(factory));
        // Unregistered callers, including the owner, are refused.
        HookrRoot second = _secondRoot();
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.registerFactoryRoot(address(second), address(0));
        vm.prank(trader);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.registerFactoryRoot(address(second), address(0));
        // No code.
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotAContract.selector, address(0xDEAD)));
        factory.register(address(0xDEAD));
        // Delegation designator.
        address e = vm.addr(0xE7702);
        vm.etch(e, abi.encodePacked(hex"ef0100", address(root)));
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.DelegatedAccount.selector, e));
        factory.register(e);
        // Reports another registry, or no registry at all.
        address foreign = address(new ForeignRegistryRoot());
        vm.expectRevert(IHookrRegistry.InvalidRoot.selector);
        factory.register(foreign);
        vm.expectRevert(IHookrRegistry.InvalidRoot.selector);
        factory.register(address(tokenA));
        // Already registered.
        vm.expectRevert(IHookrRegistry.InvalidRoot.selector);
        factory.register(address(root));
        factory.register(address(second));
        vm.expectRevert(IHookrRegistry.InvalidRoot.selector);
        factory.register(address(second));
    }

    function testGuardianDeactivatesAFactoryAtOnce() public {
        _activate(address(factory));
        bytes32 codeHash = address(factory).codehash;
        vm.prank(trader);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.deactivateRootFactory(address(factory));
        vm.expectEmit(true, false, false, true, address(registry));
        emit IHookrRegistry.RootFactorySet(address(factory), codeHash, false);
        vm.prank(guardianAccount);
        registry.deactivateRootFactory(address(factory));
        assertFalse(registry.isRootFactory(address(factory)));
        HookrRoot second = _secondRoot();
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        factory.register(address(second));
        // Idempotent; reactivation is timelocked.
        registry.deactivateRootFactory(address(factory));
        bytes32 op = registry.operationHash(registry.SET_ROOT_FACTORY(), abi.encode(address(factory), codeHash, true));
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, op));
        registry.setRootFactory(address(factory), codeHash, true);
        _activate(address(factory));
        factory.register(address(second));
        assertTrue(registry.isRoot(address(second)));
    }

    function testRootFactoryOfTellsFactoryRootsApart() public {
        _activate(address(factory));
        HookrRoot second = _secondRoot();
        // A queued REGISTER_ROOT root and an unregistered address report no factory.
        assertTrue(registry.isRoot(address(root)));
        assertEq(registry.rootFactoryOf(address(root)), address(0));
        assertEq(registry.rootFactoryOf(address(second)), address(0));
        factory.register(address(second));
        assertEq(registry.rootFactoryOf(address(second)), address(factory));
        // The record outlives the factory's deactivation and the root's retirement.
        vm.prank(guardianAccount);
        registry.deactivateRootFactory(address(factory));
        registry.queue(registry.RETIRE_ROOT(), abi.encode(address(second)));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.retireRoot(address(second));
        assertEq(registry.rootFactoryOf(address(second)), address(factory));
    }

    function testTimelockedDeactivation() public {
        _activate(address(factory));
        bytes32 codeHash = address(factory).codehash;
        registry.queue(registry.SET_ROOT_FACTORY(), abi.encode(address(factory), codeHash, false));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setRootFactory(address(factory), codeHash, false);
        assertFalse(registry.isRootFactory(address(factory)));
        assertEq(registry.rootFactoryCodeHash(address(factory)), bytes32(0));
    }
}
