# Hookr generation 4 instant-launch release runbook

This runbook is for a new Robinhood Chain deployment that adds curve-free instant launches while
retaining generation 3 as a read-supported historical release. It does not authorize a deployment.
Every signing prompt remains user-confirmed, and promotion remains blocked until real receipts and
live-chain readbacks exist.

## Evidence state

The complete generation-4 pipeline was rehearsed on an `anvil` fork of Robinhood Chain 4663 on
2026-08-10:

- deploy: 10 successful local-fork transactions;
- instant canary: 4 successful local-fork transactions and `CANARY OK`;
- replay: the same creator/intent was rejected in simulation outside the broadcast sequence;
- promotion: `--dry-run` verified ordered receipts, live-fork calldata/event/targets, runtime
  linkage, pinned readbacks, and rendered a generation-4 instant-capable manifest.

Fork receipts, fork addresses, and a generated manifest are rehearsal evidence only. They are not
production deployment proof and must not be copied into the checked-in manifest.

## Deployer and immutable anchors

The release signs as `0x5a52D4B820Ae7F02880d270562950918ACb14aA2`, using the local Foundry
keystore account `nodar-deployer` or an explicitly reviewed hardware/remote signer for that exact
address. Never place a private key in argv, the repository, a log, or a report.

The candidate launchpad runtime hash is printed by the no-broadcast deploy simulation. Its sole raw
runtime copy is `REVIEWED_PAD_RUNTIME_HASH` in `script/DeployRobinhood.s.sol`. All four deployments
also have reviewed normalized runtime-template and compiler-reference-layout anchors in
`scripts/lib/runtime-template-evidence.mjs`. Any contract change must stop the simulation/preflight
until the diff and replacement anchors are independently reproduced and reviewed. Never derive an
expected value from the same live code it is supposed to authenticate. Layout anchors pin every
immutable/link range and immutable grouping but deliberately normalize solc's non-semantic numeric
AST ids, which Foundry may renumber when the same source is compiled in a larger unit.

Addresses are intentionally not predicted here. The launchpad and router are CREATE deployments,
so unrelated deployer nonces move them; the hook is then mined with CREATE2 from the resulting
launchpad address. Downstream tooling derives both CREATE2 results from the canonical factory plus
the live `salt || initCode` calldata and verifies the CREATE results against their receipts.

## Canary plan

The fixed canary is an instant launch, not a curve sell-out:

- intent: `keccak256("hookr.v4.canary.instant.all-five.1")`;
- pool deposit: `0.01 ETH`;
- pool supply: `5000 bps` (50% of the fixed supply);
- previewed opening price: `20,000,000 wei` per whole token;
- previewed opening FDV: `0.02 ETH`;
- curve-only fields: `targetRaiseWei = 0`, `minTokensOut = 0`;
- guarded router buy: `0.001 ETH`;
- router sell: 1% of the bought balance.

ETH actually accepted into the position is locked in launchpad-owned full-range liquidity; any
tiny amount that cannot be represented by the position math is refunded as rounding residue. In the fork
rehearsal, the buy returned `35,715,085.734923640586954115` tokens and the sell returned
`0.000008265037775085 ETH`. The enforced minimums are respectively `20,000,000` tokens and
`0.000002 ETH`; both remain nonzero execution-time slippage bounds with substantial rehearsal
headroom. Peak wallet outlay is approximately `0.0112 ETH` plus gas before the small sell proceeds
return. The portion of the `0.01 ETH` deposit accepted into liquidity is intentionally
non-recoverable.

The custom stack enables all five blocks: a 200-block anti-snipe window with a 10%-of-float
per-block cap and 20% snipe tax, surge fees, 1% Auto Burn, 0.25% LP donation, and a 0.5%
deterministic Nth-buy Pot whose qualifying floor is the `0.001 ETH` canary buy.

## 0. Pre-flight: simulate only

Run from any directory. This command has no `--account` and no `--broadcast`, so it neither loads a
signer nor submits a transaction:

```bash
cd "$(git rev-parse --show-toplevel)/contracts" && forge script script/DeployRobinhood.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com --sender 0x5a52D4B820Ae7F02880d270562950918ACb14aA2
```

It must print `Script ran successfully.` The script checks chain 4663, PoolManager and canonical
CREATE2-deployer runtime hashes, hook flag mining, wiring, ownership, identities, the five seeded
blueprints, EIP-170 sizes, and the reviewed launchpad runtime hash.

