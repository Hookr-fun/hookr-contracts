// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {HookrTreasury} from "../../src/support/HookrTreasury.sol";
import {IHookrTreasury} from "../../src/interfaces/IHookrTreasury.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {GovernanceSecurityBase} from "../utils/GovernanceSecurityBase.sol";

/// @notice L-16: an EIP-7702 delegated EOA passed the registry's code.length/codehash check, so its key holder
///         controlled the module's ERC-6909 backing and could re-delegate to change existing pools.
/// @dev Original exploit (base b7aeae64, ReproGovernance.testL16_DelegatedEoaPassesAdmissionAndControlsBacking):
///      the EOA delegated to the fixture Rules was admitted, bound a pool, accrued 56.5e18 quote backing after two
///      buys, and the key holder transferred all 56.5e18 to a thief (accountingInvariant false); re-delegating to a
///      reverting contract then bricked the existing pool.
contract HookrRegistryDelegatedModuleTest is GovernanceSecurityBase {
    uint256 internal constant PK = 0xA11CE;

    function setUp() public {
        _setUpPeriphery();
        vm.setEvmVersion("prague");
    }

    function _delegatedRules() internal returns (address e, bytes32 schema) {
        e = vm.addr(PK);
        vm.signAndAttachDelegation(address(rules), PK);
        schema = HookrRules(e).configSchemaHash(); // applies the authorization
        assertEq(e.code.length, 23);
        assertEq(uint8(e.code[0]), 0xef);
        assertEq(HookrRules(e).trustedRoot(), address(root));
    }

    function testDelegatedEoaAdmissionRefused() public {
        (address e, bytes32 schema) = _delegatedRules();
        IHookrRegistry.Admission memory a = _rulesAdmission(e, e.codehash, schema);
        bytes32 admit = registry.ADMIT();
        // Old: queued, admitted after 1 hour, bound to a pool and drained of 56.5e18 backing.
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.DelegatedAccount.selector, e));
        registry.queue(admit, abi.encode(address(root), a));
        assertEq(registry.admission(address(root), e).implementation, address(0));
        // Execution re-checks before consuming, so no pre-existing queue entry could admit it either.
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.DelegatedAccount.selector, e));
        registry.admit(address(root), a);
    }

    function testDelegatedEoaRefusedForEveryRegistryRole() public {
        (address e,) = _delegatedRules();
        bytes32 setLauncher = registry.SET_LAUNCHER();
        bytes32 setQuote = registry.SET_QUOTE();
        bytes32 register = registry.REGISTER_ROOT();
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.DelegatedAccount.selector, e));
        registry.queue(setLauncher, abi.encode(e, true));
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.DelegatedAccount.selector, e));
        registry.queue(setQuote, abi.encode(e, true));
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.DelegatedAccount.selector, e));
        registry.queue(register, abi.encode(e, e.codehash));
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.DelegatedAccount.selector, e));
        registry.setLauncher(e, true);
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.DelegatedAccount.selector, e));
        registry.setQuote(e, true);
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.DelegatedAccount.selector, e));
        registry.registerRoot(e, e.codehash);
    }

    function testTreasuryRefusesDelegatedSource() public {
        HookrTreasury treasury = new HookrTreasury(address(this), address(0x7A7), manager);
        uint256 pk = 0xB0B;
        address e = vm.addr(pk);
        HookrRules r2 = new HookrRules(manager, registry, address(treasury), address(root), 0);
        vm.signAndAttachDelegation(address(r2), pk);
        assertEq(HookrRules(e).protocolRecipient(), address(treasury));
        vm.expectRevert(IHookrTreasury.InvalidSource.selector);
        treasury.admitSource(e);
        treasury.admitSource(address(r2));
        assertEq(treasury.sourceCodeHash(address(r2)), address(r2).codehash);
        assertEq(treasury.sourceCodeHash(e), bytes32(0));
        Currency native = Currency.wrap(address(0));
        vm.expectRevert(IHookrTreasury.InvalidSource.selector);
        treasury.collect(e, native);
    }

    function testOrdinaryContractsStillAdmitted() public {
        HookrRules next = new HookrRules(manager, registry, protocol, address(root), 0);
        IHookrRegistry.Admission memory a =
            _rulesAdmission(address(next), address(next).codehash, next.configSchemaHash());
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
        assertEq(registry.admission(address(root), address(next)).codeHash, address(next).codehash);
    }
}
