# HOOKR utility rail v1 release runbook

> [!WARNING]
> **SUPERSEDED — RECOVERY ONLY.** V1 was not promoted and its candidate promoter is permanently
> retired. Do not execute the deployment, canary, verification, or promotion commands below for a
> new release. Preserve this file only for historical evidence and recovery of the existing V1
> positions. All new utility release work must follow [`UTILITY_V2_RELEASE.md`](./UTILITY_V2_RELEASE.md).

This runbook covers only `HookrLockRewardsV1` and `HookrLaunchBoostV1`. It does not authorize a
deployment. Every live signing prompt remains user-confirmed. Candidate source, simulation output,
local tests, fork receipts, and Blockscout source verification are not production receipt evidence.

The utility contracts are a separate deployment sequence, but Launch Boost is immutably bound to
the promoted Hookr generation-4 launchpad. Deploy and verify generation 4 first; never bind these
contracts to generation 3, a simulation, or an unpromoted address. Do not edit or reuse
`DeployRobinhood.s.sol`, `CanaryRobinhood.s.sol`, `run-canary.sh`, or their broadcast artifacts for
the utility stage. The core sequence stays exactly ten receipts. The utility sequence is exactly
three later receipts:

1. `CREATE HookrLockRewardsV1(HOOKR, expectedDeployer)`;
2. `CREATE HookrLaunchBoostV1(HOOKR, promotedV4Launchpad, lockRewards)`;
3. `lockRewards.setRewardSourceOnce(launchBoost)`.

`FullMath` and `HookrTokenTransfer` are inlined, so no utility library receipt is expected.

Launch Boost's enumeration is a bounded active registry, not an append-only historical index.
`MAX_ACTIVE_BOOSTS` is exactly `512`. A still-registered active position may be topped up even at
capacity. A new or withdrawn-and-readded position reverts with `CapacityFull(512)` before reward
checkpointing, fee routing or token pull when all slots are occupied. After unlock, anyone may call
`pruneExpired(token)` to swap-remove only its registry membership. Pruning does not modify position
principal, creator, tier, timestamps, liability or withdrawal rights; creator withdrawal still
works, and a later Boost can re-add the token after withdrawal when capacity exists. Because
swap-removal changes page order, consumers must treat the token address as identity, refresh pages
across writes and never persist an array index as a cursor or launch identifier.

## Immutable release anchors

- chain: Robinhood Chain `4663`;
- deployer: `0x5a52D4B820Ae7F02880d270562950918ACb14aA2`;
- HOOKR: `0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c`;
- HOOKR runtime codehash:
  `0xd9346eaf1a9878650549765e1d4ce8b3d0516d93d3203e1c8b99e382428ebc8d`.

The supported launchpad address and runtime hash are intentionally not hardcoded before generation
4 is promoted. Copy both from the production-enabled, receipt-backed generation-4 manifest. Never
use a candidate simulation address, fork address, or whichever address merely answers RPC reads.
Set them as:

```bash
export HOOKR_UTILITY_LAUNCHPAD_ADDRESS=0x...
export HOOKR_UTILITY_LAUNCHPAD_RUNTIME_CODEHASH=0x...
```

## 0. Local hardening and lifecycle canary

Run from the repository root. This never forks, loads a signer, or broadcasts:

```bash
contracts/run-utility-local-canary.sh
(cd contracts && forge test --match-contract HookrLockRewardsV1Test -vv)
(cd contracts && forge test --match-contract HookrUtilityCanaryScriptsTest -vv)
```

The focused canary proves deployment/wiring in the fixture, next-epoch lock activation, a fee-bearing
boost, exact cross-vault solvency identities, reward settlement and claim, and both principal
withdrawals. The complete utility suite additionally covers ceiling-fee split resistance,
multi-locker proportionality, double-claim rejection, expiry, 64-epoch catch-up, hostile token
behavior, callback reentrancy, permit front-running, exact 512-slot saturation, registered top-ups
at capacity, swap-removal index consistency, and prune-without-custody-mutation followed by
withdrawal and re-Boost.

Before a release, also run the full contract suite and size check:

```bash
cd "$(git rev-parse --show-toplevel)/contracts"
forge test
forge build --sizes
```

Both utility runtimes must stay below EIP-170. Current candidate sizes are 8,889 bytes for Lock
Rewards and 10,369 bytes for Launch Boost. Runtime template and immutable-layout anchors live only in
`scripts/lib/utility-runtime-evidence.mjs`; any source/compiler/layout change requires independent
reproduction and review of replacement anchors.

