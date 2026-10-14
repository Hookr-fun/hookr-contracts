// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookrGoverned} from "../../src/base/HookrGoverned.sol";
import {IHookrGoverned} from "../../src/interfaces/IHookrGoverned.sol";
import {HookrCompliance} from "../../src/compliance/HookrCompliance.sol";
import {HookrSessionAdvisory} from "../../src/extensions/HookrSessionAdvisory.sol";
import {HookrFeeAdvisory} from "../../src/extensions/HookrFeeAdvisory.sol";
import {HookrLiquidityVault} from "../../src/extensions/HookrLiquidityVault.sol";
import {HookrPaymaster} from "../../src/gasless/HookrPaymaster.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";

/// @dev Stands in for an address that must hold code (a registry, the PoolManager, the EntryPoint).
contract NominationCodeStub {}

/// @notice HookrGoverned.cancelNomination on each contract that inherits it (HookrCompliance, HookrSessionAdvisory,
///         HookrFeeAdvisory, HookrLiquidityVault, HookrPaymaster): the owner alone withdraws the current nominee, at
///         once and with no timelock, so the nominee can no longer accept; nominating again consumes a newly queued
///         TRANSFER_OWNER after a full delay; and it touches no queued operation and no epoch.
abstract contract GovernedNominationTest is Test {
    uint48 internal constant DELAY = 1 days;
    address internal owner = makeAddr("owner");
    address internal nominee = makeAddr("nominee");
    address internal stranger = makeAddr("stranger");
    HookrGoverned internal governed;

    /// @dev The contract under test, owned by `owner` with timelock DELAY.
    function _deploy() internal virtual returns (HookrGoverned);

    function setUp() public {
        vm.warp(1_000_000);
        governed = _deploy();
        assertEq(governed.owner(), owner);
        assertEq(governed.delay(), DELAY);
        assertEq(governed.pendingOwner(), address(0));
    }

    function test_cancelNomination_withdrawsTheNomineeAtOnce() public {
        _nominate(nominee);
        uint256 at = vm.getBlockTimestamp();
        vm.expectEmit(address(governed));
        emit IHookrGoverned.OwnershipNominationCancelled(nominee);
        vm.prank(owner);
        governed.cancelNomination();
        assertEq(vm.getBlockTimestamp(), at, "no delay");
        assertEq(governed.pendingOwner(), address(0));
        assertEq(governed.owner(), owner);
        vm.prank(nominee);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, nominee));
        governed.acceptOwnership();
        assertEq(governed.owner(), owner);
    }

    /// Strangers, the nominee and the deployer cannot cancel. Once the nominee accepts, the former owner cannot either
    /// and the new owner can.
    function test_cancelNomination_isTheOwnersAlone() public {
        _nominate(nominee);
        address[3] memory callers = [stranger, nominee, address(this)];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, callers[i]));
            governed.cancelNomination();
        }
        assertEq(governed.pendingOwner(), nominee, "the nomination stands");
        vm.prank(nominee);
        governed.acceptOwnership();
        assertEq(governed.owner(), nominee);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, owner));
        governed.cancelNomination();
        vm.prank(nominee);
        governed.cancelNomination();
    }

    /// With no nominee it changes nothing and still says so.
    function test_cancelNomination_withoutANomination_changesNothing() public {
        vm.expectEmit(address(governed));
        emit IHookrGoverned.OwnershipNominationCancelled(address(0));
        vm.prank(owner);
        governed.cancelNomination();
        assertEq(governed.pendingOwner(), address(0));
        assertEq(governed.owner(), owner);
    }

    /// The cancelled nomination consumed its TRANSFER_OWNER, so nominating the same account again waits a new full
    /// delay; then the nominee accepts.
    function test_cancelNomination_renominatingNeedsANewQueuedTransfer() public {
        _nominate(nominee);
        vm.prank(owner);
        governed.cancelNomination();
        bytes32 kind = governed.TRANSFER_OWNER();
        bytes32 op = governed.operationHash(kind, abi.encode(nominee));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NotReady.selector, op, uint48(0)));
        governed.transferOwnership(nominee);
        vm.prank(owner);
        governed.queue(kind, abi.encode(nominee));
        uint48 ready = uint48(vm.getBlockTimestamp()) + DELAY;
        vm.warp(ready - 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NotReady.selector, op, ready));
        governed.transferOwnership(nominee);
        vm.warp(ready);
        vm.prank(owner);
        governed.transferOwnership(nominee);
        vm.prank(nominee);
        governed.acceptOwnership();
        assertEq(governed.owner(), nominee);
        assertEq(governed.pendingOwner(), address(0));
    }

    /// It withdraws the current nominee only: a TRANSFER_OWNER queued for another account stays queued and ready (the
    /// owner removes it with `cancel`), and the TRANSFER_OWNER epoch does not move.
    function test_cancelNomination_leavesQueuedTransfersAndTheEpochAlone() public {
        address other = makeAddr("other");
        bytes32 kind = governed.TRANSFER_OWNER();
        vm.prank(owner);
        bytes32 queued = governed.queue(kind, abi.encode(other));
        uint48 ready = governed.readyAt(queued);
        _nominate(nominee);
        vm.prank(owner);
        governed.cancelNomination();
        assertEq(governed.readyAt(queued), ready);
        assertEq(governed.epoch(kind), 0);
        vm.prank(owner);
        governed.transferOwnership(other);
        assertEq(governed.pendingOwner(), other);
        vm.prank(owner);
        governed.cancelNomination();
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, other));
        governed.acceptOwnership();
    }

    /// A second nomination replaces the first; cancelling then withdraws the replacement, and neither can accept.
    function test_cancelNomination_afterAReplacementWithdrawsTheReplacement() public {
        address second = makeAddr("second");
        _nominate(nominee);
        _nominate(second);
        vm.expectEmit(address(governed));
        emit IHookrGoverned.OwnershipNominationCancelled(second);
        vm.prank(owner);
        governed.cancelNomination();
        address[2] memory both = [nominee, second];
        for (uint256 i; i < 2; ++i) {
            vm.prank(both[i]);
            vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, both[i]));
            governed.acceptOwnership();
        }
        assertEq(governed.owner(), owner);
    }

    /// @dev Queues TRANSFER_OWNER(next), waits the delay and nominates `next`.
    function _nominate(address next) internal {
        bytes32 kind = governed.TRANSFER_OWNER();
        vm.prank(owner);
        governed.queue(kind, abi.encode(next));
        vm.warp(vm.getBlockTimestamp() + DELAY);
        vm.expectEmit(address(governed));
        emit IHookrGoverned.OwnershipTransferStarted(owner, next);
        vm.prank(owner);
        governed.transferOwnership(next);
        assertEq(governed.pendingOwner(), next);
    }
}

contract HookrComplianceNominationTest is GovernedNominationTest {
    function _deploy() internal override returns (HookrGoverned) {
        return new HookrCompliance(owner, DELAY);
    }
}

contract HookrSessionAdvisoryNominationTest is GovernedNominationTest {
    function _deploy() internal override returns (HookrGoverned) {
        return new HookrSessionAdvisory(owner, DELAY);
    }
}

contract HookrFeeAdvisoryNominationTest is GovernedNominationTest {
    function _deploy() internal override returns (HookrGoverned) {
        return new HookrFeeAdvisory(owner, DELAY, IHookrRegistry(address(new NominationCodeStub())), address(0));
    }
}

contract HookrLiquidityVaultNominationTest is GovernedNominationTest {
    function _deploy() internal override returns (HookrGoverned) {
        IPoolManager manager = IPoolManager(address(new NominationCodeStub()));
        return new HookrLiquidityVault(manager, makeAddr("protocolRecipient"), owner, DELAY, 1_000);
    }
}

contract HookrPaymasterNominationTest is GovernedNominationTest {
    function _deploy() internal override returns (HookrGoverned) {
        return new HookrPaymaster(address(new NominationCodeStub()), address(0), owner, DELAY, makeAddr("treasury"));
    }
}
