# HookrMarketCoordinatorTokenDeployerV3

Source: [`src/HookrMarketCoordinatorV3.sol`](../../src/HookrMarketCoordinatorV3.sol)

A linked library. Deploys a new-token market's subject token with CREATE2 and derives its founding band

Linked rather than inlined because the coordinator's runtime has to stay inside the EIP-170 limit. It executes by `DELEGATECALL`, so the token is deployed from the coordinator's address and the CREATE2 address depends on the coordinator, not the library.

## Functions

### deploy

Deploys one `HookrTokenV61` with the given salt, minting the whole supply to the caller's context.

```solidity
function deploy(
    string calldata name,
    string calldata symbol,
    string calldata tagline,
    string calldata logoURI,
    address creator,
    uint256 totalSupply,
    bytes32 create2Salt
) public returns (address subject);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`name`|`string`|Token name|
|`symbol`|`string`|Token symbol|
|`tagline`|`string`|Metadata tagline|
|`logoURI`|`string`|Metadata image URI|
|`creator`|`address`|Creator recorded by the token|
|`totalSupply`|`uint256`|Fixed supply minted at deployment|
|`create2Salt`|`bytes32`|Salt derived from the launch arguments and the intent id|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`subject`|`address`|Deployed token|

### initCodeHash

The creation-code hash for a set of constructor arguments, so any caller can predict the CREATE2 address before the launch transaction is sent.

```solidity
function initCodeHash(
    string calldata name,
    string calldata symbol,
    string calldata tagline,
    string calldata logoURI,
    address creator,
    uint256 totalSupply
) public pure returns (bytes32);
```

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bytes32`|Creation-code hash used to predict the address|

Prefer the coordinator's `previewNewTokenAddress`, which composes this with the salt derivation.

### foundingTickRange

Derives the bounded token-only sell band around the exact initialized tick.

```solidity
function foundingTickRange(address subject, PoolKey calldata key, uint160 sqrtPriceX96, int24 bandTicks)
    public
    pure
    returns (bool valid, int24 tickLower, int24 tickUpper);
```

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`valid`|`bool`|False when the opening price is not exactly on a usable tick|
|`tickLower`|`int24`|Lower edge of the band|
|`tickUpper`|`int24`|Upper edge of the band|

The opening price must sit exactly on a usable tick, because that tick is the band's edge on the quote side: the lower edge, with the supply above it, when the token is `currency0`, and the upper edge, with the supply below it, when the token is `currency1`. The coordinator rejects a `sqrtPriceX96` that does not.

### seedBand

Mints the founding position into the band `foundingTickRange` derived, inside the coordinator's own `unlock` callback.

```solidity
function seedBand(
    IPoolManager poolManager,
    PoolKey calldata key,
    uint160 sqrtPriceX96,
    int24 tickLower,
    int24 tickUpper,
    uint256 amount0,
    uint256 amount1
) public returns (bool valid, uint256 used0, uint256 used1);
```

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`valid`|`bool`|False when the requested amounts resolve to zero liquidity|
|`used0`|`uint256`|`currency0` actually consumed|
|`used1`|`uint256`|`currency1` actually consumed|

The amounts consumed are usually below the amounts offered, because liquidity is quantised. The coordinator burns the remainder to `0x…dEaD`; the residue fields of `CreatorBuyExecuted` are always zero.

### collectBand

Collects the accrued LP fees of the founding position without touching its liquidity. There is no path here that removes it.

```solidity
function collectBand(IPoolManager poolManager, PoolKey calldata key, int24 tickLower, int24 tickUpper)
    public
    returns (bool valid, uint256 amount0, uint256 amount1);
```

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`valid`|`bool`|False when the position does not exist|
|`amount0`|`uint256`|`currency0` fees collected|
|`amount1`|`uint256`|`currency1` fees collected|

This is what `HookrMarketCoordinatorV5.collectLpFees` calls. The routing of the collected amounts is `HookrNativeMechanicsCoordinatorLibV2.routeFoundingPositionFees`, which sends all of both currencies to the market's `lpFeeRecipient`.

## The Token It Deploys

`HookrTokenV61` is a fixed-supply ERC-20. 18 decimals, the whole supply minted once at construction, `name`, `symbol`, `tagline`, `logoURI`, `creator` and `launchpad` recorded on the token. No owner, no mint, no burn, no pause, no blocklist, no transfer tax.

It also tracks `weightedAcquiredAt` per holder and exposes `holdingAge(account)`, which other Hookr surfaces read. Neither affects transfers or pool math.