If it fails on `launchpad is not the reviewed build`, the script now prints the exact candidate
hash before reverting. Derive and independently reproduce that value, review the contract diff,
then deliberately update the one anchor. Do not paste a hash merely to make the assertion pass.

## 1. Deploy: 10 transactions

Only after explicit user confirmation:

```bash
cd "$(git rev-parse --show-toplevel)/contracts" && forge script script/DeployRobinhood.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com --account nodar-deployer --sender 0x5a52D4B820Ae7F02880d270562950918ACb14aA2 --broadcast --slow
```

The exact order is:

1. `HookrLaunchpadLib` through the canonical CREATE2 deployer;
2. `HookrLaunchpad`;
3. `HookrHook` through the canonical CREATE2 deployer;
4. `HookrSwapRouter`;
5. `setHook`;
6. five `saveBlueprint` calls.

Forge prepends the linked library transaction. The launchpad runtime embeds that library address,
and promotion verifies that linkage from deployed bytecode. A later failed transaction cannot roll
back an earlier receipt. If the sequence stops, inspect every mined receipt and do not rerun blindly.

## 2. Instant canary: 4 transactions

Deployment and canary are separate confirmation boundaries. Wait until all ten deploy receipts are
included at or below Robinhood RPC's `finalized` head, then present this command for a new user
confirmation:

```bash
"$(git rev-parse --show-toplevel)/contracts/run-canary.sh"
```

Before Forge can load a signer, `run-canary.sh` invokes the read-only deployment preflight. It binds
all ten live receipts to canonical finalized block headers, derives both CREATE2 addresses from
salt and initcode, verifies all four runtimes against reviewed source/compiler templates and exact
immutables/links, and proves all five blueprint calldata/event/readback triples. Robinhood's default
RPC cannot execute `eth_call` or `eth_getCode` at its finalized tag or returned finalized height, so
those state reads are all EIP-1898-pinned to one separately authenticated `safe` block hash at or
after the finalized head; the verifier rechecks that hash's canonicality after the final read. The
Solidity canary then calls and verifies `previewInstantLaunch(0.01 ether, 5000)` before
`startBroadcast`.

The artifact must contain exactly:

1. `launchInstantWithIntent` — consumes the fixed intent and atomically creates the token, opens the
   pool, and locks liquidity;
2. guarded router `exactInput` buy;
3. token `approve` for the 1% sell slice;
4. router `exactInput` sell.

After `stopBroadcast`, the Forge simulation retries the exact creator/intent and requires
`LaunchIntentAlreadyUsed`. That fifth call is intentionally reverting and intentionally absent from
the broadcast artifact.

Simulation postconditions verify the instant launch record (`graduated = true`, `soldTokens = 0`,
zero curve reserve, deposit in `targetWei`, previewed opening price and sqrt price, same-block pool
open, recorded pool ID), live liquidity, intent readback, and every hook effect: guarded/snipe fee,
nonzero surge contribution, Auto Burn, LP donation, a qualifying pot count/current claim backing,
and custody invariants.
After a live broadcast, independently repeat those readbacks against the mined state; simulation
assertions cannot undo already-mined transactions.

If transaction 1 succeeds and a later canary transaction fails, the intent is spent. Do not redeploy
or retry the instant launch. Recover only the missing buy/approval/sell against the token emitted by
the successful launch, preserving the same bounds and order, then assemble a four-receipt artifact
that retains the exact deployment source commit; promotion rejects missing or mixed commit fields.
The 200-block guard is an operational recovery budget, not permission to weaken evidence: the buy
receipt must still contain the configured guarded/surge fee and all hook-effect logs. If that window
expires before the buy lands, this fixed canary cannot prove the release; stop for a new reviewed
canary plan rather than relabelling an unguarded transaction.

## 3. Promote generation 4

Broadcast from the commit whose `contracts/src` is being deployed. The promotion tool reads the
artifact commit, refuses uncommitted contract/script changes for a real promotion, and refuses any
`contracts/src` difference between the deployed commit and promotion-time `HEAD`.

From the repository root:

```bash
cd "$(git rev-parse --show-toplevel)" && node scripts/promote-release-manifest.mjs
```

