// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookrRootRegistrar} from "./IHookrRootRegistrar.sol";

/// @title IHookrOwnedRootFactoryV2
/// @notice Owned-root factory v2 (DESIGN sections 12 and 20.3, DECISIONS D33): anyone deploys an own hook in one
///         transaction, a root v2 at the CREATE3 address of a salt the factory namespaces by the deployer and a
///         companion that is a new instance of the combined core, the template, and the factory registers both with the
///         Hookr registry in the same call (IHookrOwnedRoots.registerOwnedRoot).
///         - The template is any live RULES admission of the combined core on the shared root, named by the deployer's
///           tier-1 profile (D33a). The companion copies its module table (Hook Blocks, the shared recapture and claims
///           modules, the binder), its protocol recipient and its floor, answers to the owned root, takes the
///           template as its part scope, so it creates no brake keys and reads the template's at every bind (D33e),
///           and allows the deployer's blocks, a subset of the template's (D33d).
///         - Creation code comes from code stores pinned at construction (D33c); a deployer sends no code.
///         - The root uses one shared lane module per chain and reads the lane of `laneSource`: the shared root, or none
///           when the deployer opts out of arb recapture (DESIGN 20.2, L4-1).
///         - The root may carry one swap module (NC32), fixed at deploy: a module admitted as a RULES part under the
///           template's scope (NC39), whose HookrFill the factory deploys once per module, gas limit and scope and
///           passes as root v2's `fill`. None by default.
///         - No deployment cap; the deploy fee is the treasury's owned-root fee (D33l).
/// @dev The registry admits the factory through a timelocked `SET_ROOT_FACTORY` pinned to its runtime codehash, which
///      commits to every immutable (the shared root, the treasury, the shared lane, the stores, the creation-code
///      hashes and the core layout the companion check reads) and to HookrFill's creation code, which the factory
///      holds. The factory holds no funds and has no owner; it answers the registry's `mayOpen` and the treasury's
///      `rulesOf` (IHookrRootRegistrar).
interface IHookrOwnedRootFactoryV2 is IHookrRootRegistrar {
    /// @notice What a deployer chooses for a root; everything else is the factory's, the profile's or the template's.
    struct RootSelections {
        /// @notice The tier-1 profile on the shared root the root derives from. Its Rules module is the template.
        bytes32 profileId;
        /// @notice The profile version the deployer read; any other version is refused.
        uint32 profileVersion;
        /// @notice The release features the root's pools may use (HookrOwnedRootTypes), a subset of the profile's.
        bytes32 ruleMask;
        /// @notice Whether anyone may open pools on the root; otherwise only its owner of record.
        bool publicOpening;
        /// @notice The root's owner of record (as v1: the deployer holds it at once, anyone else once it accepts).
        address owner;
        /// @notice The Hook Blocks the root's pools may enable, one bit per brake key (D33d), a subset of the
        ///         template's own; zero allows the release rules alone.
        uint8 allowedBlocks;
        /// @notice The deployer's opt-out of arb recapture: the root reads no lane (`laneSource` zero).
        bool recaptureOff;
        /// @notice The swap module the root's pools fill part of each outer exact-input swap from (NC32), zero for
        ///         none: a live RULES part admission under the template with IHookrSwapModule's schema and its admitted
        ///         code (NC39). Fixed for the root.
        address swapModule;
        /// @notice The hook's name, at most MAX_NAME_BYTES bytes, emitted on chain and stored nowhere.
        string name;
    }

    /// @notice The factory's record of a root it deployed.
    struct OwnedRoot {
        /// @notice The owner of record; zero until a nominee accepts.
        address owner;
        /// @notice Whether anyone may open pools on the root.
        bool publicOpening;
        /// @notice Whether the owner paused new pools on the root.
        bool paused;
        /// @notice Whether the root reads a lane (the profile allows the lane and the deployer did not opt out).
        bool laneAllowed;
        /// @notice The Hook Blocks the companion allows.
        uint8 allowedBlocks;
        /// @notice The profile version the root derives from.
        uint32 profileVersion;
        /// @notice The root's companion: an instance of the template's code.
        address rules;
        /// @notice The template the companion copies.
        address template;
        /// @notice The profile the root derives from.
        bytes32 profileId;
        /// @notice The release features the root's pools may use.
        bytes32 ruleMask;
    }

