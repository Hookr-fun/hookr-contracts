// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrRevenueTypes} from "./HookrRevenueTypes.sol";

/// @title Hookr revenue split
/// @notice An immutable fee-recipient contract. Everything that reaches it (Rules royalty or protocol claims, LP
///         fees a family owner collects to it, treasury forwards, deposits, plain transfers, PoolManager ERC-6909
///         claims once redeemed) is credited to fixed payees by fixed weights, per currency, and each payee pulls its
///         own balance.
/// @dev Hookr 1 extension point: off-pool sidecar, "contract fee recipient". It is never called on the swap path,
///      holds no admission, and fails only itself.
interface IHookrRevenueSplit {
    /// @notice The payees were frozen. Emitted once, at construction.
    event SplitConfigured(bytes32 indexed splitId, bytes32 indexed tag, HookrRevenueTypes.Recipient[] recipients);
    /// @notice A source's claim was pulled in and measured by balance delta.
    event RevenueCollected(address indexed source, Currency indexed currency, uint256 received);
    /// @notice This split's ERC-6909 claims of `currency` at `manager` were burned and the currency taken here,
    ///         measured by balance delta.
    event ClaimsRedeemed(address indexed manager, Currency indexed currency, uint256 claims, uint256 received);
    /// @notice Unaccounted balance was credited as one deposit.
    event RevenueDeposited(
        Currency indexed currency, address indexed caller, uint256 amount, uint256 lifetimeDeposited
    );
    /// @notice One payee's share of one deposit.
    event RevenueCredited(
        Currency indexed currency, address indexed account, HookrRevenueTypes.Role indexed role, uint256 amount
    );
    /// @notice A payee's balance left the split.
    event RevenueClaimed(Currency indexed currency, address indexed account, address indexed to, uint256 amount);

    error InvalidRecipients();
    error DuplicateRecipient(address account, HookrRevenueTypes.Role role);
    error InvalidAmount();
    error InvalidDestination(address to);
    error NothingToClaim();
    error PullOnly(address account);
    error Reentrancy();
    error NativeTransferFailed();
    /// @notice An ERC-20 payout debited the split by more than the claim, or by nothing.
    error TransferMismatch(uint256 expected, uint256 actual);
    /// @notice Thrown by `collect` or `redeem` when the call lowered the currency's balance here.
    error SourceMismatch();
    error AccountingInvariant();
    /// @notice Thrown by a batch call given no currency, more than `MAX_BATCH_CURRENCIES`, or one currency twice.
    error InvalidCurrencies();
    /// @notice Thrown by `unlockCallback` for any caller but the manager `redeem` is unlocking, and by `redeem` when
    ///         that manager returned from `unlock` without calling back.
    error NotPoolManager();
    /// @notice Thrown by `redeem` when the manager's balance fell by more than the claims burned, by nothing, or by
    ///         more than `MAX_PAYOUT_SHORTFALL` less than them.
    error RedeemMismatch(uint256 claims, uint256 debited);

    /// @notice The factory that created this split (or the direct deployer).
    function factory() external view returns (address);

    /// @notice Free tag chosen by the creator so identical payee lists can still get separate split addresses.
    function tag() external view returns (bytes32);

    /// @notice keccak256(abi.encode(tag, recipients)): the commitment this address was derived from.
    function splitId() external view returns (bytes32);

    /// @notice The frozen payees in configured order.
    function recipients() external view returns (HookrRevenueTypes.Recipient[] memory);

    /// @notice Number of payees.
    function recipientCount() external view returns (uint256);

    /// @notice True when `account` holds the STRATEGY role here and therefore can only be paid by its own call.
    function pullOnly(address account) external view returns (bool);

    /// @notice Pulls this split's claim from a claims source (a HookrRules, or anything exposing the same two
    ///         functions), then credits everything unaccounted in that currency. Permissionless.
    /// @dev The source is untrusted: only the measured balance increase is ever credited.
    function collect(address source, Currency currency) external returns (uint256 received, uint256 credited);

    /// @notice `collect` for each listed currency in one call: every settlement currency a pool's royalty or claims can
    ///         be paid in (the pool's two, the registry's settlement set, anything the pool's recapture accrual held),
    ///         each on its own ledger. A currency with no claim at the source is only synced. Permissionless.
    /// @dev At most `MAX_BATCH_CURRENCIES` currencies, none twice. `HookrRevenueRouter.payoutCurrencies` builds the list.
    function collectMany(address source, Currency[] calldata currencies)
        external
        returns (uint256[] memory received, uint256[] memory credited);

    /// @notice Credits the currency's unaccounted balance (balance minus outstanding claims) as one deposit.
    function sync(Currency currency) external returns (uint256 credited);

    /// @notice Pulls `amount` from the caller (ERC-20) or takes `msg.value` (native, which must equal `amount`),
    ///         then credits everything unaccounted in that currency.
    function deposit(Currency currency, uint256 amount) external payable returns (uint256 credited);

