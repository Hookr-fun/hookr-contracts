// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPaymaster} from "./external/IPaymaster.sol";
import {IHookrGoverned} from "./IHookrGoverned.sol";

/// @title IHookrPaymaster
/// @notice ERC-4337 v0.7 paymaster that precharges every op and rebates only ops that paid the protocol fee.
/// @dev Fee attribution reads the Rules transient ledger, which is scoped to the transaction, and records what it
///      consumed in this paymaster's own transient storage. Another paymaster cannot see that record, so at most one
///      funded paymaster may list a given Rules ledger in its rebate rules.
interface IHookrPaymaster is IPaymaster, IHookrGoverned {
    /// @notice How an op is charged: CREDIT from the account's native credit, TOKEN from its credit in an enabled gas
    ///         token.
    enum Mode {
        CREDIT,
        TOKEN
    }

    /// @notice Per-token gas configuration (1 slot).
    struct TokenConfig {
        /// @notice Whether the token can pay for ops.
        bool enabled;
        /// @notice Whether the token is pegged one to one to the native currency, with 18 decimals and a fixed rate of
        ///         1e18.
        bool peg;
        /// @notice The markup charged on top of the converted cost, in basis points.
        uint16 markupBps;
        /// @notice The most one rate update may move the rate from the anchor of the current rate window, in basis
        ///         points.
        uint16 maxRateStepBps;
        /// @notice The longest a rate stays valid, in seconds.
        uint32 maxRateTtl;
    }

    /// @notice Raw token units per 1e18 wei (1 slot).
    struct Rate {
        /// @notice Raw token units per 1e18 wei.
        uint128 tokenPerEth;
        /// @notice The timestamp after which the rate is unavailable.
        uint48 expiresAt;
        /// @notice The timestamp of the last update.
        uint48 updatedAt;
    }

    /// @notice Sponsorship policy (3 slots).
    /// @dev maxFeePerGasWei caps the op's signed maxFeePerGas, so the per-gas undercharge any unmetered EntryPoint
    ///      work could leave is bounded.
    struct Policy {
        /// @notice The share of an op's protocol fee rebated against its gas cost, in basis points; zero halts rebates.
        uint16 rebateBps;
        /// @notice The most one op may be rebated, in wei.
        uint96 perOpRebateCapWei;
        /// @notice The most one account may be rebated per day, in wei.
        uint96 perAccountDailyRebateCapWei;
        /// @notice Whether an account is screened against the compliance registry before it is rebated.
        bool screenSanctions;
        /// @notice The most all ops may be rebated per day, in wei.
        uint128 dailyRebateCapWei;
        /// @notice The most an op's maximum cost may be, in wei.
        uint128 maxCostWei;
        /// @notice The most an op's signed maxFeePerGas may be, in wei.
        uint128 maxFeePerGasWei;
    }

    /// @notice abi-encoded, returned from validation.
    struct Context {
        /// @notice The op's account.
        address account;
        /// @notice How the op is charged.
        Mode mode;
        /// @notice The gas token, zero in CREDIT mode.
        address token;
        /// @notice The amount precharged, in the charge currency.
        uint256 required;
        /// @notice The token rate the precharge used, raw token units per 1e18 wei.
        uint256 rate;
        /// @notice The token's markup the precharge used, in basis points.
        uint16 markupBps;
        /// @notice The op's maximum cost in wei.
        uint256 maxCost;
        /// @notice The op's call gas limit.
        uint256 executionGasLimit;
        /// @notice The op's paymaster post-op gas limit.
        uint256 postOpGasLimit;
        /// @notice The op's hash.
        bytes32 userOpHash;
    }

    // EntryPoint only (IPaymaster): validatePaymasterUserOp 0x52b7512c, postOp 0x7c627b21

    // Accounts. These work while paused; no role can reduce credit.
    /// @notice Adds native credit to `account`. Works while paused.
    /// @param account The account credited.
    function depositCredit(address account) external payable;
    /// @notice Adds credit in an enabled token, pulling exactly `amount` from the caller. Works while paused.
    /// @param token The enabled token.
    /// @param account The account credited.
    /// @param amount The exact amount pulled from msg.sender.
    function depositTokenCredit(address token, address account, uint256 amount) external;
    /// @notice Withdraws the caller's own credit. Works while paused.
    /// @param token The credited token, address(0) for native.
    /// @param to The recipient.
    /// @param amount The amount withdrawn.
    function withdrawCredit(address token, address to, uint256 amount) external;

