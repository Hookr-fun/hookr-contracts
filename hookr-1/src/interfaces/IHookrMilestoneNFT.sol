// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";

/// @title IHookrMilestoneNFT
/// @notice Interface for HookrMilestoneNFT, a campaign-owned, capped milestone collection.
interface IHookrMilestoneNFT is IERC721Metadata {
    /// @notice Only the collection's controller may call this.
    error OnlyController();
    /// @notice The collection's supply or metadata is invalid.
    error InvalidCollection();
    /// @notice The token id is zero or above the collection's supply.
    error InvalidTokenId();
    /// @notice The collection is not transferable.
    error TransfersDisabled();

    /// @notice Returns the only account that may mint: the campaign controller fixed at deployment.
    /// @return The controller.
    function controller() external view returns (address);

    /// @notice Returns the collection's fixed supply.
    /// @return The most tokens that can exist.
    function maxSupply() external view returns (uint256);

    /// @notice Returns whether holders may transfer tokens.
    /// @return True when tokens are transferable.
    function transferable() external view returns (bool);

    /// @notice Safe-mint a reserved ID; only the immutable campaign controller may call.
    /// @param to The recipient.
    /// @param tokenId The reserved token id.
    function mintReserved(address to, uint256 tokenId) external;
}
