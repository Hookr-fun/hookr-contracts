# HookrMarketCoordinatorV5

Source: [`src/HookrMarketCoordinatorV5.sol`](../../src/HookrMarketCoordinatorV5.sol)

**Implements:** `IUnlockCallback`

Opens a modular pool for a newly deployed token or a fresh pool for an existing token

## Identity

Two `pure` getters every contract in the graph carries, so an integrator can confirm what it is holding without a bytecode comparison.

```solidity
function contractName() external pure returns (string memory);   // "HookrMarketCoordinatorV5"
function contractVersion() external pure returns (string memory); // "5.1.0"
```

## Constants

| Name | Type | Value |
| --- | --- | --- |
| `DYNAMIC_FEE_FLAG` | `uint24` | `0x800000` |
| `SUPPLY` | `uint256` | 1,000,000,000e18 |
| `MAX_MODULE_DATA_LENGTH` | `uint256` | 3,904 |
| `MAX_PROTOCOL_SHARE_BPS` | `uint24` | 5,000 |
| `MAX_INITIAL_BUY_SUBJECT` | `uint256` | `SUPPLY * 500 / 10_000` |
| `TOKEN_SALT_DOMAIN` | `bytes32` | `keccak256("HOOKR_MARKET_COORDINATOR_TOKEN_CREATE2_V3")` |
| `BAND_TICKS` | `int24` | 207,000, the founding band's width before it is floored to a multiple of the tick spacing; the band runs from the opening tick away from the quote (upward when the token is `currency0`, downward when it is `currency1`) |

## State Variables

| Name | Type | Description |
| --- | --- | --- |
| `poolManager` | `IPoolManager` | Immutable. The v4 singleton |
| `stackRegistry` | `IHookrStackRegistryV1CoordinatorV3` | Immutable. Where stacks are frozen |
| `treasury` | `address` | Constructor-only. The treasury forwarder. There is no setter |
| `owner` | `address` | Configures tiers and the opening pause |
| `pendingOwner` | `address` | Eligible to accept ownership |
| `marketOpeningPaused` | `bool` | True while only the owner may open markets |
| `defaultProtocolShareBps` | `uint24` | Share applied when a creator has no tier; initial value 2,000 |
| `creatorTier` | `mapping(address => Tier)` | Owner-set share override, `{set, shareBps}` |
| `launchedByIntent` | `mapping(address => mapping(bytes32 => address))` | Subject deployed for a creator and intent id |
| `tokenByCreate2Salt` | `mapping(bytes32 => address)` | Subject deployed from a derived salt |

## Functions

### constructor

Reverts `ZeroAddress` for a zero argument or a codeless dependency, and `InvalidWiring` if the registry's PoolManager differs.

```solidity
constructor(
    address owner_,
    IPoolManager poolManager_,
    IHookrStackRegistryV1CoordinatorV3 stackRegistry_,
    address treasury_
);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`owner_`|`address`|Initial owner|
|`poolManager_`|`IPoolManager`|The Uniswap v4 singleton|
|`stackRegistry_`|`IHookrStackRegistryV1CoordinatorV3`|Registry used to create immutable hook stacks|
|`treasury_`|`address`|The treasury forwarder, fixed for the life of the coordinator|

### openNewTokenMarket

Deploys the subject token with CREATE2, opens its pool, places the whole supply in one coordinator-held band (any sub-unit quantization residue is burned to `0x…dEaD`), and optionally executes a creator buy in the same transaction.

```solidity
function openNewTokenMarket(NewTokenArgs calldata args, bytes32 intentId, address expectedToken)
    external
    payable
    returns (address subject, PoolId poolId);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`args`|`NewTokenArgs`|Token metadata, market parameters and the optional initial buy|
|`intentId`|`bytes32`|Optional creator intent identifier; zero skips the check|
|`expectedToken`|`address`|Optional assertion on the CREATE2 address; zero skips it|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`subject`|`address`|Deployed subject token|
|`poolId`|`PoolId`|Initialized pool|

