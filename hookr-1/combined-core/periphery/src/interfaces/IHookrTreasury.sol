// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IHookrTreasury
/// @notice Collects and forwards protocol-owned claims; holds no user reward ledger.
interface IHookrTreasury {
    /// @notice The caller is not the owner.
    error NotOwner();
    /// @notice The caller is not the nominated owner.
    error NotPendingOwner();
    /// @notice Only the treasury itself may call this.
    error NotSelf();
    /// @notice An address argument is zero, repeats the current owner or holds no code where the call needs it.
    error InvalidAddress();
    /// @notice The source cannot be admitted: it is zero, this treasury, the destination or a pending one, holds no
    ///         code or is a delegation, is listed or pending as an integrator, or does not name this treasury as its
    ///         protocol recipient and the treasury's PoolManager as its own.
    error InvalidSource();
    /// @notice The source is already admitted.
    error SourceAlreadyAdmitted();
    /// @notice The source no longer runs the runtime codehash it was admitted with.
    error SourceCodeChanged();
    /// @notice The destination is the one already in force, or cannot receive protocol funds.
    error InvalidTarget();
    /// @notice The proposed destination `pendingTarget` can be accepted from `readyAt`.
    error TargetNotReady(address pendingTarget, uint256 readyAt);
    /// @notice The proposed destination `pendingTarget` could be accepted until `expiredAt` and no longer can be.
    error TargetExpired(address pendingTarget, uint256 expiredAt);
    /// @notice `account` is an EIP-7702 delegation, not contract code or a plain account.
    error DelegatedAccount(address account);
    /// @notice No destination is pending.
    error NoPendingTarget();
    /// @notice The call re-entered the treasury.
    error Reentrancy();
    /// @notice The source reported paying `reported`, but the destination received `received`.
    error ReceiptMismatch(uint256 reported, uint256 received);
    /// @notice The proposal is out of bounds, repeats the terms in force, or names an account that cannot take them.
    error InvalidTerms();
    /// @notice No proposal is pending for these terms.
    error NoPendingTerms();
    /// @notice The proposed terms can be accepted from `readyAt`.
    error TermsNotReady(uint256 readyAt);
    /// @notice The proposed terms could be accepted until `expiredAt` and no longer can be.
    error TermsExpired(uint256 expiredAt);
    /// @notice `account` is neither on the integrator list nor the subject of a pending proposal.
    error NotListed(address account);

