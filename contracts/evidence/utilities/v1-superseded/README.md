# Superseded HOOKR utility V1 evidence

This directory preserves the exact finalized production artifacts for the first HOOKR utility V1
deployment on Robinhood Chain (chain ID 4663). It is historical evidence, not a production utility
release: the weekly epoch design could not complete its fee-bearing Boost and reward-claim canary
on deployment day, and no application manifest was promoted from these partial stages.

Both artifacts bind clean canonical-main source commit
`a732d1340ba78281fe65c15525b3eae6dbb5b91a`.

| Record | Transactions / receipts | SHA-256 |
| --- | ---: | --- |
| `DeployHookrUtilities.s.sol/4663/run-1786439640996.json` | 3 / 3 | `e0630aa1ad7c060f88ef2b15b3319eac5b3d177697a3eeae81541cbc3fdc1196` |
| `CanaryHookrUtilitiesLock.s.sol/4663/run-1786441029803.json` | 2 / 2 | `115a964a8ae9268e5e744c2469aeac4fb740186628c3d635641469c31637036f` |

The deployment created Lock Rewards at `0x62e282555F43cba2Fec5A36c6fF821421dd06878`,
Launch Boost at `0x66a2a336f3740a22B8431e1F590a406aB89dD54c`, and permanently linked the
Boost contract as the reward source. The completed Stage 1 canary approved and locked exactly
`1 HOOKR` in Lock Rewards position `1`. That principal remains non-slashable and withdrawable by
its owner after `2026-09-10T09:37:07Z`; supersession does not modify its custody or withdrawal
rights.

All five archived receipts succeeded and finalized. The deployment preflight authenticated both
reviewed runtimes, constructor immutables, the one-shot reward-source link, promoted Hookr v4 core,
policy, custody, and solvency. The Stage 1 receipts additionally prove the exact approval, transfer,
position fields, zero residual allowance, and `1 HOOKR` principal backing. No fee-bearing Boost or
reward claim occurred on this deployment, so these files must never be relabelled as complete
`3 + 2 + 2 + 1` utility release evidence.

Verify the archived originals from this directory with
`shasum -a 256 -c SHA256SUMS.txt` before use. The incomplete zero-receipt lock artifact is
intentionally excluded.
