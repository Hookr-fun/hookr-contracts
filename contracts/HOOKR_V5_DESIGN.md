# Hookr generation 5 — zero-seed instant + CCA-bonded launches

Decided 2026-08-20. Supersedes the stepped bonding curve. HOOKR-quoted pairing is deferred;
both v5 lanes are native-ETH quoted, exactly like every deployed generation.

## Why

Three defects of the live v4 economics, all quantified in the session sims:

1. The curve ramp (1.7^9 = 118.6x) back-loads the raise: the first half of curve supply costs
   6.6% of a 5 ETH raise, and curve holders exit onto a pool float 4.14x smaller than their bags.
2. The instant path prices the pool at `ethIn / tokensInPool`, so the default 0.02 ETH deposit
   opens a ~$180-FDV pool that moves 36x on a 0.1 ETH buy.
3. Both defects are parameter-coupled: flattening the curve without shrinking it makes
   `_graduate` skim unmatched raise into protocol fees.

pools.trade (Uniswap Labs, chain 4663) demonstrates the fixes in production, and its stack is
MIT, byte-verified against source, permissionless, and audited (CCA: Spearbit/OpenZeppelin/ABDK).

## Lane 1 — zero-seed instant

Replaces `launchInstant`'s ratio pricing. The creator commits no structural capital and does NOT
pick the opening price.

