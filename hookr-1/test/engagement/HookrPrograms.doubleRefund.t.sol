// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrReferralRegistry} from "../../src/engagement/HookrReferralRegistry.sol";
import {HookrPrograms} from "../../src/engagement/HookrPrograms.sol";
import {IHookrPrograms} from "../../src/interfaces/IHookrPrograms.sol";
import {IHookrProgramValidator} from "../../src/interfaces/IHookrProgramValidator.sol";
import {HookrProgramTypes as P} from "../../src/types/HookrProgramTypes.sol";

/// N-01 (High): an unapproved global-Bux Immediate program was refunded twice, by releaseUnusedCash (no buxApproved
/// check) and then refundUnapprovedBux (no immediateCashReleased check), draining other programs' reservedCash.
///
/// Before the fix (base b7aeae64, DoubleRefundPoC):
///   attacker funded 1000e18 and received 2000e18; Programs balance and reservedCash fell to 0 while the victim's
///   1000e18 budget stayed recorded; the victim's releaseUnusedCash panicked (0x11) and a trader's earned
///   0.9575e18 became unpayable.
/// Root-cause fix: every program's cash is its own ledger (cashPaid <= cashAllocated, cashAllocated + cashRefunded
/// <= cashBudget) and every outflow re-checks it; releaseUnusedCash and lapseDay need an enabled program, so an
/// unapproved Bux program has exactly one exit; refundUnapprovedBux adds to cashRefunded instead of overwriting it.
contract HookrProgramsDoubleRefundTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    HookrPrograms private programs;
    PoolKey private key;
    address private victimCreator = address(0xB0B);
    address private attacker = address(0xBAD);
    bytes32 private constant COVERAGE = keccak256("coverage");

    function setUp() public {
        _setUpPeriphery();
        (, key,,) = _launch(true, false);
        programs =
            new HookrPrograms(manager, address(router), address(this), 1e30, address(new HookrReferralRegistry()));
        _fundCreators(address(programs));
    }

    function _fundCreators(address target) private {
        tokenB.transfer(victimCreator, 1000e18);
        tokenB.transfer(attacker, 1000e18);
        vm.prank(victimCreator);
        tokenB.approve(target, type(uint256).max);
        vm.prank(attacker);
        tokenB.approve(target, type(uint256).max);
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

    /// The PoC's exact attacker terms.
    function _immediateTerms(bool bux, uint128 budget) private view returns (P.Terms memory t) {
        t.mode = P.Mode.Immediate;
        t.globalBux = bux;
        t.start = uint64(vm.getBlockTimestamp() + 1);
        t.end = t.start + 1;
        t.pointBudget = 1;
        t.walletPointCap = 1;
        t.pointNumerator = 1;
        t.pointDenominator = 1;
        t.rewardToken = address(tokenB);
        t.cashBudget = budget;
        t.walletCashCap = budget;
        t.cashNumerator = 1;
        t.cashDenominator = 1;
        t.sourcePolicyHash = keccak256("policy");
        t.name = "x";
        t.pointDecimals = 18;
    }

    function _dailyTerms(bool bux) private view returns (P.Terms memory t) {
        t.mode = P.Mode.DailySwap;
        t.globalBux = bux;
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

    function _leaf(uint256 id, address user, uint128 weight) private view returns (bytes32) {
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
                        COVERAGE,
                        user,
                        weight
                    )
                )
            )
        );
    }

    /// The original exploit: its unapproved global-Bux Immediate cash program can no longer exist.
    function testOriginalExploitProgramIsRejected() public {
        P.NFTMetadata memory md;
        P.Scope[] memory sc = _scopes();
        P.Terms memory te = _immediateTerms(true, 1000e18);
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IHookrProgramValidator.ImmediateValueUnreviewed.selector, 1000e18, true, 0)
        );
        programs.createProgram(te, sc, new P.Milestone[](0), md);
        assertEq(tokenB.balanceOf(attacker), 1000e18);
        assertEq(programs.reservedCash(address(tokenB)), 0);
    }

    /// The same double-exit attempted on the only shape an unapproved Bux cash program can take now.
    function testUnapprovedBuxProgramHasOneExitAndVictimStaysWhole() public {
        P.NFTMetadata memory md;
        P.Scope[] memory sc = _scopes();
        P.Terms memory tv = _dailyTerms(false);
        P.Terms memory te = _dailyTerms(true);
        vm.prank(victimCreator);
        uint256 victim = programs.createProgram(tv, sc, new P.Milestone[](0), md);
        vm.prank(attacker);
        uint256 evil = programs.createProgram(te, sc, new P.Milestone[](0), md);
        assertEq(programs.reservedCash(address(tokenB)), 2000e18);

        vm.warp(uint256(te.end) + programs.PROPOSAL_WINDOW());
        // The attacker's first leg of the old sequence: no day of a never-enabled program can close or release.
        vm.expectRevert(IHookrPrograms.Unauthorized.selector);
        programs.lapseDay(evil, 0);
        vm.expectRevert(IHookrPrograms.Unauthorized.selector);
        programs.releaseUnusedCash(evil, 0);
        uint256 before_ = tokenB.balanceOf(attacker);
        programs.refundUnapprovedBux(evil);
        vm.expectRevert(IHookrPrograms.NotReady.selector);
        programs.refundUnapprovedBux(evil);
        vm.expectRevert(IHookrPrograms.Unauthorized.selector);
        programs.releaseUnusedCash(evil, 0);
        assertEq(tokenB.balanceOf(attacker) - before_, 1000e18, "attacker gets back exactly its own budget");
        assertEq(programs.reservedCash(address(tokenB)), 1000e18);
        assertEq(tokenB.balanceOf(address(programs)), 1000e18);

        // The victim program still settles in full.
        programs.lapseDay(victim, 0); // its attestor never proposed: the window has long passed
        before_ = tokenB.balanceOf(victimCreator);
        programs.releaseUnusedCash(victim, 0);
        assertEq(tokenB.balanceOf(victimCreator) - before_, 1000e18);
        assertEq(programs.reservedCash(address(tokenB)), 0);
        assertEq(tokenB.balanceOf(address(programs)), 0);
    }

    /// The victim's participants keep a fully backed claim while another program in the same token refunds.
    function testVictimParticipantsCanClaimEarnedCash() public {
        P.NFTMetadata memory md;
        P.Scope[] memory sc = _scopes();
        P.Terms memory tv = _dailyTerms(false);
        P.Terms memory te = _dailyTerms(true);
        vm.prank(victimCreator);
        uint256 victim = programs.createProgram(tv, sc, new P.Milestone[](0), md);
        vm.prank(attacker);
        uint256 evil = programs.createProgram(te, sc, new P.Milestone[](0), md);
        vm.warp(tv.end);
        programs.proposeDay(victim, 0, _leaf(victim, trader, 1), 1, COVERAGE, keccak256("evidence"));
        vm.prank(royalty);
        programs.approveDay(victim, 0, 1);
        programs.claimDay(victim, 0, trader, 1, new bytes32[](0));
        programs.refundUnapprovedBux(evil);
        uint256 before_ = tokenB.balanceOf(trader);
        programs.claimCash(victim, trader, trader, 0);
        assertEq(tokenB.balanceOf(trader) - before_, 1000e18);
        assertEq(programs.reservedCash(address(tokenB)), 0);
    }

    /// @dev Slots from `forge inspect HookrPrograms storageLayout`: _programs is slot 6 and _epochs slot 16;
    ///      Program word 23 packs openDays, buxApproved, buxReleased, cancelled (byte 6); Epoch word 7 packs
    ///      finalizeAfter, version, challenged, finalized, closed, remainderReleased (byte 19). Each test first
    ///      asserts the flag it clears reads as set, so a layout change fails loudly instead of testing nothing.
    uint256 private constant PROGRAMS_SLOT = 6;
    uint256 private constant EPOCHS_SLOT = 16;

    function _clearFlag(bytes32 slot, uint256 byteOffset) private {
        uint256 word = uint256(vm.load(address(programs), slot));
        assertEq((word >> (8 * byteOffset)) & 0xff, 1, "storage layout: flag is set before it is cleared");
        vm.store(address(programs), slot, bytes32(word & ~(uint256(0xff) << (8 * byteOffset))));
    }

    /// Even with the `cancelled` flag cleared in storage, a second refundUnapprovedBux cannot take more than the
    /// program's own unallocated budget, so it never reaches another program's reserved cash.
    function testLedgerAloneStopsASecondUnapprovedRefund() public {
        P.NFTMetadata memory md;
        P.Scope[] memory sc = _scopes();
        P.Terms memory tv = _dailyTerms(false);
        P.Terms memory te = _dailyTerms(true);
        vm.prank(victimCreator);
        programs.createProgram(tv, sc, new P.Milestone[](0), md);
        vm.prank(attacker);
        uint256 evil = programs.createProgram(te, sc, new P.Milestone[](0), md);
        vm.warp(te.start);
        programs.refundUnapprovedBux(evil);
        _clearFlag(bytes32(uint256(keccak256(abi.encode(evil, PROGRAMS_SLOT))) + 23), 6);
        assertFalse(programs.program(evil).cancelled);
        vm.expectRevert(abi.encodeWithSelector(IHookrPrograms.ProgramOverdrawn.selector, evil, 1000e18));
        programs.refundUnapprovedBux(evil);
        assertEq(programs.reservedCash(address(tokenB)), 1000e18);
        assertEq(tokenB.balanceOf(address(programs)), 1000e18);
    }

    /// Even with a closed day's `remainderReleased` flag cleared in storage, releasing it again reverts on the
    /// program's own ledger and leaves the other program's cash in place.
    function testLedgerAloneStopsASecondDayRelease() public {
        P.NFTMetadata memory md;
        P.Scope[] memory sc = _scopes();
        P.Terms memory tv = _dailyTerms(false);
        vm.prank(victimCreator);
        programs.createProgram(tv, sc, new P.Milestone[](0), md);
        vm.prank(attacker);
        uint256 evil = programs.createProgram(tv, sc, new P.Milestone[](0), md);
        vm.warp(uint256(tv.end) + programs.PROPOSAL_WINDOW());
        programs.lapseDay(evil, 0);
        assertEq(programs.releaseUnusedCash(evil, 0), 1000e18);
        bytes32 epochSlot = keccak256(abi.encode(uint256(0), keccak256(abi.encode(evil, EPOCHS_SLOT))));
        _clearFlag(bytes32(uint256(epochSlot) + 7), 19);
        assertFalse(programs.epoch(evil, 0).remainderReleased);
        vm.expectRevert(abi.encodeWithSelector(IHookrPrograms.ProgramOverdrawn.selector, evil, 1000e18));
        programs.releaseUnusedCash(evil, 0);
        assertEq(programs.reservedCash(address(tokenB)), 1000e18);
        assertEq(tokenB.balanceOf(address(programs)), 1000e18);
    }
}
