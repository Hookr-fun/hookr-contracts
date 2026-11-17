// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IHookrTokenMeter
/// @notice The balance-time meter of a HookrToken that keeps a fresh lot (the launcher's token template, pinned by
///         runtime codehash): every wallet's balance x time by UTC day, and the wallets' supply's, so a Holder Pot pays
///         each day's takings by the time wallets held, with no keeper and no record a wallet keeps once its tokens
///         left. A contract (a pool, a router, an escrow) is never metered and reads zero.
interface IHookrTokenMeter {
    /// @notice `account`'s balance-seconds on each closed UTC day from `fromDay` to `toDay` (both inclusive, `toDay`
    ///         before today), oldest first. Reverts when a day is not closed or the read walks back through more of
    ///         the account's moves than one call allows.
    function balanceSeconds(address account, uint256 fromDay, uint256 toDay) external view returns (uint256[] memory);

    /// @notice The balance-seconds of the supply in wallets' hands on each closed day from `fromDay` to `toDay`.
    function walletSupplySeconds(uint256 fromDay, uint256 toDay) external view returns (uint256[] memory);

    /// @notice `balanceSeconds` with a cursor: `hint` is one of the account's entry days at or after `fromDay - 1`,
    ///         the newest at or before the previous read's days (zero: the newest entry), so the read walks only the
    ///         entries between. Returns the balance-seconds, the entry day at or before `fromDay - 1` and the entry day
    ///         at or before `toDay` (zero: none), the hints for reads of earlier and later days.
    function balanceSecondsFrom(address account, uint256 fromDay, uint256 toDay, uint256 hint)
        external
        view
        returns (uint256[] memory balanceSecondsByDay, uint256 startCursor, uint256 endCursor);

    /// @notice `walletSupplySeconds` with a cursor, as `balanceSecondsFrom`.
    function walletSupplySecondsFrom(uint256 fromDay, uint256 toDay, uint256 hint)
        external
        view
        returns (uint256[] memory balanceSecondsByDay, uint256 startCursor, uint256 endCursor);
}
