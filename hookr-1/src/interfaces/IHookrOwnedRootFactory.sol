// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookrRegistry} from "./IHookrRegistry.sol";
import {IHookrRootRegistrar} from "./IHookrRootRegistrar.sol";
import {IHookrOwnedProfiles} from "./IHookrOwnedProfiles.sol";

/// @title IHookrOwnedRootFactory
/// @notice Tier 2 of owned roots, self-serve: anyone deploys a Hookr root of their own, an unmodified HookrRoot from
///         the pinned creation code at the CREATE3 address of a salt the factory namespaces by the deployer, with a
///         companion HookrRules for it, and the factory registers both with the Hookr registry in the same transaction
///         (IHookrOwnedRoots.registerOwnedRoot). The registry checks the root and the companion and registers the root
///         frozen with the companion's RULES admission (the template's RULES terms with the caps of a tier-1 profile on
///         the template root, Auto Burn capped off when the root's rule mask leaves it out), the ADVISORY and GATE
///         admissions the profile lists, and the template's open recapture lane with its executor switched off.
///         The root keeps Hookr's launcher, router, quoter and treasury, and its pools pay Hookr's treasury through the
///         companion at the template Rules' protocol-share floor.
/// @dev An owned root starts without arb recapture: its copy of the template's lane is braked, `activeLaneOf(root)`
///      reads empty, a pool asking for arb recapture cannot open on it and none of its pools pays the lane's gas floor.
///      It gets arb recapture only when the registry owner opens its lane through the timelock (an `OPEN_LANE`, or a
///      `LANE_ON` of the copied executor, queued after the registration) with an executor that serves every registered
///      root; pools opened before that keep no lane, since a pool freezes its executor when it opens. Apps read
///      `activeLaneOf(root)` to show whether a new pool can take arb recapture.
///      The factory implements IHookrRootRegistrar: the registry asks it `mayOpen` for every new pool on one of its
///      roots (public, or only the root's owner, and nobody while the owner paused the root) and the treasury asks it
///      `rulesOf` to know a root's companion. It holds no funds and has no owner; each root's owner of record is set in
///      two steps. Every deployment is enumerable (Uniswap's AllowlistedFactory views).
interface IHookrOwnedRootFactory is IHookrRootRegistrar {
    /// @notice What a deployer chooses for a root; everything else is the factory's or the profile's.
    struct RootSelections {
        /// @notice The tier-1 profile on the template root the root derives from: its Rules module, caps, features,
        ///         advisories and gates.
        bytes32 profileId;
        /// @notice The profile version the deployer read; any other version is refused.
        uint32 profileVersion;
        /// @notice The features the root's pools may use (HookrOwnedRootTypes), a subset of the profile's. Leaving Auto
        ///         Burn out caps the subject take at zero, which every pool's Rules enforce at bind; the other four
        ///         features are soft and a public root keeps them all.
        bytes32 ruleMask;
        /// @notice Whether anyone may open pools on the root; otherwise only its owner of record.
        bool publicOpening;
        /// @notice The root's owner of record: it may pause new pools on the root, opens them on an owner-only root and
        ///         hands the role on in two steps. When it is the deployer it holds the role at once; any other account
        ///         is nominated and holds it once it accepts (`acceptRootOwnership`).
        address owner;
    }

    /// @notice The factory's record of a root it deployed.
    struct OwnedRoot {
        /// @notice The owner of record; zero until a nominee accepts.
        address owner;
        /// @notice Whether anyone may open pools on the root.
        bool publicOpening;
        /// @notice Whether the owner paused new pools on the root.
        bool paused;
        /// @notice Whether the profile allowed its pools the recapture lane (`ownedRootConforms`).
        bool laneAllowed;
        /// @notice The profile version the root derives from.
        uint32 profileVersion;
        /// @notice The root's companion Rules module.
        address rules;
        /// @notice The profile the root derives from.
        bytes32 profileId;
        /// @notice The features the root's pools may use.
        bytes32 ruleMask;
    }

