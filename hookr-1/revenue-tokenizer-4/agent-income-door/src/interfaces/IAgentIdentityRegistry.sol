// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ERC-8004 identity registry, the two reads the door factory makes
/// @notice One ERC-721 per agent. `ownerOf` is the agent's owner; `getAgentWallet` is the wallet the agent is paid at.
interface IAgentIdentityRegistry {
    /// @notice The owner of agent `agentId`; reverts for an id that does not exist.
    /// @param agentId The agent's id.
    /// @return The owner.
    function ownerOf(uint256 agentId) external view returns (address);
    /// @notice The payment wallet of agent `agentId`, or zero when none is set.
    /// @param agentId The agent's id.
    /// @return The agent wallet.
    function getAgentWallet(uint256 agentId) external view returns (address);
}
