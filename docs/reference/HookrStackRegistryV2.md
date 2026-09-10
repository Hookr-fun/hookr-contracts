# HookrStackRegistryV2

Source: [`src/HookrStackRegistryV2.sol`](../../src/HookrStackRegistryV2.sol)

Registry for immutable per-pool stacks admitted under one sealed shared-root profile

Every pool runs on the sealed root profile. The registry requires stable root profiles, keeps the per-market kernel-instance lane switched off, and reverts every function belonging to that lane, except `kernelInstanceFactoryFor`, which returns the zero address.

## Identity

Two `pure` getters every contract in the graph carries, so an integrator can confirm what it is holding without a bytecode comparison.

```solidity
function contractName() external pure returns (string memory);   // "HookrStackRegistryV2"
function contractVersion() external pure returns (string memory); // "2.1.0"
```

## Profile Policy

| Function | Behaviour |
| --- | --- |
| `stableRootProfilesRequired()` | returns true |
| `exceptionalKernelInstancesSupported()` | returns false |
| `registerKernelInstanceFactory`, `retireKernelInstanceFactory`, `kernelInstanceFactory`, `registerKernelInstance` | revert `ExceptionalKernelInstancesDisabled(bytes32(0))` |
| `kernelInstanceFactoryFor` | returns the zero address |
| `kernelInstanceFactoryStatus` | inherited, and reports every factory as unregistered because none can be added |

`sealRootProfile` therefore requires `allowsExceptionalInstances == false`.

## Constants

| Name | Type | Value |
| --- | --- | --- |
| `ROUTER_INTEGRATION_KIND` | `bytes32` | `keccak256("HOOKR_KERNEL_INTEGRATION_ROUTER")` |
| `QUOTER_INTEGRATION_KIND` | `bytes32` | `keccak256("HOOKR_KERNEL_INTEGRATION_QUOTER")` |
| `CORRECTION_EXECUTOR_INTEGRATION_KIND` | `bytes32` | correction-executor integration kind |

## State Variables

| Name | Type | Description |
| --- | --- | --- |
| `poolManager` | `IPoolManager` | Immutable |
| `moduleCatalog` | `HookrModuleCatalogV1` | Immutable |
| `coordinator` | `address` | Set once by `setCoordinatorOnce`; the only address that may create a stack |
| `owner` | `address` | Registers kernels and integrations, seals profiles |
| `integrationIdFor` | `mapping(address => bytes32)` | Reverse lookup for a registered implementation |

## Functions

### constructor

```solidity
constructor(address owner_, IPoolManager poolManager_, HookrModuleCatalogV1 moduleCatalog_);
```

### setCoordinatorOnce

Owner-only, one-shot, irreversible. Binds the one coordinator allowed to call `createStack`.

```solidity
function setCoordinatorOnce(address coordinator_) external;
```

One registry instance therefore serves exactly one coordinator.

### registerKernel

Owner-only. Admits a root implementation under a kernel family, pinning its address, runtime code hash and hook flags.

```solidity
function registerKernel(KernelRegistration calldata registration) external returns (bytes32 kernelId);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`registration`|`KernelRegistration`|`{kernelFamilyId, version, implementation, hookFlags}`|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`kernelId`|`bytes32`|Identifier a market names in `MarketParams.kernelId`|

`kernelFamilyId` is not a free choice. The router and quoter both hardcode `keccak256("HOOKR_SWAP_DELTA_V1")`, and `createStack` requires the registered router and quoter integrations to serve the kernel's own family. Registering under a different family makes every later `createStack` revert.

### registerIntegration

Owner-only. Admits a router, quoter or correction executor. The registration's `integrationFamilyId` and `version` are round-tripped through the implementation's own `integrationFamilyId()` and `integrationVersion()` and must match exactly.

```solidity
function registerIntegration(IntegrationRegistration calldata registration)
    external
    returns (bytes32 integrationId);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`registration`|`IntegrationRegistration`|`{integrationKind, integrationFamilyId, version, implementation}`|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`integrationId`|`bytes32`|Identifier `sealRootProfile` names|

Reverts `IntegrationMetadataMismatch` on a mismatch and `IntegrationImplementationAlreadyRegistered(implementation, existingId)` on a duplicate.

### sealRootProfile

