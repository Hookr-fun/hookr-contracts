// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {HookFeeSplit} from "./HookFeeSplit.sol";

/// @title Fee Buyback Hook
/// @notice A standalone Uniswap v4 hook that charges a quote-denominated hook fee on the two
///         quadrants whose specified leg is the quote currency, and, on a permissionless crank,
///         splits what it collected: a slice to the owner, a slice **donated to the pool** so it
///         accrues to in-range liquidity pro rata, and the rest swapped into a configured hook
///         token and sent to a configured sink (the burn address by default).
/// @dev The hook does **not** touch the LP fee: the trader pays the pool's dynamic LP fee plus the
///      hook fee, and every wei of the hook fee is accounted for by `HookFeeSplit.split`. The
///      parameter set is proposed by the owner and can only take effect after `CONFIG_DELAY`; the
///      owner's share of the hook fee is hard-capped at 10% in the library, so the timelock cannot
///      be used to raise it.
contract FeeBuybackHook is IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    /// @dev `beforeSwap` returns a specified-currency delta (the fee), so the address must carry
    ///      the delta flag alongside the two callbacks it implements.
    uint160 public constant REQUIRED_FLAGS =
        Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;

    /// @dev Minimum timelock on a parameter change, whichever is longer with the constructor's.
    uint256 internal constant MIN_CONFIG_DELAY = 1 days;

    /// @dev The parameters that decide where the fee goes. The first six fields pack into one slot.
    struct Config {
        uint24 hookFeePips; // fee charged on the quote leg, in pips of the specified amount
        uint24 lpFeePips; // dynamic LP fee the hook sets on every swap
        uint24 ownerBps; // share of the hook fee to ownerFeeRecipient
        uint24 lpBps; // share of the hook fee donated to in-range liquidity
        uint24 buybackBps; // share of the hook fee swapped into hookToken
        uint16 maxSlippageBps; // tolerated shortfall of the buyback against the pre-swap spot
        bool paused; // true charges no hook fee at all; swaps are never blocked
        address ownerFeeRecipient; // receives the owner share
        Currency hookToken; // the token bought back
        PoolKey buybackKey; // pool the buyback is executed on (contains quote and hookToken)
        address buybackSink; // where the bought hook tokens go; the burn address by default
        uint256 minCrankQuote; // cranks that would distribute less than this revert
    }

    IPoolManager public immutable poolManager;
    /// @notice The single pool this hook serves; its `hooks` field is this contract.
    PoolKey public poolKey;
    /// @notice The currency the hook fee is denominated in, and the currency of the buyback input.
    Currency public immutable quote;
    address public immutable owner;
    /// @notice Timelock between proposing a config and executing it.
    uint256 public immutable configDelay;

    Config internal _config;
    Config internal _pendingConfig;
    uint256 public configEta;
    bool private locked;

    error NotPoolManager();
    error NotOwner();
    error HookNotImplemented();
    error UnknownPool();
    error QuoteNotInPool();
    error HookTokenIsQuote();
    error BuybackKeyMismatch();
    error InvalidRecipient();
    error ConfigDelayTooShort();
    error ConfigNotProposed();
    error ConfigNotReady();
    error NothingToCrank();
    error PoolNotInitialized();
    error SlippageExceeded(uint256 received, uint256 floor);
    error Reentrancy();

    event HookFeeAccrued(PoolId indexed poolId, address indexed sender, uint256 fee);
    event FeeSplit(uint256 amount, uint256 toOwner, uint256 toLp, uint256 toBuyback);
    event LpDonation(uint256 amount);
    event BuybackExecuted(uint256 quoteIn, uint256 hookTokenOut, address sink);
    event ConfigProposed(Config config, uint256 eta);
    event ConfigExecuted(Config config);
    event ConfigCancelled();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier nonReentrant() {
        if (locked) revert Reentrancy();
        locked = true;
        _;
        locked = false;
    }

    /// @param poolManager_ the v4 PoolManager this hook is pinned to
    /// @param poolKey_ the pool's currencies, tick spacing and (ignored) fee and hooks; the hook
    ///        forces `DYNAMIC_FEE_FLAG` and `hooks = this`
    /// @param quote_ the currency the hook fee is charged in; must be one of the pool's currencies
    /// @param owner_ the only address that may propose configs; immutable
    /// @param configDelay_ minimum delay before a proposed config can be executed
    /// @param initialConfig the starting parameter set
    constructor(
        IPoolManager poolManager_,
        PoolKey memory poolKey_,
        Currency quote_,
        address owner_,
        uint256 configDelay_,
        Config memory initialConfig
    ) {
        if (owner_ == address(0) || initialConfig.ownerFeeRecipient == address(0)) {
            revert InvalidRecipient();
        }
        if (configDelay_ < MIN_CONFIG_DELAY) revert ConfigDelayTooShort();
        if (
            Currency.unwrap(quote_) != Currency.unwrap(poolKey_.currency0)
                && Currency.unwrap(quote_) != Currency.unwrap(poolKey_.currency1)
        ) revert QuoteNotInPool();

        poolManager = poolManager_;
        quote = quote_;
        owner = owner_;
        configDelay = configDelay_;
        poolKey = PoolKey({
            currency0: poolKey_.currency0,
            currency1: poolKey_.currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: poolKey_.tickSpacing,
            hooks: IHooks(address(this))
        });
        _validateConfig(initialConfig);
        _config = initialConfig;

        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------- swap callbacks

    /// @inheritdoc IHooks
    /// @dev Charges the hook fee by returning a positive *specified* delta, which the PoolManager
    ///      takes from the swap's specified leg and credits to the hook. The swap amount is reduced
    ///      by the fee, so the trader's total cost is unchanged by the split: it is the same fee
    ///      they would have paid, routed by this hook instead of accruing to the pool.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolKey.toId())) revert UnknownPool();

        Config memory c = _config;
        BeforeSwapDelta delta = BeforeSwapDeltaLibrary.ZERO_DELTA;
        uint256 fee = _hookFee(c, params);
        if (fee != 0) delta = toBeforeSwapDelta(int128(uint128(fee)), 0);

        return (IHooks.beforeSwap.selector, delta, c.lpFeePips | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @inheritdoc IHooks
    /// @dev Takes the fee that `beforeSwap` credited, so it sits in this contract until a crank
    ///      splits it. The credit lands when this callback returns, which is why the take here can
    ///      never leave a settled delta behind.
    function afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolKey.toId())) revert UnknownPool();

        uint256 fee = _hookFee(_config, params);
        if (fee != 0) {
            poolManager.take(quote, address(this), fee);
            emit HookFeeAccrued(key.toId(), sender, fee);
        }
        return (IHooks.afterSwap.selector, 0);
    }

    // ---------------------------------------------------------------- crank

    /// @notice Split everything the hook holds and execute the buyback. Permissionless: the split
    ///         is fixed by the config, and `minHookOut` can only tighten the slippage floor.
    /// @param minHookOut the caller's floor on the buyback output; the hook raises it to the
    ///        spot-derived floor when the caller's is lower
    function crank(uint256 minHookOut) external nonReentrant {
        uint256 amount = quote.balanceOfSelf();
        Config memory c = _config;
        if (amount < c.minCrankQuote) revert NothingToCrank();

        (uint256 toOwner, uint256 toLp, uint256 toBuyback) = HookFeeSplit.split(amount, c.ownerBps, c.lpBps);
        if (toOwner != 0) quote.transfer(c.ownerFeeRecipient, toOwner);
        emit FeeSplit(amount, toOwner, toLp, toBuyback);

        if (toLp != 0 || toBuyback != 0) {
            poolManager.unlock(abi.encode(toLp, toBuyback, minHookOut));
        }
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        Config memory c = _config;
        (uint256 toLp, uint256 toBuyback, uint256 minHookOut) = abi.decode(data, (uint256, uint256, uint256));

        if (toLp != 0) {
            // Donating credits every unit of in-range liquidity pro rata, so the LP leg needs no
            // position register and no custody: the value is in the pool, claimable by its LPs.
            poolManager.sync(quote);
            quote.transfer(address(poolManager), toLp);
            poolManager.settle();
            PoolKey memory k = poolKey;
            poolManager.donate(k, k.currency0 == quote ? toLp : 0, k.currency1 == quote ? toLp : 0, "");
            emit LpDonation(toLp);
        }

        if (toBuyback != 0) {
            uint256 floor = HookFeeSplit.slippageFloor(_spotOut(c.buybackKey, toBuyback), c.maxSlippageBps);
            if (minHookOut < floor) minHookOut = floor;

            PoolKey memory bk = c.buybackKey;
            bool zeroForOne = bk.currency0 == quote;
            BalanceDelta delta = poolManager.swap(
                bk,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(toBuyback),
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
            uint256 received = uint256(uint128(zeroForOne ? delta.amount1() : delta.amount0()));
            if (received < minHookOut) revert SlippageExceeded(received, minHookOut);

            poolManager.sync(quote);
            quote.transfer(address(poolManager), toBuyback);
            poolManager.settle();
            poolManager.take(c.hookToken, c.buybackSink, received);
            emit BuybackExecuted(toBuyback, received, c.buybackSink);
        }

        return "";
    }

    // ---------------------------------------------------------------- owner, timelocked

    function proposeConfig(Config calldata next) external {
        if (msg.sender != owner) revert NotOwner();
        _validateConfig(next);
        _pendingConfig = next;
        configEta = block.timestamp + configDelay;
        emit ConfigProposed(next, configEta);
    }

    function executeConfig() external {
        if (msg.sender != owner) revert NotOwner();
        if (configEta == 0) revert ConfigNotProposed();
        if (block.timestamp < configEta) revert ConfigNotReady();
        Config memory next = _pendingConfig;
        delete _pendingConfig;
        configEta = 0;
        _config = next;
        emit ConfigExecuted(next);
    }

    function cancelConfig() external {
        if (msg.sender != owner) revert NotOwner();
        if (configEta == 0) revert ConfigNotProposed();
        delete _pendingConfig;
        configEta = 0;
        emit ConfigCancelled();
    }

    /// @notice The live parameter set.
    function hookConfig() external view returns (Config memory) {
        return _config;
    }

    /// @notice The parameter set waiting for its timelock, if any.
    function pendingHookConfig() external view returns (Config memory) {
        return _pendingConfig;
    }

    // ---------------------------------------------------------------- internals

    /// @dev The fee, or zero when the hook is paused or the swap's specified leg is not the quote.
    function _hookFee(Config memory c, SwapParams calldata params) internal view returns (uint256) {
        if (c.paused || c.hookFeePips == 0) return 0;
        bool exactInput = params.amountSpecified < 0;
        address input = Currency.unwrap(params.zeroForOne ? poolKey.currency0 : poolKey.currency1);
        bool isBuy = input == Currency.unwrap(quote);
        if (!HookFeeSplit.chargeable(isBuy, exactInput)) return 0;
        uint256 specified = uint256(params.amountSpecified < 0 ? -params.amountSpecified : params.amountSpecified);
        return HookFeeSplit.hookFee(specified, c.hookFeePips);
    }

    /// @dev The buyback output the pool's spot price implies, raw-to-raw (decimals live inside the
    ///      raw amounts, so no decimal scaling is needed). Used only to raise a caller-supplied
    ///      floor: the realised output is checked against it after the swap.
    function _spotOut(PoolKey memory bk, uint256 quoteIn) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(bk.toId());
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();
        uint256 priceX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        if (bk.currency0 == quote) return FullMath.mulDiv(quoteIn, priceX192, uint256(1) << 192);
        return FullMath.mulDiv(quoteIn, uint256(1) << 192, priceX192);
    }

    function _validateConfig(Config memory c) internal view {
        HookFeeSplit.validateHookFee(c.hookFeePips);
        HookFeeSplit.validateShares(c.ownerBps, c.lpBps, c.buybackBps);
        HookFeeSplit.validateSlippage(c.maxSlippageBps);
        if (c.hookFeePips > LPFeeLibrary.MAX_LP_FEE || c.lpFeePips > LPFeeLibrary.MAX_LP_FEE) {
            revert HookFeeSplit.HookFeeAboveCeiling(c.hookFeePips > LPFeeLibrary.MAX_LP_FEE
                    ? c.hookFeePips
                    : c.lpFeePips);
        }
        if (c.ownerFeeRecipient == address(0) || c.buybackSink == address(0)) revert InvalidRecipient();
        if (Currency.unwrap(c.hookToken) == Currency.unwrap(quote)) revert HookTokenIsQuote();
        PoolKey memory bk = c.buybackKey;
        bool hasQuote = bk.currency0 == quote || bk.currency1 == quote;
        bool hasHook = bk.currency0 == c.hookToken || bk.currency1 == c.hookToken;
        if (!hasQuote || !hasHook) revert BuybackKeyMismatch();
    }

    // ---------------------------------------------------------------- unimplemented callbacks

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
