# Contributing

This repository publishes each Hookr release: the sources behind the deployed contracts, the documentation, and the addresses. It is updated with every release and is the place to read, watch, cite and propose.

## The two roots

Every Hookr pool runs on one of two root hooks on Robinhood Chain, chain id 4663, and a proposal is easier to place once you know which one it touches.

- The default root, `HookrModularHookV6` at `0xb3cA29cF721380CEe8b8e4755F3865Ebc68Fe8cC`, admits the five native rules and nothing else. Its sealed profile names no correction executor.
- The recapture root, `HookrModularHookV6WthV5` at `0xb914f955294799de4b891bd2EA8AF628Fa1c68CC`, admits the same five rules plus one correction executor, `HookrWthExecutorAdapterV1`, which forwards to WTH's arbitrage executor on every swap of an ETH-quoted pool.

Both share the registry, the catalog, the coordinator, the accounting kernel, the native block, the router, the quoter and the forwarder. [Architecture](./docs/concepts/architecture.md) has the graph.

## Three kinds of proposal

**A rule.** The five rules live in one module, `HookrNativeMechanicsBlockV2`, and a sealed profile freezes its module set. A new rule is therefore a new native-block version: a new module registered in the catalog, and a new root profile sealed on the registry that names it, because `sealRootProfile` is one shot per kernel id and `moduleSetHash` never changes afterwards. That is a release, not a patch. Propose the rule with the [hook idea](https://github.com/Hookr-fun/hookr-contracts/issues/new?template=hook-idea.yml) template and prototype it in `labs/` if you want it read as code.

**A module.** A module is a separate contract the catalog registers: `registerModule` pins its implementation, its runtime code hash, its config-schema hash and the maxima it may ever request, permanently. A registered module only serves pools once a sealed profile names it, so a module ships with the next profile. The template in [`labs/templates/module`](./labs/templates/module) is the shape to start from; the [module submission](https://github.com/Hookr-fun/hookr-contracts/issues/new?template=module-submission.yml) template is where to bring it once it compiles and its tests pass.

**A full hook.** A hook of your own, with its own address, is not admitted to the registry at all. It is reviewed for listing alongside Hookr pools on hookr.fun. Start from [`labs/templates/full-hook`](./labs/templates/full-hook), and use the [external hook](https://github.com/Hookr-fun/hookr-contracts/issues/new?template=external-hook.yml) template when it is ready for that review.

## What lands here through a pull request

- Anything under `labs/`: a prototype under `labs/hooks/<id>/`, an improvement to a template, a test. The CI job builds and tests `labs/` as its own Foundry project. A merged pull request there means the code was reviewed and is worth reading; it does not deploy anything, list anything or admit anything to the registry.
- Corrections and additions to `docs/`, `README.md` and `legacy/README.md`.
- Corrections to `deployments/robinhood-4663.v2.json` that a chain read backs up.

## What does not

`src/` is a byte-for-byte export of the sources the deployed bytecode was compiled from, pinned by `SOURCE_MANIFEST.json`, and the workflow on every pull request checks each file against that manifest and every contract's storage layout against `STORAGE_LAYOUT.json`. A change to `src/` here cannot pass that check, by design, and would describe code that is not on chain. New native-block versions and new root profiles are built in Hookr's working repository and arrive here with the release that deploys them.

`labs/` code must not read secrets or carry deployment configuration: the boundary check refuses `vm.env*` readers, `[rpc_endpoints]` blocks and broadcast cheatcodes anywhere in the repository, `labs/` included. A fork test takes its RPC from `--fork-url` on the command line.

## Integrating

To integrate a launcher, an app or an agent, the [partner integration](https://github.com/Hookr-fun/hookr-contracts/issues/new?template=partner-integration.yml) template is the channel. The [integrations guide](./docs/guides/integrating-as-a-launcher.md) and the [swapping and quoting guide](./docs/guides/swapping-and-quoting.md) cover the calls, and the [`hookr-sdk`](https://www.npmjs.com/package/hookr-sdk) package on npm, version 0.2.0 at the time of writing, carries both roots' addresses and kernel ids, the frozen correction fields a recapture-root market needs, and the gas floor a correcting swap should be sent with.

## Where to talk

GitHub Discussions are disabled on this repository, so questions go in an issue and code goes in a pull request into `labs/`. Issues are public. Put no private contact details, keys or unpublished addresses in them.