## 1. No-broadcast production simulation

The command has no account and no `--broadcast`, so it does not load a signer or submit a
transaction:

```bash
cd "$(git rev-parse --show-toplevel)"
node scripts/verify-utility-core-prerequisite.mjs \
  --launchpad "$HOOKR_UTILITY_LAUNCHPAD_ADDRESS" \
  --launchpad-codehash "$HOOKR_UTILITY_LAUNCHPAD_RUNTIME_CODEHASH" \
  --rpc https://rpc.mainnet.chain.robinhood.com &&
cd contracts &&
forge script script/DeployHookrUtilities.s.sol:DeployHookrUtilities \
  --rpc-url https://rpc.mainnet.chain.robinhood.com \
  --sender 0x5a52D4B820Ae7F02880d270562950918ACb14aA2
```

It must print `Script ran successfully.` It checks chain, HOOKR codehash, the explicitly pinned
launchpad runtime and identity, all utility identities/linkage/policy, ambient-safe accounting,
the exact 512-position active-registry capacity, ambient-safe accounting identities, solvency, and
EIP-170 sizes. Permissionless positions or Boosts cannot invalidate the receipt/runtime proof.
Save the candidate
runtime hashes for review, but do not treat them as live addresses or receipts.

## 2. Live deploy — separate confirmation boundary

Only from a clean commit containing the reviewed utility source and after explicit user approval:

```bash
cd "$(git rev-parse --show-toplevel)"
node scripts/verify-utility-core-prerequisite.mjs \
  --launchpad "$HOOKR_UTILITY_LAUNCHPAD_ADDRESS" \
  --launchpad-codehash "$HOOKR_UTILITY_LAUNCHPAD_RUNTIME_CODEHASH" \
  --rpc https://rpc.mainnet.chain.robinhood.com &&
cd contracts &&
forge script script/DeployHookrUtilities.s.sol:DeployHookrUtilities \
  --rpc-url https://rpc.mainnet.chain.robinhood.com \
  --account nodar-deployer \
  --sender 0x5a52D4B820Ae7F02880d270562950918ACb14aA2 \
  --broadcast --slow
```

Never put a private key in argv, a file, or a report. After each transaction, verify its live status
before continuing. A later revert cannot roll back an earlier receipt. If the sequence stops, do
not rerun blindly: preserve the artifact, identify which addresses actually have code, and prepare
only the missing transaction under a new review. In particular, an unlinked Lock Rewards instance
still leaves the temporary configurator with authority to set exactly one source.

Expected artifact:

`contracts/broadcast/DeployHookrUtilities.s.sol/4663/run-latest.json`

It must contain exactly three unique, successful receipts from the expected deployer in the order
listed above, with zero native value.

## 3. Read-only receipt/runtime preflight

Wait for all three receipts to be finalized, then run before any canary signer is loaded:

```bash
cd "$(git rev-parse --show-toplevel)"
node scripts/verify-utility-deployment-preflight.mjs \
  --deploy contracts/broadcast/DeployHookrUtilities.s.sol/4663/run-latest.json \
  --launchpad "$HOOKR_UTILITY_LAUNCHPAD_ADDRESS" \
  --launchpad-codehash "$HOOKR_UTILITY_LAUNCHPAD_RUNTIME_CODEHASH" \
  --rpc https://rpc.mainnet.chain.robinhood.com
```

The verifier first reruns the same manifest-bound generation-4 prerequisite used before simulation
and live deployment; `--launchpad` and `--launchpad-codehash` are equality assertions, never
authorities. It then binds hash-matched artifact receipts to live canonical headers and finalized
inclusion, proves exact constructor calldata and the `RewardSourceSet(boost)` linkage event,
compares live runtimes with locally source-hashed compiler artifacts while masking only
solc-declared immutables, and pins all policy/accounting readbacks to one safe block hash before
rechecking canonicality. `--rehearsal` is accepted only for a loopback RPC.

Source verification is additional evidence, not a substitute for the preflight:

