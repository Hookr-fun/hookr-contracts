// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title Zap relay types
/// @notice Shared constants and structs of the zap relay.
library ZapRelayTypes {
    /// @notice Every subject a zap buys goes to the route's fixed sink.
    uint8 internal constant MODE_BUY = 0;
    /// @notice A zap buys with half its budget and adds the bought subject plus the other half as permanent full-range
    ///         liquidity owned by the vault ("swap-and-add in one call"). No sink.
    uint8 internal constant MODE_BUY_AND_ADD = 1;
    /// @notice A vault measures its impact window only from its own anchor.
    uint8 internal constant WINDOW_PER_VAULT = 0;
    /// @notice A vault measures from the cheapest open anchor among every feeder of its target, read from the gate's
    ///         frozen list, so a target's feeders share one window bound.
    uint8 internal constant WINDOW_POOL_WIDE = 1;

    /// @notice keccak256("HookrZapAccrual.Terms(uint24 takePips,address vault) optional HookrSessionTiers.Tiers(uint24
    ///         regularPips,uint24 preMarketPips,uint24 afterHoursPips,uint24 overnightPips,uint24 closedPips,uint16
    ///         openRampSeconds,uint16 closeRampSeconds,uint8 flags)"), without the line breaks.
    bytes32 internal constant ACCRUAL_SCHEMA = 0x15db6c3ca0a513c3e391f86babd70b212f39ba62eaeb11f13bd505dad632ae34;
    /// @notice keccak256("HookrGatedRelay.Terms(address factory,address[] feeders) optional HookrSessionTiers.Tiers(uint24
    ///         regularPips,uint24 preMarketPips,uint24 afterHoursPips,uint24 overnightPips,uint24 closedPips,uint16
    ///         openRampSeconds,uint16 closeRampSeconds,uint8 flags)"), without the line breaks.
    bytes32 internal constant GATE_SCHEMA = 0x67fad64d676b583a8d694af1d0bfe44ab753db2e6eff0fcac13d6c25ed1b6b5e;

    /// @notice One zap route, frozen when its vault is created.
    /// @param target The gated target pool. `target.hooks` is its HookrRoot; the pool need not exist yet.
    /// @param quote The currency the route accrues and spends. One side of `target`; the other side is the subject.
    /// @param rules The HookrRules that holds the vault's claims. It must be the target root's own Rules, so source
    ///        cuts and target partial-fill refunds land in one ledger.
    /// @param gate The HookrGatedRelay the target pool must run as its advisory, listing this vault as a feeder.
    /// @param sink MODE_BUY: receives every subject bought (0xdEaD for buy-and-burn). MODE_BUY_AND_ADD: must be zero.
    /// @param mode MODE_BUY or MODE_BUY_AND_ADD.
    /// @param impactBps Largest rise of the subject's quote price this route's zaps may cause within one impact window,
    ///        measured from the price the window's first zap found, 1..2000 basis points. It is per window: it still
    ///        compounds across windows, and across a target's feeders when windowScope is WINDOW_PER_VAULT.
    /// @param rewardBps Caller reward in basis points (0..100) of the quote each zap deploys: its net buy spend (router
    ///        input less the target Rules' partial-fill refund) plus the quote it adds as liquidity. Unspent quote
    ///        earns no reward, so repeated partial fills cannot re-collect it.
    /// @param threshold Least claim + idle quote (raw units) a zap needs; at least MIN_THRESHOLD.
    /// @param maxPerZap Most quote one zap consumes (raw units); zero means no cap, otherwise at least `threshold`.
    /// @param windowBlocks Length of one impact window in blocks, 1..300: the window opens at the route's first zap
    ///        after the previous window closed and spans that block and the next windowBlocks - 1. On a Nitro chain
    ///        block.number is the parent-chain height, so a window of N blocks is about N parent-chain blocks of time.
    ///        A longer window slows how fast the route can move the target price across blocks.
    /// @param windowScope WINDOW_PER_VAULT (0) or WINDOW_POOL_WIDE (1, the default): whether the impact reference also
    ///        honours the open windows of the target's other feeders. The gate requires every feeder of one target to
    ///        share one scope.
    struct Route {
        PoolKey target;
        Currency quote;
        address rules;
        address gate;
        address sink;
        uint8 mode;
        uint16 impactBps;
        uint16 rewardBps;
        uint128 threshold;
        uint128 maxPerZap;
        uint32 windowBlocks;
        uint8 windowScope;
    }

    /// @notice Advisory bytes a source pool binds with: `abi.encode(AccrualTerms)` (64 bytes, no session surcharge) or
    ///         `abi.encode(AccrualTerms, HookrSessionTiers.Tiers)` (320 bytes, optional off-market tiers).
    /// @param takePips The buy-side quote cut in pips of the gross buyer spend, 1..100,000 (10%).
    /// @param vault A vault this factory created; it receives the cut as a HookrRules claim.
    struct AccrualTerms {
        uint24 takePips;
        address vault;
    }

    /// @notice Advisory bytes a gated target pool binds with: `abi.encode(GateTerms)` (160 to 256 bytes, no session
    ///         surcharge) or `abi.encode(GateTerms, HookrSessionTiers.Tiers)` (416 to 512 bytes, optional off-market
    ///         tiers).
    /// @param factory The HookrZapAccrual whose vaults may feed the pool; it must be admitted on the same root.
    /// @param feeders One to four vaults of `factory`, each created for this pool and this gate.
    struct GateTerms {
        address factory;
        address[] feeders;
    }

    /// @notice What one zap did. All amounts are raw units.
    /// @param claimed Quote claimed from HookrRules by this zap.
    /// @param consumed Quote this zap was allowed to use: min(balance after the claim, maxPerZap).
    /// @param spent Quote the buy consumed (router amountIn: pool input plus the target Rules' reserved take).
    /// @param bought Subject the buy delivered (to the sink in MODE_BUY, to the vault in MODE_BUY_AND_ADD).
    /// @param liquidity Liquidity added to the vault's permanent position (MODE_BUY_AND_ADD only).
    /// @param addedQuote Quote principal paid into that position.
    /// @param addedSubject Subject principal paid into that position.
    /// @param feesQuote Quote LP fees the permanent position had earned, collected by this zap's add and kept idle.
    /// @param feesSubject Subject LP fees the permanent position had earned, collected likewise.
    /// @param reward Quote paid to the caller's chosen recipient: rewardBps of (spent - the Rules refund + addedQuote).
    /// @param protocolShare Hookr's share of the source cuts this zap claimed (protocolShareBps of the claim less the
    ///        vault's own partial-fill refunds), set aside for protocolRecipient and never spent by a zap.
    struct ZapResult {
        uint256 claimed;
        uint256 consumed;
        uint256 spent;
        uint256 bought;
        uint128 liquidity;
        uint256 addedQuote;
        uint256 addedSubject;
        uint256 feesQuote;
        uint256 feesSubject;
        uint256 reward;
        uint256 protocolShare;
    }
}
