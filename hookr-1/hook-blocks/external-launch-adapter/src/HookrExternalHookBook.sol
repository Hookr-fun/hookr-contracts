// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHookrRegistry} from "hookr/interfaces/IHookrRegistry.sol";
import {HookrReleased} from "hookr/base/HookrReleased.sol";
import {IHookrLaunchAdapter} from "./interfaces/IHookrLaunchAdapter.sol";
import {
    ExternalHookRecord,
    ExternalHookTypes,
    AdapterAdmission,
    IHookrExternalHookBook,
    IHookrLaunchAdapterBound
} from "./interfaces/IHookrExternalHooks.sol";

/// @title HookrExternalHookBook
/// @notice The launch records for hooks Hookr did not write, beside the Hookr 1 `HookrRegistry`: one current
///         `ExternalHookRecord` per hook, an append-only history, and launch-adapter admissions by code hash.
/// @dev The Hookr 1 `HookrRegistry` records external hooks only for discovery and attribution
///      (`IHookrExternalHooks`: LISTED or CUSTODY_ROOT, pinned to a codehash, never a launch gate) and has no launch
///      record or adapter admission, so this sidecar carries the drafted launch surface with the registry's
///      discipline: every permissive change (a record, an adapter admission, a guardian, an owner, a
///      resumption) is a queued operation whose kind and exact ABI arguments are published, checked against chain
///      state when queued and again when executed, executable only between `readyAt` and `readyAt + GRACE_PERIOD`,
///      and consumed once. The untimelocked powers only restrict new launches: retiring a record, revoking an
///      adapter and pausing the lane. None of them reaches a swap, a liquidity exit, a fee or a balance: the book is
///      read at open, never during a swap. Design rules enforced here, in order:
///      a record names the hook's live code hash and its real permission bits; LISTED records carry no
///      adapter; LAUNCHABLE needs an active adapter admitted for the same protocol, no UPGRADEABLE bit, the
///      IGNORES_HOOKDATA bit (the launcher sends empty hookData on every call it makes), exactly one seed path, and a
///      LISTED (or LAUNCHABLE) record for the same code hash already in force (LISTED ships first); an OWNER_INIT
///      record names its adapter as owner of record. A Hookr root
///      registered in the Hookr registry, a `HookrRoot` or a factory-registered `HookrPairRoot`, is never an
///      external hook.
///      The owner discipline is the Hookr 1 registry's: the fixed 30-minute owner timelock, no EIP-7702 delegated
///      owner, nominee or guardian, and an owner that can remove the guardian or withdraw an unaccepted nomination at
///      once. Cancelling a queued operation stays the owner's here, where the Hookr 1 registry also lets its
///      guardian cancel; this guardian's stops void the queued writes they would undo.
///      A stop cannot be undone by a write queued before it: every retirement and every pause takes a new stop
///      number, every queued operation remembers the stop number current when it was queued, and a record write for
///      a retired hook, or a resumption, that was queued before that hook's latest retirement (or the latest pause)
///      refuses to execute. The owner cancels it and queues it again, which restarts the full delay.
contract HookrExternalHookBook is HookrReleased, IHookrExternalHookBook {
    bytes32 public constant RECORD_EXTERNAL_HOOK = keccak256("RECORD_EXTERNAL_HOOK");
    bytes32 public constant ADMIT_ADAPTER = keccak256("ADMIT_ADAPTER");
    bytes32 public constant SET_GUARDIAN = keccak256("SET_GUARDIAN");
    bytes32 public constant TRANSFER_OWNER = keccak256("TRANSFER_OWNER");
    bytes32 public constant RESUME_LAUNCHES = keccak256("RESUME_LAUNCHES");
    /// @notice The owner timelock on every permissive operation: fixed at 30 minutes, as everywhere in Hookr 1
    uint48 public constant DELAY = 30 minutes;
    /// @notice A matured operation expires this long after `readyAt`; it must then be queued again.
    uint48 public constant GRACE_PERIOD = 14 days;

    /// @notice The Hookr registry, read to refuse registered Hookr roots (factory pair roots included) as external hooks
    IHookrRegistry public immutable hookrRegistry;

    address public owner;
    address public pendingOwner;
    /// @notice May retire records, revoke adapters and pause launches besides the owner. Zero means none.
    address public guardian;
    /// @inheritdoc IHookrExternalHookBook
    bool public launchesPaused;
    mapping(bytes32 operation => uint48) public readyAt;
    /// @notice The stop number current when `operation` was queued
    mapping(bytes32 operation => uint64) public queuedAtStop;
    /// @notice The stop number of `hook`'s latest retirement; zero if never retired
    mapping(address hook => uint64) public retiredAtStop;
    /// @notice The stop number of the latest `pauseLaunches` call; zero if never paused
    uint64 public pausedAtStop;
    /// @notice The number of stops (retirements and pauses) so far
    uint64 public stops;
    mapping(address hook => ExternalHookRecord) private _current;
    mapping(address adapter => AdapterAdmission) private _adapters;
    ExternalHookRecord[] private _history;

    error Unauthorized();
    error InvalidAddress();
    error AlreadyQueued(bytes32 operation);
    error NotQueued(bytes32 operation);
    error NotReady(bytes32 operation);
    error OperationExpired(bytes32 operation, uint48 expiredAt);
    error UnknownOperation(bytes32 kind);
    error NonCanonicalArguments(bytes32 kind);
    error NotAContract(address account);
    error DelegatedAccount(address account);
    /// @param reason A short code naming the rule the record breaks
    error InvalidRecord(bytes32 reason);
    /// @param reason A short code naming the rule the admission breaks
    error InvalidAdapter(bytes32 reason);
    error NotRetirable(address hook);
    error NotPaused();
    /// @notice The operation was queued before a retirement or pause it would undo; cancel and queue it again
    error QueuedBeforeStop(bytes32 operation);

    event OperationQueued(
        bytes32 indexed operation, bytes32 indexed kind, bytes arguments, uint48 readyAt, uint48 expiresAt
    );
    event OperationCancelled(bytes32 indexed operation);
    event OperationExecuted(bytes32 indexed operation);
    /// @notice Emitted on every record write, including a retirement; the draft registry's event
    event ExternalHookRecorded(address indexed hook, bytes32 indexed initProtocolId, uint8 listingStatus);
    /// @notice The full record behind `ExternalHookRecorded`, for indexers that list and attribute the hook
    event ExternalHookRecordWritten(uint256 indexed historyIndex, ExternalHookRecord record);
    event AdapterAdmitted(address indexed adapter, bytes32 indexed initProtocolId, bytes32 codeHash);
    event AdapterRevoked(address indexed adapter, address indexed by);
    event LaunchesPaused(address indexed by);
    event LaunchesResumed(address indexed by);
    event GuardianSet(address indexed previousGuardian, address indexed newGuardian);
    event OwnershipTransferStarted(address indexed owner, address indexed nominee);
    event OwnershipTransferCancelled(address indexed owner, address indexed nominee);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @param _owner The administrator; every permissive action it takes waits `DELAY`. Not EIP-7702 delegated.
    /// @param _hookrRegistry The Hookr registry
    constructor(address _owner, IHookrRegistry _hookrRegistry) {
        if (_owner == address(0) || address(_hookrRegistry).code.length == 0) revert InvalidAddress();
        _requireUndelegated(_owner);
        owner = _owner;
        hookrRegistry = _hookrRegistry;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyOwnerOrGuardian() {
        if (msg.sender != owner && (msg.sender != guardian || guardian == address(0))) revert Unauthorized();
        _;
    }

    /// @notice The timelock applied to every permissive operation, `DELAY`; the getter every Hookr 1 governed
    ///         contract answers
    function delay() external pure returns (uint48) {
        return DELAY;
    }

    /// @inheritdoc IHookrExternalHookBook
    function externalHook(address hook) external view returns (ExternalHookRecord memory) {
        return _current[hook];
    }

    /// @inheritdoc IHookrExternalHookBook
    function adapterAdmission(address adapter) external view returns (AdapterAdmission memory) {
        return _adapters[adapter];
    }

    /// @notice Number of record writes ever made, retirements included
    function historyLength() external view returns (uint256) {
        return _history.length;
    }

    /// @notice The record written at position `index` of the append-only history
    function historyAt(uint256 index) external view returns (ExternalHookRecord memory) {
        return _history[index];
    }

    /// @notice The last timestamp at which a queued operation can execute. Zero means it is not queued.
    function expiresAt(bytes32 operation) external view returns (uint48) {
        uint48 eta = readyAt[operation];
        return eta == 0 ? 0 : eta + GRACE_PERIOD;
    }

    /// @notice Commits an operation to this chain, this book, an action kind and its ABI arguments
    function operationHash(bytes32 kind, bytes memory arguments) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), kind, arguments));
    }

    /// @notice Queues and publishes an exact operation for execution after the delay
    /// @dev The arguments must be the canonical ABI encoding the executing function re-derives, and they are
    ///      checked against current chain state. An expired operation may be queued again.
    function queue(bytes32 kind, bytes calldata arguments) external onlyOwner returns (bytes32 operation) {
        _checkQueued(kind, arguments);
        operation = operationHash(kind, arguments);
        uint48 eta = readyAt[operation];
        if (eta != 0 && block.timestamp <= uint256(eta) + GRACE_PERIOD) revert AlreadyQueued(operation);
        eta = uint48(block.timestamp) + DELAY;
        readyAt[operation] = eta;
        queuedAtStop[operation] = stops;
        emit OperationQueued(operation, kind, arguments, eta, eta + GRACE_PERIOD);
    }

    /// @notice Cancels a queued operation
    function cancel(bytes32 operation) external onlyOwner {
        if (readyAt[operation] == 0) revert NotQueued(operation);
        delete readyAt[operation];
        delete queuedAtStop[operation];
        emit OperationCancelled(operation);
    }

    /// @notice Executes a queued record write: a LISTED or LAUNCHABLE record for one hook
    /// @dev Refused if it was queued before the hook's latest retirement.
    function recordExternalHook(ExternalHookRecord calldata record) external onlyOwner {
        _checkRecord(record);
        bytes memory arguments = abi.encode(record);
        _requireQueuedAfter(operationHash(RECORD_EXTERNAL_HOOK, arguments), retiredAtStop[record.hook]);
        _consume(RECORD_EXTERNAL_HOOK, arguments);
        _write(record);
    }

    /// @notice Executes a queued adapter admission, pinned to the adapter's code hash and protocol
    function admitAdapter(address adapter, bytes32 codeHash, bytes32 initProtocolId) external onlyOwner {
        _checkAdapter(adapter, codeHash, initProtocolId);
        _consume(ADMIT_ADAPTER, abi.encode(adapter, codeHash, initProtocolId));
        _adapters[adapter] = AdapterAdmission(codeHash, initProtocolId, true);
        emit AdapterAdmitted(adapter, initProtocolId, codeHash);
    }

    /// @notice Executes a queued guardian appointment. Zero removes the guardian.
    /// @dev An EIP-7702 delegated guardian is refused, when queued and when executed.
    function setGuardian(address nextGuardian) external onlyOwner {
        _requireUndelegated(nextGuardian);
        _consume(SET_GUARDIAN, abi.encode(nextGuardian));
        emit GuardianSet(guardian, nextGuardian);
        guardian = nextGuardian;
    }

    /// @notice Removes the guardian, effective at once
    /// @dev It only removes authority: the guardian's powers are the stops, which the owner also holds. Appointing
    ///      a guardian stays a timelocked `SET_GUARDIAN` operation. Does nothing when no guardian is set.
    function removeGuardian() external onlyOwner {
        address previous = guardian;
        if (previous != address(0)) {
            guardian = address(0);
            emit GuardianSet(previous, address(0));
        }
    }

    /// @notice Executes a queued owner nomination. The nominee must accept.
    /// @dev An EIP-7702 delegated nominee is refused, when queued, when executed and when accepting.
    function transferOwnership(address nextOwner) external onlyOwner {
        if (nextOwner == address(0)) revert InvalidAddress();
        _requireUndelegated(nextOwner);
        _consume(TRANSFER_OWNER, abi.encode(nextOwner));
        pendingOwner = nextOwner;
        emit OwnershipTransferStarted(owner, nextOwner);
    }

    /// @notice Withdraws an unaccepted nomination at once. It only removes authority.
    function cancelOwnershipTransfer() external onlyOwner {
        address nominee = pendingOwner;
        if (nominee == address(0)) revert InvalidAddress();
        pendingOwner = address(0);
        emit OwnershipTransferCancelled(owner, nominee);
    }

    /// @notice Accepts the pending ownership nomination
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert Unauthorized();
        _requireUndelegated(msg.sender);
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    /// @notice Executes a queued resumption of external launches. It can only be queued while paused.
    /// @dev Refused if it was queued before the latest `pauseLaunches` call.
    function resumeLaunches() external onlyOwner {
        if (!launchesPaused) revert NotPaused();
        _requireQueuedAfter(operationHash(RESUME_LAUNCHES, ""), pausedAtStop);
        _consume(RESUME_LAUNCHES, "");
        launchesPaused = false;
        emit LaunchesResumed(msg.sender);
    }

    /// @notice Retires a hook's current record at once: no new launch can open on it
    /// @dev Writes a new record, a copy of the current one with status RETIRED, so the history keeps both.
    ///      Pools already open on the hook are untouched; the book is never read during a swap. Every record write
    ///      for this hook queued before now is void (`QueuedBeforeStop`).
    function retireExternalHook(address hook) external onlyOwnerOrGuardian {
        ExternalHookRecord memory r = _current[hook];
        if (r.listingStatus != ExternalHookTypes.LISTED && r.listingStatus != ExternalHookTypes.LAUNCHABLE) {
            revert NotRetirable(hook);
        }
        retiredAtStop[hook] = ++stops;
        r.listingStatus = ExternalHookTypes.RETIRED;
        _write(r);
    }

    /// @notice Revokes an adapter at once; every record naming it stops launching
    /// @dev A revoked address can never be re-admitted; a fixed adapter is a new deployment.
    function revokeAdapter(address adapter) external onlyOwnerOrGuardian {
        if (!_adapters[adapter].active) revert InvalidAdapter("NOT_ACTIVE");
        _adapters[adapter].active = false;
        emit AdapterRevoked(adapter, msg.sender);
    }

    /// @notice Stops every new external launch at once. Resuming is timelocked.
    /// @dev Also callable while paused: each call voids any resumption queued before it (`QueuedBeforeStop`).
    function pauseLaunches() external onlyOwnerOrGuardian {
        pausedAtStop = ++stops;
        launchesPaused = true;
        emit LaunchesPaused(msg.sender);
    }

    function _write(ExternalHookRecord memory r) private {
        _current[r.hook] = r;
        _history.push(r);
        emit ExternalHookRecorded(r.hook, r.initProtocolId, r.listingStatus);
        emit ExternalHookRecordWritten(_history.length - 1, r);
    }

    function _checkQueued(bytes32 kind, bytes calldata arguments) private view {
        bytes memory canonical;
        if (kind == RECORD_EXTERNAL_HOOK) {
            ExternalHookRecord memory r = abi.decode(arguments, (ExternalHookRecord));
            _checkRecord(r);
            canonical = abi.encode(r);
        } else if (kind == ADMIT_ADAPTER) {
            (address adapter, bytes32 codeHash, bytes32 protocol) = abi.decode(arguments, (address, bytes32, bytes32));
            _checkAdapter(adapter, codeHash, protocol);
            canonical = abi.encode(adapter, codeHash, protocol);
        } else if (kind == SET_GUARDIAN) {
            address nextGuardian = abi.decode(arguments, (address));
            _requireUndelegated(nextGuardian);
            canonical = abi.encode(nextGuardian);
        } else if (kind == TRANSFER_OWNER) {
            address nextOwner = abi.decode(arguments, (address));
            if (nextOwner == address(0)) revert InvalidAddress();
            _requireUndelegated(nextOwner);
            canonical = abi.encode(nextOwner);
        } else if (kind == RESUME_LAUNCHES) {
            if (!launchesPaused) revert NotPaused();
        } else {
            revert UnknownOperation(kind);
        }
        if (keccak256(arguments) != keccak256(canonical)) revert NonCanonicalArguments(kind);
    }

    /// @dev The record rules. Checked when queued and again when executed, against the chain at each moment.
    function _checkRecord(ExternalHookRecord memory r) private view {
        uint32 caps = r.capabilities;
        if (r.listingStatus != ExternalHookTypes.LISTED && r.listingStatus != ExternalHookTypes.LAUNCHABLE) {
            revert InvalidRecord("STATUS");
        }
        if (r.initProtocolId == bytes32(0)) revert InvalidRecord("PROTOCOL");
        if (caps & ~ExternalHookTypes.KNOWN != 0) revert InvalidRecord("UNKNOWN_BIT");
        if (_has(caps, ExternalHookTypes.IGNORES_HOOKDATA) && _has(caps, ExternalHookTypes.READS_HOOKDATA)) {
            revert InvalidRecord("HOOKDATA_BITS");
        }
        if (_has(caps, ExternalHookTypes.ALLOWS_EXTERNAL_LP) && _has(caps, ExternalHookTypes.HOOK_OWNED_LP)) {
            revert InvalidRecord("LP_BITS");
        }
        if (r.initProtocolId == ExternalHookTypes.HOOKLESS) {
            // A hookless key cannot carry a dynamic fee (Hooks.isValidHookAddress) and has no code or owner.
            if (
                r.hook != address(0) || r.codeHash != bytes32(0) || r.permissionBits != 0
                    || !_has(caps, ExternalHookTypes.STATIC_FEE_ONLY) || _has(caps, ExternalHookTypes.OWNER_INIT)
                    || _has(caps, ExternalHookTypes.HOOK_OWNED_LP) || _has(caps, ExternalHookTypes.UPGRADEABLE)
                    || r.ownerOfRecord != address(0)
            ) revert InvalidRecord("HOOKLESS");
        } else {
            if (r.hook == address(0)) revert InvalidRecord("HOOK");
            _requireContract(r.hook);
            if (r.codeHash != r.hook.codehash) revert InvalidRecord("CODE_HASH");
            if (r.permissionBits != uint160(r.hook) & Hooks.ALL_HOOK_MASK) revert InvalidRecord("PERMISSION_BITS");
            if (hookrRegistry.isRoot(r.hook) || r.hook == address(this)) revert InvalidRecord("HOOKR_ROOT");
        }
        if (_has(caps, ExternalHookTypes.OWNER_INIT) && r.ownerOfRecord == address(0)) revert InvalidRecord("OWNER");
        if (r.listingStatus == ExternalHookTypes.LISTED) {
            if (r.launchAdapter != address(0)) revert InvalidRecord("LISTED_ADAPTER");
            return;
        }
        // LAUNCHABLE
        if (_has(caps, ExternalHookTypes.UPGRADEABLE)) revert InvalidRecord("UPGRADEABLE");
        // The launcher passes empty hookData to every add, buy, fee collection and exit it makes; a hook that needs
        // hookData could refuse the founding position's exits and freeze its principal and fees.
        if (!_has(caps, ExternalHookTypes.IGNORES_HOOKDATA)) revert InvalidRecord("HOOKDATA_NOT_IGNORED");
        if (!_has(caps, ExternalHookTypes.ALLOWS_EXTERNAL_LP) && !_has(caps, ExternalHookTypes.HOOK_OWNED_LP)) {
            revert InvalidRecord("NO_SEED_PATH");
        }
        AdapterAdmission memory a = _adapters[r.launchAdapter];
        if (
            r.launchAdapter == address(0) || !a.active || a.initProtocolId != r.initProtocolId
                || r.launchAdapter.codehash != a.codeHash
                || IHookrLaunchAdapter(r.launchAdapter).initProtocolId() != r.initProtocolId
        ) revert InvalidRecord("ADAPTER");
        // Owner-only entries are called by the adapter, so the adapter is the owner of record.
        if (_has(caps, ExternalHookTypes.OWNER_INIT) && r.ownerOfRecord != r.launchAdapter) {
            revert InvalidRecord("OWNER_NOT_ADAPTER");
        }
        // Owner decision 1: a LISTED record for this exact code precedes any LAUNCHABLE record.
        ExternalHookRecord storage cur = _current[r.hook];
        if (
            (cur.listingStatus != ExternalHookTypes.LISTED && cur.listingStatus != ExternalHookTypes.LAUNCHABLE)
                || cur.codeHash != r.codeHash || cur.initProtocolId != r.initProtocolId
        ) revert InvalidRecord("NOT_LISTED_FIRST");
    }

    function _checkAdapter(address adapter, bytes32 codeHash, bytes32 protocol) private view {
        _requireContract(adapter);
        AdapterAdmission memory a = _adapters[adapter];
        if (a.codeHash != bytes32(0)) revert InvalidAdapter("KNOWN");
        if (adapter.codehash != codeHash) revert InvalidAdapter("CODE_HASH");
        if (protocol == bytes32(0) || IHookrLaunchAdapter(adapter).initProtocolId() != protocol) {
            revert InvalidAdapter("PROTOCOL");
        }
        address bound = IHookrLaunchAdapterBound(adapter).launcher();
        if (bound == address(0) || bound.code.length == 0) revert InvalidAdapter("LAUNCHER");
    }

    function _has(uint32 caps, uint32 bit) private pure returns (bool) {
        return caps & bit != 0;
    }

    /// @dev Refuses an account without code and an EIP-7702 delegation designator (0xef0100 || target), whose key
    ///      holder could re-point it after admission.
    function _requireContract(address account) private view {
        uint256 size;
        bool delegated;
        assembly ("memory-safe") {
            size := extcodesize(account)
            if size {
                let free := mload(0x40)
                extcodecopy(account, free, 0, 1)
                delegated := eq(byte(0, mload(free)), 0xef)
            }
        }
        if (size == 0) revert NotAContract(account);
        if (delegated) revert DelegatedAccount(account);
    }

    /// @dev Refuses an account whose code is an EIP-7702 delegation designator (0xef0100 || target). Accounts
    ///      without code and ordinary contracts pass.
    function _requireUndelegated(address account) private view {
        bool delegated;
        assembly ("memory-safe") {
            if eq(extcodesize(account), 23) {
                extcodecopy(account, 0, 0, 3)
                delegated := eq(shr(232, mload(0)), 0xef0100)
            }
        }
        if (delegated) revert DelegatedAccount(account);
    }

    function _consume(bytes32 kind, bytes memory arguments) private {
        bytes32 operation = operationHash(kind, arguments);
        uint48 eta = readyAt[operation];
        if (eta == 0 || block.timestamp < eta) revert NotReady(operation);
        if (block.timestamp > uint256(eta) + GRACE_PERIOD) revert OperationExpired(operation, eta + GRACE_PERIOD);
        delete readyAt[operation];
        delete queuedAtStop[operation];
        emit OperationExecuted(operation);
    }

    /// @dev A queued operation that would undo stop number `stopAt` must have been queued at or after it.
    function _requireQueuedAfter(bytes32 operation, uint64 stopAt) private view {
        if (readyAt[operation] != 0 && queuedAtStop[operation] < stopAt) revert QueuedBeforeStop(operation);
    }
}
