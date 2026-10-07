// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookrTypes} from "../types/HookrTypes.sol";
import {IHookrFactoryRegistry} from "./IHookrFactoryRegistry.sol";

/// @title IHookrRegistry
/// @notice Interface for HookrRegistry: roots, root factories, module admissions and quote assets.
interface IHookrRegistry is IHookrFactoryRegistry {
    /// @notice What an admission admits. RULES: a pool's Rules module, or under a part scope a part of one. ADVISORY: a
    ///         pool's advisory, or a root factory's pair advisory. GATE: a contract that may vouch for a swap's payer
    ///         before the Hookr router unlocks the PoolManager (`IHookrSwapGate`), admitted per root.
    /// @dev GATE's day-one consumer is HookrFamilyRouter, whose Multi-pool launch trade legs run through the router's
    ///      gated swap; the limit-orders book follows. Its invariants: a gate is admitted only on an active root, with
    ///      zero caps, no phases, 25,000 to 200,000 gas, neither fee-only nor fail-open, its runtime codehash pinned and
    ///      the schema `keccak256("IHookrSwapGate")`; a root binds a pool's Rules and advisory only from admissions of
    ///      those kinds, so a gate is never a pool module; a revoked gate reads as empty, and its consumer refuses a
    ///      gate whose runtime codehash differs from the pinned one; a root's freeze seals its gates. A gate is inert
    ///      until a queued `ADMIT` of kind GATE executes: until then the registry reports none.
    enum Kind {
        RULES,
        ADVISORY,
        GATE
    }

    /// @notice Why an asset is a quote for new pools: native ETH, the reviewed catalog, an admitted quote class, or
    ///         any-quote mode alone (UNREVIEWED: the app shows it as unverified), or not a quote (NONE).
    enum QuoteBadge {
        NONE,
        NATIVE,
        CATALOG,
        CLASS,
        UNREVIEWED
    }

    /// @notice A module admission: the implementation a scope admits, its pinned runtime code and the limits it runs
    ///         under.
    struct Admission {
        /// @notice What the admission admits.
        Kind kind;
        /// @notice The admitted contract.
        address implementation;
        /// @notice The runtime codehash pinned at admission; the module must still run it when read.
        bytes32 codeHash;
        /// @notice The hash of the module's published configuration schema; not zero.
        bytes32 schemaHash;
        /// @notice The fee ceilings the module's charges stay under.
        HookrTypes.Caps caps;
        /// @notice The gas the root forwards to the module's calls.
        uint32 gasLimit;
        /// @notice The swap phases the module is called in: bit 0 before the swap, bit 1 after it.
        uint8 phaseMask;
        /// @notice Whether the module only changes the LP fee and takes no other charge.
        bool feeOnly;
        /// @notice Whether a failing call lets the swap go on with the base fee instead of reverting it.
        bool failOpen;
    }

    /// @notice Emitted when a root factory is activated with its pinned runtime codehash, or deactivated.
    /// @param factory The root factory.
    /// @param codeHash The runtime codehash pinned for it.
    /// @param active Whether it was activated or deactivated.
    event RootFactorySet(address indexed factory, bytes32 codeHash, bool active);

    /// @notice Emitted when an active root factory registers a root it deployed.
    /// @param factory The root factory that deployed the root.
    /// @param root The registered root.
    event FactoryRootRegistered(address indexed factory, address indexed root);

    /// @notice The caller may not do this.
    error Unauthorized();
    /// @notice An address argument is zero or not a contract the call can use.
    error InvalidAddress();
    /// @notice The delay is outside the registry's bounds.
    error InvalidDelay();
    /// @notice `operation` is already queued and has not expired.
    error AlreadyQueued(bytes32 operation);
    /// @notice `operation` is not queued.
    error NotQueued(bytes32 operation);
    /// @notice `operation` is not yet executable.
    error NotReady(bytes32 operation);
    /// @notice `operation` could be executed until `expiredAt` and no longer can be.
    error OperationExpired(bytes32 operation, uint48 expiredAt);
    /// @notice `kind` is not an operation kind.
    error UnknownOperation(bytes32 kind);
    /// @notice The arguments are not the canonical encoding the `kind` operation re-derives.
    error NonCanonicalArguments(bytes32 kind);
    /// @notice The address is not a registered, active root the call can use.
    error InvalidRoot();
    /// @notice The root's admission set is sealed.
    error RootFrozen();
    /// @notice The implementation is already admitted for the scope.
    error AlreadyAdmitted();
    /// @notice The admission, or the revocation or lane record it names, is invalid for its scope or kind.
    error InvalidAdmission();
    /// @notice `account` holds no code.
    error NotAContract(address account);
    /// @notice `account` is an EIP-7702 delegation, not contract code.
    error DelegatedAccount(address account);
    /// @notice New markets are not paused.
    error NewMarketsNotPaused();
    /// @notice The root is not closed.
    error RootNotClosed();
    /// @notice `account` does not run the runtime codehash the operation names.
    error CodeHashMismatch(address account);
    /// @notice `account` is already active.
    error AlreadyActive(address account);
    /// @notice The lane opening, executor, gas cap, partner share or settlement currency is invalid.
    error InvalidLane();

