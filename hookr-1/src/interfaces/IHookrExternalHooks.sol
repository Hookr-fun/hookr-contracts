// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IHookrExternalHooks
/// @notice The registry's record of a Uniswap v4 hook that is not a Hookr root: a hook listed for discovery and
///         attribution (LISTED), or a custody hook that holds its pools' liquidity positions itself and binds no Hookr
///         Rules (CUSTODY_ROOT). Each record is pinned to the runtime codehash the hook held when it was recorded and
///         names an optional bond reference. A record is the queued operation `RECORD_EXTERNAL_HOOK`
///         (`keccak256("RECORD_EXTERNAL_HOOK")`, arguments `abi.encode(address hook, uint8 kind, bytes32 codeHash,
///         address bondRef)`), checked when queued and again when executed with `setExternalHook`; the brake
///         `dropSingleExternalHookRecordNow` (owner or guardian) withdraws one at once.
/// @dev Day-one consumers: a leverage hook recorded as LISTED and a custody hook recorded as CUSTODY_ROOT, for
///      discovery and attribution in the app and indexers. Invariants: a record
///      never makes a hook a root or grants it an admission, so `isRoot` stays false and the router, the quoter and
///      every Rules module keep refusing the hook's pools, and no scope's admissions change; a registered root is
///      never recorded, and a recorded hook is never registered by a queued `REGISTER_ROOT`; the codehash matches when
///      the record is queued and when it executes, and `findExternalHookWithCodeCheck` reports any later drift; a brake
///      holds until a record queued after it executes; the registry stores `bondRef` and never calls it. A record is
///      inert until a queued `RECORD_EXTERNAL_HOOK` executes: until then the registry reports none for the hook.
interface IHookrExternalHooks {
    /// @notice What a record says a hook is. NONE: no record.
    enum HookKind {
        NONE,
        LISTED,
        CUSTODY_ROOT
    }

    /// @notice A recorded hook: its kind, its bond reference (zero for none) and the runtime codehash it held when the
    ///         record executed.
    struct ExternalHook {
        /// @notice What the record says the hook is.
        HookKind kind;
        /// @notice The bond reference the record names, or zero.
        address bondRef;
        /// @notice The runtime codehash the hook held when the record executed.
        bytes32 codeHash;
    }

    /// @notice The record names kind NONE, or a hook that is a registered root.
    error InvalidRecord();

    /// @notice A queued `RECORD_EXTERNAL_HOOK` recorded `hook`, replacing any earlier record of it.
    /// @param hook The recorded hook.
    /// @param kind What the hook is recorded as.
    /// @param codeHash The runtime codehash the record pins.
    /// @param bondRef The bond reference the record names, or zero.
    event ExternalHookRecorded(address indexed hook, HookKind kind, bytes32 codeHash, address indexed bondRef);

    /// @notice A brake withdrew `hook`'s record, and every record of it queued until now.
    /// @param hook The hook whose record was withdrawn.
    /// @param by The owner or guardian that withdrew it.
    event ExternalHookDelisted(address indexed hook, address indexed by);

    /// @notice Executes a queued `RECORD_EXTERNAL_HOOK`: `hook` is recorded as `kind`, pinned to `codeHash`, with the
    ///         bond reference `bondRef`. A later record of the same hook replaces it.
    /// @dev Owner only. Checked when queued and again when executed: `hook` holds code that is not an EIP-7702
    ///      delegation, its runtime codehash is `codeHash` and it is not a registered root; `kind` is LISTED or
    ///      CUSTODY_ROOT; `bondRef` is zero or holds code that is not an EIP-7702 delegation. It executes only if it was
    ///      queued after the hook's last `dropSingleExternalHookRecordNow`.
    /// @param hook The hook to record.
    /// @param kind What the hook is.
    /// @param codeHash The hook's runtime codehash.
    /// @param bondRef The hook's bond reference, or zero.
    function setExternalHook(address hook, HookKind kind, bytes32 codeHash, address bondRef) external;

    /// @notice Brake: withdraws `hook`'s record at once, and refuses every record of it queued until now.
    /// @dev Callable by the owner or the guardian, also for a hook with no record, to pre-empt a queued one. Only a
    ///      `RECORD_EXTERNAL_HOOK` queued after this call records the hook again.
    /// @param hook The hook whose record to withdraw.
    function dropSingleExternalHookRecordNow(address hook) external;

    /// @notice Returns `hook`'s record and whether its runtime codehash is still the one recorded: an empty record
    ///         (kind NONE) and false for a hook without one.
    /// @param hook The hook to read.
    /// @return record The hook's record.
    /// @return codeHashMatches Whether the hook's runtime codehash is the recorded one.
    function findExternalHookWithCodeCheck(address hook)
        external
        view
        returns (ExternalHook memory record, bool codeHashMatches);
}
