// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {HookrPriceLog} from "../../price-log/src/HookrPriceLog.sol";
import {HookrBuybackBurn} from "../src/HookrBuybackBurn.sol";
import {IHookrBuybackRouter} from "../src/interfaces/IHookrBuybackRouter.sol";

/// @dev The slice of HookrRouter the buyback calls, on a plain v4 pool: an exact-input swap that pulls the input from
///      the caller, pays the output to the recipient and refuses an output under `amountBound`.
contract TestBuybackRouter is IUnlockCallback {
    using CurrencyLibrary for Currency;

    IPoolManager internal immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    function swap(IHookrBuybackRouter.Swap calldata p, address, uint256[] calldata)
        external
        payable
        returns (uint256 amountIn, uint256 amountOut)
    {
        (amountIn, amountOut) = abi.decode(manager.unlock(abi.encode(p, msg.sender)), (uint256, uint256));
        require(amountOut >= p.amountBound, "TestBuybackRouter: bound");
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (IHookrBuybackRouter.Swap memory p, address payer) = abi.decode(data, (IHookrBuybackRouter.Swap, address));
        BalanceDelta d = manager.swap(p.key, SwapParams(p.zeroForOne, p.amountSpecified, p.sqrtPriceLimitX96), "");
        (Currency cin, Currency cout) =
            p.zeroForOne ? (p.key.currency0, p.key.currency1) : (p.key.currency1, p.key.currency0);
        int128 din = p.zeroForOne ? d.amount0() : d.amount1();
        int128 dout = p.zeroForOne ? d.amount1() : d.amount0();
        uint256 paid = uint256(uint128(-din));
        uint256 got = uint256(uint128(dout));
        if (cin.isAddressZero()) {
            manager.settle{value: paid}();
        } else {
            manager.sync(cin);
            MockERC20(Currency.unwrap(cin)).transferFrom(payer, address(manager), paid);
            manager.settle();
        }
        manager.take(cout, p.recipient, got);
        return abi.encode(paid, got);
    }

    receive() external payable {}
}

