// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice ERC-20 with a transfer hook and a freeze, for tests. While a hook is armed, every transfer out of `watched`
///         first calls `target` with `data` and records whether that call succeeded and what it returned; the transfer
///         goes on either way. While frozen, every transfer reverts. The deployer holds the supply and is the only
///         account that can arm the hook or freeze.
contract MockHookToken is ERC20 {
    address public immutable issuer;
    address public watched;
    address public target;
    bytes public data;
    bool public frozen;
    uint256 public hookCalls;
    bool public lastHookSucceeded;
    bytes public lastHookResult;

    error Frozen();

    constructor(uint256 supply) ERC20("Hook", "HOOK") {
        issuer = msg.sender;
        _mint(msg.sender, supply);
    }

    function arm(address watched_, address target_, bytes calldata data_) external {
        require(msg.sender == issuer);
        watched = watched_;
        target = target_;
        data = data_;
    }

    function setFrozen(bool frozen_) external {
        require(msg.sender == issuer);
        frozen = frozen_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (frozen) revert Frozen();
        if (from == watched && target != address(0)) {
            ++hookCalls;
            (lastHookSucceeded, lastHookResult) = target.call(data);
        }
        super._update(from, to, value);
    }
}