    /// @notice The lane opening was queued at or before the brake that last closed the root's lane. Queue it again.
    error LaneQueuedBeforeClose(bytes32 operation);
    /// @notice New markets are paused.
    error MarketsPaused();

    /// @notice The quote class is already admitted.
    error QuoteClassActive(bytes32 codeHash);

    /// @notice Any-quote mode is already on.
    error AnyQuoteActive();

    /// @notice The class admission, any-quote switch-on, quote reopening or catalog addition, the lane opening or
    ///         switch-on of an executor, or the settlement currency addition was queued at or before the brake that
    ///         last withdrew it. Queue it again.
    error QueuedBeforeBrake(bytes32 operation);

    /// @notice The asset has no quote brake to lift.
    error QuoteNotBraked(address asset);

    /// @notice An operation was queued.
    /// @param operation The operation's hash.
    /// @param kind The operation kind.
    /// @param arguments The canonical ABI arguments the executing function re-derives.
    /// @param readyAt The timestamp from which it can execute.
    /// @param expiresAt The timestamp after which it can no longer execute.
    event OperationQueued(
        bytes32 indexed operation, bytes32 indexed kind, bytes arguments, uint48 readyAt, uint48 expiresAt
    );
    /// @notice A queued operation was cancelled.
    /// @param operation The operation's hash.
    event OperationCancelled(bytes32 indexed operation);
    /// @notice A queued operation executed.
    /// @param operation The operation's hash.
    event OperationExecuted(bytes32 indexed operation);
    /// @notice A launcher was admitted or removed.
    /// @param launcher The launcher.
    /// @param active Whether it is now admitted.
    event LauncherSet(address indexed launcher, bool active);
    /// @notice A root was registered.
    /// @param root The root.
    event RootRegistered(address indexed root);
    /// @notice A root was retired and takes no new pools for good.
    /// @param root The root.
    event RootRetired(address indexed root);
    /// @notice A brake closed a root to new pools.
    /// @param root The root.
    /// @param by The owner or guardian that closed it.
    event RootClosed(address indexed root, address indexed by);
    /// @notice A queued operation reopened a closed root.
    /// @param root The root.
    event RootReopened(address indexed root);
    /// @notice A brake stopped a launcher from initialising new pools.
    /// @param launcher The launcher.
    /// @param by The owner or guardian that deactivated it.
    event LauncherDeactivated(address indexed launcher, address indexed by);
    /// @notice A root's module admission set was sealed for good.
    /// @param root The root.
    event RootSealed(address indexed root);
    /// @notice A module was admitted for future pool bindings.
    /// @param root The scope: a root, a root factory or a part scope.
    /// @param implementation The admitted module.
    /// @param kind What it was admitted as.
    /// @param codeHash The runtime codehash pinned.
    event ModuleAdmitted(address indexed root, address indexed implementation, Kind kind, bytes32 codeHash);
    /// @notice A brake revoked an admission for good.
    /// @param scope The root, root factory or part scope the admission was for.
    /// @param implementation The revoked module.
    /// @param by The owner or guardian that revoked it.
    event AdmissionRevoked(address indexed scope, address indexed implementation, address indexed by);
    /// @notice An owner nomination was queued and executed.
    /// @param owner The current owner.
    /// @param nominee The nominated successor.
    event OwnershipTransferStarted(address indexed owner, address indexed nominee);
    /// @notice An unaccepted nomination was withdrawn.
    /// @param owner The owner.
    /// @param nominee The withdrawn nominee.
    event OwnershipTransferCancelled(address indexed owner, address indexed nominee);
    /// @notice The nominee accepted ownership.
    /// @param previousOwner The former owner.
    /// @param newOwner The new owner.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    /// @notice The guardian changed.
    /// @param previousGuardian The former guardian, or zero.
    /// @param newGuardian The new guardian, or zero for none.
    event GuardianSet(address indexed previousGuardian, address indexed newGuardian);
    /// @notice A brake paused new pool initialisation, launches and root-factory registrations.
    /// @param by The owner or guardian that paused them.
    event NewMarketsPaused(address indexed by);
    /// @notice A queued operation lifted the new markets pause.
    /// @param by The account that executed the operation.
    event NewMarketsResumed(address indexed by);
    /// @notice An asset was added to or removed from the reviewed quote catalog.
    /// @param asset The asset.
    /// @param active Whether it is now in the catalog.
    event QuoteSet(address indexed asset, bool active);

