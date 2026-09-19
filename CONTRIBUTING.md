# Contributing

This repository publishes each Hookr release: the sources behind the deployed contracts, the documentation, and the addresses. It is updated with every release and is the place to read, watch and cite.

## What lands here through a pull request

- Corrections and additions to `docs/`, `README.md` and `legacy/README.md`.
- Corrections to `deployments/robinhood-4663.v2.json` that a chain read backs up.

## What does not

`src/` is a byte-for-byte export of the sources the deployed bytecode was compiled from, pinned by `SOURCE_MANIFEST.json`, and the workflow on every pull request checks each file against that manifest and every contract's storage layout against `STORAGE_LAYOUT.json`. A change to `src/` here cannot pass that check, by design, and would describe code that is not on chain. New hook blocks and new hook profiles are built in Hookr's working repository and arrive here with the release that deploys them.

## Proposing a hook, a block or an integration

- To propose a third-party Uniswap v4 hook for review and listing, open an issue with the [external hook](https://github.com/Hookr-fun/hookr-contracts/issues/new?template=external-hook.yml) template, or submit it at [hookr.fun/integrate/hooks](https://hookr.fun/integrate/hooks).
- To integrate a launcher, an app or an agent, open an issue with the [partner integration](https://github.com/Hookr-fun/hookr-contracts/issues/new?template=partner-integration.yml) template. The [integrations guide](./docs/guides/integrating-as-a-launcher.md) and the [swapping and quoting guide](./docs/guides/swapping-and-quoting.md) cover the calls.
- To build a block or a profile with Hookr, say so in either issue; work happens in the working repository by invitation, and what ships is published here.

Issues are public. Put no private contact details, keys or unpublished addresses in them.
