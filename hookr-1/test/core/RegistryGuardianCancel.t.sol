// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {MockIdleExecutor} from "../mocks/MockIdleExecutor.sol";

/// @dev Any contract with code, as a quote asset.
contract CancelQuoteStub {
    function totalSupply() external pure returns (uint256) {
        return 1;
    }
}

/// @notice The guardian cancels a queued registry operation at once, as the owner can. A cancel only withdraws: the
///         owner can queue the operation again, and it then waits a full delay. The guardian still cannot queue or
///         execute anything, and the owner answers a guardian that cancels the owner's own operations by removing it at
///         once and queueing again.
contract RegistryGuardianCancelTest is PeripheryFixture {
    bytes32 internal constant OPEN_LANE = keccak256("OPEN_LANE");
    address internal guardian = address(0x6A7D);
    address internal stranger = address(0x5757);

    function setUp() public {
        _setUpPeriphery();
        registry.queue(registry.SET_GUARDIAN(), abi.encode(guardian));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setGuardian(guardian);
    }

    function _rulesAdmission(address implementation) internal view returns (IHookrRegistry.Admission memory) {
        return IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.RULES,
            implementation: implementation,
            codeHash: implementation.codehash,
            schemaHash: HookrRules(implementation).configSchemaHash(),
            caps: HookrTypes.Caps(600_000, 200_000, 1000),
            gasLimit: 2_000_000,
            phaseMask: 3,
            feeOnly: false,
            failOpen: false
        });
    }

    function _cancelAsGuardian(bytes32 operation) internal {
        vm.expectEmit(true, false, false, false, address(registry));
        emit IHookrRegistry.OperationCancelled(operation);
        vm.prank(guardian);
        registry.cancel(operation);
        assertEq(registry.readyAt(operation), 0);
        assertEq(registry.expiresAt(operation), 0);
    }

    /// A hostile ADMIT, SET_QUOTE and OPEN_LANE, queued by a compromised owner key, are cancelled by the guardian and
    /// never execute.
    function test_guardianCancelsHostileAdmissionsQuotesAndLanes() public {
        HookrRules hostile = new HookrRules(manager, registry, protocol, address(root), 0);
        IHookrRegistry.Admission memory a = _rulesAdmission(address(hostile));
        bytes32 admitOp = registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        CancelQuoteStub quote = new CancelQuoteStub();
        bytes32 quoteOp = registry.queue(registry.SET_QUOTE(), abi.encode(address(quote), true));
        MockIdleExecutor executor = new MockIdleExecutor();
        bytes memory laneArgs = abi.encode(address(root), address(executor), address(executor).codehash, 600_000, 2_500);
        bytes32 laneOp = registry.queue(OPEN_LANE, laneArgs);

        _cancelAsGuardian(admitOp);
        _cancelAsGuardian(quoteOp);
        _cancelAsGuardian(laneOp);

        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, admitOp));
        registry.admit(address(root), a);
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, quoteOp));
        registry.setQuote(address(quote), true);
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, laneOp));
        registry.openLaneOf(address(root), address(executor), address(executor).codehash, 600_000, 2_500);
        assertEq(registry.admission(address(root), address(hostile)).implementation, address(0));
        assertFalse(registry.isQuote(address(quote)));
        (address laneExecutor,,,) = registry.activeLaneOf(address(root));
        assertEq(laneExecutor, address(0));
    }

    /// The guardian holds no permissive power: it cannot queue an operation or execute one the owner queued.
    function test_guardianCannotQueueOrExecute() public {
        bytes32 kind = registry.SET_QUOTE();
        CancelQuoteStub quote = new CancelQuoteStub();
        bytes memory arguments = abi.encode(address(quote), true);
        vm.prank(guardian);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.queue(kind, arguments);

        registry.queue(kind, arguments);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.prank(guardian);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.setQuote(address(quote), true);
        registry.setQuote(address(quote), true);
        assertTrue(registry.isQuote(address(quote)));
    }

    /// A cancelled operation can be queued again, and it then executes a full delay after the new queue.
    function test_cancelledOperationCanBeQueuedAgain() public {
        CancelQuoteStub quote = new CancelQuoteStub();
        bytes32 kind = registry.SET_QUOTE();
        bytes memory arguments = abi.encode(address(quote), true);
        bytes32 operation = registry.queue(kind, arguments);
        vm.warp(vm.getBlockTimestamp() + registry.delay() - 1);
        _cancelAsGuardian(operation);
        assertEq(registry.queue(kind, arguments), operation);
        uint48 eta = registry.readyAt(operation);
        assertEq(eta, vm.getBlockTimestamp() + registry.delay());
        vm.warp(uint256(eta) - 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, operation));
        registry.setQuote(address(quote), true);
        vm.warp(eta);
        registry.setQuote(address(quote), true);
        assertTrue(registry.isQuote(address(quote)));
    }

    /// A compromised guardian cancels the owner's SET_GUARDIAN that would replace it. The owner removes it at once,
    /// queues the appointment again, and the new guardian takes office a delay later.
    function test_guardianCancellingItsReplacementIsAnsweredByRemoveGuardian() public {
        address next = address(0x6A7E);
        bytes32 kind = registry.SET_GUARDIAN();
        bytes32 operation = registry.queue(kind, abi.encode(next));
        _cancelAsGuardian(operation);

        registry.removeGuardian();
        assertEq(registry.guardian(), address(0));
        vm.prank(guardian);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.cancel(operation);

        assertEq(registry.queue(kind, abi.encode(next)), operation);
        vm.prank(guardian);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.cancel(operation);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setGuardian(next);
        assertEq(registry.guardian(), next);
    }

    /// A stranger cannot cancel, nor can anyone cancel what is not queued.
    function test_strangersCannotCancel() public {
        bytes32 operation = registry.queue(registry.SET_LAUNCHER(), abi.encode(address(launcher), false));
        vm.prank(stranger);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.cancel(operation);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotQueued.selector, bytes32(uint256(1))));
        registry.cancel(bytes32(uint256(1)));
        assertGt(registry.readyAt(operation), 0);
    }
}