    /// @notice A quote class was admitted (`witness` is the contract whose runtime codehash was checked) or withdrawn
    ///         (`witness` zero).
    /// @param codeHash The class's runtime codehash.
    /// @param witness The contract whose codehash was checked, or zero when withdrawn.
    /// @param active Whether the class is admitted.
    event QuoteClassSet(bytes32 indexed codeHash, address indexed witness, bool active);

    /// @notice A brake withdrew one asset as a quote for new pools (`braked`), or a queued operation lifted it.
    /// @param asset The asset.
    /// @param braked Whether it is now braked.
    /// @param by The account that braked it or executed the lift.
    event QuoteBraked(address indexed asset, bool braked, address indexed by);

    /// @notice A brake withdrew the quote class, or pre-empted its queued admissions, effective at once.
    /// @param codeHash The class's runtime codehash.
    /// @param by The owner or guardian that dropped it.
    event QuoteClassDropped(bytes32 indexed codeHash, address indexed by);

    /// @notice Any-quote mode was switched on by a queued operation, or off by a brake.
    /// @param on Whether any-quote mode is now on.
    /// @param by The account that switched it.
    event AnyQuoteSet(bool on, address indexed by);

    /// @notice Returns whether the launcher is admitted for new pools.
    /// @param account The account.
    /// @return True when the launcher is admitted for new pools.
    function isLauncher(address account) external view returns (bool);

    /// @notice Returns whether a root is registered, including retired roots.
    /// @param root The address.
    /// @return True when it is a registered root, retired or not.
    function isRoot(address root) external view returns (bool);

    /// @notice Returns whether the root accepts new pool bindings: registered, neither retired nor closed, and new
    ///         markets not paused.
    /// @param root The root.
    /// @return True when the root accepts new pool bindings.
    function rootOpen(address root) external view returns (bool);

    /// @notice Returns whether a brake holds the root closed and the owner can still reopen it: closed by `closeRoot`
    ///         and not retired, so a queued `REOPEN_ROOT` could execute. While it does, HookrRouter.swapGated refuses
    ///         every gate on the root. A retired root never reopens, so a closure there never stops its gates.
    /// @dev Day-one consumer: HookrRouter, whose `swapGated` reads it before asking any gate. It gives the guardian an
    ///      instant answer to a misbehaving GATE admission it may not revoke (on a frozen root, an owned root's copy of
    ///      a template gate included) that the owner can lift, and never a permanent one: a retired root reads false.
    /// @param root The root.
    /// @return True when a brake holds the root closed and a queued reopening could execute.
    function rootReopenable(address root) external view returns (bool);

    /// @notice Returns the admission of `implementation` for a root, for a root factory (a pair advisory) or for a part
    ///         scope (a part of a Rules module, see IHookrAdmissions). An admission never changes; a brake can revoke
    ///         it, and it then reads as empty for good, and an admission a bond stands behind (IHookrAdmissions) reads as
    ///         empty while the bond does not cover it. A module admission is read only when a pool binds; a pool
    ///         already open never reads it again, so a revoke or a lapsed bond blocks new binds only and never silently
    ///         disables a live pool. A GATE admission is read when its gate vouches for a swap, so revoking a gate stops
    ///         it vouching at once while every pool keeps trading through the router's other entry points; closing its
    ///         root stops it until the root reopens (`rootReopenable`).
    /// @param root The scope: a root, a root factory or a part scope.
    /// @param implementation The module.
    /// @return The admission, empty when none is live.
    function admission(address root, address implementation) external view returns (Admission memory);

