// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Hookr revenue token door factory, part of the HookRevenue Tokenizer
/// @notice Makes revenue token doors for one tokenizer at CREATE2 addresses bound to the account adding the stream.
///         The tokenizer moves the inner shares in after `createFor`.
interface IHookrRevenueTokenDoorFactory {
    /// @notice A door was made for `outer`, to hold shares of `inner`.
    /// @param door The new door.
    /// @param returnTo The account adding the stream, who gets the shares back.
    /// @param outer The revenue token every pull pays.
    /// @param inner The revenue token whose shares the door holds.
    /// @param unlockAt The unlock timestamp, or type(uint64).max for forever.
    /// @param salt The salt the address is bound to, with `returnTo`.
    event DoorCreated(
        address indexed door,
        address indexed returnTo,
        address indexed outer,
        address inner,
        uint64 unlockAt,
        bytes32 salt
    );

    /// @notice The tokenizer address is zero.
    error TokenizerZero();
    /// @notice Only the pinned tokenizer makes doors.
    error OnlyTokenizer();
    /// @notice `inner` is not a revenue token of this factory's tokenizer.
    error ForeignToken(address inner);

    /// @notice The tokenizer this factory serves alone.
    /// @return The tokenizer.
    function tokenizer() external view returns (address);
    /// @notice True for every door this factory made.
    /// @param door The address to check.
    /// @return Whether this factory made it.
    function isDoor(address door) external view returns (bool);

    /// @notice Makes a door holding shares of `inner` for `outer`, returning them to `returnTo` from `unlockAt` (or
    ///         never). Only the tokenizer, which refuses `inner == outer` before calling; `inner` must be one of its
    ///         revenue tokens.
    /// @param returnTo The account adding the stream, whose shares the tokenizer moves in and who gets them back.
    /// @param outer The revenue token every pull pays.
    /// @param inner The revenue token whose shares the door holds.
    /// @param unlockAt The unlock timestamp, or type(uint64).max for forever.
    /// @param salt The salt the address is bound to, with `returnTo`.
    /// @return door The new door.
    function createFor(address returnTo, address outer, address inner, uint64 unlockAt, bytes32 salt)
        external
        returns (address door);

    /// @notice The address `createFor` gives for these arguments.
    /// @param returnTo The account adding the stream.
    /// @param outer The revenue token every pull pays.
    /// @param inner The revenue token whose shares the door holds.
    /// @param unlockAt The unlock timestamp, or type(uint64).max for forever.
    /// @param salt The salt the address is bound to, with `returnTo`.
    /// @return The predicted door address.
    function predict(address returnTo, address outer, address inner, uint64 unlockAt, bytes32 salt)
        external
        view
        returns (address);
}
