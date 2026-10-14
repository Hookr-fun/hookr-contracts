// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {EconomicsSecurityBase, BandLp} from "../utils/EconomicsSecurityBase.sol";
import {DustRangeSwapper} from "../utils/DustRangeSwapper.sol";
import {RulesData} from "../utils/RulesData.sol";

/// F-003: a dynamic-fee walk that ran out of steps charged the full span and saturated the parent block's flow, and
/// both could be forced by third parties: dust ticks exhausted the walk's step limit at small tick spacings, and a
/// free 1-wei push to the edge of all liquidity made the next buyer walk more than 64 empty bitmap words. Hookr
/// dynamic fees price the simulated swap, so neither the walk nor its tick-spacing floor exists.
/// Pure dynamic fee pool: base 3,000, maxFee 100,000, sens 5, protocol share 2,500; quote is currency0, so a buy is
/// zeroForOne.
contract HookrDynamicFeeForcedExhaustionTest is EconomicsSecurityBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    BandLp internal dust;
    DustRangeSwapper internal swapper;
    address internal attacker = address(0xBAD);

    function setUp() public override {
        super.setUp();
        dust = new BandLp(manager);
        swapper = new DustRangeSwapper(manager);
        tokenA.transfer(address(dust), 1e18);
        tokenB.transfer(address(dust), 1e18);
        tokenA.transfer(address(swapper), 1e18);
        tokenB.transfer(address(swapper), 1e18);
    }

    function _member(int24 spacing, int24 lower, int24 upper) internal view returns (IHookrLauncher.Member memory m) {
        m = _dynamicFeeMember(Currency.wrap(address(0)));
        m.tickSpacing = spacing;
        m.tickLower = lower;
        m.tickUpper = upper;
    }

    function _open(int24 spacing, int24 lower, int24 upper) internal returns (PoolKey memory key) {
        (key,,) = _launchMember(_member(spacing, lower, upper), false);
        assertEq(Currency.unwrap(key.currency0), Currency.unwrap(root.poolConfig(key.toId()).quote), "quote is c0");
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// Any tick spacing binds: spacings 1 and 10 were the dust-tick PoCs against the walk.
    function testDynamicFeePoolBindsAtAnySpacing() public {
        _open(1, -60_000, 60_000);
        _open(10, -60_000, 60_000);
        _open(30, -60_000, 60_000);
    }

    /// A free push to the far edge leaves the price beyond all liquidity; the next buy pays the control's dynamic fee.
    function testFreePushNoLongerForcesFullSpan() public {
        _freePush(_open(32, -60_000, 0), 0);
    }

    /// The same at spacing 16, with the buy after the reference window.
    function testFreePushAtSpacing16AfterTheWindow() public {
        IHookrLauncher.Member memory m = _member(16, -60_000, 0);
        m.rules.dynamicFeeSens = 10;
        m.rules.maxFeePips = uint24(3000 + RulesData.maxDynamicFeeSpan(10, 2_500, 3000));
        (PoolKey memory key,,) = _launchMember(m, false);
        vm.roll(vm.getBlockNumber() + 1);
        _freePush(key, _dynamicFeeReset() + 1);
    }

    function _freePush(PoolKey memory key, uint256 wait) internal {
        uint256 snap = vm.snapshotState();
        HookrTypes.ExecutionReceipt memory ctl = _quoteBuy(key, 1e21);
        vm.revertToState(snap);
        vm.prank(attacker);
        (int128 a0, int128 a1) = swapper.swap(key, false, -1, TickMath.MAX_SQRT_PRICE - 1);
        assertEq(a0, 0, "push is free");
        assertEq(a1, 0, "push is free");
        (, int24 tick,,) = manager.getSlot0(key.toId());
        assertGt(tick, 887_000, "price parked at the edge");
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + wait);
        HookrTypes.ExecutionReceipt memory atk = _quoteBuy(key, 1e21);
        assertGt(ctl.lpFeePips, 3000, "control pays a dynamic fee");
        assertLt(ctl.lpFeePips, 10_000, "control is small");
        assertApproxEqAbs(atk.lpFeePips, ctl.lpFeePips, 2, "the empty range adds no dynamic fee");
    }

    /// 70 dust ticks inside the band neither raise nor cut what a large buy through them pays, and the buy fills.
    function testDustTicksDoNotChangeTheCrossingBuy() public {
        PoolKey memory key = _open(32, -60_000, 60_000);
        uint256 snap = vm.snapshotState();
        HookrTypes.ExecutionReceipt memory clean = _quoteBuy(key, 2e23);
        vm.revertToState(snap);
        vm.startPrank(attacker);
        for (int24 i; i < 70; ++i) {
            dust.modify(key, -32 * (i + 1), -32 * i, 1);
        }
        vm.stopPrank();
        HookrTypes.ExecutionReceipt memory dusted = _quoteBuy(key, 2e23);
        assertApproxEqAbs(dusted.lpFeePips, clean.lpFeePips, 1, "dust ticks do not change the dynamic fee");
        assertLt(dusted.lpFeePips, 3000 + 97_000 - 24_250, "below the full span");
        (uint256 input,) = _buyAs(trader, key, 2e23);
        assertEq(input, 2e23, "full fill");
    }
}