The tool refuses to write unless every deploy and canary receipt succeeded from the expected
deployer on live chain 4663 in strict `(blockNumber, transactionIndex)` order and every receipt is
at or below one authenticated `finalized` evidence head. It decodes the four live canary calls and
their `TokenLaunched`, `Graduated`, `InstantLaunched`, `LaunchIntentConsumed`, `SwapExecuted`,
PoolManager `Swap`, `HookFeesAccrued`, `LpRewardsDonated`, `AutoBurn`, and `Approval` events. The decoded evidence must bind the
exact creator and fixed intent, zero curve fields, `0.01 ETH` deposit, `5000 bps` float, token,
PoolId, router directions and recipients, approval spender and amount, and sell input to one
coherent round trip; successful unrelated calls cannot be relabelled as a canary.

Receipt finality and state availability are deliberately separate. After proving every deployment
and canary receipt is at or below the authenticated finalized head, the tool pins one canonical
`safe` state head at or after it. All code, intent/launch-record, exact instant preview, hook config
and monotonic all-five ledgers, token identity/balances, raw PoolManager slot0/liquidity, and
blueprint readbacks execute against that one block hash. The RPC can serve state while that block is
`safe` but not once it becomes historical/finalized, so the tool reads first, then polls for up to
15 minutes until the finalized head reaches that height and proves the same hash is still canonical.
Timeout or an orphaned hash leaves the manifest untouched; `--finality-timeout-seconds` may set a
reviewed bound from 1 through 3600 seconds. Finalized creation/configuration receipts make the direct,
non-upgradeable runtime and immutable wiring facts safe to re-read later; finalized receipt logs are
authoritative for mutable canary effects, while later state is used only for current invariants and
monotonic backing. The tool also canonical-decodes all five house blueprint calls, checks their
events, and compares every immutable field with `getBlueprint(1..5)`;
contract-visible saved blocks are compared with each receipt block header's `l1BlockNumber`, not
the rollup receipt height. Hook flags, runtime hashes, linked-library address, identities, versions,
wiring, owner, at least the sentinel plus five house blueprints, and PoolManager codehash are also
checked. Extra user blueprints and legitimate house-blueprint use do not invalidate a release. Any
mismatch leaves the manifest untouched. Permissionless later trading cannot invalidate the canary:
the exact fee/cut/donation/burn proof is scoped to the buy receipt, while cumulative ledgers need
only remain at least as large as that receipt and global native claims need only back the current
pool-scoped pot.

Promotion writes generation 4 with `launchModes: ["curve", "instant"]` and canary kind
`instant_launch_round_trip_v1`. It replaces only `CURRENT_RELEASE_MANIFEST`; the immutable
`RETAINED_GENERATION_3_MANIFEST` and its curve canary evidence remain in the read registry.

This promoter deliberately cannot roll generation 4 forward. A generation-5 change must first
materialize the exact outgoing v4 object as `RETAINED_GENERATION_4_MANIFEST` and atomically register
`[CURRENT_RELEASE_MANIFEST, RETAINED_GENERATION_4_MANIFEST, RETAINED_GENERATION_3_MANIFEST]` before
replacing CURRENT. Until that reviewed history-extension path exists, any attempt to replace an
expanded CURRENT object fails closed; never weaken that guard or reuse the v4 release ID for new
addresses.

Use `--dry-run` to inspect a rehearsal or candidate manifest without writing. Non-dry promotion
refuses loopback/private/non-HTTPS RPC endpoints.

## 4. Post-promotion checklist

1. Run `node --test scripts/promote-release-manifest.test.mjs` and a promotion `--dry-run` against
   the same verified artifacts.
2. From the repository root run `npm test`, `npm run lint`, `npx tsc --noEmit`, and `npm run build`.
3. From `contracts/` run `forge fmt --check`, `forge test -vv`, and `forge build --sizes`. Running
   Forge from the repository root can exit successfully after testing nothing; do not use that as
   evidence.
4. Archive both real `run-latest.json` artifacts under `contracts/evidence/v4/`, add SHA-256 sums,
   and label fork artifacts separately or do not archive them. `contracts/broadcast/` stays ignored.
5. Verify source on Sourcify/Blockscout and record the actual result, including rate-limit failures.
6. Commit, review, merge, verify deployment provenance, and smoke both launch modes plus reads for a
   retained generation-3 token. A Ready web deployment is not a chain receipt.
