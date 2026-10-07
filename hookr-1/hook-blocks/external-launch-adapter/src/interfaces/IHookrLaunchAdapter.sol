// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IHookrLaunchAdapter
/// @notice One adapter per external-hook initialization protocol. The launcher calls the three steps in order
///         inside one transaction and gives the adapter nothing else: no arbitrary call, no delegatecall, no
///         allowance beyond the launch amounts
/// @dev ABI copied unchanged from the Hookr 1 draft (hookr-modular-hooks, branch nodes/hookr-1-architecture,
///      docs/architecture/interfaces/IHookrLaunchAdapter.sol; identical on review/nodes/final-review-roadmap). Only
///      the pragma moved from ^0.8.24 to ^0.8.37. The draft text follows.
///      A v4 pool has one hook, so a pool opened on an external hook runs none of Hookr's rules; Hookr provides the
///      token, the founding liquidity where the hook permits it, the optional initial buy, the listing, discovery
///      and analytics. The adapter is admitted by code hash in the registry and named by the external hook's
///      record. It must not hold funds between steps and must not own the pool after `seed` returns; residue goes
///      back to the launcher, never to the adapter. The whole launch reverts as a unit: a half-initialized
///      external pool is worse than none.
///      Amendments: A1, a launcher-owned v4 position is placed through
///      the launcher's typed `IHookrSeedHost.seedPosition` callback, because a position belongs to whoever calls
///      `modifyLiquidity`;
///      A2, an owner-initialized protocol whose shares cannot be transferred (DualPool) has its adapter as the
///      hook's owner of record and an escrow ledger that only the launcher can release (`IHookrShareEscrow`).
interface IHookrLaunchAdapter {
    /// @notice What the launcher intends to open
    /// @param subject The subject token
    /// @param quote The quote currency
    /// @param fee The LP fee in pips, as the key carries it
    /// @param tickSpacing The tick spacing of the pool
    /// @param sqrtPriceX96 The opening price, as a Q64.96 sqrt price
    /// @param subjectAmount The subject amount the launcher funds for seeding
    /// @param quoteAmount The quote amount the launcher funds for seeding
    /// @param feeRecipient The address that collects the founding position's fees
    /// @param protocolData Bytes the adapter's protocol needs, opaque to the launcher
    struct LaunchIntent {
        Currency subject;
        Currency quote;
        uint24 fee;
        int24 tickSpacing;
        uint160 sqrtPriceX96;
        uint256 subjectAmount;
        uint256 quoteAmount;
        address feeRecipient;
        bytes protocolData;
    }

    /// @notice What seeding used and produced
    /// @param subjectUsed The subject amount seeding consumed
    /// @param quoteUsed The quote amount seeding consumed
    /// @param receipt An identifier the launcher records: a position id, a share amount, or a hash the hook emits
    struct Seeded {
        uint256 subjectUsed;
        uint256 quoteUsed;
        bytes32 receipt;
    }

    /// @notice Thrown when the intent contradicts the hook's fixed requirements
    /// @param reason A short code naming the requirement the intent contradicts
    error UnsupportedIntent(bytes32 reason);
    /// @notice Thrown when the caller is not the launcher
    error NotLauncher();

    /// @notice The identifier of the initialization protocol this adapter speaks
    /// @return The protocol id
    function initProtocolId() external pure returns (bytes32);

    /// @notice Validates the intent against the hook and returns the exact key the launcher will record
    /// @dev Must revert on a dynamic fee, a native currency or a liquidity path the hook rejects; never guesses
    /// @param hook The external hook from the registry record
    /// @param intent What the launcher intends to open
    /// @return key The exact key the launcher records
    function prepare(address hook, LaunchIntent calldata intent) external view returns (PoolKey memory key);

    /// @notice Initializes the pool through the hook's own entry or through the PoolManager
    /// @param key The key `prepare` returned
    /// @param intent What the launcher intends to open
    /// @return id The pool id
    function initialize(PoolKey calldata key, LaunchIntent calldata intent) external returns (PoolId id);

    /// @notice Places founding liquidity by the path the hook permits and returns what was used
    /// @dev For a v4 position the launcher is the owner; for hook-internal shares the launcher is the holder and
    ///      escrows them
    /// @param key The key `prepare` returned
    /// @param intent What the launcher intends to open
    /// @return seeded What seeding used and produced
    function seed(PoolKey calldata key, LaunchIntent calldata intent) external payable returns (Seeded memory seeded);
}