    // Funding and treasury
    /// @notice Owner or treasury: deposits msg.value to the EntryPoint for this paymaster and adds it to the rebate
    ///         budget.
    function fundRebates() external payable;
    /// @notice Anyone: moves `amount` of native revenue into this paymaster's EntryPoint deposit.
    /// @param amount The native revenue moved into the EntryPoint deposit, in wei.
    function refillDeposit(uint256 amount) external;
    /// @notice Owner: sends `amount` of `token` revenue to the treasury; `amount` is at most the token's revenue.
    /// @param token The token; zero for native.
    /// @param amount The revenue sent, at most the token's revenue.
    function withdrawRevenue(address token, uint256 amount) external;
    /// @notice Owner: withdraws `amount` of the EntryPoint deposit to the treasury; the rebate budget is clipped to
    ///         what remains deposited.
    /// @param amount The EntryPoint deposit withdrawn, in wei.
    function withdrawDeposit(uint256 amount) external;
    /// @notice Owner: stakes msg.value on the EntryPoint with an unstake delay of at least MIN_UNSTAKE_DELAY.
    /// @param unstakeDelaySec The unstake delay in seconds, at least MIN_UNSTAKE_DELAY.
    function addStake(uint32 unstakeDelaySec) external payable;
    /// @notice Owner: starts the EntryPoint stake's unstake delay.
    function unlockStake() external;
    /// @notice Owner: withdraws the unlocked EntryPoint stake to the treasury.
    function withdrawStake() external;
    /// @notice Owner: sends the treasury what this paymaster holds of `token` above its credit and revenue.
    /// @param token The token; zero for native.
    function sweepUntracked(address token) external;

    // Keeper: immediate, bounded
    /// @notice Keeper: sets an enabled, non-peg token's rate for `ttl` seconds, at most its maxRateTtl, within
    ///         maxRateStepBps of the rate anchored at the start of the current RATE_WINDOW.
    /// @param token The enabled, non-peg token.
    /// @param tokenPerEth The new rate, raw token units per 1e18 wei.
    /// @param ttl The seconds the rate stays valid, at most the token's maxRateTtl.
    function setRate(address token, uint128 tokenPerEth, uint32 ttl) external;

    // Guardian or owner: immediate, reduces power
    /// @notice Stops sponsorship. Voids an UNPAUSE queued before it.
    function pause() external;
    /// @notice Sets the policy's rebateBps to zero. Voids a SET_POLICY queued before it.
    function haltRebates() external;
    /// @notice Disables a gas token. Voids a SET_TOKEN queued before it.
    /// @param token The token.
    function disableToken(address token) external;
    /// @notice Forbids an account call. Voids an ALLOW_CALL queued before it.
    /// @param target The call's target.
    /// @param selector The call's selector.
    function revokeCall(address target, bytes4 selector) external;
    /// @notice Forbids an approval spender. Voids an ALLOW_SPENDER queued before it.
    /// @param spender The spender.
    function revokeApprovalSpender(address spender) external;
    /// @notice Revokes a keeper. Voids a GRANT_KEEPER queued before it.
    /// @param keeper The keeper.
    function revokeKeeper(address keeper) external;
    /// @notice Removes a Rules ledger from the rebate rules, if listed. Voids an ADD_REBATE_RULES queued before it.
    /// @param rules The Rules ledger.
    function removeRebateRules(address rules) external;
    /// @notice Owner only: revokes a guardian. Voids a GRANT_GUARDIAN queued before it.
    /// @param guardian The guardian.
    function revokeGuardian(address guardian) external;

