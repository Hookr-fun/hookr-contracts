// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrTypes} from "../types/HookrTypes.sol";
import {IHookrRegistry} from "./IHookrRegistry.sol";

/// @title IHookrOwnedProfiles
/// @notice Tier 1 of owned roots: a record book of named rule sets on a shared Hookr root. Anyone writes a profile of
///         their own (a subset of the Rules features, caps under the root's RULES admission, up to four admitted
///         advisories, the recapture lane allowed or not, public or owner-only). A pool joins a profile when it
///         committed to the profile id at launch (`PoolConfig.policyId`, part of the pool's policy hash) and its frozen
///         terms fit the profile; the profile's owner, or anyone for a public profile, then records it. A profile is
///         also the template the owned-root factory (IHookrOwnedRootFactory) derives a root of its own from.
/// @dev Beside HookrRegistry, which it only reads (`isRoot`, `rootFactoryOf`, `isOwnedRoot`, `rootOpen`,
///      `admission`). It holds no assets, has no owner and no upgrade path, and nothing on a swap path reads it. A
///      profile is its writer's declaration: checked against the registry when written and against each pool's frozen
///      terms when the pool is recorded; the Rules module and caps it names are enforced when a pool opens by the root
///      and the Rules module the registry admitted.
interface IHookrOwnedProfiles {
    /// @notice A named rule set on a shared root.
    struct Profile {
        /// @notice A root a queued `REGISTER_ROOT` registered (neither a pair root nor an owned root) that takes new
        ///         pools.
        address root;
        /// @notice The RULES module admitted on `root` that the profile's pools bind.
        address rules;
        /// @notice ADVISORY modules admitted on `root` that a profile pool may bind, at most four and distinct. An
        ///         owned root derived from the profile takes each as an admission of its own.
        address[] advisories;
        /// @notice GATE modules admitted on `root` (gates that vouch for a swap's payer before the Hookr router
        ///         unlocks, such as the family router), at most four and distinct. They bind to no pool, so tier-1
        ///         conformance does not read them; an owned root derived from the profile takes each as an admission of
        ///         its own.
        address[] gates;
        /// @notice Ceilings at or under the RULES admission's caps; a profile pool's declared caps must fit under them.
        HookrTypes.Caps caps;
        /// @notice The features a profile pool may use (HookrOwnedRootTypes).
        bytes32 ruleMask;
        /// @notice Whether a profile pool may carry the root's recapture lane (arb recapture and King of the Pool).
        bool laneEnabled;
        /// @notice Whether anyone may record pools into the profile and deploy owned roots from it; otherwise only its
        ///         owner.
        bool publicOpening;
        /// @notice The writer: the only account that may rewrite it, and the only recorder and deployer when it is not
        ///         public.
        address owner;
        /// @notice Set by the book on every write, from 1.
        uint32 version;
    }

    /// @notice A pool recorded into a profile, at the profile version it was checked against.
    struct Adoption {
        /// @notice The profile.
        bytes32 profileId;
        /// @notice The profile version the pool fitted when it was recorded; zero for no record.
        uint32 version;
    }

    /// @notice A profile was written at `version`.
    /// @param profileId The profile.
    /// @param root The profile's root.
    /// @param owner The profile's writer.
    /// @param version The version written.
    /// @param terms The full terms of that version.
    event ProfileWritten(
        bytes32 indexed profileId, address indexed root, address indexed owner, uint32 version, Profile terms
    );

    /// @notice Pool `id` of `root` was recorded into `profileId` at `version`.
    /// @param profileId The profile.
    /// @param root The pool's root.
    /// @param id The pool.
    /// @param version The profile version the pool was checked against.
    event PoolAdopted(bytes32 indexed profileId, address indexed root, PoolId indexed id, uint32 version);

    /// @notice A pool's record under `profileId`, checked at `version`, was removed by `by`.
    /// @param profileId The profile.
    /// @param root The pool's root.
    /// @param id The pool.
    /// @param version The profile version the record was checked against.
    /// @param by The account that removed it.
    event AdoptionDropped(
        bytes32 indexed profileId, address indexed root, PoolId indexed id, uint32 version, address by
    );

