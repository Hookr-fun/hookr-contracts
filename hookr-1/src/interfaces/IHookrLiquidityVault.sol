// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHookrGoverned} from "./IHookrGoverned.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title IHookrLiquidityVault
/// @notice Interface for HookrLiquidityVault, which pools LP liquidity into one PoolManager position per range and
///         issues ERC-6909 shares 1:1 with that position's liquidity.
interface IHookrLiquidityVault is IHookrGoverned {
    /// @notice Deposit arguments. The vault charges exactly what the pool requires, never more than desired.
    struct DepositParams {
        /// @notice The pool.
        PoolKey key;
        /// @notice The range's lower tick.
        int24 tickLower;
        /// @notice The range's upper tick.
        int24 tickUpper;
        /// @notice The most currency0 to spend.
        uint256 amount0Desired;
        /// @notice The most currency1 to spend.
        uint256 amount1Desired;
        /// @notice The least currency0 the deposit must spend.
        uint256 amount0Min;
        /// @notice The least currency1 the deposit must spend.
        uint256 amount1Min;
        /// @notice The account that receives the shares.
        address recipient;
        /// @notice The timestamp after which the deposit reverts.
        uint256 deadline;
    }

    /// @notice Withdrawal arguments. Minimums bound the principal returned, excluding fees.
    struct WithdrawParams {
        /// @notice The pool.
        PoolKey key;
        /// @notice The range's lower tick.
        int24 tickLower;
        /// @notice The range's upper tick.
        int24 tickUpper;
        /// @notice The shares to burn, equal to the liquidity removed.
        uint128 liquidity;
        /// @notice The least currency0 principal the withdrawal must return.
        uint256 amount0Min;
        /// @notice The least currency1 principal the withdrawal must return.
        uint256 amount1Min;
        /// @notice The account that receives the principal and fees.
        address recipient;
        /// @notice The timestamp after which the withdrawal reverts.
        uint256 deadline;
    }

    /// @notice A registered range and its cumulative realised LP fees per share, Q128.
    struct Range {
        /// @notice The pool the range belongs to.
        PoolId poolId;
        /// @notice The range's lower tick.
        int24 tickLower;
        /// @notice The range's upper tick.
        int24 tickUpper;
        /// @notice The cumulative realised currency0 fees per share, in Q128.
        uint256 feesPerShare0X128;
        /// @notice The cumulative realised currency1 fees per share, in Q128.
        uint256 feesPerShare1X128;
    }

    /// @notice A holder's accumulator checkpoints and realised fees not yet paid.
    struct Account {
        /// @notice The currency0 fees-per-share checkpoint the account last settled at, in Q128.
        uint256 feesPerShare0X128;
        /// @notice The currency1 fees-per-share checkpoint the account last settled at, in Q128.
        uint256 feesPerShare1X128;
        /// @notice The realised currency0 fees not yet paid.
        uint256 owed0;
        /// @notice The realised currency1 fees not yet paid.
        uint256 owed1;
    }

    /// @notice The call re-entered the vault.
    error Reentrancy();
    /// @notice The call's `deadline` has passed.
    error DeadlinePassed(uint256 deadline);
    /// @notice The range's lower tick is not below its upper tick.
    error InvalidRange();
    /// @notice The liquidity is zero or above the maximum the vault holds.
    error InvalidLiquidity();
    /// @notice Native value was sent to a deposit that does not pay in native currency, or it does not cover the
    ///         payment.
    error InvalidValue();
    /// @notice The skim `bps` is above the vault's maximum, or a queued raise is not above the current skim.
    error InvalidSkim(uint16 bps);
    /// @notice The caller holds `balance` shares, fewer than the `required`.
    error InsufficientShares(uint256 balance, uint256 required);
    /// @notice The call spent or returned `amount0` and `amount1`, which break the caller's bounds.
    error Slippage(uint256 amount0, uint256 amount1);
    /// @notice The PoolManager reported a balance change of `amount0` and `amount1` that the call cannot have caused.
    error UnexpectedDelta(int256 amount0, int256 amount1);
    /// @notice A token transfer failed.
    error TransferFailed();
    /// @notice Refunding the unused native value failed.
    error RefundFailed();

    /// @notice A range was registered on its first deposit.
    /// @param id The range id, also its share id.
    /// @param poolId The pool.
    /// @param tickLower The range's lower tick.
    /// @param tickUpper The range's upper tick.
    event RangeOpened(uint256 indexed id, PoolId indexed poolId, int24 tickLower, int24 tickUpper);

    /// @notice Liquidity was added and shares were minted.
    /// @param id The range id.
    /// @param payer The account that paid.
    /// @param recipient The account that received the shares.
    /// @param liquidity The liquidity added, equal to the shares minted.
    /// @param amount0 The currency0 paid.
    /// @param amount1 The currency1 paid.
    event Deposit(
        uint256 indexed id,
        address indexed payer,
        address indexed recipient,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );

    /// @notice Shares were burned and liquidity was removed.
    /// @param id The range id.
    /// @param owner The account whose shares were burned.
    /// @param recipient The account that received the principal.
    /// @param liquidity The liquidity removed, equal to the shares burned.
    /// @param amount0 The currency0 principal returned.
    /// @param amount1 The currency1 principal returned.
    event Withdraw(
        uint256 indexed id,
        address indexed owner,
        address indexed recipient,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );
    /// @notice A range's accrued fees were realised into its per-share accumulators.
    /// @param id The range id.
    /// @param fees0 The currency0 fees realised.
    /// @param fees1 The currency1 fees realised.
    /// @param skim0 The currency0 share credited to the protocol.
    /// @param skim1 The currency1 share credited to the protocol.
    event FeesRealized(uint256 indexed id, uint256 fees0, uint256 fees1, uint256 skim0, uint256 skim1);

