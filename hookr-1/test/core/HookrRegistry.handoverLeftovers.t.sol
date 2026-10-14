// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {GovernanceSecurityBase} from "../utils/GovernanceSecurityBase.sol";

/// @notice RC-02 (09-24 audit, gap-lens, never independently verified, Low): what a deployer-EOA owner queued or
///         appointed (matured queue entries, the guardian, a pending treasury target, the paymaster treasury) survives
///         TRANSFER_OWNER.
/// @dev At r31 the leftovers carry no authority for the previous owner. Its queued operations stay queued, but only
///      the new owner can execute them; the guardian it appointed keeps the brakes (which only restrict) until the
///      new owner removes it at once with `removeGuardian`; the treasury's pending target lapses with its owner
///      epoch (F-051, `test/support/HookrTreasury.collectTarget.t.sol`). The release plan never hands over: it deploys HookrRegistry with
///      the registry owner Safe as its constructor owner, so none of this arises unless the owner decides to deploy
///      from an EOA.
contract HookrRegistryHandoverLeftoversTest is GovernanceSecurityBase {
    address internal safe = address(0x5AFE);
    address internal deployerGuardian = address(0xD3);

    function setUp() public {
        _setUpPeriphery();
    }

    function testLeftoversCarryNoAuthorityForThePreviousOwner() public {
        // The deployer-owner appoints itself a guardian and queues an operation it never executes.
        registry.queue(registry.SET_GUARDIAN(), abi.encode(deployerGuardian));
        registry.queue(registry.SET_QUOTE(), abi.encode(address(tokenA), false));
        registry.queue(registry.TRANSFER_OWNER(), abi.encode(safe));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setGuardian(deployerGuardian);
        registry.transferOwnership(safe);
        vm.prank(safe);
        registry.acceptOwnership();
        assertEq(registry.owner(), safe);

        // The previous owner can no longer execute its own matured operation.
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.setQuote(address(tokenA), false);
        // The guardian it appointed still holds the brakes, until the new owner removes it at once.
        assertEq(registry.guardian(), deployerGuardian);
        vm.prank(safe);
        registry.removeGuardian();
        assertEq(registry.guardian(), address(0));
        // The matured leftover stays executable by the new owner only, if it chooses to.
        assertTrue(registry.isQuote(address(tokenA)));
        vm.prank(safe);
        registry.setQuote(address(tokenA), false);
        assertFalse(registry.isQuote(address(tokenA)));
    }
}
