// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IHookrGoverned
/// @notice Interface for HookrGoverned, the owner with a disclosed timelock that HookrCompliance, HookrPaymaster,
///         HookrFeeAdvisory, HookrSessionAdvisory, HookrLiquidityVault and HookrLpBoost inherit: adding power is
///         queued and delayed; removing power is immediate.
interface IHookrGoverned {
    /// @notice `caller` may not do this.
    error Unauthorized(address caller);
    /// @notice `account` is zero or one the call cannot use.
    error InvalidAddress(address account);
    /// @notice `delay` is outside the bounds the owner's timelock allows.
    error InvalidDelay(uint48 delay);
    /// @notice `operation` is already queued and has not expired.
    error AlreadyQueued(bytes32 operation);
    /// @notice `operation` is not queued.
    error NotQueued(bytes32 operation);
    /// @notice `operation` becomes executable at `readyAt`.
    error NotReady(bytes32 operation, uint48 readyAt);
    /// @notice `operation` could be executed until `expiredAt` and no longer can be.
    error Expired(bytes32 operation, uint48 expiredAt);
    /// @notice `kind` is not an operation kind this contract queues.
    error UnknownOperation(bytes32 kind);
    /// @notice The arguments are not the canonical encoding the `kind` operation re-derives.
    error NonCanonicalArguments(bytes32 kind);
    /// @notice `account` holds no code.
    error NotAContract(address account);
    /// @notice `account` is an EIP-7702 delegation, not contract code.
    error DelegatedAccount(address account);

    /// @notice An operation was queued.
    /// @param operation The operation's id.
    /// @param kind The operation kind.
    /// @param arguments The operation's arguments, disclosed here.
    /// @param readyAt The timestamp from which it can execute.
    /// @param expiresAt The last timestamp at which it can execute.
    event OperationQueued(
        bytes32 indexed operation, bytes32 indexed kind, bytes arguments, uint48 readyAt, uint48 expiresAt
    );
    /// @notice A queued operation was cancelled.
    /// @param operation The operation's id.
    event OperationCancelled(bytes32 indexed operation);
    /// @notice A queued operation executed.
    /// @param operation The operation's id.
    event OperationExecuted(bytes32 indexed operation);
    /// @notice An owner was nominated.
    /// @param owner The current owner.
    /// @param pendingOwner The nominee.
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    /// @notice A nomination was withdrawn.
    /// @param pendingOwner The withdrawn nominee.
    event OwnershipNominationCancelled(address indexed pendingOwner);
    /// @notice The nominee accepted ownership.
    /// @param previousOwner The former owner.
    /// @param newOwner The new owner.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice The timelock delay, fixed at deployment.
    /// @return The delay in seconds.
    function delay() external view returns (uint48);

    /// @notice The current owner.
    /// @return The owner.
    function owner() external view returns (address);

    /// @notice The nominated owner, if any.
    /// @return The nominee, or zero.
    function pendingOwner() external view returns (address);

    /// @notice When `operation` becomes executable (0 if not queued).
    /// @param operation The operation's id.
    /// @return The timestamp from which it can execute, or zero.
    function readyAt(bytes32 operation) external view returns (uint48);

    /// @notice The last time `operation` may execute (0 if not queued).
    /// @param operation The operation's id.
    /// @return The last timestamp at which it can execute, or zero.
    function expiresAt(bytes32 operation) external view returns (uint48);

    /// @notice The current epoch under `key`: a kind, or keccak256(abi.encode(kind, arguments)) for a kind keyed by
    ///         subject. A restrictive action advances it.
    /// @param key The kind, or the hash of the kind and its subject arguments.
    /// @return The epoch under the key.
    function epoch(bytes32 key) external view returns (uint256);

    /// @notice The id of an operation of `kind` with exact `arguments` on this contract and chain, in the operation's
    ///         current epoch.
    /// @param kind The operation kind.
    /// @param arguments The operation's arguments.
    /// @return The operation's id.
    function operationHash(bytes32 kind, bytes memory arguments) external view returns (bytes32);

    /// @notice Queues an operation; the arguments are disclosed in the event. An expired operation may be queued again.
    /// @param kind The operation kind.
    /// @param arguments The operation's canonical ABI arguments.
    /// @return operation The operation's id.
    function queue(bytes32 kind, bytes calldata arguments) external returns (bytes32 operation);

    /// @notice Cancels a queued operation.
    /// @param operation The operation's id.
    function cancel(bytes32 operation) external;

    /// @notice Nominates `next`; consumes a queued TRANSFER_OWNER(next).
    /// @param next The nominee.
    function transferOwnership(address next) external;

    /// @notice Cancels the current nomination immediately.
    function cancelNomination() external;

    /// @notice The nominee accepts ownership. A nominee that has since become a delegated account cannot accept.
    function acceptOwnership() external;
}
