# Hookr generation 5 release runbook — HOOKR pairs and the token flywheel

This is the release procedure for `HookrLaunchpadV5` **5.0.1** on Robinhood Chain (chain ID 4663).
Generation 5 has an ETH or HOOKR-quoted zero-seed instant lane, an ETH Continuous Clearing Auction
(CCA) bonded lane, and an ETH-fee flywheel that buys and burns HOOKR. The supported retained V3/V4
curve generations remain separate, immutable read/trade lineages.

This document is an operator checklist, not standing authorization. Simulation, signature,
broadcast, receipt finality, state readback, release-manifest promotion, and public-app deployment
are separate evidence stages. Every command that loads a signer requires the user's confirmation of
that exact stage. Never place a private key or keystore password in argv, an environment variable,
the repository, or a report.

## Release design and fixed dependencies

See `HOOKR_V5_DESIGN.md` for the mechanism details. The important deployment anchors are:

- Robinhood Chain: `4663`.
- Deployer/owner/canary sender: `0x5a52D4B820Ae7F02880d270562950918ACb14aA2`.
- Foundry account: `nodar-deployer` (or an independently reviewed signer for that exact address).
- PoolManager: `0x8366a39CC670B4001A1121B8F6A443A643e40951`.
- Uniswap CCA factory: `0x000000001F26a0044BaA66024e7b6599c61963F8`.
- HOOKR: `0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c`.
- Flywheel burner release: `HookrFlywheelBurner` 1.0.1 (owner-bounded buyback).
- Canonical HOOKR buyback pool: hookless ETH/HOOKR, fee `2500`, tick spacing `25`.
- Production auction timing: `125000 / 0 / 1` blocks (duration / claim delay / migration delay).
- Canary timing: `20000 / 0 / 1`; `20000` divides the CCA's `1e7` issuance schedule exactly and
  leaves room to finalize the mined CCA before bidding.
- Instant ETH opening valuation: 2.5 ETH FDV.
- Instant HOOKR opening valuation: 2,500,000 HOOKR FDV.

The launchpad uses Uniswap's deployed CCA factory; Hookr does not deploy or administer the CCA
implementation. The flywheel burner is wired to the hook, PoolManager, HOOKR token, and the canonical
pool. Its buyback is an owner-executed, bounded operation: an untrusted caller cannot choose the
slippage floor, the owner must supply a reviewed nonzero minimum, and successful execution must burn
a nonzero amount of HOOKR.

## Why 5.0.0 is retired before canary

The completed 5.0.0 deployment is **not a release candidate and must never be canaried or promoted**:

| Component             | Retired 5.0.0 address                        |
| --------------------- | -------------------------------------------- |
| `HookrLaunchpadLibV5` | `0x0bAc7790885B4AaC65b04A522372eA35AFA88aEA` |
| `HookrFlywheelBurner` | `0x2D86620D4407e1070270765B675B02a3ea21399D` |
| `HookrLaunchpadV5`    | `0x53fD3D845058e9cE0121144eA06cBFe8eF65a1Ff` |
| `HookrHook`           | `0x6096e79baA6C3AF5F2D8C9eCDD6396B78Acbe8cc` |
| `HookrSwapRouter`     | `0x8d7EC2aE0D947d67fb157a210d5Bbad19604bA8E` |

The retirement-time readback found production timing `125000 / 0 / 1` and `tokensCount = 0` on the
retired candidate, before any canary started. The contracts are immutable, so retirement means
abandon them and never put their addresses in `CURRENT_RELEASE_MANIFEST` or production configuration.

The blocker is CCA final-state accounting. The CCA checkpoints before adding a bid, while graduation
is finalized lazily after the auction window. The 5.0.0 `migrateAuction` read `isGraduated()` before
forcing that final checkpoint. A valid auction with a funded early bid could therefore still report
stale `false`, and any permissionless caller could make the launchpad permanently take the failure
branch. This has no safe operational workaround.

Version 5.0.1 fixes the integration invariant: `migrateAuction` calls `checkpoint()` after the window
and only then reads `isGraduated()`. A regression mock pins that ordering, and a full local Robinhood
fork demonstrated the formerly stale `false` value becoming final and the 5.0.1 migration succeeding.
Fork evidence is rehearsal evidence only; it is not a production receipt.