    /// @notice Returns the root factory that registered `root` through `registerFactoryRoot`. Zero for a root
    ///         registered by a queued `REGISTER_ROOT` operation and for an unregistered address.
    /// @dev Set once at registration; it stays set after the factory is deactivated or the root is retired.
    /// @param root The root.
    /// @return The root factory that registered it, or zero.
    function rootFactoryOf(address root) external view returns (address);

    /// @notice Returns the advisory a root factory recorded for `root` and whether the root is verified: registered,
    ///         and its advisory, if any, currently admitted for the factory that registered it with an unchanged
    ///         runtime codehash.
    /// @dev For indexers and apps to gate pair roots on. `verified` turns false when that admission is revoked. A root
    ///      registered by a queued `REGISTER_ROOT` operation has no recorded advisory and is verified while registered.
    /// @param root The root.
    /// @return advisory The pair advisory the factory recorded for the root, or zero.
    /// @return verified True when the root is registered and its advisory, if any, is still admitted.
    function rootStatus(address root) external view returns (address advisory, bool verified);

    /// @notice Returns whether a new pool may bind `asset` as its quote: native ETH (zero), an asset in the timelocked
    ///         reviewed catalog, a contract whose runtime codehash is an admitted quote class, or, while any-quote mode
    ///         is on, any account holding code that is not an EIP-7702 delegation designator.
    /// @dev Native ETH and catalog assets answer before anything else is read.
    /// @param asset The asset; zero is native ETH.
    /// @return True when a new pool may bind the asset as its quote.
    function isQuote(address asset) external view returns (bool);

    /// @notice Returns why `asset` is a quote for new pools, or NONE. Nonzero exactly when `isQuote` is true.
    /// @param asset The asset; zero is native ETH.
    /// @return Why the asset is a quote, or NONE.
    function badgeForQuote(address asset) external view returns (QuoteBadge);

    /// @notice Returns the Uniswap v4 PoolManager every registered root must report.
    /// @return The PoolManager pinned at construction.
    function poolManager() external view returns (IPoolManager);

    /// @notice Returns the account that holds the registry's brakes besides the owner. Zero means none.
    /// @dev The guardian can only stop or withdraw, at once: pause new markets, close a root, deactivate a launcher or
    ///      root factory, revoke an admission (except on a frozen root or under one of its part scopes), close a lane,
    ///      switch an executor off or lower its gas, withdraw a quote, a quote class, any-quote mode, a settlement
    ///      currency or an external-hook record, and cancel a queued operation. It can never queue or execute one.
    ///      Appointing it is a timelocked `SET_GUARDIAN`; the owner removes it at once. Periphery that lets the
    ///      registry's guardian brake its own queued changes, such as a Bux program approval, reads it here.
    /// @return The guardian, or zero.
    function guardian() external view returns (address);

    /// @notice Returns the delay every queued operation waits.
    /// @return The delay in seconds.
    function delay() external view returns (uint48);

    /// @notice Returns the current registry administrator.
    /// @return The owner.
    function owner() external view returns (address);

    /// @notice Returns the nominated successor.
    /// @return The nominee, or zero.
    function pendingOwner() external view returns (address);

    /// @notice Returns whether new pool initialisation and launches are paused on every root.
    /// @return True while new markets are paused.
    function newMarketsPaused() external view returns (bool);

    /// @notice Returns the operation's execution timestamp. Zero means it is not queued.
    /// @param operation The operation's hash.
    /// @return The timestamp from which it can execute, or zero.
    function readyAt(bytes32 operation) external view returns (uint48);

    /// @notice Returns the last timestamp at which a queued operation can execute. Zero means it is not queued.
    /// @param operation The operation's hash.
    /// @return The last timestamp at which it can execute, or zero.
    function expiresAt(bytes32 operation) external view returns (uint48);

    /// @notice Returns whether the root was closed to new pools by a brake and awaits a queued reopening.
    /// @param root The root.
    /// @return True when a brake closed the root and a queued reopening is awaited.
    function rootClosed(address root) external view returns (bool);

    /// @notice Returns the runtime codehash pinned for an active root factory. Zero means inactive.
    /// @param factory The root factory.
    /// @return The pinned runtime codehash, or zero when inactive.
    function rootFactoryCodeHash(address factory) external view returns (bytes32);

    /// @notice Returns whether further module admissions are permanently disabled for this root.
    /// @param root The root.
    /// @return True when the root's admission set is sealed.
    function rootFrozen(address root) external view returns (bool);

