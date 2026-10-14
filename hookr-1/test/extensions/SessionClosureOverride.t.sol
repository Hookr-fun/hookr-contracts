// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {RootSecurityBase} from "../utils/RootSecurityBase.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrGoverned} from "../../src/interfaces/IHookrGoverned.sol";
import {HookrFeeAdvisory} from "../../src/extensions/HookrFeeAdvisory.sol";
import {IHookrFeeAdvisory} from "../../src/interfaces/IHookrFeeAdvisory.sol";
import {HookrSessionAdvisory} from "../../src/extensions/HookrSessionAdvisory.sol";
import {IHookrSessionAdvisory} from "../../src/interfaces/IHookrSessionAdvisory.sol";
import {HookrSessionTiers} from "../../src/libraries/HookrSessionTiers.sol";
import {HookrMarketCalendar} from "../../src/libraries/HookrMarketCalendar.sol";

/// @notice The calendar library over its own storage, for the mark rules on their own.
contract MarkHarness {
    HookrMarketCalendar.Extension internal x;

    function dayKind(uint256 day) external view returns (uint256) {
        return HookrMarketCalendar.dayKind(x, day);
    }

    function mark(uint256 year, uint256 monthDay, uint256 kind, uint256 timestamp) external returns (uint256) {
        return HookrMarketCalendar.mark(x, year, monthDay, kind, timestamp);
    }

    function markOf(uint256 day) external view returns (uint256) {
        return HookrMarketCalendar.markOf(x, day);
    }
}

