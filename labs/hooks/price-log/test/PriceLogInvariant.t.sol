// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {HookrPriceLog} from "../src/HookrPriceLog.sol";
import {InUnlockRecorder, PriceLogBase} from "./PriceLogBase.sol";

/// @dev Drives the pool and the log: swaps anywhere, waits, records, records from inside an unlock, pulls and puts
///      back liquidity.
contract PriceLogHandler is Test {
    using StateLibrary for IPoolManager;

    IPoolManager internal immutable manager;
    PoolSwapTest internal immutable swapRouter;
    PoolModifyLiquidityTest internal immutable liquidityRouter;
    HookrPriceLog internal immutable plog;
    InUnlockRecorder internal immutable inside;
    PoolKey internal key;
    PoolId internal poolId;
    bytes32 internal immutable id;
    int24 internal immutable sgn;
    bool internal pulled;

    /// @notice Records written by a call made inside an unlock. Must stay zero.
    uint256 public insideWrites;

    constructor(
        IPoolManager m,
        PoolSwapTest s,
        PoolModifyLiquidityTest l,
        HookrPriceLog p,
        PoolKey memory k,
        PoolId pid,
        bytes32 id_,
        int24 sgn_
    ) {
        manager = m;
        swapRouter = s;
        liquidityRouter = l;
        plog = p;
        inside = new InUnlockRecorder(m, p);
        key = k;
        poolId = pid;
        id = id_;
        sgn = sgn_;
        MockERC20(_c(k.currency0)).approve(address(s), type(uint256).max);
        MockERC20(_c(k.currency1)).approve(address(s), type(uint256).max);
        MockERC20(_c(k.currency0)).approve(address(l), type(uint256).max);
        MockERC20(_c(k.currency1)).approve(address(l), type(uint256).max);
    }

    function _c(Currency c) internal pure returns (address) {
        return Currency.unwrap(c);
    }

    function swapTo(int24 target) external {
        target = int24(bound(target, -30_000, 30_000)) * sgn;
        uint160 limit = TickMath.getSqrtPriceAtTick(target);
        (uint160 now_,,,) = manager.getSlot0(poolId);
        if (limit == now_) return;
        swapRouter.swap(key, SwapParams(limit < now_, -1e30, limit), PoolSwapTest.TestSettings(false, false), "");
    }

    function wait(uint16 secs) external {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 1, 2000));
    }

    function record() external {
        plog.record(id);
    }

    function recordInside() external {
        uint256 before = plog.count(id);
        uint32 newestBefore = plog.latest(id).time;
        try inside.recordInside(id) returns (bool wrote) {
            if (wrote) insideWrites++;
        } catch {}
        if (plog.count(id) != before || plog.latest(id).time != newestBefore) insideWrites++;
    }

    function pullLiquidity() external {
        if (pulled) return;
        liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(-887_220, 887_220, -(1e24 - 1e17), 0), "");
        pulled = true;
    }

    function putBack() external {
        if (!pulled) return;
        liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(-887_220, 887_220, 1e24 - 1e17, 0), "");
        pulled = false;
    }
}

contract PriceLogInvariantTest is PriceLogBase {
    PriceLogHandler internal handler;

    function sign() internal pure virtual override returns (int24) {
        return 1;
    }

    function setUp() public override {
        super.setUp();
        plog.record(id);
        handler = new PriceLogHandler(
            IPoolManager(address(manager)), swapRouter, liquidityRouter, plog, key, poolId, id, sign()
        );
        MockERC20(Currency.unwrap(key.currency0)).mint(address(handler), 1e30);
        MockERC20(Currency.unwrap(key.currency1)).mint(address(handler), 1e30);
        targetContract(address(handler));
    }

    function invariant_recordsMoveAtMostMaxMoveAndAnIntervalApart() public view {
        uint256 c = plog.count(id);
        assertLe(c, 64);
        for (uint256 i = 1; i < c; ++i) {
            HookrPriceLog.Record memory older = plog.recordAt(id, i);
            HookrPriceLog.Record memory newer = plog.recordAt(id, i - 1);
            int256 d = int256(newer.tick) - older.tick;
            assertLe(d < 0 ? -d : d, 500);
            assertGe(newer.time, older.time + 300);
            assertEq(newer.thin, newer.liquidity < 1e18);
        }
    }

    function invariant_neverRecordsInsideAnUnlock() public view {
        assertEq(handler.insideWrites(), 0);
    }

    function invariant_meansMatchTheModelAndStayInsideTheirRecords() public view {
        uint32[4] memory windows = [uint32(300), 900, 1800, 14_400];
        uint256 end = block.timestamp;
        for (uint256 w; w < 4; ++w) {
            (bool ok, int24 m) = plog.mean(id, windows[w]);
            (bool mok, int24 mm) = modelMean(windows[w], end);
            assertEq(ok, mok);
            if (!ok) continue;
            assertEq(m, mm);
            // Inside the range of the records that weigh in the window.
            (int24 lo, int24 hi) = _range(windows[w], end);
            assertGe(m, lo);
            assertLe(m, hi);
        }
    }

    function _range(uint32 window, uint256 end) internal view returns (int24 lo, int24 hi) {
        lo = type(int24).max;
        hi = type(int24).min;
        uint256 from = end - window;
        for (uint256 i; i < plog.count(id); ++i) {
            HookrPriceLog.Record memory r = plog.recordAt(id, i);
            if (r.time < end) {
                if (r.tick < lo) lo = r.tick;
                if (r.tick > hi) hi = r.tick;
            }
            if (r.time <= from) break;
        }
    }
}

contract PriceLogInvariantFallingTest is PriceLogInvariantTest {
    function sign() internal pure override returns (int24) {
        return -1;
    }
}
