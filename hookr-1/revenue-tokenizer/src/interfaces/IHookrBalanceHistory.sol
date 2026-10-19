// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Hookr balance history, part of the HookRevenue Tokenizer
/// @notice An ERC-20 that remembers, for every holder and for the earning supply, what the balance was at any
///         past snapshot block. Shares the Uniswap v4 PoolManager and 0xdead hold never earn, so they are
///         left out of the earning supply and read as zero in `balanceAt`; the revenue token adds its drop box and its
///         own address to that list.
/// @dev `clock()` is the block number the history is keyed by: `block.number` unless the token overrides it. A
///      snapshot block is `clock() - 1` at the moment a drop lands, recorded through `_recordSnapshot`. The history
///      answers exactly at every recorded snapshot block (and at any block at or after a holder's newest change);
///      between snapshot blocks it keeps only what those snapshots need, so `balanceAt` for an arbitrary other
///      block may answer with the holder's balance at a nearby change instead. Drops only ever ask about snapshot
///      blocks.
interface IHookrBalanceHistory is IERC20 {
    /// @notice A construction or seal argument is out of bounds (the revenue token shares this error for every fixed
    ///         term; here: the PoolManager address passed at construction was zero).
    error InvalidConfig();
    /// @notice `clock()` returned zero; the history needs block numbers from 1 up.
    error ClockZero();
    /// @notice A balance or the earning supply went above 2^128 - 1, which the history cannot store.
    error BalanceTooLarge(uint256 value);

    /// @notice The address Auto Burn pays to; shares there earn nothing.
    function DEAD() external view returns (address);
    /// @notice The Uniswap v4 PoolManager; shares it holds (pool liquidity) earn nothing.
    function poolManager() external view returns (address);
    /// @notice The block number the history is keyed by right now: `block.number` unless overridden.
    function clock() external view returns (uint48);
    /// @notice Whether `account`'s shares earn: false for the PoolManager and 0xdead (and whatever a token adds: the
    ///         revenue token's drop box and the revenue token itself).
    ///         The rule is fixed at construction: it depends on constants and immutables only, never on storage or
    ///         a balance, because the earning supply is kept by increments and an account that changes side would
    ///         break it.
    function earns(address account) external view returns (bool);
    /// @notice Shares that earn now: the supply less what the excluded addresses hold.
    function earningSupply() external view returns (uint256);
    /// @notice The newest snapshot block recorded, or zero before the first drop.
    function latestSnapshot() external view returns (uint48);
    /// @notice `account`'s balance at the end of `blockNumber`; zero for an excluded address. Exact when
    ///         `blockNumber` is a recorded snapshot block or at or after the account's newest change.
    function balanceAt(address account, uint48 blockNumber) external view returns (uint256);
    /// @notice The earning supply at the end of `blockNumber`. Exact when `blockNumber` is a recorded snapshot
    ///         block or at or after the newest change of the earning supply.
    function earningSupplyAt(uint48 blockNumber) external view returns (uint256);
    /// @notice How many checkpoints `account`'s history keeps right now (the newest plus the older ones kept
    ///         for recorded snapshots). For gas analysis.
    function checkpointCount(address account) external view returns (uint256);
    /// @notice How many checkpoints the earning-supply history keeps right now.
    function earningCheckpointCount() external view returns (uint256);
}
