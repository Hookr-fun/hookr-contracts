// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {HookrDynamicFee} from "../../src/libraries/HookrDynamicFee.sol";
import {EconomicsSecurityBase, BandLp} from "../utils/EconomicsSecurityBase.sol";
import {DustRangeSwapper} from "../utils/DustRangeSwapper.sol";
import {RulesData} from "../utils/RulesData.sol";

/// @notice One unlock: an optional band add, an optional swap and an optional band removal; settles the net deltas.
contract DynamicFeeJitSwapper is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    struct Plan {
        PoolKey key;
        int24 lower;
        int24 upper;
        int256 addLiquidity;
        int256 removeLiquidity;
        bool doSwap;
        bool zeroForOne;
        int256 amount;
        uint160 limit;
    }

    struct Result {
        int256 net0;
        int256 net1;
        int128 swap0;
        int128 swap1;
        int128 fee0;
        int128 fee1;
    }

    IPoolManager internal immutable m;

    constructor(IPoolManager m_) {
        m = m_;
    }

    function run(Plan memory p) external returns (Result memory r) {
        r = abi.decode(m.unlock(abi.encode(p)), (Result));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(m));
        Plan memory p = abi.decode(data, (Plan));
        Result memory r;
        if (p.addLiquidity != 0) {
            m.modifyLiquidity(p.key, ModifyLiquidityParams(p.lower, p.upper, p.addLiquidity, 0), "");
        }
        if (p.doSwap) {
            BalanceDelta s = m.swap(p.key, SwapParams(p.zeroForOne, p.amount, p.limit), "");
            r.swap0 = s.amount0();
            r.swap1 = s.amount1();
        }
        if (p.removeLiquidity != 0) {
            (, BalanceDelta f) =
                m.modifyLiquidity(p.key, ModifyLiquidityParams(p.lower, p.upper, -p.removeLiquidity, 0), "");
            r.fee0 = f.amount0();
            r.fee1 = f.amount1();
        }
        r.net0 = m.currencyDelta(address(this), p.key.currency0);
        r.net1 = m.currencyDelta(address(this), p.key.currency1);
        _settle(p.key.currency0, r.net0);
        _settle(p.key.currency1, r.net1);
        return abi.encode(r);
    }

    function _settle(Currency c, int256 amount) private {
        if (amount < 0) {
            m.sync(c);
            IERC20(Currency.unwrap(c)).transfer(address(m), uint256(-amount));
            m.settle();
        } else if (amount > 0) {
            m.take(c, address(this), uint256(amount));
        }
    }
}

