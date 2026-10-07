// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {HookrTypes} from "hookr/types/HookrTypes.sol";
import {IHookrRegistry} from "hookr/interfaces/IHookrRegistry.sol";
import {IHookrRoot} from "hookr/interfaces/IHookrRoot.sol";
import {IHookrModuleBond} from "hookr/interfaces/IHookrModuleBond.sol";
import {HookrReleased} from "hookr/base/HookrReleased.sol";
import {HookrGoverned} from "hookr/base/HookrGoverned.sol";
import {HookrLauncher} from "hookr/periphery/HookrLauncher.sol";
import {ModuleMarketTypes} from "./interfaces/ModuleMarketTypes.sol";
import {IHookrModuleMarket} from "./interfaces/IHookrModuleMarket.sol";
import {IHookrBondVault} from "./interfaces/IHookrBondVault.sol";
import {IHookrUsageFeeRouter} from "./interfaces/IHookrUsageFeeRouter.sol";
import {IHookrMarketModule} from "./interfaces/IHookrMarketModule.sol";
import {ModuleMarketMath} from "./libraries/ModuleMarketMath.sol";
import {IHookrLauncher} from "hookr/interfaces/IHookrLauncher.sol";
import {IRegistryPoolManager} from "./interfaces/IRegistryPoolManager.sol";

