// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHookrMilestoneNFT} from "./IHookrMilestoneNFT.sol";

/// @title IHookrMilestoneNFTFactory
/// @notice Interface for HookrMilestoneNFTFactory, which deploys HookrMilestoneNFT collections for the contract that
///         deployed it.
interface IHookrMilestoneNFTFactory {
    /// @notice Only the contract that deployed the factory may create collections.
    error OnlyDeployer();

    /// @notice The only account allowed to create collections: the contract that deployed this factory.
    /// @return The deployer.
    function deployer() external view returns (address);

    /// @notice Deploy a fixed milestone collection controlled by the caller. Deployer only.
    /// @param maxSupply The collection's fixed supply.
    /// @param name The collection's name.
    /// @param symbol The collection's symbol.
    /// @param metadataBase The base URI of the collection's token metadata.
    /// @param transferable Whether holders may transfer tokens.
    /// @return The new collection.
    function create(
        uint256 maxSupply,
        string calldata name,
        string calldata symbol,
        string calldata metadataBase,
        bool transferable
    ) external returns (IHookrMilestoneNFT);
}