```bash
forge verify-contract "$LOCK_REWARDS_ADDRESS" \
  src/HookrLockRewardsV1.sol:HookrLockRewardsV1 \
  --constructor-args "$(cast abi-encode 'constructor(address,address)' \
    0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c \
    0x5a52D4B820Ae7F02880d270562950918ACb14aA2)" \
  --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api --chain-id 4663

forge verify-contract "$LAUNCH_BOOST_ADDRESS" \
  src/HookrLaunchBoostV1.sol:HookrLaunchBoostV1 \
  --constructor-args "$(cast abi-encode 'constructor(address,address,address)' \
    0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c \
    "$HOOKR_UTILITY_LAUNCHPAD_ADDRESS" "$LOCK_REWARDS_ADDRESS")" \
  --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api --chain-id 4663
```

## 4. Pin the staged-script environment

The deployment preflight output is the authority for the two utility addresses and reviewed runtime
hashes. Set all six values explicitly. These variables are execution-time TOCTOU pins; they do not
replace the receipt/runtime preflight:

```bash
export HOOKR_UTILITY_LOCK_REWARDS_ADDRESS=0x...
export HOOKR_UTILITY_LOCK_REWARDS_RUNTIME_CODEHASH=0x...
export HOOKR_UTILITY_LAUNCH_BOOST_ADDRESS=0x...
export HOOKR_UTILITY_LAUNCH_BOOST_RUNTIME_CODEHASH=0x...
export HOOKR_UTILITY_LAUNCHPAD_ADDRESS=0x...
export HOOKR_UTILITY_LAUNCHPAD_RUNTIME_CODEHASH=0x...
```

Each stage rechecks chain `4663`, the reviewed HOOKR runtime, all three runtime hashes, contract
identities and immutable links, the one-shot reward-source link, and the burned configurator before
its first broadcast. The scripts use only the expected deployer and contain no private-key or
automatic-broadcast path.

All deposit calls are execution-bounded. Lock calls pin the previewed activation epoch and a maximum
unlock timestamp; product wallet flows may add only their explicitly displayed, at-most-15-minute
mining tolerance to the previewed unlock timestamp. Boost calls pin both the maximum reward fee and
minimum refundable principal. Launch Boost extension calls also pin a maximum unlock timestamp before
mutating the position. The staged canary uses a 10-minute lock/unlock tolerance, refuses to start
within 15 minutes of a Monday boundary, and pins the exact `1/99 HOOKR` Boost split.

## 5. Live canary is necessarily staged

An immediate boost after the first lock would exercise only the fee-waiver branch: a new lock is
ineligible until the next Monday 00:00 UTC epoch. A real canary therefore spans time and must use
separate script names so later stages cannot overwrite earlier evidence.

Use exactly `1 HOOKR` for the Lock stage and the contract minimum of exactly `100 HOOKR` for the
Boost stage, and record these five labeled receipts:

1. HOOKR `approve(lockRewards, 1 ether)`;
2. `lockRewards.lock(1 ether, tier0, previewActivationEpoch, previewUnlockAt, deadline)`;
3. after the next Monday, HOOKR `approve(launchBoost, 100 ether)`;
4. `launchBoost.boostByIntent(coreCanaryIntent, 100 ether, tier0, 1 ether, 99 ether, deadline)`;
5. after the following Monday, `lockRewards.claim(positionId, deployer)`.

Resolve the token through the promoted launchpad's
`launchedByIntent(deployer, keccak256("hookr.v4.canary.instant.all-five.1"))` and independently
require the `getLaunch(token)` token and creator to match. The boost receipt must show exactly
`1 HOOKR` forwarded as the reward fee and `99 HOOKR` retained as refundable boost principal.
On Robinhood, compare `startedAtBlock` with the receipt header's `l1BlockNumber`, not the RPC receipt
height.

### Stage 1 — approve and lock

First run a no-broadcast simulation. It neither loads the account nor sends a transaction:

```bash
cd "$(git rev-parse --show-toplevel)/contracts"
forge script script/CanaryHookrUtilitiesLock.s.sol:CanaryHookrUtilitiesLock \
  --rpc-url https://rpc.mainnet.chain.robinhood.com \
  --sender 0x5a52D4B820Ae7F02880d270562950918ACb14aA2
```

Only after the simulation and a separate user approval, run the live stage:

```bash
forge script script/CanaryHookrUtilitiesLock.s.sol:CanaryHookrUtilitiesLock \
  --rpc-url https://rpc.mainnet.chain.robinhood.com \
  --account nodar-deployer \
  --sender 0x5a52D4B820Ae7F02880d270562950918ACb14aA2 \
  --broadcast --slow
```

