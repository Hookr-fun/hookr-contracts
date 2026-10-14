// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {EconomicsSecurityBase, BandLp} from "../utils/EconomicsSecurityBase.sol";
import {DustRangeSwapper} from "../utils/DustRangeSwapper.sol";
import {RulesData} from "../utils/RulesData.sol";

/// DF-03: the tick layouts built against the walk (verify3 ZZ_WalkGas and ZZ_VerifyMinLiq, verify6 ZZ_V6Attack): dust
/// ticks inside the launch band, dust bands with gaps past its edge, a dust tick at every bitmap word edge, 32
/// disjoint and 64 nested dust ranges, and a wide range one wei under the pool's minimum dynamic fee liquidity. Each
/// buy fills, pays what it pays with no layout, and costs the swap's own tick crossings twice (the simulation and
/// the swap): there is no step limit, no fail-closed charge and no read-ahead.
contract HookrDynamicFeeLayoutsTest is EconomicsSecurityBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    int24 internal constant WORD = 4096;

    BandLp internal dust;
    DustRangeSwapper internal swapper;
    address internal attacker = address(0xBAD);

    function setUp() public override {
        super.setUp();
        dust = new BandLp(manager);
        swapper = new DustRangeSwapper(manager);
        tokenA.transfer(address(dust), 1e24);
        tokenB.transfer(address(dust), 1e24);
        tokenA.transfer(address(swapper), 1e24);
        tokenB.transfer(address(swapper), 1e24);
    }

    /// @dev A pure dynamic fee pool with band [lower, upper), price at `priceTick`, sensitivity `sens`.
    function _openAt(
        bool subjectFirst,
        int24 spacing,
        uint16 sens,
        int24 lower,
        int24 upper,
        int24 priceTick,
        uint128 liquidity
    ) internal returns (PoolKey memory key) {
        IHookrLauncher.Member memory m = _dynamicFeeMember(Currency.wrap(address(0)));
        m.tickSpacing = spacing;
        m.rules.dynamicFeeSens = sens;
        // The default span, or the widest the reach bound admits at `sens` where that is smaller.
        RulesData.clampToReach(m.rules, 3000);
        m.liquidity = liquidity;
        m.tickLower = lower;
        m.tickUpper = upper;
        m.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(priceTick);
        (key,,) = _launchMember(m, subjectFirst);
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// @dev Buys `amount` through the router: the LP fee, the subject out and the gas of the router call.
    function _buy(PoolKey memory key, uint128 amount) internal returns (uint256 fee, uint256 out, uint256 gasUsed) {
        IHookrRouter.Swap memory p = _swap(key, true, true, amount);
        fee = quoter.quote(p, trader).lpFeePips;
        vm.prank(trader);
        uint256 g = gasleft();
        (, out) = router.swap(p, address(0), new uint256[](0));
        gasUsed = g - gasleft();
    }

    struct Layout {
        uint256 ctlFee;
        uint256 ctlOut;
        uint256 ctlGas;
        uint256 fee;
        uint256 out;
        uint256 gasUsed;
    }

    function _report(string memory label, Layout memory l) internal {
        emit log(label);
        emit log_named_uint("  control LP fee", l.ctlFee);
        emit log_named_uint("  layout LP fee", l.fee);
        emit log_named_uint("  control router gas", l.ctlGas);
        emit log_named_uint("  layout router gas", l.gasUsed);
        assertApproxEqAbs(l.fee, l.ctlFee, 1, "the layout adds no dynamic fee");
        assertGe(l.out * 1000, l.ctlOut * 999, "the buy fills as in the control");
    }

    /// verify3 ZZ_WalkGas: the launch band's price edge at +-144,912, spacing 16, sensitivity 10; `mode` 0 puts 70
    /// one-spacing dust bands inside the band next to the price, `mode` 1 puts 32 dust bands with one-spacing gaps
    /// just past the edge. A one-wei swap then parks the price at the far end of the tick range.
    function _walkLayout(bool subjectFirst, uint256 mode, uint128 amount) internal returns (Layout memory l) {
        int24 top = subjectFirst ? int24(144_912) : int24(-144_912);
        PoolKey memory key = subjectFirst
            ? _openAt(true, 16, 10, top, top + 60_000, top, 1e24)
            : _openAt(false, 16, 10, top - 60_000, top, top, 1e24);
        uint256 snap = vm.snapshotState();
        (l.ctlFee, l.ctlOut, l.ctlGas) = _buy(key, amount);
        vm.revertToState(snap);
        vm.startPrank(attacker);
        if (mode == 0) {
            for (int24 i; i < 70; ++i) {
                if (subjectFirst) dust.modify(key, top + 16 * i, top + 16 * (i + 1), 1);
                else dust.modify(key, top - 16 * (i + 1), top - 16 * i, 1);
            }
        } else {
            for (int24 i; i < 32; ++i) {
                if (subjectFirst) dust.modify(key, top - 16 * (2 * i + 2), top - 16 * (2 * i + 1), 1);
                else dust.modify(key, top + 16 * (2 * i + 1), top + 16 * (2 * i + 2), 1);
            }
        }
        if (subjectFirst) swapper.swap(key, true, -1, TickMath.MIN_SQRT_PRICE + 1);
        else swapper.swap(key, false, -1, TickMath.MAX_SQRT_PRICE - 1);
        vm.stopPrank();
        vm.roll(vm.getBlockNumber() + 1);
        (l.fee, l.out, l.gasUsed) = _buy(key, amount);
    }

    function testDustInsideTheBandBothOrientations() public {
        uint256 snap = vm.snapshotState();
        _report("zeroForOne buys, 70 dust ticks in the band, 5e23 buy", _walkLayout(false, 0, 5e23));
        vm.revertToState(snap);
        _report("oneForZero buys, 70 dust ticks in the band, 5e23 buy", _walkLayout(true, 0, 5e23));
    }

    function testDustPastTheEdgeBothOrientations() public {
        uint256 snap = vm.snapshotState();
        _report("zeroForOne buys, 32 thin crossings past the edge, 1e18 buy", _walkLayout(false, 1, 1e18));
        vm.revertToState(snap);
        _report("oneForZero buys, 32 thin crossings past the edge, 1e18 buy", _walkLayout(true, 1, 1e18));
    }

    /// verify6 ZZ_V6Attack: a dust band from the lowest tick of each of 65 bitmap words above the price to the next,
    /// then the price parked at the top of the tick range; the buy crosses every one of them, and the empty words
    /// above them, before it reaches the band. (The PoC ran 151 words from tick 0, where no buy fills.)
    function testDustTickAtEveryWordEdge() public {
        PoolKey memory key = _openAt(false, 16, 10, -60_000, 0, 0, 1e24);
        Layout memory l;
        uint256 snap = vm.snapshotState();
        (l.ctlFee, l.ctlOut, l.ctlGas) = _buy(key, 1e21);
        vm.revertToState(snap);
        vm.startPrank(attacker);
        for (int24 w; w < 65; ++w) {
            dust.modify(key, w * WORD, (w + 1) * WORD, 1);
        }
        swapper.swap(key, false, -1e20, TickMath.MAX_SQRT_PRICE - 1);
        vm.stopPrank();
        vm.roll(vm.getBlockNumber() + 1);
        (l.fee, l.out, l.gasUsed) = _buy(key, 1e21);
        _report("zeroForOne buys, a dust band at every word edge of 65 words, 1e21 buy", l);
    }

    /// verify6 ZZ_V6Attack residual: 32 disjoint one-spacing dust bands, or 64 nested ranges sharing one upper
    /// tick, above the price, and a near-free push to the top of the tick range.
    function _trapBands(int24 spacing, uint16 sens, uint256 mode) internal returns (Layout memory l) {
        PoolKey memory key = _openAt(false, spacing, sens, -(60_000 / spacing) * spacing, 0, 0, 1e24);
        uint256 snap = vm.snapshotState();
        (l.ctlFee, l.ctlOut, l.ctlGas) = _buy(key, 1e21);
        vm.revertToState(snap);
        vm.startPrank(attacker);
        if (mode == 0) {
            for (int24 i; i < 32; ++i) {
                int24 lo = spacing * (2 * i + 1);
                dust.modify(key, lo, lo + spacing, 1);
            }
        } else {
            for (int24 i; i < 64; ++i) {
                dust.modify(key, spacing * (i + 1), spacing * 66, 1);
            }
        }
        swapper.swap(key, false, -1e6, TickMath.MAX_SQRT_PRICE - 1);
        vm.stopPrank();
        vm.roll(vm.getBlockNumber() + 1);
        (l.fee, l.out, l.gasUsed) = _buy(key, 1e21);
    }

    function testDisjointAndNestedDustRanges() public {
        uint256 snap = vm.snapshotState();
        _report("spacing 60 sens 5, 32 disjoint bands", _trapBands(60, 5, 0));
        vm.revertToState(snap);
        _report("spacing 60 sens 5, 64 nested ranges", _trapBands(60, 5, 1));
        vm.revertToState(snap);
        _report("spacing 16 sens 10, 32 disjoint bands", _trapBands(16, 10, 0));
        vm.revertToState(snap);
        _report("spacing 16 sens 10, 64 nested ranges", _trapBands(16, 10, 1));
    }

    /// verify6 ZZ_V6Attack thin read-ahead: a wide range over the whole tick range one wei under the pool's minimum
    /// dynamic fee liquidity and at the minimum: a small sell pays and costs the same in both.
    function testWideRangeAroundTheMinimum() public {
        int256[2] memory depths = [int256(1e22 - 1), 1e22];
        uint256[2] memory fees;
        for (uint256 i; i < 2; ++i) {
            uint256 snap = vm.snapshotState();
            PoolKey memory key = _openAt(false, 16, 10, -(60_000 / 16) * 16, 0, 0, 1e24);
            vm.prank(attacker);
            dust.modify(key, TickMath.minUsableTick(16), TickMath.maxUsableTick(16), depths[i]);
            IHookrRouter.Swap memory p = _swap(key, false, true, 1e15);
            fees[i] = quoter.quote(p, trader).lpFeePips;
            vm.prank(trader);
            uint256 g = gasleft();
            router.swap(p, address(0), new uint256[](0));
            emit log_named_int("wide range liquidity", depths[i]);
            emit log_named_uint("  small sell LP fee", fees[i]);
            emit log_named_uint("  small sell router gas", g - gasleft());
            vm.revertToState(snap);
        }
        assertEq(fees[0], fees[1], "one wei under the minimum changes nothing");
    }
}
