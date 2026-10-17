// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {HookrPriceLog} from "../src/HookrPriceLog.sol";
import {InUnlockRecorder, PriceLogBase} from "./PriceLogBase.sol";

contract HookrPriceLogTest is PriceLogBase {
    using PoolIdLibrary for PoolKey;

    function sign() internal pure virtual override returns (int24) {
        return 1;
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Opening
    // -----------------------------------------------------------------------------------------------------------------

    function test_open_isIdempotentAndKeyedByParams() public {
        HookrPriceLog.Params memory p = defaults();
        assertEq(plog.open(poolId, p), id, "same pool, same params: same log");
        p.maxMoveTicks = 400;
        bytes32 other = plog.open(poolId, p);
        assertTrue(other != id, "other params: another log");
        assertEq(plog.logId(poolId, p), other);
        assertEq(PoolId.unwrap(plog.poolOf(other)), PoolId.unwrap(poolId));
        assertEq(plog.params(other).maxMoveTicks, 400);
        // A second open never resets a log that has records.
        plog.record(id);
        plog.open(poolId, defaults());
        assertEq(plog.count(id), 1);
    }

    function test_open_bounds() public {
        HookrPriceLog.Params memory p = defaults();
        p.interval = 59;
        _expectInvalid(p, "interval");
        p.interval = 3601;
        _expectInvalid(p, "interval");
        p = defaults();
        p.maxMoveTicks = 9;
        _expectInvalid(p, "maxMoveTicks");
        p.maxMoveTicks = 5001;
        _expectInvalid(p, "maxMoveTicks");
        p = defaults();
        p.minLiquidity = 0;
        _expectInvalid(p, "minLiquidity");
        p = defaults();
        p.seedTick = 5;
        _expectInvalid(p, "seedTick"); // a seed tick without hasSeedTick would be a second id for the same log
        p.hasSeedTick = true;
        p.seedTick = TickMath.MAX_TICK;
        _expectInvalid(p, "seedTick");
        p.seedTick = TickMath.MIN_TICK;
        _expectInvalid(p, "seedTick");
        // The bounds themselves are accepted.
        p = HookrPriceLog.Params(60, 10, 1, true, TickMath.MAX_TICK - 1);
        plog.open(poolId, p);
        p = HookrPriceLog.Params(3600, 5000, type(uint128).max, false, 0);
        plog.open(poolId, p);
    }

    function _expectInvalid(HookrPriceLog.Params memory p, bytes32 what) internal {
        vm.expectRevert(abi.encodeWithSelector(HookrPriceLog.InvalidParams.selector, what));
        plog.open(poolId, p);
    }

    function test_unknownLogReverts() public {
        bytes32 nope = keccak256("nope");
        assertFalse(plog.isOpen(nope));
        vm.expectRevert(abi.encodeWithSelector(HookrPriceLog.UnknownLog.selector, nope));
        plog.record(nope);
        vm.expectRevert(abi.encodeWithSelector(HookrPriceLog.UnknownLog.selector, nope));
        plog.mean(nope, 900);
    }

    function test_constructorRefusesAManagerWithoutCode() public {
        vm.expectRevert(abi.encodeWithSelector(HookrPriceLog.InvalidParams.selector, bytes32("manager")));
        new HookrPriceLog(IPoolManager(address(0xBEEF)));
    }

    // -----------------------------------------------------------------------------------------------------------------
    // The first record
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev A log opened before its pool exists: no record until the pool is initialized and deep enough.
    function test_seed_waitsForThePoolAndForLiquidity() public {
        PoolKey memory k = key;
        k.fee = 500;
        k.tickSpacing = 10;
        PoolId pid = k.toId();
        HookrPriceLog.Params memory p = defaults();
        p.hasSeedTick = true;
        p.seedTick = 1000 * sign();
        bytes32 early = plog.open(pid, p);
        vm.expectRevert(HookrPriceLog.PoolNotInitialized.selector);
        plog.record(early);
        (bool ok,) = plog.mean(early, 900);
        assertFalse(ok);

        // Opened far from the seed: the first record is clamped to the seed within one step.
        manager.initialize(k, TickMath.getSqrtPriceAtTick(4000 * sign()));
        vm.expectRevert(HookrPriceLog.ThinStart.selector);
        plog.record(early);
        liquidityRouter.modifyLiquidity(k, ModifyLiquidityParams(-887_270, 887_270, 1e20, 0), "");
        assertTrue(plog.record(early));
        assertEq(plog.latest(early).tick, 1500 * sign(), "seed + maxMove");
        assertFalse(plog.latest(early).thin);
    }

    function test_seed_withoutSeedTickIsTheSpot() public {
        moveTo(1234);
        assertTrue(plog.record(id));
        assertEq(newest().tick, spot());
        assertEq(newest().time, uint32(vm.getBlockTimestamp()));
        assertEq(plog.count(id), 1);
    }

    function test_seed_refusedInsideAnUnlock() public {
        InUnlockRecorder r = new InUnlockRecorder(IPoolManager(address(manager)), plog);
        vm.expectRevert(HookrPriceLog.ManagerUnlocked.selector);
        r.recordInside(id);
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Records
    // -----------------------------------------------------------------------------------------------------------------

    function test_record_atMostOncePerInterval() public {
        plog.record(id);
        wait(299);
        assertFalse(plog.record(id));
        wait(1);
        assertTrue(plog.record(id));
        assertFalse(plog.record(id), "same second");
        assertEq(plog.count(id), 2);
    }

    function test_record_clampedToMaxMove() public {
        plog.record(id);
        moveTo(3000);
        step();
        assertEq(newest().tick, 500 * sign());
        step();
        assertEq(newest().tick, 1000 * sign());
        moveTo(-3000);
        step();
        assertEq(newest().tick, 500 * sign());
        moveTo(700);
        step();
        assertEq(newest().tick, spot(), "inside the clamp the spot is recorded");
    }

    function test_record_refusedInsideAnUnlockWhenDue() public {
        plog.record(id);
        InUnlockRecorder r = new InUnlockRecorder(IPoolManager(address(manager)), plog);
        // Not due: nothing to refuse, nothing written.
        assertFalse(r.recordInside(id));
        wait(300);
        vm.expectRevert(HookrPriceLog.ManagerUnlocked.selector);
        r.recordInside(id);
    }

    function test_record_thinFlag() public {
        plog.record(id);
        liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(FULL_LO, FULL_HI, -(LIQ - 1e17), 0), "");
        step();
        assertTrue(newest().thin);
        assertEq(newest().liquidity, 1e17);
        liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(FULL_LO, FULL_HI, LIQ, 0), "");
        step();
        assertFalse(newest().thin);
    }

    function test_record_ringWrapsAt64() public {
        plog.record(id);
        int24[70] memory spots;
        for (uint256 i = 1; i < 70; ++i) {
            moveTo(int24(int256(i)) * 10);
            step();
            spots[i] = spot();
        }
        assertEq(plog.count(id), 64);
        assertEq(newest().tick, spot());
        assertEq(plog.recordAt(id, 63).tick, spots[6], "the oldest kept");
        vm.expectRevert(abi.encodeWithSelector(HookrPriceLog.OutOfRange.selector, 64));
        plog.recordAt(id, 64);
        HookrPriceLog.Record[] memory r = plog.recent(id, 100);
        assertEq(r.length, 64);
        assertEq(r[0].time, newest().time);
        assertEq(r[63].time, plog.recordAt(id, 63).time);
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Means
    // -----------------------------------------------------------------------------------------------------------------

    function test_mean_newestRecordWeighsNothingWhenWritten() public {
        plog.record(id);
        steps(6);
        moveTo(400);
        step();
        (bool ok, int24 m) = plog.mean(id, 900);
        assertTrue(ok);
        assertEq(m, 0, "the record just written is not in the mean");
        wait(150);
        (, m) = plog.mean(id, 900);
        assertEq(m, int24(int256(spot()) * 150 / 900));
    }

    function test_mean_timeWeighted() public {
        plog.record(id); // t0: 0
        holdAt(300, 1); // t0+300: 300
        int24 a = newest().tick;
        holdAt(-100, 1); // t0+600: -100
        int24 b = newest().tick;
        wait(100); // now t0+700
        // Over [t0+100, t0+700]: 0 for 200 s, then `a` for 300 s, then `b` for 100 s.
        (bool ok, int24 m) = plog.mean(id, 600);
        assertTrue(ok);
        assertEq(int256(m), (int256(a) * 300 + int256(b) * 100) / 600);
        assertApproxEqAbs(int256(m), int256(133) * sign(), 1);
        (, int24 model) = modelMean(600, vm.getBlockTimestamp());
        assertEq(m, model);
    }

    function test_mean_failsClosed() public {
        (bool ok,) = plog.mean(id, 900);
        assertFalse(ok, "no records");
        plog.record(id);
        (ok,) = plog.mean(id, 900);
        assertFalse(ok, "not reaching back");
        steps(3);
        (ok,) = plog.mean(id, 900);
        assertTrue(ok, "exactly reaching back");
        (ok,) = plog.mean(id, 0);
        assertFalse(ok, "zero window");
        assertFalse(plog.servable(id, 300 * 48 + 1));
        assertTrue(plog.servable(id, 300 * 48));
        steps(48);
        (ok,) = plog.mean(id, 300 * 48 + 1);
        assertFalse(ok, "past the servable span");
    }

    function test_mean_thinFailsOnlyWhileItWeighs() public {
        plog.record(id);
        steps(3);
        liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(FULL_LO, FULL_HI, -(LIQ - 1e17), 0), "");
        step(); // thin
        liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(FULL_LO, FULL_HI, LIQ, 0), "");
        (bool ok,) = plog.mean(id, 600);
        assertTrue(ok, "the thin record was just written: no weight yet");
        wait(1);
        (ok,) = plog.mean(id, 600);
        assertFalse(ok, "now it weighs");
        step();
        steps(3);
        (ok,) = plog.mean(id, 900);
        assertTrue(ok, "past the window again");
    }

    function test_meanFresh_refusesARecordThatStoodTooLong() public {
        plog.record(id);
        steps(6);
        (bool ok,) = plog.meanFresh(id, 1800, 600);
        assertTrue(ok, "recorded every interval");
        wait(601);
        (ok,) = plog.meanFresh(id, 1800, 600);
        assertFalse(ok, "the newest record has stood 601 s");
        (bool plain,) = plog.mean(id, 1800);
        assertTrue(plain, "mean has no stand limit");
        // A record written now ends the old one's stand at 601 s; it is still too long while it weighs.
        plog.record(id);
        (ok,) = plog.meanFresh(id, 1800, 600);
        assertFalse(ok);
        // Once the long-standing record leaves the window, fresh again.
        steps(6);
        (ok,) = plog.meanFresh(id, 1800, 600);
        assertTrue(ok);
        (bool okFresh, int24 a) = plog.meanFresh(id, 1800, 600);
        (, int24 b) = plog.mean(id, 1800);
        assertTrue(okFresh);
        assertEq(a, b, "same mean when fresh");
    }

    function test_meanUntil_endsInThePast() public {
        plog.record(id);
        steps(3);
        uint32 end = uint32(vm.getBlockTimestamp());
        (bool okThen, int24 then) = plog.mean(id, 900);
        holdAt(2000, 4);
        (bool ok, int24 m) = plog.meanUntil(id, 900, end);
        assertTrue(ok && okThen);
        assertEq(m, then, "records written after the end weigh nothing");
        (ok,) = plog.meanUntil(id, 900, uint32(vm.getBlockTimestamp() + 1));
        assertFalse(ok, "the future");
        (ok,) = plog.meanUntil(id, 900, 899);
        assertFalse(ok, "before time 0");
        // Mid-record ends.
        (ok, m) = plog.meanUntil(id, 450, end + 450);
        (, int24 model) = modelMean(450, end + 450);
        assertEq(m, model);
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Fuzz
    // -----------------------------------------------------------------------------------------------------------------

    /// @notice Any path of prices and waits: every record moves at most maxMove from the last, records are at least an
    ///         interval apart, and every mean equals the model's walk of the step function.
    function testFuzz_recordsAndMeansMatchTheModel(int24[12] memory targets, uint16[12] memory waits, uint32 window)
        public
    {
        plog.record(id);
        for (uint256 i; i < 12; ++i) {
            wait(bound(waits[i], 1, 1200));
            moveTo(int24(bound(targets[i], -20_000, 20_000)));
            plog.record(id);
        }
        uint256 c = plog.count(id);
        for (uint256 i = 1; i < c; ++i) {
            HookrPriceLog.Record memory a = plog.recordAt(id, i);
            HookrPriceLog.Record memory b = plog.recordAt(id, i - 1);
            assertLe(_abs(int256(b.tick) - a.tick), 500);
            assertGe(b.time, a.time + 300);
        }
        window = uint32(bound(window, 1, 300 * 48));
        (bool ok, int24 m) = plog.mean(id, window);
        (bool mok, int24 mm) = modelMean(window, vm.getBlockTimestamp());
        assertEq(ok, mok);
        if (ok) assertEq(m, mm);
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return uint256(x < 0 ? -x : x);
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Gas
    // -----------------------------------------------------------------------------------------------------------------

    /// @notice Gas of a record and of reads, cold (storage slots not yet touched in the transaction) and warm.
    function test_gas_readsColdAndWarm() public {
        plog.record(id);
        steps(20);
        wait(300);
        moveTo(100);
        vm.cool(address(plog));
        uint256 g = gasleft();
        plog.record(id);
        console2.log("gas: record (cold slots)", g - gasleft());

        wait(100);
        uint32[3] memory windows = [uint32(900), 1800, 3600];
        for (uint256 i; i < 3; ++i) {
            vm.cool(address(plog));
            g = gasleft();
            plog.mean(id, windows[i]);
            uint256 cold = g - gasleft();
            g = gasleft();
            plog.mean(id, windows[i]);
            uint256 warm = g - gasleft();
            console2.log("gas: mean window / cold / warm", windows[i], cold, warm);
            assertLt(warm, cold);
        }
        vm.cool(address(plog));
        g = gasleft();
        plog.recent(id, 13);
        console2.log("gas: recent(13) cold", g - gasleft());
    }
}

contract HookrPriceLogFallingTest is HookrPriceLogTest {
    function sign() internal pure override returns (int24) {
        return -1;
    }
}
