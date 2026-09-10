// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Hookr Module Types V1
/// @notice Shared, versioned ABI for the first immutable Hookr module-stack family.
/// @dev READ_ONLY modules use STATICCALL. STATEFUL_V1 defines the codehash-pinned CALL lane; the
///      base Modular V3 catalog admits only its one-time canonical Native Mechanics module.
library HookrModuleTypesV1 {
    enum ExecutionMode {
        READ_ONLY,
        STATEFUL_V1
    }

    uint8 internal constant PHASE_BEFORE_ADD_LIQUIDITY = 1 << 0;
    uint8 internal constant PHASE_BEFORE_SWAP = 1 << 1;
    uint8 internal constant PHASE_AFTER_SWAP = 1 << 2;
    uint8 internal constant ALL_PHASES = PHASE_BEFORE_ADD_LIQUIDITY | PHASE_BEFORE_SWAP | PHASE_AFTER_SWAP;

    uint8 internal constant MAX_MODULES = 8;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant PIPS = 1_000_000;

    struct ModuleRegistration {
        bytes32 moduleKey;
        uint32 version;
        address implementation;
        bytes32 configSchemaHash;
        uint160 requiredHookFlags;
        uint8 phaseMask;
        bytes32 exclusiveGroup;
        ExecutionMode executionMode;
        uint24 maxLpFeeSurchargePips;
        uint16 maxSpecifiedQuoteTakeBps;
        uint16 maxUnspecifiedQuoteTakeBps;
        uint16 maxSubjectTakeBps;
        uint32 callbackGasLimit;
        bytes32[] requiredModuleKeys;
        bytes32[] conflictingModuleKeys;
    }

    struct ModuleSnapshot {
        bytes32 moduleId;
        bytes32 moduleKey;
        uint32 version;
        address implementation;
        bytes32 implementationCodeHash;
        bytes32 configSchemaHash;
        uint160 requiredHookFlags;
        uint8 phaseMask;
        bytes32 exclusiveGroup;
        ExecutionMode executionMode;
        uint24 maxLpFeeSurchargePips;
        uint16 maxSpecifiedQuoteTakeBps;
        uint16 maxUnspecifiedQuoteTakeBps;
        uint16 maxSubjectTakeBps;
        uint32 callbackGasLimit;
        bytes32 requirementsHash;
        bytes32 conflictsHash;
    }

    struct ModuleSelection {
        bytes32 moduleId;
        bytes config;
    }

    /// @notice Exact worst-case deltas one concrete pool config may request from the kernel.
    /// @dev The catalog snapshot remains the immutable upper bound for the module implementation;
    ///      stack admission aggregates these config-specific values so a pool may freeze lower caps.
    struct ModuleConfigCaps {
        bytes32 configHash;
        uint24 maxLpFeeSurchargePips;
        uint16 maxSpecifiedQuoteTakeBps;
        uint16 maxUnspecifiedQuoteTakeBps;
        uint16 maxSubjectTakeBps;
    }

    struct StackLimits {
        uint24 baseLpFeePips;
        uint24 maxLpFeePips;
        uint16 maxSpecifiedQuoteTakeBps;
        uint16 maxUnspecifiedQuoteTakeBps;
        uint16 maxSubjectTakeBps;
        uint32 maxTotalModuleGas;
        address trustedRouter;
        address trustedQuoter;
        /// @dev All-zero correction fields select the plain modular profile. A nonzero executor
        ///      selects the fixed WTH Arb Recapture profile and every companion field is mandatory.
        ///      These values are part of the stack hash and cannot change after pool creation.
        address correctionExecutor;
        address correctionCreator;
        uint16 correctionMaxVolumeBps;
        uint96 correctionMinProfitQuote;
        bytes32 correctionFeePolicyId;
    }

    struct StackCore {
        bool configured;
        bool initialized;
        address kernel;
        bytes32 kernelId;
        bytes32 kernelFamilyId;
        bytes32 kernelCodeHash;
        address subject;
        address quote;
        bytes32 stackHash;
        bytes32 trustedRouterIntegrationId;
        bytes32 trustedRouterCodeHash;
        bytes32 trustedQuoterIntegrationId;
        bytes32 trustedQuoterCodeHash;
        bytes32 correctionExecutorIntegrationId;
        bytes32 correctionExecutorCodeHash;
        uint8 moduleCount;
        StackLimits limits;
    }

    struct LiquidityContext {
        bytes32 poolId;
        address sender;
        address subject;
        address quote;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        bytes32 salt;
        bytes hookData;
    }

    struct SwapContext {
        bytes32 poolId;
        address sender;
        address payer;
        address recipient;
        address subject;
        address quote;
        bool trustedCaller;
        bool isBuy;
        bool exactInput;
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
        bytes hookData;
    }

    struct AfterSwapContext {
        bytes32 poolId;
        address sender;
        address payer;
        address recipient;
        address subject;
        address quote;
        bool trustedCaller;
        bool isBuy;
        bool exactInput;
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
        int128 amount0;
        int128 amount1;
        bytes hookData;
    }

    /// @dev `quoteTakeBps` always applies to quote currency. In beforeSwap it is a take from the
    ///      specified quote leg; in afterSwap it is a take from the unspecified quote leg.
    struct ModuleResult {
        uint24 lpFeeSurchargePips;
        uint16 quoteTakeBps;
        address claimRecipient;
        bytes32 attributionKey;
    }
}
