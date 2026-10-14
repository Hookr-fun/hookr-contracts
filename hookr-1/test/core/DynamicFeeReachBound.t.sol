// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookrDynamicFee} from "../../src/libraries/HookrDynamicFee.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRulesKnobs} from "../../src/interfaces/IHookrRulesKnobs.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {RulesData} from "../utils/RulesData.sol";
import {RulesKnobsBase} from "./RulesKnobs.t.sol";

/// @notice N09, the dynamic fee's reach bound. The root simulates a swap without its dynamic fee, so the simulated move
///         runs ahead of the executed one and the charge ahead of the fee the executed move implies: the simulation
///         lead. On DF-01's four swap shapes (a fresh pool's first swap of 5e22 in, or 4e22 out, against 1e24
///         liquidity) the lead of the exact-input shapes grows with the span times the sensitivity squared, the fee
///         being quadratic in the move below the knee, and the lead of an exact-output sell with the span times the
///         protocol share, the largest share the simulation reserves, less what the swap's own dynamic fee takes back;
///         an exact-output buy has none. Bind refuses a dynamic fee pool past either bound (HookrDynamicFee.MAX_REACH,
///         MAX_RESERVE), both chosen from a sweep of the shapes over span, sensitivity, share and the full rules so
///         that every admitted shape leads by at most 5%. Here: both sides of each bound at bind, the lead at every
///         edge of the admitted region (with and without a base fee) and inside it, and the same bound at the tempo's
///         ends, where a later swap starts from a stepped reference. The lead is the dynamic fee charged (recovered exactly from the receipt's LP fee) over the one
///         the executed end price implies (at WAD precision), so a pip of rounding never reads as lead.
contract DynamicFeeReachBoundTest is RulesKnobsBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant WAD = 1e18;
    /// @dev 5% over the implied fee, in bps of it.
    uint256 internal constant LIMIT = 10_500;
    address internal victim = address(0xB0B);

    struct Cfg {
        uint24 span;
        uint16 sens;
        uint16 share;
        bool full;
        uint24 base;
    }

    function setUp() public override {
        super.setUp();
        tokenA.transfer(victim, 1e28);
        tokenB.transfer(victim, 1e28);
        vm.startPrank(victim);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev The largest span bind admits at `sens` and `share`, from the bounds as HookrTypes states them.
    function _maxSpan(uint256 sens, uint256 share) internal pure returns (uint256 span) {
        span = 600_000 - 3000;
        uint256 sens2 = sens * sens;
        uint256 reach = HookrDynamicFee.MAX_REACH / sens2;
        if (reach < span) span = reach;
        if (share != 0) {
            uint256 reserve = HookrDynamicFee.MAX_RESERVE * HookrDynamicFee.RESERVE_SCALE
                / (share * (HookrDynamicFee.RESERVE_SCALE - sens2));
            if (reserve < span) span = reserve;
        }
    }

    function _rulesOf(Cfg memory c) internal view returns (HookrTypes.RulesConfig memory r) {
        r = _dynamicRules();
        r.maxFeePips = uint24(uint256(c.base) + c.span);
        r.dynamicFeeSens = c.sens;
        r.protocolShareBps = c.share;
        if (c.full) {
            r.burnBps = 100;
            r.lpBps = 200;
            r.royaltyBps = 500;
            r.royaltyTo = royalty;
        }
    }

    // ------------------------------------------------------------------------------------------------ the bound

    function test_bound_getter() public view {
        (uint256 reach, uint256 reserve, uint256 scale) = IHookrRulesKnobs(address(rules)).dynamicFeeReachBound();
        assertEq(reach, HookrDynamicFee.MAX_REACH, "reach");
        assertEq(reserve, HookrDynamicFee.MAX_RESERVE, "reserve");
        assertEq(scale, HookrDynamicFee.RESERVE_SCALE, "scale");
        assertEq(reach, 7_200_000);
        assertEq(reserve, 230_000_000);
        // DF-01's exact-output sell, 4e22 of the 1e24 liquidity's quote out, moves the price 1/24 from the reference,
        // where the average rate is 4/3 x (1/24)^2 = 1/432 of the span per unit of sensitivity squared.
        assertEq(scale, 432);
        assertApproxEqAbs(HookrDynamicFee.averageRate(0, HookrDynamicFee.WAD / 24, 1) * 432, HookrDynamicFee.WAD, 1e6);
    }

    /// At every sensitivity and at shares from zero to the 50% ceiling, the largest span within both bounds binds and
    /// one pip more is refused; a pool without dynamic fees is not bounded.
    function test_bound_bothSidesAtBind() public {
        uint16[5] memory shares = [uint16(0), 2_000, 2_500, 3_333, 5_000];
        for (uint16 s = 1; s <= 10; ++s) {
            for (uint256 h; h < shares.length; ++h) {
                uint256 span = _maxSpan(s, shares[h]);
                Cfg memory c = Cfg(uint24(span), s, shares[h], false, 3000);
                _bind(RulesData.encode(_rulesOf(c), 1e22));
                if (span < 600_000 - 3000) {
                    c.span = uint24(span + 1);
                    _refuse(RulesData.encode(_rulesOf(c), 1e22));
                }
            }
        }
        // The same share with no dynamic fee binds at any share.
        HookrTypes.RulesConfig memory plain = _plainRules();
        plain.protocolShareBps = 5_000;
        _bind(abi.encode(plain));
    }

    // ------------------------------------------------------------------------------------------------ the lead

    function _lpReward(Cfg memory c) internal pure returns (uint256) {
        if (!c.full) return 0;
        uint256 lpSlice = (uint256(200) * c.share + 99) / 100;
        uint256 lpNet = 200 * 100 - lpSlice;
        return lpNet - lpNet * 500 / 10_000;
    }

    /// @dev The smallest dynamic fee x with x - floor(x * share / 10,000) == surcharge: what the Rules charged.
    function _recover(uint256 surcharge, uint256 share) internal pure returns (uint256 x) {
        x = surcharge * 10_000 / (10_000 - share);
        while (x - x * share / 10_000 < surcharge) ++x;
        while (x > 0 && (x - 1) - (x - 1) * share / 10_000 >= surcharge) --x;
        assertEq(x - x * share / 10_000, surcharge, "the charge recovered");
    }

    /// @dev Launches `c` alone through launchFamily with tempo knobs `k`.
    function _openCfg(Cfg memory c, IHookrLauncher.MemberKnobs memory k) internal returns (PoolKey memory) {
        IHookrLauncher.Member memory m = _dynamicFeeMember(Currency.wrap(address(0)));
        m.config.baseLpFeePips = c.base;
        m.rules = _rulesOf(c);
        return _launchKnobbed(m, false, 60, k);
    }

    /// @dev One swap of `shape` (0 buy in, 1 buy out, 2 sell in, 3 sell out) of `amount` on `key`: its lead in bps of
    ///      the fee its executed move implies, measured from the reference the swap was priced from.
    function _leadOf(Cfg memory c, PoolKey memory key, uint8 shape, uint128 amount) internal returns (uint256) {
        bool buy = shape < 2;
        bool exactInput = shape % 2 == 0;
        (uint160 before,,,) = manager.getSlot0(key.toId());
        (,, int24 anchorBefore,,,) = rules.referenceState(key.toId());
        IHookrRouter.Swap memory p = _swap(key, buy, exactInput, amount);
        p.recipient = victim;
        HookrTypes.ExecutionReceipt memory r = quoter.quote(p, victim);
        vm.prank(victim);
        router.swap(p, address(0), new uint256[](0));
        (uint160 end,,,) = manager.getSlot0(key.toId());
        (, int24 referenceTick,,,,) = rules.referenceState(key.toId());
        uint160 sqrtRef = TickMath.getSqrtPriceAtTick(referenceTick);
        // The quote is currency0 (subject second), so a buy is zeroForOne.
        int256 from = HookrDynamicFee.distance(sqrtRef, before, buy);
        int256 to = HookrDynamicFee.distance(sqrtRef, end, buy);
        int256 away = from > 0 ? from : int256(0);
        if (to <= away) return 10_000;
        int256 anchor = HookrDynamicFee.distance(sqrtRef, TickMath.getSqrtPriceAtTick(anchorBefore), buy);
        int256 start = anchor < from ? anchor : from;
        uint256 a = start > 0 ? uint256(start) : 0;
        uint256 lpReward = buy ? _lpReward(c) : 0;
        uint256 dyn = _recover(r.lpFeePips - c.base - lpReward, c.share);
        uint256 room = 600_000 - uint256(c.base) - lpReward;
        uint256 impliedWad = uint256(c.span) * HookrDynamicFee.averageRate(a, a + uint256(to - away), c.sens);
        if (impliedWad > room * WAD) impliedWad = room * WAD;
        if (impliedWad == 0) return 10_000;
        return dyn * 10_000 * WAD / impliedWad;
    }

    /// @dev DF-01's four shapes on fresh pools of `c` with tempo `k`; each lead at most 5%.
    function _shapesWithin(Cfg memory c, IHookrLauncher.MemberKnobs memory k, string memory where)
        internal
        returns (uint256 worst)
    {
        for (uint8 shape; shape < 4; ++shape) {
            uint256 snap = vm.snapshotState();
            PoolKey memory key = _openCfg(c, k);
            uint256 lead = _leadOf(c, key, shape, shape % 2 == 0 ? 5e22 : 4e22);
            vm.revertToState(snap);
            if (lead > LIMIT) {
                emit log_named_string("where", where);
                emit log_named_uint("span", c.span);
                emit log_named_uint("sens", c.sens);
                emit log_named_uint("share", c.share);
                emit log_named_uint("shape", shape);
                emit log_named_uint("lead bps", lead);
            }
            assertLe(lead, LIMIT, "within 5%");
            if (lead > worst) worst = lead;
            if (shape == 1) assertLe(lead, 10_001, "an exact-output buy fills the simulated move");
        }
    }

    /// The lead at the edge of the admitted region, the largest span at each sensitivity and share, pure and with the
    /// full rules (Auto Burn, LP Rewards, royalty): at most 5% on every shape.
    function test_lead_atTheEdges() public {
        IHookrLauncher.MemberKnobs memory dflt;
        uint16[6] memory shares = [uint16(0), 1_000, 2_000, 2_500, 3_333, 5_000];
        uint256 worst;
        for (uint16 s = 1; s <= 10; ++s) {
            for (uint256 h; h < shares.length; ++h) {
                for (uint256 f; f < 2; ++f) {
                    uint256 w =
                        _shapesWithin(Cfg(uint24(_maxSpan(s, shares[h])), s, shares[h], f == 1, 3000), dflt, "edge");
                    if (w > worst) worst = w;
                }
            }
        }
        emit log_named_uint("worst lead at the edges, bps of the implied fee", worst);
    }

    /// The same edges with no base fee, where more of an exact-input swap moves the price: at most 5%.
    function test_lead_atTheEdgesWithoutABaseFee() public {
        IHookrLauncher.MemberKnobs memory dflt;
        uint16[3] memory shares = [uint16(0), 2_000, 5_000];
        for (uint16 s = 1; s <= 10; ++s) {
            for (uint256 h; h < shares.length; ++h) {
                _shapesWithin(Cfg(uint24(_maxSpan(s, shares[h])), s, shares[h], false, 0), dflt, "edge, no base fee");
            }
        }
    }

    /// Inside the region, a quarter, a half and three quarters of the largest span at each sensitivity, at the
    /// production floor's share: at most 5%, so the bound is not met only at its edge.
    function test_lead_inside() public {
        IHookrLauncher.MemberKnobs memory dflt;
        for (uint16 s = 1; s <= 10; ++s) {
            uint256 edge = _maxSpan(s, 2_000);
            for (uint256 q = 1; q <= 3; ++q) {
                _shapesWithin(Cfg(uint24(edge * q / 4), s, 2_000, false, 3000), dflt, "inside");
            }
        }
    }

    /// With the tempo at each knob's ends, at the two corners of the region (the most sensitive pool at the largest
    /// span its reach admits, and the least sensitive at the largest its reserve admits at the production floor's
    /// share), a swap after a 3e22 buy, inside the pool's window and after it, starts from a stepped reference and
    /// still leads by at most 5%.
    function test_lead_tempoEnds() public {
        IHookrLauncher.MemberKnobs[10] memory e = [
            _memberKnobs(12, 120, 7_500, 200, 0),
            _memberKnobs(300, 600, 7_500, 200, 0),
            _memberKnobs(30, 60, 7_500, 200, 0),
            _memberKnobs(30, 1_800, 7_500, 200, 0),
            _memberKnobs(30, 120, 0, 200, 0),
            _memberKnobs(30, 120, 9_500, 200, 0),
            _memberKnobs(30, 120, 7_500, 50, 0),
            _memberKnobs(30, 120, 7_500, 2_000, 0),
            _memberKnobs(12, 30, 0, 2_000, 0),
            _memberKnobs(300, 1_800, 9_500, 50, 0)
        ];
        Cfg[2] memory corners = [
            Cfg(uint24(_maxSpan(10, 2_000)), 10, 2_000, false, 3000),
            Cfg(uint24(_maxSpan(1, 2_000)), 1, 2_000, false, 3000)
        ];
        for (uint256 i; i < e.length; ++i) {
            for (uint256 k; k < 2; ++k) {
                _shapesWithin(corners[k], e[i], "tempo, first swap");
                uint256[2] memory waits = [uint256(1), uint256(e[i].windowSeconds) + 1];
                for (uint256 w; w < 2; ++w) {
                    for (uint8 shape; shape < 4; ++shape) {
                        uint256 snap = vm.snapshotState();
                        PoolKey memory key = _openCfg(corners[k], e[i]);
                        _leadOf(corners[k], key, 0, 3e22);
                        vm.warp(vm.getBlockTimestamp() + waits[w]);
                        vm.roll(vm.getBlockNumber() + 1);
                        uint256 lead = _leadOf(corners[k], key, shape, shape % 2 == 0 ? 2e22 : 1.5e22);
                        vm.revertToState(snap);
                        assertLe(lead, LIMIT, "a later swap within 5%");
                    }
                }
            }
        }
    }
}
