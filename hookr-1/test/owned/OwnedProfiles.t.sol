// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrOwnedProfiles} from "../../src/owned/HookrOwnedProfiles.sol";
import {HookrOwnedRootTypes as F} from "../../src/libraries/HookrOwnedRootTypes.sol";
import {IHookrOwnedProfiles} from "../../src/interfaces/IHookrOwnedProfiles.sol";
import {OwnedZeroAdvisory, OwnedGateStub} from "./OwnedRootsMocks.sol";
import {OwnedRootsFixture} from "./OwnedRootsFixture.sol";

/// @notice Tier 1: owned profiles on the shared root, written in the record book, that pools commit to at launch and
///         are recorded into when their frozen terms fit.
contract OwnedProfilesTest is OwnedRootsFixture {
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant NO_SNIPE_NO_DYNAMIC = F.AUTO_BURN | F.LP_REWARDS | F.ROYALTY;

    function setUp() public {
        _setUpOwned();
    }

    function launchExternal(address rootAddr, IHookrLauncher.Member memory m)
        external
        returns (bytes32 family, PoolKey memory key, address subject)
    {
        return _launchAs(stranger, rootAddr, m);
    }

    /// @notice Step 1. The user picks a rule subset, fee caps, the recapture lane on or off, public or owner-only.
    function test_step1_userPicksRuleSubsetCapsAndLane() public {
        IHookrOwnedProfiles.Profile memory p = _profile(NO_SNIPE_NO_DYNAMIC, false, brand);
        p.laneEnabled = false;
        // Caps above the RULES admission are refused.
        p.caps = HookrTypes.Caps(600_001, 100_000, 500);
        vm.prank(brand);
        vm.expectRevert(IHookrOwnedProfiles.InvalidProfile.selector);
        book.writeProfile(bytes32("brand"), p);
        // A feature bit outside Hookr 1 is refused.
        p.caps = HookrTypes.Caps(50_000, 100_000, 500);
        p.ruleMask = bytes32(uint256(32));
        vm.prank(brand);
        vm.expectRevert(IHookrOwnedProfiles.InvalidProfile.selector);
        book.writeProfile(bytes32("brand"), p);
        p.ruleMask = NO_SNIPE_NO_DYNAMIC;
        vm.expectEmit(true, true, true, false, address(book));
        emit IHookrOwnedProfiles.ProfileWritten(book.profileIdOf(brand, bytes32("brand")), address(root), brand, 1, p);
        vm.prank(brand);
        bytes32 id = book.writeProfile(bytes32("brand"), p);
        assertEq(id, book.profileIdOf(brand, bytes32("brand")));
        IHookrOwnedProfiles.Profile memory stored = book.profile(id);
        assertEq(stored.root, address(root));
        assertEq(stored.rules, address(sharedRules));
        assertEq(stored.caps.maxLpFeePips, 50_000);
        assertEq(stored.ruleMask, NO_SNIPE_NO_DYNAMIC);
        assertFalse(stored.laneEnabled);
        assertFalse(stored.publicOpening);
        assertEq(stored.owner, brand);
        assertEq(stored.version, 1);
        p.laneEnabled = true;
        vm.prank(brand);
        book.writeProfile(bytes32("brand-lane"), p);
    }

    /// @notice Step 2. The book keeps it as an owned profile on the shared root; pools join it by commitment at launch
    ///         and a recording that checks their frozen terms.
    function test_step2_ownedProfileOnSharedRoot() public {
        IHookrOwnedProfiles.Profile memory p = _profile(NO_SNIPE_NO_DYNAMIC, false, brand);
        p.caps = HookrTypes.Caps(50_000, 100_000, 500);
        vm.prank(brand);
        bytes32 id = book.writeProfile(bytes32("brand"), p);

        IHookrLauncher.Member memory m = _nativeMember(address(sharedRules), _rc(), id);
        m.config.caps = p.caps;
        (, PoolKey memory key,) = _launchAs(brand, address(root), m);
        PoolId pid = key.toId();
        assertEq(address(key.hooks), address(root), "tier 1 keeps the shared root");
        assertTrue(book.profileConforms(id, pid));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedProfiles.NotProfileOwner.selector, id, stranger));
        book.adoptPool(id, pid);

        vm.expectEmit(true, true, true, true, address(book));
        emit IHookrOwnedProfiles.PoolAdopted(id, address(root), pid, 1);
        vm.prank(brand);
        book.adoptPool(id, pid);
        IHookrOwnedProfiles.Adoption memory a = book.adoption(address(root), pid);
        assertEq(a.profileId, id);
        assertEq(a.version, 1);

        vm.prank(brand);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedProfiles.AlreadyAdopted.selector, address(root), pid));
        book.adoptPool(id, pid);

        // A pool that names the profile but uses the dynamic fee (outside the subset) cannot join it.
        HookrTypes.RulesConfig memory dynamicFee = _rc();
        dynamicFee.dynamicFeeSens = DYNAMIC_FEE_SENS;
        dynamicFee.maxFeePips = 10_000;
        IHookrLauncher.Member memory m2 = _nativeMember(address(sharedRules), dynamicFee, id);
        m2.config.caps = p.caps;
        (, PoolKey memory key2,) = _launchAs(brand, address(root), m2);
        assertFalse(book.profileConforms(id, key2.toId()));
        vm.prank(brand);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedProfiles.OutsideProfile.selector, id));
        book.adoptPool(id, key2.toId());

        // A conforming pool that did not commit to the profile at launch cannot join it either.
        IHookrLauncher.Member memory m3 = _nativeMember(address(sharedRules), _rc(), bytes32("other"));
        m3.config.caps = p.caps;
        (, PoolKey memory key3,) = _launchAs(brand, address(root), m3);
        assertFalse(book.profileConforms(id, key3.toId()));

        // Profile pools keep the shared router, fees and claims.
        (uint256 amountIn, uint256 amountOut) = _trade(key, true, true, 1 ether);
        assertEq(amountIn, 1 ether);
        assertGt(amountOut, 0);
        assertGt(sharedRules.claimable(ETH, address(hookrTreasury)), 0);
        assertTrue(sharedRules.accountingInvariant(ETH));
    }

    /// @notice A profile that leaves the lane out takes no pool that froze the root's lane.
    function test_laneSwitchDecidesWhetherRecapturePoolsFit() public {
        _openSharedLane();
        IHookrOwnedProfiles.Profile memory off = _profile(F.ALL_FEATURES, true, brand);
        off.laneEnabled = false;
        vm.prank(brand);
        bytes32 noLane = book.writeProfile(bytes32("no-lane"), off);
        vm.prank(brand);
        bytes32 withLane = book.writeProfile(bytes32("lane"), _profile(F.ALL_FEATURES, true, brand));
        (, PoolKey memory recapturing,) =
            _launchAs(stranger, address(root), _withRecapture(_nativeMember(address(sharedRules), _rc(), noLane)));
        (, PoolKey memory plain,) =
            _launchAs(stranger, address(root), _nativeMember(address(sharedRules), _rc(), noLane));
        assertFalse(book.profileConforms(noLane, recapturing.toId()), "the pool froze the lane");
        assertTrue(book.profileConforms(noLane, plain.toId()));
        (, PoolKey memory recapturing2,) =
            _launchAs(stranger, address(root), _withRecapture(_nativeMember(address(sharedRules), _rc(), withLane)));
        assertTrue(book.profileConforms(withLane, recapturing2.toId()));
    }

    function test_profileWriteValidation() public {
        IHookrOwnedProfiles.Profile memory p = _profile(F.ALL_FEATURES, true, brand);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedProfiles.NotProfileOwner.selector, bytes32(0), stranger));
        book.writeProfile(bytes32("x"), p);

        p.rules = address(0xBAD);
        vm.prank(brand);
        vm.expectRevert(IHookrOwnedProfiles.InvalidProfile.selector);
        book.writeProfile(bytes32("x"), p);

        p.rules = address(0);
        vm.prank(brand);
        vm.expectRevert(IHookrOwnedProfiles.InvalidProfile.selector);
        book.writeProfile(bytes32("x"), p);

        // An advisory the registry never admitted on the root.
        p = _profile(F.ALL_FEATURES, true, brand);
        p.advisories = new address[](1);
        p.advisories[0] = address(new OwnedZeroAdvisory());
        vm.prank(brand);
        vm.expectRevert(IHookrOwnedProfiles.InvalidProfile.selector);
        book.writeProfile(bytes32("x"), p);

        // Five advisories, or five gates, are one too many.
        p = _profile(F.ALL_FEATURES, true, brand);
        p.advisories = new address[](5);
        vm.prank(brand);
        vm.expectRevert(IHookrOwnedProfiles.InvalidProfile.selector);
        book.writeProfile(bytes32("x"), p);
        p = _profile(F.ALL_FEATURES, true, brand);
        p.gates = new address[](5);
        vm.prank(brand);
        vm.expectRevert(IHookrOwnedProfiles.InvalidProfile.selector);
        book.writeProfile(bytes32("x"), p);

        // A profile cannot name an owned root.
        (HookrRoot owned,) = _deployOwned(_sel(brand, F.ALL_FEATURES));
        p = _profile(F.ALL_FEATURES, true, brand);
        p.root = address(owned);
        vm.prank(brand);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedProfiles.InvalidRoot.selector, address(owned)));
        book.writeProfile(bytes32("x"), p);

        // Nor an unregistered root.
        p.root = address(0x1234);
        vm.prank(brand);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedProfiles.InvalidRoot.selector, address(0x1234)));
        book.writeProfile(bytes32("x"), p);
    }

    /// @notice A root the registry closed, retired or paused takes no new profile; the brakes are the registry's.
    function test_closedRetiredOrPausedRootTakesNoNewProfile() public {
        IHookrOwnedProfiles.Profile memory p = _profile(F.ALL_FEATURES, true, brand);
        registry.pauseNewMarkets();
        vm.prank(brand);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedProfiles.InvalidRoot.selector, address(root)));
        book.writeProfile(bytes32("x"), p);
        registry.queue(registry.RESUME_NEW_MARKETS(), "");
        vm.warp(vm.getBlockTimestamp() + DELAY);
        registry.resumeNewMarkets();
        registry.closeRoot(address(root));
        vm.prank(brand);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedProfiles.InvalidRoot.selector, address(root)));
        book.writeProfile(bytes32("x"), p);
        registry.queue(registry.REOPEN_ROOT(), abi.encode(address(root)));
        vm.warp(vm.getBlockTimestamp() + DELAY);
        registry.reopenRoot(address(root));
        vm.prank(brand);
        book.writeProfile(bytes32("x"), p);
        registry.queue(registry.RETIRE_ROOT(), abi.encode(address(root)));
        vm.warp(vm.getBlockTimestamp() + DELAY);
        registry.retireRoot(address(root));
        vm.prank(brand);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedProfiles.InvalidRoot.selector, address(root)));
        book.writeProfile(bytes32("y"), p);
    }

    /// @notice Listed advisories and gates are live admissions of the root, named once; a profile pool may bind a
    ///         listed advisory.
    function test_profileAdvisoriesAndGates() public {
        OwnedZeroAdvisory adv = new OwnedZeroAdvisory();
        OwnedGateStub gate = new OwnedGateStub();
        _admit(address(root), _advisoryAdmission(address(adv)));
        _admit(address(root), _gateAdmission(address(gate)));
        IHookrOwnedProfiles.Profile memory p = _profile(F.ALL_FEATURES, true, brand);
        p.advisories = new address[](2);
        (p.advisories[0], p.advisories[1]) = (address(adv), address(adv));
        vm.prank(brand);
        vm.expectRevert(IHookrOwnedProfiles.InvalidProfile.selector);
        book.writeProfile(bytes32("adv"), p);
        // The kinds are not interchangeable.
        p.advisories = new address[](1);
        p.advisories[0] = address(gate);
        vm.prank(brand);
        vm.expectRevert(IHookrOwnedProfiles.InvalidProfile.selector);
        book.writeProfile(bytes32("adv"), p);
        p.advisories[0] = address(adv);
        p.gates = new address[](1);
        p.gates[0] = address(adv);
        vm.prank(brand);
        vm.expectRevert(IHookrOwnedProfiles.InvalidProfile.selector);
        book.writeProfile(bytes32("adv"), p);
        p.gates = new address[](2);
        (p.gates[0], p.gates[1]) = (address(gate), address(gate));
        vm.prank(brand);
        vm.expectRevert(IHookrOwnedProfiles.InvalidProfile.selector);
        book.writeProfile(bytes32("adv"), p);
        p.gates = new address[](1);
        p.gates[0] = address(gate);
        vm.prank(brand);
        bytes32 id = book.writeProfile(bytes32("adv"), p);
        assertEq(book.profile(id).advisories[0], address(adv));
        assertEq(book.profile(id).gates[0], address(gate));
        // A pool carrying the listed advisory conforms and is recordable by anyone (public profile).
        IHookrLauncher.Member memory m = _nativeMember(address(sharedRules), _rc(), id);
        m.config.advisory = address(adv);
        m.config.advisoryGasLimit = 100_000;
        m.config.advisoryPhases = HookrTypes.BEFORE_SWAP;
        IHookrLauncher.Member[] memory ms = _members(m);
        bytes[] memory advisoryConfigs = new bytes[](1);
        IHookrLauncher.Token memory t = _newToken();
        vm.prank(stranger);
        (bytes32 family,) =
            launcher.launchAdvised{value: m.amount0Max}(t, address(root), ms, advisoryConfigs, vm.getBlockTimestamp());
        PoolId pid = launcher.position(family, 0).key.toId();
        assertTrue(book.profileConforms(id, pid));
        vm.prank(trader);
        book.adoptPool(id, pid);
        assertEq(book.adoption(address(root), pid).profileId, id);
        // The same pool does not conform to a profile that does not list the advisory.
        assertFalse(book.profileConforms(templateProfile, pid));
        // A listed admission revoked later leaves the written profile as it was; new writes refuse it.
        registry.revokeModuleAdmission(address(root), address(gate));
        assertEq(book.profile(id).gates[0], address(gate));
        vm.prank(brand);
        vm.expectRevert(IHookrOwnedProfiles.InvalidProfile.selector);
        book.writeProfile(bytes32("adv"), p);
    }

    /// @notice A profile lists at most four live advisories and four live gates: five distinct live admissions are one
    ///         too many, four are accepted. Mutation gate OW-9 (a fifth advisory was accepted).
    function test_aProfileListsAtMostFourAdvisoriesAndFourGates() public {
        address[] memory advisories = new address[](5);
        address[] memory gates = new address[](5);
        for (uint256 i; i < 5; ++i) {
            advisories[i] = address(new OwnedZeroAdvisory());
            gates[i] = address(new OwnedGateStub());
            _admit(address(root), _advisoryAdmission(advisories[i]));
            _admit(address(root), _gateAdmission(gates[i]));
        }
        IHookrOwnedProfiles.Profile memory p = _profile(F.ALL_FEATURES, true, brand);
        p.advisories = advisories;
        vm.prank(brand);
        vm.expectRevert(IHookrOwnedProfiles.InvalidProfile.selector);
        book.writeProfile(bytes32("five"), p);
        p.advisories = new address[](4);
        for (uint256 i; i < 4; ++i) {
            p.advisories[i] = advisories[i];
        }
        p.gates = gates;
        vm.prank(brand);
        vm.expectRevert(IHookrOwnedProfiles.InvalidProfile.selector);
        book.writeProfile(bytes32("five"), p);
        p.gates = new address[](4);
        for (uint256 i; i < 4; ++i) {
            p.gates[i] = gates[i];
        }
        vm.prank(brand);
        bytes32 id = book.writeProfile(bytes32("four"), p);
        assertEq(book.profile(id).advisories.length, 4);
        assertEq(book.profile(id).gates.length, 4);
    }

    function test_profileRewriteBumpsVersionAndAdoptionsKeepTheirs() public {
        IHookrOwnedProfiles.Profile memory p = _profile(NO_SNIPE_NO_DYNAMIC, false, brand);
        vm.prank(brand);
        bytes32 id = book.writeProfile(bytes32("v"), p);
        (, PoolKey memory key,) = _launchAs(brand, address(root), _nativeMember(address(sharedRules), _rc(), id));
        vm.prank(brand);
        book.adoptPool(id, key.toId());
        p.ruleMask = F.ALL_FEATURES;
        vm.prank(brand);
        assertEq(book.writeProfile(bytes32("v"), p), id);
        assertEq(book.profile(id).version, 2);
        assertEq(book.profileAt(id, 1).ruleMask, NO_SNIPE_NO_DYNAMIC, "every version stays readable");
        assertEq(book.adoption(address(root), key.toId()).version, 1, "a record keeps the version it was checked at");
        // Owned roots keep the version they were derived from.
        (HookrRoot owned,) = _deployOwned(_selFor(id, brand, F.ALL_FEATURES, true));
        assertEq(factory.ownedRoot(address(owned)).profileVersion, 2);
    }

    function test_adoptionEdgeCases() public {
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedProfiles.UnknownProfile.selector, bytes32("none")));
        book.adoptPool(bytes32("none"), PoolId.wrap(bytes32(0)));
        assertFalse(book.profileConforms(bytes32("none"), PoolId.wrap(bytes32(0))));
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedProfiles.OutsideProfile.selector, templateProfile));
        book.adoptPool(templateProfile, PoolId.wrap(bytes32(uint256(1))));
        vm.expectRevert(
            abi.encodeWithSelector(IHookrOwnedProfiles.NotAdopted.selector, address(root), PoolId.wrap(bytes32(0)))
        );
        book.dropAdoption(address(root), PoolId.wrap(bytes32(0)));
        // Declared caps above the profile's make a pool non-conforming.
        IHookrOwnedProfiles.Profile memory p = _profile(F.ALL_FEATURES, true, brand);
        p.caps = HookrTypes.Caps(100_000, 100_000, 500);
        vm.prank(brand);
        bytes32 id = book.writeProfile(bytes32("caps"), p);
        IHookrLauncher.Member memory m = _nativeMember(address(sharedRules), _rc(), id);
        (, PoolKey memory key,) = _launchAs(stranger, address(root), m);
        assertFalse(book.profileConforms(id, key.toId()));
        m.config.caps = p.caps;
        (, key,) = _launchAs(stranger, address(root), m);
        assertTrue(book.profileConforms(id, key.toId()));
        // A pool on another Rules module of the root does not conform.
        IHookrLauncher.Member memory other = _nativeMember(address(rules), _rc(), id);
        other.config.caps = p.caps;
        (, key,) = _launchAs(stranger, address(root), other);
        assertFalse(book.profileConforms(id, key.toId()));
        // A pool of another root never conforms, even one committing to the same id.
        (HookrRoot owned, HookrRules ownedRules) = _deployOwned(_sel(brand, F.ALL_FEATURES));
        (, PoolKey memory ownedKey,) =
            _launchAs(stranger, address(owned), _nativeMember(address(ownedRules), _rc(), id));
        assertFalse(book.profileConforms(id, ownedKey.toId()));
    }

    /// @notice Nobody writes into another account's profile id, and nobody records a pool into an owner-only profile.
    function test_attack_profileSquatAndForeignAdoption() public {
        IHookrOwnedProfiles.Profile memory p = _profile(F.ALL_FEATURES, false, brand);
        vm.prank(brand);
        bytes32 id = book.writeProfile(bytes32("brand"), p);
        IHookrOwnedProfiles.Profile memory q = _profile(0, false, stranger);
        vm.prank(stranger);
        bytes32 other = book.writeProfile(bytes32("brand"), q);
        assertTrue(other != id);
        assertEq(book.profile(id).ruleMask, F.ALL_FEATURES, "the brand's profile is untouched");
        (, PoolKey memory key,) = _launchAs(stranger, address(root), _nativeMember(address(sharedRules), _rc(), id));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedProfiles.NotProfileOwner.selector, id, stranger));
        book.adoptPool(id, key.toId());
    }

    function testFuzz_profileCapsAcceptedIffWithinTheRulesAdmission(uint24 lp, uint24 q, uint16 s) public {
        IHookrOwnedProfiles.Profile memory p = _profile(F.ALL_FEATURES, true, brand);
        p.caps = HookrTypes.Caps(lp, q, s);
        bool ok = lp <= 600_000 && q <= 200_000 && s <= 1000;
        vm.prank(brand);
        if (!ok) vm.expectRevert(IHookrOwnedProfiles.InvalidProfile.selector);
        bytes32 id = book.writeProfile(bytes32("f"), p);
        if (ok) {
            HookrTypes.Caps memory stored = book.profile(id).caps;
            assertEq(stored.maxLpFeePips, lp);
            assertEq(stored.maxQuoteTakePips, q);
            assertEq(stored.maxSubjectTakeBps, s);
        }
    }

    /// @notice Tier-1 conformance is exactly "the pool's features are a subset of the profile's".
    /// forge-config: default.fuzz.runs = 96
    function testFuzz_profileConformanceIsTheFeatureSubset(uint8 profileBits, uint8 poolBits) public {
        bytes32 mask = bytes32(uint256(profileBits) & 31);
        IHookrOwnedProfiles.Profile memory p = _profile(mask, true, brand);
        vm.prank(brand);
        bytes32 id = book.writeProfile(bytes32("fuzz"), p);
        HookrTypes.RulesConfig memory c;
        c.maxFeePips = 3000;
        if (poolBits & 1 != 0) c.guardEndBlock = uint40(block.number + 10);
        if (poolBits & 2 != 0) {
            c.dynamicFeeSens = DYNAMIC_FEE_SENS;
            c.maxFeePips = 10_000;
        }
        if (poolBits & 4 != 0) c.burnBps = 100;
        if (poolBits & 8 != 0) c.lpBps = 200;
        if (poolBits & 16 != 0 && c.lpBps != 0) {
            c.royaltyBps = 500;
            c.royaltyTo = royalty;
        }
        c.protocolShareBps = 2500;
        (, PoolKey memory key,) = this.launchExternal(address(root), _nativeMember(address(sharedRules), c, id));
        bool expected = F.features(c) & ~mask == 0;
        assertEq(book.profileConforms(id, key.toId()), expected);
        if (expected) {
            book.adoptPool(id, key.toId());
        } else {
            vm.expectRevert(abi.encodeWithSelector(IHookrOwnedProfiles.OutsideProfile.selector, id));
            book.adoptPool(id, key.toId());
        }
    }

    function test_bookHasNoOwnerAndHoldsNothing() public {
        assertEq(address(book.registry()), address(registry));
        assertEq(book.MAX_PROFILE_ADVISORIES(), 4);
        assertEq(book.MAX_PROFILE_GATES(), 4);
        assertEq(address(book).balance, 0);
        (bool ok,) = address(book).call{value: 1}("");
        assertFalse(ok, "no receive");
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedProfiles.InvalidRoot.selector, address(0xBEEF)));
        new HookrOwnedProfiles(IHookrRegistry(address(0xBEEF)));
    }

    /// @dev An idle executor opened as the shared root's lane through the timelock.
    function _openSharedLane() internal returns (address executor) {
        executor = address(new IdleLaneExecutor());
        bytes32 openLane = keccak256("OPEN_LANE");
        registry.queue(openLane, abi.encode(address(root), executor, executor.codehash, uint32(600_000), uint16(2_500)));
        vm.warp(vm.getBlockTimestamp() + DELAY);
        registry.openLaneOf(address(root), executor, executor.codehash, 600_000, 2_500);
    }
}

/// @notice A lane executor that does nothing on each lane call.
contract IdleLaneExecutor {
    function executeArbitrage(PoolKey calldata, address) external pure returns (uint256) {
        return 0;
    }
}