/// @notice The owner's override for unscheduled NYSE closures and early closes. MARK_SESSION_DAY(year, monthDay, mark),
///         queued through HookrSessionAdvisory's timelock (30 minutes in the release), marks a weekday the calendar
///         covers, from the current New York day on, as closed or as a 13:00 early close, or clears its mark, for every
///         pool that reads the shared calendar: the session advisory's pools on HookrRoot and on pair roots, and
///         HookrFeeAdvisory's session tiers. A day the calendar closes stays closed (an early close over a published
///         closure is refused), any other covered weekday takes its mark, and executing a mark voids every mark of its
///         date queued before it: the mark in force is replaced only by a mark queued after it took effect.
contract SessionClosureOverrideTest is RootSecurityBase {
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant SWAP_TOPIC =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    /// @dev HookrSessionAdvisory's namespace (erc7201:hookr.session.advisory). The calendar extension takes the
    ///      State's slots 1 to 4 and its `marks` mapping is the last of them: the namespace's slot + 4.
    bytes32 internal constant STATE_SLOT = 0x5d5d14a4b6eaf57142360288c8d49dac28d237caaa9ae18ae1b8baa3c2abf600;
    uint48 internal constant DELAY = 30 minutes;
    uint24 internal constant ADVISORY_CAP = 50_000;
    uint24 internal constant REGULAR = 1000;
    uint24 internal constant PRE = 4000;
    uint24 internal constant AFTER = 6000;
    uint24 internal constant NIGHT = 10_000;
    uint24 internal constant CLOSED = 20_000;
    uint256 internal constant BASE = 3000;
    uint8 internal constant NONE = 0;
    uint8 internal constant EARLY = 1;
    uint8 internal constant SHUT = 2;

    HookrSessionAdvisory internal session;
    PoolKey internal key;
    PoolId internal id;
    /// @dev 09:00 in New York on Thursday 2026-10-01: "now" for every test.
    uint256 internal start;

    function setUp() public {
        _setUpRootSecurity();
        session = new HookrSessionAdvisory(address(this), DELAY);
        _admit(address(session), session.configSchemaHash(), 150_000);
        start = _ny(2026, 10, 1, 9, 0, 0, true);
        vm.warp(start);
        key = _openSession(60);
        id = key.toId();
    }

    // ------------------------------------------------------------------ helpers

    function _admit(address advisory, bytes32 schema, uint32 gas) internal {
        IHookrRegistry.Admission memory a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: advisory,
            codeHash: advisory.codehash,
            schemaHash: schema,
            caps: HookrTypes.Caps(ADVISORY_CAP, 0, 0),
            gasLimit: gas,
            phaseMask: 1,
            feeOnly: true,
            failOpen: false
        });
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
    }

    function _schedule() internal pure returns (IHookrSessionAdvisory.Schedule memory) {
        return IHookrSessionAdvisory.Schedule(REGULAR, PRE, AFTER, NIGHT, CLOSED, 0, 0, 0);
    }

    function _advisedConfig(address advisory, uint32 gas) internal view returns (HookrTypes.PoolConfig memory pc) {
        pc = _config(address(rules));
        pc.advisory = advisory;
        pc.advisoryGasLimit = gas;
        pc.advisoryPhases = HookrTypes.BEFORE_SWAP;
    }

    /// @dev A tokenA/tokenB pool on the fixture's root and Rules, asked by the session advisory, with liquidity.
    function _openSession(int24 spacing) internal returns (PoolKey memory k) {
        k = _key(spacing);
        root.initializePool(
            k, _advisedConfig(address(session), 150_000), abi.encode(_rulesConfig()), abi.encode(_schedule()), SQRT_ONE
        );
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

    /// @dev Queues MARK_SESSION_DAY and executes it a delay later, then returns to the time it was queued.
    function _mark(uint16 year, uint16 monthDay, uint8 mark) internal {
        uint256 t = vm.getBlockTimestamp();
        session.queue(session.MARK_SESSION_DAY(), abi.encode(year, monthDay, mark));
        vm.warp(t + DELAY);
        session.markSessionDay(year, monthDay, mark);
        vm.warp(t);
    }

    /// @dev Appends `year` with the given closures and no early closes through the timelock, then returns to the time
    ///      it was queued.
    function _append(uint16 year, uint16[] memory closed) internal {
        uint16[] memory early = new uint16[](0);
        uint256 t = vm.getBlockTimestamp();
        session.queue(session.APPEND_YEAR(), abi.encode(year, closed, early));
        vm.warp(t + DELAY);
        session.appendYear(year, closed, early);
        vm.warp(t);
    }

    function _surcharge(uint256 t) internal view returns (uint256) {
        return session.surchargeAt(address(root), id, t);
    }

    /// @dev The LP fee the PoolManager charged a sell on `k` at the current time.
    function _swapFee(PoolKey memory k) internal returns (uint256) {
        vm.recordLogs();
        _genericSwap(k, false, -1e15, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (,,,,, uint24 f) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return f;
            }
        }
        revert("no swap event");
    }

    /// @dev The view and an executed sell through the root agree on the surcharge at `t`; returns to the current time.
    function _expect(uint256 t, uint256 surcharge) internal {
        assertEq(_surcharge(t), surcharge, "surchargeAt");
        uint256 back = vm.getBlockTimestamp();
        vm.warp(t);
        assertEq(_swapFee(key), BASE + surcharge, "executed LP fee");
        vm.warp(back);
    }

    function _tier(uint256 t) internal view returns (HookrMarketCalendar.Tier) {
        return session.sessionAt(t).tier;
    }

    function _dateKey(uint16 year, uint16 monthDay) internal view returns (bytes32) {
        return keccak256(abi.encode(session.MARK_SESSION_DAY(), abi.encode(year, monthDay)));
    }

    // ------------------------------------------------------------------ marks

    /// A closure on Tuesday 2026-10-06, an ordinary trading day of the compiled calendar: the day is closed, so is the
    /// evening before it, and its own evening is overnight before Wednesday's session.
    function test_mark_closedDay() public {
        _expect(_ny(2026, 10, 6, 11, 0, 0, true), REGULAR);
        _expect(_ny(2026, 10, 5, 21, 0, 0, true), NIGHT);
        _mark(2026, 1006, SHUT);
        _expect(_ny(2026, 10, 6, 11, 0, 0, true), CLOSED);
        _expect(_ny(2026, 10, 6, 5, 0, 0, true), CLOSED);
        _expect(_ny(2026, 10, 5, 19, 59, 59, true), AFTER);
        _expect(_ny(2026, 10, 5, 20, 0, 0, true), CLOSED);
        _expect(_ny(2026, 10, 6, 20, 0, 0, true), NIGHT);
        _expect(_ny(2026, 10, 7, 9, 30, 0, true), REGULAR);
        HookrMarketCalendar.Session memory s = session.sessionAt(_ny(2026, 10, 6, 11, 0, 0, true));
        assertEq(uint256(s.tier), uint256(HookrMarketCalendar.Tier.CLOSED));
        assertTrue(s.covered);
    }

    /// An early close on Wednesday 2026-10-07: regular until 13:00, after-hours until 17:00, then overnight.
    function test_mark_earlyClose() public {
        _mark(2026, 1007, EARLY);
        _expect(_ny(2026, 10, 7, 12, 59, 59, true), REGULAR);
        _expect(_ny(2026, 10, 7, 13, 0, 0, true), AFTER);
        _expect(_ny(2026, 10, 7, 16, 59, 59, true), AFTER);
        _expect(_ny(2026, 10, 7, 17, 0, 0, true), NIGHT);
        _expect(_ny(2026, 10, 8, 9, 30, 0, true), REGULAR);
        assertEq(session.sessionAt(_ny(2026, 10, 7, 12, 0, 0, true)).close, 13 hours);
    }

    /// A mark never opens a day the calendar closes: an early close on Thanksgiving or Christmas 2026 is refused when
    /// queued, and marking a published closure closed, or clearing a day without a mark, changes nothing. A published
    /// early close can be marked closed, that closure replaced by an early close queued later, and the mark cleared:
    /// the day is the compiled early close again.
    function test_mark_neverOpensWhatTheCalendarCloses() public {
        bytes32 kind = session.MARK_SESSION_DAY();
        vm.expectRevert(abi.encodeWithSelector(HookrMarketCalendar.InvalidMark.selector, 4));
        session.queue(kind, abi.encode(uint16(2026), uint16(1126), EARLY));
        vm.expectRevert(abi.encodeWithSelector(HookrMarketCalendar.InvalidMark.selector, 4));
        session.queue(kind, abi.encode(uint16(2026), uint16(1225), EARLY));
        _mark(2026, 1126, SHUT);
        _mark(2026, 1225, NONE);
        _expect(_ny(2026, 11, 26, 11, 0, 0, false), CLOSED);
        _expect(_ny(2026, 12, 25, 11, 0, 0, false), CLOSED);
        _expect(_ny(2026, 11, 27, 11, 0, 0, false), REGULAR);
        _expect(_ny(2026, 11, 27, 13, 30, 0, false), AFTER);
        _expect(_ny(2026, 11, 26, 21, 0, 0, false), NIGHT);
        _mark(2026, 1127, SHUT);
        _expect(_ny(2026, 11, 27, 11, 0, 0, false), CLOSED);
        _expect(_ny(2026, 11, 26, 21, 0, 0, false), CLOSED);
        _mark(2026, 1127, EARLY);
        _expect(_ny(2026, 11, 27, 11, 0, 0, false), REGULAR);
        _expect(_ny(2026, 11, 27, 13, 30, 0, false), AFTER);
        assertEq(session.sessionDayMark(2026, 1127), EARLY);
        _mark(2026, 1127, NONE);
        assertEq(session.sessionDayMark(2026, 1127), NONE, "cleared");
        _expect(_ny(2026, 11, 27, 11, 0, 0, false), REGULAR);
        _expect(_ny(2026, 11, 27, 13, 30, 0, false), AFTER);
        assertEq(session.sessionAt(_ny(2026, 11, 27, 11, 0, 0, false)).close, 13 hours, "the compiled early close");
    }

    /// A cleared mark leaves the day to the calendar: a trading day marked closed trades again.
    function test_mark_clearedDayFollowsTheCalendar() public {
        _mark(2026, 1006, SHUT);
        _expect(_ny(2026, 10, 6, 11, 0, 0, true), CLOSED);
        _mark(2026, 1006, NONE);
        _expect(_ny(2026, 10, 6, 11, 0, 0, true), REGULAR);
        _expect(_ny(2026, 10, 5, 21, 0, 0, true), NIGHT);
        assertEq(session.sessionDayMark(2026, 1006), NONE);
    }

    /// Marks follow the New York day across a daylight-saving switch: Monday 2026-11-02, the first weekday after the
    /// fall-back Sunday, marked closed turns that Sunday's 20:00 EST evening closed; Monday 2026-03-09, the first
    /// weekday after the spring-forward Sunday, marked as an early close closes at 13:00 EDT.
    function test_mark_followsTheNewYorkDayAcrossDst() public {
        _expect(_ny(2026, 11, 1, 20, 0, 0, false), NIGHT);
        _mark(2026, 1102, SHUT);
        _expect(_ny(2026, 11, 1, 19, 59, 59, false), CLOSED);
        _expect(_ny(2026, 11, 1, 20, 0, 0, false), CLOSED);
        _expect(_ny(2026, 11, 2, 11, 0, 0, false), CLOSED);
        _expect(_ny(2026, 11, 2, 20, 0, 0, false), NIGHT);
        _expect(_ny(2026, 11, 3, 9, 30, 0, false), REGULAR);
        uint256 t = vm.getBlockTimestamp();
        vm.warp(_ny(2026, 3, 1, 9, 0, 0, false));
        // March 2026 lies before this test's "now"; mark it from a time before it.
        _mark(2026, 309, EARLY);
        vm.warp(t);
        _expect(_ny(2026, 3, 9, 12, 59, 59, true), REGULAR);
        _expect(_ny(2026, 3, 9, 13, 0, 0, true), AFTER);
        _expect(_ny(2026, 3, 9, 17, 0, 0, true), NIGHT);
    }

    /// Only the owner, only through the timelock, and within the operation's grace; a queued mark can be cancelled.
    function test_mark_ownerThroughTheTimelock() public {
        bytes32 kind = session.MARK_SESSION_DAY();
        bytes memory args = abi.encode(uint16(2026), uint16(1006), SHUT);
        vm.prank(address(0xbad));
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, address(0xbad)));
        session.queue(kind, args);
        bytes32 op = session.operationHash(kind, args);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NotReady.selector, op, uint48(0)));
        session.markSessionDay(2026, 1006, SHUT);
        assertEq(session.queue(kind, args), op);
        uint48 ready = uint48(vm.getBlockTimestamp()) + DELAY;
        assertEq(session.readyAt(op), ready);
        vm.warp(ready - 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NotReady.selector, op, ready));
        session.markSessionDay(2026, 1006, SHUT);
        vm.warp(ready);
        vm.prank(address(0xbad));
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, address(0xbad)));
        session.markSessionDay(2026, 1006, SHUT);
        session.markSessionDay(2026, 1006, SHUT);
        assertEq(session.sessionDayMark(2026, 1006), SHUT);
        assertEq(session.readyAt(op), 0, "consumed");
        // A cancelled mark cannot execute.
        args = abi.encode(uint16(2026), uint16(1013), SHUT);
        op = session.queue(kind, args);
        session.cancel(op);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NotReady.selector, op, uint48(0)));
        session.markSessionDay(2026, 1013, SHUT);
        // A queued mark past its grace expires.
        args = abi.encode(uint16(2026), uint16(1208), SHUT);
        op = session.queue(kind, args);
        uint48 due = uint48(vm.getBlockTimestamp()) + DELAY;
        vm.warp(uint256(due) + session.GRACE() + 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Expired.selector, op, due + session.GRACE()));
        session.markSessionDay(2026, 1208, SHUT);
        assertEq(session.sessionDayMark(2026, 1013), NONE);
        assertEq(session.sessionDayMark(2026, 1208), NONE);
    }

    /// Checked when queued and again when executed: a known mark, a weekday date from 2026 and from the current New
    /// York day on, inside the covered calendar, canonical arguments.
    function test_mark_refusals() public {
        bytes32 kind = session.MARK_SESSION_DAY();
        vm.expectRevert(abi.encodeWithSelector(HookrMarketCalendar.InvalidMark.selector, 1));
        session.queue(kind, abi.encode(uint16(2026), uint16(1006), uint8(3)));
        vm.expectRevert(abi.encodeWithSelector(HookrMarketCalendar.InvalidMark.selector, 1));
        session.queue(kind, abi.encode(uint16(2026), uint16(1006), uint8(255)));
        vm.expectRevert(abi.encodeWithSelector(HookrMarketCalendar.InvalidDate.selector, 1003));
        session.queue(kind, abi.encode(uint16(2026), uint16(1003), SHUT)); // a Saturday
        vm.expectRevert(abi.encodeWithSelector(HookrMarketCalendar.InvalidDate.selector, 230));
        session.queue(kind, abi.encode(uint16(2027), uint16(230), SHUT));
        vm.expectRevert(abi.encodeWithSelector(HookrMarketCalendar.InvalidDate.selector, 1301));
        session.queue(kind, abi.encode(uint16(2027), uint16(1301), SHUT));
        vm.expectRevert(abi.encodeWithSelector(HookrMarketCalendar.InvalidDate.selector, 0));
        session.queue(kind, abi.encode(uint16(2027), uint16(0), SHUT));
        vm.expectRevert(abi.encodeWithSelector(HookrMarketCalendar.InvalidDate.selector, 1232));
        session.queue(kind, abi.encode(uint16(2027), uint16(1232), SHUT));
        vm.expectRevert(abi.encodeWithSelector(HookrMarketCalendar.InvalidMark.selector, 2));
        session.queue(kind, abi.encode(uint16(2025), uint16(1006), SHUT));
        vm.expectRevert(abi.encodeWithSelector(HookrMarketCalendar.InvalidMark.selector, 2));
        session.queue(kind, abi.encode(uint16(0), uint16(301), SHUT));
        vm.expectRevert(abi.encodeWithSelector(HookrMarketCalendar.InvalidMark.selector, 2));
        session.queue(kind, abi.encode(uint16(2026), uint16(930), SHUT)); // yesterday in New York
        vm.expectRevert(abi.encodeWithSelector(HookrMarketCalendar.InvalidMark.selector, 3));
        session.queue(kind, abi.encode(uint16(2031), uint16(304), SHUT)); // 2031 is not appended
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NonCanonicalArguments.selector, kind));
        session.queue(kind, abi.encodePacked(abi.encode(uint16(2026), uint16(1006), SHUT), uint256(0)));
        vm.expectRevert();
        session.queue(kind, abi.encode(uint256(70_000), uint16(1006), SHUT));
        vm.expectRevert();
        session.queue(kind, abi.encode(uint16(2026), uint16(1006)));
        // The current New York day itself can be marked: a closure from the moment it executes.
        _mark(2026, 1001, SHUT);
        assertEq(_surcharge(vm.getBlockTimestamp() + DELAY), CLOSED);
        assertEq(_surcharge(vm.getBlockTimestamp() - 1 hours), CLOSED, "the whole day, also before the mark executed");
        // A day that passes between queue and execution is refused when the mark would execute.
        session.queue(kind, abi.encode(uint16(2026), uint16(1002), SHUT));
        vm.warp(_ny(2026, 10, 3, 0, 0, 1, true));
        vm.expectRevert(abi.encodeWithSelector(HookrMarketCalendar.InvalidMark.selector, 2));
        session.markSessionDay(2026, 1002, SHUT);
        assertEq(session.sessionDayMark(2026, 1002), NONE);
    }

    /// Queue-time admission covers every kind: unknown kinds are refused, APPEND_YEAR needs canonical arguments (its
    /// year is still checked when it executes) and TRANSFER_OWNER is queued and executed as before.
    function test_queue_knownKindsOnly() public {
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.UnknownOperation.selector, keccak256("MARK_DAY")));
        session.queue(keccak256("MARK_DAY"), abi.encode(uint16(2026), uint16(1006), SHUT));
        bytes32 append = session.APPEND_YEAR();
        uint16[] memory none = new uint16[](0);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NonCanonicalArguments.selector, append));
        session.queue(append, abi.encodePacked(abi.encode(uint16(2031), none, none), uint256(0)));
        session.queue(append, abi.encode(uint16(2032), none, none));
        session.queue(append, abi.encode(uint16(2031), none, none));
        bytes32 transfer = session.TRANSFER_OWNER();
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.InvalidAddress.selector, address(0)));
        session.queue(transfer, abi.encode(address(0)));
        session.queue(transfer, abi.encode(address(0xA11CE)));
        vm.warp(vm.getBlockTimestamp() + DELAY);
        vm.expectRevert(abi.encodeWithSelector(HookrMarketCalendar.InvalidYear.selector, 2032));
        session.appendYear(2032, none, none);
        session.appendYear(2031, none, none);
        assertEq(session.lastCoveredYear(), 2031);
        session.transferOwnership(address(0xA11CE));
        assertEq(session.pendingOwner(), address(0xA11CE));
    }

    /// Executing a mark voids the marks of its date queued before it, so a stale queued mark cannot undo a later
    /// decision; a mark queued after it replaces it, and the marks of other dates and the epochs of other kinds are
    /// untouched.
    function test_mark_replacedOnlyByALaterQueuedMark() public {
        bytes32 kind = session.MARK_SESSION_DAY();
        bytes memory closedArgs = abi.encode(uint16(2026), uint16(1008), SHUT);
        bytes memory earlyArgs = abi.encode(uint16(2026), uint16(1008), EARLY);
        bytes memory otherArgs = abi.encode(uint16(2026), uint16(1009), SHUT);
        bytes32 closedOp = session.queue(kind, closedArgs);
        session.queue(kind, otherArgs);
        vm.warp(start + 60);
        session.queue(kind, earlyArgs);
        vm.warp(start + 60 + DELAY);
        session.markSessionDay(2026, 1008, EARLY);
        assertEq(session.sessionDayMark(2026, 1008), EARLY, "the later decision, an early close");
        assertEq(session.epoch(_dateKey(2026, 1008)), 1, "the date's epoch moved");
        assertEq(session.epoch(_dateKey(2026, 1009)), 0, "another date's did not");
        assertEq(session.epoch(kind), 0, "nor the kind's own key");
        assertEq(session.epoch(session.APPEND_YEAR()), 0);
        assertEq(session.epoch(session.TRANSFER_OWNER()), 0);
        bytes32 stale = session.operationHash(kind, closedArgs);
        assertTrue(stale != closedOp, "a new epoch, a new id");
        assertGt(session.readyAt(closedOp), 0, "the old id stays queued and cannot execute");
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NotReady.selector, stale, uint48(0)));
        session.markSessionDay(2026, 1008, SHUT);
        assertEq(session.sessionDayMark(2026, 1008), EARLY);
        session.markSessionDay(2026, 1009, SHUT);
        assertEq(session.sessionDayMark(2026, 1009), SHUT, "another date's queued mark still executes");
        session.queue(kind, closedArgs);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        session.markSessionDay(2026, 1008, SHUT);
        assertEq(session.sessionDayMark(2026, 1008), SHUT, "a mark queued after it replaces it");
        assertEq(session.epoch(_dateKey(2026, 1008)), 2);
    }

    /// Days of a year the calendar does not cover yet cannot be marked; once the year is appended its weekdays can, an
    /// appended closure refuses an early close, and a marked appended day follows its mark.
    function test_mark_appendedYears() public {
        bytes32 kind = session.MARK_SESSION_DAY();
        vm.expectRevert(abi.encodeWithSelector(HookrMarketCalendar.InvalidMark.selector, 3));
        session.queue(kind, abi.encode(uint16(2031), uint16(304), SHUT));
        uint16[] memory closed = new uint16[](2);
        (closed[0], closed[1]) = (101, 1127);
        _append(2031, closed);
        _expect(_ny(2031, 3, 4, 11, 0, 0, false), REGULAR);
        _mark(2031, 304, SHUT);
        _mark(2031, 305, EARLY);
        _expect(_ny(2031, 3, 4, 11, 0, 0, false), CLOSED);
        _expect(_ny(2031, 3, 3, 21, 0, 0, false), CLOSED);
        _expect(_ny(2031, 3, 5, 13, 30, 0, false), AFTER);
        _expect(_ny(2031, 3, 6, 11, 0, 0, false), REGULAR);
        assertTrue(session.sessionAt(_ny(2031, 3, 4, 11, 0, 0, false)).covered);
        vm.expectRevert(abi.encodeWithSelector(HookrMarketCalendar.InvalidMark.selector, 4));
        session.queue(kind, abi.encode(uint16(2031), uint16(1127), EARLY));
        vm.expectRevert(abi.encodeWithSelector(HookrMarketCalendar.InvalidMark.selector, 3));
        session.queue(kind, abi.encode(uint16(2032), uint16(105), SHUT));
        assertEq(session.lastCoveredYear(), 2031, "a mark never extends the calendar");
    }

    /// The mark reaches every pool that reads the shared calendar: another session pool on the root, a pair root's
    /// pool (keyed by the pair root, bound through bindPair) and a HookrFeeAdvisory pool with session tiers.
    function test_mark_reachesEveryCalendarReader() public {
        PoolKey memory second = _openSession(10);
        address pair = address(0x9A12);
        PoolId pairPool = PoolId.wrap(keccak256("pair pool"));
        uint32 pairGas = session.MIN_PAIR_GAS();
        vm.prank(pair);
        session.bindPair(pairPool, ADVISORY_CAP, pairGas, abi.encode(_schedule()));
        HookrFeeAdvisory fee = new HookrFeeAdvisory(address(this), 1 days, registry, address(session));
        _admit(address(fee), fee.configSchemaHash(), 200_000);
        vm.warp(start);
        PoolKey memory tiered = _key(100);
        root.initializePool(
            tiered,
            _advisedConfig(address(fee), 200_000),
            abi.encode(_rulesConfig()),
            abi.encode(
                IHookrFeeAdvisory.Config({
                    cap: 30_000,
                    surcharge: 500,
                    premium0: 0,
                    premium1: 0,
                    maxStep: 5000,
                    minInterval: 60,
                    maxTtl: 1 hours
                }),
                HookrSessionTiers.Tiers(REGULAR, PRE, AFTER, NIGHT, CLOSED, 0, 0, 0)
            ),
            SQRT_ONE
        );
        _addLiquidity(tiered, -6000, 6000, 1e24);
        bool sellZeroForOne = !_isBuyZeroForOne(tiered);
        uint256 t = _ny(2026, 10, 6, 11, 0, 0, true);
        vm.warp(t);
        assertEq(fee.surcharge(tiered.toId(), sellZeroForOne), 500 + REGULAR);
        assertEq(_swapFee(tiered), BASE + 500 + REGULAR);
        assertEq(session.surchargeAt(address(root), second.toId(), t), REGULAR);
        vm.prank(pair);
        assertEq(session.surchargeForSwap(pairPool, true, -1, 0, "", address(0)), REGULAR);
        vm.warp(start);
        _mark(2026, 1006, SHUT);
        vm.warp(t);
        assertEq(fee.surcharge(tiered.toId(), sellZeroForOne), 500 + CLOSED, "the fee advisory's tier follows it");
        assertEq(_swapFee(tiered), BASE + 500 + CLOSED, "and charges it");
        assertEq(session.surchargeAt(address(root), second.toId(), t), CLOSED, "so does every session pool");
        assertEq(_swapFee(second), BASE + CLOSED);
        vm.prank(pair);
        assertEq(session.surchargeForSwap(pairPool, true, -1, 0, "", address(0)), CLOSED, "and a pair root's pool");
    }

    /// The marks live in the session advisory's namespace, two bits a day in 128-day words: SHUT (2) for a closure and
    /// EARLY (1) for an early close, at keccak256(word, namespace + 4), bits 2 x (day % 128) of the word, the day
    /// counted from 2026-01-01. Clearing a mark zeroes its two bits and leaves its neighbours.
    function test_mark_storage() public {
        _mark(2026, 1006, SHUT);
        _mark(2026, 1007, EARLY);
        uint256 i = HookrMarketCalendar.dayOf(2026, 10, 6) - HookrMarketCalendar.EPOCH_DAY;
        assertEq(i >> 7, (i + 1) >> 7, "both days in one word");
        bytes32 slot = keccak256(abi.encode(i >> 7, uint256(STATE_SLOT) + 4));
        uint256 word = uint256(vm.load(address(session), slot));
        assertEq((word >> ((i & 127) * 2)) & 3, 2, "closed");
        assertEq((word >> (((i + 1) & 127) * 2)) & 3, 1, "early close");
        assertEq(word & ~(uint256(15) << ((i & 127) * 2)), 0, "nothing else");
        _mark(2026, 1006, NONE);
        word = uint256(vm.load(address(session), slot));
        assertEq(word, uint256(1) << (((i + 1) & 127) * 2), "only the early close is left");
        // The calendar extension's other slots are untouched: no year appended.
        assertEq(uint256(vm.load(address(session), bytes32(uint256(STATE_SLOT) + 1))), 0, "endDay and lastYear");
    }

    /// The event names the New York day and the date; the view reads the mark back and refuses a date that is not a
    /// weekday.
    function test_mark_eventAndView() public {
        bytes32 kind = session.MARK_SESSION_DAY();
        assertEq(session.sessionDayMark(2026, 1006), NONE);
        session.queue(kind, abi.encode(uint16(2026), uint16(1006), SHUT));
        vm.warp(vm.getBlockTimestamp() + DELAY);
        vm.expectEmit(true, true, true, true, address(session));
        emit IHookrSessionAdvisory.SessionDayMarked(HookrMarketCalendar.dayOf(2026, 10, 6), 2026, 1006, SHUT);
        session.markSessionDay(2026, 1006, SHUT);
        assertEq(session.sessionDayMark(2026, 1006), SHUT);
        assertEq(session.MARK_NONE(), NONE);
        assertEq(session.MARK_EARLY_CLOSE(), EARLY);
        assertEq(session.MARK_CLOSED(), SHUT);
        assertEq(session.MARK_SESSION_DAY(), keccak256("MARK_SESSION_DAY"));
        vm.expectRevert(abi.encodeWithSelector(HookrMarketCalendar.InvalidDate.selector, 1003));
        session.sessionDayMark(2026, 1003);
    }

    /// Whatever the mark, every covered weekday is at least as closed as the compiled calendar says, and exactly its
    /// mark when it has one; no other day moves, weekends cannot be marked and an early close over a closure is
    /// refused.
    function testFuzz_mark_neverBelowTheCalendar(uint256 dayIndex, uint8 kind, uint256 otherIndex) public {
        MarkHarness h = new MarkHarness();
        MarkHarness unmarked = new MarkHarness();
        uint256 epoch = HookrMarketCalendar.EPOCH_DAY;
        uint256 day = epoch + bound(dayIndex, 0, HookrMarketCalendar.CONSTANT_DAYS - 1);
        uint256 other = epoch + bound(otherIndex, 0, HookrMarketCalendar.CONSTANT_DAYS - 1);
        kind = uint8(bound(kind, 0, 2));
        uint256 published = unmarked.dayKind(day);
        (uint256 y, uint256 m, uint256 d) = HookrMarketCalendar.civil(day);
        uint256 w = HookrMarketCalendar.weekday(day);
        if (w == 0 || w == 6) {
            vm.expectRevert(abi.encodeWithSelector(HookrMarketCalendar.InvalidDate.selector, m * 100 + d));
            h.mark(y, m * 100 + d, kind, epoch * 1 days);
            return;
        }
        if (kind == EARLY && published == SHUT) {
            vm.expectRevert(abi.encodeWithSelector(HookrMarketCalendar.InvalidMark.selector, 4));
            h.mark(y, m * 100 + d, kind, epoch * 1 days);
            return;
        }
        assertEq(h.mark(y, m * 100 + d, kind, epoch * 1 days), day);
        assertEq(h.markOf(day), kind);
        uint256 marked = h.dayKind(day);
        assertEq(marked, kind == NONE || published == SHUT ? published : kind, "the mark, or the calendar");
        assertGe(marked, published, "never below the calendar");
        if (other != day) assertEq(h.dayKind(other), unmarked.dayKind(other), "no other day moves");
    }

    // ------------------------------------------------------------------ gas

    /// Cold session lookups (`sessionAt`, as HookrFeeAdvisory's tiers and every session swap read it) with marks in
    /// force. A weekday the calendar does not close reads one more storage word than the base release, the day's 128-day
    /// word of marks, and the next day's lookup reads it warm unless it crosses into the next word; a weekend, a
    /// published closure and an uncovered weekday read none. Logged for the gas tables (the base release's lookups,
    /// measured the same way, give the delta); every lookup stays far inside the 40,000 gas the tiers give the read
    /// (HookrSessionTiers.READ_GAS).
    function test_gas_sessionLookup() public {
        uint16[] memory none = new uint16[](0);
        _append(2031, none);
        _mark(2026, 1006, SHUT);
        uint256[8] memory times = [
            _ny(2026, 9, 29, 11, 0, 0, true),
            _ny(2026, 9, 29, 21, 0, 0, true),
            _ny(2026, 10, 3, 12, 0, 0, true),
            _ny(2026, 11, 26, 12, 0, 0, false),
            _ny(2026, 10, 6, 11, 0, 0, true),
            _ny(2031, 3, 4, 21, 0, 0, false),
            _ny(2032, 3, 4, 21, 0, 0, false),
            _ny(2027, 1, 19, 21, 0, 0, false)
        ];
        string[8] memory label = [
            "trading day",
            "trading day evening, two lookups",
            "weekend",
            "compiled closure",
            "marked closure",
            "appended year evening",
            "uncovered year evening",
            "evening at a 128-day word boundary"
        ];
        // 2027-01-19 and 2027-01-20 sit in different 128-day words.
        uint256 boundary = HookrMarketCalendar.dayOf(2027, 1, 19) - HookrMarketCalendar.EPOCH_DAY;
        assertEq(boundary & 127, 127, "the last day of its word");
        uint256 worst;
        for (uint256 i; i < times.length; ++i) {
            vm.cool(address(session));
            uint256 g = gasleft();
            session.sessionAt(times[i]);
            uint256 used = g - gasleft();
            console2.log(label[i], used);
            if (used > worst) worst = used;
        }
        assertLt(worst, HookrSessionTiers.READ_GAS / 2, "far inside the tiers' read gas");
    }
}
