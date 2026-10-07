// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHookrRegistry, IHookrFactoryRegistry} from "../interfaces/IHookrRegistry.sol";
import {IHookrRoot} from "../interfaces/IHookrRoot.sol";
import {IHookrLanes} from "../interfaces/IHookrLanes.sol";
import {IHookrAdmissions} from "../interfaces/IHookrAdmissions.sol";
import {IHookrExternalHooks} from "../interfaces/IHookrExternalHooks.sol";
import {IHookrOwnedRoots} from "../interfaces/IHookrOwnedRoots.sol";
import {IHookrRootRegistrar} from "../interfaces/IHookrRootRegistrar.sol";
import {HookrReleased} from "../base/HookrReleased.sol";
import {HookrRegistryStorage} from "../libraries/HookrRegistryStorage.sol";
import {HookrRegistryChecks} from "../libraries/HookrRegistryChecks.sol";
import {HookrRegistryAdmin} from "../libraries/HookrRegistryAdmin.sol";

/// @title HookrRegistry
/// @notice New-pool authority. Retirement never changes an existing pool's frozen configuration.
/// @dev Every permissive change is a queued operation whose kind and ABI arguments are published in
///      `OperationQueued`, checked against deployed code when queued, executable only between `readyAt`
///      and `readyAt + GRACE_PERIOD`, and consumed once. The only untimelocked powers restrict new
///      activity: `dropWholeQuoteClass`, `dismissAnyQuoteNow` and `brakeOneQuoteInstantly` (owner or guardian) withdraw
///      a quote class, any-quote mode or one asset from new pools, and only a `SET_QUOTE_CLASS`, `ANY_QUOTE`, or
///      `REOPEN_QUOTE` or `SET_QUOTE` queued after them lifts them;
///      `freezeRoot` seals admissions and lane openings; `pauseNewMarkets`, `closeRoot`, `deactivateLauncher`
///      and `deactivateRootFactory` (owner or guardian) stop new pool initialisation, launches or root
///      registrations; `revokeFactoryAdmissions` (owner or guardian) permanently withdraws a root factory's
///      admissions of pair advisories, and `revokeModuleAdmission` (owner or guardian, the owner alone on a frozen
///      root) one module admission for a root, a root factory or a part scope; `closeLaneOf` (owner or guardian)
///      closes a root's recapture lane, so the root's new pools open without one; `stopExecutorLane` and
///      `tuneExecutorLane` (owner or guardian) switch a lane executor off, or lower its gas, on every pool of the root
///      that froze it; `removeSettlementCurrency` (owner or guardian) takes a currency out of the recapture settlement
///      set; `dropSingleExternalHookRecordNow` (owner or guardian) withdraws an external-hook record; `cancel` (owner
///      or guardian) withdraws a queued operation, which the owner can queue again;
///      `cancelOwnershipTransfer` withdraws a nomination; `removeGuardian` withdraws the guardian's brake powers.
///      None of them can reach liquidity exits, claims or any user, LP or protocol balance, and the lane brakes reach
///      swaps only by skipping or shrinking an arb recapture. A revoke blocks new binds only and never silently
///      disables a live pool: an admission is read only when a pool binds, and a pool already open never reads it
///      again. A revoked admission is never lifted: a replacement is a new deployment admitted through the timelock.
///      A queued `SET_ADMISSION_BOND` attaches an IHookrModuleBond to a live admission for good, and the admission then
///      reads as empty whenever the bond stops covering it, which, like a revoke, refuses new binds only.
///      Each other brake is lifted only by a queued operation that can be queued and executed only while the brake
///      holds (a lane: only by an opening or a switch-on queued after the brake), so a brake holds for at least one
///      full delay. An active root factory registers the roots it deploys while new markets are not paused: pair roots
///      through `registerFactoryRoot`, and owned roots through `registerOwnedRoot`, frozen with their admissions and
///      their template's lane copied with its switch off (IHookrOwnedRoots); the factory itself is pinned by runtime
///      codehash through the timelock. An owned root's lane is the one exception to its freeze: a timelocked `OPEN_LANE`
///      or `LANE_ON` queued after its registration starts arb recapture there. The queue-time and execution-time checks
///      run in the linked library HookrRegistryChecks, and the timelock step that consumes a matured operation, the cold
///      timelocked writes (module admissions, admission bonds, lane openings, external-hook records) and owned-root
///      registration in the linked library HookrRegistryAdmin, both reached by DELEGATECALL; the state lives in the
///      ERC-7201 namespaces of HookrRegistryStorage.
contract HookrRegistry is
    HookrReleased,
    IHookrRegistry,
    IHookrLanes,
    IHookrAdmissions,
    IHookrExternalHooks,
    IHookrOwnedRoots
{
    bytes32 public constant SET_LAUNCHER = HookrRegistryChecks.SET_LAUNCHER;
    bytes32 public constant REGISTER_ROOT = HookrRegistryChecks.REGISTER_ROOT;
    bytes32 public constant RETIRE_ROOT = HookrRegistryChecks.RETIRE_ROOT;
    bytes32 public constant ADMIT = HookrRegistryChecks.ADMIT;
    bytes32 public constant TRANSFER_OWNER = HookrRegistryChecks.TRANSFER_OWNER;
    bytes32 public constant SET_GUARDIAN = HookrRegistryChecks.SET_GUARDIAN;
    bytes32 public constant SET_QUOTE = HookrRegistryChecks.SET_QUOTE;
    bytes32 public constant RESUME_NEW_MARKETS = HookrRegistryChecks.RESUME_NEW_MARKETS;
    bytes32 public constant REOPEN_ROOT = HookrRegistryChecks.REOPEN_ROOT;
    bytes32 public constant SET_ROOT_FACTORY = HookrRegistryChecks.SET_ROOT_FACTORY;
    /// @notice Lowest Rules gas limit an admission accepts. Every Rules call on a swap runs under this admitted limit.
    uint32 public constant RULES_MIN_GAS_LIMIT = HookrRegistryChecks.RULES_MIN_GAS_LIMIT;
    uint48 public constant MIN_DELAY = 30 minutes;
    uint48 public constant MAX_DELAY = 30 days;
    /// @notice A matured operation expires this long after `readyAt`; it must then be queued again.
    uint48 public constant GRACE_PERIOD = HookrRegistryAdmin.GRACE_PERIOD;
    /// @dev The kind of a queued switch-on of a lane executor on a root, at a gas cap: `keccak256("LANE_ON")`. Private:
    ///      a public getter would sort ahead of `isQuote`, `rootOpen`, `isLauncher` and `registerFactoryRoot` in the
    ///      dispatcher and cost every launch.
    bytes32 private constant LANE_ON = HookrRegistryChecks.LANE_ON;
    /// @dev The kind of a queued addition to the recapture settlement set, arguments `abi.encode(address currency)`:
    ///      `keccak256("ADD_SETTLEMENT")`. Private for the reason LANE_ON is.
    bytes32 private constant ADD_SETTLEMENT = HookrRegistryChecks.ADD_SETTLEMENT;
    /// @dev The settlement set's genesis members besides native ETH: WETH and USDG on Robinhood Chain (4663), seeded
    ///      when they hold code.
    address private constant GENESIS_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address private constant GENESIS_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    /// @dev An ERC-20's `totalSupply()`: a quote class member must report a nonzero supply.
    bytes4 private constant TOTAL_SUPPLY_SELECTOR = bytes4(keccak256("totalSupply()"));
    /// @dev The kinds of a queued quote class admission, arguments `abi.encode(bytes32 codeHash, address witness)`, of
    ///      a queued switch-on of any-quote mode, no arguments, and of a queued lift of one asset's quote brake,
    ///      `abi.encode(address asset)`. Private for the reason LANE_ON is.
    bytes32 private constant SET_QUOTE_CLASS = HookrRegistryChecks.SET_QUOTE_CLASS;
    bytes32 private constant ANY_QUOTE = HookrRegistryChecks.ANY_QUOTE;
    bytes32 private constant REOPEN_QUOTE = HookrRegistryChecks.REOPEN_QUOTE;
    /// @inheritdoc IHookrRegistry
    IPoolManager public immutable poolManager;
    /// @inheritdoc IHookrRegistry
    uint48 public immutable delay;

    constructor(address _owner, IPoolManager _manager, uint48 _delay) {
        if (_owner == address(0) || address(_manager).code.length == 0) revert InvalidAddress();
        HookrRegistryChecks.requireUndelegated(_owner);
        if (_delay < MIN_DELAY || _delay > MAX_DELAY) revert InvalidDelay();
        poolManager = _manager;
        delay = _delay;
        HookrRegistryStorage.state().owner = _owner;
        _addSettlement(address(0));
        if (GENESIS_WETH.code.length != 0) _addSettlement(GENESIS_WETH);
        if (GENESIS_USDG.code.length != 0) _addSettlement(GENESIS_USDG);
    }

    modifier onlyOwner() {
        if (msg.sender != HookrRegistryStorage.state().owner) revert Unauthorized();
        _;
    }

    modifier onlyBrake() {
        HookrRegistryStorage.State storage s = HookrRegistryStorage.state();
        if (msg.sender != s.owner && msg.sender != s.guardian) revert Unauthorized();
        _;
    }

    /// @inheritdoc IHookrRegistry
    function owner() external view returns (address) {
        return HookrRegistryStorage.state().owner;
    }

    /// @inheritdoc IHookrRegistry
    function pendingOwner() external view returns (address) {
        return HookrRegistryStorage.state().pendingOwner;
    }

    /// @inheritdoc IHookrRegistry
    function guardian() external view returns (address) {
        return HookrRegistryStorage.state().guardian;
    }

    /// @inheritdoc IHookrRegistry
    function newMarketsPaused() external view returns (bool) {
        return HookrRegistryStorage.state().newMarketsPaused;
    }

    /// @inheritdoc IHookrRegistry
    function readyAt(bytes32 operation) external view returns (uint48) {
        return HookrRegistryStorage.state().readyAt[operation];
    }

    /// @inheritdoc IHookrRegistry
    function expiresAt(bytes32 operation) external view returns (uint48) {
        uint48 eta = HookrRegistryStorage.state().readyAt[operation];
        return eta == 0 ? 0 : eta + GRACE_PERIOD;
    }

    /// @inheritdoc IHookrRegistry
    function isLauncher(address account) external view returns (bool) {
        return HookrRegistryStorage.state().launchers[account];
    }

    /// @inheritdoc IHookrRegistry
    function isRoot(address root) external view returns (bool) {
        return HookrRegistryStorage.state().roots[root].registered;
    }

    /// @inheritdoc IHookrRegistry
    function rootOpen(address root) external view returns (bool) {
        HookrRegistryStorage.State storage s = HookrRegistryStorage.state();
        HookrRegistryStorage.RootState storage r = s.roots[root];
        return r.active && !r.closed && !s.newMarketsPaused;
    }

    /// @inheritdoc IHookrRegistry
    function rootClosed(address root) external view returns (bool) {
        return HookrRegistryStorage.state().roots[root].closed;
    }

    /// @inheritdoc IHookrRegistry
    function rootReopenable(address root) external view returns (bool) {
        HookrRegistryStorage.RootState storage r = HookrRegistryStorage.state().roots[root];
        return r.closed && r.active;
    }

    /// @inheritdoc IHookrFactoryRegistry
    function isRootFactory(address factory) external view returns (bool) {
        return HookrRegistryStorage.state().rootFactories[factory] != bytes32(0);
    }

    /// @inheritdoc IHookrRegistry
    function rootFactoryOf(address root) external view returns (address) {
        return HookrRegistryStorage.state().roots[root].factory;
    }

    /// @inheritdoc IHookrRegistry
    function rootFactoryCodeHash(address factory) external view returns (bytes32) {
        return HookrRegistryStorage.state().rootFactories[factory];
    }

    /// @inheritdoc IHookrRegistry
    function rootFrozen(address root) external view returns (bool) {
        return HookrRegistryStorage.state().roots[root].frozen;
    }

    /// @inheritdoc IHookrRegistry
    function admission(address root, address implementation) external view returns (Admission memory) {
        Admission memory a = HookrRegistryStorage.state().admissions[root][implementation];
        if (!HookrRegistryChecks.bondCovers(root, implementation)) delete a;
        return a;
    }

    /// @inheritdoc IHookrAdmissions
    function pinModuleBondFor(address scope, address implementation, address bondRef) external onlyOwner {
        HookrRegistryAdmin.pinModuleBondFor(scope, implementation, bondRef, delay);
    }

    /// @inheritdoc IHookrAdmissions
    function findBondForAdmission(address scope, address implementation)
        external
        view
        returns (address bondRef, bool covering)
    {
        bondRef = HookrRegistryStorage.bonds().bondOf[scope][implementation];
        covering = bondRef != address(0)
            && HookrRegistryStorage.state().admissions[scope][implementation].implementation != address(0)
            && HookrRegistryChecks.covers(bondRef, scope, implementation);
    }

    /// @inheritdoc IHookrRegistry
    function isRevokedAdmission(address scope, address implementation) external view returns (bool) {
        return HookrRegistryStorage.state().revoked[scope][implementation];
    }

    /// @inheritdoc IHookrAdmissions
    function partScopeEligible(address module) external view returns (bool eligible, address root) {
        root = HookrRegistryChecks.partScopeRoot(module);
        eligible = root != address(0) && !HookrRegistryStorage.state().roots[root].frozen;
    }

    /// @inheritdoc IHookrLanes
    function activeLaneOf(address root)
        external
        view
        returns (address executor, bytes32 codeHash, uint32 gasCap, uint16 partnerBps)
    {
        HookrRegistryStorage.State storage s = HookrRegistryStorage.state();
        HookrRegistryStorage.Lane storage l = s.lanes[root];
        executor = l.executor;
        codeHash = l.codeHash;
        HookrRegistryStorage.LaneSwitch storage w = s.laneSwitches[root][executor];
        if (executor == address(0) || executor.codehash != codeHash || !w.on) return (address(0), bytes32(0), 0, 0);
        (gasCap, partnerBps) = (w.gasCap, l.partnerBps);
    }

    /// @inheritdoc IHookrLanes
    function executorLane(address root, address executor) external view returns (bool on, uint32 gasCap) {
        HookrRegistryStorage.LaneSwitch storage w = HookrRegistryStorage.state().laneSwitches[root][executor];
        return (w.on, w.gasCap);
    }

    /// @inheritdoc IHookrLanes
    function settlementCurrencies() external view returns (address[] memory) {
        return HookrRegistryStorage.settlement().currencies;
    }

    /// @inheritdoc IHookrLanes
    function isSettlementCurrency(address currency) external view returns (bool) {
        return HookrRegistryStorage.settlement().position[currency] != 0;
    }

    /// @inheritdoc IHookrRegistry
    function isQuote(address asset) external view returns (bool) {
        // Native ETH and catalog assets answer first and read nothing more, as before the quote classes, returning
        // straight from assembly so the launch path costs no more than it did. A braked asset is never in the
        // catalog: the brake removes it.
        mapping(address => uint256) storage positions = HookrRegistryStorage.state().quotePosition;
        assembly ("memory-safe") {
            if iszero(asset) {
                mstore(0, 1)
                return(0, 0x20)
            }
            mstore(0, asset)
            mstore(0x20, positions.slot)
            if sload(keccak256(0, 0x40)) {
                mstore(0, 1)
                return(0, 0x20)
            }
        }
        return _openQuote(asset);
    }

    /// @inheritdoc IHookrRegistry
    function quoteAssets() external view returns (address[] memory) {
        return HookrRegistryStorage.state().quotes;
    }

    /// @inheritdoc IHookrRegistry
    function badgeForQuote(address asset) external view returns (QuoteBadge) {
        if (asset == address(0)) return QuoteBadge.NATIVE;
        if (HookrRegistryStorage.state().quotePosition[asset] != 0) return QuoteBadge.CATALOG;
        HookrRegistryStorage.QuoteState storage q = HookrRegistryStorage.quoteState();
        if (q.brakes[asset].braked) return QuoteBadge.NONE;
        if (_classMember(q, asset)) return QuoteBadge.CLASS;
        return q.anyQuote && HookrRegistryChecks.holdsOwnCode(asset) ? QuoteBadge.UNREVIEWED : QuoteBadge.NONE;
    }

    /// @inheritdoc IHookrRegistry
    function openQuoteTerms()
        external
        view
        returns (bool anyQuote, uint48 anyQuoteStoppedAt, bytes32[] memory classes)
    {
        HookrRegistryStorage.QuoteState storage q = HookrRegistryStorage.quoteState();
        return (q.anyQuote, q.anyQuoteStoppedAt, q.classes);
    }

    /// @inheritdoc IHookrRegistry
    function quoteIsBraked(address asset) external view returns (bool braked, uint48 lastBrakeAt) {
        HookrRegistryStorage.QuoteBrake storage b = HookrRegistryStorage.quoteState().brakes[asset];
        return (b.braked, b.lastBrakeAt);
    }

    /// @inheritdoc IHookrRegistry
    function operationHash(bytes32 kind, bytes memory arguments) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), kind, arguments));
    }

    /// @inheritdoc IHookrRegistry
    function queue(bytes32 kind, bytes calldata arguments) external onlyOwner returns (bytes32 operation) {
        HookrRegistryChecks.checkQueued(kind, arguments, address(poolManager));
        operation = operationHash(kind, arguments);
        HookrRegistryStorage.State storage s = HookrRegistryStorage.state();
        uint48 eta = s.readyAt[operation];
        if (eta != 0 && block.timestamp <= uint256(eta) + GRACE_PERIOD) revert AlreadyQueued(operation);
        eta = uint48(block.timestamp) + delay;
        s.readyAt[operation] = eta;
        emit OperationQueued(operation, kind, arguments, eta, eta + GRACE_PERIOD);
    }

    /// @inheritdoc IHookrRegistry
    function cancel(bytes32 operation) external onlyBrake {
        HookrRegistryStorage.State storage s = HookrRegistryStorage.state();
        if (s.readyAt[operation] == 0) revert NotQueued(operation);
        delete s.readyAt[operation];
        emit OperationCancelled(operation);
    }

    /// @inheritdoc IHookrRegistry
    function setLauncher(address launcher, bool active) external onlyOwner {
        if (active) HookrRegistryChecks.checkAdmitLauncher(launcher);
        _consume(SET_LAUNCHER, abi.encode(launcher, active));
        HookrRegistryStorage.state().launchers[launcher] = active;
        emit LauncherSet(launcher, active);
    }

    /// @inheritdoc IHookrRegistry
    function registerRoot(address root, bytes32 codeHash) external onlyOwner {
        HookrRegistryChecks.checkRoot(root, codeHash, address(poolManager));
        _consume(REGISTER_ROOT, abi.encode(root, codeHash));
        HookrRegistryStorage.state().roots[root] = HookrRegistryStorage.RootState(true, true, false, false, address(0));
        emit RootRegistered(root);
    }

    /// @inheritdoc IHookrRegistry
    function rootStatus(address root) external view returns (address advisory, bool verified) {
        HookrRegistryStorage.State storage s = HookrRegistryStorage.state();
        HookrRegistryStorage.RootState storage r = s.roots[root];
        if (!r.registered) return (address(0), false);
        advisory = s.rootAdvisories[root];
        if (advisory == address(0)) return (address(0), true);
        Admission storage a = s.admissions[r.factory][advisory];
        verified = a.implementation == advisory && advisory.codehash == a.codeHash
            && HookrRegistryChecks.bondCovers(r.factory, advisory);
    }

    /// @inheritdoc IHookrOwnedRoots
    function registerOwnedRoot(
        address root,
        address template,
        address templateRules,
        Admission calldata rules,
        address[] calldata copies
    ) external {
        HookrRegistryAdmin.registerOwnedRoot(root, template, templateRules, rules, copies, address(poolManager));
    }

    /// @inheritdoc IHookrOwnedRoots
    function rootOpenFor(address root, address opener) external view returns (bool) {
        HookrRegistryStorage.State storage s = HookrRegistryStorage.state();
        HookrRegistryStorage.RootState storage r = s.roots[root];
        if (!r.active || r.closed || s.newMarketsPaused) return false;
        address factory = HookrRegistryStorage.owned().roots[root].factory;
        return factory == address(0)
            || HookrRegistryChecks.answersTrue(factory, IHookrRootRegistrar.mayOpen.selector, root, opener);
    }

    /// @inheritdoc IHookrOwnedRoots
    function isOwnedRoot(address root) external view returns (bool) {
        return HookrRegistryStorage.owned().roots[root].factory != address(0);
    }

    /// @inheritdoc IHookrOwnedRoots
    function ownedRootTemplate(address root) external view returns (address) {
        return HookrRegistryStorage.owned().roots[root].template;
    }

    /// @inheritdoc IHookrOwnedRoots
    function ownedRegistrarForRoot(address root) external view returns (address) {
        return HookrRegistryStorage.owned().roots[root].factory;
    }

    /// @inheritdoc IHookrFactoryRegistry
    function registerFactoryRoot(address root, address advisory) external {
        HookrRegistryStorage.State storage s = HookrRegistryStorage.state();
        bytes32 pinned = s.rootFactories[msg.sender];
        if (pinned == bytes32(0) || msg.sender.codehash != pinned) revert Unauthorized();
        if (s.newMarketsPaused) revert MarketsPaused();
        HookrRegistryChecks.requireContract(root);
        if (
            s.roots[root].registered
                || !HookrRegistryChecks.reports(root, IHookrRoot.registry.selector, uint160(address(this)))
        ) {
            revert InvalidRoot();
        }
        s.roots[root] = HookrRegistryStorage.RootState(true, true, false, false, msg.sender);
        if (advisory != address(0)) s.rootAdvisories[root] = advisory;
        emit RootRegistered(root);
        emit FactoryRootRegistered(msg.sender, root);
    }

    /// @inheritdoc IHookrRegistry
    function setRootFactory(address factory, bytes32 codeHash, bool active) external onlyOwner {
        HookrRegistryChecks.checkRootFactory(factory, codeHash, active);
        _consume(SET_ROOT_FACTORY, abi.encode(factory, codeHash, active));
        HookrRegistryStorage.state().rootFactories[factory] = active ? codeHash : bytes32(0);
        emit RootFactorySet(factory, codeHash, active);
    }

    /// @inheritdoc IHookrRegistry
    function deactivateRootFactory(address factory) external onlyBrake {
        HookrRegistryStorage.State storage s = HookrRegistryStorage.state();
        bytes32 pinned = s.rootFactories[factory];
        if (pinned != bytes32(0)) {
            delete s.rootFactories[factory];
            emit RootFactorySet(factory, pinned, false);
        }
    }

    /// @inheritdoc IHookrRegistry
    function deactivateLauncher(address launcher) external onlyBrake {
        HookrRegistryStorage.State storage s = HookrRegistryStorage.state();
        if (s.launchers[launcher]) {
            s.launchers[launcher] = false;
            emit LauncherSet(launcher, false);
            emit LauncherDeactivated(launcher, msg.sender);
        }
    }

    /// @inheritdoc IHookrRegistry
    function closeRoot(address root) external onlyBrake {
        HookrRegistryStorage.RootState storage r = HookrRegistryStorage.state().roots[root];
        if (!r.registered) revert InvalidRoot();
        if (!r.closed) {
            r.closed = true;
            emit RootClosed(root, msg.sender);
        }
    }

    /// @inheritdoc IHookrRegistry
    function reopenRoot(address root) external onlyOwner {
        HookrRegistryChecks.checkReopen(root);
        _consume(REOPEN_ROOT, abi.encode(root));
        HookrRegistryStorage.state().roots[root].closed = false;
        emit RootReopened(root);
    }

    /// @inheritdoc IHookrRegistry
    function openLaneOf(address root, address executor, bytes32 codeHash, uint32 gasCap, uint16 partnerBps)
        external
        onlyOwner
    {
        HookrRegistryAdmin.openLaneOf(root, executor, codeHash, gasCap, partnerBps, delay);
    }

    /// @inheritdoc IHookrRegistry
    function closeLaneOf(address root) external onlyBrake {
        HookrRegistryStorage.State storage s = HookrRegistryStorage.state();
        if (!s.roots[root].registered) revert InvalidRoot();
        s.lanes[root] = HookrRegistryStorage.Lane(address(0), 0, uint48(block.timestamp), bytes32(0));
        emit LaneClosed(root, msg.sender);
    }

    /// @inheritdoc IHookrRegistry
    function stopExecutorLane(address root, address executor) external onlyBrake {
        HookrRegistryStorage.State storage s = HookrRegistryStorage.state();
        if (!s.roots[root].registered) revert InvalidRoot();
        HookrRegistryStorage.LaneSwitch storage w = s.laneSwitches[root][executor];
        (w.on, w.brakedAt) = (false, uint48(block.timestamp));
        emit ExecutorLaneSet(root, executor, false, w.gasCap, msg.sender);
    }

    /// @inheritdoc IHookrRegistry
    function tuneExecutorLane(address root, address executor, uint32 gasCap) external onlyBrake {
        HookrRegistryStorage.State storage s = HookrRegistryStorage.state();
        if (!s.roots[root].registered) revert InvalidRoot();
        HookrRegistryStorage.LaneSwitch storage w = s.laneSwitches[root][executor];
        if (gasCap < HookrRegistryChecks.MIN_LANE_GAS || gasCap >= w.gasCap) revert InvalidLane();
        (w.gasCap, w.brakedAt) = (gasCap, uint48(block.timestamp));
        emit ExecutorLaneSet(root, executor, w.on, gasCap, msg.sender);
    }

    /// @inheritdoc IHookrRegistry
    function startExecutorLaneAt(address root, address executor, uint32 gasCap) external onlyOwner {
        HookrRegistryChecks.checkLaneOn(root, executor, gasCap);
        bytes memory arguments = abi.encode(root, executor, gasCap);
        HookrRegistryStorage.LaneSwitch storage w = HookrRegistryStorage.state().laneSwitches[root][executor];
        _consumeAfter(LANE_ON, arguments, w.brakedAt);
        (w.on, w.gasCap) = (true, gasCap);
        emit ExecutorLaneSet(root, executor, true, gasCap, msg.sender);
    }

    /// @inheritdoc IHookrRegistry
    function retireRoot(address root) external onlyOwner {
        _consume(RETIRE_ROOT, abi.encode(root));
        if (!HookrRegistryStorage.state().roots[root].registered) revert InvalidRoot();
        HookrRegistryStorage.state().roots[root].active = false;
        emit RootRetired(root);
    }

    /// @inheritdoc IHookrRegistry
    function freezeRoot(address root) external onlyOwner {
        HookrRegistryStorage.RootState storage r = HookrRegistryStorage.state().roots[root];
        if (!r.registered) revert InvalidRoot();
        if (r.frozen) revert RootFrozen();
        r.frozen = true;
        emit RootSealed(root);
    }

    /// @inheritdoc IHookrRegistry
    function admit(address root, Admission calldata a) external onlyOwner {
        HookrRegistryAdmin.admit(root, a, delay);
    }

    /// @inheritdoc IHookrRegistry
    function revokeFactoryAdmissions(address factory, address[] calldata implementations) external onlyBrake {
        HookrRegistryStorage.State storage s = HookrRegistryStorage.state();
        if (s.roots[factory].registered) revert InvalidAdmission();
        for (uint256 i; i < implementations.length; ++i) {
            address implementation = implementations[i];
            if (s.admissions[factory][implementation].kind != Kind.ADVISORY) revert InvalidAdmission();
            _revoke(s, factory, implementation);
        }
    }

    /// @inheritdoc IHookrAdmissions
    function revokeModuleAdmission(address scope, address implementation) external {
        HookrRegistryStorage.State storage s = HookrRegistryStorage.state();
        if (msg.sender != s.owner) {
            if (msg.sender != s.guardian) revert Unauthorized();
            // On a frozen root, and a part scope of one, a revocation could not be undone: the owner's alone.
            if (HookrRegistryChecks.frozenScope(scope)) revert Unauthorized();
        }
        _revoke(s, scope, implementation);
    }

    /// @inheritdoc IHookrRegistry
    function setGuardian(address nextGuardian) external onlyOwner {
        HookrRegistryChecks.requireUndelegated(nextGuardian);
        _consume(SET_GUARDIAN, abi.encode(nextGuardian));
        HookrRegistryStorage.State storage s = HookrRegistryStorage.state();
        emit GuardianSet(s.guardian, nextGuardian);
        s.guardian = nextGuardian;
    }

    /// @inheritdoc IHookrRegistry
    function removeGuardian() external onlyOwner {
        HookrRegistryStorage.State storage s = HookrRegistryStorage.state();
        address previous = s.guardian;
        if (previous != address(0)) {
            s.guardian = address(0);
            emit GuardianSet(previous, address(0));
        }
    }

    /// @inheritdoc IHookrRegistry
    function pauseNewMarkets() external onlyBrake {
        HookrRegistryStorage.State storage s = HookrRegistryStorage.state();
        if (!s.newMarketsPaused) {
            s.newMarketsPaused = true;
            emit NewMarketsPaused(msg.sender);
        }
    }

    /// @inheritdoc IHookrRegistry
    function resumeNewMarkets() external onlyOwner {
        HookrRegistryStorage.State storage s = HookrRegistryStorage.state();
        if (!s.newMarketsPaused) revert NewMarketsNotPaused();
        _consume(RESUME_NEW_MARKETS, "");
        s.newMarketsPaused = false;
        emit NewMarketsResumed(msg.sender);
    }

    /// @inheritdoc IHookrRegistry
    function setQuote(address asset, bool active) external onlyOwner {
        if (asset == address(0)) revert InvalidAddress();
        uint48 brakedAt;
        if (active) {
            HookrRegistryChecks.requireContract(asset);
            HookrRegistryStorage.QuoteBrake storage b = HookrRegistryStorage.quoteState().brakes[asset];
            (brakedAt, b.braked) = (b.lastBrakeAt, false);
        }
        _consumeAfter(SET_QUOTE, abi.encode(asset, active), brakedAt);
        HookrRegistryStorage.State storage s = HookrRegistryStorage.state();
        if (active && s.quotePosition[asset] == 0) {
            s.quotes.push(asset);
            s.quotePosition[asset] = s.quotes.length;
        } else if (!active) {
            _dropFromCatalog(asset);
        }
        emit QuoteSet(asset, active);
    }

    /// @inheritdoc IHookrRegistry
    function addSettlementCurrency(address currency) external onlyOwner {
        HookrRegistryChecks.checkSettlement(currency);
        bytes memory arguments = abi.encode(currency);
        _consumeAfter(ADD_SETTLEMENT, arguments, HookrRegistryStorage.settlement().removedAt[currency]);
        _addSettlement(currency);
    }

    /// @inheritdoc IHookrRegistry
    function removeSettlementCurrency(address currency) external onlyBrake {
        HookrRegistryStorage.Settlement storage t = HookrRegistryStorage.settlement();
        t.removedAt[currency] = uint48(block.timestamp);
        uint256 position = t.position[currency];
        if (position != 0) {
            address last = t.currencies[t.currencies.length - 1];
            t.currencies[position - 1] = last;
            t.position[last] = position;
            t.currencies.pop();
            delete t.position[currency];
        }
        emit SettlementCurrencySet(currency, false, msg.sender);
    }

    /// @inheritdoc IHookrRegistry
    function brakeOneQuoteInstantly(address asset) external onlyBrake {
        if (asset == address(0)) revert InvalidAddress();
        if (_dropFromCatalog(asset)) emit QuoteSet(asset, false);
        HookrRegistryStorage.QuoteBrake storage b = HookrRegistryStorage.quoteState().brakes[asset];
        b.braked = true;
        b.lastBrakeAt = uint48(block.timestamp);
        emit QuoteBraked(asset, true, msg.sender);
    }

    /// @inheritdoc IHookrRegistry
    function reopenSingleQuote(address asset) external onlyOwner {
        HookrRegistryStorage.QuoteBrake storage b = HookrRegistryStorage.quoteState().brakes[asset];
        if (!b.braked) revert QuoteNotBraked(asset);
        _consumeAfter(REOPEN_QUOTE, abi.encode(asset), b.lastBrakeAt);
        b.braked = false;
        emit QuoteBraked(asset, false, msg.sender);
    }

    /// @inheritdoc IHookrRegistry
    function installQuoteClass(bytes32 codeHash, address witness) external onlyOwner {
        HookrRegistryChecks.checkQuoteClass(codeHash, witness);
        HookrRegistryStorage.QuoteState storage q = HookrRegistryStorage.quoteState();
        _consumeAfter(SET_QUOTE_CLASS, abi.encode(codeHash, witness), q.classDroppedAt[codeHash]);
        q.classes.push(codeHash);
        q.classPosition[codeHash] = q.classes.length;
        emit QuoteClassSet(codeHash, witness, true);
    }

    /// @inheritdoc IHookrRegistry
    function dropWholeQuoteClass(bytes32 codeHash) external onlyBrake {
        HookrRegistryStorage.QuoteState storage q = HookrRegistryStorage.quoteState();
        q.classDroppedAt[codeHash] = uint48(block.timestamp);
        uint256 position = q.classPosition[codeHash];
        if (position != 0) {
            bytes32 last = q.classes[q.classes.length - 1];
            q.classes[position - 1] = last;
            q.classPosition[last] = position;
            q.classes.pop();
            delete q.classPosition[codeHash];
            emit QuoteClassSet(codeHash, address(0), false);
        }
        emit QuoteClassDropped(codeHash, msg.sender);
    }

    /// @inheritdoc IHookrRegistry
    function authorizeAnyQuote() external onlyOwner {
        HookrRegistryStorage.QuoteState storage q = HookrRegistryStorage.quoteState();
        if (q.anyQuote) revert AnyQuoteActive();
        _consumeAfter(ANY_QUOTE, "", q.anyQuoteStoppedAt);
        q.anyQuote = true;
        emit AnyQuoteSet(true, msg.sender);
    }

    /// @inheritdoc IHookrRegistry
    function dismissAnyQuoteNow() external onlyBrake {
        HookrRegistryStorage.QuoteState storage q = HookrRegistryStorage.quoteState();
        (q.anyQuote, q.anyQuoteStoppedAt) = (false, uint48(block.timestamp));
        emit AnyQuoteSet(false, msg.sender);
    }

    /// @inheritdoc IHookrExternalHooks
    function setExternalHook(address hook, HookKind kind, bytes32 codeHash, address bondRef) external onlyOwner {
        HookrRegistryAdmin.setExternalHook(hook, kind, codeHash, bondRef, delay);
    }

    /// @inheritdoc IHookrExternalHooks
    function dropSingleExternalHookRecordNow(address hook) external onlyBrake {
        HookrRegistryStorage.Records storage t = HookrRegistryStorage.records();
        delete t.hooks[hook];
        t.delistedAt[hook] = uint48(block.timestamp);
        emit ExternalHookDelisted(hook, msg.sender);
    }

    /// @inheritdoc IHookrExternalHooks
    function findExternalHookWithCodeCheck(address hook)
        external
        view
        returns (ExternalHook memory record, bool codeHashMatches)
    {
        record = HookrRegistryStorage.records().hooks[hook];
        codeHashMatches = record.kind != HookKind.NONE && hook.codehash == record.codeHash;
    }

    /// @inheritdoc IHookrRegistry
    function transferOwnership(address nextOwner) external onlyOwner {
        if (nextOwner == address(0)) revert InvalidAddress();
        HookrRegistryChecks.requireUndelegated(nextOwner);
        _consume(TRANSFER_OWNER, abi.encode(nextOwner));
        HookrRegistryStorage.State storage s = HookrRegistryStorage.state();
        s.pendingOwner = nextOwner;
        emit OwnershipTransferStarted(s.owner, nextOwner);
    }

    /// @inheritdoc IHookrRegistry
    function cancelOwnershipTransfer() external onlyOwner {
        HookrRegistryStorage.State storage s = HookrRegistryStorage.state();
        address nominee = s.pendingOwner;
        if (nominee == address(0)) revert InvalidAddress();
        s.pendingOwner = address(0);
        emit OwnershipTransferCancelled(s.owner, nominee);
    }

    /// @inheritdoc IHookrRegistry
    function acceptOwnership() external {
        HookrRegistryStorage.State storage s = HookrRegistryStorage.state();
        if (msg.sender != s.pendingOwner) revert Unauthorized();
        HookrRegistryChecks.requireUndelegated(msg.sender);
        address previous = s.owner;
        s.owner = msg.sender;
        s.pendingOwner = address(0);
        emit OwnershipTransferred(previous, msg.sender);
    }

    /// @dev Withdraws a live admission for good: the scope can never admit `implementation` again.
    function _revoke(HookrRegistryStorage.State storage s, address scope, address implementation) private {
        if (s.admissions[scope][implementation].implementation == address(0)) revert InvalidAdmission();
        delete s.admissions[scope][implementation];
        s.revoked[scope][implementation] = true;
        emit AdmissionRevoked(scope, implementation, msg.sender);
    }

    function _addSettlement(address currency) private {
        HookrRegistryStorage.Settlement storage t = HookrRegistryStorage.settlement();
        t.currencies.push(currency);
        t.position[currency] = t.currencies.length;
        emit SettlementCurrencySet(currency, true, msg.sender);
    }

    /// @dev `isQuote` past native ETH and the catalog: refused while braked; in any-quote mode every class member
    ///      qualifies too, a class being the codehash of non-delegated code.
    function _openQuote(address asset) private view returns (bool) {
        HookrRegistryStorage.QuoteState storage q = HookrRegistryStorage.quoteState();
        if (q.brakes[asset].braked) return false;
        return q.anyQuote ? HookrRegistryChecks.holdsOwnCode(asset) : _classMember(q, asset);
    }

    /// @dev Whether `asset`'s runtime codehash is an admitted class and `asset` reports a nonzero `totalSupply()`,
    ///      read under the registry's probe gas in scratch space; a failed or malformed read is false.
    function _classMember(HookrRegistryStorage.QuoteState storage q, address asset) private view returns (bool ok) {
        if (q.classPosition[asset.codehash] == 0) return false;
        bytes4 selector = TOTAL_SUPPLY_SELECTOR;
        uint256 probeGas = HookrRegistryChecks.PROBE_GAS;
        // Yul evaluates arguments right to left, so the call's success is bound before its returndatasize is read.
        assembly ("memory-safe") {
            mstore(0, selector)
            let called := staticcall(probeGas, asset, 0, 4, 0, 32)
            ok := and(and(called, eq(returndatasize(), 32)), iszero(iszero(mload(0))))
        }
    }

    /// @dev Removes `asset` from the catalog; returns whether it was there.
    function _dropFromCatalog(address asset) private returns (bool listed) {
        HookrRegistryStorage.State storage s = HookrRegistryStorage.state();
        uint256 position = s.quotePosition[asset];
        if (position == 0) return false;
        address last = s.quotes[s.quotes.length - 1];
        s.quotes[position - 1] = last;
        s.quotePosition[last] = position;
        s.quotes.pop();
        delete s.quotePosition[asset];
        return true;
    }

    /// @dev `_consume` for an operation a brake can pre-empt: it also refuses one queued at or before `brakeAt` (it was
    ///      queued at readyAt - delay). The timelock step runs in HookrRegistryAdmin.
    function _consumeAfter(bytes32 kind, bytes memory arguments, uint48 brakeAt) private {
        HookrRegistryAdmin.consume(kind, arguments, brakeAt, delay);
    }

    /// @dev Consumes a matured queued operation: queued, ready and not expired. The timelock step runs in
    ///      HookrRegistryAdmin.
    function _consume(bytes32 kind, bytes memory arguments) private {
        HookrRegistryAdmin.consume(kind, arguments, 0, delay);
    }
}
