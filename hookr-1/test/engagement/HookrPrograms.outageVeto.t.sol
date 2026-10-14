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

/// L-23 (Programs side): the veto window shared its boundary with finalization, could be as short as
/// one hour, and was re-armed by every re-proposal, so a sequencer outage or censorship longer than the remaining
/// window removed the reviewer's veto.
///
/// Before the fix (base b7aeae64, Programs port of B17Verify.testC2_VetoBoundary): with a 1-hour
/// delay, a challenge at finalizeAfter-1 succeeded, the same challenge at finalizeAfter (the first block after an
/// outage) reverted NotReady and anyone finalized; the attestor re-opened the vetoed day alone.
/// Fix: (1) the review delay is at least 6 days, two days above chain 4663's 4-day forced-inclusion delay, so under
/// honest timestamps a reviewer who acts within about the first reviewDelay - 4 days - 1 hour lands a veto through the
/// delayed inbox (test/engagement/ReviewFloors.t.sol models the sequencer's clock bounds); (2) a veto lands
/// whenever it arrives before finalization, not only before finalizeAfter; (3) one veto is sticky, so the reviewer
/// needs to win one race per day, not one per re-proposal. A finalize that is included before a delayed veto still
/// wins (first come, first served); the window length is what makes that avoidable.
contract HookrProgramsOutageVetoTest is PeripheryFixture {
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

    function _terms(uint64 delay) internal view returns (P.Terms memory t) {
        t.mode = P.Mode.DailySwap;
        t.start = uint64((vm.getBlockTimestamp() / 1 days + 1) * 1 days);
        t.end = t.start + 2 days;
        t.dailyPointBudget = 1000e18;
        t.pointBudget = 2000e18;
        t.walletPointCap = t.pointBudget;
        t.rewardToken = address(tokenB);
        t.dailyCashBudget = 100e18;
        t.cashBudget = 200e18;
        t.walletCashCap = t.cashBudget;
        t.attestor = attestor;
        t.reviewer = reviewer;
        t.reviewDelay = delay;
        t.sourcePolicyHash = keccak256("dailySwap");
        t.name = "Daily";
        t.pointDecimals = 18;
    }

    function _scopes() internal view returns (P.Scope[] memory s) {
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

    function testOneHourWindowIsRejected() public {
        P.Terms memory t = _terms(1 hours);
        P.Scope[] memory s = _scopes();
        P.NFTMetadata memory md;
        vm.expectRevert(IHookrPrograms.InvalidProgram.selector);
        programs.createProgram(t, s, new P.Milestone[](0), md);
        t.reviewDelay = 6 days - 1;
        vm.expectRevert(IHookrPrograms.InvalidProgram.selector);
        programs.createProgram(t, s, new P.Milestone[](0), md);
    }

    /// The PoC's boundary: a veto delayed past finalizeAfter by an outage still lands if it arrives first, and a
    /// vetoed day cannot be re-opened by the attestor alone.
    function testDelayedVetoStillLandsAndSticks() public {
        P.Terms memory t = _terms(6 days);
        P.Scope[] memory s = _scopes();
        P.NFTMetadata memory md;
        uint256 id = programs.createProgram(t, s, new P.Milestone[](0), md);
        vm.warp(t.end);
        vm.startPrank(attestor);
        programs.proposeDay(id, 0, keccak256("bad0"), 1, COV, keccak256("ev"));
        programs.proposeDay(id, 1, keccak256("bad1"), 1, COV, keccak256("ev"));
        vm.stopPrank();
        uint64 fa = programs.epoch(id, 0).finalizeAfter;
        vm.warp(fa - 1);
        vm.prank(reviewer);
        programs.challengeDay(id, 0, keccak256("veto"));
        // First block after an outage that spans the boundary: the reviewer's delayed veto is ordered first.
        vm.warp(fa + 6 hours);
        vm.prank(reviewer);
        programs.challengeDay(id, 1, keccak256("veto"));
        vm.expectRevert(IHookrPrograms.NotReady.selector);
        programs.finalizeDay(id, 1);
        vm.prank(attestor);
        programs.proposeDay(id, 0, keccak256("bad0"), 1, COV, keccak256("ev2"));
        assertTrue(programs.epoch(id, 0).challenged, "the attestor cannot re-open a vetoed day");
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.expectRevert(IHookrPrograms.NotReady.selector);
        programs.finalizeDay(id, 0);
    }
}
