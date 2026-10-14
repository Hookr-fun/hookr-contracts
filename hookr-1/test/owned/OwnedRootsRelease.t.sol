// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrTreasury} from "../../src/support/HookrTreasury.sol";
import {HookrOwnedProfiles} from "../../src/owned/HookrOwnedProfiles.sol";
import {HookrOwnedRootFactory} from "../../src/owned/HookrOwnedRootFactory.sol";
import {HookrOwnedRootTypes as F} from "../../src/libraries/HookrOwnedRootTypes.sol";
import {IHookrOwnedRootFactory} from "../../src/interfaces/IHookrOwnedRootFactory.sol";
import {IHookrOwnedProfiles} from "../../src/interfaces/IHookrOwnedProfiles.sol";
import {OwnedRootsFixture} from "./OwnedRootsFixture.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";

/// @notice The release steps around owned roots: the governance operations a release runs once (the factory's
///         timelocked SET_ROOT_FACTORY, the treasury's owned-root registry, the standard profile) and none per root;
///         the companion's admission, which is the template's RULES terms for the companion and cannot diverge from
///         them.
contract OwnedRootsReleaseTest is OwnedRootsFixture {
    function setUp() public {
        _setUpOwned();
    }

    function launchExternal(address rootAddr, IHookrLauncher.Member memory m)
        external
        returns (bytes32 family, PoolKey memory key, address subject)
    {
        return _launchAs(stranger, rootAddr, m);
    }

    /// @notice Once the release wired the factory and the treasury, a brand's root needs no Safe signature: the brand
    ///         deploys and pays the fee, its pool trades, and the treasury collects its companion by provenance.
    function test_noGovernanceStepPerRoot() public {
        // A fresh release: a treasury and a factory nobody wired for owned roots yet.
        HookrTreasury t = new HookrTreasury(address(this), TARGET, manager);
        HookrRules tRules = new HookrRules(manager, registry, address(t), address(root), PROTOCOL_FLOOR);
        _admit(address(root), _rulesAdmission(address(tRules)));
        t.admitSource(address(tRules));
        HookrOwnedRootFactory f = new HookrOwnedRootFactory(
            registry,
            book,
            address(root),
            address(tRules),
            address(t),
            keccak256(type(HookrRoot).creationCode),
            keccak256(type(HookrRules).creationCode),
            500
        );
        IHookrOwnedProfiles.Profile memory p = _profile(F.ALL_FEATURES, true, address(this));
        p.rules = address(tRules);
        bytes32 standard = book.writeProfile(bytes32("release-standard"), p);
        IHookrOwnedRootFactory.RootSelections memory sel = _selFor(standard, brand, F.ALL_FEATURES, true);
        // Before SET_ROOT_FACTORY executes, the registry refuses the factory's registrations.
        bytes32 salt = _mineFor(address(f), brand, 1);
        uint256 fee = _fee(f);
        vm.deal(brand, brand.balance + fee);
        vm.prank(brand);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        _deployCall(f, fee, sel, salt);
        // The release's one-time steps: SET_ROOT_FACTORY through the timelock, the treasury's registry.
        _activateFactory(address(f));
        t.setOwnedRootRegistry(address(registry));
        // From here on, no governance step per root.
        (HookrRoot owned, HookrRules companion) = _deployWith(f, brand, sel, salt);
        (, PoolKey memory key,) = _launchAs(stranger, address(owned), _nativeMember(address(companion), _rc(), 0));
        _trade(key, true, true, 5 ether);
        uint256 owed = companion.claimable(ETH, address(t));
        assertGt(owed, 0);
        uint256 before = TARGET.balance;
        vm.prank(stranger);
        assertEq(t.collect(address(companion), ETH), owed);
        assertEq(TARGET.balance - before, owed);
        assertEq(t.sourceCodeHash(address(companion)), address(companion).codehash);
    }

    /// @notice The companion's admission is the template's RULES admission of the template Rules with the
    ///         companion's address and codehash and the profile's caps: its schema, gas, phases, fee-only and fail-open
    ///         flags are the template's, so it cannot diverge from what governance admitted.
    function test_companionAdmissionIsTheTemplatesTerms() public {
        HookrTypes.Caps memory narrow = HookrTypes.Caps(300_000, 100_000, 500);
        IHookrOwnedProfiles.Profile memory np = _profile(F.ALL_FEATURES, true, address(this));
        np.caps = narrow;
        bytes32 id = book.writeProfile(bytes32("narrow"), np);
        (HookrRoot owned, HookrRules companion) = _deployOwned(_selFor(id, stranger, F.ALL_FEATURES, true));
        IHookrRegistry.Admission memory d = registry.admission(address(owned), address(companion));
        assertEq(uint8(d.kind), uint8(IHookrRegistry.Kind.RULES));
        assertEq(d.implementation, address(companion));
        assertEq(d.codeHash, address(companion).codehash);
        assertEq(d.schemaHash, companion.configSchemaHash(), "the companion's schema");
        assertEq(d.gasLimit, 2_000_000);
        assertEq(d.phaseMask, 3);
        assertFalse(d.feeOnly);
        assertFalse(d.failOpen);
        assertEq(d.caps.maxLpFeePips, narrow.maxLpFeePips, "the profile's ceiling");
        assertEq(d.caps.maxQuoteTakePips, narrow.maxQuoteTakePips);
        assertEq(d.caps.maxSubjectTakeBps, narrow.maxSubjectTakeBps);
    }

    /// @notice A template admission under a schema its Rules do not declare opens no pool on the template, and an
    ///         owned root copying it opens none either: the copy cannot make a pool the template would refuse. The
    ///         mismatched Rules are the template Rules of a factory of their own.
    function test_aMismatchedTemplateSchemaOpensNoPoolEitherWay() public {
        HookrTypes.Caps memory caps = HookrTypes.Caps(600_000, 200_000, 1000);
        bytes32 id = _secondRulesProfile(bytes32("other-schema"), keccak256("another.schema"), caps);
        IHookrOwnedProfiles.Profile memory p = book.profile(id);
        HookrOwnedRootFactory f = new HookrOwnedRootFactory(
            registry,
            book,
            address(root),
            p.rules,
            address(hookrTreasury),
            keccak256(type(HookrRoot).creationCode),
            keccak256(type(HookrRules).creationCode),
            500
        );
        _activateFactory(address(f));
        (HookrRoot owned, HookrRules companion) =
            _deployWith(f, stranger, _selFor(id, stranger, F.ALL_FEATURES, true), _mineFor(address(f), stranger, 1));
        assertEq(registry.admission(address(owned), address(companion)).schemaHash, keccak256("another.schema"));
        IHookrLauncher.Member memory onTemplate = _nativeMember(p.rules, _rc(), 0);
        vm.expectRevert(abi.encodeWithSelector(IHookrRootEvents.InvalidModule.selector, p.rules));
        this.launchExternal(address(root), onTemplate);
        IHookrLauncher.Member memory onOwned = _nativeMember(address(companion), _rc(), 0);
        vm.expectRevert(abi.encodeWithSelector(IHookrRootEvents.InvalidModule.selector, address(companion)));
        this.launchExternal(address(owned), onOwned);
    }

    /// @notice Every companion keeps the template Rules' protocol-share floor (decision 6): 1,999 bps is refused at
    ///         bind, 2,000 opens.
    function test_ownedRootsKeepTheProtocolShareFloor() public {
        (HookrRoot owned, HookrRules companion) = _deployOwned(_sel(brand, F.ALL_FEATURES));
        assertEq(companion.minProtocolShareBps(), 2_000);
        HookrTypes.RulesConfig memory c = _rc();
        c.protocolShareBps = 1_999;
        IHookrLauncher.Member memory below = _nativeMember(address(companion), c, 0);
        vm.expectRevert(_bindRefusal(address(companion)));
        this.launchExternal(address(owned), below);
        c.protocolShareBps = 2_000;
        this.launchExternal(address(owned), _nativeMember(address(companion), c, 0));
    }

    /// @dev A second HookrRules on the shared root (same build, treasury and floor), admitted with `caps` under
    ///      `schemaHash` (zero: the build's own schema), and a public profile naming it at those caps. A root derives
    ///      from that profile only through a factory whose template Rules it is.
    function _secondRulesProfile(bytes32 salt, bytes32 schemaHash, HookrTypes.Caps memory caps)
        internal
        returns (bytes32 pid)
    {
        HookrRules second = new HookrRules(manager, registry, address(hookrTreasury), address(root), PROTOCOL_FLOOR);
        IHookrRegistry.Admission memory a = _rulesAdmission(address(second));
        if (schemaHash != bytes32(0)) a.schemaHash = schemaHash;
        a.caps = caps;
        _admit(address(root), a);
        IHookrOwnedProfiles.Profile memory p = _profile(F.ALL_FEATURES, true, address(this));
        p.rules = address(second);
        p.caps = caps;
        pid = book.writeProfile(salt, p);
    }
}
