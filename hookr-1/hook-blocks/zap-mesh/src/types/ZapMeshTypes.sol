// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title Zap mesh types
/// @notice Shared constants and structs of the zap mesh: one zap vault that feeds up to four gated target pools.
library ZapMeshTypes {
    /// @notice Each zap splits its budget across every route that can still buy, by the routes' weights.
    uint8 internal constant SPLIT_WEIGHTS = 0;
    /// @notice Each zap sends its whole budget to the one route whose target sits furthest below its weight in quote
    ///         depth, each route judged on the larger of its depth in the newest snapshot from an earlier block and its
    ///         depth now. A target with no quote depth is never chosen; what the chosen route cannot spend goes to the
    ///         other routes by weight in the same zap.
    uint8 internal constant SPLIT_FILL_GAP = 1;
    /// @notice Most routes one mesh may carry: the gated relay's feeder limit per target, applied per mesh.
    uint256 internal constant MAX_ROUTES = 4;

    /// @notice A mesh, frozen when it is created.
    /// @param targets One to four gated target pools on one HookrRoot, all trading in `quote`, each distinct. A target
    ///        need not exist yet.
    /// @param weights Each route's share in basis points, at least one each, summing to 10,000. With SPLIT_WEIGHTS it is
    ///        the share of every zap; with SPLIT_FILL_GAP it is the share of the family's quote depth the route aims for.
    /// @param quote The currency the mesh accrues and spends. One side of every target.
    /// @param rules The HookrRules every target and every source binds: source cuts and the legs' partial-fill refunds
    ///        land in that one ledger.
    /// @param gate The HookrGatedRelay every target runs as its advisory, listing that route's leg as a feeder.
    /// @param sink MODE_BUY: receives every subject bought (0xdEaD for buy-and-burn). MODE_BUY_AND_ADD: zero.
    /// @param mode ZapRelayTypes.MODE_BUY or ZapRelayTypes.MODE_BUY_AND_ADD, for every route.
    /// @param split SPLIT_WEIGHTS or SPLIT_FILL_GAP.
    /// @param impactBps Largest rise of a target's subject price within one of that route's impact windows, 1..2000.
    /// @param rewardBps Caller reward in basis points (0..100) of the quote one zap deploys across all routes.
    /// @param threshold Least claimable plus idle quote (raw units) a zap needs; at least the zap vault's MIN_THRESHOLD.
    /// @param maxPerZap Most quote one zap consumes (raw units); zero means no cap, otherwise at least `threshold`.
    /// @param windowBlocks Length of each route's impact window in blocks, 1..300.
    /// @param windowScope ZapRelayTypes.WINDOW_PER_VAULT or WINDOW_POOL_WIDE, shared by every route (the gate requires
    ///        one scope among a target's feeders).
    struct Mesh {
        PoolKey[] targets;
        uint16[] weights;
        Currency quote;
        address rules;
        address gate;
        address sink;
        uint8 mode;
        uint8 split;
        uint16 impactBps;
        uint16 rewardBps;
        uint128 threshold;
        uint128 maxPerZap;
        uint32 windowBlocks;
        uint8 windowScope;
    }

    /// @notice What one route's leg reads from its mesh when it is made.
    struct LegSpec {
        PoolKey target;
        Currency quote;
        address rules;
        address gate;
        address router;
        address sink;
        uint8 mode;
        uint16 impactBps;
        uint32 windowBlocks;
        uint8 windowScope;
    }

    /// @notice What one route did inside a zap. All amounts are raw units.
    /// @param spent Quote the buy consumed (router amountIn).
    /// @param refund The target Rules' partial-fill refund credited back to the leg, inside `spent`.
    /// @param bought Subject the buy delivered.
    /// @param liquidity Liquidity added to the leg's permanent position (MODE_BUY_AND_ADD only).
    /// @param addedQuote Quote principal paid into that position.
    /// @param addedSubject Subject principal paid into that position.
    /// @param feesQuote Quote LP fees the position had earned, collected by this add and returned to the mesh.
    /// @param feesSubject Subject LP fees the position had earned, collected likewise and kept for the next add.
    struct LegResult {
        uint256 spent;
        uint256 refund;
        uint256 bought;
        uint128 liquidity;
        uint256 addedQuote;
        uint256 addedSubject;
        uint256 feesQuote;
        uint256 feesSubject;
    }

    /// @notice What one zap did across the mesh. All amounts are raw units.
    /// @param claimed Quote the mesh claimed from HookrRules (source cuts).
    /// @param pulled Quote the legs passed back from their own Rules claims (refunds, and any other credit to a leg).
    /// @param consumed Quote this zap was allowed to use: min(idle quote after the claims, maxPerZap).
    /// @param deployed Quote the routes deployed: net buy spend (spent less refunds) plus quote added as liquidity.
    /// @param reward Quote paid to the caller's chosen recipient: rewardBps of `deployed`.
    /// @param protocolShare Hookr's share set aside by this zap: protocolShareBps of the source cuts claimed and of any
    ///        leg credit that was not a refund. Never spent by a zap.
    /// @param allocated Quote handed to each route's leg. Under SPLIT_FILL_GAP it includes the chosen route's unspent
    ///        quote handed on to the others, so the sum can exceed the budget; `deployed` never does.
    /// @param ran Bit i set when route i's leg ran; a route that was offered quote and failed keeps it idle (under
    ///        SPLIT_FILL_GAP the chosen route's quote goes on to the other routes).
    struct ZapResult {
        uint256 claimed;
        uint256 pulled;
        uint256 consumed;
        uint256 deployed;
        uint256 reward;
        uint256 protocolShare;
        uint256[4] allocated;
        uint8 ran;
    }
}
