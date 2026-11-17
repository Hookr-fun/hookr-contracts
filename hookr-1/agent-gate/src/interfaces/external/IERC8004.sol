// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IERC8004Identity
/// @notice The reads the gate makes on the ERC-8004 Identity Registry (reference implementation 2.0.0, an ERC-721
///         behind an ERC-1967 proxy, the same address on Robinhood Chain and Monad).
interface IERC8004Identity {
    /// @notice The identities `owner` holds. Reverts for the zero address.
    function balanceOf(address owner) external view returns (uint256);
    /// @notice The owner of `agentId`. Reverts for an unknown id.
    function ownerOf(uint256 agentId) external view returns (address);
    /// @notice The agent wallet of `agentId`: the registrant at registration, changed only with the new wallet's
    ///         signature, cleared when the identity is transferred; zero when unset or for an unknown id.
    function getAgentWallet(uint256 agentId) external view returns (address);
    /// @notice The implementation's version string ("2.0.0" on 4663 and 143 on 2026-10-28).
    function getVersion() external view returns (string memory);
}

/// @title IERC8004Reputation
/// @notice The reads the gate makes on the ERC-8004 Reputation Registry (reference implementation 2.0.0). Anyone but
///         an agent's owner and operators can post feedback on it; a client's entries for an agent are numbered from 1
///         and never deleted, only revoked by their author.
interface IERC8004Reputation {
    /// @notice The identity registry this registry reads.
    function getIdentityRegistry() external view returns (address);
    /// @notice How many entries `clientAddress` has posted for `agentId`: the index of its latest, zero for none.
    function getLastIndex(uint256 agentId, address clientAddress) external view returns (uint64);
    /// @notice One entry: a signed fixed-point value at `valueDecimals` (0 to 18), its two tags and whether its author
    ///         revoked it. Reverts for index 0 and above the last index.
    function readFeedback(uint256 agentId, address clientAddress, uint64 feedbackIndex)
        external
        view
        returns (int128 value, uint8 valueDecimals, string memory tag1, string memory tag2, bool isRevoked);
    /// @notice The implementation's version string.
    function getVersion() external view returns (string memory);
}
