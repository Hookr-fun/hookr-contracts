// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHookrGoverned} from "../../src/interfaces/IHookrGoverned.sol";
import {HookrCompliance} from "../../src/compliance/HookrCompliance.sol";
import {HookrComplianceGuard} from "../../src/compliance/HookrComplianceGuard.sol";
import {IHookrComplianceGuard} from "../../src/interfaces/IHookrComplianceGuard.sol";
import {HookrPaymaster} from "../../src/gasless/HookrPaymaster.sol";
import {HookrTreasury} from "../../src/support/HookrTreasury.sol";
import {IHookrTreasury} from "../../src/interfaces/IHookrTreasury.sol";
import {MockEntryPoint} from "../gasless/GaslessMocks.sol";

/// @notice F-019 / F-037: an EIP-7702 delegated EOA (code 0xef0100 || delegate) was accepted as owner, nominee,
///         guardian or external admission, so a delegate's session keys could exercise owner powers.
/// @dev PoC (final-core GovernanceLens): a delegated owner key queued TRANSFER_OWNER to itself. Each case below
///      succeeded on the old code; every one now reverts.
contract HookrGovernedDelegatedGovernanceTest is Test {
    uint48 internal constant DELAY = 1 days;
    address internal owner = makeAddr("owner");
    address internal delegated = makeAddr("delegated");
    address internal delegate = makeAddr("sessionDelegator");
    HookrCompliance internal compliance;

    function setUp() public {
        vm.warp(1_000_000);
        vm.etch(delegate, hex"00");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", delegate));
        compliance = new HookrCompliance(owner, DELAY);
    }

    function _timelocked(bytes32 kind, bytes memory arguments) internal {
        vm.prank(owner);
        compliance.queue(kind, arguments);
        vm.warp(vm.getBlockTimestamp() + DELAY);
    }

    function test_governedRefusesDelegatedOwner() public {
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.DelegatedAccount.selector, delegated));
        new HookrCompliance(delegated, DELAY);
    }

    function test_governedRefusesDelegatedNomineeAtQueue() public {
        bytes32 kind = compliance.TRANSFER_OWNER();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.DelegatedAccount.selector, delegated));
        compliance.queue(kind, abi.encode(delegated));
    }

    /// A nominee queued while plain that delegates before execution or acceptance is refused at both points.
    function test_governedRefusesNomineeThatDelegatesLater() public {
        address nominee = makeAddr("nominee");
        _timelocked(compliance.TRANSFER_OWNER(), abi.encode(nominee));
        vm.etch(nominee, abi.encodePacked(hex"ef0100", delegate));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.DelegatedAccount.selector, nominee));
        compliance.transferOwnership(nominee);
        vm.etch(nominee, "");
        vm.prank(owner);
        compliance.transferOwnership(nominee);
        vm.etch(nominee, abi.encodePacked(hex"ef0100", delegate));
        vm.prank(nominee);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.DelegatedAccount.selector, nominee));
        compliance.acceptOwnership();
        assertEq(compliance.owner(), owner);
    }

    function test_complianceRefusesDelegatedGuardian() public {
        bytes32 kind = compliance.GRANT_GUARDIAN();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.DelegatedAccount.selector, delegated));
        compliance.queue(kind, abi.encode(delegated));
        address later = makeAddr("laterGuardian");
        _timelocked(kind, abi.encode(later));
        vm.etch(later, abi.encodePacked(hex"ef0100", delegate));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.DelegatedAccount.selector, later));
        compliance.grantGuardian(later);
    }

    function test_paymasterRefusesDelegatedGuardian() public {
        MockEntryPoint ep = new MockEntryPoint();
        HookrPaymaster pm = new HookrPaymaster(address(ep), address(0), owner, DELAY, makeAddr("treasury"));
        vm.prank(owner);
        pm.queue(keccak256("GRANT_GUARDIAN"), abi.encode(delegated));
        vm.warp(vm.getBlockTimestamp() + DELAY);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.DelegatedAccount.selector, delegated));
        pm.grantGuardian(delegated);
    }

    function test_treasuryRefusesDelegatedOwnerAndNominee() public {
        IPoolManager manager = IPoolManager(address(new MockEntryPoint()));
        vm.expectRevert(abi.encodeWithSelector(IHookrTreasury.DelegatedAccount.selector, delegated));
        new HookrTreasury(delegated, address(0xBEEF), manager);
        HookrTreasury t = new HookrTreasury(address(this), address(0xBEEF), manager);
        vm.expectRevert(abi.encodeWithSelector(IHookrTreasury.DelegatedAccount.selector, delegated));
        t.proposeOwner(delegated);
        address nominee = makeAddr("treasuryNominee");
        t.proposeOwner(nominee);
        vm.etch(nominee, abi.encodePacked(hex"ef0100", delegate));
        vm.prank(nominee);
        vm.expectRevert(abi.encodeWithSelector(IHookrTreasury.DelegatedAccount.selector, nominee));
        t.acceptOwnership();
        assertEq(t.owner(), address(this));
    }

    /// F-037: a delegated account is refused as the sanctions source and as the guard's compliance registry.
    function test_delegatedAdmissionsRefused() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.DelegatedAccount.selector, delegated));
        compliance.setSanctionsSource(delegated);
        vm.expectRevert(abi.encodeWithSelector(IHookrComplianceGuard.InvalidCompliance.selector, delegated));
        new HookrComplianceGuard(delegated);
    }
}
