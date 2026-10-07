// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title HookrProgramTypes
/// @notice Immutable creator program terms, market units and milestone metadata.
library HookrProgramTypes {
    /// @dev A program day: daily budgets divide whole UTC days.
    uint256 internal constant DAY = 1 days;
    /// @dev Longest program, in days.
    uint256 internal constant MAX_DAYS = 366;
    /// @dev Most market scopes a program may have.
    uint256 internal constant MAX_SCOPES = 8;
    /// @dev Most milestones a program may have.
    uint256 internal constant MAX_MILESTONES = 16;
    /// @dev Largest numerator or denominator of a program rate.
    uint256 internal constant MAX_RATE = 1e18;

    /// @notice Immediate receipts (creator points only) or reviewed daily allocations from swaps, earned LP fees or
    ///         referrals (points, cash, Bux and milestones).
    enum Mode {
        Immediate,
        DailySwap,
        DailyLPFees,
        DailyReferral
    }

    /// @notice Fixed program window, lifetime caps, issuance rates and review authority.
    /// @dev Daily budgets divide whole UTC days; wallet caps span the entire program. Immediate terms carry no cash,
    ///      no global Bux and no milestones; daily terms need a distinct attestor and reviewer and a 6 to 30 day
    ///      review delay.
    struct Terms {
        Mode mode;
        bool globalBux;
        uint64 start;
        uint64 end;
        uint128 pointBudget;
        uint128 walletPointCap;
        uint128 pointNumerator;
        uint128 pointDenominator;
        uint128 dailyPointBudget;
        address rewardToken;
        uint128 cashBudget;
        uint128 walletCashCap;
        uint128 cashNumerator;
        uint128 cashDenominator;
        uint128 dailyCashBudget;
        address attestor;
        address reviewer;
        uint64 reviewDelay;
        bytes32 sourcePolicyHash;
        string name;
        string metadataURI;
        uint8 pointDecimals;
        address referralRegistry;
        uint256 baseProgramId;
    }

    /// @notice One immutable market and its fixed conversion into common program-weight units.
    /// @dev numerator/denominator normalize quote; subject rates normalize the other LP fee currency.
    struct Scope {
        address root;
        bytes32 poolId;
        bytes32 configHash;
        address quoteAsset;
        uint128 numerator;
        uint128 denominator;
        uint128 subjectNumerator;
        uint128 subjectDenominator;
    }

    /// @notice A point threshold and its finite number of onchain award reservations.
    struct Milestone {
        uint128 pointsRequired;
        uint32 maxAwards;
    }

    /// @notice Fixed metadata and transferability for a newly deployed milestone collection.
    struct NFTMetadata {
        string name;
        string symbol;
        string baseURI;
        bool transferable;
    }
}