    /// @notice Returns whether a brake revoked the admission of `implementation` for `scope`: a root, a root factory or
    ///         a part scope. A revoked implementation cannot be admitted for that scope again.
    /// @param scope The root, root factory or part scope.
    /// @param implementation The module.
    /// @return True when a brake revoked the admission.
    function isRevokedAdmission(address scope, address implementation) external view returns (bool);

    /// @notice Returns every reviewed ERC20 quote asset currently in the catalog. Native ETH is implicit.
    /// @return The catalog's ERC20 quote assets.
    function quoteAssets() external view returns (address[] memory);

    /// @notice Returns whether any-quote mode is on, the time of the last `dismissAnyQuoteNow` (zero: never) and the
    ///         runtime codehash of every admitted quote class.
    /// @return anyQuote True while any-quote mode is on.
    /// @return anyQuoteStoppedAt The time of the last `dismissAnyQuoteNow`, or zero.
    /// @return classes The runtime codehash of every admitted quote class.
    function openQuoteTerms() external view returns (bool anyQuote, uint48 anyQuoteStoppedAt, bytes32[] memory classes);

    /// @notice Returns whether `asset` is braked as a quote for new pools, and the time of its last brake (zero: never).
    /// @param asset The asset.
    /// @return braked True while the asset is braked as a quote.
    /// @return lastBrakeAt The time of its last brake, or zero.
    function quoteIsBraked(address asset) external view returns (bool braked, uint48 lastBrakeAt);

    /// @notice Commits an operation to this chain, registry, action kind and ABI arguments.
    /// @param kind The operation kind.
    /// @param arguments The operation's canonical ABI arguments.
    /// @return The hash this chain and registry commit to for the operation.
    function operationHash(bytes32 kind, bytes memory arguments) external view returns (bytes32);

    /// @notice Queues and publishes an exact operation for execution after the registry delay.
    /// @dev The arguments must be the canonical ABI encoding the executing function re-derives, and they are
    ///      checked against current chain state: addresses being admitted must already hold non-delegated code.
    ///      An expired operation may be queued again.
    /// @param kind The operation kind.
    /// @param arguments The operation's canonical ABI arguments.
    /// @return operation The operation's hash.
    function queue(bytes32 kind, bytes calldata arguments) external returns (bytes32 operation);

    /// @notice Cancels a queued operation at once.
    /// @dev Callable by the owner or the guardian: a cancel only withdraws, and the owner can queue the operation again,
    ///      which then waits a full delay. A guardian that cancels the owner's operations, a `SET_GUARDIAN` replacing it
    ///      included, is answered by `removeGuardian`, which takes effect at once, and a new queue.
    /// @param operation The operation's hash.
    function cancel(bytes32 operation) external;

    /// @notice Executes a queued launcher admission or removal. An admission executes only while the launcher is
    ///         inactive.
    /// @param launcher The launcher.
    /// @param active True to admit it, false to remove it.
    function setLauncher(address launcher, bool active) external;

    /// @notice Executes a queued registration of a compatible root whose runtime codehash matches the queued one.
    /// @param root The root.
    /// @param codeHash The runtime codehash the queued operation pins.
    function registerRoot(address root, bytes32 codeHash) external;

    /// @notice Executes a queued root factory activation, pinned to the queued runtime codehash, or deactivation.
    ///         An activation executes only while the factory is inactive.
    /// @param factory The root factory.
    /// @param codeHash The runtime codehash the queued operation pins.
    /// @param active True to activate it, false to deactivate it.
    function setRootFactory(address factory, bytes32 codeHash, bool active) external;

    /// @notice Brake: stops a root factory from registering further roots, effective at once.
    /// @dev Callable by the owner or the guardian. Roots it already registered are unaffected. Reactivation is a
    ///      timelocked `SET_ROOT_FACTORY` operation that can only be queued while the factory is inactive.
    /// @param factory The root factory.
    function deactivateRootFactory(address factory) external;

    /// @notice Brake: stops one launcher from initialising new pools, effective at once.
    /// @dev Callable by the owner or the guardian. Positions it holds and exits it serves are unaffected.
    ///      Readmission is a timelocked `SET_LAUNCHER` operation that can only be queued while the launcher is
    ///      inactive.
    /// @param launcher The launcher.
    function deactivateLauncher(address launcher) external;

