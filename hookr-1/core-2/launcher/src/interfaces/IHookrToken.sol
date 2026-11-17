// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IHookrToken
/// @notice Interface for HookrToken's own surface beside ERC-20 and EIP-2612: its presentation (tagline and logo URI),
///         its holders' lots and its errors.
interface IHookrToken {
    /// @notice The tagline or logo URI is past its bound.
    error InvalidMetadata();
    /// @notice The token's supply is zero.
    error ZeroSupply();
    /// @notice The token's supply is past 2^108 - 1, the most a holder word's balance and lot hold.
    error SupplyTooLarge();

    /// @notice Only the token's creator may set its presentation, once, in the transaction that created it.
    error NotPresenter();

    /// @notice The permit's `deadline` has passed.
    error ERC2612ExpiredSignature(uint256 deadline);

    /// @notice The permit's signature recovers to `signer`, not `owner`.
    error ERC2612InvalidSigner(address signer, address owner);

    /// @notice `account`'s balance, its fresh lot and the lot's time: tokens received join the fresh lot and move its
    ///         time toward the time they arrive, weighted by amount; tokens sent leave the fresh lot first, then the
    ///         rest of the balance, the aged bag. A lot 30 days past its time (the longest Exit Clock horizon a pool
    ///         can set) has aged into the bag. Exit Clock prices a sell by it: the fresh lot at its age's rate, the bag
    ///         at the floor.
    /// @param account The holder.
    /// @return balance `account`'s balance.
    /// @return fresh The fresh lot's amount, at most `balance`; zero once the lot has aged.
    /// @return freshSince The lot's amount-weighted average arrival time, in seconds; zero while the lot is empty.
    function lots(address account) external view returns (uint256 balance, uint256 fresh, uint256 freshSince);

    /// @notice `account`'s lots as they stood before the last `back` tokens it sent in this transaction left (fewer if
    ///         it sent fewer since it last received). Exit Clock reads it with the sale's amount, so a router that
    ///         collects a sale leg by leg right before each swap prices every leg on the lots a sale in one pool sees.
    /// @param account The holder.
    /// @param back How many of the tokens `account` sent in this transaction to put back, the last sent first.
    /// @return balance The balance before those tokens left.
    /// @return fresh The fresh lot before they left.
    /// @return freshSince The lot's time before they left; zero while that lot is empty.
    function lotsBefore(address account, uint256 back)
        external
        view
        returns (uint256 balance, uint256 fresh, uint256 freshSince);

    /// @notice The days asked for are not all closed, or run backwards.
    error DaysNotClosed();
    /// @notice A read walked back through more entries than one call allows (256).
    error TooManyEntries();

    /// @notice `account`'s meter: the token counts, for every wallet (no code, or an EIP-7702 designator; never a
    ///         contract such as a pool or a router), its balance x time by UTC day, so a Holder Pot can pay each day's
    ///         takings to the wallets by the time they held, with no keeper and no record a wallet keeps after its tokens
    ///         left. Every transfer accrues both wallet sides up to that moment; a wallet's first move of a day closes
    ///         the day before into an entry.
    /// @return balanceSecondsToday The balance-seconds accrued so far in the day of the wallet's last move.
    /// @return lastMove When the meter last accrued.
    /// @return day The UTC day of the last move (block.timestamp / 1 days).
    /// @return metered Whether the account read as a wallet at its last move (a contract is never metered).
    function meterOf(address account)
        external
        view
        returns (uint256 balanceSecondsToday, uint256 lastMove, uint256 day, bool metered);

    /// @notice `account`'s balance-seconds on each closed UTC day from `fromDay` to `toDay` (both inclusive, `toDay`
    ///         before today), oldest first: a day with no move had the balance the previous move left, all day; a
    ///         contract, or the days before a wallet first held, read zero.
    function balanceSeconds(address account, uint256 fromDay, uint256 toDay) external view returns (uint256[] memory);

    /// @notice `balanceSeconds` with a cursor: `hint` is the cursor a previous read returned for the day before
    ///         `fromDay` (a read of later days) or the day after `toDay` (a read of earlier days); zero: no cursor yet,
    ///         the read starts from the newest entry. A cursor is an entry day, or the edge day itself while the account
    ///         had not moved past it (the read then finds its entry once written, or walks from the newest entry through
    ///         the moves since), or 2^32 - 1 when no entry lies at or before the edge and none ever will (the days at
    ///         or before that edge read zero; the days after it read as they are). Day zero is refused. Returns the balance-seconds and the cursors for the day before `fromDay` and for `toDay`.
    ///         A cursor from another read of the same account is the caller's to keep right: one from a different edge
    ///         reads the days without their own entry from the wrong balance.
    function balanceSecondsFrom(address account, uint256 fromDay, uint256 toDay, uint256 hint)
        external
        view
        returns (uint256[] memory balanceSecondsByDay, uint256 startCursor, uint256 endCursor);

    /// @notice The balance-seconds of the supply in wallets' hands on each closed day from `fromDay` to `toDay`: the
    ///         denominator of a day's pot, so what contracts hold (the pool's own liquidity above all) earns nothing.
    function walletSupplySeconds(uint256 fromDay, uint256 toDay) external view returns (uint256[] memory);

    /// @notice `walletSupplySeconds` with a cursor, as `balanceSecondsFrom`.
    function walletSupplySecondsFrom(uint256 fromDay, uint256 toDay, uint256 hint)
        external
        view
        returns (uint256[] memory balanceSecondsByDay, uint256 startCursor, uint256 endCursor);

    /// @notice The supply held by wallets now, as metered.
    function walletSupply() external view returns (uint256);

    /// @notice A short line the token's creator set when it created the token, at most 160 bytes; empty if none.
    /// @return The tagline.
    function tagline() external view returns (string memory);

    /// @notice The token's logo URI, set by its creator when it created the token, at most 300 bytes; empty if none.
    /// @return The logo URI.
    function logoURI() external view returns (string memory);

    /// @notice Sets the token's tagline (at most 160 bytes) and logo URI (at most 300 bytes), for good. HookrLauncher
    ///         calls it right after creating a token whose launchFamily names either.
    /// @dev Only the account that created the token may call it, once, and only in the transaction that created the
    ///      token (the creator is held in transient storage); any other call reverts NotPresenter. Reverts
    ///      InvalidMetadata for a tagline or logo URI past its bound.
    /// @param tagline_ The tagline, at most 160 bytes.
    /// @param logoURI_ The logo URI, at most 300 bytes.
    function setPresentation(string calldata tagline_, string calldata logoURI_) external;
}
