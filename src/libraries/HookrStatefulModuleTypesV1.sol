// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookrModuleTypesV1} from "./HookrModuleTypesV1.sol";

/// @title Hookr Stateful Module Types V1
/// @notice Fixed-size action ABI for stateful policy modules admitted to HookrSwapKernelV3.
/// @dev The ABI supports codehash-pinned STATEFUL_V1 callbacks. Base Modular V3 admits only the
///      catalog's one-time canonical Native Mechanics module. The kernel bounds and executes each
///      returned donation, claim-mint, token-take, and hook-delta action plan.
library HookrStatefulModuleTypesV1 {
    bytes32 internal constant MODULE_MAGIC = keccak256("HOOKR_STATEFUL_SWAP_MODULE_V1");
    uint16 internal constant MAX_SUBJECT_TAKE_BPS = 1_000;

    struct BeforeSwapContext {
        HookrModuleTypesV1.SwapContext swapContext;
        uint24 baseLpFeePips;
    }

    /// @dev `quoteTakeAmount` is the full specified-quote hook delta. The donation is a subset;
    ///      the remainder is minted as ERC-6909 claims to `claimRecipient`.
    ///      `quoteTakePips` is a conservative runtime cap declaration, not a second fee charge.
    struct BeforeSwapResult {
        uint24 lpFeeSurchargePips;
        uint16 quoteTakeBps;
        uint24 quoteTakePips;
        uint16 quoteDonationWeightBps;
        uint16 quoteEscrowWeightBps;
        uint16 quoteRoyaltyBps;
        uint128 quoteTakeAmount;
        uint128 quoteDonationAmount;
        address claimRecipient;
        bytes32 attributionKey;
    }

    struct AfterSwapContext {
        HookrModuleTypesV1.AfterSwapContext swapContext;
        uint24 effectiveLpFeePips;
        uint128 aggregateSpecifiedQuoteTake;
        uint128 aggregateQuoteDonation;
    }

    /// @dev Exactly one of `quoteTakeAmount` and `subjectTakeAmount` may be nonzero because a v4
    ///      afterSwap hook delta is denominated in the swap's unspecified currency. V1 subject
    ///      takes are burn-only: a nonzero action must target the canonical dead address.
    struct AfterSwapResult {
        uint24 quoteTakePips;
        uint16 subjectTakeBps;
        uint128 quoteTakeAmount;
        uint128 subjectTakeAmount;
        address claimRecipient;
        address subjectRecipient;
        bytes32 quoteAttributionKey;
        bytes32 subjectAttributionKey;
    }
}
