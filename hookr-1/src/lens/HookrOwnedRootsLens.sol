// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {HookrTypes} from "../types/HookrTypes.sol";
import {IHookrRegistry} from "../interfaces/IHookrRegistry.sol";
import {IHookrLanes} from "../interfaces/IHookrLanes.sol";
import {IHookrOwnedProfiles} from "../interfaces/IHookrOwnedProfiles.sol";
import {IHookrOwnedRootFactory} from "../interfaces/IHookrOwnedRootFactory.sol";
import {IHookrOwnedRootsLens} from "../interfaces/IHookrOwnedRootsLens.sol";
import {IHookrProtocolClaims} from "../interfaces/IHookrProtocolClaims.sol";
import {IHookrTreasury} from "../interfaces/IHookrTreasury.sol";
import {HookrOwnedRootTypes as F} from "../libraries/HookrOwnedRootTypes.sol";

/// @title HookrOwnedRootsLens
/// @notice The creator knobs of owned roots with their bounds and defaults, for the app and the SDK.
/// @dev View-only: no state and no owner; its one constructor argument is the release's family router, which its
///      default profile lists. It enforces nothing; the book, the factory and the registry enforce every bound it
///      reports.
contract HookrOwnedRootsLens is IHookrOwnedRootsLens {
    /// @inheritdoc IHookrOwnedRootsLens
    bytes32 public constant ALL_FEATURES = F.ALL_FEATURES;
    /// @inheritdoc IHookrOwnedRootsLens
    bytes32 public constant PUBLIC_REQUIRED_FEATURES = F.SOFT_FEATURES;
    /// @inheritdoc IHookrOwnedRootsLens
    address public immutable familyRouter;

    /// @param familyRouter_ The release's HookrFamilyRouter, or zero for none.
    constructor(address familyRouter_) {
        familyRouter = familyRouter_;
    }

    /// @inheritdoc IHookrOwnedRootsLens
    function profileBounds(IHookrOwnedProfiles book, address root, address rules)
        external
        view
        returns (HookrTypes.Caps memory maxCaps, bytes32 maxRuleMask, uint256 maxAdvisories, uint256 maxGates)
    {
        maxCaps = _admittedCaps(book.registry(), root, rules);
        maxRuleMask = F.ALL_FEATURES;
        maxAdvisories = book.MAX_PROFILE_ADVISORIES();
        maxGates = book.MAX_PROFILE_GATES();
    }

    /// @inheritdoc IHookrOwnedRootsLens
    function defaultProfile(IHookrOwnedProfiles book, address root, address rules, address owner)
        external
        view
        returns (IHookrOwnedProfiles.Profile memory p)
    {
        IHookrRegistry reg = book.registry();
        p.root = root;
        p.rules = rules;
        p.advisories = new address[](0);
        p.gates = new address[](0);
        address[] memory family = new address[](1);
        family[0] = familyRouter;
        if (family[0] != address(0) && _listedLive(reg, root, family, IHookrRegistry.Kind.GATE)) p.gates = family;
        p.caps = _admittedCaps(reg, root, rules);
        p.ruleMask = F.ALL_FEATURES;
        p.laneEnabled = true;
        p.publicOpening = true;
        p.owner = owner;
    }

    /// @inheritdoc IHookrOwnedRootsLens
    function selectionBounds(IHookrOwnedRootFactory factory, bytes32 profileId, address deployer)
        external
        view
        returns (SelectionBounds memory b)
    {
        IHookrOwnedProfiles.Profile memory p = factory.profiles().profile(profileId);
        IHookrRegistry reg = factory.registry();
        address template = factory.template();
        address treasury = factory.treasury();
        b.profileVersion = p.version;
        b.maxRuleMask = p.ruleMask;
        b.publicRequiredMask = F.SOFT_FEATURES;
        b.publicAllowed = p.ruleMask & F.SOFT_FEATURES == F.SOFT_FEATURES;
        b.deployerAllowed = p.version != 0 && (p.publicOpening || deployer == p.owner);
        b.caps = p.caps;
        b.laneCopied = _laneOpen(reg, template);
        b.fee = IHookrTreasury(treasury).ownedRootFee();
        b.deployable = b.deployerAllowed && p.root == template && p.rules == factory.templateRules()
            && _paysTreasury(reg, template, p.rules, treasury)
            && _listedLive(reg, template, p.advisories, IHookrRegistry.Kind.ADVISORY)
            && _listedLive(reg, template, p.gates, IHookrRegistry.Kind.GATE) && reg.rootOpen(template)
            && reg.isRootFactory(address(factory)) && factory.allDeploymentsLength() < factory.maxDeployments();
    }

    /// @inheritdoc IHookrOwnedRootsLens
    function defaultSelections(IHookrOwnedRootFactory factory, bytes32 profileId, address deployer)
        external
        view
        returns (IHookrOwnedRootFactory.RootSelections memory s)
    {
        IHookrOwnedProfiles.Profile memory p = factory.profiles().profile(profileId);
        s.profileId = profileId;
        s.profileVersion = p.version;
        s.ruleMask = p.ruleMask;
        s.publicOpening = p.ruleMask & F.SOFT_FEATURES == F.SOFT_FEATURES;
        s.owner = deployer;
    }

    /// @dev The caps of `rules`' live RULES admission on `root`, or zero caps when it holds none.
    function _admittedCaps(IHookrRegistry reg, address root, address rules)
        private
        view
        returns (HookrTypes.Caps memory caps)
    {
        IHookrRegistry.Admission memory a = reg.admission(root, rules);
        if (
            rules != address(0) && a.kind == IHookrRegistry.Kind.RULES && a.implementation == rules
                && rules.codehash == a.codeHash
        ) caps = a.caps;
    }

    /// @dev Whether `root` has an open recapture lane.
    function _laneOpen(IHookrRegistry reg, address root) private view returns (bool) {
        (address executor,,,) = IHookrLanes(address(reg)).activeLaneOf(root);
        return executor != address(0);
    }

    /// @dev Whether `rules` holds a live RULES admission on `root` and pays `treasury`.
    function _paysTreasury(IHookrRegistry reg, address root, address rules, address treasury)
        private
        view
        returns (bool)
    {
        IHookrRegistry.Admission memory a = reg.admission(root, rules);
        return rules != address(0) && a.kind == IHookrRegistry.Kind.RULES && a.implementation == rules
            && rules.codehash == a.codeHash && IHookrProtocolClaims(rules).protocolRecipient() == treasury;
    }

    /// @dev Whether every entry of `list` is a live admission of `kind` on `root`: the registry reports a revoked one,
    ///      or one whose bond does not cover it, as empty.
    function _listedLive(IHookrRegistry reg, address root, address[] memory list, IHookrRegistry.Kind kind)
        private
        view
        returns (bool)
    {
        for (uint256 i; i < list.length; ++i) {
            address implementation = list[i];
            IHookrRegistry.Admission memory a = reg.admission(root, implementation);
            if (a.kind != kind || a.implementation != implementation || implementation.codehash != a.codeHash) {
                return false;
            }
        }
        return true;
    }
}
