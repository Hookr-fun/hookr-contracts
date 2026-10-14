// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {HookrRegistry} from "../../src/core/HookrRegistry.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {GovernanceSecurityBase} from "../utils/GovernanceSecurityBase.sol";

/// @dev Stands in for a session-key delegate: anyone may drive the delegating account.
contract SessionDelegate {
    function execute(address target, bytes calldata data) external returns (bytes memory result) {
        bool ok;
        (ok, result) = target.call(data);
        require(ok, "call");
    }

    fallback() external payable {}
}

/// @notice F-019: the registry accepted an EIP-7702 delegated EOA as owner, nominee or guardian, so whatever the
///         delegate honoured (a session key, a delegate bug) could exercise those powers.
/// @dev Delegation designators are refused for the owner at deployment, for a nominee at queue, execution and
///      acceptance, and for a guardian at queue and execution. Plain EOAs and contracts are still accepted.
contract HookrRegistryDelegatedAuthoritiesTest is GovernanceSecurityBase {
    uint256 internal constant PK = 0xF019;
    address internal delegated;

    function setUp() public {
        _setUpPeriphery();
        vm.setEvmVersion("prague");
        delegated = vm.addr(PK);
    }

    function _delegate(address account, uint256 pk) internal {
        SessionDelegate d = new SessionDelegate();
        vm.signAndAttachDelegation(address(d), pk);
        // The next call applies the authorization.
        (bool ok,) = account.call("");
        assertTrue(ok);
        assertEq(account.code.length, 23);
        assertEq(uint24(bytes3(account.code)), 0xef0100);
    }

    function testDelegatedOwnerRefusedAtDeployment() public {
        _delegate(delegated, PK);
        // Old: deployed with the delegated EOA as owner.
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.DelegatedAccount.selector, delegated));
        new HookrRegistry(delegated, manager, 1 days);
        HookrRegistry plain = new HookrRegistry(vm.addr(0xE0A), manager, 1 days);
        assertEq(plain.owner(), vm.addr(0xE0A));
    }

    function testDelegatedNomineeRefusedAtQueueAndExecution() public {
        _delegate(delegated, PK);
        bytes32 transfer = registry.TRANSFER_OWNER();
        // Old: queued, executed and accepted through the session delegate.
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.DelegatedAccount.selector, delegated));
        registry.queue(transfer, abi.encode(delegated));
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.DelegatedAccount.selector, delegated));
        registry.transferOwnership(delegated);
        assertEq(registry.pendingOwner(), address(0));
    }

    /// A nominee that delegates after nomination cannot accept while delegated.
    function testNomineeDelegatedAfterNominationCannotAccept() public {
        registry.queue(registry.TRANSFER_OWNER(), abi.encode(delegated));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.transferOwnership(delegated);
        _delegate(delegated, PK);
        vm.prank(delegated);
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.DelegatedAccount.selector, delegated));
        registry.acceptOwnership();
        assertEq(registry.owner(), address(this));
        // Undelegated, the same key accepts.
        vm.etch(delegated, "");
        vm.prank(delegated);
        registry.acceptOwnership();
        assertEq(registry.owner(), delegated);
    }

    function testDelegatedGuardianRefusedAtQueueAndExecution() public {
        registry.queue(registry.SET_GUARDIAN(), abi.encode(delegated));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        _delegate(delegated, PK);
        // Old: appointed; the session key could then pause new markets.
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.DelegatedAccount.selector, delegated));
        registry.setGuardian(delegated);
        bytes32 setGuardian = registry.SET_GUARDIAN();
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.DelegatedAccount.selector, delegated));
        registry.queue(setGuardian, abi.encode(delegated));
        assertEq(registry.guardian(), address(0));
    }

    /// Removing the guardian (zero) and appointing a plain EOA stay possible.
    function testPlainAndZeroGuardiansAccepted() public {
        address eoa = vm.addr(0xE0B);
        registry.queue(registry.SET_GUARDIAN(), abi.encode(eoa));
        registry.queue(registry.SET_GUARDIAN(), abi.encode(address(0)));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setGuardian(eoa);
        assertEq(registry.guardian(), eoa);
        registry.setGuardian(address(0));
        assertEq(registry.guardian(), address(0));
    }
}
