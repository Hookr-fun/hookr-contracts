// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HookrFeeConversionTypes} from "../types/HookrFeeConversionTypes.sol";
import {HookrTaxQueueTypes} from "../types/HookrTaxQueueTypes.sol";

/// @title Hookr tax queue
/// @notice Per-pool, per-direction claim queue for the directional tax. Every function here is permissionless and
///         every destination is frozen in the queue's own code, except the one the frozen protocol recipient names:
///         the protocol share, swept as quote or paid as ERC-6909 claims by the exit, goes to that HookrTreasury's
///         current `target()` (to the recipient itself when it has no code). The queue also implements
///         `IHookrStraySweep`, which only its route registry may call and which never reaches the quote asset.
interface IHookrTaxQueue {
    event Settled(uint256 income, uint256 protocolAmount, uint256 creatorAmount);
    /// @notice The Rules claim could not be pulled this time; it remains a backed Rules claim.
    event ClaimDeferred(uint256 claim);
    /// @notice The Rules claim could not be pulled as the quote token, so it left as PoolManager ERC-6909 claims of the
    ///         quote, split at the frozen share and credited at once. `protocolTo` is the account credited with the
    ///         protocol part: the frozen protocol recipient when it has no code, otherwise the current `target()` of
    ///         that HookrTreasury (zero when the frozen share is zero). `creatorRecipient` is the asset recipient of a
    ///         direct leg or the recovery recipient of a routed one.
    event ClaimPaidAsClaims(
        uint256 claim,
        address indexed protocolTo,
        uint256 protocolAmount,
        address indexed creatorRecipient,
        uint256 creatorAmount
    );
    /// @notice The booked protocol share left as quote. `recipient` is the account paid: the frozen protocol recipient
    ///         when it has no code, otherwise the current `target()` of that HookrTreasury.
    event ProtocolSwept(address indexed recipient, uint256 amount);
    event CreatorPaid(address indexed recipient, uint256 amount, bool recovered);
    event Converted(
        bytes32 indexed routeId,
        bytes32 indexed planDigest,
        address indexed recipient,
        uint256 amountIn,
        uint256 amountOut
    );

    /// @notice Returns the advisory that deployed this queue.
    function advisory() external view returns (address);

    /// @notice Returns the frozen terms read from this queue's code.
    function terms() external view returns (HookrTaxQueueTypes.Terms memory);

    /// @notice Returns the queue's ledger.
    function ledger() external view returns (HookrTaxQueueTypes.Ledger memory);

    /// @notice Quote the queue could book now: its Rules claim plus any unbooked balance.
    function pending() external view returns (uint256);

    /// @notice Pulls the queue's Rules claim and books every unbooked quote unit, split once at the frozen share.
    function settle() external returns (uint256 income);

    /// @notice Settles, then pays the whole protocol share as quote to the account the frozen protocol recipient names:
    ///         the recipient itself when it has no code, otherwise that HookrTreasury's current `target()`.
    function sweepProtocol() external returns (uint256 amount);

    /// @notice Settles, then pays the whole creator share as quote to `assetRecipient`. Only when no route is set.
    function payCreator() external returns (uint256 amount);

    /// @notice Settles, then converts `plan.amountIn` of the creator share through the signed route to `assetRecipient`.
    function process(
        HookrFeeConversionTypes.ExecutionPlan calldata plan,
        bytes calldata signature,
        bytes calldata routeData
    ) external returns (uint256 delivered, bytes32 planDigest);

    /// @notice Settles, then pays the creator share as quote to `recoveryRecipient`, once the route is retired and the
    ///         recovery delay has passed, or once the booked share has waited the stale delay with no successful
    ///         conversion.
    function recover() external returns (uint256 amount);

    /// @notice Routed queues: when the current wait of the booked creator share began (zero when nothing waits).
    ///         Stale recovery opens `staleRecoveryDelay()` after this time.
    function creatorWaitingSince() external view returns (uint256);

    /// @notice Routed queues: the frozen wait, in seconds, after which a booked creator share with no successful
    ///         conversion can be recovered as quote. Zero on a direct-payout queue.
    function staleRecoveryDelay() external view returns (uint256);

    /// @notice Returns whether the ledger identities hold and the booked quote is held.
    function accountingInvariant() external view returns (bool);
}