    // Owner, timelocked through HookrGoverned (queue(kind, abi.encode(args)) first)
    /// @notice Lifts the pause. Owner, timelocked: kind UNPAUSE.
    function unpause() external;
    /// @notice Lists or reconfigures a gas token. Owner, timelocked: kind SET_TOKEN. A peg requires decimals() == 18
    ///         and rate 1e18; otherwise maxRateStepBps < markupBps and (1 - step)^2 * (1 + markup) >= 1. Resets the
    ///         rate anchor.
    /// @param token The token.
    /// @param config The token's configuration.
    /// @param initialRate The rate set with it, raw token units per 1e18 wei.
    function setToken(address token, TokenConfig calldata config, uint128 initialRate) external;
    /// @notice Replaces the sponsorship policy. Owner, timelocked: kind SET_POLICY.
    /// @param policy The new policy.
    function setPolicy(Policy calldata policy) external;
    /// @notice Allows an account call, with or without value. Owner, timelocked: kind ALLOW_CALL. An approve also
    ///         needs an allowed spender.
    /// @param target The call's target.
    /// @param selector The call's selector.
    /// @param valueAllowed Whether the call may carry value.
    function allowCall(address target, bytes4 selector, bool valueAllowed) external;
    /// @notice Allows an approval spender. Owner, timelocked: kind ALLOW_SPENDER.
    /// @param spender The spender.
    function allowApprovalSpender(address spender) external;
    /// @notice Adds a Rules ledger to the rebate rules. Owner, timelocked: kind ADD_REBATE_RULES. The Rules must
    ///         answer protocolFeePaid with one word within RULES_PROBE_GAS.
    /// @param rules The Rules ledger.
    function addRebateRules(address rules) external;
    /// @notice Sets the rebate quotes, at most 4, address(0) for native. Owner, timelocked: kind SET_REBATE_QUOTES.
    /// @param quotes The quote currencies whose protocol fee earns a rebate, at most 4; zero is native.
    function setRebateQuotes(address[] calldata quotes) external;
    /// @notice Grants a keeper. Owner, timelocked: kind GRANT_KEEPER.
    /// @param keeper The keeper.
    function grantKeeper(address keeper) external;
    /// @notice Grants a guardian (never an EIP-7702 delegated account). Owner, timelocked: kind GRANT_GUARDIAN.
    /// @param guardian The guardian.
    function grantGuardian(address guardian) external;
    /// @notice Sets the treasury. Owner, timelocked: kind SET_TREASURY.
    /// @param treasury The treasury.
    function setTreasury(address treasury) external;

    // Views
    /// @notice Returns the EntryPoint v0.7 this paymaster serves.
    /// @return The EntryPoint.
    function entryPoint() external view returns (address);
    /// @notice Returns the compliance registry screened against; zero disables screening.
    /// @return The compliance registry, or zero.
    function compliance() external view returns (address);
    /// @notice Returns the treasury.
    /// @return The treasury.
    function treasury() external view returns (address);
    /// @notice Returns whether sponsorship is paused.
    /// @return True while sponsorship is paused.
    function paused() external view returns (bool);
    /// @notice Returns the sponsorship policy.
    /// @return The policy.
    function policy() external view returns (Policy memory);
    /// @notice Returns a gas token's configuration.
    /// @param token The token.
    /// @return The token's configuration.
    function tokenConfig(address token) external view returns (TokenConfig memory);
    /// @notice Returns a gas token's rate.
    /// @param token The token.
    /// @return The token's rate.
    function rate(address token) external view returns (Rate memory);
    /// @notice Returns an account's credit in `token`, address(0) for native.
    /// @param account The account.
    /// @param token The token; zero for native.
    /// @return The account's credit in the token.
    function credit(address account, address token) external view returns (uint256);
    /// @notice Returns all accounts' credit in `token`.
    /// @param token The token; zero for native.
    /// @return The credit of every account in the token.
    function totalCredit(address token) external view returns (uint256);
    /// @notice Returns the revenue held in `token`.
    /// @param token The token; zero for native.
    /// @return The revenue held in the token.
    function revenue(address token) external view returns (uint256);
    /// @notice Returns the rebate budget, in wei.
    /// @return The rebate budget in wei.
    function rebateBudget() external view returns (uint256);
    /// @notice Returns the Rules ledgers whose protocol fee earns a rebate.
    /// @return The Rules ledgers whose protocol fee earns a rebate.
    function rebateRules() external view returns (address[] memory);
    /// @notice Returns the rebate quotes.
    /// @return The quote currencies whose protocol fee earns a rebate.
    function rebateQuotes() external view returns (address[] memory);
    /// @notice Returns whether an account call is allowed, and whether with value.
    /// @param target The call's target.
    /// @param selector The call's selector.
    /// @return allowed True when the call is allowed.
    /// @return valueAllowed True when it may carry value.
    function callPolicy(address target, bytes4 selector) external view returns (bool allowed, bool valueAllowed);
    /// @notice Returns whether `spender` is an allowed approval spender.
    /// @param spender The spender.
    /// @return True when the spender is allowed.
    function isApprovalSpender(address spender) external view returns (bool);
    /// @notice Returns what an op of up to `maxCost` wei requires in `mode` and `token`, and until when the rate
    ///         behind it is valid.
    /// @param mode How the op is charged.
    /// @param token The gas token; zero in CREDIT mode.
    /// @param maxCost The op's maximum cost in wei.
    /// @return required The amount the op requires, in the charge currency.
    /// @return validUntil The timestamp until which the rate behind it is valid.
    function quoteCharge(Mode mode, address token, uint256 maxCost)
        external
        view
        returns (uint256 required, uint48 validUntil);
    /// @notice Returns the shared release identity.
    /// @return The release id.
    function releaseId() external view returns (uint256);

