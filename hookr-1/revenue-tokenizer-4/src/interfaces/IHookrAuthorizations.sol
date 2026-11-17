// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC5267} from "@openzeppelin/contracts/interfaces/IERC5267.sol";

/// @title Hookr authorizations
/// @notice Signed, one-shot authorizations under the contract's EIP-712 domain, in the shape of EIP-3009: each carries
///         a random `bytes32` nonce its signer picks, is used once or canceled by its signer, and is accepted from an
///         EOA (ECDSA, a 65-byte `r || s || v` signature) and from a contract account (ERC-1271, any bytes) alike, so a
///         smart wallet or an EIP-7702 account signs like anyone else. The signatures that use them are in the
///         inheriting interface; the events are EIP-3009's, so an indexer or an x402 facilitator reads them as it
///         reads USDC's. The domain is readable through `eip712Domain` (EIP-5267).
interface IHookrAuthorizations is IERC5267 {
    /// @notice The signature is not `signer`'s over the typed data.
    error InvalidSigner();
    /// @notice The signature's deadline (or `validBefore`) has passed.
    error SignatureExpired(uint256 deadline);
    /// @notice The authorization's `validAfter` has not passed yet.
    error AuthorizationNotYetValid(uint256 validAfter);
    /// @notice `nonce` was used or canceled by its signer before.
    error NonceAlreadyUsed(bytes32 nonce);

    /// @notice `authorizer`'s authorization `nonce` was used.
    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);
    /// @notice `authorizer` canceled authorization `nonce` before it was used.
    event AuthorizationCanceled(address indexed authorizer, bytes32 indexed nonce);

    /// @notice The EIP-712 type hash of `cancelAuthorization`:
    ///         `CancelAuthorization(address authorizer,bytes32 nonce)`.
    function CANCEL_AUTHORIZATION_TYPEHASH() external view returns (bytes32);
    /// @notice Whether `authorizer`'s `nonce` was used or canceled.
    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool);
    /// @notice Cancels `authorizer`'s unused `nonce` with `authorizer`'s signature over
    ///         `CancelAuthorization(authorizer, nonce)`; anyone may relay it.
    function cancelAuthorization(address authorizer, bytes32 nonce, bytes calldata signature) external;
    /// @notice `cancelAuthorization` with an ECDSA signature given as `v`, `r`, `s`.
    function cancelAuthorization(address authorizer, bytes32 nonce, uint8 v, bytes32 r, bytes32 s) external;
}