    /// @notice Brake: closes one root to new pools, effective at once.
    /// @dev Callable by the owner or the guardian. Existing pools keep trading, exiting and claiming. While the closed
    ///      root is unretired (`rootReopenable`), HookrRouter.swapGated refuses every gate on it, so a closure also
    ///      stops a misbehaving GATE admission the guardian may not revoke on a frozen root. Reopening is a timelocked
    ///      `REOPEN_ROOT` operation that can only be queued while the root is closed.
    /// @param root The root.
    function closeRoot(address root) external;

    /// @notice Executes a queued reopening of a closed, unretired root.
    /// @param root The root.
    function reopenRoot(address root) external;

    /// @notice Executes a queued opening of `root`'s recapture lane: the partner executor `executor`, pinned to the
    ///         runtime codehash `codeHash`, which new recapture pools freeze with its partner share `partnerBps`, and
    ///         whose switch it turns on at `gasCap` gas per lane call.
    /// @dev Checked when queued and again when executed: `root` is registered, unretired and not frozen, unless it is an
    ///      owned root (IHookrOwnedRoots), whose lane is the one exception to its freeze; `executor` is not `root` and
    ///      holds non-delegated code with that codehash; `gasCap` is from 50,000 to 5,000,000; and `partnerBps` is at
    ///      most 2,500. The executor's own `partnerBps()` is never read: `partnerBps` is the pinned rate an arb
    ///      recapture's push is checked against. An opening replaces the root's lane, so a new executor takes over new
    ///      pools with no gap; pools that froze an earlier executor keep it and its switch. It executes only if it was
    ///      queued after the root's last `closeLaneOf` and after the executor's last brake.
    /// @param root The root.
    /// @param executor The partner executor.
    /// @param codeHash The executor's runtime codehash, which new pools freeze.
    /// @param gasCap The gas each lane call gets, from 50,000 to 5,000,000.
    /// @param partnerBps The partner's share of each arb recapture's profit, at most 2,500.
    function openLaneOf(address root, address executor, bytes32 codeHash, uint32 gasCap, uint16 partnerBps) external;

    /// @notice Brake: closes `root`'s recapture lane to new pools, effective at once, and refuses every opening for it
    ///         queued until now.
    /// @dev Callable by the owner or the guardian, also on a frozen or retired root. The root's later pools open
    ///      without a lane; pools already open keep the executor they froze, whose switch `stopExecutorLane` turns off
    ///      (see `IHookrLanes`). A new lane is a timelocked `OPEN_LANE` queued after this call.
    /// @param root The root.
    function closeLaneOf(address root) external;

    /// @notice Brake: switches `executor` off on `root`, effective at once: every pool of the root that froze it stops
    ///         calling it from its next swap, new pools cannot freeze it, and every opening or switch-on of it queued
    ///         until now is refused.
    /// @dev Callable by the owner or the guardian, also on a frozen or retired root and for an executor never opened
    ///      there. It never points a pool at another executor: a pool's executor is frozen at its initialization. The
    ///      executor recaptures again only after a timelocked `LANE_ON` or `OPEN_LANE` queued after this call.
    /// @param root The root.
    /// @param executor The executor.
    function stopExecutorLane(address root, address executor) external;

    /// @notice Brake: lowers the gas every lane call of `executor` on `root` gets to `gasCap`, effective at once on
    ///         every pool of the root that froze it, and refuses every opening or switch-on of it queued until now.
    /// @dev Callable by the owner or the guardian. `gasCap` must be at least 50,000 and below the current cap: raising
    ///      it is a timelocked `LANE_ON`. Whether the executor is on is unchanged.
    /// @param root The root.
    /// @param executor The executor.
    /// @param gasCap The lower gas each lane call gets, at least 50,000.
    function tuneExecutorLane(address root, address executor, uint32 gasCap) external;

    /// @notice Executes a queued switch-on of `executor` on `root` at `gasCap` gas per lane call: every pool of the
    ///         root that froze it recaptures again from its next swap, with that gas. The one way to raise a cap.
    /// @dev Checked when queued and again when executed: `root` is registered; `executor` was opened on it; `gasCap` is
    ///      from 50,000 to 5,000,000. Also on a frozen or retired root, since it only restores pools already open. It
    ///      executes only if it was queued after the executor's last brake.
    /// @param root The root.
    /// @param executor The executor.
    /// @param gasCap The gas each lane call gets, from 50,000 to 5,000,000.
    function startExecutorLaneAt(address root, address executor, uint32 gasCap) external;

