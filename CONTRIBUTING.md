# Contributing

This repository publishes verified sources, addresses and deployment records of Hookr's deployed contracts. Read, cite and build on them here; propose through an issue or a pull request.

## Proposing a Hook Block

`HookrRoot` is Hookr's shared hook. A pool on it binds a Rules contract, such as the core, and may bind one advisory beside it. A new idea fits one of three places.

- **An advisory.** A contract that implements [`IHookrAdvisory`](./hookr-1/src/interfaces/IHookrAdvisory.sol). It binds a pool's settings when the pool opens, and the hook asks it for bounded advice before and after each swap and before each liquidity addition, through static calls. The registry admits an advisory on `HookrRoot` at its exact code hash, behind a timelock, and a pool binds it at launch. Start from [`TemplateAdvisory.sol`](./hookr-1/test/kit/TemplateAdvisory.sol), the smallest advisory that passes the conformance suite, and inherit [`AdvisoryConformance.sol`](./hookr-1/test/kit/AdvisoryConformance.sol) in its test. It builds against `hookr-1/` with solc 0.8.37, so bring it from a repository of your own, at a pinned commit, with the [advisory submission](https://github.com/Hookr-fun/hookr-contracts/issues/new?template=module-submission.yml) template.
- **A Hook Block in the core.** A change to what `HookrRules` does arrives with a new core. Propose it with the [hook idea](https://github.com/Hookr-fun/hookr-contracts/issues/new?template=hook-idea.yml) template.
- **A hook of your own.** A standalone Uniswap v4 hook at its own address is reviewed for listing on hookr.fun, not admitted to the registry. Start from [`labs/templates/full-hook`](./labs/templates/full-hook) and use the [external hook](https://github.com/Hookr-fun/hookr-contracts/issues/new?template=external-hook.yml) template when it is ready for review. `HookrOwnedRootFactoryV2` deploys a hook of your own with the Hook Blocks built in, in one transaction.

## What lands here through a pull request

- Prototypes and templates under [`labs/`](./labs/README.md). CI builds and tests `labs/` as its own Foundry project. A merged pull request there means the code was reviewed and is worth reading; it deploys nothing, lists nothing and admits nothing.
- The gas bench in [`bench/`](./bench/README.md): a figure for a piece it does not measure yet, or a fix to one. `bench/gas-figures.json` is the output of `node bench/gas-figures.mjs`, never edited by hand.
- Fixes and additions to the README, this file, [PREVIOUS_RELEASES.md](./PREVIOUS_RELEASES.md) and the folder READMEs.
- Fixes to the deployment records that a chain read backs up.

## What does not

Sources. The contract sources under [`hookr-1/`](./hookr-1/README.md) are byte-identical to the verified sources of their contracts, and CI checks [`src/`](./src/) against [`SOURCE_MANIFEST.json`](./SOURCE_MANIFEST.json) and [`STORAGE_LAYOUT.json`](./STORAGE_LAYOUT.json) on every pull request. A changed source would describe code that is not on chain. New contracts arrive here after they are deployed and verified.

No secrets and no deployment configuration, anywhere. `node check-review-boundary.mjs` refuses `vm.env*` readers, `[rpc_endpoints]` blocks, broadcast cheatcodes and key-shaped strings, `labs/` included. A fork test takes its RPC from `--fork-url` on the command line. The gas bench forks through an rpc alias named `robinhood` that each reader defines in their own Foundry config ([`bench/README.md`](./bench/README.md)).

## Integrating

To integrate a launcher, an app or an agent, use the [partner integration](https://github.com/Hookr-fun/hookr-contracts/issues/new?template=partner-integration.yml) template. The [`hookr-sdk`](https://www.npmjs.com/package/hookr-sdk) package on npm builds launches, pool openings, quotes and swaps.

## Where to talk

Discussions are off on this repository, so questions go in an issue and code goes in a pull request. Issues are public: put no private contact details, keys or unpublished addresses in them.