    /// @notice No profile was ever written under `profileId`.
    error UnknownProfile(bytes32 profileId);

    /// @notice `caller` is not the owner `profileId` needs: a write names another owner, or the profile is owner-only.
    error NotProfileOwner(bytes32 profileId, address caller);

    /// @notice `root` is not a registered root that takes new pools and that a queued `REGISTER_ROOT` registered.
    error InvalidRoot(address root);

    /// @notice The Rules module, caps, mask, advisories or gates are outside what the registry admitted on the root.
    error InvalidProfile();

    /// @notice The pool is not on the profile's root, did not commit to the profile at launch, or its frozen terms are
    ///         outside the profile.
    error OutsideProfile(bytes32 profileId);

    /// @notice Pool `id` of `root` is already recorded.
    error AlreadyAdopted(address root, PoolId id);

    /// @notice Pool `id` of `root` has no record to remove.
    error NotAdopted(address root, PoolId id);

    /// @notice The Hookr registry the book reads.
    /// @return The registry.
    function registry() external view returns (IHookrRegistry);

    /// @notice The most advisories one profile lists: 4.
    /// @return The limit.
    function MAX_PROFILE_ADVISORIES() external view returns (uint256);

    /// @notice The most gates one profile lists: 4.
    /// @return The limit.
    function MAX_PROFILE_GATES() external view returns (uint256);

    /// @notice Writes, or rewrites as a new version, the caller's profile under `salt`.
    /// @dev The caller must be `p.owner`; `p.version` is ignored and set by the book. The id is namespaced by the
    ///      writer, so nobody squats or overwrites another account's profile. Every earlier version stays readable
    ///      through `profileAt`; a pool recorded earlier keeps the version it was checked against, and an owned root
    ///      keeps the version it was derived from.
    /// @param salt The writer's salt for the id.
    /// @param p The profile's terms.
    /// @return profileId The profile's id, `profileIdOf(msg.sender, salt)`.
    function writeProfile(bytes32 salt, Profile calldata p) external returns (bytes32 profileId);

    /// @notice The id a writer's profile takes for `salt`, namespaced by chain, book and writer.
    /// @param writer The profile's writer.
    /// @param salt The writer's salt.
    /// @return The profile id.
    function profileIdOf(address writer, bytes32 salt) external view returns (bytes32);

    /// @notice The profile's current terms; version zero for a profile never written.
    /// @param profileId The profile.
    /// @return The current terms.
    function profile(bytes32 profileId) external view returns (Profile memory);

    /// @notice The profile's terms at `version`, kept after every rewrite; version zero in the result for one never
    ///         written.
    /// @param profileId The profile.
    /// @param version The version to read.
    /// @return The terms of that version.
    function profileAt(bytes32 profileId, uint32 version) external view returns (Profile memory);

    /// @notice Records pool `id` of the profile's root into the profile, at its current version. Only the profile's
    ///         owner unless the profile is public.
    /// @param profileId The profile.
    /// @param id The pool, which committed to `profileId` at launch and whose frozen terms fit the profile.
    function adoptPool(bytes32 profileId, PoolId id) external;

    /// @notice Removes a pool's record. The profile's owner may remove any record under its profile; anyone may remove
    ///         a record whose pool no longer fits the profile's current version. A removed pool that fits the current
    ///         version can be recorded again.
    /// @param root The pool's root.
    /// @param id The pool.
    function dropAdoption(address root, PoolId id) external;

    /// @notice The profile and version pool `id` of `root` was recorded under; version zero for none.
    /// @param root The pool's root.
    /// @param id The pool.
    /// @return The record.
    function adoption(address root, PoolId id) external view returns (Adoption memory);

    /// @notice Whether pool `id` committed to the profile at launch and its frozen terms fit the profile's current
    ///         version.
    /// @param profileId The profile.
    /// @param id The pool, on the profile's root.
    /// @return Whether it fits.
    function profileConforms(bytes32 profileId, PoolId id) external view returns (bool);
}