An empty, unwired burner at `0xF6Cc818323380663Ba391B76C2ACefcE2870D75e` came from the interrupted
broadcast and is also excluded. It is not referenced by either candidate. The deployed
`HookrLaunchpadLibV5` at `0x0bAc...8aEA` is the exception: its exact runtime and original receipt are
reusable because the 5.0.1 patch did not change that library.

## Evidence and source gates

The immutable deployment source is commit
`b1ccb017f86d9caffff8bf4277a735d714130972`. The canary operator may be a clean descendant commit
because Robinhood's ArbSys marker needs a Foundry-only simulation shim, but the operator lineage
must show **no change** under `contracts/src`, `contracts/lib`, `contracts/foundry.toml`, or
`contracts/script/DeployRobinhoodV5.s.sol`. The preflight, authenticated target state, four canary
artifacts, promotion verifier, and final manifest keep the deployment source commit distinct from
the canary operator commit.

Before a production broadcast, the operator commit must be clean and all contract/runtime anchors
must still match the immutable deployment source. At minimum, run from the worktree root:

```bash
git status --short
git rev-parse HEAD
cd contracts
forge build --sizes
forge test
cd ..
npx tsc --noEmit
npm run test:release-tooling
git diff --check
```

The current 5.0.1 launchpad is 23,838 bytes at the release compiler settings, below the 24,576-byte
EIP-170 ceiling. `DeployRobinhoodV5.s.sol`, the runtime-template verifier, and the built artifacts are
the authority for exact runtime hashes. Rebuild and re-run every gate on the final committed head;
do not copy a hash from a fork or an earlier dirty build into a production packet.

The already-mined library is represented by:

```text
contracts/release-evidence/v5/reused-launchpad-library.json
```

That record binds the library address, source commit, transaction hash, calldata hash, finalized
receipt, the SHA-256 and shape of the interrupted raw Forge artifact, and the excluded orphan burner.
Retain the referenced raw artifact at its recorded path and SHA-256. The verifier intentionally fails
if either the wrapper evidence or its raw source artifact is missing or changed.

## Deployment: simulate, confirm, then broadcast 11 transactions

Set the RPC without printing it. Production examples use the existing Alchemy environment variable:

```bash
cd /Users/nodes/repos/hookr/.claude/worktrees/hook-block-icons-5182e5/contracts
export HOOKR_RPC_URL="$ALCHEMY_RPC_URL"
export ETH_RPC_URL="$HOOKR_RPC_URL"
export FOUNDRY_ETH_RPC_URL="$HOOKR_RPC_URL"
```

First run the no-signature simulation. It must succeed on chain 4663 and print the exact candidate
addresses, sizes, and runtime hashes:

```bash
forge script script/DeployRobinhoodV5.s.sol \
  --sender 0x5a52D4B820Ae7F02880d270562950918ACb14aA2
```

Recheck the deployer nonce, native balance, predicted addresses, final source commit, and the whole
transaction packet immediately before asking for confirmation. A production broadcast is then:

```bash
forge script script/DeployRobinhoodV5.s.sol \
  --sender 0x5a52D4B820Ae7F02880d270562950918ACb14aA2 \
  --account nodar-deployer \
  --broadcast \
  --slow
```

`--slow` is mandatory: Forge waits for each receipt before sending the next transaction. It does not
make a multi-transaction release atomic. If the process is interrupted, reconcile the onchain nonce,
each receipt, mempool state, calldata, and `run-latest.json`. Do not rerun or automatically resume the
deployment; prepare a new exact action packet for the unconfirmed suffix after manual reconciliation.

Because `HookrLaunchpadLibV5` is already live and authenticated, the fresh 5.0.1 Forge artifact has
**11 transactions/11 receipts**:

1. `HookrFlywheelBurner` CREATE.
2. `HookrLaunchpadV5` CREATE.
3. `HookrHook` CREATE2, mined with the required `0x28cc` flag bits.
4. `HookrSwapRouter` CREATE.
5. `pad.setHook(hook)`.
6. `burner.setHook(hook)`.
7. Five `pad.saveBlueprint(...)` calls.

The preflight tool prepends the separately proven library receipt to form the complete logical
12-receipt dependency proof. Do not pass the retired 5.0.0 deploy artifact as the new deployment.

