// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {HookrPrograms} from "../../src/engagement/HookrPrograms.sol";
import {IHookrPrograms} from "../../src/interfaces/IHookrPrograms.sol";
import {HookrReferralRegistry} from "../../src/engagement/HookrReferralRegistry.sol";
import {HookrProgramTypes as P} from "../../src/types/HookrProgramTypes.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";

/// @dev Stands in for the trusted router and its registry at once: it answers `registry()` with itself and forwards
///      `isRoot` and `guardian` to the real registry, and a test can make the registry read or the guardian read
///      fail.
contract GuardianSourceStub {
    IHookrRegistry internal immutable real;
    bool public registryFails;
    bool public guardianFails;

    constructor(IHookrRegistry real_) {
        real = real_;
    }

    function setFailures(bool registryFails_, bool guardianFails_) external {
        registryFails = registryFails_;
        guardianFails = guardianFails_;
    }

    /// @notice As IHookrRouter.registry: this stub, unless the read fails.
    function registry() external view returns (address) {
        require(!registryFails, "no registry");
        return address(this);
    }

    /// @notice As IHookrRegistry.isRoot, from the real registry.
    function isRoot(address root) external view returns (bool) {
        return real.isRoot(root);
    }

    /// @notice As IHookrRegistry.guardian, from the real registry, unless the read fails.
    function guardian() external view returns (address) {
        require(!guardianFails, "no guardian");
        return real.guardian();
    }
}

