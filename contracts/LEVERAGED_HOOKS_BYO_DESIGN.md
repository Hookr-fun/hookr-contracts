# Leveraged Hooks for existing tokens — design spec

Status: **DRAFTED IN SOURCE, NOT DEPLOYED.** `src/LeverageExistingTokenFactory.sol` and its
suite `test/LeverageExistingTokenFactory.t.sol` implement this document (10 tests: the
end-to-end credit loop over a foreign token, plus refusal of fee-on-transfer,
no-return, false-returning, EOA and duplicate tokens, reentrancy neutralization, dust and
surplus refunds, stray-ETH refusal). Nothing is on chain: go-live still requires the
adversarial review passes, the deploy→verify→promote pipeline below, and an operator
broadcast. Until then every surface labels this route undeployed (see
`src/lib/module-market.ts` `EXISTING_TOKENS` and the create-market panel copy). Prepared
2026-08-13 against the live generation (factory `0xa8566BB5…`, hook `0x81DEc5…`, router
`0x148bBc…`, chain 4663).

## Why a new generation is required (verified against deployed source)

Four independent blocks, each sufficient, none operator-overridable:

1. `LeverageFactory.createMarket(name, symbol, tagline, logoURI, supply, sqrtPriceX96,
   seedLiquidity, cfg)` has **no token parameter** — it mints its market's own
   `HookrToken` via `LeverageTokenDeployLib.deployToken` (LeverageFactory.sol:66-78).
2. `LeverageHook.setFactory` is deployer-only and **one-shot, already consumed**
   (LeverageHook.sol:185-190 `FactoryAlreadySet`) — a new factory cannot register pools on
   the live hook.
3. `LeverageHook.beforeInitialize` rejects any pool whose id was not registered by its
   factory (`PoolNotRegistered`, LeverageHook.sol:266-267).
4. In v4 the hook address is part of the `PoolKey`, so no existing pool can ever adopt a
   hook after creation — BYO is always a **new pool** plus voluntary liquidity migration,
   never a retrofit.

The strategically useful facts going the other way:

- **The engine is already token-agnostic.** `LeverageMarket`'s constructor takes an
  arbitrary `PoolKey` and derives its token from `key.currency1`
  (LeverageMarket.sol:139-158); nothing in the credit ledger assumes the token is fresh.
- **`createMarket` is permissionless with zero admin surface** — the BYO product inherits
  self-serve, which is the marketplace-correct shape.

## The new generation, smallest honest scope

### 1. `LeverageFactoryB` (working name)

```
createMarket(
    address token,          // pre-existing ERC20; replaces name/symbol/tagline/logoURI/supply
    uint256 tokenAmount,    // pulled via transferFrom(msg.sender) to seed the pool's token leg
    uint160 sqrtPriceX96,   // opening price — MUST match where the token already trades (caller-attested)
    uint128 seedLiquidity,
    ILeverage.MarketConfig calldata cfg
) external payable returns (address marketAddr)
```

- Pulls `tokenAmount` with `transferFrom` and **verifies received == requested by balance
  delta** — this is the fee-on-transfer gate (below), not a courtesy check.
- One market per token per factory, as today (`marketOf` mapping).
- Metadata (name/symbol) is read from the token, never supplied — a BYO market must not be
  able to impersonate a different token's identity.
- The opening price is caller-supplied, exactly like the live factory's, and equally
  caller-attested: a price far from the token's real market is arbitraged against the
  seeder, and the credit engine's own capacity floor (min of liquidity, executable
  liquidation depth, bond, protocol limit) is the systemic guard. State this in UI copy
  rather than pretending the factory can verify an external market's price.

### 2. `LeverageHookB` — unavoidable new deploy

Re-mine a CREATE2 salt for `REQUIRED_FLAGS` (`0x3AC0` family; the constructor self-checks
`uint160(address(this)) & 0x3FFF == REQUIRED_FLAGS`, LeverageHook.sol:41-42, :172). Bind
`setFactory` once to `LeverageFactoryB`. Hook logic itself should be reusable unchanged;
any change to its bytecode changes the mined address — plan the salt search into the
deploy script as the live generation already does.

### 3. `LeverageMarket` — reused byte-identical (better than the first draft hoped)

Building the factory corrected this section: **no engine delta is needed at all.**
`seedLiquidity` already returns dust to its caller (the factory), and both factories
forward it to `msg.sender`; the constructor already derives the token from
`key.currency1` and records `factory = msg.sender`. The engine that was audited is the
engine that ships.

### 4. The new risk class BYO introduces: arbitrary ERC20 behavior

`HookrToken` is fixed-supply, non-rebasing, non-taxing, callback-free. An arbitrary token
is none of those by default, and each violation breaks a different invariant:

| Token behavior | What it breaks | Gate |
|---|---|---|
| fee-on-transfer / tax | `transferFrom` amount ≠ received; seed + collateral accounting overstate | balance-delta check on every inbound transfer; **refuse** mismatches outright |
| rebasing / elastic supply | collateral quantity drifts under the ledger | not supportable — document as excluded; detectability is imperfect, so the terms say "unsupported", the UI warns, and the capacity floor limits blast radius |
| ERC777-style callbacks / reentrancy | re-entry during seed/liquidation flows | the factory holds a creation-wide reentrancy lock (a foreign `transferFrom` is a call into unreviewed code); the market keeps v4's lock discipline |
| non-standard returns (USDT-style) | not a here-and-now failure: the ENGINE's typed `IERC20Like` declares `returns (bool)`, so a no-return token reverts *inside the engine later* — worst case on the transfer a liquidation depends on | **refused at creation**: the factory's token calls require a decodable `true` (stricter than a SafeTransferLib on purpose), so a token the engine cannot run never gets a market |
| pausable / blocklistable tokens | liquidations can be bricked by the token's own admin | cannot be prevented; must be named in terms + market page ("this market's token can pause transfers") if detectable, and priced by LPs if not |

This table is the heart of the adversarial review scope for the milestone — the credit
engine's math was audited under a well-behaved token; every proof that leaned on that
assumption gets re-examined.

### 5. Thin-market honesty (already designed, keep it)

`EXISTING_TOKENS.edge` in `module-market.ts` states the trade-off the UI must keep making:
two markets for one token, the new one thinner, and the credit engine **refuses to lend
much against thin liquidity by construction** (capacity = min of its inputs). The TWAP
also needs its warm-up on a fresh pool before credit opens — same behavior as today's
fresh markets, worth restating in the BYO flow copy.

## Go-live gates (house method, unchanged)

Deploy script mines the salt and one-shots `setFactory`; a verify script authenticates the
broadcast against live RPC (receipts by contract NAME, not count — the live generation's
mainnet lesson: a CREATE2 lib already on chain drops a tx from the artifact); promotion
writes a generated json the UI gate parses (`{"current": null}` until then); `--rehearsal`
against an anvil fork proves the whole flow without a write; adversarial review passes with
PoC-verified fixes before broadcast (finder consensus is not evidence); `forge fmt --check`
before push. The UI side reuses `LEVERAGE_UI_WRITES_WIRED` — the BYO create flow ships as
its own wired action with its own behavior tests.

## Explicitly out of scope for this milestone

Launchpad-side power-ups for foreign tokens (fee blocks/guard/jackpot need a new
`HookrHook` with a different authorization model — heavier, separate decision); the bonded
module marketplace contracts; any change to the live leverage generation, which continues
to serve factory-minted markets untouched.