    /// @notice Closes a root to new pools. Existing pools and claims retain their terms.
    /// @param root The root.
    function retireRoot(address root) external;

    /// @notice Permanently seals the root's module admission set.
    /// @param root The root.
    function freezeRoot(address root) external;

    /// @notice Executes a queued, codehash-pinned module admission for future pool bindings.
    /// @dev The scope is an active root, an active root factory admitting a pair advisory (kind ADVISORY) for the
    ///      pair roots it deploys, or a part scope admitting a part of a Rules module (see `IHookrAdmissions`).
    /// @param root The scope: a root, a root factory or a part scope.
    /// @param a The admission.
    function admit(address root, Admission calldata a) external;

    /// @notice Brake: permanently withdraws a root factory's admissions of the given pair advisories, effective at
    ///         once.
    /// @dev Callable by the owner or the guardian. Reverts unless every implementation holds a live ADVISORY admission
    ///      for `factory`, the only kind a root factory's scope admits. The factory then refuses new pair roots naming
    ///      any of them; pair roots already deployed keep calling theirs, since their advisory is immutable. A revoked
    ///      address cannot be admitted for `factory` again, so no queued admission can lift the brake; a replacement is
    ///      a new deployment admitted through the timelock. A root's admissions, and part admissions (always RULES), are
    ///      revoked one at a time by `revokeModuleAdmission`, which keeps a revocation on a frozen root, or under one of
    ///      its part scopes, the owner's alone.
    /// @param factory The root factory.
    /// @param implementations The pair advisories to withdraw.
    function revokeFactoryAdmissions(address factory, address[] calldata implementations) external;

    /// @notice Executes a queued guardian appointment. Zero removes the guardian.
    /// @param nextGuardian The guardian, or zero to remove it.
    function setGuardian(address nextGuardian) external;

    /// @notice Removes the guardian, effective at once.
    /// @dev It only removes authority: the guardian's powers are the brakes, which the owner also holds. Appointing
    ///      a guardian stays a timelocked `SET_GUARDIAN` operation. Does nothing when no guardian is set.
    function removeGuardian() external;

    /// @notice Emergency brake: stops new pool initialisation, launches and root-factory registrations on every
    ///         root, effective at once.
    /// @dev Callable by the owner or the guardian. It is not timelocked because it can only stop new activity:
    ///      swaps, liquidity changes and exits on existing pools, claims and every balance are unaffected.
    ///      Lifting it is a timelocked `RESUME_NEW_MARKETS` operation.
    function pauseNewMarkets() external;

    /// @notice Executes a queued resumption of new markets. It can only be queued while paused.
    function resumeNewMarkets() external;

    /// @notice Executes a queued addition to, or removal from, the reviewed quote catalog. Existing pools are unaffected.
    /// @dev A removal leaves the asset a quote while an admitted class or any-quote mode still qualifies it. An
    ///      addition executes only if it was queued after the asset's last brake, and lifts it.
    /// @param asset The asset.
    /// @param active True to add it to the catalog, false to remove it.
    function setQuote(address asset, bool active) external;

    /// @notice Executes a queued `ADD_SETTLEMENT` operation: `currency` joins the recapture settlement set, so every
    ///         lane executor may push arb recaptures in it (IHookrLaneRoot.settleRecapture).
    /// @dev Checked when queued and again when executed: native ETH (zero) or non-delegated code, not a member, and room
    ///      in the set (MAX_SETTLEMENT). It executes only if it was queued after the currency's last removal.
    /// @param currency The currency; zero is native ETH.
    function addSettlementCurrency(address currency) external;

    /// @notice Brake: takes `currency` out of the recapture settlement set at once, and refuses every addition of it
    ///         queued until now. Callable by the owner or the guardian. A pool's own two currencies stay accepted for
    ///         its arb recaptures whatever the set holds.
    /// @param currency The currency; zero is native ETH.
    function removeSettlementCurrency(address currency) external;

    /// @notice Brake: withdraws `asset` as a quote for new pools, effective at once, whatever qualifies it (the
    ///         catalog, a class or any-quote mode), and refuses every `SET_QUOTE` addition or `REOPEN_QUOTE` of it
    ///         queued until now.
    /// @dev Callable by the owner or the guardian. A catalog asset leaves the catalog. Existing pools keep the quote
    ///      they bound. Lifting it is a timelocked `REOPEN_QUOTE` (`reopenSingleQuote`) or `SET_QUOTE` addition
    ///      queued after this call.
    /// @param asset The asset.
    function brakeOneQuoteInstantly(address asset) external;

