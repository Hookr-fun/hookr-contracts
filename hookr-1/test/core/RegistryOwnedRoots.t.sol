// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {HookrRegistry} from "../../src/core/HookrRegistry.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrAdmissions} from "../../src/interfaces/IHookrAdmissions.sol";
import {IHookrExternalHooks} from "../../src/interfaces/IHookrExternalHooks.sol";
import {IHookrLanes} from "../../src/interfaces/IHookrLanes.sol";
import {IHookrOwnedRoots} from "../../src/interfaces/IHookrOwnedRoots.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {MockOwnedRootFactory} from "../mocks/MockOwnedRootFactory.sol";
import {MockModuleBond} from "../mocks/MockModuleBond.sol";
import {MockIdleExecutor} from "../mocks/MockIdleExecutor.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";

/// @dev An advisory or a gate as the registry sees it: code it pins and never calls.
contract OwnedModuleStub {}

/// @dev The same module with other runtime code, to model a codehash drift.
contract OwnedModuleStubV2 {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev A root as `registerOwnedRoot` probes it, with every answer settable: the registry, PoolManager, router, quoter,
///      curated router and permission flags it reports, and the lane module and codehash it reports from
///      `laneModule()`.
contract OwnedRootStub {
    address public registry;
    address public poolManager;
    address public router;
    address public quoter;
    address public curatedRouter;
    uint160 public PERMISSION_FLAGS;
    address internal module;
    bytes32 internal moduleHash;

    function set(address[5] calldata wiring, uint160 flags) external {
        (registry, poolManager, router, quoter, curatedRouter) = (wiring[0], wiring[1], wiring[2], wiring[3], wiring[4]);
        PERMISSION_FLAGS = flags;
    }

    function setModule(address module_, bytes32 moduleHash_) external {
        (module, moduleHash) = (module_, moduleHash_);
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        if (input.length == 4 && bytes4(input) == bytes4(keccak256("laneModule()")) && module != address(0)) {
            return abi.encode(module, moduleHash);
        }
        revert();
    }
}

/// @dev A pair-root factory as the registry sees it: code that registers the roots it names.
contract OwnedPairFactoryStub {
    function register(HookrRegistry registry, address root) external {
        registry.registerFactoryRoot(root, address(0));
    }
}

/// @dev Reports the registry it names, which is all `registerFactoryRoot` asks of a root.
contract OwnedPairRootStub {
    address public immutable registry;

    constructor(address registry_) {
        registry = registry_;
    }
}

/// @notice Owned roots: an active root factory, pinned by runtime codehash through SET_ROOT_FACTORY, registers an
///         unmodified HookrRoot it deployed, frozen with its companion Rules (the template's RULES admission with caps
///         no wider), the template's live ADVISORY and GATE admissions it names (at most four of each) and the
///         template's open lane with its switch off, so the owned root starts without arb recapture and only a
///         timelocked LANE_ON or OPEN_LANE queued after the registration starts it. `rootOpenFor` asks the root's
///         factory who may open pools on it. Every brake reaches an owned root, the module brake by the owner alone
///         since the root is frozen.
contract RegistryOwnedRootsTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    bytes32 internal constant OPEN_LANE = keccak256("OPEN_LANE");
    bytes32 internal constant LANE_ON = keccak256("LANE_ON");
    bytes32 internal constant SET_ADMISSION_BOND = keccak256("SET_ADMISSION_BOND");
    bytes32 internal constant GATE_SCHEMA = keccak256("IHookrSwapGate");
    uint32 internal constant LANE_GAS = 600_000;
    uint16 internal constant LANE_SHARE = 2_500;
    address internal guardian = address(0x6A7D);
    address internal stranger = address(0x5757);
    address internal brand = address(0xB4A9D);
    MockOwnedRootFactory internal factory;
    MockIdleExecutor internal executor;
    OwnedModuleStub[5] internal advisories;
    OwnedModuleStub[5] internal gates;
    uint256 internal nextSalt = 1 << 128;

    function setUp() public {
        _setUpPeriphery();
        registry.queue(registry.SET_GUARDIAN(), abi.encode(guardian));
        factory = new MockOwnedRootFactory(IHookrOwnedRoots(address(registry)));
        registry.queue(registry.SET_ROOT_FACTORY(), abi.encode(address(factory), address(factory).codehash, true));
        executor = new MockIdleExecutor();
        registry.queue(
            OPEN_LANE, abi.encode(address(root), address(executor), address(executor).codehash, LANE_GAS, LANE_SHARE)
        );
        for (uint256 i; i < 5; ++i) {
            advisories[i] = new OwnedModuleStub();
            gates[i] = new OwnedModuleStub();
            registry.queue(registry.ADMIT(), abi.encode(address(root), _advisory(address(advisories[i]))));
            registry.queue(registry.ADMIT(), abi.encode(address(root), _gate(address(gates[i]))));
        }
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setGuardian(guardian);
        registry.setRootFactory(address(factory), address(factory).codehash, true);
        registry.openLaneOf(address(root), address(executor), address(executor).codehash, LANE_GAS, LANE_SHARE);
        for (uint256 i; i < 5; ++i) {
            registry.admit(address(root), _advisory(address(advisories[i])));
            registry.admit(address(root), _gate(address(gates[i])));
        }
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _advisory(address implementation) internal view returns (IHookrRegistry.Admission memory) {
        return IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: implementation,
            codeHash: implementation.codehash,
            schemaHash: keccak256("test.advisory.v1"),
            caps: HookrTypes.Caps(10_000, 0, 0),
            gasLimit: 100_000,
            phaseMask: HookrTypes.BEFORE_SWAP,
            feeOnly: true,
            failOpen: false
        });
    }

    function _gate(address implementation) internal view returns (IHookrRegistry.Admission memory) {
        return IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.GATE,
            implementation: implementation,
            codeHash: implementation.codehash,
            schemaHash: GATE_SCHEMA,
            caps: HookrTypes.Caps(0, 0, 0),
            gasLimit: 100_000,
            phaseMask: 0,
            feeOnly: false,
            failOpen: false
        });
    }

    /// @dev The template's RULES terms for `companion`.
    function _rules(address companion) internal view returns (IHookrRegistry.Admission memory a) {
        a = registry.admission(address(root), address(rules));
        a.implementation = companion;
        a.codeHash = companion.codehash;
    }

    /// @dev An unmodified HookrRoot at a fresh CREATE2 address carrying the root's permission flags.
    function _deployRoot() internal returns (HookrRoot r) {
        bytes memory args = abi.encode(manager, registry, address(router), address(quoter), address(0));
        bytes32 initHash = keccak256(abi.encodePacked(type(HookrRoot).creationCode, args));
        for (uint256 i = nextSalt;; ++i) {
            address predicted = vm.computeCreate2Address(bytes32(i), initHash, address(this));
            if (uint160(predicted) & 0x3fff == 0x2acc) {
                nextSalt = i + 1;
                return new HookrRoot{salt: bytes32(i)}(manager, registry, address(router), address(quoter), address(0));
            }
        }
    }

    /// @dev A companion Rules module for `ownedRoot`, with the template Rules' protocol recipient and floor.
    function _companion(address ownedRoot) internal returns (HookrRules) {
        return new HookrRules(manager, registry, protocol, ownedRoot, 0);
    }

    function _copies(uint256 advisoryCount, uint256 gateCount) internal view returns (address[] memory list) {
        list = new address[](advisoryCount + gateCount);
        for (uint256 i; i < advisoryCount; ++i) {
            list[i] = address(advisories[i]);
        }
        for (uint256 i; i < gateCount; ++i) {
            list[advisoryCount + i] = address(gates[i]);
        }
    }

    function _register(address[] memory copies, bool ownerOnly) internal returns (HookrRoot r, HookrRules companion) {
        r = _deployRoot();
        companion = _companion(address(r));
        factory.register(
            address(r), address(root), address(rules), _rules(address(companion)), copies, brand, ownerOnly
        );
    }

    function _expectRefused(
        address r,
        address template,
        address templateRules,
        IHookrRegistry.Admission memory a,
        address[] memory copies,
        bytes memory reason
    ) internal {
        vm.expectRevert(reason);
        factory.register(r, template, templateRules, a, copies, brand, false);
    }

    function _invalidRoot() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IHookrRegistry.InvalidRoot.selector);
    }

    function _invalidAdmission() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IHookrRegistry.InvalidAdmission.selector);
    }

    function _launchOn(address r, address companion, int24 spacing) internal returns (PoolKey memory key) {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(0)));
        members[0].config.rules = companion;
        members[0].tickSpacing = spacing;
        (bytes32 family,) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), r, members, vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
    }

    /// @dev Buys the subject with 1e18 of native ETH on `key`, a native-quote pool of the root in its hooks field.
    function _buy(PoolKey memory key) internal {
        Currency subject = HookrRoot(address(key.hooks)).poolConfig(key.toId()).subject;
        bool inputIs0 = Currency.unwrap(key.currency0) != Currency.unwrap(subject);
        IHookrRouter.Swap memory p = IHookrRouter.Swap(
            key, inputIs0, -int128(1e18), 1, inputIs0 ? MIN_PRICE : MAX_PRICE, trader, vm.getBlockTimestamp()
        );
        vm.prank(trader);
        (uint256 input, uint256 output) = router.swap{value: 1e18}(p, address(0), new uint256[](0));
        assertGt(input, 0);
        assertGt(output, 0);
    }

    function _assertNoLane(address r) internal view {
        (address laneExecutor, bytes32 codeHash, uint32 gasCap, uint16 share) = registry.activeLaneOf(r);
        assertEq(laneExecutor, address(0), "no executor");
        assertEq(codeHash, bytes32(0), "no codehash");
        assertEq(gasCap, 0, "no gas");
        assertEq(share, 0, "no share");
    }

    // ───────────────────────────── registration ─────────────────────────────

    /// The root is registered open and frozen with its companion's RULES admission, the named copies with the
    /// template's terms, and the template's lane with its switch off; every write is logged as the timelocked paths log
    /// it, the braked lane as a brake by the factory.
    function test_registerFreezesTheRootWithItsRulesCopiesAndBrakedLane() public {
        HookrRoot r = _deployRoot();
        HookrRules companion = _companion(address(r));
        address[] memory copies = _copies(2, 1);
        IHookrRegistry.Admission memory a = _rules(address(companion));

        vm.recordLogs();
        factory.register(address(r), address(root), address(rules), a, copies, brand, false);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32[8] memory topics = [
            IHookrRegistry.RootRegistered.selector,
            IHookrRegistry.ModuleAdmitted.selector,
            IHookrRegistry.ModuleAdmitted.selector,
            IHookrRegistry.ModuleAdmitted.selector,
            IHookrRegistry.ModuleAdmitted.selector,
            IHookrLanes.ExecutorLaneSet.selector,
            IHookrRegistry.RootSealed.selector,
            IHookrOwnedRoots.OwnedRootRegistered.selector
        ];
        assertEq(logs.length, topics.length);
        for (uint256 i; i < topics.length; ++i) {
            assertEq(logs[i].topics[0], topics[i]);
            assertEq(logs[i].emitter, address(registry));
        }
        // ExecutorLaneSet(root, executor, false, gasCap, factory): the copy is braked by the registering factory.
        assertEq(address(uint160(uint256(logs[5].topics[1]))), address(r));
        assertEq(address(uint160(uint256(logs[5].topics[2]))), address(executor));
        assertEq(address(uint160(uint256(logs[5].topics[3]))), address(factory));
        assertEq(logs[5].data, abi.encode(false, LANE_GAS));
        assertEq(address(uint160(uint256(logs[7].topics[1]))), address(r));
        assertEq(address(uint160(uint256(logs[7].topics[2]))), address(factory));
        assertEq(address(uint160(uint256(logs[7].topics[3]))), address(root));
        assertEq(logs[7].data, abi.encode(address(companion)));

        assertTrue(registry.isRoot(address(r)));
        assertTrue(registry.rootOpen(address(r)));
        assertTrue(registry.rootFrozen(address(r)));
        assertFalse(registry.rootClosed(address(r)));
        assertTrue(registry.isOwnedRoot(address(r)));
        assertEq(registry.ownedRootTemplate(address(r)), address(root));
        assertEq(registry.ownedRegistrarForRoot(address(r)), address(factory));
        assertEq(registry.rootFactoryOf(address(r)), address(0));
        (address recorded, bool verified) = registry.rootStatus(address(r));
        assertEq(recorded, address(0));
        assertTrue(verified);

        assertEq(abi.encode(registry.admission(address(r), address(companion))), abi.encode(a));
        for (uint256 i; i < copies.length; ++i) {
            IHookrRegistry.Admission memory copied = registry.admission(address(r), copies[i]);
            IHookrRegistry.Admission memory original = registry.admission(address(root), copies[i]);
            assertEq(abi.encode(copied), abi.encode(original));
        }
        assertEq(registry.admission(address(r), address(advisories[2])).implementation, address(0));

        // The lane is copied braked: no active lane, the executor's switch off at the template's cap.
        _assertNoLane(address(r));
        (bool on, uint32 cap) = registry.executorLane(address(r), address(executor));
        assertFalse(on);
        assertEq(cap, LANE_GAS);

        // Nothing on the template changed.
        assertFalse(registry.isOwnedRoot(address(root)));
        assertFalse(registry.rootFrozen(address(root)));
        (address templateExecutor,,,) = registry.activeLaneOf(address(root));
        assertEq(templateExecutor, address(executor));
    }

    /// Pools open on an owned root with its companion Rules, without a lane while the copy is braked, and trade
    /// through the router; the template's Rules answer to the template only.
    function test_poolsOpenAndTradeOnAnOwnedRoot() public {
        (HookrRoot r, HookrRules companion) = _register(new address[](0), false);
        PoolKey memory key = _launchOn(address(r), address(companion), 60);
        assertEq(address(key.hooks), address(r));
        _buy(key);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(0)));
        members[0].tickSpacing = 120;
        IHookrLauncher.Token memory token = IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0));
        uint256 deadline = vm.getBlockTimestamp();
        vm.expectRevert(abi.encodeWithSelector(IHookrRootEvents.InvalidModule.selector, rules));
        launcher.launch{value: 1e24}(token, address(r), members, deadline);
    }

    /// Only an active root factory at its pinned runtime codehash registers, and never while new markets are paused.
    function test_onlyAnActivePinnedFactoryRegisters() public {
        HookrRoot r = _deployRoot();
        HookrRules companion = _companion(address(r));
        IHookrRegistry.Admission memory a = _rules(address(companion));
        address[] memory none = new address[](0);

        vm.prank(stranger);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.registerOwnedRoot(address(r), address(root), address(rules), a, none);

        MockOwnedRootFactory idle = new MockOwnedRootFactory(IHookrOwnedRoots(address(registry)));
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        idle.register(address(r), address(root), address(rules), a, none, brand, false);

        vm.prank(guardian);
        registry.pauseNewMarkets();
        _expectRefused(
            address(r),
            address(root),
            address(rules),
            a,
            none,
            abi.encodeWithSelector(IHookrRegistry.MarketsPaused.selector)
        );
        registry.queue(registry.RESUME_NEW_MARKETS(), "");
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.resumeNewMarkets();

        vm.prank(guardian);
        registry.deactivateRootFactory(address(factory));
        _expectRefused(
            address(r),
            address(root),
            address(rules),
            a,
            none,
            abi.encodeWithSelector(IHookrRegistry.Unauthorized.selector)
        );

        // A factory whose code drifted from its pin is refused like an inactive one.
        registry.queue(registry.SET_ROOT_FACTORY(), abi.encode(address(factory), address(factory).codehash, true));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setRootFactory(address(factory), address(factory).codehash, true);
        bytes memory original = address(factory).code;
        vm.etch(address(factory), abi.encodePacked(original, hex"00"));
        _expectRefused(
            address(r),
            address(root),
            address(rules),
            a,
            none,
            abi.encodeWithSelector(IHookrRegistry.Unauthorized.selector)
        );
        vm.etch(address(factory), original);
        assertFalse(registry.isRoot(address(r)));
        factory.register(address(r), address(root), address(rules), a, none, brand, false);
        assertTrue(registry.isOwnedRoot(address(r)));
    }

    /// The root must be unregistered, unrecorded code that reports this registry, its PoolManager, the template's
    /// router, quoter and curated router and flags equal to its address bits and to the template's, with a lane module
    /// that holds what it reports.
    function test_rootChecks() public {
        address[] memory none = new address[](0);
        HookrRules companion = _companion(address(root));
        IHookrRegistry.Admission memory a = _rules(address(companion));

        // Registered already: the template itself.
        _expectRefused(address(root), address(root), address(rules), a, none, _invalidRoot());
        // No code.
        address bare = address(uint160(0xBA4E0000) << 16 | 0x2acc);
        _expectRefused(
            bare,
            address(root),
            address(rules),
            a,
            none,
            abi.encodeWithSelector(IHookrRegistry.NotAContract.selector, bare)
        );

        // A root that reports each wiring right but one, at an address with the template's flags.
        OwnedRootStub stub = new OwnedRootStub();
        address fake = address(uint160(0xFA4E0000) << 16 | 0x2acc);
        address[5] memory wiring = [address(registry), address(manager), address(router), address(quoter), address(0)];
        for (uint256 i; i < 6; ++i) {
            // A fresh copy: a memory array assignment would alias `wiring`.
            address[5] memory w = [wiring[0], wiring[1], wiring[2], wiring[3], wiring[4]];
            uint160 flags = 0x2acc;
            if (i < 5) w[i] = address(0xBAD);
            else flags = 0x2acd;
            stub.set(w, flags);
            vm.etch(fake, address(stub).code);
            vm.copyStorage(address(stub), fake);
            _expectRefused(fake, address(root), address(rules), a, none, _invalidRoot());
        }
        // Every report right: refused only on the companion, which answers to another root.
        stub.set(wiring, 0x2acc);
        vm.etch(fake, address(stub).code);
        vm.copyStorage(address(stub), fake);
        _expectRefused(fake, address(root), address(rules), a, none, _invalidAdmission());
        // A lane module that does not hold the codehash it reports.
        stub.setModule(address(executor), keccak256("other"));
        vm.copyStorage(address(stub), fake);
        HookrRules fakeCompanion = _companion(fake);
        _expectRefused(
            fake,
            address(root),
            address(rules),
            _rules(address(fakeCompanion)),
            none,
            abi.encodeWithSelector(IHookrRegistry.CodeHashMismatch.selector, address(executor))
        );

        // An address whose flags are not the template's, whatever it reports.
        address otherFlags = address(uint160(0xFA4E0000) << 16 | 0x2acd);
        stub.setModule(address(0), bytes32(0));
        stub.set(wiring, 0x2acd);
        vm.etch(otherFlags, address(stub).code);
        vm.copyStorage(address(stub), otherFlags);
        _expectRefused(
            otherFlags, address(root), address(rules), _rules(address(_companion(otherFlags))), none, _invalidRoot()
        );
    }

    /// A hook recorded as an external hook is never registered as an owned root.
    function test_recordedHookIsRefused() public {
        HookrRoot r = _deployRoot();
        HookrRules companion = _companion(address(r));
        bytes32 record = keccak256("RECORD_EXTERNAL_HOOK");
        IHookrExternalHooks.HookKind listed = IHookrExternalHooks.HookKind.LISTED;
        registry.queue(record, abi.encode(address(r), listed, address(r).codehash, address(0)));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setExternalHook(address(r), listed, address(r).codehash, address(0));
        _expectRefused(
            address(r), address(root), address(rules), _rules(address(companion)), new address[](0), _invalidRoot()
        );
        registry.dropSingleExternalHookRecordNow(address(r));
        factory.register(
            address(r), address(root), address(rules), _rules(address(companion)), new address[](0), brand, false
        );
        assertTrue(registry.isOwnedRoot(address(r)));
    }

    /// The template is an active, unclosed root registered by REGISTER_ROOT: not unregistered, retired, closed, a pair
    /// root or an owned root. A frozen template serves.
    function test_templateChecks() public {
        address[] memory none = new address[](0);
        HookrRoot r = _deployRoot();
        HookrRules companion = _companion(address(r));
        IHookrRegistry.Admission memory a = _rules(address(companion));

        _expectRefused(address(r), address(0xDEAD), address(rules), a, none, _invalidRoot());

        // A pair root.
        OwnedPairFactoryStub pairFactory = new OwnedPairFactoryStub();
        registry.queue(
            registry.SET_ROOT_FACTORY(), abi.encode(address(pairFactory), address(pairFactory).codehash, true)
        );
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setRootFactory(address(pairFactory), address(pairFactory).codehash, true);
        address pairRoot = address(new OwnedPairRootStub(address(registry)));
        pairFactory.register(registry, pairRoot);
        _expectRefused(address(r), pairRoot, address(rules), a, none, _invalidRoot());

        // An owned root.
        (HookrRoot owned,) = _register(none, false);
        _expectRefused(address(r), address(owned), address(rules), a, none, _invalidRoot());

        // A closed template, then a retired one.
        vm.prank(guardian);
        registry.closeRoot(address(root));
        _expectRefused(address(r), address(root), address(rules), a, none, _invalidRoot());
        registry.queue(registry.REOPEN_ROOT(), abi.encode(address(root)));
        registry.queue(registry.RETIRE_ROOT(), abi.encode(address(root)));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.reopenRoot(address(root));
        // A frozen template still serves as one: freezing seals its own admissions only.
        registry.freezeRoot(address(root));
        factory.register(address(r), address(root), address(rules), a, none, brand, false);
        HookrRoot later = _deployRoot();
        HookrRules laterCompanion = _companion(address(later));
        registry.retireRoot(address(root));
        _expectRefused(
            address(later), address(root), address(rules), _rules(address(laterCompanion)), none, _invalidRoot()
        );
    }

    /// The companion's admission is the template's RULES admission with its own implementation and caps no wider, for a
    /// companion that answers to the root, reports this registry and keeps the template Rules' protocol recipient and
    /// floor; the template's RULES admission must be live.
    function test_rulesBounds() public {
        address[] memory none = new address[](0);
        HookrRoot r = _deployRoot();
        HookrRules companion = _companion(address(r));
        IHookrRegistry.Admission memory good = _rules(address(companion));
        IHookrRegistry.Admission memory a;

        a = _rules(address(companion));
        a.schemaHash = keccak256("other");
        _expectRefused(address(r), address(root), address(rules), a, none, _invalidAdmission());
        a = _rules(address(companion));
        a.gasLimit = 1_999_999;
        _expectRefused(address(r), address(root), address(rules), a, none, _invalidAdmission());
        a = _rules(address(companion));
        a.phaseMask = 1;
        _expectRefused(address(r), address(root), address(rules), a, none, _invalidAdmission());
        a = _rules(address(companion));
        a.feeOnly = true;
        _expectRefused(address(r), address(root), address(rules), a, none, _invalidAdmission());
        a = _rules(address(companion));
        a.failOpen = true;
        _expectRefused(address(r), address(root), address(rules), a, none, _invalidAdmission());
        a = _rules(address(companion));
        a.kind = IHookrRegistry.Kind.ADVISORY;
        _expectRefused(address(r), address(root), address(rules), a, none, _invalidAdmission());
        a = _rules(address(companion));
        a.caps.maxLpFeePips += 1;
        _expectRefused(address(r), address(root), address(rules), a, none, _invalidAdmission());
        a = _rules(address(companion));
        a.caps.maxQuoteTakePips += 1;
        _expectRefused(address(r), address(root), address(rules), a, none, _invalidAdmission());
        a = _rules(address(companion));
        a.caps.maxSubjectTakeBps += 1;
        _expectRefused(address(r), address(root), address(rules), a, none, _invalidAdmission());
        a = _rules(address(companion));
        a.codeHash = keccak256("other code");
        _expectRefused(
            address(r),
            address(root),
            address(rules),
            a,
            none,
            abi.encodeWithSelector(IHookrRegistry.CodeHashMismatch.selector, address(companion))
        );
        a = _rules(address(0xC0FFEE));
        _expectRefused(
            address(r),
            address(root),
            address(rules),
            a,
            none,
            abi.encodeWithSelector(IHookrRegistry.NotAContract.selector, address(0xC0FFEE))
        );

        // A companion for another root, with another floor, or paying another recipient.
        HookrRules stray = _companion(address(root));
        _expectRefused(address(r), address(root), address(rules), _rules(address(stray)), none, _invalidAdmission());
        HookrRules floor = new HookrRules(manager, registry, protocol, address(r), 2_000);
        _expectRefused(address(r), address(root), address(rules), _rules(address(floor)), none, _invalidAdmission());
        HookrRules payee = new HookrRules(manager, registry, address(0xFEE), address(r), 0);
        _expectRefused(address(r), address(root), address(rules), _rules(address(payee)), none, _invalidAdmission());

        // The template's Rules must hold a live RULES admission on it.
        _expectRefused(address(r), address(root), address(advisories[0]), good, none, _invalidAdmission());
        _expectRefused(address(r), address(root), address(0xBEEF), good, none, _invalidAdmission());

        // Narrower caps register.
        a = _rules(address(companion));
        a.caps = HookrTypes.Caps(300_000, 100_000, 500);
        factory.register(address(r), address(root), address(rules), a, none, brand, false);
        assertEq(registry.admission(address(r), address(companion)).caps.maxLpFeePips, 300_000);
    }

    /// A revoked template Rules admission, or one its bond no longer covers, refuses registration.
    function test_templateRulesMustBeLive() public {
        address[] memory none = new address[](0);
        HookrRoot r = _deployRoot();
        HookrRules companion = _companion(address(r));
        IHookrRegistry.Admission memory a = _rules(address(companion));

        MockModuleBond bond = new MockModuleBond();
        bond.setCovered(address(root), address(rules), true);
        registry.queue(SET_ADMISSION_BOND, abi.encode(address(root), address(rules), address(bond)));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.pinModuleBondFor(address(root), address(rules), address(bond));
        bond.setCovered(address(root), address(rules), false);
        _expectRefused(address(r), address(root), address(rules), a, none, _invalidAdmission());
        bond.setCovered(address(root), address(rules), true);

        registry.revokeModuleAdmission(address(root), address(rules));
        _expectRefused(address(r), address(root), address(rules), a, none, _invalidAdmission());
    }

    // ───────────────────────────── copies ─────────────────────────────

    /// At most four ADVISORY and four GATE admissions, each live on the template and named once; never a RULES one. A
    /// bonded copy keeps its bond, asked for the owned root's scope, and registers only while that bond covers it there.
    function test_copies() public {
        HookrRoot r = _deployRoot();
        HookrRules companion = _companion(address(r));
        IHookrRegistry.Admission memory a = _rules(address(companion));

        _expectRefused(address(r), address(root), address(rules), a, _copies(5, 0), _invalidAdmission());
        _expectRefused(address(r), address(root), address(rules), a, _copies(0, 5), _invalidAdmission());
        address[] memory list = new address[](1);
        list[0] = address(rules);
        _expectRefused(address(r), address(root), address(rules), a, list, _invalidAdmission());
        list[0] = address(0xC0DE);
        _expectRefused(address(r), address(root), address(rules), a, list, _invalidAdmission());
        list[0] = address(companion);
        _expectRefused(address(r), address(root), address(rules), a, list, _invalidAdmission());
        list = new address[](2);
        (list[0], list[1]) = (address(gates[0]), address(gates[0]));
        _expectRefused(
            address(r),
            address(root),
            address(rules),
            a,
            list,
            abi.encodeWithSelector(IHookrRegistry.AlreadyAdmitted.selector)
        );

        // A revoked, a drifted and an unbonded template admission is not live.
        vm.prank(guardian);
        registry.revokeModuleAdmission(address(root), address(advisories[0]));
        list = new address[](1);
        list[0] = address(advisories[0]);
        _expectRefused(address(r), address(root), address(rules), a, list, _invalidAdmission());
        bytes memory original = address(advisories[1]).code;
        vm.etch(address(advisories[1]), address(new OwnedModuleStubV2()).code);
        list[0] = address(advisories[1]);
        _expectRefused(address(r), address(root), address(rules), a, list, _invalidAdmission());
        vm.etch(address(advisories[1]), original);
        MockModuleBond bond = new MockModuleBond();
        bond.setCovered(address(root), address(advisories[1]), true);
        registry.queue(SET_ADMISSION_BOND, abi.encode(address(root), address(advisories[1]), address(bond)));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.pinModuleBondFor(address(root), address(advisories[1]), address(bond));
        bond.setCovered(address(root), address(advisories[1]), false);
        _expectRefused(address(r), address(root), address(rules), a, list, _invalidAdmission());

        // A bond that covers on the template but not on the owned root refuses the copy.
        bond.setCovered(address(root), address(advisories[1]), true);
        _expectRefused(
            address(r),
            address(root),
            address(rules),
            a,
            list,
            abi.encodeWithSelector(IHookrAdmissions.BondNotCovering.selector, address(bond))
        );

        // Four of each register; the bonded copy keeps its bond, asked for the owned root.
        bond.setCovered(address(r), address(advisories[1]), true);
        address[] memory eight = new address[](8);
        for (uint256 i; i < 4; ++i) {
            eight[i] = address(advisories[i + 1]);
            eight[4 + i] = address(gates[i]);
        }
        factory.register(address(r), address(root), address(rules), a, eight, brand, false);
        (address bondRef, bool covering) = registry.findBondForAdmission(address(r), address(advisories[1]));
        assertEq(bondRef, address(bond));
        assertTrue(covering);
        assertEq(registry.admission(address(r), address(advisories[1])).implementation, address(advisories[1]));
        bond.setCovered(address(r), address(advisories[1]), false);
        assertEq(registry.admission(address(r), address(advisories[1])).implementation, address(0));
        assertEq(registry.admission(address(root), address(advisories[1])).implementation, address(advisories[1]));
        assertEq(uint8(registry.admission(address(r), address(gates[3])).kind), uint8(IHookrRegistry.Kind.GATE));
        (bondRef,) = registry.findBondForAdmission(address(r), address(gates[3]));
        assertEq(bondRef, address(0));
    }

    // ───────────────────────────── the lane ─────────────────────────────

    /// Nothing is copied unless the template's lane is open: not while the executor is off, not when its code drifted
    /// and not after `closeLaneOf`; the owned root then has no switch to turn on.
    function test_laneIsCopiedOnlyWhileTheTemplatesIsOpen() public {
        address[] memory none = new address[](0);
        vm.prank(guardian);
        registry.stopExecutorLane(address(root), address(executor));
        (HookrRoot off,) = _register(none, false);
        vm.warp(vm.getBlockTimestamp() + 1);
        _assertNoLane(address(off));
        (bool on, uint32 cap) = registry.executorLane(address(off), address(executor));
        assertFalse(on);
        assertEq(cap, 0);

        bytes memory laneOn = abi.encode(address(root), address(executor), LANE_GAS);
        registry.queue(LANE_ON, laneOn);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.startExecutorLaneAt(address(root), address(executor), LANE_GAS);
        bytes memory original = address(executor).code;
        vm.etch(address(executor), address(new OwnedModuleStubV2()).code);
        (HookrRoot drifted,) = _register(none, false);
        (, cap) = registry.executorLane(address(drifted), address(executor));
        assertEq(cap, 0);
        vm.etch(address(executor), original);

        vm.prank(guardian);
        registry.closeLaneOf(address(root));
        (HookrRoot closed,) = _register(none, false);
        (, cap) = registry.executorLane(address(closed), address(executor));
        assertEq(cap, 0);
        _assertNoLane(address(closed));

        // With nothing copied there is no switch to turn on: a LANE_ON for the owned root is refused.
        vm.expectRevert(IHookrRegistry.InvalidLane.selector);
        registry.queue(LANE_ON, abi.encode(address(closed), address(executor), LANE_GAS));
    }

    /// The copied lane starts braked: a switch-on can be queued only once the root is registered, one queued in the
    /// registration's own second cannot execute, and one queued after it executes, after which the owned root's new
    /// pools freeze the template's executor at its pinned codehash and partner share.
    function test_copiedLaneStartsOnlyThroughALaterTimelock() public {
        HookrRoot r = _deployRoot();
        HookrRules companion = _companion(address(r));
        bytes memory laneOn = abi.encode(address(r), address(executor), LANE_GAS);
        bytes memory openLane =
            abi.encode(address(r), address(executor), address(executor).codehash, LANE_GAS, LANE_SHARE);

        // Before registration neither can be queued.
        vm.expectRevert(IHookrRegistry.InvalidRoot.selector);
        registry.queue(LANE_ON, laneOn);
        vm.expectRevert(IHookrRegistry.InvalidRoot.selector);
        registry.queue(OPEN_LANE, openLane);

        factory.register(
            address(r), address(root), address(rules), _rules(address(companion)), new address[](0), brand, false
        );
        _assertNoLane(address(r));

        // Queued in the registration's own second: the registration is the switch's last brake.
        bytes32 early = registry.queue(LANE_ON, laneOn);
        bytes32 earlyOpen = registry.queue(OPEN_LANE, openLane);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.QueuedBeforeBrake.selector, early));
        registry.startExecutorLaneAt(address(r), address(executor), LANE_GAS);
        vm.expectRevert(abi.encodeWithSelector(IHookrRegistry.QueuedBeforeBrake.selector, earlyOpen));
        registry.openLaneOf(address(r), address(executor), address(executor).codehash, LANE_GAS, LANE_SHARE);
        _assertNoLane(address(r));

        // Queued after the registration: it executes, and the owned root's lane is the template's.
        registry.cancel(early);
        registry.queue(LANE_ON, laneOn);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        vm.expectEmit(true, true, true, true, address(registry));
        emit IHookrLanes.ExecutorLaneSet(address(r), address(executor), true, LANE_GAS, address(this));
        registry.startExecutorLaneAt(address(r), address(executor), LANE_GAS);
        (address laneExecutor, bytes32 codeHash, uint32 gasCap, uint16 share) = registry.activeLaneOf(address(r));
        assertEq(laneExecutor, address(executor));
        assertEq(codeHash, address(executor).codehash);
        assertEq(gasCap, LANE_GAS);
        assertEq(share, LANE_SHARE);
    }

    /// A timelocked OPEN_LANE gives a frozen owned root a lane, here a different executor; its admissions stay frozen,
    /// and a frozen root that is not owned still refuses a lane.
    function test_openLaneOnAFrozenOwnedRoot() public {
        (HookrRoot r,) = _register(new address[](0), false);
        MockIdleExecutor next = new MockIdleExecutor();
        bytes memory args = abi.encode(address(r), address(next), address(next).codehash, LANE_GAS, LANE_SHARE);
        registry.queue(OPEN_LANE, args);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.openLaneOf(address(r), address(next), address(next).codehash, LANE_GAS, LANE_SHARE);
        (address laneExecutor,,,) = registry.activeLaneOf(address(r));
        assertEq(laneExecutor, address(next));
        (bool on,) = registry.executorLane(address(r), address(executor));
        assertFalse(on);

        registry.freezeRoot(address(root));
        bytes32 openLane = OPEN_LANE;
        vm.expectRevert(IHookrRegistry.RootFrozen.selector);
        registry.queue(openLane, abi.encode(address(root), address(next), address(next).codehash, LANE_GAS, LANE_SHARE));
        OwnedModuleStub late = new OwnedModuleStub();
        bytes32 admit = registry.ADMIT();
        vm.expectRevert(IHookrRegistry.RootFrozen.selector);
        registry.queue(admit, abi.encode(address(r), _advisory(address(late))));
    }

    // ───────────────────────────── brakes ─────────────────────────────

    /// Every brake reaches an owned root; the module brake is the owner's alone there, since the root is frozen. The
    /// open pool keeps trading.
    function test_brakesReachOwnedRoots() public {
        (HookrRoot r, HookrRules companion) = _register(_copies(1, 0), false);
        PoolKey memory key = _launchOn(address(r), address(companion), 60);

        vm.prank(guardian);
        registry.closeRoot(address(r));
        assertFalse(registry.rootOpen(address(r)));
        assertFalse(registry.rootOpenFor(address(r), brand));

        vm.prank(guardian);
        vm.expectRevert(IHookrRegistry.Unauthorized.selector);
        registry.revokeModuleAdmission(address(r), address(advisories[0]));
        registry.revokeModuleAdmission(address(r), address(advisories[0]));
        assertTrue(registry.isRevokedAdmission(address(r), address(advisories[0])));
        assertEq(registry.admission(address(root), address(advisories[0])).implementation, address(advisories[0]));

        vm.prank(guardian);
        registry.tuneExecutorLane(address(r), address(executor), 100_000);
        (bool on, uint32 cap) = registry.executorLane(address(r), address(executor));
        assertFalse(on);
        assertEq(cap, 100_000);
        vm.prank(guardian);
        registry.stopExecutorLane(address(r), address(executor));
        vm.prank(guardian);
        registry.closeLaneOf(address(r));
        _assertNoLane(address(r));

        registry.queue(registry.RETIRE_ROOT(), abi.encode(address(r)));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.retireRoot(address(r));
        assertTrue(registry.isRoot(address(r)));
        assertTrue(registry.isOwnedRoot(address(r)));
        assertFalse(registry.rootOpenFor(address(r), brand));

        _buy(key);
    }

    // ───────────────────────────── rootOpenFor ─────────────────────────────

    /// For a root that is not owned, rootOpenFor is rootOpen whoever asks.
    function test_rootOpenForEqualsRootOpenOnRootsThatAreNotOwned() public {
        address[3] memory askers = [brand, stranger, address(0)];
        for (uint256 i; i < askers.length; ++i) {
            assertEq(registry.rootOpenFor(address(root), askers[i]), registry.rootOpen(address(root)));
            assertEq(registry.rootOpenFor(address(0xDEAD), askers[i]), registry.rootOpen(address(0xDEAD)));
        }
        assertTrue(registry.rootOpenFor(address(root), stranger));
        vm.prank(guardian);
        registry.pauseNewMarkets();
        assertEq(registry.rootOpenFor(address(root), brand), registry.rootOpen(address(root)));
        assertFalse(registry.rootOpenFor(address(root), brand));
        registry.queue(registry.RESUME_NEW_MARKETS(), "");
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.resumeNewMarkets();
        vm.prank(guardian);
        registry.closeRoot(address(root));
        assertEq(registry.rootOpenFor(address(root), brand), registry.rootOpen(address(root)));
        assertFalse(registry.rootOpenFor(address(root), brand));
    }

    /// An owned root asks its factory: public roots open for anyone, owner-only ones for their owner, paused ones for
    /// nobody, and the registry's brakes still close them.
    function test_rootOpenForAsksTheOwnedRootsFactory() public {
        (HookrRoot open,) = _register(new address[](0), false);
        (HookrRoot owned,) = _register(new address[](0), true);
        assertTrue(registry.rootOpenFor(address(open), stranger));
        assertTrue(registry.rootOpenFor(address(owned), brand));
        assertFalse(registry.rootOpenFor(address(owned), stranger));
        assertTrue(registry.rootOpen(address(owned)));

        factory.setPaused(address(open), true);
        assertFalse(registry.rootOpenFor(address(open), brand));
        factory.setPaused(address(open), false);

        // A deactivated factory is still asked: deactivation stops registrations only.
        vm.prank(guardian);
        registry.deactivateRootFactory(address(factory));
        assertTrue(registry.rootOpenFor(address(open), stranger));
        assertFalse(registry.rootOpenFor(address(owned), stranger));

        vm.prank(guardian);
        registry.pauseNewMarkets();
        assertFalse(registry.rootOpenFor(address(open), stranger));
        assertFalse(registry.rootOpenFor(address(owned), brand));
    }

    /// A factory answer that reverts, is short, long or dirty, or burns the probe's gas reads as closed.
    function test_badFactoryAnswersReadClosed() public {
        (HookrRoot r,) = _register(new address[](0), false);
        assertTrue(registry.rootOpenFor(address(r), stranger));
        MockOwnedRootFactory.Answer[5] memory bad = [
            MockOwnedRootFactory.Answer.REVERT,
            MockOwnedRootFactory.Answer.SHORT,
            MockOwnedRootFactory.Answer.LONG,
            MockOwnedRootFactory.Answer.DIRTY,
            MockOwnedRootFactory.Answer.BURN
        ];
        for (uint256 i; i < bad.length; ++i) {
            factory.setAnswer(bad[i]);
            assertFalse(registry.rootOpenFor(address(r), stranger));
            assertTrue(registry.rootOpen(address(r)));
        }
        factory.setAnswer(MockOwnedRootFactory.Answer.POLICY);
        assertTrue(registry.rootOpenFor(address(r), stranger));
    }

    // ───────────────────────────── pair roots ─────────────────────────────

    /// Pair-root factories register as before; a pair root is never owned.
    function test_pairRootFactoriesAreUnaffected() public {
        OwnedPairFactoryStub pairFactory = new OwnedPairFactoryStub();
        registry.queue(
            registry.SET_ROOT_FACTORY(), abi.encode(address(pairFactory), address(pairFactory).codehash, true)
        );
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.setRootFactory(address(pairFactory), address(pairFactory).codehash, true);
        address pairRoot = address(new OwnedPairRootStub(address(registry)));
        pairFactory.register(registry, pairRoot);
        assertTrue(registry.isRoot(pairRoot));
        assertEq(registry.rootFactoryOf(pairRoot), address(pairFactory));
        assertFalse(registry.isOwnedRoot(pairRoot));
        assertEq(registry.ownedRegistrarForRoot(pairRoot), address(0));
        assertEq(registry.ownedRootTemplate(pairRoot), address(0));
        assertTrue(registry.rootOpenFor(pairRoot, stranger));
        assertEq(registry.rootOpenFor(pairRoot, stranger), registry.rootOpen(pairRoot));
    }

    // ───────────────────────────── dispatch ─────────────────────────────

    /// The owned-root entry points keep the names the owner's decisions and the launcher and treasury steps use
    /// (`rootOpenFor`, `isOwnedRoot`, `registerOwnedRoot`, `ownedRootTemplate`), pinned here; the factory read the
    /// treasury asks sorts after every on-chain registry read.
    function test_dispatch_ownedRootSelectors() public pure {
        assertEq(HookrRegistry.rootOpenFor.selector, bytes4(0x7ec0149e));
        assertEq(HookrRegistry.isOwnedRoot.selector, bytes4(0x838f36c2));
        assertEq(HookrRegistry.registerOwnedRoot.selector, bytes4(0x8ff9dd92));
        assertEq(HookrRegistry.ownedRootTemplate.selector, bytes4(0x9f5eced8));
        assertEq(HookrRegistry.ownedRegistrarForRoot.selector, bytes4(0xffed9edd));
        bytes4[10] memory hot = [
            HookrRegistry.isRoot.selector,
            HookrRegistry.admission.selector,
            HookrRegistry.isQuote.selector,
            HookrRegistry.rootOpen.selector,
            HookrRegistry.isLauncher.selector,
            HookrRegistry.rootFactoryOf.selector,
            HookrRegistry.registerFactoryRoot.selector,
            HookrRegistry.executorLane.selector,
            HookrRegistry.activeLaneOf.selector,
            HookrRegistry.settlementCurrencies.selector
        ];
        for (uint256 i; i < hot.length; ++i) {
            assertLt(uint32(hot[i]), uint32(HookrRegistry.ownedRegistrarForRoot.selector));
        }
    }
}
