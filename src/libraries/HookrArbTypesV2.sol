// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Fixed-size calldata shared by HookrHookV6, its canonical router, and HookrArbExecutorV2.
/// @dev There are no arbitrary targets, paths, approvals, or dynamically-sized route bytes.
library HookrArbTypesV2 {
    uint8 internal constant PLAN_VERSION = 1;
    uint8 internal constant VENUE_V3 = 1;
    uint8 internal constant VENUE_V4 = 2;

    /// @notice One signed same-pair correction candidate.
    /// @dev `baseAmount` is exact on both legs: one leg buys that amount and the other sells it.
    ///      For v3, `externalTickSpacing` must be zero. For v4 it identifies a hookless static-fee
    ///      pool on the executor's immutable PoolManager.
    struct ArbPlan {
        uint8 version;
        uint8 venueKind;
        uint24 externalFee;
        int24 externalTickSpacing;
        uint128 baseAmount;
        uint96 minProfitQuote;
        uint160 hookrSqrtPriceLimitX96;
        uint160 externalSqrtPriceLimitX96;
        uint64 maxBlock;
        uint64 deadline;
        uint64 nonce;
    }

    /// @notice Canonical V6 hook payload. `abi.encode(HookData)` is exactly 480 bytes.
    /// @dev A zero-version plan means "no arb candidate" while preserving the recipient binding
    ///      required by jackpot and output-recipient accounting.
    struct HookData {
        address recipient;
        ArbPlan plan;
        bytes32 r;
        bytes32 s;
        uint8 v;
    }

    /// @notice Pool-bound share fields for the fixed realized-profit policy.
    /// @dev The three basis-point fields MUST sum to 8_000. `creator` is meaningful only when
    ///      `creatorBps` is non-zero; the authenticated swap recipient remains request-scoped so
    ///      value is not stranded in routers or aggregators.
    struct ProfitSplit {
        address creator;
        uint16 traderBps;
        uint16 creatorBps;
        uint16 triggerPoolBps;
    }

    /// @notice Hook-authenticated request passed to the executor after the triggering swap.
    struct ExecutionRequest {
        PoolKey targetKey;
        bool outerZeroForOne;
        uint128 triggerBaseAmount;
        address rebateRecipient;
        uint16 maxArbVolumeBps;
        ProfitSplit profitSplit;
        uint96 poolMinProfitQuote;
        ArbPlan plan;
        bytes32 r;
        bytes32 s;
        uint8 v;
    }
}
