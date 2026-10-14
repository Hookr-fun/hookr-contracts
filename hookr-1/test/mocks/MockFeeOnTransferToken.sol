// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fee-on-transfer ERC-20 for tests. While `feeBps` is above zero, every transfer between two accounts sends
///         `feeBps` of the amount, rounded down, to `feeSink`, or burns it when `feeSink` is the zero address; the
///         recipient gets the rest. Mints and burns pay no fee. The deployer holds the whole supply and is the only
///         account that can change the fee.
contract MockFeeOnTransferToken is ERC20 {
    address public immutable issuer;
    address public immutable feeSink;
    uint256 public feeBps;

    constructor(string memory name_, string memory symbol_, uint256 supply, uint256 feeBps_, address feeSink_)
        ERC20(name_, symbol_)
    {
        issuer = msg.sender;
        feeSink = feeSink_;
        feeBps = feeBps_;
        _mint(msg.sender, supply);
    }

    function setFeeBps(uint256 bps) external {
        require(msg.sender == issuer);
        feeBps = bps;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (feeBps != 0 && from != address(0) && to != address(0)) {
            uint256 fee = value * feeBps / 10_000;
            // A zero feeSink burns the fee: ERC20._update to the zero address lowers the supply.
            super._update(from, feeSink, fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}
