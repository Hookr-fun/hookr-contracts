// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrRegistry} from "../../src/core/HookrRegistry.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice Unit tests for the registry's queue, execution window, brake, catalog and ownership logic.
contract HookrRegistryTest is PeripheryFixture {
    function setUp() public {
        _setUpPeriphery();
    }

    function _admission(address implementation) internal view returns (IHookrRegistry.Admission memory a) {
        a = IHookrRegistry.Admission(
            IHookrRegistry.Kind.RULES,
            implementation,
            implementation.codehash,
            HookrRules(implementation).configSchemaHash(),
            HookrTypes.Caps(600_000, 200_000, 1000),
            2_000_000,
            3,
            false,
            false
        );
    }

    function testConstructorBounds() public {
        vm.expectRevert(IHookrRegistry.InvalidAddress.selector);
        new HookrRegistry(address(0), manager, 1 days);
        vm.expectRevert(IHookrRegistry.InvalidAddress.selector);
        new HookrRegistry(address(this), IPoolManager(address(0xDEAD)), 1 days);
        HookrRegistry r = new HookrRegistry(address(this), manager, 2 days);
        assertEq(r.delay(), 2 days);
        assertEq(r.owner(), address(this));
        assertEq(r.GRACE_PERIOD(), 14 days);
    }

    function testQueueIsOwnerOnlyAndSingle() public {
        bytes32 kind = registry.SET_LAUNCHER();
        bytes memory args = abi.encode(address(this), true);
        vm.prank(trader);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.queue(kind, args);
        bytes32 op = registry.queue(kind, args);
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.AlreadyQueued.selector, op));
        registry.queue(kind, args);
        // Still single at the last executable second.
        vm.warp(uint256(registry.expiresAt(op)));
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.AlreadyQueued.selector, op));
        registry.queue(kind, args);
    }

    function testCancelRequiresAQueuedOperation() public {
        bytes32 op = registry.operationHash(registry.SET_LAUNCHER(), abi.encode(address(this), true));
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotQueued.selector, op));
        registry.cancel(op);
        registry.queue(registry.SET_LAUNCHER(), abi.encode(address(this), true));
        vm.prank(trader);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.cancel(op);
        registry.cancel(op);
        assertEq(registry.readyAt(op), 0);
        assertEq(registry.expiresAt(op), 0);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, op));
        registry.setLauncher(address(this), true);
    }

    function testQueueTimeAdmissionValidationMatchesExecution() public {
        HookrRules next = new HookrRules(manager, registry, protocol, address(root), 0);
        bytes32 admit = registry.ADMIT();
        IHookrRegistry.Admission memory a = _admission(address(next));
        a.codeHash = bytes32(uint256(1));
        vm.expectRevert(IHookrRegistry.InvalidAdmission.selector);
        registry.queue(admit, abi.encode(address(root), a));
        a = _admission(address(next));
        a.gasLimit = 24_999;
        vm.expectRevert(IHookrRegistry.InvalidAdmission.selector);
        registry.queue(admit, abi.encode(address(root), a));
        a = _admission(address(next));
        a.caps.maxQuoteTakePips = 1_000_000;
        vm.expectRevert(IHookrRegistry.InvalidAdmission.selector);
        registry.queue(admit, abi.encode(address(root), a));
        a = _admission(address(rules));
        vm.expectRevert(IHookrRegistry.AlreadyAdmitted.selector);
        registry.queue(admit, abi.encode(address(root), a));
        a = _admission(address(next));
        registry.queue(admit, abi.encode(address(root), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
        assertEq(registry.admission(address(root), address(next)).implementation, address(next));
    }

    function testRetirementQueueNeedsARegisteredRoot() public {
        bytes32 retire = registry.RETIRE_ROOT();
        vm.expectRevert(IHookrRegistry.InvalidRoot.selector);
        registry.queue(retire, abi.encode(address(0xDEAD)));
        registry.queue(retire, abi.encode(address(root)));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.retireRoot(address(root));
        assertFalse(registry.rootOpen(address(root)));
        assertTrue(registry.isRoot(address(root)));
        // Retired roots cannot receive new admissions either.
        HookrRules next = new HookrRules(manager, registry, protocol, address(root), 0);
        bytes32 admit = registry.ADMIT();
        IHookrRegistry.Admission memory a = _admission(address(next));
        vm.expectRevert(IHookrRegistry.InvalidRoot.selector);
        registry.queue(admit, abi.encode(address(root), a));
    }

    function testLauncherRemovalNeedsNoCodeButNamesAnAddress() public {
        bytes32 kind = registry.SET_LAUNCHER();
        vm.expectRevert(IHookrRegistry.InvalidAddress.selector);
        registry.queue(kind, abi.encode(address(0), false));
        registry.queue(kind, abi.encode(address(launcher), false));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setLauncher(address(launcher), false);
        assertFalse(registry.isLauncher(address(launcher)));
        // The root refuses initialisation from a launcher that is no longer admitted.
        vm.expectRevert(IHookrRootEvents.Unauthorized.selector);
        this.launchExternal();
    }

    function launchExternal() external {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(tokenBCurrency());
        launcher.launch(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
    }

    function tokenBCurrency() internal view returns (Currency) {
        return Currency.wrap(address(tokenB));
    }

    function testPauseAndRetireComposeInRootOpen() public {
        assertTrue(registry.rootOpen(address(root)));
        registry.pauseNewMarkets();
        assertFalse(registry.rootOpen(address(root)));
        assertTrue(registry.isRoot(address(root)));
        registry.queue(registry.RETIRE_ROOT(), abi.encode(address(root)));
        registry.queue(registry.RESUME_NEW_MARKETS(), "");
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.retireRoot(address(root));
        registry.resumeNewMarkets();
        assertFalse(registry.rootOpen(address(root)));
        assertFalse(registry.rootOpen(address(0xDEAD)));
    }

    function testOnlyOwnerExecutesQueuedOperations() public {
        registry.queue(registry.SET_GUARDIAN(), abi.encode(trader));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.prank(trader);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.setGuardian(trader);
        registry.setGuardian(trader);
        assertEq(registry.guardian(), trader);
        vm.prank(trader);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.freezeRoot(address(root));
    }

    function testOwnerRemovesTheGuardianAtOnce() public {
        registry.queue(registry.SET_GUARDIAN(), abi.encode(trader));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setGuardian(trader);
        // Only the owner, not the guardian itself or anyone else.
        vm.prank(trader);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.removeGuardian();
        vm.prank(address(0xBAD));
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.removeGuardian();
        // No queued operation needed.
        vm.expectEmit(true, true, false, false, address(registry));
        emit IHookrRegistry.GuardianSet(trader, address(0));
        registry.removeGuardian();
        assertEq(registry.guardian(), address(0));
        // The former guardian has no brake left.
        vm.prank(trader);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.pauseNewMarkets();
        // Idempotent, and emits nothing without a guardian.
        vm.recordLogs();
        registry.removeGuardian();
        assertEq(vm.getRecordedLogs().length, 0);
        // Appointing a guardian stays timelocked.
        bytes32 op = registry.operationHash(registry.SET_GUARDIAN(), abi.encode(trader));
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.NotReady.selector, op));
        registry.setGuardian(trader);
    }

    /// An operation can still be executed at the last second of its window (ready + GRACE) and is expired the second
    /// after. Mutation gate RG-5 (the window closed a second early).
    function testExecutesAtTheLastSecondOfItsWindow() public {
        bytes32 kind = registry.SET_LAUNCHER();
        bytes memory args = abi.encode(address(tokenA), true);
        bytes32 op = registry.queue(kind, args);
        uint256 lastSecond = uint256(registry.expiresAt(op));
        vm.warp(lastSecond);
        registry.setLauncher(address(tokenA), true);
        assertTrue(registry.isLauncher(address(tokenA)));
        op = registry.queue(registry.SET_LAUNCHER(), abi.encode(address(tokenB), true));
        lastSecond = uint256(registry.expiresAt(op));
        vm.warp(lastSecond + 1);
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.OperationExpired.selector, op, uint48(lastSecond)));
        registry.setLauncher(address(tokenB), true);
    }

    /// The settlement set holds at most MAX_SETTLEMENT (8) currencies: the ninth is refused, at queue time and again at
    /// execution. Mutation gate RG-17 (the set held one more).
    function testSettlementSetIsFullAtEight() public {
        while (registry.settlementCurrencies().length < 8) {
            address c = address(new MockERC20("S", "S", 18));
            registry.queue(keccak256("ADD_SETTLEMENT"), abi.encode(c));
            vm.warp(vm.getBlockTimestamp() + registry.delay());
            registry.addSettlementCurrency(c);
        }
        assertEq(registry.settlementCurrencies().length, 8);
        address ninth = address(new MockERC20("S", "S", 18));
        vm.expectRevert(IHookrRegistry.InvalidLane.selector);
        registry.queue(keccak256("ADD_SETTLEMENT"), abi.encode(ninth));
        vm.expectRevert(IHookrRegistry.InvalidLane.selector);
        registry.addSettlementCurrency(ninth);
        assertEq(registry.settlementCurrencies().length, 8);
    }
}