    /// @notice An op was settled in postOp.
    /// @param account The op's account.
    /// @param userOpHash The op's hash.
    /// @param token The charge currency, zero for native.
    /// @param mode How the op was charged.
    /// @param succeeded Whether the op's execution succeeded.
    /// @param costWei The op's cost in wei, including the paymaster's own overhead.
    /// @param feeWei The protocol fee attributed to the op, in wei.
    /// @param rebateWei The rebate granted, in wei.
    /// @param charged The amount charged, in the charge currency.
    /// @param refunded The precharge returned to the account's credit, in the charge currency.
    event UserOperationSettled(
        address indexed account,
        bytes32 indexed userOpHash,
        address indexed token,
        Mode mode,
        bool succeeded,
        uint256 costWei,
        uint256 feeWei,
        uint256 rebateWei,
        uint256 charged,
        uint256 refunded
    );
    /// @notice Credit was added to an account.
    /// @param account The account credited.
    /// @param token The token, zero for native.
    /// @param from The payer.
    /// @param amount The amount added.
    event CreditDeposited(address indexed account, address indexed token, address indexed from, uint256 amount);
    /// @notice An account withdrew its own credit.
    /// @param account The account.
    /// @param token The token, zero for native.
    /// @param to The recipient.
    /// @param amount The amount withdrawn.
    event CreditWithdrawn(address indexed account, address indexed token, address to, uint256 amount);
    /// @notice The rebate budget was funded.
    /// @param from The owner or treasury that funded it.
    /// @param amount The amount added, in wei.
    event RebatesFunded(address indexed from, uint256 amount);
    /// @notice Native revenue moved into the EntryPoint deposit.
    /// @param amount The amount moved, in wei.
    event DepositRefilled(uint256 amount);
    /// @notice Revenue was sent to the treasury.
    /// @param token The token, zero for native.
    /// @param to The treasury.
    /// @param amount The amount sent.
    event RevenueWithdrawn(address indexed token, address indexed to, uint256 amount);
    /// @notice The owner withdrew part of the EntryPoint deposit.
    /// @param to The treasury.
    /// @param amount The amount withdrawn, in wei.
    event DepositWithdrawn(address indexed to, uint256 amount);
    /// @notice A keeper set a token's rate.
    /// @param token The token.
    /// @param tokenPerEth The new rate, raw token units per 1e18 wei.
    /// @param expiresAt The timestamp after which the rate is unavailable.
    event RateSet(address indexed token, uint128 tokenPerEth, uint48 expiresAt);
    /// @notice A gas token was listed or reconfigured.
    /// @param token The token.
    /// @param config The token's configuration.
    /// @param initialRate The rate set with it.
    event TokenSet(address indexed token, TokenConfig config, uint128 initialRate);
    /// @notice A brake disabled a gas token.
    /// @param token The token.
    event TokenDisabled(address indexed token);
    /// @notice The sponsorship policy was replaced.
    /// @param policy The new policy.
    event PolicySet(Policy policy);
    /// @notice A brake set the rebate share to zero.
    /// @param by The owner or guardian.
    event RebatesHalted(address indexed by);
    /// @notice Sponsorship was paused or resumed.
    /// @param paused Whether sponsorship is now paused.
    /// @param by The account that changed it.
    event PauseSet(bool paused, address indexed by);
    /// @notice An account call was allowed or forbidden.
    /// @param target The call's target.
    /// @param selector The call's selector.
    /// @param allowed Whether the call is now allowed.
    /// @param valueAllowed Whether it may carry value.
    event CallSet(address indexed target, bytes4 indexed selector, bool allowed, bool valueAllowed);
    /// @notice An approval spender was allowed or forbidden.
    /// @param spender The spender.
    /// @param allowed Whether the spender is now allowed.
    event ApprovalSpenderSet(address indexed spender, bool allowed);
    /// @notice A Rules ledger was added to or removed from the rebate rules.
    /// @param rules The Rules ledger.
    /// @param allowed Whether it is now listed.
    event RebateRulesSet(address indexed rules, bool allowed);
    /// @notice The rebate quote currencies were replaced.
    /// @param quotes The new quote currencies.
    event RebateQuotesSet(address[] quotes);
    /// @notice A keeper was granted or revoked.
    /// @param keeper The keeper.
    /// @param allowed Whether it is now a keeper.
    event KeeperSet(address indexed keeper, bool allowed);
    /// @notice A guardian was granted or revoked.
    /// @param guardian The guardian.
    /// @param allowed Whether it is now a guardian.
    event GuardianSet(address indexed guardian, bool allowed);
    /// @notice The treasury changed.
    /// @param treasury The new treasury.
    event TreasurySet(address indexed treasury);
    /// @notice Balances the paymaster held above its credit and revenue were sent to the treasury.
    /// @param token The token, zero for native.
    /// @param to The treasury.
    /// @param amount The amount swept.
    event UntrackedSwept(address indexed token, address indexed to, uint256 amount);

