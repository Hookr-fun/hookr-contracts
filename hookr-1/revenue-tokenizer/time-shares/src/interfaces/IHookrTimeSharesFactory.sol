// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHookrRevenueToken} from "fee-tokenizer/interfaces/IHookrRevenueToken.sol";

/// @title Hookr time shares factory
/// @notice Makes the one canonical `HookrTimeShares` of a revenue token, at an address that follows from the token,
///         with Hookr's roll tip terms. Anyone may call; a token's time shares are made once. A `HookrTimeShares`
///         with other tip terms can be deployed directly, next to it.
interface IHookrTimeSharesFactory {
    /// @notice The token's time shares exist already.
    error AlreadyCreated(address token);

    /// @notice `shares` were made for `token`.
    event Created(address indexed token, address indexed shares);

    /// @notice The roll tip the factory's time shares pay: 50 basis points of the ETH a roll attributes.
    function TIP_BPS() external view returns (uint16);
    /// @notice The most ETH one roll pays its caller: 0.01 ETH.
    function TIP_CAP() external view returns (uint256);
    /// @notice The time shares made for `token`, or zero.
    function sharesOf(address token) external view returns (address);
    /// @notice The address `create(token)` makes, whether or not it ran yet.
    function predict(IHookrRevenueToken token) external view returns (address);
    /// @notice Makes `token`'s time shares. Once per token.
    function create(IHookrRevenueToken token) external returns (address shares);
}
