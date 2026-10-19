// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title pools.trade BeneficiaryVault, the subset the FEEB adapter uses
/// @notice The pools.trade "Fee Beneficiary" (FEEB) NFT contract: whoever holds a token id claims that launch's creator
///         fee. Every vault the tokenizer admits answers each function below.
/// @dev `amounts` answers two words: the pending ETH leg, then the other side, which compounds and stays zero. `claim`
///      returns no data, so it is declared without a return value: a declared return would make every real call revert
///      on decoding. `claim` pays msg.sender, who must be the token's owner; no operator path exists.
interface IBeneficiaryVault {
    /// @notice The holder of `tokenId`; reverts for an unknown id.
    function ownerOf(uint256 tokenId) external view returns (address);

    /// @notice The account approved to move `tokenId`, or zero.
    function getApproved(uint256 tokenId) external view returns (address);

    /// @notice Whether `operator` may move every token of `owner`.
    function isApprovedForAll(address owner, address operator) external view returns (bool);

    /// @notice Approves `to` to move `tokenId` once.
    function approve(address to, uint256 tokenId) external;

    /// @notice Moves `tokenId` from `from` to `to` without the receiver check.
    function transferFrom(address from, address to, uint256 tokenId) external;

    /// @notice Moves `tokenId` from `from` to `to`, calling `onERC721Received` on a contract receiver.
    function safeTransferFrom(address from, address to, uint256 tokenId) external;

    /// @notice Pays the launch's pending creator fee to the caller, who must own `tokenId`. `min0` and `min1` bound the
    ///         two sides; the ETH side (40% of the pool's ETH fees) is the only one that pays out, the other compounds.
    ///         Returns nothing.
    function claim(uint256 tokenId, uint256 min0, uint256 min1) external;

    /// @notice The fee pending for `tokenId`: the ETH side first, then the other side (zero while it compounds).
    function amounts(uint256 tokenId) external view returns (uint256 amount0, uint256 amount1);
}
