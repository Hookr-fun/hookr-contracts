// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {HookrPaymaster} from "../../src/gasless/HookrPaymaster.sol";
import {IHookrGoverned} from "../../src/interfaces/IHookrGoverned.sol";
import {IHookrPaymaster} from "../../src/interfaces/IHookrPaymaster.sol";
import {IPaymaster} from "../../src/interfaces/external/IPaymaster.sol";
import {PackedUserOperation} from "../../src/interfaces/external/PackedUserOperation.sol";
import {GaslessToken, MockEntryPoint, MockRulesLedger} from "./GaslessMocks.sol";
import {PaymasterFixtures} from "../utils/PaymasterFixtures.sol";

/// @notice The paymaster's guardian-or-owner brakes that had no test: haltRebates, disableToken, revokeCall,
///         revokeApprovalSpender and removeRebateRules. Each one, sent by a guardian or by the owner, takes effect in
///         the same block; voids every operation of the kind that would undo it queued before it (whatever its
///         arguments), so the undo waits a full delay; refuses every other account; writes only its own switch and
///         that kind's epoch; and leaves the settled books (credit, revenue, the rebate budget and deposit, balances)
///         as they were.
/// @dev The guardian role is checked when it is granted: a delegated (EIP-7702) account is never granted it, so a
///      delegated account that is not the owner reaches no brake. The brakes themselves check the role only: a guardian
///      whose key later delegates keeps its brakes until the owner revokes it at once (a brake only removes power).
contract HookrPaymasterBrakesTest is PaymasterFixtures {
    enum Brake {
        HALT_REBATES,
        DISABLE_TOKEN,
        REVOKE_CALL,
        REVOKE_SPENDER,
        REMOVE_RULES
    }

    struct Books {
        uint256 creditNative;
        uint256 creditUsd;
        uint256 totalCreditNative;
        uint256 totalCreditUsd;
        uint256 revenueNative;
        uint256 revenueUsd;
        uint256 rebateBudget;
        uint256 deposit;
        uint256 heldNative;
        uint256 heldUsd;
        uint256 treasuryNative;
        uint256 treasuryUsd;
    }

    /// @dev HookrGoverned's storage root (erc7201:hookr.governed); `epoch` is the Governance struct's fourth slot.
    uint256 internal constant GOVERNED_SLOT = 0x1dd33d6e7c663fca7615dd42387ea79307807dd042d32ccb3b478f696fce9000;
    address internal constant GUARDIAN = address(0x6A);
    address internal constant ACCOUNT = address(0xACC);
    address internal constant ROUTER = address(0x4001);
    address internal constant STRANGER = address(0xBAD);
    bytes4 internal constant ROUTE = 0x19b36adf;
    bytes4 internal constant APPROVE = 0x095ea7b3;
    /// @dev SimpleAccount execute(address,uint256,bytes).
    bytes4 internal constant EXECUTE = 0xb61d27f6;
    uint256 internal constant MAX_COST = 0.01 ether;
    uint256 internal constant GAS_COST = 0.001 ether;
    uint256 internal constant FEE = 0.004 ether;

    MockEntryPoint internal ep;
    MockRulesLedger internal rulesA;
    MockRulesLedger internal rulesB;
    address internal delegated;

    function setUp() public {
        vm.warp(1_000_000);
        ep = new MockEntryPoint();
        rulesA = new MockRulesLedger();
        rulesB = new MockRulesLedger();
        usd = new GaslessToken();
        pm = new HookrPaymaster(address(ep), address(0), OWNER, DELAY, TREASURY);
        _setPolicy(_policy(false, 1 ether));
        _allowCall(ROUTER, ROUTE);
        _allowCall(address(usd), APPROVE);
        _gov(keccak256("ALLOW_SPENDER"), abi.encode(SPENDER));
        vm.prank(OWNER);
        pm.allowApprovalSpender(SPENDER);
        _addRules(address(rulesA));
        _addRules(address(rulesB));
        _setQuotes(new address[](1));
        _setToken(address(usd), _usdConfig(), USD_PER_ETH);
        _gov(keccak256("GRANT_KEEPER"), abi.encode(KEEPER));
        vm.prank(OWNER);
        pm.grantKeeper(KEEPER);
        _gov(keccak256("GRANT_GUARDIAN"), abi.encode(GUARDIAN));
        vm.prank(OWNER);
        pm.grantGuardian(GUARDIAN);
        _fundRebates(1 ether);

        vm.deal(address(this), 10 ether);
        pm.depositCredit{value: 1 ether}(ACCOUNT);
        usd.mint(address(this), 1_000e18);
        usd.approve(address(pm), type(uint256).max);
        pm.depositTokenCredit(address(usd), ACCOUNT, 500e18);

        // Settled books before any brake: a native op rebated in full and a token op charged in usd.
        vm.prank(KEEPER);
        pm.setRate(address(usd), USD_PER_ETH, 3_600);
        assertEq(_settle(_routeOp(0), rulesA, FEE), GAS_COST, "the native op is rebated");
        assertEq(_settle(_routeOp(1), rulesA, 0), 0, "the token op pays no protocol fee");
        assertGt(pm.revenue(address(usd)), 0);
        assertLt(pm.rebateBudget(), 1 ether);

        delegated = makeAddr("delegated");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", makeAddr("sessionDelegate")));
    }

    // ───────────────────────────── each brake acts at once, by a guardian and by the owner ─────────────────────────

    function test_haltRebates_byGuardianAndOwner_actAtOnce() public {
        _actsAtOnce(Brake.HALT_REBATES);
    }

    function test_disableToken_byGuardianAndOwner_actAtOnce() public {
        _actsAtOnce(Brake.DISABLE_TOKEN);
    }

    function test_revokeCall_byGuardianAndOwner_actAtOnce() public {
        _actsAtOnce(Brake.REVOKE_CALL);
    }

    function test_revokeApprovalSpender_byGuardianAndOwner_actAtOnce() public {
        _actsAtOnce(Brake.REVOKE_SPENDER);
    }

    function test_removeRebateRules_byGuardianAndOwner_actAtOnce() public {
        _actsAtOnce(Brake.REMOVE_RULES);
    }

    /// @dev The brake by `GUARDIAN`, then, once the owner restored the switch through the timelock, by `OWNER`: its
    ///      event, its switch off in the block it was sent, the op it stops in that block, and the books unchanged.
    function _actsAtOnce(Brake b) internal {
        address[2] memory by = [GUARDIAN, OWNER];
        for (uint256 i; i < 2; ++i) {
            if (i == 1) {
                _gov(_restoreKind(b), _restoreArgs(b));
                _restore(b);
            }
            assertTrue(_live(b), "live before the brake");
            Books memory before = _books();
            _expectBrakeEvent(b, by[i]);
            _brake(b, by[i]);
            assertFalse(_live(b), "off in the block it was sent");
            assertEq(abi.encode(_books()), abi.encode(before), "settled books unchanged");
            _assertStops(b);
        }
    }

    /// @dev What each brake stops, checked in the block it was sent.
    function _assertStops(Brake b) internal {
        if (b == Brake.HALT_REBATES) {
            assertEq(pm.policy().rebateBps, 0);
            assertEq(_settle(_routeOp(0), rulesA, FEE), 0, "a fee-paying op gets no rebate");
        } else if (b == Brake.DISABLE_TOKEN) {
            vm.prank(address(ep));
            vm.expectRevert(abi.encodeWithSelector(IHookrPaymaster.UnsupportedToken.selector, address(usd)));
            pm.validatePaymasterUserOp(_routeOp(1), bytes32("h"), MAX_COST);
            vm.expectRevert(abi.encodeWithSelector(IHookrPaymaster.UnsupportedToken.selector, address(usd)));
            pm.depositTokenCredit(address(usd), ACCOUNT, 1e18);
            vm.prank(KEEPER);
            vm.expectRevert(abi.encodeWithSelector(IHookrPaymaster.UnsupportedToken.selector, address(usd)));
            pm.setRate(address(usd), USD_PER_ETH, 3_600);
            vm.expectRevert(abi.encodeWithSelector(IHookrPaymaster.UnsupportedToken.selector, address(usd)));
            pm.quoteCharge(IHookrPaymaster.Mode.TOKEN, address(usd), MAX_COST);
            // Native sponsorship is untouched.
            _validate(_routeOp(0));
        } else if (b == Brake.REVOKE_CALL) {
            (bool allowed, bool valueAllowed) = pm.callPolicy(ROUTER, ROUTE);
            assertFalse(allowed);
            assertFalse(valueAllowed);
            vm.prank(address(ep));
            vm.expectRevert(abi.encodeWithSelector(IHookrPaymaster.CallNotAllowed.selector, ROUTER, ROUTE));
            pm.validatePaymasterUserOp(_routeOp(0), bytes32("h"), MAX_COST);
            // Another allowed call still validates.
            _validate(_op(0, _approveCall(SPENDER)));
        } else if (b == Brake.REVOKE_SPENDER) {
            assertFalse(pm.isApprovalSpender(SPENDER));
            vm.prank(address(ep));
            vm.expectRevert(abi.encodeWithSelector(IHookrPaymaster.ApprovalNotAllowed.selector, SPENDER));
            pm.validatePaymasterUserOp(_op(0, _approveCall(SPENDER)), bytes32("h"), MAX_COST);
            _validate(_routeOp(0));
        } else {
            address[] memory listed = pm.rebateRules();
            assertEq(listed.length, 1);
            assertEq(listed[0], address(rulesB));
            assertEq(_settle(_routeOp(0), rulesA, FEE), 0, "a fee in the removed ledger earns nothing");
            assertEq(_settle(_routeOp(0), rulesB, FEE), GAS_COST, "the other ledger still rebates");
        }
    }

    // ───────────────────────────── each brake writes only its own switch and one epoch ─────────────────────────────

    /// The whole state diff of each brake: no value moves, no call leaves the paymaster (the rebate Rules list lives in
    /// the linked admin library, reached by DELEGATECALL), and the only storage words that change are the brake's own
    /// switch and the epoch of the kind that would undo it, which goes up by one. Removing the first of two rebate
    /// ledgers moves the second into its place, so it changes three words of the list.
    function test_eachBrake_writesOnlyItsSwitchAndOneEpoch() public {
        uint256[5] memory switchWords = [uint256(1), 1, 1, 1, 3];
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 5; ++i) {
            vm.revertToState(snap);
            Brake b = Brake(i);
            bytes32 kind = _restoreKind(b);
            bytes32 epochSlot = keccak256(abi.encode(kind, GOVERNED_SLOT + 3));
            assertEq(uint256(vm.load(address(pm), epochSlot)), pm.epoch(kind), "the epoch slot");
            uint256 epochBefore = pm.epoch(kind);
            vm.startStateDiffRecording();
            _brake(b, GUARDIAN);
            (bytes32[] memory slots, bytes32[] memory olds, bytes32[] memory news, uint256 libraryCalls) =
                _changedWords(vm.stopAndReturnStateDiff());
            assertEq(libraryCalls, b == Brake.REMOVE_RULES ? 1 : 0, "only the rebate Rules list uses the library");
            assertEq(slots.length, switchWords[i] + 1, "the switch and the epoch, nothing else");
            bool sawEpoch;
            for (uint256 j; j < slots.length; ++j) {
                if (slots[j] != epochSlot) continue;
                sawEpoch = true;
                assertEq(uint256(olds[j]), epochBefore);
                assertEq(uint256(news[j]), epochBefore + 1);
            }
            assertTrue(sawEpoch, "the kind's epoch moved");
        }
    }

    // ───────────────────────────── each brake voids the queued undo ─────────────────────────────

    /// A restore queued and matured before the brake can no longer execute; it is void, not pending, and the owner can
    /// still clear it by its old id. A restore queued after the brake waits its own full delay.
    function test_eachBrake_voidsTheQueuedRestore_andARestoreQueuedAfterItWaitsAFullDelay() public {
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 5; ++i) {
            vm.revertToState(snap);
            Brake b = Brake(i);
            bytes32 kind = _restoreKind(b);
            bytes memory args = _restoreArgs(b);
            bytes32 armed = pm.operationHash(kind, args);
            _gov(kind, args); // queued and ready
            assertEq(pm.readyAt(armed), uint48(vm.getBlockTimestamp()));

            _brake(b, GUARDIAN);
            bytes32 current = pm.operationHash(kind, args);
            assertTrue(current != armed, "a new epoch, a new id");
            assertEq(pm.epoch(kind), 1);
            vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NotReady.selector, current, uint48(0)));
            _restore(b);
            assertFalse(_live(b), "the brake holds");
            vm.prank(OWNER);
            pm.cancel(armed);
            assertEq(pm.readyAt(armed), 0);

            vm.prank(OWNER);
            pm.queue(kind, args);
            uint48 ready = uint48(vm.getBlockTimestamp()) + DELAY;
            vm.warp(ready - 1);
            vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NotReady.selector, current, ready));
            _restore(b);
            vm.warp(ready);
            _restore(b);
            assertTrue(_live(b), "restored after a full delay");
        }
    }

    /// The paymaster keys these epochs by kind, so a brake voids every queued operation of its kind, including ones on
    /// other subjects: each one, ready before the brake, can no longer execute. Operations of other kinds stay queued
    /// and execute.
    function test_eachBrake_voidsEveryQueuedOperationOfItsKind_whateverItsArguments() public {
        GaslessToken other = new GaslessToken();
        MockRulesLedger otherLedger = new MockRulesLedger();
        bytes[5] memory otherArgs = [
            abi.encode(_policy(true, 2 ether)),
            abi.encode(address(other), _usdConfig(), USD_PER_ETH),
            abi.encode(address(0x4002), bytes4(0xdeadbeef), true),
            abi.encode(address(0x5F)),
            abi.encode(address(otherLedger))
        ];
        bytes32 unrelated = keccak256("GRANT_KEEPER");
        bytes memory unrelatedArgs = abi.encode(address(0x4F));
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 5; ++i) {
            vm.revertToState(snap);
            Brake b = Brake(i);
            bytes32 kind = _restoreKind(b);
            vm.startPrank(OWNER);
            bytes32 sameKind = pm.queue(kind, otherArgs[i]);
            bytes32 otherKind = pm.queue(unrelated, unrelatedArgs);
            vm.stopPrank();
            vm.warp(vm.getBlockTimestamp() + DELAY);
            _brake(b, GUARDIAN);
            bytes32 current = pm.operationHash(kind, otherArgs[i]);
            assertTrue(current != sameKind, "same kind, other subject: a new id");
            assertEq(pm.readyAt(current), 0);
            vm.prank(OWNER);
            vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NotReady.selector, current, uint48(0)));
            if (b == Brake.HALT_REBATES) pm.setPolicy(_policy(true, 2 ether));
            else if (b == Brake.DISABLE_TOKEN) pm.setToken(address(other), _usdConfig(), USD_PER_ETH);
            else if (b == Brake.REVOKE_CALL) pm.allowCall(address(0x4002), bytes4(0xdeadbeef), true);
            else if (b == Brake.REVOKE_SPENDER) pm.allowApprovalSpender(address(0x5F));
            else pm.addRebateRules(address(otherLedger));
            assertEq(pm.operationHash(unrelated, unrelatedArgs), otherKind, "another kind: untouched");
            vm.prank(OWNER);
            pm.grantKeeper(address(0x4F));
        }
    }

    // ───────────────────────────── each brake refuses every other account ─────────────────────────────

    /// Strangers, the keeper, the treasury, the EntryPoint, the owner's nominee, a revoked guardian and a delegated
    /// (EIP-7702) account are all refused, and nothing changes.
    function test_eachBrake_refusesStrangersOtherRolesAndDelegatedAccounts() public {
        address nominee = makeAddr("nominee");
        _gov(keccak256("TRANSFER_OWNER"), abi.encode(nominee));
        vm.prank(OWNER);
        pm.transferOwnership(nominee);
        address revoked = makeAddr("revokedGuardian");
        _gov(keccak256("GRANT_GUARDIAN"), abi.encode(revoked));
        vm.startPrank(OWNER);
        pm.grantGuardian(revoked);
        pm.revokeGuardian(revoked);
        vm.stopPrank();

        address[7] memory callers = [STRANGER, KEEPER, TREASURY, address(ep), nominee, revoked, delegated];
        for (uint256 i; i < 5; ++i) {
            Brake b = Brake(i);
            uint256 epochBefore = pm.epoch(_restoreKind(b));
            for (uint256 j; j < callers.length; ++j) {
                vm.expectRevert(abi.encodeWithSelector(IHookrPaymaster.NotGuardian.selector, callers[j]));
                _brake(b, callers[j]);
            }
            assertTrue(_live(b), "still live");
            assertEq(pm.epoch(_restoreKind(b)), epochBefore, "nothing voided");
        }
    }

    /// A delegated account is refused the guardian role when the grant executes, so it can never reach a brake.
    function test_aDelegatedAccountIsNeverGrantedTheGuardianRole() public {
        _gov(keccak256("GRANT_GUARDIAN"), abi.encode(delegated));
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.DelegatedAccount.selector, delegated));
        pm.grantGuardian(delegated);
        for (uint256 i; i < 5; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IHookrPaymaster.NotGuardian.selector, delegated));
            _brake(Brake(i), delegated);
        }
    }

    /// The brakes check the role, not the code: a guardian whose key delegates after its grant still brakes (a brake
    /// only removes power) until the owner revokes it, which takes effect at once and voids a queued re-grant.
    function test_aGuardianThatDelegatesAfterItsGrant_keepsItsBrakesUntilTheOwnerRevokesIt() public {
        vm.etch(GUARDIAN, abi.encodePacked(hex"ef0100", makeAddr("sessionDelegate")));
        _brake(Brake.HALT_REBATES, GUARDIAN);
        assertFalse(_live(Brake.HALT_REBATES));
        // A re-grant queued and matured before the revocation.
        bytes32 regrant = keccak256("GRANT_GUARDIAN");
        _gov(regrant, abi.encode(GUARDIAN));
        vm.prank(OWNER);
        pm.revokeGuardian(GUARDIAN);
        for (uint256 i = 1; i < 5; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IHookrPaymaster.NotGuardian.selector, GUARDIAN));
            _brake(Brake(i), GUARDIAN);
        }
        // While delegated it cannot be granted again; undelegated, the re-grant queued before the revocation is void.
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.DelegatedAccount.selector, GUARDIAN));
        pm.grantGuardian(GUARDIAN);
        vm.etch(GUARDIAN, "");
        bytes32 current = pm.operationHash(regrant, abi.encode(GUARDIAN));
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NotReady.selector, current, uint48(0)));
        pm.grantGuardian(GUARDIAN);
    }

    // ───────────────────────────── repeated brakes and exits ─────────────────────────────

    /// A brake on a switch that is already off changes nothing but still voids its kind again; removing a ledger that
    /// is not listed emits nothing.
    function test_aRepeatedBrakeOnlyAdvancesTheEpoch() public {
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 5; ++i) {
            vm.revertToState(snap);
            Brake b = Brake(i);
            bytes32 kind = _restoreKind(b);
            _brake(b, GUARDIAN);
            Books memory before = _books();
            address[] memory listed = pm.rebateRules();
            IHookrPaymaster.Policy memory p = pm.policy();
            vm.recordLogs();
            _brake(b, OWNER);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertEq(logs.length, b == Brake.REMOVE_RULES ? 0 : 1, "its event, or none for an unlisted ledger");
            assertEq(pm.epoch(kind), 2);
            assertFalse(_live(b));
            assertEq(abi.encode(_books()), abi.encode(before));
            assertEq(abi.encode(pm.rebateRules()), abi.encode(listed));
            assertEq(abi.encode(pm.policy()), abi.encode(p));
        }
    }

    /// With every brake applied, accounts still withdraw all their credit in both currencies and the owner still
    /// withdraws revenue: the brakes stop sponsorship, never funds.
    function test_withEveryBrakeOn_creditAndRevenueStillLeave() public {
        for (uint256 i; i < 5; ++i) {
            _brake(Brake(i), GUARDIAN);
        }
        uint256 native = pm.credit(ACCOUNT, address(0));
        uint256 tokens = pm.credit(ACCOUNT, address(usd));
        assertGt(native, 0);
        assertGt(tokens, 0);
        vm.startPrank(ACCOUNT);
        pm.withdrawCredit(address(0), ACCOUNT, native);
        pm.withdrawCredit(address(usd), ACCOUNT, tokens);
        vm.stopPrank();
        assertEq(ACCOUNT.balance, native);
        assertEq(usd.balanceOf(ACCOUNT), tokens);
        uint256 revenueUsd = pm.revenue(address(usd));
        vm.prank(OWNER);
        pm.withdrawRevenue(address(usd), revenueUsd);
        assertEq(usd.balanceOf(TREASURY), revenueUsd);
        assertEq(usd.balanceOf(address(pm)), pm.totalCredit(address(usd)) + pm.revenue(address(usd)));
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _brake(Brake b, address by) internal {
        vm.prank(by);
        if (b == Brake.HALT_REBATES) pm.haltRebates();
        else if (b == Brake.DISABLE_TOKEN) pm.disableToken(address(usd));
        else if (b == Brake.REVOKE_CALL) pm.revokeCall(ROUTER, ROUTE);
        else if (b == Brake.REVOKE_SPENDER) pm.revokeApprovalSpender(SPENDER);
        else pm.removeRebateRules(address(rulesA));
    }

    function _expectBrakeEvent(Brake b, address by) internal {
        vm.expectEmit(address(pm));
        if (b == Brake.HALT_REBATES) emit IHookrPaymaster.RebatesHalted(by);
        else if (b == Brake.DISABLE_TOKEN) emit IHookrPaymaster.TokenDisabled(address(usd));
        else if (b == Brake.REVOKE_CALL) emit IHookrPaymaster.CallSet(ROUTER, ROUTE, false, false);
        else if (b == Brake.REVOKE_SPENDER) emit IHookrPaymaster.ApprovalSpenderSet(SPENDER, false);
        else emit IHookrPaymaster.RebateRulesSet(address(rulesA), false);
    }

    /// @dev The timelocked kind each brake voids.
    function _restoreKind(Brake b) internal pure returns (bytes32) {
        if (b == Brake.HALT_REBATES) return keccak256("SET_POLICY");
        if (b == Brake.DISABLE_TOKEN) return keccak256("SET_TOKEN");
        if (b == Brake.REVOKE_CALL) return keccak256("ALLOW_CALL");
        if (b == Brake.REVOKE_SPENDER) return keccak256("ALLOW_SPENDER");
        return keccak256("ADD_REBATE_RULES");
    }

    function _restoreArgs(Brake b) internal view returns (bytes memory) {
        if (b == Brake.HALT_REBATES) return abi.encode(_policy(false, 1 ether));
        if (b == Brake.DISABLE_TOKEN) return abi.encode(address(usd), _usdConfig(), USD_PER_ETH);
        if (b == Brake.REVOKE_CALL) return abi.encode(ROUTER, ROUTE, false);
        if (b == Brake.REVOKE_SPENDER) return abi.encode(SPENDER);
        return abi.encode(address(rulesA));
    }

    /// @dev The owner executes the brake's undo (consuming the queued operation).
    function _restore(Brake b) internal {
        vm.prank(OWNER);
        if (b == Brake.HALT_REBATES) pm.setPolicy(_policy(false, 1 ether));
        else if (b == Brake.DISABLE_TOKEN) pm.setToken(address(usd), _usdConfig(), USD_PER_ETH);
        else if (b == Brake.REVOKE_CALL) pm.allowCall(ROUTER, ROUTE, false);
        else if (b == Brake.REVOKE_SPENDER) pm.allowApprovalSpender(SPENDER);
        else pm.addRebateRules(address(rulesA));
    }

    /// @dev Whether the switch the brake turns off is on.
    function _live(Brake b) internal view returns (bool) {
        if (b == Brake.HALT_REBATES) return pm.policy().rebateBps != 0;
        if (b == Brake.DISABLE_TOKEN) return pm.tokenConfig(address(usd)).enabled;
        if (b == Brake.REVOKE_CALL) {
            (bool allowed,) = pm.callPolicy(ROUTER, ROUTE);
            return allowed;
        }
        if (b == Brake.REVOKE_SPENDER) return pm.isApprovalSpender(SPENDER);
        address[] memory listed = pm.rebateRules();
        for (uint256 i; i < listed.length; ++i) {
            if (listed[i] == address(rulesA)) return true;
        }
        return false;
    }

    function _books() internal view returns (Books memory k) {
        k.creditNative = pm.credit(ACCOUNT, address(0));
        k.creditUsd = pm.credit(ACCOUNT, address(usd));
        k.totalCreditNative = pm.totalCredit(address(0));
        k.totalCreditUsd = pm.totalCredit(address(usd));
        k.revenueNative = pm.revenue(address(0));
        k.revenueUsd = pm.revenue(address(usd));
        k.rebateBudget = pm.rebateBudget();
        k.deposit = ep.balanceOf(address(pm));
        k.heldNative = address(pm).balance;
        k.heldUsd = usd.balanceOf(address(pm));
        k.treasuryNative = TREASURY.balance;
        k.treasuryUsd = usd.balanceOf(TREASURY);
    }

    /// @dev The paymaster's storage words a recorded call changed, with their first and last values, and the number of
    ///      DELEGATECALLs into a linked library. Every other call the recording saw is the paymaster's own, no value
    ///      moves and only the paymaster's storage is written.
    function _changedWords(VmSafe.AccountAccess[] memory accesses)
        internal
        view
        returns (bytes32[] memory slots, bytes32[] memory olds, bytes32[] memory news, uint256 libraryCalls)
    {
        uint256 total;
        for (uint256 i; i < accesses.length; ++i) {
            VmSafe.AccountAccess memory a = accesses[i];
            if (a.kind == VmSafe.AccountAccessKind.DelegateCall) {
                assertGt(a.account.code.length, 0, "a DELEGATECALL into library code");
                ++libraryCalls;
            } else if (
                a.kind == VmSafe.AccountAccessKind.Call || a.kind == VmSafe.AccountAccessKind.StaticCall
                    || a.kind == VmSafe.AccountAccessKind.CallCode || a.kind == VmSafe.AccountAccessKind.Create
            ) {
                assertEq(a.account, address(pm), "no call leaves the paymaster");
            }
            assertEq(a.oldBalance, a.newBalance, "no value moves");
            total += a.storageAccesses.length;
        }
        bytes32[] memory s = new bytes32[](total);
        bytes32[] memory o = new bytes32[](total);
        bytes32[] memory n = new bytes32[](total);
        uint256 count;
        for (uint256 i; i < accesses.length; ++i) {
            VmSafe.StorageAccess[] memory list = accesses[i].storageAccesses;
            for (uint256 j; j < list.length; ++j) {
                VmSafe.StorageAccess memory w = list[j];
                if (!w.isWrite || w.reverted) continue;
                assertEq(w.account, address(pm), "only the paymaster's storage is written");
                uint256 k;
                while (k < count && s[k] != w.slot) ++k;
                if (k == count) {
                    s[count] = w.slot;
                    o[count] = w.previousValue;
                    ++count;
                }
                n[k] = w.newValue;
            }
        }
        uint256 changed;
        for (uint256 k; k < count; ++k) {
            if (o[k] != n[k]) ++changed;
        }
        slots = new bytes32[](changed);
        olds = new bytes32[](changed);
        news = new bytes32[](changed);
        changed = 0;
        for (uint256 k; k < count; ++k) {
            if (o[k] == n[k]) continue;
            (slots[changed], olds[changed], news[changed]) = (s[k], o[k], n[k]);
            ++changed;
        }
    }

    function _op(uint8 mode, bytes memory callData) internal view returns (PackedUserOperation memory op) {
        op.sender = ACCOUNT;
        op.callData = callData;
        op.accountGasLimits = bytes32(uint256(200_000));
        op.gasFees = bytes32(uint256(1 gwei));
        op.paymasterAndData = abi.encodePacked(
            address(pm),
            uint128(100_000),
            uint128(240_000),
            mode,
            mode == 0 ? address(0) : address(usd),
            type(uint128).max,
            uint48(vm.getBlockTimestamp() + 1 days)
        );
    }

    function _routeOp(uint8 mode) internal view returns (PackedUserOperation memory) {
        return _op(mode, abi.encodeWithSelector(EXECUTE, ROUTER, uint256(0), abi.encodeWithSelector(ROUTE)));
    }

    function _approveCall(address spender) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            EXECUTE, address(usd), uint256(0), abi.encodeWithSelector(APPROVE, spender, type(uint256).max)
        );
    }

    function _validate(PackedUserOperation memory op) internal returns (bytes memory ctx) {
        vm.prank(address(ep));
        (ctx,) = pm.validatePaymasterUserOp(op, bytes32("h"), MAX_COST);
    }

    /// @dev Validates and settles `op` at GAS_COST after it paid `fee` more protocol fee in `ledger` (each ledger is
    ///      cumulative within a transaction, as HookrRules' is); returns the rebate it got.
    function _settle(PackedUserOperation memory op, MockRulesLedger ledger, uint256 fee)
        internal
        returns (uint256 rebate)
    {
        bytes memory ctx = _validate(op);
        if (fee != 0) ledger.set(ACCOUNT, address(0), ledger.paid(ACCOUNT, address(0)) + fee);
        uint256 budget = pm.rebateBudget();
        vm.prank(address(ep));
        pm.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, GAS_COST, 0);
        rebate = budget - pm.rebateBudget();
    }
}