Owner-only, one-shot per kernel. Fixes the admission envelope every pool on this root shares. Once sealed the profile can never admit another implementation or change its exceptional-instance policy.

```solidity
function sealRootProfile(
    bytes32 kernelId,
    bytes32 profileId,
    uint32 profileVersion,
    bytes32[] calldata moduleIds,
    bytes32 routerIntegrationId,
    bytes32 quoterIntegrationId,
    bytes32 correctionExecutorIntegrationId,
    bool allowsExceptionalInstances
) external returns (bytes32 profileManifestHash);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`kernelId`|`bytes32`|The registered root this profile seals|
|`profileId`|`bytes32`|Permanent identity for the profile|
|`profileVersion`|`uint32`|Profile version, non-zero|
|`moduleIds`|`bytes32[]`|Every module a pool on this root may select|
|`routerIntegrationId`|`bytes32`|The registered router integration id, not its kind|
|`quoterIntegrationId`|`bytes32`|The registered quoter integration id, not its kind|
|`correctionExecutorIntegrationId`|`bytes32`|Zero when no correction executor is in the profile|
|`allowsExceptionalInstances`|`bool`|Must be false|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`profileManifestHash`|`bytes32`|Commitment to the sealed envelope|

Pass the ids `registerIntegration` returned. Passing `ROUTER_INTEGRATION_KIND` or `QUOTER_INTEGRATION_KIND` instead reverts `IntegrationNotActive`, because no integration is ever registered under an id equal to its own kind.

### createStack

Coordinator-only. Validates the pool, the limits, the integrations and every module selection, derives the per-pool caps, and freezes one `StackCore` for the `PoolId`.

```solidity
function createStack(
    PoolKey calldata key,
    address subject,
    address quote,
    bytes32 kernelId,
    HookrModuleTypesV1.ModuleSelection[] calldata selections,
    HookrModuleTypesV1.StackLimits calldata limits
) external returns (PoolId poolId, bytes32 stackHash);
```

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|The pool the stack is frozen for|
|`stackHash`|`bytes32`|Commitment to the frozen stack|

Reverts `ModuleConfigCapsExceedSnapshot` if a module's config-derived caps exceed its catalog registration, and `IntegrationFamilyMismatch` if the router or quoter serves a different kernel family.

### markInitialized

Callable by the pool's kernel. Marks the stack initialized during `beforeInitialize`.

```solidity
function markInitialized(PoolId poolId) external;
```

### Read functions

```solidity
function stack(PoolId poolId) external view returns (HookrModuleTypesV1.StackCore memory core);
function moduleAt(PoolId poolId, uint256 index) external view returns (HookrModuleTypesV1.ModuleSnapshot memory, bytes memory config);
function frozenModuleConfigHash(PoolId poolId, address implementation) external view returns (bytes32 configHash);
function kernel(bytes32 kernelId) external view returns (KernelSnapshot memory snapshot);
function activeKernel(bytes32 kernelId) external view returns (KernelSnapshot memory snapshot);
function rootProfile(bytes32 kernelId) external view returns (RootProfileSnapshot memory profile);
function isRootProfileModuleAllowed(bytes32 kernelId, bytes32 moduleId) external view returns (bool);
function integration(bytes32 integrationId) external view returns (IntegrationSnapshot memory snapshot);
function activeIntegration(bytes32 integrationId) external view returns (IntegrationSnapshot memory snapshot);
function module(bytes32 moduleId) external view returns (HookrModuleTypesV1.ModuleSnapshot memory snapshot);
function stackCount() external view returns (uint256);
function poolIdAt(uint256 index) external view returns (PoolId);
```

`stack(poolId)` is the read an indexer or an interface wants: it returns the subject, the quote, the kernel, the stack hash, the trusted router and quoter with their code hashes, the module count, and the frozen `StackLimits`.

Alongside these, the registry enumerates and computes:

```solidity
function kernelCount() external view returns (uint256);
function kernelIdAt(uint256 index) external view returns (bytes32);
function kernelStatus(bytes32 kernelId) external view returns (uint8);
function integrationCount() external view returns (uint256);
function integrationIdAt(uint256 index) external view returns (bytes32);
function integrationStatus(bytes32 integrationId) external view returns (uint8);
function integrationIdFor(address implementation) external view returns (bytes32);
function rootKernelForProfile(bytes32 profileId, uint32 profileVersion) external view returns (bytes32 kernelId);
function rootProfileModuleAt(bytes32 kernelId, uint256 index) external view returns (bytes32 moduleId);
function rootProfileSource(bytes32 kernelId) external view returns (bytes32 rootKernelId);
function computeKernelId(KernelRegistration calldata registration, bytes32 implementationCodeHash)
    public view returns (bytes32);
