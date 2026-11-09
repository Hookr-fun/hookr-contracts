// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title Hookr forward events, part of the HookRevenue Tokenizer
/// @notice What a door or a source logs as it moves what it collected on: to the revenue token when the token lists
///         the currency, into the token's drop box when it does not (less Hookr's leg, which goes to the leg collector
///         after the rest reached the box; the box makes it one immediate drop at a release period under an hour and
///         streams it at a longer one), and the revenue token itself to 0xdead.
interface IHookrForwardEvents {
    /// @notice `amount` of `currency` reached the revenue token.
    event Forwarded(Currency indexed currency, uint256 amount);
    /// @notice The revenue token could not take `amount` of `currency` this time; it stays where it is for a later
    ///         pull. An `amount` of zero means the balance could not be read.
    event ForwardFailed(Currency indexed currency, uint256 amount);
    /// @notice `amount` of `asset`, which the token does not list, was transferred into the token's drop box. It
    ///         reports the transfer, not the recognition: the box's `dropStray` runs after it and may refuse (no earning
    ///         supply at the snapshot, too little gas), leaving the amount in the box for the next `dropStray`. The box's
    ///         own `StrayAdded` and `Dropped` record what reached the holders.
    event StrayStreamed(address indexed asset, uint256 amount);
    /// @notice `amount` of `asset`, which the token does not list, could not reach the token's drop box this time (no
    ///         box yet, or the asset refused the transfer); it stays where it is for a later pull.
    event StrayStreamFailed(address indexed asset, uint256 amount);
    /// @notice Hookr's leg, `amount` of `asset`, which the token does not list, went to the token's leg collector,
    ///         after the rest went into the drop box (`StrayStreamed`).
    event LegPaid(address indexed asset, uint256 amount);
    /// @notice `amount` of the revenue token itself went to 0xdead, whose shares earn nothing.
    event Retired(uint256 amount);
}
