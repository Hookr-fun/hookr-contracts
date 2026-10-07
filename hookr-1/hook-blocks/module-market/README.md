# Module Market

The bonded module marketplace: developers publish advisory modules with a frozen fee split, $HOOKR bonded in the vault stands behind each version, and the usage fee router splits each version's fees between developer, backers, protocol and reserve.

Deployed in production wave 1 on Robinhood Chain (chain id 4663).

| Contract | Address | Verified source | Note |
| --- | --- | --- | --- |
| `HookrBondVault` | [`0xeC09A4BfE1076D1cC928EC475D6C27188b9B1F90`](https://robin.etherscan.io/address/0xeC09A4BfE1076D1cC928EC475D6C27188b9B1F90#code) | [Sourcify](https://repo.sourcify.dev/4663/0xeC09A4BfE1076D1cC928EC475D6C27188b9B1F90) |  |
| `HookrModuleMarket` | [`0xbAcE47373D6FF5B017e08a3EcA5a93ec49680f15`](https://robin.etherscan.io/address/0xbAcE47373D6FF5B017e08a3EcA5a93ec49680f15#code) | [Sourcify](https://repo.sourcify.dev/4663/0xbAcE47373D6FF5B017e08a3EcA5a93ec49680f15) |  |
| `HookrUsageFeeRouter` | [`0xf98A8701325f2AB5cD92FAB3775615F98C70F3f1`](https://robin.etherscan.io/address/0xf98A8701325f2AB5cD92FAB3775615F98C70F3f1#code) | [Sourcify](https://repo.sourcify.dev/4663/0xf98A8701325f2AB5cD92FAB3775615F98C70F3f1) |  |

## Sources

This folder holds the block's own sources. A file's path under this folder is its source unit name in the verified metadata. The sources a block shares with the release are the release's own files in [`../../src/`](../../src/), which the metadata names `../hookr-phase-one/src/...`, and the dependencies are the pinned submodules in [`lib/`](../../../lib/), named `../../../contracts/lib/...`. [`deployments/robinhood-4663.json`](../../deployments/robinhood-4663.json) maps every source unit of every contract to its file in this repository.

Any contract above rebuilds byte for byte, metadata hash included, from its address; for the first one:

```sh
node hookr-1/standard-input.mjs 0xeC09A4BfE1076D1cC928EC475D6C27188b9B1F90 > input.json
solc-0.8.37 --standard-json input.json > output.json
```