The absolute deployment-worktree path above is historical immutable evidence only. Do **not** run
the canary wrapper from that `b1ccb` tree. Switch to the clean descendant canary-operator worktree,
print and record its full HEAD, and verify it is not the deployment commit before continuing:

```bash
cd /Users/nodes/.codex/worktrees/v5-canary-arbsys-recovery/hookr
test -z "$(git status --porcelain --untracked-files=normal)"
CANARY_OPERATOR_COMMIT="$(git rev-parse HEAD)"
test "$CANARY_OPERATOR_COMMIT" != "b1ccb017f86d9caffff8bf4277a735d714130972"
printf '%s\n' "$CANARY_OPERATOR_COMMIT"
```

The wrapper and promotion gate independently prove that this HEAD descends from the deployment
commit and that no deployed source input changed between them.

## Deployment preflight: read-only and fail closed

For a fresh deployment with no canary launches, after all 11 deployment receipts exist, wait for
production finality and run from the worktree root:

```bash
node scripts/verify-deployment-preflight.mjs \
  --deploy contracts/broadcast/DeployRobinhoodV5.s.sol/4663/run-latest.json \
  --library-evidence contracts/release-evidence/v5/reused-launchpad-library.json
```

The standalone command is the fresh-lane verifier and still requires zero launch tokens and zero
protocol fees. It authenticates source attribution, the reused library provenance, all receipts, live runtime
templates and immutables, the 5.0.1 identity, PoolManager/CCA/HOOKR dependencies, hook/router/burner
wiring, burner pool configuration, owner, all five blueprints, and exact production timing. A failed
or unavailable read is a blocker, never zero or a pass.

The current live recovery must use the wrapper, not that standalone fresh command. Before it writes
the authenticated target, the wrapper re-fetches and canonical/finality-binds the exact completed
prefix: instant launch nonce 707, timing shorten 708, instant buy plus auction launch 709-710,
timing restore 711, and the separately preserved raw owner-bid transaction/receipt at nonce 712. It
then requires production timing `125000 / 0 / 1`, latest and pending owner nonce 713, the reviewed
instant and auction intent/token identities, the exact immutable `allTokens[0:2]` prefix and live
token/CCA runtimes, and an unused HOOKR intent. Auction status may be `Auctioning` or `Live` because
permissionless migration is harmless to the independent HOOKR lane; `Failed` is rejected.

Ambient permissionless activity cannot grief this recovery checkpoint. Extra launches and collected
pool fees may only extend `tokensCount` beyond two and increase `protocolFeesWei` beyond the exact
two-creation-fee baseline of `400000000000000`. Likewise, permissionless `collect()` may move the
Phase-A flywheel accrual from `claimableWei(burner)` into the burner's native balance, so their sum
must remain at least the receipt-proven `3000000000000`; `totalEthSpent` and `totalHookrBurned` must
both remain zero. Any legacy combined `bidLaunchHookr-latest.json`, HOOKR launch/buy/index evidence,
wrong prefix/intent, lower baseline, owner nonce drift, or unavailable read blocks recovery.

Only after those recovery checks does the safe wrapper run the deployment verifier and persist
non-secret addresses, hashes, artifact digests, `deploymentSourceCommit`, and
`canaryOperatorCommit` for later stage checks. In that target record, `canaryOperatorCommit` means
the exact clean HEAD that authenticated the target; it is not silently rewritten to mean whatever
tooling HEAD happens to run later:

```bash
cd contracts
./run-canary-v5.sh preflight
./run-canary-v5.sh status
```

The canary signer environment includes all four authenticated raw runtime hashes. In particular,
`HOOKR_FLYWHEEL_BURNER_RUNTIME_CODEHASH` is required alongside:

```text
HOOKR_LAUNCHPAD_V5_RUNTIME_CODEHASH
HOOKR_HOOK_V5_RUNTIME_CODEHASH
HOOKR_SWAP_ROUTER_V5_RUNTIME_CODEHASH
HOOKR_FLYWHEEL_BURNER_RUNTIME_CODEHASH
```

The wrapper derives these from the authenticated deployment and rechecks the live code before every
stage. Do not populate them from an unauthenticated `cast codehash` result by hand.

### Robinhood ArbSys and Foundry simulation

