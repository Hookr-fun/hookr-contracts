// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {HookrPriceLog} from "../../price-log/src/HookrPriceLog.sol";
import {HookrBuybackBurn} from "../src/HookrBuybackBurn.sol";
import {BuybackBase} from "./BuybackBase.sol";

/// @dev Drives the pool, the log and the buyback: swaps anywhere, waits, records, funds and triggers buybacks.
contract BuybackHandler is Test {
    using StateLibrary for IPoolManager;

    IPoolManager internal immutable manager;
    PoolSwapTest internal immutable swapRouter;
    HookrPriceLog internal immutable plog;
    HookrBuybackBurn internal immutable buyback;
    MockERC20 internal immutable quote;
    PoolKey internal key;
    PoolId internal poolId;
    bytes32 internal immutable logId;
    bool internal immutable hookrIs0;

    uint256 public spent;
    uint256 public buys;
    uint256 public underFloor;

    constructor(
        IPoolManager m,
        PoolSwapTest s,
        HookrPriceLog p,
        HookrBuybackBurn b,
        MockERC20 q,
        MockERC20 h,
        PoolKey memory k,
        PoolId pid,
        bytes32 lid,
        bool hookrIs0_
    ) {
        manager = m;
        swapRouter = s;
        plog = p;
        buyback = b;
        quote = q;
        key = k;
        poolId = pid;
        logId = lid;
        hookrIs0 = hookrIs0_;
        q.approve(address(s), type(uint256).max);
        h.approve(address(s), type(uint256).max);
    }

    function swapTo(int24 target) external {
        target = int24(bound(target, -4000, 4000));
        uint160 limit = TickMath.getSqrtPriceAtTick(target);
        (uint160 now_,,,) = manager.getSlot0(poolId);
        if (limit == now_) return;
        swapRouter.swap(key, SwapParams(limit < now_, -1e30, limit), PoolSwapTest.TestSettings(false, false), "");
    }

    function wait(uint16 secs) external {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 1, 1200));
    }

    function record() external {
        plog.record(logId);
    }

    function fund(uint96 amount) external {
        quote.mint(address(buyback), bound(amount, 0, 20e18));
    }

    function buy(uint96 amount) external {
        uint256 bal = quote.balanceOf(address(buyback));
        if (bal == 0) return;
        uint256 amt = bound(amount, 1, bal);
        uint256 floor = _floor(amt);
        try buyback.buyback(amt) returns (uint256 out) {
            spent += amt;
            buys++;
            if (out + 2 < floor) underFloor++;
        } catch {}
    }

    function _floor(uint256 amount) internal view returns (uint256) {
        (bool ok, int24 m) = plog.mean(logId, buyback.referenceWindow());
        (bool ok2, int24 s) = plog.mean(logId, buyback.SPOT_WINDOW());
        if (!ok || !ok2) return 0;
        uint256 a = _at(amount, m);
        uint256 b = _at(amount, s);
        uint256 e = a > b ? a : b;
        return e - e * buyback.maxSlippageBps() / 10_000;
    }

    function _at(uint256 amount, int24 t) internal view returns (uint256) {
        uint256 sp = TickMath.getSqrtPriceAtTick(t);
        uint256 ratioX128 = FullMath.mulDiv(sp, sp, 1 << 64);
        return hookrIs0 ? FullMath.mulDiv(1 << 128, amount, ratioX128) : FullMath.mulDiv(ratioX128, amount, 1 << 128);
    }
}

contract BuybackInvariantTest is BuybackBase {
    BuybackHandler internal handler;
    uint256 internal start;

    function hookrIs0() internal pure virtual override returns (bool) {
        return true;
    }

    function setUp() public override {
        super.setUp();
        warmUp();
        start = vm.getBlockTimestamp();
        handler = new BuybackHandler(
            IPoolManager(address(manager)), swapRouter, plog, buyback, quote, hookr, key, poolId, logId, hookrIs0()
        );
        hookr.mint(address(handler), 1e30);
        quote.mint(address(handler), 1e30);
        targetContract(address(handler));
    }

    /// @notice The handler's buys do succeed, so the invariants below are about real buybacks.
    function test_handlerBuys() public {
        handler.fund(5e18);
        handler.buy(1e18);
        handler.wait(600);
        handler.record();
        handler.buy(2e18);
        assertEq(handler.buys(), 2);
        assertEq(handler.spent(), 3e18);
    }

    function invariant_neverHoldsHookr() public view {
        assertEq(hookr.balanceOf(address(buyback)), 0);
    }

    /// @notice What every buyback burned is at least the floor off the better of the two means.
    function invariant_neverBuysUnderTheFloor() public view {
        assertEq(handler.underFloor(), 0);
    }

    /// @notice A token bucket: at most one cap up front plus one cap per period since.
    function invariant_spendWithinTheLimit() public view {
        uint256 elapsed = vm.getBlockTimestamp() - start;
        assertLe(handler.spent(), uint256(CAP) + uint256(CAP) * elapsed / buyback.spendPeriod());
        assertLe(buyback.spendable(), CAP);
    }
}

contract BuybackInvariantFlippedTest is BuybackInvariantTest {
    function hookrIs0() internal pure override returns (bool) {
        return false;
    }
}