    /// @notice `root` was deployed by `deployer` with its companion `rules` and registered with the registry.
    /// @param root The owned root.
    /// @param deployer The account that deployed it.
    /// @param rules The root's companion Rules module.
    /// @param selections The deployer's choices.
    event RootDeployed(
        address indexed root, address indexed deployer, address indexed rules, RootSelections selections
    );

    /// @notice Uniswap AllowlistedFactory-shaped deployment event, so an indexer keyed on that shape sees every root.
    /// @param deployed The owned root.
    /// @param creationCodeHash keccak256 of the root's creation code, without its constructor arguments.
    /// @param deployer The account that deployed it.
    /// @param constructorArgs The root's ABI-encoded constructor arguments.
    /// @param salt The namespaced CREATE3 salt used.
    event Deployed(
        address indexed deployed,
        bytes32 indexed creationCodeHash,
        address indexed deployer,
        bytes constructorArgs,
        bytes32 salt
    );

    /// @notice `owner` nominated `nominee` as `root`'s next owner of record; a zero nominee withdraws the nomination.
    /// @param root The owned root.
    /// @param owner The current owner of record, zero at deployment.
    /// @param nominee The nominee.
    event RootOwnershipTransferStarted(address indexed root, address indexed owner, address indexed nominee);

    /// @notice `newOwner` became `root`'s owner of record.
    /// @param root The owned root.
    /// @param previousOwner The previous owner, zero at deployment.
    /// @param newOwner The new owner.
    event RootOwnershipTransferred(address indexed root, address indexed previousOwner, address indexed newOwner);

    /// @notice `root`'s owner paused or resumed new pools on it.
    /// @param root The owned root.
    /// @param paused Whether new pools are paused.
    event RootPaused(address indexed root, bool paused);

    /// @notice The deploy fee of `root` reached the treasury's target.
    /// @param root The owned root.
    /// @param target The treasury's target that received it.
    /// @param fee The fee, in the native currency's base units.
    event DeployFeePaid(address indexed root, address indexed target, uint256 fee);

    /// @notice A constructor argument does not match the Hookr stack it names.
    error InvalidWiring();

    /// @notice The creation code's hash is not the one this factory deploys.
    error CreationCodeNotAllowed(bytes32 creationCodeHash);

    /// @notice The factory reached its deployment cap.
    error FactoryFull(uint256 cap);

    /// @notice `deployer` already used `salt`.
    error SaltUsed(address deployer, bytes32 salt);

    /// @notice No profile was ever written under `profileId`.
    error UnknownProfile(bytes32 profileId);

    /// @notice The profile's version moved after the deployer read it.
    error ProfileVersionMismatch(bytes32 profileId, uint32 selected, uint32 current);

    /// @notice The profile is owner-only and `deployer` is not its owner.
    error NotProfileOwner(bytes32 profileId, address deployer);

    /// @notice The profile is not on this factory's template root, the template takes no new pools, the profile names
    ///         a Rules module other than the template Rules (`templateRules()`), or the template Rules hold no live
    ///         RULES admission there that pays this factory's treasury.
    error InvalidTemplate(address template);

    /// @notice The rule mask is outside the profile's.
    error OutsideProfile(bytes32 profileId);

    /// @notice A root anyone may open pools on must keep every soft feature, so every rule it advertises is one its
    ///         pools can use.
    error SoftMaskNeedsOwnerOnly(bytes32 ruleMask);

    /// @notice The owner of record selected for a new root is the zero address.
    error InvalidOwner();

    /// @notice The companion Rules module could not be deployed for `root`.
    error CompanionNotDeployed(address root);

    /// @notice The factory was re-entered.
    error Reentrancy();

    /// @notice `sent` is not the deploy fee `fee`.
    error WrongFee(uint256 sent, uint256 fee);

    /// @notice The deploy fee could not be sent to the treasury's target `target`.
    error FeeNotForwarded(address target);

    /// @notice `root` was not deployed by this factory.
    error NotOwnedRoot(address root);

    /// @notice `caller` is not the owner of record, or the nominee, the call needs.
    error NotRootOwner(address root, address caller);