/// @notice Hookr Bux approval waits: the owner proposes a Bux program, the approval executes only from
///         BUX_APPROVAL_DELAY (30 minutes) after the proposal until BUX_APPROVAL_GRACE (14 days) after that and before
///         the program starts, and the owner or the Hookr registry's guardian, read live through the trusted router,
///         can veto a pending proposal; a vetoed or expired proposal needs a new one. The reservation itself is
///         unchanged: an approval reserves the program's whole point budget, refused above the unreserved supply.
contract BuxApprovalTimelockTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    HookrPrograms internal programs;
    PoolKey internal key;
    address internal stranger = address(0x5757);
    uint256 internal constant CAP = 10_000;

    event BuxProgramProposed(uint256 indexed id, uint256 readyAt, uint256 expiresAt);
    event BuxProgramVetoed(uint256 indexed id, address indexed by);
    event BuxProgramApproved(uint256 indexed id, uint256 reserved);

    function setUp() public {
        _setUpPeriphery();
        (, key,,) = _launch(true, false);
        programs = new HookrPrograms(manager, address(router), address(this), CAP, address(new HookrReferralRegistry()));
        tokenB.approve(address(programs), type(uint256).max);
    }

    /// @dev A one-day Bux daily program starting `lead` days from the next UTC midnight, with `budget` points.
    function _create(uint64 lead, uint128 budget) internal returns (uint256 id, P.Terms memory t) {
        t.mode = P.Mode.DailySwap;
        t.globalBux = true;
        t.start = uint64((vm.getBlockTimestamp() / 1 days + 1 + lead) * 1 days);
        t.end = t.start + 1 days;
        t.pointBudget = budget;
        t.dailyPointBudget = budget;
        t.walletPointCap = budget;
        t.rewardToken = address(tokenB);
        t.cashBudget = 100;
        t.dailyCashBudget = 100;
        t.walletCashCap = 100;
        t.attestor = address(this);
        t.reviewer = royalty;
        t.reviewDelay = 6 days;
        t.sourcePolicyHash = keccak256("bux");
        t.name = "Bux";
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
        id = programs.createProgram(t, s, new P.Milestone[](0), P.NFTMetadata("", "", "", false));
    }

    function test_constantsAndSelectors() public view {
        assertEq(programs.BUX_APPROVAL_DELAY(), 30 minutes);
        assertEq(programs.BUX_APPROVAL_GRACE(), 14 days);
        assertEq(HookrPrograms.approveBuxProgram.selector, bytes4(0xc6e1429a), "approveBuxProgram keeps its selector");
        assertEq(HookrPrograms.proposeBuxProgram.selector, bytes4(0x809578e0));
        assertEq(HookrPrograms.vetoBuxProgram.selector, bytes4(0x99486944));
    }

    /// The approval waits the full delay, to the second, then reserves the whole point budget once.
    function test_approvalWaitsTheDelay() public {
        (uint256 id,) = _create(0, 6000);
        uint256 readyAt = vm.getBlockTimestamp() + 30 minutes;
        vm.expectEmit(address(programs));
        emit BuxProgramProposed(id, readyAt, readyAt + 14 days);
        programs.proposeBuxProgram(id);
        assertEq(programs.buxApprovalReadyAt(id), readyAt);
        vm.expectRevert(abi.encodeWithSelector(IHookrPrograms.BuxApprovalNotReady.selector, id, readyAt));
        programs.approveBuxProgram(id);
        vm.warp(readyAt - 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrPrograms.BuxApprovalNotReady.selector, id, readyAt));
        programs.approveBuxProgram(id);
        assertEq(programs.buxReserved(), 0);
        vm.warp(readyAt);
        vm.expectEmit(address(programs));
        emit BuxProgramApproved(id, 6000);
        programs.approveBuxProgram(id);
        assertTrue(programs.program(id).buxApproved);
        assertEq(programs.buxReserved(), 6000);
        assertEq(programs.buxApprovalReadyAt(id), 0, "the proposal is consumed");
        vm.expectRevert(IHookrPrograms.InvalidProgram.selector);
        programs.approveBuxProgram(id);
        vm.expectRevert(IHookrPrograms.InvalidProgram.selector);
        programs.proposeBuxProgram(id);
    }

    /// Without a proposal there is nothing to approve or veto.
    function test_nothingToApproveOrVetoWithoutAProposal() public {
        (uint256 id,) = _create(0, 1000);
        vm.expectRevert(abi.encodeWithSelector(IHookrPrograms.BuxApprovalNotReady.selector, id, 0));
        programs.approveBuxProgram(id);
        vm.expectRevert(abi.encodeWithSelector(IHookrPrograms.BuxApprovalNotReady.selector, id, 0));
        programs.vetoBuxProgram(id);
    }

    /// A ready proposal executes until readyAt + 14 days inclusive, then expires; an expired proposal may be proposed
    /// again and waits the full delay.
    function test_proposalExpiresAfterTheGrace() public {
        (uint256 id,) = _create(30, 1000);
        programs.proposeBuxProgram(id);
        uint256 readyAt = programs.buxApprovalReadyAt(id);
        uint256 snapshot = vm.snapshotState();
        vm.warp(readyAt + 14 days);
        programs.approveBuxProgram(id);
        assertTrue(programs.program(id).buxApproved);
        vm.revertToState(snapshot);
        vm.warp(readyAt + 14 days + 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrPrograms.BuxApprovalExpired.selector, id, readyAt + 14 days));
        programs.approveBuxProgram(id);
        programs.proposeBuxProgram(id);
        uint256 again = programs.buxApprovalReadyAt(id);
        assertEq(again, vm.getBlockTimestamp() + 30 minutes);
        vm.warp(again - 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrPrograms.BuxApprovalNotReady.selector, id, again));
        programs.approveBuxProgram(id);
        vm.warp(again);
        programs.approveBuxProgram(id);
        assertEq(programs.buxReserved(), 1000);
    }

    /// A proposal cannot be repeated while it is pending or approvable: the clock is not restartable.
    function test_proposalCannotRepeatWhilePending() public {
        (uint256 id,) = _create(30, 1000);
        programs.proposeBuxProgram(id);
        uint256 readyAt = programs.buxApprovalReadyAt(id);
        vm.expectRevert(abi.encodeWithSelector(IHookrPrograms.BuxApprovalPending.selector, id, readyAt));
        programs.proposeBuxProgram(id);
        vm.warp(readyAt + 14 days);
        vm.expectRevert(abi.encodeWithSelector(IHookrPrograms.BuxApprovalPending.selector, id, readyAt));
        programs.proposeBuxProgram(id);
        vm.warp(readyAt + 14 days + 1);
        programs.proposeBuxProgram(id);
        assertEq(programs.buxApprovalReadyAt(id), vm.getBlockTimestamp() + 30 minutes);
    }

    /// The owner's veto voids a pending or ready proposal; approving again needs a new proposal and a new full wait.
    function test_vetoVoidsTheProposal() public {
        (uint256 id,) = _create(0, 1000);
        programs.proposeBuxProgram(id);
        vm.warp(programs.buxApprovalReadyAt(id));
        vm.expectEmit(address(programs));
        emit BuxProgramVetoed(id, address(this));
        programs.vetoBuxProgram(id);
        assertEq(programs.buxApprovalReadyAt(id), 0);
        vm.expectRevert(abi.encodeWithSelector(IHookrPrograms.BuxApprovalNotReady.selector, id, 0));
        programs.approveBuxProgram(id);
        vm.expectRevert(abi.encodeWithSelector(IHookrPrograms.BuxApprovalNotReady.selector, id, 0));
        programs.vetoBuxProgram(id);
        programs.proposeBuxProgram(id);
        uint256 again = programs.buxApprovalReadyAt(id);
        assertEq(again, vm.getBlockTimestamp() + 30 minutes);
        vm.warp(again - 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrPrograms.BuxApprovalNotReady.selector, id, again));
        programs.approveBuxProgram(id);
        vm.warp(again);
        programs.approveBuxProgram(id);
        assertTrue(programs.program(id).buxApproved);
        assertEq(programs.buxReserved(), 1000);
    }

    /// Only the owner proposes, vetoes or approves; ownership moves the whole path.
    function test_strangerIsRefused() public {
        (uint256 id,) = _create(0, 1000);
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        programs.proposeBuxProgram(id);
        vm.stopPrank();
        programs.proposeBuxProgram(id);
        vm.warp(programs.buxApprovalReadyAt(id));
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        programs.approveBuxProgram(id);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        programs.vetoBuxProgram(id);
        vm.stopPrank();
        programs.transferOwnership(stranger);
        vm.prank(stranger);
        programs.acceptOwnership();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        programs.approveBuxProgram(id);
        vm.prank(stranger);
        programs.approveBuxProgram(id);
        assertTrue(programs.program(id).buxApproved);
    }

    // ───────────────────────────── the guardian's veto ─────────────────────────────

    function _appointGuardian(address next) internal {
        registry.queue(registry.SET_GUARDIAN(), abi.encode(next));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setGuardian(next);
    }

    /// The registry's guardian vetoes a pending or a ready proposal, logged as its own veto; approving then needs a new
    /// proposal and a new full wait.
    function test_guardianVetoesAProposal() public {
        address guardian = address(0x6A7D);
        _appointGuardian(guardian);
        assertEq(router.registry().guardian(), guardian);
        (uint256 id,) = _create(1, 1000);
        programs.proposeBuxProgram(id);
        vm.prank(guardian);
        vm.expectEmit(address(programs));
        emit BuxProgramVetoed(id, guardian);
        programs.vetoBuxProgram(id);
        assertEq(programs.buxApprovalReadyAt(id), 0);
        vm.expectRevert(abi.encodeWithSelector(IHookrPrograms.BuxApprovalNotReady.selector, id, 0));
        programs.approveBuxProgram(id);

        // A ready proposal is vetoed the same way.
        programs.proposeBuxProgram(id);
        vm.warp(programs.buxApprovalReadyAt(id));
        vm.prank(guardian);
        programs.vetoBuxProgram(id);
        vm.expectRevert(abi.encodeWithSelector(IHookrPrograms.BuxApprovalNotReady.selector, id, 0));
        programs.approveBuxProgram(id);
        programs.proposeBuxProgram(id);
        vm.warp(programs.buxApprovalReadyAt(id));
        programs.approveBuxProgram(id);
        assertTrue(programs.program(id).buxApproved);
    }

    /// The guardian may only veto: proposing and approving stay the owner's.
    function test_guardianCannotProposeOrApprove() public {
        address guardian = address(0x6A7D);
        _appointGuardian(guardian);
        (uint256 id,) = _create(1, 1000);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        programs.proposeBuxProgram(id);
        programs.proposeBuxProgram(id);
        vm.warp(programs.buxApprovalReadyAt(id));
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        programs.approveBuxProgram(id);
    }

    /// The guardian is read live: a removed guardian is refused at once, its successor vetoes once appointed, and with
    /// no guardian only the owner vetoes.
    function test_theGuardianIsReadLive() public {
        address first = address(0x6A7D);
        address second = address(0x6A7E);
        (uint256 id,) = _create(1, 1000);
        programs.proposeBuxProgram(id);
        vm.prank(first);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, first));
        programs.vetoBuxProgram(id);

        _appointGuardian(first);
        registry.removeGuardian();
        vm.prank(first);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, first));
        programs.vetoBuxProgram(id);

        _appointGuardian(second);
        vm.prank(first);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, first));
        programs.vetoBuxProgram(id);
        vm.prank(second);
        programs.vetoBuxProgram(id);
        assertEq(programs.buxApprovalReadyAt(id), 0);
    }

    /// The owner's veto never depends on the guardian read: when the router's registry read or the registry's guardian
    /// read fails, the appointed guardian and every other caller are refused and the owner still vetoes.
    function test_aFailingGuardianReadLeavesTheOwnersVeto() public {
        address guardian = address(0x6A7D);
        _appointGuardian(guardian);
        GuardianSourceStub source = new GuardianSourceStub(registry);
        programs = new HookrPrograms(manager, address(source), address(this), CAP, address(new HookrReferralRegistry()));
        tokenB.approve(address(programs), type(uint256).max);
        (uint256 id,) = _create(1, 1000);
        programs.proposeBuxProgram(id);
        vm.prank(guardian);
        programs.vetoBuxProgram(id);
        bool[2] memory registryFails = [true, false];
        for (uint256 i; i < 2; ++i) {
            source.setFailures(registryFails[i], !registryFails[i]);
            programs.proposeBuxProgram(id);
            address[2] memory refused = [guardian, stranger];
            for (uint256 j; j < 2; ++j) {
                vm.prank(refused[j]);
                vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, refused[j]));
                programs.vetoBuxProgram(id);
            }
            programs.vetoBuxProgram(id);
            assertEq(programs.buxApprovalReadyAt(id), 0);
        }
    }

    /// Proposals refuse what approvals refuse: an unknown id, a program without Bux, an approved one and a started one.
    function test_proposalRefusals() public {
        vm.expectRevert(IHookrPrograms.InvalidProgram.selector);
        programs.proposeBuxProgram(99);
        (uint256 id, P.Terms memory t) = _create(0, 1000);
        t.globalBux = false;
        t.pointDecimals = 18;
        P.Scope[] memory s = programs.scopes(id);
        uint256 plain = programs.createProgram(t, s, new P.Milestone[](0), P.NFTMetadata("", "", "", false));
        vm.expectRevert(IHookrPrograms.InvalidProgram.selector);
        programs.proposeBuxProgram(plain);
        vm.warp(t.start);
        vm.expectRevert(IHookrPrograms.InvalidProgram.selector);
        programs.proposeBuxProgram(id);
    }

    /// A proposal does not outlive the program's start: approving then is refused, and the unapproved program refunds
    /// as before.
    function test_startEndsAPendingProposal() public {
        (uint256 id, P.Terms memory t) = _create(0, 1000);
        programs.proposeBuxProgram(id);
        vm.warp(t.start);
        vm.expectRevert(IHookrPrograms.InvalidProgram.selector);
        programs.approveBuxProgram(id);
        uint256 before_ = tokenB.balanceOf(address(this));
        programs.refundUnapprovedBux(id);
        assertTrue(programs.program(id).cancelled);
        assertEq(tokenB.balanceOf(address(this)) - before_, t.cashBudget);
        assertEq(programs.buxReserved(), 0);
    }

    /// The reservation is unchanged: the budget is checked at approval against the unreserved supply, a refused
    /// approval keeps its proposal, and room freed by a closed day lets it execute inside the grace.
    function test_reservationUnchanged() public {
        (uint256 first, P.Terms memory t) = _create(0, 6000);
        (uint256 second,) = _create(10, 6000);
        programs.proposeBuxProgram(first);
        programs.proposeBuxProgram(second);
        vm.warp(programs.buxApprovalReadyAt(second));
        programs.approveBuxProgram(first);
        assertEq(programs.buxReserved(), 6000);
        vm.expectRevert(IHookrPrograms.BudgetExceeded.selector);
        programs.approveBuxProgram(second);
        assertGt(programs.buxApprovalReadyAt(second), 0, "a refused approval keeps its proposal");
        // The first program's only day closes empty: its whole allowance returns.
        vm.warp(t.end);
        programs.proposeDay(first, 0, bytes32(0), 0, keccak256("coverage"), keccak256("evidence"));
        vm.prank(royalty);
        programs.approveDay(first, 0, 1);
        assertEq(programs.buxReserved(), 0);
        programs.approveBuxProgram(second);
        assertEq(programs.buxReserved(), 6000);
        assertEq(programs.buxIssued(), 0);
    }
}