    /// @notice An owner was nominated.
    /// @param pendingOwner The nominee, or zero when the nomination was cancelled.
    event OwnershipProposed(address indexed pendingOwner);
    /// @notice The nominee accepted ownership.
    /// @param previousOwner The former owner.
    /// @param newOwner The new owner.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    /// @notice The destination for protocol-owned funds changed.
    /// @param previousTarget The former destination.
    /// @param newTarget The new destination.
    event TargetSet(address indexed previousTarget, address indexed newTarget);
    /// @notice A new destination was proposed.
    /// @param currentTarget The destination in force.
    /// @param pendingTarget The proposed destination.
    /// @param readyAt The timestamp from which it can be accepted.
    event TargetProposed(address indexed currentTarget, address indexed pendingTarget, uint256 readyAt);
    /// @notice The pending destination proposal was withdrawn.
    /// @param pendingTarget The withdrawn destination.
    event TargetProposalCancelled(address indexed pendingTarget);
    /// @notice A claims source was admitted.
    /// @param source The source.
    /// @param codeHash The runtime codehash it was admitted with.
    event SourceAdmitted(address indexed source, bytes32 indexed codeHash);
    /// @notice The owned-root registry changed.
    /// @param previous The former registry, or zero.
    /// @param current The new registry, or zero.
    event OwnedRootRegistrySet(address indexed previous, address indexed current);
    /// @notice A source's claim was collected into the treasury.
    /// @param source The claims source.
    /// @param currency The currency collected.
    /// @param to The account the claim was paid to.
    /// @param amount The amount collected.
    event ProtocolCollected(address indexed source, Currency indexed currency, address indexed to, uint256 amount);
    /// @notice Protocol funds reached the destination.
    /// @param currency The currency forwarded.
    /// @param target The destination.
    /// @param amount The amount forwarded.
    event ProtocolForwarded(Currency indexed currency, address indexed target, uint256 amount);
    /// @notice A delivery to the destination failed and the funds wait for a retry.
    /// @param currency The currency deferred.
    /// @param target The destination.
    /// @param amount The amount deferred.
    event ProtocolForwardDeferred(Currency indexed currency, address indexed target, uint256 amount);
    /// @notice A governed rule-share floor was proposed.
    /// @param current The floor in force, in basis points.
    /// @param proposed The proposed floor, in basis points.
    /// @param readyAt The timestamp from which it can be accepted.
    event RuleShareFloorProposed(uint16 current, uint16 proposed, uint256 readyAt);
    /// @notice The pending rule-share floor proposal was withdrawn.
    /// @param proposed The withdrawn floor, in basis points.
    event RuleShareFloorProposalCancelled(uint16 proposed);
    /// @notice The governed rule-share floor changed.
    /// @param previous The former floor, in basis points.
    /// @param current The new floor, in basis points.
    event RuleShareFloorSet(uint16 previous, uint16 current);
    /// @notice An integrator listing or re-rate was proposed.
    /// @param account The integrator.
    /// @param current The rate in force, in basis points, zero when not listed.
    /// @param proposed The proposed rate, in basis points.
    /// @param readyAt The timestamp from which it can be accepted.
    event IntegratorProposed(address indexed account, uint16 current, uint16 proposed, uint256 readyAt);
    /// @notice A pending integrator proposal was withdrawn.
    /// @param account The integrator.
    /// @param proposed The withdrawn rate, in basis points.
    event IntegratorProposalCancelled(address indexed account, uint16 proposed);
    /// @notice An integrator's rate changed.
    /// @param account The integrator.
    /// @param previous The former rate, in basis points, zero when it was not listed.
    /// @param current The new rate, in basis points.
    event IntegratorSet(address indexed account, uint16 previous, uint16 current);
    /// @notice An integrator was taken off the list.
    /// @param account The integrator.
    /// @param previous The rate it had, in basis points.
    event IntegratorRemoved(address indexed account, uint16 previous);
    /// @notice A Hookr minimum was proposed for one kind of pool.
    /// @param recapture True for pools with arb recapture on, false for pools without.
    /// @param current The minimum in force, in pips.
    /// @param proposed The proposed minimum, in pips.
    /// @param readyAt The timestamp from which it can be accepted.
    event MinFeeProposed(bool indexed recapture, uint16 current, uint16 proposed, uint256 readyAt);
    /// @notice A pending Hookr minimum proposal was withdrawn.
    /// @param recapture True for pools with arb recapture on, false for pools without.
    /// @param proposed The withdrawn minimum, in pips.
    event MinFeeProposalCancelled(bool indexed recapture, uint16 proposed);
    /// @notice The Hookr minimum of one kind of pool changed.
    /// @param recapture True for pools with arb recapture on, false for pools without.
    /// @param previous The former minimum, in pips.
    /// @param current The new minimum, in pips.
    event MinFeeSet(bool indexed recapture, uint16 previous, uint16 current);

    /// @notice An integrator's Hookr minimum override was proposed.
    /// @dev Override values are pips, or NO_MIN_FEE_OVERRIDE for none.
    /// @param account The integrator.
    /// @param current The override in force, in pips, or NO_MIN_FEE_OVERRIDE.
    /// @param proposed The proposed override, in pips, or NO_MIN_FEE_OVERRIDE.
    /// @param readyAt The timestamp from which it can be accepted.
    event IntegratorMinFeeProposed(address indexed account, uint16 current, uint16 proposed, uint256 readyAt);
    /// @notice A pending override proposal was withdrawn.
    /// @param account The integrator.
    /// @param proposed The withdrawn override, in pips.
    event IntegratorMinFeeProposalCancelled(address indexed account, uint16 proposed);
    /// @notice An integrator's Hookr minimum override changed.
    /// @param account The integrator.
    /// @param previous The former override, in pips, or NO_MIN_FEE_OVERRIDE.
    /// @param current The new override, in pips, or NO_MIN_FEE_OVERRIDE.
    event IntegratorMinFeeSet(address indexed account, uint16 previous, uint16 current);
    /// @notice An integrator approved, or withdrew its approval of, a pool binding its Hookr minimum override.
    /// @param account The integrator.
    /// @param id The pool.
    /// @param approved Whether the pool is now approved.
    event MinFeePoolApproved(address indexed account, PoolId indexed id, bool approved);

