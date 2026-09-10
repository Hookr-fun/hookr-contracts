# HookrNativeMechanicsBlockV2

Source: [`src/HookrNativeMechanicsBlockV2.sol`](../../src/HookrNativeMechanicsBlockV2.sol)

**Implements:** `IHookrModuleV1`, `IHookrStatefulModuleV1`, `IUnlockCallback`

Stateful lifecycle module holding the five Hookr rules on any quote currency

## Identity

Two `pure` getters every contract in the graph carries, so an integrator can confirm what it is holding without a bytecode comparison.

```solidity
function contractName() external pure returns (string memory);   // "HookrNativeMechanicsBlockV2"
function contractVersion() external pure returns (string memory); // "2.1.0"
```

## Constants

| Name | Type | Value |
| --- | --- | --- |
| `MODULE_KEY` | `bytes32` | `keccak256("HOOKR_NATIVE_MECHANICS")` |
| `EXCLUSIVE_GROUP` | `bytes32` | `keccak256("HOOKR_NATIVE_MECHANICS")` |
| `CONFIG_SCHEMA_HASH` | `bytes32` | `keccak256("HookrNativeMechanicsBlockV2.Config(...)")`, listing all twenty fields in order |
| `MODULE_VERSION` | `uint32` | 2 |
| `PHASE_MASK` | `uint8` | all phases |
| `MAX_TOTAL_FEE_PIPS` | `uint24` | 500,000 |
| `MAX_PROTOCOL_SHARE_BPS` | `uint16` | 5,000 |
| `MIN_POT_BUY_WEI` | `uint96` | 0.001 ether |
| `MAX_QUOTE_DECIMALS` | `uint256` | 36 |
| `MAX_GUARD_BLOCKS` | `uint256` | 100,000 |
| `MIN_SQRT_PRICE_LIMIT` | `uint160` | 4295128740 |
| `MAX_SQRT_PRICE_LIMIT` | `uint160` | 1461446703485210103287273052203988822378723970341 |
| `DEAD` | `address` | `0x000000000000000000000000000000000000dEaD` |
| `NATIVE_CUT_ATTRIBUTION_KEY` | `bytes32` | `keccak256("HOOKR_NATIVE_BUY_CUT")` |
| `AUTO_BURN_ATTRIBUTION_KEY` | `bytes32` | `keccak256("HOOKR_NATIVE_AUTO_BURN")` |
| `PROTOCOL_SHARE_ATTRIBUTION_KEY` | `bytes32` | `keccak256("HOOKR_NATIVE_PROTOCOL_SHARE")` |

The schema string names every field in order, and the admission library pins the same literal, so a config encoded against any other layout or any other field meaning fails closed at admission. `protocolShareBps` is a share of each add-on in basis points, never a flat rate on the quote leg; an encoder that treats it otherwise produces a config that prices completely differently, which is why the hash of the schema string, not only the byte layout, is part of admission.

Six `pure` getters expose the same values through `IHookrModuleV1` and `IHookrStatefulModuleV1`, and two of the contracts read them back off the module rather than trusting what a registrar typed: the catalog reads `statefulModuleMagic()` at registration, and the registry round-trips `moduleKey`, `moduleVersion` and `configSchemaHash` against the module when a stack is created.

```solidity
function moduleKey() external pure returns (bytes32);            // MODULE_KEY
function moduleVersion() external pure returns (uint32);         // MODULE_VERSION
function configSchemaHash() external pure returns (bytes32);     // CONFIG_SCHEMA_HASH
function phaseMask() external pure returns (uint8);              // PHASE_MASK
function exclusiveGroup() external pure returns (bytes32);       // EXCLUSIVE_GROUP
function statefulModuleMagic() external pure returns (bytes32);  // keccak256("HOOKR_STATEFUL_SWAP_MODULE_V1")
```

`statefulModuleMagic()` returns the shared marker the accounting kernel checks before it will drive a module through the stateful callbacks. A module that answers anything else is refused.

## State Variables

