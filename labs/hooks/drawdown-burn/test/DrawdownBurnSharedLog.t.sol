// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {HookrDrawdownBurn} from "../src/HookrDrawdownBurn.sol";
import {HookrPriceLog} from "../../price-log/src/HookrPriceLog.sol";
import {DrawdownBurnBase} from "./DrawdownBurnBase.sol";

/// @notice What reading the shared price log changes for the engine: the log is the pool's, not the engine's.
contract DrawdownBurnSharedLogTest is DrawdownBurnBase {
    function subjectIs0() internal pure virtual override returns (bool) {
        return true;
    }

    function test_twoEnginesWithTheSameParamsShareOneLog() public {
        steps(6);
        HookrDrawdownBurn second = new HookrDrawdownBurn(defaults());
        assertEq(second.logId(), engine.logId());
        assertEq(second.count(), engine.count(), "no warm-up: the second engine reads the history already there");
        (bool ok,) = second.meanTick(900);
        assertTrue(ok);
        // A record either engine writes is the other's too.
        step();
        assertEq(second.checkpointAt(0).time, engine.checkpointAt(0).time);
        // Other parameters: another log.
        HookrDrawdownBurn.Config memory c = defaults();
        c.maxMoveTicks = 400;
        HookrDrawdownBurn third = new HookrDrawdownBurn(c);
        assertTrue(third.logId() != engine.logId());
        assertEq(third.count(), 1);
    }

    function test_engineReadsTheLogsPoolTicksInTheSubjectsOrientation() public {
        moveTo(400);
        step();
        int24 poolTick = priceLog.latest(engine.logId()).tick;
        assertEq(engine.checkpointAt(0).tick, subjectIs0() ? poolTick : -poolTick);
        assertEq(engine.checkpointAt(0).tick, spot());
    }

    function test_recordsWrittenStraightToTheLogRaiseTheHigh() public {
        // Records written by anyone, not through the engine.
        bytes32 id = engine.logId();
        for (uint256 i; i < 13; ++i) {
            vm.warp(vm.getBlockTimestamp() + 300);
            priceLog.record(id);
        }
        assertFalse(engine.athSet(), "the engine has not looked yet");
        engine.checkpoint(); // not due: writes nothing, measures the high against the newest record
        assertTrue(engine.athSet());
        assertApproxEqAbs(int256(engine.ath()), 0, 1);
    }

    /// @notice Review finding: with an athWindow that is not a multiple of the interval, the high must still rise.
    function test_highRisesWhenTheWindowIsNotAMultipleOfTheInterval() public {
        HookrDrawdownBurn.Config memory c = defaults();
        c.log = new HookrPriceLog(IPoolManager(address(manager)));
        c.athWindow = 500;
        c.athMinCheckpoints = 2;
        HookrDrawdownBurn e = new HookrDrawdownBurn(c);
        for (uint256 i; i < 3; ++i) {
            vm.warp(vm.getBlockTimestamp() + 300);
            e.checkpoint();
        }
        assertTrue(e.athSet(), "records 300 s apart span 500 s after three");
    }

    function test_engineSeedsItsLogsFirstRecordInTheSubjectsOrientation() public {
        HookrDrawdownBurn.Config memory c = defaults();
        c.log = new HookrPriceLog(IPoolManager(address(manager)));
        c.hasSeedTick = true;
        c.seedTick = 2000; // the subject's price tick
        HookrDrawdownBurn e = new HookrDrawdownBurn(c);
        HookrPriceLog.Params memory p = c.log.params(e.logId());
        assertEq(p.seedTick, subjectIs0() ? int24(2000) : int24(-2000), "the log keeps the pool's tick");
        // Spot is 0: the first record is clamped to the seed, 500 under it.
        assertEq(e.checkpointAt(0).tick, 1500);
    }

    /// @notice The epoch closes on the mean ending at its boundary: a call made hours late reads the same close.
    function test_epochClosesAtItsBoundaryEvenWhenCalledLate() public {
        HookrDrawdownBurn.Config memory c = epochDefaults();
        c.hasInitialAth = true;
        c.initialAth = 5000;
        HookrPriceLog own = new HookrPriceLog(IPoolManager(address(manager)));
        c.log = own;
        engine = new HookrDrawdownBurn(c);
        bytes32 id = engine.logId();
        uint256 b1 = (vm.getBlockTimestamp() / 4 hours + 1) * 4 hours;
        // The price rises through the epoch and is recorded by others.
        while (vm.getBlockTimestamp() + 300 < b1) {
            vm.warp(vm.getBlockTimestamp() + 300);
            moveTo(1000);
            own.record(id);
        }
        // After the boundary the price falls back and is recorded for two hours before the engine is called.
        moveTo(0);
        for (uint256 i; i < 24; ++i) {
            vm.warp(vm.getBlockTimestamp() + 300);
            own.record(id);
        }
        engine.checkpoint();
        assertEq(uint8(engine.mode()), uint8(HookrDrawdownBurn.Mode.ACCUMULATE), "closed on the rise before b1");
        (, int24 close) = own.meanUntil(id, 3600, uint32(b1));
        assertEq(engine.epochOpen(), subjectIs0() ? close : -close, "the next epoch opens at that close");
        (, int24 now_) = engine.meanTick(3600);
        assertLt(now_, 100, "the mean at the call is back near 0, which a prompt-at-call close would have read");
    }
}

contract DrawdownBurnSharedLogFlippedTest is DrawdownBurnSharedLogTest {
    function subjectIs0() internal pure override returns (bool) {
        return false;
    }
}