- The opening valuation is FIXED platform-wide (`instantOpenFdvWei`, a constructor immutable,
  ~2.5 ETH — matching pools.trade's immutable opening tick). Every instant launch opens identically;
  the constructor precomputes the sqrt price and band ticks once and reverts a launchpad whose fixed
  FDV cannot be placed.
- The entire fixed supply is placed as ONE token-only band `[openTick - BAND_TICKS, openTick]`
  and the pool is initialized at the band's upper edge. Price walk is a closed-form square-root
  curve: ETH to reach multiple m ≈ FDV·(√m−1); supply distributed ≈ 1−1/√m.
- No bid-side liquidity exists at open, so nothing can be sold that was not first bought.
- No atomic dev-buy: the lane was trimmed to fit EIP-170 and the launch transaction carries no
  swap. A creator who wants a first buy makes it through the guarded router immediately after —
  snipe-taxed, per-block capped, and pot-eligible like anyone else's. The share math the UI shows
  is unchanged: a buy of `x` against the fixed FDV `F` takes exactly `x/(F+x)` of supply.
- The `lpBps` (LP donation) hook block is STRUCTURALLY refused on this lane
  (`InstantRejectsLpDonation`, checked on the RESOLVED params so a blueprint cannot smuggle it in):
  a zero-seed pool opens with the tick outside its band, so in-range liquidity is zero until the
  first buy — and the hook fails closed on an LP-donation cut with no in-range LP to receive it.
  Allowing it would brick the pool on its very first buy. The block stays fully available on the
  bonded lane, whose migrated pool has full-range POL in range from its first block. (Found by the
  hook-block matrix test; see `test/HookBlockMatrixV5.t.sol`.)
- `collectPoolFees` pokes the position the launch actually holds: instant pools poke the BAND
  (poking full-range there would revert on a nonexistent position and strand the fees forever);
  bonded pools poke full-range. LP tranches are removed from generation 5 entirely — the
  continuous band subsumes the ladder — so there is no per-band collection loop.
- The launchpad still owns every position and exposes no negative-liquidity path — locked by
  construction carries over.

## Lane 2 — CCA-bonded

Replaces the stepped curve. The auction phase reuses Uniswap's DEPLOYED
`ContinuousClearingAuctionFactory` (`0x000000001F26a0044BaA66024e7b6599c61963F8`, byte-verified,
permissionless, 3,647 real auctions). The launchpad is the auction's `fundsRecipient` and
`tokensRecipient`; migration is ours and lands in a HookrHook pool.

- CONFIGURABLE split (pools.trade-style): the creator picks `reserveBps` in
  `[MIN_RESERVE_BPS, MAX_RESERVE_BPS]` (20–50%) — the share of supply reserved to seed the pool; the
  rest is auctioned. At `MAX_RESERVE_BPS` (50%) the reserved tokens exactly balance the raise at the
  clearing price, so 100% of it locks — the unique zero-skim point (depth/FDV ≈ 50%, overhang ≈ 1.0x
  vs the old curve's 19.3% / 4.14x). Below it, the reserved tokens are worth less than the raise, and
  the un-locked balance is returned to the creator as DISCLOSED PROCEEDS (a real fundraise). The
  split is public before anyone bids, so bidders always know it. Example: at 20% reserved, ~75% of
  the raise is creator proceeds, 20% of supply locks as liquidity.
- DECOUPLED floor and graduation, pools.trade-style: `floorFdvWei` sets the auction's STARTING
  valuation (floor price = clearing price at that FDV over the TOTAL supply), while
  `raiseFloorWei` is the independent graduation threshold (`requiredCurrencyRaised`). An auction
  can open cheap (pools.trade: ~$1k floor) and still demand a real raise (~$5k) before it
  graduates — when the raise floor exceeds what a fully-sold auction raises at the floor price,
  graduating REQUIRES the clearing price to rise above the floor. Contract bounds are deliberately
  loose safety rails (0.01 ether minimums, so a canary can run at dust scale); the
  pools.trade-parity production numbers are UI policy (`PRODUCT_*` in `src/lib/auction-v5.ts`),
  the same loose-contract/strict-UI split generation 4 shipped.
- `launchAuction(args, floorFdvWei, raiseFloorWei, reserveBps, intentId)`: deploys the token,
  creates the CCA (currency = native ETH, uniform issuance schedule, floor price from
  `floorFdvWei`, `requiredCurrencyRaised = raiseFloorWei`),
  funds it with the auctioned share, calls `onTokensReceived()`, and records the pending launch.
  Everyone — including the creator — bids at auction prices; no token allocation exists. Proceeds
  are credited at migration and claimed via `claimAuctionProceeds` (pull payment).
- `migrateAuction(token)`: permissionless, after `endBlock + MIGRATION_DELAY_BLOCKS`.
  - Graduated: sweep the raise (measured by balance delta, so a factory protocol fee cannot
    poison accounting), sweep unsold auction supply, open the pool AT the clearing price through
    the existing `_openPool` path (same locked position, same hook config, same fee ledgers),
    burn whatever the position cannot absorb. Anti-snipe guard starts at migration.
  - Not graduated: the CCA refunds every bid on exit; the launchpad burns the full 1B supply and
    marks the launch failed. No pool ever exists.
- Auction timing is chain-cadence-dependent, so `AUCTION_DURATION_BLOCKS`, `CLAIM_DELAY_BLOCKS`
  and `MIGRATION_DELAY_BLOCKS` are constructor args (Robinhood ≈ 10 blocks/s; 4h ≈ 144,000).
  `AUCTION_DURATION_BLOCKS` must divide the CCA's MPS constant (1e7) exactly so the uniform
  one-step schedule has an integer per-block rate.
- Bidders' exits/claims happen on the CCA directly; the UI surfaces them. A Hermes
  scheduled-task keeper pokes `migrateAuction`; anyone can.

## What is removed

`launch` / `launchWithIntent` (curve), `buy`, `sell`, the curve walk, `_graduate`, curve
constants and events. Gen-3/v4 remain read-supported through the retained manifests; the freed
runtime size pays for the two new lanes.

## What is unchanged

Blueprints (the LP Loyalty blueprint is bonded-lane-only now — see the instant-lane refusal),
fee collection (`collectPoolFees` with the `guardLpEarnedWei` withholding, now mode-branched to
poke the position each lane actually holds), creator fee splits, payout redirection, intents
(one namespace, all lanes), `_openPool`, the hook (byte-identical source, freshly CREATE2-mined
for the v5 launchpad address), the router, and the locked-liquidity invariant.

## Deployment

Same pipeline as v4: `DeployRobinhood.s.sol` (updated in place; new reviewed runtime anchors) →
fork rehearsal (deploy + both canaries + promotion `--dry-run`) → user-confirmed broadcast with
the `nodar-deployer` keystore → `promote-release-manifest.mjs` with live receipts → UI gate
flips. Canaries: one zero-seed launch with a dev-buy and router round-trip; one full auction
cycle (create → bid → end → migrate → claim) — on the fork with time-warp, in production with a
real 4-hour window.

## New constants (contract-pinned, mirror-tested like v4's)

| name | value | note |
| --- | --- | --- |
| `INSTANT_OPEN_FDV_WEI` | 2.5 ether (deploy constant) | fixed platform-wide instant open, pools.trade parity |
| `BAND_TICKS` | 207_000 | ~1e9x price span; `bandLiquidity` fits uint128 with 8+ OOM headroom |
| `MIN_RESERVE_BPS` / `MAX_RESERVE_BPS` | 2000 / 5000 | configurable split; 5000 is the zero-skim point |
| `MIN_RAISE_FLOOR_WEI` | 0.01 ether | LOOSE rail (canary scale); production floor is UI policy |
| `MAX_RAISE_FLOOR_WEI` | 1000 ether | matches v4 MAX_TARGET |
| `MIN_FLOOR_FDV_WEI` | 0.01 ether | LOOSE rail (canary scale); production floor is UI policy |
| `MAX_FLOOR_FDV_WEI` | 10,000 ether | above this a floor is an exit, not an open |
