// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC6909} from "@uniswap/v4-core/src/ERC6909.sol";
import {IERC6909Claims} from "@uniswap/v4-core/src/interfaces/external/IERC6909Claims.sol";
import {HookrIncomeTimeline} from "./HookrIncomeTimeline.sol";
import {IHookrTimeShares} from "../interfaces/IHookrTimeShares.sol";

/// @title Hookr day units, part of the time shares
/// @notice The time shares themselves: an ERC-6909 (Uniswap v4's) whose id is the day. Every unit of day `d` earns
///         that day's per-unit index in every asset, and nothing else. Each holder keeps, per day and asset, the
///         index it last settled at and its unpaid credit; a transfer settles both sides first, at their old
///         balances, so the sender keeps what its units earned while it held and the receiver earns from the last
///         settle point on. No external call in a transfer.
/// @dev Units minted after their day started carry the day's income so far: the mint credits `amount x index` on
///      top of the holder's settled position, because the revenue tokens behind the units were locked here for the
///      whole day whether or not the units had been issued yet. Units cannot be sent to the zero address or to this
///      contract.
abstract contract HookrDayUnits is ERC6909, HookrIncomeTimeline {
    /// @notice A holder's position in one day and asset: the per-unit index it last settled at and its unpaid
    ///         credit, scaled.
    struct Holder {
        uint256 index;
        uint256 credit;
    }

    mapping(address holder => mapping(uint256 day => Holder[MAX_ASSETS])) internal _holders;
    mapping(uint256 day => uint256) internal _unitSupply;

    /// @inheritdoc IHookrTimeShares
    function unitSupply(uint256 day) external view returns (uint256) {
        return _unitSupply[day];
    }

    /// @inheritdoc IERC6909Claims
    function transfer(address receiver, uint256 id, uint256 amount)
        public
        override(ERC6909, IERC6909Claims)
        returns (bool)
    {
        _beforeMove(msg.sender, receiver, id);
        return super.transfer(receiver, id, amount);
    }

    /// @inheritdoc IERC6909Claims
    function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
        public
        override(ERC6909, IERC6909Claims)
        returns (bool)
    {
        _beforeMove(sender, receiver, id);
        return super.transferFrom(sender, receiver, id, amount);
    }

    /// @dev Settles both sides of a move of day `day` units at the day's settled index, before balances change.
    function _beforeMove(address from, address to, uint256 day) private {
        if (to == address(0) || to == address(this)) revert InvalidRecipient(to);
        uint256[MAX_ASSETS] memory u = _dayIndexes(day);
        _checkpoint(from, day, u);
        if (to != from) _checkpoint(to, day, u);
    }

    /// @dev Settles `holder`'s credit in every asset of day `day` at index `u`.
    function _checkpoint(address holder, uint256 day, uint256[MAX_ASSETS] memory u) internal {
        uint256 balance = balanceOf[holder][day];
        uint256 n = _assetCount;
        for (uint256 i; i < n; ++i) {
            Holder storage h = _holders[holder][day][i];
            uint256 last = h.index;
            if (u[i] == last) continue;
            if (balance != 0) h.credit += balance * (u[i] - last);
            h.index = u[i];
        }
    }

    /// @dev Mints `amount` units of day `day` to `to` with the day's income so far credited to them.
    function _mintUnits(address to, uint256 day, uint256 amount) internal {
        uint256[MAX_ASSETS] memory u = _dayIndexes(day);
        _checkpoint(to, day, u);
        uint256 n = _assetCount;
        for (uint256 i; i < n; ++i) {
            if (u[i] != 0) _holders[to][day][i].credit += amount * u[i];
        }
        _unitSupply[day] += amount;
        _mint(to, day, amount);
    }
}