/// @title HookrModuleMarket
/// @notice The module registry of the bonded module marketplace (H17). Third-party developers publish
///         advisory modules with a permission manifest, a risk tier and a frozen fee split; $HOOKR bonded in
///         HookrBondVault stands behind each version; creators install a version at launch through the
///         phase-one Launcher's `launchAdvised`; usage fees route out through HookrUsageFeeRouter.
///
///      Where it sits in Hookr 1: a registry-side sidecar beside HookrRegistry. It changes no hook and no
///      phase-one contract. The safety gate stays where phase one put it: a module runs in a pool only if
///      HookrRegistry ADMITs it for that root as an ADVISORY (timelocked, code-hash pinned, capped). This
///      contract adds the economic gate on top: a marketplace module's `bind` calls `recordInstall`, which
///      refuses the pool's initialization unless the version is listed, open, bonded to its tier's floor, and
///      admitted no wider than its manifest. The market is also an IHookrModuleBond: once a queued
///      `SET_ADMISSION_BOND` names it for a module's admission, the registry reports that admission only while the
///      market `covers` it, so the root itself refuses new pools for an unbonded or flagged version before the
///      module's bind runs; the reviewed module code keeps its own check either way.
///
///      Nothing here runs during a swap. A paused, broken or drained marketplace cannot stop a swap in any
///      pool, including pools that installed a marketplace module: modules read only their own bind-time
///      storage in `beforeSwap`, and fees accrue as HookrRules claims whether or not anyone ever collects them.
///
///      Powers. Permissive changes are HookrGoverned operations (queued, published, delayed by the Hookr
///      timelock, expiring 14 days after they mature): reputation bands, guardian, protocol recipient, reserve
///      draws, resuming installs, and giving exit notice for a version whose owner will not (FORCE_EXIT). Slashes
///      are their own published proposals with the same delay; the owner or the guardian can veto one while it is
///      pending. A pending slash blocks the version's bond release, so a slash cannot be dodged by exiting, and its
///      new installs, so no new pool freezes a version governance has flagged.
///      Pausing new installs is immediate (owner or guardian) and touches no existing pool, bond or claim.
///
///      Clocks. Every window here is `block.timestamp` based, so it means the same thing on an anvil fork (where
///      block.number is the L2 height) and on Robinhood Chain (where block.number is the parent-chain height).
contract HookrModuleMarket is HookrReleased, HookrGoverned, IHookrModuleMarket, IHookrModuleBond {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice Timelocked: assign a publisher's reputation band. Arguments: (address publisher, Band band).
    bytes32 public constant SET_BAND = keccak256("SET_BAND");
    /// @notice Timelocked: appoint the guardian (zero removes it). Arguments: (address guardian).
    bytes32 public constant SET_GUARDIAN = keccak256("SET_GUARDIAN");
    /// @notice Timelocked: change who is paid the protocol share, the share still unpaid included. Arguments:
    ///         (address recipient).
    bytes32 public constant SET_PROTOCOL_RECIPIENT = keccak256("SET_PROTOCOL_RECIPIENT");
    /// @notice Timelocked: pay part of one version's reserve. Arguments: (versionId, currency, to, amount, evidence).
    bytes32 public constant DRAW_RESERVE = keccak256("DRAW_RESERVE");
    /// @notice Timelocked: lift a pause on new installs. Arguments: empty.
    bytes32 public constant RESUME_INSTALLS = keccak256("RESUME_INSTALLS");
    /// @notice Timelocked: give notice for a version whose owner will not (lost key, abandoned module), so the
    ///         stakes behind it are not locked for ever. Arguments: (uint256 versionId, bytes32 evidence).
    bytes32 public constant FORCE_EXIT = keccak256("FORCE_EXIT");

    /// @notice Minimum time between an exit request and the end of exposure, even with no installs.
    uint64 public constant EXIT_NOTICE = 7 days;
    /// @notice After this long from the exit request, installs that are still live stop holding the bond.
    /// @dev Bounds the griefing where anyone installs a module into dust pools to lock its bond forever.
    uint64 public constant MAX_DRAIN = 90 days;
    /// @notice Waiting period after exposure ends, so late failures still have a bond behind them.
    uint64 public constant COOLDOWN = 30 days;
    /// @notice Longest manifest URI accepted at publish.
    uint256 public constant MAX_URI_BYTES = 256;
    /// @notice A slash of this size takes the whole bond and terminates the version.
    uint16 public constant FULL_SLASH_BPS = 10_000;

    IHookrRegistry public immutable registry;
    IPoolManager public immutable poolManager;
    IERC20 public immutable hookr;
    uint256 public immutable bondUnit;
    /// @notice The protocol's share of every usage fee, in basis points: a bounded knob frozen at construction
    ///         (PROTOCOL_MIN_BPS, the genesis floor, to PROTOCOL_MAX_BPS) and stamped into every version at publish.
    uint16 public immutable protocolBps;
    /// @notice The slash-compensation reserve's share of every usage fee, frozen like `protocolBps`.
    uint16 public immutable reserveBps;

    IHookrBondVault public vault;
    IHookrUsageFeeRouter public router;
    address public guardian;
    address public protocolRecipient;
    bool public installsPaused;
    uint256 public versionCount;
    uint256 public slashCount;

    mapping(uint256 versionId => ModuleMarketTypes.Version) private _versions;
    /// @inheritdoc IHookrModuleMarket
    mapping(address module => uint256) public versionOf;
    /// @notice Current owner of a module family: publishes its versions, requests exits, is paid the developer share.
    mapping(bytes32 moduleId => address) public moduleOwner;
    /// @notice Nominee who may accept a module family.
    mapping(bytes32 moduleId => address) public pendingModuleOwner;
    /// @notice Highest version number published under a module family.
    mapping(bytes32 moduleId => uint32) public latestNumber;
    /// @notice A publisher's reputation band. NEW by default.
    mapping(address publisher => ModuleMarketTypes.Band) public bandOf;
    mapping(PoolId => ModuleMarketTypes.Install) private _installs;
    /// @inheritdoc IHookrModuleMarket
    mapping(uint256 versionId => mapping(address rules => bool)) public usesRules;
    mapping(uint256 slashId => ModuleMarketTypes.SlashProposal) private _slashes;

    error NotWired();
    error AlreadyWired();
    error BadWiring();
    error AlreadyListed(address module);
    error NotDeveloper(address caller, address developer);
    error WrongMarket(address module);
    error WrongFeeRecipient(address module, address named, address expected);
    error NotModuleOwner(bytes32 moduleId, address caller);
    error FamilyNotNamespaced(bytes32 moduleId, address publisher);
    error TierBelowManifest(ModuleMarketTypes.RiskTier tier, ModuleMarketTypes.RiskTier minimum);
    error InvalidManifestRef();
    error UnknownVersion(uint256 versionId);
    error NotListed(address module);
    error InstallsClosed(uint256 versionId, ModuleMarketTypes.Status status);
    error InstallsArePaused();
    error BondShort(uint256 versionId, uint256 bonded, uint256 required);
    error NotBinding(address root, PoolId id);
    error AdmissionMismatch(address root, address module);
    error AdmissionWiderThanManifest(address root, address module);
    error AlreadyInstalled(PoolId id);
    error NotLive(PoolId id);
    error NoMarketOwner(PoolId id);
    error NotDrained(PoolId id);
    error WrongStatus(uint256 versionId, ModuleMarketTypes.Status status);
    error NotReleasable(uint256 versionId, uint256 releaseAt);
    error SlashPending(uint256 versionId, uint16 pending);
    error InvalidSlash();
    error UnknownSlash(uint256 slashId);
    error SlashNotPending(uint256 slashId);
    error SlashNotReady(uint256 slashId, uint48 readyAt);
    error SlashExpired(uint256 slashId, uint256 expiredAt);
    error SlashNotExpired(uint256 slashId, uint256 expiresAt);
    error NotPaused();

    event Wired(address indexed vault, address indexed router);
    event ModulePublished(
        uint256 indexed versionId,
        bytes32 indexed moduleId,
        address indexed module,
        uint32 number,
        address publisher,
        ModuleMarketTypes.RiskTier tier,
        bytes32 codeHash,
        bytes32 manifestHash,
        ModuleMarketTypes.Manifest manifest,
        ModuleMarketTypes.Split split,
        address feeAccount,
        string manifestURI
    );
    event ModuleInstalled(
        PoolId indexed poolId, uint256 indexed versionId, address indexed root, address liquidityOwner
    );
    event InstallClosed(PoolId indexed poolId, uint256 indexed versionId, ModuleMarketTypes.CloseReason reason);
    event ExitRequested(uint256 indexed versionId, uint64 requestedAt, uint32 liveInstalls);
    event ExitForced(uint256 indexed versionId, bytes32 evidence);
    event VersionReleased(uint256 indexed versionId);
    event VersionTerminated(uint256 indexed versionId);
    event SlashProposed(
        uint256 indexed slashId,
        uint256 indexed versionId,
        uint16 bps,
        ModuleMarketTypes.SlashReason reason,
        address recipient,
        bytes32 evidenceHash,
        uint48 readyAt
    );
    event SlashVetoed(uint256 indexed slashId, address indexed by);
    event SlashExecuted(uint256 indexed slashId, uint256 indexed versionId, uint256 amount);
    event SlashLapsed(uint256 indexed slashId);
    event BandSet(address indexed publisher, ModuleMarketTypes.Band band);
    event GuardianSet(address indexed guardian);
    event ProtocolRecipientSet(address indexed recipient);
    event ReserveDrawn(
        uint256 indexed versionId, Currency indexed currency, address to, uint256 amount, bytes32 evidence
    );
    event InstallsPaused(address indexed by);
    event InstallsResumed();
    event ModuleTransferStarted(bytes32 indexed moduleId, address indexed owner, address indexed nominee);
    event ModuleTransferred(bytes32 indexed moduleId, address indexed owner);

    /// @param owner_ Marketplace governance (the same owner as HookrRegistry in a release).
    /// @param delay_ HookrGoverned delay for permissive operations and slashes: the Hookr timelock, within
    ///        HookrGoverned's MIN_DELAY and MAX_DELAY.
    /// @param registry_ The HookrRegistry whose roots, launchers and admissions this market reads.
    /// @param hookr_ The bond token.
    /// @param protocolRecipient_ Who is paid the protocol's share of usage fees.
    /// @param guardian_ May veto slashes and pause installs; zero for none.
    /// @param protocolBps_ The protocol's share of every usage fee (PROTOCOL_MIN_BPS to PROTOCOL_MAX_BPS; default
    ///        PROTOCOL_DEFAULT_BPS). Frozen for the market's life.
    /// @param reserveBps_ The reserve's share of every usage fee (RESERVE_MIN_BPS to RESERVE_MAX_BPS; default
    ///        RESERVE_DEFAULT_BPS). Frozen for the market's life.
    constructor(
        address owner_,
        uint48 delay_,
        IHookrRegistry registry_,
        IERC20 hookr_,
        address protocolRecipient_,
        address guardian_,
        uint16 protocolBps_,
        uint16 reserveBps_
    ) HookrGoverned(owner_, delay_) {
        ModuleMarketMath.checkShares(protocolBps_, reserveBps_);
        _requireContract(address(registry_));
        _requireContract(address(hookr_));
        if (protocolRecipient_ == address(0)) revert InvalidAddress(protocolRecipient_);
        uint8 decimals = IERC20Metadata(address(hookr_)).decimals();
        if (decimals > 30) revert BadWiring();
        registry = registry_;
        poolManager = IRegistryPoolManager(address(registry_)).poolManager();
        hookr = hookr_;
        bondUnit = 10 ** decimals;
        protocolRecipient = protocolRecipient_;
        guardian = guardian_;
        protocolBps = protocolBps_;
        reserveBps = reserveBps_;
    }

    /// @notice Bounds and default of the protocol share a market may be built with.
    function protocolShareBounds() external pure returns (uint16 minBps, uint16 maxBps, uint16 defaultBps) {
        return
            (
                ModuleMarketMath.PROTOCOL_MIN_BPS,
                ModuleMarketMath.PROTOCOL_MAX_BPS,
                ModuleMarketMath.PROTOCOL_DEFAULT_BPS
            );
    }

    /// @notice Bounds and default of the reserve share a market may be built with.
    function reserveShareBounds() external pure returns (uint16 minBps, uint16 maxBps, uint16 defaultBps) {
        return
            (ModuleMarketMath.RESERVE_MIN_BPS, ModuleMarketMath.RESERVE_MAX_BPS, ModuleMarketMath.RESERVE_DEFAULT_BPS);
    }

    /// @notice The developer share a publisher can reach on this market (the static bounds narrowed by what the
    ///         frozen protocol and reserve shares leave), and the default a publish pre-fills.
    function developerShareBounds() external view returns (uint16 minBps, uint16 maxBps, uint16 defaultBps) {
        (minBps, maxBps) = ModuleMarketMath.developerRange(protocolBps, reserveBps);
        defaultBps = ModuleMarketMath.defaultSplit(protocolBps, reserveBps).developerBps;
    }

    /// @notice The backers share a publisher can reach on this market, and the default a publish pre-fills.
    function backersShareBounds() external view returns (uint16 minBps, uint16 maxBps, uint16 defaultBps) {
        uint16 rest = uint16(ModuleMarketMath.BPS) - protocolBps - reserveBps;
        (uint16 devMin, uint16 devMax) = ModuleMarketMath.developerRange(protocolBps, reserveBps);
        (minBps, maxBps) = (rest - devMax, rest - devMin);
        defaultBps = ModuleMarketMath.defaultSplit(protocolBps, reserveBps).backersBps;
    }

    /// @notice The split the publish flow pre-fills on this market; `publish` accepts it as is.
    function defaultSplit() external view returns (ModuleMarketTypes.Split memory) {
        return ModuleMarketMath.defaultSplit(protocolBps, reserveBps);
    }

    /// @notice One-time wiring of the vault and the router, both built against this market.
    function wire(IHookrBondVault vault_, IHookrUsageFeeRouter router_) external onlyOwner {
        if (address(vault) != address(0) || address(router) != address(0)) revert AlreadyWired();
        _requireContract(address(vault_));
        _requireContract(address(router_));
        if (vault_.market() != address(this) || router_.market() != address(this)) revert BadWiring();
        vault = vault_;
        router = router_;
        emit Wired(address(vault_), address(router_));
    }

    /// @notice Publishes a module version with its manifest, risk tier and fee split. Only the module's own
    ///         developer can publish it, once. Everything but the lifecycle is frozen from here on.
    /// @param moduleId The module family. A new family's id must start with its publisher's address (see
    ///        `familyId`); the first publisher owns it and alone adds later versions.
    /// @param module The advisory implementation (a HookrMarketModuleBase).
    /// @param tier The declared risk tier; at least PARAMS (`ModuleMarketMath.MIN_TIER`): every phase-one advisory
    ///        can refuse a swap.
    /// @param manifestHash Hash of the full can/cannot manifest document at `manifestURI`.
    /// @param manifest The enforced numeric boundary: caps and phases the admission must stay within.
    /// @param split The fee split, inside the published bounds.
    /// @param manifestURI Where the manifest document is published (at most 256 bytes).
    function publish(
        bytes32 moduleId,
        address module,
        ModuleMarketTypes.RiskTier tier,
        bytes32 manifestHash,
        ModuleMarketTypes.Manifest calldata manifest,
        ModuleMarketTypes.Split calldata split,
        string calldata manifestURI
    ) external returns (uint256 versionId) {
        IHookrUsageFeeRouter r = router;
        if (address(r) == address(0)) revert NotWired();
        _requireContract(module);
        if (versionOf[module] != 0) revert AlreadyListed(module);
        address developer = IHookrMarketModule(module).developer();
        if (developer != msg.sender) revert NotDeveloper(msg.sender, developer);
        if (address(IHookrMarketModule(module).market()) != address(this)) revert WrongMarket(module);
        address expected = r.feeAccountOf(module);
        address named = IHookrMarketModule(module).feeRecipient();
        if (named != expected) revert WrongFeeRecipient(module, named, expected);
        address familyOwner = moduleOwner[moduleId];
        if (familyOwner == address(0)) {
            // A new family's id carries its publisher's address, so nobody can take a family id another developer
            // has announced by publishing it first.
            if (address(bytes20(moduleId)) != msg.sender) revert FamilyNotNamespaced(moduleId, msg.sender);
            moduleOwner[moduleId] = msg.sender;
        } else if (familyOwner != msg.sender) {
            revert NotModuleOwner(moduleId, msg.sender);
        }
        if (moduleId == bytes32(0) || manifestHash == bytes32(0) || bytes(manifestURI).length > MAX_URI_BYTES) {
            revert InvalidManifestRef();
        }
        ModuleMarketMath.checkManifest(manifest);
        ModuleMarketMath.checkSplit(split, protocolBps, reserveBps);
        if (tier < ModuleMarketMath.MIN_TIER) revert TierBelowManifest(tier, ModuleMarketMath.MIN_TIER);

        address feeAccount = r.deployFeeAccount(module);
        versionId = ++versionCount;
        uint32 number = ++latestNumber[moduleId];
        ModuleMarketTypes.Version storage v = _versions[versionId];
        v.module = module;
        v.moduleId = moduleId;
        v.number = number;
        v.tier = tier;
        v.status = ModuleMarketTypes.Status.LISTED;
        v.codeHash = module.codehash;
        v.manifestHash = manifestHash;
        v.manifest = manifest;
        v.split = split;
        v.feeAccount = feeAccount;
        v.publishedAt = uint64(block.timestamp);
        versionOf[module] = versionId;
        emit ModulePublished(
            versionId,
            moduleId,
            module,
            number,
            msg.sender,
            tier,
            v.codeHash,
            manifestHash,
            manifest,
            split,
            feeAccount,
            manifestURI
        );
    }

    /// @notice The id a publisher gives a new module family named `name`: the publisher's address, then the first
    ///         12 bytes of keccak256(name). Only that publisher can open the family; a handover keeps the id.
    function familyId(address publisher, string calldata name) external pure returns (bytes32) {
        return bytes32(abi.encodePacked(publisher, bytes12(keccak256(bytes(name)))));
    }

    /// @notice Starts a two-step handover of a module family (developer payee, exits, new versions).
    function transferModule(bytes32 moduleId, address nominee) external {
        if (moduleOwner[moduleId] != msg.sender) revert NotModuleOwner(moduleId, msg.sender);
        pendingModuleOwner[moduleId] = nominee;
        emit ModuleTransferStarted(moduleId, msg.sender, nominee);
    }

    /// @notice Completes a module family handover. The new owner's band sets the bond from now on.
    function acceptModule(bytes32 moduleId) external {
        if (pendingModuleOwner[moduleId] != msg.sender || msg.sender == address(0)) {
            revert NotModuleOwner(moduleId, msg.sender);
        }
        moduleOwner[moduleId] = msg.sender;
        delete pendingModuleOwner[moduleId];
        emit ModuleTransferred(moduleId, msg.sender);
    }

    /// @notice The $HOOKR the version must have bonded before a pool may install it.
    function requiredBond(uint256 versionId) public view returns (uint256) {
        ModuleMarketTypes.Version storage v = _version(versionId);
        return ModuleMarketMath.requiredBond(v.tier, bandOf[moduleOwner[v.moduleId]], bondUnit);
    }

    /// @notice Whether the bond currently covers the requirement.
    function bondSatisfied(uint256 versionId) public view returns (bool) {
        return vault.totalAssets(versionId) >= requiredBond(versionId);
    }

    /// @notice Whether a new pool could install the version right now (registry admission aside): it is listed,
    ///         installs are open, no slash is pending against it and its bond covers the requirement.
    function installable(uint256 versionId) external view returns (bool) {
        _version(versionId);
        return _installable(versionId);
    }

    /// @inheritdoc IHookrModuleBond
    /// @dev The bond behind a module's registry admission, for any scope (the stake stands behind the version, not one
    ///      root): it covers the admission exactly while a new pool could install the module's version (`installable`:
    ///      listed, installs open, no slash pending, bonded to its floor). With a queued `SET_ADMISSION_BOND` naming
    ///      this market, the root then refuses new pools for a version that is unbonded, paused, exiting, released,
    ///      terminated or under a pending slash, and a root factory copies the admission to an owned root only while it
    ///      is covered. Pools already open never read the admission again. It reads no registry state (the registry
    ///      asks it while reading that admission) and an unknown implementation is not covered.
    function covers(address, address implementation) external view returns (bool) {
        uint256 versionId = versionOf[implementation];
        return versionId != 0 && _installable(versionId);
    }

    /// @inheritdoc IHookrModuleMarket
    /// @dev Also closed while a slash is pending, so nobody can be slashed for conduct that predates their stake.
    function acceptsBond(uint256 versionId) external view returns (bool) {
        ModuleMarketTypes.Version storage v = _versions[versionId];
        return v.status == ModuleMarketTypes.Status.LISTED && v.pendingSlashes == 0;
    }

    /// @inheritdoc IHookrModuleMarket
    function bondReleased(uint256 versionId) external view returns (bool) {
        ModuleMarketTypes.Status s = _versions[versionId].status;
        return s == ModuleMarketTypes.Status.RELEASED || s == ModuleMarketTypes.Status.TERMINATED;
    }

    /// @inheritdoc IHookrModuleMarket
    /// @dev Called from the module's `bind`, inside HookrRoot.initializePool, under the advisory gas limit.
    ///      `bindingPool()` proves the root is binding exactly this key right now, so an install cannot be
    ///      recorded outside a real pool initialization, and the admission read is the one the root enforces.
    ///      A pending slash refuses the install as it refuses new bond: a pool would otherwise
    ///      freeze, for good, a version governance has already published a slash against.
    ///      The pool's Rules is recorded in `usesRules`: the root checked its RULES admission
    ///      before this bind, and the pool credits the version's usage fees there for its whole life.
    function recordInstall(PoolKey calldata key, HookrTypes.PoolConfig calldata config) external {
        uint256 versionId = versionOf[msg.sender];
        if (versionId == 0) revert NotListed(msg.sender);
        ModuleMarketTypes.Version storage v = _versions[versionId];
        if (v.status != ModuleMarketTypes.Status.LISTED) revert InstallsClosed(versionId, v.status);
        if (installsPaused) revert InstallsArePaused();
        if (v.pendingSlashes != 0) revert SlashPending(versionId, v.pendingSlashes);
        uint256 required = requiredBond(versionId);
        uint256 bonded = vault.totalAssets(versionId);
        if (bonded < required) revert BondShort(versionId, bonded, required);

        address root = address(key.hooks);
        PoolId id = key.toId();
        if (
            !registry.isRoot(root) || PoolId.unwrap(IHookrRoot(root).bindingPool()) != PoolId.unwrap(id)
                || config.advisory != msg.sender
        ) revert NotBinding(root, id);
        IHookrRegistry.Admission memory a = registry.admission(root, msg.sender);
        if (
            a.implementation != msg.sender || a.kind != IHookrRegistry.Kind.ADVISORY || a.codeHash != v.codeHash
                || msg.sender.codehash != v.codeHash
        ) revert AdmissionMismatch(root, msg.sender);
        ModuleMarketTypes.Manifest memory m = v.manifest;
        if (
            a.caps.maxLpFeePips > m.maxLpFeeSurchargePips || a.caps.maxQuoteTakePips > m.maxQuoteTakePips
                || a.phaseMask & ~m.phaseMask != 0 || config.advisoryPhases & ~m.phaseMask != 0
        ) revert AdmissionWiderThanManifest(root, msg.sender);
        if (_installs[id].versionId != 0) revert AlreadyInstalled(id);

        address launcher = registry.isLauncher(config.liquidityOwner) ? config.liquidityOwner : address(0);
        _installs[id] = ModuleMarketTypes.Install({
            versionId: uint64(versionId),
            root: root,
            launcher: launcher,
            installedAt: uint64(block.timestamp),
            live: true
        });
        usesRules[versionId][config.rules] = true;
        ++v.liveInstalls;
        ++v.totalInstalls;
        emit ModuleInstalled(id, versionId, root, config.liquidityOwner);
    }

    /// @notice The market's owner (the Launcher family owner) declares the pool migrated off the module.
    /// @dev The pool keeps running the frozen module; this only ends the bond's exposure to it. A market
    ///      without a registered-launcher owner can only be closed by `pokeDrained` or the drain window.
    function closeInstall(PoolId id) external {
        ModuleMarketTypes.Install storage ins = _installs[id];
        if (!ins.live) revert NotLive(id);
        address launcher = ins.launcher;
        if (launcher == address(0)) revert NoMarketOwner(id);
        address marketOwner = HookrLauncher(launcher).familyOwner(HookrLauncher(launcher).poolFamily(id));
        if (marketOwner == address(0)) revert NoMarketOwner(id);
        if (msg.sender != marketOwner) revert Unauthorized(msg.sender);
        _close(id, ins, ModuleMarketTypes.CloseReason.OWNER);
    }

    /// @notice Anyone may close an install whose pool has no in-range liquidity and whose launch position is empty.
    /// @dev Out-of-range positions held by third parties are not visible here; dust kept in range only delays
    ///      the close until the drain window, which ends exposure regardless.
    function pokeDrained(PoolId id) external {
        ModuleMarketTypes.Install storage ins = _installs[id];
        if (!ins.live) revert NotLive(id);
        if (poolManager.getLiquidity(id) != 0) revert NotDrained(id);
        address launcher = ins.launcher;
        if (launcher != address(0)) {
            bytes32 family = HookrLauncher(launcher).poolFamily(id);
            uint8 n = HookrLauncher(launcher).memberCount(family);
            for (uint8 i; i < n; ++i) {
                IHookrLauncher.Position memory p = HookrLauncher(launcher).position(family, i);
                if (PoolId.unwrap(p.key.toId()) == PoolId.unwrap(id) && p.liquidity != 0) revert NotDrained(id);
            }
        }
        _close(id, ins, ModuleMarketTypes.CloseReason.DRAINED);
    }

    /// @notice Gives notice. From now on no pool can install this version; existing pools are untouched.
    function requestExit(uint256 versionId) external {
        ModuleMarketTypes.Version storage v = _version(versionId);
        if (moduleOwner[v.moduleId] != msg.sender) revert NotModuleOwner(v.moduleId, msg.sender);
        _startExit(versionId, v);
    }

    /// @notice Executes a queued FORCE_EXIT: gives notice for a version on its owner's behalf, exactly as
    ///         `requestExit` would. The notice, drain window, cooldown and pending-slash rules all still apply.
    /// @dev Without it only the module owner could start an exit, so a lost or unwilling owner would lock every
    ///      backer's stake for ever. A backer cannot start one (anyone could stake one $HOOKR and
    ///      delist a module); governance can, only through this published, delayed operation.
    function forceExit(uint256 versionId, bytes32 evidence) external onlyOwner {
        ModuleMarketTypes.Version storage v = _version(versionId);
        _consume(FORCE_EXIT, abi.encode(versionId, evidence));
        _startExit(versionId, v);
        emit ExitForced(versionId, evidence);
    }

    /// @notice When the version's exposure ended, or zero while it has not.
    /// @dev max(notice end, last install closed), capped at the drain window; with installs still live, the
    ///      drain window's end once it has passed. Monotonic: it never moves later once non-zero.
    function exposureEndedAt(uint256 versionId) public view returns (uint256) {
        ModuleMarketTypes.Version storage v = _version(versionId);
        if (v.status != ModuleMarketTypes.Status.EXITING && v.status != ModuleMarketTypes.Status.RELEASED) return 0;
        uint256 cap = uint256(v.exitRequestedAt) + MAX_DRAIN;
        if (v.liveInstalls == 0) {
            uint256 end = uint256(v.exitRequestedAt) + EXIT_NOTICE;
            if (v.drainedAt > end) end = v.drainedAt;
            return end < cap ? end : cap;
        }
        return block.timestamp >= cap ? cap : 0;
    }

    /// @notice When the bond can be released (exposure end plus the cooldown), or zero while exposure lasts.
    function releaseAt(uint256 versionId) public view returns (uint256) {
        uint256 ended = exposureEndedAt(versionId);
        return ended == 0 ? 0 : ended + COOLDOWN;
    }

    /// @notice Releases the version's bond for withdrawal. Anyone may call once the cooldown has passed and no
    ///         slash is pending.
    function release(uint256 versionId) external {
        ModuleMarketTypes.Version storage v = _version(versionId);
        if (v.status != ModuleMarketTypes.Status.EXITING) revert WrongStatus(versionId, v.status);
        uint256 readyAt_ = releaseAt(versionId);
        if (readyAt_ == 0 || block.timestamp < readyAt_) revert NotReleasable(versionId, readyAt_);
        if (v.pendingSlashes != 0) revert SlashPending(versionId, v.pendingSlashes);
        v.status = ModuleMarketTypes.Status.RELEASED;
        emit VersionReleased(versionId);
    }

    /// @notice Publishes a slash on one of the listed grounds. Executable after the governance delay.
    /// @dev The reason enum has no member for market outcomes (price, liquidations, popularity, fee flow).
    function proposeSlash(
        uint256 versionId,
        uint16 bps,
        ModuleMarketTypes.SlashReason reason,
        address recipient,
        bytes32 evidenceHash
    ) external onlyOwner returns (uint256 slashId) {
        ModuleMarketTypes.Version storage v = _version(versionId);
        if (v.status != ModuleMarketTypes.Status.LISTED && v.status != ModuleMarketTypes.Status.EXITING) {
            revert WrongStatus(versionId, v.status);
        }
        if (
            bps == 0 || bps > FULL_SLASH_BPS || recipient == address(0) || recipient == address(vault)
                || evidenceHash == bytes32(0)
        ) revert InvalidSlash();
        slashId = ++slashCount;
        uint48 readyAt = uint48(block.timestamp) + delay;
        _slashes[slashId] = ModuleMarketTypes.SlashProposal({
            versionId: uint64(versionId),
            bps: bps,
            reason: reason,
            status: ModuleMarketTypes.SlashStatus.PENDING,
            readyAt: readyAt,
            recipient: recipient,
            evidenceHash: evidenceHash
        });
        ++v.pendingSlashes;
        emit SlashProposed(slashId, versionId, bps, reason, recipient, evidenceHash, readyAt);
    }

    /// @notice Vetoes a pending slash. Owner or guardian; immediate, since it only removes a power.
    function vetoSlash(uint256 slashId) external {
        if (msg.sender != owner() && (msg.sender != guardian || guardian == address(0))) {
            revert Unauthorized(msg.sender);
        }
        ModuleMarketTypes.SlashProposal storage p = _pendingSlash(slashId);
        p.status = ModuleMarketTypes.SlashStatus.VETOED;
        --_versions[p.versionId].pendingSlashes;
        emit SlashVetoed(slashId, msg.sender);
    }

    /// @notice Executes a matured slash: takes `bps` of the version's bond pro rata from developer and backers.
    function executeSlash(uint256 slashId) external onlyOwner returns (uint256 amount) {
        ModuleMarketTypes.SlashProposal storage p = _pendingSlash(slashId);
        if (block.timestamp < p.readyAt) revert SlashNotReady(slashId, p.readyAt);
        uint256 expiresAt = uint256(p.readyAt) + GRACE;
        if (block.timestamp > expiresAt) revert SlashExpired(slashId, expiresAt);
        p.status = ModuleMarketTypes.SlashStatus.EXECUTED;
        ModuleMarketTypes.Version storage v = _versions[p.versionId];
        --v.pendingSlashes;
        amount = vault.slash(p.versionId, p.bps, p.recipient);
        if (p.bps == FULL_SLASH_BPS) {
            v.status = ModuleMarketTypes.Status.TERMINATED;
            emit VersionTerminated(p.versionId);
        }
        emit SlashExecuted(slashId, p.versionId, amount);
    }

    /// @notice Anyone may lapse a slash nobody executed within its window, unblocking the release.
    function expireSlash(uint256 slashId) external {
        ModuleMarketTypes.SlashProposal storage p = _pendingSlash(slashId);
        uint256 expiresAt = uint256(p.readyAt) + GRACE;
        if (block.timestamp <= expiresAt) revert SlashNotExpired(slashId, expiresAt);
        p.status = ModuleMarketTypes.SlashStatus.EXPIRED;
        --_versions[p.versionId].pendingSlashes;
        emit SlashLapsed(slashId);
    }

    /// @notice Executes a queued SET_BAND. A better band lowers the bond future installs need.
    function setBand(address publisher, ModuleMarketTypes.Band band) external onlyOwner {
        _consume(SET_BAND, abi.encode(publisher, band));
        bandOf[publisher] = band;
        emit BandSet(publisher, band);
    }

    /// @notice Executes a queued SET_GUARDIAN.
    function setGuardian(address next) external onlyOwner {
        _consume(SET_GUARDIAN, abi.encode(next));
        guardian = next;
        emit GuardianSet(next);
    }

    /// @notice Executes a queued SET_PROTOCOL_RECIPIENT. The router books the protocol share to the protocol, not to
    ///         an address, and pays all of it to whoever is the recipient at payment time, so `next` is paid every
    ///         unpaid share, fees collected before the change included.
    function setProtocolRecipient(address next) external onlyOwner {
        if (next == address(0)) revert InvalidAddress(next);
        _consume(SET_PROTOCOL_RECIPIENT, abi.encode(next));
        protocolRecipient = next;
        emit ProtocolRecipientSet(next);
    }

    /// @notice Executes a queued DRAW_RESERVE: pays part of ONE version's reserve (first loss for that
    ///         version's markets). No path draws one version's reserve for another.
    function drawReserve(uint256 versionId, Currency currency, address to, uint256 amount, bytes32 evidence)
        external
        onlyOwner
    {
        _version(versionId);
        _consume(DRAW_RESERVE, abi.encode(versionId, currency, to, amount, evidence));
        router.drawReserve(versionId, currency, to, amount);
        emit ReserveDrawn(versionId, currency, to, amount, evidence);
    }

    /// @notice Stops new installs of every version at once. Existing pools, bonds, fees and exits are untouched.
    /// @dev Voids every RESUME_INSTALLS queued so far, so lifting this pause always waits a full delay from the
    ///      pause itself, as HookrPaymaster.pause voids UNPAUSE.
    function pauseInstalls() external {
        if (msg.sender != owner() && (msg.sender != guardian || guardian == address(0))) {
            revert Unauthorized(msg.sender);
        }
        installsPaused = true;
        _invalidateQueued(RESUME_INSTALLS);
        emit InstallsPaused(msg.sender);
    }

    /// @notice Executes a queued RESUME_INSTALLS.
    function resumeInstalls() external onlyOwner {
        if (!installsPaused) revert NotPaused();
        _consume(RESUME_INSTALLS, "");
        installsPaused = false;
        emit InstallsResumed();
    }

    /// @inheritdoc IHookrModuleMarket
    function getVersion(uint256 versionId) external view returns (ModuleMarketTypes.Version memory) {
        return _version(versionId);
    }

    /// @inheritdoc IHookrModuleMarket
    function payee(uint256 versionId) external view returns (address) {
        return moduleOwner[_version(versionId).moduleId];
    }

    /// @notice The install record of a pool (zero version if the pool never installed a marketplace module).
    function getInstall(PoolId id) external view returns (ModuleMarketTypes.Install memory) {
        return _installs[id];
    }

    /// @notice Whether a live install still has the version's bond standing behind it: the install is live
    ///         and the bond has been neither released nor slashed away. The bond may be below the tier floor
    ///         after a partial slash; `bondSatisfied` says whether it is.
    function installBonded(PoolId id) external view returns (bool) {
        ModuleMarketTypes.Install storage ins = _installs[id];
        if (!ins.live) return false;
        ModuleMarketTypes.Status s = _versions[ins.versionId].status;
        return s == ModuleMarketTypes.Status.LISTED || s == ModuleMarketTypes.Status.EXITING;
    }

    /// @notice A slash proposal.
    function getSlash(uint256 slashId) external view returns (ModuleMarketTypes.SlashProposal memory) {
        return _slashes[slashId];
    }

    function _startExit(uint256 versionId, ModuleMarketTypes.Version storage v) private {
        if (v.status != ModuleMarketTypes.Status.LISTED) revert WrongStatus(versionId, v.status);
        v.status = ModuleMarketTypes.Status.EXITING;
        v.exitRequestedAt = uint64(block.timestamp);
        if (v.liveInstalls == 0) v.drainedAt = uint64(block.timestamp);
        emit ExitRequested(versionId, uint64(block.timestamp), v.liveInstalls);
    }

    function _close(PoolId id, ModuleMarketTypes.Install storage ins, ModuleMarketTypes.CloseReason reason) private {
        ins.live = false;
        ModuleMarketTypes.Version storage v = _versions[ins.versionId];
        --v.liveInstalls;
        if (v.liveInstalls == 0 && v.status == ModuleMarketTypes.Status.EXITING) v.drainedAt = uint64(block.timestamp);
        emit InstallClosed(id, ins.versionId, reason);
    }

    /// @dev `installable` for a published version.
    function _installable(uint256 versionId) private view returns (bool) {
        ModuleMarketTypes.Version storage v = _versions[versionId];
        return v.status == ModuleMarketTypes.Status.LISTED && !installsPaused && v.pendingSlashes == 0
            && bondSatisfied(versionId);
    }

    function _version(uint256 versionId) private view returns (ModuleMarketTypes.Version storage v) {
        v = _versions[versionId];
        if (v.module == address(0)) revert UnknownVersion(versionId);
    }

    function _pendingSlash(uint256 slashId) private view returns (ModuleMarketTypes.SlashProposal storage p) {
        p = _slashes[slashId];
        if (p.status == ModuleMarketTypes.SlashStatus.NONE) revert UnknownSlash(slashId);
        if (p.status != ModuleMarketTypes.SlashStatus.PENDING) revert SlashNotPending(slashId);
    }

    /// @dev Refuses EOAs and EIP-7702 delegated accounts (0xef0100 prefix), as HookrRegistry does.
    function _requireContract(address account) private view {
        _requireDeployedCode(account);
    }
}
