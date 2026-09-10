# Hook permissions

The Hookr root hook is `HookrModularHookV6`. Its address is mined so the low fourteen bits equal `0x28cc`, which is six permissions.

## The Permissions Struct

```solidity
Hooks.Permissions({
    beforeInitialize: true,
    afterInitialize: false,
    beforeAddLiquidity: true,
    afterAddLiquidity: false,
    beforeRemoveLiquidity: false,
    afterRemoveLiquidity: false,
    beforeSwap: true,
    afterSwap: true,
    beforeDonate: false,
    afterDonate: false,
    beforeSwapReturnDelta: true,
    afterSwapReturnDelta: true,
    afterAddLiquidityReturnDelta: false,
    afterRemoveLiquidityReturnDelta: false
});
```

The root does not inherit `BaseHook` and does not expose `getHookPermissions()`. It pins the same set as a constant instead:

```solidity
uint160 public constant REQUIRED_FLAGS =
    uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
```

That value is 10444 decimal, `0x28cc` hex. The CREATE2 mining target is `requiredFlags = 0x28cc` under `mask = 0x3fff`, and the accounting kernel's own `REQUIRED_FLAGS` is checked against the root's at construction.

## Bit Mapping

| Bit | Flag | Permission | Set |
| --- | --- | --- | --- |
| 13 | `BEFORE_INITIALIZE_FLAG` | `beforeInitialize` | yes |
| 12 | `AFTER_INITIALIZE_FLAG` | `afterInitialize` | no |
| 11 | `BEFORE_ADD_LIQUIDITY_FLAG` | `beforeAddLiquidity` | yes |
| 10 | `AFTER_ADD_LIQUIDITY_FLAG` | `afterAddLiquidity` | no |
| 9 | `BEFORE_REMOVE_LIQUIDITY_FLAG` | `beforeRemoveLiquidity` | no |
| 8 | `AFTER_REMOVE_LIQUIDITY_FLAG` | `afterRemoveLiquidity` | no |
| 7 | `BEFORE_SWAP_FLAG` | `beforeSwap` | yes |
| 6 | `AFTER_SWAP_FLAG` | `afterSwap` | yes |
| 5 | `BEFORE_DONATE_FLAG` | `beforeDonate` | no |
| 4 | `AFTER_DONATE_FLAG` | `afterDonate` | no |
| 3 | `BEFORE_SWAP_RETURNS_DELTA_FLAG` | `beforeSwapReturnDelta` | yes |
| 2 | `AFTER_SWAP_RETURNS_DELTA_FLAG` | `afterSwapReturnDelta` | yes |
| 1 | `AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG` | `afterAddLiquidityReturnDelta` | no |
| 0 | `AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG` | `afterRemoveLiquidityReturnDelta` | no |

The authoritative bit list is [`Hooks.sol`](https://github.com/Uniswap/v4-core/blob/main/src/libraries/Hooks.sol) in v4-core.

Note the two spellings. `Hooks.Permissions` uses `beforeSwapReturnDelta` and `afterSwapReturnDelta`. Uniswap's hooklist schema uses `beforeSwapReturnsDelta` and `afterSwapReturnsDelta`. The hooklist entry in this repository uses the hooklist spelling; everything else uses the struct spelling.

## What Each Permission Is For

### beforeInitialize

Accepts pool initialization only from `HookrMarketCoordinatorV5`, only once per `PoolId`, and only when the `PoolKey` matches the stack the registry already froze for that `PoolId`. This is what makes a Hookr pool impossible to create by any path other than the coordinator, and what guarantees every pool that names this hook has a frozen configuration behind it.

### beforeAddLiquidity

Runs the module's liquidity check. Its only effect today is the guard-window lock: while a new-token pool's guard window is open, any sender other than the coordinator reverts `ExternalLiquidityBlockedDuringGuard`. Outside the window it returns true for everyone.

There is no corresponding removal permission. Removing liquidity is never hooked, so no Hookr rule can trap an LP position.

### beforeSwap

Sets the effective LP fee for this swap and, on an exact-input buy, takes the quote-side cuts as a `BeforeSwapDelta` on the specified currency.

### afterSwap

Takes the protocol share on the unspecified quote leg, applies the auto-burn to subject output, and updates the guard and pot counters. It returns an `int128` delta on the unspecified currency.

### beforeSwapReturnDelta and afterSwapReturnDelta

Both are required because the hook moves value in both phases. `beforeSwapReturnDelta` carries the LP-reward, pot and protocol takes off the specified quote input. `afterSwapReturnDelta` carries the burn and the unspecified-leg protocol take.

A hook with a return-delta permission can hold value outside the curve. Hookr's is bounded twice: the catalog registration fixes a structural ceiling on what any module may ever request, and the pool's own frozen `StackLimits` fix a lower per-pool ceiling that the accounting kernel enforces on every callback.

## The Dynamic Fee Flag

Every Hookr pool sets `PoolKey.fee = 0x800000`. The coordinator refuses to open a pool with any other value, and the router and quoter both refuse to serve one.

The hook sets the fee per swap by returning an override from `beforeSwap`. It also exposes `syncBaseFee(PoolKey)`, to be called at the root hook's address (it runs in the accounting kernel by `DELEGATECALL`; the PoolManager accepts a dynamic-fee update only from the pool's hook), which pushes the pool's frozen `baseLpFeePips` into the PoolManager's dynamic-fee cache for any caller that reads it directly.

Fees are in pips: 3,000 pips is 0.30%, and `MAX_TOTAL_FEE_PIPS = 500_000` is 50%.

## Hooklist Entry

`hooklist/robinhood-4663.template.json` carries this flag set in the shape Uniswap's hooklist expects, with the root hook's live address filled in. The audit URL is a placeholder until a report exists because no audit report exists.
