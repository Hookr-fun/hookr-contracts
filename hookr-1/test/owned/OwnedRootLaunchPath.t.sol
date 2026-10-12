// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {IHookrLanes} from "../../src/interfaces/IHookrLanes.sol";
import {IHookrLaneRoot} from "../../src/interfaces/IHookrLaneRoot.sol";
import {IHookrOwnedRoots} from "../../src/interfaces/IHookrOwnedRoots.sol";
import {IHookrOwnedRootFactory} from "../../src/interfaces/IHookrOwnedRootFactory.sol";
import {HookrLauncher} from "../../src/periphery/HookrLauncher.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrOwnedRootTypes as F} from "../../src/libraries/HookrOwnedRootTypes.sol";
import {MockIdleExecutor} from "../mocks/MockIdleExecutor.sol";
import {OwnedRootsFixture} from "./OwnedRootsFixture.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";

/// @notice The owned-root launch path end to end with the real HookrOwnedRootFactory and the merged HookrLauncher
///         (owned roots decision 4, owner amendment 3): the launcher opens a family only while the registry's
///         rootOpenFor(root, caller) holds, which on an owned root asks the factory that registered it. An owner-only
///         owned root launches for its owner and refuses a stranger, through launch and launchFamily alike, and refuses
///         everyone, its owner included, while its owner has paused it; a public owned root launches for anyone. The
///         shared root's lane, open at the release cap and partner share when both roots register, is copied onto each
///         with its executor switched off, so both refuse a pool that asks for arb recapture and open a plain pool with
///         no lane and no lane gas floor. LauncherOwnedRootOpen.t.sol runs the same questions against the registry's
///         registrar entry with a mock factory; this suite runs them against the factory the release deploys.
contract OwnedRootLaunchPathTest is OwnedRootsFixture {
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant OPEN_LANE = keccak256("OPEN_LANE");
    /// @dev The release's lane cap and WTH's partner share, at which the shared root's lane opens.
    uint32 internal constant RELEASE_CAP = 3_000_000;
    uint16 internal constant PARTNER_BPS = 2_500;

    MockIdleExecutor internal executor;
    HookrRoot internal ownerOnly;
    HookrRules internal ownerOnlyRules;
    HookrRoot internal publicRoot;
    HookrRules internal publicRules;

    function setUp() public {
        _setUpOwned();
        executor = new MockIdleExecutor();
        registry.queue(
            OPEN_LANE,
            abi.encode(address(root), address(executor), address(executor).codehash, RELEASE_CAP, PARTNER_BPS)
        );
        vm.warp(vm.getBlockTimestamp() + DELAY);
        registry.openLaneOf(address(root), address(executor), address(executor).codehash, RELEASE_CAP, PARTNER_BPS);
        // Both roots are deployed and held by `brand`: one opening for its owner only, one opening for anyone.
        (ownerOnly, ownerOnlyRules) = _deployOwned(_selFor(templateProfile, brand, F.ALL_FEATURES, false));
        (publicRoot, publicRules) = _deployOwned(_sel(brand, F.ALL_FEATURES));
    }

    // ───────────────────────────── helpers ─────────────────────────────

    /// @dev A plain one-member family of a new token against native ETH on `rootAddr`, launched by `caller`.
    function _launch(address caller, address rootAddr, HookrRules companion) internal returns (bytes32 family) {
        (family,,) = _launchAs(caller, rootAddr, _nativeMember(address(companion), _rc(), 0));
    }

    /// @dev Launches `m` on `rootAddr` as `caller` and returns whether the launcher accepted it and its revert data.
    function _try(address caller, address rootAddr, IHookrLauncher.Member memory m)
        internal
        returns (bool ok, bytes memory reason)
    {
        IHookrLauncher.Member[] memory ms = _members(m);
        IHookrLauncher.Token memory t = _newToken();
        uint256 deadline = vm.getBlockTimestamp();
        vm.prank(caller);
        (ok, reason) = address(launcher).call{value: m.amount0Max}(
            abi.encodeCall(HookrLauncher.launch, (t, rootAddr, ms, deadline))
        );
    }

    /// @dev Expects the launcher to refuse a plain launch on `rootAddr` by `caller` because the root does not open
    ///      for it (InvalidFamily).
    function _expectClosedFor(address caller, address rootAddr, HookrRules companion) internal {
        (bool ok, bytes memory reason) = _try(caller, rootAddr, _nativeMember(address(companion), _rc(), 0));
        assertFalse(ok, "refused");
        assertEq(reason, abi.encodeWithSelector(IHookrLauncher.InvalidFamily.selector), "InvalidFamily");
    }

    /// @dev launchFamily's input for one plain member of a new token on `rootAddr`, with no knobs, buys or check.
    function _familyParams(address rootAddr, HookrRules companion)
        internal
        returns (IHookrLauncher.LaunchParams memory p)
    {
        p.token = _newToken();
        p.root = rootAddr;
        p.members = _members(_nativeMember(address(companion), _rc(), 0));
        p.knobs = new IHookrLauncher.MemberKnobs[](1);
        p.advisoryConfigs = new bytes[](1);
        p.buys = new IHookrLauncher.DevBuy[](0);
        p.maxRetainedBps = 10_000;
        p.opening.references = new PoolKey[](0);
        p.deadline = vm.getBlockTimestamp();
    }

    // ───────────────────────────── owner-only ─────────────────────────────

    /// @notice An owner-only owned root launches for its owner, through launch and launchFamily, and refuses a stranger
    ///         and the template's own deployer through both, although rootOpen alone reads it open.
    function test_ownerOnlyRootLaunchesForItsOwnerAndRefusesAStranger() public {
        assertTrue(registry.rootOpen(address(ownerOnly)), "rootOpen alone would let a stranger in");
        assertTrue(IHookrOwnedRoots(address(registry)).rootOpenFor(address(ownerOnly), brand));
        assertFalse(IHookrOwnedRoots(address(registry)).rootOpenFor(address(ownerOnly), stranger));
        assertFalse(factory.mayOpen(address(ownerOnly), stranger));

        bytes32 family = _launch(brand, address(ownerOnly), ownerOnlyRules);
        assertEq(launcher.familyOwner(family), brand);
        assertEq(address(launcher.position(family, 0).key.hooks), address(ownerOnly), "on the owned root");

        _expectClosedFor(stranger, address(ownerOnly), ownerOnlyRules);
        _expectClosedFor(address(this), address(ownerOnly), ownerOnlyRules);

        IHookrLauncher.LaunchParams memory p = _familyParams(address(ownerOnly), ownerOnlyRules);
        uint256 value = p.members[0].amount0Max;
        vm.prank(stranger);
        vm.expectRevert(IHookrLauncher.InvalidFamily.selector);
        launcher.launchFamily{value: value}(p);
        p = _familyParams(address(ownerOnly), ownerOnlyRules);
        vm.prank(brand);
        (family,,) = launcher.launchFamily{value: value}(p);
        assertEq(launcher.familyOwner(family), brand);
    }

    /// @notice While its owner has paused it, an owner-only owned root refuses everyone, its owner included; once the
    ///         owner lifts the pause it opens for its owner again and still refuses a stranger. Only the owner pauses.
    function test_aPausedOwnerOnlyRootRefusesEveryone() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IHookrOwnedRootFactory.NotRootOwner.selector, address(ownerOnly), stranger)
        );
        factory.setPaused(address(ownerOnly), true);

        vm.prank(brand);
        factory.setPaused(address(ownerOnly), true);
        assertFalse(IHookrOwnedRoots(address(registry)).rootOpenFor(address(ownerOnly), brand));
        _expectClosedFor(brand, address(ownerOnly), ownerOnlyRules);
        _expectClosedFor(stranger, address(ownerOnly), ownerOnlyRules);
        // The pause is the owned root's own: the shared root and the public owned root stay open.
        _launch(stranger, address(root), sharedRules);
        _launch(stranger, address(publicRoot), publicRules);

        vm.prank(brand);
        factory.setPaused(address(ownerOnly), false);
        bytes32 family = _launch(brand, address(ownerOnly), ownerOnlyRules);
        assertEq(launcher.familyOwner(family), brand);
        _expectClosedFor(stranger, address(ownerOnly), ownerOnlyRules);
    }

    // ───────────────────────────── public ─────────────────────────────

    /// @notice A public owned root launches for anyone, its owner included, and a paused one for nobody.
    function test_aPublicOwnedRootLaunchesForAnyone() public {
        address[3] memory callers = [stranger, brand, address(this)];
        for (uint256 i; i < callers.length; ++i) {
            assertTrue(IHookrOwnedRoots(address(registry)).rootOpenFor(address(publicRoot), callers[i]));
            bytes32 family = _launch(callers[i], address(publicRoot), publicRules);
            assertEq(launcher.familyOwner(family), callers[i]);
            assertEq(address(launcher.position(family, 0).key.hooks), address(publicRoot));
        }
        vm.prank(brand);
        factory.setPaused(address(publicRoot), true);
        _expectClosedFor(stranger, address(publicRoot), publicRules);
        _expectClosedFor(brand, address(publicRoot), publicRules);
    }

    // ───────────────────────────── braked lanes ─────────────────────────────

    /// @notice Both owned roots copied the shared root's lane braked: no active lane, the executor's switch off at the
    ///         template's cap, while the shared root keeps its lane. Each refuses a pool that asks for arb recapture
    ///         (HookrLane.InvalidConfig), its owner launching, and opens a plain pool without a lane or lane gas floor.
    function test_recapturePoolRefusedOnBothWhileTheirLanesAreBraked() public {
        (address templateLane,, uint32 templateCap, uint16 templateShare) =
            IHookrLanes(address(registry)).activeLaneOf(address(root));
        assertEq(templateLane, address(executor), "the shared root keeps its lane");
        assertEq(templateCap, RELEASE_CAP);
        assertEq(templateShare, PARTNER_BPS);

        HookrRoot[2] memory roots = [ownerOnly, publicRoot];
        HookrRules[2] memory companions = [ownerOnlyRules, publicRules];
        for (uint256 i; i < 2; ++i) {
            address r = address(roots[i]);
            (address active,,,) = IHookrLanes(address(registry)).activeLaneOf(r);
            assertEq(active, address(0), "the copied lane is braked");
            (bool on, uint32 cap) = IHookrLanes(address(registry)).executorLane(r, address(executor));
            assertFalse(on, "the executor's switch is off");
            assertEq(cap, RELEASE_CAP, "at the template's cap");

            IHookrLauncher.Member memory recapturing = _withRecapture(_nativeMember(address(companions[i]), _rc(), 0));
            (bool ok, bytes memory reason) = _try(brand, r, recapturing);
            assertFalse(ok, "a recapture pool is refused");
            assertEq(reason, abi.encodeWithSelector(IHookrRootEvents.InvalidConfig.selector));

            (, PoolKey memory key,) = _launchAs(brand, r, _nativeMember(address(companions[i]), _rc(), 0));
            (address frozen,,,,,, uint256 floor) = IHookrLaneRoot(r).laneOf(key.toId());
            assertEq(frozen, address(0), "a plain pool has no lane");
            assertEq(floor, 0, "and no lane gas floor");
        }
    }
}
