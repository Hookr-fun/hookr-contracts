// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IHookrERC20Authorizations} from "../interfaces/IHookrERC20Authorizations.sol";
import {HookrAuthorizations} from "./HookrAuthorizations.sol";

/// @title Hookr ERC-20 authorizations
/// @notice EIP-3009 for an ERC-20: a holder signs a transfer once (`from`, `to`, `value`, a validity window and a
///         random nonce) and anyone relays it, so the holder pays no gas. `transferWithAuthorization` is open to any
///         relayer; `receiveWithAuthorization` only to the payee, so a payment signed for a contract cannot be
///         relayed to it by a stranger before it is ready. Each takes the signature as `v`, `r`, `s` or as bytes
///         (ECDSA or ERC-1271). This is what x402's EVM "exact" scheme settles with: a facilitator pays the holder's
///         signed amount to the payee and the holder moves nothing itself.
/// @dev Nonces, cancellation and verification are HookrAuthorizations'. The window is strict at both ends, as the
///      standard's reference implementation reads it: valid when `validAfter < block.timestamp < validBefore`.
abstract contract HookrERC20Authorizations is ERC20, IHookrERC20Authorizations, HookrAuthorizations {
    /// @inheritdoc IHookrERC20Authorizations
    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    /// @inheritdoc IHookrERC20Authorizations
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    /// @inheritdoc IHookrERC20Authorizations
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        _transferWithAuthorization(
            TRANSFER_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce, signature
        );
    }

    /// @inheritdoc IHookrERC20Authorizations
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        _transferWithAuthorization(
            TRANSFER_WITH_AUTHORIZATION_TYPEHASH,
            from,
            to,
            value,
            validAfter,
            validBefore,
            nonce,
            abi.encodePacked(r, s, v)
        );
    }

    /// @inheritdoc IHookrERC20Authorizations
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        if (to != msg.sender) revert CallerIsNotPayee(to);
        _transferWithAuthorization(
            RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce, signature
        );
    }

    /// @inheritdoc IHookrERC20Authorizations
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (to != msg.sender) revert CallerIsNotPayee(to);
        _transferWithAuthorization(
            RECEIVE_WITH_AUTHORIZATION_TYPEHASH,
            from,
            to,
            value,
            validAfter,
            validBefore,
            nonce,
            abi.encodePacked(r, s, v)
        );
    }

    function _transferWithAuthorization(
        bytes32 typeHash,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) private {
        if (block.timestamp <= validAfter) revert AuthorizationNotYetValid(validAfter);
        if (block.timestamp >= validBefore) revert SignatureExpired(validBefore);
        _useAuthorization(
            from, nonce, keccak256(abi.encode(typeHash, from, to, value, validAfter, validBefore, nonce)), signature
        );
        _transfer(from, to, value);
    }
}
