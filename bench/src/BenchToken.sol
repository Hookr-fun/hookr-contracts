// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title BenchToken
/// @notice A plain 18-decimal ERC-20: the subject token of every pool the bench opens on an existing token. A pool and
///         the pool it is compared with each trade a token deployed the same way, so the token's own transfer cost is in
///         both transactions and cancels out of the difference.
contract BenchToken is ERC20 {
    /// @param supply The whole supply, minted once.
    /// @param to Who receives it.
    constructor(uint256 supply, address to) ERC20("Bench", "BENCH") {
        _mint(to, supply);
    }
}