    /// @notice A holder's realised fees were paid.
    /// @param id The range id.
    /// @param owner The holder.
    /// @param recipient The account that received the fees.
    /// @param fees0 The currency0 fees paid.
    /// @param fees1 The currency1 fees paid.
    event FeesClaimed(
        uint256 indexed id, address indexed owner, address indexed recipient, uint256 fees0, uint256 fees1
    );
    /// @notice Skimmed fees were paid to the protocol recipient.
    /// @param currency The currency.
    /// @param to The protocol recipient.
    /// @param amount The amount paid.
    event ProtocolFeesPaid(Currency indexed currency, address indexed to, uint256 amount);
    /// @notice The skim changed.
    /// @param bps The new skim, in basis points.
    event SkimSet(uint16 bps);

    /// @notice Immutable upper bound for skimBps.
    /// @return The maximum skim, in basis points.
    function maxSkimBps() external view returns (uint16);

    /// @notice Share of each realised fee credited to the protocol, in basis points.
    /// @return The skim, in basis points.
    function skimBps() external view returns (uint16);

    /// @notice Outstanding shares, equal to the vault position's liquidity, per range id.
    /// @param id The range id.
    /// @return The outstanding shares.
    function totalSupply(uint256 id) external view returns (uint256);

    /// @notice Skimmed fees payable to the protocol recipient, per currency.
    /// @param currency The currency.
    /// @return The skimmed fees awaiting payment.
    function protocolFees(Currency currency) external view returns (uint256);

    /// @notice Adds the most liquidity the desired amounts buy at the current price and mints that many shares.
    /// @dev A native currency0 is paid from msg.value; the unused remainder is refunded to the caller.
    ///      ERC-20 amounts are pulled from the caller, who approves this contract.
    /// @param params The deposit arguments.
    /// @return id The range id.
    /// @return liquidity Shares minted, equal to the liquidity added.
    /// @return amount0 Currency0 paid.
    /// @return amount1 Currency1 paid.
    function deposit(DepositParams calldata params)
        external
        payable
        returns (uint256 id, uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice Burns the caller's shares, removes that liquidity and pays the principal plus all of the caller's
    ///         realised fees in the range to the recipient.
    /// @param params The withdrawal arguments.
    /// @return amount0 Currency0 principal.
    /// @return amount1 Currency1 principal.
    /// @return fees0 Currency0 fees.
    /// @return fees1 Currency1 fees.
    function withdraw(WithdrawParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1, uint256 fees0, uint256 fees1);

    /// @notice Realises the range's fees and pays the caller's fees to the recipient. Principal is untouched.
    /// @param key The pool.
    /// @param tickLower The range's lower tick.
    /// @param tickUpper The range's upper tick.
    /// @param recipient The account that receives the fees.
    /// @return fees0 The currency0 fees paid.
    /// @return fees1 The currency1 fees paid.
    function claim(PoolKey calldata key, int24 tickLower, int24 tickUpper, address recipient)
        external
        returns (uint256 fees0, uint256 fees1);

    /// @notice Realises the range's accrued fees into the per-share accumulators. Permissionless.
    /// @param key The pool.
    /// @param tickLower The range's lower tick.
    /// @param tickUpper The range's upper tick.
    function poke(PoolKey calldata key, int24 tickLower, int24 tickUpper) external;

    /// @notice Sets the skim. Lowering is immediate and voids every SET_SKIM queued before it; raising consumes a
    ///         queued SET_SKIM(bps) operation. A raise applies to fees realised after it, including fees the pool
    ///         accrued earlier that nobody realised; anyone can poke a range during the delay to realise them first.
    /// @param bps The new skim, in basis points.
    function setSkim(uint16 bps) external;

    /// @notice Pays skimmed fees in `currency` to the protocol recipient. Permissionless.
    /// @param currency The currency.
    /// @return The amount paid.
    function collectProtocolFees(Currency currency) external returns (uint256);

    /// @notice Returns the share id of a range.
    /// @param poolId The pool.
    /// @param tickLower The range's lower tick.
    /// @param tickUpper The range's upper tick.
    /// @return The range's share id.
    function rangeId(PoolId poolId, int24 tickLower, int24 tickUpper) external pure returns (uint256);

    /// @notice Returns a registered range. A zero poolId means the id was never used.
    /// @param id The range id.
    /// @return The range.
    function range(uint256 id) external view returns (Range memory);

    /// @notice Returns an account's checkpoints and realised unpaid fees, before settling the latest accumulator.
    /// @param id The range id.
    /// @param holder The holder.
    /// @return The holder's checkpoints and unpaid fees.
    function account(uint256 id, address holder) external view returns (Account memory);

    /// @notice Returns the fees a claim would pay now, including fees accrued in the pool but not yet realised.
    /// @param key The pool.
    /// @param tickLower The range's lower tick.
    /// @param tickUpper The range's upper tick.
    /// @param holder The holder.
    /// @return fees0 The currency0 fees a claim would pay.
    /// @return fees1 The currency1 fees a claim would pay.
    function pendingFees(PoolKey calldata key, int24 tickLower, int24 tickUpper, address holder)
        external
        view
        returns (uint256 fees0, uint256 fees1);
}
