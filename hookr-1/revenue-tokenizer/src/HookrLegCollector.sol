// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IHookrTreasury} from "hookr/interfaces/IHookrTreasury.sol";
import {HookrDropSweep} from "./base/HookrDropSweep.sol";
import {IHookrRevenueToken} from "./interfaces/IHookrRevenueToken.sol";
import {IHookrLegCollector} from "./interfaces/IHookrLegCollector.sol";

/// @title Hookr leg collector, part of the HookRevenue Tokenizer
/// @notice Holds Hookr's leg of every revenue token the tokenizer creates with one (5% of the shares when the tokenized
///         stream does not pay Hookr through our hook; none when it does) and lets anyone sweep what those shares earned
///         to the HookrTreasury's current `target()`.
/// @dev No owner. The target is read on every sweep, so only the treasury's own two-step target change moves where the
///      money goes. The collector never transfers its shares: they earn for good. Drops into a revenue token's drop box
///      are paid to whoever calls the box, so the collector's share of every drop would sit there for good without a
///      code path: HookrDropSweep gives it `sweepDrops`, anyone's call, paid to the same target.
contract HookrLegCollector is IHookrLegCollector, HookrDropSweep {
    /// @inheritdoc IHookrLegCollector
    address public immutable treasury;

    /// @param treasury_ The HookrTreasury; must have code.
    constructor(address treasury_) {
        if (treasury_.code.length == 0) revert InvalidTreasury(treasury_);
        treasury = treasury_;
    }

    /// @inheritdoc IHookrLegCollector
    /// @dev Bubbles the token's `NothingToClaim` when nothing is due.
    function sweep(address token, uint256 asset) external returns (uint256 amount) {
        if (token.code.length == 0) revert InvalidToken(token);
        address target = IHookrTreasury(treasury).target();
        amount = IHookrRevenueToken(token).claim(asset, target);
        emit Swept(token, asset, target, amount);
    }

    /// @inheritdoc IHookrLegCollector
    function sweepAll(address token) external returns (uint256[] memory amounts) {
        if (token.code.length == 0) revert InvalidToken(token);
        address target = IHookrTreasury(treasury).target();
        amounts = IHookrRevenueToken(token).claimAll(target);
        for (uint256 i; i < amounts.length; ++i) {
            if (amounts[i] != 0) emit Swept(token, i, target, amounts[i]);
        }
    }

    /// @dev Where `sweepDrops` pays: the treasury's target, read on every call like `sweep`'s.
    function _dropTarget() internal view override returns (address) {
        return IHookrTreasury(treasury).target();
    }
}