    /// @notice A change of owner voided every per-account fee-terms proposal (integrator listings and re-rates, Hookr
    ///         minimum overrides) made before owner epoch `epoch`. The floor, minimum and owned-root fee proposals it
    ///         voided emit their own cancellation events.
    /// @param epoch The owner epoch the change of owner started.
    event FeeTermsProposalsVoided(uint64 indexed epoch);

    /// @notice An owned-root fee was proposed.
    /// @dev Owned-root fee values are in the native currency's base units (wei).
    /// @param current The fee in force, in base units of the native currency.
    /// @param proposed The proposed fee, in base units of the native currency.
    /// @param readyAt The timestamp from which it can be accepted.
    event OwnedRootFeeProposed(uint256 current, uint256 proposed, uint256 readyAt);
    /// @notice The pending owned-root fee proposal was withdrawn.
    /// @param proposed The withdrawn fee, in base units of the native currency.
    event OwnedRootFeeProposalCancelled(uint256 proposed);
    /// @notice The owned-root fee changed.
    /// @param previous The former fee, in base units of the native currency.
    /// @param current The new fee, in base units of the native currency.
    event OwnedRootFeeSet(uint256 previous, uint256 current);

    /// @notice Return the gas limit for one isolated delivery attempt.
    /// @return The gas limit of one delivery attempt.
    function DELIVERY_GAS() external view returns (uint256);

    /// @notice Return the notice period between proposing and accepting a new destination.
    /// @return The notice period in seconds.
    function TARGET_DELAY() external view returns (uint256);

    /// @notice Return how long a matured destination proposal stays acceptable.
    /// @return The grace period in seconds.
    function TARGET_GRACE() external view returns (uint256);

    /// @notice Return the PoolManager shared by admitted claims sources.
    /// @return The PoolManager.
    function poolManager() external view returns (IPoolManager);

    /// @notice Return the owner authorized to admit sources and change destinations.
    /// @return The owner.
    function owner() external view returns (address);

    /// @notice Return the nominated owner, or zero if no transfer is pending.
    /// @return The nominee, or zero.
    function pendingOwner() external view returns (address);

    /// @notice Return the destination for protocol-owned funds.
    /// @return The destination.
    function target() external view returns (address);

    /// @notice Return the proposed next destination, or zero if none is pending.
    /// @return The proposed destination, or zero.
    function pendingTarget() external view returns (address);

    /// @notice Return the timestamp from which the pending destination can be accepted.
    /// @return The timestamp from which the pending destination can be accepted.
    function targetReadyAt() external view returns (uint256);

    /// @notice Return the admitted runtime hash of a claims source, or zero if unadmitted.
    /// @param source The claims source.
    /// @return The admitted runtime codehash, or zero.
    function sourceCodeHash(address source) external view returns (bytes32);

    /// @notice Propose the next owner; zero cancels the pending proposal.
    /// @param nextOwner The nominee, or zero to cancel the pending nomination.
    function proposeOwner(address nextOwner) external;

    /// @notice Accept ownership as the nominated owner; clears any pending destination.
    function acceptOwnership() external;

    /// @notice Propose a new destination for protocol-owned funds, effective after `TARGET_DELAY`.
    /// @param nextTarget The proposed destination.
    function proposeTarget(address nextTarget) external;

    /// @notice Withdraw the pending destination proposal.
    function cancelTarget() external;

    /// @notice Accept the matured destination proposal within `TARGET_GRACE` of maturity.
    function acceptTarget() external;

    /// @notice Admit a reviewed source that assigns protocol claims to this treasury. An account that is on the
    ///         integrator list or has a pending proposal to be listed is refused.
    /// @param source The reviewed source to admit.
    function admitSource(address source) external;

    /// @notice Return the registry whose owned roots' companion Rules are admitted as sources on their first
    ///         collection, or zero for none.
    /// @return The owned-root registry, or zero.
    function ownedRootRegistry() external view returns (address);

    /// @notice Name the registry whose owned roots' companion Rules are admitted as sources on their first collection,
    ///         or zero to admit no further companion that way; effective at once. Sources already admitted stay
    ///         admitted. Owner only.
    /// @param registry The registry, or zero for none.
    function setOwnedRootRegistry(address registry) external;

    /// @notice Collect this treasury's claims and attempt delivery to its target.
    /// @dev The source is an admitted source, or an owned root's companion Rules the owned-root registry vouches for,
    ///      admitted on this first collection; either way it must still run its admitted runtime codehash.
    /// @param source The claims source.
    /// @param currency The currency to collect.
    /// @return received The measured receipt, excluding the treasury's prior balance.
    function collect(address source, Currency currency) external returns (uint256 received);

