// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {HookrDrawdownBurn} from "../src/HookrDrawdownBurn.sol";
import {HookrPriceLog} from "../../price-log/src/HookrPriceLog.sol";

/// @dev A plain v4 pool (no hook, 0.30% LP fee, full-range liquidity at price 1) and an engine on it with Ika's numbers
///      as defaults. `subjectIs0()` picks which currency is the subject, so every suite runs in both orientations.
abstract contract DrawdownBurnBase is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    int24 internal constant SPACING = 60;
    int24 internal constant FULL_LO = -887_220;
    int24 internal constant FULL_HI = 887_220;
    int256 internal constant LIQ = 1e24;
    uint256 internal constant T0 = 1_000_000;

    PoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liquidityRouter;
    MockERC20 internal subjectToken;
    MockERC20 internal quoteToken;
    PoolKey internal key;
    PoolId internal id;
    HookrDrawdownBurn internal engine;
    HookrPriceLog internal priceLog;

    function subjectIs0() internal pure virtual returns (bool);

    function setUp() public virtual {
        vm.warp(T0);
        manager = new PoolManager(address(this));
        priceLog = new HookrPriceLog(IPoolManager(address(manager)));
        swapRouter = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);

        MockERC20 a = new MockERC20("Subject", "SUBJ", 18);
        MockERC20 b = new MockERC20("Quote", "QUOTE", 18);
        bool aIs0 = address(a) < address(b);
        // Pick the subject so that it sorts as subjectIs0() asks.
        if (aIs0 == subjectIs0()) (subjectToken, quoteToken) = (a, b);
        else (subjectToken, quoteToken) = (b, a);
        (Currency c0, Currency c1) = subjectIs0()
            ? (Currency.wrap(address(subjectToken)), Currency.wrap(address(quoteToken)))
            : (Currency.wrap(address(quoteToken)), Currency.wrap(address(subjectToken)));
        key = PoolKey(c0, c1, 3000, SPACING, IHooks(address(0)));
        id = key.toId();

        subjectToken.mint(address(this), 1e30);
        quoteToken.mint(address(this), 1e30);
        subjectToken.approve(address(swapRouter), type(uint256).max);
        quoteToken.approve(address(swapRouter), type(uint256).max);
        subjectToken.approve(address(liquidityRouter), type(uint256).max);
        quoteToken.approve(address(liquidityRouter), type(uint256).max);

        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(FULL_LO, FULL_HI, LIQ, 0), "");

        engine = new HookrDrawdownBurn(defaults());
    }

    /// @notice Ika's numbers (X post 2026-10-16, TG rhub x WTH) with the oracle-less checkpoint knobs at their defaults.
    function defaults() internal view virtual returns (HookrDrawdownBurn.Config memory c) {
        c.manager = IPoolManager(address(manager));
        c.log = priceLog;
        c.key = key;
        c.subjectIsCurrency0 = subjectIs0();
        c.checkpointInterval = 300;
        c.maxMoveTicks = 500;
        c.minLiquidity = 1e18;
        c.athWindow = 3600;
        c.athMinCheckpoints = 6;
        c.athRiseCapBpsPerHour = 0;
        c.measure = HookrDrawdownBurn.Reference.PRICE;
        c.tierEdgesBps = [uint16(2000), 4000, 6000];
        c.tierBurnBps = [uint16(0), 2500, 5000, 7500, 10_000];
        c.refWindow = 900;
        c.spendCap = 10e18;
        c.refillSeconds = 12;
        c.maxSlippageBps = 300;
        c.wall = HookrDrawdownBurn.Wall.RESERVE;
        c.wallOffsetBps = 6000;
        c.epochSwitch = false;
        c.epochLength = 1 days;
        c.deadBandBps = 100;
    }

    function epochDefaults() internal view returns (HookrDrawdownBurn.Config memory c) {
        c = defaults();
        c.epochSwitch = true;
        c.epochLength = 4 hours;
        c.epochWindow = 3600;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Pool helpers
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev The subject's price as a tick (higher = pricier), whichever currency it is.
    function spot() internal view returns (int24) {
        (, int24 t,,) = IPoolManager(address(manager)).getSlot0(id);
        return subjectIs0() ? t : -t;
    }

    /// @dev Moves the pool so the subject's price tick is `target` (a big exact-input swap stopped by its price limit).
    function moveTo(int24 target) internal {
        moveToFrom(target, address(this));
    }

    function moveToFrom(int24 target, address who) internal {
        int24 poolTarget = subjectIs0() ? target : -target;
        uint160 limit = TickMath.getSqrtPriceAtTick(poolTarget);
        (uint160 now_,,,) = IPoolManager(address(manager)).getSlot0(id);
        if (limit == now_) return;
        bool zeroForOne = limit < now_;
        vm.prank(who);
        swapRouter.swap(key, SwapParams(zeroForOne, -1e30, limit), PoolSwapTest.TestSettings(false, false), "");
    }

    /// @dev Warps one interval and records. Returns whether a record was written.
    function step() internal returns (bool) {
        vm.warp(vm.getBlockTimestamp() + 300);
        return engine.checkpoint();
    }

    /// @dev Records `n` times, one interval apart, at the current price.
    function steps(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            step();
        }
    }

    /// @dev Holds the price at `target` for `n` intervals, recording each.
    function holdAt(int24 target, uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            vm.warp(vm.getBlockTimestamp() + 300);
            moveTo(target);
            engine.checkpoint();
        }
    }

    function fund(uint256 amount) internal {
        quoteToken.mint(address(engine), amount);
    }

    function deadBalance() internal view returns (uint256) {
        return subjectToken.balanceOf(DEAD);
    }

    function quoteBal(address who) internal view returns (uint256) {
        return quoteToken.balanceOf(who);
    }
}
