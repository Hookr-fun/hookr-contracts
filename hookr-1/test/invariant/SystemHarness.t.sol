// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {HookrFeeAdvisory} from "../../src/extensions/HookrFeeAdvisory.sol";
import {HookrSessionAdvisory} from "../../src/extensions/HookrSessionAdvisory.sol";
import {IHookrSessionAdvisory} from "../../src/interfaces/IHookrSessionAdvisory.sol";
import {HookrMarketCalendar} from "../../src/libraries/HookrMarketCalendar.sol";
import {SystemHandler} from "./SystemHandler.sol";
import {SystemDeploy} from "./SystemDeploy.sol";
import {SysFeeAdapter} from "./SystemHelpers.sol";

/// @notice The campaign's own reach, pinned: where it starts, which settings and states its handlers reach from
///         dictionary-sized seeds, and that its exact fee checks hold, and fire, under a Uniswap protocol fee and a
///         pool's own base LP fee.
contract SystemHarnessTest is Test {
    using PoolIdLibrary for PoolKey;

    SystemHandler internal h;

    function setUp() public {
        h = new SystemHandler();
    }

    function _hits(string memory label) internal view returns (uint256) {
        return h.hits(keccak256(bytes(label)));
    }

    function _noViolations() internal view {
        if (h.violations() != 0) {
            string[] memory log = h.violationLog();
            for (uint256 i; i < log.length; ++i) {
                console2.log(log[i]);
            }
            assertEq(h.violations(), 0, log[0]);
        }
    }

    function _setProtocolFee(PoolKey memory k, uint24 zeroForOne, uint24 oneForZero) internal {
        SysFeeAdapter a = h.feeAdapter();
        vm.prank(a.feeSetter());
        a.setPoolOverride(k.toId(), (oneForZero << 12) | zeroForOne);
        a.triggerFeeUpdate(k);
    }

    /// @dev Gives pool `p` a base LP fee of `base` in every read of its root config (the root prices from storage).
    function _mockBase(uint256 p, uint24 base) internal {
        PoolKey memory k = h.key(p);
        HookrRoot r = HookrRoot(address(k.hooks));
        HookrTypes.PoolConfig memory pc = r.poolConfig(k.toId());
        pc.baseLpFeePips = base;
        vm.mockCall(address(r), abi.encodeCall(r.poolConfig, (k.toId())), abi.encode(pc));
    }

    function _swapUntilFlagged(uint256 tries) internal {
        for (uint256 i; i < tries && h.violations() == 0; ++i) {
            h.swapRouter(i);
        }
    }

    function _has(string memory s, string memory part) internal pure returns (bool) {
        return vm.indexOf(s, part) != type(uint256).max;
    }

    // ───────────── INV-R1: a decaying, capped family is live at the start; the cap is probed at its edge

    function test_R1_familyEIsMidDecayAndGuardedAtCampaignStart() public view {
        SystemDeploy.Meta memory m = h.meta(6);
        assertEq(m.family, h.famE());
        PoolId id = h.key(6).toId();
        HookrTypes.RulesConfig memory c = h.rules1().config(id);
        uint256 elapsed = block.timestamp - m.launchedAt;
        assertEq(elapsed, 900);
        assertLt(elapsed, c.snipeDecaySeconds, "decay over before the campaign starts");
        assertGe(c.guardEndBlock - block.number, 300, "guard shorter than 300 blocks at the start");
        assertEq(c.maxBuyQuoteAmount, 5e19);
        assertEq(h.root1().poolConfig(id).baseLpFeePips, 10_000);
    }

    /// Family E's buys are checked exactly (S1) part way down the decay, at its own 1% base.
    function test_R1_R6_familyEBuysPricedMidDecayAtItsOwnBase() public {
        uint256 checks = h.lpFeeChecks();
        for (uint256 i; i < 120 && _hits("swap.buyMidDecay") < 3; ++i) {
            h.swapRouter(i);
        }
        assertGe(_hits("swap.buyMidDecay"), 3, "no guarded buy priced mid-decay");
        assertGt(h.lpFeeChecks(), checks);
        _noViolations();
    }

    /// Near-cap buys: past the room they are refused, within it they clear, and no check fires.
    function test_R1_nearCapBuysRefusedPastTheRoomAndClearWithinIt() public {
        for (uint256 i; i < 80; ++i) {
            h.nearCapBuy(i);
            if (i % 8 == 7) h.clock(i);
        }
        assertGt(_hits("nearCap.refusedPastRoom"), 0, "no buy past the room was tried");
        assertGt(_hits("nearCap.clearedWithinRoom"), 0, "no buy within the room cleared");
        assertGt(h.guardBuys(), 0);
        _noViolations();
    }

    // ───────────── INV-R2: dictionary-sized seeds (high bits zero) still spread every setting

    function test_R2_smallSeedsSpreadDevLaunchSettings() public {
        for (uint256 i; i < 200 && h.familyCount() < 24; ++i) {
            h.launchDevBuy(i);
            if (i % 4 == 3) h.clock(i);
        }
        assertGe(h.devLaunches(), 10, "too few dev launches");
        string[10] memory labels = [
            "devbuy.decayingSnipe",
            "devbuy.flatSnipe",
            "devbuy.dynamicFee",
            "devbuy.staticFee",
            "devbuy.royalty",
            "devbuy.noRoyalty",
            "devbuy.shareAboveFloor",
            "devbuy.baseOther",
            "devbuy.base3000",
            "devbuy.lockShort"
        ];
        for (uint256 j; j < labels.length; ++j) {
            assertGt(_hits(labels[j]), 0, labels[j]);
        }
        _noViolations();
    }

    function test_R2_smallSeedsSpreadClockSteps() public {
        for (uint256 i; i < 200; ++i) {
            h.clock(i);
        }
        uint256 day = _hits("clock.day");
        assertGt(day, 0);
        assertLt(day, 40, "one-day jumps far above one in ten");
        assertGt(_hits("clock.small"), 30);
        assertGt(_hits("clock.hour"), 50);
        assertGt(_hits("clock.anyTime"), 20);
    }

    function test_R2_smallSeedsSpreadPairSwapBranches() public {
        for (uint256 i; i < 100; ++i) {
            h.pairSwap(i);
        }
        uint256 squat = _hits("pair.squatRefused");
        assertGt(squat, 0);
        assertLt(squat, 45, "the squat branch runs far more than one in four");
        assertGt(_hits("pair.swap"), 40);
        assertGt(h.pairDeltaChecks(), 40);
        _noViolations();
    }

    // ───────────── INV-R3: the campaign starts in a session and its clock reaches every tier

    function test_R3_campaignStartsPreMarketBeforeAHolidayAndAnEarlyClose() public view {
        uint256 t0 = block.timestamp;
        assertEq(t0, h.campaignStart());
        // Wednesday 2026-11-25, 09:00 EST (UTC-5).
        assertEq(t0, HookrMarketCalendar.dayOf(2026, 11, 25) * 1 days + 14 hours);
        assertEq(HookrMarketCalendar.weekday(t0 / 1 days), 3);
        (,,, IHookrSessionAdvisory.Bound memory b) = h.frozen();
        HookrSessionAdvisory s = h.sessionAdvisory();
        address r = address(h.root1());
        PoolId id = h.key(3).toId();
        assertEq(s.surchargeAt(r, id, t0), b.preMarketPips, "not pre-market at the start");
        // Thursday 2026-11-26 is Thanksgiving: closed at noon.
        assertEq(s.surchargeAt(r, id, t0 + 1 days + 3 hours), b.closedPips, "Thanksgiving not closed");
        // Friday 2026-11-27 closes at 13:00: regular at noon, after-hours at 14:00.
        assertEq(s.surchargeAt(r, id, t0 + 2 days + 3 hours), b.regularPips);
        assertEq(s.surchargeAt(r, id, t0 + 2 days + 5 hours), b.afterHoursPips, "no early close on Friday");
    }

    function test_R3_clockReachesEverySessionTierAndRamp() public {
        (,,, IHookrSessionAdvisory.Bound memory b) = h.frozen();
        HookrSessionAdvisory s = h.sessionAdvisory();
        address r = address(h.root1());
        PoolId id = h.key(3).toId();
        uint256 seen;
        uint256 i;
        for (; i < 600 && seen != 63; ++i) {
            h.clock(i);
            uint256 v = s.surchargeAt(r, id, block.timestamp);
            if (v == b.regularPips) seen |= 1;
            else if (v == b.preMarketPips) seen |= 2;
            else if (v == b.afterHoursPips) seen |= 4;
            else if (v == b.overnightPips) seen |= 8;
            else if (v == b.closedPips) seen |= 16;
            else seen |= 32;
        }
        console2.log("clock steps to reach every tier and a ramp", i);
        assertEq(seen, 63, "a session tier or ramp was never reached");
    }

    // ───────────── INV-R4 / INV-R7: exact fee checks under a Uniswap protocol fee

    function test_R4_R7_exactFeeChecksHoldUnderAProtocolFee() public {
        for (uint256 p; p < h.poolCount(); ++p) {
            _setProtocolFee(h.key(p), 1000, 700);
        }
        for (uint256 q; q < h.pairCount(); ++q) {
            _setProtocolFee(h.pairKey(q), 400, 1000);
        }
        for (uint256 i; i < 80; ++i) {
            h.swapRouter(i);
            h.pairSwap(i);
        }
        assertGt(h.protocolFeeChecks(), 40, "few exact checks under the protocol fee");
        assertGt(h.pairDeltaChecks(), 0);
        assertGt(h.dynamicChecks(), 0, "no DF-02 check on an executed swap fee");
        _noViolations();
    }

    /// A wrong expected LP fee is flagged under a protocol fee (the exact check used to be skipped there).
    function test_R4_wrongFeeFlaggedUnderAProtocolFee() public {
        _setProtocolFee(h.key(4), 1000, 1000);
        _mockBase(4, 2000);
        _swapUntilFlagged(200);
        assertGt(h.violations(), 0, "a 1,000 pip error went unflagged under a protocol fee");
        string memory first = h.violationLog()[0];
        assertTrue(_has(first, "S1") && _has(first, "pool 4") && _has(first, "protocol 1000"), first);
    }

    // ───────────── INV-R6: the base LP fee is the pool's own, and the edges are reached

    /// The fee checks read the pool's base LP fee from its root (it used to be a hard-coded 3,000).
    function test_R6_baseFeeReadFromThePoolConfig() public {
        _mockBase(4, 2000);
        _swapUntilFlagged(200);
        assertGt(h.violations(), 0, "a base fee other than the pool's went unflagged");
        string memory first = h.violationLog()[0];
        assertTrue(_has(first, "S1") && _has(first, "pool 4") && _has(first, "expected LP fee 2000"), first);
    }

    function test_R6_devLaunchAndSwapEdgesReached() public {
        for (uint256 i; i < 400 && h.familyCount() < 24; ++i) {
            h.launchDevBuy(uint256(keccak256(abi.encode("edges", i))));
            h.swapRouter(i);
            if (i % 3 == 2) h.clock(i);
        }
        (string[] memory labels, uint256[] memory counts) = h.coverage();
        for (uint256 j; j < labels.length; ++j) {
            if (_has(labels[j], "devbuy")) console2.log(labels[j], counts[j]);
        }
        assertGt(_hits("devbuy.baseOther"), 0);
        assertGt(_hits("devbuy.longGuard"), 0, "no guard of 10,000 blocks or more");
        assertGt(_hits("devbuy.lockMax"), 0, "no dev buy locked for the maximum");
        assertGt(_hits("devbuy.lockLong"), 0);
        assertGt(_hits("devbuy.buyAtCap"), 0);
        assertGt(_hits("swap.tinyAmount"), 0);
        _noViolations();
        // Every party still exits after the longest lock.
        h.liveness();
        _noViolations();
    }
}