    /// @notice `caller` is not the EntryPoint.
    error NotEntryPoint(address caller);
    /// @notice Sponsorship is paused.
    error SponsorshipPaused();
    /// @notice The op's paymaster data has the wrong `length`.
    error InvalidPaymasterData(uint256 length);
    /// @notice `mode` is not a charge mode.
    error InvalidMode(uint8 mode);
    /// @notice The op's post-op gas `given` is outside `minimum` and `maximum`.
    error PostOpGasOutOfRange(uint256 given, uint256 minimum, uint256 maximum);
    /// @notice The op's maximum cost `maxCost` is above the policy's `cap`.
    error CostAboveCap(uint256 maxCost, uint256 cap);
    /// @notice The op's `maxFeePerGas` is above the policy's `cap`.
    error FeePerGasAboveCap(uint256 maxFeePerGas, uint256 cap);
    /// @notice The precharge `required` is above the op's `maxCharge`.
    error ChargeAboveLimit(uint256 required, uint256 maxCharge);
    /// @notice The account's credit `available` is below the precharge `required`.
    error InsufficientCredit(uint256 available, uint256 required);
    /// @notice `token` is not an enabled gas token.
    error UnsupportedToken(address token);
    /// @notice `token` has no valid rate.
    error RateUnavailable(address token);
    /// @notice `account` has no code yet.
    error AccountNotDeployed(address account);
    /// @notice A transfer of `token` moved `received` instead of `expected`.
    error InexactTransfer(address token, uint256 expected, uint256 received);
    /// @notice `account` is sanctioned.
    error SenderSanctioned(address account);
    /// @notice The account call with `selector` is not one the paymaster sponsors.
    error UnsupportedAccountCall(bytes4 selector);
    /// @notice The account call data is not the canonical encoding.
    error NonCanonicalCallData();
    /// @notice The op batches `count` calls, more than the paymaster allows.
    error TooManyCalls(uint256 count);
    /// @notice The call to `target` with `selector` is not allowed.
    error CallNotAllowed(address target, bytes4 selector);
    /// @notice `spender` is not an allowed approval spender.
    error ApprovalNotAllowed(address spender);
    /// @notice The call to `target` may not carry `value`.
    error ValueNotAllowed(address target, uint256 value);
    /// @notice `caller` is not a keeper.
    error NotKeeper(address caller);
    /// @notice `caller` is not a guardian or the owner.
    error NotGuardian(address caller);
    /// @notice The rate moved from `current` to `proposed`, more than the token's step allows.
    error RateStepTooLarge(uint128 current, uint128 proposed);
    /// @notice The rate's `ttl` is above the token's `maximum`.
    error RateTtlTooLong(uint32 ttl, uint32 maximum);
    /// @notice The policy breaks a bound; `field` numbers the check that failed.
    error InvalidPolicy(uint8 field);
    /// @notice The token configuration breaks a bound; `field` numbers the check that failed.
    error InvalidTokenConfig(uint8 field);
    /// @notice The `requested` amount is above the `available` revenue.
    error AmountExceedsRevenue(uint256 requested, uint256 available);
    /// @notice `count` entries are more than the `maximum`.
    error TooManyEntries(uint256 count, uint256 maximum);
    /// @notice The call re-entered the paymaster.
    error Reentered();
    /// @notice A native transfer failed.
    error NativeTransferFailed();
}
