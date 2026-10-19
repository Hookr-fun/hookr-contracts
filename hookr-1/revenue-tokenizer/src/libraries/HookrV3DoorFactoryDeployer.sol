// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {HookrV3PositionNftDoorFactory} from "../HookrV3PositionNftDoorFactory.sol";
import {INonfungiblePositionManagerDoor} from "../interfaces/external/INonfungiblePositionManagerDoor.sol";

/// @title Hookr v3 door factory deployer
/// @notice Deploys the tokenizer's v3 position-NFT door factory from the tokenizer's own constructor, so the
///         factory's creation code (which carries the door's) lives here and not in the tokenizer's init code: the
///         tokenizer's init code already carries the v4 door factory and sits near the 49,152-byte limit.
/// @dev An external library the tokenizer reaches by delegatecall, so `address(this)` is the tokenizer and the
///      factory is created from the tokenizer's address and pinned to it, as HookrDropBoxDeployer does for the
///      token's box. Linked at deploy.
library HookrV3DoorFactoryDeployer {
    /// @notice Deploys the v3 door factory on `positionManager`, pinned to the calling tokenizer.
    function deploy(address positionManager) external returns (address) {
        return
            address(new HookrV3PositionNftDoorFactory(INonfungiblePositionManagerDoor(positionManager), address(this)));
    }
}
