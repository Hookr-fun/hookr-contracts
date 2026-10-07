// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHookrRegistry} from "./IHookrRegistry.sol";

/// @title IHookrOwnedRoots
/// @notice Roots users deploy for themselves. An active root factory, admitted at its pinned runtime codehash through
///         the timelocked `SET_ROOT_FACTORY` and stopped by `deactivateRootFactory`, deploys an unmodified HookrRoot and
///         a companion Rules module for it and registers the root here in the same transaction: frozen with the
///         companion's RULES admission, the ADVISORY and GATE admissions of the template root it names, and the
///         template's open recapture lane with its switch off. The factory implements IHookrRootRegistrar: it answers
///         who may open pools on each of its roots and which Rules it deployed for each.
/// @dev An owned root's admissions are frozen, so nobody, the registry owner included, can widen them. Its lane is the
///      one exception to the freeze: a timelocked `OPEN_LANE` can give it a lane and a timelocked `LANE_ON` can switch
///      its copied lane on, each only when queued after the registration. Arb recapture therefore runs on the shared
///      root and on an owned root only once its lane is opened or switched on. Every brake reaches an owned root as any
///      other root: `pauseNewMarkets`, `closeRoot`, `closeLaneOf`, `stopExecutorLane`, `tuneExecutorLane`, the
///      timelocked `RETIRE_ROOT` and, by the owner alone since the root is frozen, `revokeModuleAdmission`. A GATE copy
///      is read on every gated swap and stays live when the template's admission is revoked, so the guardian's instant
///      answer to a misbehaving copy is `closeRoot`: HookrRouter.swapGated then refuses every gate of the root
///      (`rootReopenable`) until the owner revokes the copy and the root reopens through the timelock.
///      `rootFactoryOf` stays zero for an owned root, which is not a pair root.
///      Day-one consumers: HookrOwnedRootFactory, the root factory that calls `registerOwnedRoot` and answers as each
///      of its roots' IHookrRootRegistrar; HookrLauncher, which asks `rootOpenFor` with its caller before every launch;
///      HookrTreasury, which reads `isOwnedRoot` and `ownedRegistrarForRoot` to collect a companion Rules module by
///      provenance; HookrOwnedProfiles, which reads `isOwnedRoot` to keep profiles off owned roots. The surface is
///      inert until a timelocked `SET_ROOT_FACTORY` admits a factory at its pinned runtime codehash.
interface IHookrOwnedRoots {
    /// @notice `factory` registered `root`, frozen, with the Rules module `rules`; `template` is the root whose
    ///         admissions and lane it copied.
    /// @param root The registered owned root.
    /// @param factory The root factory that registered it.
    /// @param template The root whose admissions and lane it copied.
    /// @param rules The companion Rules module admitted for it.
    event OwnedRootRegistered(address indexed root, address indexed factory, address indexed template, address rules);

    /// @notice Registers `root`, deployed by the calling root factory, frozen with the RULES admission `rules`, the
    ///         template's live ADVISORY and GATE admissions `copies` names, and the template's open lane with its
    ///         switch off: the owned root starts without arb recapture.
    /// @dev Callable only by an active root factory at its pinned runtime codehash, while new markets are not paused.
    ///      `root` must hold code that is not an EIP-7702 delegation, be unregistered and not recorded as an external
    ///      hook, report this registry and its PoolManager and the template's router, quoter and curated router, declare
    ///      permission flags equal to its address bits and to the template's, and report a lane module that holds the
    ///      codehash it reports. `template` must be an active, unclosed root that a queued `REGISTER_ROOT` registered:
    ///      neither a pair root nor an owned root. `templateRules` must hold a live RULES admission on `template` (its
    ///      runtime codehash the pinned one and its bond, if any, covering it), and `rules` must equal that admission in
    ///      kind, schema, gas limit, phases, fee-only and fail-open, with caps no wider, for an implementation that holds
    ///      code that is not an EIP-7702 delegation with the pinned codehash, answers to `root` from `trustedRoot()`,
    ///      reports this registry and its PoolManager, keeps `templateRules`' protocol recipient and protocol share
    ///      floor, and reports its recapture module truthfully. `copies` names at most four ADVISORY and four GATE
    ///      implementations, each live on `template` and named once; each is admitted on `root` with the template's
    ///      terms and bond reference, and a bonded one only while its bond covers it on `root` too. When the template's
    ///      lane is open (an executor whose runtime codehash is the pinned one, its switch on), the registry writes that
    ///      lane (executor, codehash, partner share) and the switch's gas cap onto `root` with the switch off and the
    ///      time of registration as its last brake, and emits `ExecutorLaneSet(root, executor, false, gasCap,
    ///      factory)`. `activeLaneOf(root)` then reads empty, so the root refuses a pool whose Rules ask for arb
    ///      recapture and opens every other pool without a lane: no pool of it pays the lane's gas floor for an executor
    ///      that serves only the template. Arb recapture on `root` starts only through the timelock, with a `LANE_ON` of
    ///      the copied executor once it serves every registered root, or an `OPEN_LANE` naming such an executor, queued
    ///      after this call; pools opened before that keep no lane, since a pool freezes its executor when it opens.
    /// @param root The root the factory deployed.
    /// @param template The registered root whose admissions and lane the owned root takes.
    /// @param templateRules The template's Rules module whose admission bounds `rules`.
    /// @param rules The owned root's RULES admission: its companion Rules module.
    /// @param copies The template's ADVISORY and GATE implementations to admit on the owned root.
    function registerOwnedRoot(
        address root,
        address template,
        address templateRules,
        IHookrRegistry.Admission calldata rules,
        address[] calldata copies
    ) external;

    /// @notice Whether `opener` may open a new pool on `root` now: `rootOpen(root)`, and for an owned root also its
    ///         factory's `mayOpen(root, opener)`.
    /// @dev The factory is asked with a bounded static call; a revert, a return shorter or longer than one word, any
    ///      word other than 1 or running out of gas reads as closed. For a root that is not owned this equals
    ///      `rootOpen(root)`. A launcher admitted by `SET_LAUNCHER` asks this with its caller before it opens a pool;
    ///      the root itself checks `rootOpen` when a pool initializes.
    /// @param root The root to open a pool on.
    /// @param opener The account opening the pool.
    /// @return Whether the pool may open.
    function rootOpenFor(address root, address opener) external view returns (bool);

    /// @notice Whether `root` was registered by `registerOwnedRoot`.
    /// @param root The root to check.
    /// @return Whether `root` is an owned root.
    function isOwnedRoot(address root) external view returns (bool);

    /// @notice The template an owned root copied, or zero for a root that is not owned.
    /// @param root The root to read.
    /// @return The owned root's template.
    function ownedRootTemplate(address root) external view returns (address);

    /// @notice The root factory that registered an owned root, its IHookrRootRegistrar, or zero for any other root.
    /// @dev The treasury asks it `rulesOf(root)` to know an owned root's companion Rules.
    /// @param root The root to read.
    /// @return The owned root's factory.
    function ownedRegistrarForRoot(address root) external view returns (address);
}
