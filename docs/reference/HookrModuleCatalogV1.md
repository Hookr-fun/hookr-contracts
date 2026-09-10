# HookrModuleCatalogV1

Source: [`src/HookrModuleCatalogV1.sol`](../../src/HookrModuleCatalogV1.sol)

Module admission. Fixes what a module implementation may ever request, permanently

A registration pins the implementation address, its runtime code hash, its config schema hash, its required hook flags, its phase mask, its exclusive group, its execution mode and four structural ceilings. There is no updater. Retiring a module stops future admission and touches nothing already frozen.

## Identity

Two `pure` getters every contract in the graph carries, so an integrator can confirm what it is holding without a bytecode comparison.

```solidity
function contractName() external pure returns (string memory);   // "HookrModuleCatalogV1"
function contractVersion() external pure returns (string memory); // "1.2.0"
```

## Constants

| Name | Type | Value |
| --- | --- | --- |
| `MODULE_ID_DOMAIN` | `bytes32` | `keccak256("HOOKR_MODULE_CATALOG_V1")` |
| `MAX_RELATIONS` | `uint8` | `HookrModuleTypesV1.MAX_MODULES`, the module-count ceiling of a stack |
| `ALL_HOOK_FLAGS` | `uint160` | `(1 << 14) - 1` |
| `MIN_CALLBACK_GAS` | `uint32` | 25,000 |
| `CANONICAL_STATEFUL_MARKER_GAS` | `uint32` | 50,000 |

## State Variables

| Name | Type | Description |
| --- | --- | --- |
| `owner` | `address` | Registers and retires modules |
| `pendingOwner` | `address` | Eligible to accept ownership |
| `canonicalStatefulModule` | `address` | The one stateful implementation this catalog admits |
| `canonicalStatefulModuleCodeHash` | `bytes32` | Its runtime code hash at binding time |
| `moduleStatus` | `mapping(bytes32 => ModuleStatus)` | `UNSET`, `ACTIVE` or `RETIRED` per `moduleId` |

```solidity
enum ModuleStatus { UNSET, ACTIVE, RETIRED }
```

## Functions

### constructor

```solidity
constructor(address owner_);
```

Reverts `ZeroAddress` for a zero owner.

### setCanonicalStatefulModuleOnce

Owner-only, one-shot per catalog instance. `registerModule` rejects a `STATEFUL_V1` module until this has run, and afterwards rejects any stateful module other than the bound one.

```solidity
function setCanonicalStatefulModuleOnce(address implementation) external;
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`implementation`|`address`|The stateful module this catalog will admit|

Reverts `CanonicalStatefulModuleAlreadySet(implementation)` on a second call and `InvalidCanonicalStatefulModule(implementation)` if the candidate has no code or does not report the expected stateful marker within `CANONICAL_STATEFUL_MARKER_GAS`. One catalog instance therefore serves exactly one stateful module.

### registerModule

Owner-only. Computes a deterministic `moduleId` from the registration and the implementation's code hash, and stores the snapshot.

```solidity
function registerModule(HookrModuleTypesV1.ModuleRegistration calldata registration)
    external
    returns (bytes32 moduleId);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`registration`|`ModuleRegistration`|Key, version, implementation, schema hash, required flags, phase mask, exclusive group, execution mode, the four caps, callback gas limit, and the required and conflicting module keys|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`moduleId`|`bytes32`|Identifier the registry and the sealed profile refer to|

Validation rejects a zero or codeless implementation, a phase mask outside the legal set, a `maxLpFeeSurchargePips` above one million, a `maxSpecifiedQuoteTakeBps` or `maxUnspecifiedQuoteTakeBps` at or above ten thousand, a `maxSubjectTakeBps` above one thousand, a `callbackGasLimit` below `MIN_CALLBACK_GAS`, required flags that do not cover the flags the caps imply, duplicate or self-referential relations, and a stateful module other than the canonical one. Reverts `ModuleAlreadyExists(moduleId)` for a registration that hashes to an existing id. It also rejects a zero `moduleKey`, `version` or `configSchemaHash`, required flags outside `ALL_HOOK_FLAGS`, caps declared for a phase the mask does not include (`InvalidModuleCaps`), more relations than `MAX_RELATIONS` (`TooManyRelations`), a key that appears on both relation lists (`ContradictoryRelation`), and an execution mode that disagrees with the module's own stateful marker.

The caps are the ceiling for every pool this module will ever serve, not for one pool. They are sized against the module's structural maxima; the values and their derivation are in [Config schema and limits](./config-schema-and-limits.md).

### retireModule

Owner-only. Stops future admission. Sealed profiles and open pools are unaffected.

```solidity
function retireModule(bytes32 moduleId) external;
```

Reverts `UnknownModule(moduleId)` and `ModuleAlreadyRetired(moduleId)`.

