// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {GovernanceSecurityBase} from "../utils/GovernanceSecurityBase.sol";

/// @dev Reports the canonical wiring but has no `PERMISSION_FLAGS` getter.
contract FlaglessRoot {
    address public immutable poolManager;
    address public immutable registry;

    constructor(address manager_, address registry_) {
        poolManager = manager_;
        registry = registry_;
    }
}

/// @notice F-018: registration never compared a root's hook-permission bits with its declared flags; the
///         constructor check does not run for code placed without it, so the canonical runtime at an address with
///         other flag bits (0x0acc drops the initialise guard, 0x28cc the removal lock) was registered under the
///         canonical codehash.
/// @dev The registry reads `PERMISSION_FLAGS()` and requires it to equal the address's low 14 bits, at queue and
///      execution; a missing getter is refused.
contract HookrRegistryRootPermissionFlagsTest is GovernanceSecurityBase {
    function setUp() public {
        _setUpPeriphery();
    }

    function _cloneAt(uint160 flags) internal returns (address clone) {
        clone = address(uint160(uint256(keccak256(abi.encode("f018", flags)))) & ~uint160(0x3fff) | flags);
        vm.etch(clone, address(root).code);
        assertEq(clone.codehash, address(root).codehash);
        assertEq(HookrRoot(clone).PERMISSION_FLAGS(), 0x2acc);
    }

    function _expectRefused(address candidate) internal {
        bytes32 register = registry.REGISTER_ROOT();
        bytes32 codeHash = candidate.codehash;
        // Old: queued and registered after the delay.
        vm.expectRevert(IHookrRegistry.InvalidRoot.selector);
        registry.queue(register, abi.encode(candidate, codeHash));
        vm.expectRevert(IHookrRegistry.InvalidRoot.selector);
        registry.registerRoot(candidate, codeHash);
        assertFalse(registry.isRoot(candidate));
    }

    function testCanonicalRuntimeWithoutInitializeGuardBitRefused() public {
        _expectRefused(_cloneAt(0x0acc));
    }

    function testCanonicalRuntimeWithoutRemovalLockBitRefused() public {
        _expectRefused(_cloneAt(0x28cc));
    }

    function testMissingFlagsGetterRefused() public {
        _expectRefused(address(new FlaglessRoot(address(manager), address(registry))));
    }

    /// The canonical runtime at its declared flag address still registers.
    function testMatchingFlagsRegister() public {
        address clone = _cloneAt(0x2acc);
        bytes32 codeHash = clone.codehash;
        registry.queue(registry.REGISTER_ROOT(), abi.encode(clone, codeHash));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.registerRoot(clone, codeHash);
        assertTrue(registry.isRoot(clone));
    }
}
