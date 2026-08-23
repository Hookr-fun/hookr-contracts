# Hookr v4 Robinhood broadcast evidence

This directory archives the exact production Foundry broadcast records used to promote Hookr
generation 4 on Robinhood Chain (chain ID 4663). Both artifacts name deployed-contract source
commit `df6835d51d5460d4e57fee81352b18be486cb5c5`.

| Record | Transactions / receipts | SHA-256 |
| --- | ---: | --- |
| `DeployRobinhood.s.sol/4663/run-latest.json` | 10 / 10 | `1ad518c0162c94058eb32407fbab86ba0b05d7bf17498f6862141f2d6decc399` |
| `CanaryRobinhood.s.sol/4663/run-latest.json` | 4 / 4 | `c4d81dd885034e6bce99e1c02a9e946647e23362efad00c498b095b69d0559fd` |

The deployment artifact records the reviewed library, launchpad, hook, router, immutable hook
wiring, and five house blueprints. The canary artifact records the fixed instant launch, guarded
buy, token approval, and bounded sell. All 14 receipts succeeded, were checked against live
calldata and canonical block headers, and were beneath finalized evidence before manifest
promotion. The promoter also authenticated runtime templates and immutables, all 12 launchpad
library link sites, blueprint calldata/events/readbacks, the canary token/pool/intent, hook effects,
custody, balances, and one hash-pinned safe-state snapshot that subsequently finalized.

`run-latest.json` files under `contracts/broadcast/` remain ignored working artifacts. These copies
are the immutable review records; verify them from this directory with
`shasum -a 256 -c SHA256SUMS.txt` before use. Dry-run and fork artifacts are intentionally not
archived here.
