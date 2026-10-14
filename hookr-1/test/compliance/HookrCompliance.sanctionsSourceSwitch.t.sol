// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IHookrGoverned} from "../../src/interfaces/IHookrGoverned.sol";
import {IHookrCompliance} from "../../src/interfaces/IHookrCompliance.sol";
import {ComplianceTestBase} from "./ComplianceTestBase.sol";
import {MockSanctionsList} from "../fixtures/MockSanctionsList.sol";

/// @notice F-021: the compliance guardian could switch off a healthy external sanctions screen instantly, and
///         switching it back on waited a full delay (PoC C2: a listed buyer went from SANCTIONED to ALLOW).
///         Switching a healthy source off is timelocked, and so is switching one on (AG-01: an instant switch-on let
///         the owner freeze every exit without notice).
contract HookrComplianceSanctionsSourceSwitchTest is ComplianceTestBase {
    address internal listed = makeAddr("ofacListed");

    function _setSourceNow(address src) internal {
        vm.prank(owner);
        compliance.setSanctionsSource(src);
    }

    function test_healthySourceCannotBeClearedInstantly() public {
        _setSource(address(source));
        source.setListed(listed, true);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IHookrCompliance.SourceHealthy.selector, address(source)));
        compliance.clearSanctionsSource();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IHookrCompliance.SourceHealthy.selector, address(source)));
        compliance.clearSanctionsSource();
        assertEq(uint8(_check(listed, 0, 0)), uint8(IHookrCompliance.Decision.SANCTIONED));
        // The timelocked path removes it.
        bytes32 kind = compliance.SET_SANCTIONS_SOURCE();
        bytes32 op = compliance.operationHash(kind, abi.encode(address(0)));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NotReady.selector, op, 0));
        compliance.setSanctionsSource(address(0));
        _timelocked(kind, abi.encode(address(0)));
        _setSourceNow(address(0));
        assertEq(compliance.sanctionsSource(), address(0));
    }

    function test_failingSourceClearedByGuardian() public {
        _setSource(address(source));
        source.setMode(MockSanctionsList.Mode.REVERT);
        vm.prank(guardian);
        compliance.clearSanctionsSource();
        assertEq(compliance.sanctionsSource(), address(0));
    }

    /// Switching on and replacing are timelocked; a source that fails its probe is refused.
    function test_switchOnAndReplaceTimelocked() public {
        bytes32 on = compliance.operationHash(compliance.SET_SANCTIONS_SOURCE(), abi.encode(address(source)));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NotReady.selector, on, 0));
        compliance.setSanctionsSource(address(source));
        _setSource(address(source));
        source.setListed(listed, true);
        assertEq(uint8(_check(listed, 0, 0)), uint8(IHookrCompliance.Decision.SANCTIONED));
        MockSanctionsList other = new MockSanctionsList();
        vm.prank(owner);
        vm.expectRevert();
        compliance.setSanctionsSource(address(other));
        _timelocked(compliance.SET_SANCTIONS_SOURCE(), abi.encode(address(other)));
        _setSourceNow(address(other));
        assertEq(compliance.sanctionsSource(), address(other));

        MockSanctionsList broken = new MockSanctionsList();
        broken.setMode(MockSanctionsList.Mode.TWO);
        _timelocked(compliance.SET_SANCTIONS_SOURCE(), abi.encode(address(broken)));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IHookrCompliance.InvalidSource.selector, address(broken)));
        compliance.setSanctionsSource(address(broken));
    }

    function test_guardianCannotSwitchOn() public {
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.Unauthorized.selector, guardian));
        compliance.setSanctionsSource(address(source));
    }
}
