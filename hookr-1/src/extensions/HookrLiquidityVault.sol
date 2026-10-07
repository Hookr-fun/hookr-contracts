// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {ERC6909} from "@uniswap/v4-core/src/ERC6909.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {HookrGoverned} from "../base/HookrGoverned.sol";
import {HookrReleased} from "../base/HookrReleased.sol";
import {IHookrProtocolClaims} from "../interfaces/IHookrProtocolClaims.sol";
import {IHookrLiquidityVault} from "../interfaces/IHookrLiquidityVault.sol";

/// @title HookrLiquidityVault
/// @notice Pools LP liquidity into one PoolManager position per (pool, tickLower, tickUpper) range and issues
///         ERC-6909 shares 1:1 with that position's liquidity. Works with Hookr roots and any other v4 pool.
/// @dev Fees realise whenever a range's position is modified (deposit, withdraw, claim, poke) and are credited to
///      the shares outstanding before that modification through per-range Q128 fee-per-share accumulators, so a
///      later depositor never earns fees realised before its shares exist. Realised fees are held as PoolManager
///      ERC-6909 claims. A share transfer settles realised fees to both parties first; fees still unrealised in the
///      pool follow the shares (poke the range first to realise them). All rounding favours the vault.
///      The optional protocol skim applies to realised fees only, never to principal, and is paid only to the
///      immutable protocol recipient. The owner can change the skim and nothing else: there is no pause, no sweep and
///      no authority over principal. Withdrawals are refused only by the pool itself, for example by a Hookr root
///      during its launch-guard removal lock; fee claims use a zero-liquidity modification, which Hookr roots allow.
contract HookrLiquidityVault is
    HookrReleased,
    ERC6909,
    HookrGoverned,
    IUnlockCallback,
    IHookrProtocolClaims,
    IHookrLiquidityVault
{
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using SafeCast for int128;

    /// @notice Timelock kind for raising the skim.
    bytes32 public constant SET_SKIM = keccak256("SET_SKIM");
    /// @notice Hard ceiling for maxSkimBps.
    uint16 public constant SKIM_CEILING_BPS = 2_000;
    uint256 private constant BPS = 10_000;
    uint256 private constant MAX_AMOUNT = uint128(type(int128).max);
    uint8 private constant DEPOSIT = 0;
    uint8 private constant WITHDRAW = 1;
    uint8 private constant CLAIM = 2;
    uint8 private constant POKE = 3;
    uint8 private constant PROTOCOL = 4;
    /// @dev keccak256("hookr.vault.transient.entered")
    bytes32 private constant ENTERED = 0xe1700c7d44cc571e32c4f14bfacd14fc8077377789823bba66eecd1d60df050f;

    /// @inheritdoc IHookrProtocolClaims
    /// @notice The PoolManager holding every position and realised fee.
    IPoolManager public immutable poolManager;
    /// @inheritdoc IHookrProtocolClaims
    /// @notice The only recipient of skimmed fees.
    address public immutable protocolRecipient;
    /// @inheritdoc IHookrLiquidityVault
    uint16 public immutable maxSkimBps;
    /// @inheritdoc IHookrLiquidityVault
    uint16 public skimBps;

    /// @inheritdoc IHookrLiquidityVault
    mapping(uint256 id => uint256) public totalSupply;
    /// @inheritdoc IHookrLiquidityVault
    mapping(Currency currency => uint256) public protocolFees;
    mapping(uint256 id => Range) private _ranges;
    mapping(uint256 id => mapping(address account => Account)) private _accounts;

    /// @param manager The PoolManager.
    /// @param recipient The protocol recipient, normally the Hookr treasury. Immutable.
    /// @param owner_ The skim owner.
    /// @param delay_ Timelock delay for raising the skim.
    /// @param maxSkim Immutable skim bound, at most SKIM_CEILING_BPS.
    constructor(IPoolManager manager, address recipient, address owner_, uint48 delay_, uint16 maxSkim)
        HookrGoverned(owner_, delay_)
    {
        if (address(manager).code.length == 0 || recipient == address(0) || recipient == address(manager)) {
            revert InvalidAddress(recipient);
        }
        if (maxSkim > SKIM_CEILING_BPS) revert InvalidSkim(maxSkim);
        poolManager = manager;
        protocolRecipient = recipient;
        maxSkimBps = maxSkim;
    }

    modifier nonReentrant() {
        if (_entered() != 0) revert Reentrancy();
        _enter(1);
        _;
        _enter(0);
    }

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlinePassed(deadline);
        _;
    }

    /// @inheritdoc IHookrLiquidityVault
    function deposit(DepositParams calldata params)
        external
        payable
        nonReentrant
        checkDeadline(params.deadline)
        returns (uint256 id, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        _checkRecipient(params.recipient);
        bool native = params.key.currency0.isAddressZero();
        if (msg.value != 0 && !native) revert InvalidValue();
        (id, liquidity, amount0, amount1) = abi.decode(
            poolManager.unlock(abi.encode(DEPOSIT, abi.encode(params, msg.sender, msg.value))),
            (uint256, uint128, uint256, uint256)
        );
        if (native && msg.value > amount0) {
            (bool ok,) = msg.sender.call{value: msg.value - amount0}("");
            if (!ok) revert RefundFailed();
        }
    }

    /// @inheritdoc IHookrLiquidityVault
    function withdraw(WithdrawParams calldata params)
        external
        nonReentrant
        checkDeadline(params.deadline)
        returns (uint256 amount0, uint256 amount1, uint256 fees0, uint256 fees1)
    {
        _checkRecipient(params.recipient);
        return abi.decode(
            poolManager.unlock(abi.encode(WITHDRAW, abi.encode(params, msg.sender))),
            (uint256, uint256, uint256, uint256)
        );
    }

    /// @inheritdoc IHookrLiquidityVault
    function claim(PoolKey calldata key, int24 tickLower, int24 tickUpper, address recipient)
        external
        nonReentrant
        returns (uint256 fees0, uint256 fees1)
    {
        _checkRecipient(recipient);
        return abi.decode(
            poolManager.unlock(abi.encode(CLAIM, abi.encode(key, tickLower, tickUpper, msg.sender, recipient))),
            (uint256, uint256)
        );
    }

    /// @inheritdoc IHookrLiquidityVault
    function poke(PoolKey calldata key, int24 tickLower, int24 tickUpper) external nonReentrant {
        poolManager.unlock(abi.encode(POKE, abi.encode(key, tickLower, tickUpper, msg.sender, msg.sender)));
    }

    /// @inheritdoc ERC6909
    /// @notice Transfers shares after settling both parties' realised fees.
    function transfer(address receiver, uint256 id, uint256 amount) public override nonReentrant returns (bool) {
        _beforeTransfer(msg.sender, receiver, id);
        return super.transfer(receiver, id, amount);
    }

    /// @inheritdoc ERC6909
    /// @notice Transfers shares after settling both parties' realised fees.
    function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
        public
        override
        nonReentrant
        returns (bool)
    {
        _beforeTransfer(sender, receiver, id);
        return super.transferFrom(sender, receiver, id, amount);
    }

    /// @inheritdoc IHookrLiquidityVault
    function setSkim(uint16 bps) external onlyOwner {
        if (bps > maxSkimBps) revert InvalidSkim(bps);
        if (bps > skimBps) _consume(SET_SKIM, abi.encode(bps));
        else if (bps < skimBps) _invalidateQueued(SET_SKIM);
        skimBps = bps;
        emit SkimSet(bps);
    }

    /// @inheritdoc IHookrLiquidityVault
    function collectProtocolFees(Currency currency) external nonReentrant returns (uint256) {
        return _payProtocol(currency, protocolRecipient);
    }

    /// @inheritdoc IHookrProtocolClaims
    function claimable(Currency currency, address claimant) external view returns (uint256) {
        return claimant == protocolRecipient ? protocolFees[currency] : 0;
    }

    /// @inheritdoc IHookrProtocolClaims
    /// @dev Only the protocol recipient can call.
    function claimTo(Currency currency, address to) external nonReentrant returns (uint256) {
        if (msg.sender != protocolRecipient) revert Unauthorized(msg.sender);
        if (to == address(0) || to == address(poolManager) || to == address(this)) revert InvalidAddress(to);
        return _payProtocol(currency, to);
    }

    /// @inheritdoc IHookrLiquidityVault
    function rangeId(PoolId poolId, int24 tickLower, int24 tickUpper) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(poolId, tickLower, tickUpper)));
    }

    /// @inheritdoc IHookrLiquidityVault
    function range(uint256 id) external view returns (Range memory) {
        return _ranges[id];
    }

    /// @inheritdoc IHookrLiquidityVault
    function account(uint256 id, address holder) external view returns (Account memory) {
        return _accounts[id][holder];
    }

    /// @inheritdoc IHookrLiquidityVault
    function pendingFees(PoolKey calldata key, int24 tickLower, int24 tickUpper, address holder)
        external
        view
        returns (uint256 fees0, uint256 fees1)
    {
        PoolId poolId = key.toId();
        uint256 id = rangeId(poolId, tickLower, tickUpper);
        Range storage r = _ranges[id];
        uint256 per0 = r.feesPerShare0X128;
        uint256 per1 = r.feesPerShare1X128;
        uint256 supply = totalSupply[id];
        if (supply != 0) {
            (uint128 liquidity, uint256 last0, uint256 last1) =
                poolManager.getPositionInfo(poolId, address(this), tickLower, tickUpper, bytes32(0));
            (uint256 inside0, uint256 inside1) = poolManager.getFeeGrowthInside(poolId, tickLower, tickUpper);
            uint256 u0;
            uint256 u1;
            unchecked {
                u0 = FullMath.mulDiv(inside0 - last0, liquidity, FixedPoint128.Q128);
                u1 = FullMath.mulDiv(inside1 - last1, liquidity, FixedPoint128.Q128);
                per0 += FullMath.mulDiv(u0 - u0 * skimBps / BPS, FixedPoint128.Q128, supply);
                per1 += FullMath.mulDiv(u1 - u1 * skimBps / BPS, FixedPoint128.Q128, supply);
            }
        }
        Account storage a = _accounts[id][holder];
        uint256 balance = balanceOf[holder][id];
        fees0 = a.owed0;
        fees1 = a.owed1;
        unchecked {
            fees0 += FullMath.mulDiv(per0 - a.feesPerShare0X128, balance, FixedPoint128.Q128);
            fees1 += FullMath.mulDiv(per1 - a.feesPerShare1X128, balance, FixedPoint128.Q128);
        }
    }

    /// @inheritdoc IUnlockCallback
    /// @notice Executes one vault action inside the PoolManager lock. Only reachable from this contract's unlock.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || _entered() == 0) revert Unauthorized(msg.sender);
        (uint8 action, bytes memory args) = abi.decode(data, (uint8, bytes));
        if (action == DEPOSIT) return _deposit(args);
        if (action == WITHDRAW) return _withdraw(args);
        if (action == PROTOCOL) {
            (Currency currency, address to, uint256 amount) = abi.decode(args, (Currency, address, uint256));
            poolManager.burn(address(this), currency.toId(), amount);
            poolManager.take(currency, to, amount);
            return "";
        }
        return _claim(args, action == CLAIM);
    }

    function _deposit(bytes memory args) private returns (bytes memory) {
        (DepositParams memory p, address payer, uint256 value) = abi.decode(args, (DepositParams, address, uint256));
        PoolId poolId = p.key.toId();
        uint256 id = _open(poolId, p.tickLower, p.tickUpper);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint256 liquidity = _liquidityFor(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(p.tickLower),
            TickMath.getSqrtPriceAtTick(p.tickUpper),
            p.amount0Desired,
            p.amount1Desired
        );
        if (liquidity == 0 || liquidity > MAX_AMOUNT) revert InvalidLiquidity();
        (int256 principal0, int256 principal1, uint256 fees0, uint256 fees1) =
            _modify(p.key, p.tickLower, p.tickUpper, id, int256(liquidity));
        if (principal0 > 0 || principal1 > 0) revert UnexpectedDelta(principal0, principal1);
        uint256 paid0 = uint256(-principal0);
        uint256 paid1 = uint256(-principal1);
        if (paid0 > p.amount0Desired || paid1 > p.amount1Desired || paid0 < p.amount0Min || paid1 < p.amount1Min) {
            revert Slippage(paid0, paid1);
        }
        if (p.key.currency0.isAddressZero() && paid0 > value) revert InvalidValue();
        _accrue(id, p.recipient);
        _mint(p.recipient, id, liquidity);
        totalSupply[id] += liquidity;
        emit Deposit(id, payer, p.recipient, uint128(liquidity), paid0, paid1);
        _settle(p.key.currency0, fees0, 0, principal0, payer, payer);
        _settle(p.key.currency1, fees1, 0, principal1, payer, payer);
        return abi.encode(id, liquidity, paid0, paid1);
    }

    function _withdraw(bytes memory args) private returns (bytes memory) {
        (WithdrawParams memory p, address owner_) = abi.decode(args, (WithdrawParams, address));
        uint256 id = rangeId(p.key.toId(), p.tickLower, p.tickUpper);
        uint256 balance = balanceOf[owner_][id];
        if (p.liquidity == 0) revert InvalidLiquidity();
        if (balance < p.liquidity) revert InsufficientShares(balance, p.liquidity);
        (int256 principal0, int256 principal1, uint256 fees0, uint256 fees1) =
            _modify(p.key, p.tickLower, p.tickUpper, id, -int256(uint256(p.liquidity)));
        if (principal0 < 0 || principal1 < 0) revert UnexpectedDelta(principal0, principal1);
        if (uint256(principal0) < p.amount0Min || uint256(principal1) < p.amount1Min) {
            revert Slippage(uint256(principal0), uint256(principal1));
        }
        _accrue(id, owner_);
        _burn(owner_, id, p.liquidity);
        totalSupply[id] -= p.liquidity;
        (uint256 paid0, uint256 paid1) = _takeOwed(id, owner_, uint256(principal0), uint256(principal1));
        emit Withdraw(id, owner_, p.recipient, p.liquidity, uint256(principal0), uint256(principal1));
        emit FeesClaimed(id, owner_, p.recipient, paid0, paid1);
        _settle(p.key.currency0, fees0, paid0, principal0, owner_, p.recipient);
        _settle(p.key.currency1, fees1, paid1, principal1, owner_, p.recipient);
        return abi.encode(uint256(principal0), uint256(principal1), paid0, paid1);
    }

    /// @dev Claim when `pay`, otherwise poke. A range with no shares has no position to touch.
    function _claim(bytes memory args, bool pay) private returns (bytes memory) {
        (PoolKey memory key, int24 tickLower, int24 tickUpper, address owner_, address recipient) =
            abi.decode(args, (PoolKey, int24, int24, address, address));
        uint256 id = rangeId(key.toId(), tickLower, tickUpper);
        int256 principal0;
        int256 principal1;
        uint256 fees0;
        uint256 fees1;
        if (totalSupply[id] != 0) {
            (principal0, principal1, fees0, fees1) = _modify(key, tickLower, tickUpper, id, 0);
            if (principal0 != 0 || principal1 != 0) revert UnexpectedDelta(principal0, principal1);
        } else if (!pay) {
            revert InvalidLiquidity();
        }
        uint256 paid0;
        uint256 paid1;
        if (pay) {
            _accrue(id, owner_);
            (paid0, paid1) = _takeOwed(id, owner_, 0, 0);
            emit FeesClaimed(id, owner_, recipient, paid0, paid1);
        }
        _settle(key.currency0, fees0, paid0, 0, owner_, recipient);
        _settle(key.currency1, fees1, paid1, 0, owner_, recipient);
        return abi.encode(paid0, paid1);
    }

    /// @dev Queue-time admission: SET_SKIM with one canonical uint16 above the current skim and no higher than
    ///      maxSkimBps, and TRANSFER_OWNER; every other kind is refused. setSkim applies a value at or below the
    ///      current skim at once without consuming anything, so each admitted operation is executable when queued.
    ///      A later lowering voids every queued raise, and a raise past a queued value leaves it unexecutable.
    function _checkQueue(bytes32 kind, bytes calldata arguments) internal view override {
        if (kind == SET_SKIM) {
            uint16 bps = abi.decode(arguments, (uint16));
            if (bps > maxSkimBps || bps <= skimBps) revert InvalidSkim(bps);
            _requireCanonical(kind, arguments, abi.encode(bps));
        } else if (kind == TRANSFER_OWNER) {
            super._checkQueue(kind, arguments);
        } else {
            revert UnknownOperation(kind);
        }
    }

    /// @dev Modifies the vault position and realises its fees against the shares outstanding before the change.
    ///      principal = callerDelta - feesAccrued, positive when the pool pays the vault.
    function _modify(PoolKey memory key, int24 tickLower, int24 tickUpper, uint256 id, int256 liquidityDelta)
        private
        returns (int256 principal0, int256 principal1, uint256 fees0, uint256 fees1)
    {
        (BalanceDelta callerDelta, BalanceDelta feesAccrued) =
            poolManager.modifyLiquidity(key, ModifyLiquidityParams(tickLower, tickUpper, liquidityDelta, 0), "");
        fees0 = feesAccrued.amount0().toUint128();
        fees1 = feesAccrued.amount1().toUint128();
        principal0 = int256(callerDelta.amount0()) - int256(fees0);
        principal1 = int256(callerDelta.amount1()) - int256(fees1);
        if (fees0 != 0 || fees1 != 0) _realize(id, key.currency0, key.currency1, fees0, fees1);
    }

    /// @dev Skim rounds down; the per-share credit rounds down, leaving any remainder in the vault.
    function _realize(uint256 id, Currency currency0, Currency currency1, uint256 fees0, uint256 fees1) private {
        uint256 supply = totalSupply[id];
        uint256 bps = skimBps;
        uint256 skim0 = fees0 * bps / BPS;
        uint256 skim1 = fees1 * bps / BPS;
        if (supply == 0) {
            // Unreachable while shares equal position liquidity: an empty position accrues nothing.
            skim0 = fees0;
            skim1 = fees1;
        } else {
            Range storage r = _ranges[id];
            unchecked {
                r.feesPerShare0X128 += FullMath.mulDiv(fees0 - skim0, FixedPoint128.Q128, supply);
                r.feesPerShare1X128 += FullMath.mulDiv(fees1 - skim1, FixedPoint128.Q128, supply);
            }
        }
        if (skim0 != 0) protocolFees[currency0] += skim0;
        if (skim1 != 0) protocolFees[currency1] += skim1;
        emit FeesRealized(id, fees0, fees1, skim0, skim1);
    }

    /// @dev Credits the holder's realised fees since its checkpoint and moves the checkpoint to the accumulator.
    function _accrue(uint256 id, address holder) private {
        Range storage r = _ranges[id];
        Account storage a = _accounts[id][holder];
        uint256 per0 = r.feesPerShare0X128;
        uint256 per1 = r.feesPerShare1X128;
        uint256 balance = balanceOf[holder][id];
        if (balance != 0) {
            uint256 delta0;
            uint256 delta1;
            unchecked {
                delta0 = per0 - a.feesPerShare0X128;
                delta1 = per1 - a.feesPerShare1X128;
            }
            if (delta0 != 0) a.owed0 += FullMath.mulDiv(delta0, balance, FixedPoint128.Q128);
            if (delta1 != 0) a.owed1 += FullMath.mulDiv(delta1, balance, FixedPoint128.Q128);
        }
        if (a.feesPerShare0X128 != per0) a.feesPerShare0X128 = per0;
        if (a.feesPerShare1X128 != per1) a.feesPerShare1X128 = per1;
    }

    /// @dev Debits the holder's owed fees, bounded so principal plus fees fits one PoolManager take.
    function _takeOwed(uint256 id, address holder, uint256 principal0, uint256 principal1)
        private
        returns (uint256 paid0, uint256 paid1)
    {
        Account storage a = _accounts[id][holder];
        paid0 = _bounded(a.owed0, principal0);
        paid1 = _bounded(a.owed1, principal1);
        if (paid0 != 0) a.owed0 -= paid0;
        if (paid1 != 0) a.owed1 -= paid1;
    }

    function _payProtocol(Currency currency, address to) private returns (uint256 amount) {
        amount = _bounded(protocolFees[currency], 0);
        if (amount == 0) return 0;
        protocolFees[currency] -= amount;
        emit ProtocolFeesPaid(currency, to, amount);
        poolManager.unlock(abi.encode(PROTOCOL, abi.encode(currency, to, amount)));
    }

    /// @dev Nets this contract's PoolManager deltas for one currency. `held` realised fees stay as ERC-6909 claims,
    ///      `paid` fees leave them, a negative principal is paid by `payer` and the rest is taken to `receiver`.
    function _settle(Currency currency, uint256 held, uint256 paid, int256 principal, address payer, address receiver)
        private
    {
        if (held > paid) poolManager.mint(address(this), currency.toId(), held - paid);
        else if (paid > held) poolManager.burn(address(this), currency.toId(), paid - held);
        int256 net = principal + int256(paid);
        if (net > 0) {
            poolManager.take(currency, receiver, uint256(net));
        } else if (net < 0) {
            uint256 amount = uint256(-net);
            if (currency.isAddressZero()) {
                poolManager.settle{value: amount}();
            } else {
                poolManager.sync(currency);
                _transferFrom(Currency.unwrap(currency), payer, address(poolManager), amount);
                poolManager.settle();
            }
        }
    }

    function _open(PoolId poolId, int24 tickLower, int24 tickUpper) private returns (uint256 id) {
        if (tickLower >= tickUpper) revert InvalidRange();
        id = rangeId(poolId, tickLower, tickUpper);
        Range storage r = _ranges[id];
        if (PoolId.unwrap(r.poolId) == bytes32(0)) {
            r.poolId = poolId;
            r.tickLower = tickLower;
            r.tickUpper = tickUpper;
            emit RangeOpened(id, poolId, tickLower, tickUpper);
        }
    }

    function _beforeTransfer(address from, address to, uint256 id) private {
        if (to == address(0)) revert InvalidAddress(to);
        _accrue(id, from);
        _accrue(id, to);
    }

    function _checkRecipient(address to) private view {
        if (to == address(0) || to == address(this) || to == address(poolManager)) revert InvalidAddress(to);
    }

    function _transferFrom(address token, address from, address to, uint256 amount) private {
        (bool ok, bytes memory result) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, amount));
        if (
            !ok || token.code.length == 0
                || (result.length != 0 && (result.length != 32 || !abi.decode(result, (bool))))
        ) {
            revert TransferFailed();
        }
    }

    /// @dev min(owed, MAX_AMOUNT - principal).
    function _bounded(uint256 owed, uint256 principal) private pure returns (uint256) {
        uint256 room = MAX_AMOUNT - principal;
        return owed < room ? owed : room;
    }

    /// @dev Liquidity bought by amounts at the current price, rounded down.
    function _liquidityFor(uint160 price, uint160 lower, uint160 upper, uint256 amount0, uint256 amount1)
        private
        pure
        returns (uint256)
    {
        if (price <= lower) return _liquidity0(lower, upper, amount0);
        if (price >= upper) return _liquidity1(lower, upper, amount1);
        uint256 l0 = _liquidity0(price, upper, amount0);
        uint256 l1 = _liquidity1(lower, price, amount1);
        return l0 < l1 ? l0 : l1;
    }

    function _liquidity0(uint160 lower, uint160 upper, uint256 amount0) private pure returns (uint256) {
        return FullMath.mulDiv(amount0, FullMath.mulDiv(lower, upper, FixedPoint96.Q96), upper - lower);
    }

    function _liquidity1(uint160 lower, uint160 upper, uint256 amount1) private pure returns (uint256) {
        return FullMath.mulDiv(amount1, FixedPoint96.Q96, upper - lower);
    }

    function _entered() private view returns (uint256 value) {
        bytes32 slot = ENTERED;
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    function _enter(uint256 value) private {
        bytes32 slot = ENTERED;
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }
}
