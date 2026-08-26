# Hookr hooks for existing tokens — gen-5 "attach" design spec

Status: **CANDIDATE — DRAFTED IN SOURCE, UNAUDITED, NOT DEPLOYED.**
`src/HookrAttachHook.sol` and `src/HookrExistingTokenFactory.sol` with suite
`test/HookrExistingTokenFactory.t.sol` implement this document (the end-to-end
attach→trade→collect→claim loop over a foreign 18-decimals token, plus refusal of
fee-on-transfer, no-return, false-returning, EOA, non-18-decimals and duplicate tokens,
unplaceable-band refusal at validation, reentrancy neutralization on both the pull and the
CB_SEED settle paths, stray-ETH refusal, dust and surplus refunds, leftover-refund
accounting, the ERC-6909 burn-refusal fallback, the guard-window LP block with factory
exemption AND guard-era fee withholding through the attach pair, hook-economics
composition over a foreign token, the planned-placement cap basis with a saturating
near-edge clamp, preview/execution equivalence, and preview/attach revert parity).
Nothing is on chain: go-live still requires the adversarial review passes, the
deploy→verify→promote pipeline below, and an operator broadcast. Prepared 2026-08-14
against the launchpad generation live on chain 4663.

## Why a new generation is required (same shape as the leverage BYO memo)

1. `HookrLaunchpad` has **no attach path** — both launch paths mint their own `HookrToken`
   and `_create` rejects nothing else because nothing else can reach it.
2. `HookrHook.beforeInitialize` requires `sender == launchpad`, and `configurePool` is
   launchpad-only — the live hook can never serve a pool the launchpad did not open.
3. In v4 the hook address is part of the `PoolKey`, so no existing pool can adopt a hook
   after creation — attach is always a **new pool** plus voluntary liquidity migration,
   never a retrofit.

## Mechanism

`HookrExistingTokenFactory.attach(AttachArgs)` opens a native-ETH Uniswap v4 pool for a
token the caller already owns, wearing the caller's configured Hookr blocks:

- **Pool key, hardcoded:** currency0 = native ETH, currency1 = the token, dynamic-fee
  flag, tickSpacing 60, hooks = the attach-generation hook. Fully determined by the token
  address.
- **Ordering, ported from the launchpad's `openPool`:** `configurePool` (register on the
  hook BEFORE initialize) → `poolManager.initialize` at the caller-attested price →
  `syncBaseFee` → seed the founding full-range position inside one unlock → seed the
  token-only bands (max 4, above the open price). Unlike the launchpad, bands are NOT
  skip-don't-revert at seed time: because the seed executes in the same transaction at
  exactly the attested price, `_validateBands` prices every band up front and reverts
  `BadLpPlan` on any band that would collapse under alignment, leave the usable range,
  quantize its token slice to zero, or price to zero liquidity. **Planned == placed,
  always** — the seed loop's skip branches survive only as unreachable defense-in-depth.
- **Payment:** `msg.value` = `creationFeeWei` + seed ETH, exactly; unconsumed seed ETH and
  unplaced tokens refund in the same transaction.
- **Locked by construction:** the only `modifyLiquidity` calls the factory can reach carry
  positive or exactly-zero liquidity deltas (CB_SEED, CB_BAND mint; CB_COLLECT pokes with
  zero). No function takes a negative delta; positions are factory-owned forever.
- **Fees:** `collectPoolFees` is permissionless; the ETH side splits creator/protocol
  (default 5000 bps to the creator, max 8000, protocol always ≥ 2000), guard-window
  earnings withheld to protocol against the hook's cumulative `guardLpEarnedWei`
  high-water mark; the token side burns to DEAD with an ERC-6909 fallback (below).
  **`creatorFeeBps` convention:** `0` in `AttachArgs` means "use the 5000-bps default" —
  the launchpad's convention, kept deliberately — so an explicit ZERO-fee attach is not
  expressible this generation. A creator who wants to renounce fees can point
  `setCreatorPayout` at a burn address or simply never claim; a first-class 0-bps encoding
  would need a sentinel field and is out of v1 scope.
- **Preview:** `previewAttach(args, ethForPool)` runs every validation `attach` runs and
  computes amounts with the pool's own rounding (`SqrtPriceMath`, round-up on deposits),
  so a successful preview matches execution wei-for-wei.
- **Blueprints:** v1 accepts raw `HookParams` only. A blueprint-id attach would read the
  launchpad's public `getBlueprint` cross-contract and could not bump its `uses` counter
  (that write is launchpad-internal) — out of v1 scope rather than shipped half-working.

