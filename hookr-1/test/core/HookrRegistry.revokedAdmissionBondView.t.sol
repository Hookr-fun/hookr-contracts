// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {HookrRegistry} from "../../src/core/HookrRegistry.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {MockModuleBond} from "../mocks/MockModuleBond.sol";

/// @dev Any contract with code: the registry only needs its PoolManager to hold code.
contract BondViewManagerStub {}

/// @dev A root as REGISTER_ROOT probes it: registry, PoolManager and permission flags equal to its address bits.
contract BondViewRootStub {
    address public immutable registry;
    address public immutable poolManager;

    constructor(address registry_, address manager_) {
        registry = registry_;
        poolManager = manager_;
    }

    function PERMISSION_FLAGS() external view returns (uint160) {
        return uint160(address(this)) & 0x3fff;
    }
}

/// @dev A Rules module as the registry sees it: code and the root it reports.
contract BondViewModuleStub {
    address public immutable trustedRoot;

    constructor(address root_) {
        trustedRoot = root_;
    }
}

/// @notice REG-03: `findBondForAdmission` kept reporting a bond that covers after the admission was revoked for good,
///         since a revoke deletes the admission but not its permanent bond record, so an app or indexer showed a
///         backed, covered admission where `admission()` read empty and `isRevokedAdmission` was true. `covering` now
///         also needs the admission to be live; the bond record stays readable.
contract HookrRegistryRevokedAdmissionBondViewTest is Test {
    bytes32 internal constant SET_ADMISSION_BOND = keccak256("SET_ADMISSION_BOND");
    HookrRegistry internal registry;
    BondViewRootStub internal root;
    BondViewModuleStub internal module;
    MockModuleBond internal bond;

    function _execute(bytes32 kind, bytes memory arguments) internal {
        registry.queue(kind, arguments);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
    }

    function _rulesAdmission(address implementation) internal view returns (IHookrRegistry.Admission memory) {
        return IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.RULES,
            implementation: implementation,
            codeHash: implementation.codehash,
            schemaHash: keccak256("test.module.v1"),
            caps: HookrTypes.Caps(600_000, 200_000, 1000),
            gasLimit: 2_000_000,
            phaseMask: 3,
            feeOnly: false,
            failOpen: false
        });
    }

    function setUp() public {
        vm.warp(1_800_000_000);
        address manager = address(new BondViewManagerStub());
        registry = HookrRegistry(
            deployCode("HookrRegistry.sol:HookrRegistry", abi.encode(address(this), manager, uint48(1 days)))
        );
        root = new BondViewRootStub(address(registry), manager);
        _execute(registry.REGISTER_ROOT(), abi.encode(address(root), address(root).codehash));
        registry.registerRoot(address(root), address(root).codehash);
        module = new BondViewModuleStub(address(root));
        _execute(registry.ADMIT(), abi.encode(address(root), _rulesAdmission(address(module))));
        registry.admit(address(root), _rulesAdmission(address(module)));
        bond = new MockModuleBond();
        bond.setCovered(address(root), address(module), true);
        _execute(SET_ADMISSION_BOND, abi.encode(address(root), address(module), address(bond)));
        registry.pinModuleBondFor(address(root), address(module), address(bond));
    }

    function _assertBondView(address bondRef, bool covering) internal view {
        (address reported, bool covers) = registry.findBondForAdmission(address(root), address(module));
        assertEq(reported, bondRef, "bond record");
        assertEq(covers, covering, "covering");
    }

    /// The PoC: after a revoke the view reports the bond record but no longer as covering, matching `admission()`.
    function test_bondViewReportsNoCoverAfterTheAdmissionsRevoke() public {
        _assertBondView(address(bond), true);
        registry.revokeModuleAdmission(address(root), address(module));
        assertTrue(registry.isRevokedAdmission(address(root), address(module)));
        assertEq(registry.admission(address(root), address(module)).implementation, address(0));
        _assertBondView(address(bond), false);
        // The bond still answers that it covers: the view now reads the admission first.
        assertTrue(bond.covers(address(root), address(module)));
    }

    /// Before a revoke the view follows the bond, as `admission()` does.
    function test_bondViewFollowsTheBondWhileTheAdmissionIsLive() public {
        bond.setCovered(address(root), address(module), false);
        _assertBondView(address(bond), false);
        assertEq(registry.admission(address(root), address(module)).implementation, address(0));
        bond.setCovered(address(root), address(module), true);
        _assertBondView(address(bond), true);
        assertEq(registry.admission(address(root), address(module)).implementation, address(module));
    }

    /// An admission without a bond, live or revoked, reports none.
    function test_unbondedAdmissionReportsNoBond() public {
        BondViewModuleStub plain = new BondViewModuleStub(address(root));
        _execute(registry.ADMIT(), abi.encode(address(root), _rulesAdmission(address(plain))));
        registry.admit(address(root), _rulesAdmission(address(plain)));
        (address reported, bool covers) = registry.findBondForAdmission(address(root), address(plain));
        assertEq(reported, address(0));
        assertFalse(covers);
        registry.revokeModuleAdmission(address(root), address(plain));
        (reported, covers) = registry.findBondForAdmission(address(root), address(plain));
        assertEq(reported, address(0));
        assertFalse(covers);
    }
}
