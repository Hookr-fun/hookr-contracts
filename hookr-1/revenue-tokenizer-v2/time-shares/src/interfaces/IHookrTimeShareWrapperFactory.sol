// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHookrTimeShares} from "./IHookrTimeShares.sol";

/// @title Hookr time share wrapper factory
/// @notice Opens the ERC-20 wrapper of one day of one time shares contract, on demand, at an address that follows
///         from the two (CREATE2). Anyone may open a day; a day is opened once.
interface IHookrTimeShareWrapperFactory {
    /// @notice The day's wrapper exists already.
    error AlreadyOpen(address shares, uint256 day);

    /// @notice `wrapper` was opened for day `day` of `shares`.
    event Opened(address indexed shares, uint256 indexed day, address indexed wrapper);

    /// @notice The wrapper of day `day` of `shares`, or zero.
    function wrapperOf(address shares, uint256 day) external view returns (address);
    /// @notice The address `open(shares, day)` makes, whether or not it ran yet.
    function predict(IHookrTimeShares shares, uint256 day) external view returns (address);
    /// @notice Opens the wrapper of day `day` of `shares`. Once per day.
    function open(IHookrTimeShares shares, uint256 day) external returns (address wrapper);
}