Robinhood serves `0xfe` as the code marker at ArbSys address `0x64`; the canonical RPC executes
`arbBlockNumber()` there as a chain precompile. Foundry 1.5.1's local script EVM instead executes the
marker as an invalid opcode. `CanaryRobinhoodV5` authenticates exactly the `keccak256(0xfe)` marker
and replaces it only in local cheatcode state with a nine-byte `block.number` return shim before
`startBroadcast`. That `vm.etch` is not a transaction and cannot mutate production.

Foundry 1.5.1 does not resolve `forge script` from `ETH_RPC_URL`; it requires
`FOUNDRY_ETH_RPC_URL`. The wrapper derives one authenticated RPC value and exports it under both
names, so Cast and Forge cannot silently select different chains. The endpoint remains environment
only, is covered by the streaming stderr redactor, and is never placed in the Forge process argv.

The wrapper therefore uses `--skip-simulation`: the script's full local execution still runs with
the authenticated shim, while Forge skips its separate second simulation that cannot carry the
cheatcode override. Each real transaction still executes on Robinhood and `--slow` requires its
successful receipt before the next send. Never prepare on a fork and use `forge --resume` against
production: Foundry binds resume to the RPC stored in its cache, while the canary also hardcodes
short deadlines and CREATE-derived token/CCA addresses that can drift.

A disposable Anvil rehearsal needs the same shim installed on the fork node so its mined
transactions can execute. The script accepts that already-installed runtime only when the wrapper
has authenticated a loopback RPC and `HOOKR_UNLOCKED=1`; the production wrapper clears any inherited
exception and passes none, therefore requiring Robinhood's exact marker before local etching. After
etching, the script authenticates the shim code hash and requires `arbBlockNumber()` to return the
current block. Compile and copy the authenticated deployment inputs before starting the fork, then
capture a fresh public head and start the disposable node with exactly this history/finality policy:

```bash
: "${REHEARSAL_PORT:?set REHEARSAL_PORT to a free loopback port}"
FRESH_BASE="$(env -u ALCHEMY_RPC_URL -u HOOKR_RPC_URL -u ETH_RPC_URL -u FOUNDRY_ETH_RPC_URL \
  cast block-number --rpc-url https://rpc.mainnet.chain.robinhood.com)"
env -u ALCHEMY_RPC_URL -u HOOKR_RPC_URL -u ETH_RPC_URL -u FOUNDRY_ETH_RPC_URL \
  anvil --host 127.0.0.1 --port "$REHEARSAL_PORT" \
  --fork-url https://rpc.mainnet.chain.robinhood.com --fork-block-number "$FRESH_BASE" \
  --chain-id 4663 --auto-impersonate --slots-in-an-epoch 0 --prune-history --silent
```

`--slots-in-an-epoch 0` makes `safe` and `finalized` follow locally mined latest under the
wrapper's explicit loopback-latest rehearsal policy. Bare `--prune-history` lets the 20,000 empty
auction blocks advance without retaining unnecessary historical state snapshots, keeping current
fork-state reads inside the public provider's short archive window. The verifier still authenticates
every older Phase-A transaction, receipt, log, and block header; all post-close state/code calls are
pinned to a fresh current head. Do not combine this rehearsal with `--max-persisted-states`,
`--transaction-block-keeper`, `--preserve-historical-states`, or `--prune-history 0`, and do not pause
for manual work after starting the public fork. These flags and the shim are rehearsal-only. The
artifact validator rejects any transaction addressed to `0x64`.

Robinhood exposes two distinct block clocks and the wrapper never substitutes one for the other.
Solidity `block.number` used by Hook guard windows is the receipt header's `l1BlockNumber`, read only
through `current_contract_block`. Auction duration, CCA checkpointing, and `endBlock()` use the
rollup clock: `eth_blockNumber` must exactly equal the authenticated ArbSys `arbBlockNumber()` read
from `0x64` through `current_auction_block`. A missing, malformed, unauthenticated, or disagreeing
auction-clock read is a hard stop before any dependent signature.

## Production canary: finalized dynamic-address stages with hard interruption stops

The canonical evidence kind is:

```text
all_lanes_and_flywheel_round_trip_v5
```

The canary covers every V5 lane plus the full token flywheel:

