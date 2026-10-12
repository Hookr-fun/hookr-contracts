// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrRules} from "../../src/interfaces/IHookrRules.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {HookrTreasury} from "../../src/support/HookrTreasury.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {LaneFixture} from "./LaneFixture.sol";
import {ScriptedExecutor} from "./mocks/ScriptedExecutor.sol";
import {RulesData} from "../utils/RulesData.sol";
import {IHookrRecaptureEvents} from "../../src/interfaces/IHookrRecaptureEvents.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";
import {IHookrRulesEvents} from "../../src/interfaces/IHookrRulesEvents.sol";

/// @notice Hookr's cut of an arb recapture: exactly 25% of the realized profit (RECAPTURE_PROTOCOL_BPS), on every pool
///         whatever its protocolShareBps, never split with an integrator. The lane partner keeps its share of the
///         profit (WTH: 25%, the registry's most) and pushes the rest; the root reads the profit back from the push at
///         the pool's frozen partner share, push x 10,000 / (10,000 - partnerBps), whatever the executor's call
///         returns. The rest of the push splits per pool as configured (trader, pot, LPs). With the default trader
///         share a profit P splits WTH 25%, Hookr 25%, trader 12.5% and LPs 37.5%; with no trader the LPs take 50%.
///         These suites open the lane at WTH's 25%, as the release does.
contract ArbRecaptureCutTest is LaneFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    address internal constant INTEGRATOR = address(0x1A7E);
    uint256 internal constant P = 1e18;
    /// @dev WTH's partner share: the lane opens at it and the scripted executor keeps it.
    uint16 internal constant WTH_BPS = 2_500;
    /// @dev What WTH pushes of P: 75%.
    uint256 internal constant PUSHED = P - P * WTH_BPS / 10_000;

    ScriptedExecutor internal exec;
    HookrTreasury internal treasury;

    function setUp() public {
        _setUpLane();
        // The release pays a HookrTreasury, which lists the integrators: these suites' Rules pay one.
        treasury = new HookrTreasury(address(this), address(0x7A7), manager);
        HookrRules r2 = new HookrRules(manager, registry, address(treasury), address(root), 2_000);
        IHookrRegistry.Admission memory a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.RULES,
            implementation: address(r2),
            codeHash: address(r2).codehash,
            schemaHash: r2.configSchemaHash(),
            caps: HookrTypes.Caps(600_000, 200_000, 1000),
            gasLimit: 2_000_000,
            phaseMask: 3,
            feeOnly: false,
            failOpen: false
        });
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
        treasury.admitSource(address(r2));
        rules = r2;
        protocol = address(treasury);
        treasury.proposeIntegrator(INTEGRATOR, 5_000);
        vm.warp(vm.getBlockTimestamp() + treasury.TERMS_DELAY());
        treasury.acceptIntegrator(INTEGRATOR);
        exec = new ScriptedExecutor(manager);
        vm.deal(address(exec), 1e30);
        tokenB.transfer(address(exec), 1e27);
        exec.setRoot(address(root));
        exec.setKeepBps(WTH_BPS);
        _openLane(address(exec), LANE_GAS, WTH_BPS);
    }

    function _rc(uint16 traderBps, uint16 potBps) internal pure returns (HookrTypes.RecaptureConfig memory rc) {
        rc.on = true;
        rc.traderBps = traderBps;
        rc.lpBps = 10_000 - traderBps - potBps;
        rc.releaseBlocks = RELEASE;
        if (potBps != 0) {
            rc.period = PERIOD;
            rc.maxPrizeBps = 1;
            rc.potReleaseBps = 5_000;
            rc.minBuyQuote = MIN_BUY;
        }
    }

    function _pool(uint16 share, uint16 traderBps, uint16 potBps, address integrator)
        internal
        returns (PoolKey memory)
    {
        HookrTypes.RulesConfig memory r;
        r.maxFeePips = BASE_FEE;
        r.protocolShareBps = share;
        r.integrator = integrator;
        if (potBps != 0) {
            r.lpBps = KOTH_LP_REWARDS;
            r.potBps = potBps;
        }
        return _openPool(ETH, r, _rc(traderBps, potBps));
    }

    /// @dev One arb recapture split as the root asks for it: a push of `amount` for a reported `profit`, the trader's
    ///      basis covering the push.
    function _settle(PoolKey memory key, address trader, uint256 amount, uint256 profit)
        internal
        returns (Splits memory t)
    {
        vm.recordLogs();
        vm.prank(address(root));
        assertEq(_recap().settleRecapture(key, ETH, trader, amount, amount, profit), amount);
        t = _splits(vm.getRecordedLogs());
        assertEq(t.reported, profit, "the split reports the profit it was given");
    }

    /// The agreed split for a profit P with WTH keeping its 25% (push 75%) and the default 25% trader share: Hookr
    /// 25%, trader 12.5%, LPs 37.5%, on rule shares 2,000 / 2,500 / 3,333 / 5,000 alike; without a trader the LPs take
    /// 50%. Per 1 ETH: WTH 0.25, Hookr 0.25, trader 0.125, LPs 0.375 (0.50 with no trader).
    function test_arbRecap_hookrTakesTwentyFivePercentOfProfitOnEveryShare() public {
        uint16[4] memory shares = [uint16(2_000), 2_500, 3_333, 5_000];
        assertEq(P, 1 ether, "per 1 ETH of profit");
        assertEq(PUSHED, 0.75 ether, "WTH keeps 0.25 and pushes 0.75");
        for (uint256 i; i < shares.length; ++i) {
            PoolKey memory key = _pool(shares[i], 2_500, 0, address(0));
            uint256 before = rules.claimable(ETH, protocol);
            Splits memory t = _settle(key, whale, PUSHED, P);
            assertEq(t.protocol, 0.25 ether, "Hookr: 25% of the profit");
            assertEq(t.trader, 0.125 ether, "trader: 12.5% of the profit");
            assertEq(t.lp, 0.375 ether, "LPs: 37.5% of the profit");
            assertEq(t.pot, 0);
            assertEq(rules.claimable(ETH, protocol) - before, 0.25 ether);
            t = _settle(key, address(0), PUSHED, P);
            assertEq(t.protocol, 0.25 ether);
            assertEq(t.trader, 0);
            assertEq(t.lp, 0.5 ether, "no trader: LPs 50% of the profit");
        }
    }

    /// Any profit P through a lane at the 2,500 cap with the default 25% trader share: WTH keeps floor(P x 25%) and
    /// pushes the rest, the root reads the profit back from the push (P, or one wei above it), and the push splits
    /// Hookr 25%, trader 12.5% and LPs 37.5% of P (50% with no trader), each to a few wei of rounding.
    function testFuzz_arbRecap_twentyFiveTwentyFiveFifty(uint256 profit) public {
        profit = bound(profit, 1e6, 1e30);
        PoolKey memory key = _pool(2_000, 2_500, 0, address(0));
        uint256 kept = profit * WTH_BPS / 10_000;
        uint256 pushed = profit - kept;
        uint256 reported = pushed * 10_000 / (10_000 - WTH_BPS);
        assertApproxEqAbs(reported, profit, 1, "the push reads back as P");
        Splits memory t = _settle(key, whale, pushed, reported);
        assertApproxEqAbs(kept, profit / 4, 1, "WTH: 25%");
        assertApproxEqAbs(t.protocol, profit / 4, 1, "Hookr: 25%");
        assertApproxEqAbs(t.trader, profit / 8, 2, "trader: 12.5%");
        assertApproxEqAbs(t.lp, profit * 3 / 8, 3, "LPs: 37.5%");
        assertEq(kept + t.protocol + t.trader + t.lp + t.pot, profit, "the four legs are the whole profit");
        t = _settle(key, address(0), pushed, reported);
        assertApproxEqAbs(t.protocol, profit / 4, 1, "Hookr: 25%, no trader");
        assertEq(t.trader, 0);
        assertApproxEqAbs(t.lp, profit / 2, 2, "no trader: LPs 50%");
        assertEq(kept + t.protocol + t.lp, profit);
    }

    /// A lane opened below the cap, at 1,500: the partner keeps 15% of a profit P and pushes 85%, and Hookr still takes
    /// 25% of P. Per 1 ETH with the default 25% trader share: the partner 0.15, Hookr 0.25, the trader 0.15 and the
    /// LPs 0.45 (0.60 with no trader).
    function test_arbRecap_aLowerPartnerShareStillGivesHookrTwentyFivePercent() public {
        PoolKey memory key = _pool(2_000, 2_500, 0, address(0));
        Splits memory t = _settle(key, whale, 0.85 ether, 1 ether);
        assertEq(t.protocol, 0.25 ether, "Hookr: 0.25");
        assertEq(t.trader, 0.15 ether, "trader: 0.15");
        assertEq(t.lp, 0.45 ether, "LPs: 0.45");
        t = _settle(key, address(0), 0.85 ether, 1 ether);
        assertEq(t.protocol, 0.25 ether);
        assertEq(t.lp, 0.6 ether, "no trader: LPs 0.60");
    }

    /// Any profit, push, share and knobs: Hookr takes floor(profit x 25%), at most the push; the trader
    /// traderBps of the rest, the pot potBps of it, the LPs the remainder; the legs sum to the push.
    function testFuzz_arbRecap_exactSplit(uint256 profit, uint256 amount, uint16 share, uint16 traderBps, uint16 potBps)
        public
    {
        amount = bound(amount, 1, 1e30);
        profit = bound(profit, 0, 2e31);
        share = uint16(bound(share, 2_000, 5_000));
        traderBps = uint16(bound(traderBps, 0, 5_000));
        potBps = uint16(bound(potBps, 0, 5_000));
        if (potBps != 0) share = 5_000; // room for a prize of one basis point on 4% LP Rewards
        PoolKey memory key = _pool(share, traderBps, potBps, address(0));
        Splits memory t = _settle(key, whale, amount, profit);
        uint256 pro = profit * 2_500 / 10_000 < amount ? profit * 2_500 / 10_000 : amount;
        uint256 rest = amount - pro;
        assertEq(t.protocol, pro);
        assertEq(t.trader, rest * traderBps / 10_000);
        assertEq(t.pot, rest * potBps / 10_000);
        assertEq(t.trader + t.pot + t.lp + t.protocol, amount);
    }

    /// End to end through the lane at WTH's 25%: the executor keeps 25% of P and pushes 75%, the root reads P back from
    /// the push, and every phase pays Hookr 25% of P, whatever the pool's rule share.
    function test_arbRecap_throughTheLaneWithThePartnersShareKept() public {
        PoolKey memory low = _pool(2_000, 2_500, 0, address(0));
        PoolKey memory high = _pool(5_000, 2_500, 0, address(0));
        exec.set(ScriptedExecutor.Mode.PUSH_NET, P);
        vm.recordLogs();
        _buy(low, ETH, whale, 1e18);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertEq(o.succeeded, 2);
        vm.recordLogs();
        _buy(high, ETH, whale, 1e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Splits memory t = _splits(logs);
        o = _outcome(logs);
        assertEq(o.pushedBefore, PUSHED, "75% pushed");
        assertEq(o.profitBefore, P, "P read back from the push");
        assertEq(o.profitAfter, P);
        assertEq(t.count, 2);
        assertEq(t.protocol, 2 * (25 * P / 100), "Hookr: 25% of each profit");
        assertEq(t.trader + t.lp, 2 * (50 * P / 100), "the rest of the push to trader and LPs");
        assertEq(manager.balanceOf(address(rules), ETH.toId()) >= rules.totalLiability(ETH), true, "backed");
    }

    /// The arb recapture cut is never split with an integrator: on a pool that names one, a push pays Hookr its 25%
    /// and the integrator nothing, while the same pool's rule fees pay the integrator its rate of Hookr's share.
    function test_arbRecap_neverSplitWithTheIntegrator() public {
        PoolKey memory key = _pool(5_000, 2_500, 4_000, INTEGRATOR);
        (, uint16 rate) = rules.integration(key.toId());
        assertEq(rate, 5_000);
        uint256 hookr = rules.claimable(ETH, protocol);
        Splits memory t = _settle(key, whale, PUSHED, P);
        assertEq(t.protocol, 25 * P / 100);
        assertEq(rules.claimable(ETH, protocol) - hookr, 25 * P / 100, "the whole cut to Hookr");
        assertEq(rules.claimable(ETH, INTEGRATOR), 0, "nothing of it to the integrator");
        // A buy on the same pool pays LP Rewards: the integrator takes half of Hookr's share of them.
        exec.set(ScriptedExecutor.Mode.NOTHING, 0);
        hookr = rules.claimable(ETH, protocol);
        _buy(key, ETH, whale, 1e18);
        uint256 kept = rules.claimable(ETH, protocol) - hookr;
        uint256 cut = rules.claimable(ETH, INTEGRATOR);
        assertGt(cut, 0);
        assertEq(cut, (kept + cut) / 2);
    }

    /// King of the Pool's prize bound counts what Hookr keeps after the pool's integrator: at a 25% rule share on 4%
    /// LP Rewards the widest prize is 50 bps without an integrator and 25 bps with one at 50%.
    function test_koth_prizeBoundCountsTheIntegratorsPart() public {
        HookrTypes.RulesConfig memory r = _laneRules(true);
        HookrTypes.RecaptureConfig memory rc = _kothRc();
        assertEq(rc.maxPrizeBps, 50);
        _openPool(ETH, r, rc);
        r.integrator = INTEGRATOR;
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _laneMember(ETH, r, rc);
        HookrToken s = _newSubject();
        vm.expectRevert(
            abi.encodeWithSelector(
                IHookrRootEvents.ModuleCallReverted.selector,
                address(rules),
                IHookrRules.bind.selector,
                abi.encodeWithSelector(IHookrRecaptureEvents.PrizeAboveBound.selector, 50, 25)
            )
        );
        vm.prank(creator);
        launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(s), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        // Called as the root binds, the refusal names the prize and the kept share's bound.
        rc.maxPrizeBps = 50;
        PoolKey memory k = _bindingKey(s);
        HookrTypes.PoolConfig memory pc = members[0].config;
        (pc.subject, pc.quote, pc.liquidityOwner) = (Currency.wrap(address(s)), ETH, address(this));
        vm.mockCall(address(root), abi.encodeWithSignature("bindingPool()"), abi.encode(k.toId()));
        vm.prank(address(root));
        vm.expectRevert(abi.encodeWithSelector(IHookrRecaptureEvents.PrizeAboveBound.selector, 50, 25));
        rules.bind(k, pc, RulesData.lane(r, 0, rc));
        vm.clearMockedCalls();
        rc.maxPrizeBps = 25;
        _openPool(ETH, r, rc);
    }

    /// @dev The key a native-quoted pool of `s` gets on the root.
    function _bindingKey(HookrToken s) internal view returns (PoolKey memory) {
        return PoolKey(ETH, Currency.wrap(address(s)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(root)));
    }

    /// prizeBoundFor is the widest prize the bind admits for a pool naming an integrator at its rate: 25 bps at a 25%
    /// share on 4% LP Rewards with an integrator at 5,000 (where prizeBound on the full share says 50, which the bind
    /// refuses), and prizeBound on the full share at a zero rate.
    function test_koth_prizeBoundForTheIntegratorsRate() public {
        assertEq(_recap().prizeBoundFor(400, 0, 2_500, 5_000), 25);
        assertEq(_recap().prizeBoundFor(400, 0, 2_500, 0), _recap().prizeBound(400, 0, 2_500));
        HookrTypes.RulesConfig memory r = _laneRules(true);
        r.integrator = INTEGRATOR;
        HookrTypes.RecaptureConfig memory rc = _kothRc();
        rc.maxPrizeBps = uint16(_recap().prizeBoundFor(r.lpBps, r.burnBps, r.protocolShareBps, 5_000));
        _openPool(ETH, r, rc);
    }

    /// prizeBoundFor(lp, burn, share, rate) is prizeBound on the kept share, share x (10,000 - rate) / 10,000 rounded
    /// down, the share the bind checks.
    function testFuzz_koth_prizeBoundForIsTheKeptShare(uint16 lp, uint16 burn, uint16 share, uint16 rate) public view {
        lp = uint16(bound(lp, 0, 1_000));
        burn = uint16(bound(burn, 0, 1_000 - lp));
        share = uint16(bound(share, 0, 5_000));
        rate = uint16(bound(rate, 0, 5_000));
        uint16 kept = uint16(uint256(share) * (10_000 - rate) / 10_000);
        assertEq(_recap().prizeBoundFor(lp, burn, share, rate), _recap().prizeBound(lp, burn, kept));
    }

    /// A Hookr token's pool with arb recapture binds no Hookr minimum, whatever the treasury's recapture rate (1,000
    /// here): Hookr earns its cut of each arb recapture instead. The split is unchanged (Hookr 25% of each profit, the
    /// partner's 25% kept), and the trader's swap on this pool without rules settles through the Rules once and pays
    /// Hookr nothing.
    function test_arbRecap_noMinimumOnALanePool() public {
        PoolKey memory key = _pool(2_000, 2_500, 0, address(0));
        assertEq(treasury.minFeePips(true), 1_000);
        assertEq(_recap().minimumFee(key.toId()), 0);
        exec.set(ScriptedExecutor.Mode.PUSH_NET, P);
        vm.recordLogs();
        _buy(key, ETH, whale, 1e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Splits memory t = _splits(logs);
        assertEq(t.count, 2, "both phases pushed");
        assertEq(t.protocol, 2 * (25 * P / 100), "Hookr: 25% of each profit");
        assertEq(t.trader + t.lp, 2 * (50 * P / 100));
        uint256 allocations;
        uint256 paid;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(rules) || logs[i].topics[0] != IHookrRulesEvents.FeesAllocated.selector) {
                continue;
            }
            (uint256 pro,,,,) = abi.decode(logs[i].data, (uint256, uint256, uint256, address, uint256));
            paid += pro;
            ++allocations;
        }
        assertEq(allocations, 1, "the trader's swap alone");
        assertEq(paid, 0, "no minimum");
        assertEq(manager.balanceOf(address(rules), ETH.toId()) >= rules.totalLiability(ETH), true, "backed");
    }

    function test_arbRecap_constant() public view {
        assertEq(_recap().RECAPTURE_PROTOCOL_BPS(), 2_500);
    }
}