Reverts `NotCreator` unless `args.expectedCreator == msg.sender`, `InvalidMarketArgs` unless `totalSupply` and `subjectAmount` equal `SUPPLY`, `quoteAmount` is zero and `lpFeeRecipient` is neither zero nor the coordinator, `IntentAlreadyUsed` or `TokenSaltAlreadyUsed` on replay, `InvalidPayment` on a wrong `msg.value`, `UnexpectedToken` on an address assertion mismatch, `TaxedTransfer` if the token does not mint the full supply to the coordinator, and `InitialBuyAboveCap(subjectOut, cap)` if the creator receives more than 5% of supply.

### openExistingTokenMarket

Initializes a fresh pool for an already deployed token. Permissionless, subject to the opening pause. Adds no liquidity.

```solidity
function openExistingTokenMarket(ExistingTokenArgs calldata args)
    external
    payable
    returns (PoolId poolId);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`args`|`ExistingTokenArgs`|Existing subject and market parameters, with every founding field zero|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|Initialized zero-liquidity pool|

Reverts `InvalidToken` for a subject with no code, and `InvalidMarketArgs` unless `subjectAmount`, `quoteAmount` and `lpFeeRecipient` are all zero.

`market.creator` records who called this function. It performs no ownership check on the subject token and must not be presented as one.

### collectLpFees

Collects the founding position's accrued fees and routes both currencies to the creator's `lpFeeRecipient`. Anyone may call it. It does not touch fees owned by external LP positions.

```solidity
function collectLpFees(PoolId poolId) external returns (uint256 amount0, uint256 amount1);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`poolId`|`PoolId`|New-token pool holding the founding position|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`amount0`|`uint256`|Currency0 amount collected|
|`amount1`|`uint256`|Currency1 amount collected|

Reverts `InvalidMarketArgs` for a pool the coordinator never opened, and `NoFoundingPosition` on an existing-asset market or a market with no seeded band.

### protocolShareBps

The share a market opened by this creator must carry. Two steps: the creator's tier if set, otherwise the default.

```solidity
function protocolShareBps(address creator) public view returns (uint24 shareBps);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`creator`|`address`|Account opening the market|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`shareBps`|`uint24`|Protocol share in basis points|

### setDefaultProtocolShareBps

Owner-only. Reverts `ProtocolShareAboveCeiling` above `MAX_PROTOCOL_SHARE_BPS` and `DefaultProtocolShareBpsUnchanged` on a no-op. Affects only markets opened afterwards.

```solidity
function setDefaultProtocolShareBps(uint24 shareBps) external;
```

### setCreatorTier

Owner-only, unconditional. A tier granted to a contract launcher applies to every market that contract ever opens, for every one of its users, until cleared. Reverts `ZeroAddress`, `ProtocolShareAboveCeiling`, or `CreatorTierUnchanged`.

```solidity
function setCreatorTier(address creator, uint24 shareBps) external;
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`creator`|`address`|Launcher address whose markets all carry this share|
|`shareBps`|`uint24`|Tier share in basis points; zero is allowed|

### clearCreatorTier

Owner-only. Returns a launcher to the default. Reverts `TierNotSet`.

```solidity
function clearCreatorTier(address creator) external;
```

### setMarketOpeningPaused

Owner-only. While paused, only the owner may open markets; the owner may always open. Reverts `MarketOpeningPauseUnchanged` on a no-op.

```solidity
function setMarketOpeningPaused(bool paused_) external;
```

### treasuryBeneficiary

The address the admission library compares against the module's immutable recipient.

```solidity
function treasuryBeneficiary() external view returns (address);
```

### maxInitialBuySubject

The ceiling on the subject a creator may receive from the same-transaction buy, so an interface can compute the largest quote amount that lands on it.

```solidity
function maxInitialBuySubject() external pure returns (uint256);
```

### proposeOwner

Owner-only. Names the account that may accept ownership.

```solidity
function proposeOwner(address nextOwner) external;
```

### acceptOwnership

Callable only by the pending owner.

```solidity
function acceptOwnership() external;
```

### getMarket

The full coordinator record for one pool.

```solidity
function getMarket(PoolId poolId) external view returns (Market memory market);
```

### guardLpFeeAccounting

The pool's recorded native module and its cumulative guard-window quote LP earnings. Informational; it gates no transfer.

