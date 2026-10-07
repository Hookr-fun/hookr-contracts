// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IHookrToken
/// @notice Interface for HookrToken's own surface beside ERC-20 and EIP-2612: its presentation (tagline and logo URI)
///         and its errors.
interface IHookrToken {
    /// @notice The tagline or logo URI is past its bound.
    error InvalidMetadata();
    /// @notice The token's supply is zero.
    error ZeroSupply();

    /// @notice Only the token's creator may set its presentation, once, in the transaction that created it.
    error NotPresenter();

    /// @notice The permit's `deadline` has passed.
    error ERC2612ExpiredSignature(uint256 deadline);

    /// @notice The permit's signature recovers to `signer`, not `owner`.
    error ERC2612InvalidSigner(address signer, address owner);

    /// @notice A short line the token's creator set when it created the token, at most 160 bytes; empty if none.
    /// @return The tagline.
    function tagline() external view returns (string memory);

    /// @notice The token's logo URI, set by its creator when it created the token, at most 300 bytes; empty if none.
    /// @return The logo URI.
    function logoURI() external view returns (string memory);

    /// @notice Sets the token's tagline (at most 160 bytes) and logo URI (at most 300 bytes), for good. HookrLauncher
    ///         calls it right after creating a token whose launchFamily names either.
    /// @dev Only the account that created the token may call it, once, and only in the transaction that created the
    ///      token (the creator is held in transient storage); any other call reverts NotPresenter. Reverts
    ///      InvalidMetadata for a tagline or logo URI past its bound.
    /// @param tagline_ The tagline, at most 160 bytes.
    /// @param logoURI_ The logo URI, at most 300 bytes.
    function setPresentation(string calldata tagline_, string calldata logoURI_) external;
}
