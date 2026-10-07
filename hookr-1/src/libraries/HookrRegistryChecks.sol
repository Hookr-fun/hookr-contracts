// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IHookrRegistry} from "../interfaces/IHookrRegistry.sol";
import {IHookrAdmissions} from "../interfaces/IHookrAdmissions.sol";
import {IHookrModuleBond} from "../interfaces/IHookrModuleBond.sol";
import {IHookrExternalHooks} from "../interfaces/IHookrExternalHooks.sol";
import {IHookrRoot} from "../interfaces/IHookrRoot.sol";
import {HookrRegistryStorage} from "./HookrRegistryStorage.sol";
import {HookrDelegation} from "./HookrDelegation.sol";

/// @title HookrRegistryChecks
/// @notice HookrRegistry's queue-time and execution-time checks: the canonical arguments of every queued operation and
///         the chain state each must hold against when queued and again when executed (module admissions, roots and
///         root factories, launchers, recapture lanes, quote classes and the settlement set).
/// @dev Deployed as an external (linked) library so the registry stays under the EIP-170 runtime limit: it is deployed
///      through CREATE3 and linked into the registry's bytecode before the registry is deployed. The registry reaches
///      its external functions by DELEGATECALL, so they read the registry's storage (HookrRegistryStorage),
///      `address(this)` is the registry and every revert is the registry's. They are all `view`: nothing here writes
///      storage. The internal helpers at the end compile into whichever contract calls them, the registry included.
library HookrRegistryChecks {
    /// @dev The registry's operation kinds; HookrRegistry publishes the public ones under the same names.
    bytes32 internal constant SET_LAUNCHER = keccak256("SET_LAUNCHER");
    bytes32 internal constant REGISTER_ROOT = keccak256("REGISTER_ROOT");
    bytes32 internal constant RETIRE_ROOT = keccak256("RETIRE_ROOT");
    bytes32 internal constant ADMIT = keccak256("ADMIT");
    bytes32 internal constant TRANSFER_OWNER = keccak256("TRANSFER_OWNER");
    bytes32 internal constant SET_GUARDIAN = keccak256("SET_GUARDIAN");
    bytes32 internal constant SET_QUOTE = keccak256("SET_QUOTE");
    bytes32 internal constant RESUME_NEW_MARKETS = keccak256("RESUME_NEW_MARKETS");
    bytes32 internal constant REOPEN_ROOT = keccak256("REOPEN_ROOT");
    bytes32 internal constant SET_ROOT_FACTORY = keccak256("SET_ROOT_FACTORY");
    bytes32 internal constant OPEN_LANE = keccak256("OPEN_LANE");
    bytes32 internal constant LANE_ON = keccak256("LANE_ON");
    bytes32 internal constant ADD_SETTLEMENT = keccak256("ADD_SETTLEMENT");
    bytes32 internal constant SET_QUOTE_CLASS = keccak256("SET_QUOTE_CLASS");
    bytes32 internal constant ANY_QUOTE = keccak256("ANY_QUOTE");
    bytes32 internal constant REOPEN_QUOTE = keccak256("REOPEN_QUOTE");
    bytes32 internal constant RECORD_EXTERNAL_HOOK = keccak256("RECORD_EXTERNAL_HOOK");
    bytes32 internal constant SET_ADMISSION_BOND = keccak256("SET_ADMISSION_BOND");
    /// @dev Lowest Rules gas limit an admission accepts. Every Rules call on a swap runs under this admitted limit.
    uint32 internal constant RULES_MIN_GAS_LIMIT = 2_000_000;
    /// @dev Highest gas limit a GATE admission accepts: a gate vouches for a payer, so it runs a short check.
    uint32 internal constant MAX_GATE_GAS_LIMIT = 200_000;
    /// @dev The schema a GATE admission carries: `keccak256("IHookrSwapGate")`.
    bytes32 internal constant GATE_SCHEMA = keccak256("IHookrSwapGate");
    /// @dev A lane's gas per call is from MIN_LANE_GAS to MAX_LANE_GAS, the bounds the recapture root wires a lane
    ///      with: enough for an executor's frame, and small enough that a swap funding two lane calls fits a block.
    uint256 internal constant MIN_LANE_GAS = 50_000;
    uint256 internal constant MAX_LANE_GAS = 5_000_000;
    /// @dev The most a lane's partner keeps of an arb recapture: 2,500 bps (25%), the rate agreed and pinned for the
    ///      partner executor. A lower rate can open; a higher one needs a new registry.
    uint256 internal constant MAX_LANE_PARTNER_BPS = 2_500;
    /// @dev The most currencies the settlement set holds, so a root's frame reads a bounded list.
    uint256 internal constant MAX_SETTLEMENT = 8;
    /// @dev Gas forwarded to each root identity getter and every other probe.
    uint256 internal constant PROBE_GAS = 50_000;
    /// @dev Uniswap v4 hook permission bits in the low 14 bits of a hook address.
    uint160 internal constant FLAG_MASK = 0x3fff;
    bytes4 internal constant PERMISSION_FLAGS_SELECTOR = bytes4(keccak256("PERMISSION_FLAGS()"));
    /// @dev `laneModule()`: a root that runs cold paths in a module it deployed reports the module and the module's
    ///      runtime codehash, both fixed in the root's own runtime code. Registration checks the module's code.
    bytes4 internal constant LANE_MODULE_SELECTOR = bytes4(keccak256("laneModule()"));
    /// @dev `recaptureModule()`: HookrRules reports its HookrRecapture module the same way (checked at ADMIT of RULES).
    bytes4 internal constant RECAPTURE_MODULE_SELECTOR = bytes4(keccak256("recaptureModule()"));
    /// @dev `trustedRoot()`: the one root a Rules module answers to, read to find a part scope's root.
    bytes4 internal constant TRUSTED_ROOT_SELECTOR = bytes4(keccak256("trustedRoot()"));

    /// @dev The errors the checks raise. HookrRegistry declares each with the same signature, so a revert from here
    ///      decodes against the registry's ABI.
    error InvalidAddress();
    error UnknownOperation(bytes32 kind);
    error NonCanonicalArguments(bytes32 kind);
    error InvalidRoot();
    error RootFrozen();
    error AlreadyAdmitted();
    error InvalidAdmission();
    error NotAContract(address account);
    error DelegatedAccount(address account);
    error NewMarketsNotPaused();
    error RootNotClosed();
    error CodeHashMismatch(address account);
    error AlreadyActive(address account);
    error InvalidLane();
    error QuoteClassActive(bytes32 codeHash);
    error AnyQuoteActive();
    error QuoteNotBraked(address asset);

    /// @notice Checks a queued operation: its arguments must be the canonical ABI encoding the executing function
    ///         re-derives, and they must hold against current chain state.
    /// @param kind The operation kind.
    /// @param arguments The operation's ABI arguments.
    /// @param poolManager The registry's PoolManager, which a root must report.
    function checkQueued(bytes32 kind, bytes calldata arguments, address poolManager) external view {
        bytes memory canonical;
        if (kind == SET_LAUNCHER || kind == SET_QUOTE) {
            (address account, bool active) = abi.decode(arguments, (address, bool));
            if (account == address(0)) revert InvalidAddress();
            if (active) {
                if (kind == SET_LAUNCHER) _checkAdmitLauncher(account);
                else requireContract(account);
            }
            canonical = abi.encode(account, active);
        } else if (kind == REGISTER_ROOT) {
            (address root, bytes32 codeHash) = abi.decode(arguments, (address, bytes32));
            _checkRoot(root, codeHash, poolManager);
            canonical = abi.encode(root, codeHash);
        } else if (kind == REOPEN_ROOT) {
            address root = abi.decode(arguments, (address));
            _checkReopen(root);
            canonical = abi.encode(root);
        } else if (kind == SET_ROOT_FACTORY) {
            (address factory, bytes32 codeHash, bool active) = abi.decode(arguments, (address, bytes32, bool));
            _checkRootFactory(factory, codeHash, active);
            canonical = abi.encode(factory, codeHash, active);
        } else if (kind == RETIRE_ROOT) {
            address root = abi.decode(arguments, (address));
            if (!HookrRegistryStorage.state().roots[root].registered) revert InvalidRoot();
            canonical = abi.encode(root);
        } else if (kind == ADMIT) {
            (address root, IHookrRegistry.Admission memory a) =
                abi.decode(arguments, (address, IHookrRegistry.Admission));
            _checkAdmission(root, a);
            canonical = abi.encode(root, a);
        } else if (kind == TRANSFER_OWNER) {
            address nextOwner = abi.decode(arguments, (address));
            if (nextOwner == address(0)) revert InvalidAddress();
            requireUndelegated(nextOwner);
            canonical = abi.encode(nextOwner);
        } else if (kind == SET_GUARDIAN) {
            address nextGuardian = abi.decode(arguments, (address));
            requireUndelegated(nextGuardian);
            canonical = abi.encode(nextGuardian);
        } else if (kind == RESUME_NEW_MARKETS) {
            if (!HookrRegistryStorage.state().newMarketsPaused) revert NewMarketsNotPaused();
        } else if (kind == SET_QUOTE_CLASS) {
            (bytes32 codeHash, address witness) = abi.decode(arguments, (bytes32, address));
            _checkQuoteClass(codeHash, witness);
            canonical = abi.encode(codeHash, witness);
        } else if (kind == ANY_QUOTE) {
            if (HookrRegistryStorage.quoteState().anyQuote) revert AnyQuoteActive();
        } else if (kind == REOPEN_QUOTE) {
            address asset = abi.decode(arguments, (address));
            if (!HookrRegistryStorage.quoteState().brakes[asset].braked) revert QuoteNotBraked(asset);
            canonical = abi.encode(asset);
        } else if (kind == OPEN_LANE) {
            (address root, address executor, bytes32 codeHash, uint32 gasCap, uint16 partnerBps) =
                abi.decode(arguments, (address, address, bytes32, uint32, uint16));
            _checkLane(root, executor, codeHash, gasCap, partnerBps);
            canonical = abi.encode(root, executor, codeHash, gasCap, partnerBps);
        } else if (kind == ADD_SETTLEMENT) {
            address currency = abi.decode(arguments, (address));
            _checkSettlement(currency);
            canonical = abi.encode(currency);
        } else if (kind == LANE_ON) {
            (address root, address executor, uint32 gasCap) = abi.decode(arguments, (address, address, uint32));
            _checkLaneOn(root, executor, gasCap);
            canonical = abi.encode(root, executor, gasCap);
        } else if (kind == SET_ADMISSION_BOND) {
            (address scope, address implementation, address bondRef) =
                abi.decode(arguments, (address, address, address));
            _checkBond(scope, implementation, bondRef);
            canonical = abi.encode(scope, implementation, bondRef);
        } else if (kind == RECORD_EXTERNAL_HOOK) {
            (address hook, IHookrExternalHooks.HookKind hookKind, bytes32 codeHash, address bondRef) =
                abi.decode(arguments, (address, IHookrExternalHooks.HookKind, bytes32, address));
            _checkRecord(hook, hookKind, codeHash, bondRef);
            canonical = abi.encode(hook, hookKind, codeHash, bondRef);
        } else {
            revert UnknownOperation(kind);
        }
        if (keccak256(arguments) != keccak256(canonical)) revert NonCanonicalArguments(kind);
    }

    /// @notice Checks a root registration (REGISTER_ROOT) when it executes.
    function checkRoot(address root, bytes32 codeHash, address poolManager) external view {
        _checkRoot(root, codeHash, poolManager);
    }

    /// @notice Checks a root reopening (REOPEN_ROOT) when it executes.
    function checkReopen(address root) external view {
        _checkReopen(root);
    }

    /// @notice Checks a root factory activation or deactivation (SET_ROOT_FACTORY) when it executes.
    function checkRootFactory(address factory, bytes32 codeHash, bool active) external view {
        _checkRootFactory(factory, codeHash, active);
    }

    /// @notice Checks a launcher admission (SET_LAUNCHER, active) when it executes.
    function checkAdmitLauncher(address launcher) external view {
        _checkAdmitLauncher(launcher);
    }

    /// @notice Checks a module admission (ADMIT) when it executes.
    function checkAdmission(address scope, IHookrRegistry.Admission memory a) external view {
        _checkAdmission(scope, a);
    }

    /// @notice Checks a lane opening (OPEN_LANE) when it executes.
    function checkLane(address root, address executor, bytes32 codeHash, uint32 gasCap, uint16 partnerBps)
        external
        view
    {
        _checkLane(root, executor, codeHash, gasCap, partnerBps);
    }

    /// @notice Checks an executor switch-on (LANE_ON) when it executes.
    function checkLaneOn(address root, address executor, uint32 gasCap) external view {
        _checkLaneOn(root, executor, gasCap);
    }

    /// @notice Checks a settlement currency addition (ADD_SETTLEMENT) when it executes.
    function checkSettlement(address currency) external view {
        _checkSettlement(currency);
    }

    /// @notice Checks a quote class admission (SET_QUOTE_CLASS) when it executes.
    function checkQuoteClass(bytes32 codeHash, address witness) external view {
        _checkQuoteClass(codeHash, witness);
    }

    /// @notice Checks an external-hook record (RECORD_EXTERNAL_HOOK) when it executes.
    function checkRecord(address hook, IHookrExternalHooks.HookKind kind, bytes32 codeHash, address bondRef)
        external
        view
    {
        _checkRecord(hook, kind, codeHash, bondRef);
    }

    /// @notice Checks an admission bond (SET_ADMISSION_BOND) when it executes.
    function checkBond(address scope, address implementation, address bondRef) external view {
        _checkBond(scope, implementation, bondRef);
    }

    /// @notice The root of the part scope `module`, or zero when `module` is not one (see `_partScopeRoot`).
    function partScopeRoot(address module) external view returns (address) {
        return _partScopeRoot(module);
    }

    /// @notice Whether `scope` is a frozen root or a part scope of one, where `revokeModuleAdmission` is the owner's
    ///         alone.
    /// @dev A part scope's root here is the root `scope` reports from `trustedRoot()` while that root stores a RULES
    ///      admission of `scope`. Unlike `_partScopeRoot`, the module's bond, its codehash and the root's lifecycle are
    ///      not read: the freeze outlasts each of them, so a lapse in any never lets the guardian make a revocation
    ///      the freeze keeps from being undone.
    function frozenScope(address scope) external view returns (bool) {
        HookrRegistryStorage.State storage s = HookrRegistryStorage.state();
        address root = scope;
        if (!s.roots[scope].registered) {
            root = _reportedRoot(scope);
            IHookrRegistry.Admission storage a = s.admissions[root][scope];
            if (a.implementation != scope || a.kind != IHookrRegistry.Kind.RULES) return false;
        }
        return s.roots[root].frozen;
    }

    /// @dev Contract code is immutable after creation on this EVM, except for an EIP-7702 delegation
    ///      designator (0xef0100 || target), which its key holder can re-point or use to move balances. Code that
    ///      starts with 0xEF (HookrDelegation.isDelegated: a designator or a Stylus program) is refused.
    function requireContract(address account) internal view {
        if (account.code.length == 0) revert NotAContract(account);
        if (HookrDelegation.isDelegated(account)) revert DelegatedAccount(account);
    }

    /// @dev Refuses an account whose code is an EIP-7702 delegation designator (HookrDelegation.isDesignator).
    ///      Accounts without code and every other code, a Stylus program included, pass.
    function requireUndelegated(address account) internal view {
        if (HookrDelegation.isDesignator(account)) revert DelegatedAccount(account);
    }

    /// @dev Whether `account` holds code that does not start with 0xEF: `requireContract` as a boolean.
    function holdsOwnCode(address account) internal view returns (bool held) {
        if (account.code.length != 0) held = !HookrDelegation.isDelegated(account);
    }

    /// @dev Whether `implementation`'s admission for `scope` reads as admitted under its bond: true when it has none, and
    ///      otherwise only while the bond answers `covers(scope, implementation)` with a clean 32-byte true under
    ///      PROBE_GAS. A revert, a return shorter or longer than one word, any word other than 1 and running out of gas
    ///      all read as false.
    function bondCovers(address scope, address implementation) internal view returns (bool) {
        address bond = HookrRegistryStorage.bonds().bondOf[scope][implementation];
        return bond == address(0) || covers(bond, scope, implementation);
    }

    /// @dev Whether `bond` answers `covers(scope, implementation)` with a clean 32-byte true under PROBE_GAS.
    function covers(address bond, address scope, address implementation) internal view returns (bool) {
        return answersTrue(bond, IHookrModuleBond.covers.selector, scope, implementation);
    }

    /// @dev Whether `target` answers `selector(first, second)` with a clean 32-byte true under PROBE_GAS: a revert, a
    ///      return shorter or longer than one word, any word other than 1 and running out of gas all read as false. The
    ///      call is built past the free memory pointer, which it never moves, and the answer read from scratch space.
    function answersTrue(address target, bytes4 selector, address first, address second)
        internal
        view
        returns (bool ok)
    {
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, selector)
            mstore(add(p, 4), first)
            mstore(add(p, 36), second)
            // The call first: Yul evaluates arguments right to left, so returndatasize() must come after it.
            let called := staticcall(PROBE_GAS, target, p, 68, 0, 32)
            ok := and(and(called, eq(returndatasize(), 32)), eq(mload(0), 1))
        }
    }

    /// @dev The first word a bounded static call to the no-argument getter `selector` of `target` returns, and whether
    ///      the call succeeded with at least one word.
    function read(address target, bytes4 selector) internal view returns (bool ok, uint256 word) {
        assembly ("memory-safe") {
            mstore(0, selector)
            // The call first: Yul evaluates arguments right to left, so returndatasize() must come after it.
            let called := staticcall(PROBE_GAS, target, 0, 4, 0, 32)
            ok := and(called, gt(returndatasize(), 31))
            word := mload(0)
        }
    }

    /// @dev Whether a bounded static call to a no-argument getter succeeds and returns at least one word equal to
    ///      `expected`. Reverts, short returns and dirty high bits all read as false.
    function reports(address target, bytes4 selector, uint256 expected) internal view returns (bool matches) {
        assembly ("memory-safe") {
            mstore(0, selector)
            let ok := staticcall(PROBE_GAS, target, 0, 4, 0, 32)
            matches := and(and(ok, gt(returndatasize(), 31)), eq(mload(0), expected))
        }
    }

    /// @dev A root must hold non-delegated code with the queued runtime codehash, be unregistered and not recorded as
    ///      an external hook, report this registry's PoolManager and this registry, and declare permission flags equal
    ///      to its address bits. A root that reports a module from `laneModule()` (HookrRoot's HookrLane, reached by
    ///      DELEGATECALL) must have that module hold code with the runtime codehash the root reports: both are fixed in
    ///      the root's runtime, so the pinned root codehash then also pins the module's code.
    function _checkRoot(address root, bytes32 codeHash, address poolManager) private view {
        requireContract(root);
        if (root.codehash != codeHash) revert CodeHashMismatch(root);
        if (
            HookrRegistryStorage.state().roots[root].registered
                || HookrRegistryStorage.records().hooks[root].kind != IHookrExternalHooks.HookKind.NONE
                || !reports(root, IHookrRoot.poolManager.selector, uint160(poolManager))
                || !reports(root, IHookrRoot.registry.selector, uint160(address(this)))
                || !reports(root, PERMISSION_FLAGS_SELECTOR, uint160(root) & FLAG_MASK)
        ) revert InvalidRoot();
        checkModule(root, LANE_MODULE_SELECTOR);
    }

    /// @dev A contract that reports a module from `selector` (HookrRoot's `laneModule()`, HookrRules'
    ///      `recaptureModule()`: a module it deployed and reaches by DELEGATECALL, and that module's runtime codehash,
    ///      both fixed in its own runtime) must have that module hold code with that codehash, so the pinned codehash of
    ///      the contract also pins the module's code. A contract that reports none is not checked.
    function checkModule(address target, bytes4 selector) internal view {
        bool reported;
        uint256 word;
        bytes32 moduleHash;
        assembly ("memory-safe") {
            mstore(0, selector)
            // The call first: Yul evaluates arguments right to left, so returndatasize() must come after it.
            let ok := staticcall(PROBE_GAS, target, 0, 4, 0, 64)
            reported := and(ok, eq(returndatasize(), 64))
            word := mload(0)
            moduleHash := mload(32)
        }
        if (reported) {
            address module = address(uint160(word));
            if (word >> 160 != 0 || module.code.length == 0 || module.codehash != moduleHash) {
                revert CodeHashMismatch(module);
            }
        }
    }

    /// @dev A switch-on names a registered root, an executor opened on it and a gas cap inside the lane bounds.
    function _checkLaneOn(address root, address executor, uint32 gasCap) private view {
        HookrRegistryStorage.State storage s = HookrRegistryStorage.state();
        if (!s.roots[root].registered) revert InvalidRoot();
        if (s.laneSwitches[root][executor].gasCap == 0 || gasCap < MIN_LANE_GAS || gasCap > MAX_LANE_GAS) {
            revert InvalidLane();
        }
    }

    function _checkReopen(address root) private view {
        HookrRegistryStorage.RootState storage r = HookrRegistryStorage.state().roots[root];
        if (!r.active) revert InvalidRoot();
        if (!r.closed) revert RootNotClosed();
    }

    /// @dev An activation is refused while the factory is active, so none can be queued ahead of a brake.
    function _checkRootFactory(address factory, bytes32 codeHash, bool active) private view {
        if (factory == address(0)) revert InvalidAddress();
        if (active) {
            requireContract(factory);
            if (factory.codehash != codeHash) revert CodeHashMismatch(factory);
            if (HookrRegistryStorage.state().rootFactories[factory] != bytes32(0)) {
                revert AlreadyActive(factory);
            }
        }
    }

    /// @dev An admission is refused while the launcher is active, so none can be queued ahead of a brake.
    function _checkAdmitLauncher(address launcher) private view {
        requireContract(launcher);
        if (HookrRegistryStorage.state().launchers[launcher]) revert AlreadyActive(launcher);
    }

    /// @dev An active root admits any kind. An active root factory admits ADVISORY implementations (pair advisories).
    ///      Any other scope must be a part scope: a Rules module holding a live RULES admission on the active root it
    ///      reports from `trustedRoot()` (see `_partScopeRoot`), which admits RULES parts with 25,000 to 2,000,000
    ///      gas, a nonzero phase mask and no fail-open, never the module itself, and which that root's freeze seals. A
    ///      GATE, on a root only, has zero caps, no phases, 25,000 to 200,000 gas, is neither fee-only nor fail-open
    ///      (a fail-open admission must be fee-only) and carries the schema `keccak256("IHookrSwapGate")`. No scope
    ///      admits an implementation a brake revoked for it.
    function _checkAdmission(address scope, IHookrRegistry.Admission memory a) private view {
        HookrRegistryStorage.State storage s = HookrRegistryStorage.state();
        HookrRegistryStorage.RootState storage r = s.roots[scope];
        bool factoryScope;
        bool partScope;
        if (!r.active) {
            if (s.rootFactories[scope] != bytes32(0)) {
                factoryScope = true;
            } else {
                address root = _partScopeRoot(scope);
                if (root == address(0)) revert InvalidRoot();
                r = s.roots[root];
                partScope = true;
            }
        }
        if (r.frozen) revert RootFrozen();
        if (s.admissions[scope][a.implementation].implementation != address(0)) revert AlreadyAdmitted();
        if (s.revoked[scope][a.implementation] || (factoryScope && a.kind != IHookrRegistry.Kind.ADVISORY)) {
            revert InvalidAdmission();
        }
        requireContract(a.implementation);
        if (
            a.implementation.codehash != a.codeHash || a.schemaHash == bytes32(0) || a.gasLimit < 25_000
                || a.gasLimit > 2_000_000 || a.caps.maxLpFeePips > 600_000 || a.caps.maxQuoteTakePips >= 1_000_000
                || a.caps.maxSubjectTakeBps > 1_000 || (a.phaseMask & ~uint8(3)) != 0
                || (a.kind == IHookrRegistry.Kind.RULES
                    && (a.phaseMask == 0
                        || a.failOpen
                        || (!partScope && (a.phaseMask != 3 || a.gasLimit < RULES_MIN_GAS_LIMIT))))
                || (partScope && (a.kind != IHookrRegistry.Kind.RULES || a.implementation == scope))
                || (a.kind == IHookrRegistry.Kind.ADVISORY && (a.phaseMask == 0 || a.caps.maxSubjectTakeBps != 0))
                || (a.kind == IHookrRegistry.Kind.GATE
                    && (a.gasLimit > MAX_GATE_GAS_LIMIT
                        || a.phaseMask != 0
                        || a.feeOnly
                        || a.schemaHash != GATE_SCHEMA
                        || a.caps.maxLpFeePips != 0
                        || a.caps.maxQuoteTakePips != 0
                        || a.caps.maxSubjectTakeBps != 0))
                || (a.failOpen && (!a.feeOnly || a.caps.maxQuoteTakePips != 0))
        ) revert InvalidAdmission();
        if (a.kind == IHookrRegistry.Kind.RULES) checkModule(a.implementation, RECAPTURE_MODULE_SELECTOR);
    }

    /// @dev The root of the part scope `module`: the root it reports from `trustedRoot()`, read with PROBE_GAS as one
    ///      clean address word, while that root is active and holds a live RULES admission of `module` whose pinned
    ///      codehash is `module`'s current one. Zero otherwise. A Rules module answers to one root (the root refuses
    ///      a pool's Rules whose `trustedRoot()` is another), so its part scope follows that root's lifecycle.
    function _partScopeRoot(address module) private view returns (address root) {
        root = _reportedRoot(module);
        HookrRegistryStorage.State storage s = HookrRegistryStorage.state();
        IHookrRegistry.Admission storage a = s.admissions[root][module];
        if (
            !s.roots[root].active || a.implementation != module || a.kind != IHookrRegistry.Kind.RULES
                || module.codehash != a.codeHash || !bondCovers(root, module)
        ) return address(0);
    }

    /// @dev The root `module` reports from `trustedRoot()`, read with PROBE_GAS as one clean address word; zero when
    ///      the call fails, returns less than a word or sets bits above the address.
    function _reportedRoot(address module) private view returns (address root) {
        (bool ok, uint256 word) = read(module, TRUSTED_ROOT_SELECTOR);
        if (ok && word >> 160 == 0) root = address(uint160(word));
    }

    /// @dev A lane opens only on a registered, unretired root, unfrozen unless it is an owned root (whose lane is the one
    ///      exception to its freeze), for an executor other than the root that holds non-delegated code with the pinned
    ///      runtime codehash, with the gas cap and the share inside their bounds. The executor's own `partnerBps()` is
    ///      not read.
    function _checkLane(address root, address executor, bytes32 codeHash, uint32 gasCap, uint16 partnerBps)
        private
        view
    {
        HookrRegistryStorage.RootState storage r = HookrRegistryStorage.state().roots[root];
        if (!r.active) revert InvalidRoot();
        if (r.frozen && HookrRegistryStorage.owned().roots[root].factory == address(0)) revert RootFrozen();
        requireContract(executor);
        if (executor.codehash != codeHash) revert CodeHashMismatch(executor);
        if (executor == root || gasCap < MIN_LANE_GAS || gasCap > MAX_LANE_GAS || partnerBps > MAX_LANE_PARTNER_BPS) {
            revert InvalidLane();
        }
    }

    /// @dev A bond attaches to a live admission that has none, once and for good, and names a bond that holds
    ///      non-delegated code and covers the admission now, so attaching it never withdraws the admission.
    function _checkBond(address scope, address implementation, address bondRef) private view {
        if (HookrRegistryStorage.state().admissions[scope][implementation].implementation == address(0)) {
            revert InvalidAdmission();
        }
        if (HookrRegistryStorage.bonds().bondOf[scope][implementation] != address(0)) {
            revert IHookrAdmissions.AlreadyBonded(scope, implementation);
        }
        requireContract(bondRef);
        if (!covers(bondRef, scope, implementation)) revert IHookrAdmissions.BondNotCovering(bondRef);
    }

    /// @dev A record names a hook that holds non-delegated code with the recorded runtime codehash and is not a
    ///      registered root, a kind other than NONE, and a bond reference that is zero or holds non-delegated code.
    function _checkRecord(address hook, IHookrExternalHooks.HookKind kind, bytes32 codeHash, address bondRef)
        private
        view
    {
        if (kind == IHookrExternalHooks.HookKind.NONE) revert IHookrExternalHooks.InvalidRecord();
        requireContract(hook);
        if (hook.codehash != codeHash) revert CodeHashMismatch(hook);
        if (HookrRegistryStorage.state().roots[hook].registered) revert IHookrExternalHooks.InvalidRecord();
        if (bondRef != address(0)) requireContract(bondRef);
    }

    /// @dev A settlement currency is native ETH or non-delegated code, not yet a member, with room in the set.
    function _checkSettlement(address currency) private view {
        if (currency != address(0)) requireContract(currency);
        HookrRegistryStorage.Settlement storage t = HookrRegistryStorage.settlement();
        if (t.position[currency] != 0 || t.currencies.length >= MAX_SETTLEMENT) revert InvalidLane();
    }

    /// @dev A class is the runtime codehash of `witness`, which must hold non-delegated code, and is not admitted.
    function _checkQuoteClass(bytes32 codeHash, address witness) private view {
        requireContract(witness);
        if (witness.codehash != codeHash) revert CodeHashMismatch(witness);
        if (HookrRegistryStorage.quoteState().classPosition[codeHash] != 0) {
            revert QuoteClassActive(codeHash);
        }
    }
}
