// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHookrRevenueSource} from "hookrevenue/interfaces/IHookrRevenueSource.sol";

/// @title Hookr agent income door
/// @notice A door an ERC-8004 agent is paid at. Whatever lands on it by plain transfer, native ETH or one of the
///         ERC-20s it names, is forwarded to the agent's revenue token on every sync and reaches the holders as the
///         door's income, less Hookr's leg, like any outside door (IHookrRevenueSource).
/// @dev The door holds no right and nothing can force an agent to be paid here: the agent chooses to point its
///      payments at the door and can stop at any time, which is why `ends()` answers `REVOCABLE` with no date for
///      good. `bound()` answers only whether the door's tokenizer minted its revenue token. The door cannot tell a customer's payment from any other transfer:
///      whoever sends to it, the agent included, adds to the door's income and pays the leg on it. Each transfer's
///      sender is on the currency's own `Transfer` log (native ETH has none).
///
///      No owner, no admin, no upgrade, no way to take anything back: everything the door receives goes to the
///      revenue token or its drop box. A door made for a token that is never minted, or that never adds the door,
///      keeps what it was sent for good, so an agent points its payments here only once `admitted()` is true.
interface IHookrAgentIncomeDoor is IHookrRevenueSource {
    /// @notice A constructor argument does not hold: no code at the tokenizer or the registry, more than
    ///         `MAX_TOKENS` ERC-20s, or an ERC-20 that is zero, the revenue token, without code or named twice.
    error InvalidConfig();
    /// @notice The pinned tokenizer has not minted the revenue token: nothing leaves the door, by `pull` or by
    ///         `dropStray`, until it has.
    error NotAdmitted();

    /// @notice The stream kind id: `keccak256("hookr.agent.income")`.
    /// @return The id.
    function SOURCE_KIND() external view returns (bytes32);
    /// @notice The most ERC-20s a door names beside native ETH: 2.
    /// @return The limit.
    function MAX_TOKENS() external view returns (uint256);
    /// @notice The factory that made the door.
    /// @return The factory.
    function factory() external view returns (address);
    /// @notice The HookRevenue Tokenizer whose tokens the door pays, and no other contract.
    /// @return The tokenizer.
    function tokenizer() external view returns (address);
    /// @notice The ERC-8004 identity registry `agentId` lives on.
    /// @return The registry.
    function agentRegistry() external view returns (address);
    /// @notice The agent whose income this is. Whoever made the door controlled this id on the registry then
    ///         (its owner or its agent wallet); the id can change hands later, so a reader also checks the id's own
    ///         record names the revenue token.
    /// @return The agent's id on `agentRegistry`.
    function agentId() external view returns (uint256);
    /// @notice Whether the tokenizer minted `revenueToken` and the token has this door: from then on every sync
    ///         forwards what the door holds. False before the mint, and for good when the token never adds the door.
    /// @return Whether the door is one of its token's doors.
    function admitted() external view returns (bool);
}
