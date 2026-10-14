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

/// F-003, the dust-range trap: a liquidity-1 range above the price plus a near-free push parked the price on the far
/// side of the range, and the next buyer's walk back through it priced as real movement (LP fee 3,363 -> 72,684 pips
/// for a 6-wei trap). Liquidity age, a block-open anchor and a minimum walk liquidity each left a residual. The
/// dynamic fee is now priced on the simulated swap from the pool's anchor, which only swaps with real notional move,
/// so every trap below charges the victim what it pays with no trap. Pure dynamic fee pool at spacing 60: base 3,000,
/// maxFee 100,000, sens 5, protocol share 2,500; quote is currency0, so a buy is zeroForOne. The launch band
/// [-60000, 0) leaves the price at the edge of all liquidity.
contract HookrDynamicFeeDustRangeTest is EconomicsSecurityBase {
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
        tokenA.transfer(address(swapper), 1e21);
        tokenB.transfer(address(swapper), 1e21);
    }

    function _open() internal returns (PoolKey memory key) {
        key = _openAt(60, 5, 100_000, 0);
    }

    /// @dev Band [top - 60,000, top) at spacing `spacing`, price at `top`, at `maxFee` or the widest span the reach
    ///      bound admits at `sens` (HookrDynamicFee.withinReach), whichever is smaller.
    function _openAt(int24 spacing, uint16 sens, uint24 maxFee, int24 top) internal returns (PoolKey memory key) {
        IHookrLauncher.Member memory m = _dynamicFeeMember(Currency.wrap(address(0)));
        m.tickSpacing = spacing;
        m.rules.dynamicFeeSens = sens;
        m.rules.maxFeePips = maxFee;
        RulesData.clampToReach(m.rules, 3000);
        m.tickUpper = top;
        m.tickLower = top - (60_000 / spacing) * spacing;
        m.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(top);
        (key,,) = _launchMember(m, false);
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _bal(address who) internal view returns (uint256) {
        return tokenA.balanceOf(who) + tokenB.balanceOf(who);
    }

    function _control(PoolKey memory key, uint256 wait) internal returns (uint256 fee, uint256 out) {
        uint256 snap = vm.snapshotState();
        vm.warp(vm.getBlockTimestamp() + wait);
        fee = _quoteBuy(key, 1e21).lpFeePips;
        (, out) = _buyAs(trader, key, 1e21);
        vm.revertToState(snap);
    }

    function _plant(PoolKey memory key) internal {
        vm.prank(attacker);
        dust.modify(key, 60, 16_080, 1);
    }

    function _push(PoolKey memory key, int24 toTick) internal {
        vm.prank(attacker);
        swapper.swap(key, false, -1e6, TickMath.getSqrtPriceAtTick(toTick));
        (, int24 tick,,) = manager.getSlot0(key.toId());
        assertGe(tick, toTick - 1, "price pushed");
    }

    function _victim(PoolKey memory key) internal returns (uint256 fee, uint256 out) {
        fee = _quoteBuy(key, 1e21).lpFeePips;
        (, out) = _buyAs(trader, key, 1e21);
        emit log_named_uint("victim LP fee", fee);
    }

    function _assertControl(uint256 ctlFee, uint256 ctlOut, uint256 fee, uint256 out) internal {
        emit log_named_uint("control LP fee", ctlFee);
        assertApproxEqAbs(fee, ctlFee, 1, "the trap adds nothing");
        assertGe(out * 1000, ctlOut * 999, "victim output");
    }

    /// Trap set, then the victim buys after `blocks` blocks and `wait` seconds.
    function _trapAfter(uint256 blocks, uint256 wait) internal {
        PoolKey memory key = _open();
        (uint256 ctlFee, uint256 ctlOut) = _control(key, wait);
        uint256 before = _bal(address(dust)) + _bal(address(swapper));
        _plant(key);
        _push(key, 16_200);
        assertLt(before - (_bal(address(dust)) + _bal(address(swapper))), 100, "trap costs under 100 wei");
        vm.roll(vm.getBlockNumber() + blocks);
        vm.warp(vm.getBlockTimestamp() + wait);
        (uint256 fee, uint256 out) = _victim(key);
        _assertControl(ctlFee, ctlOut, fee, out);
    }

    function testDustRangePushSameBlock() public {
        _trapAfter(0, 0);
    }

    function testDustRangePushEarlierBlock() public {
        _trapAfter(1, 12);
    }

    /// The walk's liquidity-age design re-opened the trap once the range matured; there is no age now.
    function testDustRangeAfterTheWindowAndTheReset() public {
        uint256 snap = vm.snapshotState();
        _trapAfter(10, _dynamicFeeWindow() + 1);
        vm.revertToState(snap);
        _trapAfter(40, _dynamicFeeReset() + 1);
    }

    /// A push that parks the price inside the range: the victim's first stretch trades only dust.
    function testPushIntoTheDustRange() public {
        PoolKey memory key = _open();
        (uint256 ctlFee, uint256 ctlOut) = _control(key, 0);
        _plant(key);
        _push(key, 8_000);
        (uint256 fee, uint256 out) = _victim(key);
        _assertControl(ctlFee, ctlOut, fee, out);
    }

    /// A range planted long before the push, then the push in the victim's block (the age design's residual).
    function testPrePlantedRangeThenPushInTheVictimsBlock() public {
        PoolKey memory key = _open();
        _plant(key);
        vm.roll(vm.getBlockNumber() + 1000);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        (uint256 ctlFee, uint256 ctlOut) = _control(key, 0);
        _push(key, 16_200);
        (uint256 fee, uint256 out) = _victim(key);
        _assertControl(ctlFee, ctlOut, fee, out);
    }

    /// Many dust ranges between the price and the push (the age design's full-slots residual).
    function testManyDustRanges() public {
        PoolKey memory key = _open();
        (uint256 ctlFee, uint256 ctlOut) = _control(key, 0);
        vm.startPrank(attacker);
        for (int24 i; i < 40; ++i) {
            dust.modify(key, 60 + 300 * i, 120 + 300 * i, 1);
        }
        vm.stopPrank();
        _push(key, 16_200);
        (uint256 fee, uint256 out) = _victim(key);
        _assertControl(ctlFee, ctlOut, fee, out);
    }

    /// A deep decoy at the dust range, removed right after the dust is added (the age design's bypass, verify3 V2),
    /// and the same with a one-wei decoy.
    function testDecoyRemovalBeforeThePush() public {
        int256[2] memory decoys = [int256(1e18), 1];
        for (uint256 i; i < 2; ++i) {
            uint256 snap = vm.snapshotState();
            PoolKey memory key = _open();
            (uint256 ctlFee, uint256 ctlOut) = _control(key, 0);
            BandLp decoy = new BandLp(manager);
            tokenA.transfer(address(decoy), 1e22);
            tokenB.transfer(address(decoy), 1e22);
            decoy.modify(key, 60, 16_080, decoys[i]);
            vm.roll(vm.getBlockNumber() + 100);
            _plant(key);
            decoy.modify(key, 60, 16_080, -decoys[i]);
            _push(key, 16_200);
            (uint256 fee, uint256 out) = _victim(key);
            _assertControl(ctlFee, ctlOut, fee, out);
            vm.revertToState(snap);
        }
    }

    /// One wide liquidity-1 band from above the price to the top of the tick range and a push to the edge, at every
    /// sensitivity the walk's tick-spacing floor used to pair with a spacing, a low launch tick, and the most sensitive
    /// setting at the widest span (the realized design's "dust gift" residual: crossing the band hands the victim real
    /// subject at extreme prices, and it must not raise the fee).
    function testWideDustBandAtEverySpacing() public {
        int24[8] memory sp = [int24(16), 18, 20, 23, 27, 32, 32, 40];
        uint16[8] memory se = [uint16(10), 9, 8, 7, 6, 5, 5, 4];
        int24[8] memory top = [int24(0), 0, 0, 0, 0, 0, -200_000, -440_000];
        uint24[8] memory maxFee = [uint24(600_000), 100_000, 100_000, 100_000, 100_000, 100_000, 100_000, 100_000];
        for (uint256 i; i < 8; ++i) {
            uint256 snap = vm.snapshotState();
            PoolKey memory key = _openAt(sp[i], se[i], maxFee[i], top[i]);
            (uint256 ctlFee, uint256 ctlOut) = _control(key, 0);
            int24 hi = TickMath.maxUsableTick(sp[i]);
            vm.startPrank(attacker);
            dust.modify(key, top[i] + sp[i], hi, 1);
            swapper.swap(key, false, -1e20, TickMath.MAX_SQRT_PRICE - 1);
            vm.stopPrank();
            vm.roll(vm.getBlockNumber() + 1);
            (uint256 fee, uint256 out) = _victim(key);
            _assertControl(ctlFee, ctlOut, fee, out);
            vm.revertToState(snap);
        }
    }

    /// The same band with the minimal push: the price parked only part of the way up.
    function testWideDustBandMinimalPush() public {
        int24[3] memory sp = [int24(16), 20, 23];
        uint16[3] memory se = [uint16(10), 8, 7];
        int24[3] memory park = [int24(540_000), 670_000, 770_040];
        for (uint256 i; i < 3; ++i) {
            uint256 snap = vm.snapshotState();
            PoolKey memory key = _openAt(sp[i], se[i], 100_000, 0);
            (uint256 ctlFee, uint256 ctlOut) = _control(key, 0);
            vm.startPrank(attacker);
            dust.modify(key, sp[i], TickMath.maxUsableTick(sp[i]), 1);
            swapper.swap(key, false, -1e20, TickMath.getSqrtPriceAtTick(park[i]));
            vm.stopPrank();
            vm.roll(vm.getBlockNumber() + 1);
            (uint256 fee, uint256 out) = _victim(key);
            _assertControl(ctlFee, ctlOut, fee, out);
            vm.revertToState(snap);
        }
    }

    /// The anchor stays at the launch price through the trap: a range thinner than the pool's minimum dynamic fee
    /// liquidity carries it only as far as its notional pays at that minimum, under one tick here. The victim's buy
    /// has real notional and carries it to its own end price.
    function testTrapLeavesTheAnchor() public {
        PoolKey memory key = _open();
        _plant(key);
        _push(key, 16_200);
        (uint256 minLiquidity, int24 ref, int24 anchor,,,) = rules.referenceState(key.toId());
        assertEq(minLiquidity, 1e22, "launch liquidity / 100");
        assertEq(ref, 0, "the reference starts at the launch price");
        assertEq(anchor, 0, "the push leaves the anchor");
        _victim(key);
        (, int24 end,,) = manager.getSlot0(key.toId());
        (,, anchor,,,) = rules.referenceState(key.toId());
        assertApproxEqAbs(anchor, end, 1, "the victim's buy carries the anchor");
    }

    /// A deep third-party band over the launch band is real depth: the buy moves the price less and still pays a
    /// dynamic fee on that move.
    function testDeepBandOverTheLaunchBandStillPrices() public {
        PoolKey memory key = _open();
        vm.roll(vm.getBlockNumber() + 1);
        tokenA.transfer(address(dust), 1e22);
        tokenB.transfer(address(dust), 1e22);
        vm.prank(attacker);
        dust.modify(key, -60_000, 0, 1e21);
        assertGt(_quoteBuy(key, 1e23).lpFeePips, 3000, "dynamic fee still charged");
    }
}