    /// @notice Where, in the combined core's runtime, the factory reads the template's module table and which immutable
    ///         sites a companion may differ at. Each offset is 16 bits, packed low first; a zero offset ends a mask list.
    /// @dev Exported from a release build (`release/export_core_offsets.py`). A wrong layout fails closed: the companion
    ///      cannot be built from wrong wires (its constructor pins every module by codehash) and cannot pass the check.
    struct CoreLayout {
        /// @notice The core's runtime size.
        uint256 runtimeLength;
        /// @notice The first site of: recapture, recaptureCodeHash, claimsModule, block0, block1, block2, block3,
        ///         binder, allowedBlocks (32-byte words) and the HookrViewSwap link (20 bytes), in that order.
        uint256 reads;
        /// @notice Every site of every per-root, per-allowed and per-scope immutable (32-byte words), at most 32.
        uint256[2] masks;
    }

    /// @notice `root` was deployed by `deployer` with its companion `rules`, an instance of `template`, and registered.
    /// @param root The owned root.
    /// @param deployer The account that deployed it.
    /// @param rules The root's companion.
    /// @param template The combined-core instance the companion copies.
    /// @param laneSource The root whose lane the root reads, zero for none.
    /// @param selections The deployer's choices, the name among them.
    event RootDeployed(
        address indexed root,
        address indexed deployer,
        address indexed rules,
        address template,
        address laneSource,
        RootSelections selections
    );
    /// @notice Uniswap AllowlistedFactory-shaped deployment event, as v1.
    event Deployed(
        address indexed deployed,
        bytes32 indexed creationCodeHash,
        address indexed deployer,
        bytes constructorArgs,
        bytes32 salt
    );
    /// @notice `owner` nominated `nominee` as `root`'s next owner of record; zero withdraws the nomination.
    event RootOwnershipTransferStarted(address indexed root, address indexed owner, address indexed nominee);
    /// @notice `newOwner` became `root`'s owner of record.
    event RootOwnershipTransferred(address indexed root, address indexed previousOwner, address indexed newOwner);
    /// @notice `root`'s owner paused or resumed new pools on it.
    event RootPaused(address indexed root, bool paused);
    /// @notice The deploy fee of `root` reached the treasury's target.
    event DeployFeePaid(address indexed root, address indexed target, uint256 fee);
    /// @notice The HookrFill `fill` of swap module `module` at `gasLimit` under `scope` was deployed, by the first root
    ///         built with that module; every later root with the same module, gas limit and scope reuses it.
    event SwapModuleFillDeployed(address indexed module, address indexed scope, uint256 gasLimit, address fill);

    /// @notice A constructor argument does not match the Hookr stack it names, or a store does not hold its code.
    error InvalidWiring();
    /// @notice `deployer` already used `salt`.
    error SaltUsed(address deployer, bytes32 salt);
    /// @notice No profile was ever written under `profileId`.
    error UnknownProfile(bytes32 profileId);
    /// @notice The profile's version moved after the deployer read it.
    error ProfileVersionMismatch(bytes32 profileId, uint32 selected, uint32 current);
    /// @notice The profile is owner-only and `deployer` is not its owner.
    error NotProfileOwner(bytes32 profileId, address deployer);
    /// @notice The profile is not on the shared root, the shared root takes no new pools, or the profile's Rules hold
    ///         no live RULES admission on it that pays this factory's treasury and answers to the shared root.
    error InvalidTemplate(address template);
    /// @notice The rule mask is outside the profile's.
    error OutsideProfile(bytes32 profileId);
    /// @notice A public root must keep every soft feature.
    error SoftMaskNeedsOwnerOnly(bytes32 ruleMask);
    /// @notice The allowed blocks are outside the template's own.
    error BlocksNotAllowed(uint8 allowedBlocks, uint8 templateBlocks);
    /// @notice The name is longer than MAX_NAME_BYTES.
    error NameTooLong(uint256 length);
    /// @notice The owner of record selected for a new root is the zero address.
    error InvalidOwner();
    /// @notice The companion could not be deployed for `root`.
    error CompanionNotDeployed(address root);
    /// @notice The companion's runtime is not the template's with only its per-root, per-allowed and per-scope
    ///         immutables changed: the template is not an instance of the core this factory deploys.
    error CompanionMismatch(address template, address companion);
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
    /// @notice The swap module holds no live RULES part admission under the template, or one with another schema than
    ///         IHookrSwapModule's, or no longer runs the code admitted; or its HookrFill could not be deployed.
    error InvalidSwapModule(address module);

