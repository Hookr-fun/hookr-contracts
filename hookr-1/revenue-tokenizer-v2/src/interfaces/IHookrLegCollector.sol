// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title Hookr leg collector, part of the HookRevenue Tokenizer
/// @notice Where every revenue token the tokenizer creates sends Hookr's leg of what its legged doors deliver: native
///         ETH and ERC-20s pushed in a sync. Anyone sweeps a currency's whole balance to the live HookrTreasury's
///         current `target()`. No owner, no shares: the treasury's target is read on every sweep, so the treasury's own
///         two-step target change is the only way to move where the money goes.
interface IHookrLegCollector {
    /// @notice The treasury has no code.
    error InvalidTreasury(address treasury);
    /// @notice The collector holds none of `currency`.
    error NothingToSweep(Currency currency);
    /// @notice One collection visits at most eight drops.
    error TooManyCollectionDrops(uint256 count);
    /// @notice The caller left too little gas to give item `index` its capped claim.
    error CollectionStarved(uint256 index);

    /// @notice `amount` of `currency` went to `target`.
    event Swept(Currency indexed currency, address indexed target, uint256 amount);
    /// @notice The collector's income in asset `asset` of `revenueToken`, `amount` as the token answered, was claimed to
    ///         `target`.
    event IncomeCollected(address indexed revenueToken, uint256 indexed asset, address indexed target, uint256 amount);
    /// @notice The collector's share of drop `dropId` in `revenueToken`'s drop box, `amount` as the box answered, was
    ///         claimed to `target`.
    event DropCollected(address indexed revenueToken, uint256 indexed dropId, address indexed target, uint256 amount);

    /// @notice The HookrTreasury whose `target()` every sweep pays.
    function treasury() external view returns (address);

    /// @notice Pays the collector's whole balance of `currency` (address zero is native ETH) to the treasury's
    ///         target. Anyone. Reverts `NothingToSweep` on a zero balance.
    function sweep(Currency currency) external returns (uint256 amount);

    /// @notice `sweep` for each of `currencies`, skipping those with a zero balance.
    function sweepMany(Currency[] calldata currencies) external returns (uint256[] memory amounts);

    /// @notice Claims the income the collector's shares of `revenueToken` earned there, asset by asset, straight to the
    ///         treasury's target. Anyone. For a revenue token that does not leave this collector out of `earns` (one
    ///         of another tokenizer or release); a token of this tokenizer owes it nothing. At most eight assets; each
    ///         claim gets a gas cap and a failed one is skipped with its credit intact; `CollectionStarved` before an
    ///         attempt the caller left too little gas for. An address that does not answer `assetCount`, or lists more
    ///         than eight, returns an empty list. Returns what each asset's claim answered.
    function collectIncome(address revenueToken) external returns (uint256[] memory amounts);
    /// @notice Claims the collector's share of up to eight drops in `revenueToken`'s drop box straight to the
    ///         treasury's target. Anyone. More than eight is `TooManyCollectionDrops`; unknown, claimed or failed
    ///         drops are skipped; `CollectionStarved` as in `collectIncome`. Returns what each claim answered.
    function collectDrops(address revenueToken, uint256[] calldata dropIds) external returns (uint256[] memory amounts);
}
