// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title IHookrLaneEvents
/// @notice The events and errors of a Hookr root's arb recapture lane. HookrLane runs at the root's address by
///         DELEGATECALL and emits and reverts with them there, so IHookrLaneRoot, HookrLane and HookrRoot inherit this
///         one declaration.
interface IHookrLaneEvents {
    /// @notice A push came from a caller, pool, amount or base the open frame does not accept.
    error SinkClosed();
    /// @notice The root's claims in the pushed currency do not back the pushes made so far.
    error SinkUnbacked();
    /// @notice The executor left an unsettled delta in `currency`.
    error LaneLeftDelta(address currency);
    /// @notice The executor left the PoolManager synced to `currency`.
    error LaneLeftSync(address currency);
    /// @notice The executor's `executeArbitrage` did not return exactly one word.
    error LaneBadReturn();

    /// @notice The root's claims in `currency` were not back at the frame's snapshot once its push moved on: a claim
    ///         minted to the root and not pushed.
    error LaneStrayClaims(address currency);
    /// @notice Too little gas is left for the pushes the frame made.
    error LaneOutOfGas();
    /// @notice A pool's legs in the frame must all run in one direction.
    error LegDirection();
    /// @notice The frame already runs legs on the most lane siblings it allows.
    error LegFamilyFull();
    /// @notice A lane call has `available` gas, below the `required` floor.
    error InsufficientLaneGas(uint256 available, uint256 required);
    /// @notice The PoolManager is synced to a currency, so no frame can open.
    error SyncPending();

    /// @notice Pool `id` froze its lane at initialization: `executor`, its runtime `codeHash`, the partner share
    ///         `partnerBps` and the lane `family`.
    /// @param id The pool.
    /// @param executor The frozen lane executor.
    /// @param codeHash The executor's runtime codehash, frozen with it.
    /// @param partnerBps The frozen partner share of each arb recapture's realized profit.
    /// @param family The frozen lane family: zero, or the launcher-scoped family whose siblings take legs.
    event PoolLane(PoolId indexed id, address indexed executor, bytes32 codeHash, uint16 partnerBps, bytes32 family);

    /// @notice One arb recapture ran: the profit the executor reported and what it pushed, both in `currency`.
    ///         The event keeps its pre-release name for ABI and topic0 stability.
    /// @param id The pool.
    /// @param phase The phase: 1 before the swap is quoted, 2 after it settles.
    /// @param trader The after-phase's authenticated payer, or zero.
    /// @param reportedProfit The profit the executor's push reports at the pool's frozen partner share; not proof of
    ///         payment.
    /// @param pushed What the executor pushed.
    /// @param currency The currency of the push.
    event CorrectionSucceeded(
        PoolId indexed id,
        uint8 indexed phase,
        address indexed trader,
        uint256 reportedProfit,
        uint256 pushed,
        Currency currency
    );

    /// @notice `sweepClaims` moved `amount` of the root's `currency` claims to lane pool `id`'s Rules for the protocol.
    /// @param id The lane pool whose Rules received the claims.
    /// @param currency The currency swept.
    /// @param amount The amount swept.
    event ClaimsSwept(PoolId indexed id, Currency indexed currency, uint256 amount);

    /// @notice An arb recapture frame on pool `id` did not complete in `phase` (it reverted, or returned other than 64
    ///         bytes); a reverted frame is unwound and the swap goes on. The event keeps its pre-release name for ABI
    ///         and topic0 stability.
    /// @param id The pool.
    /// @param phase The phase: before the swap is quoted or after it settles.
    /// @param trader The after-phase's authenticated payer, or zero.
    /// @param reason The first four bytes of the frame's revert data (for example LaneOutOfGas), or zero.
    event CorrectionFailed(PoolId indexed id, uint8 indexed phase, address indexed trader, bytes4 reason);

    /// @notice The lane on pool `id` was skipped in `phase` because the executor's runtime code differs from the
    ///         frozen codehash. Emitted only in the before-phase.
    /// @param id The pool.
    /// @param phase The phase, always the before-phase.
    event LaneCodeChanged(PoolId indexed id, uint8 indexed phase);
}
