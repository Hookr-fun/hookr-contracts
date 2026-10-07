// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HookrTypes} from "../types/HookrTypes.sol";
import {IHookrOwnedProfiles} from "./IHookrOwnedProfiles.sol";
import {IHookrOwnedRootFactory} from "./IHookrOwnedRootFactory.sol";

/// @title IHookrOwnedRootsLens
/// @notice The creator knobs of owned roots with their bounds and defaults, for the app and the SDK: what a profile
///         may hold on a root, what a root may select from a profile, and complete defaults for both.
/// @dev View-only: no state and no owner, so one deployment serves every profile book and every owned-root factory of
///      a release; its one constructor argument is the release's family router, which its default profile lists. It
///      enforces nothing; the book, the factory and the registry enforce every bound it reports, and a stale read only
///      makes a write or a deployment revert.
interface IHookrOwnedRootsLens {
    /// @notice The creator knobs of a root derived from one profile through one factory, as the chain reads now.
    struct SelectionBounds {
        /// @notice The version `RootSelections.profileVersion` must name; zero for an unknown profile.
        uint32 profileVersion;
        /// @notice The widest `ruleMask`: the profile's own mask.
        bytes32 maxRuleMask;
        /// @notice The features a root anyone may open pools on keeps (PUBLIC_REQUIRED_FEATURES).
        bytes32 publicRequiredMask;
        /// @notice Whether the profile's mask holds every required feature, so a public root can be derived.
        bool publicAllowed;
        /// @notice Whether the deployer may use the profile: it is public, or the deployer owns it.
        bool deployerAllowed;
        /// @notice The caps the root's RULES admission takes from the profile, before Auto Burn is capped off for a
        ///         mask that leaves it out.
        HookrTypes.Caps caps;
        /// @notice Whether the template has an open recapture lane, which the root copies with its executor switched
        ///         off: the root takes no pool that asks for arb recapture until its lane is opened through the
        ///         registry's timelock.
        bool laneCopied;
        /// @notice The deploy fee `deploy` must be sent now: the treasury's `ownedRootFee()`.
        uint256 fee;
        /// @notice Whether the deployer could deploy from the profile now: the profile exists, is on the factory's
        ///         template and usable by the deployer, its Rules module is the factory's template Rules and holds a
        ///         live RULES admission there that pays the factory's treasury, every advisory and gate it lists is
        ///         still a live admission there, the template takes new pools, the factory is an active root factory
        ///         and is not full.
        bool deployable;
    }

    /// @notice Every feature a profile or a root may allow: the widest rule mask.
    /// @return The mask.
    function ALL_FEATURES() external view returns (bytes32);

    /// @notice The release's HookrFamilyRouter, which runs every leg of a family trade through HookrRouter.swapGated
    ///         as the root's GATE; zero for none. An owned root takes only the gates its profile lists and is frozen at
    ///         registration, so the default profile lists it.
    /// @return The family router.
    function familyRouter() external view returns (address);

    /// @notice The features a root anyone may open pools on keeps, so every rule it advertises is one its pools can
    ///         use.
    /// @return The mask.
    function PUBLIC_REQUIRED_FEATURES() external view returns (bytes32);

    /// @notice The bounds of a profile written on `root` with `rules`: caps at most the RULES admission's (zero when
    ///         `rules` holds no RULES admission there), a mask within every feature, and the book's advisory and gate
    ///         limits. The lane switch and the opening are free.
    /// @param book The profile book.
    /// @param root The profile's root.
    /// @param rules The profile's Rules module.
    /// @return maxCaps The widest caps.
    /// @return maxRuleMask The widest mask.
    /// @return maxAdvisories The most advisories.
    /// @return maxGates The most gates.
    function profileBounds(IHookrOwnedProfiles book, address root, address rules)
        external
        view
        returns (HookrTypes.Caps memory maxCaps, bytes32 maxRuleMask, uint256 maxAdvisories, uint256 maxGates);

    /// @notice A complete default profile for `owner` on `root` with `rules`: the RULES admission's caps, every
    ///         feature, public, no advisory, the release's family router as its one gate while it is a live GATE
    ///         admission of `root` (none otherwise), and the lane allowed, so a root derived from it takes Multi-pool
    ///         launch's family trades. `writeProfile` accepts it as is from `owner` while `rules` holds a live RULES
    ///         admission on `root` and `root` takes new pools.
    /// @param book The profile book.
    /// @param root The profile's root.
    /// @param rules The profile's Rules module.
    /// @param owner The profile's writer.
    /// @return p The profile.
    function defaultProfile(IHookrOwnedProfiles book, address root, address rules, address owner)
        external
        view
        returns (IHookrOwnedProfiles.Profile memory p);

    /// @notice The creator knobs of a root `deployer` derives from `profileId` through `factory`, with their bounds.
    /// @param factory The owned-root factory.
    /// @param profileId The profile in the factory's book.
    /// @param deployer The account that would deploy.
    /// @return b The bounds.
    function selectionBounds(IHookrOwnedRootFactory factory, bytes32 profileId, address deployer)
        external
        view
        returns (SelectionBounds memory b);

    /// @notice Complete default selections for `deployer` against `profileId`: the profile's current version and full
    ///         mask, public when the mask allows it (owner-only otherwise), and `deployer` as the owner of record.
    /// @param factory The owned-root factory.
    /// @param profileId The profile in the factory's book.
    /// @param deployer The account that would deploy and own the root.
    /// @return s The selections.
    function defaultSelections(IHookrOwnedRootFactory factory, bytes32 profileId, address deployer)
        external
        view
        returns (IHookrOwnedRootFactory.RootSelections memory s);
}
