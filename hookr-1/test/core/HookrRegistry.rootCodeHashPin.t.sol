// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {GovernanceSecurityBase} from "../utils/GovernanceSecurityBase.sol";

/// @dev EIP-1967-style proxy whose admin sits outside the registry.
contract CodeHashProxy {
    bytes32 internal constant IMPL = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    address public immutable admin;

    constructor(address impl, address admin_) {
        admin = admin_;
        assembly ("memory-safe") { sstore(IMPL, impl) }
    }

    function setImplementation(address impl) external {
        require(msg.sender == admin, "admin");
        assembly ("memory-safe") { sstore(IMPL, impl) }
    }

    fallback() external payable {
        assembly {
            let impl := sload(IMPL)
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}

/// @notice F-008: `REGISTER_ROOT` named an address only, so a proxy at a flag-valid address that delegated to the
///         canonical `HookrRoot` passed every wiring probe and was registered; its admin could later swap the
///         implementation and hold LP principal (`launcher.withdraw` reverted `V8_RANSOM`).
/// @dev The operation now carries the expected runtime codehash and executes only if the root's code still hashes
///      to it. The reviewed canonical hash cannot admit the proxy, and code changed after queueing is refused.
contract HookrRegistryRootCodeHashPinTest is GovernanceSecurityBase {
    address internal constant PARTNER = address(0xA11CE);

    function setUp() public {
        _setUpPeriphery();
    }

    function _mineProxy(address impl) internal returns (CodeHashProxy proxy) {
        bytes32 h = keccak256(abi.encodePacked(type(CodeHashProxy).creationCode, abi.encode(impl, PARTNER)));
        for (uint256 i = 7_000_000;; ++i) {
            address p = vm.computeCreate2Address(bytes32(i), h, address(this));
            if (uint160(p) & 0x3fff == 0x2acc) return new CodeHashProxy{salt: bytes32(i)}(impl, PARTNER);
        }
    }

    /// The proxy reports the canonical root's wiring and flags, so only the codehash separates it.
    function testProxyRefusedUnderTheCanonicalCodeHash() public {
        address p = address(_mineProxy(address(root)));
        assertEq(address(HookrRoot(p).poolManager()), address(manager));
        assertEq(address(HookrRoot(p).registry()), address(registry));
        assertEq(HookrRoot(p).PERMISSION_FLAGS(), uint160(p) & 0x3fff);
        bytes32 canonical = address(root).codehash;
        bytes32 register = registry.REGISTER_ROOT();
        // Old: REGISTER_ROOT(p) queued, executed after the delay, and the root was open.
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.CodeHashMismatch.selector, p));
        registry.queue(register, abi.encode(p, canonical));
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.CodeHashMismatch.selector, p));
        registry.registerRoot(p, canonical);
        assertFalse(registry.isRoot(p));
    }

    /// The queue event publishes the pinned codehash, so reviewers compare it with the reviewed build.
    function testQueueEventPublishesThePinnedCodeHash() public {
        HookrRoot second = _secondRoot();
        bytes32 codeHash = address(second).codehash;
        vm.recordLogs();
        registry.queue(registry.REGISTER_ROOT(), abi.encode(address(second), codeHash));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bytes memory published,,) = abi.decode(logs[0].data, (bytes, uint48, uint48));
        (address rootArg, bytes32 hashArg) = abi.decode(published, (address, bytes32));
        assertEq(rootArg, address(second));
        assertEq(hashArg, codeHash);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.registerRoot(address(second), codeHash);
        assertTrue(registry.isRoot(address(second)) && registry.rootOpen(address(second)));
    }

    /// Code that changes between queue and execution does not execute.
    function testCodeChangedAfterQueueRefusedAtExecution() public {
        HookrRoot second = _secondRoot();
        bytes32 codeHash = address(second).codehash;
        registry.queue(registry.REGISTER_ROOT(), abi.encode(address(second), codeHash));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.etch(address(second), address(_mineProxy(address(root))).code);
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.CodeHashMismatch.selector, address(second)));
        registry.registerRoot(address(second), codeHash);
        assertFalse(registry.isRoot(address(second)));
    }

    /// An EIP-7702 delegation designator is refused even when the queued hash is the designator's own.
    function testDelegationDesignatorRefused() public {
        uint256 pk = 0xF008;
        address e = vm.addr(pk);
        vm.etch(e, abi.encodePacked(hex"ef0100", address(root)));
        assertEq(e.code.length, 23);
        bytes32 register = registry.REGISTER_ROOT();
        bytes32 designatorHash = e.codehash;
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.DelegatedAccount.selector, e));
        registry.queue(register, abi.encode(e, designatorHash));
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.DelegatedAccount.selector, e));
        registry.registerRoot(e, designatorHash);
    }

    /// The single-address shape is no longer canonical.
    function testAddressOnlyShapeRefused() public {
        HookrRoot second = _secondRoot();
        bytes32 register = registry.REGISTER_ROOT();
        vm.expectRevert();
        registry.queue(register, abi.encode(address(second)));
        bytes memory padded = bytes.concat(abi.encode(address(second), address(second).codehash), bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NonCanonicalArguments.selector, register));
        registry.queue(register, padded);
    }
}
