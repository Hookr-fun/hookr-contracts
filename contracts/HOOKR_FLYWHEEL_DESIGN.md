# The HOOKR flywheel — generation-5 quote currencies and the buyback burn

Decision record, 2026-08-20, folded into the generation-5 launch before its first promotion
(nothing prior shipped; the abandoned first deployment predates this design). User decisions:
guard + surge only on HOOKR pairs; 0.3% flywheel fee on buys AND sells of ETH pairs; fixed
HOOKR instant open of 2,500,000 HOOKR (deliberately below today's ETH-lane parity — priced for
HOOKR appreciation).

## The loop

1. Every swap on an ETH-quoted generation-5 pool pays a 0.3% protocol fee (`FLYWHEEL_FEE_PIPS =
   3000`), accrued by the hook as native ERC-6909-backed claims to `HookrFlywheelBurner`.
2. Anyone may `collect()` the burner's accrued ETH from the hook. Spending that protocol ETH is
   deliberately different: only the burner owner may call `buybackAndBurn(ethIn, minHookrOut)`.
   Each market buy is capped per call, limited to one per block, and must carry an owner-reviewed
   minimum HOOKR output. It routes through the canonical ETH/HOOKR v4 pool (`0x590dcb…`:
   currency0 ETH, currency1 HOOKR, fee 2500, tick spacing 25, hookless), with every HOOKR received
   transferred to `0xdEaD` in the same transaction.
3. Launches may choose HOOKR as their quote currency. HOOKR-paired pools pay NO flywheel fee and
   the launchpad routes 100% of their collected LP fees to the creator — the pairing incentive.

## Fee mechanics (hook)

`PoolConfig` gains `flywheelFeePips` (set by the launchpad: 3000 for ETH quotes, 0 for HOOKR).
The fee is taken on the ETH side of the swap in the three quadrants where v4's exact-amount
semantics allow an ETH-side take:

| quadrant        | ETH position    | where taken                                  |
|-----------------|-----------------|----------------------------------------------|
| buy, exact-in   | specified (in)  | beforeSwap specified delta (same shape as the cut machinery) |
| buy, exact-out  | unspecified (in)| afterSwap unspecified delta                  |
| sell, exact-in  | unspecified (out)| afterSwap unspecified delta                 |
| sell, exact-out | specified (out) | EXEMPT — taking ETH would break the exact output |

The sell-exact-out exemption is a documented dust leak (avoiding 0.3% requires routing every
sell as exact-output), accepted over breaking exact-out semantics or charging a token-denominated
fee with no flywheel value. The auto-burn's afterSwap token delta (exact-in buys) and the
flywheel's afterSwap ETH delta (exact-out buys / exact-in sells) never target the same swap's
unspecified currency, so the single return delta never carries both.

The stated docs principle becomes "no punitive exit taxes": the 0.3% protocol fee applies on
exit, the guard's snipe tax never does.

## Quote currencies (launchpad)

- `launchInstant(args, quote, intentId)` / `launchAuction(args, quote, floorFdvWei,
  raiseFloorWei, reserveBps, intentId)` with `quote ∈ {Eth, Hookr}`. Floors are denominated in
  the quote currency.
- HOOKR immutables: token `0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c`, fixed instant FDV
  2,500,000 HOOKR with its own precomputed band (constructor-validated like the ETH one).
- HOOKR-paired tokens are CREATE2-deployed with an onchain-mined salt such that
  `token > HOOKR` — HOOKR is always `currency0`, so the hook's `isBuy = zeroForOne` and the
  whole band geometry carry over unchanged (~90% of salts qualify; expected ~1.1 iterations).
- Contract rails (LOOSE, canary-scale by design): floor FDV and raise floor each in
  [10,000 HOOKR, 1,000,000,000 HOOKR]. PRODUCT floors are UI policy, value-matched to the ETH
  lane at ~2.8M HOOKR/ETH and tunable per deploy: floor FDV 600,000 HOOKR, graduation
  3,000,000 HOOKR, instant open fixed at 2,500,000 HOOKR.
- HOOKR pairs support the guard (cap + snipe tax) and surge blocks — pure LP-fee blocks, quote
  agnostic. The pot, auto-burn, and LP-donation blocks are REFUSED on HOOKR pairs (launchpad
  validation on resolved params + hook `configurePool` defense-in-depth): their cut machinery is
  native-ETH end to end, and generalizing the most security-critical contract's claim ledger to
  a second currency is future-generation work, not launch work.
- Bonded HOOKR: the CCA is created with `currency = HOOKR` (the deployed factory supports ERC20
  currencies; bids ride Permit2). The migration sweep measures the raise by HOOKR balance delta,
  the pool opens with ERC20-aware settlement, and creator proceeds are a HOOKR ledger claimed
  by pull payment.
- `collectPoolFees` on a HOOKR pair routes the full quote-side collection to the creator (no
  protocol split, no guard withholding — the withholding exists to stop creator rebates out of
  the PROTOCOL share, which HOOKR pairs do not have).

## Deployment order

`HookrFlywheelBurner` (no dependencies) → `HookrLaunchpadLibV5` → `HookrLaunchpadV5` →
`HookrHook` (constructor gains the burner as flywheel recipient; CREATE2-mined as before) →
router → wiring. The burner's pool key is a construction constant; its buyback bounds are
owner-tunable.

## What this deliberately does not do

- No HOOKR-denominated pot/burn/LP-donation (future generation).
- No auto-buyback in the swap path. Collection remains permissionless; each spend is
  owner-executed with a reviewed output minimum, a per-call ceiling, and a one-buyback-per-block
  throttle.
- No protocol fee of any kind on HOOKR pairs.
- No retroactivity: generations 1–4 pools are untouched; the flywheel fee exists only where the
  generation-5 launchpad configures it.