| Name | Type | Description |
| --- | --- | --- |
| `poolManager` | `IPoolManager` | Immutable. The v4 singleton |
| `stackRegistry` | `IHookrStackRegistryV1` | Immutable. Source of the frozen stack and config hash |
| `protocolRecipient` | `address` | Immutable. The only address that may receive the protocol share |
| `potWei` | `mapping(bytes32 => uint256)` | Current pot balance per pool |
| `potBuyCount` | `mapping(bytes32 => uint256)` | Qualifying buys counted per pool |
| `potLastQualifyingBlock` | `mapping(bytes32 => uint40)` | Last block the counter advanced |
| `guardBuyBlock` | `mapping(bytes32 => uint40)` | Block the guard cap is currently counting |
| `guardBuyAmount` | `mapping(bytes32 => uint96)` | Quote spent on buys in that block |
| `guardLpEarnedQuote` | `mapping(bytes32 => uint256)` | Cumulative guard-window quote LP earnings, informational |
| `totalHookFeesWei` | `mapping(bytes32 => uint256)` | Cumulative LP-reward plus pot cuts |
| `totalBurnedTokens` | `mapping(bytes32 => uint256)` | Cumulative subject burned |
| `totalLpDonatedWei` | `mapping(bytes32 => uint256)` | Cumulative LP donations |
| `totalPotPaidWei` | `mapping(bytes32 => uint256)` | Cumulative pot payouts |
| `totalProtocolShareWei` | `mapping(bytes32 => uint256)` | Cumulative protocol share across every stream |
| `protocolShareByStream` | `mapping(bytes32 => mapping(uint8 => uint256))` | Cumulative protocol share per pool per `ProtocolStream` |
| `claimable` | `mapping(address => mapping(address => uint256))` | Pull-claim ledger, quote then account |
| `totalClaimLiability` | `mapping(address => uint256)` | Backed ERC-6909 liability per quote |

## Functions

### constructor

Pins the PoolManager, the stack registry and the protocol recipient. Reverts `ZeroAddress` if any is zero, or if the PoolManager or the registry has no code.

```solidity
constructor(
    IPoolManager poolManager_,
    IHookrStackRegistryV1 stackRegistry_,
    address protocolRecipient_
);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolManager_`|`IPoolManager`|The Uniswap v4 singleton every pool settles through|
|`stackRegistry_`|`IHookrStackRegistryV1`|The registry holding each pool's frozen stack|
|`protocolRecipient_`|`address`|The treasury forwarder, immutable for the life of the module|

### validateConfig

Structural validation. Decodes the config, enforces every bound, and returns its hash. It is `pure`, so it cannot read the recipient immutable; admission must also call `validateProtocolShare`.

```solidity
function validateConfig(bytes calldata config) external pure returns (bytes32 configHash);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`config`|`bytes`|ABI-encoded Config, exactly 640 bytes|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`configHash`|`bytes32`|keccak256 of the config bytes|

### validateProtocolShare

Admission read proving the config routes a within-ceiling share to this module's own recipient and, for an ERC-20 quote with a pot, a decimals-aware floor. Reverts `InvalidConfig` for a structurally invalid config; returns false rather than reverting for a valid config that fails either check.

```solidity
function validateProtocolShare(bytes calldata config) external view returns (bool enforced);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`config`|`bytes`|ABI-encoded Config|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`enforced`|`bool`|True when the share, the recipient and the pot floor all hold|

### requiresLockedFoundingPosition

Admission read reporting whether this config asks for a guard window, which is what makes it new-token-lane only.

```solidity
function requiresLockedFoundingPosition(bytes calldata config) external pure returns (bool required);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`config`|`bytes`|ABI-encoded Config|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`required`|`bool`|True when `guardEndBlock` is non-zero|

### validateStack

Derives the worst-case deltas this exact config may request, for the registry to check against the catalog registration. Reverts `InvalidConfig` if the config does not match the pool it is being frozen into, or if the kernel is not a stateful kernel on the same PoolManager.

```solidity
function validateStack(
    bytes32 poolId,
    address kernel,
    address subject,
    address quote,
    bytes calldata config
) external view returns (HookrModuleTypesV1.ModuleConfigCaps memory caps);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`bytes32`|The pool being created|
|`kernel`|`address`|The root hook bound to the pool|
|`subject`|`address`|The subject token|
|`quote`|`address`|The quote currency|
|`config`|`bytes`|ABI-encoded Config|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`caps`|`ModuleConfigCaps`|Config hash plus the surcharge, specified-take, unspecified-take and subject-take ceilings for this pool|

