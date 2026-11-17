// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {HookrDelegation} from "../libraries/HookrDelegation.sol";
import {IHookrGoverned} from "../interfaces/IHookrGoverned.sol";

/// @title HookrGoverned
/// @notice Owner with a disclosed timelock: adding power is queued and delayed; removing power is immediate.
/// @dev Explicit owner (under CREATE3 the constructor's msg.sender is the factory proxy). Ownership cannot be renounced.
///      Operation ids bind chain, contract, kind, the operation's epoch and exact arguments. An epoch is kept per kind,
///      or per kind and subject where a derived contract keys it so. A queued operation expires GRACE after it is ready
///      and may then be queued again. A restrictive action advances the epoch of the operations that would undo it, so
///      every such operation queued before the brake is void and a brake holds for at least one full delay.
///      The owner, a nominee and the accepting account are never an EIP-7702 delegated account.
abstract contract HookrGoverned is IHookrGoverned {
    /// @custom:storage-location erc7201:hookr.governed
    struct Governance {
        address owner;
        address pendingOwner;
        mapping(bytes32 operation => uint48) readyAt;
        mapping(bytes32 kind => uint256) epoch;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("hookr.governed")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant GOVERNED_SLOT = 0x1dd33d6e7c663fca7615dd42387ea79307807dd042d32ccb3b478f696fce9000;

    /// @notice Window after readyAt in which a queued operation may execute.
    uint48 public constant GRACE = 14 days;
    /// @notice Minimum timelock delay.
    uint48 public constant MIN_DELAY = 30 minutes;
    /// @notice Maximum timelock delay.
    uint48 public constant MAX_DELAY = 30 days;
    /// @notice Kind for nominating a new owner.
    bytes32 public constant TRANSFER_OWNER = keccak256("TRANSFER_OWNER");
    /// @inheritdoc IHookrGoverned
    uint48 public immutable delay;

    /// @param owner_ The initial owner (non-zero, not an EIP-7702 delegated account).
    /// @param delay_ The timelock delay, within [MIN_DELAY, MAX_DELAY].
    constructor(address owner_, uint48 delay_) {
        if (owner_ == address(0)) revert InvalidAddress(owner_);
        _refuseDelegated(owner_);
        if (delay_ < MIN_DELAY || delay_ > MAX_DELAY) revert InvalidDelay(delay_);
        delay = delay_;
        _governance().owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    /// @inheritdoc IHookrGoverned
    function owner() public view returns (address) {
        return _governance().owner;
    }

    /// @inheritdoc IHookrGoverned
    function pendingOwner() external view returns (address) {
        return _governance().pendingOwner;
    }

    /// @inheritdoc IHookrGoverned
    function readyAt(bytes32 operation) external view returns (uint48) {
        return _governance().readyAt[operation];
    }

    /// @inheritdoc IHookrGoverned
    function expiresAt(bytes32 operation) external view returns (uint48) {
        uint48 ready = _governance().readyAt[operation];
        return ready == 0 ? 0 : ready + GRACE;
    }

    /// @inheritdoc IHookrGoverned
    function epoch(bytes32 key) external view returns (uint256) {
        return _governance().epoch[key];
    }

    /// @inheritdoc IHookrGoverned
    function operationHash(bytes32 kind, bytes memory arguments) public view returns (bytes32) {
        return keccak256(
            abi.encode(block.chainid, address(this), kind, _governance().epoch[_epochKey(kind, arguments)], arguments)
        );
    }

    /// @inheritdoc IHookrGoverned
    function queue(bytes32 kind, bytes calldata arguments) external onlyOwner returns (bytes32 operation) {
        _checkQueue(kind, arguments);
        operation = operationHash(kind, arguments);
        Governance storage g = _governance();
        uint48 ready = g.readyAt[operation];
        if (ready != 0 && block.timestamp <= uint256(ready) + GRACE) revert AlreadyQueued(operation);
        ready = uint48(block.timestamp) + delay;
        g.readyAt[operation] = ready;
        emit OperationQueued(operation, kind, arguments, ready, ready + GRACE);
    }

    /// @inheritdoc IHookrGoverned
    function cancel(bytes32 operation) external onlyOwner {
        Governance storage g = _governance();
        if (g.readyAt[operation] == 0) revert NotQueued(operation);
        delete g.readyAt[operation];
        emit OperationCancelled(operation);
    }

    /// @inheritdoc IHookrGoverned
    function transferOwnership(address next) external onlyOwner {
        if (next == address(0)) revert InvalidAddress(next);
        _refuseDelegated(next);
        _consume(TRANSFER_OWNER, abi.encode(next));
        _governance().pendingOwner = next;
        emit OwnershipTransferStarted(_governance().owner, next);
    }

    /// @inheritdoc IHookrGoverned
    function cancelNomination() external onlyOwner {
        Governance storage g = _governance();
        address pending = g.pendingOwner;
        g.pendingOwner = address(0);
        emit OwnershipNominationCancelled(pending);
    }

    /// @inheritdoc IHookrGoverned
    function acceptOwnership() external {
        Governance storage g = _governance();
        if (msg.sender != g.pendingOwner || msg.sender == address(0)) revert Unauthorized(msg.sender);
        _refuseDelegated(msg.sender);
        address previous = g.owner;
        g.owner = msg.sender;
        g.pendingOwner = address(0);
        emit OwnershipTransferred(previous, msg.sender);
    }

    /// @dev Queue-time admission of `kind` and its arguments. The default checks TRANSFER_OWNER and accepts every
    ///      other kind; a derived contract that overrides it refuses unknown kinds and non-canonical arguments.
    function _checkQueue(bytes32 kind, bytes calldata arguments) internal view virtual {
        if (kind == TRANSFER_OWNER) {
            address next = abi.decode(arguments, (address));
            if (next == address(0)) revert InvalidAddress(next);
            _refuseDelegated(next);
            _requireCanonical(kind, arguments, abi.encode(next));
        }
    }

    /// @dev Reverts unless `arguments` is exactly `canonical`.
    function _requireCanonical(bytes32 kind, bytes calldata arguments, bytes memory canonical) internal pure {
        if (keccak256(arguments) != keccak256(canonical)) revert NonCanonicalArguments(kind);
    }

    /// @dev Consumes a ready, unexpired operation of the kind's current epoch. NotReady if unqueued (including queued
    ///      in an earlier epoch) or early; Expired if past readyAt + GRACE.
    function _consume(bytes32 kind, bytes memory arguments) internal {
        bytes32 operation = operationHash(kind, arguments);
        Governance storage g = _governance();
        uint48 ready = g.readyAt[operation];
        if (ready == 0 || block.timestamp < ready) revert NotReady(operation, ready);
        if (block.timestamp > uint256(ready) + GRACE) revert Expired(operation, ready + GRACE);
        delete g.readyAt[operation];
        emit OperationExecuted(operation);
    }

    /// @dev The epoch key an operation reads. The default keys by kind; a derived contract may key a kind by
    ///      keccak256(abi.encode(kind, arguments)) so that a brake voids only the operation on its own subject.
    function _epochKey(bytes32 kind, bytes memory) internal view virtual returns (bytes32) {
        return kind;
    }

    /// @dev Called by a restrictive action with the epoch key of the operations that would undo it: every such
    ///      operation queued so far is void, and a new one waits a full delay. The restrictive action's own event marks
    ///      the change.
    function _invalidateQueued(bytes32 key) internal {
        unchecked {
            ++_governance().epoch[key];
        }
    }

    /// @dev Reverts if `account`'s code starts with 0xEF (HookrDelegation.isDelegated): an EIP-7702 delegation
    ///      designator, which its key holder can re-point, or a Stylus program.
    function _refuseDelegated(address account) internal view {
        if (HookrDelegation.isDelegated(account)) revert DelegatedAccount(account);
    }

    /// @dev Reverts unless `account` holds contract code that does not start with 0xEF (see `_refuseDelegated`).
    function _requireDeployedCode(address account) internal view {
        if (account.code.length == 0) revert NotAContract(account);
        if (HookrDelegation.isDelegated(account)) revert DelegatedAccount(account);
    }

    /// @dev Current owner, for derived contracts.
    function _owner() internal view returns (address) {
        return _governance().owner;
    }

    function _onlyOwner() internal view {
        if (msg.sender != _governance().owner) revert Unauthorized(msg.sender);
    }

    function _governance() private pure returns (Governance storage g) {
        assembly ("memory-safe") {
            g.slot := GOVERNED_SLOT
        }
    }
}
