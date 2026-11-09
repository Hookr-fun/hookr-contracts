// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title Pons V2 launch factory, the subset the Pons adapter uses
/// @notice The creator fee right of a Pons launch is an address in this factory. The current recipient hands it on
///         at once with `transferCreatorFeeRecipient`; the factory owner can propose another recipient for any
///         launch, which anyone executes after a three-day timelock and within a three-day window after it. A
///         creator transfer never cancels a pending proposal: a matured proposal wins.
/// @dev Verified source on Robinhood Chain 4663: `PonsV2LaunchFactory`, solc 0.8.35 (Sourcify exact match).
interface IPonsV2LaunchFactory {
    /// @notice Where a launch is in its life: trading on its bonding curve, drained, in its Uniswap v4 pool, or
    ///         rescued.
    enum GraduationPhase {
        NotGraduated,
        Swept,
        PoolCreated,
        Rescued
    }

    /// @notice The factory's record of one launch.
    /// @param creatorFeeRecipient The creator right: who claims the creator's share of the fees from the escrow.
    /// @param pairToken The quote asset the launch trades against; address zero is native ETH.
    /// @param poolFee The pool's fee, with `tickSpacing` and the meme hook the pool key once graduated.
    /// @param phase Which contract pays the creator right: the curve before `PoolCreated`, the meme hook after.
    struct LaunchedToken {
        address token;
        address curve;
        address deployer;
        address creatorFeeRecipient;
        address pairToken;
        uint256 graduationThreshold;
        uint24 poolFee;
        int24 tickSpacing;
        uint16 creatorTaxBps;
        bool buybackEnabled;
        GraduationPhase phase;
        uint256 sweptQuote;
        uint256 sweptTokens;
        uint256 sweptAt;
        bool exists;
    }

    /// @notice The owner proposed `proposedRecipient` for `token`, executable from `effectiveAt` until `expiresAt`.
    event CreatorFeeRecipientChangeProposed(
        address indexed token,
        address indexed currentRecipient,
        address indexed proposedRecipient,
        uint256 effectiveAt,
        uint256 expiresAt
    );
    /// @notice `token`'s creator right moved from `previousRecipient` to `newRecipient`.
    event CreatorFeeRecipientUpdated(
        address indexed token, address indexed previousRecipient, address indexed newRecipient
    );

    /// @notice The owner's timelock on a proposed override: 3 days.
    function CREATOR_FEE_RECIPIENT_TIMELOCK() external view returns (uint256);
    /// @notice How long a matured override stays executable: 3 days.
    function CREATOR_FEE_RECIPIENT_EXECUTION_WINDOW() external view returns (uint256);
    /// @notice The shared fee escrow every creator right claims from.
    function feeEscrow() external view returns (address);
    /// @notice The shared meme hook of every graduated pool.
    function memeHook() external view returns (address);
    /// @notice The shared buyback vault.
    function buybackVault() external view returns (address);
    /// @notice The record of `token`; `exists` false for a token this factory did not launch.
    function getLaunchedToken(address token) external view returns (LaunchedToken memory);
    /// @notice The owner's pending override of `token`'s creator right, or zero fields.
    function pendingCreatorFeeRecipient(address token)
        external
        view
        returns (address newRecipient, uint256 effectiveAt, uint256 expiresAt);
    /// @notice Hands `token`'s creator right to `newRecipient`. Only the current recipient; at once.
    function transferCreatorFeeRecipient(address token, address newRecipient) external;
}

/// @title Pons V2 fee escrow, the subset the Pons adapter uses
/// @notice Every recipient's claimable balance, native and per ERC-20. Pays only the caller.
/// @dev Verified source on Robinhood Chain 4663: `PonsV2FeeEscrow`, solc 0.8.35.
interface IPonsV2FeeEscrow {
    /// @notice The caller's claimable native ETH.
    function balanceOf(address recipient) external view returns (uint256);
    /// @notice The caller's claimable balance of `token`.
    function balanceOfToken(address recipient, address token) external view returns (uint256);
    /// @notice Pays the caller its whole native balance; reverts on zero.
    function claim() external returns (uint256 amount);
    /// @notice Pays the caller its whole balance of `token`; reverts on zero.
    function claimToken(address token) external returns (uint256 amount);
}

/// @title Pons V2 meme hook, the subset the Pons adapter uses
/// @notice The hook of every graduated Pons pool: it takes the hook fee and the creator tax on each swap, keeps
///         them pending per pool, and on a sweep converts, buys back and credits the escrow.
/// @dev Verified source on Robinhood Chain 4663: `PonsV2MemeHook`, solc 0.8.35.
interface IPonsV2MemeHook {
    /// @notice A registered pool: `creator` is the current creator fee recipient the sweep credits; `quoteToken`
    ///         is address zero for native ETH.
    function launches(PoolId poolId)
        external
        view
        returns (
            bool registered,
            bool memecoinIsCurrency0,
            address memecoin,
            address quoteToken,
            address creator,
            address buybackCreatorRecipient,
            address protocolFeeRecipient,
            uint16 creatorTaxBps,
            uint16 protocolFeeShareBps,
            uint16 buybackBurnBps,
            uint16 hookFeeBps,
            uint16 maxInternalPriceImpactBps,
            bool buybackEnabled
        );
    /// @notice Hook fees of `poolId` pending in `currency`.
    function pendingFees(PoolId poolId, address currency) external view returns (uint256 amount);
    /// @notice Creator tax of `poolId` pending in `currency`.
    function pendingCreatorTax(PoolId poolId, address currency) external view returns (uint256 amount);
    /// @notice The buyback slice of `poolId` pending in `currency`.
    function pendingBuyback(PoolId poolId, address currency) external view returns (uint256 amount);
    /// @notice The operator that may sweep when a conversion or a buyback is needed.
    function feeSweepOperator() external view returns (address);
    /// @notice Converts, buys back and credits the escrow. The operator, or the pool's creator when no internal
    ///         swap is needed (nothing pending in the memecoin and no buyback pending in the quote).
    function sweepPoolFees(PoolId poolId, uint256 minConversionQuoteOut, uint256 minBuybackTokensOut) external;
}

/// @title Pons V2 buyback vault, the subset the Pons adapter uses
/// @notice Holds every launch's bought-back memecoin and vests it over five years. A release credits the escrow:
///         the creator recipient's share to the creator recipient, the rest to the protocol.
/// @dev Verified source on Robinhood Chain 4663: `PonsV2BuybackVault`, solc 0.8.35. `release` may be called only by
///      the two recipients a release pays; the factory moves `creatorRecipient` with the creator right.
interface IPonsV2BuybackVault {
    /// @notice The recipients of `token`'s releases and the protocol's share of each.
    function vestingTerms(address token)
        external
        view
        returns (address creatorRecipient, address protocolRecipient, uint16 protocolFeeShareBps);
    /// @notice What a release of `token` would move now.
    function releasable(address token) external view returns (uint256);
    /// @notice Releases what vested and credits the escrow. Only `token`'s creator or protocol recipient.
    function release(address token) external returns (uint256 released);
}