### proposeOwner and acceptOwnership

Two-step ownership transfer.

```solidity
function proposeOwner(address nextOwner) external;
function acceptOwnership() external;
```

### module

The stored snapshot for a module, whatever its status. Reverts `UnknownModule(moduleId)` for an id that was never registered.

```solidity
function module(bytes32 moduleId) external view returns (HookrModuleTypesV1.ModuleSnapshot memory snapshot);
```

### activeModule

The same snapshot, but only while the module is `ACTIVE`. Reverts `ModuleNotActive(moduleId)` otherwise. This is the read the registry uses at admission.

```solidity
function activeModule(bytes32 moduleId) external view returns (HookrModuleTypesV1.ModuleSnapshot memory snapshot);
```

### requiredModuleKeys, conflictingModuleKeys

The relation lists a registration declared.

```solidity
function requiredModuleKeys(bytes32 moduleId) external view returns (bytes32[] memory keys);
function conflictingModuleKeys(bytes32 moduleId) external view returns (bytes32[] memory keys);
```

### moduleCount, moduleIdAt

Enumeration of every registered id, in registration order.

```solidity
function moduleCount() external view returns (uint256);
function moduleIdAt(uint256 index) external view returns (bytes32);
```

### computeModuleId

The id a registration would receive, so a deployer can predict it before the transaction.

```solidity
function computeModuleId(
    HookrModuleTypesV1.ModuleRegistration calldata registration,
    bytes32 implementationCodeHash,
    bytes32 requirementsHash,
    bytes32 conflictsHash
) public view returns (bytes32);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`registration`|`ModuleRegistration`|The registration to hash|
|`implementationCodeHash`|`bytes32`|The implementation's runtime code hash|
|`requirementsHash`|`bytes32`|Hash of the required module keys|
|`conflictsHash`|`bytes32`|Hash of the conflicting module keys|

### contractName, contractVersion

```solidity
function contractName() external pure returns (string memory);
function contractVersion() external pure returns (string memory);
```

Return `"HookrModuleCatalogV1"` and `"1.2.0"`.

## Structs

### ModuleRegistration

```solidity
struct ModuleRegistration {
    bytes32 moduleKey;
    uint32 version;
    address implementation;
    bytes32 configSchemaHash;
    uint160 requiredHookFlags;
    uint8 phaseMask;
    bytes32 exclusiveGroup;
    ExecutionMode executionMode;
    uint24 maxLpFeeSurchargePips;
    uint16 maxSpecifiedQuoteTakeBps;
    uint16 maxUnspecifiedQuoteTakeBps;
    uint16 maxSubjectTakeBps;
    uint32 callbackGasLimit;
    bytes32[] requiredModuleKeys;
    bytes32[] conflictingModuleKeys;
}
```

### ModuleSnapshot

What the catalog stores and the registry reads. The relation lists are stored as hashes.

```solidity
struct ModuleSnapshot {
    bytes32 moduleId;
    bytes32 moduleKey;
    uint32 version;
    address implementation;
    bytes32 implementationCodeHash;
    bytes32 configSchemaHash;
    uint160 requiredHookFlags;
    uint8 phaseMask;
    bytes32 exclusiveGroup;
    ExecutionMode executionMode;
    uint24 maxLpFeeSurchargePips;
    uint16 maxSpecifiedQuoteTakeBps;
    uint16 maxUnspecifiedQuoteTakeBps;
    uint16 maxSubjectTakeBps;
    uint32 callbackGasLimit;
    bytes32 requirementsHash;
    bytes32 conflictsHash;
}
```

## Events

### ModuleRegistered

```solidity
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
```

### ModuleRetired

```solidity
event ModuleRetired(bytes32 indexed moduleId);
```

### CanonicalStatefulModuleSet

```solidity
event CanonicalStatefulModuleSet(address indexed implementation, bytes32 indexed implementationCodeHash);
```

### OwnerProposed, OwnerSet

```solidity
event OwnerProposed(address indexed pendingOwner);
event OwnerSet(address indexed owner);
```

## Errors

`NotOwner`, `NotPendingOwner`, `ZeroAddress`, `InvalidModule`, `InvalidPhaseMask`, `InvalidModuleCaps`, `TooManyRelations`, `DuplicateRelation(moduleKey)`, `SelfRelation(moduleKey)`, `ContradictoryRelation(moduleKey)`, `ModuleAlreadyExists(moduleId)`, `UnknownModule(moduleId)`, `ModuleNotActive(moduleId)`, `ModuleAlreadyRetired(moduleId)`, `CanonicalStatefulModuleAlreadySet(implementation)`, `CanonicalStatefulModuleNotSet`, `InvalidCanonicalStatefulModule(implementation)`, `NonCanonicalStatefulModule(expected, actual)`, `CanonicalStatefulModuleCodeChanged(expected, actual)`.
