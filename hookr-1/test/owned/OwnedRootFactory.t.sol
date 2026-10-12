// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookrRegistry} from "../../src/core/HookrRegistry.sol";
import {HookrRegistryChecks} from "../../src/libraries/HookrRegistryChecks.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrOwnedRoots} from "../../src/interfaces/IHookrOwnedRoots.sol";
import {IHookrLanes} from "../../src/interfaces/IHookrLanes.sol";
import {IHookrLaneRoot} from "../../src/interfaces/IHookrLaneRoot.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrTreasury} from "../../src/support/HookrTreasury.sol";
import {HookrOwnedProfiles} from "../../src/owned/HookrOwnedProfiles.sol";
import {HookrOwnedRootFactory} from "../../src/owned/HookrOwnedRootFactory.sol";
import {HookrOwnedRootTypes as F} from "../../src/libraries/HookrOwnedRootTypes.sol";
import {IHookrOwnedRootFactory} from "../../src/interfaces/IHookrOwnedRootFactory.sol";
import {IHookrOwnedProfiles} from "../../src/interfaces/IHookrOwnedProfiles.sol";
import {MockIdleExecutor} from "../mocks/MockIdleExecutor.sol";
import {OwnedZeroAdvisory, OwnedGateStub} from "./OwnedRootsMocks.sol";
import {OwnedRootsFixture} from "./OwnedRootsFixture.sol";
import {ReleaseWiring} from "../utils/ReleaseWiring.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";

