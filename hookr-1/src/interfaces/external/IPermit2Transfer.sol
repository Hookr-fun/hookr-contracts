// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPermit2Signature} from "./IPermit2Signature.sol";

/// @title IPermit2Transfer
/// @notice Permit2's SignatureTransfer `permitTransferFrom`, the transfer a signed permit without a witness allows
///         (0x000000000022D473030F116dDEE9F6B43aC78BA3).
interface IPermit2Transfer {
    /// @notice Transfers `transferDetails.requestedAmount` of `permit.permitted.token` from `owner` to
    ///         `transferDetails.to`, as `owner` signed for the calling spender.
    /// @param permit The signed token, amount, nonce and deadline.
    /// @param transferDetails The recipient and the amount, at most the permitted amount.
    /// @param owner The signer whose tokens move.
    /// @param signature The owner's signature over the permit and the calling spender.
    function permitTransferFrom(
        IPermit2Signature.PermitTransferFrom calldata permit,
        IPermit2Signature.SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;
}