    /// @notice Executes a queued lift of `asset`'s quote brake (`REOPEN_QUOTE`, `abi.encode(asset)`): it qualifies
    ///         again as a class member or in any-quote mode. A catalog entry it lost needs a `SET_QUOTE` addition.
    /// @dev Queueable only while the brake holds, and executes only if queued after the asset's last brake.
    /// @param asset The asset.
    function reopenSingleQuote(address asset) external;

    /// @notice Executes a queued admission of the quote class `codeHash`: every contract whose runtime codehash is
    ///         `codeHash` and that reports a nonzero `totalSupply()` becomes a quote for new pools, as a catalog asset
    ///         is. Existing pools are unaffected.
    /// @dev Checked when queued and again when executed: `witness` holds non-delegated code whose runtime codehash is
    ///      `codeHash`, so a class is always real contract code and never an EIP-7702 delegation designator, and the
    ///      class is not admitted. It executes only if it was queued after the class's last `dropWholeQuoteClass`.
    ///      A class suits code whose every instance answers to one issuer: an OpenZeppelin BeaconProxy holds its
    ///      beacon in its runtime, so its codehash admits exactly the proxies of that beacon (every Robinhood stock
    ///      token on 4663 shares one, 0x6c1fdd40...5630). Anyone can deploy another proxy of that beacon, or a copy of
    ///      its runtime, and initialize it with a real stock's name, symbol and uid, but only the issuer's minter can
    ///      give it supply, so the supply requirement keeps such a copy out of the class.
    ///      Never admit the codehash of a permissionless template: every copy anyone deploys would qualify. That
    ///      includes a HookrToken, a launchpad ERC-20 and a bridged token (a ClonableBeaconProxy the bridge gateway
    ///      deploys for any L1 token anyone deposits, with any name and any supply): admit those by address.
    /// @param codeHash The runtime codehash of the class.
    /// @param witness A contract holding that code, which proves the class is real contract code.
    function installQuoteClass(bytes32 codeHash, address witness) external;

    /// @notice Brake: withdraws the quote class `codeHash` from new pools, effective at once, and refuses every
    ///         admission of it queued until now.
    /// @dev Callable by the owner or the guardian, also for a class that is not admitted, to pre-empt a queued
    ///      admission. Existing pools keep the quote they bound, and a catalog entry for a member still qualifies it.
    ///      Readmission is a timelocked `SET_QUOTE_CLASS` queued after this call.
    /// @param codeHash The runtime codehash of the class.
    function dropWholeQuoteClass(bytes32 codeHash) external;

    /// @notice Executes a queued switch-on of any-quote mode: every account that holds code other than an EIP-7702
    ///         delegation designator becomes a quote for new pools, the rule the live launchpad applies. Existing
    ///         pools are unaffected.
    /// @dev It can be queued only while the mode is off, and executes only if it was queued after the last
    ///      `dismissAnyQuoteNow`. `badgeForQuote` tells such a quote (UNREVIEWED) from a reviewed one. The release reads
    ///      no quote decimals: only the Nth-buy pot words would, and they are reserved zeros. Uniswap v4 cannot carry a
    ///      fee-on-transfer or rebasing asset exactly: the Hookr router and Launcher refuse inexact transfers, the
    ///      PoolManager credits only what it receives, and a shortfall such an asset causes (a rebase down, an issuer
    ///      burn or freeze of the PoolManager) falls on that asset's own balances and claims. Every Hookr claim and
    ///      liability is kept per currency, so no quote reaches another currency's claims.
    function authorizeAnyQuote() external;

    /// @notice Brake: switches any-quote mode off for new pools, effective at once, and refuses every switch-on queued
    ///         until now.
    /// @dev Callable by the owner or the guardian. Existing pools keep the quote they bound; native ETH, the catalog
    ///      and the admitted classes still qualify. Switching on again is a timelocked `ANY_QUOTE` queued after this
    ///      call.
    function dismissAnyQuoteNow() external;

    /// @notice Executes a queued owner nomination. The successor must accept.
    /// @param nextOwner The nominee, who must accept.
    function transferOwnership(address nextOwner) external;

    /// @notice Withdraws an unaccepted nomination at once. It only removes authority.
    function cancelOwnershipTransfer() external;

    /// @notice Accepts the pending registry ownership nomination.
    function acceptOwnership() external;
}
