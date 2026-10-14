// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {HookrOwnedRootsLens} from "../../src/lens/HookrOwnedRootsLens.sol";
import {HookrOwnedRootTypes as F} from "../../src/libraries/HookrOwnedRootTypes.sol";
import {IHookrOwnedRootFactory} from "../../src/interfaces/IHookrOwnedRootFactory.sol";
import {IHookrOwnedRootsLens} from "../../src/interfaces/IHookrOwnedRootsLens.sol";
import {IHookrOwnedProfiles} from "../../src/interfaces/IHookrOwnedProfiles.sol";
import {OwnedZeroAdvisory, OwnedGateStub} from "./OwnedRootsMocks.sol";
import {OwnedRootsFixture} from "./OwnedRootsFixture.sol";

/// @notice The creator knobs with their on-chain bounds and defaults (the view-only lens), and the runtime sizes
///         against EIP-170.
contract OwnedRootsLensTest is OwnedRootsFixture {
    function setUp() public {
        _setUpOwned();
    }

    // ───────────────────────────── profiles ─────────────────────────────

    /// @notice Profile bounds: the caps of the RULES admission (zero for a module without one), every feature, and the
    ///         book's advisory and gate limits; a profile above them is refused.
    function test_profileBoundsAreTheAdmission() public {
        assertEq(lens.ALL_FEATURES(), F.ALL_FEATURES);
        (HookrTypes.Caps memory maxCaps, bytes32 maxMask, uint256 maxAdvisories, uint256 maxGates) =
            lens.profileBounds(book, address(root), address(sharedRules));
        assertEq(maxCaps.maxLpFeePips, 600_000);
        assertEq(maxCaps.maxQuoteTakePips, 200_000);
        assertEq(maxCaps.maxSubjectTakeBps, 1_000);
        assertEq(maxMask, F.ALL_FEATURES);
        assertEq(maxAdvisories, book.MAX_PROFILE_ADVISORIES());
        assertEq(maxGates, book.MAX_PROFILE_GATES());
        (maxCaps,,,) = lens.profileBounds(book, address(root), address(0xBEEF));
        assertEq(maxCaps.maxLpFeePips, 0);
        IHookrOwnedProfiles.Profile memory p = _profile(F.ALL_FEATURES, true, brand);
        p.caps.maxQuoteTakePips = 200_001;
        vm.prank(brand);
        vm.expectRevert(IHookrOwnedProfiles.InvalidProfile.selector);
        book.writeProfile(bytes32("above"), p);
    }

    /// @notice The default profile writes as is; with no RULES admission its caps read zero and the write is refused.
    function test_defaultProfileWritesAsIs() public {
        IHookrOwnedProfiles.Profile memory p = lens.defaultProfile(book, address(root), address(sharedRules), brand);
        assertEq(p.root, address(root));
        assertEq(p.rules, address(sharedRules));
        assertEq(p.advisories.length, 0);
        assertEq(p.gates.length, 0);
        assertEq(p.caps.maxLpFeePips, 600_000);
        assertEq(p.ruleMask, F.ALL_FEATURES);
        assertTrue(p.laneEnabled, "the lane allowed by default");
        assertTrue(p.publicOpening, "public by default");
        assertEq(p.owner, brand);
        vm.prank(brand);
        bytes32 id = book.writeProfile(bytes32("default"), p);
        assertEq(book.profile(id).version, 1);
        IHookrOwnedProfiles.Profile memory none = lens.defaultProfile(book, address(root), address(0xBEEF), brand);
        assertEq(none.caps.maxLpFeePips, 0);
        vm.prank(brand);
        vm.expectRevert(IHookrOwnedProfiles.InvalidProfile.selector);
        book.writeProfile(bytes32("none"), none);
    }

    /// @notice The book, the lens, the registry and the treasury each stay under 24,576 bytes (EIP-170).
    function test_runtimeSizesStayPortable() public view {
        assertLe(address(book).code.length, 24_576, "profile book");
        assertLe(address(lens).code.length, 24_576, "lens");
        assertLe(address(registry).code.length, 24_576, "registry");
        assertLe(address(hookrTreasury).code.length, 24_576, "treasury");
    }

    function test_lensHasNoStateAndHoldsNothing() public {
        HookrOwnedRootsLens fresh = new HookrOwnedRootsLens(address(0));
        assertEq(address(fresh).code.length, address(lens).code.length);
        assertEq(address(fresh).codehash, address(lens).codehash, "no state: the family router is its one immutable");
        (bool ok,) = address(lens).call{value: 1}("");
        assertFalse(ok);
    }

    // ───────────────────────────── owned roots ─────────────────────────────

    /// @notice The standard profile's bounds, complete defaults that deploy as they are, and the constants behind them.
    function test_defaultSelectionsDeployAndMatchTheBounds() public {
        assertEq(lens.PUBLIC_REQUIRED_FEATURES(), F.SOFT_FEATURES);
        IHookrOwnedRootsLens.SelectionBounds memory b = lens.selectionBounds(factory, templateProfile, brand);
        assertEq(b.profileVersion, 1);
        assertEq(b.maxRuleMask, F.ALL_FEATURES);
        assertEq(b.publicRequiredMask, F.SOFT_FEATURES);
        assertTrue(b.publicAllowed);
        assertTrue(b.deployerAllowed);
        assertEq(b.caps.maxLpFeePips, 600_000);
        assertEq(b.caps.maxQuoteTakePips, 200_000);
        assertEq(b.caps.maxSubjectTakeBps, 1_000);
        assertFalse(b.laneCopied, "the template has no open lane");
        assertEq(b.fee, hookrTreasury.ownedRootFee());
        assertEq(b.fee, 0.01 ether, "the release default");
        assertTrue(b.deployable);
        IHookrOwnedRootFactory.RootSelections memory d = lens.defaultSelections(factory, templateProfile, brand);
        assertEq(d.profileId, templateProfile);
        assertEq(d.profileVersion, 1);
        assertEq(d.ruleMask, F.ALL_FEATURES);
        assertTrue(d.publicOpening);
        assertEq(d.owner, brand);
        (HookrRoot owned,) = _deployOwned(d);
        assertEq(factory.ownedRoot(address(owned)).ruleMask, F.ALL_FEATURES);
        assertEq(factory.ownedRoot(address(owned)).owner, brand);
        assertTrue(registry.rootOpen(address(owned)));
    }

    /// @notice A default profile seeds a public root with the default selections, at the admission's caps.
    function test_aDefaultProfileSeedsAPublicRoot() public {
        IHookrOwnedProfiles.Profile memory p = lens.defaultProfile(book, address(root), address(sharedRules), brand);
        vm.prank(brand);
        bytes32 id = book.writeProfile(bytes32("default"), p);
        assertTrue(lens.selectionBounds(factory, id, stranger).deployable, "a public default profile seeds anyone");
        (HookrRoot owned, HookrRules companion) = _deployOwned(lens.defaultSelections(factory, id, stranger));
        assertEq(registry.admission(address(owned), address(companion)).caps.maxLpFeePips, 600_000);
        assertTrue(factory.ownedRoot(address(owned)).publicOpening);
    }

    /// @notice With the template's lane open the bounds say the root copies it, braked.
    function test_boundsReportTheBrakedLaneCopy() public {
        address executor = address(new LensIdleExecutor());
        registry.queue(
            keccak256("OPEN_LANE"),
            abi.encode(address(root), executor, executor.codehash, uint32(600_000), uint16(2_500))
        );
        vm.warp(vm.getBlockTimestamp() + DELAY);
        registry.openLaneOf(address(root), executor, executor.codehash, 600_000, 2_500);
        assertTrue(lens.selectionBounds(factory, templateProfile, brand).laneCopied);
        (HookrRoot owned,) = _deployOwned(lens.defaultSelections(factory, templateProfile, brand));
        (address active,,,) = registry.activeLaneOf(address(owned));
        assertEq(active, address(0), "copied braked");
    }

    /// @notice A profile without every soft feature seeds owner-only roots only; a private profile is usable by its
    ///         owner alone; the brakes, the fee and the cap move the bounds.
    function test_boundsFollowTheProfileAndTheBrakes() public {
        bytes32 mask = F.AUTO_BURN | F.LP_REWARDS | F.ROYALTY;
        IHookrOwnedProfiles.Profile memory p = _profile(mask, false, brand);
        p.caps = HookrTypes.Caps(100_000, 100_000, 500);
        vm.prank(brand);
        bytes32 id = book.writeProfile(bytes32("brand"), p);
        IHookrOwnedRootsLens.SelectionBounds memory b = lens.selectionBounds(factory, id, brand);
        assertEq(b.maxRuleMask, mask);
        assertFalse(b.publicAllowed);
        assertEq(b.caps.maxLpFeePips, 100_000);
        assertTrue(b.deployable, "an owner-only root keeps any subset");
        IHookrOwnedRootFactory.RootSelections memory d = lens.defaultSelections(factory, id, brand);
        assertFalse(d.publicOpening, "the default is owner-only when public is not possible");
        (HookrRoot ownerOnly,) = _deployOwned(d);
        assertFalse(factory.ownedRoot(address(ownerOnly)).publicOpening);
        assertFalse(lens.selectionBounds(factory, id, stranger).deployerAllowed, "private profile, not its owner");
        assertFalse(lens.selectionBounds(factory, id, stranger).deployable);
        assertEq(lens.selectionBounds(factory, bytes32("none"), brand).profileVersion, 0);
        assertFalse(lens.selectionBounds(factory, bytes32("none"), brand).deployable);
        // A profile on the template whose Rules do not pay the factory's treasury.
        IHookrOwnedProfiles.Profile memory q = _profile(F.ALL_FEATURES, true, brand);
        q.rules = address(rules);
        vm.prank(brand);
        bytes32 unpaid = book.writeProfile(bytes32("unpaid"), q);
        assertFalse(lens.selectionBounds(factory, unpaid, brand).deployable);
        registry.pauseNewMarkets();
        assertFalse(lens.selectionBounds(factory, templateProfile, brand).deployable, "paused");
        registry.queue(registry.RESUME_NEW_MARKETS(), "");
        vm.warp(vm.getBlockTimestamp() + DELAY);
        registry.resumeNewMarkets();
        assertTrue(lens.selectionBounds(factory, templateProfile, brand).deployable);
        registry.closeRoot(address(root));
        assertFalse(lens.selectionBounds(factory, templateProfile, brand).deployable, "template root closed");
        registry.queue(registry.REOPEN_ROOT(), abi.encode(address(root)));
        vm.warp(vm.getBlockTimestamp() + DELAY);
        registry.reopenRoot(address(root));
        _setDeployFee(0.5 ether);
        assertEq(lens.selectionBounds(factory, templateProfile, brand).fee, 0.5 ether, "the fee follows the treasury");
        registry.deactivateRootFactory(address(factory));
        assertFalse(lens.selectionBounds(factory, templateProfile, brand).deployable, "factory deactivated");
    }

    /// @notice A profile whose listed advisory or gate the template no longer holds is not deployable: the registry
    ///         would refuse the copy.
    function test_boundsReportARevokedListedCopy() public {
        OwnedZeroAdvisory adv = new OwnedZeroAdvisory();
        OwnedGateStub gate = new OwnedGateStub();
        _admit(address(root), _advisoryAdmission(address(adv)));
        _admit(address(root), _gateAdmission(address(gate)));
        IHookrOwnedProfiles.Profile memory p = _profile(F.ALL_FEATURES, true, brand);
        p.advisories = new address[](1);
        p.advisories[0] = address(adv);
        p.gates = new address[](1);
        p.gates[0] = address(gate);
        vm.prank(brand);
        bytes32 id = book.writeProfile(bytes32("listed"), p);
        assertTrue(lens.selectionBounds(factory, id, brand).deployable);
        registry.revokeModuleAdmission(address(root), address(gate));
        assertFalse(lens.selectionBounds(factory, id, brand).deployable, "a revoked gate");
        p.gates = new address[](0);
        vm.prank(brand);
        id = book.writeProfile(bytes32("listed-advisory"), p);
        assertTrue(lens.selectionBounds(factory, id, brand).deployable);
        registry.revokeModuleAdmission(address(root), address(adv));
        assertFalse(lens.selectionBounds(factory, id, brand).deployable, "a revoked advisory");
    }

    /// @notice A full factory is not deployable.
    function test_boundsFollowTheCap() public {
        factory = _newFactory(1);
        _activateFactory(address(factory));
        assertTrue(lens.selectionBounds(factory, templateProfile, brand).deployable);
        _deployOwned(_sel(brand, F.ALL_FEATURES));
        assertFalse(lens.selectionBounds(factory, templateProfile, brand).deployable, "full");
    }

    /// @notice The factory stays under 24,576 bytes (EIP-170).
    function test_factoryRuntimeStaysPortable() public view {
        assertLe(address(factory).code.length, 24_576, "factory");
    }
}

/// @notice A lane executor that does nothing on each lane call.
contract LensIdleExecutor {
    function executeArbitrage(PoolKey calldata, address) external pure returns (uint256) {
        return 0;
    }
}