- ETH instant launch with the four instant-compatible hook blocks and a guarded 0.001 ETH router buy.
- ETH bonded launch with all five blocks, 0.02 ETH floor FDV, 0.01 ETH raise floor, 20% reserve, and
  one 0.0105 ETH clearing bid.
- HOOKR-quoted instant launch with guard + surge and an exact 25,000 HOOKR approval/buy.
- Auction migrate, bidder exit, token claim, creator proceeds claim, burner fee collection, then an
  owner-executed bounded buyback-and-burn with a 3 HOOKR minimum output.

The sender needs at least 25,000 HOOKR; provision roughly 50,000 HOOKR to retain headroom. Peak
native outlay is about **0.0121 ETH plus gas**: three 0.0002 ETH creation fees, a 0.001 ETH instant
buy, and the 0.0105 ETH bid. Some auction value returns as disclosed creator proceeds; reserved value
becomes permanently locked liquidity. Canary tokens, locked liquidity, fees, and burns are real and
non-recoverable on production.

Each mutating command requires `HOOKR_V5_CONFIRM=<exact-command>` and authenticates the pinned
target again. This recovery operator preserves the two completed Forge stages, two raw timing
transactions, and the separately mined owner bid. It signs only the remaining HOOKR launch and
approval/buy Forge stages. Expect two secure keystore prompts. Forge
always uses `--slow --skip-simulation`; this is safe only with the authenticated local ArbSys shim
and dual-commit provenance checks above.

### A. Phase A — live recovery after the separately mined owner bid

```bash
HOOKR_V5_CONFIRM=phase-a ./run-canary-v5.sh phase-a
```

The wrapper requires production timing `125000 / 0 / 1` and refuses to recreate any missing
evidence through nonce 712. The exact live nine-transaction chronology is:

1. `707`: ETH instant launch (already mined).
2. `708`: shorten timing to `20000 / 0 / 1` (already mined).
3. `709`: guarded ETH router buy (already mined; accrues the flywheel fee).
4. `710`: ETH bonded auction launch (already mined).
5. `711`: restore timing to `125000 / 0 / 1` (already mined).
6. `712`: exact owner bid, transaction
   `0x718d6a17d804c80f011814bd90c010257aa4b2edabfb517f91ed0e18e08f5063` (already mined).
7. `713`: HOOKR-pair instant launch (next signature).
8. `714`: exact 25,000 HOOKR router approval.
9. `715`: guarded HOOKR-pair router buy, consuming that approval to zero.

The four raw Forge artifacts are `openInstant-latest.json` (1),
`buyInstantLaunchAuction-latest.json` (2), `launchHookrPair-latest.json` (1), and
`buyHookrPair-latest.json` (2). Nonce 712 remains the ordinary raw
`owner-bid-transaction.json` / `owner-bid-receipt.json` pair with bid ID `3`, 0.0105 ETH value, and
exact max price `814814390533794434497901791991308996217`. The timing calls remain separate raw
transaction/receipt pairs. Never create a synthetic Forge artifact for the owner bid.

Every dynamic address crosses a finalized boundary before it enters later calldata:

- Finalize the ETH instant launch, then authenticate its event, intent mapping, code, and
  `getLaunch` record before the router buy.
- Shorten only immediately before the buy + auction-launch stage, then restore as soon as both
  receipts are complete—before waiting for either receipt to finalize.
- Authenticate and finalize the exact raw owner-bid pair before nonce 713. The HOOKR launch accepts
  the independent ETH auction in `Auctioning` or `Live` state, so a permissionless migration cannot
  grief recovery; `Failed` remains rejected.
- Finalize the HOOKR launch, then authenticate its actual token/pool before approval + buy.
- Finalize the last stage and require `allowance(sender, router) == 0` before indexing.

The CCA duration and each canary hook guard are 20,000 blocks. The longer canary-only guard is
intentional: every dynamic launch must cross a finalized boundary before its buy is signed, so the
old 200-block guard could not truthfully exercise the snipe-tax path. The recovered owner bid was
already mined before the authenticated auction end; the independent HOOKR launch has no auction-end
headroom dependency. Hook guards use the receipt header's `l1BlockNumber`, and the wrapper plus
promotion prove both guarded buys mined before their configured guard end. Router deadlines are
proven against the mined block timestamps.

