// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {RootSecurityBase} from "../utils/RootSecurityBase.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrAdvisory} from "../../src/interfaces/IHookrAdvisory.sol";
import {IHookrGoverned} from "../../src/interfaces/IHookrGoverned.sol";
import {HookrSessionAdvisory} from "../../src/extensions/HookrSessionAdvisory.sol";
import {IHookrSessionAdvisory} from "../../src/interfaces/IHookrSessionAdvisory.sol";
import {HookrMarketCalendar} from "../../src/libraries/HookrMarketCalendar.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";
import {IHookrRulesEvents} from "../../src/interfaces/IHookrRulesEvents.sol";

/// @notice Exposes the calendar library over its own storage extension.
contract CalendarHarness {
    HookrMarketCalendar.Extension internal x;

    function session(uint256 timestamp) external view returns (HookrMarketCalendar.Session memory) {
        return HookrMarketCalendar.session(x, timestamp);
    }

    function utcOffset(uint256 timestamp) external pure returns (uint256) {
        return HookrMarketCalendar.utcOffset(timestamp);
    }

    function dayKind(uint256 day) external view returns (uint256) {
        return HookrMarketCalendar.dayKind(x, day);
    }

    function append(uint256 year, uint16[] calldata closed, uint16[] calldata early) external {
        HookrMarketCalendar.append(x, year, closed, early);
    }
}

