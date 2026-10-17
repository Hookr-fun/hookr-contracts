// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {HookrPriceLog} from "../src/HookrPriceLog.sol";
import {PriceLogBase} from "./PriceLogBase.sol";

/// @dev A flash pumper: moves the pool inside its own unlock, tries to record there, and settles.
contract FlashPumper is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager internal immutable manager;
    HookrPriceLog internal immutable log;
    PoolKey internal key;

    constructor(IPoolManager m, HookrPriceLog l, PoolKey memory k) {
        manager = m;
        log = l;
        key = k;
    }

    function pumpAndRecord(bytes32 id, int24 target) external {
        manager.unlock(abi.encode(id, target));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (bytes32 id, int24 target) = abi.decode(data, (bytes32, int24));
        uint160 limit = TickMath.getSqrtPriceAtTick(target);
        (uint160 now_,,,) = manager.getSlot0(key.toId());
        manager.swap(key, SwapParams(limit < now_, -1e30, limit), "");
        log.record(id); // reverts: the pump is free until the unlock settles, so it never reaches settlement
        return "";
    }
}

contract PriceLogAttackTest is PriceLogBase {
    function sign() internal pure virtual override returns (int24) {
        return 1;
    }

    function setUp() public override {
        super.setUp();
        plog.record(id);
        steps(12);
    }

    /// @notice 1. A free pump inside an unlock cannot be recorded.
    function test_attack_flashPumpInsideAnUnlockIsRefused() public {
        wait(300);
        FlashPumper f = new FlashPumper(IPoolManager(address(manager)), plog, key);
        vm.expectRevert(HookrPriceLog.ManagerUnlocked.selector);
        f.pumpAndRecord(id, 5000 * sign());
    }

    /// @notice 2. Pump, record, dump in one transaction: the record is clamped, weighs nothing in that block, and an
    ///         honest record one interval later caps its weight at one interval.
    function test_attack_pumpRecordDumpMovesTheMeanByOneClampedStepForOneInterval() public {
        (, int24 before) = plog.mean(id, 1800);
        wait(300);
        moveTo(5000);
        plog.record(id);
        moveTo(0);
        assertEq(newest().tick, 500 * sign(), "clamped");
        (, int24 same) = plog.mean(id, 1800);
        assertEq(same, before, "weighs nothing in the block it was written");
        wait(300);
        plog.record(id); // anyone records the true price over it
        (, int24 m) = plog.mean(id, 1800);
        console2.log(
            "pumped +5000, recorded +500, honest record next interval: 1800 s mean moved (ticks)", int256(m) - before
        );
        assertEq(int256(m) - before, int256(500) * sign() * 300 / 1800);
    }

    /// @notice 3. Owning every record for a whole window walks the mean, bounded by the clamp: at most maxMove per
    ///         interval for the newest record, and the window's mean by the triangle under it. The attacker must hold
    ///         the pool at each recorded price outside an unlock, so every step is a paid move others can arbitrage.
    function test_attack_owningEveryRecordWalksTheMeanAtMostOneClampAnInterval() public {
        (, int24 before) = plog.mean(id, 1800);
        for (uint256 i; i < 6; ++i) {
            wait(300);
            moveTo(20_000);
            plog.record(id);
        }
        moveTo(0);
        wait(299);
        assertEq(newest().tick, 3000 * sign(), "six clamped steps");
        (, int24 m) = plog.mean(id, 1800);
        // Weights: 0 for 1 s, then 500 .. 2500 for 300 s each, 3000 for 299 s.
        int256 bound_ = (int256(500 + 1000 + 1500 + 2000 + 2500) * 300 + 3000 * 299) / 1800;
        console2.log("six owned records: newest record (ticks)", int256(newest().tick));
        console2.log("six owned records: 1800 s mean (ticks)", int256(m));
        assertEq(int256(m) - before, bound_ * sign());
    }

    /// @notice 4. Another opener cannot change a reader's log: other parameters (a hostile seed) are another id.
    function test_attack_idSquatIsAnotherLog() public {
        HookrPriceLog.Params memory p = defaults();
        p.hasSeedTick = true;
        p.seedTick = 100_000 * sign();
        bytes32 hostile = plog.open(poolId, p);
        assertTrue(hostile != id);
        uint256 c = plog.count(id);
        plog.record(hostile);
        assertEq(plog.count(id), c, "the reader's log is untouched");
        // Its first record is the spot clamped to within maxMove of its own seed.
        int24 lo = p.seedTick - int24(p.maxMoveTicks);
        int24 hi = p.seedTick + int24(p.maxMoveTicks);
        int24 sp = spot();
        assertEq(plog.latest(hostile).tick, sp < lo ? lo : (sp > hi ? hi : sp));
    }

    /// @notice 5. Spamming records: one per interval, whoever calls.
    function test_attack_recordSpamWritesOncePerInterval() public {
        wait(300);
        uint256 c = plog.count(id);
        for (uint256 i; i < 20; ++i) {
            vm.prank(address(uint160(0xA000 + i)));
            plog.record(id);
        }
        assertEq(plog.count(id), c + 1);
    }

    /// @notice 6. Pinned limitation (the Oracle Recorder's S2-1): whoever can pull the pool's liquidity can add a
    ///         position just around each record and remove it after, so a thin pool reads deep at every record and a
    ///         dust pump walks it. The thin flag is no defense there: read logs only on pools whose liquidity is
    ///         locked.
    function test_attack_jitLiquidityAroundEachRecordDefeatsTheThinFlag() public {
        liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(FULL_LO, FULL_HI, -(LIQ - 1e17), 0), "");
        for (uint256 i; i < 6; ++i) {
            wait(300);
            moveTo(20_000);
            liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(FULL_LO, FULL_HI, LIQ, bytes32(uint256(1))), "");
            plog.record(id);
            liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(FULL_LO, FULL_HI, -LIQ, bytes32(uint256(1))), "");
            assertFalse(newest().thin, "read deep at the record");
        }
        wait(300);
        (bool ok, int24 m) = plog.mean(id, 1800);
        assertTrue(ok, "limitation: the mean serves");
        console2.log("JIT around each record on a pulled pool: 1800 s mean (ticks)", int256(m));
        assertEq(newest().tick, 3000 * sign(), "still bounded by the clamp");
    }

    /// @notice 7. A past-ending mean cannot be steered by records written after its end.
    function test_attack_meanUntilIgnoresLaterRecords() public {
        uint32 end = uint32(vm.getBlockTimestamp());
        (, int24 then) = plog.meanUntil(id, 1800, end);
        for (uint256 i; i < 6; ++i) {
            wait(300);
            moveTo(20_000);
            plog.record(id);
        }
        (, int24 still) = plog.meanUntil(id, 1800, end);
        assertEq(still, then);
    }
}

contract PriceLogAttackFallingTest is PriceLogAttackTest {
    function sign() internal pure override returns (int24) {
        return -1;
    }
}