    /// @notice The longest name a deployer may give a root, in bytes.
    function MAX_NAME_BYTES() external view returns (uint256);

    /// @notice The schema hash a swap module's admission carries: keccak256("IHookrSwapModule").
    function SWAP_MODULE_SCHEMA() external view returns (bytes32);

    /// @notice Deploys an own hook in one transaction: the root at `computeAddress(msg.sender, salt)`, its companion,
    ///         and the registration. The caller sends exactly `deployFee()`, forwarded to the treasury's target.
    /// @dev Reverts `Hooks.HookAddressNotValid(root)` before any code runs when the address does not carry the shared
    ///      root's permission flags. Any brake that stops registration reverts the whole deployment.
    /// @param selections The deployer's choices.
    /// @param salt The deployer's salt, namespaced by the deployer.
    /// @return root The owned root.
    /// @return rules Its companion.
    function deploy(RootSelections calldata selections, bytes32 salt)
        external
        payable
        returns (address root, address rules);

    /// @notice The deploy fee `deploy` takes now: the treasury's `ownedRootFee()`.
    function deployFee() external view returns (uint256);

    /// @notice Pauses or resumes new pools on `root`. Only its owner of record.
    function setPaused(address root, bool paused) external;

    /// @notice Nominates `nominee` as `root`'s next owner of record, or withdraws with zero. Only its owner of record.
    function transferRootOwnership(address root, address nominee) external;

    /// @notice Accepts the nomination as `root`'s owner of record. Only the nominee.
    function acceptRootOwnership(address root) external;

    /// @notice `root`'s nominee, or zero.
    function pendingRootOwner(address root) external view returns (address);

    /// @notice The factory's record of `root`; all zero for an address it did not deploy.
    function ownedRoot(address root) external view returns (OwnedRoot memory);

    /// @notice Whether pool `id` of `root` binds the root's companion, no advisory or one its profile version lists,
    ///         only the root's release features, and the recapture lane only when the root reads one.
    function ownedRootConforms(address root, PoolId id) external view returns (bool);

    /// @notice Whether `companion`'s runtime equals `template`'s outside the per-root, per-allowed and per-scope
    ///         immutable sites of the pinned core layout: the check `deploy` makes of every companion.
    function companionMatchesTemplate(address template, address companion) external view returns (bool);

    /// @notice The template's own allowed blocks, read from its runtime at the pinned layout.
    function templateBlocks(address template) external view returns (uint8);

    /// @notice The address `deploy` produces for `deployer` and `salt`.
    function computeAddress(address deployer, bytes32 salt) external view returns (address);

    /// @notice Whether `deployer` already used `salt`.
    function saltUsed(address deployer, bytes32 salt) external view returns (bool);

    /// @notice The address of the HookrFill of swap module `module` at `gasLimit` under `scope` (deployed or not): the
    ///         CREATE2 address `deploy` builds it at, from this factory with a zero salt.
    function swapModuleFill(address module, uint256 gasLimit, address scope) external view returns (address);

    /// @notice Whether this factory deployed `root`.
    function isFromFactory(address root) external view returns (bool);

    /// @notice How many roots this factory deployed.
    function allDeploymentsLength() external view returns (uint256);

    /// @notice The `index`th root this factory deployed.
    function allDeployments(uint256 index) external view returns (address);
}