/// DF-01: attacks on Hookr dynamic fees priced on the simulated swap. Pure dynamic fee pool unless stated: base
/// 3,000, maxFee 100,000, sens 5, protocol share 2,500, launch liquidity 1e24 at spacing 60 (minimum dynamic fee
/// liquidity 1e22). With `subjectFirst` false the quote is currency0, so a buy is zeroForOne and moves the price down.
contract HookrDynamicFeeAttacksTest is EconomicsSecurityBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    bytes32 internal constant DONATE = keccak256("Donate(bytes32,address,uint256,uint256)");

    BandLp internal dust;
    DustRangeSwapper internal swapper;
    DynamicFeeJitSwapper internal jit;
    address internal attacker = address(0xBAD);
    address internal victim = address(0xB0B);

    function setUp() public override {
        super.setUp();
        dust = new BandLp(manager);
        swapper = new DustRangeSwapper(manager);
        jit = new DynamicFeeJitSwapper(manager);
        tokenA.transfer(address(dust), 1e18);
        tokenB.transfer(address(dust), 1e18);
        tokenA.transfer(address(swapper), 1e18);
        tokenB.transfer(address(swapper), 1e18);
        tokenA.transfer(address(jit), 1e28);
        tokenB.transfer(address(jit), 1e28);
        _fund(attacker);
        _fund(victim);
    }

    function _fund(address who) internal {
        tokenA.transfer(who, 1e27);
        tokenB.transfer(who, 1e27);
        vm.startPrank(who);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _open(IHookrLauncher.Member memory m, bool subjectFirst) internal returns (PoolKey memory key) {
        (key,,) = _launchMember(m, subjectFirst);
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _edgePool() internal returns (PoolKey memory key) {
        IHookrLauncher.Member memory m = _dynamicFeeMember(Currency.wrap(address(0)));
        m.tickUpper = 0;
        key = _open(m, false);
    }

    function _swapAs(address who, PoolKey memory key, bool buy, bool exactInput, uint128 amount)
        internal
        returns (HookrTypes.ExecutionReceipt memory r, uint256 input, uint256 output)
    {
        IHookrRouter.Swap memory p = _swap(key, buy, exactInput, amount);
        p.recipient = who;
        r = quoter.quote(p, who);
        vm.prank(who);
        (input, output) = router.swap(p, address(0), new uint256[](0));
        assertEq(input, r.inputAmount, "quote input");
        assertEq(output, r.outputAmount, "quote output");
    }

    function _subjectBalance(PoolKey memory key, address who) internal view returns (uint256) {
        return IERC20(Currency.unwrap(root.poolConfig(key.toId()).subject)).balanceOf(who);
    }

    function _quoteBalance(PoolKey memory key, address who) internal view returns (uint256) {
        return IERC20(Currency.unwrap(root.poolConfig(key.toId()).quote)).balanceOf(who);
    }

    /// The windows every pool uses, and the root's answer to the Rules' probe.
    function testParameters() public view {
        (uint256 window, uint256 reset, uint256 carryBps, uint256 moveTicks) = rules.dynamicFeeParameters();
        assertEq(window, 30);
        assertEq(reset, 120);
        assertEq(carryBps, 7_500);
        assertEq(moveTicks, 200);
        assertTrue(rules.rootSimulates(), "HookrRoot answers the empty call with 1");
    }

    // ------------------------------------------------------------------------------------------------------------
    // 1. Price parked in an empty gap, then a buyer after the reference window.
    // ------------------------------------------------------------------------------------------------------------

    /// A 1-wei sell parks the price beyond all liquidity, against the buy direction. After each wait (none, past the
    /// window, past the reset) the next buy pays what it pays with no push after the same wait.
    function testGapAgainstTheBuyThenBuyAfterTheWindow() public {
        uint256[3] memory waits = [uint256(0), _dynamicFeeWindow() + 1, _dynamicFeeReset() + 1];
        for (uint256 i; i < waits.length; ++i) {
            uint256 fresh = vm.snapshotState();
            PoolKey memory key = _edgePool();
            uint256 snap = vm.snapshotState();
            vm.warp(vm.getBlockTimestamp() + waits[i]);
            HookrTypes.ExecutionReceipt memory ctl = _quoteBuy(key, 1e22);
            vm.revertToState(snap);
            vm.prank(attacker);
            swapper.swap(key, false, -1, TickMath.MAX_SQRT_PRICE - 1);
            (, int24 parked,,) = manager.getSlot0(key.toId());
            assertGt(parked, 887_000, "price parked at the edge");
            vm.warp(vm.getBlockTimestamp() + waits[i]);
            HookrTypes.ExecutionReceipt memory atk = _quoteBuy(key, 1e22);
            emit log_named_uint("wait (s)", waits[i]);
            emit log_named_uint("  control LP fee", ctl.lpFeePips);
            emit log_named_uint("  after the park", atk.lpFeePips);
            assertGt(ctl.lpFeePips, 3000, "control pays a dynamic fee");
            assertApproxEqAbs(atk.lpFeePips, ctl.lpFeePips, 1, "the parked gap adds nothing");
            assertEq(atk.outputAmount, ctl.outputAmount, "same fill");
            vm.revertToState(fresh);
        }
    }

    /// The launch price sits in an empty gap 3,000 ticks above the band, so a buy first crosses the gap. A 1-wei buy
    /// carries the price across it to the band's edge; the next buyer, after each wait, pays no more than a buyer who
    /// crosses the gap itself (the gap it does not cross is not charged to it).
    function testGapAlongTheBuyThenBuyAfterTheWindow() public {
        uint256[3] memory waits = [uint256(0), _dynamicFeeWindow() + 1, _dynamicFeeReset() + 1];
        for (uint256 i; i < waits.length; ++i) {
            uint256 fresh = vm.snapshotState();
            IHookrLauncher.Member memory m = _dynamicFeeMember(Currency.wrap(address(0)));
            m.tickUpper = 0;
            m.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(3000);
            PoolKey memory key = _open(m, false);
            uint256 snap = vm.snapshotState();
            vm.warp(vm.getBlockTimestamp() + waits[i]);
            HookrTypes.ExecutionReceipt memory ctl = _quoteBuy(key, 1e22);
            vm.revertToState(snap);
            vm.prank(attacker);
            swapper.swap(key, true, -1, TickMath.getSqrtPriceAtTick(1));
            (, int24 parked,,) = manager.getSlot0(key.toId());
            assertEq(parked, 1, "price carried across the gap for free");
            vm.warp(vm.getBlockTimestamp() + waits[i]);
            HookrTypes.ExecutionReceipt memory atk = _quoteBuy(key, 1e22);
            emit log_named_uint("wait (s)", waits[i]);
            emit log_named_uint("  control LP fee (crosses the gap)", ctl.lpFeePips);
            emit log_named_uint("  after the free crossing", atk.lpFeePips);
            assertLe(atk.lpFeePips, ctl.lpFeePips, "no more than the control");
            assertGe(atk.outputAmount, ctl.outputAmount, "no less subject");
            vm.revertToState(fresh);
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // 2. Two near-free pushes through a thin range, then victims (the walk's flow saturation, F-003 residual).
    // ------------------------------------------------------------------------------------------------------------

    function _victims(PoolKey memory key, uint256 n) internal returns (uint256[] memory fees) {
        fees = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            (HookrTypes.ExecutionReceipt memory r,,) = _swapAs(victim, key, true, true, 1e21);
            fees[i] = r.lpFeePips;
        }
    }

    function _roundTrip(uint24 maxFee, uint16 sens, int256 liquidity) internal {
        IHookrLauncher.Member memory m = _dynamicFeeMember(Currency.wrap(address(0)));
        m.tickUpper = 0;
        m.rules.maxFeePips = maxFee;
        m.rules.dynamicFeeSens = sens;
        PoolKey memory key = _open(m, false);
        uint256 snap = vm.snapshotState();
        uint256[] memory ctl = _victims(key, 5);
        vm.revertToState(snap);
        uint256 before = tokenA.balanceOf(address(dust)) + tokenB.balanceOf(address(dust))
            + tokenA.balanceOf(address(swapper)) + tokenB.balanceOf(address(swapper));
        vm.startPrank(attacker);
        dust.modify(key, 60, 16_080, liquidity);
        swapper.swap(key, false, -1e18, TickMath.getSqrtPriceAtTick(16_200));
        // Exact output, so the price-limited buy reserves no quote take (an unauthenticated refund reverts).
        swapper.swap(key, true, 1e18, TickMath.getSqrtPriceAtTick(0));
        dust.modify(key, 60, 16_080, -liquidity);
        vm.stopPrank();
        uint256 cost = before
            - (tokenA.balanceOf(address(dust))
                + tokenB.balanceOf(address(dust))
                + tokenA.balanceOf(address(swapper))
                + tokenB.balanceOf(address(swapper)));
        emit log_named_uint("attacker cost (wei)", cost);
        uint256[] memory hit = _victims(key, 5);
        for (uint256 i; i < 5; ++i) {
            emit log_named_uint("  control victim LP fee", ctl[i]);
            emit log_named_uint("  pushed victim LP fee", hit[i]);
            assertApproxEqAbs(hit[i], ctl[i], 1, "the pushes add nothing");
        }
        assertLt(cost, 1e13, "near free");
    }

    function testTwoNearFreePushesThenVictims() public {
        _roundTrip(100_000, 5, 1e12);
    }

    /// At sensitivity 10, at the widest span the reach bound admits there (HookrDynamicFee.withinReach).
    function testTwoNearFreePushesThenVictimsAtTheMostSensitive() public {
        _roundTrip(uint24(3000 + RulesData.maxDynamicFeeSpan(10, 2_500, 3000)), 10, 1e12);
    }

    // ------------------------------------------------------------------------------------------------------------
    // 3. One order split into N pieces inside the window.
    // ------------------------------------------------------------------------------------------------------------

    function _split(uint256 n, uint256 gap) internal returns (uint256 out, uint256 protocolClaim) {
        uint256 snap = vm.snapshotState();
        PoolKey memory key = _open(_dynamicFeeMember(Currency.wrap(address(0))), false);
        uint128 piece = uint128(6e22 / n);
        uint256 before = _subjectBalance(key, victim);
        for (uint256 i; i < n; ++i) {
            if (i != 0) vm.warp(vm.getBlockTimestamp() + gap);
            _swapAs(victim, key, true, true, piece);
        }
        out = _subjectBalance(key, victim) - before;
        protocolClaim = rules.claimable(root.poolConfig(key.toId()).quote, protocol);
        vm.revertToState(snap);
    }

    /// A 6e22 buy (past a third of the knee) against the same buy in 2 to 30 pieces at one timestamp and spread over
    /// the reset period with no gap as long as the window:
    /// the path-average rate charges the pieces the same total, so splitting inside the window saves nothing. What
    /// remains is the simulation's lead: the one buy's exact-input simulation overstates its move by its own dynamic
    /// fee, a piece's by its smaller one, so the pieces pay up to about 0.5% less dynamic fee and gain under 0.03%.
    function testSplitInsideTheWindowSavesNothing() public {
        (uint256 oneOut, uint256 oneFee) = _split(1, 0);
        emit log_named_uint("one buy: subject out", oneOut);
        emit log_named_uint("one buy: protocol dynamic fee share", oneFee);
        uint256[4] memory ns = [uint256(2), 5, 10, 30];
        for (uint256 i; i < ns.length; ++i) {
            for (uint256 g; g < 2; ++g) {
                uint256 gap = (_dynamicFeeReset() - 1) / (ns[i] - 1);
                if (gap >= _dynamicFeeWindow()) gap = _dynamicFeeWindow() - 1;
                if (g == 0) gap = 0;
                (uint256 out, uint256 fee) = _split(ns[i], gap);
                emit log_named_uint(string.concat("pieces ", vm.toString(ns[i]), ", gap ", vm.toString(gap)), out);
                emit log_named_uint("  protocol dynamic fee share", fee);
                assertLe(out * 10_000, oneOut * 10_003, "no more subject than the single buy");
                assertGe(fee * 10_000, oneFee * 9_700, "the same dynamic fee, less the single buy's lead");
            }
        }
    }

    /// Past the window the reference steps a quarter of the way to the anchor, so a patient buyer pays less: the
    /// decay that bounds how long a move is charged.
    function testSplitAcrossWindowsDecays() public {
        (uint256 oneOut,) = _split(1, 0);
        (uint256 windowOut,) = _split(2, _dynamicFeeWindow() + 1);
        (uint256 resetOut,) = _split(2, _dynamicFeeReset() + 1);
        emit log_named_uint("one buy", oneOut);
        emit log_named_uint("two halves, one window apart", windowOut);
        emit log_named_uint("two halves, one reset apart", resetOut);
        assertGt(windowOut, oneOut, "a step lowers the second half's rate");
        assertGt(resetOut, windowOut, "a reset lowers it further");
    }

    // ------------------------------------------------------------------------------------------------------------
    // 4. Sandwich.
    // ------------------------------------------------------------------------------------------------------------

    struct Sandwich {
        uint256 victimAloneFee;
        uint256 victimAloneOut;
        uint256 frontFee;
        uint256 victimFee;
        uint256 victimOut;
        uint256 backFee;
        int256 attackerPnl;
    }

    function _sandwich(IHookrLauncher.Member memory m) internal returns (Sandwich memory s) {
        uint256 snap = vm.snapshotState();
        PoolKey memory key = _open(m, false);
        uint256 inner = vm.snapshotState();
        (HookrTypes.ExecutionReceipt memory alone,, uint256 aloneOut) = _swapAs(victim, key, true, true, 1e22);
        s.victimAloneFee = alone.lpFeePips;
        s.victimAloneOut = aloneOut;
        vm.revertToState(inner);
        uint256 quoteBefore = _quoteBalance(key, attacker);
        (HookrTypes.ExecutionReceipt memory front,, uint256 got) = _swapAs(attacker, key, true, true, 3e22);
        (HookrTypes.ExecutionReceipt memory hit,, uint256 out) = _swapAs(victim, key, true, true, 1e22);
        (HookrTypes.ExecutionReceipt memory back,,) = _swapAs(attacker, key, false, true, uint128(got));
        s.frontFee = front.lpFeePips;
        s.victimFee = hit.lpFeePips;
        s.victimOut = out;
        s.backFee = back.lpFeePips;
        s.attackerPnl = int256(_quoteBalance(key, attacker)) - int256(quoteBefore);
        vm.revertToState(snap);
    }

    /// The front-run pays the dynamic fee on its own move; the victim pays the rate from where the front-run left the
    /// price (the design's cost of memory); the back-run moves toward the reference and pays only the base fee. The
    /// same sandwich on a pool without dynamic fees nets the attacker more.
    function testSandwichCostsTheAttackerMore() public {
        IHookrLauncher.Member memory dyn = _dynamicFeeMember(Currency.wrap(address(0)));
        IHookrLauncher.Member memory flat = _dynamicFeeMember(Currency.wrap(address(0)));
        flat.rules.maxFeePips = 3000;
        flat.rules.dynamicFeeSens = 0;
        Sandwich memory d = _sandwich(dyn);
        Sandwich memory f = _sandwich(flat);
        emit log_named_uint("dynamic: victim alone LP fee", d.victimAloneFee);
        emit log_named_uint("dynamic: front-run LP fee", d.frontFee);
        emit log_named_uint("dynamic: sandwiched victim LP fee", d.victimFee);
        emit log_named_uint("dynamic: back-run LP fee", d.backFee);
        emit log_named_int("dynamic: attacker P&L (quote)", d.attackerPnl);
        emit log_named_int("flat: attacker P&L (quote)", f.attackerPnl);
        emit log_named_uint("dynamic: victim subject lost to the sandwich", d.victimAloneOut - d.victimOut);
        emit log_named_uint("flat: victim subject lost to the sandwich", f.victimAloneOut - f.victimOut);
        assertEq(d.backFee, 3000, "the back-run pays the base fee only");
        assertGt(d.frontFee, 3000, "the front-run pays for its own move");
        assertGt(d.victimFee, d.victimAloneFee, "the victim pays from where the front-run left the price");
        assertLt(d.attackerPnl, f.attackerPnl, "dynamic fees make the sandwich cost more");
    }

    // ------------------------------------------------------------------------------------------------------------
    // 5. Simulation versus execution across fee settings.
    // ------------------------------------------------------------------------------------------------------------

    struct Drift {
        uint24 maxFee;
        uint16 sens;
        bool full;
    }

    /// @dev The native LP fee HookrRules quotes for `dynamicFee` pips on a swap outside the guard.
    function _lpFee(IHookrLauncher.Member memory m, bool buy, uint256 dynamicFee) internal pure returns (uint256) {
        uint256 share = m.rules.protocolShareBps;
        uint256 base = m.config.baseLpFeePips;
        uint256 lpReward;
        if (buy) {
            uint256 lpNet = uint256(m.rules.lpBps) * 100 - (uint256(m.rules.lpBps) * share + 99) / 100;
            lpReward = lpNet - lpNet * m.rules.royaltyBps / 10_000;
        }
        uint256 room = 600_000 - base - lpReward;
        if (dynamicFee > room) dynamicFee = room;
        return base + lpReward + dynamicFee - dynamicFee * share / 10_000;
    }

    /// First swap on a fresh pool at tick 0, so the reference and the anchor are the launch price. The dynamic fee the
    /// executed swap's own end price implies is the floor; the charge may exceed it only by the simulation's lead.
    function _drift(Drift memory d, bool buy, bool exactInput, uint128 amount) internal returns (uint256 leadBps) {
        uint256 snap = vm.snapshotState();
        IHookrLauncher.Member memory m = _dynamicFeeMember(Currency.wrap(address(0)));
        m.rules.maxFeePips = d.maxFee;
        m.rules.dynamicFeeSens = d.sens;
        if (d.full) {
            m.rules.burnBps = 100;
            m.rules.lpBps = 200;
            m.rules.royaltyBps = 500;
            m.rules.royaltyTo = royalty;
        }
        PoolKey memory key = _open(m, false);
        (HookrTypes.ExecutionReceipt memory r,,) = _swapAs(victim, key, buy, exactInput, amount);
        (uint160 end,,,) = manager.getSlot0(key.toId());
        bool zeroForOne = buy;
        int256 dist = HookrDynamicFee.distance(SQRT_ONE, end, zeroForOne);
        uint256 ideal;
        if (dist > 0) {
            ideal =
                uint256(d.maxFee - 3000) * HookrDynamicFee.averageRate(0, uint256(dist), d.sens) / HookrDynamicFee.WAD;
        }
        uint256 floorFee = _lpFee(m, buy, ideal);
        uint256 baseFee = _lpFee(m, buy, 0);
        emit log_named_string(
            "shape",
            string.concat(
                buy ? "buy " : "sell ",
                exactInput ? "exact in, " : "exact out, ",
                "maxFee ",
                vm.toString(d.maxFee),
                ", sens ",
                vm.toString(d.sens),
                d.full ? ", burn + LP Rewards + royalty" : ""
            )
        );
        emit log_named_uint("  LP fee charged", r.lpFeePips);
        emit log_named_uint("  LP fee the executed end price implies", floorFee);
        assertGe(r.lpFeePips + 1, floorFee, "never below the executed move");
        leadBps = floorFee > baseFee ? (r.lpFeePips - baseFee) * 10_000 / (floorFee - baseFee) : 10_000;
        emit log_named_uint("  charged dynamic part, bps of the implied", leadBps);
        vm.revertToState(snap);
    }

    /// The widest rows are the most sensitive pool at the widest span the reach bound admits (HookrDynamicFee.withinReach).
    function testSimulationVersusExecutionAcrossFeeSettings() public {
        uint24 widest = uint24(3000 + RulesData.maxDynamicFeeSpan(10, 2_500, 3000));
        Drift[5] memory ds = [
            Drift(30_000, 1, false),
            Drift(100_000, 5, false),
            Drift(100_000, 5, true),
            Drift(widest, 10, false),
            Drift(widest, 10, true)
        ];
        for (uint256 i; i < ds.length; ++i) {
            uint256 lead = _drift(ds[i], true, true, 5e22);
            assertLe(lead, ds[i].maxFee > 100_000 ? 20_000 : 12_500, "exact-input buy lead");
            lead = _drift(ds[i], true, false, 4e22);
            assertLe(lead, 10_001, "an exact-output buy fills the simulated move");
            lead = _drift(ds[i], false, true, 5e22);
            assertLe(lead, ds[i].maxFee > 100_000 ? 20_000 : 12_500, "exact-input sell lead");
            lead = _drift(ds[i], false, false, 4e22);
            assertLe(lead, ds[i].maxFee > 100_000 ? 20_000 : 12_500, "exact-output sell lead");
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // 6. Collection: LP fee override, no donation, no capture by a band the swap does not trade in.
    // ------------------------------------------------------------------------------------------------------------

    function testDynamicFeeNeverDonates() public {
        PoolKey memory key = _open(_dynamicFeeMember(Currency.wrap(address(0))), true);
        vm.recordLogs();
        (HookrTypes.ExecutionReceipt memory r,,) = _swapAs(victim, key, true, true, 5e22);
        assertGt(r.lpFeePips, 3000);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertFalse(logs[i].emitter == address(manager) && logs[i].topics[0] == DONATE, "no donation");
        }
    }

    /// A deep band added just past where the swap ends and removed in the same unlock earns nothing: the LP fee
    /// accrues per step to the liquidity the swap trades, and the swap trades nothing in the band. (Against the
    /// donation design a band past the limit recovered 99.8% of the swapper's own LP share.) Unauthenticated swaps,
    /// so the two shapes that reserve no quote take: an exact-output buy (price down) and an exact-input sell (up).
    function testSelfBandPastTheEndEarnsNothing() public {
        PoolKey memory key = _open(_dynamicFeeMember(Currency.wrap(address(0))), false);
        bool[2] memory zeroForOne = [true, false];
        int256[2] memory amounts = [int256(4e22), -5e22];
        for (uint256 i; i < 2; ++i) {
            DynamicFeeJitSwapper.Plan memory p;
            p.key = key;
            p.doSwap = true;
            p.zeroForOne = zeroForOne[i];
            p.amount = amounts[i];
            p.limit = zeroForOne[i] ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
            uint256 snap = vm.snapshotState();
            DynamicFeeJitSwapper.Result memory plain = jit.run(p);
            (, int24 endTick,,) = manager.getSlot0(key.toId());
            vm.revertToState(snap);
            int24 c = endTick / 60;
            if (endTick < 0 && endTick % 60 != 0) --c;
            (p.lower, p.upper) = zeroForOne[i] ? (c * 60 - 60, c * 60) : (c * 60 + 60, c * 60 + 120);
            p.addLiquidity = 1e27;
            p.removeLiquidity = 1e27;
            DynamicFeeJitSwapper.Result memory banded = jit.run(p);
            vm.revertToState(snap);
            assertEq(banded.swap0, plain.swap0, "same swap");
            assertEq(banded.swap1, plain.swap1, "same swap");
            assertEq(banded.fee0 + banded.fee1, 0, "the band earns nothing");
            // Adding and removing the band costs its owner one wei of rounding; it returns nothing.
            assertLe(banded.net0, plain.net0, "no rebate");
            assertLe(banded.net1, plain.net1, "no rebate");
        }
    }

    /// A deep band placed on the victim's end price before it trades is real depth: the victim moves the price less,
    /// pays no more dynamic fee and gets no less subject; the band earns only on the volume it fills.
    function testThirdPartyBandAtTheVictimsEndPrice() public {
        PoolKey memory key = _open(_dynamicFeeMember(Currency.wrap(address(0))), false);
        uint256 snap = vm.snapshotState();
        (HookrTypes.ExecutionReceipt memory ctl,, uint256 ctlOut) = _swapAs(victim, key, true, true, 3e22);
        (, int24 endTick,,) = manager.getSlot0(key.toId());
        vm.revertToState(snap);
        int24 lower = (endTick < 0 && endTick % 60 != 0 ? endTick / 60 - 1 : endTick / 60) * 60;
        DynamicFeeJitSwapper.Plan memory add;
        add.key = key;
        add.lower = lower;
        add.upper = lower + 60;
        add.addLiquidity = 1e27;
        jit.run(add);
        (HookrTypes.ExecutionReceipt memory hit,, uint256 out) = _swapAs(victim, key, true, true, 3e22);
        emit log_named_uint("control LP fee", ctl.lpFeePips);
        emit log_named_uint("banded LP fee", hit.lpFeePips);
        assertLe(hit.lpFeePips, ctl.lpFeePips, "no more dynamic fee");
        assertGe(out, ctlOut, "no less subject");
    }

    // ------------------------------------------------------------------------------------------------------------
    // 7. Native quote and dust swaps.
    // ------------------------------------------------------------------------------------------------------------

    /// Each shape on a fresh native-quote pool: the quote matches the execution, the first move pays a dynamic fee,
    /// the claims stay backed and the protocol claims ETH.
    function testNativeQuoteAllShapes() public {
        bool[2] memory flags = [true, false];
        for (uint256 i; i < 2; ++i) {
            for (uint256 j; j < 2; ++j) {
                uint256 snap = vm.snapshotState();
                IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
                members[0] = _dynamicFeeMember(Currency.wrap(address(0)));
                (bytes32 family,) = launcher.launch{value: 1e24}(
                    IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)),
                    address(root),
                    members,
                    vm.getBlockTimestamp()
                );
                PoolKey memory key = launcher.position(family, 0).key;
                assertTrue(CurrencyLibrary.isAddressZero(key.currency0));
                vm.roll(vm.getBlockNumber() + 1);
                bool buy = flags[i];
                bool exactInput = flags[j];
                IHookrRouter.Swap memory p = _swap(key, buy, exactInput, 5e22);
                HookrTypes.ExecutionReceipt memory q = quoter.quote(p, trader);
                uint256 value = buy ? (exactInput ? 5e22 : 1e25) : 0;
                vm.prank(trader);
                (uint256 input, uint256 output) = router.swap{value: value}(p, address(0), new uint256[](0));
                assertEq(q.inputAmount, input, "quote input");
                assertEq(q.outputAmount, output, "quote output");
                assertGt(q.lpFeePips, 3000, "dynamic fee charged");
                assertTrue(rules.accountingInvariant(key.currency0) && rules.accountingInvariant(key.currency1));
                uint256 claim = rules.claimable(key.currency0, protocol);
                if (claim != 0) {
                    uint256 before = protocol.balance;
                    vm.prank(protocol);
                    rules.claim(key.currency0);
                    assertEq(protocol.balance - before, claim, "protocol claims ETH");
                }
                vm.revertToState(snap);
            }
        }
    }

    function testOneWeiSwapsSettle() public {
        PoolKey memory key = _open(_dynamicFeeMember(Currency.wrap(address(0))), false);
        bool[2] memory flags = [true, false];
        for (uint256 i; i < 2; ++i) {
            for (uint256 j; j < 2; ++j) {
                DynamicFeeJitSwapper.Plan memory p;
                p.key = key;
                p.doSwap = true;
                p.zeroForOne = flags[i];
                p.amount = flags[j] ? -1 : int256(1);
                p.limit = flags[i] ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
                jit.run(p);
            }
        }
        (,, int24 anchor, uint40 movedAt,,) = rules.referenceState(key.toId());
        assertEq(anchor, 0, "dust swaps leave the anchor");
        assertGt(movedAt, 0, "started");
    }

    // ------------------------------------------------------------------------------------------------------------
    // 8. Ports of the realized design's PoCs (verify6 ZZ_R5RealizedAttack).
    // ------------------------------------------------------------------------------------------------------------

    /// Two near-free pushes plus a deep band standing at the current price: under the walk's per-block flow, every
    /// later buy paid the full span and its LP share landed on the band. Here each buy pays what it pays in a quiet
    /// pool, and the band earns only its share of those fees.
    function testPushesPlusStandingBandCaptureNothingExtra() public {
        PoolKey memory key = _edgePool();
        DynamicFeeJitSwapper.Plan memory add;
        add.key = key;
        add.lower = -60;
        add.upper = 0;
        add.addLiquidity = 1e26;
        jit.run(add);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 snap = vm.snapshotState();
        uint256[] memory quiet = _victims(key, 5);
        DynamicFeeJitSwapper.Plan memory rem = add;
        rem.addLiquidity = 0;
        rem.removeLiquidity = 1e26;
        DynamicFeeJitSwapper.Result memory quietBand = jit.run(rem);
        vm.revertToState(snap);
        vm.startPrank(attacker);
        dust.modify(key, 60, 16_080, 1e12);
        swapper.swap(key, false, -1e18, TickMath.getSqrtPriceAtTick(16_200));
        swapper.swap(key, true, 1e18, TickMath.getSqrtPriceAtTick(0));
        dust.modify(key, 60, 16_080, -1e12);
        vm.stopPrank();
        uint256[] memory pushed = _victims(key, 5);
        DynamicFeeJitSwapper.Result memory pushedBand = jit.run(rem);
        for (uint256 i; i < 5; ++i) {
            assertApproxEqAbs(pushed[i], quiet[i], 1, "the pushes add nothing");
        }
        emit log_named_int("band fees, quiet (quote)", quietBand.fee0);
        emit log_named_int("band fees, after the pushes (quote)", pushedBand.fee0);
        assertLe(pushedBand.fee0, quietBand.fee0 + int128(int256(2e12)), "no extra capture");
    }

    /// A liquidity-1 band over everything above the launch band, and a sell past the launch band's edge: the band
    /// earns fees only on the dust it fills, never the dynamic fee the sell paid on the launch band's volume. (Against
    /// the donation design it took the whole LP share.)
    function testDustAtTheEndTakesNothing() public {
        PoolKey memory key = _edgePool();
        _buyAs(trader, key, 1e22);
        vm.roll(vm.getBlockNumber() + 1);
        DynamicFeeJitSwapper.Plan memory add;
        add.key = key;
        add.lower = 0;
        add.upper = TickMath.maxUsableTick(60);
        add.addLiquidity = 1;
        jit.run(add);
        IHookrRouter.Swap memory p = _swap(key, false, true, 5e22);
        p.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(6000);
        HookrTypes.ExecutionReceipt memory r = quoter.quote(p, trader);
        vm.prank(trader);
        router.swap(p, address(0), new uint256[](0));
        DynamicFeeJitSwapper.Plan memory rem = add;
        rem.addLiquidity = 0;
        rem.removeLiquidity = 1;
        DynamicFeeJitSwapper.Result memory fees = jit.run(rem);
        emit log_named_uint("sell LP fee", r.lpFeePips);
        emit log_named_int("liquidity-1 band fees (subject, the sell's input)", fees.fee1);
        assertGt(r.lpFeePips, 3000, "the sell paid a dynamic fee");
        assertLe(fees.fee1, 1, "the band earns nothing on the launch band's volume");
    }
}
