# Hookr v2 Robinhood broadcast evidence

This directory is an immutable archive of historical Robinhood Chain (chain ID 4663) Foundry
broadcast records produced by the **v2** `DeployRobinhood` and `CanaryRobinhood` scripts. It was
moved out of `contracts/broadcast/` so Forge's script-name-based `run-latest.json` aliases cannot be
mistaken for evidence from the source-ready v3 candidate.

These records are not v3 release evidence. In particular, the archived canaries deploy and use
Uniswap's `PoolSwapTest`; they do not deploy or exercise the v3 `HookrSwapRouter`. The current v3
scripts also have different bytecode, wiring, code-hash checks, and transaction boundaries.

## Preserved records

| Record | Transactions / receipts | SHA-256 |
| --- | ---: | --- |
| `DeployRobinhood.s.sol/4663/run-1785625339670.json` | 8 / 8 | `7b0983e5c75dd0e02b48b7fca01f473b6392b84a3adf155acb4fda1e34376737` |
| `DeployRobinhood.s.sol/4663/run-1785632513843.json` | 8 / 8 | `37b68bbc6bbe47bc4c3374bed948e3b8ddc66adf7ce1f7fa1fc7c6fe5b6953d2` |
| `DeployRobinhood.s.sol/4663/run-latest.json` | 8 / 8 | `37b68bbc6bbe47bc4c3374bed948e3b8ddc66adf7ce1f7fa1fc7c6fe5b6953d2` |
| `CanaryRobinhood.s.sol/4663/run-1785625474457.json` | 6 / 6 | `a8065d15a84221601ffe5163a66af77468f1071ded2f60827a40b3fedcde337b` |
| `CanaryRobinhood.s.sol/4663/run-1785632680463.json` | 6 / 6 | `6aa130b5367e4a91da9d67e95981ae230a0952a13c49eb2399a80c81acf1e706` |
| `CanaryRobinhood.s.sol/4663/run-latest.json` | 6 / 6 | `6aa130b5367e4a91da9d67e95981ae230a0952a13c49eb2399a80c81acf1e706` |

Each `run-latest.json` is byte-for-byte identical to the corresponding newest timestamped record,
as reflected by the matching hash. The duplicate aliases are retained only to preserve the exact
historical evidence set.

Historical receipts prove that their listed transactions were broadcast and mined; they do not
prove the current source is deployed, authorize a new transaction, or satisfy the v3 release gate.
New v3 dry-run output remains ignored under `contracts/broadcast/*/*/dry-run/`. Any future evidence
must be copied into a versioned archive only after receipt status, runtime bytecode, source SHA,
addresses, and postconditions are independently verified.
