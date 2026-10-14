// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {HookrPrograms} from "../../src/engagement/HookrPrograms.sol";
import {IHookrPrograms} from "../../src/interfaces/IHookrPrograms.sol";
import {HookrReferralRegistry} from "../../src/engagement/HookrReferralRegistry.sol";

/// I-10: HookrPrograms inherited OZ renounceOwnership, so one Bux-owner call permanently disabled Bux approvals.
///
/// Before the fix (base b7aeae64, B14Gov.testC4_ProgramsRenounceDisablesBuxApproval): renounceOwnership set owner()
/// and pendingOwner() to 0, and approveBuxProgram reverted OwnableUnauthorizedAccount for everyone forever (the Bux
/// path is now proposeBuxProgram, a 30-minute wait, then approveBuxProgram; both are owner-only).
/// Fix: renounceOwnership always reverts RenounceDisabled, matching HookrRegistry and HookrTreasury. Ownership still
/// moves only through the two-step transfer; it has no delay (recorded as an owner decision).
contract HookrProgramsRenounceDisabledTest is PeripheryFixture {
    function setUp() public {
        _setUpPeriphery();
    }

    function testRenounceIsDisabledAndPendingNomineeSurvives() public {
        address buxOwner = address(0xB0C5);
        HookrPrograms programs =
            new HookrPrograms(manager, address(router), buxOwner, 1e24, address(new HookrReferralRegistry()));
        vm.prank(buxOwner);
        programs.transferOwnership(address(0xCAFE));
        vm.prank(buxOwner);
        vm.expectRevert(IHookrPrograms.RenounceDisabled.selector);
        programs.renounceOwnership();
        assertEq(programs.owner(), buxOwner);
        assertEq(programs.pendingOwner(), address(0xCAFE));
        vm.prank(address(0xCAFE));
        programs.acceptOwnership();
        assertEq(programs.owner(), address(0xCAFE));
        vm.prank(address(0xCAFE));
        vm.expectRevert(IHookrPrograms.RenounceDisabled.selector);
        programs.renounceOwnership();
    }
}