    /// @notice Pay this treasury's claim from an admitted source, or an owned root's companion Rules, directly to the
    ///         current target. Permissionless.
    /// @param source The claims source.
    /// @param currency The currency to collect.
    /// @return received The target's measured receipt, equal to the source's reported payment.
    function collectTo(address source, Currency currency) external returns (uint256 received);

    /// @notice Credit this treasury's claim from an admitted Rules source, or an owned root's companion Rules, to the
    ///         current target as PoolManager ERC-6909 claims. Moves no token. Only the owner or the current target can
    ///         call.
    /// @param source The claims source.
    /// @param currency The currency to collect.
    /// @return received The target's measured ERC-6909 receipt, equal to the source's reported payment.
    function collectAsClaims(address source, Currency currency) external returns (uint256 received);

    /// @notice Retry deferred protocol funds or forward an unassigned donation.
    /// @param currency The currency to forward.
    /// @return amount The balance selected for delivery.
    /// @return delivered Whether delivery completed.
    function forwardBalance(Currency currency) external returns (uint256 amount, bool delivered);

    /// @notice Transfer protocol funds inside a failure-isolated self-call.
    /// @param currency The currency to send.
    /// @param to The recipient.
    /// @param amount The amount to send.
    function deliver(Currency currency, address to, uint256 amount) external;

    /// @notice Return the notice period between proposing and accepting a fee-terms change (governed floor or
    ///         integrator rate): 30 minutes.
    /// @return The notice period in seconds.
    function TERMS_DELAY() external view returns (uint256);

    /// @notice Return how long a matured fee-terms proposal stays acceptable.
    /// @return The grace period in seconds.
    function TERMS_GRACE() external view returns (uint256);

    /// @notice Return the highest governed rule-share floor, in basis points: 5,000.
    /// @return The highest floor, in basis points.
    function MAX_RULE_SHARE_FLOOR_BPS() external view returns (uint16);

    /// @notice Return the highest integrator rate, in basis points of Hookr's rule-fee share: 5,000.
    /// @return The highest integrator rate, in basis points.
    function MAX_INTEGRATOR_BPS() external view returns (uint16);

    /// @notice Return the integrator rate the app pre-fills: 5,000, half of Hookr's rule-fee share.
    /// @return The pre-filled integrator rate, in basis points.
    function DEFAULT_INTEGRATOR_BPS() external view returns (uint16);

    /// @notice Return the highest Hookr minimum, in pips of a swap: 10,000 (1%).
    /// @return The highest Hookr minimum, in pips.
    function MAX_MIN_FEE_PIPS() external view returns (uint16);

    /// @notice Return the Hookr minimum both rates start at: 1,000 pips (0.1%).
    /// @return The starting Hookr minimum, in pips.
    function DEFAULT_MIN_FEE_PIPS() external view returns (uint16);

    /// @notice Return the override value that means none: type(uint16).max.
    /// @return The sentinel meaning no override.
    function NO_MIN_FEE_OVERRIDE() external view returns (uint16);

    /// @notice What a Rules reads once when it binds a pool: the governed floor of the pool's protocolShareBps
    ///         (the Rules apply the larger of it and their own immutable floor), `integrator`'s rate on the list,
    ///         zero when it is not listed (always zero for the zero address), and the Hookr minimum in pips for a pool
    ///         with arb recapture on (`recapture`) or without: `integrator`'s override when it has one and approved
    ///         pool `id`, else the rate for that kind of pool. HookrRules apply the minimum only to a Hookr token's
    ///         pool with no arb recapture and nothing that pays Hookr a share (HookrRules.bind: a rule that can pay
    ///         Hookr a pip of a swap, or Tax + Conversion), so never the recapture rate.
    /// @param integrator The pool's integrator, or zero for none.
    /// @param recapture True for a pool with arb recapture on.
    /// @param id The pool.
    /// @return ruleShareFloorBps The governed floor of the pool's protocol share, in basis points.
    /// @return integratorBps The integrator's rate on the list, in basis points, zero when not listed.
    /// @return minFeePips The Hookr minimum for the pool, in pips.
    function feeTerms(address integrator, bool recapture, PoolId id)
        external
        view
        returns (uint16 ruleShareFloorBps, uint16 integratorBps, uint16 minFeePips);

