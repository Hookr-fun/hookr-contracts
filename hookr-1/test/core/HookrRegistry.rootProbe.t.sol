// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {GovernanceSecurityBase} from "../utils/GovernanceSecurityBase.sol";

/// @dev A root candidate whose `poolManager()` answers in one of several malformed ways.
contract OddRoot {
    uint256 internal constant SHORT = 1;
    uint256 internal constant DIRTY = 2;
    uint256 internal constant REVERTS = 3;
    uint256 internal constant EMPTY = 4;
    address internal immutable manager;
    address public immutable registry;
    uint256 internal immutable mode;

    constructor(address manager_, address registry_, uint256 mode_) {
        manager = manager_;
        registry = registry_;
        mode = mode_;
    }

    function poolManager() external view returns (address) {
        address m = manager;
        uint256 how = mode;
        assembly ("memory-safe") {
            mstore(0, m)
            if eq(how, 1) { return(12, 20) }
            if eq(how, 2) {
                mstore(0, or(m, shl(160, 1)))
                return(0, 32)
            }
            if eq(how, 3) { revert(0, 0) }
            if eq(how, 4) { return(0, 0) }
        }
        return m;
    }

    function PERMISSION_FLAGS() external view returns (uint160) {
        return uint160(address(this)) & 0x3fff;
    }
}

/// @notice F-048: the root identity probe used typed high-level calls, so a short return, dirty high bits or an
///         empty return reverted inside the registry with no reason instead of reading as an incompatible root.
/// @dev Probes are bounded static calls that treat any malformed answer as `InvalidRoot`, at queue and execution.
contract HookrRegistryRootProbeTest is GovernanceSecurityBase {
    function setUp() public {
        _setUpPeriphery();
    }

    function _expectInvalid(uint256 mode) internal {
        OddRoot odd = new OddRoot(address(manager), address(registry), mode);
        bytes32 register = registry.REGISTER_ROOT();
        bytes32 codeHash = address(odd).codehash;
        // Old: the typed call reverted with empty data (or bubbled the root's revert).
        vm.expectRevert(IHookrRegistry.InvalidRoot.selector);
        registry.queue(register, abi.encode(address(odd), codeHash));
        vm.expectRevert(IHookrRegistry.InvalidRoot.selector);
        registry.registerRoot(address(odd), codeHash);
    }

    function testShortReturnReadsAsInvalidRoot() public {
        _expectInvalid(1);
    }

    function testDirtyHighBitsReadAsInvalidRoot() public {
        _expectInvalid(2);
    }

    function testRevertReadsAsInvalidRoot() public {
        _expectInvalid(3);
    }

    function testEmptyReturnReadsAsInvalidRoot() public {
        _expectInvalid(4);
    }

    /// A well-formed candidate with the same shape passes the probe.
    function testWellFormedCandidateRegisters() public {
        OddRoot fine = new OddRoot(address(manager), address(registry), 0);
        bytes32 codeHash = address(fine).codehash;
        registry.queue(registry.REGISTER_ROOT(), abi.encode(address(fine), codeHash));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.registerRoot(address(fine), codeHash);
        assertTrue(registry.isRoot(address(fine)));
    }

    /// A candidate that reports another registry is refused.
    function testForeignRegistryRefused() public {
        OddRoot foreign = new OddRoot(address(manager), address(0xBEEF), 0);
        bytes32 register = registry.REGISTER_ROOT();
        bytes32 codeHash = address(foreign).codehash;
        vm.expectRevert(IHookrRegistry.InvalidRoot.selector);
        registry.queue(register, abi.encode(address(foreign), codeHash));
    }
}
