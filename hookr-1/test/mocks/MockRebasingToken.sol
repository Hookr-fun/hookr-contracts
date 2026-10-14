// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice ERC-20 whose issuer can rebase one account's balance up or down without a transfer, as a rebasing token
///         looks to a holder, for tests. Transfers are exact. The deployer holds the supply.
contract MockRebasingToken is ERC20 {
    address public immutable issuer;

    constructor(uint256 supply) ERC20("Rebasing", "REB") {
        issuer = msg.sender;
        _mint(msg.sender, supply);
    }

    /// @notice Sets `account`'s balance to `balance`, minting or burning the difference.
    function rebase(address account, uint256 balance) external {
        require(msg.sender == issuer);
        uint256 current = balanceOf(account);
        if (balance > current) _mint(account, balance - current);
        else if (balance < current) _burn(account, current - balance);
    }
}
