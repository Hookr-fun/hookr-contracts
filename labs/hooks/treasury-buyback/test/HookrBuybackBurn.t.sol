// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {HookrPriceLog} from "../../price-log/src/HookrPriceLog.sol";
import {HookrBuybackBurn} from "../src/HookrBuybackBurn.sol";
import {IHookrGoverned} from "../vendor/hookr-1/interfaces/IHookrGoverned.sol";
import {BuybackBase, InUnlockBuyer, TestBuybackRouter} from "./BuybackBase.sol";

contract HookrBuybackBurnTest is BuybackBase {
    using PoolIdLibrary for PoolKey;

    function hookrIs0() internal pure virtual override returns (bool) {
        return true;
    }

    // -----------------------------------------------------------------------------------------------------------------
    // SL-1: the buyback deploys before its reference pool and stays inert until the log covers the window
    // -----------------------------------------------------------------------------------------------------------------

    function test_SL1_deploysBeforeThePoolAndRefusesUntilTheLogCoversTheWindow() public {
        // A fresh key no pool has used: no pool, no records.
        PoolKey memory k = _key(500, 10);
        bytes32 id = plog.open(k.toId(), logDefaults());
        HookrBuybackBurn b = new HookrBuybackBurn(address(this), address(hookr), address(router), plog, k, id, CAP);
        quote.mint(address(b), 1e18);
        vm.expectRevert(abi.encodeWithSelector(HookrBuybackBurn.NoHealthyReference.selector, k.toId(), 1800));
        b.buyback(1e18);

        // The pool launches; the log is seeded; a window later the buyback works.
        manager.initialize(k, TickMath.getSqrtPriceAtTick(0));
        liquidityRouter.modifyLiquidity(k, ModifyLiquidityParams(-887_270, 887_270, LIQ, 0), "");
        plog.record(id);
        for (uint256 i; i < 5; ++i) {
            wait(300);
            plog.record(id);
        }
        vm.expectRevert(abi.encodeWithSelector(HookrBuybackBurn.NoHealthyReference.selector, k.toId(), 1800));
        b.buyback(1e18); // 1,500 s of history: one interval short
        wait(300);
        uint256 out = b.buyback(1e18);
        assertGt(out, 0);
        assertEq(hookr.balanceOf(DEAD), out);
    }

    /// @notice The default setUp is the SL-1 path too: the buyback was built before the pool was initialized.
    function test_SL1_theDefaultBuybackWasBuiltBeforeItsPool() public {
        fund(1e18);
        vm.expectRevert(abi.encodeWithSelector(HookrBuybackBurn.NoHealthyReference.selector, poolId, 1800));
        buyback.buyback(1e18);
        warmUp();
        assertGt(buyback.buyback(1e18), 0);
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Binding
    // -----------------------------------------------------------------------------------------------------------------

    function test_bind_refusals() public {
        // A pool without HOOKR.
        MockERC20 other = new MockERC20("X", "X", 18);
        (Currency c0, Currency c1) = address(other) < address(quote)
            ? (Currency.wrap(address(other)), Currency.wrap(address(quote)))
            : (Currency.wrap(address(quote)), Currency.wrap(address(other)));
        PoolKey memory noHookr = PoolKey(c0, c1, 3000, 60, key.hooks);
        bytes32 noHookrLog = plog.open(noHookr.toId(), logDefaults());
        vm.expectRevert(abi.encodeWithSelector(HookrBuybackBurn.PoolDoesNotHoldHookr.selector, noHookr.toId()));
        new HookrBuybackBurn(address(this), address(hookr), address(router), plog, noHookr, noHookrLog, CAP);

        // A log of another pool.
        vm.expectRevert(abi.encodeWithSelector(HookrBuybackBurn.LogNotForPool.selector, noHookrLog, poolId));
        new HookrBuybackBurn(address(this), address(hookr), address(router), plog, key, noHookrLog, CAP);

        // A log never opened.
        bytes32 unopened = keccak256("unopened");
        vm.expectRevert(abi.encodeWithSelector(HookrBuybackBurn.LogNotForPool.selector, unopened, poolId));
        new HookrBuybackBurn(address(this), address(hookr), address(router), plog, key, unopened, CAP);

        // A log whose interval leaves the default window under four records.
        HookrPriceLog.Params memory p = logDefaults();
        p.interval = 600;
        bytes32 slow = plog.open(poolId, p);
        vm.expectRevert(abi.encodeWithSelector(HookrBuybackBurn.InvalidWindow.selector, 1800));
        new HookrBuybackBurn(address(this), address(hookr), address(router), plog, key, slow, CAP);

        // No log contract.
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.InvalidAddress.selector, address(0xBEEF)));
        new HookrBuybackBurn(
            address(this), address(hookr), address(router), HookrPriceLog(address(0xBEEF)), key, logId, CAP
        );
    }

    function test_bind_refusesARouterOnAnotherManager() public {
        TestBuybackRouter elsewhere = new TestBuybackRouter(IPoolManager(address(new PoolManager(address(this)))));
        vm.expectRevert(abi.encodeWithSelector(HookrBuybackBurn.RouterManagerMismatch.selector, address(elsewhere)));
        new HookrBuybackBurn(address(this), address(hookr), address(elsewhere), plog, key, logId, CAP);
        bytes32 kind = buyback.SET_ROUTER();
        vm.expectRevert(abi.encodeWithSelector(HookrBuybackBurn.RouterManagerMismatch.selector, address(elsewhere)));
        buyback.queue(kind, abi.encode(address(elsewhere)));
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Buying
    // -----------------------------------------------------------------------------------------------------------------

    function test_buyback_burnsWhatItBuysAtTheFloorOrBetter() public {
        warmUp();
        fund(5e18);
        uint256 floor = floorFor(5e18);
        uint256 out = buyback.buyback(5e18);
        assertGe(out, floor);
        assertEq(burned(), out);
        assertEq(hookr.balanceOf(address(buyback)), 0, "never holds HOOKR");
        assertEq(quote.balanceOf(address(buyback)), 0);
        assertEq(buyback.spendable(), CAP - 5e18);
    }

    function test_buyback_writesTheDueRecordWhichWeighsNothing() public {
        warmUp();
        wait(300);
        moveTo(-300); // a move the log has not seen (HOOKR cheaper: the floor allows it)
        (, int24 before) = plog.mean(logId, 1800);
        uint256 c = plog.count(logId);
        fund(1e18);
        buyback.buyback(1e18);
        assertEq(plog.count(logId), c + 1, "the buyback recorded the due record");
        assertEq(plog.latest(logId).time, uint32(vm.getBlockTimestamp()));
        (, int24 after_) = plog.mean(logId, 1800);
        assertEq(after_, before, "and it weighs nothing in the mean that priced the buyback");
    }

    function test_buyback_defaultFloorIs300Bps() public {
        assertEq(buyback.maxSlippageBps(), 300);
        assertEq(buyback.DEFAULT_SLIPPAGE_BPS(), 300);
        assertEq(buyback.referenceWindow(), 1800);
    }

    function test_buyback_refusedInsideAnUnlock() public {
        warmUp();
        fund(1e18);
        InUnlockBuyer x = new InUnlockBuyer(IPoolManager(address(manager)), buyback);
        vm.expectRevert(HookrBuybackBurn.ManagerUnlocked.selector);
        x.buyInside(1e18);
    }

    function test_buyback_thinRecordStillWeighingRefuses() public {
        warmUp();
        liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(FULL_LO, FULL_HI, -(LIQ - 1e17), 0), "");
        steps(1);
        liquidityRouter.modifyLiquidity(key, ModifyLiquidityParams(FULL_LO, FULL_HI, LIQ - 1e17, 0), "");
        wait(10);
        fund(1e18);
        vm.expectRevert(abi.encodeWithSelector(HookrBuybackBurn.NoHealthyReference.selector, poolId, 1800));
        buyback.buyback(1e18);
    }

    function test_spendLimit_capsAndRefills() public {
        warmUp();
        fund(100e18);
        buyback.buyback(CAP);
        vm.expectRevert(abi.encodeWithSelector(HookrBuybackBurn.SpendLimitExceeded.selector, 1, 0));
        buyback.buyback(1);
        wait(900);
        assertEq(buyback.spendable(), CAP / 2);
        // A refused buyback spends nothing of the allowance.
        vm.expectRevert(abi.encodeWithSelector(HookrBuybackBurn.SpendLimitExceeded.selector, CAP, CAP / 2));
        buyback.buyback(CAP);
        assertEq(buyback.spendable(), CAP / 2);
    }

    function test_pause_isImmediateAndUnpauseWaits() public {
        warmUp();
        fund(1e18);
        buyback.pause();
        vm.expectRevert(HookrBuybackBurn.Paused.selector);
        buyback.buyback(1e18);
        buyback.queue(buyback.UNPAUSE(), "");
        wait(30 minutes);
        plog.record(logId);
        buyback.executeUnpause();
        steps(6);
        assertGt(buyback.buyback(1e18), 0);
    }

    function test_window_queueChecksTheLog() public {
        bytes32 kind = buyback.SET_WINDOW();
        vm.expectRevert(abi.encodeWithSelector(HookrBuybackBurn.InvalidWindow.selector, 1199));
        buyback.queue(kind, abi.encode(uint32(1199)));
        vm.expectRevert(abi.encodeWithSelector(HookrBuybackBurn.InvalidWindow.selector, 300 * 48 + 1));
        buyback.queue(kind, abi.encode(uint32(300 * 48 + 1)));
        buyback.queue(kind, abi.encode(uint32(3600)));
        wait(30 minutes);
        buyback.executeWindow(3600);
        assertEq(buyback.referenceWindow(), 3600);
    }

    function test_repin_movesThePoolAndItsLogTogether() public {
        PoolKey memory k = _key(500, 10);
        bytes32 id = plog.open(k.toId(), logDefaults());
        bytes32 kind = buyback.SET_POOL();
        // The log must be the new pool's.
        vm.expectRevert(abi.encodeWithSelector(HookrBuybackBurn.LogNotForPool.selector, logId, k.toId()));
        buyback.queue(kind, abi.encode(k, logId));
        buyback.queue(kind, abi.encode(k, id));
        wait(30 minutes);
        buyback.executePool(k, id);
        assertEq(buyback.logId(), id);
        (,,, int24 spacing,) = buyback.pool();
        assertEq(spacing, 10);
    }

    function test_onlyOwner() public {
        vm.startPrank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, address(0xBAD)));
        buyback.pause();
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, address(0xBAD)));
        buyback.tightenSlippage(100);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Fuzz
    // -----------------------------------------------------------------------------------------------------------------

    /// @notice Whatever the price path before it and whatever the pool's price in the call: a buyback either reverts
    ///         or returns at least the floor off the better mean, burns all of it, and spends exactly its input.
    function testFuzz_buybackNeverBelowTheFloor(int24[6] memory path, int24 pump, uint96 amount) public {
        plog.record(logId);
        for (uint256 i; i < 6; ++i) {
            wait(300);
            moveTo(int24(bound(path[i], -3000, 3000)));
            plog.record(logId);
        }
        wait(300);
        moveTo(int24(bound(pump, -6000, 6000)));
        uint256 amt = bound(amount, 1e15, CAP);
        fund(amt);
        uint256 floor = floorFor(amt);
        try buyback.buyback(amt) returns (uint256 out) {
            assertGe(out + 2, floor, "at the floor or better");
            assertEq(burned(), out);
            assertEq(hookr.balanceOf(address(buyback)), 0);
            assertEq(quote.balanceOf(address(buyback)), 0);
        } catch {
            assertEq(burned(), 0);
            assertEq(quote.balanceOf(address(buyback)), amt, "a refused buyback spends nothing");
        }
    }
}

contract HookrBuybackBurnFlippedTest is HookrBuybackBurnTest {
    function hookrIs0() internal pure override returns (bool) {
        return false;
    }
}
