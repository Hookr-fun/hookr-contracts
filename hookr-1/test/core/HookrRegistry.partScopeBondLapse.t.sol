// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {HookrRegistry} from "../../src/core/HookrRegistry.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {MockModuleBond} from "../mocks/MockModuleBond.sol";

/// @dev Any contract with code: the registry only needs its PoolManager to hold code.
contract PartScopeManagerStub {}

/// @dev A root as REGISTER_ROOT probes it: it reports the registry, the PoolManager and permission flags equal to its
///      own address bits, and reports no lane module.
contract PartScopeRootStub {
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

/// @dev A composing Rules module (a rule chain) as the registry sees it: code and the root it reports.
contract PartScopeChainStub {
    address public immutable trustedRoot;

    constructor(address root_) {
        trustedRoot = root_;
    }
}

/// @dev The same module with other runtime code, so its codehash no longer matches its admission.
contract PartScopeChainStubV2 {
    address public immutable trustedRoot;

    constructor(address root_) {
        trustedRoot = root_;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev A part as the registry sees it: any contract with code.
contract PartScopePartStub {}

/// @notice REG-01: the guardian's frozen-root check in `revokeModuleAdmission` took a part scope's root from
///         `partScopeRoot`, which reads zero while the module's admission bond does not cover it (and while the
///         module's codehash differs from its admission's, or the root is retired). During such a lapse the guardian
///         could revoke a part under a frozen root's Rules module for good: once the bond covered again, the freeze
///         refused every replacement. The check now reads the stored RULES admission on the root the module reports,
///         so on a frozen root's part scope only the owner revokes, whatever the bond, the codehash or the lifecycle.
contract HookrRegistryPartScopeBondLapseTest is Test {
    bytes32 internal constant SET_ADMISSION_BOND = keccak256("SET_ADMISSION_BOND");
    address internal guardian = address(0x6A7D);
    HookrRegistry internal registry;
    PartScopeRootStub internal root;
    PartScopeChainStub internal chain;
    PartScopePartStub internal part;
    MockModuleBond internal bond;

    function _execute(bytes32 kind, bytes memory arguments) internal {
        registry.queue(kind, arguments);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
    }

    function _chainAdmission() internal view returns (IHookrRegistry.Admission memory) {
        return IHookrRegistry.Admission({
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
    }

    function _partAdmission(address p) internal view returns (IHookrRegistry.Admission memory) {
        return IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.RULES,
            implementation: p,
            codeHash: p.codehash,
            schemaHash: keccak256("test.part.v1"),
            caps: HookrTypes.Caps(10_000, 5_000, 0),
            gasLimit: 60_000,
            phaseMask: 1,
            feeOnly: false,
            failOpen: false
        });
    }

    /// @dev A root with a guardian, a rule-chain Rules module on it, a part under the module and a bond behind the
    ///      module's own admission. Not frozen: each test freezes, retires or lapses what it needs.
    function setUp() public {
        vm.warp(1_800_000_000);
        address manager = address(new PartScopeManagerStub());
        registry = HookrRegistry(
            deployCode("HookrRegistry.sol:HookrRegistry", abi.encode(address(this), manager, uint48(1 days)))
        );
        root = new PartScopeRootStub(address(registry), manager);
        _execute(registry.REGISTER_ROOT(), abi.encode(address(root), address(root).codehash));
        registry.registerRoot(address(root), address(root).codehash);
        _execute(registry.SET_GUARDIAN(), abi.encode(guardian));
        registry.setGuardian(guardian);

        chain = new PartScopeChainStub(address(root));
        _execute(registry.ADMIT(), abi.encode(address(root), _chainAdmission()));
        registry.admit(address(root), _chainAdmission());
        part = new PartScopePartStub();
        _execute(registry.ADMIT(), abi.encode(address(chain), _partAdmission(address(part))));
        registry.admit(address(chain), _partAdmission(address(part)));
        bond = new MockModuleBond();
        bond.setCovered(address(root), address(chain), true);
        _execute(SET_ADMISSION_BOND, abi.encode(address(root), address(chain), address(bond)));
        registry.pinModuleBondFor(address(root), address(chain), address(bond));
    }

    function _guardianRevokeRefused() internal {
        vm.prank(guardian);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.revokeModuleAdmission(address(chain), address(part));
        assertFalse(registry.isRevokedAdmission(address(chain), address(part)));
    }

    /// The PoC: while the bond covers the guardian is refused, and it stays refused through the lapse, so when the bond
    /// covers again the part is still admitted under the frozen root's module. The owner still revokes it.
    function test_guardianCannotRevokeAFrozenRootsPartDuringABondLapse() public {
        registry.freezeRoot(address(root));
        _guardianRevokeRefused();

        bond.setCovered(address(root), address(chain), false);
        (, address scopeRoot) = registry.partScopeEligible(address(chain));
        assertEq(scopeRoot, address(0), "the lapsed module is no part scope for new admissions");
        _guardianRevokeRefused();

        bond.setCovered(address(root), address(chain), true);
        (, scopeRoot) = registry.partScopeEligible(address(chain));
        assertEq(scopeRoot, address(root));
        assertEq(registry.admission(address(chain), address(part)).implementation, address(part), "part kept");
        bytes32 admit = registry.ADMIT();
        bytes memory again = abi.encode(address(chain), _partAdmission(address(new PartScopePartStub())));
        vm.expectRevert(IHookrRegistry.RootFrozen.selector);
        registry.queue(admit, again);

        registry.revokeModuleAdmission(address(chain), address(part));
        assertTrue(registry.isRevokedAdmission(address(chain), address(part)));
    }

    /// A module whose runtime code no longer matches its admission is no part scope for new admissions either, and the
    /// guardian is still refused under the frozen root.
    function test_guardianCannotRevokeAFrozenRootsPartAfterItsModuleCodeChanged() public {
        registry.freezeRoot(address(root));
        vm.etch(address(chain), address(new PartScopeChainStubV2(address(root))).code);
        assertEq(PartScopeChainStubV2(address(chain)).trustedRoot(), address(root));
        (, address scopeRoot) = registry.partScopeEligible(address(chain));
        assertEq(scopeRoot, address(0));
        _guardianRevokeRefused();
    }

    /// A retired root closes its part scopes, but a frozen one keeps a revocation under them the owner's alone.
    function test_guardianCannotRevokeAPartUnderARetiredFrozenRoot() public {
        registry.freezeRoot(address(root));
        _execute(registry.RETIRE_ROOT(), abi.encode(address(root)));
        registry.retireRoot(address(root));
        (, address scopeRoot) = registry.partScopeEligible(address(chain));
        assertEq(scopeRoot, address(0));
        _guardianRevokeRefused();
        registry.revokeModuleAdmission(address(chain), address(part));
        assertTrue(registry.isRevokedAdmission(address(chain), address(part)));
    }

    /// On a root that is not frozen the brake stays the guardian's too, with the bond covering or lapsed.
    function test_guardianStillRevokesAnUnfrozenRootsPartDuringABondLapse() public {
        bond.setCovered(address(root), address(chain), false);
        vm.prank(guardian);
        registry.revokeModuleAdmission(address(chain), address(part));
        assertTrue(registry.isRevokedAdmission(address(chain), address(part)));
    }

    /// Once the module itself is revoked on the frozen root its part scope is gone for good, so a part left under it
    /// can never bind again and the guardian may withdraw it.
    function test_guardianRevokesAPartUnderAModuleRevokedForGood() public {
        registry.freezeRoot(address(root));
        registry.revokeModuleAdmission(address(root), address(chain));
        vm.prank(guardian);
        registry.revokeModuleAdmission(address(chain), address(part));
        assertTrue(registry.isRevokedAdmission(address(chain), address(part)));
    }
}