### beforeAddLiquidity

Blocks any sender other than the config's `lockedLiquidityProvider` while a guard window is open, and admission requires that field to be the coordinator whenever a guard is set. Reverts `ExternalLiquidityBlockedDuringGuard`.

```solidity
function beforeAddLiquidity(
    HookrModuleTypesV1.LiquidityContext calldata context,
    bytes calldata config
) external view returns (bool allowed);
```

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`allowed`|`bool`|True when the add may proceed|

### beforeSwapStateful

Returns the LP-fee surcharge the kernel adds to the base fee to form the override and, on an exact-input buy, computes the quote-side takes. Enforces the guard cap and the full-fill limit.

```solidity
function beforeSwapStateful(
    HookrStatefulModuleTypesV1.BeforeSwapContext calldata context,
    bytes calldata config
) external returns (HookrStatefulModuleTypesV1.BeforeSwapResult memory result);
```

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`result`|`BeforeSwapResult`|LP-fee surcharge, quote take in pips, in bps and in absolute amount, donation and escrow weights, royalty bps, claim recipient and attribution key|

### afterSwapStateful

Takes the protocol share on the unspecified quote leg, applies the burn to subject output on an exact-input buy, releases the guard's per-block buy ledger and credits `guardLpEarnedQuote`. The pot counters advance in `beforeSwapStateful`, not here.

```solidity
function afterSwapStateful(
    HookrStatefulModuleTypesV1.AfterSwapContext calldata context,
    bytes calldata config
) external returns (HookrStatefulModuleTypesV1.AfterSwapResult memory result);
```

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`result`|`AfterSwapResult`|Quote take and subject take with their recipients and attribution keys|

### beforeSwap

Reverts `StatefulKernelRequired`. A read-only kernel must never execute this module as if it were stateless.

```solidity
function beforeSwap(
    HookrModuleTypesV1.SwapContext calldata,
    bytes calldata
) external pure returns (HookrModuleTypesV1.ModuleResult memory);
```

### afterSwap

Reverts `StatefulKernelRequired`, for the same reason.

```solidity
function afterSwap(
    HookrModuleTypesV1.AfterSwapContext calldata,
    bytes calldata
) external pure returns (HookrModuleTypesV1.ModuleResult memory);
```

### claim

Pays the caller everything owed to it in one quote currency. Reverts `NothingToClaim` when the balance is zero and `ClaimTransferFailed` when the recipient's measured balance does not rise by exactly the debited amount.

```solidity
function claim(address quote) external;
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`quote`|`address`|Quote currency of the accrual; `address(0)` is native|

### claimTo

Pays the caller's balance to a different address. Reverts `ZeroAddress` for a zero recipient.

```solidity
function claimTo(address quote, address to) external;
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`quote`|`address`|Quote currency of the accrual|
|`to`|`address`|Recipient of the payment|

### claimBalance

The module's own ERC-6909 balance held on the PoolManager for one quote currency.

```solidity
function claimBalance(address quote) public view returns (uint256);
```

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|Balance of the currency id derived from `quote`|

### accountingInvariant

Per-quote solvency check. Every quote currency is backed independently.

```solidity
function accountingInvariant(address quote) external view returns (bool);
```

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bool`|True when `claimBalance(quote) >= totalClaimLiability[quote]`|

### unlockCallback

PoolManager unlock callback used only by `claim` and `claimTo`. Burns the module's ERC-6909 balance, takes the currency to the recipient, and returns the measured delta. Reverts `NotPoolManager` for any other caller and `HookNotCalled` for an unrecognised action.

```solidity
function unlockCallback(bytes calldata data) external returns (bytes memory);
```

## Events

### HookFeesAccrued

Emitted once per exact-input buy that takes an LP-reward or pot cut

```solidity
event HookFeesAccrued(
    bytes32 indexed poolId,
    uint256 burnWei,
    uint256 lpWei,
    uint256 potWeiAdded,
    uint256 royaltyWei,
    address royaltyTo
);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`bytes32`|Pool that took the cut|
|`burnWei`|`uint256`|Always zero; the burn is reported by `AutoBurn`|
|`lpWei`|`uint256`|Quote donated to in-range LPs|
|`potWeiAdded`|`uint256`|Quote added to the pot|
|`royaltyWei`|`uint256`|Quote credited to the royalty recipient|
|`royaltyTo`|`address`|Royalty recipient|

