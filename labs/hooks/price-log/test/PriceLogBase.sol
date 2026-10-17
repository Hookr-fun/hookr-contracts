// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {HookrPriceLog} from "../src/HookrPriceLog.sol";

/// @dev Calls `record` from inside an unlock, after an optional free pump: what the log must refuse.
contract InUnlockRecorder is IUnlockCallback {
    IPoolManager internal immutable manager;
    HookrPriceLog internal immutable log;

    constructor(IPoolManager m, HookrPriceLog l) {
        manager = m;
        log = l;
    }

    function recordInside(bytes32 id) external returns (bool) {
        return abi.decode(manager.unlock(abi.encode(id)), (bool));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        return abi.encode(log.record(abi.decode(data, (bytes32))));
    }
}

/// @dev A plain v4 pool (no hook, 0.30% LP fee, full-range liquidity at price 1) and a log on it with the defaults.
///      `sign()` mirrors every price the suites move to, so each suite runs on rising and on falling pool ticks: the
///      log keeps pool ticks, and a reader whose subject is currency1 reads them negated.
abstract contract PriceLogBase is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    int24 internal constant SPACING = 60;
    int24 internal constant FULL_LO = -887_220;
    int24 internal constant FULL_HI = 887_220;
    int256 internal constant LIQ = 1e24;
    uint256 internal constant T0 = 1_000_000;

    PoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liquidityRouter;
    HookrPriceLog internal plog;
    PoolKey internal key;
    PoolId internal poolId;
    bytes32 internal id;

    function sign() internal pure virtual returns (int24);

    function setUp() public virtual {
        vm.warp(T0);
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        plog = new HookrPriceLog(IPoolManager(address(manager)));

        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);
        key = PoolKey(Currency.wrap(address(t0)), Currency.wrap(address(t1)), 3000, SPACING, IHooks(address(0)));
        poolId = key.toId();
        t0.mint(address(this), 1e30);
        t1.mint(address(this), 1e30);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);
        t0.approve(address(liquidityRouter), type(uint256).max);
        t1.approve(address(liquidityRouter), type(uint256).max);

        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(FULL_LO, FULL_HI, LIQ, 0), "");
        id = plog.open(poolId, defaults());
    }

    function defaults() internal pure returns (HookrPriceLog.Params memory p) {
        p.interval = 300;
        p.maxMoveTicks = 500;
        p.minLiquidity = 1e18;
    }

    /// @dev The pool's tick.
    function spot() internal view returns (int24 t) {
        (, t,,) = IPoolManager(address(manager)).getSlot0(poolId);
    }

    /// @dev Moves the pool to `sign() * target` with one swap stopped by its price limit.
    function moveTo(int24 target) internal {
        uint160 limit = TickMath.getSqrtPriceAtTick(target * sign());
        (uint160 now_,,,) = IPoolManager(address(manager)).getSlot0(poolId);
        if (limit == now_) return;
        swapRouter.swap(key, SwapParams(limit < now_, -1e30, limit), PoolSwapTest.TestSettings(false, false), "");
    }

    function wait(uint256 secs) internal {
        vm.warp(vm.getBlockTimestamp() + secs);
    }

    /// @dev Waits one interval and records.
    function step() internal returns (bool) {
        wait(300);
        return plog.record(id);
    }

    function steps(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            step();
        }
    }

    function holdAt(int24 target, uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            wait(300);
            moveTo(target);
            plog.record(id);
        }
    }

    function newest() internal view returns (HookrPriceLog.Record memory) {
        return plog.latest(id);
    }

    /// @dev The mean recomputed from the records by brute force, one second at a time is too slow; walks the step
    ///      function the same way any reader would, independently of the contract's loop.
    function modelMean(uint32 window, uint256 end) internal view returns (bool ok, int24 tick) {
        uint256 c = plog.count(id);
        if (c == 0 || window == 0 || end < window) return (false, 0);
        uint256 from = end - window;
        int256 acc;
        // Record i stands from its time until the next newer record's time (or forever for the newest).
        bool reached;
        for (uint256 i; i < c; ++i) {
            HookrPriceLog.Record memory r = plog.recordAt(id, i);
            uint256 standsUntil = i == 0 ? type(uint256).max : plog.recordAt(id, i - 1).time;
            uint256 lo = r.time > from ? r.time : from;
            uint256 hi = standsUntil < end ? standsUntil : end;
            if (hi > lo) {
                if (r.thin) return (false, 0);
                acc += int256(r.tick) * int256(hi - lo);
            }
            if (r.time <= from) {
                reached = true;
                break;
            }
        }
        if (!reached) return (false, 0);
        return (true, int24(acc / int256(uint256(window))));
    }
}
