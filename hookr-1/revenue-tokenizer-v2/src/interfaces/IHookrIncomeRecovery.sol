// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Hookr income recovery
/// @notice Collects drops earned by revenue token shares held by a token or its drop box. The recipient is always
///         the collecting contract. Anyone can trigger collection; nobody can redirect its income.
interface IHookrIncomeRecovery {
    /// @notice One call may collect at most eight drops; a longer history is collected in pages.
    error TooManyRecoveryDrops(uint256 count);
    /// @notice The caller left too little gas to attempt this drop and finish the bookkeeping (in the token host's
    ///         income collection, `dropId` is the asset whose retirement could not be attempted).
    error IncomeRecoveryStarved(uint256 dropId);

    /// @notice A drop earned by the collecting contract was paid into it. `amount` is what the source box answered:
    ///         a fake source can report any figure, so book the collecting contract's balance change, not this.
    event DropIncomeCollected(address indexed revenueToken, uint256 indexed dropId, uint256 amount);
    /// @notice The collecting contract's share of a drop paid in its own revenue token was claimed to 0xdead. `amount`
    ///         is what left the source box for 0xdead: the smaller of the rise of 0xdead's balance of that revenue token
    ///         and the fall of the source box's balance of it across the claim, never what the source box answered,
    ///         and never another contract's retirement that the box's code triggers during the claim. A claim that
    ///         moved none of the box's own shares, or whose balances could not be read, emits nothing. Book 0xdead's
    ///         balance, not this event: a box that sends its own shares elsewhere during such a retirement can still be
    ///         credited up to what it sent.
    event DropIncomeRetired(address indexed revenueToken, uint256 indexed dropId, uint256 amount);
    /// @notice The token host's income in its own shares, asset `asset` of `revenueToken`, was claimed to 0xdead.
    ///         `amount` is what left `revenueToken` for 0xdead: the smaller of the rise of 0xdead's balance of the host
    ///         and the fall of `revenueToken`'s balance of the host across the claim, never what `revenueToken`
    ///         answered, and never another contract's retirement that its code triggers during the claim. A claim
    ///         that moved none of its own host shares, or whose balances could not be read, emits nothing. Book
    ///         0xdead's balance, not this event: a source that sends its own host shares elsewhere during such a
    ///         retirement can still be credited up to what it sent.
    event IncomeRetired(address indexed revenueToken, uint256 indexed asset, uint256 amount);

    /// @notice Claims up to eight of another revenue token's drops into this contract. Failed or unknown drops are
    ///         skipped with their upstream credit intact. A drop paid in the host's own revenue token (the token
    ///         itself, or the token whose holders the box pays) is claimed to 0xdead instead (`DropIncomeRetired`):
    ///         the token refuses its own shares, and in its box they would earn nothing for anyone, so they are
    ///         retired rather than left to earn in the source box. Returns each amount paid into this contract, zero
    ///         for a retired share.
    function collectDrops(address revenueToken, uint256[] calldata dropIds) external returns (uint256[] memory amounts);
}
