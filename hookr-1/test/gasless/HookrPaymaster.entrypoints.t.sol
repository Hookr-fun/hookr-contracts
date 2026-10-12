// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {HookrPaymaster} from "../../src/gasless/HookrPaymaster.sol";
import {IHookrGoverned} from "../../src/interfaces/IHookrGoverned.sol";
import {IHookrPaymaster} from "../../src/interfaces/IHookrPaymaster.sol";
import {IPaymaster} from "../../src/interfaces/external/IPaymaster.sol";
import {PackedUserOperation} from "../../src/interfaces/external/PackedUserOperation.sol";
import {EntryPointV07Code} from "./EntryPointV07Code.sol";
import {GaslessToken} from "./GaslessMocks.sol";
import {PaymasterFixtures} from "../utils/PaymasterFixtures.sol";

/// @dev The EntryPoint v0.7 stake and deposit surface the paymaster drives.
interface IEntryPointStake {
    struct DepositInfo {
        uint256 deposit;
        bool staked;
        uint112 stake;
        uint32 unstakeDelaySec;
        uint48 withdrawTime;
    }

    function getDepositInfo(address account) external view returns (DepositInfo memory info);
    function balanceOf(address account) external view returns (uint256);
    function depositTo(address account) external payable;
}

/// @notice Paymaster entry points that had no test of their own, against the canonical EntryPoint v0.7 runtime
///         (Robinhood Chain 4663) etched at its address. The owner's EntryPoint stake and deposit: addStake,
///         unlockStake, withdrawStake and withdrawDeposit, each the owner's alone; the stake needs an unstake delay of
///         at least a day and comes back only to the treasury, only after unlockStake and that delay; withdrawDeposit
///         pays the treasury and clips the rebate budget to what stays deposited, and refillDeposit (anyone, from
///         native revenue) never raises it. setTreasury and revokeGuardian, which the scan first counted only by name
///         (a test helper's `setTreasury`, HookrCompliance's `revokeGuardian`): the owner's timelocked move of every
///         withdrawal's destination, and the owner's immediate removal of a guardian.
contract HookrPaymasterEntryPointsTest is PaymasterFixtures {
    address internal constant EP = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address internal constant GUARDIAN = address(0x6A);
    address internal constant STRANGER = address(0xBAD);
    address internal constant ACCOUNT = address(0xACC);
    address internal constant ROUTER = address(0x4001);
    bytes4 internal constant ROUTE = 0x19b36adf;
    /// @dev SimpleAccount execute(address,uint256,bytes).
    bytes4 internal constant EXECUTE = 0xb61d27f6;
    uint32 internal constant DAY = 86_400;
    uint256 internal constant CREDIT = 0.05 ether;
    uint256 internal constant MAX_COST = 0.01 ether;
    uint256 internal constant GAS_COST = 0.001 ether;

    IEntryPointStake internal ep = IEntryPointStake(EP);

    function setUp() public {
        vm.warp(1_760_000_000);
        vm.etch(EP, EntryPointV07Code.RUNTIME);
        assertEq(EP.codehash, EntryPointV07Code.CODEHASH);
        pm = new HookrPaymaster(EP, address(0), OWNER, DELAY, TREASURY);
        usd = new GaslessToken();
        _gov(keccak256("GRANT_GUARDIAN"), abi.encode(GUARDIAN));
        vm.prank(OWNER);
        pm.grantGuardian(GUARDIAN);
        vm.deal(OWNER, 100 ether);
    }

    // ───────────────────────────── stake ─────────────────────────────

    /// Only the owner stakes, with an unstake delay of at least a day; the stake is the paymaster's on the EntryPoint
    /// and grows with each call at the same delay.
    function test_addStake_isTheOwners_withAtLeastADayToUnstake() public {
        address[4] memory callers = [STRANGER, GUARDIAN, TREASURY, KEEPER];
        for (uint256 i; i < callers.length; ++i) {
            vm.deal(callers[i], 1 ether);
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, callers[i]));
            pm.addStake{value: 1 ether}(DAY);
        }
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.InvalidDelay.selector, uint48(DAY - 1)));
        pm.addStake{value: 1 ether}(DAY - 1);

        vm.prank(OWNER);
        pm.addStake{value: 1 ether}(DAY);
        IEntryPointStake.DepositInfo memory info = ep.getDepositInfo(address(pm));
        assertTrue(info.staked);
        assertEq(info.stake, 1 ether);
        assertEq(info.unstakeDelaySec, DAY);
        assertEq(info.deposit, 0, "a stake is not a deposit");
        vm.prank(OWNER);
        pm.addStake{value: 0.5 ether}(DAY);
        assertEq(ep.getDepositInfo(address(pm)).stake, 1.5 ether);
        assertEq(address(pm).balance, 0, "nothing stays in the paymaster");
    }

    /// The stake comes back only after the owner unlocks it and the delay passes, and only to the treasury.
    function test_unlockAndWithdrawStake_payTheTreasuryAfterTheDelay() public {
        vm.prank(OWNER);
        pm.addStake{value: 2 ether}(DAY);
        vm.prank(OWNER);
        vm.expectRevert(bytes("must call unlockStake() first"));
        pm.withdrawStake();

        address[3] memory callers = [STRANGER, GUARDIAN, TREASURY];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, callers[i]));
            pm.unlockStake();
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, callers[i]));
            pm.withdrawStake();
        }

        vm.prank(OWNER);
        pm.unlockStake();
        IEntryPointStake.DepositInfo memory info = ep.getDepositInfo(address(pm));
        assertFalse(info.staked);
        assertEq(info.withdrawTime, uint48(vm.getBlockTimestamp()) + DAY);
        vm.warp(vm.getBlockTimestamp() + DAY - 1);
        vm.prank(OWNER);
        vm.expectRevert(bytes("Stake withdrawal is not due"));
        pm.withdrawStake();

        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 treasury0 = TREASURY.balance;
        uint256 owner0 = OWNER.balance;
        vm.prank(OWNER);
        pm.withdrawStake();
        assertEq(TREASURY.balance, treasury0 + 2 ether, "the treasury gets the stake");
        assertEq(OWNER.balance, owner0, "never the owner");
        info = ep.getDepositInfo(address(pm));
        assertEq(info.stake, 0);
        assertEq(info.unstakeDelaySec, 0);
        assertEq(info.withdrawTime, 0);
        vm.prank(OWNER);
        vm.expectRevert(bytes("No stake to withdraw"));
        pm.withdrawStake();
    }

    // ───────────────────────────── deposit ─────────────────────────────

    /// Only the owner withdraws the deposit, only to the treasury and at most what is deposited; the rebate budget is
    /// clipped to what remains deposited and never raised.
    function test_withdrawDeposit_paysTheTreasury_andClipsTheRebateBudget() public {
        _fundRebates(1 ether);
        vm.deal(address(this), 1 ether);
        ep.depositTo{value: 0.5 ether}(address(pm)); // deposited without raising the budget
        assertEq(ep.balanceOf(address(pm)), 1.5 ether);
        assertEq(pm.rebateBudget(), 1 ether);

        address[4] memory callers = [STRANGER, GUARDIAN, TREASURY, KEEPER];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, callers[i]));
            pm.withdrawDeposit(0.1 ether);
        }

        // Down to 1 ether deposited: the budget fits and stays.
        uint256 treasury0 = TREASURY.balance;
        vm.expectEmit(address(pm));
        emit IHookrPaymaster.DepositWithdrawn(TREASURY, 0.5 ether);
        vm.prank(OWNER);
        pm.withdrawDeposit(0.5 ether);
        assertEq(TREASURY.balance, treasury0 + 0.5 ether);
        assertEq(ep.balanceOf(address(pm)), 1 ether);
        assertEq(pm.rebateBudget(), 1 ether);

        // Down to 0.4 ether: the budget is clipped to it.
        vm.prank(OWNER);
        pm.withdrawDeposit(0.6 ether);
        assertEq(ep.balanceOf(address(pm)), 0.4 ether);
        assertEq(pm.rebateBudget(), 0.4 ether);
        assertEq(TREASURY.balance, treasury0 + 1.1 ether);

        // More than is deposited is refused by the EntryPoint; nothing moves.
        vm.prank(OWNER);
        vm.expectRevert(bytes("Withdraw amount too large"));
        pm.withdrawDeposit(0.4 ether + 1);
        assertEq(ep.balanceOf(address(pm)), 0.4 ether);
        assertEq(pm.rebateBudget(), 0.4 ether);

        // Emptied, the budget is zero; a later deposit through refillDeposit leaves it there and only fundRebates
        // raises it.
        vm.prank(OWNER);
        pm.withdrawDeposit(0.4 ether);
        assertEq(pm.rebateBudget(), 0);
        uint256 revenue = _earnNativeRevenue();
        pm.refillDeposit(revenue);
        assertEq(ep.balanceOf(address(pm)), revenue);
        assertEq(pm.rebateBudget(), 0, "a refill does not raise it");
        _fundRebates(0.3 ether);
        assertEq(pm.rebateBudget(), 0.3 ether, "only fundRebates raises it");
    }

    /// Anyone moves native revenue into the deposit, at most what revenue holds, out of the paymaster's own balance;
    /// the rebate budget and the accounts' credit stay as they were.
    function test_refillDeposit_movesNativeRevenueIntoTheDeposit_withoutRaisingTheBudget() public {
        _fundRebates(0.2 ether);
        uint256 revenue = _earnNativeRevenue();
        assertEq(revenue, GAS_COST, "one op's charge");
        uint256 deposit0 = ep.balanceOf(address(pm));
        uint256 held0 = address(pm).balance;

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IHookrPaymaster.AmountExceedsRevenue.selector, revenue + 1, revenue));
        pm.refillDeposit(revenue + 1);

        vm.expectEmit(address(pm));
        emit IHookrPaymaster.DepositRefilled(revenue);
        vm.prank(STRANGER);
        pm.refillDeposit(revenue);
        assertEq(ep.balanceOf(address(pm)), deposit0 + revenue, "the revenue is deposited");
        assertEq(address(pm).balance, held0 - revenue, "out of the paymaster's own balance");
        assertEq(pm.revenue(address(0)), 0);
        assertEq(pm.rebateBudget(), 0.2 ether, "the budget is not raised");
        assertEq(pm.credit(ACCOUNT, address(0)), CREDIT - GAS_COST, "the account's credit is untouched");
        assertEq(address(pm).balance, pm.totalCredit(address(0)), "what stays backs the credit exactly");
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IHookrPaymaster.AmountExceedsRevenue.selector, 1, 0));
        pm.refillDeposit(1);
    }

    // ───────────────────────────── treasury ─────────────────────────────

    /// The treasury moves only by the owner's SET_TREASURY after a full delay, once per queued operation, and never to
    /// zero; from then on the deposit, revenue, untracked funds and the stake go to the new treasury, never the old.
    function test_setTreasury_isTheOwnersTimelockedMove_andRedirectsEveryWithdrawal() public {
        address next = makeAddr("nextTreasury");
        bytes32 kind = keccak256("SET_TREASURY");
        bytes32 op = pm.operationHash(kind, abi.encode(next));
        address[4] memory callers = [STRANGER, GUARDIAN, TREASURY, next];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, callers[i]));
            pm.setTreasury(next);
        }
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NotReady.selector, op, uint48(0)));
        pm.setTreasury(next);

        vm.prank(OWNER);
        pm.queue(kind, abi.encode(next));
        uint48 ready = uint48(vm.getBlockTimestamp()) + DELAY;
        vm.warp(ready - 1);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NotReady.selector, op, ready));
        pm.setTreasury(next);
        vm.warp(ready);
        vm.expectEmit(address(pm));
        emit IHookrPaymaster.TreasurySet(next);
        vm.prank(OWNER);
        pm.setTreasury(next);
        assertEq(pm.treasury(), next);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NotReady.selector, op, uint48(0)));
        pm.setTreasury(next);

        // A queued zero treasury is refused when it executes.
        vm.prank(OWNER);
        pm.queue(kind, abi.encode(address(0)));
        vm.warp(vm.getBlockTimestamp() + DELAY);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.InvalidAddress.selector, address(0)));
        pm.setTreasury(address(0));
        assertEq(pm.treasury(), next);

        // Every withdrawal now pays `next`.
        uint256 old0 = TREASURY.balance;
        _fundRebates(1 ether);
        uint256 revenue = _earnNativeRevenue();
        vm.startPrank(OWNER);
        pm.addStake{value: 2 ether}(DAY);
        pm.withdrawDeposit(0.25 ether);
        pm.withdrawRevenue(address(0), revenue);
        pm.unlockStake();
        vm.stopPrank();
        vm.deal(address(pm), address(pm).balance + 0.125 ether); // held but not tracked
        vm.prank(OWNER);
        pm.sweepUntracked(address(0));
        vm.warp(vm.getBlockTimestamp() + DAY);
        vm.prank(OWNER);
        pm.withdrawStake();
        assertEq(next.balance, 0.25 ether + revenue + 0.125 ether + 2 ether, "deposit, revenue, untracked, stake");
        assertEq(TREASURY.balance, old0, "the old treasury gets nothing");
    }

    // ───────────────────────────── guardians ─────────────────────────────

    /// Only the owner removes a guardian: not the guardian itself, another guardian or anyone else. The removal acts in
    /// the block it is sent (the removed guardian's brakes are refused, the other guardian keeps its own) and voids a
    /// GRANT_GUARDIAN queued before it.
    function test_revokeGuardian_isTheOwnersAlone_andActsAtOnce() public {
        address second = makeAddr("secondGuardian");
        bytes32 kind = keccak256("GRANT_GUARDIAN");
        _gov(kind, abi.encode(second));
        vm.prank(OWNER);
        pm.grantGuardian(second);
        address[4] memory callers = [GUARDIAN, second, STRANGER, TREASURY];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, callers[i]));
            pm.revokeGuardian(GUARDIAN);
        }
        vm.prank(GUARDIAN);
        pm.haltRebates(); // still a guardian

        vm.prank(OWNER);
        bytes32 regrant = pm.queue(kind, abi.encode(GUARDIAN));
        vm.warp(vm.getBlockTimestamp() + DELAY);
        vm.expectEmit(address(pm));
        emit IHookrPaymaster.GuardianSet(GUARDIAN, false);
        vm.prank(OWNER);
        pm.revokeGuardian(GUARDIAN);
        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(IHookrPaymaster.NotGuardian.selector, GUARDIAN));
        pm.pause();
        vm.prank(second);
        pm.pause();
        assertTrue(pm.paused(), "the other guardian keeps its brakes");

        bytes32 current = pm.operationHash(kind, abi.encode(GUARDIAN));
        assertTrue(current != regrant, "the re-grant queued before the removal is void");
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NotReady.selector, current, uint48(0)));
        pm.grantGuardian(GUARDIAN);
    }

    // ───────────────────────────── helpers ─────────────────────────────

    /// @dev Settles one sponsored op that pays GAS_COST from ACCOUNT's native credit and no protocol fee (so no
    ///      rebate), called as the EntryPoint; returns the native revenue it leaves.
    function _earnNativeRevenue() internal returns (uint256) {
        _setPolicy(_policy(false, 1 ether));
        _allowCall(ROUTER, ROUTE);
        vm.deal(address(this), CREDIT);
        pm.depositCredit{value: CREDIT}(ACCOUNT);
        PackedUserOperation memory op;
        op.sender = ACCOUNT;
        op.callData = abi.encodeWithSelector(EXECUTE, ROUTER, uint256(0), abi.encodeWithSelector(ROUTE));
        op.accountGasLimits = bytes32(uint256(200_000));
        op.gasFees = bytes32(uint256(1 gwei));
        op.paymasterAndData = abi.encodePacked(
            address(pm),
            uint128(100_000),
            uint128(240_000),
            uint8(0),
            address(0),
            type(uint128).max,
            uint48(vm.getBlockTimestamp() + 1 days)
        );
        vm.prank(EP);
        (bytes memory context,) = pm.validatePaymasterUserOp(op, bytes32("op"), MAX_COST);
        vm.prank(EP);
        pm.postOp(IPaymaster.PostOpMode.opSucceeded, context, GAS_COST, 0);
        return pm.revenue(address(0));
    }

    /// The stake and the deposit are separate: withdrawing the whole deposit leaves the stake, and the stake's
    /// withdrawal leaves the deposit.
    function test_stakeAndDepositAreSeparate() public {
        _fundRebates(1 ether);
        vm.prank(OWNER);
        pm.addStake{value: 3 ether}(DAY);
        vm.prank(OWNER);
        pm.withdrawDeposit(1 ether);
        IEntryPointStake.DepositInfo memory info = ep.getDepositInfo(address(pm));
        assertEq(info.deposit, 0);
        assertEq(info.stake, 3 ether);
        assertTrue(info.staked);

        _fundRebates(0.2 ether);
        vm.prank(OWNER);
        pm.unlockStake();
        vm.warp(vm.getBlockTimestamp() + DAY);
        vm.prank(OWNER);
        pm.withdrawStake();
        info = ep.getDepositInfo(address(pm));
        assertEq(info.deposit, 0.2 ether);
        assertEq(info.stake, 0);
        assertEq(pm.rebateBudget(), 0.2 ether);
    }
}
