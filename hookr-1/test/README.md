# Hookr 1 tests

These are the Hookr 1 release's own unit, fuzz and invariant tests. Here they build and run against the published sources in [`../src/`](../src/).

## Where they come from

They are the test tree of the Hookr 1 release package, the package the deployed contracts were built from. That package's `src/` is the same as [`../src/`](../src/), file for file: all 127 files match the keccak256 that [`../deployments/robinhood-4663.json`](../deployments/robinhood-4663.json) records for the verified sources. So these tests exercise the code that is on chain, up to the metadata hash (see "With Forge" in [`../README.md`](../README.md)).

What differs from the package:

- 13 test files and one helper differ only in comments. Those comments named files in Hookr's private working repository (docs, procedures, deploy tooling, the SDK, the app and the operator service). No code changed.
- Two test files are left out (see "Not included").
- [`../script/`](../script/) holds the three helpers the tests import from the package's `script/` folder: `HookrCreate3.sol` (the CREATE3 address book), `HookrLink.sol` (library link placeholders) and `HookrPairRootSalt.s.sol` (pair root salt mining). The tests use them on Forge's local chain only.
- [`../snapshots/`](../snapshots/) holds the benches' gas figures and code sizes, measured on this folder's build. 200 of the 217 figures equal the package's. The other 17 move because the metadata hash records source paths, and those paths differ from the package's build tree: five code hashes belong to contracts that carry another contract's code with its metadata, and twelve gas figures follow addresses that depend on creation code: new tokens' CREATE2 addresses and mined pair-root salts. Every code size is the same.

## What is covered

| Folder | What it tests |
| --- | --- |
| `core/` | `HookrRoot`, `HookrRules` and `HookrRegistry`: pool initialization and frozen terms, Anti-Snipe, dynamic fees, Auto Burn, LP Rewards, the minimum fee, claims, module admission and bonds, governance delays and brakes |
| `lane/` | Arb recapture and King of the Pool: the executor's legs and frames, the splits, the pot, gas floors, and attacks by hostile executors |
| `periphery/` | `HookrLauncher` (multi-pool launches, dev buys, exits), `HookrRouter`, `HookrQuoter`, `HookrFamilyRouter`, `HookrFamilyLock`, `HookrLpBoost` and the token deployer |
| `owned/` | The owned-root factory, owned profiles and the owned-roots lens |
| `factory/` | `HookrRootFactory` and pair roots |
| `engagement/` | Programs, referrals and milestone NFTs |
| `extensions/` | The fee and session advisories and `HookrLiquidityVault` |
| `gasless/` | `HookrForwarder` and `HookrPaymaster` (ERC-4337, EntryPoint v0.7) |
| `compliance/` | `HookrCompliance` and its guard |
| `libraries/`, `support/`, `base/` | `HookrDynamicFee`, `HookrRelease`, `HookrDelegation`, `HookrToken`, `HookrTreasury` and the governance base |
| `invariant/` | The whole-system invariant campaign and the LP Boost invariants |
| `kit/` | The conformance kit for advisories and the executor admission scan |
| `bench/` | Gas benches and code sizes |

Other invariant suites sit beside the unit tests they extend: accounting (`core/`), programs (`engagement/`), vault solvency (`extensions/`), owned roots (`owned/`), dev buys (`periphery/`) and the lane's (`lane/invariant/`).

## Running them

From `hookr-1/`, after `git submodule update --init --recursive` at the repository root:

```sh
forge build test/fixtures/PoolManagerArtifact.sol   # v4-core's PoolManager, built with solc 0.8.26
forge test                                          # unit, fuzz and invariant tests
FOUNDRY_PROFILE=lane forge test                     # arb recapture and King of the Pool
```

The tests deploy the PoolManager from its artifact in `out/`, so build it first. The default profile runs 2,091 tests and the lane profile 500. The lane profile runs every call as its own transaction, so transient storage resets between calls as it does on chain.

The via-IR build needs a large stack (`ulimit -s 65536`; 65520 on macOS). The full build takes about 20 minutes and more than 20 GB of memory, because one solc process compiles every test at once. CI runs one group of folders per job, with `--match-path`.

Fuzz and invariant depth:

- The default profile runs each fuzz test 256 times and each invariant campaign for 128 runs of 64 calls.
- `FOUNDRY_PROFILE=pr`, `ci` and `debug` fix the fuzz seed at `0x4444`, with 1,000, 5,000 and 100 runs.
- `test/invariant/run.sh deep` runs the system campaign at 512 runs of 256 calls; `run.sh lane` and `run.sh lane-deep` run the lane's.

Gas and code sizes. A plain `forge test` neither writes nor checks [`../snapshots/`](../snapshots/). To check them, run the benches isolated, so every measured call is a whole transaction:

```sh
FORGE_SNAPSHOT_CHECK=true forge test --isolate --match-path 'test/bench/*'
FORGE_SNAPSHOT_CHECK=true forge test --isolate --match-path test/factory/HookrPairRootGas.t.sol
FOUNDRY_PROFILE=lane FORGE_SNAPSHOT_CHECK=true forge test --match-path 'test/lane/bench/*'
```

Mutation gate. `test/invariant/mutations.sh` applies the one-edit mutants in `test/invariant/mutants.py` to the value-moving contracts, one at a time, and requires a test named for each to fail. It edits `src/` in place and restores it after every mutant, so run it on a clean checkout. `--check` confirms that every mutant still applies, without building; `--only <Contract>` and `--id <id>` select mutants. Use one worker: `--jobs` copies this folder, and the copies cannot reach `../lib`.

## Fork tests

The contracts named `*Fork*` and `QuoteLookAlikesTest` read Robinhood Chain (4663) at pinned blocks. They are left out of the runs above and of CI. To run them, define an rpc alias named `robinhood` in your own Foundry config, with the URL in an environment variable. This repository keeps no RPC table (see `CONTRIBUTING.md`).

```toml
# ~/.foundry/foundry.toml, on your machine only
[rpc_endpoints]
robinhood = "${ALCHEMY_RPC_URL}"
```

```sh
set -a; . /path/to/rpc.env; set +a   # a file outside the repository that sets ALCHEMY_RPC_URL
FOUNDRY_PROFILE=fork forge test
FOUNDRY_PROFILE=lane-fork forge test
```

The RPC must serve state at the blocks the tests pin, so use an archive node. Keep the URL off the command line, where process listings show it. Two tests of `HookrPaymasterErc7562ForkTest` need Forge's tracer and skip unless run with `-vvv`. `test_endToEndFromAnEthereumDeposit` also needs `ETH_POC_RPC`, an Ethereum mainnet RPC, and skips without it.

## Not included

- `test/script/RehearseCanaries.t.sol` and `test/script/RehearseClock.t.sol`. They test the fork rehearsal script, which is deployment tooling and reads its configuration from the environment. That script is not published here.
- The package's `qualification`, `sdk-parity` and `admission-parity` profiles. They check the deploy tooling and the SDK against the contracts, and need those tools.
- Tests for the whole-pot Rules in [`../king-of-the-pool-whole-pot/`](../king-of-the-pool-whole-pot/README.md) and the Hook Blocks in [`../hook-blocks/`](../hook-blocks/README.md). These tests cover `../src/` only.

## Finding ids

Test comments cite finding ids such as F-011, M-2 or I-12. They come from Hookr's own reviews of the release, not from an independent audit. No independent audit of Hookr 1 has been completed.