```solidity
function guardLpFeeAccounting(PoolId poolId) external view returns (address module, uint256 cumulativeEarned);
```

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`module`|`address`|Native module recorded for this pool at creation|
|`cumulativeEarned`|`uint256`|Cumulative guard-window quote LP earnings, read from that module at its recorded code hash|

### marketCount

How many markets this coordinator has opened.

```solidity
function marketCount() external view returns (uint256);
```

### previewNewTokenAddress

The CREATE2 address a launch would produce, computable by anyone before the transaction is sent.

```solidity
function previewNewTokenAddress(NewTokenArgs calldata args, bytes32 intentId)
    external
    view
    returns (address predicted);
```

### computeNewTokenSalt

The derived CREATE2 salt for a launch.

```solidity
function computeNewTokenSalt(NewTokenArgs calldata args, bytes32 intentId) external view returns (bytes32);
```

### poolKeyFor

The sorted `PoolKey` a market's parameters produce, with `fee` set to the dynamic-fee flag.

```solidity
function poolKeyFor(address subject, MarketParams calldata params) external view returns (PoolKey memory key);
```

### unlockCallback

PoolManager unlock callback for seeding and collecting the founding band. Reverts `NotPoolManager` and `BadCallback`.

```solidity
function unlockCallback(bytes calldata data) external returns (bytes memory);
```

## Structs

### MarketParams

```solidity
struct MarketParams {
    address quote;
    uint128 subjectAmount;
    uint128 quoteAmount;
    address lpFeeRecipient;
    int24 tickSpacing;
    uint160 sqrtPriceX96;
    bytes32 kernelId;
    HookrModuleTypesV1.ModuleSelection[] modules;
    HookrModuleTypesV1.StackLimits limits;
}
```

### InitialBuyParams

```solidity
struct InitialBuyParams {
    uint128 quoteAmountIn;
    uint128 subjectAmountOutMinimum;
    uint256 deadline;
    bytes moduleData;
}
```

### NewTokenArgs

```solidity
struct NewTokenArgs {
    string name;
    string symbol;
    string tagline;
    string logoURI;
    address expectedCreator;
    uint256 totalSupply;
    bytes32 deploymentSalt;
    MarketParams market;
    InitialBuyParams initialBuy;
}
```

### ExistingTokenArgs

```solidity
struct ExistingTokenArgs {
    address subject;
    MarketParams market;
}
```

### Tier

```solidity
struct Tier {
    bool set;
    uint24 shareBps;
}
```

### MarketOrigin

```solidity
enum MarketOrigin {
    /// @notice Zero value for an absent market record.
    UNSET,
    /// @notice Market whose subject token was deployed by this coordinator.
    NEW_TOKEN,
    /// @notice Fresh market for a subject token that was already deployed.
    EXISTING_TOKEN
}
```

`MarketCreated` carries it as a `uint8`: `NEW_TOKEN` is 1, `EXISTING_TOKEN` is 2. `UNSET` never appears in an event.

### Market

What `getMarket` returns. Field order is the ABI order.

