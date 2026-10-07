// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {HookrReleased} from "../base/HookrReleased.sol";
import {IHookrMilestoneNFT} from "../interfaces/IHookrMilestoneNFT.sol";
import {IHookrMilestoneNFTFactory} from "../interfaces/IHookrMilestoneNFTFactory.sol";
import {HookrMilestoneNFT} from "./HookrMilestoneNFT.sol";

/// @title HookrMilestoneNFTFactory
/// @notice Deploys the capped HookrMilestoneNFT collection of each program of the contract that deployed it.
/// @dev Separate deployment code keeps the NFT implementation out of the engagement runtime. Each factory serves only
///      the contract that deployed it (HookrPrograms).
contract HookrMilestoneNFTFactory is HookrReleased, IHookrMilestoneNFTFactory {
    /// @inheritdoc IHookrMilestoneNFTFactory
    address public immutable deployer;

    constructor() {
        deployer = msg.sender;
    }

    /// @inheritdoc IHookrMilestoneNFTFactory
    function create(
        uint256 maxSupply,
        string calldata name,
        string calldata symbol,
        string calldata metadataBase,
        bool transferable
    ) external returns (IHookrMilestoneNFT) {
        if (msg.sender != deployer) revert OnlyDeployer();
        return new HookrMilestoneNFT(msg.sender, maxSupply, name, symbol, metadataBase, transferable);
    }
}
