// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {HookrDrawdownBurn} from "../src/HookrDrawdownBurn.sol";
import {DrawdownBurnBase} from "./DrawdownBurnBase.sol";

/// @dev The free pump: inside one unlock, swap the price up (owing the PoolManager, paying nothing yet), record, then
///      swap back so the debt nets to the fees alone. The engine refuses the record.
contract FlashPumper is IUnlockCallback {
    IPoolManager internal immutable manager;
    HookrDrawdownBurn internal immutable engine;
    PoolKey internal key;
    uint160 internal pumpTo;
    bool internal zeroForOneUp;

    constructor(IPoolManager m, HookrDrawdownBurn e, PoolKey memory k) {
        manager = m;
        engine = e;
        key = k;
    }

    function go(uint160 sqrtTarget, bool upIsZeroForOne) external {
        pumpTo = sqrtTarget;
        zeroForOneUp = upIsZeroForOne;
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        manager.swap(key, SwapParams(zeroForOneUp, -1e30, pumpTo), "");
        engine.checkpoint();
        return "";
    }
}

/// @notice Attacks on the oracle-less engine, on a plain v4 pool (0.30% LP fee, no taxes). The Hookr pool's 3.3% Auto
///         Burn on buys and 3.3% sell tax make every paid pump below about 7% dearer per round trip; the fork suite
///         measures that on a real Hookr pool.
contract DrawdownBurnAttackTest is DrawdownBurnBase {
    using StateLibrary for IPoolManager;

    address internal attacker = makeAddr("attacker");

    function subjectIs0() internal pure virtual override returns (bool) {
        return true;
    }

    function setUp() public override {
        super.setUp();
        subjectToken.mint(attacker, 1e30);
        quoteToken.mint(attacker, 1e30);
        vm.startPrank(attacker);
        subjectToken.approve(address(swapRouter), type(uint256).max);
        quoteToken.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev The attacker's holdings valued in the quote at the pool's current price.
    function attackerValue() internal view returns (uint256) {
        (uint160 sqrtP,,,) = IPoolManager(address(manager)).getSlot0(id);
        return attackerValueAt(sqrtP);
    }

    /// @dev The same at a fixed price, so a round trip's cost is not mixed with marking the inventory to a new price.
    function attackerValueAt(uint160 sqrtP) internal view returns (uint256) {
        uint256 priceX96 = uint256(sqrtP) * uint256(sqrtP) >> 96; // currency1 per currency0, Q96
        uint256 s = subjectToken.balanceOf(attacker);
        uint256 q = quoteToken.balanceOf(attacker);
        uint256 sInQuote = subjectIs0() ? s * priceX96 >> 96 : (s << 96) / priceX96;
        return q + sInQuote;
    }

    function pumpPokeDump(int24 pumpTarget) internal returns (uint256 cost) {
        (uint160 sqrtBefore,,,) = IPoolManager(address(manager)).getSlot0(id);
        uint256 before = attackerValueAt(sqrtBefore);
        int24 back = spot();
        moveToFrom(pumpTarget, attacker);
        vm.prank(attacker);
        engine.checkpoint();
        moveToFrom(back, attacker);
        uint256 afterValue = attackerValueAt(sqrtBefore);
        cost = before > afterValue ? before - afterValue : 0;
    }

    // 1. A pump and a dump around one record, in one transaction.
    function test_attack_oneBlockPumpMovesOneRecordByTheClampOnly() public {
        steps(12);
        assertEq(engine.ath(), 0);
        vm.warp(vm.getBlockTimestamp() + 300);
        uint256 cost = pumpPokeDump(5000);
        assertEq(engine.checkpointAt(0).tick, 500, "a +5000 tick spot records as +500");
        assertEq(engine.ath(), 0, "the high needs a whole window");
        (,,, uint8 tier) = engine.drawdown();
        assertEq(tier, 0);
        // The next honest record walks it back.
        step();
        assertEq(engine.checkpointAt(0).tick, 0);
        console2.log("one pump-poke-dump to +5000 ticks, attacker cost in quote wei", cost);
    }

    // 2. The free version, inside one unlock: refused.
    function test_attack_flashPumpInsideUnlockRefused() public {
        steps(12);
        FlashPumper p = new FlashPumper(IPoolManager(address(manager)), engine, key);
        int24 poolTarget = subjectIs0() ? int24(5000) : int24(-5000);
        vm.warp(vm.getBlockTimestamp() + 300);
        vm.expectRevert(HookrDrawdownBurn.ManagerUnlocked.selector);
        p.go(TickMath.getSqrtPriceAtTick(poolTarget), !subjectIs0());
    }

    // 3. Owning every record for hours: what it takes to lift the high, with and without the rise cap.
    function test_attack_sustainedPumpingLiftsTheHighOnlyAtAPrice() public {
        steps(12);
        uint256 total;
        for (uint256 i; i < 24; ++i) {
            vm.warp(vm.getBlockTimestamp() + 300);
            total += pumpPokeDump(5000);
        }
        int32 uncapped = engine.ath();
        console2.log("24 records pumped to +5000 over 2 h, no cap: high now (ticks)", int256(uncapped));
        console2.log("  attacker cost, quote wei", total);
        assertGt(uncapped, 0, "an attacker who owns every record for a window can lift the high");

        // Same attack with a 5%/h rise cap.
        HookrDrawdownBurn.Config memory c = defaults();
        c.athRiseCapBpsPerHour = 500;
        engine = new HookrDrawdownBurn(c);
        steps(12);
        uint256 t0 = vm.getBlockTimestamp();
        int32 a0 = engine.ath();
        for (uint256 i; i < 24; ++i) {
            vm.warp(vm.getBlockTimestamp() + 300);
            pumpPokeDump(5000);
        }
        int32 capped = engine.ath();
        console2.log("same attack, 5%/h rise cap: high now (ticks)", int256(capped));
        assertLe(int256(capped) - a0, int256(487) * int256(vm.getBlockTimestamp() - t0) / 3600 + 1);
        assertLt(capped, uncapped);
    }

    // 4. Dumping right before a run to buy a deeper tier: the tier reads the mean.
    function test_attack_dumpBeforeRunDoesNotDeepenTheTier() public {
        steps(12);
        holdAt(-3000, 9);
        fund(4e18);
        moveToFrom(-12_000, attacker);
        (,,, uint8 tier) = engine.drawdown();
        assertEq(tier, 2, "mean still -3000");
        vm.recordLogs();
        engine.run();
        assertEq(engine.burnBudget(), 0, "the burn share bought cheap from the dumper");
        assertLe(spot(), -9163, "the wall filled only up to its price");
    }

    // 5. Sandwiching the buyback: pump before run, sell into it after.
    function test_attack_sandwichBuysNothingAboveTheLimit() public {
        steps(12);
        holdAt(-3000, 9);
        fund(4e18);
        uint256 deadBefore = deadBalance();
        moveToFrom(0, attacker); // +3000 ticks above the reference
        engine.run();
        assertEq(deadBalance(), deadBefore);
        assertEq(engine.burnBudget(), 2e18);
    }

    // 6. Epoch boundary: one paid record before the close cannot flip the mode; three can, at three round trips.
    function test_attack_epochBoundary() public {
        HookrDrawdownBurn.Config memory c = epochDefaults();
        c.hasInitialAth = true;
        c.initialAth = 5000;
        engine = new HookrDrawdownBurn(c);
        uint256 b1 = (T0 / 4 hours + 1) * 4 hours;
        uint256 b2 = b1 + 4 hours;
        holdAt(1000, 4);
        while (vm.getBlockTimestamp() + 300 < b1) step();
        step();
        assertEq(uint8(engine.mode()), uint8(HookrDrawdownBurn.Mode.ACCUMULATE));

        // Flat through the next epoch; the attacker takes the last record before the close.
        while (vm.getBlockTimestamp() + 600 < b2) step();
        vm.warp(vm.getBlockTimestamp() + 300);
        pumpPokeDump(-5000);
        step(); // first record past the close
        assertGt(vm.getBlockTimestamp(), b2);
        assertEq(uint8(engine.mode()), uint8(HookrDrawdownBurn.Mode.ACCUMULATE), "one record cannot flip it");

        // Next epoch: the attacker takes the last three records.
        uint256 b3 = b2 + 4 hours;
        while (vm.getBlockTimestamp() + 1200 < b3) step();
        uint256 cost;
        for (uint256 i; i < 3; ++i) {
            vm.warp(vm.getBlockTimestamp() + 300);
            cost += pumpPokeDump(-5000);
        }
        step();
        assertGt(vm.getBlockTimestamp(), b3);
        console2.log("three dumped records flip the epoch; attacker cost, quote wei", cost);
        assertEq(uint8(engine.mode()), uint8(HookrDrawdownBurn.Mode.SPEND), "three records can");
    }

    // 8. Pinned limitation (the Oracle Recorder's S2-1 in this engine): whoever can pull the pool's liquidity can also
    //    add a position just around each record and remove it after, so a thin pool reads deep at every record. The
    //    floor is then no defense, and moving a thin pool costs dust: only the clamp and the rise cap bound the high.
    //    Hence: run the engine only on pools whose liquidity is locked (Launcher principal lock), with the rise cap on.
    function test_attack_jitLiquidityAroundEachRecordPassesTheFloor() public {
        steps(12);
        liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(FULL_LO, FULL_HI, -(LIQ - 1e17), 0), "");
        for (uint256 i; i < 16; ++i) {
            vm.warp(vm.getBlockTimestamp() + 300);
            moveTo(5000); // dust on a thin pool
            liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(FULL_LO, FULL_HI, LIQ, bytes32(uint256(1))), "");
            engine.checkpoint();
            liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(FULL_LO, FULL_HI, -LIQ, bytes32(uint256(1))), "");
            assertFalse(engine.checkpointAt(0).thin, "read deep at the record");
        }
        console2.log("JIT around each record, no rise cap: high now (ticks)", int256(engine.ath()));
        assertGt(engine.ath(), 0, "limitation: the high moved on a pool whose liquidity can be pulled");

        // Same attack against an engine with a 5%/h rise cap, from the same honest start.
        liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(FULL_LO, FULL_HI, LIQ - 1e17, 0), "");
        moveTo(0);
        HookrDrawdownBurn.Config memory c = defaults();
        c.athRiseCapBpsPerHour = 500;
        engine = new HookrDrawdownBurn(c);
        steps(12);
        int32 a0 = engine.ath();
        assertApproxEqAbs(int256(a0), 0, 1);
        liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(FULL_LO, FULL_HI, -(LIQ - 1e17), 0), "");
        uint256 t0 = vm.getBlockTimestamp();
        for (uint256 i; i < 16; ++i) {
            vm.warp(vm.getBlockTimestamp() + 300);
            moveTo(5000);
            liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(FULL_LO, FULL_HI, LIQ, bytes32(uint256(1))), "");
            engine.checkpoint();
            liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(FULL_LO, FULL_HI, -LIQ, bytes32(uint256(1))), "");
        }
        console2.log("same with a 5%/h rise cap: high now (ticks)", int256(engine.ath()));
        assertLe(int256(engine.ath()) - a0, int256(487) * int256(vm.getBlockTimestamp() - t0) / 3600 + 1);
    }

    // 7. Pulling the liquidity and moving the price with dust: thin records, no high, no spend.
    function test_attack_liquidityPull() public {
        steps(12);
        fund(4e18);
        liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(FULL_LO, FULL_HI, -(LIQ - 1e17), 0), "");
        uint256 cost;
        for (uint256 i; i < 14; ++i) {
            vm.warp(vm.getBlockTimestamp() + 300);
            uint256 before = attackerValue();
            moveToFrom(5000, attacker);
            vm.prank(attacker);
            engine.checkpoint();
            moveToFrom(0, attacker);
            uint256 afterValue = attackerValue();
            cost += before > afterValue ? before - afterValue : 0;
        }
        assertTrue(engine.checkpointAt(0).thin);
        assertEq(engine.ath(), 0, "thin records never raise the high");
        uint256 deadBefore = deadBalance();
        engine.run();
        assertEq(deadBalance(), deadBefore, "no spend on a thin reference");
        assertEq(engine.burnBudget(), 0);
        console2.log("liquidity pulled, 14 dust pumps: attacker cost, quote wei", cost);
    }
}

contract DrawdownBurnAttackFlippedTest is DrawdownBurnAttackTest {
    function subjectIs0() internal pure override returns (bool) {
        return false;
    }
}
