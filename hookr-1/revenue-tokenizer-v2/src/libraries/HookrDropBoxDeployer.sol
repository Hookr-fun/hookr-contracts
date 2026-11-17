// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {HookrDropBox} from "../HookrDropBox.sol";

/// @title Hookr drop box deployer
/// @notice Deploys a revenue token's drop box from the token's own constructor, so the box's creation code lives here
///         and not in the token's: the tokenizer's token deployer carries the token's creation code in its runtime,
///         which the box would push past the 24,576-byte limit.
/// @dev An external library the token reaches by delegatecall, so `address(this)` is the token and the box is
///      created from the token's address, naming it; the token links this library at deploy.
library HookrDropBoxDeployer {
    /// @notice Deploys the drop box of the calling token.
    function deploy() external returns (address) {
        return address(new HookrDropBox(address(this)));
    }
}