function computeIntegrationId(IntegrationRegistration calldata registration, bytes32 implementationCodeHash)
    public view returns (bytes32);
```

`computeKernelId` and `computeIntegrationId` reproduce off chain the identifiers `registerKernel` and `registerIntegration` return, so a caller can predict an id before sending the registration.

## Owner Surface

Ownership is the same two-step transfer the rest of the graph uses, and every registration has a matching retirement. Retiring affects future admission only: a sealed profile and every pool already open keep running on what they froze.

```solidity
function proposeOwner(address nextOwner) external;
function acceptOwnership() external;
function pendingOwner() external view returns (address);
function retireKernel(bytes32 kernelId) external;
function retireIntegration(bytes32 integrationId) external;
```

## Domain Constants

Identifier and manifest domains, plus the bounds the registry enforces while validating a stack.

| Name | Type | Value |
| --- | --- | --- |
| `KERNEL_ID_DOMAIN` | `bytes32` | domain separator for `computeKernelId` |
| `INTEGRATION_ID_DOMAIN` | `bytes32` | domain separator for `computeIntegrationId` |
| `STACK_ID_DOMAIN` | `bytes32` | domain separator for a per-pool stack hash |
| `STABLE_ROOT_STACK_ID_DOMAIN` | `bytes32` | domain separator for a stack under a sealed shared root |
| `STACK_MODULES_DOMAIN` | `bytes32` | domain separator for the module list inside a stack hash |
| `ROOT_PROFILE_MANIFEST_DOMAIN` | `bytes32` | domain separator for the sealed profile's manifest hash |
| `ROOT_PROFILE_MODULES_DOMAIN` | `bytes32` | domain separator for the profile's admitted module set |
| `SUPPORTED_KERNEL_INSTANCE_LAYOUT_ID` | `bytes32` | the one instance layout a kernel may report |
| `ALL_HOOK_FLAGS` | `uint160` | mask of every hook permission bit |
| `MAX_CONFIG_BYTES` | `uint32` | 4,096: longest module config a stack may carry |
| `MAX_CORRECTION_VOLUME_BPS` | `uint16` | ceiling on a correction executor's volume share |
| `KERNEL_WIRING_GAS` | `uint32` | 30,000: gas bound on the wiring staticcalls made against a kernel |
| `INTEGRATION_WIRING_GAS` | `uint32` | 30,000: gas bound on the wiring staticcalls made against an integration |

## Events

Registration and lifecycle, all indexed by their identifier.

`CoordinatorSet`, `OwnerProposed`, `OwnerSet`, `KernelRegistered`, `KernelRetired`, `IntegrationRegistered`, `IntegrationRetired`, `RootProfileSealed`, `StackConfigured`, `StackInitialized`, `KernelInstanceFactoryRegistered`, `KernelInstanceFactoryRetired`, `KernelInstanceRegistered`, `ExceptionalKernelInstanceRegistered`.

The last four belong to the per-market kernel-instance lane, which this registry keeps switched off, so nothing here can emit them.

## Errors

Ownership and wiring: `NotOwner`, `NotPendingOwner`, `NotCoordinator`, `NotStackKernel`, `ZeroAddress`, `CoordinatorAlreadySet`, `CoordinatorNotSet`.

Kernel registration: `InvalidKernel`, `KernelAlreadyExists`, `KernelAlreadyRetired`, `KernelNotActive`, `UnknownKernel`, `KernelCodeChanged`, `KernelCoordinatorMismatch`, `KernelPoolManagerMismatch`, `KernelStackRegistryMismatch`, `InvalidHookFlags`, `InvalidHookFlagDependencies`, `UnsupportedHookFlags`, `RootImplementationAlreadyRegistered`.

Integration registration: `InvalidIntegration`, `InvalidIntegrationWiring`, `IntegrationAlreadyExists`, `IntegrationAlreadyRetired`, `UnknownIntegration`, `UnregisteredIntegration`, `IntegrationCodeChanged`, `IntegrationKindMismatch`, `IntegrationMetadataMismatch`, `IntegrationFamilyMismatch`, `IntegrationNotActive`, `IntegrationPoolManagerMismatch`, `IntegrationStackRegistryMismatch`, `IntegrationOutsideRootProfile`.

Root profile: `InvalidRootProfile`, `RootProfileAlreadySealed`, `RootProfileNotSealed`, `RootProfileIdentityAlreadyUsed`, `NonCanonicalProfileModuleOrder`, `StableRootProfilesRequired`, `ModuleOutsideRootProfile`.

Stack creation: `InvalidPoolKey`, `InvalidCurrencyPair`, `InvalidStackLimits`, `InvalidModuleConfig`, `InvalidModuleStackBinding`, `ConfigTooLarge`, `TooManyModules`, `DuplicateModule`, `DuplicateModuleImplementation`, `ExclusiveGroupConflict`, `ModuleConflict`, `MissingDependency`, `ModuleCapsExceedStackLimits`, `ModuleConfigCapsExceedSnapshot`, `ModuleGasExceedsStackLimit`, `ModuleMetadataMismatch`, `ModuleCodeChanged`, `StackAlreadyConfigured`, `StackAlreadyInitialized`, `UnknownStack`.

Disabled lane: `ExceptionalKernelInstancesDisabled(bytes32 kernelId)`, plus `InvalidKernelInstance`, `InvalidKernelInstanceFactory`, `KernelInstanceFactoryAlreadyExists`, `KernelInstanceFactoryAlreadyRetired`, `KernelInstanceFactoryNotActive`, `KernelInstanceFactoryCodeChanged`, `UnknownKernelInstanceFactory`, which are unreachable while the lane is off.

`ModuleCapsExceedStackLimits` and `ModuleConfigCapsExceedSnapshot` are the two a launcher meets in practice: the first when a pool's config asks for more than its own `StackLimits` allow, the second when it asks for more than the module's one-shot catalog registration. See [Config schema and limits](./config-schema-and-limits.md).

## Structs

### StackLimits

```solidity
struct StackLimits {
    uint24 baseLpFeePips;
    uint24 maxLpFeePips;
    uint16 maxSpecifiedQuoteTakeBps;
    uint16 maxUnspecifiedQuoteTakeBps;
    uint16 maxSubjectTakeBps;
    uint32 maxTotalModuleGas;
    address trustedRouter;
    address trustedQuoter;
    address correctionExecutor;
    address correctionCreator;
    uint16 correctionMaxVolumeBps;
    uint96 correctionMinProfitQuote;
    bytes32 correctionFeePolicyId;
}
```

All-zero correction fields select the plain modular profile, which is what every Hookr market uses. These values are part of the stack hash and cannot change after pool creation.

### ModuleSelection

```solidity
struct ModuleSelection {
    bytes32 moduleId;
    bytes config;
}
```

### Snapshots and the frozen core

The read functions above return these structs. Field order is the ABI order.

```solidity
struct KernelSnapshot {
    bytes32 kernelId;
    bytes32 kernelFamilyId;
    uint32 version;
    address implementation;
    bytes32 implementationCodeHash;
    uint160 hookFlags;
}

struct IntegrationSnapshot {
    bytes32 integrationId;
    bytes32 integrationKind;
    bytes32 integrationFamilyId;
    uint32 version;
    address implementation;
    bytes32 implementationCodeHash;
}

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

struct StackCore {
    bool configured;
    bool initialized;
    address kernel;
    bytes32 kernelId;
    bytes32 kernelFamilyId;
    bytes32 kernelCodeHash;
    address subject;
    address quote;
    bytes32 stackHash;
    bytes32 trustedRouterIntegrationId;
    bytes32 trustedRouterCodeHash;
    bytes32 trustedQuoterIntegrationId;
    bytes32 trustedQuoterCodeHash;
    bytes32 correctionExecutorIntegrationId;
    bytes32 correctionExecutorCodeHash;
    uint8 moduleCount;
    StackLimits limits;
}
```