/// @notice Calendar, schedule and governance tests plus end-to-end swaps through the fixture's real Root and Rules.
contract HookrSessionAdvisoryTest is RootSecurityBase {
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    uint24 internal constant ADVISORY_CAP = 50_000;
    uint24 internal constant REGULAR = 1000;
    uint24 internal constant PRE = 4000;
    uint24 internal constant AFTER = 6000;
    uint24 internal constant NIGHT = 10_000;
    uint24 internal constant CLOSED = 20_000;
    uint256 internal constant BASE = 3000;
    uint256 internal constant BUY_LP_REWARD = 14_250;

    HookrSessionAdvisory internal advisory;
    CalendarHarness internal cal;
    PoolKey internal key;
    PoolId internal id;

    function setUp() public {
        _setUpRootSecurity();
        advisory = new HookrSessionAdvisory(address(this), 1 days);
        cal = new CalendarHarness();
        IHookrRegistry.Admission memory ad = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: address(advisory),
            codeHash: address(advisory).codehash,
            schemaHash: advisory.configSchemaHash(),
            caps: HookrTypes.Caps(ADVISORY_CAP, 0, 0),
            gasLimit: 150_000,
            phaseMask: 1,
            feeOnly: true,
            failOpen: false
        });
        registry.queue(registry.ADMIT(), abi.encode(address(root), ad));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), ad);
        key = _openSession(_schedule(0, 0, 0), 600_000, _rulesConfig(), 60);
        id = key.toId();
    }

    // ------------------------------------------------------------ helpers

    function _schedule(uint16 openRamp, uint16 closeRamp, uint8 flags)
        internal
        pure
        returns (IHookrSessionAdvisory.Schedule memory)
    {
        return IHookrSessionAdvisory.Schedule(REGULAR, PRE, AFTER, NIGHT, CLOSED, openRamp, closeRamp, flags);
    }

    function _pc(uint24 poolCap) internal view returns (HookrTypes.PoolConfig memory pc) {
        pc = _config(address(rules));
        pc.caps.maxLpFeePips = poolCap;
        pc.advisory = address(advisory);
        pc.advisoryGasLimit = 150_000;
        pc.advisoryPhases = HookrTypes.BEFORE_SWAP;
    }

    function _openSession(
        IHookrSessionAdvisory.Schedule memory s,
        uint24 poolCap,
        HookrTypes.RulesConfig memory rc,
        int24 spacing
    ) internal returns (PoolKey memory k) {
        k = _key(spacing);
        root.initializePool(k, _pc(poolCap), abi.encode(rc), abi.encode(s), SQRT_ONE);
        _addLiquidity(k, -6000, 6000, 1e24);
    }

    /// @dev Unix time of a New York wall-clock instant; `dst` states the expected offset independently of the code.
    function _ny(uint256 y, uint256 m, uint256 d, uint256 h, uint256 mi, uint256 sec, bool dst)
        internal
        pure
        returns (uint256)
    {
        return
            HookrMarketCalendar.dayOf(y, m, d) * 1 days + h * 1 hours + mi * 1 minutes + sec + (dst ? 4 : 5) * 1 hours;
    }

    function _swapFee(PoolKey memory k, bool buy) internal returns (uint256 fee) {
        vm.recordLogs();
        _genericSwap(k, buy, -1e15, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (,,,,, uint24 f) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return f;
            }
        }
        revert("no swap event");
    }

    /// @dev Asserts the view and an executed sell through the real Root agree on the surcharge at `t`.
    function _expect(uint256 t, uint256 surcharge) internal {
        vm.warp(t);
        assertEq(advisory.surchargeAt(address(root), id, t), surcharge, "surchargeAt");
        assertEq(_swapFee(key, false), BASE + surcharge, "executed LP fee");
    }

    function _tier(uint256 t) internal view returns (HookrMarketCalendar.Tier) {
        return advisory.sessionAt(t).tier;
    }

    function _u16(uint256[] memory a) internal pure returns (uint16[] memory out) {
        out = new uint16[](a.length);
        for (uint256 i; i < a.length; ++i) {
            out[i] = uint16(a[i]);
        }
    }

    function _closed2031() internal pure returns (uint16[] memory c) {
        uint256[] memory a = new uint256[](10);
        (a[0], a[1], a[2], a[3], a[4]) = (101, 120, 217, 411, 526);
        (a[5], a[6], a[7], a[8], a[9]) = (619, 704, 901, 1127, 1225);
        c = _u16(a);
    }

    function _early2031() internal pure returns (uint16[] memory e) {
        uint256[] memory a = new uint256[](3);
        (a[0], a[1], a[2]) = (703, 1128, 1224);
        e = _u16(a);
    }

    // ------------------------------------------------------------ DST through the Root

    function testSpringForwardSwitchDay() public {
        // Sunday 2026-03-08: 01:59:59 EST is one second before the switch; 03:00 EDT is the switch instant.
        assertEq(_ny(2026, 3, 8, 1, 59, 59, false) + 1, _ny(2026, 3, 8, 3, 0, 0, true));
        assertEq(cal.utcOffset(_ny(2026, 3, 8, 1, 59, 59, false)), 5 hours);
        assertEq(cal.utcOffset(_ny(2026, 3, 8, 3, 0, 0, true)), 4 hours);
        // Sunday evening becomes overnight at 20:00 EDT (00:00 UTC), an hour earlier than under EST.
        _expect(_ny(2026, 3, 8, 19, 59, 59, true), CLOSED);
        _expect(_ny(2026, 3, 8, 20, 0, 0, true), NIGHT);
        // Monday 09:30 EDT is 13:30 UTC; under EST that instant would still be pre-market.
        _expect(_ny(2026, 3, 9, 9, 29, 59, true), PRE);
        _expect(_ny(2026, 3, 9, 9, 30, 0, true), REGULAR);
        // The Friday before, 09:30 EST is 14:30 UTC.
        _expect(_ny(2026, 3, 6, 9, 29, 59, false), PRE);
        _expect(_ny(2026, 3, 6, 9, 30, 0, false), REGULAR);
    }

    function testFallBackSwitchDay() public {
        // Sunday 2026-11-01: 01:59:59 EDT, then 01:00 EST one second later.
        assertEq(_ny(2026, 11, 1, 1, 59, 59, true) + 1, _ny(2026, 11, 1, 1, 0, 0, false));
        assertEq(cal.utcOffset(_ny(2026, 11, 1, 1, 59, 59, true)), 4 hours);
        assertEq(cal.utcOffset(_ny(2026, 11, 1, 1, 0, 0, false)), 5 hours);
        _expect(_ny(2026, 11, 1, 19, 59, 59, false), CLOSED);
        _expect(_ny(2026, 11, 1, 20, 0, 0, false), NIGHT);
        _expect(_ny(2026, 11, 2, 9, 29, 59, false), PRE);
        _expect(_ny(2026, 11, 2, 9, 30, 0, false), REGULAR);
        _expect(_ny(2026, 10, 30, 15, 59, 59, true), REGULAR);
        _expect(_ny(2026, 10, 30, 16, 0, 0, true), AFTER);
    }

    function testDstSwitchInstantsEveryYear() public view {
        for (uint256 y = 2026; y <= 2040; ++y) {
            uint256 march = _nthSunday(y, 3, 2);
            uint256 nov = _nthSunday(y, 11, 1);
            uint256 start = march * 1 days + 7 hours;
            uint256 end = nov * 1 days + 6 hours;
            assertEq(cal.utcOffset(start - 1), 5 hours);
            assertEq(cal.utcOffset(start), 4 hours);
            assertEq(cal.utcOffset(end - 1), 4 hours);
            assertEq(cal.utcOffset(end), 5 hours);
            assertEq(cal.utcOffset(HookrMarketCalendar.dayOf(y, 7, 1) * 1 days), 4 hours);
            assertEq(cal.utcOffset(HookrMarketCalendar.dayOf(y, 1, 15) * 1 days), 5 hours);
        }
    }

    /// @dev Independent of the library: walk the month and count Sundays.
    function _nthSunday(uint256 y, uint256 m, uint256 n) internal pure returns (uint256 day) {
        day = HookrMarketCalendar.dayOf(y, m, 1);
        uint256 seen;
        while (true) {
            if ((day + 4) % 7 == 0 && ++seen == n) return day;
            ++day;
        }
    }

    // ------------------------------------------------------------ holidays through the Root

    function testThanksgivingAndEarlyClose() public {
        _expect(_ny(2026, 11, 25, 19, 59, 59, false), AFTER);
        _expect(_ny(2026, 11, 25, 20, 0, 0, false), CLOSED);
        _expect(_ny(2026, 11, 26, 12, 0, 0, false), CLOSED);
        _expect(_ny(2026, 11, 26, 20, 0, 0, false), NIGHT);
        _expect(_ny(2026, 11, 27, 3, 59, 59, false), NIGHT);
        _expect(_ny(2026, 11, 27, 4, 0, 0, false), PRE);
        _expect(_ny(2026, 11, 27, 12, 59, 59, false), REGULAR);
        _expect(_ny(2026, 11, 27, 13, 0, 0, false), AFTER);
        _expect(_ny(2026, 11, 27, 16, 59, 59, false), AFTER);
        _expect(_ny(2026, 11, 27, 17, 0, 0, false), CLOSED);
        assertEq(advisory.sessionAt(_ny(2026, 11, 27, 12, 0, 0, false)).close, 13 hours);
    }

    function testJulyThirdAndFourth() public {
        // 2026: July 4 is a Saturday, so Friday July 3 is the closure and Thursday is a full session.
        _expect(_ny(2026, 7, 2, 15, 59, 59, true), REGULAR);
        _expect(_ny(2026, 7, 2, 16, 0, 0, true), AFTER);
        _expect(_ny(2026, 7, 2, 20, 0, 0, true), CLOSED);
        _expect(_ny(2026, 7, 3, 10, 0, 0, true), CLOSED);
        _expect(_ny(2026, 7, 4, 10, 0, 0, true), CLOSED);
        _expect(_ny(2026, 7, 5, 20, 0, 0, true), NIGHT);
        // 2028: Monday July 3 closes at 13:00 and Tuesday July 4 is closed.
        _expect(_ny(2028, 7, 3, 12, 59, 59, true), REGULAR);
        _expect(_ny(2028, 7, 3, 13, 0, 0, true), AFTER);
        _expect(_ny(2028, 7, 3, 17, 0, 0, true), CLOSED);
        _expect(_ny(2028, 7, 4, 13, 0, 0, true), CLOSED);
        _expect(_ny(2028, 7, 4, 20, 0, 0, true), NIGHT);
        _expect(_ny(2028, 7, 5, 9, 30, 0, true), REGULAR);
    }

    function testWeekend() public {
        _expect(_ny(2026, 9, 25, 19, 59, 59, true), AFTER);
        _expect(_ny(2026, 9, 25, 20, 0, 0, true), CLOSED);
        _expect(_ny(2026, 9, 26, 12, 0, 0, true), CLOSED);
        _expect(_ny(2026, 9, 27, 19, 59, 59, true), CLOSED);
        _expect(_ny(2026, 9, 27, 20, 0, 0, true), NIGHT);
        _expect(_ny(2026, 9, 28, 3, 59, 59, true), NIGHT);
        _expect(_ny(2026, 9, 28, 4, 0, 0, true), PRE);
        _expect(_ny(2026, 9, 29, 22, 0, 0, true), NIGHT);
    }

    function testGoodFriday() public {
        _expect(_ny(2026, 4, 2, 19, 0, 0, true), AFTER);
        _expect(_ny(2026, 4, 2, 20, 0, 0, true), CLOSED);
        _expect(_ny(2026, 4, 3, 11, 0, 0, true), CLOSED);
        _expect(_ny(2026, 4, 5, 20, 0, 0, true), NIGHT);
        _expect(_ny(2026, 4, 6, 9, 30, 0, true), REGULAR);
        // Good Friday moves with Easter: 2027-03-26 and 2030-04-19.
        assertEq(uint256(_tier(_ny(2027, 3, 26, 11, 0, 0, true))), uint256(HookrMarketCalendar.Tier.CLOSED));
        assertEq(uint256(_tier(_ny(2030, 4, 19, 11, 0, 0, true))), uint256(HookrMarketCalendar.Tier.CLOSED));
    }

    function testChristmasAndYearEnd() public {
        _expect(_ny(2026, 12, 24, 12, 59, 59, false), REGULAR);
        _expect(_ny(2026, 12, 24, 13, 0, 0, false), AFTER);
        _expect(_ny(2026, 12, 24, 17, 0, 0, false), CLOSED);
        _expect(_ny(2026, 12, 25, 12, 0, 0, false), CLOSED);
        // Thursday 2026-12-31 evening precedes the New Year closure.
        _expect(_ny(2026, 12, 31, 20, 0, 0, false), CLOSED);
        // 2028 New Year falls on a Saturday: Friday 2027-12-31 trades normally.
        _expect(_ny(2027, 12, 31, 15, 0, 0, false), REGULAR);
    }

    /// @dev Every closure and early close for 2026-2030 against the published lists; no other weekday is flagged.
    function testConstantCalendarMatchesPublishedLists() public view {
        uint256[10][5] memory closed = [
            [uint256(101), 119, 216, 403, 525, 619, 703, 907, 1126, 1225],
            [uint256(101), 118, 215, 326, 531, 618, 705, 906, 1125, 1224],
            [uint256(117), 221, 414, 529, 619, 704, 904, 1123, 1225, 0],
            [uint256(101), 115, 219, 330, 528, 619, 704, 903, 1122, 1225],
            [uint256(101), 121, 218, 419, 527, 619, 704, 902, 1128, 1225]
        ];
        uint256[3][5] memory early = [
            [uint256(1127), 1224, 0],
            [uint256(1126), 0, 0],
            [uint256(703), 1124, 0],
            [uint256(703), 1123, 1224],
            [uint256(703), 1129, 1224]
        ];
        uint256 first = HookrMarketCalendar.EPOCH_DAY;
        for (uint256 day = first; day < first + HookrMarketCalendar.CONSTANT_DAYS; ++day) {
            (uint256 y, uint256 m, uint256 d) = HookrMarketCalendar.civil(day);
            uint256 md = m * 100 + d;
            uint256 w = (day + 4) % 7;
            uint256 expected = (w == 0 || w == 6) ? 2 : 0;
            for (uint256 j; j < 10; ++j) {
                if (closed[y - 2026][j] == md) expected = 2;
            }
            for (uint256 j; j < 3; ++j) {
                if (early[y - 2026][j] == md) expected = 1;
            }
            assertEq(cal.dayKind(day), expected, "day kind");
        }
        assertEq(cal.dayKind(first + HookrMarketCalendar.CONSTANT_DAYS + 1), 3, "2031-01-02 uncovered");
        assertEq(cal.dayKind(first - 1), 3, "2025-12-31 uncovered");
    }

    // ------------------------------------------------------------ schedule and limits

    function testRamps() public {
        PoolKey memory k = _openSession(_schedule(1800, 900, 0), 600_000, _rulesConfig(), 10);
        PoolId pid = k.toId();
        address r = address(root);
        assertEq(advisory.surchargeAt(r, pid, _ny(2026, 9, 28, 9, 29, 59, true)), PRE);
        assertEq(advisory.surchargeAt(r, pid, _ny(2026, 9, 28, 9, 30, 0, true)), PRE);
        assertEq(advisory.surchargeAt(r, pid, _ny(2026, 9, 28, 9, 45, 0, true)), 2500);
        assertEq(advisory.surchargeAt(r, pid, _ny(2026, 9, 28, 10, 0, 0, true)), REGULAR);
        assertEq(advisory.surchargeAt(r, pid, _ny(2026, 9, 28, 15, 45, 0, true)), REGULAR);
        assertEq(advisory.surchargeAt(r, pid, _ny(2026, 9, 28, 15, 52, 30, true)), 3500);
        assertEq(advisory.surchargeAt(r, pid, _ny(2026, 9, 28, 15, 59, 59, true)), 1000 + uint256(5000) * 899 / 900);
        assertEq(advisory.surchargeAt(r, pid, _ny(2026, 9, 28, 16, 0, 0, true)), AFTER);
        // The close ramp follows the 13:00 early close.
        assertEq(advisory.surchargeAt(r, pid, _ny(2026, 11, 27, 12, 52, 30, false)), 3500);
        vm.warp(_ny(2026, 9, 28, 9, 45, 0, true));
        assertEq(_swapFee(k, false), BASE + 2500);
    }

    function testClampsToPoolRoom() public {
        // The Root reserves the advisory's admitted maximum inside the pool cap before Rules bind, so a pool whose
        // room beside the Rules' largest native LP fee (base 3000 + LP reward 14,250) is below ADVISORY_CAP is
        // refused at initialization.
        uint24 tight = uint24(BASE + BUY_LP_REWARD + 5000);
        PoolKey memory refused = _key(10);
        vm.expectRevert(IHookrRootEvents.InvalidConfig.selector);
        root.initializePool(refused, _pc(tight), abi.encode(_rulesConfig()), abi.encode(_schedule(0, 0, 0)), SQRT_ONE);
        // With exactly ADVISORY_CAP of room the limit is the admission cap and a buy can reach the pool cap.
        uint24 poolCap = uint24(BASE + BUY_LP_REWARD + ADVISORY_CAP);
        PoolKey memory k = _openSession(_schedule(0, 0, 0), poolCap, _rulesConfig(), 10);
        IHookrSessionAdvisory.Bound memory b = advisory.schedule(address(root), k.toId());
        assertEq(b.limit, ADVISORY_CAP);
        vm.warp(_ny(2026, 9, 26, 12, 0, 0, true));
        assertEq(advisory.surchargeAt(address(root), k.toId(), vm.getBlockTimestamp()), CLOSED);
        assertEq(_swapFee(k, true), BASE + BUY_LP_REWARD + CLOSED);
        assertEq(_swapFee(k, false), BASE + CLOSED);
        vm.warp(_ny(2026, 9, 28, 11, 0, 0, true));
        assertEq(_swapFee(k, true), BASE + BUY_LP_REWARD + REGULAR);
    }

    /// RR-A1 mirror: LP Rewards at `lpBps` 4 and a 2,000 share are 320 pips, the protocol's share taken in pips and
    /// rounded up, as the Rules take them. With the pool cap exactly the Rules' 3,320 plus ADVISORY_CAP the limit is
    /// the admission cap; with the old whole-bps share the ceiling read 3,400 and the limit 49,920.
    function testRulesCeilingTakesTheProtocolShareInPips() public {
        HookrTypes.RulesConfig memory rc = _rulesConfig();
        rc.lpBps = 4;
        rc.burnBps = 0;
        rc.royaltyBps = 0;
        rc.royaltyTo = address(0);
        rc.protocolShareBps = 2000;
        uint24 poolCap = uint24(BASE + 320 + ADVISORY_CAP);
        PoolKey memory tight = _key(10);
        vm.expectRevert(
            abi.encodeWithSelector(
                IHookrRootEvents.ModuleCallReverted.selector,
                address(rules),
                IHookrAdvisory.bind.selector,
                abi.encodeWithSelector(IHookrRulesEvents.InvalidConfig.selector)
            )
        );
        root.initializePool(tight, _pc(poolCap - 1), abi.encode(rc), abi.encode(_schedule(0, 0, 0)), SQRT_ONE);
        PoolKey memory k = _openSession(_schedule(0, 0, 0), poolCap, rc, 10);
        assertEq(advisory.schedule(address(root), k.toId()).limit, ADVISORY_CAP);
    }

    function testGuardLimitUsesRulesClock() public {
        HookrTypes.RulesConfig memory rc = _rulesConfig();
        rc.guardEndBlock = uint40(vm.getBlockNumber() + 100);
        rc.snipeTaxPips = 40_000;
        // The guard's native ceiling adds the Snipe tax; the Root keeps ADVISORY_CAP of room beside it.
        uint24 poolCap = uint24(BASE + BUY_LP_REWARD + 40_000 + ADVISORY_CAP);
        PoolKey memory k = _openSession(_schedule(0, 0, 0), poolCap, rc, 10);
        IHookrSessionAdvisory.Bound memory b = advisory.schedule(address(root), k.toId());
        assertEq(b.guardLimit, ADVISORY_CAP);
        assertEq(b.limit, ADVISORY_CAP);
        assertEq(b.guardEnd, rc.guardEndBlock);
        vm.warp(_ny(2026, 9, 26, 12, 0, 0, true));
        assertEq(advisory.surchargeAt(address(root), k.toId(), vm.getBlockTimestamp()), CLOSED);
        _swapFee(k, true);
        vm.roll(vm.getBlockNumber() + 100);
        assertEq(advisory.surchargeAt(address(root), k.toId(), vm.getBlockTimestamp()), CLOSED);
        assertEq(_swapFee(k, true), BASE + BUY_LP_REWARD + CLOSED);
    }

    function testFallbackCeilingForOtherRules() public {
        // A Rules module outside the Hookr schema: the ceiling is min(pool cap, Rules admission cap = 100,000).
        HookrTypes.PoolConfig memory pc = _pc(120_000);
        pc.rules = address(mock);
        PoolKey memory k = _key(10);
        root.initializePool(k, pc, bytes("m"), abi.encode(_schedule(0, 0, 0)), SQRT_ONE);
        assertEq(advisory.schedule(address(root), k.toId()).limit, 20_000);
    }

    function testBindRejects() public {
        PoolKey memory k = _key(10);
        HookrTypes.PoolConfig memory pc = _pc(600_000);
        IHookrSessionAdvisory.Schedule memory s = _schedule(0, 0, 0);

        s.closedPips = ADVISORY_CAP + 1;
        vm.prank(address(root));
        vm.expectRevert(abi.encodeWithSelector(IHookrSessionAdvisory.InvalidSchedule.selector, 3));
        advisory.bind(k, pc, abi.encode(s));

        s = _schedule(12_000, 601, 0);
        vm.prank(address(root));
        vm.expectRevert(abi.encodeWithSelector(IHookrSessionAdvisory.InvalidSchedule.selector, 2));
        advisory.bind(k, pc, abi.encode(s));

        s = _schedule(0, 0, 2);
        vm.prank(address(root));
        vm.expectRevert(abi.encodeWithSelector(IHookrSessionAdvisory.InvalidSchedule.selector, 1));
        advisory.bind(k, pc, abi.encode(s));

        vm.prank(address(root));
        vm.expectRevert(abi.encodeWithSelector(IHookrSessionAdvisory.InvalidSchedule.selector, 0));
        advisory.bind(k, pc, abi.encodePacked(abi.encode(_schedule(0, 0, 0)), uint256(0)));

        pc.advisoryPhases = 3;
        vm.prank(address(root));
        vm.expectRevert(abi.encodeWithSelector(IHookrSessionAdvisory.InvalidPoolConfig.selector, 1));
        advisory.bind(k, pc, abi.encode(_schedule(0, 0, 0)));

        pc = _pc(600_000);
        pc.advisoryGasLimit = 149_999;
        vm.prank(address(root));
        vm.expectRevert(abi.encodeWithSelector(IHookrSessionAdvisory.InvalidPoolConfig.selector, 2));
        advisory.bind(k, pc, abi.encode(_schedule(0, 0, 0)));

        vm.prank(address(root));
        vm.expectRevert(abi.encodeWithSelector(IHookrSessionAdvisory.AlreadyBound.selector, address(root), id));
        advisory.bind(key, _pc(600_000), abi.encode(_schedule(0, 0, 0)));

        // Through the Root, a tier above the admission cap refuses the pool.
        s = _schedule(0, 0, 0);
        s.regularPips = ADVISORY_CAP + 1;
        vm.expectRevert();
        root.initializePool(k, _pc(600_000), abi.encode(_rulesConfig()), abi.encode(s), SQRT_ONE);
    }

    function testEpochTimestampsDoNotRevert() public {
        for (uint256 t; t < 40_000; t += 3_600) {
            assertFalse(advisory.sessionAt(t).covered);
            advisory.surchargeAt(address(root), id, t);
        }
        // 1970-01-01 00:00:01 UTC clamps to the start of a Thursday: the overnight tier.
        vm.warp(1);
        assertEq(_swapFee(key, false), BASE + NIGHT);
    }

    function testNeverRejectsNeverTakes() public {
        vm.warp(_ny(2026, 9, 26, 12, 0, 0, true));
        HookrTypes.SwapContext memory x;
        x.id = id;
        vm.prank(address(root));
        HookrTypes.Advice memory a = advisory.beforeSwap(x);
        assertEq(a.lpFeeSurchargePips, CLOSED);
        assertEq(a.quoteTakePips, 0);
        assertEq(a.recipient, address(0));
        assertFalse(a.reject);
        // Another caller's namespace is unbound and receives no surcharge.
        a = advisory.beforeSwap(x);
        assertEq(a.lpFeeSurchargePips, 0);
        assertTrue(advisory.beforeAddLiquidity(id, address(1)));
    }

    // ------------------------------------------------------------ calendar governance

    function testAppendYearTimelocked() public {
        bytes memory args = abi.encode(uint16(2031), _closed2031(), _early2031());
        vm.expectRevert();
        advisory.appendYear(2031, _closed2031(), _early2031());

        advisory.queue(advisory.APPEND_YEAR(), args);
        vm.expectRevert();
        advisory.appendYear(2031, _closed2031(), _early2031());
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(address(0xbad));
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, address(0xbad)));
        advisory.appendYear(2031, _closed2031(), _early2031());

        // Before the append, Thanksgiving 2031 is an uncovered weekday priced by its session.
        uint256 thanksgiving = _ny(2031, 11, 27, 12, 0, 0, false);
        assertEq(advisory.surchargeAt(address(root), id, thanksgiving), REGULAR);
        assertFalse(advisory.sessionAt(thanksgiving).covered);

        advisory.appendYear(2031, _closed2031(), _early2031());
        assertEq(advisory.lastCoveredYear(), 2031);
        assertEq(advisory.surchargeAt(address(root), id, thanksgiving), CLOSED);
        assertTrue(advisory.sessionAt(thanksgiving).covered);
        assertEq(advisory.surchargeAt(address(root), id, _ny(2031, 11, 28, 13, 0, 0, false)), AFTER);
        assertEq(advisory.surchargeAt(address(root), id, _ny(2031, 7, 3, 12, 59, 0, true)), REGULAR);
        assertEq(advisory.surchargeAt(address(root), id, _ny(2031, 7, 3, 13, 0, 0, true)), AFTER);
        assertEq(advisory.surchargeAt(address(root), id, _ny(2031, 7, 3, 17, 0, 0, true)), CLOSED);
        // The 2030-12-31 evening now knows 2031-01-01 is closed.
        assertEq(advisory.surchargeAt(address(root), id, _ny(2030, 12, 31, 21, 0, 0, false)), CLOSED);

        // An appended year cannot be replaced.
        advisory.queue(advisory.APPEND_YEAR(), args);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.expectRevert(abi.encodeWithSelector(HookrMarketCalendar.InvalidYear.selector, 2031));
        advisory.appendYear(2031, _closed2031(), _early2031());
    }

    function testAppendValidation() public {
        uint16[] memory none = new uint16[](0);
        uint16[] memory one = new uint16[](1);
        vm.expectRevert(abi.encodeWithSelector(HookrMarketCalendar.InvalidYear.selector, 2032));
        cal.append(2032, none, none);
        one[0] = 104; // 2031-01-04 is a Saturday
        vm.expectRevert(abi.encodeWithSelector(HookrMarketCalendar.InvalidDate.selector, 104));
        cal.append(2031, one, none);
        one[0] = 230; // February 30
        vm.expectRevert(abi.encodeWithSelector(HookrMarketCalendar.InvalidDate.selector, 230));
        cal.append(2031, one, none);
        one[0] = 1301;
        vm.expectRevert(abi.encodeWithSelector(HookrMarketCalendar.InvalidDate.selector, 1301));
        cal.append(2031, one, none);
        uint16[] memory two = new uint16[](2);
        (two[0], two[1]) = (120, 101);
        vm.expectRevert(abi.encodeWithSelector(HookrMarketCalendar.InvalidDate.selector, 101));
        cal.append(2031, two, none);
        one[0] = 101;
        vm.expectRevert(abi.encodeWithSelector(HookrMarketCalendar.InvalidDate.selector, 101));
        cal.append(2031, one, one);
        cal.append(2031, _closed2031(), _early2031());
        cal.append(2032, none, none);
        assertEq(cal.dayKind(HookrMarketCalendar.dayOf(2032, 12, 31)), 0);
        assertEq(cal.dayKind(HookrMarketCalendar.dayOf(2033, 1, 3)), 3);
    }

    function testUncoveredAsClosedFlag() public {
        PoolKey memory k = _openSession(_schedule(0, 0, 1), 600_000, _rulesConfig(), 10);
        uint256 t = _ny(2031, 3, 4, 11, 0, 0, false);
        assertEq(advisory.surchargeAt(address(root), k.toId(), t), CLOSED);
        assertEq(advisory.surchargeAt(address(root), id, t), REGULAR);
        vm.warp(t);
        assertEq(_swapFee(k, false), BASE + CLOSED);
        // Covered years ignore the flag.
        assertEq(advisory.surchargeAt(address(root), k.toId(), _ny(2030, 3, 5, 11, 0, 0, false)), REGULAR);
        // The last covered evening before an uncovered weekday is also uncovered.
        assertEq(advisory.surchargeAt(address(root), k.toId(), _ny(2030, 12, 30, 21, 0, 0, false)), NIGHT);
        assertEq(advisory.surchargeAt(address(root), k.toId(), _ny(2030, 12, 31, 21, 0, 0, false)), CLOSED);
    }

    // ------------------------------------------------------------ gas

    function testGasPerSwap() public {
        PoolKey memory plain = _key(10);
        HookrTypes.PoolConfig memory pc = _config(address(rules));
        root.initializePool(plain, pc, abi.encode(_rulesConfig()), bytes(""), SQRT_ONE);
        _addLiquidity(plain, -6000, 6000, 1e24);

        uint256[4] memory times = [
            _ny(2026, 9, 28, 11, 0, 0, true),
            _ny(2026, 9, 26, 11, 0, 0, true),
            _ny(2026, 11, 26, 20, 30, 0, false),
            _ny(2031, 3, 4, 11, 0, 0, false)
        ];
        string[4] memory label = ["regular", "weekend", "holiday evening", "uncovered year"];
        _genericSwap(plain, false, -1e15, 0);
        _genericSwap(key, false, -1e15, 0);
        for (uint256 i; i < 4; ++i) {
            vm.warp(times[i]);
            _cool();
            uint256 g = gasleft();
            _genericSwap(plain, false, -1e15, 0);
            uint256 without = g - gasleft();
            _cool();
            g = gasleft();
            _genericSwap(key, false, -1e15, 0);
            uint256 advised = g - gasleft();
            HookrTypes.SwapContext memory x;
            x.id = id;
            _cool();
            vm.prank(address(root));
            g = gasleft();
            advisory.beforeSwap(x);
            uint256 call = g - gasleft();
            console2.log(label[i]);
            console2.log("  cold swap without advisory", without);
            console2.log("  cold swap with advisory   ", advised);
            console2.log("  cold advisory beforeSwap  ", call);
            assertLt(advised - without, 15_000);
            assertLt(call, 12_000);
        }
    }

    /// @dev Marks every touched account and slot cold, as at the start of a transaction.
    function _cool() internal {
        vm.cool(address(manager));
        vm.cool(address(root));
        vm.cool(address(rules));
        vm.cool(address(advisory));
        vm.cool(address(registry));
        vm.cool(address(tokenA));
        vm.cool(address(tokenB));
        vm.cool(address(generic));
    }
}
