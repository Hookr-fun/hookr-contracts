// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {HookrRegistry} from "../../src/core/HookrRegistry.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";

/// @dev A composing Rules module (a rule chain) as the registry sees it: code, a root it reports and a schema.
contract ChainModuleStub {
    address public immutable trustedRoot;

    constructor(address root_) {
        trustedRoot = root_;
    }

    function configSchemaHash() external pure returns (bytes32) {
        return keccak256("test.chain.v1");
    }
}

/// @dev The same module with other runtime code, to model a codehash drift at the module's address.
contract ChainModuleStubV2 {
    address public immutable trustedRoot;

    constructor(address root_) {
        trustedRoot = root_;
    }

    function configSchemaHash() external pure returns (bytes32) {
        return keccak256("test.chain.v1");
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev Answers every call, `trustedRoot()` included, with the root in the low 160 bits of a word whose high bits are
///      dirty.
contract DirtyRootStub {
    uint256 private immutable word;

    constructor(address root_) {
        word = uint256(uint160(root_)) | (uint256(1) << 200);
    }

    fallback() external {
        uint256 w = word;
        assembly ("memory-safe") {
            mstore(0, w)
            return(0, 32)
        }
    }
}

/// @dev A root factory as the registry sees it: code it pins.
contract AdmissionsFactoryStub {}

/// @dev A part as the registry sees it: any contract with code. The registry never calls a part.
contract PartStub {
    function configSchemaHash() external pure returns (bytes32) {
        return keccak256("test.part.v1");
    }
}

/// @notice The per-module brake (`revokeModuleAdmission`) and part scopes (admissions under a Rules module admitted on
///         its active root). Both live only in the registry: the root reads admissions once, when a pool initializes.
contract RegistryModuleAdmissionsTest is PeripheryFixture {
    address internal guardian = address(0x6A7D);
    address internal stranger = address(0x5757);
    bytes32 internal constant PART_SCHEMA = keccak256("test.part.v1");

    function setUp() public {
        _setUpPeriphery();
        registry.queue(registry.SET_GUARDIAN(), abi.encode(guardian));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setGuardian(guardian);
    }

    // ───────────────────────────── helpers ─────────────────────────────

    /// @dev The fixture's root-scope Rules admission, for another module.
    function _rulesAdmission(address implementation, bytes32 schema)
        internal
        view
        returns (IHookrRegistry.Admission memory a)
    {
        a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.RULES,
            implementation: implementation,
            codeHash: implementation.codehash,
            schemaHash: schema,
            caps: HookrTypes.Caps(600_000, 200_000, 1000),
            gasLimit: 2_000_000,
            phaseMask: 3,
            feeOnly: false,
            failOpen: false
        });
    }

    /// @dev A root factory's admission of a pair advisory.
    function _pairAdvisory(address implementation) internal view returns (IHookrRegistry.Admission memory a) {
        a = _rulesAdmission(implementation, keccak256("test.chain.v1"));
        a.kind = IHookrRegistry.Kind.ADVISORY;
        a.phaseMask = HookrTypes.BEFORE_SWAP;
        a.caps = HookrTypes.Caps(10_000, 0, 0);
        a.gasLimit = 100_000;
    }

    /// @dev A part admission with room inside every bound.
    function _part(address part) internal view returns (IHookrRegistry.Admission memory a) {
        a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.RULES,
            implementation: part,
            codeHash: part.codehash,
            schemaHash: PART_SCHEMA,
            caps: HookrTypes.Caps(10_000, 5_000, 0),
            gasLimit: 60_000,
            phaseMask: 1,
            feeOnly: false,
            failOpen: false
        });
    }

    function _queue(address scope, IHookrRegistry.Admission memory a) internal returns (bytes32) {
        return registry.queue(registry.ADMIT(), abi.encode(scope, a));
    }

    function _admit(address scope, IHookrRegistry.Admission memory a) internal {
        _queue(scope, a);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(scope, a);
    }

    function _expectQueueRefused(address scope, IHookrRegistry.Admission memory a, bytes memory reason) internal {
        bytes32 kind = registry.ADMIT();
        bytes memory args = abi.encode(scope, a);
        vm.expectRevert(reason);
        registry.queue(kind, args);
    }

    function _invalidAdmission() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IHookrRegistry.InvalidAdmission.selector);
    }

    function _invalidRoot() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IHookrRegistry.InvalidRoot.selector);
    }

    /// @dev One native-quote member of `tokenA` on the root at `spacing`, bound to `rulesModule`.
    function _nativeMembers(int24 spacing, address rulesModule)
        internal
        view
        returns (IHookrLauncher.Member[] memory members)
    {
        members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(0)));
        members[0].tickSpacing = spacing;
        members[0].config.rules = rulesModule;
    }

    function _launchNative(int24 spacing, address rulesModule) internal returns (PoolKey memory key) {
        IHookrLauncher.Member[] memory members = _nativeMembers(spacing, rulesModule);
        (bytes32 family,) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
    }

    function _expectLaunchRefused(int24 spacing, address rulesModule, bytes memory reason) internal {
        IHookrLauncher.Member[] memory members = _nativeMembers(spacing, rulesModule);
        IHookrLauncher.Token memory token = IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0));
        uint256 deadline = vm.getBlockTimestamp();
        vm.expectRevert(reason);
        launcher.launch{value: 1e24}(token, address(root), members, deadline);
    }

    function _buyAndSell(PoolKey memory key) internal {
        IHookrRouter.Swap memory p = _swap(key, true, true, 1e18);
        vm.prank(trader);
        (uint256 input, uint256 output) = router.swap(p, address(0), new uint256[](0));
        assertGt(input, 0);
        assertGt(output, 0);
        p = _swap(key, false, true, 1e17);
        vm.prank(trader);
        (input, output) = router.swap(p, address(0), new uint256[](0));
        assertGt(input, 0);
        assertGt(output, 0);
    }

    function _assertScope(address module, bool eligible, address expectedRoot) internal view {
        (bool ok, address r) = registry.partScopeEligible(module);
        assertEq(ok, eligible, "eligible");
        assertEq(r, expectedRoot, "root");
    }

    // ───────────────────────────── the brake ─────────────────────────────

    /// The guardian revokes the root's Rules module at once: the unchanged root refuses new pools naming it, the pool
    /// already open keeps trading, and the pair (root, module) is marked revoked.
    function test_revoke_rootRulesStopsNewPoolsOnly() public {
        (, PoolKey memory live,,) = _launch(true, false);

        vm.prank(stranger);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.revokeModuleAdmission(address(root), address(rules));

        vm.expectEmit(true, true, true, true, address(registry));
        emit IHookrRegistry.AdmissionRevoked(address(root), address(rules), guardian);
        vm.prank(guardian);
        registry.revokeModuleAdmission(address(root), address(rules));

        assertEq(registry.admission(address(root), address(rules)).implementation, address(0));
        assertTrue(registry.isRevokedAdmission(address(root), address(rules)));
        assertTrue(registry.rootOpen(address(root)));
        _expectLaunchRefused(60, address(rules), abi.encodeWithSelector(IHookrRootEvents.InvalidModule.selector, rules));
        _buyAndSell(live);

        // Nothing is left to revoke.
        vm.prank(guardian);
        vm.expectRevert(IHookrRegistry.InvalidAdmission.selector);
        registry.revokeModuleAdmission(address(root), address(rules));
    }

    /// A compromised guardian revokes the genesis Rules on the unfrozen root: the owner removes the guardian at once,
    /// and a new deployment of the same Rules code, admitted through the timelock, opens pools again.
    function test_revoke_compromisedGuardianIsAnsweredByTheOwner() public {
        vm.prank(guardian);
        registry.revokeModuleAdmission(address(root), address(rules));
        registry.removeGuardian();
        vm.prank(guardian);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.revokeModuleAdmission(address(root), address(rules));

        HookrRules replacement = new HookrRules(manager, registry, protocol, address(root), 0);
        _admit(address(root), _rulesAdmission(address(replacement), replacement.configSchemaHash()));
        _launchNative(60, address(replacement));
    }

    /// No admission of the same address for the same root executes after the brake, whether it was queued before it or
    /// after; a new deployment of the same code, admitted through the timelock, restores launches.
    function test_revoke_isPermanentAndAReplacementIsANewDeployment() public {
        // Two admissions of one module queued together: the first executes, the brake lands, the second never can.
        HookrRules second = new HookrRules(manager, registry, protocol, address(root), 0);
        IHookrRegistry.Admission memory first = _rulesAdmission(address(second), second.configSchemaHash());
        IHookrRegistry.Admission memory again = _rulesAdmission(address(second), second.configSchemaHash());
        again.caps.maxLpFeePips = 500_000;
        _queue(address(root), first);
        _queue(address(root), again);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), first);
        registry.revokeModuleAdmission(address(root), address(second));
        vm.expectRevert(IHookrRegistry.InvalidAdmission.selector);
        registry.admit(address(root), again);
        _expectQueueRefused(address(root), first, _invalidAdmission());
        _expectQueueRefused(address(root), again, _invalidAdmission());

        // The fixture's Rules module, revoked by the owner, cannot be queued again either.
        registry.revokeModuleAdmission(address(root), address(rules));
        _expectQueueRefused(
            address(root), _rulesAdmission(address(rules), rules.configSchemaHash()), _invalidAdmission()
        );
        _expectLaunchRefused(60, address(rules), abi.encodeWithSelector(IHookrRootEvents.InvalidModule.selector, rules));

        HookrRules replacement = new HookrRules(manager, registry, protocol, address(root), 0);
        _expectLaunchRefused(
            60, address(replacement), abi.encodeWithSelector(IHookrRootEvents.InvalidModule.selector, replacement)
        );
        _admit(address(root), _rulesAdmission(address(replacement), replacement.configSchemaHash()));
        assertFalse(registry.isRevokedAdmission(address(root), address(replacement)));
        _launchNative(60, address(replacement));
    }

    /// The brake stays available on a closed or retired root, to the owner and the guardian. On a frozen root only the
    /// owner revokes: a frozen root takes no replacement admission, so the revocation could not be undone, and the
    /// guardian's instant answer there is `closeRoot`, which the owner can lift.
    function test_revoke_onClosedFrozenAndRetiredRoots() public {
        HookrRules second = new HookrRules(manager, registry, protocol, address(root), 0);
        HookrRules third = new HookrRules(manager, registry, protocol, address(root), 0);
        _queue(address(root), _rulesAdmission(address(second), second.configSchemaHash()));
        _queue(address(root), _rulesAdmission(address(third), third.configSchemaHash()));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), _rulesAdmission(address(second), second.configSchemaHash()));
        registry.admit(address(root), _rulesAdmission(address(third), third.configSchemaHash()));

        vm.prank(guardian);
        registry.closeRoot(address(root));
        vm.prank(guardian);
        registry.revokeModuleAdmission(address(root), address(rules));

        registry.freezeRoot(address(root));
        vm.prank(guardian);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.revokeModuleAdmission(address(root), address(second));
        registry.revokeModuleAdmission(address(root), address(second));

        registry.queue(registry.RETIRE_ROOT(), abi.encode(address(root)));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.retireRoot(address(root));
        registry.revokeModuleAdmission(address(root), address(third));

        assertTrue(registry.isRevokedAdmission(address(root), address(rules)));
        assertTrue(registry.isRevokedAdmission(address(root), address(second)));
        assertTrue(registry.isRevokedAdmission(address(root), address(third)));
        assertEq(registry.admission(address(root), address(third)).implementation, address(0));
    }

    /// The finding behind the frozen-root rule: if the guardian could revoke on a frozen root, the root's only Rules
    /// admission would be gone for good, since the freeze refuses every replacement. The guardian's brake there is
    /// closeRoot, which the owner lifts with a queued REOPEN_ROOT.
    function test_revoke_guardianCannotEndAFrozenRootForGood() public {
        registry.freezeRoot(address(root));
        vm.prank(guardian);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.revokeModuleAdmission(address(root), address(rules));
        assertEq(registry.admission(address(root), address(rules)).implementation, address(rules));

        // What the guardian does instead, and how the owner lifts it.
        vm.prank(guardian);
        registry.closeRoot(address(root));
        assertFalse(registry.rootOpen(address(root)));
        registry.queue(registry.REOPEN_ROOT(), abi.encode(address(root)));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.reopenRoot(address(root));
        _launchNative(60, address(rules));

        // A replacement can never be admitted on the frozen root, which is why the revocation is the owner's alone.
        HookrRules replacement = new HookrRules(manager, registry, protocol, address(root), 0);
        _expectQueueRefused(
            address(root),
            _rulesAdmission(address(replacement), replacement.configSchemaHash()),
            abi.encodeWithSelector(IHookrRegistry.RootFrozen.selector)
        );
    }

    /// Only a live admission can be revoked, for the scope it was made for.
    function test_revoke_needsALiveAdmissionInThatScope() public {
        vm.expectRevert(IHookrRegistry.InvalidAdmission.selector);
        registry.revokeModuleAdmission(address(root), address(0x1234));
        vm.expectRevert(IHookrRegistry.InvalidAdmission.selector);
        registry.revokeModuleAdmission(address(0x1234), address(rules));
        vm.expectRevert(IHookrRegistry.InvalidAdmission.selector);
        registry.revokeModuleAdmission(address(rules), address(root));
        // An admission under the module is a different scope from the module's own admission on the root.
        PartStub part = new PartStub();
        _admit(address(rules), _part(address(part)));
        vm.expectRevert(IHookrRegistry.InvalidAdmission.selector);
        registry.revokeModuleAdmission(address(root), address(part));
        assertEq(registry.admission(address(rules), address(part)).implementation, address(part));
        assertEq(registry.admission(address(root), address(rules)).implementation, address(rules));
    }

    // ───────────────────────────── part scopes ─────────────────────────────

    /// A Rules module admitted on its active root is the scope of its parts' admissions. The part is recorded under the
    /// module only; the root's own admission set is unchanged.
    function test_part_admittedUnderAnAdmittedRulesModule() public {
        _assertScope(address(rules), true, address(root));
        PartStub part = new PartStub();
        IHookrRegistry.Admission memory a = _part(address(part));
        _queue(address(rules), a);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.expectEmit(true, true, true, true, address(registry));
        emit IHookrRegistry.ModuleAdmitted(
            address(rules), address(part), IHookrRegistry.Kind.RULES, address(part).codehash
        );
        registry.admit(address(rules), a);

        IHookrRegistry.Admission memory got = registry.admission(address(rules), address(part));
        assertEq(got.implementation, address(part));
        assertEq(got.codeHash, address(part).codehash);
        assertEq(got.schemaHash, PART_SCHEMA);
        assertEq(got.gasLimit, 60_000);
        assertEq(got.phaseMask, 1);
        assertEq(got.caps.maxLpFeePips, 10_000);
        assertEq(registry.admission(address(root), address(part)).implementation, address(0));
        _expectQueueRefused(address(rules), a, abi.encodeWithSelector(IHookrRegistry.AlreadyAdmitted.selector));
    }

    /// A part carries its own gas budget, from 25,000 to 2,000,000, and any nonzero phase mask; everything else keeps
    /// the admission bounds. A part is never fail-open, never an advisory and never the module itself.
    function test_part_bounds() public {
        PartStub[6] memory parts;
        for (uint256 i; i < parts.length; ++i) {
            parts[i] = new PartStub();
        }
        IHookrRegistry.Admission memory a;

        a = _part(address(parts[0]));
        a.gasLimit = 25_000;
        _queue(address(rules), a);
        a = _part(address(parts[1]));
        a.gasLimit = 2_000_000;
        a.phaseMask = 3;
        _queue(address(rules), a);
        a = _part(address(parts[2]));
        a.phaseMask = 2;
        a.feeOnly = true;
        a.caps = HookrTypes.Caps(600_000, 999_999, 1000);
        _queue(address(rules), a);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        a = _part(address(parts[0]));
        a.gasLimit = 25_000;
        registry.admit(address(rules), a);
        a = _part(address(parts[1]));
        a.gasLimit = 2_000_000;
        a.phaseMask = 3;
        registry.admit(address(rules), a);
        a = _part(address(parts[2]));
        a.phaseMask = 2;
        a.feeOnly = true;
        a.caps = HookrTypes.Caps(600_000, 999_999, 1000);
        registry.admit(address(rules), a);
        assertEq(registry.admission(address(rules), address(parts[0])).gasLimit, 25_000);
        assertEq(registry.admission(address(rules), address(parts[1])).gasLimit, 2_000_000);
        assertEq(registry.admission(address(rules), address(parts[2])).phaseMask, 2);

        address p = address(parts[3]);
        a = _part(p);
        a.gasLimit = 24_999;
        _expectQueueRefused(address(rules), a, _invalidAdmission());
        a = _part(p);
        a.gasLimit = 2_000_001;
        _expectQueueRefused(address(rules), a, _invalidAdmission());
        a = _part(p);
        a.phaseMask = 0;
        _expectQueueRefused(address(rules), a, _invalidAdmission());
        a = _part(p);
        a.phaseMask = 4;
        _expectQueueRefused(address(rules), a, _invalidAdmission());
        a = _part(p);
        a.failOpen = true;
        a.feeOnly = true;
        a.caps.maxQuoteTakePips = 0;
        _expectQueueRefused(address(rules), a, _invalidAdmission());
        a = _part(p);
        a.kind = IHookrRegistry.Kind.ADVISORY;
        a.caps.maxSubjectTakeBps = 0;
        _expectQueueRefused(address(rules), a, _invalidAdmission());
        a = _part(p);
        a.caps.maxLpFeePips = 600_001;
        _expectQueueRefused(address(rules), a, _invalidAdmission());
        a = _part(p);
        a.caps.maxQuoteTakePips = 1_000_000;
        _expectQueueRefused(address(rules), a, _invalidAdmission());
        a = _part(p);
        a.caps.maxSubjectTakeBps = 1001;
        _expectQueueRefused(address(rules), a, _invalidAdmission());
        a = _part(p);
        a.codeHash = keccak256("other code");
        _expectQueueRefused(address(rules), a, _invalidAdmission());
        a = _part(p);
        a.schemaHash = bytes32(0);
        _expectQueueRefused(address(rules), a, _invalidAdmission());
        // The module cannot be its own part.
        a = _part(address(rules));
        _expectQueueRefused(address(rules), a, _invalidAdmission());
        // A part must hold code.
        a = _part(address(0xC0FFEE));
        _expectQueueRefused(
            address(rules), a, abi.encodeWithSelector(IHookrRegistry.NotAContract.selector, address(0xC0FFEE))
        );

        // The relaxed bounds apply under a part scope only: a root still admits Rules with exactly 2,000,000 gas
        // and both phases.
        a = _part(address(parts[4]));
        _expectQueueRefused(address(root), a, _invalidAdmission());
        a = _rulesAdmission(address(parts[4]), PART_SCHEMA);
        a.phaseMask = 1;
        _expectQueueRefused(address(root), a, _invalidAdmission());
        a = _rulesAdmission(address(parts[4]), PART_SCHEMA);
        a.gasLimit = 1_999_999;
        _expectQueueRefused(address(root), a, _invalidAdmission());
        _queue(address(root), _rulesAdmission(address(parts[5]), PART_SCHEMA));
    }

    /// Only a module with a live RULES admission on the active root it reports from `trustedRoot()`, with its code
    /// unchanged, is a part scope. Anything else reads as an unknown scope.
    function test_part_scopeIsALiveRulesAdmissionOnTheModulesOwnRoot() public {
        PartStub part = new PartStub();
        IHookrRegistry.Admission memory a = _part(address(part));

        // A Rules module for the root that was never admitted.
        HookrRules stray = new HookrRules(manager, registry, protocol, address(root), 0);
        _expectQueueRefused(address(stray), a, _invalidRoot());
        _assertScope(address(stray), false, address(0));

        // An account without code, and a contract without `trustedRoot()`.
        _expectQueueRefused(address(0xABCD), a, _invalidRoot());
        _expectQueueRefused(address(part), _part(address(new PartStub())), _invalidRoot());

        // A module admitted on the root as an advisory.
        ChainModuleStub asAdvisory = new ChainModuleStub(address(root));
        IHookrRegistry.Admission memory adv = _rulesAdmission(address(asAdvisory), keccak256("test.chain.v1"));
        adv.kind = IHookrRegistry.Kind.ADVISORY;
        adv.phaseMask = HookrTypes.BEFORE_SWAP;
        adv.caps = HookrTypes.Caps(10_000, 0, 0);
        adv.gasLimit = 100_000;
        _admit(address(root), adv);
        _expectQueueRefused(address(asAdvisory), a, _invalidRoot());
        _assertScope(address(asAdvisory), false, address(0));

        // A module admitted RULES on the root that reports another root.
        ChainModuleStub elsewhere = new ChainModuleStub(address(0xBEEF));
        _admit(address(root), _rulesAdmission(address(elsewhere), keccak256("test.chain.v1")));
        _expectQueueRefused(address(elsewhere), a, _invalidRoot());
        _assertScope(address(elsewhere), false, address(0));

        // A module admitted RULES on the root whose `trustedRoot()` word has dirty high bits.
        DirtyRootStub dirty = new DirtyRootStub(address(root));
        _admit(address(root), _rulesAdmission(address(dirty), keccak256("test.dirty.v1")));
        _expectQueueRefused(address(dirty), a, _invalidRoot());
        _assertScope(address(dirty), false, address(0));

        // The root itself is a root scope, never a part scope.
        _assertScope(address(root), false, address(0));

        // A module admitted RULES on its own root is one.
        ChainModuleStub chain = new ChainModuleStub(address(root));
        _admit(address(root), _rulesAdmission(address(chain), keccak256("test.chain.v1")));
        _assertScope(address(chain), true, address(root));
        _admit(address(chain), a);
        assertEq(registry.admission(address(chain), address(part)).implementation, address(part));
    }

    /// A drift of the module's runtime code closes its part scope; the scope opens again only with the pinned code.
    function test_part_codehashDriftClosesTheScope() public {
        ChainModuleStub chain = new ChainModuleStub(address(root));
        _admit(address(root), _rulesAdmission(address(chain), keccak256("test.chain.v1")));
        PartStub part = new PartStub();
        _queue(address(chain), _part(address(part)));
        bytes memory original = address(chain).code;

        vm.etch(address(chain), address(new ChainModuleStubV2(address(root))).code);
        assertEq(ChainModuleStubV2(address(chain)).trustedRoot(), address(root));
        _assertScope(address(chain), false, address(0));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.expectRevert(IHookrRegistry.InvalidRoot.selector);
        registry.admit(address(chain), _part(address(part)));

        vm.etch(address(chain), original);
        _assertScope(address(chain), true, address(root));
        registry.admit(address(chain), _part(address(part)));
    }

    /// Freezing the root seals its part scopes, including admissions queued before the freeze, and a revocation under
    /// a sealed part scope is the owner's alone, as on the root itself.
    function test_part_freezeRootSealsItsPartScopes() public {
        PartStub kept = new PartStub();
        PartStub part = new PartStub();
        _admit(address(rules), _part(address(kept)));
        _queue(address(rules), _part(address(part)));
        registry.freezeRoot(address(root));
        _assertScope(address(rules), false, address(root));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.expectRevert(IHookrRegistry.RootFrozen.selector);
        registry.admit(address(rules), _part(address(part)));
        _expectQueueRefused(
            address(rules), _part(address(new PartStub())), abi.encodeWithSelector(IHookrRegistry.RootFrozen.selector)
        );
        vm.prank(guardian);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.revokeModuleAdmission(address(rules), address(kept));
        registry.revokeModuleAdmission(address(rules), address(kept));
        assertTrue(registry.isRevokedAdmission(address(rules), address(kept)));
    }

    /// The factory brake withdraws pair advisories only, so it is no way around the frozen-root rule: neither the
    /// guardian nor the owner can revoke a part with it, on a frozen root or an open one. A part is revoked by
    /// `revokeModuleAdmission`, by the owner alone under a frozen root.
    function test_part_factoryBrakeNeverReachesAPart() public {
        PartStub part = new PartStub();
        _admit(address(rules), _part(address(part)));
        address[] memory parts = new address[](1);
        parts[0] = address(part);

        vm.prank(guardian);
        vm.expectRevert(IHookrRegistry.InvalidAdmission.selector);
        registry.revokeFactoryAdmissions(address(rules), parts);
        vm.expectRevert(IHookrRegistry.InvalidAdmission.selector);
        registry.revokeFactoryAdmissions(address(rules), parts);

        registry.freezeRoot(address(root));
        vm.prank(guardian);
        vm.expectRevert(IHookrRegistry.InvalidAdmission.selector);
        registry.revokeFactoryAdmissions(address(rules), parts);
        vm.expectRevert(IHookrRegistry.InvalidAdmission.selector);
        registry.revokeFactoryAdmissions(address(rules), parts);
        vm.prank(guardian);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.revokeModuleAdmission(address(rules), address(part));
        assertEq(registry.admission(address(rules), address(part)).implementation, address(part));
        assertFalse(registry.isRevokedAdmission(address(rules), address(part)));

        registry.revokeModuleAdmission(address(rules), address(part));
        assertTrue(registry.isRevokedAdmission(address(rules), address(part)));
    }

    /// The factory brake still withdraws a root factory's pair advisories, from the guardian as from the owner, active
    /// or deactivated.
    function test_factoryBrakeStillWithdrawsPairAdvisories() public {
        AdmissionsFactoryStub factory = new AdmissionsFactoryStub();
        registry.queue(registry.SET_ROOT_FACTORY(), abi.encode(address(factory), address(factory).codehash, true));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setRootFactory(address(factory), address(factory).codehash, true);
        ChainModuleStub first = new ChainModuleStub(address(0));
        ChainModuleStub second = new ChainModuleStub(address(0));
        IHookrRegistry.Admission memory a = _pairAdvisory(address(first));
        IHookrRegistry.Admission memory b = _pairAdvisory(address(second));
        _queue(address(factory), a);
        _queue(address(factory), b);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(factory), a);
        registry.admit(address(factory), b);

        address[] memory list = new address[](1);
        list[0] = address(first);
        vm.prank(guardian);
        registry.revokeFactoryAdmissions(address(factory), list);
        assertTrue(registry.isRevokedAdmission(address(factory), address(first)));

        vm.prank(guardian);
        registry.deactivateRootFactory(address(factory));
        list[0] = address(second);
        registry.revokeFactoryAdmissions(address(factory), list);
        assertTrue(registry.isRevokedAdmission(address(factory), address(second)));
    }

    /// Retiring the root closes its part scopes, including admissions queued before the retirement.
    function test_part_retiredRootClosesItsPartScopes() public {
        PartStub part = new PartStub();
        _queue(address(rules), _part(address(part)));
        registry.queue(registry.RETIRE_ROOT(), abi.encode(address(root)));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.retireRoot(address(root));
        _assertScope(address(rules), false, address(0));
        vm.expectRevert(IHookrRegistry.InvalidRoot.selector);
        registry.admit(address(rules), _part(address(part)));
    }

    /// Revoking the module on its root ends its part scope at once; parts already admitted under it stay readable, and
    /// a root closed by the brake still takes part admissions, as it takes its own.
    function test_part_revokingTheModuleEndsItsPartScope() public {
        PartStub kept = new PartStub();
        PartStub pending = new PartStub();
        _admit(address(rules), _part(address(kept)));

        vm.prank(guardian);
        registry.closeRoot(address(root));
        _assertScope(address(rules), true, address(root));

        _queue(address(rules), _part(address(pending)));
        vm.prank(guardian);
        registry.revokeModuleAdmission(address(root), address(rules));
        _assertScope(address(rules), false, address(0));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.expectRevert(IHookrRegistry.InvalidRoot.selector);
        registry.admit(address(rules), _part(address(pending)));
        assertEq(registry.admission(address(rules), address(kept)).implementation, address(kept));
    }

    /// A revoked part cannot return under that module, whether its readmission was queued before the brake or after;
    /// the same part under another module is untouched.
    function test_part_revokedPartCannotReturn() public {
        ChainModuleStub chain = new ChainModuleStub(address(root));
        _admit(address(root), _rulesAdmission(address(chain), keccak256("test.chain.v1")));
        PartStub part = new PartStub();
        IHookrRegistry.Admission memory first = _part(address(part));
        IHookrRegistry.Admission memory again = _part(address(part));
        again.gasLimit = 80_000;
        _queue(address(rules), first);
        _queue(address(rules), again);
        _queue(address(chain), first);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(rules), first);
        registry.admit(address(chain), first);

        vm.prank(stranger);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.revokeModuleAdmission(address(rules), address(part));
        vm.expectEmit(true, true, true, true, address(registry));
        emit IHookrRegistry.AdmissionRevoked(address(rules), address(part), guardian);
        vm.prank(guardian);
        registry.revokeModuleAdmission(address(rules), address(part));

        assertEq(registry.admission(address(rules), address(part)).implementation, address(0));
        assertTrue(registry.isRevokedAdmission(address(rules), address(part)));
        assertEq(registry.admission(address(chain), address(part)).implementation, address(part));
        assertFalse(registry.isRevokedAdmission(address(chain), address(part)));
        vm.expectRevert(IHookrRegistry.InvalidAdmission.selector);
        registry.admit(address(rules), again);
        _expectQueueRefused(address(rules), first, _invalidAdmission());
        // The module's own admission on the root is unchanged.
        _assertScope(address(rules), true, address(root));
    }

    /// The root reads only its own admissions: a Rules module admitted as a part, and nowhere else, cannot be a pool's
    /// Rules.
    function test_part_isNeverBindableAsAPoolsRules() public {
        HookrRules inner = new HookrRules(manager, registry, protocol, address(root), 0);
        IHookrRegistry.Admission memory a = _rulesAdmission(address(inner), inner.configSchemaHash());
        a.gasLimit = 150_000;
        _admit(address(rules), a);
        assertEq(registry.admission(address(rules), address(inner)).implementation, address(inner));
        _expectLaunchRefused(60, address(inner), abi.encodeWithSelector(IHookrRootEvents.InvalidModule.selector, inner));
        // The composing module itself still opens pools.
        _launchNative(60, address(rules));
    }

    // ───────────────────────────── dispatch ─────────────────────────────

    /// @dev The dispatcher compares selectors in ascending order, so a selector below a hot one costs every call to
    ///      that one. The brake and the part-scope read sort after every registry read on a launch, a swap, a lane swap
    ///      or a pair-root deployment.
    function test_dispatch_newSelectorsSortAfterEveryOnChainRegistryCall() public pure {
        bytes4[10] memory hot = [
            HookrRegistry.isRoot.selector,
            HookrRegistry.admission.selector,
            HookrRegistry.isQuote.selector,
            HookrRegistry.rootOpen.selector,
            HookrRegistry.isLauncher.selector,
            HookrRegistry.rootFactoryOf.selector,
            HookrRegistry.registerFactoryRoot.selector,
            HookrRegistry.executorLane.selector,
            HookrRegistry.activeLaneOf.selector,
            HookrRegistry.settlementCurrencies.selector
        ];
        bytes4[2] memory added =
            [HookrRegistry.revokeModuleAdmission.selector, HookrRegistry.partScopeEligible.selector];
        assertEq(added[0], bytes4(0xff60c7f4));
        assertEq(added[1], bytes4(0xffdf8271));
        for (uint256 i; i < hot.length; ++i) {
            for (uint256 j; j < added.length; ++j) {
                assertLt(uint32(hot[i]), uint32(added[j]));
            }
        }
    }
}
