// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IHookrRevenueTokenizer} from "hookrevenue/interfaces/IHookrRevenueTokenizer.sol";
import {IAgentIdentityRegistry} from "./interfaces/IAgentIdentityRegistry.sol";
import {IHookrAgentIncomeDoorFactory} from "./interfaces/IHookrAgentIncomeDoorFactory.sol";
import {HookrAgentIncomeDoor} from "./HookrAgentIncomeDoor.sol";

/// @title Hookr agent income door factory
/// @notice Makes agent income doors for one tokenizer and one ERC-8004 identity registry. See
///         IHookrAgentIncomeDoorFactory for the rules.
/// @dev No owner, nothing mutable but the list of doors made. The registry is outside code that its own owner can
///      change: it is read once, when a door is made, and never by a door.
contract HookrAgentIncomeDoorFactory is IHookrAgentIncomeDoorFactory {
    /// @inheritdoc IHookrAgentIncomeDoorFactory
    address public immutable tokenizer;
    /// @inheritdoc IHookrAgentIncomeDoorFactory
    address public immutable agentRegistry;
    /// @inheritdoc IHookrAgentIncomeDoorFactory
    mapping(address door => bool) public isDoor;

    /// @param tokenizer_ The HookRevenue Tokenizer; must have code.
    /// @param agentRegistry_ The ERC-8004 identity registry; must have code.
    constructor(address tokenizer_, address agentRegistry_) {
        if (tokenizer_.code.length == 0 || agentRegistry_.code.length == 0) revert InvalidConfig();
        tokenizer = tokenizer_;
        agentRegistry = agentRegistry_;
    }

    /// @inheritdoc IHookrAgentIncomeDoorFactory
    function create(address revenueToken, uint256 agentId, address[] calldata tokens) external returns (address door) {
        if (!_controls(msg.sender, agentId)) revert NotAgent(msg.sender, agentId);
        if (
            revenueToken.code.length != 0
                && IHookrRevenueTokenizer(tokenizer).tokenizations(revenueToken).creator == address(0)
        ) revert NotARevenueToken(revenueToken);
        door = address(
            new HookrAgentIncomeDoor{salt: _salt(msg.sender, revenueToken, agentId, tokens)}(
                tokenizer, agentRegistry, revenueToken, agentId, tokens
            )
        );
        isDoor[door] = true;
        emit DoorCreated(door, revenueToken, agentId, msg.sender, tokens);
    }

    /// @inheritdoc IHookrAgentIncomeDoorFactory
    function predict(address maker, address revenueToken, uint256 agentId, address[] calldata tokens)
        external
        view
        returns (address)
    {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(HookrAgentIncomeDoor).creationCode,
                abi.encode(tokenizer, agentRegistry, revenueToken, agentId, tokens)
            )
        );
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), address(this), _salt(maker, revenueToken, agentId, tokens), initCodeHash
                        )
                    )
                )
            )
        );
    }

    /// @dev Whether `who` is the owner or the agent wallet of `agentId` now. An id that does not exist, or a read
    ///      the registry refuses, is no.
    function _controls(address who, uint256 agentId) private view returns (bool) {
        IAgentIdentityRegistry registry = IAgentIdentityRegistry(agentRegistry);
        try registry.ownerOf(agentId) returns (address owner) {
            if (owner == who) return true;
        } catch {
            return false;
        }
        try registry.getAgentWallet(agentId) returns (address wallet) {
            return wallet == who;
        } catch {
            return false;
        }
    }

    function _salt(address maker, address revenueToken, uint256 agentId, address[] calldata tokens)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(maker, revenueToken, agentId, tokens));
    }
}
