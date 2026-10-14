// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {HookrRegistry} from "../../src/core/HookrRegistry.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";

/// @dev A swap gate as the registry sees it: code it pins and never calls.
contract GateStub {
    function vouch() external pure returns (bool) {
        return true;
    }
}

/// @dev The same gate with other runtime code, to model a codehash drift at its address.
contract GateStubV2 {
    function vouch() external pure returns (bool) {
        return false;
    }
}

/// @dev A Rules module that reports the fixture's root, to open a part scope.
contract GateChainStub {
    address public immutable trustedRoot;

    constructor(address root_) {
        trustedRoot = root_;
    }
}

/// @dev A root factory as the registry sees it.
contract GateFactoryStub {}

/// @notice GATE admissions: per root, a contract that may vouch for a swap's payer before the router unlocks the
///         PoolManager. The registry admits one only for an active root, with zero caps, no phases, 25,000 to 200,000
///         gas, neither fee-only nor fail-open, its codehash pinned and the schema `keccak256("IHookrSwapGate")`. A gate
///         is inert until its queued ADMIT executes, a root's freeze seals its gates, the module brake withdraws one,
///         and the root never binds a gate as a pool's Rules or advisory, since it asks the registry for those kinds
///         only.
contract RegistryGatesTest is PeripheryFixture {
    bytes32 internal constant GATE_SCHEMA = keccak256("IHookrSwapGate");
    address internal guardian = address(0x6A7D);

    function setUp() public {
        _setUpPeriphery();
        registry.queue(registry.SET_GUARDIAN(), abi.encode(guardian));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setGuardian(guardian);
    }

    function _gate(address implementation) internal view returns (IHookrRegistry.Admission memory a) {
        a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.GATE,
            implementation: implementation,
            codeHash: implementation.codehash,
            schemaHash: GATE_SCHEMA,
            caps: HookrTypes.Caps(0, 0, 0),
            gasLimit: 100_000,
            phaseMask: 0,
            feeOnly: false,
            failOpen: false
        });
    }

    function _admit(address scope, IHookrRegistry.Admission memory a) internal {
        registry.queue(registry.ADMIT(), abi.encode(scope, a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(scope, a);
    }

    function _expectRefused(address scope, IHookrRegistry.Admission memory a, bytes memory reason) internal {
        bytes32 kind = registry.ADMIT();
        bytes memory arguments = abi.encode(scope, a);
        vm.expectRevert(reason);
        registry.queue(kind, arguments);
    }

    function _invalid() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IHookrRegistry.InvalidAdmission.selector);
    }

    function _assertNoGate(address gate) internal view {
        IHookrRegistry.Admission memory got = registry.admission(address(root), gate);
        assertEq(got.implementation, address(0), "no admission");
        assertEq(got.codeHash, bytes32(0), "no codehash");
    }

    /// GATE is the third kind, so every Admission encoding and selector stays as it was; an admitted gate reads back
    /// with every term and logs its kind.
    function test_gateIsAdmittedForAnActiveRoot() public {
        assertEq(uint8(IHookrRegistry.Kind.RULES), 0);
        assertEq(uint8(IHookrRegistry.Kind.ADVISORY), 1);
        assertEq(uint8(IHookrRegistry.Kind.GATE), 2);
        GateStub gate = new GateStub();
        IHookrRegistry.Admission memory a = _gate(address(gate));
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.expectEmit(true, true, true, true, address(registry));
        emit IHookrRegistry.ModuleAdmitted(
            address(root), address(gate), IHookrRegistry.Kind.GATE, address(gate).codehash
        );
        registry.admit(address(root), a);
        IHookrRegistry.Admission memory got = registry.admission(address(root), address(gate));
        assertEq(uint8(got.kind), uint8(IHookrRegistry.Kind.GATE));
        assertEq(got.implementation, address(gate));
        assertEq(got.codeHash, address(gate).codehash);
        assertEq(got.schemaHash, GATE_SCHEMA);
        assertEq(got.gasLimit, 100_000);
        assertEq(got.phaseMask, 0);
        assertFalse(got.feeOnly);
        assertFalse(got.failOpen);
    }

    /// A gate is inert until its queued ADMIT executes: queued, matured or cancelled, the registry reports no gate, so
    /// its consumer (the router's gated swap) refuses it.
    function test_gateIsInertUntilItsAdmitExecutes() public {
        GateStub gate = new GateStub();
        IHookrRegistry.Admission memory a = _gate(address(gate));
        bytes32 operation = registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        _assertNoGate(address(gate));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        _assertNoGate(address(gate));
        registry.cancel(operation);
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, operation));
        registry.admit(address(root), a);
        _assertNoGate(address(gate));

        _admit(address(root), a);
        assertEq(registry.admission(address(root), address(gate)).implementation, address(gate));
    }

    /// The gas bounds are inclusive at both ends.
    function test_gateGasBounds() public {
        GateStub low = new GateStub();
        GateStub high = new GateStub();
        IHookrRegistry.Admission memory a = _gate(address(low));
        a.gasLimit = 25_000;
        IHookrRegistry.Admission memory b = _gate(address(high));
        b.gasLimit = 200_000;
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        registry.queue(registry.ADMIT(), abi.encode(address(root), b));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
        registry.admit(address(root), b);

        GateStub other = new GateStub();
        a = _gate(address(other));
        a.gasLimit = 24_999;
        _expectRefused(address(root), a, _invalid());
        a.gasLimit = 200_001;
        _expectRefused(address(root), a, _invalid());
        a.gasLimit = 2_000_000;
        _expectRefused(address(root), a, _invalid());
    }

    /// Every other term of a gate is fixed: zero caps, no phases, neither fee-only nor fail-open, the gate schema and
    /// the pinned codehash of code that is not an EIP-7702 delegation.
    function test_gateTermsAreFixed() public {
        GateStub gate = new GateStub();
        IHookrRegistry.Admission memory a;
        a = _gate(address(gate));
        a.caps.maxLpFeePips = 1;
        _expectRefused(address(root), a, _invalid());
        a = _gate(address(gate));
        a.caps.maxQuoteTakePips = 1;
        _expectRefused(address(root), a, _invalid());
        a = _gate(address(gate));
        a.caps.maxSubjectTakeBps = 1;
        _expectRefused(address(root), a, _invalid());
        a = _gate(address(gate));
        a.phaseMask = HookrTypes.BEFORE_SWAP;
        _expectRefused(address(root), a, _invalid());
        a = _gate(address(gate));
        a.phaseMask = 3;
        _expectRefused(address(root), a, _invalid());
        a = _gate(address(gate));
        a.feeOnly = true;
        _expectRefused(address(root), a, _invalid());
        a = _gate(address(gate));
        a.failOpen = true;
        _expectRefused(address(root), a, _invalid());
        a = _gate(address(gate));
        a.feeOnly = true;
        a.failOpen = true;
        _expectRefused(address(root), a, _invalid());
        a = _gate(address(gate));
        a.schemaHash = keccak256("IHookrAdvisory");
        _expectRefused(address(root), a, _invalid());
        a = _gate(address(gate));
        a.schemaHash = bytes32(0);
        _expectRefused(address(root), a, _invalid());
        a = _gate(address(gate));
        a.codeHash = keccak256("other code");
        _expectRefused(address(root), a, _invalid());
        a = _gate(address(0xC0FFEE));
        _expectRefused(
            address(root), a, abi.encodeWithSelector(IHookrRegistry.NotAContract.selector, address(0xC0FFEE))
        );
        address delegated = address(0xDE1E);
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(gate)));
        a = _gate(delegated);
        _expectRefused(address(root), a, abi.encodeWithSelector(IHookrRegistry.DelegatedAccount.selector, delegated));
    }

    /// A root factory's scope admits ADVISORY only, and a part scope RULES only, so neither admits a gate; nor does an
    /// address that is no scope.
    function test_gateNeedsAnActiveRootScope() public {
        GateStub gate = new GateStub();
        GateFactoryStub factory = new GateFactoryStub();
        registry.queue(registry.SET_ROOT_FACTORY(), abi.encode(address(factory), address(factory).codehash, true));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setRootFactory(address(factory), address(factory).codehash, true);
        _expectRefused(address(factory), _gate(address(gate)), _invalid());

        GateChainStub chain = new GateChainStub(address(root));
        IHookrRegistry.Admission memory rulesAdmission = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.RULES,
            implementation: address(chain),
            codeHash: address(chain).codehash,
            schemaHash: keccak256("test.chain.v1"),
            caps: HookrTypes.Caps(600_000, 200_000, 1000),
            gasLimit: 2_000_000,
            phaseMask: 3,
            feeOnly: false,
            failOpen: false
        });
        _admit(address(root), rulesAdmission);
        (bool eligible,) = registry.partScopeEligible(address(chain));
        assertTrue(eligible);
        _expectRefused(address(chain), _gate(address(gate)), _invalid());

        _expectRefused(
            address(0xABCD), _gate(address(gate)), abi.encodeWithSelector(IHookrRegistry.InvalidRoot.selector)
        );
    }

    /// Freezing the root seals its gates, including one queued before the freeze; the module brake withdraws an
    /// admitted gate for good, and no admission of it executes again.
    function test_freezeSealsAndTheBrakeWithdrawsGates() public {
        GateStub kept = new GateStub();
        GateStub queued = new GateStub();
        _admit(address(root), _gate(address(kept)));
        registry.queue(registry.ADMIT(), abi.encode(address(root), _gate(address(queued))));

        vm.prank(guardian);
        registry.revokeModuleAdmission(address(root), address(kept));
        _assertNoGate(address(kept));
        assertTrue(registry.isRevokedAdmission(address(root), address(kept)));
        _expectRefused(address(root), _gate(address(kept)), _invalid());

        registry.freezeRoot(address(root));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.expectRevert(IHookrRegistry.RootFrozen.selector);
        registry.admit(address(root), _gate(address(queued)));
        _expectRefused(
            address(root), _gate(address(new GateStub())), abi.encodeWithSelector(IHookrRegistry.RootFrozen.selector)
        );
    }

    /// A gate whose code changes keeps its pinned codehash, which the gate's consumer compares with the live code; the
    /// same address cannot be admitted again with the new code.
    function test_codeChangedGateKeepsItsPinnedCodeHash() public {
        GateStub gate = new GateStub();
        bytes32 pinned = address(gate).codehash;
        _admit(address(root), _gate(address(gate)));
        vm.etch(address(gate), address(new GateStubV2()).code);
        IHookrRegistry.Admission memory got = registry.admission(address(root), address(gate));
        assertEq(got.codeHash, pinned);
        assertTrue(address(gate).codehash != pinned);
        _expectRefused(
            address(root), _gate(address(gate)), abi.encodeWithSelector(IHookrRegistry.AlreadyAdmitted.selector)
        );
    }

    /// The root binds a pool's Rules and advisory only from admissions of those kinds: a gate is never a pool module.
    function test_rootNeverBindsAGateAsAPoolModule() public {
        GateStub gate = new GateStub();
        _admit(address(root), _gate(address(gate)));
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(0)));
        members[0].config.rules = address(gate);
        IHookrLauncher.Token memory token = IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0));
        uint256 deadline = vm.getBlockTimestamp();
        vm.expectRevert(abi.encodeWithSelector(IHookrRootEvents.InvalidModule.selector, gate));
        launcher.launch{value: 1e24}(token, address(root), members, deadline);

        members[0] = _member(Currency.wrap(address(0)));
        members[0].config.advisory = address(gate);
        members[0].config.advisoryGasLimit = 100_000;
        members[0].config.advisoryPhases = HookrTypes.BEFORE_SWAP;
        bytes[] memory configs = new bytes[](1);
        vm.expectRevert(abi.encodeWithSelector(IHookrRootEvents.InvalidModule.selector, gate));
        launcher.launchAdvised{value: 1e24}(token, address(root), members, configs, deadline);
    }

    /// IHookrRegistry declares guardian(), so periphery reads the brake account through the interface.
    function test_guardianIsDeclaredOnTheInterface() public {
        assertEq(IHookrRegistry(address(registry)).guardian(), guardian);
        assertEq(IHookrRegistry.guardian.selector, HookrRegistry.guardian.selector);
        registry.removeGuardian();
        assertEq(IHookrRegistry(address(registry)).guardian(), address(0));
    }
}