    /// @notice Redeems this split's ERC-6909 balance of `currency` at the PoolManager `manager` into the currency
    ///         itself, then credits everything unaccounted in that currency. Permissionless. Claims reach a split when
    ///         it is named as the recipient of an ERC-6909 payment: a Rules `claimAsClaims`, a treasury
    ///         `collectAsClaims` to its target, a launcher `withdrawWithClaims`, a Directional Tax queue's exit for a
    ///         quote that will not deliver, or any claims transfer. They can arrive before the split exists and wait at
    ///         its predicted address.
    /// @dev The split unlocks `manager`, burns its own claims there and takes the same amount here, inside that one
    ///      unlock: the whole balance, or the PoolManager's int128 amount limit when the balance is larger (a later
    ///      call redeems the rest). `manager` is the caller's choice: only the PoolManager that holds the claims can
    ///      pay them, and any other account can at most send this split something, which is credited like any
    ///      deposit; an indexer counts `ClaimsRedeemed` from the canonical PoolManager only. A payout that debits the
    ///      manager by more than the claims burned (a fee charged to the sender on top), by nothing, or short of them
    ///      by more than share rounding is refused with `RedeemMismatch` and the claims stay; a fee taken from what
    ///      arrives credits only what arrived. Reverts while the manager is unlocked, or when the currency cannot be
    ///      delivered here (an issuer pause, or a freeze of this split); the claims stay and a later call redeems
    ///      them. Nothing to redeem only syncs.
    function redeem(IPoolManager manager, Currency currency) external returns (uint256 received, uint256 credited);

    /// @notice Pays the caller's whole balance in `currency` to the caller.
    /// @dev All three payouts return what left the split. The ERC-20 transfer requests the balance, capped at the
    ///      split's holdings. A token that debits the split up to 2 wei less than that request (share rounding) pays
    ///      less and the remainder stays claimable; a debit of nothing, of more than the request, or short by more
    ///      than 2 wei reverts with `TransferMismatch(requested, debited)`.
    function claim(Currency currency) external returns (uint256 amount);

    /// @notice Pays the caller's whole balance in `currency` to `to`. Only the owner of a balance chooses `to`.
    function claimTo(Currency currency, address to) external returns (uint256 amount);

    /// @notice Pays `account`'s whole balance to `account` itself. Anyone may call; refused for pull-only accounts.
    function claimFor(address account, Currency currency) external returns (uint256 amount);

    /// @notice Pays the caller's whole balance in each listed currency to `to`, skipping currencies where it has
    ///         none. Reverts `NothingToClaim` only if it has nothing in any of them. Same payout rules as `claim`.
    function claimMany(Currency[] calldata currencies, address to) external returns (uint256[] memory amounts);

    /// @notice Pays `account`'s whole balance in each listed currency to `account` itself, skipping currencies where
    ///         it has none. Anyone may call; refused for pull-only accounts.
    function claimForMany(address account, Currency[] calldata currencies) external returns (uint256[] memory amounts);

    /// @notice Most currencies one batch call takes.
    function MAX_BATCH_CURRENCIES() external view returns (uint256);

    /// @notice Outstanding claim of `account` in `currency`.
    function claimable(Currency currency, address account) external view returns (uint256);

    /// @notice Sum of all outstanding claims in `currency`.
    function reserved(Currency currency) external view returns (uint256);

    /// @notice Total ever credited in `currency`.
    function lifetimeDeposited(Currency currency) external view returns (uint256);

    /// @notice Total ever credited to one (account, role) payee. Survives withdrawals.
    function lifetimeCredited(Currency currency, address account, HookrRevenueTypes.Role role)
        external
        view
        returns (uint256);

    /// @notice Total ever credited to `account` across all its roles. Survives withdrawals.
    function lifetimeCreditedByAccount(Currency currency, address account) external view returns (uint256);

    /// @notice Total ever credited to one role label across all payees holding it.
    function lifetimeCreditedByRole(Currency currency, HookrRevenueTypes.Role role) external view returns (uint256);

    /// @notice Total `account` has withdrawn in `currency`.
    function lifetimeClaimed(Currency currency, address account) external view returns (uint256);

    /// @notice Balance not yet credited (it becomes a deposit on the next sync, collect or deposit).
    function unaccounted(Currency currency) external view returns (uint256);

    /// @notice Balance, outstanding claims, surplus and whether the balance covers the claims.
    function solvency(Currency currency)
        external
        view
        returns (uint256 balance, uint256 liability, uint256 surplus, bool solvent);

    /// @notice The cumulative per-payee credit a lifetime total of `total` produces, in configured order.
    function allocation(uint256 total) external view returns (uint256[] memory);

    /// @notice The per-payee shares a deposit of `amount` would credit now, in configured order.
    function preview(Currency currency, uint256 amount) external view returns (uint256[] memory shares);
}