### ProtocolShareAccrued

Emitted for each stream that credits the protocol share

```solidity
event ProtocolShareAccrued(bytes32 indexed poolId, ProtocolStream indexed stream, uint256 amount);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`bytes32`|Pool the accrual belongs to|
|`stream`|`ProtocolStream`|Which add-on the slice was carved out of|
|`amount`|`uint256`|Quote credited to the protocol recipient|

```solidity
enum ProtocolStream { Surcharge, Guard, LpReward, Pot, Burn }
```

`Guard` is the snipe-tax slice and only ever accrues on an exact-input buy inside a guard window, which is what keeps guard-window revenue separable from post-guard revenue without arithmetic. A deferred slice taken in `afterSwap` is always pure surge and reports as `Surcharge`.

### JackpotHit

Emitted when a qualifying buy trips the pot counter

```solidity
event JackpotHit(bytes32 indexed poolId, address indexed winner, uint256 amountWei, uint256 buyCount);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`bytes32`|Pool that paid the pot|
|`winner`|`address`|Recipient carried in the authenticated hookData|
|`amountWei`|`uint256`|Quote credited to the winner's claim balance|
|`buyCount`|`uint256`|Qualifying-buy counter at the payout|

### AutoBurn

Emitted when subject output is withheld and sent to the dead address

```solidity
event AutoBurn(bytes32 indexed poolId, uint256 tokensBurned);
```

### LpRewardsDonated

Emitted when quote is donated to in-range liquidity inside a swap

```solidity
event LpRewardsDonated(bytes32 indexed poolId, uint256 amountWei);
```

### Claimed

Emitted when an account pulls its claim balance

```solidity
event Claimed(address indexed quote, address indexed account, address indexed to, uint256 amount);
```

## Errors

### InvalidConfig

Thrown when a config is malformed or violates any structural bound

```solidity
error InvalidConfig();
```

### StatefulKernelRequired

Thrown when a read-only kernel calls the stateless callbacks

```solidity
error StatefulKernelRequired();
```

### NotKernel

Thrown when the caller is not the pool's frozen kernel, or the frozen config hash does not match

```solidity
error NotKernel();
```

### NotPoolManager

Thrown when `unlockCallback` is called by anyone but the PoolManager

```solidity
error NotPoolManager();
```

### InvalidRuntimeContext

Thrown when the runtime pool, subject, quote or recipient does not match the config

```solidity
error InvalidRuntimeContext();
```

### MaxBuyExceeded

Thrown when a guard-window buy would push this block's total past the cap

```solidity
error MaxBuyExceeded(uint256 attemptedQuoteAmount, uint256 maxQuoteAmount);
```

### ExactOutputBlockedDuringGuard

Thrown when an exact-output buy is attempted while the guard window is open

```solidity
error ExactOutputBlockedDuringGuard();
```

### PartialFillUnsupportedWithInputCuts

Thrown when an exact-input buy with input cuts does not use the canonical full-fill price limit, or does not consume its whole input

```solidity
error PartialFillUnsupportedWithInputCuts();
```

### ExternalLiquidityBlockedDuringGuard

Thrown when a sender other than the coordinator adds liquidity during the guard window

```solidity
error ExternalLiquidityBlockedDuringGuard();
```

### InvalidPotRecipient

Thrown when a pot-qualifying buy carries a zero recipient

```solidity
error InvalidPotRecipient();
```

### NothingToClaim

Thrown when `claim` or `claimTo` finds a zero balance

```solidity
error NothingToClaim();
```

### ZeroAddress

Thrown for a zero constructor argument or a zero claim recipient

```solidity
error ZeroAddress();
```

### ClaimTransferFailed

Thrown when a claim's measured recipient balance delta does not equal the debited amount

```solidity
error ClaimTransferFailed();
```

### HookNotCalled

Thrown for an unrecognised unlock-callback action

```solidity
error HookNotCalled();
```

### ProtocolShareNotEnforced

Thrown on every swap and liquidity add when the config's share exceeds the ceiling or names a foreign recipient

```solidity
error ProtocolShareNotEnforced();
```