## The authorization diff (`HookrAttachHook` vs `HookrHook`)

The hook is a copy of `HookrHook` whose ONLY intended change is the authorizing identity:
the single immutable `launchpad` becomes the single immutable `factory` (constructor arg),
renaming `NotLaunchpad` to `NotFactory` and updating the comments that named the party.
Same `REQUIRED_FLAGS`, same fee invariants in `configurePool` (50% total-fee ceiling, ≤10%
combined cuts, dead `burnTriggerWei` rejected), same one-shot write-once `configurePool`
per poolId — now factory-only — same `beforeInitialize` sender gate, same guard-window LP
exemption identity. Deliberately NOT a multi-initializer ACL: one immutable authority, no
setter, no owner path, so the fail-closed 1:1 hook↔deployer binding of the launchpad
generation carries over unchanged. The audit diff is ~40 changed lines per side and
mechanically reviewable; everything else is byte-equal.

Deployment is the leverage-BYO recipe: predict the factory's CREATE address, mine the
hook's CREATE2 salt against `REQUIRED_FLAGS` with that address as the constructor arg,
deploy the hook, deploy the factory — whose constructor re-runs `HookrLaunchpad.setHook`'s
checks (flag bits, `hook.factory() == address(this)`, shared PoolManager) and refuses to
construct if any leg of the binding is wrong.

## Deliberate departures from the launchpad / BYO recipes

| # | Departure | Constraint that forces it |
|---|---|---|
| a | No per-token uniqueness mapping | A factory-owned uniqueness slot is a squatting surface with its own semantics to defend. The PoolKey is fully determined by the token address, so the hook's one-shot `configurePool` (and v4's own initialize) already make a second attach of the same token impossible. |
| b | `decimals() == 18` required (`NonStandardDecimals`) | All price/tranche/guard math assumes 18/18 between ETH and the token — the same assumption pools.trade enforces. A 6-decimals token would be off by 10^12 in every derived figure. |
| c | Leftover / unplaceable tokens REFUND, never burn — and unplaceable BANDS are refused at validation | The launchpad burns leftovers because it minted them and nobody ever owned them; here every token is the caller's property. The launchpad must also keep bands skippable at seed time because price moves between plan and graduation; an attach has no such gap — the seed executes at the attested price in the same transaction — so band collapse is computable at validation and `_validateBands` reverts `BadLpPlan` instead of silently skip-refunding. Planned placement (`_capTokens`, the anti-snipe cap basis) therefore always equals seeded depth. The seed/collection skip branches remain as unreachable defense-in-depth (a revert inside an unlock callback cannot be skipped, and an absent-band poke would brick collection forever). |
| d | Token-side fee burn falls back to ERC-6909 claims | The burn target is foreign code that can refuse a transfer to DEAD (blocklist, pause). The positive currency delta MUST still resolve inside the unlock — a bare try/catch leaves `NonzeroDeltaCount` and bricks the WHOLE unlock, ETH side included. On refusal the amount mints to the factory as native ERC-6909 claims (`deferredBurnClaims`), and permissionless `retryDeferredBurn` completes the burn whenever the token allows it. |
| e | Anti-snipe cap basis = planned placement (`tokenAmount + bandTokenAmount`) | The instant path's precedent: the cap bounds a buy against pool DEPTH. A foreign token's `totalSupply()` is whatever its code says — an attacker-chosen number is no basis for a guard. A cap that quantizes to zero wei fails closed (`BadHookParams`) instead of silently meaning "uncapped". |
| f | Guard-window LP exemption identity = this factory | The hook's `beforeAddLiquidity` exempts `sender == factory`, so the attach transaction can seed its own positions while the guard it just configured is already live. |

## Token-behavior gates

| Token behavior | What it breaks | Gate |
|---|---|---|
| fee-on-transfer / tax | seed and refund accounting assume amounts move whole | balance-delta equality on the inbound pull; **refused** (`TaxedTransfer`) |
| non-standard returns (USDT-style / false-returning) | v4 settlement and the factory's refund path expect a decodable `true` | every token call requires success AND ≥32 return bytes AND `true`; **refused** (`TokenCallFailed`) |
| non-18 decimals | every derived price/cap figure off by orders of magnitude | `decimals()` read at attach; **refused** (`NonStandardDecimals`) |
| rebasing / elastic supply | pool balances drift under positions the factory can never rebalance | **undetectable on chain** — excluded by terms, disclosure-only; the UI must warn |
| ERC777-style callbacks / reentrancy | re-entry during attach flows | creation-wide reentrancy lock spanning every entrypoint that calls token code |
| pausable / blocklistable | trading and the token-side fee burn can be halted by the token's own admin | cannot be prevented; disclosure-only for trading. The fee path specifically is protected by departure (d) so a hostile token cannot brick ETH-side fee collection. The `burnBps` swap path has a sharper edge, stated precisely in Risks below |

