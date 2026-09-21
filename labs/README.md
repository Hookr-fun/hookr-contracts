# Labs

The place in this repository where code arrives by pull request. `src/` is a byte-pinned export of what is deployed and cannot change here; `labs/` is a separate Foundry project that compiles against the same pinned interfaces and the same v4-core, and CI builds and tests it on every pull request.

A merged pull request into `labs/` means one thing: the code was reviewed and is worth reading. It does not deploy anything, list anything on hookr.fun, or admit anything to the registry. Those are separate steps with their own evidence, described in [CONTRIBUTING.md](../CONTRIBUTING.md).

## Layout

| Path | What it is |
| --- | --- |
| [`templates/module/`](./templates/module) | A read-only policy module in the shape the catalog admits (`IHookrModuleV1`), with a config struct, admission-time validation and a Foundry test that pins its caps under the catalog's registration maxima |
| [`templates/full-hook/`](./templates/full-hook) | A standalone Uniswap v4 hook with mined flags, a swap counter and a dynamic-fee override, with a test that deploys a PoolManager from `lib/v4-core`, mines the address, opens a pool and swaps through it |
| [`hooks/<id>/`](./hooks) | Prototypes. One directory per idea, copied from a template, with a README that says what it does and what is unproven |

## Running

From the repository root, with the submodules initialized:

```sh
git submodule update --init --recursive
forge fmt --check --root labs
forge build --root labs
forge test --root labs -vv
```

`labs/foundry.toml` is the whole configuration. It resolves `hookr/` to the repository's `src/` (read-only: the export's own checks would reject any change there) and `@uniswap/v4-core/` and `forge-std/` to the root submodules, so a template imports `hookr/interfaces/IHookrModuleV1.sol` and `@uniswap/v4-core/src/PoolManager.sol` and nothing has to be vendored.

## Rules

- No secrets and no deployment configuration. `node check-review-boundary.mjs` at the repository root scans `labs/` too and refuses `vm.env*` readers, `[rpc_endpoints]` blocks, broadcast cheatcodes and key-shaped strings. A fork test reads its RPC from `--fork-url` on the command line.
- Solidity 0.8.26, via-IR, optimizer at 200 runs, `cancun`, as the release. A template's gas numbers should be comparable to the deployed code's.
- Every prototype carries a test. A pull request without one is a sketch, and a sketch belongs in a [hook idea](https://github.com/Hookr-fun/hookr-contracts/issues/new?template=hook-idea.yml) issue.
- Say what is unproven. A README that claims a property the tests do not show is the one thing a review will send back.

## What a module may request

The catalog fixes the structural maxima a module implementation may ever request when it is registered, and a sealed profile freezes which modules a pool may name. The current native block's registration is the reference point:

| Cap | Registered value |
| --- | --- |
| `maxLpFeeSurchargePips` | 500,000 (50%) |
| `maxSpecifiedQuoteTakeBps` | 4,000 (40%) |
| `maxUnspecifiedQuoteTakeBps` | 2,500 (25%) |
| `maxSubjectTakeBps` | 1,000 (10%) |
| `callbackGasLimit` | 2,000,000 |

A new module's registration would set its own values; the template's test asserts the template stays under these. Registration is permanent and the catalog's stateful lane (`STATEFUL_V1`, the one the native block uses) admits exactly one canonical module per catalog, so a contributed module is a read-only module (`IHookrModuleV1`, called by `STATICCALL`) unless a new catalog ships. See [HookrModuleCatalogV1](../docs/reference/HookrModuleCatalogV1.md) and [HookrStackRegistryV2](../docs/reference/HookrStackRegistryV2.md).
