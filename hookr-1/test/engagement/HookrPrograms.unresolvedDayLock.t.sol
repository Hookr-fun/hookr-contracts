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
import {HookrTypes} from "../../src/types/HookrTypes.sol";

/// L-03: one unresolved day of an approved daily Bux program pinned that day's cash and the WHOLE program's unused Bux
/// allowance against the immutable buxSupplyCap, with no timeout.
///
/// Before the fix (base b7aeae64, v1_any_unresolved_day_of_a_daily_program_pe_8):
///   silent attestor: 10 years after end, buxReserved 10,000e18 of a 10,000e18 cap, buxIssued 0, 5e18 cash locked,
///     and the next 1-wei Bux approval reverted BudgetExceeded;
///   zero-cash program: 7,000e18 of headroom pinned for gas only;
///   30-day program: buxReserved 30,000e18 against 1,000e18 issued, 28,000e18 of it from days already closed;
///   over-declared totalWeight: 0.0999e18 cash and 0.999e18 Bux locked; duplicate leaves: 66.67e18 cash and
///     666.67e18 Bux locked; reviewer veto loop: 10 vetoes over 10 years, 1,000e18 allowance locked.
/// Fix: closing a day returns its unissued allowance at once; proposals close PROPOSAL_WINDOW after the day ends,
/// after which an unproposed or still-vetoed day lapses to zero (cash to the creator, allowance to the cap). A
/// finalized day whose attested weights never fully claim stays pinned, but only for its own share.
contract HookrProgramsUnresolvedDayLockTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    HookrPrograms internal programs;
    HookrReferralRegistry internal refs;
    PoolKey internal key;
    bytes32 internal constant COVERAGE = keccak256("complete pinned daily coverage");
    bytes32 internal constant EVIDENCE = keccak256("evidence");
    address internal creator = address(0xC0FFEE);
    address internal attestor = address(0xA77E);
    address internal reviewer = address(0xBEEF);

    function setUp() public {
        _setUpPeriphery();
        (, key,,) = _launch(true, false);
        refs = new HookrReferralRegistry();
        tokenB.transfer(creator, 1e24);
    }

    function _deploy(uint256 cap) internal {
        programs = new HookrPrograms(manager, address(router), address(this), cap, address(refs));
        vm.prank(creator);
        tokenB.approve(address(programs), type(uint256).max);
    }

    function _terms(uint256 numDays, uint128 dailyPts, uint128 dailyCash) internal view returns (P.Terms memory t) {
        t.mode = P.Mode.DailySwap;
        t.globalBux = true;
        t.start = uint64((vm.getBlockTimestamp() / 1 days + 1) * 1 days);
        t.end = t.start + uint64(numDays * 1 days);
        t.pointBudget = uint128(dailyPts * numDays);
        t.walletPointCap = t.pointBudget;
        t.dailyPointBudget = dailyPts;
        if (dailyCash != 0) {
            t.rewardToken = address(tokenB);
            t.cashBudget = uint128(dailyCash * numDays);
            t.walletCashCap = t.cashBudget;
            t.dailyCashBudget = dailyCash;
        }
        t.attestor = attestor;
        t.reviewer = reviewer;
        t.reviewDelay = 6 days;
        t.sourcePolicyHash = keccak256("explicit normalized scope units");
        t.name = "Daily";
        t.metadataURI = "ipfs://terms";
        t.pointDecimals = 18;
    }

    /// @dev Proposes a Bux program's approval and executes it once BUX_APPROVAL_DELAY has passed.
    function _approveBux(uint256 id) internal {
        programs.proposeBuxProgram(id);
        vm.warp(vm.getBlockTimestamp() + programs.BUX_APPROVAL_DELAY());
        programs.approveBuxProgram(id);
    }

    function _create(P.Terms memory t) internal returns (uint256 id) {
        P.Scope[] memory sources = new P.Scope[](1);
        HookrTypes.PoolConfig memory c = root.poolConfig(key.toId());
        sources[0] = P.Scope(
            address(root),
            PoolId.unwrap(key.toId()),
            root.policyHash(key.toId()),
            Currency.unwrap(c.quote),
            1,
            1e15,
            0,
            0
        );
        P.NFTMetadata memory metadata;
        vm.prank(creator);
        id = programs.createProgram(t, sources, new P.Milestone[](0), metadata);
    }

    function _leaf(uint256 id, uint256 day, address user, uint128 weight) internal view returns (bytes32) {
        uint64 end = programs.dayEnd(id, day);
        return keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(
                        block.chainid,
                        address(programs),
                        id,
                        programs.program(id).termsHash,
                        day,
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

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _proposeAndFinalize(uint256 id, uint256 day, bytes32 root_, uint256 total) internal {
        vm.prank(attestor);
        programs.proposeDay(id, day, root_, total, COVERAGE, EVIDENCE);
        vm.warp(vm.getBlockTimestamp() + 6 days);
        programs.finalizeDay(id, day);
    }

    function _pastWindow(uint256 id, uint256 day) internal {
        uint256 closesAt = programs.dayEnd(id, day) + programs.PROPOSAL_WINDOW();
        if (vm.getBlockTimestamp() < closesAt) vm.warp(closesAt);
    }

    /// (a) silent attestor: the day lapses after its window; cash and the whole cap come back.
    function testSilentAttestorDayLapsesAndReleasesCapAndCash() public {
        _deploy(10_000e18);
        P.Terms memory t = _terms(1, 10_000e18, 5e18);
        uint256 id = _create(t);
        _approveBux(id);
        assertEq(programs.buxReserved(), 10_000e18);
        vm.warp(t.end);
        vm.expectRevert(IHookrPrograms.NotReady.selector);
        programs.lapseDay(id, 0);
        _pastWindow(id, 0);
        vm.prank(creator);
        vm.expectRevert(IHookrPrograms.NotReady.selector); // the creator still cannot attest
        programs.proposeDay(id, 0, bytes32(0), 0, COVERAGE, EVIDENCE);
        programs.lapseDay(id, 0); // anyone
        assertEq(programs.buxReserved(), 0);
        uint256 before_ = tokenB.balanceOf(creator);
        programs.releaseUnusedCash(id, 0);
        assertEq(tokenB.balanceOf(creator) - before_, 5e18);
        assertEq(programs.reservedCash(address(tokenB)), 0);
        assertTrue(programs.program(id).buxReleased);
        uint256 next = _create(_terms(1, 10_000e18, 0));
        _approveBux(next); // the full cap is available again
    }

    /// Zero-cash variant: the pinned headroom returns once the window passes.
    function testZeroCashProgramReleasesCapAfterWindow() public {
        _deploy(10_000e18);
        P.Terms memory t = _terms(7, 1_000e18, 0);
        uint256 id = _create(t);
        _approveBux(id);
        _pastWindow(id, 6);
        for (uint256 d; d < 7; ++d) {
            programs.lapseDay(id, d);
        }
        assertEq(programs.buxReserved(), 0);
        assertEq(programs.program(id).openDays, 0);
    }

    /// One unproposed day of thirty pins only its own allowance, and lapses later.
    function testOneOpenDayOfThirtyPinsOnlyItsOwnAllowance() public {
        _deploy(1_000_000e18);
        P.Terms memory t = _terms(30, 1_000e18, 100e18);
        uint256 id = _create(t);
        _approveBux(id);
        vm.warp(t.end);
        for (uint256 d; d < 28; ++d) {
            vm.prank(attestor);
            programs.proposeDay(id, d, bytes32(0), 0, COVERAGE, EVIDENCE);
        }
        bytes32 leaf28 = _leaf(id, 28, trader, 1000);
        vm.prank(attestor);
        programs.proposeDay(id, 28, leaf28, 1000, COVERAGE, EVIDENCE);
        vm.warp(vm.getBlockTimestamp() + 6 days);
        for (uint256 d; d < 29; ++d) {
            programs.finalizeDay(id, d);
        }
        programs.claimDay(id, 28, trader, 1000, new bytes32[](0));
        uint256 locked = programs.buxReserved() - programs.buxIssued();
        assertEq(programs.buxIssued(), 1_000e18);
        assertEq(locked, t.dailyPointBudget, "only day 29 still holds allowance (was 29,000e18)");
        _pastWindow(id, 29);
        programs.lapseDay(id, 29);
        assertEq(programs.buxReserved(), programs.buxIssued());
        for (uint256 d; d < 30; ++d) {
            programs.releaseUnusedCash(id, d);
        }
        assertEq(programs.reservedCash(address(tokenB)), programs.claimableCash(id, trader));
    }

    /// (c) over-declared totalWeight: the finalized day stays open, but pins only its own remainder.
    function testOverDeclaredDayPinsOnlyItsOwnShare() public {
        _deploy(10_000e18);
        P.Terms memory t = _terms(2, 1_000e18, 100e18);
        uint256 id = _create(t);
        _approveBux(id);
        vm.warp(t.end);
        _proposeAndFinalize(id, 0, _leaf(id, 0, trader, 1000), 1001);
        programs.claimDay(id, 0, trader, 1000, new bytes32[](0));
        _proposeAndFinalize(id, 1, bytes32(0), 0);
        assertEq(programs.buxReserved() - programs.buxIssued(), 1_000e18 - 999_000_999_000_999_000_999);
        _pastWindow(id, 1);
        vm.expectRevert(IHookrPrograms.NotReady.selector); // finalized commitments are never confiscated
        programs.lapseDay(id, 0);
        programs.releaseUnusedCash(id, 1);
        assertEq(
            programs.reservedCash(address(tokenB)) - programs.claimableCash(id, trader),
            100e18 - 99_900_099_900_099_900_099
        );
    }

    /// (d) duplicate beneficiary leaves: same bound, only that day's share stays pinned.
    function testDuplicateLeavesPinOnlyTheirOwnDay() public {
        _deploy(10_000e18);
        P.Terms memory t = _terms(2, 1_000e18, 100e18);
        uint256 id = _create(t);
        _approveBux(id);
        vm.warp(t.end);
        bytes32 a = _leaf(id, 0, trader, 1);
        bytes32 b = _leaf(id, 0, trader, 2);
        _proposeAndFinalize(id, 0, _pair(a, b), 3);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = b;
        programs.claimDay(id, 0, trader, 1, proof);
        proof[0] = a;
        vm.expectRevert(IHookrPrograms.Duplicate.selector);
        programs.claimDay(id, 0, trader, 2, proof);
        _proposeAndFinalize(id, 1, bytes32(0), 0);
        assertEq(programs.buxReserved() - programs.buxIssued(), 1_000e18 - 333_333_333_333_333_333_333);
    }

    /// (b) veto loop: one veto sticks; the attestor cannot clear it, and the day lapses after its window.
    function testVetoedDayLapsesInsteadOfLoopingForever() public {
        _deploy(10_000e18);
        P.Terms memory t = _terms(1, 1_000e18, 100e18);
        uint256 id = _create(t);
        _approveBux(id);
        vm.warp(t.end);
        vm.prank(attestor);
        programs.proposeDay(id, 0, bytes32(0), 0, COVERAGE, EVIDENCE);
        vm.prank(reviewer);
        programs.challengeDay(id, 0, keccak256("veto"));
        for (uint256 i; i < 10; ++i) {
            vm.prank(attestor);
            programs.proposeDay(id, 0, bytes32(0), 0, COVERAGE, keccak256(abi.encode(i)));
            assertTrue(programs.epoch(id, 0).challenged);
            vm.warp(vm.getBlockTimestamp() + 7 days);
            vm.expectRevert(IHookrPrograms.NotReady.selector);
            programs.finalizeDay(id, 0);
        }
        _pastWindow(id, 0);
        programs.lapseDay(id, 0);
        assertEq(programs.buxReserved(), 0);
        assertEq(programs.releaseUnusedCash(id, 0), 100e18);
    }
}