## Risks, stated plainly

- **Caller-attested price.** No contract can read an external venue's price. A price far
  from the real market is arbitraged against the attacher's own seed; the UI must say so
  before anyone signs.
- **Permissionless-many junk pools.** Anyone can attach any token at any price. Discovery
  surfaces must not imply curation, and the first-mover claims the token's ONE pool slot
  in this generation (the PoolKey is token-determined) — a griefer can squat a project's
  slot with a junk price; the project's remedies are migration liquidity elsewhere or a
  later generation.
- **Two-pools divergence.** An attached token usually already trades somewhere else; the
  two venues will disagree, and the thinner (usually the attach pool) is the one that
  moves. Same honesty copy as the leverage BYO flow.
- **Locked-forever seed.** The founding position has no removal path by construction. The
  attacher must understand the seed is spent, not parked.
- **Guard-window griefing on tiny seeds.** A guard configured over a dust-deep pool is
  decoration, and the guard-window fee withholding means a creator who trades their own
  guarded pool donates that tax to protocol. Configure the guard against the actual float.
- **Deferred burns are factory-held claims.** Until `retryDeferredBurn` succeeds, refused
  token-side fees sit as ERC-6909 claims owned by the factory. They are spendable by no
  one (no factory function moves them except the retry-burn), but they are not yet burned
  and supply-tracking UIs must not claim they are.
- **The DEAD-blocklist buy brick, named precisely.** A token admin who blocklists ONLY the
  dead address selectively bricks every exact-input buy on a pool configured with
  `burnBps > 0`, while the token trades normally everywhere else: the hook's `afterSwap`
  takes the burn cut to `0xdEaD` inside the swap, the token's transfer refusal reverts
  that `take`, and the whole swap reverts atomically with it — no funds are lost, the pool
  is merely un-buyable until the token unblocks DEAD (sells and exact-output buys pay no
  burn cut and keep working). The candidate fix — a deferred-burn fallback in the hook's
  `afterSwap`, mirroring the factory's collection-time ERC-6909 fallback — is deliberately
  NOT taken in this generation because the hook's audit value is byte-equality with
  `HookrHook`; the adversarial cycle decides whether that trade holds. Pinned by
  `test_burnBpsWithDeadBlocklistedTokenRevertsBuysAtomically`.

## Go-live gates (house method, unchanged)

1. **PoC-verified adversarial review.** Invariant-green is NOT evidence — the leverage
   audit history ran green through four live criticals; only verify-with-PoC separates
   real from plausible, and finder consensus is not evidence either. The token-behavior
   table above is the review scope: every hook-economics proof was made under a
   launchpad-minted token and gets re-examined under an arbitrary one.
2. **Deploy→verify→promote.** Deploy script predicts the factory address, mines the hook
   salt, deploys hook then factory; a verify script authenticates the broadcast against
   live RPC by contract NAME, not count (the live generation's lesson: a CREATE2 lib
   already on chain drops a tx from the artifact); promotion writes the generated json
   the UI gate parses (`{"current": null}` until then); `--rehearsal` against an anvil
   fork proves the whole flow without a write.
3. **Canary attach on a throwaway token first** — a real broadcast against a token that
   matters to nobody, held through a full guard window and one fee-collection cycle,
   before any real token is invited in. The utility-V3 canary lesson applies: pick the
   observation window before the broadcast, not after.
4. `forge fmt` and the full suite green before push; UI wiring ships behind
   `LEVERAGE_UI_WRITES_WIRED`-style gates as its own PR.

## Explicitly out of scope for v1

Blueprint-id attaches and blueprint royalties (cross-contract `uses` bump has no honest
implementation from here); multi-pool-per-token (the PoolKey has no salt); fee-recipient
splits beyond creator/protocol; any change to the live launchpad or leverage generations,
which continue serving their pools untouched.

## Sizing note (why there is no HookrAttachLib)

`HookrLaunchpad` needs its DELEGATECALL library because the token creation code plus curve
walk pushed it to 28,134 bytes. The attach factory carries neither: measured at 17,481
bytes deployed (7,095 under the EIP-170 limit) with everything inlined, so a
`HookrAttachLib` would be a second deploy transaction and a verify-list entry purchased
for nothing. Do not add one until a measured build actually needs it.
