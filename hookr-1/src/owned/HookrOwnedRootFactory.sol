// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CREATE3} from "solmate/src/utils/CREATE3.sol";
import {HookrTypes} from "../types/HookrTypes.sol";
import {IHookrRegistry} from "../interfaces/IHookrRegistry.sol";
import {IHookrOwnedRoots} from "../interfaces/IHookrOwnedRoots.sol";
import {IHookrRootRegistrar} from "../interfaces/IHookrRootRegistrar.sol";
import {IHookrRoot} from "../interfaces/IHookrRoot.sol";
import {IHookrLaneRoot} from "../interfaces/IHookrLaneRoot.sol";
import {IHookrOwnedProfiles} from "../interfaces/IHookrOwnedProfiles.sol";
import {IHookrOwnedRootFactory} from "../interfaces/IHookrOwnedRootFactory.sol";
import {IHookrOwnedTemplate} from "../interfaces/IHookrOwnedTemplate.sol";
import {IHookrRules} from "../interfaces/IHookrRules.sol";
import {IHookrProtocolClaims} from "../interfaces/IHookrProtocolClaims.sol";
import {IHookrTreasury} from "../interfaces/IHookrTreasury.sol";
import {HookrOwnedConformance as C} from "../libraries/HookrOwnedConformance.sol";
import {HookrOwnedRootTypes as F} from "../libraries/HookrOwnedRootTypes.sol";