Before every signing boundary, `latest nonce == pending nonce == expected nonce` is required. After
all nine receipts finalize, `phase-a-evidence-v5.json` binds the four exact raw Forge artifacts,
the raw owner-bid pair, two raw timing pairs, both source commits, nine nonces/hashes/calldata/values/canonical
coordinates, both instant pool IDs, the auction token/CCA/end block, HOOKR-pair token, and bid ID.

Continuation is stage-level, never Forge `--resume`. This recovery wrapper requires every completed
nonce 707-712 source and refuses to recreate it. It may skip nonce 713 or 714-715 only when that raw
Forge artifact is complete, hash-matched, canonical, finalized, and live state re-authenticates.
Any partial/pending artifact is a manual hard stop. On failure, the wrapper tries
to restore production timing immediately with a visible password prompt and reports a nonzero HOOKR
allowance with an exact revoke command. If that emergency restore consumes an interstitial nonce,
the nine-transaction chronology is abandoned: do not rerun Phase A or manufacture replacement
evidence. The wrapper persists `phase-a-abandoned-v5.json` so later invocations remain blocked.
Preserve every artifact and reconcile it manually.

`INT`, `TERM`, and `HUP` exit through the visible restore guard. The wrapper ignores `TSTP` for
itself and signer children while Phase A runs, so Ctrl-Z cannot suspend a password prompt during
the shortened-timing interval. `SIGSTOP`, `SIGKILL`, power loss, and terminal loss cannot run shell
cleanup: immediately re-read timing from a new shell and use `restore` if it is not
`125000 / 0 / 1`. The wrapper isolates Forge's resolved endpoint in a private disposable cache and
removes that cache after every stage; do not use `forge --resume` or a manually copied cache.

The wrapper holds one exclusive `.operator-lock` for every invocation, including `status`, so a
second operator cannot race signer nonces or delete an active Forge cache. If SIGKILL, terminal
loss, or power failure leaves the lock behind, do not blindly delete it: first prove the recorded
PID is gone, read production timing and pending/latest nonces independently, and reconcile every
receipt. Then remove only `broadcast/CanaryRobinhoodV5.s.sol/4663/.operator-lock` before recovery.

`restore` is emergency recovery only. It sends nothing when timing is already production:

```bash
HOOKR_V5_CONFIRM=restore ./run-canary-v5.sh restore
```

### B. Phase B — six canonically reconciled outcomes

The mined Phase-A v3 index permanently records
`canaryRecoveryCommit = cfb571c16a24842738f9c39ecf4c2ce00f6c05d4`. Do not edit the index or
relabel its Forge artifacts when Phase-B tooling changes. Phase B may run from a clean descendant
commit containing wrapper, verifier, test, or documentation hardening. The wrapper derives the
Phase-A recovery commit from the index, requires that full commit to exist, requires the
authenticated target operator to equal it, proves it descends from the deployment source and is an
ancestor of the current tooling HEAD, and revalidates the Phase-A artifacts against that historical
commit. It separately proves that neither the recovery commit nor the descendant tooling commit
changed `contracts/src`, `contracts/lib`, `contracts/foundry.toml`, or
`contracts/script/DeployRobinhoodV5.s.sol`, and that the descendant did not change the mined
`contracts/script/CanaryRobinhoodV5.s.sol`. Phase-B signing plans and Phase-B evidence truthfully
separate the two meanings: each owner signing plan records the current descendant tooling HEAD,
while the Phase-B index's existing `sourceCommit` field remains the authenticated immutable canary
source (`canaryRecoveryCommit`) required by the promotion schema. The current HEAD is independently
ancestry/source-diff checked at runtime and by promotion; neither index is relabeled. `status` prints
the target operator and current tooling HEAD as separate fields.

By the time all three Phase-A finality barriers complete, the 20,000-block auction should normally
have ended. Confirm `status` shows production timing restored. The wrapper derives the auction token
and bid ID from the authenticated Phase-A evidence and live intent mapping. Before migration, it
requires `current_auction_block > auctionEndBlock`; this is the authenticated ArbSys/rollup clock,
never the Hook guard's header `l1BlockNumber` clock:

```bash
./run-canary-v5.sh status
HOOKR_V5_CONFIRM=phase-b ./run-canary-v5.sh phase-b
```