    /// @notice Deploys an owned root from `rootCreationCode` at `computeAddress(msg.sender, salt)` and its companion
    ///         Rules module from `rulesCreationCode`, and registers the root with the registry, frozen, in the same
    ///         transaction. The caller sends exactly the deploy fee (`deployFee()`, the treasury's `ownedRootFee()`),
    ///         which the factory forwards to the treasury's target in the same call with at most FEE_FORWARD_GAS; a
    ///         failed forward reverts the deployment.
    /// @dev Reverts `Hooks.HookAddressNotValid(root)` before any code runs when the address does not carry the
    ///      template's permission flags; mine the salt for them. The registry's checks (IHookrOwnedRoots) apply, and
    ///      any brake that stops registration (the factory deactivated, new markets paused, the template closed or
    ///      retired) reverts the whole deployment. The profile must name the template Rules (`templateRules()`), since
    ///      the companion is always a plain HookrRules from the pinned build. The companion is deployed with CREATE2 at
    ///      the root's address as salt, paying this factory's treasury at the template Rules' protocol-share floor.
    /// @param rootCreationCode The HookrRoot creation code, accepted only at `rootCreationCodeHash`.
    /// @param rulesCreationCode The HookrRules creation code, accepted only at `rulesCreationCodeHash`.
    /// @param selections The deployer's choices.
    /// @param salt The deployer's salt, namespaced by the deployer.
    /// @return root The owned root.
    function deploy(
        bytes calldata rootCreationCode,
        bytes calldata rulesCreationCode,
        RootSelections calldata selections,
        bytes32 salt
    ) external payable returns (address root);

    /// @notice The deploy fee `deploy` takes now: the treasury's `ownedRootFee()`.
    /// @return The fee, in the native currency's base units.
    function deployFee() external view returns (uint256);

    /// @notice Pauses or resumes new pools on `root`. Only its owner of record. Pools already open are not affected.
    /// @param root The owned root.
    /// @param paused Whether new pools are paused.
    function setPaused(address root, bool paused) external;

    /// @notice Nominates `nominee` as `root`'s next owner of record, or withdraws the nomination with zero. Only its
    ///         owner of record.
    /// @param root The owned root.
    /// @param nominee The nominee, or zero.
    function transferRootOwnership(address root, address nominee) external;

    /// @notice Accepts the nomination as `root`'s owner of record. Only the nominee.
    /// @param root The owned root.
    function acceptRootOwnership(address root) external;

    /// @notice `root`'s nominee, or zero.
    /// @param root The owned root.
    /// @return The nominee.
    function pendingRootOwner(address root) external view returns (address);

    /// @notice The factory's record of `root`; all zero for an address it did not deploy.
    /// @param root The owned root.
    /// @return The record.
    function ownedRoot(address root) external view returns (OwnedRoot memory);

    /// @notice Whether pool `id` of `root` binds the root's companion, no advisory or one its profile version lists,
    ///         only the root's features, and the recapture lane only when the profile allowed it.
    /// @param root The owned root.
    /// @param id The pool.
    /// @return Whether the pool conforms.
    function ownedRootConforms(address root, PoolId id) external view returns (bool);

    /// @notice Whether `root` runs the template's exact build. Every HookrRoot deploys its own HookrLane module and
    ///         keeps that module's address and runtime codehash in its runtime, and the module keeps its own address:
    ///         the template's module runtime with its address replaced by the root's module address must hash to the
    ///         root's module codehash, and the template's runtime with the module address and codehash replaced the
    ///         same way must hash to the root's codehash. Everything else (the PoolManager, registry, router, quoter
    ///         and curated router with their codehashes, the permission flags) is then byte-equal.
    /// @dev A byte-level identity check for apps and indexers, kept off the deployment path for its gas; the registry
    ///      checks each root's wiring when it registers it.
    /// @param root The root to check.
    /// @return Whether `root` runs the template's build.
    function runtimeMatchesTemplate(address root) external view returns (bool);

    /// @notice The address `deploy` produces for `deployer` and `salt`.
    /// @param deployer The deploying account.
    /// @param salt The deployer's salt.
    /// @return The owned root's address.
    function computeAddress(address deployer, bytes32 salt) external view returns (address);