/// @title HookrOwnedRootFactory
/// @notice Tier 2 of owned roots, self-serve: anyone deploys a Hookr root of their own, an unmodified HookrRoot from
///         the pinned creation code at the CREATE3 address of a salt namespaced by the deployer, with a companion
///         HookrRules for it, and the factory registers the root with the Hookr registry in the same transaction,
///         frozen with the companion's RULES admission, the ADVISORY and GATE admissions its profile lists and the
///         template's open recapture lane with its executor switched off. An owned root starts without arb recapture:
///         it gets it only when its lane is opened through the registry's timelock with an executor that serves every
///         registered root; apps read `activeLaneOf(root)`.
/// @dev The registry admits this factory through a timelocked `SET_ROOT_FACTORY` pinned to its runtime codehash, which
///      commits to every immutable below: the template root and its Rules, the treasury, the cap and the root and Rules
///      creation-code hashes. A root is derived only from a profile naming the template Rules: every companion is a
///      plain HookrRules from the pinned build, so a profile naming a variant could never be honoured. The deployer
///      passes the creation code, accepted only at the pinned hashes, and its choices; every constructor argument of
///      the root (the template's PoolManager, registry, router, quoter and curated router) and of the companion (the
///      treasury, the root, the template Rules' protocol-share floor) is the factory's. The registry re-checks the root
///      and the companion when it registers them. The factory holds no funds and has no owner; it answers the
///      registry's `mayOpen` and the treasury's `rulesOf` (IHookrRootRegistrar).
contract HookrOwnedRootFactory is IHookrOwnedRootFactory {
    /// @inheritdoc IHookrOwnedRootFactory
    uint256 public constant MIN_MAX_DEPLOYMENTS = 1;
    /// @inheritdoc IHookrOwnedRootFactory
    uint256 public constant MAX_MAX_DEPLOYMENTS = 500;
    /// @inheritdoc IHookrOwnedRootFactory
    uint256 public constant DEFAULT_MAX_DEPLOYMENTS = 500;
    /// @inheritdoc IHookrOwnedRootFactory
    uint256 public constant FEE_FORWARD_GAS = 100_000;
    /// @dev keccak256("hookr.owned-root-factory.transient.lock")
    bytes32 private constant LOCK = keccak256("hookr.owned-root-factory.transient.lock");

    /// @inheritdoc IHookrOwnedRootFactory
    IPoolManager public immutable poolManager;
    /// @inheritdoc IHookrOwnedRootFactory
    IHookrRegistry public immutable registry;
    /// @inheritdoc IHookrOwnedRootFactory
    IHookrOwnedProfiles public immutable profiles;
    /// @inheritdoc IHookrOwnedRootFactory
    address public immutable template;
    /// @inheritdoc IHookrOwnedRootFactory
    address public immutable templateRules;
    /// @inheritdoc IHookrOwnedRootFactory
    address public immutable router;
    /// @inheritdoc IHookrOwnedRootFactory
    address public immutable quoter;
    /// @inheritdoc IHookrOwnedRootFactory
    address public immutable curatedRouter;
    /// @inheritdoc IHookrOwnedRootFactory
    address public immutable treasury;
    /// @inheritdoc IHookrOwnedRootFactory
    uint160 public immutable rootClassFlags;
    /// @inheritdoc IHookrOwnedRootFactory
    bytes32 public immutable rootCreationCodeHash;
    /// @inheritdoc IHookrOwnedRootFactory
    bytes32 public immutable rulesCreationCodeHash;
    /// @inheritdoc IHookrOwnedRootFactory
    uint256 public immutable maxDeployments;

    mapping(bytes32 namespacedSalt => bool) private _used;
    mapping(address root => OwnedRoot) private _records;
    mapping(address root => address) private _pendingOwner;
    address[] private _deployments;

    /// @param registry_ The Hookr registry.
    /// @param profiles_ The tier-1 profile book on `registry_`.
    /// @param template_ The template root: a HookrRoot wired to `registry_` whose address carries its permission flags.
    /// @param templateRules_ The template Rules: the HookrRules answering to `template_` that pays `treasury_`.
    /// @param treasury_ The protocol-fee recipient of every companion (Hookr's treasury), on `registry_`'s PoolManager.
    /// @param rootCodeHash keccak256 of the reviewed HookrRoot creation code.
    /// @param rulesCodeHash keccak256 of the reviewed HookrRules creation code.
    /// @param maxDeployments_ The deployment cap, MIN_MAX_DEPLOYMENTS to MAX_MAX_DEPLOYMENTS.
    constructor(
        IHookrRegistry registry_,
        IHookrOwnedProfiles profiles_,
        address template_,
        address templateRules_,
        address treasury_,
        bytes32 rootCodeHash,
        bytes32 rulesCodeHash,
        uint256 maxDeployments_
    ) {
        if (
            address(registry_).code.length == 0 || address(profiles_).code.length == 0 || template_.code.length == 0
                || templateRules_.code.length == 0 || treasury_.code.length == 0 || rootCodeHash == bytes32(0)
                || rulesCodeHash == bytes32(0) || maxDeployments_ < MIN_MAX_DEPLOYMENTS
                || maxDeployments_ > MAX_MAX_DEPLOYMENTS
        ) revert InvalidWiring();
        IPoolManager manager = registry_.poolManager();
        uint160 flags = uint160(template_) & Hooks.ALL_HOOK_MASK;
        IHookrRoot t = IHookrRoot(template_);
        if (
            address(profiles_.registry()) != address(registry_) || address(t.registry()) != address(registry_)
                || address(t.poolManager()) != address(manager) || flags == 0
                || IHookrOwnedTemplate(template_).PERMISSION_FLAGS() != flags
                || address(IHookrTreasury(treasury_).poolManager()) != address(manager)
                || IHookrRules(templateRules_).trustedRoot() != template_
                || IHookrProtocolClaims(templateRules_).protocolRecipient() != treasury_
        ) revert InvalidWiring();
        poolManager = manager;
        registry = registry_;
        profiles = profiles_;
        template = template_;
        templateRules = templateRules_;
        router = t.router();
        quoter = t.quoter();
        curatedRouter = t.curatedRouter();
        treasury = treasury_;
        rootClassFlags = flags;
        rootCreationCodeHash = rootCodeHash;
        rulesCreationCodeHash = rulesCodeHash;
        maxDeployments = maxDeployments_;
    }

    /// @inheritdoc IHookrOwnedRootFactory
    function deploy(
        bytes calldata rootCreationCode,
        bytes calldata rulesCreationCode,
        RootSelections calldata selections,
        bytes32 salt
    ) external payable returns (address root) {
        _lock();
        uint256 fee = IHookrTreasury(treasury).ownedRootFee();
        if (msg.value != fee) revert WrongFee(msg.value, fee);
        bytes32 codeHash = keccak256(rootCreationCode);
        if (codeHash != rootCreationCodeHash) revert CreationCodeNotAllowed(codeHash);
        codeHash = keccak256(rulesCreationCode);
        if (codeHash != rulesCreationCodeHash) revert CreationCodeNotAllowed(codeHash);
        if (_deployments.length >= maxDeployments) revert FactoryFull(maxDeployments);
        IHookrOwnedProfiles.Profile memory p = _checkedProfile(selections);
        IHookrRegistry.Admission memory admission = _templateAdmission(p.rules);
        bytes32 namespaced = _namespace(msg.sender, salt);
        if (_used[namespaced]) revert SaltUsed(msg.sender, salt);
        _used[namespaced] = true;
        root = CREATE3.getDeployed(namespaced);
        // Checked before any code runs: a salt not mined for the template's flags never deploys.
        if (uint160(root) & Hooks.ALL_HOOK_MASK != rootClassFlags) revert Hooks.HookAddressNotValid(root);
        bytes memory args = abi.encode(poolManager, registry, router, quoter, curatedRouter);
        CREATE3.deploy(namespaced, bytes.concat(rootCreationCode, args), 0);
        address rules = _deployCompanion(rulesCreationCode, root);
        admission.implementation = rules;
        admission.codeHash = rules.codehash;
        admission.caps = F.hardCaps(p.caps, selections.ruleMask);
        OwnedRoot storage o = _records[root];
        (o.publicOpening, o.laneAllowed, o.profileVersion) = (selections.publicOpening, p.laneEnabled, p.version);
        (o.rules, o.profileId, o.ruleMask) = (rules, selections.profileId, selections.ruleMask);
        _deployments.push(root);
        IHookrOwnedRoots(address(registry)).registerOwnedRoot(root, template, templateRules, admission, _copies(p));
        emit Deployed(root, rootCreationCodeHash, msg.sender, args, namespaced);
        emit RootDeployed(root, msg.sender, rules, selections);
        if (selections.owner == msg.sender) {
            o.owner = msg.sender;
            emit RootOwnershipTransferred(root, address(0), msg.sender);
        } else {
            _pendingOwner[root] = selections.owner;
            emit RootOwnershipTransferStarted(root, address(0), selections.owner);
        }
        if (fee != 0) {
            address to = IHookrTreasury(treasury).target();
            (bool ok,) = to.call{value: fee, gas: FEE_FORWARD_GAS}("");
            if (!ok) revert FeeNotForwarded(to);
            emit DeployFeePaid(root, to, fee);
        }
        _unlock();
    }

    /// @inheritdoc IHookrOwnedRootFactory
    function deployFee() external view returns (uint256) {
        return IHookrTreasury(treasury).ownedRootFee();
    }

    /// @inheritdoc IHookrRootRegistrar
    /// @dev One storage read; the registry asks it with a bounded static call for every new pool on `root`.
    function mayOpen(address root, address opener) external view returns (bool) {
        OwnedRoot storage o = _records[root];
        return !o.paused && (o.publicOpening || (o.owner != address(0) && opener == o.owner));
    }

    /// @inheritdoc IHookrRootRegistrar
    function rulesOf(address root) external view returns (address) {
        return _records[root].rules;
    }

    /// @inheritdoc IHookrOwnedRootFactory
    function setPaused(address root, bool paused) external {
        OwnedRoot storage o = _owned(root);
        if (msg.sender != o.owner) revert NotRootOwner(root, msg.sender);
        o.paused = paused;
        emit RootPaused(root, paused);
    }

    /// @inheritdoc IHookrOwnedRootFactory
    function transferRootOwnership(address root, address nominee) external {
        OwnedRoot storage o = _owned(root);
        if (msg.sender != o.owner) revert NotRootOwner(root, msg.sender);
        _pendingOwner[root] = nominee;
        emit RootOwnershipTransferStarted(root, msg.sender, nominee);
    }

    /// @inheritdoc IHookrOwnedRootFactory
    function acceptRootOwnership(address root) external {
        OwnedRoot storage o = _owned(root);
        if (msg.sender != _pendingOwner[root]) revert NotRootOwner(root, msg.sender);
        address previous = o.owner;
        o.owner = msg.sender;
        delete _pendingOwner[root];
        emit RootOwnershipTransferred(root, previous, msg.sender);
    }

    /// @inheritdoc IHookrOwnedRootFactory
    function pendingRootOwner(address root) external view returns (address) {
        return _pendingOwner[root];
    }

    /// @inheritdoc IHookrOwnedRootFactory
    function ownedRoot(address root) external view returns (OwnedRoot memory) {
        return _records[root];
    }

    /// @inheritdoc IHookrOwnedRootFactory
    /// @dev The pool's declared caps are not compared: the root binds every pool at the lower of its declared caps and
    ///      the companion's admission.
    function ownedRootConforms(address root, PoolId id) external view returns (bool) {
        OwnedRoot storage o = _records[root];
        if (o.rules == address(0)) return false;
        HookrTypes.Caps memory any = HookrTypes.Caps(type(uint24).max, type(uint24).max, type(uint16).max);
        address[] memory advisories = profiles.profileAt(o.profileId, o.profileVersion).advisories;
        return C.poolFits(root, id, o.rules, advisories, any, o.ruleMask, o.laneAllowed);
    }

    /// @inheritdoc IHookrOwnedRootFactory
    function runtimeMatchesTemplate(address root) external view returns (bool) {
        (address tLane, bytes32 tLaneHash) = IHookrLaneRoot(template).laneModule();
        (address rLane, bytes32 rLaneHash) = IHookrLaneRoot(root).laneModule();
        if (tLane.codehash != tLaneHash || rLane.codehash != rLaneHash || tLane == rLane) return false;
        if (_hashReplacing(tLane, tLane, rLane, bytes32(0), bytes32(0)) != rLaneHash) return false;
        return _hashReplacing(template, tLane, rLane, tLaneHash, rLaneHash) == root.codehash;
    }

    /// @inheritdoc IHookrOwnedRootFactory
    function computeAddress(address deployer, bytes32 salt) external view returns (address) {
        return CREATE3.getDeployed(_namespace(deployer, salt));
    }

    /// @inheritdoc IHookrOwnedRootFactory
    function saltUsed(address deployer, bytes32 salt) external view returns (bool) {
        return _used[_namespace(deployer, salt)];
    }

    /// @inheritdoc IHookrOwnedRootFactory
    function isAllowedCreationCode(bytes32 creationCodeHash) external view returns (bool) {
        return creationCodeHash == rootCreationCodeHash;
    }

    /// @inheritdoc IHookrOwnedRootFactory
    function isFromFactory(address root) external view returns (bool) {
        return _records[root].rules != address(0);
    }

    /// @inheritdoc IHookrOwnedRootFactory
    function creationCodeHashOf(address root) external view returns (bytes32) {
        return _records[root].rules == address(0) ? bytes32(0) : rootCreationCodeHash;
    }

    /// @inheritdoc IHookrOwnedRootFactory
    function allDeploymentsLength() external view returns (uint256) {
        return _deployments.length;
    }

    /// @inheritdoc IHookrOwnedRootFactory
    function allDeployments(uint256 index) external view returns (address) {
        return _deployments[index];
    }

    /// @dev The profile the selections name, at the version they read, on the template root, usable by the caller,
    ///      with the selections inside it, while the template takes new pools.
    function _checkedProfile(RootSelections calldata s) private view returns (IHookrOwnedProfiles.Profile memory p) {
        p = profiles.profile(s.profileId);
        if (p.version == 0) revert UnknownProfile(s.profileId);
        if (s.profileVersion != p.version) revert ProfileVersionMismatch(s.profileId, s.profileVersion, p.version);
        if (p.root != template || !registry.rootOpen(template)) revert InvalidTemplate(p.root);
        if (!p.publicOpening && msg.sender != p.owner) revert NotProfileOwner(s.profileId, msg.sender);
        if (s.owner == address(0)) revert InvalidOwner();
        if (s.ruleMask & ~p.ruleMask != 0) revert OutsideProfile(s.profileId);
        if (s.publicOpening && s.ruleMask & F.SOFT_FEATURES != F.SOFT_FEATURES) {
            revert SoftMaskNeedsOwnerOnly(s.ruleMask);
        }
    }

    /// @dev The template Rules' live RULES admission on the template, whose module must still pay this factory's
    ///      treasury: the terms the companion's admission copies. `profileRules`, the profile's Rules module, must be
    ///      the template Rules: the companion is a plain HookrRules, which could never offer what a variant does.
    function _templateAdmission(address profileRules) private view returns (IHookrRegistry.Admission memory a) {
        a = registry.admission(template, templateRules);
        if (
            profileRules != templateRules || a.kind != IHookrRegistry.Kind.RULES || a.implementation != templateRules
                || templateRules.codehash != a.codeHash
                || IHookrProtocolClaims(templateRules).protocolRecipient() != treasury
        ) revert InvalidTemplate(template);
    }

    /// @dev One companion per root, CREATE2 with the root's address as salt, from the pinned Rules build, paying the
    ///      treasury at the template Rules' protocol-share floor.
    function _deployCompanion(bytes calldata code, address root) private returns (address rules) {
        uint16 floorBps = IHookrOwnedTemplate(templateRules).minProtocolShareBps();
        bytes memory init = bytes.concat(code, abi.encode(poolManager, registry, treasury, root, floorBps));
        bytes32 s = bytes32(uint256(uint160(root)));
        assembly ("memory-safe") {
            rules := create2(0, add(init, 32), mload(init), s)
        }
        if (rules == address(0)) revert CompanionNotDeployed(root);
    }

    /// @dev The template admissions the root copies: the profile's advisories, then its gates.
    function _copies(IHookrOwnedProfiles.Profile memory p) private pure returns (address[] memory list) {
        uint256 n = p.advisories.length;
        list = new address[](n + p.gates.length);
        for (uint256 i; i < n; ++i) {
            list[i] = p.advisories[i];
        }
        for (uint256 i; i < p.gates.length; ++i) {
            list[n + i] = p.gates[i];
        }
    }

    /// @dev keccak256 of `account`'s runtime with every 20-byte `oldAddress` replaced by `newAddress` and, when
    ///      `oldHash` is nonzero, every 32-byte `oldHash` replaced by `newHash`, scanning left to right.
    function _hashReplacing(address account, address oldAddress, address newAddress, bytes32 oldHash, bytes32 newHash)
        private
        view
        returns (bytes32 h)
    {
        uint256 n = account.code.length;
        if (n < 32) return bytes32(0);
        assembly ("memory-safe") {
            let p := mload(0x40)
            extcodecopy(account, p, 0, n)
            let end := sub(n, 19)
            let hashEnd := sub(n, 31)
            for { let i := 0 } lt(i, end) { i := add(i, 1) } {
                let w := mload(add(p, i))
                if and(iszero(iszero(oldHash)), and(lt(i, hashEnd), eq(w, oldHash))) {
                    mstore(add(p, i), newHash)
                    i := add(i, 31)
                    continue
                }
                if eq(shr(96, w), oldAddress) {
                    mstore(add(p, i), or(shl(96, newAddress), and(w, 0xffffffffffffffffffffffff)))
                    i := add(i, 19)
                }
            }
            h := keccak256(p, n)
        }
    }

    /// @dev The record of a root this factory deployed.
    function _owned(address root) private view returns (OwnedRoot storage o) {
        o = _records[root];
        if (o.rules == address(0)) revert NotOwnedRoot(root);
    }

    /// @dev Under CREATE3 the address ignores the creation code, so the salt is bound to the account that deploys:
    ///      nobody else can take the address a deployer mined.
    function _namespace(address deployer, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(deployer, salt));
    }

    function _lock() private {
        bytes32 slot = LOCK;
        uint256 entered;
        assembly ("memory-safe") {
            entered := tload(slot)
        }
        if (entered != 0) revert Reentrancy();
        assembly ("memory-safe") {
            tstore(slot, 1)
        }
    }

    function _unlock() private {
        bytes32 slot = LOCK;
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }
}
