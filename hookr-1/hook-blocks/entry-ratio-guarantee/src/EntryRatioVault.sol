// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ErgTypes} from "./interfaces/ErgTypes.sol";
import {IEntryRatioGuarantee} from "./interfaces/IEntryRatioGuarantee.sol";
import {ErgPositionMath} from "./libraries/ErgPositionMath.sol";

/// @title EntryRatioVault
/// @notice Custody and settlement for Entry Ratio Guarantee positions. The vault owns every enrolled PoolManager
///         position (salt = position id), so nobody, the LP included, can collect or add to it outside a full
///         exit: accrued fees stay in the position until the hook forfeits them.
/// @dev Created by `EntryRatioGuaranteeHook` in its constructor. The vault is a distinct address from the hook so
///      the PoolManager calls the hook's removal callbacks for it (a hook's own calls skip its callbacks). It holds
///      no assets between calls: deposits pull exactly what the PoolManager charges straight from the LP into the
///      PoolManager, withdrawals take straight from the PoolManager to the recipient (or mint the recipient ERC-6909
///      claims, `withdrawAsClaims`), and unused ETH is refunded in the same call.
contract EntryRatioVault is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    /// @notice Deposit request.
    /// @param key The registered pool
    /// @param tickLower Lower tick of the new position
    /// @param tickUpper Upper tick of the new position
    /// @param liquidity Liquidity to add
    /// @param amount0Max Most currency0 the LP will pay
    /// @param amount1Max Most currency1 the LP will pay
    /// @param term LOCK or OPTION
    /// @param deadline Last timestamp the deposit may execute
    struct DepositParams {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 amount0Max;
        uint128 amount1Max;
        ErgTypes.Term term;
        uint256 deadline;
    }

    /// @notice Withdrawal request. Always a full exit of one position.
    /// @param positionId The position
    /// @param exercise True to ask for the entry ratio: a LOCK position from its unlock until the pool's LOCK coverage
    ///        horizon ends (for the position's life when the pool sets none), an OPTION inside its window. It needs
    ///        the pool's price reference to answer and the pool price inside the reference band
    /// @param recipient Receiver of both currencies
    /// @param amount0Min Least currency0 the LP accepts
    /// @param amount1Min Least currency1 the LP accepts
    /// @param deadline Last timestamp the withdrawal may execute
    struct WithdrawParams {
        uint256 positionId;
        bool exercise;
        address recipient;
        uint128 amount0Min;
        uint128 amount1Min;
        uint256 deadline;
    }

    enum Action {
        DEPOSIT,
        WITHDRAW,
        REDEEM
    }

    /// @notice The Uniswap v4 PoolManager.
    IPoolManager public immutable poolManager;
    /// @notice The hook that created this vault and settles its removals.
    IEntryRatioGuarantee public immutable hook;
    /// @notice The next position id (also the next PoolManager salt).
    uint256 public nextPositionId = 1;

    bool private transient _entered;

    /// @notice Emitted after a deposit settles.
    /// @param positionId The new position
    /// @param owner The LP
    /// @param amount0 currency0 paid
    /// @param amount1 currency1 paid
    event Deposited(uint256 indexed positionId, address indexed owner, uint256 amount0, uint256 amount1);

    /// @notice Emitted after a withdrawal settles.
    /// @param positionId The position
    /// @param recipient Receiver of the amounts
    /// @param exercised Whether the entry ratio was requested
    /// @param amount0 currency0 delivered
    /// @param amount1 currency1 delivered
    event Withdrawn(
        uint256 indexed positionId, address indexed recipient, bool exercised, uint256 amount0, uint256 amount1
    );

    /// @notice Emitted after a withdrawal settles as ERC-6909 claims instead of tokens.
    /// @param positionId The position
    /// @param recipient Receiver of the claims
    /// @param exercised Whether the entry ratio was requested
    /// @param amount0 currency0 claims minted to the recipient
    /// @param amount1 currency1 claims minted to the recipient
    event WithdrawnAsClaims(
        uint256 indexed positionId, address indexed recipient, bool exercised, uint256 amount0, uint256 amount1
    );

    /// @notice Emitted when an account turns its own ERC-6909 claims back into tokens through the vault.
    /// @param owner The account whose claims were burned
    /// @param currency The currency
    /// @param recipient Receiver of the tokens
    /// @param amount Units redeemed
    event ClaimsRedeemed(address indexed owner, Currency indexed currency, address indexed recipient, uint256 amount);

    /// @notice Thrown on reentry.
    error Reentrancy();
    /// @notice Thrown when the unlock callback does not come from the PoolManager.
    error NotPoolManager();
    /// @notice Thrown after the deadline.
    error Expired();
    /// @notice Thrown when ETH is sent for a pool without a native currency, or too little ETH is sent.
    error InvalidValue();
    /// @notice Thrown when a deposit costs more than the LP's maximums.
    error MaxAmountExceeded(uint256 amount0, uint256 amount1);
    /// @notice Thrown when a withdrawal delivers less than the LP's minimums.
    error MinAmountNotMet(uint256 amount0, uint256 amount1);
    /// @notice Thrown when someone other than the position owner withdraws.
    error NotPositionOwner();
    /// @notice Thrown for a zero liquidity or zero recipient.
    error InvalidRequest();
    /// @notice Thrown when a PoolManager delta has an unexpected sign.
    error UnexpectedDelta();
    /// @notice Thrown when an ETH refund fails.
    error RefundFailed();

    modifier nonReentrant() {
        if (_entered) revert Reentrancy();
        _entered = true;
        _;
        _entered = false;
    }

    /// @param manager The Uniswap v4 PoolManager
    /// @param hook_ The hook creating this vault
    constructor(IPoolManager manager, IEntryRatioGuarantee hook_) {
        poolManager = manager;
        hook = hook_;
    }

    /// @notice Adds a new vault-owned position and enrolls it with the hook at its entry amounts.
    /// @dev For a native currency0 pool send at least the currency0 amount as ETH; the excess is refunded to the
    ///      caller. The hook refuses the deposit unless the pool is registered and open and its spot price is
    ///      inside the reference band.
    /// @param p The deposit request
    /// @return positionId The new position id
    /// @return amount0 currency0 paid
    /// @return amount1 currency1 paid
    function deposit(DepositParams calldata p)
        external
        payable
        nonReentrant
        returns (uint256 positionId, uint256 amount0, uint256 amount1)
    {
        if (block.timestamp > p.deadline) revert Expired();
        if (p.liquidity == 0) revert InvalidRequest();
        bool native = p.key.currency0.isAddressZero();
        if (!native && msg.value != 0) revert InvalidValue();
        positionId = nextPositionId++;
        (amount0, amount1) = abi.decode(
            poolManager.unlock(abi.encode(Action.DEPOSIT, abi.encode(p, positionId, msg.sender, msg.value))),
            (uint256, uint256)
        );
        if (native && msg.value > amount0) {
            (bool ok,) = msg.sender.call{value: msg.value - amount0}("");
            if (!ok) revert RefundFailed();
        }
        emit Deposited(positionId, msg.sender, amount0, amount1);
    }

    /// @notice Exits one position in full through the hook's settlement.
    /// @param p The withdrawal request
    /// @return amount0 currency0 delivered to the recipient
    /// @return amount1 currency1 delivered to the recipient
    function withdraw(WithdrawParams calldata p) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = _exit(p, false);
        emit Withdrawn(p.positionId, p.recipient, p.exercise, amount0, amount1);
    }

    /// @notice Exits one position in full, as `withdraw` does, but delivers both currencies as the PoolManager's
    ///         ERC-6909 claims instead of tokens. No token moves, so the exit settles while a pool currency is paused
    ///         or the recipient is blocked by a token, and an exercise window cannot lapse because the tokens could
    ///         not be transferred. The claims are redeemable later through `redeemClaims` or any
    ///         PoolManager integration.
    /// @param p The withdrawal request
    /// @return amount0 currency0 claims minted to the recipient
    /// @return amount1 currency1 claims minted to the recipient
    function withdrawAsClaims(WithdrawParams calldata p)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = _exit(p, true);
        emit WithdrawnAsClaims(p.positionId, p.recipient, p.exercise, amount0, amount1);
    }

    /// @notice Turns the caller's own ERC-6909 claims on the PoolManager into tokens sent to `recipient`. The caller
    ///         must first let the vault burn them (`poolManager.setOperator(vault, true)` or an allowance for the
    ///         currency's id). The vault holds nothing before or after.
    /// @param currency The currency to redeem
    /// @param amount Units to redeem
    /// @param recipient Receiver of the tokens
    function redeemClaims(Currency currency, uint256 amount, address recipient) external nonReentrant {
        if (amount == 0 || recipient == address(0)) revert InvalidRequest();
        poolManager.unlock(abi.encode(Action.REDEEM, abi.encode(currency, amount, msg.sender, recipient)));
        emit ClaimsRedeemed(msg.sender, currency, recipient, amount);
    }

    function _exit(WithdrawParams calldata p, bool asClaims) private returns (uint256 amount0, uint256 amount1) {
        if (block.timestamp > p.deadline) revert Expired();
        if (p.recipient == address(0)) revert InvalidRequest();
        if (hook.position(p.positionId).owner != msg.sender) revert NotPositionOwner();
        (amount0, amount1) =
            abi.decode(poolManager.unlock(abi.encode(Action.WITHDRAW, abi.encode(p, asClaims))), (uint256, uint256));
    }

    /// @notice The largest liquidity the given amounts fund in a pool's current state.
    /// @param key The pool
    /// @param tickLower Lower tick
    /// @param tickUpper Upper tick
    /// @param amount0 Available currency0
    /// @param amount1 Available currency1
    /// @return liquidity The liquidity
    function liquidityForAmounts(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) external view returns (uint128 liquidity) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        return ErgPositionMath.liquidityForAmounts(sqrtPriceX96, tickLower, tickUpper, amount0, amount1);
    }

    /// @notice PoolManager unlock callback.
    /// @param data The encoded action
    /// @return The encoded amounts
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (Action action, bytes memory inner) = abi.decode(data, (Action, bytes));
        if (action == Action.DEPOSIT) return _deposit(inner);
        if (action == Action.WITHDRAW) return _withdraw(inner);
        return _redeem(inner);
    }

    function _deposit(bytes memory inner) private returns (bytes memory) {
        (DepositParams memory p, uint256 positionId, address owner, uint256 value) =
            abi.decode(inner, (DepositParams, uint256, address, uint256));
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            p.key,
            ModifyLiquidityParams({
                tickLower: p.tickLower,
                tickUpper: p.tickUpper,
                liquidityDelta: int256(uint256(p.liquidity)),
                salt: bytes32(positionId)
            }),
            ""
        );
        // A fresh salt has no fees, so both components are payments by the vault.
        if (delta.amount0() > 0 || delta.amount1() > 0) revert UnexpectedDelta();
        uint256 amount0 = uint256(uint128(-delta.amount0()));
        uint256 amount1 = uint256(uint128(-delta.amount1()));
        if (amount0 > p.amount0Max || amount1 > p.amount1Max) revert MaxAmountExceeded(amount0, amount1);
        hook.enroll(
            positionId, owner, p.key, p.tickLower, p.tickUpper, p.liquidity, uint128(amount0), uint128(amount1), p.term
        );
        _pay(p.key.currency0, owner, amount0, value);
        _pay(p.key.currency1, owner, amount1, 0);
        return abi.encode(amount0, amount1);
    }

    function _withdraw(bytes memory inner) private returns (bytes memory) {
        (WithdrawParams memory p, bool asClaims) = abi.decode(inner, (WithdrawParams, bool));
        ErgTypes.Position memory pos = hook.position(p.positionId);
        PoolKey memory key = hook.poolKey(pos.poolId);
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: pos.tickLower,
                tickUpper: pos.tickUpper,
                liquidityDelta: -int256(uint256(pos.liquidity)),
                salt: bytes32(p.positionId)
            }),
            abi.encode(p.exercise)
        );
        if (delta.amount0() < 0 || delta.amount1() < 0) revert UnexpectedDelta();
        uint256 amount0 = uint256(uint128(delta.amount0()));
        uint256 amount1 = uint256(uint128(delta.amount1()));
        if (amount0 < p.amount0Min || amount1 < p.amount1Min) revert MinAmountNotMet(amount0, amount1);
        if (asClaims) {
            if (amount0 > 0) poolManager.mint(p.recipient, key.currency0.toId(), amount0);
            if (amount1 > 0) poolManager.mint(p.recipient, key.currency1.toId(), amount1);
        } else {
            if (amount0 > 0) poolManager.take(key.currency0, p.recipient, amount0);
            if (amount1 > 0) poolManager.take(key.currency1, p.recipient, amount1);
        }
        return abi.encode(amount0, amount1);
    }

    function _redeem(bytes memory inner) private returns (bytes memory) {
        (Currency currency, uint256 amount, address owner, address recipient) =
            abi.decode(inner, (Currency, uint256, address, address));
        poolManager.burn(owner, currency.toId(), amount);
        poolManager.take(currency, recipient, amount);
        return "";
    }

    function _pay(Currency currency, address payer, uint256 amount, uint256 value) private {
        if (amount == 0) return;
        if (currency.isAddressZero()) {
            if (amount > value) revert InvalidValue();
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(poolManager), amount);
            poolManager.settle();
        }
    }
}
