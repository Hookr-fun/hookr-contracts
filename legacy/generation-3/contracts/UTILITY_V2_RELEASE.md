# Hookr Utility V2 Release Runbook

This runbook covers only the bootstrap-enabled `HookrLockRewardsV2` and
`HookrLaunchBoostV2` rail. It does not authorize a deployment, wallet signature, broadcast,
promotion, or change to the already promoted generation-4 Hookr core. Every live command needs a
separate user approval, and every mined stage must be archived and finalized before the next stage.

V2 exists to make the first fee-bearing lifecycle observable without weakening the complete-epoch
accounting rule. The first two epochs are exactly two hours. Epoch two begins four hours after the
LockRewards CREATE and bridges to the first strictly later Monday 00:00 UTC. Weekly epochs begin
thereafter.

## Exact receipt contract

The complete release evidence is exactly eight successful, zero-native-value receipts in strict
order:

1. `CREATE HookrLockRewardsV2(HOOKR, expectedDeployer)`;
2. `CREATE HookrLaunchBoostV2(HOOKR, promotedV4Launchpad, lockRewardsV2)`;
3. `lockRewardsV2.setRewardSourceOnce(launchBoostV2)`;
4. HOOKR `approve(lockRewardsV2, 1 ether)`;
5. `lockRewardsV2.lock(1 ether, tier0, ...)`;
6. HOOKR `approve(launchBoostV2, 100 ether)`;
7. `launchBoostV2.boostByIntent(coreCanaryIntent, 100 ether, tier0, 1 ether, 99 ether, ...)`;
8. `lockRewardsV2.claim(positionId, expectedDeployer)`.

That is `3 + 2 + 2 + 1`. A partial artifact is not permission to rerun. Preserve it, stop, and
prepare a separately reviewed recovery. Never merge receipts from separate attempts.

## Immutable identities

- Chain: Robinhood Chain mainnet, chain ID `4663`.
- Expected deployer: `0x5a52D4B820Ae7F02880d270562950918ACb14aA2`.
- HOOKR: `0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c`.
- Reviewed HOOKR runtime hash:
  `0xd9346eaf1a9878650549765e1d4ce8b3d0516d93d3203e1c8b99e382428ebc8d`.
- Supported core release: `hookr-4663-v4`, source `df6835d51d5460d4e57fee81352b18be486cb5c5`.
- Promoted v4 launchpad: `0x5Ce779D23D2e99D322004F203813389B6a426e3B`.
- Promoted v4 launchpad runtime hash:
  `0x433411c5613df1dd265dfac168c7f78c4cfcbe87c7ae4ab669d1ff5340d09c71`.
- Fixed core canary intent: `keccak256("hookr.v4.canary.instant.all-five.1")`.

Re-read the promoted release manifest before any live action. Stop if its identity, source,
production gate, runtime, fixed canary, or exact instant-launch readback differs.

## Source and local gates

Start from the reviewed clean commit. Record it before simulation and again before broadcast:

```bash
git status --short
git rev-parse HEAD
```

Run all contract gates from `contracts/`:

```bash
cd "$(git rev-parse --show-toplevel)/contracts"
./run-utility-v2-local-canary.sh
forge fmt --check
forge test -vv
forge build --sizes
```

The deterministic local suite exercises:

- exact deployment-derived bootstrap boundaries;
- the pre-opening Boost hard revert;
- the `2 + 2 + 1` staged canary and replay rejection;
- at least 45 minutes remaining in the lock, fee, and bridge stages;
- a bridge claim more than two hours after `claimEpochStartsAt`;
- ambient locks, Boosts, and claims with receipt-local delta proofs;
- a full Boost registry rejection before any canary approval or token pull;
- the exact 100 HOOKR = 99 HOOKR refundable principal + 1 HOOKR reward fee split; and
- the promoted-v4 core probe and minimum bridge-window guard.

Passing tests prove source behavior only. They are not deployment or receipt evidence.

## Bootstrap boundaries

The first LockRewards CREATE timestamp is `bootstrapStartedAt`:

```text
epoch 0: [bootstrapStartedAt, feeEpochStartsAt)
feeEpochStartsAt   = bootstrapStartedAt + 2 hours
epoch 1: [feeEpochStartsAt, claimEpochStartsAt)
claimEpochStartsAt = feeEpochStartsAt + 2 hours
epoch 2: [claimEpochStartsAt, weeklyEpochsStartAt)
weeklyEpochsStartAt = first Monday 00:00 UTC strictly after claimEpochStartsAt
epoch 3+: weekly Monday-aligned epochs
```

The deployment script derives the prospective boundaries before `startBroadcast` and rejects a
claim bridge shorter than 45 minutes. It repeats the derivation from the actual deployed
immutables. The three canary scripts then enforce:

- Stage 1: epoch `0`, with at least 45 minutes before `feeEpochStartsAt`;
- Stage 2: epoch `1`, with at least 45 minutes before `claimEpochStartsAt`; and
- Stage 3: bridge epoch `2`, with at least 45 minutes before `weeklyEpochsStartAt`.

There is deliberately no artificial `claimEpochStartsAt + 2 hours` cutoff. A valid bridge claim
remains possible until the final 45-minute safety margin before the first weekly boundary.

## Required balances

Before deployment, independently confirm:

- the expected deployer controls the reviewed signer;
- enough native ETH is available for exactly three deployment receipts and five canary receipts;
- at least `101 HOOKR` is available for the bounded canary (`1` lock + `100` Boost); and
- no unexpected V2 contract addresses, approvals, positions, or artifacts already exist.

The scripts never send native value. Do not log private keys, keystore material, passwords, or raw
credential output. The account remains user-confirmed; automation must not approve a wallet prompt.

## Deployment — three receipts

Set only the promoted core identity:

```bash
export HOOKR_UTILITY_V2_LAUNCHPAD_ADDRESS=0x5Ce779D23D2e99D322004F203813389B6a426e3B
export HOOKR_UTILITY_V2_LAUNCHPAD_RUNTIME_CODEHASH=0x433411c5613df1dd265dfac168c7f78c4cfcbe87c7ae4ab669d1ff5340d09c71
```

Simulate without loading an account or broadcasting:

```bash
cd "$(git rev-parse --show-toplevel)/contracts"
forge script script/DeployHookrUtilitiesV2.s.sol:DeployHookrUtilitiesV2 \
  --rpc-url https://rpc.mainnet.chain.robinhood.com \
  --sender 0x5a52D4B820Ae7F02880d270562950918ACb14aA2
```

Review the exact predicted addresses, runtime sizes/hashes, promoted-core proof, and four boundary
timestamps. Only after separate user approval may the live command be run:

```bash
cd "$(git rev-parse --show-toplevel)/contracts"
forge script script/DeployHookrUtilitiesV2.s.sol:DeployHookrUtilitiesV2 \
  --rpc-url https://rpc.mainnet.chain.robinhood.com \
  --account nodar-deployer \
  --sender 0x5a52D4B820Ae7F02880d270562950918ACb14aA2 \
  --broadcast --slow
```

Archive:

```text
contracts/broadcast/DeployHookrUtilitiesV2.s.sol/4663/run-latest.json
```

It must contain exactly three hash-matched successful receipts in the order above. All values must
be zero. The CREATE addresses must match the deployer's consecutive nonces, and the linkage call
must emit exactly one `RewardSourceSet` naming the deployed V2 Boost.

After the receipts finalize, run the read-only deployment verifier:

```bash
cd "$(git rev-parse --show-toplevel)"
node scripts/verify-utility-v2-deployment-preflight.mjs \
  --deploy contracts/broadcast/DeployHookrUtilitiesV2.s.sol/4663/run-latest.json \
  --launchpad 0x5Ce779D23D2e99D322004F203813389B6a426e3B \
  --launchpad-codehash 0x433411c5613df1dd265dfac168c7f78c4cfcbe87c7ae4ab669d1ff5340d09c71 \
  --rpc https://rpc.mainnet.chain.robinhood.com
```

Do not start Stage 1 if this verifier is red or if fewer than 45 minutes remain in epoch zero.

## Canary environment

Use the receipt-derived addresses and independently reviewed live runtime hashes:

```bash
export HOOKR_UTILITY_V2_LOCK_REWARDS_ADDRESS=<receipt-derived-lock-rewards-v2>
export HOOKR_UTILITY_V2_LOCK_REWARDS_RUNTIME_CODEHASH=<reviewed-live-lock-rewards-v2-codehash>
export HOOKR_UTILITY_V2_LAUNCH_BOOST_ADDRESS=<receipt-derived-launch-boost-v2>
export HOOKR_UTILITY_V2_LAUNCH_BOOST_RUNTIME_CODEHASH=<reviewed-live-launch-boost-v2-codehash>
export HOOKR_UTILITY_V2_LAUNCHPAD_ADDRESS=0x5Ce779D23D2e99D322004F203813389B6a426e3B
export HOOKR_UTILITY_V2_LAUNCHPAD_RUNTIME_CODEHASH=0x433411c5613df1dd265dfac168c7f78c4cfcbe87c7ae4ab669d1ff5340d09c71
```

Read and record `bootstrapStartedAt`, `feeEpochStartsAt`, `claimEpochStartsAt`, and
`weeklyEpochsStartAt` directly from the deployed LockRewards contract. Do not calculate timing from
the second or third deployment receipt.

## Stage 1 — epoch-zero approval and lock

Simulate first:

```bash
cd "$(git rev-parse --show-toplevel)/contracts"
forge script script/CanaryHookrUtilitiesV2Lock.s.sol:CanaryHookrUtilitiesV2Lock \
  --rpc-url https://rpc.mainnet.chain.robinhood.com \
  --sender 0x5a52D4B820Ae7F02880d270562950918ACb14aA2
```

The simulation must prove epoch `0`, Boosting closed, one exact future activation at epoch `1`, no
prior deployer V2 position, zero prior LockRewards allowance, and at least 45 minutes remaining.
After separate user approval:

```bash
cd "$(git rev-parse --show-toplevel)/contracts"
forge script script/CanaryHookrUtilitiesV2Lock.s.sol:CanaryHookrUtilitiesV2Lock \
  --rpc-url https://rpc.mainnet.chain.robinhood.com \
  --account nodar-deployer \
  --sender 0x5a52D4B820Ae7F02880d270562950918ACb14aA2 \
  --broadcast --slow
```

Archive `contracts/broadcast/CanaryHookrUtilitiesV2Lock.s.sol/4663/run-latest.json`. It must contain
exactly the 1-HOOKR approval and lock receipts. The postcondition allowance is zero, custody and
principal increase by exactly 1 HOOKR, and the receipt position activates exactly at
`feeEpochStartsAt`.

## Stage 2 — epoch-one approval and fee-bearing Boost

Wait until `feeEpochStartsAt`, require Stage 1 finality, and independently confirm epoch `1`,
`boostingOpen() == true`, `boostedTokensCount() < MAX_ACTIVE_BOOSTS()`, and at least 45 minutes
remain before `claimEpochStartsAt`.

Simulate first:

```bash
cd "$(git rev-parse --show-toplevel)/contracts"
forge script script/CanaryHookrUtilitiesV2Boost.s.sol:CanaryHookrUtilitiesV2Boost \
  --rpc-url https://rpc.mainnet.chain.robinhood.com \
  --sender 0x5a52D4B820Ae7F02880d270562950918ACb14aA2
```

After separate user approval:

```bash
cd "$(git rev-parse --show-toplevel)/contracts"
forge script script/CanaryHookrUtilitiesV2Boost.s.sol:CanaryHookrUtilitiesV2Boost \
  --rpc-url https://rpc.mainnet.chain.robinhood.com \
  --account nodar-deployer \
  --sender 0x5a52D4B820Ae7F02880d270562950918ACb14aA2 \
  --broadcast --slow
```

Archive `contracts/broadcast/CanaryHookrUtilitiesV2Boost.s.sol/4663/run-latest.json`. It must contain
exactly the 100-HOOKR approval and Boost receipts. The Boost receipt must prove these exact local
deltas even when unrelated users exist:

```text
gross Boost             +100 HOOKR
refundable principal     +99 HOOKR
reward fee forwarded      +1 HOOKR
LockRewards reserve        +1 HOOKR
deployer Boost allowance    0 after execution
```

