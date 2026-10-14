// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20FlashMint} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20FlashMint.sol";

/// @notice ERC-20 with OpenZeppelin's ERC-3156 flash mint at its defaults (no fee, any amount), for tests: anyone may
///         mint for the length of one call, burned back before it returns, so its totalSupply between transactions is
///         the supply minted here. The deployer holds that supply.
contract MockFlashMintToken is ERC20, ERC20FlashMint {
    constructor(uint256 supply) ERC20("Flash", "FLM") {
        _mint(msg.sender, supply);
    }
}
