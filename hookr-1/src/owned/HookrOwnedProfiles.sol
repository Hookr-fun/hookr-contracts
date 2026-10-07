// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookrRegistry} from "../interfaces/IHookrRegistry.sol";
import {IHookrOwnedRoots} from "../interfaces/IHookrOwnedRoots.sol";
import {IHookrRoot} from "../interfaces/IHookrRoot.sol";
import {IHookrOwnedProfiles} from "../interfaces/IHookrOwnedProfiles.sol";
import {HookrOwnedConformance as C} from "../libraries/HookrOwnedConformance.sol";
import {HookrOwnedRootTypes as F} from "../libraries/HookrOwnedRootTypes.sol";

/// @title HookrOwnedProfiles
/// @notice Tier 1 of owned roots: anyone writes a named rule set of their own on a shared Hookr root, launches pools on
///         the shared root that commit to it at launch, and records the pools that fit it. Pools stay on the shared
///         root with Hookr's launcher, router and quoter. A profile is also the template the owned-root factory
///         derives a root of its own from.
/// @dev A record book beside HookrRegistry, which it reads and never writes. No owner, no assets, no upgrade path,
///      never read on a swap path. A profile is its writer's declaration, checked against the registry when written and
///      against each pool's frozen terms when the pool is recorded; the Rules module and caps it names are enforced
///      when a pool opens by the root and the Rules module the registry admitted.
contract HookrOwnedProfiles is IHookrOwnedProfiles {
    /// @inheritdoc IHookrOwnedProfiles
    uint256 public constant MAX_PROFILE_ADVISORIES = 4;
    /// @inheritdoc IHookrOwnedProfiles
    uint256 public constant MAX_PROFILE_GATES = 4;

    /// @inheritdoc IHookrOwnedProfiles
    IHookrRegistry public immutable registry;

    /// @dev Every version a profile was written at, kept so the terms a pool was recorded against stay readable.
    mapping(bytes32 profileId => mapping(uint32 version => Profile)) private _versions;
    mapping(bytes32 profileId => uint32) private _latest;
    mapping(address root => mapping(PoolId => Adoption)) private _adoptions;

    /// @param registry_ The Hookr registry the book reads.
    constructor(IHookrRegistry registry_) {
        if (address(registry_).code.length == 0) revert InvalidRoot(address(registry_));
        registry = registry_;
    }

    /// @inheritdoc IHookrOwnedProfiles
    function profileIdOf(address writer, bytes32 salt) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), writer, salt));
    }

    /// @inheritdoc IHookrOwnedProfiles
    function writeProfile(bytes32 salt, Profile calldata p) external returns (bytes32 profileId) {
        if (p.owner != msg.sender) revert NotProfileOwner(bytes32(0), msg.sender);
        IHookrRegistry reg = registry;
        if (
            !reg.isRoot(p.root) || reg.rootFactoryOf(p.root) != address(0)
                || IHookrOwnedRoots(address(reg)).isOwnedRoot(p.root) || !reg.rootOpen(p.root)
        ) revert InvalidRoot(p.root);
        if (!_admissible(reg, p)) revert InvalidProfile();
        profileId = profileIdOf(msg.sender, salt);
        uint32 version = _latest[profileId] + 1;
        Profile storage stored = _versions[profileId][version];
        stored.root = p.root;
        stored.rules = p.rules;
        for (uint256 i; i < p.advisories.length; ++i) {
            stored.advisories.push(p.advisories[i]);
        }
        for (uint256 i; i < p.gates.length; ++i) {
            stored.gates.push(p.gates[i]);
        }
        stored.caps = p.caps;
        stored.ruleMask = p.ruleMask;
        stored.laneEnabled = p.laneEnabled;
        stored.publicOpening = p.publicOpening;
        stored.owner = msg.sender;
        stored.version = version;
        _latest[profileId] = version;
        emit ProfileWritten(profileId, p.root, msg.sender, version, stored);
    }

    /// @inheritdoc IHookrOwnedProfiles
    function profile(bytes32 profileId) external view returns (Profile memory) {
        return _versions[profileId][_latest[profileId]];
    }

    /// @inheritdoc IHookrOwnedProfiles
    function profileAt(bytes32 profileId, uint32 version) external view returns (Profile memory) {
        return _versions[profileId][version];
    }

    /// @inheritdoc IHookrOwnedProfiles
    function adoptPool(bytes32 profileId, PoolId id) external {
        Profile storage p = _current(profileId);
        if (p.version == 0) revert UnknownProfile(profileId);
        if (!p.publicOpening && msg.sender != p.owner) revert NotProfileOwner(profileId, msg.sender);
        address root = p.root;
        if (_adoptions[root][id].version != 0) revert AlreadyAdopted(root, id);
        if (!_fits(p, profileId, id)) revert OutsideProfile(profileId);
        _adoptions[root][id] = Adoption(profileId, p.version);
        emit PoolAdopted(profileId, root, id, p.version);
    }

    /// @inheritdoc IHookrOwnedProfiles
    function dropAdoption(address root, PoolId id) external {
        Adoption memory a = _adoptions[root][id];
        if (a.version == 0) revert NotAdopted(root, id);
        Profile storage p = _current(a.profileId);
        if (msg.sender != p.owner && _fits(p, a.profileId, id)) revert NotProfileOwner(a.profileId, msg.sender);
        delete _adoptions[root][id];
        emit AdoptionDropped(a.profileId, root, id, a.version, msg.sender);
    }

    /// @inheritdoc IHookrOwnedProfiles
    function adoption(address root, PoolId id) external view returns (Adoption memory) {
        return _adoptions[root][id];
    }

    /// @inheritdoc IHookrOwnedProfiles
    function profileConforms(bytes32 profileId, PoolId id) external view returns (bool) {
        Profile storage p = _current(profileId);
        if (p.version == 0) return false;
        return _fits(p, profileId, id);
    }

    /// @dev The profile's latest version: an empty record, version zero, when never written.
    function _current(bytes32 profileId) private view returns (Profile storage) {
        return _versions[profileId][_latest[profileId]];
    }

    /// @dev A pool is in a profile when it committed to the profile id at launch and its frozen terms fit it.
    function _fits(Profile storage p, bytes32 profileId, PoolId id) private view returns (bool) {
        address root = p.root;
        if (!IHookrRoot(root).knownPool(id) || IHookrRoot(root).poolConfig(id).policyId != profileId) return false;
        return C.poolFits(root, id, p.rules, p.advisories, p.caps, p.ruleMask, p.laneEnabled);
    }

    /// @dev The profile names its root's live RULES admission, caps at or under that admission's, only known features,
    ///      and at most MAX_PROFILE_ADVISORIES distinct live ADVISORY and MAX_PROFILE_GATES distinct live GATE
    ///      admissions of its root. A live admission is recorded, not revoked, covered by its bond if it has one, and
    ///      its implementation runs the pinned runtime codehash.
    function _admissible(IHookrRegistry reg, Profile calldata p) private view returns (bool) {
        address rules = p.rules;
        IHookrRegistry.Admission memory ra = reg.admission(p.root, rules);
        if (
            !_live(ra, rules, IHookrRegistry.Kind.RULES) || !F.capsWithin(p.caps, ra.caps)
                || p.ruleMask & ~F.ALL_FEATURES != 0 || p.advisories.length > MAX_PROFILE_ADVISORIES
                || p.gates.length > MAX_PROFILE_GATES
        ) return false;
        return _listed(reg, p.root, p.advisories, IHookrRegistry.Kind.ADVISORY)
            && _listed(reg, p.root, p.gates, IHookrRegistry.Kind.GATE);
    }

    /// @dev Whether every entry of `list` is distinct and a live admission of `kind` on `root`.
    function _listed(IHookrRegistry reg, address root, address[] calldata list, IHookrRegistry.Kind kind)
        private
        view
        returns (bool)
    {
        for (uint256 i; i < list.length; ++i) {
            address implementation = list[i];
            if (!_live(reg.admission(root, implementation), implementation, kind)) return false;
            for (uint256 j; j < i; ++j) {
                if (list[j] == implementation) return false;
            }
        }
        return true;
    }

    /// @dev Whether `a` admits `implementation` as `kind` at its current runtime codehash. The registry reports a
    ///      revoked admission, or one whose bond does not cover it, as empty.
    function _live(IHookrRegistry.Admission memory a, address implementation, IHookrRegistry.Kind kind)
        private
        view
        returns (bool)
    {
        return implementation != address(0) && a.kind == kind && a.implementation == implementation
            && implementation.codehash == a.codeHash;
    }
}