    /// @notice Return whether `account` approved pool `id` binding its Hookr minimum override.
    /// @param account The integrator.
    /// @param id The pool.
    /// @return True when the integrator approved the pool.
    function minFeePoolApproved(address account, PoolId id) external view returns (bool);

    /// @notice Approve, or withdraw the approval of, pool `id` binding the caller's Hookr minimum override when the
    ///         pool names the caller as its integrator. Naming an integrator is the creator's free choice, so an
    ///         override reaches only the pools its integrator approved.
    /// @param id The pool.
    /// @param approved True to approve, false to withdraw the approval.
    function approveMinFeePool(PoolId id, bool approved) external;

    /// @notice Return the Hookr minimum, in pips, of pools with arb recapture on (`recapture`) or without.
    /// @param recapture True for pools with arb recapture on, false for pools without.
    /// @return The Hookr minimum, in pips.
    function minFeePips(bool recapture) external view returns (uint16);

    /// @notice Return the pending Hookr minimum of that kind of pool and when it can be accepted; zero `readyAt` when
    ///         none is pending. A proposal past TERMS_GRACE after its `readyAt` has lapsed and is not pending.
    /// @param recapture True for pools with arb recapture on, false for pools without.
    /// @return pips The proposed minimum, in pips.
    /// @return readyAt The timestamp from which it can be accepted, or zero.
    function pendingMinFee(bool recapture) external view returns (uint16 pips, uint256 readyAt);

    /// @notice Return `account`'s Hookr minimum override and its pending one, each in pips or NO_MIN_FEE_OVERRIDE for
    ///         none, and when the pending one can be accepted (zero `readyAt` when none is pending; a lapsed proposal is
    ///         not pending).
    /// @param account The integrator.
    /// @return pips The override in force, in pips, or NO_MIN_FEE_OVERRIDE.
    /// @return pendingPips The pending override, in pips, or NO_MIN_FEE_OVERRIDE.
    /// @return readyAt The timestamp from which the pending override can be accepted, or zero.
    function integratorMinFee(address account) external view returns (uint16 pips, uint16 pendingPips, uint256 readyAt);

    /// @notice Return the governed rule-share floor new pools bind with, in basis points.
    /// @return The floor, in basis points.
    function ruleShareFloorBps() external view returns (uint16);

    /// @notice Return the pending rule-share floor and when it can be accepted; zero `readyAt` when none is pending. A
    ///         proposal past TERMS_GRACE after its `readyAt` has lapsed and is not pending.
    /// @return floorBps The proposed floor, in basis points.
    /// @return readyAt The timestamp from which it can be accepted, or zero.
    function pendingRuleShareFloor() external view returns (uint16 floorBps, uint256 readyAt);

    /// @notice Return `account`'s rate on the integrator list (zero when not listed) and its pending rate and when
    ///         that can be accepted (zero `readyAt` when none is pending; a lapsed proposal is not pending).
    /// @param account The account.
    /// @return rateBps The rate on the list, in basis points, zero when not listed.
    /// @return pendingRateBps The pending rate, in basis points.
    /// @return readyAt The timestamp from which the pending rate can be accepted, or zero.
    function integrator(address account) external view returns (uint16 rateBps, uint16 pendingRateBps, uint256 readyAt);

    /// @notice Propose a new governed rule-share floor for pools bound from now on, at most 5,000. It can be
    ///         accepted after TERMS_DELAY; a new proposal replaces the pending one.
    /// @param floorBps The proposed floor, in basis points.
    function proposeRuleShareFloor(uint16 floorBps) external;

    /// @notice Withdraw the pending rule-share floor.
    function cancelRuleShareFloor() external;

    /// @notice Make the matured rule-share floor proposal the governed floor, within TERMS_GRACE of maturity.
    function acceptRuleShareFloor() external;

    /// @notice Propose listing `account` as an integrator, or re-rating a listed one, at `rateBps` (1 to 5,000) of
    ///         Hookr's rule-fee share. It can be accepted after TERMS_DELAY; a new proposal for the same account
    ///         replaces the pending one.
    /// @param account The account to list or re-rate.
    /// @param rateBps The rate, from 1 to 5,000 basis points.
    function proposeIntegrator(address account, uint16 rateBps) external;

    /// @notice Withdraw the pending proposal for `account`.
    /// @param account The account.
    function cancelIntegrator(address account) external;

