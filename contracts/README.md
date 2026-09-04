# Hookr contracts

Foundry workspace for Hookr's immutable contract lineages. Solidity is pinned to 0.8.26 with the
optimizer, via-IR, Cancun, and no metadata bytecode hash. Generation 5 is the promoted write target
on Robinhood Chain 4663; retained generations remain separate, immutable markets.

## Generation 5

`HookrLaunchpadV5` 5.0.1 supports three new-token paths:

- zero-seed instant launch quoted in native ETH;
- zero-seed instant launch quoted in HOOKR; and
- bonded ETH launch through Uniswap's deployed Continuous Clearing Auction.

The instant price is platform-fixed. A bonded launch discloses its floor, raise threshold, and
reserve before the transaction. A failed raise refunds bids and opens no pool. Successful markets
initialize a new Uniswap v4 `PoolKey` with locked launch liquidity.

The current contract set is:

- `HookrLaunchpadV5.sol` — launch preparation, intent replay protection, CCA integration,
  blueprints, fee splits, immutable launch records, migration, and locked liquidity;
- `HookrHook.sol` — the shared five-block v4 hook and creator/protocol accounting;
- `HookrSwapRouter.sol` — bounded exact-input and exact-output settlement with recipient, deadline,
  price limit, measured output, refund, callback, and reentrancy boundaries;
- `HookrFlywheelBurner.sol` — owner-bounded collection and HOOKR buy-and-burn with a nonzero
  execution floor;
- `HookrToken.sol` — fixed one-billion supply without owner mint, pause, blacklist, or transfer tax;
  and
- `HookrLaunchpadLibV5.sol` — linked launchpad logic whose exact deployed library is preserved in
  the V5 evidence packet.

`HookrExistingTokenFactory` and `HookrAttachHook` are source candidates for a new-pool path. They
are not part of the promoted V5 release and cannot retrofit an existing pool.

## Hook blocks

| Block | Behavior |
| --- | --- |
| Anti-Snipe | Finite opening guard with a buy cap and extra LP fee. |
| Surge Fees | LP fee scales with trade size relative to in-range depth. |
| Auto Burn | A configured share of actual buy output goes to the dead address. |
| LP Rewards | A configured ETH-side share is donated to in-range liquidity. |
| Nth-buy Pot | A deterministic scheduled pot advances at most once per pool per block. |

The hook permission mask is `0x28cc`:

```text
beforeInitialize | beforeAddLiquidity | beforeSwap | afterSwap |
beforeSwapReturnsDelta | afterSwapReturnsDelta
```

The hook address and configuration are fixed by the pool. No owner can retune a live pool's blocks.
Hook cuts apply to eligible exact-input buys. An ETH-paired V5 market also accrues the promoted
flywheel fee; a HOOKR-paired market pays no protocol fee.

## Transaction and authority boundary

Partner and agent flows use nonzero, creator-scoped intent IDs. A successful launch records the
token under that creator and intent; an exact replay reverts. A failed transaction does not consume
the intent. Ordinary manual launch entrypoints remain intentionally repeatable.

The SDK and contracts keep these states separate:

1. prepare exact calldata, value, recipients, bounds, and intent;
2. simulate from the intended account against the current release;
3. ask the user's wallet to sign the exact simulated request;
4. wait for the canonical success receipt; and
5. read back the intent, launch, pool, and runtime wiring.

A source file, local simulation, signature request, broadcast hash, successful receipt, and release
promotion prove different things. None substitutes for the next stage.

## Verification

From this directory:

```bash
forge fmt --check
forge build --sizes
forge test
```

The complete suite includes unit, fuzz, adversarial, invariant, all-32-hook-combination, V5 launch,
CCA, flywheel, router, attachment-candidate, utility, leverage-research, and fork coverage. Release
runs pin one recent Robinhood block and retain its number and hash with the tested commit.

From the repository root:

```bash
npm test
npm run contracts:release-tooling
```

Those tests authenticate the staged V5 evidence builders, canary wrapper, redaction boundary,
runtime templates, receipt ordering, and release-promotion invariants.

## Release protocol

[`RELEASE_V5.md`](RELEASE_V5.md) is the full operator runbook. In summary:

1. freeze source, dependencies, compiler settings, libraries, constructor inputs, and tested SHA;
2. run local, adversarial, invariant, size, and pinned-block fork gates;
3. simulate without broadcasting and review the exact deployer, chain, salts, values, ownership,
   runtime hashes, and predicted addresses;
4. obtain explicit human confirmation before any signing or broadcast stage;
5. reconcile every receipt in order and re-read runtime identity, immutable wiring, permissions,
   blueprints, fees, and ownership;
6. run lane and flywheel canaries, including failure-path postconditions; and
7. promote the release manifest only after the canonical evidence is final and complete.

Historical receipts and SHA-256 indexes live under `evidence/`. A retained artifact is evidence for
the transaction it names, not authorization to replay it.

## Security status

This project has not received an independent audit. Passing tests, adversarial review, live canary
receipts, and source verification are release evidence, not a substitute for one. Never place a
private key in argv, an environment variable, this repository, a log, or a report.
