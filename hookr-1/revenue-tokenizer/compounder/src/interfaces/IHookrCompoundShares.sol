// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title Hookr compound shares
/// @notice The shares of a compounder are an ERC-20 with EIP-2612 permit (name, symbol, decimals, totalSupply,
///         balanceOf, allowance, approve, transfer, transferFrom, permit, nonces, DOMAIN_SEPARATOR), plus the ledger of
///         the side assets this interface describes. A side asset is an asset the compounder receives that is not the
///         pool's quote, so it cannot be placed in the pool: the revenue token's other assets (fixed at construction,
///         the first `fixedSideCount`) and any asset the token's creator lists with `listSide`, at most `MAX_SIDES` in
///         all. Every amount the compounder holds of a side asset is split over the earning shares by an index as it is
///         recognized, settled on every transfer, and claimed by each shareholder with `claimSide`. Shares at `DEAD`
///         (the minimum shares of the first deposit) and shares held by the PoolManager (a pool of the shares, which
///         could never claim) earn nothing. Shares cannot be transferred to the compounder itself. What a drop brings
///         in is released over `dropStream` seconds, as the revenue token releases its own income, so only whoever
///         holds shares while it releases earns it.
interface IHookrCompoundShares {
    /// @notice One side asset's accounting.
    /// @param currency The asset; address zero is native ETH (a side asset when the pool's quote is an ERC-20).
    /// @param index Recognized amount per earning share, scaled by `SCALE`.
    /// @param carry Recognized amount not yet expressible in the index, scaled.
    /// @param recognized Total units recognized.
    /// @param paid Total units paid to shareholders; never above `recognized`.
    /// @param dropped Units a drop brought in that had not yet been released at `droppedAt`.
    /// @param droppedAt When `dropped` was last set; it releases linearly over `dropStream` seconds from then.
    struct Side {
        Currency currency;
        uint256 index;
        uint256 carry;
        uint128 recognized;
        uint128 paid;
        uint128 dropped;
        uint40 droppedAt;
    }

    /// @notice A call re-entered the compounder.
    error Reentrant();
    /// @notice `side` is past the last side asset.
    error UnknownSide(uint256 side);
    /// @notice The claim would pay nothing.
    error NothingToClaim();
    /// @notice `to` cannot receive: the zero address or the compounder itself.
    error InvalidRecipient(address to);
    /// @notice Listing one more side asset would make `count`, above `MAX_SIDES`.
    error TooManySides(uint256 count);

    /// @notice `currency` was listed as side asset `side`.
    event SideAdded(uint256 indexed side, Currency indexed currency);
    /// @notice `amount` of side asset `side` was recognized and split over the earning shares; the index
    ///         is now `index`.
    event SideRecognized(uint256 indexed side, uint256 amount, uint256 index);
    /// @notice `account` was paid `amount` of side asset `side` at `to`.
    event SideClaimed(address indexed account, uint256 indexed side, address indexed to, uint256 amount);

    /// @notice Fixed-point scale of the side indexes: 1e36.
    function SCALE() external view returns (uint256);
    /// @notice Most side assets a compounder lists, fixed and found together: 8.
    function MAX_SIDES() external view returns (uint256);
    /// @notice Gas a side asset's balance is read with: 30,000, and only the first word of its answer is kept. An asset
    ///         that does not answer in that gas reads as zero.
    function SIDE_READ_GAS() external view returns (uint256);
    /// @notice The address the first deposit's minimum shares go to; shares there earn no side asset.
    function DEAD() external view returns (address);

    /// @notice Number of side assets listed now: the fixed ones and those the creator listed.
    function sideCount() external view returns (uint256);
    /// @notice Number of side assets fixed at construction: the revenue token's assets other than the quote. They
    ///         are the first `fixedSideCount` sides.
    function fixedSideCount() external view returns (uint256);
    /// @notice Side asset `side` and its accounting; reverts `UnknownSide` past the last one.
    function sideAt(uint256 side) external view returns (Side memory);
    /// @notice Whether `currency` is a side asset and, if so, which.
    function sideOf(Currency currency) external view returns (bool listed, uint256 side);
    /// @notice Seconds a drop's proceeds take to release: the revenue token's `streamSeconds`.
    function dropStream() external view returns (uint256);
    /// @notice The shares that earn side assets: the total supply less the shares at `DEAD` and at the PoolManager.
    function earningSupply() external view returns (uint256);
    /// @notice Units of side asset `side` that `account` can claim now.
    function sideClaimable(address account, uint256 side) external view returns (uint256);
    /// @notice Pays the caller's claim in side asset `side` to `to`: the lesser of what it is owed and what the
    ///         compounder holds; the rest stays owed. Reverts `NothingToClaim` when that is zero.
    function claimSide(uint256 side, address to) external returns (uint256 amount);
}
