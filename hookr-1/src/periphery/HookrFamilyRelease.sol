// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrLauncher} from "./HookrLauncher.sol";
import {HookrReleased} from "../base/HookrReleased.sol";
import {IHookrFamilyRelease} from "../interfaces/IHookrFamilyRelease.sol";

/// @title HookrFamilyRelease
/// @notice Hands one family released by HookrFamilyLock to the owner its beneficiary chose, and passes the fees the
///         family earns until that owner accepts it to the beneficiary.
/// @dev Created by the lock for one release. It owns the family from the release until the new owner accepts; it only
///      starts or re-targets that transfer, with every member's fees on acceptance paid to it as PoolManager ERC-6909
///      claims, which `sweep` sends to the beneficiary.
contract HookrFamilyRelease is HookrReleased, IHookrFamilyRelease {
    /// @inheritdoc IHookrFamilyRelease
    address public immutable lock;
    /// @inheritdoc IHookrFamilyRelease
    bytes32 public immutable familyId;
    /// @inheritdoc IHookrFamilyRelease
    address public immutable beneficiary;
    HookrLauncher internal immutable _launcher;
    IPoolManager internal immutable _manager;

    constructor(HookrLauncher launcher_, bytes32 familyId_, address beneficiary_) {
        lock = msg.sender;
        familyId = familyId_;
        beneficiary = beneficiary_;
        _launcher = launcher_;
        _manager = launcher_.poolManager();
    }

    /// @inheritdoc IHookrFamilyRelease
    function accept() external {
        if (msg.sender != lock) revert NotAllowed(msg.sender);
        _launcher.acceptFamily(familyId);
    }

    /// @inheritdoc IHookrFamilyRelease
    function transferTo(address newOwner) external {
        if (msg.sender != lock && msg.sender != beneficiary) revert NotAllowed(msg.sender);
        if (newOwner == address(0) || newOwner == address(this)) revert InvalidNewOwner(newOwner);
        uint256 n = _launcher.memberCount(familyId);
        _launcher.transferFamily(familyId, newOwner, uint16((uint256(1) << (2 * n)) - 1));
    }

    /// @inheritdoc IHookrFamilyRelease
    function sweep(Currency currency) external returns (uint256 amount) {
        uint256 id = currency.toId();
        amount = _manager.balanceOf(address(this), id);
        if (amount != 0) _manager.transfer(beneficiary, id, amount);
    }
}
