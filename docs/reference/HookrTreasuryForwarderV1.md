# HookrTreasuryForwarderV1

Source: [`src/HookrTreasuryForwarderV1.sol`](../../src/HookrTreasuryForwarderV1.sol)

Rotatable payout indirection for the one treasury address every market pins forever

The module's `protocolRecipient` is immutable and the coordinator's `treasury` is constructor-only, and admission requires them to be equal. Pinning an EOA at either end would make rotating the payout destination de-admit every future market. This contract is pinned instead. It holds no protocol authority and can only move what it is owed to one owner-settable target.

## Identity

Two `pure` getters every contract in the graph carries, so an integrator can confirm what it is holding without a bytecode comparison.

```solidity
function contractName() external pure returns (string memory);   // "HookrTreasuryForwarderV1"
function contractVersion() external pure returns (string memory); // "1.0.0"
```

## State Variables

| Name | Type | Description |
| --- | --- | --- |
| `poolManager` | `address` | Immutable. Held so `target` can be rejected as the PoolManager before a module is bound |
| `owner` | `address` | May rotate the target and point at a module |
| `pendingOwner` | `address` | Eligible to accept ownership |
| `target` | `address` | Sole payout destination |
| `nativeBlock` | `address` | The module whose accruals this forwarder pulls |

## Functions

### constructor

Reverts `ZeroAddress` for a zero owner, PoolManager or target, `InvalidPoolManager` for a codeless PoolManager, and `InvalidTarget` for a target equal to this contract or the PoolManager.

```solidity
constructor(address owner_, address target_, address poolManager_);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`owner_`|`address`|Initial owner|
|`target_`|`address`|Initial payout destination|
|`poolManager_`|`address`|The Uniswap v4 singleton the bound module settles through|

### collect

Permissionless. Claims this forwarder's accrual for one quote out of the module and forwards it to `target` in the same call. Returns zero rather than reverting when nothing is owed.

```solidity
function collect(address quote) external returns (uint256 collected);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`quote`|`address`|Quote currency of the accrual; `address(0)` is native|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`collected`|`uint256`|Amount pulled out of the module|

Claiming into this contract before forwarding is what keeps a bad target non-blocking. If the forward fails the accrual is already out of the module, `ForwardDeferred` is emitted, and the funds rest here until `sweep` runs. Reverts `NotBound` when no module is bound.

### sweep

Permissionless. Forwards any balance this contract itself holds to `target`. Unlike `collect` it reverts when the target rejects the payment, because at that point there is nothing left to rescue. A zero balance returns silently, with no event.

```solidity
function sweep(address token) external;
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`token`|`address`|Token to forward; `address(0)` is native|

### setTarget

Owner-only. Rotates the payout destination. The pinned forwarder address never changes, so no live market is touched and no future admission is affected.

```solidity
function setTarget(address target_) external;
```

Reverts `ZeroAddress`, `TargetUnchanged`, or `InvalidTarget` when the destination is this contract, the bound module, or a PoolManager.

### setTargetAndCollect

Owner-only. Rotates and drains in one transaction, so no third party gets a block boundary in which the old target can still be paid.

```solidity
function setTargetAndCollect(address newTarget, address[] calldata quotes)
    external
    returns (uint256[] memory collected);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`newTarget`|`address`|New payout destination|
|`quotes`|`address[]`|Quote currencies to collect after rotating|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`collected`|`uint256[]`|Amount pulled for each quote, in the same order|

Broadcast this through a private relay or an atomic bundle when the old target is believed compromised. A public mempool still exposes the rotation intent, just not a claimable window.

### setNativeBlock

Owner-only, and deliberately not one-shot. The candidate must already read back this forwarder as its own `protocolRecipient`, so the owner can only point at a module that already pays here.

```solidity
function setNativeBlock(address nativeBlock_) external;
```

Reverts `ZeroAddress`, `NativeBlockUnchanged`, or `InvalidNativeBlock` when the candidate has no code, equals the current target, or does not name this forwarder, and `InvalidTarget` when the standing target equals the candidate or the candidate's own PoolManager.

### proposeOwner

Owner-only. Passing the zero address clears a standing proposal and emits `OwnerProposalCleared`. Proposing the current owner reverts `ZeroAddress`.

```solidity
function proposeOwner(address nextOwner) external;
```

### acceptOwnership

Callable only by the pending owner.

```solidity
function acceptOwnership() external;
```

### receive

Accepts native value, so a native `collect` can claim into this contract before forwarding.

```solidity
receive() external payable;
```

## Events

```solidity
event OwnerProposed(address indexed pendingOwner);
event OwnerProposalCleared();
event OwnerSet(address indexed owner);
event TargetSet(address indexed target);
event NativeBlockSet(address indexed nativeBlock);
event Collected(address indexed quote, address indexed target, uint256 paid);
event ForwardDeferred(address indexed quote, address indexed target, uint256 amount);
event Swept(address indexed token, address indexed target, uint256 amount);
```

`ForwardDeferred` is the one to alert on. It means an accrual was pulled out of the module and the target refused it.

## Errors

`NotOwner`, `NotPendingOwner`, `ZeroAddress`, `TargetUnchanged`, `InvalidTarget`, `InvalidPoolManager`, `InvalidNativeBlock`, `NativeBlockUnchanged`, `NotBound`, `NativeTransferFailed`, `TokenCallFailed`.

`TokenCallFailed` comes from the shared transfer helper and surfaces when an ERC-20 quote's `transfer` or `balanceOf` reverts or returns nothing usable. `NativeTransferFailed` is its native counterpart, raised by `sweep` when the target rejects the value; `collect` emits `ForwardDeferred` instead and leaves the funds here.
