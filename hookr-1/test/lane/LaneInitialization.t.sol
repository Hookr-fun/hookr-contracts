// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrAdvisory} from "../../src/interfaces/IHookrAdvisory.sol";
import {IHookrLaneRoot} from "../../src/interfaces/IHookrLaneRoot.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {TemplateAdvisory} from "../kit/TemplateAdvisory.sol";
import {LaneFixture} from "./LaneFixture.sol";
import {ScriptedExecutor} from "./mocks/ScriptedExecutor.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";

/// @notice A recapture pool's initialization on HookrRoot: the quote catalog applies (PERIPH-02), the pool freezes the
///         root's open lane and needs one that is on, and an admitted advisory binds on a lane pool beside the lane. A
///         delegated (EIP-7702) subject is refused. Removal locks, codeless subjects and min(pool, admission) caps are
///         the root's own initialization, covered by the default profile's suites.
contract LaneInitializationTest is LaneFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    bytes32 internal constant POOL_LANE = keccak256("PoolLane(bytes32,address,bytes32,uint16,bytes32)");
    uint24 internal constant ADVISORY_CAP = 50_000;
    uint24 internal constant SURCHARGE = 20_000;
    ScriptedExecutor internal exec;
    TemplateAdvisory internal advisory;

    function setUp() public {
        _setUpLane();
        exec = new ScriptedExecutor(manager);
        vm.deal(address(exec), 1e28);
        exec.setRoot(address(root));
        _openLane(address(exec));
    }

    /// PERIPH-02: a recapture pool on a quote outside the registry's catalog is refused, then opens once it is listed.
    function test_unlistedQuoteRefusedForARecapturePool() public {
        HookrToken fake = new HookrToken("USDG", "USDG", 1e30, address(this));
        assertFalse(registry.isQuote(address(fake)));
        fake.transfer(creator, 1e27);
        vm.prank(creator);
        fake.approve(address(launcher), type(uint256).max);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _laneMember(Currency.wrap(address(fake)), _laneRules(true), _kothRc());
        HookrToken s = _newSubject();
        vm.expectRevert(abi.encodeWithSelector(IHookrRootEvents.UnqualifiedQuote.selector, address(fake)));
        vm.prank(creator);
        launcher.launch(
            IHookrLauncher.Token(address(s), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        _catalogQuote(address(fake));
        (, PoolKey[] memory keys) = _launchAs(creator, s, members);
        assertTrue(root.knownPool(keys[0].toId()));
    }

    /// The pool freezes the open lane (executor, codehash, pinned rate, scoped family) and announces it.
    function test_initializationFreezesTheOpenLane() public {
        vm.recordLogs();
        (PoolKey memory key, bytes32 family) = _openPoolWithFamily(ETH, _laneRules(true), _kothRc());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool announced;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(root) || logs[i].topics[0] != POOL_LANE) continue;
            assertEq(logs[i].topics[1], PoolId.unwrap(key.toId()));
            assertEq(address(uint160(uint256(logs[i].topics[2]))), address(exec));
            (bytes32 codeHash, uint16 partnerBps, bytes32 fam) = abi.decode(logs[i].data, (bytes32, uint16, bytes32));
            assertEq(codeHash, address(exec).codehash);
            assertEq(partnerBps, PARTNER_BPS);
            assertEq(fam, keccak256(abi.encode(address(launcher), family)));
            announced = true;
        }
        assertTrue(announced, "PoolLane emitted");
        (address executor, bytes32 frozenHash, uint16 rate, bytes32 f, bool on, uint32 gasCap, uint256 floor) =
            IHookrLaneRoot(address(root)).laneOf(key.toId());
        assertEq(executor, address(exec));
        assertEq(frozenHash, address(exec).codehash);
        assertEq(rate, PARTNER_BPS);
        assertEq(f, keccak256(abi.encode(address(launcher), family)));
        assertTrue(on);
        assertEq(gasCap, LANE_GAS);
        assertEq(floor, _entryFloor(LANE_GAS));
        assertEq(root.feeOnlyFrom(key.toId()), 0, "a lane pool is never fee-only");
    }

    /// A subject whose code is an EIP-7702 delegation designator (0xef0100 || target) is refused on a recapture pool,
    /// as HookrLane refuses it on every pool: the key holder could re-point it at will. The same account holding its
    /// own code again opens the lane pool.
    function test_delegatedSubjectIsRefused() public {
        HookrToken s = _newSubject();
        HookrToken target = new HookrToken("T", "T", 1, address(this));
        bytes memory own = address(s).code;
        vm.etch(address(s), abi.encodePacked(hex"ef0100", address(target)));
        assertEq(address(s).code.length, 23);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _laneMember(ETH, _laneRules(true), _kothRc());
        vm.expectRevert(IHookrRootEvents.InvalidConfig.selector);
        vm.prank(creator);
        launcher.launch{value: members[0].amount0Max}(
            IHookrLauncher.Token(address(s), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        vm.etch(address(s), own);
        (, PoolKey[] memory keys) = _launchAs(creator, s, members);
        assertTrue(root.knownPool(keys[0].toId()));
        (address executor,,,) = _laneOf(keys[0]);
        assertEq(executor, address(exec));
    }

    /// A switched-off executor refuses new recapture launches; opting out still launches on the same root.
    function test_aSwitchedOffLaneRefusesRecaptureLaunches() public {
        registry.stopExecutorLane(address(root), address(exec));
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _laneMember(ETH, _laneRules(false), _recaptureOnlyRc());
        HookrToken s = _newSubject();
        vm.expectRevert(IHookrRootEvents.InvalidConfig.selector);
        vm.prank(creator);
        launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(s), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        HookrTypes.RecaptureConfig memory off;
        PoolKey memory k = _openPool(ETH, _laneRules(false), off);
        (address executor,,,) = _laneOf(k);
        assertEq(executor, address(0));
    }

    function _admitAdvisory() internal {
        advisory = new TemplateAdvisory();
        IHookrRegistry.Admission memory a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: address(advisory),
            codeHash: address(advisory).codehash,
            schemaHash: IHookrAdvisory(address(advisory)).configSchemaHash(),
            caps: HookrTypes.Caps(ADVISORY_CAP, 0, 0),
            gasLimit: 100_000,
            phaseMask: HookrTypes.BEFORE_SWAP,
            feeOnly: true,
            failOpen: false
        });
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
    }

    /// @dev A recapture pool with the template advisory's constant surcharge, launched as `creator`.
    function _launchAdvised(bool lane) internal returns (PoolKey memory key) {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        HookrTypes.RecaptureConfig memory off;
        members[0] = _laneMember(ETH, _laneRules(false), lane ? _recaptureOnlyRc() : off);
        members[0].config.advisory = address(advisory);
        members[0].config.advisoryGasLimit = 100_000;
        members[0].config.advisoryPhases = HookrTypes.BEFORE_SWAP;
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(SURCHARGE);
        HookrToken s = _newSubject();
        vm.prank(creator);
        (bytes32 family,) = launcher.launchAdvised{value: 1e24}(
            IHookrLauncher.Token(address(s), "", "", 0, bytes32(0)),
            address(root),
            members,
            data,
            vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
    }

    /// An admitted advisory binds on a lane pool: the outer swap pays its surcharge, both arb recaptures run, and the
    /// executor's legs pay it too, as any unauthenticated swap of the executor on the pool does.
    function test_anAdvisoryBindsOnALanePool_andLegsPayItsSurcharge() public {
        _admitAdvisory();
        PoolKey memory advised = _launchAdvised(true);
        PoolKey memory plain = _openRecapture(ETH);
        (address executor,,,) = _laneOf(advised);
        assertEq(executor, address(exec), "the advised pool froze the lane");
        exec.set(ScriptedExecutor.Mode.PUSH_NET, 1e18);
        uint256 snap = vm.snapshotState();
        uint256 outPlain = _buy(plain, ETH, whale, 1e20);
        vm.revertToState(snap);
        vm.recordLogs();
        uint256 outAdvised = _buy(advised, ETH, whale, 1e20);
        Outcome memory o = _outcome(vm.getRecordedLogs());
        assertEq(o.succeeded, 2, "both arb recaptures ran on the advised pool");
        assertLt(outAdvised, outPlain, "the outer swap paid the advisory surcharge");
        // A leg on the advised pool against an ordinary swap of the same size.
        vm.revertToState(snap);
        exec.set(ScriptedExecutor.Mode.REVERT, 0);
        uint256 ordinary = exec.outsideSwap(advised, 1e20);
        vm.revertToState(snap);
        exec.set(ScriptedExecutor.Mode.LEG_SAME_POOL, 1e20);
        _buy(advised, ETH, whale, 1e15);
        assertEq(exec.legOuts(0), ordinary, "a leg pays the advisory surcharge as an ordinary swap does");
        assertTrue(rules.accountingInvariant(ETH));
    }
}
