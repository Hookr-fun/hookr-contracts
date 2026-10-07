// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPermit2Signature
/// @notice Minimal Permit2 SignatureTransfer surface (0x000000000022D473030F116dDEE9F6B43aC78BA3).
interface IPermit2Signature {
    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }

    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    /// @notice Transfers `transferDetails.requestedAmount` from `owner` using a signed permit that covers `witness`.
    function permitWitnessTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external;

    /// @notice The unordered nonce bitmap word `wordPos` of `owner`.
    function nonceBitmap(address owner, uint256 wordPos) external view returns (uint256);

    /// @notice Marks the bits of `mask` in the caller's word `wordPos` as used.
    function invalidateUnorderedNonces(uint256 wordPos, uint256 mask) external;
}
