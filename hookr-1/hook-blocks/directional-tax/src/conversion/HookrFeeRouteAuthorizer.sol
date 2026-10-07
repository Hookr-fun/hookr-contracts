// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {HookrGoverned} from "hookr/base/HookrGoverned.sol";

/// @title HookrFeeRouteAuthorizer
/// @notice Paused-by-default ERC-1271 signer boundary for tax conversions, a Hookr 1 port of the V2-lineage
///         `HookrFeeRouteAuthorizerV1`, governed like every Hookr 1 contract: powers that let conversions run
///         (unpausing, nominating a signer) wait the owner timelock; pausing is immediate.
/// @dev Neither the owner nor the signer can change a queue's route, output asset, recipients or accrued balances,
///      and neither is ever consulted during a swap: pausing stops conversion, never accrual. Pausing voids every
///      UNPAUSE queued before it, so a pause holds for at least one full delay. The owner, a nominee and the
///      accepting account are never an EIP-7702 delegated account.
contract HookrFeeRouteAuthorizer is HookrGoverned, IERC1271 {
    bytes4 internal constant INVALID_SIGNATURE = 0xffffffff;
    /// @notice Kind for resuming conversions. Arguments: empty.
    bytes32 public constant UNPAUSE = keccak256("UNPAUSE");
    /// @notice Kind for nominating a signer. Arguments: `abi.encode(nextSigner)`.
    bytes32 public constant SET_SIGNER = keccak256("SET_SIGNER");

    address public signer;
    address public pendingSigner;
    bool public paused = true;

    event SignerProposed(address indexed pendingSigner);
    event SignerSet(address indexed signer);
    event PauseSet(bool paused);

    error NotPendingSigner();
    error InvalidSigner(address signer);
    error AlreadySet();

    /// @param owner_ May pause at once, and unpause or nominate a signer after the timelock.
    /// @param delay_ The owner timelock, within `HookrGoverned`'s bounds.
    /// @param signer_ The key whose EIP-712 signatures authorise conversions while unpaused.
    constructor(address owner_, uint48 delay_, address signer_) HookrGoverned(owner_, delay_) {
        if (signer_ == address(0)) revert InvalidSigner(signer_);
        signer = signer_;
        emit SignerSet(signer_);
        emit PauseSet(true);
    }

    /// @notice ERC-1271: valid only while unpaused and only for the current signer's ECDSA signature.
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        if (paused) return INVALID_SIGNATURE;
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        if (err != ECDSA.RecoverError.NoError || recovered != signer) return INVALID_SIGNATURE;
        return IERC1271.isValidSignature.selector;
    }

    /// @notice Pauses conversions at once, voiding every UNPAUSE queued before, or resumes them by consuming a queued
    ///         UNPAUSE.
    function setPaused(bool paused_) external onlyOwner {
        if (paused == paused_) revert AlreadySet();
        if (paused_) _invalidateQueued(UNPAUSE);
        else _consume(UNPAUSE, "");
        paused = paused_;
        emit PauseSet(paused_);
    }

    /// @notice Nominates a new signer, who must accept from its own key. Consumes a queued SET_SIGNER(nextSigner).
    function proposeSigner(address nextSigner) external onlyOwner {
        if (nextSigner == address(0) || nextSigner == signer) revert InvalidSigner(nextSigner);
        _consume(SET_SIGNER, abi.encode(nextSigner));
        pendingSigner = nextSigner;
        emit SignerProposed(nextSigner);
    }

    /// @notice Withdraws a signer nomination at once, including one a previous owner made.
    function cancelSignerNomination() external onlyOwner {
        pendingSigner = address(0);
        emit SignerProposed(address(0));
    }

    /// @notice Accepts a signer nomination.
    function acceptSigner() external {
        if (msg.sender != pendingSigner) revert NotPendingSigner();
        signer = msg.sender;
        pendingSigner = address(0);
        emit SignerSet(msg.sender);
    }

    /// @dev Only UNPAUSE, SET_SIGNER and TRANSFER_OWNER may be queued, with canonical arguments.
    function _checkQueue(bytes32 kind, bytes calldata arguments) internal view override {
        if (kind == UNPAUSE) {
            if (arguments.length != 0) revert NonCanonicalArguments(kind);
        } else if (kind == SET_SIGNER) {
            address nextSigner = abi.decode(arguments, (address));
            _requireCanonical(kind, arguments, abi.encode(nextSigner));
            if (nextSigner == address(0)) revert InvalidSigner(nextSigner);
        } else if (kind == TRANSFER_OWNER) {
            super._checkQueue(kind, arguments);
        } else {
            revert UnknownOperation(kind);
        }
    }
}
