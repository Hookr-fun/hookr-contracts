// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Issuer-controlled ERC-20 for tests, as a regulated dollar or stock token carries: a global pause, a block
///         list and a freeze list, and a switchable transfer fee paid to the issuer. A paused token reverts "paused"
///         on every mint, burn and transfer; otherwise a transfer from or to a blocked or frozen account reverts with
///         the reason given at deployment. The deployer is the issuer: it holds the whole supply and is the only
///         account that can call the setters.
contract MockRestrictedToken is ERC20 {
    address public immutable issuer;
    string internal reason;
    mapping(address => bool) public blocked;
    mapping(address => bool) public frozen;
    bool public paused;
    uint256 public feeBps;

    constructor(string memory name_, string memory symbol_, uint256 supply, string memory reason_)
        ERC20(name_, symbol_)
    {
        issuer = msg.sender;
        reason = reason_;
        _mint(msg.sender, supply);
    }

    modifier onlyIssuer() {
        require(msg.sender == issuer);
        _;
    }

    function setBlocked(address account, bool b) external onlyIssuer {
        blocked[account] = b;
    }

    function freeze(address account, bool f) external onlyIssuer {
        frozen[account] = f;
    }

    function setPaused(bool p) external onlyIssuer {
        paused = p;
    }

    function setFee(uint256 bps) external onlyIssuer {
        feeBps = bps;
    }

    function _update(address from, address to, uint256 amount) internal override {
        require(!paused, "paused");
        if (blocked[from] || blocked[to] || frozen[from] || frozen[to]) revert(reason);
        if (feeBps != 0 && from != address(0) && to != address(0)) {
            uint256 fee = amount * feeBps / 10_000;
            super._update(from, issuer, fee);
            amount -= fee;
        }
        super._update(from, to, amount);
    }
}
