// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Hookr agent income door factory
/// @notice Makes agent income doors at predictable addresses, before or after the revenue token exists. Only an
///         agent's owner or its agent wallet on the ERC-8004 identity registry makes a door that names the agent.
/// @dev No owner and nothing to configure: the tokenizer and the registry are fixed at construction. The address
///      follows from the maker, the revenue token, the agent and the ERC-20s, so it is known before the door exists
///      (`predict`) and no one takes another's.
interface IHookrAgentIncomeDoorFactory {
    /// @notice The tokenizer or the registry has no code.
    error InvalidConfig();
    /// @notice `caller` is neither the owner nor the agent wallet of `agentId` on the registry, or the id does not
    ///         exist.
    error NotAgent(address caller, uint256 agentId);
    /// @notice `revenueToken` has code and the tokenizer did not mint it.
    error NotARevenueToken(address revenueToken);

    /// @notice A door was made.
    /// @param door The door.
    /// @param revenueToken The revenue token it pays.
    /// @param agentId The agent whose income it takes.
    /// @param maker Who made it: the agent's owner or its agent wallet then.
    /// @param tokens The ERC-20s it forwards beside native ETH.
    event DoorCreated(
        address indexed door, address indexed revenueToken, uint256 indexed agentId, address maker, address[] tokens
    );

    /// @notice The HookRevenue Tokenizer every door of this factory pays the tokens of.
    /// @return The tokenizer.
    function tokenizer() external view returns (address);
    /// @notice The ERC-8004 identity registry agents are read on.
    /// @return The registry.
    function agentRegistry() external view returns (address);
    /// @notice Whether this factory made `door`.
    /// @param door The address asked about.
    /// @return Whether it is a door of this factory.
    function isDoor(address door) external view returns (bool);
    /// @notice Makes the door of agent `agentId` for `revenueToken`. The caller must be the agent's owner or its
    ///         agent wallet. `revenueToken` may not exist yet (the address `predictToken` gives on the tokenizer);
    ///         one that has code must be a token the tokenizer minted. The door forwards native ETH and `tokens`.
    /// @param revenueToken The revenue token the door pays.
    /// @param agentId The agent's id on the registry.
    /// @param tokens Up to two ERC-20s with code, each once, none the revenue token.
    /// @return door The door.
    function create(address revenueToken, uint256 agentId, address[] calldata tokens) external returns (address door);
    /// @notice The address `create` gives `maker` for the same arguments, made or not.
    /// @param maker The caller of `create`.
    /// @param revenueToken The revenue token the door pays.
    /// @param agentId The agent's id on the registry.
    /// @param tokens The ERC-20s the door forwards beside native ETH.
    /// @return The door's address.
    function predict(address maker, address revenueToken, uint256 agentId, address[] calldata tokens)
        external
        view
        returns (address);
}
