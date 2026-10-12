// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HookrReferralRegistry} from "../../src/engagement/HookrReferralRegistry.sol";
import {HookrPrograms} from "../../src/engagement/HookrPrograms.sol";
import {IHookrPrograms} from "../../src/interfaces/IHookrPrograms.sol";
import {HookrProgramTypes as P} from "../../src/types/HookrProgramTypes.sol";
import {HookrRouter} from "../../src/periphery/HookrRouter.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";

/// @dev Drives one points-only Immediate program and two funded daily programs (one global Bux) that share a reward
///      token through trades, attested days, vetoes, approvals, lapses, claims, refunds and donations.
contract HookrProgramHandler is Test {
    HookrPrograms public immutable programs;
    HookrRouter private immutable router;
    IERC20 private immutable cash;
    PoolKey private pool;
    address[2] private users;
    uint256[3] private ids;
    address public immutable reviewer;
    uint256 public immutable days_;
    uint160 private constant MIN_PRICE = 4295128740;
    uint160 private constant MAX_PRICE = 1461446703485210103287273052203988822378723970341;
    bytes32 private constant COVERAGE = keccak256("coverage");
    mapping(uint256 => mapping(uint256 => uint128[2])) private weights;

    constructor(
        HookrPrograms programs_,
        HookrRouter router_,
        IERC20 cash_,
        PoolKey memory pool_,
        address[2] memory users_,
        uint256[3] memory ids_,
        address reviewer_,
        uint256 dayCount
    ) {
        programs = programs_;
        router = router_;
        cash = cash_;
        pool = pool_;
        users = users_;
        ids = ids_;
        reviewer = reviewer_;
        days_ = dayCount;
    }

    function trade(uint256 userSeed, uint256 amountSeed, bool zeroForOne) external {
        if (vm.getBlockTimestamp() >= programs.program(ids[0]).terms.end) return;
        address user = users[userSeed % 2];
        uint128 amount = uint128(bound(amountSeed, 1e12, 1e20));
        IHookrRouter.Swap memory params = IHookrRouter.Swap(
            pool, zeroForOne, -int128(amount), 1, zeroForOne ? MIN_PRICE : MAX_PRICE, user, vm.getBlockTimestamp()
        );
        uint256[] memory targets = new uint256[](3);
        targets[0] = ids[0];
        targets[1] = ids[1];
        targets[2] = ids[2];
        vm.prank(user);
        router.swap(params, address(programs), targets);
    }

    function warp(uint256 seed) external {
        vm.warp(vm.getBlockTimestamp() + bound(seed, 1 hours, 20 days));
    }

    /// @dev Attestor proposes a two-leaf (or zero) day; the reviewer may veto and later approve a corrected version.
    function propose(uint256 programSeed, uint256 daySeed, uint128 w0, uint128 w1, bool veto, bool approve) external {
        uint256 id = ids[programSeed % 2];
        uint256 day = daySeed % days_;
        uint256 end = programs.dayEnd(id, day);
        IHookrPrograms.Epoch memory e = programs.epoch(id, day);
        if (vm.getBlockTimestamp() < end || vm.getBlockTimestamp() >= end + programs.PROPOSAL_WINDOW() || e.finalized) {
            return;
        }
        w0 = uint128(bound(w0, 0, 1e18));
        w1 = uint128(bound(w1, 0, 1e18));
        bytes32 root_;
        if (w0 != 0 && w1 != 0) {
            bytes32 a = _leaf(id, day, users[0], w0);
            bytes32 b = _leaf(id, day, users[1], w1);
            root_ = a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
        } else if (w0 != 0) {
            root_ = _leaf(id, day, users[0], w0);
        } else if (w1 != 0) {
            root_ = _leaf(id, day, users[1], w1);
        }
        programs.proposeDay(id, day, root_, uint256(w0) + w1, COVERAGE, keccak256(abi.encode(w0, w1)));
        weights[id][day] = [w0, w1];
        if (veto) {
            vm.prank(reviewer);
            programs.challengeDay(id, day, keccak256("veto"));
        }
        if (approve) {
            uint64 version = programs.epoch(id, day).version;
            vm.prank(reviewer);
            programs.approveDay(id, day, version);
        }
    }

    /// @dev Finalize the first finalizable day, scanning from a random program.
    function finalize(uint256 seed) external {
        for (uint256 k; k < 2 * days_; ++k) {
            (uint256 id, uint256 day) = _slot(seed % 64 + k);
            IHookrPrograms.Epoch memory e = programs.epoch(id, day);
            if (e.version == 0 || e.finalized || e.challenged || vm.getBlockTimestamp() < e.finalizeAfter) continue;
            programs.finalizeDay(id, day);
            return;
        }
    }

    function lapse(uint256 seed) external {
        for (uint256 k; k < 2 * days_; ++k) {
            (uint256 id, uint256 day) = _slot(seed % 64 + k);
            IHookrPrograms.Epoch memory e = programs.epoch(id, day);
            if (
                e.finalized || vm.getBlockTimestamp() < programs.dayEnd(id, day) + programs.PROPOSAL_WINDOW()
                    || (e.version != 0 && (!e.challenged || vm.getBlockTimestamp() < e.finalizeAfter))
            ) continue;
            programs.lapseDay(id, day);
            return;
        }
    }

    function claimDay(uint256 seed, uint256 userSeed) external {
        for (uint256 k; k < 4 * days_; ++k) {
            (uint256 id, uint256 day) = _slot(seed % 64 + k);
            uint256 u = (userSeed % 2 + k / (2 * days_)) % 2;
            IHookrPrograms.Epoch memory e = programs.epoch(id, day);
            if (!e.finalized || e.totalWeight == 0 || programs.dayClaimed(id, day, users[u])) continue;
            // A finalized day's commitment is the latest proposal this handler made for it.
            uint128 w0 = weights[id][day][0];
            uint128 w1 = weights[id][day][1];
            uint128 weight = u == 0 ? w0 : w1;
            if (weight == 0) continue;
            bytes32[] memory proof;
            if (w0 != 0 && w1 != 0) {
                proof = new bytes32[](1);
                proof[0] = _leaf(id, day, users[1 - u], u == 0 ? w1 : w0);
            }
            programs.claimDay(id, day, users[u], weight, proof);
            return;
        }
    }

    function claimCash(uint256 userSeed, uint256 programSeed) external {
        address user = users[userSeed % 2];
        uint256 id = ids[programSeed % 2];
        if (programs.claimableCash(id, user) != 0) programs.claimCash(id, user, user, 0);
    }

    function release(uint256 seed) external {
        for (uint256 k; k < 2 * days_; ++k) {
            (uint256 id, uint256 day) = _slot(seed % 64 + k);
            IHookrPrograms.Epoch memory e = programs.epoch(id, day);
            if (!e.closed || e.remainderReleased) continue;
            programs.releaseUnusedCash(id, day);
            return;
        }
    }

    function donate(uint256 amountSeed) external {
        uint256 balance = cash.balanceOf(address(this));
        if (balance == 0) return;
        cash.transfer(address(programs), bound(amountSeed, 1, balance));
    }

    function _slot(uint256 seed) private view returns (uint256 id, uint256 day) {
        uint256 slot = seed % (2 * days_);
        id = ids[slot % 2];
        day = slot / 2;
    }

    /// @dev dayLeaf() reads the stored coverage hash, so leaves for a new proposal are built here.
    function _leaf(uint256 id, uint256 day, address user, uint128 weight) private view returns (bytes32) {
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
}

contract HookrProgramInvariantTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;
    HookrPrograms private programs;
    HookrProgramHandler private handler;
    uint256 private globalId;
    uint256 private localId;
    uint256 private pointsId;
    address private second = address(0x777777);
    address private reviewer = address(0x5EE);
    uint256 private constant DAYS = 3;

    function setUp() public {
        _setUpPeriphery();
        (, PoolKey memory key,,) = _launch(true, false);
        programs =
            new HookrPrograms(manager, address(router), address(this), 1e22, address(new HookrReferralRegistry()));
        tokenA.transfer(second, 1e27);
        tokenB.transfer(second, 1e27);
        vm.startPrank(second);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        vm.stopPrank();
        P.Scope[] memory scopes = new P.Scope[](1);
        scopes[0] = P.Scope(
            address(root),
            PoolId.unwrap(key.toId()),
            root.policyHash(key.toId()),
            Currency.unwrap(root.poolConfig(key.toId()).quote),
            1,
            1e15,
            0,
            0
        );
        P.NFTMetadata memory metadata;
        P.Terms memory terms;
        terms.mode = P.Mode.Immediate;
        terms.start = uint64((vm.getBlockTimestamp() / 1 days + 1) * 1 days);
        terms.end = terms.start + uint64(DAYS * 1 days);
        terms.pointBudget = 5000;
        terms.walletPointCap = 3000;
        terms.pointNumerator = 1;
        terms.pointDenominator = 1;
        terms.sourcePolicyHash = keccak256("source units");
        terms.name = "Invariant";
        terms.pointDecimals = 18;
        pointsId = programs.createProgram(terms, scopes, new P.Milestone[](0), metadata);

        terms.mode = P.Mode.DailySwap;
        terms.pointNumerator = 0;
        terms.pointDenominator = 0;
        terms.pointBudget = uint128(3000 * DAYS);
        terms.dailyPointBudget = 3000;
        terms.walletPointCap = 5000;
        terms.rewardToken = address(tokenB);
        terms.cashBudget = uint128(10_000 * DAYS);
        terms.dailyCashBudget = 10_000;
        terms.walletCashCap = 16_000;
        terms.attestor = address(0); // set to the handler below
        terms.reviewer = reviewer;
        terms.reviewDelay = 6 days;

        // The handler is the attestor; deploy it first with placeholder IDs, then create the programs.
        uint256 next = programs.programCount();
        address[2] memory users = [trader, second];
        uint256[3] memory ids = [next + 1, next + 2, pointsId];
        handler = new HookrProgramHandler(programs, router, IERC20(address(tokenB)), key, users, ids, reviewer, DAYS);
        terms.attestor = address(handler);
        tokenB.approve(address(programs), type(uint256).max);
        terms.globalBux = true;
        globalId = programs.createProgram(terms, scopes, new P.Milestone[](0), metadata);
        programs.proposeBuxProgram(globalId);
        vm.warp(vm.getBlockTimestamp() + programs.BUX_APPROVAL_DELAY());
        programs.approveBuxProgram(globalId);
        terms.globalBux = false;
        localId = programs.createProgram(terms, scopes, new P.Milestone[](0), metadata);
        assertEq(globalId, ids[0]);
        assertEq(localId, ids[1]);
        tokenB.transfer(address(handler), 1e20);
        vm.warp(terms.start);
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.trade.selector;
        selectors[1] = handler.warp.selector;
        selectors[2] = handler.propose.selector;
        selectors[3] = handler.finalize.selector;
        selectors[4] = handler.lapse.selector;
        selectors[5] = handler.claimDay.selector;
        selectors[6] = handler.claimCash.selector;
        selectors[7] = handler.release.selector;
        selectors[8] = handler.donate.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
        // Every fuzzed call comes from one account no invariant reads: on a fork, whose base fee is not zero, a call's
        // sender is left holding ETH for its gas, which would read as a balance of a checked contract.
        targetSender(address(uint160(uint256(keccak256("hookr.invariant.sender")))));
    }

    function invariantPointsAllowancesAndCashRemainConserved() public view {
        IHookrPrograms.Program memory a = programs.program(globalId);
        IHookrPrograms.Program memory b = programs.program(localId);
        IHookrPrograms.Program memory c = programs.program(pointsId);
        assertLe(a.pointsIssued, a.terms.pointBudget);
        assertLe(b.pointsIssued, b.terms.pointBudget);
        assertLe(c.pointsIssued, c.terms.pointBudget);
        assertEq(programs.buxIssued(), a.pointsIssued);
        assertLe(programs.buxIssued(), programs.buxReserved());
        assertLe(programs.buxReserved(), programs.buxSupplyCap());
        // Closed days have returned their unissued allowance; only open days still hold theirs.
        uint256 pending;
        for (uint256 d; d < DAYS; ++d) {
            IHookrPrograms.Epoch memory e = programs.epoch(globalId, d);
            if (!e.closed) pending += a.terms.dailyPointBudget - e.pointsAllocated;
        }
        assertEq(programs.buxReserved(), programs.buxIssued() + pending);
        assertEq(programs.points(globalId, trader) + programs.points(globalId, second), a.pointsIssued);
        assertEq(programs.buxBalance(trader), programs.points(globalId, trader));
        assertEq(programs.buxBalance(second), programs.points(globalId, second));
        assertLe(programs.points(globalId, trader), a.terms.walletPointCap);
        assertLe(programs.points(globalId, second), a.terms.walletPointCap);
        assertLe(programs.points(localId, trader), b.terms.walletPointCap);
        assertLe(programs.points(localId, second), b.terms.walletPointCap);
        assertLe(programs.points(pointsId, trader), c.terms.walletPointCap);
        assertLe(programs.points(pointsId, second), c.terms.walletPointCap);
        // Per-program cash ledgers: no program ever pays out more than it funded.
        assertLe(a.cashPaid, a.cashAllocated);
        assertLe(b.cashPaid, b.cashAllocated);
        assertLe(a.cashAllocated + a.cashRefunded, a.terms.cashBudget);
        assertLe(b.cashAllocated + b.cashRefunded, b.terms.cashBudget);
        assertEq(c.cashAllocated + c.cashPaid + c.cashRefunded, 0);
        assertEq(
            programs.reservedCash(address(tokenB)),
            uint256(a.terms.cashBudget) + b.terms.cashBudget - a.cashPaid - b.cashPaid - a.cashRefunded - b.cashRefunded
        );
        assertGe(tokenB.balanceOf(address(programs)), programs.reservedCash(address(tokenB)));
        assertEq(
            programs.claimableCash(globalId, trader) + programs.claimableCash(globalId, second),
            a.cashAllocated - a.cashPaid
        );
        assertEq(
            programs.claimableCash(localId, trader) + programs.claimableCash(localId, second),
            b.cashAllocated - b.cashPaid
        );
    }
}