Archive `contracts/broadcast/CanaryHookrUtilitiesLock.s.sol/4663/run-latest.json`. It must contain
exactly the approval and lock receipts. The script rejects an existing deployer canary position,
nonzero deployer allowance, or any amount other than its compiled one-HOOKR action. Unrelated user
positions and ledgers are allowed and later proved through receipt-local deltas. If only the
approval mines, do not rerun: preserve the partial artifact and prepare a separately reviewed
recovery.

### Stage 2 — after the next Monday, approve and Boost

Run only during the position's exact activation epoch. Immediately confirm the active registry has
space, then simulate without an account first:

```bash
cd "$(git rev-parse --show-toplevel)/contracts"
active_boosts=$(cast call "$HOOKR_UTILITY_LAUNCH_BOOST_ADDRESS" \
  "boostedTokensCount()(uint256)" --rpc-url https://rpc.mainnet.chain.robinhood.com)
test "$active_boosts" -lt 512
forge script script/CanaryHookrUtilitiesBoost.s.sol:CanaryHookrUtilitiesBoost \
  --rpc-url https://rpc.mainnet.chain.robinhood.com \
  --sender 0x5a52D4B820Ae7F02880d270562950918ACb14aA2
```

Repeat that read immediately before a new, explicit user approval. Capacity is permissionless and
best-effort: 512 unrelated active Boosts can prevent the canary's first position. The contract
reverts before pulling the 100-HOOKR Boost deposit or forwarding its fee, but the separate approval
receipt may already have mined; preserve that partial evidence and do not rerun blindly.

```bash
forge script script/CanaryHookrUtilitiesBoost.s.sol:CanaryHookrUtilitiesBoost \
  --rpc-url https://rpc.mainnet.chain.robinhood.com \
  --account nodar-deployer \
  --sender 0x5a52D4B820Ae7F02880d270562950918ACb14aA2 \
  --broadcast --slow
```

Archive `contracts/broadcast/CanaryHookrUtilitiesBoost.s.sol/4663/run-latest.json`. The script
resolves the fixed core intent through `launchedByIntent(expectedDeployer, intent)`, repeats
`getLaunch(token)` creator/token validation, and asserts the exact ceiling-rounded split:
`100 HOOKR gross = 99 HOOKR refundable principal + 1 HOOKR reward fee`. Its canonical-position and
allowance guards reject replay or a partially mined prior stage. Ambient user ledgers and registry
entries are allowed: the script proves exact gross/principal/fee/count deltas and valid canonical
token membership under the exact 512-slot policy.

### Stage 3 — after the following Monday, claim

Run only during the immediate following epoch. Simulate first:

```bash
cd "$(git rev-parse --show-toplevel)/contracts"
forge script script/CanaryHookrUtilitiesClaim.s.sol:CanaryHookrUtilitiesClaim \
  --rpc-url https://rpc.mainnet.chain.robinhood.com \
  --sender 0x5a52D4B820Ae7F02880d270562950918ACb14aA2
```

After a third, separate user approval:

```bash
forge script script/CanaryHookrUtilitiesClaim.s.sol:CanaryHookrUtilitiesClaim \
  --rpc-url https://rpc.mainnet.chain.robinhood.com \
  --account nodar-deployer \
  --sender 0x5a52D4B820Ae7F02880d270562950918ACb14aA2 \
  --broadcast --slow
```

Archive `contracts/broadcast/CanaryHookrUtilitiesClaim.s.sol/4663/run-latest.json`. The one-receipt
stage requires the exact deployer position and canonical Boost state, then claims the canary's
mathematically proven pro-rata share of the realized fee. Unrelated eligible weight may reduce that
share below `1 HOOKR`; the verifier derives it from the pinned start/end reward indexes rather than
assuming an isolated cohort or zero remainder. The deployer position's claim cursor rejects replay.

A source-tested withdrawal is not live receipt proof: the earliest tier-0 principal withdrawal is
30 days after each deposit. The five-receipt canary deliberately proves approval, custody, fee
routing and reward claim, not a later live withdrawal.

## 6. Exact 3+5 evidence verifier

After the claim receipt and the readback block finalize, run:

```bash
cd "$(git rev-parse --show-toplevel)"
node scripts/verify-utility-canary-evidence.mjs \
  --deploy contracts/broadcast/DeployHookrUtilities.s.sol/4663/run-latest.json \
  --lock contracts/broadcast/CanaryHookrUtilitiesLock.s.sol/4663/run-latest.json \
  --boost contracts/broadcast/CanaryHookrUtilitiesBoost.s.sol/4663/run-latest.json \
  --claim contracts/broadcast/CanaryHookrUtilitiesClaim.s.sol/4663/run-latest.json \
  --rpc https://rpc.mainnet.chain.robinhood.com
```

