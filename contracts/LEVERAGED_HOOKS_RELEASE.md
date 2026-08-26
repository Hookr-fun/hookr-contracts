# Leveraged Hooks — go-live runbook

> **Status (2026-08-13): PROMOTED LIVE.** `src/lib/leverage-release.generated.json` carries the
> verified deployment — factory `0xa8566BB5Ac3D91aaFdF6300e1b7321d057F10704`, hook
> `0x81DEc5b02c546437b4D0e57211bd5632E67d7AC0`, router
> `0x148bBc8BDa1012F9b37226527602E7A70f314175`, block 35666997, five receipts — and the `/leverage`
> hero reads `LIVE`. No market had been opened at promotion time (`marketCount() == 0`). Write
> buttons additionally obey `LEVERAGE_UI_WRITES_WIRED` in `leverage-release.ts`: they stay held
> until the interface ships each signing flow. The runbook below is retained verbatim for
> redeploys and for `promote-leverage-release --reset`.

The contracts, tests and UI are done. The gate in `src/lib/leverage-release.ts` reads
`src/lib/leverage-release.generated.json`, which ships `{ "current": null }` until promotion — in
that state every `/leverage` write button is closed and the hero reads `CANDIDATE · NOT DEPLOYED`.
It opens only when a **verified** deployment record is promoted into that json. Hand-editing the
TypeScript cannot open it; promotion has to survive the on-chain checks below.

This whole flow was rehearsed against a loopback fork of chain 4663 (anvil `--fork-url`) before
this landed: the deploy script runs, the verifier authenticates the wiring and the mined hook
flags, the promotion flips the gate, and the `/leverage` hero + panels go live. Only the final
production broadcast is left, because it signs from the reviewed `nodar-deployer` keystore.

## 1. Deploy (operator, signs from the keystore)

```bash
cd contracts
POOL_MANAGER=0x8366a39CC670B4001A1121B8F6A443A643e40951 \
LEVERAGE_ADMIN=<operator address> \
forge script script/DeployLeverage.s.sol:DeployLeverage \
  --rpc-url https://rpc.mainnet.chain.robinhood.com \
  --account nodar-deployer --sender <operator address> \
  --broadcast --slow
```

The script mines the hook salt so its address carries the six declared permission flags
(`0x3AC0`), deploys the factory and router, and calls `hook.setFactory(...)` in the same run —
it reverts rather than leaving a half-wired deployment (the fatal `setFactory` gate that hid for
five audit passes; see `AUDIT.md`). It writes `broadcast/DeployLeverage.s.sol/4663/run-latest.json`.

## 2. Verify (read-only, fails closed)

```bash
node scripts/verify-leverage-deployment.mjs \
  --deploy contracts/broadcast/DeployLeverage.s.sol/4663/run-latest.json \
  --rpc https://rpc.mainnet.chain.robinhood.com
```

Authenticates the artifact against the live chain: the six ordered, distinct receipt hashes are
each **fetched on chain**, required to exist and to have succeeded (a stale or fork artifact fails
here — its receipts never landed on real 4663), and the deploy block is taken from those on-chain
receipts, not from the artifact; every address carries code; the hook address carries `0x3AC0`;
`hook.factory() == factory`, `factory.hook() == hook`, and all three `poolManager()`s equal the
canonical pool manager; and **the finalized head is at or past the on-chain deploy block** (the
record pins that block). On success it prints the deployment record as JSON. Any mismatch exits
non-zero and nothing is promoted.

The finalized-head check means verify/promote will **block until the deploy finalizes** —
immediately after broadcast the finalized tag still lags the deploy, and the verifier says so
(`...the finalized head is only M — not yet final, wait for finalization and re-run`). This is
deliberate: it is what stops a still-reorganizable deploy from opening the gate. Wait for
finalization and re-run; nothing else is required.

## 3. Promote (the only thing that opens the gate)

```bash
node scripts/promote-leverage-release.mjs \
  --deploy contracts/broadcast/DeployLeverage.s.sol/4663/run-latest.json \
  --rpc https://rpc.mainnet.chain.robinhood.com
```

Runs the verifier again and, only if it passes, writes the authenticated record into
`src/lib/leverage-release.generated.json`. Then:

```bash
npm test          # the leverage-release gate test now asserts the live record; update it
npm run build
```

`src/lib/leverage-release.test.ts` deliberately asserts the candidate state, so it will fail once
the record is live — flip that assertion in the same commit as the generated json, on purpose,
naming the deployed address in the message. That is the conscious act the gate exists to force.

To shut the gate again (e.g. after a fork rehearsal that must never be committed):

```bash
node scripts/promote-leverage-release.mjs --reset
```

## Fork rehearsal (no keystore, proves the pipeline)

```bash
anvil --fork-url https://rpc.mainnet.chain.robinhood.com --chain-id 4663 --port 8545 &
cd contracts
POOL_MANAGER=0x8366a39CC670B4001A1121B8F6A443A643e40951 \
LEVERAGE_ADMIN=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
forge script script/DeployLeverage.s.sol:DeployLeverage \
  --rpc-url http://localhost:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --broadcast --slow
# optional: exercise a full market round-trip and read the UI surface
FACTORY=<factory from the log> \
forge script script/RehearseLeverage.s.sol:RehearseLeverage \
  --rpc-url http://localhost:8545 --private-key 0xac0…ff80 --broadcast --slow
# verify / promote against the fork carry --rehearsal so no fork manifest is written to disk
node scripts/verify-leverage-deployment.mjs --deploy contracts/broadcast/DeployLeverage.s.sol/4663/run-latest.json --rpc http://localhost:8545 --rehearsal
```

The `0xf39F…2266` / `0xac09…ff80` pair is anvil's first well-known dev account — a public test
key, never a real one. Never point the production keystore at a local fork; `run-canary.sh`
already refuses that and this flow follows the same rule.