```solidity
struct Market {
    /// @notice True after the coordinator records the initialized market.
    /// @dev This flag does not indicate release activation or production availability.
    bool live;
    /// @notice Whether the subject was newly deployed or already existed.
    MarketOrigin origin;
    /// @notice Subject token paired by the pool.
    address subject;
    /// @notice Quote token, or address(0) for native currency.
    address quote;
    /// @notice Creator permanently attributed to the market.
    address creator;
    /// @notice Root hook implementation bound to the PoolKey.
    address kernel;
    /// @notice Recipient of fees earned by the founding position, or zero when absent.
    address lpFeeRecipient;
    /// @notice Registered root-hook identifier.
    bytes32 kernelId;
    /// @notice Commitment to the immutable hook stack.
    bytes32 stackHash;
    /// @notice Uniswap v4 PoolId for the market.
    PoolId poolId;
    /// @notice Initial square-root pool price encoded as Q64.96.
    uint160 sqrtPriceX96;
    /// @notice Tick spacing encoded in the PoolKey.
    int24 tickSpacing;
    /// @notice Maximum subject amount offered to the founding position.
    uint256 subjectSupplied;
    /// @notice Maximum quote amount offered to the founding position.
    uint256 quoteSupplied;
    /// @notice Subject amount consumed by the founding position.
    uint256 subjectUsed;
    /// @notice Quote amount consumed by the founding position.
    uint256 quoteUsed;
    /// @notice Cumulative currency0 fees collected from the founding position.
    uint256 cumulativeFee0;
    /// @notice Cumulative currency1 fees collected from the founding position.
    uint256 cumulativeFee1;
    /// @notice Block number at which the market record was created.
    uint256 openedAtBlock;
    /// @notice Optional creator intent identifier used by the launch.
    bytes32 launchIntentId;
    /// @notice Router that executed the initial creator buy, or zero when no buy occurred.
    address initialBuyRouter;
    /// @notice Creator token allocation; always zero for fixed-supply band launches.
    uint256 creatorAllocation;
    /// @notice Native quote amount consumed by the initial creator buy.
    uint256 initialBuyQuoteIn;
    /// @notice Subject amount delivered by the initial creator buy.
    uint256 initialBuySubjectOut;
    /// @notice Minimum subject output required by the initial creator buy.
    uint256 initialBuySubjectOutMinimum;
    /// @notice Hash of module data supplied to the initial creator buy.
    bytes32 initialBuyModuleDataHash;
}
```

`creatorAllocation` is never written and is always zero in this release.

## Events

### MarketCreated

Emitted after a market is initialized and recorded

```solidity
event MarketCreated(
    PoolId indexed poolId,
    address indexed subject,
    address indexed creator,
    address quote,
    MarketOrigin origin,
    address kernel,
    address lpFeeRecipient,
    bytes32 kernelId,
    bytes32 stackHash,
    uint160 sqrtPriceX96,
    int24 tickSpacing,
    uint256 subjectUsed,
    uint256 quoteUsed
);
```

### ProtocolShareResolved

Emitted once per market with the share frozen into its immutable config

```solidity
event ProtocolShareResolved(PoolId indexed poolId, address indexed creator, uint24 shareBps);
```

### CreatorBuyExecuted

Emitted after an optional initial creator buy settles

```solidity
event CreatorBuyExecuted(
    PoolId indexed poolId,
    address indexed subject,
    address indexed creator,
    bytes32 intentId,
    bytes32 stackHash,
    address router,
    uint256 requestedQuoteIn,
    uint256 actualQuoteIn,
    uint256 subjectOut,
    uint256 subjectOutMinimum,
    bytes32 moduleDataHash,
    uint256 creatorAllocation,
    uint256 subjectSeedResidue,
    uint256 quoteSeedResidue
);
```

### LpFeesCollected

Emitted after founding-position fees are collected and routed

```solidity
event LpFeesCollected(PoolId indexed poolId, address indexed recipient, uint256 amount0, uint256 amount1);
```

### Other events

`OwnerProposed`, `OwnerSet`, `MarketOpeningPauseSet`, `DefaultProtocolShareBpsSet`, `CreatorTierSet`, `CreatorTierCleared`.

## Errors

`NotOwner`, `NotPendingOwner`, `MarketOpeningPaused(caller)`, `MarketOpeningPauseUnchanged`, `ZeroAddress`, `InvalidWiring`, `InvalidMarketArgs`, `InvalidToken`, `UnexpectedToken(expected, actual)`, `NotCreator(expected, caller)`, `ProtocolShareAboveCeiling(shareBps)`, `DefaultProtocolShareBpsUnchanged`, `CreatorTierUnchanged(creator)`, `TierNotSet(account)`, `IntentAlreadyUsed(creator, intentId, subject)`, `TokenSaltAlreadyUsed(create2Salt, subject)`, `InvalidPayment(expected, received)`, `InvalidInitialBuy`, `InitialBuyInputMismatch(expected, actual)`, `InitialBuyAboveCap(subjectOut, cap)`, `InvalidStack`, `NativeMechanicsModuleRequired`, `DuplicateMarket(poolId)`, `NoFoundingPosition(poolId)`, `ZeroLiquidity`, `ExcessiveSettlement`, `TransferFailed`, `TaxedTransfer`, `NativeTransferFailed`, `NotPoolManager`, `BadCallback`, `ReentrantCall`.
