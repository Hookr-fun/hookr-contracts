// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookrModuleTypesV1} from "./libraries/HookrModuleTypesV1.sol";
import {HookrStatefulModuleTypesV1} from "./libraries/HookrStatefulModuleTypesV1.sol";
import {IHookrStatefulModuleV1} from "./interfaces/IHookrStatefulModuleV1.sol";

/// @title Hookr Module Catalog V1
/// @notice Append-only admission registry for explicitly read-only or stateful Hookr stack modules.
/// @dev A module definition is immutable once admitted. Retirement only prevents the module from
///      being selected by a future stack; it cannot alter stacks that already froze the snapshot.
///      STATEFUL_V1 admission is an explicit owner-reviewed trust boundary because CALL cannot
///      sandbox an implementation while PoolManager is unlocked.
contract HookrModuleCatalogV1 {
    bytes32 public constant MODULE_ID_DOMAIN = keccak256("HOOKR_MODULE_CATALOG_V1");
    uint8 public constant MAX_RELATIONS = HookrModuleTypesV1.MAX_MODULES;
    uint160 public constant ALL_HOOK_FLAGS = uint160((1 << 14) - 1);
    uint32 public constant MIN_CALLBACK_GAS = 25_000;
    uint32 public constant CANONICAL_STATEFUL_MARKER_GAS = 50_000;

    enum ModuleStatus {
        UNSET,
        ACTIVE,
        RETIRED
    }

    address public owner;
    address public pendingOwner;
    address public canonicalStatefulModule;
    bytes32 public canonicalStatefulModuleCodeHash;

    mapping(bytes32 moduleId => HookrModuleTypesV1.ModuleSnapshot snapshot) private _modules;
    mapping(bytes32 moduleId => ModuleStatus status) public moduleStatus;
    mapping(bytes32 moduleId => bytes32[] keys) private _requiredModuleKeys;
    mapping(bytes32 moduleId => bytes32[] keys) private _conflictingModuleKeys;
    bytes32[] private _moduleIds;

    event OwnerProposed(address indexed pendingOwner);
    event OwnerSet(address indexed owner);
    event CanonicalStatefulModuleSet(address indexed implementation, bytes32 indexed implementationCodeHash);
    event ModuleRegistered(
        bytes32 indexed moduleId,
        bytes32 indexed moduleKey,
        uint32 indexed version,
        address implementation,
        bytes32 implementationCodeHash,
        bytes32 configSchemaHash,
        uint160 requiredHookFlags,
        uint8 phaseMask,
        bytes32 exclusiveGroup,
        HookrModuleTypesV1.ExecutionMode executionMode
    );
    event ModuleRetired(bytes32 indexed moduleId);

    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error InvalidModule();
    error InvalidPhaseMask();
    error InvalidModuleCaps();
    error TooManyRelations();
    error DuplicateRelation(bytes32 moduleKey);
    error SelfRelation(bytes32 moduleKey);
    error ContradictoryRelation(bytes32 moduleKey);
    error ModuleAlreadyExists(bytes32 moduleId);
    error UnknownModule(bytes32 moduleId);
    error ModuleNotActive(bytes32 moduleId);
    error ModuleAlreadyRetired(bytes32 moduleId);
    error CanonicalStatefulModuleAlreadySet(address implementation);
    error CanonicalStatefulModuleNotSet();
    error InvalidCanonicalStatefulModule(address implementation);
    error NonCanonicalStatefulModule(address expected, address actual);
    error CanonicalStatefulModuleCodeChanged(bytes32 expected, bytes32 actual);

    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        emit OwnerSet(owner_);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function contractName() external pure returns (string memory) {
        return "HookrModuleCatalogV1";
    }

    function contractVersion() external pure returns (string memory) {
        return "1.2.0";
    }

    function proposeOwner(address nextOwner) external onlyOwner {
        if (nextOwner == address(0) || nextOwner == owner) revert ZeroAddress();
        pendingOwner = nextOwner;
        emit OwnerProposed(nextOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnerSet(msg.sender);
    }

    /// @notice Binds the sole implementation permitted to execute stateful module callbacks.
    /// @dev Must be called after the registry and native mechanics block are deployed, and before
    ///      the native module is registered. The binding cannot be changed or cleared.
    function setCanonicalStatefulModuleOnce(address implementation) external onlyOwner {
        address current = canonicalStatefulModule;
        if (current != address(0)) revert CanonicalStatefulModuleAlreadySet(current);
        if (implementation == address(0) || implementation.code.length == 0) {
            revert InvalidCanonicalStatefulModule(implementation);
        }

        (bool markerOk, bytes32 marker) = _readStatefulMarker(implementation, CANONICAL_STATEFUL_MARKER_GAS);
        if (!markerOk || marker != HookrStatefulModuleTypesV1.MODULE_MAGIC) {
            revert InvalidCanonicalStatefulModule(implementation);
        }

        bytes32 implementationCodeHash = implementation.codehash;
        canonicalStatefulModule = implementation;
        canonicalStatefulModuleCodeHash = implementationCodeHash;
        emit CanonicalStatefulModuleSet(implementation, implementationCodeHash);
    }

    function registerModule(HookrModuleTypesV1.ModuleRegistration calldata registration)
        external
        onlyOwner
        returns (bytes32 moduleId)
    {
        _validateRegistration(registration);

        bytes32 implementationCodeHash = registration.implementation.codehash;
        bytes32 requirementsHash = keccak256(abi.encode(registration.requiredModuleKeys));
        bytes32 conflictsHash = keccak256(abi.encode(registration.conflictingModuleKeys));
        moduleId = computeModuleId(registration, implementationCodeHash, requirementsHash, conflictsHash);
        if (_modules[moduleId].moduleId != bytes32(0)) revert ModuleAlreadyExists(moduleId);

        HookrModuleTypesV1.ModuleSnapshot storage snapshot = _modules[moduleId];
        snapshot.moduleId = moduleId;
        snapshot.moduleKey = registration.moduleKey;
        snapshot.version = registration.version;
        snapshot.implementation = registration.implementation;
        snapshot.implementationCodeHash = implementationCodeHash;
        snapshot.configSchemaHash = registration.configSchemaHash;
        snapshot.requiredHookFlags = registration.requiredHookFlags;
        snapshot.phaseMask = registration.phaseMask;
        snapshot.exclusiveGroup = registration.exclusiveGroup;
        snapshot.executionMode = registration.executionMode;
        snapshot.maxLpFeeSurchargePips = registration.maxLpFeeSurchargePips;
        snapshot.maxSpecifiedQuoteTakeBps = registration.maxSpecifiedQuoteTakeBps;
        snapshot.maxUnspecifiedQuoteTakeBps = registration.maxUnspecifiedQuoteTakeBps;
        snapshot.maxSubjectTakeBps = registration.maxSubjectTakeBps;
        snapshot.callbackGasLimit = registration.callbackGasLimit;
        snapshot.requirementsHash = requirementsHash;
        snapshot.conflictsHash = conflictsHash;

        _copyKeys(registration.requiredModuleKeys, _requiredModuleKeys[moduleId]);
        _copyKeys(registration.conflictingModuleKeys, _conflictingModuleKeys[moduleId]);
        moduleStatus[moduleId] = ModuleStatus.ACTIVE;
        _moduleIds.push(moduleId);

        emit ModuleRegistered(
            moduleId,
            registration.moduleKey,
            registration.version,
            registration.implementation,
            implementationCodeHash,
            registration.configSchemaHash,
            registration.requiredHookFlags,
            registration.phaseMask,
            registration.exclusiveGroup,
            registration.executionMode
        );
    }

    function retireModule(bytes32 moduleId) external onlyOwner {
        ModuleStatus status = moduleStatus[moduleId];
        if (status == ModuleStatus.UNSET) revert UnknownModule(moduleId);
        if (status == ModuleStatus.RETIRED) revert ModuleAlreadyRetired(moduleId);
        moduleStatus[moduleId] = ModuleStatus.RETIRED;
        emit ModuleRetired(moduleId);
    }

    function module(bytes32 moduleId) external view returns (HookrModuleTypesV1.ModuleSnapshot memory snapshot) {
        snapshot = _module(moduleId);
    }

    function activeModule(bytes32 moduleId) external view returns (HookrModuleTypesV1.ModuleSnapshot memory snapshot) {
        if (moduleStatus[moduleId] != ModuleStatus.ACTIVE) revert ModuleNotActive(moduleId);
        snapshot = _module(moduleId);
    }

    function requiredModuleKeys(bytes32 moduleId) external view returns (bytes32[] memory keys) {
        _module(moduleId);
        keys = _requiredModuleKeys[moduleId];
    }

    function conflictingModuleKeys(bytes32 moduleId) external view returns (bytes32[] memory keys) {
        _module(moduleId);
        keys = _conflictingModuleKeys[moduleId];
    }

    function moduleCount() external view returns (uint256) {
        return _moduleIds.length;
    }

    function moduleIdAt(uint256 index) external view returns (bytes32) {
        return _moduleIds[index];
    }

    function computeModuleId(
        HookrModuleTypesV1.ModuleRegistration calldata registration,
        bytes32 implementationCodeHash,
        bytes32 requirementsHash,
        bytes32 conflictsHash
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                MODULE_ID_DOMAIN,
                block.chainid,
                address(this),
                registration.moduleKey,
                registration.version,
                registration.implementation,
                implementationCodeHash,
                registration.configSchemaHash,
                registration.requiredHookFlags,
                registration.phaseMask,
                registration.exclusiveGroup,
                registration.executionMode,
                registration.maxLpFeeSurchargePips,
                registration.maxSpecifiedQuoteTakeBps,
                registration.maxUnspecifiedQuoteTakeBps,
                registration.maxSubjectTakeBps,
                registration.callbackGasLimit,
                requirementsHash,
                conflictsHash
            )
        );
    }

    function _validateRegistration(HookrModuleTypesV1.ModuleRegistration calldata registration) internal view {
        if (registration.executionMode == HookrModuleTypesV1.ExecutionMode.STATEFUL_V1) {
            _validateCanonicalStatefulModule(registration.implementation);
        }
        if (
            registration.moduleKey == bytes32(0) || registration.version == 0
                || registration.implementation == address(0) || registration.implementation.code.length == 0
                || registration.configSchemaHash == bytes32(0) || registration.callbackGasLimit < MIN_CALLBACK_GAS
                || registration.requiredHookFlags & ~ALL_HOOK_FLAGS != 0
        ) revert InvalidModule();
        if (registration.phaseMask == 0 || registration.phaseMask & ~HookrModuleTypesV1.ALL_PHASES != 0) {
            revert InvalidPhaseMask();
        }
        (bool markerOk, bytes32 marker) =
            _readStatefulMarker(registration.implementation, registration.callbackGasLimit);
        bool reportsStateful = markerOk && marker == HookrStatefulModuleTypesV1.MODULE_MAGIC;
        if (reportsStateful != (registration.executionMode == HookrModuleTypesV1.ExecutionMode.STATEFUL_V1)) {
            revert InvalidModule();
        }
        if (
            registration.maxLpFeeSurchargePips > HookrModuleTypesV1.PIPS
                || registration.maxSpecifiedQuoteTakeBps >= HookrModuleTypesV1.BPS
                || registration.maxUnspecifiedQuoteTakeBps >= HookrModuleTypesV1.BPS
                || registration.maxSubjectTakeBps > 1_000
                || (registration.phaseMask & HookrModuleTypesV1.PHASE_BEFORE_SWAP == 0
                    && (registration.maxLpFeeSurchargePips != 0 || registration.maxSpecifiedQuoteTakeBps != 0))
                || (registration.phaseMask & HookrModuleTypesV1.PHASE_AFTER_SWAP == 0
                    && (registration.maxUnspecifiedQuoteTakeBps != 0 || registration.maxSubjectTakeBps != 0))
        ) revert InvalidModuleCaps();
        if (
            registration.requiredModuleKeys.length > MAX_RELATIONS
                || registration.conflictingModuleKeys.length > MAX_RELATIONS
        ) revert TooManyRelations();

        _validateRelations(registration.moduleKey, registration.requiredModuleKeys, registration.conflictingModuleKeys);

        uint160 impliedHookFlags;
        if (registration.phaseMask & HookrModuleTypesV1.PHASE_BEFORE_ADD_LIQUIDITY != 0) {
            impliedHookFlags |= 1 << 11;
        }
        if (registration.phaseMask & HookrModuleTypesV1.PHASE_BEFORE_SWAP != 0) impliedHookFlags |= 1 << 7;
        if (registration.phaseMask & HookrModuleTypesV1.PHASE_AFTER_SWAP != 0) impliedHookFlags |= 1 << 6;
        if (registration.maxSpecifiedQuoteTakeBps != 0) impliedHookFlags |= 1 << 3;
        if (registration.maxUnspecifiedQuoteTakeBps != 0 || registration.maxSubjectTakeBps != 0) {
            impliedHookFlags |= 1 << 2;
        }
        if (registration.requiredHookFlags & impliedHookFlags != impliedHookFlags) revert InvalidModule();
    }

    function _validateCanonicalStatefulModule(address implementation) internal view {
        address canonical = canonicalStatefulModule;
        if (canonical == address(0)) revert CanonicalStatefulModuleNotSet();
        if (implementation != canonical) revert NonCanonicalStatefulModule(canonical, implementation);

        bytes32 expectedCodeHash = canonicalStatefulModuleCodeHash;
        bytes32 actualCodeHash = implementation.codehash;
        if (actualCodeHash != expectedCodeHash) {
            revert CanonicalStatefulModuleCodeChanged(expectedCodeHash, actualCodeHash);
        }
    }

    function _validateRelations(bytes32 self, bytes32[] calldata required, bytes32[] calldata conflicting)
        internal
        pure
    {
        for (uint256 i; i < required.length; ++i) {
            bytes32 key = required[i];
            if (key == bytes32(0) || key == self) revert SelfRelation(key);
            for (uint256 j; j < i; ++j) {
                if (required[j] == key) revert DuplicateRelation(key);
            }
            for (uint256 j; j < conflicting.length; ++j) {
                if (conflicting[j] == key) revert ContradictoryRelation(key);
            }
        }
        for (uint256 i; i < conflicting.length; ++i) {
            bytes32 key = conflicting[i];
            if (key == bytes32(0) || key == self) revert SelfRelation(key);
            for (uint256 j; j < i; ++j) {
                if (conflicting[j] == key) revert DuplicateRelation(key);
            }
        }
    }

    function _copyKeys(bytes32[] calldata source, bytes32[] storage destination) internal {
        for (uint256 i; i < source.length; ++i) {
            destination.push(source[i]);
        }
    }

    function _readStatefulMarker(address implementation, uint256 gasLimit)
        internal
        view
        returns (bool ok, bytes32 marker)
    {
        bytes memory input = abi.encodeCall(IHookrStatefulModuleV1.statefulModuleMagic, ());
        assembly ("memory-safe") {
            mstore(0, 0)
            ok := staticcall(gasLimit, implementation, add(input, 0x20), mload(input), 0, 0x20)
            if iszero(eq(returndatasize(), 0x20)) { ok := 0 }
            marker := mload(0)
        }
    }

    function _module(bytes32 moduleId) internal view returns (HookrModuleTypesV1.ModuleSnapshot storage snapshot) {
        snapshot = _modules[moduleId];
        if (snapshot.moduleId == bytes32(0)) revert UnknownModule(moduleId);
    }
}