/// @dev Calls `buyback` from inside an unlock.
contract InUnlockBuyer is IUnlockCallback {
    IPoolManager internal immutable manager;
    HookrBuybackBurn internal immutable buyback;

    constructor(IPoolManager m, HookrBuybackBurn b) {
        manager = m;
        buyback = b;
    }

    function buyInside(uint256 amount) external {
        manager.unlock(abi.encode(amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        buyback.buyback(abi.decode(data, (uint256)));
        return "";
    }
}

/// @dev A plain v4 pool, HOOKR against a quote token, full range at price 1, its price log opened with the defaults
///      (300 s, 500 ticks, 1e18 liquidity), and a buyback bound to it with the deploy-day 300 bps floor and a cap.
///      `hookrIs0()` picks which currency HOOKR is, so every suite runs in both orientations.
abstract contract BuybackBase is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    int24 internal constant SPACING = 60;
    int24 internal constant FULL_LO = -887_220;
    int24 internal constant FULL_HI = 887_220;
    int256 internal constant LIQ = 1e22; // ~10,000 of each side at price 1
    uint256 internal constant T0 = 1_000_000;
    uint128 internal constant CAP = 10e18;

    PoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liquidityRouter;
    TestBuybackRouter internal router;
    HookrPriceLog internal plog;
    MockERC20 internal hookr;
    MockERC20 internal quote;
    PoolKey internal key;
    PoolId internal poolId;
    bytes32 internal logId;
    HookrBuybackBurn internal buyback;

    function hookrIs0() internal pure virtual returns (bool);

    function setUp() public virtual {
        vm.warp(T0);
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        router = new TestBuybackRouter(IPoolManager(address(manager)));
        plog = new HookrPriceLog(IPoolManager(address(manager)));

        MockERC20 a = new MockERC20("HOOKR", "HOOKR", 18);
        MockERC20 b = new MockERC20("Quote", "QUOTE", 18);
        if ((address(a) < address(b)) == hookrIs0()) (hookr, quote) = (a, b);
        else (hookr, quote) = (b, a);
        key = _key(3000, SPACING);
        poolId = key.toId();
        hookr.mint(address(this), 1e30);
        quote.mint(address(this), 1e30);
        hookr.approve(address(swapRouter), type(uint256).max);
        quote.approve(address(swapRouter), type(uint256).max);
        hookr.approve(address(liquidityRouter), type(uint256).max);
        quote.approve(address(liquidityRouter), type(uint256).max);

        logId = plog.open(poolId, logDefaults());
        buyback = new HookrBuybackBurn(address(this), address(hookr), address(router), plog, key, logId, CAP);

        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(FULL_LO, FULL_HI, LIQ, 0), "");
    }

    function _key(uint24 fee, int24 spacing) internal view returns (PoolKey memory k) {
        (Currency c0, Currency c1) = hookrIs0()
            ? (Currency.wrap(address(hookr)), Currency.wrap(address(quote)))
            : (Currency.wrap(address(quote)), Currency.wrap(address(hookr)));
        k = PoolKey(c0, c1, fee, spacing, IHooks(address(0)));
    }

    function logDefaults() internal pure returns (HookrPriceLog.Params memory p) {
        p.interval = 300;
        p.maxMoveTicks = 500;
        p.minLiquidity = 1e18;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev HOOKR's price in the quote as a tick (higher = pricier), whichever currency it is.
    function hookrTick() internal view returns (int24) {
        (, int24 t,,) = IPoolManager(address(manager)).getSlot0(poolId);
        return hookrIs0() ? t : -t;
    }

    /// @dev Moves the pool so HOOKR's price tick is `target`.
    function moveTo(int24 target) internal {
        int24 poolTarget = hookrIs0() ? target : -target;
        uint160 limit = TickMath.getSqrtPriceAtTick(poolTarget);
        (uint160 now_,,,) = IPoolManager(address(manager)).getSlot0(poolId);
        if (limit == now_) return;
        swapRouter.swap(key, SwapParams(limit < now_, -1e30, limit), PoolSwapTest.TestSettings(false, false), "");
    }

    function wait(uint256 secs) internal {
        vm.warp(vm.getBlockTimestamp() + secs);
    }

    /// @dev Records `n` times, one interval apart, at the current price.
    function steps(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            wait(300);
            plog.record(logId);
        }
    }

    function holdAt(int24 target, uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            wait(300);
            moveTo(target);
            plog.record(logId);
        }
    }

    /// @dev Seeds the log and records over a whole reference window and then some.
    function warmUp() internal {
        plog.record(logId);
        steps(8);
    }

    function fund(uint256 amount) internal {
        quote.mint(address(buyback), amount);
    }

    function burned() internal view returns (uint256) {
        return hookr.balanceOf(DEAD);
    }

    /// @dev The floor `buyback(amount)` would set now: off the better of the reference and spot means, less the
    ///      slippage allowance. Reads the log as the buyback does, after the record it would write (which weighs
    ///      nothing).
    function floorFor(uint256 amount) internal view returns (uint256) {
        (, int24 m) = plog.mean(logId, buyback.referenceWindow());
        (, int24 s) = plog.mean(logId, buyback.SPOT_WINDOW());
        uint256 a = expectedAt(amount, m);
        uint256 b = expectedAt(amount, s);
        uint256 e = a > b ? a : b;
        return e - e * buyback.maxSlippageBps() / 10_000;
    }

    /// @dev HOOKR that `amount` of quote buys at pool tick `t` (price = sqrtP^2 / 2^192 currency1 per currency0).
    function expectedAt(uint256 amount, int24 t) internal pure returns (uint256) {
        uint256 sp = TickMath.getSqrtPriceAtTick(t);
        uint256 ratioX128 = FullMath.mulDiv(sp, sp, 1 << 64);
        // Quote is currency1 when HOOKR is currency0: HOOKR out = amount / price.
        return hookrIs0() ? FullMath.mulDiv(1 << 128, amount, ratioX128) : FullMath.mulDiv(ratioX128, amount, 1 << 128);
    }
}