The verifier is read-only. It requires exactly `3 + 2 + 2 + 1` hash-matched successful receipts,
strict cross-artifact order and uniqueness, exact sender/target/value/calldata, canonical constructor
initcode, exact events and transfers, finalized canonical headers, the Robinhood
`l1BlockNumber` contract clock, the shared exact generation-4 preview/all-five core proof, zero
residual allowances, receipt-scoped canary deltas, monotonic ambient ledgers and solvency identities.
Direct token donations and unrelated valid positions remain ambient state and cannot grief
promotion. The final readback also pins `MAX_ACTIVE_BOOSTS == 512` and the canary token's valid
registry membership/index range. State reads share one EIP-1898 block hash, which is
rechecked for canonicality and must finalize before output.

The deployment artifact commit defines `sourceCommit`. Later stage artifacts may have different Git
commits only when the verifier's pinned utility/core evidence path set is byte-identical to that
deployment commit; unrelated application work does not invalidate a multi-week canary. Any relevant
dirty file or relevant cross-commit diff fails closed. A loopback fork must pass `--rehearsal`.

## 7. Deterministic candidate promotion and terms hash

Do not populate `CURRENT_UTILITY_RELEASE` from hand-copied addresses. Promotion must bind:

- the exact utility source commit (`0x` plus the 40-character Git SHA);
- three labeled deployment receipts and five labeled canary receipts, with uniqueness and strict
  order enforced;
- runtime codehashes and a linkage `{blockNumber, blockHash}`;
- the exact supported core release and launchpad runtime;
- a checked-in terms document whose raw UTF-8 bytes are hashed by the promoter;
- separately archived original artifacts plus checksums.

`docs/HOOKR_UTILITY_TERMS_V1.md` is the exact v1 terms source. Its reviewed Keccak-256 is stored in
`src/lib/utility-terms.generated.json`, and a byte-identical public copy is served at
`/terms/HOOKR_UTILITY_TERMS_V1.md`. Build, CI, tests and the promoter all run the same verifier over
the raw bytes; no caller-provided terms hash is accepted. After an intentional terms edit, run
`npm run generate:utility-terms`, review all three changed files, and then run
`npm run verify:utility-terms`. Generation is deliberately never automatic during build.

The promoter reruns both that byte verifier and the exact 3+5 receipt verifier and emits the
application-facing schema-2 candidate to stdout without editing
`src/lib/utility-release.generated.json` or any CURRENT manifest:

```bash
cd "$(git rev-parse --show-toplevel)"
node scripts/promote-utility-release-candidate.mjs \
  --deploy contracts/broadcast/DeployHookrUtilities.s.sol/4663/run-latest.json \
  --lock contracts/broadcast/CanaryHookrUtilitiesLock.s.sol/4663/run-latest.json \
  --boost contracts/broadcast/CanaryHookrUtilitiesBoost.s.sol/4663/run-latest.json \
  --claim contracts/broadcast/CanaryHookrUtilitiesClaim.s.sol/4663/run-latest.json \
  --rpc https://rpc.mainnet.chain.robinhood.com
```

The deterministic payload contains exactly the schema/version/chain/production flag, `0x`-prefixed
utility source commit, deploy block, HOOKR identity, supported core id/source, three contract
identities, policy (including the 100-HOOKR minimum and 512-position active capacity), linkage
block/hash, terms path/hash, three labeled deployment receipts, five labeled canary receipts and
final canary readback. Production evidence emits
`productionAllowed: true`; `--rehearsal` emits `false` and is accepted only with a loopback RPC and
an explicit rehearsal core fixture.

Review the emitted JSON before separately deciding whether to place it in the generated application
manifest. This promoter never makes that edit. Archive the four original Forge artifacts, the
candidate JSON and an operator-created `SHA256SUMS` under `contracts/evidence/utilities/v1/`; never
replace originals with hand-normalized copies.

Opaque receipt arrays, an unfinalized state block, a hand-copied address, or a candidate JSON alone
are not release evidence. Until the deployment and all three live stages succeed and the emitted
candidate is separately reviewed and installed, the accurate state remains **source-ready,
locally canaried, not deployed, and writes closed**.
