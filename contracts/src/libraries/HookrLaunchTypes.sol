// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Shared launch-configuration structs for generation 5, defined once so the launchpad and
///         its DELEGATECALL-linked library agree on their shapes. Moving them here (rather than into
///         the launchpad) is what lets `HookrLaunchpadLibV5` host the validation and pool-config
///         assembly — the bulk that pushed the launchpad past EIP-170 when inlined.

/// @notice Creator-facing hook configuration — mirrors the builder blocks.
struct HookParams {
    uint32 guardBlocks;
    uint16 maxBuyBps;
    uint24 snipeTaxPips;
    uint24 baseFeePips;
    uint24 maxFeePips;
    uint16 surgeSens;
    uint16 burnBps;
    uint96 burnTriggerWei; // deprecated; custom configs MUST set this to zero
    uint16 lpBps;
    uint16 potBps;
    uint32 potEveryNBuys;
    uint96 potMinBuyWei;
}

/// @notice A share of the creator side of pool fees. `bps` values must sum to exactly BPS.
struct FeeRecipient {
    address to;
    uint16 bps;
}

/// @notice One token-only liquidity band sitting above the migration price (bonded lane only).
struct LpTranche {
    int24 startOffset;
    int24 endOffset;
    uint16 bps;
}
