// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IHookrAuthorizations} from "../interfaces/IHookrAuthorizations.sol";

/// @title Hookr authorizations
/// @notice The signed one-shot authorizations of `IHookrAuthorizations`: an EIP-712 domain (the inheriting contract's
///         name, version "1", the chain and its address, readable through `eip712Domain`), a used-or-canceled flag per
///         signer and nonce, and one verifier that takes an EOA's ECDSA signature or a contract account's ERC-1271
///         answer.
/// @dev `_useAuthorization` is the one path that marks a nonce used, and it verifies the signature first, so a wrong
///      signature never burns a nonce. The verifier tries ECDSA before ERC-1271 whatever code the signer has, so an
///      EIP-7702 account signs with its key and a smart wallet through its validator. A contract's answer can change
///      over time; nothing here caches it.
abstract contract HookrAuthorizations is EIP712, IHookrAuthorizations {
    /// @inheritdoc IHookrAuthorizations
    bytes32 public constant CANCEL_AUTHORIZATION_TYPEHASH =
        keccak256("CancelAuthorization(address authorizer,bytes32 nonce)");

    mapping(address authorizer => mapping(bytes32 nonce => bool)) private _used;

    /// @inheritdoc IHookrAuthorizations
    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool) {
        return _used[authorizer][nonce];
    }

    /// @inheritdoc IHookrAuthorizations
    function cancelAuthorization(address authorizer, bytes32 nonce, bytes calldata signature) external {
        _cancel(authorizer, nonce, signature);
    }

    /// @inheritdoc IHookrAuthorizations
    function cancelAuthorization(address authorizer, bytes32 nonce, uint8 v, bytes32 r, bytes32 s) external {
        _cancel(authorizer, nonce, abi.encodePacked(r, s, v));
    }

    function _cancel(address authorizer, bytes32 nonce, bytes memory signature) private {
        if (_used[authorizer][nonce]) revert NonceAlreadyUsed(nonce);
        _verify(authorizer, keccak256(abi.encode(CANCEL_AUTHORIZATION_TYPEHASH, authorizer, nonce)), signature);
        _used[authorizer][nonce] = true;
        emit AuthorizationCanceled(authorizer, nonce);
    }

    /// @dev Uses `authorizer`'s `nonce` for the authorization `structHash` describes, once `signature` is verified as
    ///      `authorizer`'s over it.
    function _useAuthorization(address authorizer, bytes32 nonce, bytes32 structHash, bytes memory signature) internal {
        if (_used[authorizer][nonce]) revert NonceAlreadyUsed(nonce);
        _verify(authorizer, structHash, signature);
        _used[authorizer][nonce] = true;
        emit AuthorizationUsed(authorizer, nonce);
    }

    /// @dev `signature` must be `signer`'s over the typed data `structHash` describes under this domain: an ECDSA
    ///      signature that recovers to `signer`, or one `signer`'s code accepts through ERC-1271.
    function _verify(address signer, bytes32 structHash, bytes memory signature) internal view {
        if (!SignatureChecker.isValidSignatureNow(signer, _hashTypedDataV4(structHash), signature)) {
            revert InvalidSigner();
        }
    }
}
