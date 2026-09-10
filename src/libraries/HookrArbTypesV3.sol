// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Phase-bound correction types for the second modular WTH integration generation.
library HookrArbTypesV3 {
    uint8 internal constant PLAN_VERSION = 2;
    uint8 internal constant PHASE_BEFORE_SWAP = 1;
    uint8 internal constant PHASE_AFTER_SWAP = 2;
    uint8 internal constant VENUE_V3 = 1;
    uint8 internal constant VENUE_V4 = 2;

    /// @dev `routeId` commits to an immutable executor-side secondary-pool registration.
    struct ArbPlan {
        uint8 version;
        uint8 phase;
        bytes32 routeId;
        /// @notice True to buy base on Hookr then sell it externally; false for the reverse order.
        bool buyBaseOnTarget;
        uint128 baseAmount;
        uint96 minProfitQuote;
        uint160 hookrSqrtPriceLimitX96;
        uint160 externalSqrtPriceLimitX96;
        uint64 maxBlock;
        uint64 deadline;
        uint64 nonce;
    }

    struct HookData {
        address recipient;
        ArbPlan plan;
        bytes32 r;
        bytes32 s;
        uint8 v;
    }

    struct ProfitSplit {
        address creator;
        uint16 traderBps;
        uint16 creatorBps;
        uint16 triggerPoolBps;
    }

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

    /// @dev Registrations are immutable by routeId. Governance may only enable or disable them.
    struct SecondaryRoute {
        bool registered;
        bool enabled;
        uint8 venueKind;
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address venuePool;
    }
}
