# Credential Gate

A fail-closed advisory for gated pools: credential lists, sanctions, curated routers and restricted subjects, plus off-market session tiers, in one advisory slot.

Deployed in production wave 3 on Robinhood Chain (chain id 4663).

| Contract | Address | Verified source | Note |
| --- | --- | --- | --- |
| `HookrCredentialGate` | [`0x9fddb25D80B71022384AcCE128bD8B76E3206266`](https://robin.etherscan.io/address/0x9fddb25D80B71022384AcCE128bD8B76E3206266#code) | [Sourcify](https://repo.sourcify.dev/4663/0x9fddb25D80B71022384AcCE128bD8B76E3206266) |  |

## Sources

This folder holds the block's own sources. A file's path under this folder is its source unit name in the verified metadata. The sources a block shares with the release are the release's own files in [`../../src/`](../../src/), which the metadata names `../hookr-phase-one/src/...`, and the dependencies are the pinned submodules in [`lib/`](../../../lib/), named `../../../contracts/lib/...`. [`deployments/robinhood-4663.json`](../../deployments/robinhood-4663.json) maps every source unit of every contract to its file in this repository.

Any contract above rebuilds byte for byte, metadata hash included, from its address; for the first one:

```sh
node hookr-1/standard-input.mjs 0x9fddb25D80B71022384AcCE128bD8B76E3206266 > input.json
solc-0.8.37 --standard-json input.json > output.json
```
