// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrReferralRegistry} from "../../src/engagement/HookrReferralRegistry.sol";
import {HookrPrograms} from "../../src/engagement/HookrPrograms.sol";
import {IHookrPrograms} from "../../src/interfaces/IHookrPrograms.sol";
import {HookrProgramTypes as P} from "../../src/types/HookrProgramTypes.sol";

/// @notice G-10 (phase-one review, Appendix A, Informational): releaseUnusedCash on an Immediate program ignored `day`
///         but logged the caller's value, and refundUnapprovedBux reused the same event with day 0, so a log reader
///         could not tell an unapproved-Bux cancellation refund from a day's release.
/// @dev The first half is fixed in code: Immediate programs hold no cash and releaseUnusedCash refuses them for any
///      day (dayEnd), and a daily program's day is range-checked. The second half is documented, not changed: the
///      refund logs exactly UnusedCashReleased(id, 0, cashBudget), the event a day-0 release logs, and nothing else
///      from HookrPrograms, and `program(id).cancelled`, true only after the refund, tells them apart, as the NatSpec
///      on refundUnapprovedBux and the release's programs docs say. No service, SDK or app code reads the event. These tests pin both.
contract HookrProgramsRefundEventsTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    event UnusedCashReleased(uint256 indexed id, uint256 indexed day, uint256 amount);

    HookrPrograms private programs;
    PoolKey private key;
    address private creator = address(0xC0DE);

    function setUp() public {
        _setUpPeriphery();
        (, key,,) = _launch(true, false);
        programs =
            new HookrPrograms(manager, address(router), address(this), 1e30, address(new HookrReferralRegistry()));
        tokenB.transfer(creator, 10_000e18);
        vm.prank(creator);
        tokenB.approve(address(programs), type(uint256).max);
    }

    /// @dev An Immediate program has no day, and releaseUnusedCash refuses it for any `day`.
    function testImmediateProgramsRefuseReleaseForAnyDay() public {
        uint256 id = _create(_immediatePointsTerms());
        vm.warp(uint256(programs.program(id).terms.end) + 1);
        uint256[3] memory days_ = [uint256(0), 1, 123_456_789];
        for (uint256 i; i < days_.length; ++i) {
            vm.expectRevert(IHookrPrograms.InvalidProgram.selector);
            programs.releaseUnusedCash(id, days_[i]);
        }
    }

    /// @dev A daily program's day is range-checked: the release of a day past the program's end reverts.
    function testDailyReleaseRefusesADayOutsideTheProgram() public {
        uint256 id = _create(_dailyTerms(false));
        vm.warp(uint256(programs.program(id).terms.end) + programs.PROPOSAL_WINDOW());
        vm.expectRevert(IHookrPrograms.InvalidProgram.selector);
        programs.releaseUnusedCash(id, 1);
    }

    /// @dev The documented half: the unapproved-Bux cancellation refund and a lapsed day 0's release log the same
    ///      event with the same day, the refund logs nothing else, and `cancelled` is what tells them apart. A cancelled
    ///      program releases no day afterwards.
    function testCancellationRefundAndDayZeroReleaseAreToldApartByCancelled() public {
        uint256 daily = _create(_dailyTerms(false));
        uint256 bux = _create(_dailyTerms(true));
        vm.warp(uint256(programs.program(daily).terms.end) + programs.PROPOSAL_WINDOW());
        programs.lapseDay(daily, 0);

        vm.recordLogs();
        programs.releaseUnusedCash(daily, 0);
        Vm.Log memory release = _onlyProgramsLog(vm.getRecordedLogs());

        vm.recordLogs();
        programs.refundUnapprovedBux(bux);
        Vm.Log memory refund = _onlyProgramsLog(vm.getRecordedLogs());

        assertEq(release.topics[0], UnusedCashReleased.selector, "a day's release logs UnusedCashReleased");
        assertEq(refund.topics[0], UnusedCashReleased.selector, "the cancellation refund logs UnusedCashReleased");
        assertEq(release.topics[2], bytes32(0), "the release names day 0");
        assertEq(refund.topics[2], bytes32(0), "the refund names day 0 too");
        assertEq(release.data, abi.encode(uint256(1000e18)), "release amount");
        assertEq(refund.data, release.data, "the same amount word");
        assertEq(uint256(refund.topics[1]), bux, "only the program id differs");
        assertFalse(programs.program(daily).cancelled, "the released program is not cancelled");
        assertTrue(programs.program(bux).cancelled, "the refunded one is: cancelled tells the refund apart");

        // A cancelled program can never log a day's release after its refund: it is disabled for good.
        vm.expectRevert(IHookrPrograms.Unauthorized.selector);
        programs.lapseDay(bux, 0);
        vm.expectRevert(IHookrPrograms.Unauthorized.selector);
        programs.releaseUnusedCash(bux, 0);
    }

    function _onlyProgramsLog(Vm.Log[] memory logs) private view returns (Vm.Log memory found) {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(programs)) {
                found = logs[i];
                ++n;
            }
        }
        assertEq(n, 1, "HookrPrograms logs exactly one event");
    }

    function _create(P.Terms memory t) private returns (uint256 id) {
        P.NFTMetadata memory md;
        P.Scope[] memory scopes = _scopes();
        vm.prank(creator);
        id = programs.createProgram(t, scopes, new P.Milestone[](0), md);
    }

    function _scopes() private view returns (P.Scope[] memory s) {
        s = new P.Scope[](1);
        s[0] = P.Scope(
            address(root),
            PoolId.unwrap(key.toId()),
            root.policyHash(key.toId()),
            Currency.unwrap(root.poolConfig(key.toId()).quote),
            1,
            1,
            0,
            0
        );
    }

    /// @dev An Immediate program as r31 admits it: creator points only, no cash, no Bux, no milestones.
    function _immediatePointsTerms() private view returns (P.Terms memory t) {
        t.mode = P.Mode.Immediate;
        t.start = uint64(vm.getBlockTimestamp() + 1);
        t.end = t.start + 1 days;
        t.pointBudget = 1000e18;
        t.walletPointCap = 1000e18;
        t.pointNumerator = 1;
        t.pointDenominator = 1;
        t.sourcePolicyHash = keccak256("policy");
        t.name = "x";
        t.pointDecimals = 18;
    }

    /// @dev A one-day DailySwap program at the review floor (HookrProgramValidator.MIN_REVIEW_DELAY, 6 days).
    function _dailyTerms(bool globalBux) private view returns (P.Terms memory t) {
        t.mode = P.Mode.DailySwap;
        t.globalBux = globalBux;
        t.start = uint64((vm.getBlockTimestamp() / 1 days + 1) * 1 days);
        t.end = t.start + 1 days;
        t.pointBudget = 1000e18;
        t.dailyPointBudget = 1000e18;
        t.walletPointCap = 1000e18;
        t.rewardToken = address(tokenB);
        t.cashBudget = 1000e18;
        t.dailyCashBudget = 1000e18;
        t.walletCashCap = 1000e18;
        t.attestor = address(this);
        t.reviewer = royalty;
        t.reviewDelay = 6 days;
        t.sourcePolicyHash = keccak256("policy");
        t.name = "x";
        t.pointDecimals = 18;
    }
}
