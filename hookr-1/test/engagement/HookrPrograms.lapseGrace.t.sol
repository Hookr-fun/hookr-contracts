// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrReferralRegistry} from "../../src/engagement/HookrReferralRegistry.sol";
import {HookrPrograms} from "../../src/engagement/HookrPrograms.sol";
import {IHookrPrograms} from "../../src/interfaces/IHookrPrograms.sol";
import {HookrProgramTypes as P} from "../../src/types/HookrProgramTypes.sol";

/// Review regression of the L-18 sticky veto combined with the L-03 lapse (Programs).
///
/// With the sticky veto, a corrected re-proposal stays challenged until the reviewer approves it. lapseDay accepted
/// any challenged day as soon as end + PROPOSAL_WINDOW passed, whenever its latest version was proposed.
/// Before this fix (lane head 3c2152b, review PoC test/review/ReviewLapseRace.t.sol): the attestor
/// proposed a corrected v2 at end + 90d - 10min, which inherited the veto; at end + 90d the creator lapsed the day
/// first, the reviewer's approveDay(v2) reverted NotReady, releaseUnusedCash
/// paid the creator the day's 100e18 and the trader received 0.
/// Fix: a vetoed version cannot lapse before its own finalizeAfter, so the reviewer keeps the full review delay after
/// the latest proposal. Proposals stop at the window end, so every day still closes by end + window + reviewDelay.
contract HookrProgramsLapseGraceTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    HookrPrograms programs;
    PoolKey key;
    address attestor = address(0xA11);
    address reviewer = address(0xB22);
    bytes32 constant COV = keccak256("cov");

    function setUp() public {
        _setUpPeriphery();
        (, key,,) = _launch(true, false);
        programs =
            new HookrPrograms(manager, address(router), address(this), 1e30, address(new HookrReferralRegistry()));
        tokenB.approve(address(programs), type(uint256).max);
    }

    function _create(uint64 reviewDelay) internal returns (uint256) {
        P.Terms memory t;
        t.mode = P.Mode.DailySwap;
        t.start = uint64((vm.getBlockTimestamp() / 1 days + 1) * 1 days);
        t.end = t.start + 1 days;
        t.dailyPointBudget = 1000e18;
        t.pointBudget = 1000e18;
        t.walletPointCap = t.pointBudget;
        t.rewardToken = address(tokenB);
        t.dailyCashBudget = 100e18;
        t.cashBudget = 100e18;
        t.walletCashCap = t.cashBudget;
        t.attestor = attestor;
        t.reviewer = reviewer;
        t.reviewDelay = reviewDelay;
        t.sourcePolicyHash = keccak256("dailySwap");
        t.name = "Daily";
        t.pointDecimals = 18;
        P.Scope[] memory s = new P.Scope[](1);
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
        return programs.createProgram(t, s, new P.Milestone[](0), P.NFTMetadata("", "", "", false));
    }

    function _leaf(uint256 id, address who, uint128 w) internal view returns (bytes32) {
        uint64 end = programs.dayEnd(id, 0);
        return keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(
                        block.chainid,
                        address(programs),
                        id,
                        programs.program(id).termsHash,
                        uint256(0),
                        uint64(end - 1 days),
                        end,
                        COV,
                        who,
                        w
                    )
                )
            )
        );
    }

    /// @dev Bad root vetoed at the day's end, then a corrected v2 proposed `lateBy` before the window closes.
    function _vetoThenLateCorrection(uint256 id, uint256 lateBy) internal returns (uint256 windowEnd) {
        uint256 end = programs.dayEnd(id, 0);
        windowEnd = end + programs.PROPOSAL_WINDOW();
        vm.warp(end);
        bytes32 bad = _leaf(id, attestor, 1);
        vm.prank(attestor);
        programs.proposeDay(id, 0, bad, 1, COV, keccak256("bad"));
        vm.prank(reviewer);
        programs.challengeDay(id, 0, keccak256("wrong"));
        vm.warp(windowEnd - lateBy);
        bytes32 good = _leaf(id, trader, 1);
        vm.prank(attestor);
        programs.proposeDay(id, 0, good, 1, COV, keccak256("good"));
        assertTrue(programs.epoch(id, 0).challenged, "the correction inherits the sticky veto");
    }

    /// The review PoC: the creator can no longer lapse the corrected day ahead of the reviewer's approval.
    function testCreatorCannotLapseCorrectedDayBeforeReviewerCanApprove() public {
        uint256 id = _create(6 days);
        uint256 windowEnd = _vetoThenLateCorrection(id, 10 minutes);
        vm.warp(windowEnd);
        vm.expectRevert(IHookrPrograms.NotReady.selector);
        programs.lapseDay(id, 0); // msg.sender == creator (this)
        vm.warp(windowEnd + 1 days); // the reviewer answers inside the grace
        vm.prank(reviewer);
        programs.approveDay(id, 0, 2);
        programs.claimDay(id, 0, trader, 1, new bytes32[](0));
        assertEq(programs.claimableCash(id, trader), 100e18, "the trader keeps the corrected day");
        uint256 before_ = tokenB.balanceOf(address(this));
        assertEq(programs.releaseUnusedCash(id, 0), 0);
        assertEq(tokenB.balanceOf(address(this)), before_, "the creator recovers nothing");
    }

    /// The grace is the review delay after the latest version, to the second; after it a silent reviewer's veto lapses.
    function testGraceEndsAtTheLatestFinalizeAfter() public {
        uint256 id = _create(6 days);
        _vetoThenLateCorrection(id, 10 minutes);
        uint64 finalizeAfter = programs.epoch(id, 0).finalizeAfter;
        vm.warp(finalizeAfter - 1);
        vm.expectRevert(IHookrPrograms.NotReady.selector);
        programs.lapseDay(id, 0);
        vm.warp(finalizeAfter);
        programs.lapseDay(id, 0);
        assertTrue(programs.epoch(id, 0).closed);
        assertEq(programs.releaseUnusedCash(id, 0), 100e18);
        assertEq(programs.claimableCash(id, trader), 0);
    }

    /// The attestor cannot stretch the grace: proposals stop at the window end, so the last possible lapse is
    /// end + PROPOSAL_WINDOW + reviewDelay, even with the 30-day maximum delay.
    function testGraceIsBoundedByTheWindowAndTheMaximumDelay() public {
        uint256 id = _create(30 days);
        uint256 windowEnd = _vetoThenLateCorrection(id, 1);
        assertEq(programs.epoch(id, 0).finalizeAfter, windowEnd - 1 + 30 days);
        vm.warp(windowEnd);
        bytes32 again = _leaf(id, attestor, 1);
        vm.prank(attestor);
        vm.expectRevert(abi.encodeWithSelector(IHookrPrograms.ProposalWindowClosed.selector, id, 0, windowEnd));
        programs.proposeDay(id, 0, again, 1, COV, keccak256("again"));
        vm.warp(windowEnd - 1 + 30 days);
        programs.lapseDay(id, 0);
        assertTrue(programs.epoch(id, 0).finalized);
    }

    /// A veto on an old version whose delay already ran out lapses at the window end, as before.
    function testOldVetoedVersionLapsesAtTheWindowEnd() public {
        uint256 id = _create(6 days);
        uint256 end = programs.dayEnd(id, 0);
        vm.warp(end);
        bytes32 bad = _leaf(id, attestor, 1);
        vm.prank(attestor);
        programs.proposeDay(id, 0, bad, 1, COV, keccak256("bad"));
        vm.prank(reviewer);
        programs.challengeDay(id, 0, keccak256("wrong"));
        vm.warp(end + programs.PROPOSAL_WINDOW() - 1);
        vm.expectRevert(IHookrPrograms.NotReady.selector);
        programs.lapseDay(id, 0);
        vm.warp(end + programs.PROPOSAL_WINDOW());
        programs.lapseDay(id, 0);
        assertEq(programs.releaseUnusedCash(id, 0), 100e18);
    }
}
