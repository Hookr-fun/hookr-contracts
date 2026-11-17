# Labs

The place in this repository where code arrives by pull request. `labs/` is a separate Foundry project, and CI builds and tests it on every pull request.

A merged pull request into `labs/` means one thing: the code was reviewed and is worth reading. It does not deploy anything, list anything on hookr.fun, or admit anything to the registry. Those are separate steps with their own evidence, described in [CONTRIBUTING.md](../CONTRIBUTING.md).

## Layout

| Path | What it is |
| --- | --- |
| [`templates/full-hook/`](./templates/full-hook) | A standalone Uniswap v4 hook with mined flags, a swap counter and a dynamic-fee override, with a test that deploys a PoolManager from `lib/v4-core`, mines the address, opens a pool and swaps through it |
| [`templates/module/`](./templates/module) | A read-only policy module (`IHookrModuleV1`) for the contracts in `src/`, which [PREVIOUS_RELEASES.md](../PREVIOUS_RELEASES.md#sources) describes, with a config struct, admission-time validation and a Foundry test that pins its caps |
| [`hooks/<id>/`](./hooks) | Prototypes. One directory per idea, copied from a template, with a README that says what it does and what is unproven |

An advisory for `HookrRoot` builds against `hookr-1/` with solc 0.8.37, so it is not built here: start from [`hookr-1/test/kit/TemplateAdvisory.sol`](../hookr-1/test/kit/TemplateAdvisory.sol), inherit [`AdvisoryConformance`](../hookr-1/test/kit/AdvisoryConformance.sol) in its test, and keep it in a repository of your own, as [CONTRIBUTING.md](../CONTRIBUTING.md#proposing-a-hook-block) explains.

## Running

From the repository root, with the submodules initialized:

```sh
git submodule update --init --recursive
forge fmt --check --root labs
forge build --root labs
forge test --root labs -vv
```

`labs/foundry.toml` is the whole configuration. It resolves `hookr/` to the repository's `src/`, read-only, and `@uniswap/v4-core/` and `forge-std/` to the root submodules, so a template imports `hookr/interfaces/IHookrModuleV1.sol` and `@uniswap/v4-core/src/PoolManager.sol` and nothing has to be vendored.

## Rules

- No secrets and no deployment configuration. `node check-review-boundary.mjs` at the repository root scans `labs/` too and refuses `vm.env*` readers, `[rpc_endpoints]` blocks, broadcast cheatcodes and key-shaped strings. A fork test reads its RPC from `--fork-url` on the command line.
- Solidity 0.8.26, via-IR, the optimizer at 200 runs and `cancun`, as `labs/foundry.toml` sets.
- Every prototype carries a test. A pull request without one is a sketch, and a sketch belongs in a [hook idea](https://github.com/Hookr-fun/hookr-contracts/issues/new?template=hook-idea.yml) issue.
- Say what is unproven. A README that claims a property the tests do not show is the one thing a review will send back.
