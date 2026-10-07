# Limit Orders

Escrowed exact-input limit orders that anyone can fill through the pinned Hookr router. No owner, admin, pause or upgrade.

Deployed in production wave 2 on Robinhood Chain (chain id 4663).

| Contract | Address | Verified source | Note |
| --- | --- | --- | --- |
| `HookrLimitOrders` | [`0x0c376cc30b1AC98b8ef80a4F516212D3B99402fA`](https://robin.etherscan.io/address/0x0c376cc30b1AC98b8ef80a4F516212D3B99402fA#code) | [Sourcify](https://repo.sourcify.dev/4663/0x0c376cc30b1AC98b8ef80a4F516212D3B99402fA) |  |

## Sources

This folder holds the block's own sources. A file's path under this folder is its source unit name in the verified metadata. The sources a block shares with the release are the release's own files in [`../../src/`](../../src/), which the metadata names `../hookr-phase-one/src/...`, and the dependencies are the pinned submodules in [`lib/`](../../../lib/), named `../../../contracts/lib/...`. [`deployments/robinhood-4663.json`](../../deployments/robinhood-4663.json) maps every source unit of every contract to its file in this repository.

Any contract above rebuilds byte for byte, metadata hash included, from its address; for the first one:

```sh
node hookr-1/standard-input.mjs 0x0c376cc30b1AC98b8ef80a4F516212D3B99402fA > input.json
solc-0.8.37 --standard-json input.json > output.json
```
