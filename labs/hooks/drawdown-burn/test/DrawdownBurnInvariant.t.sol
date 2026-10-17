// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTestNoChecks} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTestNoChecks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {HookrDrawdownBurn} from "../src/HookrDrawdownBurn.sol";
import {DrawdownBurnBase} from "./DrawdownBurnBase.sol";

/// @dev Drives the pool and the engine in any order: swaps to any price, time passing, records, runs, donations, and
///      liquidity pulled and put back. Every check that needs the state just before and after a call lives here.
contract DrawdownBurnHandler is Test {
    using StateLibrary for IPoolManager;

    HookrDrawdownBurn internal immutable engine;
    IPoolManager internal immutable manager;
    PoolSwapTest internal immutable swapRouter;
    PoolModifyLiquidityTestNoChecks internal immutable liquidityRouter;
    MockERC20 internal immutable quoteToken;
    PoolKey internal key;
    PoolId internal immutable id;
    bool internal immutable subjectIs0;

    uint256 public immutable startTime;
    uint256 public clock;
    uint256 public spent;
    int256 public maxRecorded;
    int32 public lastAth;
    bool public athFell;
    bool public moveTooBig;
    int256 public pulled;

    constructor(
        HookrDrawdownBurn e,
        IPoolManager m,
        PoolSwapTest s,
        PoolModifyLiquidityTestNoChecks l,
        MockERC20 q,
        PoolKey memory k,
        bool s0
    ) {
        engine = e;
        manager = m;
        swapRouter = s;
        liquidityRouter = l;
        quoteToken = q;
        key = k;
        id = engine.poolId();
        subjectIs0 = s0;
        startTime = vm.getBlockTimestamp();
        clock = startTime;
        maxRecorded = engine.checkpointAt(0).tick;
    }

    function swapTo(int256 target) external {
        int24 t = int24(bound(target, -30_000, 30_000));
        int24 poolTarget = subjectIs0 ? t : -t;
        uint160 limit = TickMath.getSqrtPriceAtTick(poolTarget);
        (uint160 now_,,,) = manager.getSlot0(id);
        if (limit == now_) return;
        swapRouter.swap(key, SwapParams(limit < now_, -1e30, limit), PoolSwapTest.TestSettings(false, false), "");
    }

    function wait(uint256 secs) external {
        clock += bound(secs, 1, 1800);
        vm.warp(clock);
    }

    function checkpoint() external {
        int24 before = engine.checkpointAt(0).tick;
        if (engine.checkpoint()) {
            int24 rec = engine.checkpointAt(0).tick;
            int256 d = int256(rec) - int256(before);
            if ((d < 0 ? -d : d) > 500) moveTooBig = true;
            if (rec > maxRecorded) maxRecorded = rec;
        }
        _athCheck();
    }

    function run() external {
        int24 before = engine.checkpointAt(0).tick;
        uint8 n = engine.count();
        uint256 balBefore = quoteToken.balanceOf(address(engine));
        engine.run();
        uint256 balAfter = quoteToken.balanceOf(address(engine));
        if (balBefore > balAfter) spent += balBefore - balAfter;
        if (engine.count() != n || engine.checkpointAt(0).time == uint32(clock)) {
            int24 rec = engine.checkpointAt(0).tick;
            int256 d = int256(rec) - int256(before);
            if ((d < 0 ? -d : d) > 500) moveTooBig = true;
            if (rec > maxRecorded) maxRecorded = rec;
        }
        _athCheck();
    }

    function donate(uint256 amount) external {
        quoteToken.mint(address(engine), bound(amount, 1, 50e18));
    }

    function pullLiquidity(uint256 share) external {
        if (pulled != 0) return;
        int256 amount = int256(bound(share, 1, 9999)) * 1e24 / 10_000;
        liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(-887_220, 887_220, -amount, 0), "");
        pulled = amount;
    }

    function putBack() external {
        if (pulled == 0) return;
        liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(-887_220, 887_220, pulled, 0), "");
        pulled = 0;
    }

    function _athCheck() internal {
        if (engine.athSet()) {
            if (engine.ath() < lastAth) athFell = true;
            lastAth = engine.ath();
        }
    }
}

contract DrawdownBurnInvariantTest is DrawdownBurnBase {
    DrawdownBurnHandler internal handler;

    function subjectIs0() internal pure virtual override returns (bool) {
        return true;
    }

    function setUp() public override {
        super.setUp();
        PoolModifyLiquidityTestNoChecks lr = new PoolModifyLiquidityTestNoChecks(manager);
        handler = new DrawdownBurnHandler(
            engine, IPoolManager(address(manager)), swapRouter, lr, quoteToken, key, subjectIs0()
        );
        subjectToken.mint(address(handler), 1e30);
        quoteToken.mint(address(handler), 1e30);
        vm.startPrank(address(handler));
        subjectToken.approve(address(swapRouter), type(uint256).max);
        quoteToken.approve(address(swapRouter), type(uint256).max);
        subjectToken.approve(address(lr), type(uint256).max);
        quoteToken.approve(address(lr), type(uint256).max);
        // The handler owns half the pool's liquidity, so it can pull it.
        lr.modifyLiquidity(key, ModifyLiquidityParams(FULL_LO, FULL_HI, 1e24, 0), "");
        vm.stopPrank();
        targetContract(address(handler));
    }

    function defaults() internal view virtual override returns (HookrDrawdownBurn.Config memory c) {
        c = super.defaults();
        c.hasInitialAth = true;
        c.initialAth = 1000;
        c.athRiseCapBpsPerHour = 2000;
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    function invariant_athNeverFalls() public view {
        assertFalse(handler.athFell());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    function invariant_recordsMoveAtMostMaxMove() public view {
        assertFalse(handler.moveTooBig());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    function invariant_athNeverAboveWhatWasRecorded() public view {
        // The high starts at 1000 and only rises to a level every record of a full window held.
        int256 ceiling = handler.maxRecorded() > 1000 ? handler.maxRecorded() : int256(1000);
        assertLe(int256(engine.ath()), ceiling);
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    function invariant_budgetsBacked() public view {
        assertGe(quoteToken.balanceOf(address(engine)), engine.burnBudget() + engine.wallReserve() + engine.totalOwed());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    function invariant_neverHoldsTheSubject() public view {
        assertEq(subjectToken.balanceOf(address(engine)), 0);
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    function invariant_spendWithinTheCap() public view {
        uint256 elapsed = handler.clock() - handler.startTime();
        assertLe(handler.spent(), 10e18 + 10e18 * elapsed / 12);
    }
}

contract DrawdownBurnInvariantFlippedTest is DrawdownBurnInvariantTest {
    function subjectIs0() internal pure override returns (bool) {
        return false;
    }
}
