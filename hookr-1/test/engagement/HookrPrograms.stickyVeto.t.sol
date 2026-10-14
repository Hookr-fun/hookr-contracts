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

/// L-18 (Programs side): a re-proposal cleared the reviewer's veto, so a malicious attestor could
/// re-propose the vetoed (or trivially varied) commitment at once and one missed review window finalized it.
///
/// Before the fix (base b7aeae64, B15Verify.testC3_VetoNotSticky_IdenticalAndVaried): 24 veto/re-propose rounds,
/// each clearing `challenged`; one missed 1-hour window then finalized a self-allocating root and the attestor took
/// 100e18 cash and 1,000e18 points.
/// Fix: a veto is sticky for the day (every later version, identical or varied, stays challenged) until the reviewer
/// approves one exact version; an unlifted veto lapses the day to zero after the proposal window.
contract HookrProgramsStickyVetoTest is PeripheryFixture {
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

    function _create() internal returns (uint256) {
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
        t.reviewDelay = 6 days;
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

    /// The PoC's loop: after one veto, identical or varied re-proposals, as many as the proposal window fits at the
    /// 6-day review floor (15), all stay vetoed and none ever finalizes, however many review windows the reviewer
    /// sleeps through.
    function testReproposalCannotClearTheVeto() public {
        uint256 id = _create();
        vm.warp(programs.dayEnd(id, 0));
        bytes32 bad = _leaf(id, attestor, 1);
        vm.prank(attestor);
        programs.proposeDay(id, 0, bad, 1, COV, keccak256("ev"));
        vm.prank(reviewer);
        programs.challengeDay(id, 0, keccak256("theft"));
        uint256 rounds = programs.PROPOSAL_WINDOW() / 6 days;
        for (uint256 i; i < rounds; ++i) {
            vm.prank(attestor);
            programs.proposeDay(id, 0, bad, 1, COV, i % 2 == 0 ? keccak256("ev") : keccak256(abi.encode("ev", i)));
            assertTrue(programs.epoch(id, 0).challenged, "re-proposal keeps the veto");
            vm.warp(vm.getBlockTimestamp() + 6 days); // the reviewer misses every window
            vm.expectRevert(IHookrPrograms.NotReady.selector);
            programs.finalizeDay(id, 0);
        }
        vm.prank(attestor);
        vm.expectRevert(IHookrPrograms.NotReady.selector);
        programs.approveDay(id, 0, uint64(rounds + 1)); // only the reviewer can lift it
        assertEq(programs.points(id, attestor), 0);
        assertEq(programs.claimableCash(id, attestor), 0);
        // The vetoed day lapses to zero after the window: the creator, not the attestor, recovers the cash.
        vm.warp(uint256(programs.dayEnd(id, 0)) + programs.PROPOSAL_WINDOW());
        programs.lapseDay(id, 0);
        uint256 before_ = tokenB.balanceOf(address(this));
        programs.releaseUnusedCash(id, 0);
        assertEq(tokenB.balanceOf(address(this)) - before_, 100e18);
        assertEq(tokenB.balanceOf(attestor), 0);
    }

    /// A corrected root finalizes only with the reviewer's approval of that exact version.
    function testReviewerApprovesCorrectedVersion() public {
        uint256 id = _create();
        vm.warp(programs.dayEnd(id, 0));
        bytes32 bad = _leaf(id, attestor, 1);
        bytes32 fixedRoot = _leaf(id, trader, 1);
        vm.prank(attestor);
        programs.proposeDay(id, 0, bad, 1, COV, keccak256("ev"));
        vm.prank(reviewer);
        programs.challengeDay(id, 0, keccak256("theft"));
        vm.prank(attestor);
        programs.proposeDay(id, 0, fixedRoot, 1, COV, keccak256("fixed"));
        vm.prank(reviewer);
        programs.approveDay(id, 0, 2);
        programs.claimDay(id, 0, trader, 1, new bytes32[](0));
        assertEq(programs.claimableCash(id, trader), 100e18);
    }
}