The six required outcomes are:

1. `pad.migrateAuction(token)`; 5.0.1 checkpoints the CCA before reading graduation.
2. `auction.exitBid(bidId)`.
3. `auction.claimTokens(bidId)` or a permissionless batch claim containing that bid at least once;
   duplicate IDs are tolerated only when the receipt proves exactly one positive canary claim.
4. `pad.claimAuctionProceeds(token)` when migration credited positive creator proceeds; otherwise an
   explicit authenticated `not-applicable-zero-proceeds` outcome aliases the migration receipt and
   no claim transaction is sent.
5. `burner.collect()`.
6. Owner-executed bounded `burner.buybackAndBurn(...)` with a 3 HOOKR minimum output.

The first five transitions are permissionless when applicable. A keeper may migrate, settle the bid, claim tokens or
proceeds, or collect the flywheel fee before the owner returns, directly or through a helper that
performs several transitions in one transaction. The wrapper therefore rescans canonical events
before every prompt, signs only a missing transition, and accepts any caller/nonce that proves the
exact reviewed outcome. Only `buybackAndBurn(3000000000000, 3e18)` must be a direct call from the
release owner. Evidence enforces only the real dependency edges: migrate before proceeds claim,
exit before token claim, and the exact Phase-A pool accrual before collect before buyback. Every
selected receipt must finalize before its dependent transition. A failed or ambiguous send is never
blindly retried; rerunning the wrapper rescans first.

Before every owner signature, the wrapper requires `latest == pending`, pins the exact nonce, and
for the buyback performs a read-only live `eth_call` from the exact release owner for
`buybackAndBurn(3000000000000, 3e18)`. The returned burn must decode and be at least 3 HOOKR; an
unavailable, reverted, malformed, or below-floor simulation stops before any signing journal or
signature. Only after that check does it atomically write the per-action plan under
`phase-b-signing-journal-v5/`. A failed, rejected, or
response-lost send leaves that journal in place and no rerun will sign the action again. Reconcile
the exact nonce, mempool transaction, and receipt manually; do not delete a journal merely because
the outcome scanner has not found a finalized event yet. This is especially strict for the bounded
buyback, which must never be submitted twice.

If a completed migration journal already exists, the wrapper treats it as a permanent no-retry
boundary. It authenticates the regular non-symlinked plan, transaction, and receipt; re-fetches the
exact transaction hash and complete ordered logs from the live RPC; proves the journal's operator
commit is on the authenticated target-to-current ancestry; and requires the collector to select
that same canonical migration hash. It then waits for the collector-selected receipt to finalize.
Never delete the journal, manually copy its files into the evidence directory, or rerun migration.
The collector installs only its independently fetched canonical pair.

The migration may legitimately consume the full swept raise as pool liquidity. In that case the
receipt has no `AuctionProceeds` event, `Migrated.ethLiquidity == CurrencySwept.currencyAmount`, and
the live creator-proceeds ledger is zero. Only the collector's exact
`not-applicable-zero-proceeds` result may satisfy the proceeds outcome without a transaction: the
wrapper also requires its action hash and proof hash to equal the migration hash. If the outcome is
missing while the ledger is zero, the wrapper stops before signing a claim that would revert. The
positive-proceeds path remains unchanged and sends or reconciles `claimAuctionProceeds(token)`.

The wrapper stores six canonical outcome references under `phase-b-evidence-v5/`; several of the
first five may bind the same raw RPC transaction/receipt pair. A zero-proceeds run therefore has
five transactions but still six authenticated outcomes. It builds `phase-b-evidence-v5.json`
and automatically runs the full promotion dry-run before reporting Phase B complete. No synthetic
Forge settlement artifact exists.

Do not promote unless Phase A is exact raw Forge 1+2+1+2 plus the raw owner-bid pair and both timing pairs, all six Phase-B
outcomes and all 15 canary action references are authenticated and finalized, the dynamic identities and clocks
agree, both router inputs were fully consumed, the HOOKR allowance is zero, receipt-local events
prove the clearing-price migration and exact flywheel accrual/collect/bounded burn, creator proceeds
are either positively claimed or proven exactly zero at migration, and timing reads back
`125000 / 0 / 1`.

## Promotion

First run the complete promotion verifier without writing the manifest:

```bash
./contracts/run-canary-v5.sh promote-dry-run
```

Equivalent explicit command from the worktree root:

```bash
node scripts/promote-release-manifest.mjs \
  --deploy contracts/broadcast/DeployRobinhoodV5.s.sol/4663/run-latest.json \
  --library-evidence contracts/release-evidence/v5/reused-launchpad-library.json \
  --canary-instant-launch contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/openInstant-latest.json \
  --canary-instant-buy-auction-launch contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/buyInstantLaunchAuction-latest.json \
  --canary-owner-bid-transaction contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/owner-bid-transaction.json \
  --canary-owner-bid-receipt contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/owner-bid-receipt.json \
  --canary-hookr-launch contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/launchHookrPair-latest.json \
  --canary-hookr-approve-buy contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/buyHookrPair-latest.json \
  --canary-timing-shorten-transaction contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/timing-shorten-transaction.json \
  --canary-timing-shorten-receipt contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/timing-shorten-receipt.json \
  --canary-timing-restore-transaction contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/timing-restore-transaction.json \
  --canary-timing-restore-receipt contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/timing-restore-receipt.json \
  --canary-phase-a-index contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/phase-a-evidence-v5.json \
  --canary-phase-b-index contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/phase-b-evidence-v5.json \
  --dry-run
```

The verifier pins finalized receipts and one canonical state snapshot; authenticates immutable
deployment source plus the descendant canary operator source,
runtime, addresses, wiring, blueprints, timing, all 15 canary transactions and their decoded
calldata/events/readbacks; proves the CCA round trip and HOOKR-pair trade; and proves collect →
bounded buyback → dead-address burn. Only after reviewing that output should the manifest-writing
command be separately authorized:

```bash
node scripts/promote-release-manifest.mjs \
  --deploy contracts/broadcast/DeployRobinhoodV5.s.sol/4663/run-latest.json \
  --library-evidence contracts/release-evidence/v5/reused-launchpad-library.json \
  --canary-instant-launch contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/openInstant-latest.json \
  --canary-instant-buy-auction-launch contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/buyInstantLaunchAuction-latest.json \
  --canary-owner-bid-transaction contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/owner-bid-transaction.json \
  --canary-owner-bid-receipt contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/owner-bid-receipt.json \
  --canary-hookr-launch contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/launchHookrPair-latest.json \
  --canary-hookr-approve-buy contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/buyHookrPair-latest.json \
  --canary-timing-shorten-transaction contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/timing-shorten-transaction.json \
  --canary-timing-shorten-receipt contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/timing-shorten-receipt.json \
  --canary-timing-restore-transaction contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/timing-restore-transaction.json \
  --canary-timing-restore-receipt contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/timing-restore-receipt.json \
  --canary-phase-a-index contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/phase-a-evidence-v5.json \
  --canary-phase-b-index contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/phase-b-evidence-v5.json
```

The generated generation-5 manifest must retain generation 4 as a read identity, use
`launchModes: ["instant", "bonded"]`, include the library source provenance, all deployment and
canary receipts, the burner address/runtime hash/configuration, and
`canaryReceipts.kind = "all_lanes_and_flywheel_round_trip_v5"`, plus the authenticated Phase-A
and Phase-B index SHA-256 values.

## App and infrastructure go-live

Manifest promotion is not the public release by itself. On the exact promoted commit:

- Edit `public/llms.txt`, which is static and cannot branch on the runtime manifest. Describe the
  fixed-price instant lane, bonded clearing-price auction, HOOKR pairs, and owner-executed flywheel;
  retain only the actually supported V3/V4 curve history. Do not claim Hookr launches appear on
  pools.trade.
- Verify the instant and bonded wizard paths, ETH and HOOKR quote labels, exact approvals/value,
  failure states, and the Simple/Full boundary on desktop and narrow mobile.
- Run the permissionless migration keeper only against authenticated V5 launches and surface failed
  reads as unavailable, not zero.
- Deploy the exact reviewed Git commit through the approved Vercel/Git workflow, then independently
  verify the production alias, bundle/release identity, wallet flows, and chain readbacks.

Call the release production-verified only after the contract receipts, final state, promoted source
commit, production deployment identity, canonical alias, and browser smoke all agree.
