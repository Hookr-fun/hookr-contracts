// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrOwnedProfiles} from "../../src/interfaces/IHookrOwnedProfiles.sol";
import {HookrOwnedRootTypes as F} from "../../src/libraries/HookrOwnedRootTypes.sol";
import {OwnedRootsFixture} from "./OwnedRootsFixture.sol";

/// @notice The owned-roots lab's adversarial round, as regression tests on the profile book. L-01: a record kept under
///         a profile its owner tightened afterwards (fixed: every version stays readable, the event carries the full
///         terms, and a stale record can be dropped). The round's L-02 (an executor braked on the template between an
///         owner-operated deploy and its seal) has no counterpart: registration copies the lane, braked, in the
///         deploying transaction, so there is no window to seal into. Its I-01 (a root-agnostic executor that trusts
///         `key.hooks` alone) is a property of the executor, shown with the stand-in in
///         test/lane/OwnedRootLane.t.sol.
contract OwnedRootsProfileHistoryTest is OwnedRootsFixture {
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant PROFILE_WRITTEN = IHookrOwnedProfiles.ProfileWritten.selector;

    function setUp() public {
        _setUpOwned();
    }

    function launchExternal(address caller, address rootAddr, IHookrLauncher.Member memory m)
        external
        returns (bytes32 family, PoolKey memory key, address subject)
    {
        return _launchAs(caller, rootAddr, m);
    }

    /// @notice L-01. A stranger's pool recorded under a brand's loose public profile: after the brand tightens the
    ///         profile, the version the record was checked against stays readable, the event carries the new terms in
    ///         full, and the stale record can be dropped by anyone, since the pool no longer fits; it cannot be
    ///         recorded again under the tightened version.
    function test_regression_rewrittenProfileKeepsHistoryAndDropsStaleAdoption() public {
        IHookrOwnedProfiles.Profile memory p = _profile(F.ALL_FEATURES, true, brand);
        vm.prank(brand);
        bytes32 id = book.writeProfile(bytes32("brand-safe"), p);

        HookrTypes.RulesConfig memory c = _rc();
        c.royaltyTo = stranger;
        c.royaltyBps = 1_000;
        (, PoolKey memory key,) =
            this.launchExternal(stranger, address(root), _nativeMember(address(sharedRules), c, id));
        PoolId pid = key.toId();
        vm.prank(stranger);
        book.adoptPool(id, pid);
        // While the pool fits, only the brand may drop it.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedProfiles.NotProfileOwner.selector, id, stranger));
        book.dropAdoption(address(root), pid);

        // The brand tightens the profile it markets.
        IHookrOwnedProfiles.Profile memory tight = _profile(0, false, brand);
        tight.caps = HookrTypes.Caps(3_000, 0, 0);
        tight.laneEnabled = false;
        vm.recordLogs();
        vm.prank(brand);
        book.writeProfile(bytes32("brand-safe"), tight);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], PROFILE_WRITTEN);
        (uint32 v, IHookrOwnedProfiles.Profile memory emitted) =
            abi.decode(logs[0].data, (uint32, IHookrOwnedProfiles.Profile));
        assertEq(v, 2);
        assertEq(emitted.version, 2, "the event carries the new terms");
        assertEq(emitted.ruleMask, bytes32(0));
        assertFalse(emitted.publicOpening);
        assertEq(emitted.caps.maxLpFeePips, 3_000);

        // The terms the record was checked against stay readable.
        IHookrOwnedProfiles.Adoption memory a = book.adoption(address(root), pid);
        assertEq(a.version, 1);
        IHookrOwnedProfiles.Profile memory then_ = book.profileAt(id, 1);
        assertEq(then_.version, 1);
        assertEq(then_.ruleMask, F.ALL_FEATURES);
        assertTrue(then_.publicOpening);
        assertTrue(then_.laneEnabled);
        assertEq(book.profile(id).version, 2);
        assertEq(book.profileAt(id, 2).ruleMask, bytes32(0));
        assertFalse(book.profileConforms(id, pid));

        // The stale record can be removed: here by anyone, since the pool no longer fits the current version.
        vm.expectEmit(true, true, true, true, address(book));
        emit IHookrOwnedProfiles.AdoptionDropped(id, address(root), pid, 1, stranger);
        vm.prank(stranger);
        book.dropAdoption(address(root), pid);
        assertEq(book.adoption(address(root), pid).version, 0, "record removed");
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedProfiles.NotAdopted.selector, address(root), pid));
        book.dropAdoption(address(root), pid);
        // And it cannot come back under the tightened profile.
        vm.prank(brand);
        vm.expectRevert(abi.encodeWithSelector(IHookrOwnedProfiles.OutsideProfile.selector, id));
        book.adoptPool(id, pid);
    }

    /// @notice L-01, the owner's path: the brand drops a record whose pool still fits, and can record it again.
    function test_regression_ownerDropsAFittingRecord() public {
        vm.prank(brand);
        bytes32 id = book.writeProfile(bytes32("brand-safe"), _profile(F.ALL_FEATURES, true, brand));
        (, PoolKey memory key,) =
            this.launchExternal(stranger, address(root), _nativeMember(address(sharedRules), _rc(), id));
        PoolId pid = key.toId();
        vm.prank(stranger);
        book.adoptPool(id, pid);
        assertTrue(book.profileConforms(id, pid));
        vm.prank(brand);
        book.dropAdoption(address(root), pid);
        assertEq(book.adoption(address(root), pid).version, 0);
        vm.prank(brand);
        book.adoptPool(id, pid);
        assertEq(book.adoption(address(root), pid).version, 1);
    }
}