/// @notice The self-serve tier-2 factory: who may deploy, what it deploys and registers, what it refuses, the root's
///         owner of record and its opening policy, and the copies (advisories, gates, the braked lane) the registry
///         makes at registration.
contract OwnedRootFactoryTest is OwnedRootsFixture {
    using PoolIdLibrary for PoolKey;

    bytes internal code;
    bytes internal rulesCode;

    function setUp() public {
        _setUpOwned();
        code = type(HookrRoot).creationCode;
        rulesCode = type(HookrRules).creationCode;
    }

    function launchExternal(address caller, address rootAddr, IHookrLauncher.Member memory m)
        external
        returns (bytes32 family, PoolKey memory key, address subject)
    {
        return _launchAs(caller, rootAddr, m);
    }

    function deployExternal(address deployer, IHookrOwnedRootFactory.RootSelections memory sel, bytes32 salt)
        external
        returns (HookrRoot r, HookrRules c)
    {
        return _deployWith(factory, deployer, sel, salt);
    }

    // ───────────────────────────── deployment and registration ─────────────────────────────

    /// @notice A deployment registers the root frozen, as an owned root of this factory on the shared template, with
    ///         its companion as its only RULES admission at the template's terms; the root runs the template's build.
    function test_deployRegistersFrozenWithItsCompanionAndEnumerates() public {
        (HookrRoot a, HookrRules ar) = _deployOwned(_sel(brand, F.ALL_FEATURES));
        (HookrRoot b, HookrRules br) = _deployOwned(_sel(stranger, F.ALL_FEATURES));
        assertEq(factory.allDeploymentsLength(), 2);
        assertEq(factory.allDeployments(0), address(a));
        assertEq(factory.allDeployments(1), address(b));
        assertTrue(factory.isAllowedCreationCode(keccak256(code)));
        assertFalse(factory.isAllowedCreationCode(keccak256(rulesCode)));
        assertTrue(factory.isFromFactory(address(a)));
        assertFalse(factory.isFromFactory(address(root)), "the shared root is not an owned root");
        assertEq(factory.creationCodeHashOf(address(root)), bytes32(0));
        assertEq(factory.creationCodeHashOf(address(a)), keccak256(code));
        assertEq(factory.rulesOf(address(a)), address(ar));
        assertEq(factory.rulesOf(address(b)), address(br));
        // The registry's own record.
        IHookrOwnedRoots owned = IHookrOwnedRoots(address(registry));
        assertTrue(registry.isRoot(address(a)));
        assertTrue(owned.isOwnedRoot(address(a)));
        assertEq(owned.ownedRootTemplate(address(a)), address(root));
        assertEq(owned.ownedRegistrarForRoot(address(a)), address(factory));
        assertEq(registry.rootFactoryOf(address(a)), address(0), "an owned root is not a pair root");
        assertTrue(registry.rootFrozen(address(a)));
        assertTrue(registry.rootOpen(address(a)));
        // The companion's admission: the template's RULES terms for the companion at its codehash.
        IHookrRegistry.Admission memory t = registry.admission(address(root), address(sharedRules));
        IHookrRegistry.Admission memory d = registry.admission(address(a), address(ar));
        assertEq(uint8(d.kind), uint8(IHookrRegistry.Kind.RULES));
        assertEq(d.implementation, address(ar));
        assertEq(d.codeHash, address(ar).codehash);
        assertEq(d.schemaHash, t.schemaHash);
        assertEq(d.gasLimit, t.gasLimit);
        assertEq(d.phaseMask, t.phaseMask);
        assertEq(d.feeOnly, t.feeOnly);
        assertEq(d.failOpen, t.failOpen);
        assertEq(d.caps.maxLpFeePips, t.caps.maxLpFeePips);
        assertEq(d.caps.maxQuoteTakePips, t.caps.maxQuoteTakePips);
        assertEq(d.caps.maxSubjectTakeBps, t.caps.maxSubjectTakeBps);
        assertEq(registry.admission(address(a), address(sharedRules)).implementation, address(0));
        assertEq(registry.admission(address(a), address(rules)).implementation, address(0));
        // The companion: the reviewed Rules build, trusting only its root, paying the treasury at the floor.
        assertEq(ar.trustedRoot(), address(a));
        assertEq(address(ar.registry()), address(registry));
        assertEq(address(ar.poolManager()), address(manager));
        assertEq(ar.protocolRecipient(), address(hookrTreasury));
        assertEq(ar.minProtocolShareBps(), PROTOCOL_FLOOR);
        assertEq(ar.configSchemaHash(), sharedRules.configSchemaHash());
        // The record.
        IHookrOwnedRootFactory.OwnedRoot memory o = factory.ownedRoot(address(a));
        assertEq(o.owner, brand);
        assertTrue(o.publicOpening);
        assertFalse(o.paused);
        assertTrue(o.laneAllowed);
        assertEq(o.profileVersion, 1);
        assertEq(o.rules, address(ar));
        assertEq(o.profileId, templateProfile);
        assertEq(o.ruleMask, F.ALL_FEATURES);
        // The template's exact build, at a root of its own.
        assertTrue(factory.runtimeMatchesTemplate(address(a)));
        assertTrue(factory.runtimeMatchesTemplate(address(b)));
        assertTrue(address(a).codehash != address(root).codehash, "each root runs its own lane module");
        assertEq(uint160(address(a)) & Hooks.ALL_HOOK_MASK, CLASS);
        assertEq(a.router(), address(router));
        assertEq(a.quoter(), address(quoter));
        assertEq(a.curatedRouter(), root.curatedRouter());
    }

    /// @notice The deployment is self-serve: anyone deploys, and the address belongs to the deployer's namespace.
    function test_anyoneDeploysAtTheirOwnNamespacedAddress() public {
        bytes32 salt = _mine(stranger);
        address predicted = factory.computeAddress(stranger, salt);
        assertTrue(predicted != factory.computeAddress(brand, salt), "the namespace is the deployer's");
        assertEq(predicted.code.length, 0);
        (HookrRoot r,) = _deployWith(factory, stranger, _sel(stranger, F.ALL_FEATURES), salt);
        assertEq(address(r), predicted);
        assertTrue(factory.saltUsed(stranger, salt));
        assertFalse(factory.saltUsed(brand, salt));
        assertEq(factory.ownedRoot(address(r)).owner, stranger, "the deployer named itself and holds the root");
    }

    /// @notice Front-running a mined salt takes nothing: the same salt from another deployer lands in its own
    ///         namespace, and the brand's transaction still deploys at the address it mined.
    function test_frontRunningAMinedSaltCannotTakeTheAddress() public {
        bytes32 salt = _mine(brand);
        address brandAddress = factory.computeAddress(brand, salt);
        IHookrOwnedRootFactory.RootSelections memory sel = _sel(brand, F.ALL_FEATURES);
        // The front-runner copies the brand's calldata, owner included; the address is the front-runner's.
        address attackerAddress = factory.computeAddress(stranger, salt);
        if (uint160(attackerAddress) & Hooks.ALL_HOOK_MASK == CLASS) {
            (HookrRoot taken,) = _deployWith(factory, stranger, sel, salt);
            assertEq(address(taken), attackerAddress);
            assertEq(factory.pendingRootOwner(address(taken)), brand, "the brand is only nominated");
            assertEq(factory.ownedRoot(address(taken)).owner, address(0));
        } else {
            uint256 fee = _fee(factory);
            vm.prank(stranger);
            vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, attackerAddress));
            _deployCallWith(factory, fee, code, rulesCode, sel, salt);
        }
        (HookrRoot mine,) = _deployWith(factory, brand, sel, salt);
        assertEq(address(mine), brandAddress, "the brand's mined address is still the brand's");
        assertEq(factory.ownedRoot(address(mine)).owner, brand);
    }

    function test_refusesCreationCodeOffTheAllowlist() public {
        bytes memory other = bytes.concat(code, hex"00");
        bytes32 salt = _mine(brand);
        IHookrOwnedRootFactory.RootSelections memory sel = _sel(brand, F.ALL_FEATURES);
        uint256 fee = _fee(factory);
        vm.startPrank(brand);
        vm.expectRevert(
            abi.encodeWithSelector(IHookrOwnedRootFactory.CreationCodeNotAllowed.selector, keccak256(other))
        );
        _deployCallWith(factory, fee, other, rulesCode, sel, salt);
        bytes memory otherRules = bytes.concat(rulesCode, hex"00");
        vm.expectRevert(
            abi.encodeWithSelector(IHookrOwnedRootFactory.CreationCodeNotAllowed.selector, keccak256(otherRules))
        );
        _deployCallWith(factory, fee, code, otherRules, sel, salt);
        // The companion's code in the root's place, and the reverse.
        vm.expectRevert(
            abi.encodeWithSelector(IHookrOwnedRootFactory.CreationCodeNotAllowed.selector, keccak256(rulesCode))
        );
        _deployCallWith(factory, fee, rulesCode, code, sel, salt);
        vm.stopPrank();
    }

    /// @notice A salt whose address does not carry the template's permission flags is refused before any code runs.
    function test_refusesASaltNotMinedForTheFlags() public {
        bytes32 salt = _unmined(address(factory), brand, 7);
        address predicted = factory.computeAddress(brand, salt);
        uint256 fee = _fee(factory);
        IHookrOwnedRootFactory.RootSelections memory sel = _sel(brand, F.ALL_FEATURES);
        vm.prank(brand);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        _deployCallWith(factory, fee, code, rulesCode, sel, salt);
        assertEq(factory.allDeploymentsLength(), 0);
        assertEq(predicted.code.length, 0);
        assertFalse(factory.saltUsed(brand, salt));
    }

    function test_refusesASaltTwice() public {
        bytes32 salt = _mine(brand);
        IHookrOwnedRootFactory.RootSelections memory sel = _sel(brand, F.ALL_FEATURES);
        _deployWith(factory, brand, sel, salt);
        uint256 fee = _fee(factory);
        vm.prank(brand);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedRootFactory.SaltUsed.selector, brand, salt));
        _deployCallWith(factory, fee, code, rulesCode, sel, salt);
    }

    /// @notice A selection with a rule its profile lacks is refused, also when that rule is the lowest feature bit alone.
    ///         Mutation gate OW-6 (the check only caught a difference above that bit).
    function test_aSingleRuleOutsideTheProfileIsRefused() public {
        IHookrOwnedProfiles.Profile memory p = _profile(F.AUTO_BURN | F.LP_REWARDS | F.ROYALTY, false, brand);
        vm.prank(brand);
        bytes32 id = book.writeProfile(bytes32("noSnipe"), p);
        bytes32 salt = _mine(brand);
        uint256 fee = _fee(factory);
        IHookrOwnedRootFactory.RootSelections memory sel = _selFor(id, brand, F.ANTI_SNIPE, false);
        vm.startPrank(brand);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedRootFactory.OutsideProfile.selector, id));
        _deployCallWith(factory, fee, code, rulesCode, sel, salt);
        vm.stopPrank();
    }

    function test_selectionRefusals() public {
        bytes32 salt = _mine(brand);
        uint256 fee = _fee(factory);
        IHookrOwnedRootFactory.RootSelections memory sel = _sel(address(0), F.ALL_FEATURES);
        vm.startPrank(brand);
        vm.expectRevert(IHookrOwnedRootFactory.InvalidOwner.selector);
        _deployCallWith(factory, fee, code, rulesCode, sel, salt);

        sel = _sel(brand, bytes32(uint256(64)));
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedRootFactory.OutsideProfile.selector, templateProfile));
        _deployCallWith(factory, fee, code, rulesCode, sel, salt);

        // A public root keeps every soft feature.
        sel = _sel(brand, F.AUTO_BURN | F.LP_REWARDS | F.ROYALTY | F.ANTI_SNIPE);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedRootFactory.SoftMaskNeedsOwnerOnly.selector, sel.ruleMask));
        _deployCallWith(factory, fee, code, rulesCode, sel, salt);

        sel = _sel(brand, F.ALL_FEATURES);
        sel.profileId = bytes32("missing");
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedRootFactory.UnknownProfile.selector, bytes32("missing")));
        _deployCallWith(factory, fee, code, rulesCode, sel, salt);

        sel = _sel(brand, F.ALL_FEATURES);
        sel.profileVersion = 2;
        vm.expectRevert(
            abi.encodeWithSelector(
                IHookrOwnedRootFactory.ProfileVersionMismatch.selector, templateProfile, uint32(2), uint32(1)
            )
        );
        _deployCallWith(factory, fee, code, rulesCode, sel, salt);
        vm.stopPrank();

        // A failed deployment leaves no trace.
        assertFalse(factory.saltUsed(brand, salt));
        assertEq(factory.allDeploymentsLength(), 0);

        // A public root without Auto Burn deploys: its admission caps the subject take at zero.
        (HookrRoot r, HookrRules c) =
            _deployWith(factory, brand, _sel(brand, F.ANTI_SNIPE | F.DYNAMIC_FEE | F.LP_REWARDS | F.ROYALTY), salt);
        assertEq(registry.admission(address(r), address(c)).caps.maxSubjectTakeBps, 0);
    }

    /// @notice An owner-only root may drop soft features: only its owner opens pools on it.
    function test_ownerOnlyRootMayDropSoftFeatures() public {
        (HookrRoot r, HookrRules c) = _deployOwned(_selFor(templateProfile, brand, F.AUTO_BURN, false));
        IHookrOwnedRootFactory.OwnedRoot memory o = factory.ownedRoot(address(r));
        assertFalse(o.publicOpening);
        assertEq(o.ruleMask, F.AUTO_BURN);
        assertEq(registry.admission(address(r), address(c)).caps.maxSubjectTakeBps, 1000);
        assertTrue(factory.mayOpen(address(r), brand));
        assertFalse(factory.mayOpen(address(r), stranger));
    }

    /// @notice Review L-1 on the self-serve path: a profile rewritten after the deployer read it refuses the deploy.
    function test_profileRewriteAfterTheDeployerReadIsRefused() public {
        IHookrOwnedRootFactory.RootSelections memory sel = _sel(brand, F.ALL_FEATURES);
        book.writeProfile(bytes32("standard"), _profile(F.AUTO_BURN | F.SOFT_FEATURES, true, address(this)));
        bytes32 salt = _mine(brand);
        uint256 fee = _fee(factory);
        vm.prank(brand);
        vm.expectRevert(
            abi.encodeWithSelector(
                IHookrOwnedRootFactory.ProfileVersionMismatch.selector, templateProfile, uint32(1), uint32(2)
            )
        );
        _deployCallWith(factory, fee, code, rulesCode, sel, salt);
        sel.profileVersion = 2;
        (HookrRoot r,) = _deployWith(factory, brand, sel, salt);
        assertEq(factory.ownedRoot(address(r)).profileVersion, 2);
    }

    /// @notice An owner-only profile seeds roots for its owner alone; the root's owner of record may be anyone.
    function test_privateProfileDeploysOnlyForItsOwner() public {
        vm.prank(brand);
        bytes32 id = book.writeProfile(bytes32("private"), _profile(F.ALL_FEATURES, false, brand));
        IHookrOwnedRootFactory.RootSelections memory sel = _selFor(id, stranger, F.ALL_FEATURES, true);
        bytes32 salt = _mine(stranger);
        uint256 fee = _fee(factory);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedRootFactory.NotProfileOwner.selector, id, stranger));
        _deployCallWith(factory, fee, code, rulesCode, sel, salt);
        // The profile's owner deploys and nominates the stranger as the root's owner of record.
        (HookrRoot r,) = _deployWith(factory, brand, sel, _mine(brand));
        assertEq(factory.ownedRoot(address(r)).profileId, id);
        assertEq(factory.pendingRootOwner(address(r)), stranger);
        vm.prank(stranger);
        factory.acceptRootOwnership(address(r));
        assertEq(factory.ownedRoot(address(r)).owner, stranger);
    }

    /// @notice The factory derives roots from its own template only, and only from Rules there that pay its treasury.
    function test_profileMustBeOnTheTemplateAndPayTheTreasury() public {
        // A profile naming the fixture's other Rules on the shared root, which pay a code-less recipient.
        IHookrOwnedProfiles.Profile memory p = _profile(F.ALL_FEATURES, true, brand);
        p.rules = address(rules);
        vm.prank(brand);
        bytes32 other = book.writeProfile(bytes32("other-rules"), p);
        bytes32 salt = _mine(brand);
        uint256 fee = _fee(factory);
        IHookrOwnedRootFactory.RootSelections memory sel = _selFor(other, brand, F.ALL_FEATURES, true);
        vm.prank(brand);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedRootFactory.InvalidTemplate.selector, address(root)));
        _deployCallWith(factory, fee, code, rulesCode, sel, salt);
        // A profile on a second shared root.
        (HookrRoot second, HookrRules secondRules) = _secondSharedRoot();
        p = _profile(F.ALL_FEATURES, true, brand);
        p.root = address(second);
        p.rules = address(secondRules);
        vm.prank(brand);
        bytes32 onSecond = book.writeProfile(bytes32("second-root"), p);
        sel = _selFor(onSecond, brand, F.ALL_FEATURES, true);
        vm.prank(brand);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedRootFactory.InvalidTemplate.selector, address(second)));
        _deployCallWith(factory, fee, code, rulesCode, sel, salt);
    }

    /// @notice The registry's brakes on the template stop new owned roots from it: closed, paused, retired.
    function test_brakedTemplateRefusesNewOwnedRoots() public {
        bytes32 salt = _mine(brand);
        IHookrOwnedRootFactory.RootSelections memory sel = _sel(brand, F.ALL_FEATURES);
        uint256 fee = _fee(factory);
        registry.closeRoot(address(root));
        vm.prank(brand);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedRootFactory.InvalidTemplate.selector, address(root)));
        _deployCallWith(factory, fee, code, rulesCode, sel, salt);
        registry.queue(registry.REOPEN_ROOT(), abi.encode(address(root)));
        vm.warp(vm.getBlockTimestamp() + DELAY);
        registry.reopenRoot(address(root));
        registry.pauseNewMarkets();
        vm.prank(brand);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedRootFactory.InvalidTemplate.selector, address(root)));
        _deployCallWith(factory, fee, code, rulesCode, sel, salt);
        registry.queue(registry.RESUME_NEW_MARKETS(), "");
        registry.queue(registry.RETIRE_ROOT(), abi.encode(address(root)));
        vm.warp(vm.getBlockTimestamp() + DELAY);
        registry.resumeNewMarkets();
        registry.retireRoot(address(root));
        vm.prank(brand);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedRootFactory.InvalidTemplate.selector, address(root)));
        _deployCallWith(factory, fee, code, rulesCode, sel, salt);
        assertEq(factory.allDeploymentsLength(), 0);
    }

    /// @notice The registry's `deactivateRootFactory` brake stops this factory at once: the whole deployment reverts.
    function test_deactivatedFactoryCannotRegister() public {
        registry.deactivateRootFactory(address(factory));
        assertFalse(registry.isRootFactory(address(factory)));
        bytes32 salt = _mine(brand);
        address predicted = factory.computeAddress(brand, salt);
        IHookrOwnedRootFactory.RootSelections memory sel = _sel(brand, F.ALL_FEATURES);
        uint256 fee = _fee(factory);
        vm.prank(brand);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        _deployCallWith(factory, fee, code, rulesCode, sel, salt);
        assertEq(predicted.code.length, 0, "the whole deployment reverted");
        // Reactivation is the timelocked SET_ROOT_FACTORY again, at the same pinned codehash.
        _activateFactory(address(factory));
        (HookrRoot r,) = _deployWith(factory, brand, sel, salt);
        assertEq(address(r), predicted);
    }

    /// @notice A factory the registry never admitted registers nothing; the whole deployment reverts.
    function test_unadmittedFactoryIsRefusedByTheRegistry() public {
        HookrOwnedRootFactory other = _newFactory(500);
        bytes32 salt = _mineFor(address(other), brand, 1);
        address predicted = other.computeAddress(brand, salt);
        uint256 fee = _fee(other);
        IHookrOwnedRootFactory.RootSelections memory sel = _sel(brand, F.ALL_FEATURES);
        vm.prank(brand);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        _deployCallWith(other, fee, code, rulesCode, sel, salt);
        assertEq(predicted.code.length, 0);
    }

    function test_capReached() public {
        HookrOwnedRootFactory small = _newFactory(1);
        _activateFactory(address(small));
        _deployWith(small, brand, _sel(brand, F.ALL_FEATURES), _mineFor(address(small), brand, 1));
        bytes32 salt = _mineFor(address(small), stranger, 1);
        uint256 fee = _fee(small);
        IHookrOwnedRootFactory.RootSelections memory sel = _sel(stranger, F.ALL_FEATURES);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedRootFactory.FactoryFull.selector, uint256(1)));
        _deployCallWith(small, fee, code, rulesCode, sel, salt);
        assertEq(small.allDeploymentsLength(), 1);
    }

    /// @notice A root built from the same code with any other wiring is not the template's build.
    function test_runtimeIdentityRefusesOtherWiring() public {
        HookrRoot curated = _orphanRoot(address(router));
        assertFalse(factory.runtimeMatchesTemplate(address(curated)), "another curated router");
        HookrRoot same = _orphanRoot(address(0));
        assertTrue(factory.runtimeMatchesTemplate(address(same)), "same build and wiring");
        assertFalse(factory.runtimeMatchesTemplate(address(root)), "the template itself shares its lane module");
        // A root whose lane module was swapped for other code.
        HookrRoot swapped = _orphanRoot(address(0));
        (address module,) = IHookrLaneRoot(address(swapped)).laneModule();
        vm.etch(module, address(rules).code);
        assertFalse(factory.runtimeMatchesTemplate(address(swapped)), "a module with other code");
    }

    function test_constructorRefusesForeignWiringAndOutOfBoundKnobs() public {
        bytes32 rootHash = keccak256(code);
        bytes32 rulesHash = keccak256(rulesCode);
        HookrRegistry other = new HookrRegistry(address(this), manager, DELAY);
        HookrOwnedProfiles foreignBook = new HookrOwnedProfiles(IHookrRegistry(address(other)));
        address shared = address(sharedRules);
        address treasury_ = address(hookrTreasury);
        _expectBad(IHookrRegistry(address(0xDEAD)), book, address(root), shared, treasury_, rootHash, rulesHash, 500);
        _expectBad(registry, foreignBook, address(root), shared, treasury_, rootHash, rulesHash, 500);
        _expectBad(
            IHookrRegistry(address(other)), foreignBook, address(root), shared, treasury_, rootHash, rulesHash, 500
        );
        _expectBad(registry, book, address(router), shared, treasury_, rootHash, rulesHash, 500);
        _expectBad(registry, book, address(root), shared, address(0x7A26E8), rootHash, rulesHash, 500);
        _expectBad(registry, book, address(root), shared, treasury_, bytes32(0), rulesHash, 500);
        _expectBad(registry, book, address(root), shared, treasury_, rootHash, bytes32(0), 500);
        _expectBad(registry, book, address(root), shared, treasury_, rootHash, rulesHash, 0);
        _expectBad(registry, book, address(root), shared, treasury_, rootHash, rulesHash, 501);
        // A treasury on another PoolManager.
        HookrTreasury foreignTreasury = new HookrTreasury(address(this), TARGET, IPoolManager(_otherManager()));
        _expectBad(registry, book, address(root), shared, address(foreignTreasury), rootHash, rulesHash, 500);
        // Template Rules with no code, paying another recipient, or answering to another root.
        _expectBad(registry, book, address(root), address(0x7E57), treasury_, rootHash, rulesHash, 500);
        _expectBad(registry, book, address(root), address(rules), treasury_, rootHash, rulesHash, 500);
        (, HookrRules secondRules) = _secondSharedRoot();
        _expectBad(registry, book, address(root), address(secondRules), treasury_, rootHash, rulesHash, 500);
        // The bounds and defaults are on chain.
        assertEq(factory.MIN_MAX_DEPLOYMENTS(), 1);
        assertEq(factory.MAX_MAX_DEPLOYMENTS(), 500);
        assertEq(factory.DEFAULT_MAX_DEPLOYMENTS(), 500);
        assertEq(factory.maxDeployments(), 500);
        // Everything else is read from the template.
        assertEq(factory.template(), address(root));
        assertEq(factory.router(), root.router());
        assertEq(factory.quoter(), root.quoter());
        assertEq(factory.curatedRouter(), root.curatedRouter());
        assertEq(address(factory.poolManager()), address(manager));
        assertEq(address(factory.registry()), address(registry));
        assertEq(address(factory.profiles()), address(book));
        assertEq(factory.treasury(), address(hookrTreasury));
        assertEq(factory.rootClassFlags(), CLASS);
        assertEq(factory.rootCreationCodeHash(), rootHash);
        assertEq(factory.rulesCreationCodeHash(), rulesHash);
    }

    // ───────────────────────────── the owner of record and the opening ─────────────────────────────

    function test_rootOwnershipIsTwoStep() public {
        bytes32 salt = _mine(stranger);
        (HookrRoot r,) = _deployWith(factory, stranger, _sel(brand, F.ALL_FEATURES), salt);
        address root_ = address(r);
        assertEq(factory.ownedRoot(root_).owner, address(0), "nobody holds it before the nominee accepts");
        assertEq(factory.pendingRootOwner(root_), brand);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedRootFactory.NotRootOwner.selector, root_, stranger));
        factory.acceptRootOwnership(root_);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedRootFactory.NotRootOwner.selector, root_, stranger));
        factory.setPaused(root_, true);
        vm.prank(brand);
        factory.acceptRootOwnership(root_);
        assertEq(factory.ownedRoot(root_).owner, brand);
        assertEq(factory.pendingRootOwner(root_), address(0));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedRootFactory.NotRootOwner.selector, root_, stranger));
        factory.transferRootOwnership(root_, stranger);
        vm.prank(brand);
        factory.transferRootOwnership(root_, stranger);
        assertEq(factory.ownedRoot(root_).owner, brand, "the owner keeps the role until the nominee accepts");
        // A zero nominee withdraws the nomination.
        vm.prank(brand);
        factory.transferRootOwnership(root_, address(0));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedRootFactory.NotRootOwner.selector, root_, stranger));
        factory.acceptRootOwnership(root_);
        vm.prank(brand);
        factory.transferRootOwnership(root_, stranger);
        vm.prank(stranger);
        factory.acceptRootOwnership(root_);
        assertEq(factory.ownedRoot(root_).owner, stranger);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedRootFactory.NotOwnedRoot.selector, address(root)));
        factory.acceptRootOwnership(address(root));
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedRootFactory.NotOwnedRoot.selector, address(root)));
        factory.setPaused(address(root), true);
    }

    /// @notice `mayOpen` is the factory's answer to the registry: public roots open for anyone, owner-only roots for
    ///         their owner of record alone, and nobody while the owner paused the root.
    function test_mayOpenFollowsTheRecord() public {
        (HookrRoot pub,) = _deployOwned(_sel(brand, F.ALL_FEATURES));
        (HookrRoot own,) = _deployOwned(_selFor(templateProfile, brand, F.ALL_FEATURES, false));
        assertTrue(factory.mayOpen(address(pub), stranger));
        assertTrue(factory.mayOpen(address(pub), brand));
        assertFalse(factory.mayOpen(address(own), stranger));
        assertTrue(factory.mayOpen(address(own), brand));
        assertFalse(factory.mayOpen(address(root), brand), "not one of its roots");
        assertFalse(factory.mayOpen(address(0x1234), address(0)), "an unknown root opens for nobody, zero included");
        vm.expectEmit(true, false, false, true, address(factory));
        emit IHookrOwnedRootFactory.RootPaused(address(pub), true);
        vm.prank(brand);
        factory.setPaused(address(pub), true);
        vm.prank(brand);
        factory.setPaused(address(own), true);
        assertFalse(factory.mayOpen(address(pub), stranger));
        assertFalse(factory.mayOpen(address(own), brand));
        vm.prank(brand);
        factory.setPaused(address(pub), false);
        assertTrue(factory.mayOpen(address(pub), stranger));
        // An owner-only root whose nominee has not accepted opens for nobody.
        (HookrRoot nominated,) =
            _deployWith(factory, stranger, _selFor(templateProfile, brand, F.ALL_FEATURES, false), _mine(stranger));
        assertFalse(factory.mayOpen(address(nominated), brand));
        assertFalse(factory.mayOpen(address(nominated), stranger));
        assertFalse(factory.mayOpen(address(nominated), address(0)));
    }

    /// @notice The registry asks the factory: `rootOpenFor` follows `mayOpen` under the registry's own brakes.
    function test_registryRootOpenForAsksTheFactory() public {
        IHookrOwnedRoots owned = IHookrOwnedRoots(address(registry));
        (HookrRoot own,) = _deployOwned(_selFor(templateProfile, brand, F.ALL_FEATURES, false));
        (HookrRoot pub,) = _deployOwned(_sel(stranger, F.ALL_FEATURES));
        assertTrue(owned.rootOpenFor(address(own), brand));
        assertFalse(owned.rootOpenFor(address(own), stranger), "a stranger is refused on an owner-only root");
        assertTrue(owned.rootOpenFor(address(pub), brand));
        assertTrue(registry.rootOpen(address(own)), "rootOpen keeps meaning open under the registry's brakes");
        vm.prank(brand);
        factory.setPaused(address(own), true);
        assertFalse(owned.rootOpenFor(address(own), brand), "the owner's own pause closes it");
        vm.prank(brand);
        factory.setPaused(address(own), false);
        registry.pauseNewMarkets();
        assertFalse(owned.rootOpenFor(address(own), brand), "the registry's pause closes it for the owner too");
        assertFalse(owned.rootOpenFor(address(pub), brand));
        registry.queue(registry.RESUME_NEW_MARKETS(), "");
        vm.warp(vm.getBlockTimestamp() + DELAY);
        registry.resumeNewMarkets();
        registry.closeRoot(address(own));
        assertFalse(owned.rootOpenFor(address(own), brand));
        // A deactivated factory is still asked: deactivation stops registrations only.
        registry.deactivateRootFactory(address(factory));
        assertTrue(owned.rootOpenFor(address(pub), stranger));
        // A factory whose code breaks reads as closed.
        vm.etch(address(factory), hex"fe");
        assertFalse(owned.rootOpenFor(address(pub), stranger));
    }

    // ───────────────────────────── copies at registration ─────────────────────────────

    /// @notice Decision 3: the profile's listed advisories and gates are admitted on the owned root with the
    ///         template's terms, and frozen with it.
    function test_copiesTheProfilesAdvisoriesAndGates() public {
        OwnedZeroAdvisory a1 = new OwnedZeroAdvisory();
        OwnedZeroAdvisory a2 = new OwnedZeroAdvisory();
        OwnedGateStub g1 = new OwnedGateStub();
        _admit(address(root), _advisoryAdmission(address(a1)));
        _admit(address(root), _advisoryAdmission(address(a2)));
        _admit(address(root), _gateAdmission(address(g1)));
        IHookrOwnedProfiles.Profile memory p = _profile(F.ALL_FEATURES, true, brand);
        p.advisories = new address[](2);
        (p.advisories[0], p.advisories[1]) = (address(a1), address(a2));
        p.gates = new address[](1);
        p.gates[0] = address(g1);
        vm.prank(brand);
        bytes32 id = book.writeProfile(bytes32("copies"), p);
        (HookrRoot r,) = _deployOwned(_selFor(id, brand, F.ALL_FEATURES, true));
        address[3] memory list = [address(a1), address(a2), address(g1)];
        for (uint256 i; i < 3; ++i) {
            IHookrRegistry.Admission memory t = registry.admission(address(root), list[i]);
            IHookrRegistry.Admission memory c = registry.admission(address(r), list[i]);
            assertEq(keccak256(abi.encode(c)), keccak256(abi.encode(t)), "the template's terms");
        }
        assertTrue(registry.rootFrozen(address(r)));
        // The standard profile lists none: its roots carry the companion alone.
        (HookrRoot bare,) = _deployOwned(_sel(stranger, F.ALL_FEATURES));
        assertEq(registry.admission(address(bare), address(a1)).implementation, address(0));
        assertEq(registry.admission(address(bare), address(g1)).implementation, address(0));
    }

    /// @notice A listed admission the template no longer holds (revoked since the profile was written) refuses the
    ///         deployment: no root is born with a dead copy.
    function test_aRevokedListedAdmissionRefusesTheDeployment() public {
        OwnedZeroAdvisory a1 = new OwnedZeroAdvisory();
        _admit(address(root), _advisoryAdmission(address(a1)));
        IHookrOwnedProfiles.Profile memory p = _profile(F.ALL_FEATURES, true, brand);
        p.advisories = new address[](1);
        p.advisories[0] = address(a1);
        vm.prank(brand);
        bytes32 id = book.writeProfile(bytes32("revoked"), p);
        registry.revokeModuleAdmission(address(root), address(a1));
        bytes32 salt = _mine(brand);
        uint256 fee = _fee(factory);
        IHookrOwnedRootFactory.RootSelections memory sel = _selFor(id, brand, F.ALL_FEATURES, true);
        vm.prank(brand);
        vm.expectRevert(HookrRegistryChecks.InvalidAdmission.selector);
        _deployCallWith(factory, fee, code, rulesCode, sel, salt);
    }

    /// @notice Decision 5 with owner amendment 3: the template's open lane is copied braked. The owned root takes no
    ///         pool that asks for arb recapture, and opens every other pool without a lane.
    function test_laneIsCopiedBraked() public {
        MockIdleExecutor executor = new MockIdleExecutor();
        bytes32 openLane = keccak256("OPEN_LANE");
        registry.queue(
            openLane,
            abi.encode(address(root), address(executor), address(executor).codehash, uint32(600_000), uint16(2_500))
        );
        vm.warp(vm.getBlockTimestamp() + DELAY);
        registry.openLaneOf(address(root), address(executor), address(executor).codehash, 600_000, 2_500);
        (HookrRoot r, HookrRules c) = _deployOwned(_sel(brand, F.ALL_FEATURES));
        (address active,,,) = IHookrLanes(address(registry)).activeLaneOf(address(r));
        assertEq(active, address(0), "no active lane: no arb recapture");
        (bool on, uint32 cap) = IHookrLanes(address(registry)).executorLane(address(r), address(executor));
        assertFalse(on);
        assertEq(cap, 600_000);
        (address templateLane,,,) = IHookrLanes(address(registry)).activeLaneOf(address(root));
        assertEq(templateLane, address(executor), "the template's lane is untouched");
        // A pool asking for arb recapture is refused at launch.
        IHookrLauncher.Member memory recapturing = _withRecapture(_nativeMember(address(c), _rc(), 0));
        vm.expectRevert(IHookrRootEvents.InvalidConfig.selector);
        this.launchExternal(stranger, address(r), recapturing);
        // A plain pool opens without a lane.
        (, PoolKey memory key,) = _launchAs(stranger, address(r), _nativeMember(address(c), _rc(), 0));
        (address frozen,,,,,, uint256 floor) = IHookrLaneRoot(address(r)).laneOf(key.toId());
        assertEq(frozen, address(0));
        assertEq(floor, 0, "no lane gas floor");
    }

    /// @notice With no open lane on the template the root copies none: no lane, and no switch to turn on later.
    function test_noTemplateLaneCopiesNothing() public {
        MockIdleExecutor executor = new MockIdleExecutor();
        (HookrRoot r,) = _deployOwned(_sel(brand, F.ALL_FEATURES));
        (address active,,,) = IHookrLanes(address(registry)).activeLaneOf(address(r));
        assertEq(active, address(0));
        (bool on, uint32 cap) = IHookrLanes(address(registry)).executorLane(address(r), address(executor));
        assertFalse(on);
        assertEq(cap, 0);
    }

    // ───────────────────────────── custody and gas ─────────────────────────────

    function test_factoryHoldsNothingAndHasNoOwner() public {
        _deployOwned(_sel(brand, F.ALL_FEATURES));
        assertEq(address(factory).balance, 0);
        (bool ok,) = address(factory).call{value: 1}("");
        assertFalse(ok, "no receive");
        (ok,) = address(factory).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "no owner");
    }

    /// @notice Measured locally (the fork measurement is OwnedRootsForkGas.t.sol): the execution gas of one owned-root
    ///         deployment, without the transaction's intrinsic and calldata cost.
    function test_measureDeployGas() public {
        bytes32 salt = _mine(brand);
        IHookrOwnedRootFactory.RootSelections memory sel = _sel(brand, F.ALL_FEATURES);
        uint256 fee = _fee(factory);
        vm.prank(brand);
        uint256 before = gasleft();
        address owned = _deployCallWith(factory, fee, code, rulesCode, sel, salt);
        uint256 used = before - gasleft();
        console2.log("factory.deploy execution gas (root, lane module, rules, recapture module, registration)", used);
        console2.log("root runtime bytes", owned.code.length);
        console2.log("rules runtime bytes", factory.rulesOf(owned).code.length);
        console2.log("factory runtime bytes", address(factory).code.length);
        console2.log("book runtime bytes", address(book).code.length);
        console2.log("lens runtime bytes", address(lens).code.length);
        assertLe(address(factory).code.length, 24_576, "factory stays under EIP-170");
        assertLe(address(book).code.length, 24_576, "book stays under EIP-170");
        assertLe(address(lens).code.length, 24_576, "lens stays under EIP-170");
        assertLt(used, 30_000_000);
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _expectBad(
        IHookrRegistry reg,
        HookrOwnedProfiles book_,
        address template_,
        address templateRules_,
        address treasury_,
        bytes32 rootHash,
        bytes32 rulesHash,
        uint256 cap
    ) internal {
        vm.expectRevert();
        new HookrOwnedRootFactory(reg, book_, template_, templateRules_, treasury_, rootHash, rulesHash, cap);
    }

    function _otherManager() internal returns (address) {
        return deployCode("PoolManager.sol:PoolManager", abi.encode(address(this)));
    }

    /// @dev A HookrRoot this test deploys itself (CREATE2, mined for the flags) with `curated` as curated router.
    function _orphanRoot(address curated) internal returns (HookrRoot orphan) {
        bytes32 initHash = ReleaseWiring.rootInitHash(manager, registry, address(router), address(quoter), curated);
        uint256 counter =
            ReleaseWiring.mineSalt(address(this), initHash, ReleaseWiring.ROOT_FLAGS, (1 << 60) + (++saltNonce << 40));
        orphan = new HookrRoot{salt: bytes32(counter)}(manager, registry, address(router), address(quoter), curated);
    }

    /// @dev A second root registered by a queued REGISTER_ROOT, with a Rules module paying the treasury admitted on it.
    function _secondSharedRoot() internal returns (HookrRoot second, HookrRules secondRules) {
        second = _orphanRoot(address(0));
        ReleaseWiring.queueRoot(registry, address(second));
        ReleaseWiring.waitDelay(registry);
        ReleaseWiring.registerRoot(registry, address(second));
        secondRules = new HookrRules(manager, registry, address(hookrTreasury), address(second), PROTOCOL_FLOOR);
        _admit(address(second), _rulesAdmission(address(secondRules)));
    }
}