    /// @notice Whether `deployer` already used `salt`.
    /// @param deployer The deploying account.
    /// @param salt The salt.
    /// @return Whether it was used.
    function saltUsed(address deployer, bytes32 salt) external view returns (bool);

    /// @notice Whether `creationCodeHash` is the root creation code this factory deploys.
    /// @param creationCodeHash keccak256 of a root creation code.
    /// @return Whether the factory deploys it.
    function isAllowedCreationCode(bytes32 creationCodeHash) external view returns (bool);

    /// @notice Whether this factory deployed `root`.
    /// @param root The address to check.
    /// @return Whether it is one of this factory's roots.
    function isFromFactory(address root) external view returns (bool);

    /// @notice The creation-code hash `root` was deployed from, or zero for an address this factory did not deploy.
    /// @param root The address to check.
    /// @return The creation-code hash.
    function creationCodeHashOf(address root) external view returns (bytes32);

    /// @notice How many roots this factory deployed.
    /// @return The count.
    function allDeploymentsLength() external view returns (uint256);

    /// @notice The `index`th root this factory deployed.
    /// @param index The position, from zero.
    /// @return The root.
    function allDeployments(uint256 index) external view returns (address);

    /// @notice The least deployment cap the constructor accepts: 1.
    /// @return The bound.
    function MIN_MAX_DEPLOYMENTS() external view returns (uint256);

    /// @notice The greatest deployment cap the constructor accepts: 500, the most Uniswap's factory enumerator reads.
    /// @return The bound.
    function MAX_MAX_DEPLOYMENTS() external view returns (uint256);

    /// @notice The release's deployment cap: 500.
    /// @return The default.
    function DEFAULT_MAX_DEPLOYMENTS() external view returns (uint256);

    /// @notice The gas the deploy fee's transfer to the treasury's target gets: 100,000.
    /// @return The gas.
    function FEE_FORWARD_GAS() external view returns (uint256);

    /// @notice The PoolManager every root reports.
    /// @return The PoolManager.
    function poolManager() external view returns (IPoolManager);

    /// @notice The registry the factory registers roots with.
    /// @return The registry.
    function registry() external view returns (IHookrRegistry);

    /// @notice The profile book the factory derives roots from.
    /// @return The book.
    function profiles() external view returns (IHookrOwnedProfiles);

    /// @notice The template root: the shared root whose wiring every owned root carries and whose profiles, admissions
    ///         and lane it takes.
    /// @return The template.
    function template() external view returns (address);

    /// @notice The template Rules: the template's HookrRules that pays the treasury, the one Rules module a profile a
    ///         root is derived from may name. Every companion is a plain HookrRules from the pinned build, so a root
    ///         derived from a profile naming another Rules module (a variant admitted beside it) could never offer what
    ///         that profile advertises; tier-1 profiles on the template may still name any live RULES admission.
    /// @return The template Rules.
    function templateRules() external view returns (address);

    /// @notice The router every root pins: the template's.
    /// @return The router.
    function router() external view returns (address);

    /// @notice The quoter every root pins: the template's.
    /// @return The quoter.
    function quoter() external view returns (address);

    /// @notice The curated router every root pins: the template's.
    /// @return The curated router, or zero.
    function curatedRouter() external view returns (address);

    /// @notice The protocol-fee recipient of every companion, Hookr's treasury: the template Rules' recipient.
    /// @return The treasury.
    function treasury() external view returns (address);

    /// @notice The permission flags every root's address carries: the template's.
    /// @return The flags.
    function rootClassFlags() external view returns (uint160);

    /// @notice keccak256 of the root creation code the factory deploys.
    /// @return The hash.
    function rootCreationCodeHash() external view returns (bytes32);

    /// @notice keccak256 of the Rules creation code the factory deploys companions from.
    /// @return The hash.
    function rulesCreationCodeHash() external view returns (bytes32);

    /// @notice The most roots this factory deploys.
    /// @return The cap.
    function maxDeployments() external view returns (uint256);
}
