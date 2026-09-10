// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {HookrModuleCatalogV1} from "./HookrModuleCatalogV1.sol";
import {IHookrKernelIntegrationV1} from "./interfaces/IHookrKernelIntegrationV1.sol";
import {IHookrKernelInstanceFactoryV1} from "./interfaces/IHookrKernelInstanceFactoryV1.sol";
import {IHookrKernelInstanceV1} from "./interfaces/IHookrKernelInstanceV1.sol";
import {IHookrKernelInstanceLayoutV1} from "./interfaces/IHookrKernelInstanceLayoutV1.sol";
import {IHookrArbExecutorV2} from "./interfaces/IHookrArbExecutorV2.sol";
import {IHookrModuleV1} from "./interfaces/IHookrModuleV1.sol";
import {IHookrStackRegistryV1} from "./interfaces/IHookrStackRegistryV1.sol";
import {HookrModuleTypesV1} from "./libraries/HookrModuleTypesV1.sol";
import {HookrWthFeePolicyV2} from "./libraries/HookrWthFeePolicyV2.sol";

/// @title Hookr Stack Registry V1
/// @notice Registry for immutable per-pool module stacks and reviewed kernel integrations.
/// @dev Kernel and module retirement only prevents future stack creation. A configured pool keeps
///      the exact implementation codehashes, module snapshots, configs, limits, and integration
///      addresses it selected before initialization.
contract HookrStackRegistryV1 is IHookrStackRegistryV1 {
    using PoolIdLibrary for PoolKey;

    bytes32 public constant KERNEL_ID_DOMAIN = keccak256("HOOKR_KERNEL_REGISTRY_V1");
    bytes32 public constant INTEGRATION_ID_DOMAIN = keccak256("HOOKR_KERNEL_INTEGRATION_REGISTRY_V1");
    bytes32 public constant STACK_ID_DOMAIN = keccak256("HOOKR_STACK_REGISTRY_V1");
    bytes32 public constant STABLE_ROOT_STACK_ID_DOMAIN = keccak256("HOOKR_STABLE_ROOT_STACK_V2");
    bytes32 public constant STACK_MODULES_DOMAIN = keccak256("HOOKR_STACK_MODULES_V1");
    bytes32 public constant ROOT_PROFILE_MANIFEST_DOMAIN = keccak256("HOOKR_ROOT_PROFILE_MANIFEST_V1");
    bytes32 public constant ROOT_PROFILE_MODULES_DOMAIN = keccak256("HOOKR_ROOT_PROFILE_MODULES_V1");
    bytes32 public constant ROUTER_INTEGRATION_KIND = keccak256("HOOKR_KERNEL_INTEGRATION_ROUTER");
    bytes32 public constant QUOTER_INTEGRATION_KIND = keccak256("HOOKR_KERNEL_INTEGRATION_QUOTER");
    bytes32 public constant CORRECTION_EXECUTOR_INTEGRATION_KIND =
        keccak256("HOOKR_KERNEL_INTEGRATION_CORRECTION_EXECUTOR");
    bytes32 public constant SUPPORTED_KERNEL_INSTANCE_LAYOUT_ID = keccak256("HOOKR_KERNEL_INSTANCE_LAYOUT_V1");
    uint160 public constant ALL_HOOK_FLAGS = uint160((1 << 14) - 1);
    uint32 public constant MAX_CONFIG_BYTES = 4096;
    uint32 public constant KERNEL_WIRING_GAS = 30_000;
    uint32 public constant INTEGRATION_WIRING_GAS = 30_000;
    uint16 public constant MAX_CORRECTION_VOLUME_BPS = 5_000;
    bytes4 private constant POOL_MANAGER_SELECTOR = bytes4(keccak256("poolManager()"));
    bytes4 private constant STACK_REGISTRY_SELECTOR = bytes4(keccak256("stackRegistry()"));
    bytes4 private constant COORDINATOR_SELECTOR = bytes4(keccak256("coordinator()"));
    bytes4 private constant TEMPLATE_KERNEL_ID_SELECTOR = IHookrKernelInstanceFactoryV1.templateKernelId.selector;
    bytes4 private constant TEMPLATE_KERNEL_SELECTOR = IHookrKernelInstanceFactoryV1.templateKernel.selector;
    bytes4 private constant KERNEL_FAMILY_ID_SELECTOR = IHookrKernelInstanceFactoryV1.kernelFamilyId.selector;
    bytes4 private constant KERNEL_VERSION_SELECTOR = IHookrKernelInstanceFactoryV1.kernelVersion.selector;
    bytes4 private constant HOOK_FLAGS_SELECTOR = IHookrKernelInstanceFactoryV1.hookFlags.selector;
    bytes4 private constant INSTANCE_LAYOUT_ID_SELECTOR = IHookrKernelInstanceFactoryV1.instanceLayoutId.selector;
    bytes4 private constant STATEFUL_KERNEL_MAGIC_SELECTOR = bytes4(keccak256("statefulModuleKernelMagic()"));
    bytes32 private constant STATEFUL_MODULE_MAGIC = keccak256("HOOKR_STATEFUL_SWAP_MODULE_V1");
    bytes32 private constant INSTANCE_LAYOUT_ID = keccak256("HOOKR_KERNEL_INSTANCE_LAYOUT_V1");

    enum KernelStatus {
        UNSET,
        ACTIVE,
        RETIRED
    }

    enum IntegrationStatus {
        UNSET,
        ACTIVE,
        RETIRED
    }

    enum KernelInstanceFactoryStatus {
        UNSET,
        ACTIVE,
        RETIRED
    }

    struct KernelRegistration {
        bytes32 kernelFamilyId;
        uint32 version;
        address implementation;
        uint160 hookFlags;
    }

    struct KernelSnapshot {
        bytes32 kernelId;
        bytes32 kernelFamilyId;
        uint32 version;
        address implementation;
        bytes32 implementationCodeHash;
        uint160 hookFlags;
    }

    /// @notice Immutable admission envelope shared by every pool using one root-hook generation.
    struct RootProfileSnapshot {
        bool isSealed;
        bool allowsExceptionalInstances;
        uint8 moduleCount;
        uint32 profileVersion;
        bytes32 profileId;
        bytes32 profileManifestHash;
        bytes32 moduleSetHash;
        bytes32 routerIntegrationId;
        bytes32 quoterIntegrationId;
        bytes32 correctionExecutorIntegrationId;
    }

    struct IntegrationRegistration {
        bytes32 integrationKind;
        bytes32 integrationFamilyId;
        uint32 version;
        address implementation;
    }

    struct IntegrationSnapshot {
        bytes32 integrationId;
        bytes32 integrationKind;
        bytes32 integrationFamilyId;
        uint32 version;
        address implementation;
        bytes32 implementationCodeHash;
    }

    struct KernelInstanceFactorySnapshot {
        address factory;
        bytes32 factoryCodeHash;
        bytes32 templateKernelId;
    }

    address public owner;
    address public pendingOwner;
    address public coordinator;
    IPoolManager public immutable poolManager;
    HookrModuleCatalogV1 public immutable moduleCatalog;

    mapping(bytes32 kernelId => KernelSnapshot snapshot) private _kernels;
    mapping(bytes32 kernelId => KernelStatus status) public kernelStatus;
    bytes32[] private _kernelIds;

    mapping(bytes32 rootKernelId => RootProfileSnapshot profile) private _rootProfiles;
    mapping(bytes32 kernelId => bytes32 rootKernelId) private _rootProfileSource;
    mapping(bytes32 rootKernelId => bytes32[] moduleIds) private _rootProfileModuleIds;
    mapping(bytes32 rootKernelId => mapping(bytes32 moduleId => bool allowed)) private _rootProfileModuleAllowed;
    mapping(bytes32 profileKey => bytes32 rootKernelId) private _rootKernelForProfileKey;

    mapping(address factory => KernelInstanceFactorySnapshot snapshot) private _kernelInstanceFactories;
    mapping(address factory => KernelInstanceFactoryStatus status) public kernelInstanceFactoryStatus;
    mapping(bytes32 kernelId => address factory) private _kernelInstanceFactoryFor;

    mapping(bytes32 integrationId => IntegrationSnapshot snapshot) private _integrations;
    mapping(bytes32 integrationId => IntegrationStatus status) public integrationStatus;
    mapping(address implementation => bytes32 integrationId) public integrationIdFor;
    bytes32[] private _integrationIds;

    mapping(PoolId poolId => HookrModuleTypesV1.StackCore core) private _stacks;
    mapping(PoolId poolId => HookrModuleTypesV1.ModuleSnapshot[] modules) private _stackModules;
    mapping(PoolId poolId => bytes[] configs) private _stackConfigs;
    mapping(PoolId poolId => mapping(address implementation => bytes32 configHash)) private _frozenModuleConfigHashes;
    PoolId[] private _poolIds;

    // Stable roots have one permanent identity per implementation, including after retirement.
    // Legacy registries retain their historical kernel/exceptional-instance registration semantics.
    mapping(address implementation => bytes32 kernelId) private _stableRootKernelIdForImplementation;

    event OwnerProposed(address indexed pendingOwner);
    event OwnerSet(address indexed owner);
    event CoordinatorSet(address indexed coordinator);
    event KernelRegistered(
        bytes32 indexed kernelId,
        bytes32 indexed kernelFamilyId,
        uint32 indexed version,
        address implementation,
        bytes32 implementationCodeHash,
        uint160 hookFlags
    );
    event KernelRetired(bytes32 indexed kernelId);
    event RootProfileSealed(
        bytes32 indexed kernelId,
        bytes32 indexed profileId,
        uint32 indexed profileVersion,
        bytes32 profileManifestHash,
        bytes32 moduleSetHash,
        bytes32 routerIntegrationId,
        bytes32 quoterIntegrationId,
        bytes32 correctionExecutorIntegrationId,
        bool allowsExceptionalInstances
    );
    event ExceptionalKernelInstanceRegistered(
        bytes32 indexed kernelId,
        bytes32 indexed rootKernelId,
        address indexed implementation,
        bytes32 profileManifestHash
    );
    event KernelInstanceFactoryRegistered(
        address indexed factory, bytes32 indexed templateKernelId, bytes32 factoryCodeHash
    );
    event KernelInstanceFactoryRetired(address indexed factory, bytes32 indexed templateKernelId);
    event KernelInstanceRegistered(
        bytes32 indexed kernelId, bytes32 indexed templateKernelId, address indexed factory, address implementation
    );
    event IntegrationRegistered(
        bytes32 indexed integrationId,
        bytes32 indexed integrationKind,
        bytes32 indexed integrationFamilyId,
        uint32 version,
        address implementation,
        bytes32 implementationCodeHash
    );
    event IntegrationRetired(bytes32 indexed integrationId);
    event StackConfigured(
        PoolId indexed poolId,
        bytes32 indexed stackHash,
        bytes32 indexed kernelId,
        address subject,
        address quote,
        uint8 moduleCount
    );
    event StackInitialized(PoolId indexed poolId, bytes32 indexed stackHash, address indexed kernel);

    error NotOwner();
    error NotPendingOwner();
    error NotCoordinator();
    error NotStackKernel(address expected, address actual);
    error ZeroAddress();
    error CoordinatorAlreadySet();
    error InvalidKernel();
    error CoordinatorNotSet();
    error KernelPoolManagerMismatch();
    error KernelStackRegistryMismatch();
    error KernelCoordinatorMismatch();
    error InvalidHookFlags(uint160 expected, uint160 actual);
    error InvalidHookFlagDependencies();
    error KernelAlreadyExists(bytes32 kernelId);
    error RootImplementationAlreadyRegistered(address implementation, bytes32 kernelId);
    error UnknownKernel(bytes32 kernelId);
    error KernelNotActive(bytes32 kernelId);
    error KernelAlreadyRetired(bytes32 kernelId);
    error KernelCodeChanged(bytes32 expected, bytes32 actual);
    error StableRootProfilesRequired();
    error RootProfileAlreadySealed(bytes32 kernelId);
    error RootProfileNotSealed(bytes32 kernelId);
    error InvalidRootProfile();
    error RootProfileIdentityAlreadyUsed(bytes32 profileId, uint32 profileVersion, bytes32 kernelId);
    error NonCanonicalProfileModuleOrder(bytes32 previousModuleId, bytes32 moduleId);
    error ModuleOutsideRootProfile(bytes32 kernelId, bytes32 moduleId);
    error IntegrationOutsideRootProfile(bytes32 kernelId, bytes32 integrationId);
    error ExceptionalKernelInstancesDisabled(bytes32 kernelId);
    error InvalidKernelInstanceFactory();
    error KernelInstanceFactoryAlreadyExists(address factory);
    error UnknownKernelInstanceFactory(address factory);
    error KernelInstanceFactoryNotActive(address factory);
    error KernelInstanceFactoryAlreadyRetired(address factory);
    error KernelInstanceFactoryCodeChanged(address factory, bytes32 expected, bytes32 actual);
    error InvalidKernelInstance(address implementation);
    error InvalidIntegration();
    error IntegrationAlreadyExists(bytes32 integrationId);
    error IntegrationImplementationAlreadyRegistered(address implementation, bytes32 integrationId);
    error UnknownIntegration(bytes32 integrationId);
    error IntegrationNotActive(bytes32 integrationId);
    error IntegrationAlreadyRetired(bytes32 integrationId);
    error IntegrationMetadataMismatch(address implementation);
    error IntegrationPoolManagerMismatch(address implementation);
    error IntegrationStackRegistryMismatch(address implementation);
    error UnregisteredIntegration(address implementation);
    error IntegrationKindMismatch(address implementation, bytes32 expected, bytes32 actual);
    error IntegrationFamilyMismatch(address implementation, bytes32 expected, bytes32 actual);
    error IntegrationCodeChanged(address implementation, bytes32 expected, bytes32 actual);
    error InvalidPoolKey();
    error InvalidCurrencyPair();
    error InvalidIntegrationWiring();
    error StackAlreadyConfigured(PoolId poolId);
    error UnknownStack(PoolId poolId);
    error StackAlreadyInitialized(PoolId poolId);
    error TooManyModules();
    error ConfigTooLarge(bytes32 moduleId);
    error DuplicateModule(bytes32 moduleKey);
    error DuplicateModuleImplementation(address implementation);
    error ExclusiveGroupConflict(bytes32 exclusiveGroup);
    error MissingDependency(bytes32 moduleKey, bytes32 requiredModuleKey);
    error ModuleConflict(bytes32 moduleKey, bytes32 conflictingModuleKey);
    error ModuleCodeChanged(bytes32 moduleId, bytes32 expected, bytes32 actual);
    error ModuleMetadataMismatch(bytes32 moduleId);
    error InvalidModuleConfig(bytes32 moduleId);
    error InvalidModuleStackBinding(bytes32 moduleId);
    error ModuleConfigCapsExceedSnapshot(bytes32 moduleId);
    error UnsupportedHookFlags(bytes32 moduleId, uint160 required, uint160 available);
    error InvalidStackLimits();
    error ModuleCapsExceedStackLimits();
    error ModuleGasExceedsStackLimit();

    constructor(address owner_, IPoolManager poolManager_, HookrModuleCatalogV1 moduleCatalog_) {
        if (
            owner_ == address(0) || address(poolManager_) == address(0) || address(poolManager_).code.length == 0
                || address(moduleCatalog_) == address(0) || address(moduleCatalog_).code.length == 0
        ) {
            revert ZeroAddress();
        }
        owner = owner_;
        poolManager = poolManager_;
        moduleCatalog = moduleCatalog_;
        emit OwnerSet(owner_);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyCoordinator() {
        if (msg.sender != coordinator) revert NotCoordinator();
        _;
    }

    function contractName() external pure virtual returns (string memory) {
        return "HookrStackRegistryV1";
    }

    function contractVersion() external pure virtual returns (string memory) {
        return "1.3.0";
    }

    /// @notice True when future stacks must belong to a sealed shared-root profile.
    function stableRootProfilesRequired() public pure virtual returns (bool) {
        return false;
    }

    /// @notice True when the registry admits per-market kernel instances from a reviewed factory.
    function exceptionalKernelInstancesSupported() public pure virtual returns (bool) {
        return true;
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

    /// @notice Freezes the only coordinator permitted to prepare stacks.
    function setCoordinatorOnce(address coordinator_) external onlyOwner {
        if (coordinator != address(0)) revert CoordinatorAlreadySet();
        if (coordinator_ == address(0) || coordinator_.code.length == 0) revert ZeroAddress();
        coordinator = coordinator_;
        emit CoordinatorSet(coordinator_);
    }

    /// @notice Admits one immutable router or quoter runtime for future stacks.
    /// @dev The owner must admit only reviewed, non-proxy implementations. A runtime codehash cannot
    ///      pin mutable implementation state behind a delegate proxy.
    function registerIntegration(IntegrationRegistration calldata registration)
        external
        onlyOwner
        returns (bytes32 integrationId)
    {
        _validateIntegrationRegistration(registration);
        bytes32 existingId = integrationIdFor[registration.implementation];
        if (existingId != bytes32(0)) {
            revert IntegrationImplementationAlreadyRegistered(registration.implementation, existingId);
        }

        bytes32 implementationCodeHash = registration.implementation.codehash;
        integrationId = computeIntegrationId(registration, implementationCodeHash);
        if (_integrations[integrationId].integrationId != bytes32(0)) {
            revert IntegrationAlreadyExists(integrationId);
        }

        _integrations[integrationId] = IntegrationSnapshot({
            integrationId: integrationId,
            integrationKind: registration.integrationKind,
            integrationFamilyId: registration.integrationFamilyId,
            version: registration.version,
            implementation: registration.implementation,
            implementationCodeHash: implementationCodeHash
        });
        integrationStatus[integrationId] = IntegrationStatus.ACTIVE;
        integrationIdFor[registration.implementation] = integrationId;
        _integrationIds.push(integrationId);
        emit IntegrationRegistered(
            integrationId,
            registration.integrationKind,
            registration.integrationFamilyId,
            registration.version,
            registration.implementation,
            implementationCodeHash
        );
    }

    /// @notice Retires an integration for future stack creation without mutating frozen stacks.
    function retireIntegration(bytes32 integrationId) external onlyOwner {
        IntegrationStatus status = integrationStatus[integrationId];
        if (status == IntegrationStatus.UNSET) revert UnknownIntegration(integrationId);
        if (status == IntegrationStatus.RETIRED) revert IntegrationAlreadyRetired(integrationId);
        integrationStatus[integrationId] = IntegrationStatus.RETIRED;
        emit IntegrationRetired(integrationId);
    }

    function registerKernel(KernelRegistration calldata registration) external onlyOwner returns (bytes32 kernelId) {
        return _registerKernel(registration);
    }

    /// @notice Seals the admission envelope shared by every pool using one reviewed root hook.
    /// @dev Module and integration identifiers include their implementation codehashes. Once sealed,
    ///      the profile cannot admit another implementation or change its exceptional-instance policy.
    function sealRootProfile(
        bytes32 kernelId,
        bytes32 profileId,
        uint32 profileVersion,
        bytes32[] calldata moduleIds,
        bytes32 routerIntegrationId,
        bytes32 quoterIntegrationId,
        bytes32 correctionExecutorIntegrationId,
        bool allowsExceptionalInstances
    ) external onlyOwner returns (bytes32 profileManifestHash) {
        if (!stableRootProfilesRequired()) revert StableRootProfilesRequired();
        if (allowsExceptionalInstances && !exceptionalKernelInstancesSupported()) {
            revert ExceptionalKernelInstancesDisabled(kernelId);
        }
        if (profileId == bytes32(0) || profileVersion == 0 || moduleIds.length > HookrModuleTypesV1.MAX_MODULES) {
            revert InvalidRootProfile();
        }
        if (_rootProfileSource[kernelId] != bytes32(0) || _kernelInstanceFactoryFor[kernelId] != address(0)) {
            revert RootProfileAlreadySealed(kernelId);
        }

        KernelSnapshot memory kernel_ = _activeKernel(kernelId);
        bytes32 profileKey = keccak256(abi.encode(profileId, profileVersion));
        bytes32 existingKernelId = _rootKernelForProfileKey[profileKey];
        if (existingKernelId != bytes32(0)) {
            revert RootProfileIdentityAlreadyUsed(profileId, profileVersion, existingKernelId);
        }

        IntegrationSnapshot memory router =
            _activeIntegrationForId(routerIntegrationId, ROUTER_INTEGRATION_KIND, kernel_.kernelFamilyId);
        IntegrationSnapshot memory quoter =
            _activeIntegrationForId(quoterIntegrationId, QUOTER_INTEGRATION_KIND, kernel_.kernelFamilyId);
        IntegrationSnapshot memory correction;
        if (correctionExecutorIntegrationId != bytes32(0)) {
            correction = _activeIntegrationForId(
                correctionExecutorIntegrationId, CORRECTION_EXECUTOR_INTEGRATION_KIND, kernel_.kernelFamilyId
            );
        }

        bytes32 moduleSetHash = keccak256(abi.encode(ROOT_PROFILE_MODULES_DOMAIN));
        bytes32 previousModuleId;
        for (uint256 i; i < moduleIds.length; ++i) {
            bytes32 moduleId = moduleIds[i];
            if (moduleId == bytes32(0) || (i != 0 && moduleId <= previousModuleId)) {
                revert NonCanonicalProfileModuleOrder(previousModuleId, moduleId);
            }
            HookrModuleTypesV1.ModuleSnapshot memory module_ = moduleCatalog.activeModule(moduleId);
            bytes32 actualCodeHash = module_.implementation.codehash;
            if (actualCodeHash != module_.implementationCodeHash) {
                revert ModuleCodeChanged(moduleId, module_.implementationCodeHash, actualCodeHash);
            }
            // moduleId already commits to the implementation codehash in HookrModuleCatalogV1.
            moduleSetHash = keccak256(abi.encode(moduleSetHash, moduleId));
            previousModuleId = moduleId;
        }

        profileManifestHash = _computeRootProfileManifestHash(
            kernel_.kernelId,
            profileId,
            profileVersion,
            moduleSetHash,
            router.integrationId,
            quoter.integrationId,
            correction.integrationId,
            allowsExceptionalInstances
        );
        _rootProfiles[kernelId] = RootProfileSnapshot({
            isSealed: true,
            allowsExceptionalInstances: allowsExceptionalInstances,
            moduleCount: uint8(moduleIds.length),
            profileVersion: profileVersion,
            profileId: profileId,
            profileManifestHash: profileManifestHash,
            moduleSetHash: moduleSetHash,
            routerIntegrationId: routerIntegrationId,
            quoterIntegrationId: quoterIntegrationId,
            correctionExecutorIntegrationId: correctionExecutorIntegrationId
        });
        _rootProfileSource[kernelId] = kernelId;
        _rootKernelForProfileKey[profileKey] = kernelId;
        for (uint256 i; i < moduleIds.length; ++i) {
            bytes32 moduleId = moduleIds[i];
            _rootProfileModuleIds[kernelId].push(moduleId);
            _rootProfileModuleAllowed[kernelId][moduleId] = true;
        }

        emit RootProfileSealed(
            kernelId,
            profileId,
            profileVersion,
            profileManifestHash,
            moduleSetHash,
            routerIntegrationId,
            quoterIntegrationId,
            correctionExecutorIntegrationId,
            allowsExceptionalInstances
        );
    }

    /// @notice Admits a reviewed factory for permissionless instances of one active kernel.
    /// @dev Factory retirement or template retirement only prevents future instance creation.
    function registerKernelInstanceFactory(address factory) external virtual onlyOwner {
        if (factory == address(0) || factory.code.length == 0) revert InvalidKernelInstanceFactory();
        if (kernelInstanceFactoryStatus[factory] != KernelInstanceFactoryStatus.UNSET) {
            revert KernelInstanceFactoryAlreadyExists(factory);
        }

        (bool templateIdOk, uint256 rawTemplateKernelId) =
            _readBoundedWord(factory, TEMPLATE_KERNEL_ID_SELECTOR, KERNEL_WIRING_GAS);
        if (!templateIdOk) revert InvalidKernelInstanceFactory();
        bytes32 templateKernelId = bytes32(rawTemplateKernelId);
        KernelSnapshot memory template = _activeKernel(templateKernelId);
        if (stableRootProfilesRequired()) {
            bytes32 rootKernelId = _rootProfileSource[templateKernelId];
            if (rootKernelId == bytes32(0)) revert RootProfileNotSealed(templateKernelId);
            RootProfileSnapshot storage profile = _rootProfiles[rootKernelId];
            if (!profile.allowsExceptionalInstances) revert ExceptionalKernelInstancesDisabled(rootKernelId);
        }
        (bool registryOk, address reportedRegistry) =
            _readBoundedAddress(factory, STACK_REGISTRY_SELECTOR, KERNEL_WIRING_GAS);
        (bool templateOk, address reportedTemplate) =
            _readBoundedAddress(factory, TEMPLATE_KERNEL_SELECTOR, KERNEL_WIRING_GAS);
        (bool familyOk, uint256 reportedFamily) =
            _readBoundedWord(factory, KERNEL_FAMILY_ID_SELECTOR, KERNEL_WIRING_GAS);
        (bool versionOk, uint256 reportedVersion) =
            _readBoundedWord(factory, KERNEL_VERSION_SELECTOR, KERNEL_WIRING_GAS);
        (bool flagsOk, uint256 reportedFlags) = _readBoundedWord(factory, HOOK_FLAGS_SELECTOR, KERNEL_WIRING_GAS);
        (bool layoutOk, uint256 reportedLayout) =
            _readBoundedWord(factory, INSTANCE_LAYOUT_ID_SELECTOR, KERNEL_WIRING_GAS);
        (bool templateLayoutOk, uint256 reportedTemplateLayout) = _readBoundedWord(
            template.implementation, IHookrKernelInstanceLayoutV1.kernelInstanceLayoutId.selector, KERNEL_WIRING_GAS
        );
        if (
            !registryOk || reportedRegistry != address(this) || !templateOk
                || reportedTemplate != template.implementation || !familyOk
                || bytes32(reportedFamily) != template.kernelFamilyId || !versionOk
                || reportedVersion > type(uint32).max || reportedVersion != template.version || !flagsOk
                || reportedFlags > type(uint160).max || reportedFlags != template.hookFlags || !layoutOk
                || bytes32(reportedLayout) != SUPPORTED_KERNEL_INSTANCE_LAYOUT_ID || !templateLayoutOk
                || bytes32(reportedTemplateLayout) != SUPPORTED_KERNEL_INSTANCE_LAYOUT_ID
        ) revert InvalidKernelInstanceFactory();

        bytes32 factoryCodeHash = factory.codehash;
        _kernelInstanceFactories[factory] = KernelInstanceFactorySnapshot({
            factory: factory, factoryCodeHash: factoryCodeHash, templateKernelId: templateKernelId
        });
        kernelInstanceFactoryStatus[factory] = KernelInstanceFactoryStatus.ACTIVE;
        emit KernelInstanceFactoryRegistered(factory, templateKernelId, factoryCodeHash);
    }

    /// @notice Retires a factory for future instances without changing previously admitted kernels.
    function retireKernelInstanceFactory(address factory) external virtual onlyOwner {
        KernelInstanceFactoryStatus status = kernelInstanceFactoryStatus[factory];
        if (status == KernelInstanceFactoryStatus.UNSET) revert UnknownKernelInstanceFactory(factory);
        if (status == KernelInstanceFactoryStatus.RETIRED) revert KernelInstanceFactoryAlreadyRetired(factory);
        kernelInstanceFactoryStatus[factory] = KernelInstanceFactoryStatus.RETIRED;
        emit KernelInstanceFactoryRetired(factory, _kernelInstanceFactories[factory].templateKernelId);
    }

    function kernelInstanceFactory(address factory)
        external
        view
        virtual
        returns (KernelInstanceFactorySnapshot memory snapshot)
    {
        snapshot = _kernelInstanceFactories[factory];
        if (snapshot.factory == address(0)) revert UnknownKernelInstanceFactory(factory);
    }

    /// @notice Returns the reviewed factory that created a kernel, or zero for a direct kernel.
    /// @dev Factory retirement does not invalidate reservations for instances already registered.
    function kernelInstanceFactoryFor(bytes32 kernelId) external view virtual returns (address factory) {
        factory = _kernelInstanceFactoryFor[kernelId];
        if (factory == address(0)) return address(0);
        KernelInstanceFactorySnapshot memory snapshot = _kernelInstanceFactories[factory];
        bytes32 actualFactoryCodeHash = factory.codehash;
        if (actualFactoryCodeHash != snapshot.factoryCodeHash) {
            revert KernelInstanceFactoryCodeChanged(factory, snapshot.factoryCodeHash, actualFactoryCodeHash);
        }
    }

    /// @notice Registers one factory-created hook address under a distinct kernel id.
    function registerKernelInstance(address implementation) external virtual returns (bytes32 kernelId) {
        KernelInstanceFactorySnapshot memory factory = _kernelInstanceFactories[msg.sender];
        if (kernelInstanceFactoryStatus[msg.sender] != KernelInstanceFactoryStatus.ACTIVE) {
            revert KernelInstanceFactoryNotActive(msg.sender);
        }
        bytes32 actualFactoryCodeHash = msg.sender.codehash;
        if (actualFactoryCodeHash != factory.factoryCodeHash) {
            revert KernelInstanceFactoryCodeChanged(msg.sender, factory.factoryCodeHash, actualFactoryCodeHash);
        }

        KernelSnapshot memory template = _activeKernel(factory.templateKernelId);
        (bool factoryOk, address reportedFactory) =
            _readBoundedAddress(implementation, IHookrKernelInstanceV1.factory.selector, KERNEL_WIRING_GAS);
        (bool implementationOk, address reportedImplementation) =
            _readBoundedAddress(implementation, IHookrKernelInstanceV1.implementation.selector, KERNEL_WIRING_GAS);
        (bool codeHashOk, uint256 reportedCodeHash) =
            _readBoundedWord(implementation, IHookrKernelInstanceV1.implementationCodeHash.selector, KERNEL_WIRING_GAS);
        (bool attested, uint256 isInstance) = _readBoundedWordWithInput(
            msg.sender, abi.encodeCall(IHookrKernelInstanceFactoryV1.isInstance, (implementation)), KERNEL_WIRING_GAS
        );
        if (
            implementation == address(0) || implementation.code.length == 0 || !factoryOk
                || reportedFactory != msg.sender || !implementationOk
                || reportedImplementation != template.implementation || !codeHashOk
                || bytes32(reportedCodeHash) != template.implementationCodeHash || !attested || isInstance != 1
        ) revert InvalidKernelInstance(implementation);

        KernelRegistration memory registration = KernelRegistration({
            kernelFamilyId: template.kernelFamilyId,
            version: template.version,
            implementation: implementation,
            hookFlags: template.hookFlags
        });
        kernelId = _registerKernel(registration);
        _kernelInstanceFactoryFor[kernelId] = msg.sender;
        emit KernelInstanceRegistered(kernelId, factory.templateKernelId, msg.sender, implementation);
        if (stableRootProfilesRequired()) {
            bytes32 rootKernelId = _rootProfileSource[factory.templateKernelId];
            if (rootKernelId == bytes32(0)) revert RootProfileNotSealed(factory.templateKernelId);
            RootProfileSnapshot storage profile = _rootProfiles[rootKernelId];
            if (!profile.allowsExceptionalInstances) revert ExceptionalKernelInstancesDisabled(rootKernelId);
            _rootProfileSource[kernelId] = rootKernelId;
            emit ExceptionalKernelInstanceRegistered(
                kernelId, rootKernelId, implementation, profile.profileManifestHash
            );
        }
    }

    function _registerKernel(KernelRegistration memory registration) internal returns (bytes32 kernelId) {
        _validateKernelRegistration(registration);
        bytes32 implementationCodeHash = registration.implementation.codehash;
        kernelId = _computeKernelId(registration, implementationCodeHash);
        if (_kernels[kernelId].kernelId != bytes32(0)) revert KernelAlreadyExists(kernelId);
        if (stableRootProfilesRequired()) {
            bytes32 originalKernelId = _stableRootKernelIdForImplementation[registration.implementation];
            if (originalKernelId != bytes32(0)) {
                revert RootImplementationAlreadyRegistered(registration.implementation, originalKernelId);
            }
            _stableRootKernelIdForImplementation[registration.implementation] = kernelId;
        }

        _kernels[kernelId] = KernelSnapshot({
            kernelId: kernelId,
            kernelFamilyId: registration.kernelFamilyId,
            version: registration.version,
            implementation: registration.implementation,
            implementationCodeHash: implementationCodeHash,
            hookFlags: registration.hookFlags
        });
        kernelStatus[kernelId] = KernelStatus.ACTIVE;
        _kernelIds.push(kernelId);
        emit KernelRegistered(
            kernelId,
            registration.kernelFamilyId,
            registration.version,
            registration.implementation,
            implementationCodeHash,
            registration.hookFlags
        );
    }

    function retireKernel(bytes32 kernelId) external onlyOwner {
        KernelStatus status = kernelStatus[kernelId];
        if (status == KernelStatus.UNSET) revert UnknownKernel(kernelId);
        if (status == KernelStatus.RETIRED) revert KernelAlreadyRetired(kernelId);
        kernelStatus[kernelId] = KernelStatus.RETIRED;
        emit KernelRetired(kernelId);
    }

    /// @notice Validates and freezes a pool's complete execution graph before initialization.
    function createStack(
        PoolKey calldata key,
        address subject,
        address quote,
        bytes32 kernelId,
        HookrModuleTypesV1.ModuleSelection[] calldata selections,
        HookrModuleTypesV1.StackLimits calldata limits
    ) external onlyCoordinator returns (PoolId poolId, bytes32 stackHash) {
        KernelSnapshot memory kernel_ = _activeKernel(kernelId);
        _validatePool(key, subject, quote, kernel_);
        _validateLimits(key, subject, quote, limits);
        IntegrationSnapshot memory routerIntegration =
            _activeIntegrationFor(limits.trustedRouter, ROUTER_INTEGRATION_KIND, kernel_.kernelFamilyId);
        IntegrationSnapshot memory quoterIntegration =
            _activeIntegrationFor(limits.trustedQuoter, QUOTER_INTEGRATION_KIND, kernel_.kernelFamilyId);
        IntegrationSnapshot memory correctionIntegration;
        if (limits.correctionExecutor != address(0)) {
            correctionIntegration = _activeIntegrationFor(
                limits.correctionExecutor, CORRECTION_EXECUTOR_INTEGRATION_KIND, kernel_.kernelFamilyId
            );
        }
        bytes32 rootKernelId = _rootProfileSource[kernelId];
        bytes32 profileManifestHash;
        if (stableRootProfilesRequired()) {
            if (rootKernelId == bytes32(0)) revert RootProfileNotSealed(kernelId);
            RootProfileSnapshot storage profile = _rootProfiles[rootKernelId];
            profileManifestHash = profile.profileManifestHash;
            if (routerIntegration.integrationId != profile.routerIntegrationId) {
                revert IntegrationOutsideRootProfile(rootKernelId, routerIntegration.integrationId);
            }
            if (quoterIntegration.integrationId != profile.quoterIntegrationId) {
                revert IntegrationOutsideRootProfile(rootKernelId, quoterIntegration.integrationId);
            }
            if (
                correctionIntegration.integrationId != bytes32(0)
                    && correctionIntegration.integrationId != profile.correctionExecutorIntegrationId
            ) {
                revert IntegrationOutsideRootProfile(rootKernelId, correctionIntegration.integrationId);
            }
        }
        if (selections.length > HookrModuleTypesV1.MAX_MODULES) revert TooManyModules();

        poolId = key.toId();
        if (_stacks[poolId].configured) revert StackAlreadyConfigured(poolId);

        (
            HookrModuleTypesV1.ModuleSnapshot[] memory snapshots,
            bytes32 modulesHash,
            uint256 lpFeeSurchargePips,
            uint256 specifiedQuoteTakeBps,
            uint256 unspecifiedQuoteTakeBps,
            uint256 subjectTakeBps,
            uint256 totalModuleGas
        ) = _validateModules(poolId, kernel_, rootKernelId, subject, quote, selections);

        if (
            uint256(limits.baseLpFeePips) + lpFeeSurchargePips > limits.maxLpFeePips
                || specifiedQuoteTakeBps > limits.maxSpecifiedQuoteTakeBps
                || unspecifiedQuoteTakeBps > limits.maxUnspecifiedQuoteTakeBps
                || subjectTakeBps > limits.maxSubjectTakeBps
        ) revert ModuleCapsExceedStackLimits();
        if (totalModuleGas > limits.maxTotalModuleGas) revert ModuleGasExceedsStackLimit();
        if (subjectTakeBps > 1_000) revert ModuleCapsExceedStackLimits();

        if (stableRootProfilesRequired()) {
            stackHash = keccak256(
                abi.encode(
                    STABLE_ROOT_STACK_ID_DOMAIN,
                    PoolId.unwrap(poolId),
                    rootKernelId,
                    profileManifestHash,
                    subject,
                    quote,
                    modulesHash,
                    routerIntegration.integrationId,
                    quoterIntegration.integrationId,
                    correctionIntegration.integrationId,
                    keccak256(abi.encode(limits))
                )
            );
        } else {
            stackHash = keccak256(
                abi.encode(
                    STACK_ID_DOMAIN,
                    block.chainid,
                    address(this),
                    PoolId.unwrap(poolId),
                    kernel_.kernelId,
                    kernel_.implementationCodeHash,
                    subject,
                    quote,
                    modulesHash,
                    routerIntegration.integrationId,
                    routerIntegration.implementationCodeHash,
                    quoterIntegration.integrationId,
                    quoterIntegration.implementationCodeHash,
                    correctionIntegration.integrationId,
                    correctionIntegration.implementationCodeHash,
                    keccak256(abi.encode(limits))
                )
            );
        }

        HookrModuleTypesV1.StackCore storage core = _stacks[poolId];
        core.configured = true;
        core.kernel = kernel_.implementation;
        core.kernelId = kernel_.kernelId;
        core.kernelFamilyId = kernel_.kernelFamilyId;
        core.kernelCodeHash = kernel_.implementationCodeHash;
        core.subject = subject;
        core.quote = quote;
        core.stackHash = stackHash;
        core.trustedRouterIntegrationId = routerIntegration.integrationId;
        core.trustedRouterCodeHash = routerIntegration.implementationCodeHash;
        core.trustedQuoterIntegrationId = quoterIntegration.integrationId;
        core.trustedQuoterCodeHash = quoterIntegration.implementationCodeHash;
        core.correctionExecutorIntegrationId = correctionIntegration.integrationId;
        core.correctionExecutorCodeHash = correctionIntegration.implementationCodeHash;
        // Safe because the length is checked against the uint8 constant MAX_MODULES.
        // forge-lint: disable-next-line(unsafe-typecast)
        core.moduleCount = uint8(selections.length);
        core.limits = limits;

        for (uint256 i; i < selections.length; ++i) {
            _stackModules[poolId].push(snapshots[i]);
            _stackConfigs[poolId].push(selections[i].config);
            _frozenModuleConfigHashes[poolId][snapshots[i].implementation] = keccak256(selections[i].config);
        }
        _poolIds.push(poolId);

        emit StackConfigured(poolId, stackHash, kernel_.kernelId, subject, quote, core.moduleCount);
    }

    /// @inheritdoc IHookrStackRegistryV1
    function markInitialized(PoolId poolId) external {
        HookrModuleTypesV1.StackCore storage core = _stack(poolId);
        if (msg.sender != core.kernel) revert NotStackKernel(core.kernel, msg.sender);
        bytes32 actualCodeHash = msg.sender.codehash;
        if (actualCodeHash != core.kernelCodeHash) revert KernelCodeChanged(core.kernelCodeHash, actualCodeHash);
        if (core.initialized) revert StackAlreadyInitialized(poolId);
        core.initialized = true;
        emit StackInitialized(poolId, core.stackHash, msg.sender);
    }

    function kernel(bytes32 kernelId) external view returns (KernelSnapshot memory snapshot) {
        snapshot = _kernel(kernelId);
    }

    function activeKernel(bytes32 kernelId) external view returns (KernelSnapshot memory snapshot) {
        snapshot = _activeKernel(kernelId);
    }

    /// @notice Returns the sealed profile inherited by a root hook or one exceptional instance.
    function rootProfile(bytes32 kernelId) external view returns (RootProfileSnapshot memory profile) {
        bytes32 rootKernelId = _rootProfileSource[kernelId];
        if (rootKernelId == bytes32(0)) revert RootProfileNotSealed(kernelId);
        profile = _rootProfiles[rootKernelId];
    }

    /// @notice Returns the direct root kernel for a profiled kernel, or zero when none is sealed.
    function rootProfileSource(bytes32 kernelId) external view returns (bytes32) {
        return _rootProfileSource[kernelId];
    }

    function rootProfileModuleAt(bytes32 kernelId, uint256 index) external view returns (bytes32 moduleId) {
        bytes32 rootKernelId = _rootProfileSource[kernelId];
        if (rootKernelId == bytes32(0)) revert RootProfileNotSealed(kernelId);
        moduleId = _rootProfileModuleIds[rootKernelId][index];
    }

    function isRootProfileModuleAllowed(bytes32 kernelId, bytes32 moduleId) external view returns (bool) {
        bytes32 rootKernelId = _rootProfileSource[kernelId];
        if (rootKernelId == bytes32(0)) return false;
        return _rootProfileModuleAllowed[rootKernelId][moduleId];
    }

    function rootKernelForProfile(bytes32 profileId, uint32 profileVersion) external view returns (bytes32) {
        return _rootKernelForProfileKey[keccak256(abi.encode(profileId, profileVersion))];
    }

    function integration(bytes32 integrationId) external view returns (IntegrationSnapshot memory snapshot) {
        snapshot = _integration(integrationId);
    }

    function activeIntegration(bytes32 integrationId) external view returns (IntegrationSnapshot memory snapshot) {
        snapshot = _activeIntegration(integrationId);
    }

    /// @notice Catalog read-through for coordinator and release tooling.
    function module(bytes32 moduleId) external view returns (HookrModuleTypesV1.ModuleSnapshot memory snapshot) {
        snapshot = moduleCatalog.module(moduleId);
    }

    /// @inheritdoc IHookrStackRegistryV1
    function stack(PoolId poolId) external view returns (HookrModuleTypesV1.StackCore memory core) {
        core = _stack(poolId);
    }

    /// @inheritdoc IHookrStackRegistryV1
    function moduleAt(PoolId poolId, uint256 index)
        external
        view
        returns (HookrModuleTypesV1.ModuleSnapshot memory module_, bytes memory config)
    {
        _stack(poolId);
        module_ = _stackModules[poolId][index];
        config = _stackConfigs[poolId][index];
    }

    /// @notice Returns the exact frozen config hash for one module implementation in a pool stack.
    /// @dev A zero value means the implementation is not part of the frozen stack.
    function frozenModuleConfigHash(PoolId poolId, address implementation) external view returns (bytes32 configHash) {
        _stack(poolId);
        configHash = _frozenModuleConfigHashes[poolId][implementation];
    }

    function kernelCount() external view returns (uint256) {
        return _kernelIds.length;
    }

    function kernelIdAt(uint256 index) external view returns (bytes32) {
        return _kernelIds[index];
    }

    function integrationCount() external view returns (uint256) {
        return _integrationIds.length;
    }

    function integrationIdAt(uint256 index) external view returns (bytes32) {
        return _integrationIds[index];
    }

    function stackCount() external view returns (uint256) {
        return _poolIds.length;
    }

    function poolIdAt(uint256 index) external view returns (PoolId) {
        return _poolIds[index];
    }

    function computeKernelId(KernelRegistration calldata registration, bytes32 implementationCodeHash)
        public
        view
        returns (bytes32)
    {
        return _computeKernelId(registration, implementationCodeHash);
    }

    function _computeKernelId(KernelRegistration memory registration, bytes32 implementationCodeHash)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                KERNEL_ID_DOMAIN,
                block.chainid,
                address(this),
                registration.kernelFamilyId,
                registration.version,
                registration.implementation,
                implementationCodeHash,
                registration.hookFlags
            )
        );
    }

    function computeIntegrationId(IntegrationRegistration calldata registration, bytes32 implementationCodeHash)
        public
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                INTEGRATION_ID_DOMAIN,
                block.chainid,
                address(this),
                registration.integrationKind,
                registration.integrationFamilyId,
                registration.version,
                registration.implementation,
                implementationCodeHash
            )
        );
    }

    function _computeRootProfileManifestHash(
        bytes32 kernelId,
        bytes32 profileId,
        uint32 profileVersion,
        bytes32 moduleSetHash,
        bytes32 routerIntegrationId,
        bytes32 quoterIntegrationId,
        bytes32 correctionExecutorIntegrationId,
        bool allowsExceptionalInstances
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                ROOT_PROFILE_MANIFEST_DOMAIN,
                block.chainid,
                address(this),
                profileId,
                profileVersion,
                kernelId,
                moduleSetHash,
                routerIntegrationId,
                quoterIntegrationId,
                correctionExecutorIntegrationId,
                allowsExceptionalInstances
            )
        );
    }

    function _validateIntegrationRegistration(IntegrationRegistration calldata registration) internal view {
        address implementation = registration.implementation;
        if (
            (registration.integrationKind != ROUTER_INTEGRATION_KIND
                    && registration.integrationKind != QUOTER_INTEGRATION_KIND
                    && registration.integrationKind != CORRECTION_EXECUTOR_INTEGRATION_KIND)
                || registration.integrationFamilyId == bytes32(0) || registration.version == 0
                || implementation == address(0) || implementation.code.length == 0
        ) revert InvalidIntegration();

        (bool kindOk, uint256 reportedKind) =
            _readBoundedWord(implementation, IHookrKernelIntegrationV1.integrationKind.selector, INTEGRATION_WIRING_GAS);
        (bool familyOk, uint256 reportedFamily) = _readBoundedWord(
            implementation, IHookrKernelIntegrationV1.integrationFamilyId.selector, INTEGRATION_WIRING_GAS
        );
        (bool versionOk, uint256 reportedVersion) = _readBoundedWord(
            implementation, IHookrKernelIntegrationV1.integrationVersion.selector, INTEGRATION_WIRING_GAS
        );
        if (
            !kindOk || bytes32(reportedKind) != registration.integrationKind || !familyOk
                || bytes32(reportedFamily) != registration.integrationFamilyId || !versionOk
                || reportedVersion > type(uint32).max || reportedVersion != registration.version
        ) revert IntegrationMetadataMismatch(implementation);

        (bool poolManagerOk, address wiredPoolManager) =
            _readBoundedAddress(implementation, IHookrKernelIntegrationV1.poolManager.selector, INTEGRATION_WIRING_GAS);
        if (!poolManagerOk || wiredPoolManager != address(poolManager)) {
            revert IntegrationPoolManagerMismatch(implementation);
        }
        (bool registryOk, address wiredRegistry) = _readBoundedAddress(
            implementation, IHookrKernelIntegrationV1.stackRegistry.selector, INTEGRATION_WIRING_GAS
        );
        if (!registryOk || wiredRegistry != address(this)) {
            revert IntegrationStackRegistryMismatch(implementation);
        }
    }

    function _validateKernelRegistration(KernelRegistration memory registration) internal view {
        if (coordinator == address(0)) revert CoordinatorNotSet();
        if (
            registration.kernelFamilyId == bytes32(0) || registration.version == 0
                || registration.implementation == address(0) || registration.implementation.code.length == 0
                || registration.hookFlags == 0 || registration.hookFlags & ~ALL_HOOK_FLAGS != 0
        ) revert InvalidKernel();
        uint160 actualFlags = uint160(registration.implementation) & ALL_HOOK_FLAGS;
        if (actualFlags != registration.hookFlags) revert InvalidHookFlags(registration.hookFlags, actualFlags);
        (bool managerOk, address wiredPoolManager) =
            _readKernelAddress(registration.implementation, POOL_MANAGER_SELECTOR);
        if (!managerOk || wiredPoolManager != address(poolManager)) revert KernelPoolManagerMismatch();
        (bool registryOk, address wiredRegistry) =
            _readKernelAddress(registration.implementation, STACK_REGISTRY_SELECTOR);
        if (!registryOk || wiredRegistry != address(this)) revert KernelStackRegistryMismatch();
        (bool coordinatorOk, address wiredCoordinator) =
            _readKernelAddress(registration.implementation, COORDINATOR_SELECTOR);
        if (!coordinatorOk || wiredCoordinator != coordinator) revert KernelCoordinatorMismatch();
        if (
            (registration.hookFlags & (1 << 3) != 0 && registration.hookFlags & (1 << 7) == 0)
                || (registration.hookFlags & (1 << 2) != 0 && registration.hookFlags & (1 << 6) == 0)
                || (registration.hookFlags & (1 << 1) != 0 && registration.hookFlags & (1 << 10) == 0)
                || (registration.hookFlags & 1 != 0 && registration.hookFlags & (1 << 8) == 0)
        ) revert InvalidHookFlagDependencies();
    }

    function _readKernelAddress(address implementation, bytes4 selector)
        internal
        view
        returns (bool valid, address value)
    {
        return _readBoundedAddress(implementation, selector, KERNEL_WIRING_GAS);
    }

    function _readBoundedAddress(address implementation, bytes4 selector, uint256 gasLimit)
        internal
        view
        returns (bool valid, address value)
    {
        (bool success, uint256 raw) = _readBoundedWord(implementation, selector, gasLimit);
        if (!success || raw > type(uint160).max) return (false, address(0));
        // `raw` was bounded to uint160 immediately above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (true, address(uint160(raw)));
    }

    /// @dev Copies exactly one return word and rejects short or oversized return data. This avoids
    ///      allocating dependency-controlled return data during admission.
    function _readBoundedWord(address implementation, bytes4 selector, uint256 gasLimit)
        internal
        view
        returns (bool valid, uint256 word)
    {
        bytes memory input = abi.encodeWithSelector(selector);
        return _readBoundedWordWithInput(implementation, input, gasLimit);
    }

    function _readBoundedWordWithInput(address implementation, bytes memory input, uint256 gasLimit)
        internal
        view
        returns (bool valid, uint256 word)
    {
        assembly ("memory-safe") {
            mstore(0, 0)
            valid := staticcall(gasLimit, implementation, add(input, 0x20), mload(input), 0, 0x20)
            if iszero(eq(returndatasize(), 0x20)) { valid := 0 }
            word := mload(0)
        }
    }

    function _validatePool(PoolKey calldata key, address subject, address quote, KernelSnapshot memory kernel_)
        internal
        view
    {
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        if (
            key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG || address(key.hooks) != kernel_.implementation
                || uint160(currency0) >= uint160(currency1)
        ) revert InvalidPoolKey();
        if (
            subject == quote
                || !((subject == currency0 && quote == currency1) || (subject == currency1 && quote == currency0))
                || subject == address(0) || subject.code.length == 0 || (quote != address(0) && quote.code.length == 0)
        ) revert InvalidCurrencyPair();
    }

    function _validateLimits(
        PoolKey calldata key,
        address subject,
        address quote,
        HookrModuleTypesV1.StackLimits calldata limits
    ) internal view {
        if (
            limits.baseLpFeePips > limits.maxLpFeePips || limits.maxLpFeePips > HookrModuleTypesV1.PIPS
                || limits.maxSpecifiedQuoteTakeBps >= HookrModuleTypesV1.BPS
                || limits.maxUnspecifiedQuoteTakeBps >= HookrModuleTypesV1.BPS || limits.maxSubjectTakeBps > 1_000
        ) revert InvalidStackLimits();
        if (
            limits.trustedRouter == address(0) || limits.trustedRouter.code.length == 0
                || limits.trustedQuoter == address(0) || limits.trustedQuoter.code.length == 0
                || limits.trustedRouter == limits.trustedQuoter
                || (limits.correctionExecutor != address(0) && limits.correctionExecutor.code.length == 0)
        ) revert InvalidIntegrationWiring();

        if (limits.correctionExecutor == address(0)) {
            if (
                limits.correctionCreator != address(0) || limits.correctionMaxVolumeBps != 0
                    || limits.correctionMinProfitQuote != 0 || limits.correctionFeePolicyId != bytes32(0)
            ) revert InvalidStackLimits();
            return;
        }

        // The WTH V2 executor treats currency0 as quote and currency1 as subject. Keep the
        // first modular port native-quote-only rather than silently mispricing a sorted ERC20 pair.
        if (
            quote != address(0) || Currency.unwrap(key.currency0) != quote || Currency.unwrap(key.currency1) != subject
                || limits.correctionCreator == address(0) || limits.correctionMaxVolumeBps == 0
                || limits.correctionMaxVolumeBps > MAX_CORRECTION_VOLUME_BPS || limits.correctionMinProfitQuote == 0
                || limits.correctionFeePolicyId != HookrWthFeePolicyV2.FEE_POLICY_ID
        ) revert InvalidStackLimits();

        (bool policyOk, uint256 reportedPolicy) =
            _readBoundedWord(limits.correctionExecutor, bytes4(keccak256("feePolicyId()")), INTEGRATION_WIRING_GAS);
        if (!policyOk || bytes32(reportedPolicy) != limits.correctionFeePolicyId) {
            revert IntegrationMetadataMismatch(limits.correctionExecutor);
        }
        try IHookrArbExecutorV2(limits.correctionExecutor).routeAdmissionOpen() returns (bool open) {
            if (!open) revert InvalidIntegrationWiring();
        } catch {
            revert InvalidIntegrationWiring();
        }
    }

    function _validateModules(
        PoolId poolId,
        KernelSnapshot memory kernel_,
        bytes32 rootKernelId,
        address subject,
        address quote,
        HookrModuleTypesV1.ModuleSelection[] calldata selections
    )
        internal
        view
        returns (
            HookrModuleTypesV1.ModuleSnapshot[] memory snapshots,
            bytes32 modulesHash,
            uint256 lpFeeSurchargePips,
            uint256 specifiedQuoteTakeBps,
            uint256 unspecifiedQuoteTakeBps,
            uint256 subjectTakeBps,
            uint256 totalModuleGas
        )
    {
        snapshots = new HookrModuleTypesV1.ModuleSnapshot[](selections.length);
        modulesHash = keccak256(abi.encode(STACK_MODULES_DOMAIN));

        for (uint256 i; i < selections.length; ++i) {
            HookrModuleTypesV1.ModuleSelection calldata selection = selections[i];
            if (selection.config.length > MAX_CONFIG_BYTES) revert ConfigTooLarge(selection.moduleId);
            if (stableRootProfilesRequired() && !_rootProfileModuleAllowed[rootKernelId][selection.moduleId]) {
                revert ModuleOutsideRootProfile(rootKernelId, selection.moduleId);
            }
            HookrModuleTypesV1.ModuleSnapshot memory snapshot = moduleCatalog.activeModule(selection.moduleId);
            bytes32 actualCodeHash = snapshot.implementation.codehash;
            if (actualCodeHash != snapshot.implementationCodeHash) {
                revert ModuleCodeChanged(selection.moduleId, snapshot.implementationCodeHash, actualCodeHash);
            }
            if (snapshot.requiredHookFlags & ~kernel_.hookFlags != 0) {
                revert UnsupportedHookFlags(selection.moduleId, snapshot.requiredHookFlags, kernel_.hookFlags);
            }
            HookrModuleTypesV1.ModuleConfigCaps memory configCaps = _validateModuleMetadataAndConfig(
                snapshot, poolId, kernel_.implementation, subject, quote, selection.config
            );
            if (snapshot.executionMode == HookrModuleTypesV1.ExecutionMode.STATEFUL_V1) {
                (bool magicOk, uint256 magic) =
                    _readBoundedWord(kernel_.implementation, STATEFUL_KERNEL_MAGIC_SELECTOR, KERNEL_WIRING_GAS);
                (bool layoutOk, uint256 layout) = _readBoundedWord(
                    kernel_.implementation,
                    IHookrKernelInstanceLayoutV1.kernelInstanceLayoutId.selector,
                    KERNEL_WIRING_GAS
                );
                if (
                    !magicOk || bytes32(magic) != STATEFUL_MODULE_MAGIC || !layoutOk
                        || bytes32(layout) != INSTANCE_LAYOUT_ID
                ) {
                    revert InvalidModuleStackBinding(snapshot.moduleId);
                }
            }

            // Freeze the concrete config's admitted bounds into the per-pool snapshot. The
            // catalog values are implementation-wide ceilings; the kernel must enforce the
            // tighter values returned for this exact config on every callback.
            snapshot.maxLpFeeSurchargePips = configCaps.maxLpFeeSurchargePips;
            snapshot.maxSpecifiedQuoteTakeBps = configCaps.maxSpecifiedQuoteTakeBps;
            snapshot.maxUnspecifiedQuoteTakeBps = configCaps.maxUnspecifiedQuoteTakeBps;
            snapshot.maxSubjectTakeBps = configCaps.maxSubjectTakeBps;

            for (uint256 j; j < i; ++j) {
                if (snapshots[j].implementation == snapshot.implementation) {
                    revert DuplicateModuleImplementation(snapshot.implementation);
                }
                if (snapshots[j].moduleKey == snapshot.moduleKey) revert DuplicateModule(snapshot.moduleKey);
                if (snapshot.exclusiveGroup != bytes32(0) && snapshots[j].exclusiveGroup == snapshot.exclusiveGroup) {
                    revert ExclusiveGroupConflict(snapshot.exclusiveGroup);
                }
            }

            snapshots[i] = snapshot;
            modulesHash = keccak256(
                abi.encode(
                    modulesHash,
                    snapshot.moduleId,
                    keccak256(selection.config),
                    snapshot.executionMode,
                    snapshot.maxLpFeeSurchargePips,
                    snapshot.maxSpecifiedQuoteTakeBps,
                    snapshot.maxUnspecifiedQuoteTakeBps,
                    snapshot.maxSubjectTakeBps
                )
            );
            lpFeeSurchargePips += configCaps.maxLpFeeSurchargePips;
            specifiedQuoteTakeBps += configCaps.maxSpecifiedQuoteTakeBps;
            unspecifiedQuoteTakeBps += configCaps.maxUnspecifiedQuoteTakeBps;
            subjectTakeBps += configCaps.maxSubjectTakeBps;
            totalModuleGas += snapshot.callbackGasLimit;
        }

        _validateRelations(snapshots);
    }

    function _validateModuleMetadataAndConfig(
        HookrModuleTypesV1.ModuleSnapshot memory snapshot,
        PoolId poolId,
        address kernelAddress,
        address subject,
        address quote,
        bytes calldata config
    ) internal view returns (HookrModuleTypesV1.ModuleConfigCaps memory configCaps) {
        (bool keyOk, bytes memory keyData) = _staticcallExact(
            snapshot.implementation, snapshot.callbackGasLimit, abi.encodeCall(IHookrModuleV1.moduleKey, ()), 32
        );
        (bool versionOk, bytes memory versionData) = _staticcallExact(
            snapshot.implementation, snapshot.callbackGasLimit, abi.encodeCall(IHookrModuleV1.moduleVersion, ()), 32
        );
        (bool schemaOk, bytes memory schemaData) = _staticcallExact(
            snapshot.implementation, snapshot.callbackGasLimit, abi.encodeCall(IHookrModuleV1.configSchemaHash, ()), 32
        );
        if (
            !keyOk || abi.decode(keyData, (bytes32)) != snapshot.moduleKey || !versionOk
                || abi.decode(versionData, (uint32)) != snapshot.version || !schemaOk
                || abi.decode(schemaData, (bytes32)) != snapshot.configSchemaHash
        ) revert ModuleMetadataMismatch(snapshot.moduleId);

        (bool configOk, bytes memory configData) = _staticcallExact(
            snapshot.implementation,
            snapshot.callbackGasLimit,
            abi.encodeCall(IHookrModuleV1.validateConfig, (config)),
            32
        );
        if (!configOk || abi.decode(configData, (bytes32)) != keccak256(config)) {
            revert InvalidModuleConfig(snapshot.moduleId);
        }

        (bool stackOk, bytes memory stackData) = _staticcallExact(
            snapshot.implementation,
            snapshot.callbackGasLimit,
            abi.encodeCall(
                IHookrModuleV1.validateStack, (PoolId.unwrap(poolId), kernelAddress, subject, quote, config)
            ),
            160
        );
        if (!stackOk) {
            revert InvalidModuleStackBinding(snapshot.moduleId);
        }
        bytes32 configHash;
        uint256 rawLpFeeSurchargePips;
        uint256 rawSpecifiedQuoteTakeBps;
        uint256 rawUnspecifiedQuoteTakeBps;
        uint256 rawSubjectTakeBps;
        assembly ("memory-safe") {
            configHash := mload(add(stackData, 0x20))
            rawLpFeeSurchargePips := mload(add(stackData, 0x40))
            rawSpecifiedQuoteTakeBps := mload(add(stackData, 0x60))
            rawUnspecifiedQuoteTakeBps := mload(add(stackData, 0x80))
            rawSubjectTakeBps := mload(add(stackData, 0xa0))
        }
        if (
            configHash != keccak256(config) || rawLpFeeSurchargePips > type(uint24).max
                || rawSpecifiedQuoteTakeBps > type(uint16).max || rawUnspecifiedQuoteTakeBps > type(uint16).max
                || rawSubjectTakeBps > type(uint16).max
        ) revert InvalidModuleStackBinding(snapshot.moduleId);

        configCaps.configHash = configHash;
        // Each raw value is explicitly bounded to its destination width immediately above.
        // forge-lint: disable-next-line(unsafe-typecast)
        configCaps.maxLpFeeSurchargePips = uint24(rawLpFeeSurchargePips);
        // forge-lint: disable-next-line(unsafe-typecast)
        configCaps.maxSpecifiedQuoteTakeBps = uint16(rawSpecifiedQuoteTakeBps);
        // forge-lint: disable-next-line(unsafe-typecast)
        configCaps.maxUnspecifiedQuoteTakeBps = uint16(rawUnspecifiedQuoteTakeBps);
        // The raw value is explicitly bounded to uint16 immediately above.
        // forge-lint: disable-next-line(unsafe-typecast)
        configCaps.maxSubjectTakeBps = uint16(rawSubjectTakeBps);
        if (
            configCaps.maxLpFeeSurchargePips > snapshot.maxLpFeeSurchargePips
                || configCaps.maxSpecifiedQuoteTakeBps > snapshot.maxSpecifiedQuoteTakeBps
                || configCaps.maxUnspecifiedQuoteTakeBps > snapshot.maxUnspecifiedQuoteTakeBps
                || configCaps.maxSubjectTakeBps > snapshot.maxSubjectTakeBps
        ) revert ModuleConfigCapsExceedSnapshot(snapshot.moduleId);
    }

    /// @dev Copies only the expected fixed ABI payload and rejects short or oversized return data.
    ///      This keeps a future admitted module from forcing caller-side allocation/copy work outside
    ///      its callback gas stipend before the registry can validate the response length.
    function _staticcallExact(address target, uint256 gasLimit, bytes memory input, uint256 expectedLength)
        internal
        view
        returns (bool ok, bytes memory output)
    {
        output = new bytes(expectedLength);
        assembly ("memory-safe") {
            ok := staticcall(gasLimit, target, add(input, 0x20), mload(input), add(output, 0x20), expectedLength)
            let returnSize := returndatasize()
            if iszero(eq(returnSize, expectedLength)) {
                ok := 0
                if lt(returnSize, expectedLength) { mstore(output, returnSize) }
            }
        }
    }

    function _validateRelations(HookrModuleTypesV1.ModuleSnapshot[] memory snapshots) internal view {
        for (uint256 i; i < snapshots.length; ++i) {
            bytes32[] memory required = moduleCatalog.requiredModuleKeys(snapshots[i].moduleId);
            bytes32[] memory conflicting = moduleCatalog.conflictingModuleKeys(snapshots[i].moduleId);
            if (
                keccak256(abi.encode(required)) != snapshots[i].requirementsHash
                    || keccak256(abi.encode(conflicting)) != snapshots[i].conflictsHash
            ) revert ModuleMetadataMismatch(snapshots[i].moduleId);

            for (uint256 j; j < required.length; ++j) {
                if (!_containsModuleKey(snapshots, required[j])) {
                    revert MissingDependency(snapshots[i].moduleKey, required[j]);
                }
            }
            for (uint256 j; j < conflicting.length; ++j) {
                if (_containsModuleKey(snapshots, conflicting[j])) {
                    revert ModuleConflict(snapshots[i].moduleKey, conflicting[j]);
                }
            }
        }
    }

    function _containsModuleKey(HookrModuleTypesV1.ModuleSnapshot[] memory snapshots, bytes32 moduleKey)
        internal
        pure
        returns (bool found)
    {
        for (uint256 i; i < snapshots.length; ++i) {
            if (snapshots[i].moduleKey == moduleKey) return true;
        }
    }

    function _kernel(bytes32 kernelId) internal view returns (KernelSnapshot storage snapshot) {
        snapshot = _kernels[kernelId];
        if (snapshot.kernelId == bytes32(0)) revert UnknownKernel(kernelId);
    }

    function _activeKernel(bytes32 kernelId) internal view returns (KernelSnapshot memory snapshot) {
        if (kernelStatus[kernelId] != KernelStatus.ACTIVE) revert KernelNotActive(kernelId);
        snapshot = _kernel(kernelId);
        bytes32 actualCodeHash = snapshot.implementation.codehash;
        if (actualCodeHash != snapshot.implementationCodeHash) {
            revert KernelCodeChanged(snapshot.implementationCodeHash, actualCodeHash);
        }
    }

    function _integration(bytes32 integrationId) internal view returns (IntegrationSnapshot storage snapshot) {
        snapshot = _integrations[integrationId];
        if (snapshot.integrationId == bytes32(0)) revert UnknownIntegration(integrationId);
    }

    function _activeIntegration(bytes32 integrationId) internal view returns (IntegrationSnapshot memory snapshot) {
        if (integrationStatus[integrationId] != IntegrationStatus.ACTIVE) {
            revert IntegrationNotActive(integrationId);
        }
        snapshot = _integration(integrationId);
        bytes32 actualCodeHash = snapshot.implementation.codehash;
        if (actualCodeHash != snapshot.implementationCodeHash) {
            revert IntegrationCodeChanged(snapshot.implementation, snapshot.implementationCodeHash, actualCodeHash);
        }
    }

    function _activeIntegrationFor(address implementation, bytes32 expectedKind, bytes32 expectedFamilyId)
        internal
        view
        returns (IntegrationSnapshot memory snapshot)
    {
        bytes32 integrationId = integrationIdFor[implementation];
        if (integrationId == bytes32(0)) revert UnregisteredIntegration(implementation);
        snapshot = _activeIntegration(integrationId);
        if (snapshot.integrationKind != expectedKind) {
            revert IntegrationKindMismatch(implementation, expectedKind, snapshot.integrationKind);
        }
        if (snapshot.integrationFamilyId != expectedFamilyId) {
            revert IntegrationFamilyMismatch(implementation, expectedFamilyId, snapshot.integrationFamilyId);
        }
    }

    function _activeIntegrationForId(bytes32 integrationId, bytes32 expectedKind, bytes32 expectedFamilyId)
        internal
        view
        returns (IntegrationSnapshot memory snapshot)
    {
        if (integrationId == bytes32(0)) revert InvalidRootProfile();
        snapshot = _activeIntegration(integrationId);
        if (snapshot.integrationKind != expectedKind) {
            revert IntegrationKindMismatch(snapshot.implementation, expectedKind, snapshot.integrationKind);
        }
        if (snapshot.integrationFamilyId != expectedFamilyId) {
            revert IntegrationFamilyMismatch(snapshot.implementation, expectedFamilyId, snapshot.integrationFamilyId);
        }
    }

    function _stack(PoolId poolId) internal view returns (HookrModuleTypesV1.StackCore storage core) {
        core = _stacks[poolId];
        if (!core.configured) revert UnknownStack(poolId);
    }
}
