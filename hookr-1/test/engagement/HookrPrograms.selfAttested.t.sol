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
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";

/// I-14: a creator who names both the attestor and the reviewer can zero every day after users opt in, then take back
/// the whole daily cash budget.
///
/// Before the fix (base b7aeae64, B16Verify.testC2_CreatorAttestorZeroesDayAndReclaimsFullCash): after an opted-in
/// trade, a creator-held attestor proposed a zero root, it finalized one hour later and releaseUnusedCash returned
/// all 10,000 to the creator; the trader's claimable cash stayed 0. An independent reviewer's veto was cleared by the
/// next re-proposal.
/// Status: trust model, documented. The contract cannot prove attestor/reviewer independence; the app and service
/// must label programs whose attestor and reviewer are not manifest-approved as self-attested. What changed onchain:
/// an independent reviewer's single veto now sticks (L-18), so a zeroing needs that reviewer's approval or waits out
/// the whole proposal window in public before the creator can recover the day's cash.
contract HookrProgramsSelfAttestedTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    HookrPrograms programs;
    PoolKey key;
    address constant ATTESTOR = address(0xA1);
    address constant REVIEWER = address(0xA2);

    function setUp() public {
        _setUpPeriphery();
        (, key,,) = _launch(true, false);
        programs =
            new HookrPrograms(manager, address(router), address(this), 10_000, address(new HookrReferralRegistry()));
        tokenB.approve(address(programs), type(uint256).max);
    }

    function _program() internal returns (uint256 id, P.Terms memory t) {
        t.mode = P.Mode.DailySwap;
        t.start = uint64((vm.getBlockTimestamp() / 1 days + 1) * 1 days);
        t.end = t.start + 1 days;
        t.pointBudget = 1000;
        t.dailyPointBudget = 1000;
        t.walletPointCap = 1000;
        t.rewardToken = address(tokenB);
        t.cashBudget = 10_000;
        t.dailyCashBudget = 10_000;
        t.walletCashCap = 10_000;
        t.attestor = ATTESTOR;
        t.reviewer = REVIEWER;
        t.reviewDelay = 6 days;
        t.sourcePolicyHash = keccak256("policy");
        t.name = "Program";
        t.pointDecimals = 18;
        P.Scope[] memory s = new P.Scope[](1);
        s[0] = P.Scope(
            address(root),
            PoolId.unwrap(key.toId()),
            root.policyHash(key.toId()),
            Currency.unwrap(root.poolConfig(key.toId()).quote),
            1,
            1e15,
            0,
            0
        );
        P.NFTMetadata memory md;
        id = programs.createProgram(t, s, new P.Milestone[](0), md);
        vm.warp(t.start + 1 hours);
        IHookrRouter.Swap memory params = _swap(key, true, true, 1e18);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(trader);
        router.swap(params, address(programs), ids);
        vm.warp(t.end);
        vm.prank(ATTESTOR);
        programs.proposeDay(id, 0, bytes32(0), 0, keccak256("c"), keccak256("e"));
    }

    /// Residual trust model: with a creator-held reviewer the zero day still returns the cash (accepted, disclosed).
    function testCreatorHeldReviewerCanStillZeroTheDay() public {
        (uint256 id, P.Terms memory t) = _program();
        vm.prank(REVIEWER);
        programs.approveDay(id, 0, 1);
        assertEq(programs.releaseUnusedCash(id, 0), t.cashBudget);
        assertEq(programs.claimableCash(id, trader), 0);
    }

    /// With an independent reviewer, one veto blocks the zeroing for good: the attestor cannot re-propose past it, and
    /// the creator waits out the full public proposal window before the day lapses.
    function testIndependentReviewerVetoSticks() public {
        (uint256 id,) = _program();
        vm.prank(REVIEWER);
        programs.challengeDay(id, 0, keccak256("activity was opted in"));
        vm.prank(ATTESTOR);
        programs.proposeDay(id, 0, bytes32(0), 0, keccak256("c"), keccak256("again"));
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.expectRevert(IHookrPrograms.NotReady.selector);
        programs.finalizeDay(id, 0);
        vm.expectRevert(IHookrPrograms.NotReady.selector);
        programs.releaseUnusedCash(id, 0);
        vm.expectRevert(IHookrPrograms.NotReady.selector);
        programs.lapseDay(id, 0);
    }
}
