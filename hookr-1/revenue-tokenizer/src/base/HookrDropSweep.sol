// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IHookrDropBox} from "../interfaces/IHookrDropBox.sol";
import {IHookrDropHost} from "../interfaces/IHookrDropHost.sol";
import {IHookrDropSweep} from "../interfaces/IHookrDropSweep.sol";

/// @title Hookr drop sweep, part of the HookRevenue Tokenizer
/// @notice Mixin for a contract that holds revenue-token shares on someone's behalf and must not keep what they earn:
///         Hookr's leg collector, which holds Hookr's leg of a revenue token for good and sweeps its income to the
///         treasury's target. Without this a contract holder is in every drop's denominator and its share sits in the box
///         forever (the box pays `msg.sender` and has no sweep). With it, anyone can push the holder's share of any
///         drop to `_dropTarget()`.
/// @dev No owner, no state. The inheritor says where the money goes by implementing `_dropTarget()` (the collector
///      returns `IHookrTreasury(treasury).target()`, read on every call, so only the treasury's own target change
///      moves it). The box's `claim` reverts on an unknown, already claimed or empty id, and so does this.
abstract contract HookrDropSweep is IHookrDropSweep {
    /// @inheritdoc IHookrDropSweep
    function sweepDrops(address token, uint256[] calldata dropIds) external returns (uint256[] memory amounts) {
        if (token.code.length == 0) revert NoDropBox(token);
        address target = _dropTarget();
        amounts = IHookrDropBox(IHookrDropHost(token).dropBox()).claim(dropIds, target);
        for (uint256 i; i < dropIds.length; ++i) {
            emit DropSwept(token, dropIds[i], target, amounts[i]);
        }
    }

    /// @dev Where swept drops are paid. Must never be zero (the box refuses it) and never this contract.
    function _dropTarget() internal view virtual returns (address);
}
