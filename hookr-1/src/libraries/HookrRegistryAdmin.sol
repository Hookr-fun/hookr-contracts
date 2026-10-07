// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IHookrRegistry} from "../interfaces/IHookrRegistry.sol";
import {IHookrAdmissions} from "../interfaces/IHookrAdmissions.sol";
import {IHookrLanes} from "../interfaces/IHookrLanes.sol";
import {IHookrExternalHooks} from "../interfaces/IHookrExternalHooks.sol";
import {IHookrOwnedRoots} from "../interfaces/IHookrOwnedRoots.sol";
import {IHookrRoot} from "../interfaces/IHookrRoot.sol";
import {HookrRegistryStorage} from "./HookrRegistryStorage.sol";
import {HookrRegistryChecks} from "./HookrRegistryChecks.sol";

/// @title HookrRegistryAdmin
/// @notice HookrRegistry's cold write paths: the timelock step that consumes a matured queued operation, the timelocked
///         writes that run after it (module admissions, admission bonds, lane openings and external-hook records), and
///         the registration of an owned root by its root factory.
/// @dev Deployed as an external (linked) library so the registry stays under the EIP-170 runtime limit: it is deployed
///      through CREATE3 after HookrRegistryChecks, which it links, and linked into the registry's bytecode before the
///      registry is deployed. The registry checks the owner before each timelocked write and reaches this library by
///      DELEGATECALL, so its functions read and write the registry's storage (HookrRegistryStorage), `msg.sender` is the
///      registry's caller (which `registerOwnedRoot` checks itself: an active root factory at its pinned codehash),
///      `address(this)` is the registry and every event is logged by the registry. Its functions write storage, so
///      solc's call guard refuses any call that is not a DELEGATECALL.
library HookrRegistryAdmin {
    /// @dev A matured operation expires this long after its `readyAt`: HookrRegistry's GRACE_PERIOD.
    uint48 internal constant GRACE_PERIOD = 14 days;
    /// @dev The most ADVISORY, and the most GATE, admissions an owned root copies from its template.
    uint256 internal constant MAX_OWNED_COPIES = 4;
    /// @dev The one-word getters registration compares: a Rules module's root, protocol recipient and protocol share
    ///      floor, and a HookrRoot's pinned router, quoter and curated router.
    bytes4 private constant TRUSTED_ROOT_SELECTOR = bytes4(keccak256("trustedRoot()"));
    bytes4 private constant PROTOCOL_RECIPIENT_SELECTOR = bytes4(keccak256("protocolRecipient()"));
    bytes4 private constant MIN_PROTOCOL_SHARE_SELECTOR = bytes4(keccak256("minProtocolShareBps()"));
    bytes4 private constant ROUTER_SELECTOR = bytes4(keccak256("router()"));
    bytes4 private constant QUOTER_SELECTOR = bytes4(keccak256("quoter()"));
    bytes4 private constant CURATED_ROUTER_SELECTOR = bytes4(keccak256("curatedRouter()"));

    /// @dev The errors and events these paths raise and log. HookrRegistry declares each with the same signature, so
    ///      they decode against the registry's ABI.
    error NotReady(bytes32 operation);
    error OperationExpired(bytes32 operation, uint48 expiredAt);
    error QueuedBeforeBrake(bytes32 operation);
    error LaneQueuedBeforeClose(bytes32 operation);
    error Unauthorized();
    error MarketsPaused();

    event OperationExecuted(bytes32 indexed operation);
    event RootRegistered(address indexed root);
    event RootSealed(address indexed root);
    event ModuleAdmitted(
        address indexed root, address indexed implementation, IHookrRegistry.Kind kind, bytes32 codeHash
    );

    /// @notice Consumes a matured queued operation: it must be queued and ready, not past its grace period, and queued
    ///         after `brakeAt`, the last brake that can pre-empt it (zero for none).
    /// @param kind The operation kind.
    /// @param arguments The operation's ABI arguments.
    /// @param brakeAt The time of the last brake that pre-empts the operation, or zero.
    /// @param delay The registry's delay.
    function consume(bytes32 kind, bytes memory arguments, uint48 brakeAt, uint48 delay) external {
        _consume(kind, arguments, brakeAt, delay);
    }

    /// @notice Executes a queued module admission (HookrRegistry.admit): checked again, consumed, recorded.
    /// @param scope The root, root factory or part scope the admission is for.
    /// @param a The admission.
    /// @param delay The registry's delay.
    function admit(address scope, IHookrRegistry.Admission calldata a, uint48 delay) external {
        HookrRegistryChecks.checkAdmission(scope, a);
        _consume(HookrRegistryChecks.ADMIT, abi.encode(scope, a), 0, delay);
        HookrRegistryStorage.state().admissions[scope][a.implementation] = a;
        emit ModuleAdmitted(scope, a.implementation, a.kind, a.codeHash);
    }

    /// @notice Executes a queued lane opening (HookrRegistry.openLaneOf): checked again, refused if it was queued at or
    ///         before the root's last lane close or the executor's last brake, consumed, then the root's lane for new
    ///         pools and the executor's switch on at `gasCap`.
    /// @param root The root whose lane opens.
    /// @param executor The lane executor.
    /// @param codeHash The executor's pinned runtime codehash.
    /// @param gasCap The gas each lane call gets.
    /// @param partnerBps The partner's share of each arb recapture.
    /// @param delay The registry's delay.
    function openLaneOf(
        address root,
        address executor,
        bytes32 codeHash,
        uint32 gasCap,
        uint16 partnerBps,
        uint48 delay
    ) external {
        HookrRegistryChecks.checkLane(root, executor, codeHash, gasCap, partnerBps);
        bytes memory arguments = abi.encode(root, executor, codeHash, gasCap, partnerBps);
        HookrRegistryStorage.State storage s = HookrRegistryStorage.state();
        HookrRegistryStorage.Lane storage l = s.lanes[root];
        HookrRegistryStorage.LaneSwitch storage w = s.laneSwitches[root][executor];
        bytes32 operation = _operationHash(HookrRegistryChecks.OPEN_LANE, arguments);
        uint256 eta = s.readyAt[operation];
        // Queued at eta - delay: an opening queued at or before the last close cannot lift it.
        if (eta != 0 && eta <= uint256(l.closedAt) + delay) revert LaneQueuedBeforeClose(operation);
        _consume(HookrRegistryChecks.OPEN_LANE, arguments, w.brakedAt, delay);
        s.lanes[root] = HookrRegistryStorage.Lane(executor, partnerBps, l.closedAt, codeHash);
        (w.on, w.gasCap) = (true, gasCap);
        emit IHookrLanes.LaneOpened(root, executor, codeHash, gasCap, partnerBps);
        emit IHookrLanes.ExecutorLaneSet(root, executor, true, gasCap, msg.sender);
    }

    /// @notice Executes a queued external-hook record (IHookrExternalHooks.setExternalHook): checked again, refused if
    ///         it was queued at or before the hook's last delist, consumed, recorded.
    /// @param hook The hook to record.
    /// @param kind What the hook is.
    /// @param codeHash The hook's runtime codehash.
    /// @param bondRef The hook's bond reference, or zero.
    /// @param delay The registry's delay.
    function setExternalHook(
        address hook,
        IHookrExternalHooks.HookKind kind,
        bytes32 codeHash,
        address bondRef,
        uint48 delay
    ) external {
        HookrRegistryChecks.checkRecord(hook, kind, codeHash, bondRef);
        HookrRegistryStorage.Records storage t = HookrRegistryStorage.records();
        _consume(
            HookrRegistryChecks.RECORD_EXTERNAL_HOOK,
            abi.encode(hook, kind, codeHash, bondRef),
            t.delistedAt[hook],
            delay
        );
        t.hooks[hook] = IHookrExternalHooks.ExternalHook(kind, bondRef, codeHash);
        emit IHookrExternalHooks.ExternalHookRecorded(hook, kind, codeHash, bondRef);
    }

    /// @notice Executes a queued admission bond (IHookrAdmissions.pinModuleBondFor): checked again, consumed, recorded.
    /// @param scope The root, root factory or part scope of the admission.
    /// @param implementation The admitted implementation.
    /// @param bondRef The bond that stands behind the admission from now on.
    /// @param delay The registry's delay.
    function pinModuleBondFor(address scope, address implementation, address bondRef, uint48 delay) external {
        HookrRegistryChecks.checkBond(scope, implementation, bondRef);
        _consume(HookrRegistryChecks.SET_ADMISSION_BOND, abi.encode(scope, implementation, bondRef), 0, delay);
        HookrRegistryStorage.bonds().bondOf[scope][implementation] = bondRef;
        emit IHookrAdmissions.AdmissionBondSet(scope, implementation, bondRef);
    }

    /// @notice Registers an owned root for the calling root factory (IHookrOwnedRoots.registerOwnedRoot): every check,
    ///         then the root, frozen, with its companion's RULES admission, the template admissions `copies` names and
    ///         the template's open lane with its switch off.
    /// @param root The root the factory deployed.
    /// @param template The registered root whose admissions and lane the owned root takes.
    /// @param templateRules The template's Rules module whose admission bounds `rules`.
    /// @param rules The owned root's RULES admission.
    /// @param copies The template's ADVISORY and GATE implementations to admit on the owned root.
    /// @param poolManager The registry's PoolManager.
    function registerOwnedRoot(
        address root,
        address template,
        address templateRules,
        IHookrRegistry.Admission calldata rules,
        address[] calldata copies,
        address poolManager
    ) external {
        HookrRegistryStorage.State storage s = HookrRegistryStorage.state();
        bytes32 pinned = s.rootFactories[msg.sender];
        if (pinned == bytes32(0) || msg.sender.codehash != pinned) revert Unauthorized();
        if (s.newMarketsPaused) revert MarketsPaused();
        _checkOwnedRoot(s, root, template, poolManager);
        _checkCompanion(s, root, template, templateRules, rules, poolManager);
        s.roots[root] = HookrRegistryStorage.RootState(true, true, true, false, address(0));
        HookrRegistryStorage.owned().roots[root] = HookrRegistryStorage.OwnedRoot(template, msg.sender);
        emit RootRegistered(root);
        s.admissions[root][rules.implementation] = rules;
        emit ModuleAdmitted(root, rules.implementation, IHookrRegistry.Kind.RULES, rules.codeHash);
        _copyAdmissions(s, root, template, copies);
        _copyLane(s, root, template);
        emit RootSealed(root);
        emit IHookrOwnedRoots.OwnedRootRegistered(root, msg.sender, template, rules.implementation);
    }

    /// @dev The template is an active, unclosed root a queued `REGISTER_ROOT` registered (neither a pair root nor an
    ///      owned root). The root holds non-delegated code, is unregistered and unrecorded, reports this registry and
    ///      `poolManager` and the template's router, quoter and curated router, declares permission flags equal to its
    ///      address bits and to the template's, and reports a lane module that holds the codehash it reports.
    function _checkOwnedRoot(HookrRegistryStorage.State storage s, address root, address template, address poolManager)
        private
        view
    {
        HookrRegistryStorage.RootState storage t = s.roots[template];
        if (
            !t.active || t.closed || t.factory != address(0)
                || HookrRegistryStorage.owned().roots[template].factory != address(0)
        ) revert HookrRegistryChecks.InvalidRoot();
        HookrRegistryChecks.requireContract(root);
        uint160 flags = uint160(root) & HookrRegistryChecks.FLAG_MASK;
        if (
            s.roots[root].registered
                || HookrRegistryStorage.records().hooks[root].kind != IHookrExternalHooks.HookKind.NONE
                || flags != uint160(template) & HookrRegistryChecks.FLAG_MASK
                || !HookrRegistryChecks.reports(root, IHookrRoot.poolManager.selector, uint160(poolManager))
                || !HookrRegistryChecks.reports(root, IHookrRoot.registry.selector, uint160(address(this)))
                || !HookrRegistryChecks.reports(root, HookrRegistryChecks.PERMISSION_FLAGS_SELECTOR, flags)
                || !_reportsAsDoes(root, template, ROUTER_SELECTOR) || !_reportsAsDoes(root, template, QUOTER_SELECTOR)
                || !_reportsAsDoes(root, template, CURATED_ROUTER_SELECTOR)
        ) revert HookrRegistryChecks.InvalidRoot();
        HookrRegistryChecks.checkModule(root, HookrRegistryChecks.LANE_MODULE_SELECTOR);
    }

    /// @dev `templateRules` holds a live RULES admission on the template, and `rules` equals it in kind, schema, gas
    ///      limit, phases, fee-only and fail-open with caps no wider, for a companion that holds non-delegated code
    ///      with the pinned codehash, answers to `root`, reports this registry and `poolManager`, keeps the template
    ///      Rules' protocol recipient and protocol share floor, and reports its recapture module truthfully.
    function _checkCompanion(
        HookrRegistryStorage.State storage s,
        address root,
        address template,
        address templateRules,
        IHookrRegistry.Admission calldata rules,
        address poolManager
    ) private view {
        IHookrRegistry.Admission storage t = s.admissions[template][templateRules];
        if (!_live(template, templateRules, t) || t.kind != IHookrRegistry.Kind.RULES) {
            revert HookrRegistryChecks.InvalidAdmission();
        }
        if (
            rules.kind != IHookrRegistry.Kind.RULES || rules.schemaHash != t.schemaHash || rules.gasLimit != t.gasLimit
                || rules.phaseMask != t.phaseMask || rules.feeOnly != t.feeOnly || rules.failOpen != t.failOpen
                || rules.caps.maxLpFeePips > t.caps.maxLpFeePips
                || rules.caps.maxQuoteTakePips > t.caps.maxQuoteTakePips
                || rules.caps.maxSubjectTakeBps > t.caps.maxSubjectTakeBps
        ) revert HookrRegistryChecks.InvalidAdmission();
        address companion = rules.implementation;
        HookrRegistryChecks.requireContract(companion);
        if (companion.codehash != rules.codeHash) revert HookrRegistryChecks.CodeHashMismatch(companion);
        if (
            !HookrRegistryChecks.reports(companion, TRUSTED_ROOT_SELECTOR, uint160(root))
                || !HookrRegistryChecks.reports(companion, IHookrRoot.registry.selector, uint160(address(this)))
                || !HookrRegistryChecks.reports(companion, IHookrRoot.poolManager.selector, uint160(poolManager))
                || !_reportsAsDoes(companion, templateRules, PROTOCOL_RECIPIENT_SELECTOR)
                || !_reportsAsDoes(companion, templateRules, MIN_PROTOCOL_SHARE_SELECTOR)
        ) revert HookrRegistryChecks.InvalidAdmission();
        HookrRegistryChecks.checkModule(companion, HookrRegistryChecks.RECAPTURE_MODULE_SELECTOR);
    }

    /// @dev Admits on `root` each template admission `copies` names: live on the template, ADVISORY or GATE, at most
    ///      MAX_OWNED_COPIES of each, named once, with the template's terms and bond reference, a bonded one only while
    ///      its bond covers it on `root` too.
    function _copyAdmissions(
        HookrRegistryStorage.State storage s,
        address root,
        address template,
        address[] calldata copies
    ) private {
        HookrRegistryStorage.Bonds storage b = HookrRegistryStorage.bonds();
        uint256 advisories;
        uint256 gates;
        for (uint256 i; i < copies.length; ++i) {
            address implementation = copies[i];
            IHookrRegistry.Admission storage c = s.admissions[template][implementation];
            if (!_live(template, implementation, c)) revert HookrRegistryChecks.InvalidAdmission();
            if (c.kind == IHookrRegistry.Kind.ADVISORY) {
                if (++advisories > MAX_OWNED_COPIES) revert HookrRegistryChecks.InvalidAdmission();
            } else if (c.kind == IHookrRegistry.Kind.GATE) {
                if (++gates > MAX_OWNED_COPIES) revert HookrRegistryChecks.InvalidAdmission();
            } else {
                revert HookrRegistryChecks.InvalidAdmission();
            }
            if (s.admissions[root][implementation].implementation != address(0)) {
                revert HookrRegistryChecks.AlreadyAdmitted();
            }
            s.admissions[root][implementation] = c;
            address bondRef = b.bondOf[template][implementation];
            if (bondRef != address(0)) {
                if (!HookrRegistryChecks.covers(bondRef, root, implementation)) {
                    revert IHookrAdmissions.BondNotCovering(bondRef);
                }
                b.bondOf[root][implementation] = bondRef;
            }
            emit ModuleAdmitted(root, implementation, c.kind, c.codeHash);
        }
    }

    /// @dev Copies the template's open lane onto `root` braked: the lane for new pools (executor, codehash, partner
    ///      share) and the executor's gas cap, with its switch off and the registration as its last brake, so only a
    ///      `LANE_ON` or `OPEN_LANE` queued after this call starts arb recapture on `root`. A lane that is not open (none,
    ///      closed, its executor's codehash drifted, or its switch off) copies nothing.
    function _copyLane(HookrRegistryStorage.State storage s, address root, address template) private {
        HookrRegistryStorage.Lane storage l = s.lanes[template];
        address executor = l.executor;
        HookrRegistryStorage.LaneSwitch storage w = s.laneSwitches[template][executor];
        if (executor == address(0) || executor.codehash != l.codeHash || !w.on) return;
        uint32 gasCap = w.gasCap;
        s.lanes[root] = HookrRegistryStorage.Lane(executor, l.partnerBps, 0, l.codeHash);
        s.laneSwitches[root][executor] = HookrRegistryStorage.LaneSwitch(false, gasCap, uint48(block.timestamp));
        emit IHookrLanes.ExecutorLaneSet(root, executor, false, gasCap, msg.sender);
    }

    /// @dev Whether `a`, `implementation`'s admission for `scope`, is live: recorded, its implementation's runtime
    ///      codehash the pinned one, and its bond, if any, covering it.
    function _live(address scope, address implementation, IHookrRegistry.Admission storage a)
        private
        view
        returns (bool)
    {
        return implementation != address(0) && a.implementation == implementation
            && implementation.codehash == a.codeHash && HookrRegistryChecks.bondCovers(scope, implementation);
    }

    /// @dev Whether `target` answers the one-word getter `selector` as `model` does, `model` answering at all.
    function _reportsAsDoes(address target, address model, bytes4 selector) private view returns (bool) {
        (bool ok, uint256 word) = HookrRegistryChecks.read(model, selector);
        return ok && HookrRegistryChecks.reports(target, selector, word);
    }

    /// @dev The registry's operation id, as HookrRegistry.operationHash derives it: chain, registry, kind, arguments.
    function _operationHash(bytes32 kind, bytes memory arguments) private view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), kind, arguments));
    }

    /// @dev Consumes a queued operation: ready, not expired, and queued after `brakeAt` (it was queued at readyAt minus
    ///      the delay). Zero `brakeAt` refuses nothing, since every readyAt exceeds the delay.
    function _consume(bytes32 kind, bytes memory arguments, uint48 brakeAt, uint48 delay) private {
        bytes32 operation = _operationHash(kind, arguments);
        HookrRegistryStorage.State storage s = HookrRegistryStorage.state();
        uint48 eta = s.readyAt[operation];
        if (eta == 0 || block.timestamp < eta) revert NotReady(operation);
        if (eta <= uint256(brakeAt) + delay) revert QueuedBeforeBrake(operation);
        if (block.timestamp > uint256(eta) + GRACE_PERIOD) revert OperationExpired(operation, eta + GRACE_PERIOD);
        delete s.readyAt[operation];
        emit OperationExecuted(operation);
    }
}