    /// @notice Make the matured proposal for `account` its rate on the list, within TERMS_GRACE of maturity. The
    ///         addresses proposeIntegrator refuses (zero, this treasury, the PoolManager, an admitted source) are
    ///         refused again.
    /// @param account The account.
    function acceptIntegrator(address account) external;

    /// @notice Take `account` off the list at once and void any pending proposal for it, and remove its Hookr minimum
    ///         override with any pending one. Pools already bound with it keep paying it at their frozen rate and keep
    ///         their frozen minimum; only new pools can no longer name it. Reverts for an account neither listed nor
    ///         with a pending proposal.
    /// @param account The account.
    function removeIntegrator(address account) external;

    /// @notice Propose the Hookr minimum, 0 to 10,000 pips, for Hookr token pools bound from now on, with arb recapture
    ///         on (`recapture`) or without. It can be accepted after TERMS_DELAY; a new proposal replaces the pending
    ///         one.
    /// @param recapture True for pools with arb recapture on, false for pools without.
    /// @param pips The proposed minimum, from 0 to 10,000 pips.
    function proposeMinFee(bool recapture, uint16 pips) external;

    /// @notice Withdraw the pending Hookr minimum of that kind of pool.
    /// @param recapture True for pools with arb recapture on, false for pools without.
    function cancelMinFee(bool recapture) external;

    /// @notice Make the matured Hookr minimum proposal of that kind of pool current, within TERMS_GRACE of maturity.
    /// @param recapture True for pools with arb recapture on, false for pools without.
    function acceptMinFee(bool recapture) external;

    /// @notice Propose `account`'s Hookr minimum override, 0 to 10,000 pips, or NO_MIN_FEE_OVERRIDE to remove it, for
    ///         the pools naming `account` whose ids it approved. It can be accepted after TERMS_DELAY; a new proposal
    ///         for the same account replaces the pending one.
    /// @param account The integrator.
    /// @param pips The override, from 0 to 10,000 pips, or NO_MIN_FEE_OVERRIDE to remove it.
    function proposeIntegratorMinFee(address account, uint16 pips) external;

    /// @notice Withdraw the pending override proposal for `account`.
    /// @param account The integrator.
    function cancelIntegratorMinFee(address account) external;

    /// @notice Make the matured override proposal for `account` current, within TERMS_GRACE of maturity.
    /// @param account The integrator.
    function acceptIntegratorMinFee(address account) external;

    /// @notice Return the step the owned-root fee moves in: 0.0001 of the native currency (1e14 base units).
    /// @return The step, in base units of the native currency.
    function OWNED_ROOT_FEE_UNIT() external view returns (uint256);

    /// @notice Return the highest owned-root fee: 1 of the native currency (1e18 base units).
    /// @return The highest fee, in base units of the native currency.
    function MAX_OWNED_ROOT_FEE() external view returns (uint256);

    /// @notice Return the owned-root fee at construction: 0.01 of the native currency (1e16 base units).
    /// @return The starting fee, in base units of the native currency.
    function DEFAULT_OWNED_ROOT_FEE() external view returns (uint256);

    /// @notice Return the fee, in the native currency's base units, the owned-root factory takes from the deployer of
    ///         every owned root and forwards to this treasury's target in the same transaction.
    /// @return The fee, in base units of the native currency.
    function ownedRootFee() external view returns (uint256);

    /// @notice Return the pending owned-root fee and when it can be accepted; zero `readyAt` when none is pending. A
    ///         proposal past TERMS_GRACE after its `readyAt` has lapsed and is not pending.
    /// @return fee The proposed fee, in base units of the native currency.
    /// @return readyAt The timestamp from which it can be accepted, or zero.
    function pendingOwnedRootFee() external view returns (uint256 fee, uint256 readyAt);

    /// @notice Propose the owned-root fee, 0 to MAX_OWNED_ROOT_FEE in steps of OWNED_ROOT_FEE_UNIT. It can be accepted
    ///         after TERMS_DELAY; a new proposal replaces the pending one, and a change of owner voids it.
    /// @param fee The proposed fee, in base units of the native currency.
    function proposeOwnedRootFee(uint256 fee) external;

    /// @notice Withdraw the pending owned-root fee.
    function cancelOwnedRootFee() external;

    /// @notice Make the matured owned-root fee proposal current, within TERMS_GRACE of maturity.
    function acceptOwnedRootFee() external;
}
