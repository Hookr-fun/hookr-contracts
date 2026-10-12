// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IHookrGoverned} from "../../src/interfaces/IHookrGoverned.sol";
import {HookrComplianceGuard} from "../../src/compliance/HookrComplianceGuard.sol";
import {IHookrComplianceGuard} from "../../src/interfaces/IHookrComplianceGuard.sol";
import {IHookrCompliance} from "../../src/interfaces/IHookrCompliance.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {ComplianceTestBase} from "./ComplianceTestBase.sol";
import {MockRootView} from "../mocks/MockRootView.sol";
import {MockLauncherView} from "../mocks/MockLauncherView.sol";

/// @dev Owner-controlled source: answers the zero-address probe as clean and, once armed, lists every other wallet
///      except an exempt one.
contract ProgrammableSource {
    address public immutable controller;
    bool public armed;
    address public exempt;

    constructor() {
        controller = msg.sender;
    }

    function arm(bool on, address exempt_) external {
        require(msg.sender == controller);
        armed = on;
        exempt = exempt_;
    }

    function isSanctioned(address wallet) external view returns (bool) {
        return armed && wallet != address(0) && wallet != exempt;
    }
}

/// @notice AG-01: installing a sanctions source where none is set waits the full delay, so the owner cannot freeze
///         every exit on guard-bound pools without notice.
contract HookrComplianceInstantSourceTest is ComplianceTestBase {
    using PoolIdLibrary for PoolKey;

    HookrComplianceGuard internal guard;
    MockRootView internal root;
    MockLauncherView internal launcherView;
    address internal seller = makeAddr("seller");
    address internal insider = makeAddr("insider");
    PoolKey internal key;
    PoolId internal id;

    function setUp() public override {
        super.setUp();
        guard = new HookrComplianceGuard(address(compliance));
        root = new MockRootView(address(0));
        launcherView = new MockLauncherView();
        key = PoolKey(
            Currency.wrap(address(0x1000)), Currency.wrap(address(0x2000)), 0x800000, 60, IHooks(address(root))
        );
        id = key.toId();
        launcherView.setFamily(id, keccak256("family"), makeAddr("creator"));
        HookrTypes.PoolConfig memory pc;
        pc.subject = key.currency1;
        pc.quote = key.currency0;
        pc.advisory = address(guard);
        pc.liquidityOwner = address(launcherView);
        pc.advisoryGasLimit = 200_000;
        pc.advisoryPhases = HookrTypes.BEFORE_SWAP;
        vm.prank(address(root));
        guard.bind(
            key, pc, abi.encode(IHookrComplianceGuard.Terms({listId: bytes32(0), requireAll: 0, blockAny: 0, flags: 0}))
        );
    }

    function _sell(address who) internal view returns (bool allowed) {
        HookrTypes.SwapContext memory x;
        x.id = id;
        x.sender = address(0xB0B);
        x.payer = who;
        x.beneficiary = who;
        x.subject = key.currency1;
        x.quote = key.currency0;
        x.authenticated = true;
        x.isBuy = false;
        x.exactInput = true;
        x.amountSpecified = -1e18;
        (allowed,,) = guard.explainSwap(address(root), x);
    }

    function test_switchOnWaitsTheDelay() public {
        vm.startPrank(owner);
        ProgrammableSource evil = new ProgrammableSource();
        evil.arm(true, insider);
        bytes32 op = compliance.operationHash(compliance.SET_SANCTIONS_SOURCE(), abi.encode(address(evil)));
        vm.expectRevert(abi.encodeWithSelector(IHookrGoverned.NotReady.selector, op, 0));
        compliance.setSanctionsSource(address(evil));
        vm.stopPrank();
        assertEq(compliance.sanctionsSource(), address(0));
        assertTrue(_sell(seller), "exits stay open");

        // The queued switch-on is public for the full delay before it can take effect.
        bytes32 kind = compliance.SET_SANCTIONS_SOURCE();
        vm.prank(owner);
        compliance.queue(kind, abi.encode(address(evil)));
        vm.prank(owner);
        vm.expectRevert();
        compliance.setSanctionsSource(address(evil));
        assertTrue(_sell(seller));
        vm.warp(vm.getBlockTimestamp() + DELAY);
        vm.prank(owner);
        compliance.setSanctionsSource(address(evil));
        assertFalse(_sell(seller));
    }
}

/// @notice AG-05: compliance epochs are keyed by subject, so a brake voids only the restore on its own subject.
contract HookrGovernedEpochTest is ComplianceTestBase {
    bytes32 internal constant OTHER = keccak256("hookr.list.other");

    function test_brakeOnOneListKeepsResumeOfAnother() public {
        _timelocked(compliance.CREATE_LIST(), abi.encode(OTHER));
        vm.prank(owner);
        compliance.createList(OTHER);
        vm.prank(guardian);
        compliance.suspendList(LIST);
        vm.prank(guardian);
        compliance.suspendList(OTHER);
        _timelocked(compliance.RESUME_LIST(), abi.encode(OTHER));
        vm.prank(guardian);
        compliance.suspendList(LIST);
        vm.prank(owner);
        compliance.resumeList(OTHER);
        assertFalse(compliance.list(OTHER).suspended);
        assertTrue(compliance.list(LIST).suspended);
    }

    function test_suspendVoidsResumeOfTheSameList() public {
        vm.prank(guardian);
        compliance.suspendList(LIST);
        _timelocked(compliance.RESUME_LIST(), abi.encode(LIST));
        vm.prank(guardian);
        compliance.suspendList(LIST);
        vm.prank(owner);
        vm.expectRevert();
        compliance.resumeList(LIST);
    }

    function test_ownerRotatesGuardianQueueFirst() public {
        address next = makeAddr("nextGuardian");
        _timelocked(compliance.GRANT_GUARDIAN(), abi.encode(next));
        vm.prank(owner);
        compliance.revokeGuardian(guardian);
        vm.prank(owner);
        compliance.grantGuardian(next);
        assertTrue(compliance.isGuardian(next));
        assertFalse(compliance.isGuardian(guardian));
    }

    function test_revokeVoidsGrantOfTheSameGuardian() public {
        _timelocked(compliance.GRANT_GUARDIAN(), abi.encode(guardian));
        vm.prank(owner);
        compliance.revokeGuardian(guardian);
        vm.prank(owner);
        vm.expectRevert();
        compliance.grantGuardian(guardian);
    }
}
