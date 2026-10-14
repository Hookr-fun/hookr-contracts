// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrTreasury} from "../../src/support/HookrTreasury.sol";
import {IHookrTreasury} from "../../src/interfaces/IHookrTreasury.sol";
import {GovernanceSecurityBase} from "../utils/GovernanceSecurityBase.sol";

/// @notice I-11: the treasury owner could redirect protocol cash in the same block, and the immutable factory owner
///         registered roots without the REGISTER_ROOT timelock.
/// @dev Original exploits (base b7aeae64):
///      ReproGovernance.testI11_TreasuryTargetInstant redirected 5e18 wei to a new target in the same block;
///      ReproGovernance.testI11_FactoryRootBypassesRegisterRootTimelock registered and opened a factory root in the
///      same block with no queued operation. Roots now register through a published, codehash-pinned REGISTER_ROOT,
///      or through registerFactoryRoot from a factory activated by a published, codehash-pinned SET_ROOT_FACTORY.
contract HookrRegistryCentralizationTest is GovernanceSecurityBase {
    Currency internal constant NATIVE = Currency.wrap(address(0));

    function setUp() public {
        _setUpPeriphery();
    }

    function testTreasuryRedirectNeedsNoticeAndCanBeOutrun() public {
        HookrTreasury t = new HookrTreasury(address(this), address(0xBEEF), manager);
        vm.deal(address(t), 5 ether);
        t.proposeTarget(address(0xBAD));
        assertEq(t.pendingTarget(), address(0xBAD));
        vm.expectRevert(
            abi.encodeWithSelector(
                IHookrTreasury.TargetNotReady.selector, address(0xBAD), vm.getBlockTimestamp() + 30 minutes
            )
        );
        t.acceptTarget();
        // Old: the same-block forward paid 5e18 to 0xBAD. Now anyone can still flush to the current target.
        vm.prank(address(0xCAFE));
        (uint256 amount, bool delivered) = t.forwardBalance(NATIVE);
        assertTrue(delivered);
        assertEq(amount, 5 ether);
        assertEq(address(0xBEEF).balance, 5 ether);
        assertEq(address(0xBAD).balance, 0);
        vm.warp(vm.getBlockTimestamp() + t.TARGET_DELAY() - 1);
        vm.expectRevert();
        t.acceptTarget();
        vm.warp(vm.getBlockTimestamp() + 1);
        t.acceptTarget();
        assertEq(t.target(), address(0xBAD));
        assertEq(t.pendingTarget(), address(0));
    }

    function testTreasuryProposalRulesAndCancel() public {
        HookrTreasury t = new HookrTreasury(address(this), address(0xBEEF), manager);
        vm.expectRevert(IHookrTreasury.NoPendingTarget.selector);
        t.acceptTarget();
        vm.expectRevert(IHookrTreasury.NoPendingTarget.selector);
        t.cancelTarget();
        vm.expectRevert(IHookrTreasury.InvalidTarget.selector);
        t.proposeTarget(address(0xBEEF));
        vm.expectRevert(IHookrTreasury.InvalidTarget.selector);
        t.proposeTarget(address(0));
        vm.prank(address(0xCAFE));
        vm.expectRevert(IHookrTreasury.NotOwner.selector);
        t.proposeTarget(address(0xBAD));
        t.proposeTarget(address(0xBAD));
        t.cancelTarget();
        assertEq(t.pendingTarget(), address(0));
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.expectRevert(IHookrTreasury.NoPendingTarget.selector);
        t.acceptTarget();
        // A newer proposal restarts the notice period.
        t.proposeTarget(address(0xBAD));
        vm.warp(vm.getBlockTimestamp() + 20 minutes);
        t.proposeTarget(address(0xBAE));
        // Past the first proposal's 30 minutes, 20 minutes into the second's.
        vm.warp(vm.getBlockTimestamp() + 20 minutes);
        vm.expectRevert();
        t.acceptTarget();
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        t.acceptTarget();
        assertEq(t.target(), address(0xBAE));
    }

    /// The treasury's state lives in its ERC-7201 namespace.
    function testTreasuryUsesItsNamespace() public {
        HookrTreasury t = new HookrTreasury(address(this), address(0xBEEF), manager);
        bytes32 slot = keccak256(abi.encode(uint256(keccak256("hookr.treasury")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(address(uint160(uint256(vm.load(address(t), slot)))), address(this));
        assertEq(address(uint160(uint256(vm.load(address(t), bytes32(uint256(slot) + 2))))), address(0xBEEF));
        assertEq(vm.load(address(t), bytes32(0)), bytes32(0));
    }

    /// Old: the factory owner registered roots in the same block. Registration by a factory now needs a factory
    /// activated through a published, codehash-pinned SET_ROOT_FACTORY; any other caller is refused.
    function testFactoryRegistrationNeedsATimelockedFactory() public {
        HookrRoot second = _secondRoot();
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.registerFactoryRoot(address(second), address(0));
        assertFalse(registry.isRootFactory(address(this)));
        (bool ok,) = address(registry).call(abi.encodeWithSignature("isFactory(address)", address(this)));
        assertFalse(ok);
        (ok,) = address(registry).call(abi.encodeWithSignature("SET_FACTORY()"));
        assertFalse(ok);
        assertFalse(registry.isRoot(address(second)));
    }

    /// Old: a factory root was registered and open in its creation block. Now any owner-registered root waits for a
    /// published REGISTER_ROOT, pinned to its runtime codehash, to mature.
    function testNewRootRegistersOnlyThroughPublishedTimelock() public {
        HookrRoot second = _secondRoot();
        bytes32 codeHash = address(second).codehash;
        assertFalse(registry.isRoot(address(second)));
        bytes32 op = registry.operationHash(registry.REGISTER_ROOT(), abi.encode(address(second), codeHash));
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, op));
        registry.registerRoot(address(second), codeHash);
        registry.queue(registry.REGISTER_ROOT(), abi.encode(address(second), codeHash));
        vm.warp(vm.getBlockTimestamp() + registry.delay() - 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, op));
        registry.registerRoot(address(second), codeHash);
        vm.warp(vm.getBlockTimestamp() + 1);
        registry.registerRoot(address(second), codeHash);
        assertTrue(registry.isRoot(address(second)) && registry.rootOpen(address(second)));
        // A registered root cannot be queued again.
        bytes32 register = registry.REGISTER_ROOT();
        vm.expectRevert(IHookrRegistry.InvalidRoot.selector);
        registry.queue(register, abi.encode(address(second), codeHash));
    }
}
