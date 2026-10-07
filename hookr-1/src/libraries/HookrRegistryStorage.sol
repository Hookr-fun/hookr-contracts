// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IHookrRegistry} from "../interfaces/IHookrRegistry.sol";
import {IHookrExternalHooks} from "../interfaces/IHookrExternalHooks.sol";

/// @title HookrRegistryStorage
/// @notice HookrRegistry's namespaced storage (ERC-7201), shared with its linked libraries, which run in the
///         registry's context through DELEGATECALL.
/// @dev Every namespace is a struct at the slot `cast index-erc7201 <id>` names. A member is only ever appended.
library HookrRegistryStorage {
    /// @dev ERC-7201 slot of `State`: `cast index-erc7201 hookr.registry`.
    bytes32 internal constant SLOT = 0x9a51922757df0ac456dcfdd975bdabe6e420440d7def07553f70853f8394c000;
    /// @dev ERC-7201 slot of `QuoteState`: `cast index-erc7201 hookr.registry.quotes`.
    bytes32 internal constant QUOTE_SLOT = 0x175b0de7591e7bf9ef1d59ff7d4b868a03b040c985a1c2a689968d473c83fb00;
    /// @dev ERC-7201 slot of `Settlement`: `cast index-erc7201 hookr.registry.settlement`.
    bytes32 internal constant SETTLEMENT_SLOT = 0x17be4c484b454c9a7b115dda293e62b52c30147a635aa702a72cdd3caab2bb00;
    /// @dev ERC-7201 slot of `Records`: `cast index-erc7201 hookr.registry.records`.
    bytes32 internal constant RECORDS_SLOT = 0x7f5c8cc56838cf2d2a0d68f7385be07160716d6c7cfc212544a4782db0e94a00;
    /// @dev ERC-7201 slot of `Bonds`: `cast index-erc7201 hookr.registry.bonds`.
    bytes32 internal constant BONDS_SLOT = 0xb13e882696c503e1f17feaf6582171c7d097e5b0f2d86ddc31abc071a62a7500;
    /// @dev ERC-7201 slot of `Owned`: `cast index-erc7201 hookr.registry.owned`.
    bytes32 internal constant OWNED_SLOT = 0xcf353e4bfbb75cd7bdf669507f3959bd29a395597c94d46df1bb706aed054700;

    /// @dev A root's recapture lane for new pools, live while `executor`'s runtime codehash is `codeHash` and its
    ///      switch is on. `closedAt` is the time of the last `closeLaneOf` on the root: an opening queued at or before it
    ///      cannot execute.
    struct Lane {
        address executor;
        uint16 partnerBps;
        uint48 closedAt;
        bytes32 codeHash;
    }

    /// @dev One lane executor's live switch on one root, read by the root on every swap of a pool that froze the
    ///      executor: whether it recaptures and the gas each lane call gets. `gasCap` is nonzero once the executor was
    ///      opened on the root. `brakedAt` is the time of the last brake on it (stopped or its gas lowered): an opening
    ///      or a switch-on queued at or before it cannot execute.
    struct LaneSwitch {
        bool on;
        uint32 gasCap;
        uint48 brakedAt;
    }

    /// @dev The recapture settlement set, in its own namespace: `currencies` lists the members (zero is native ETH),
    ///      `position` is a member's 1-based index in it and `removedAt` the time of the last brake removal of a
    ///      currency, before which a queued addition of it cannot execute.
    /// @custom:storage-location erc7201:hookr.registry.settlement
    struct Settlement {
        address[] currencies;
        mapping(address => uint256) position;
        mapping(address => uint48) removedAt;
    }

    struct RootState {
        bool registered;
        bool active;
        bool frozen;
        bool closed;
        address factory;
    }

    /// @custom:storage-location erc7201:hookr.registry
    struct State {
        address owner;
        address pendingOwner;
        mapping(bytes32 => uint48) readyAt;
        mapping(address => bool) launchers;
        mapping(address => RootState) roots;
        mapping(address => mapping(address => IHookrRegistry.Admission)) admissions;
        address guardian;
        bool newMarketsPaused;
        address[] quotes;
        mapping(address => uint256) quotePosition;
        mapping(address => bytes32) rootFactories;
        mapping(address => mapping(address => bool)) revoked;
        mapping(address => address) rootAdvisories;
        mapping(address => Lane) lanes;
        mapping(address => mapping(address => LaneSwitch)) laneSwitches;
    }

    /// @dev One asset's quote brake: `braked` while `brakeOneQuoteInstantly` holds it, `lastBrakeAt` the time of the
    ///      last one.
    struct QuoteBrake {
        bool braked;
        uint48 lastBrakeAt;
    }

    /// @dev Quote classes, any-quote mode and per-asset brakes, in their own namespace. `classes` lists the admitted
    ///      runtime codehashes, `classPosition` is a class's 1-based index in it (zero: not admitted) and
    ///      `classDroppedAt` the time of the last `dropWholeQuoteClass` on it. `anyQuoteStoppedAt` is the time of the
    ///      last `dismissAnyQuoteNow`.
    /// @custom:storage-location erc7201:hookr.registry.quotes
    struct QuoteState {
        bool anyQuote;
        uint48 anyQuoteStoppedAt;
        bytes32[] classes;
        mapping(bytes32 => uint256) classPosition;
        mapping(bytes32 => uint48) classDroppedAt;
        mapping(address => QuoteBrake) brakes;
    }

    /// @dev The external-hook records, in their own namespace: `hooks` holds each recorded hook's record and
    ///      `delistedAt` the time of the last brake that withdrew a hook's record, before which a queued record of it
    ///      cannot execute.
    /// @custom:storage-location erc7201:hookr.registry.records
    struct Records {
        mapping(address => IHookrExternalHooks.ExternalHook) hooks;
        mapping(address => uint48) delistedAt;
    }

    /// @dev The admission bonds, in their own namespace: `bondOf[scope][implementation]` is the IHookrModuleBond a queued
    ///      `SET_ADMISSION_BOND` attached to that admission for good, zero for none.
    /// @custom:storage-location erc7201:hookr.registry.bonds
    struct Bonds {
        mapping(address => mapping(address => address)) bondOf;
    }

    /// @dev An owned root: the template whose admissions and lane it copied, and the root factory that registered it.
    struct OwnedRoot {
        address template;
        address factory;
    }

    /// @dev The owned roots, in their own namespace: `roots[root]` is set once, by `registerOwnedRoot`, and never cleared.
    /// @custom:storage-location erc7201:hookr.registry.owned
    struct Owned {
        mapping(address => OwnedRoot) roots;
    }

    function state() internal pure returns (State storage s) {
        assembly ("memory-safe") { s.slot := SLOT }
    }

    function quoteState() internal pure returns (QuoteState storage q) {
        assembly ("memory-safe") { q.slot := QUOTE_SLOT }
    }

    function settlement() internal pure returns (Settlement storage t) {
        assembly ("memory-safe") { t.slot := SETTLEMENT_SLOT }
    }

    function records() internal pure returns (Records storage r) {
        assembly ("memory-safe") { r.slot := RECORDS_SLOT }
    }

    function bonds() internal pure returns (Bonds storage b) {
        assembly ("memory-safe") { b.slot := BONDS_SLOT }
    }

    function owned() internal pure returns (Owned storage o) {
        assembly ("memory-safe") { o.slot := OWNED_SLOT }
    }
}
