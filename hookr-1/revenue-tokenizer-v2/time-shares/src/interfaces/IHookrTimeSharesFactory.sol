// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHookrRevenueToken} from "hookrevenue-v2/interfaces/IHookrRevenueToken.sol";
import {IHookrRevenueTokenizer} from "hookrevenue-v2/interfaces/IHookrRevenueTokenizer.sol";

/// @title Hookr time shares factory
/// @notice Makes the one canonical `HookrTimeShares` of a revenue token, at an address that follows from the token,
///         with Hookr's roll tip terms. Anyone may call; a token's time shares are made once. The factory is bound,
///         for good, to one HookRevenue Tokenizer and makes time shares only for the revenue tokens that tokenizer
///         minted. A `HookrTimeShares`
///         with other tip terms can be deployed directly, next to it.
interface IHookrTimeSharesFactory {
    /// @notice The token's time shares exist already.
    error AlreadyCreated(address token);
    /// @notice The factory was given something that is not a tokenizer: no code, or no launcher.
    error InvalidTokenizer(address tokenizer);
    /// @notice The pinned tokenizer has no record of `token`: it did not mint it.
    error NotTokenized(address token);
    /// @notice The token names another tokenizer than the pinned one.
    error WrongTokenizer(address token);

    /// @notice `shares` were made for `token`.
    event Created(address indexed token, address indexed shares);

    /// @notice The only tokenizer whose revenue tokens this factory accepts. Fixed at construction.
    function tokenizer() external view returns (IHookrRevenueTokenizer);
    /// @notice The roll tip the factory's time shares pay: 50 basis points of the ETH a roll attributes.
    function TIP_BPS() external view returns (uint16);
    /// @notice The most ETH one roll pays its caller: 0.01 ETH.
    function TIP_CAP() external view returns (uint256);
    /// @notice The time shares made for `token`, or zero.
    function sharesOf(address token) external view returns (address);
    /// @notice The address `create(token)` makes, whether or not it ran yet.
    function predict(IHookrRevenueToken token) external view returns (address);
    /// @notice Makes `token`'s time shares. Once per token, and only for a live revenue token the pinned tokenizer
    ///         minted (it has a record of it, and the token names it); the time shares' constructor then refuses a token that is
    ///         not live, whose drop box does not point back at it, or whose clock is not the block number
    ///         (`InvalidConfig`).
    function create(IHookrRevenueToken token) external returns (address shares);
}