The script resolves the fixed canary through the promoted v4 launchpad and rejects a prior Boost,
fee waiver, noncanonical split, stale checkpoint, replay, partial prior approval, or a full registry.
It repeats the capacity read immediately before preparing the approval. Because approval and Boost
must remain two distinct receipts, another account can still fill the last slot between them. If
that happens, the Boost reverts and the 100-HOOKR allowance remains: preserve both artifacts, stop,
and do not rerun or promote this candidate. Any allowance revocation or replacement deployment is
a separately reviewed recovery transaction and is not part of the exact eight-receipt evidence.

## Stage 3 — bridge-epoch claim

Wait until `claimEpochStartsAt`, require Stage 2 finality, and independently confirm epoch `2` with
at least 45 minutes before `weeklyEpochsStartAt`.

Simulate first:

```bash
cd "$(git rev-parse --show-toplevel)/contracts"
forge script script/CanaryHookrUtilitiesV2Claim.s.sol:CanaryHookrUtilitiesV2Claim \
  --rpc-url https://rpc.mainnet.chain.robinhood.com \
  --sender 0x5a52D4B820Ae7F02880d270562950918ACb14aA2
```

After separate user approval:

```bash
cd "$(git rev-parse --show-toplevel)/contracts"
forge script script/CanaryHookrUtilitiesV2Claim.s.sol:CanaryHookrUtilitiesV2Claim \
  --rpc-url https://rpc.mainnet.chain.robinhood.com \
  --account nodar-deployer \
  --sender 0x5a52D4B820Ae7F02880d270562950918ACb14aA2 \
  --broadcast --slow
```

Archive `contracts/broadcast/CanaryHookrUtilitiesV2Claim.s.sol/4663/run-latest.json`. It must contain
exactly one claim receipt. The reward must be nonzero and must equal the receipt position's weight
times the pinned epoch-1-to-epoch-2 reward-index delta divided by `2^128`. Do not require an exact
1-HOOKR payout: unrelated eligible weight is allowed and changes the deployer's pro-rata share.

## Final evidence and promotion

Only after all eight receipts finalize, run the read-only complete verifier:

```bash
cd "$(git rev-parse --show-toplevel)"
node scripts/verify-utility-v2-canary-evidence.mjs \
  --deploy contracts/broadcast/DeployHookrUtilitiesV2.s.sol/4663/run-latest.json \
  --lock contracts/broadcast/CanaryHookrUtilitiesV2Lock.s.sol/4663/run-latest.json \
  --boost contracts/broadcast/CanaryHookrUtilitiesV2Boost.s.sol/4663/run-latest.json \
  --claim contracts/broadcast/CanaryHookrUtilitiesV2Claim.s.sol/4663/run-latest.json \
  --rpc https://rpc.mainnet.chain.robinhood.com
```

It must bind the four exact artifacts, source provenance, strict `3 + 2 + 2 + 1` receipt order,
canonical headers/finality, reviewed runtime templates and immutable values, promoted-v4 linkage,
bootstrap boundaries, receipt-local accounting deltas, position-scoped reward math, allowances,
custody, and solvency.

Promotion is a separate repository write and still needs explicit review:

```bash
cd "$(git rev-parse --show-toplevel)"
node scripts/promote-utility-v2-release-candidate.mjs \
  --deploy contracts/broadcast/DeployHookrUtilitiesV2.s.sol/4663/run-latest.json \
  --lock contracts/broadcast/CanaryHookrUtilitiesV2Lock.s.sol/4663/run-latest.json \
  --boost contracts/broadcast/CanaryHookrUtilitiesV2Boost.s.sol/4663/run-latest.json \
  --claim contracts/broadcast/CanaryHookrUtilitiesV2Claim.s.sol/4663/run-latest.json \
  --rpc https://rpc.mainnet.chain.robinhood.com
```

The promoter reruns the exact verifier and emits a deterministic candidate to stdout; it does not
install or write the application manifest. Review and archive that output before a separately
approved manifest change. Do not promote from a simulation, pending receipt, nonfinalized fork,
manually assembled JSON, or a canary that violated any 45-minute safety guard. Deployment, staged
canary, verified evidence, and promotion are four distinct release states.
