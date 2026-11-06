// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHookrAuthorizations} from "./IHookrAuthorizations.sol";

/// @title Hookr ERC-20 authorizations
/// @notice EIP-3009 for a token: a holder signs a transfer once (`from`, `to`, `value`, a validity window and a random
///         nonce) and anyone relays it, so the holder pays no gas. `transferWithAuthorization` is open to any relayer;
///         `receiveWithAuthorization` only to the payee. Each takes the signature as `v`, `r`, `s` or as bytes (ECDSA
///         or ERC-1271). This is what x402's EVM "exact" scheme settles with. Nonces and cancellation are
///         IHookrAuthorizations'.
interface IHookrERC20Authorizations is IHookrAuthorizations {
    /// @notice `receiveWithAuthorization` was called by someone other than the payee `to`.
    error CallerIsNotPayee(address to);

    /// @notice The EIP-712 type hash of `transferWithAuthorization`:
    ///         `TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)`.
    function TRANSFER_WITH_AUTHORIZATION_TYPEHASH() external view returns (bytes32);
    /// @notice The EIP-712 type hash of `receiveWithAuthorization`:
    ///         `ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)`.
    function RECEIVE_WITH_AUTHORIZATION_TYPEHASH() external view returns (bytes32);

    /// @notice Moves `value` from `from` to `to` on `from`'s signature over
    ///         `TransferWithAuthorization(from, to, value, validAfter, validBefore, nonce)`, valid strictly between
    ///         `validAfter` and `validBefore`, using `nonce` once. Anyone may relay it.
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external;
    /// @notice `transferWithAuthorization` with an ECDSA signature given as `v`, `r`, `s`.
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
    ) external;
    /// @notice As `transferWithAuthorization`, over `ReceiveWithAuthorization(...)`, and only the payee `to` may relay
    ///         it (`CallerIsNotPayee` otherwise), so a payment signed for a contract cannot be pushed to it by a
    ///         stranger before it is ready.
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external;
    /// @notice `receiveWithAuthorization` with an ECDSA signature given as `v`, `r`, `s`.
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
    ) external;
}
