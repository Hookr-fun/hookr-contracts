# Revenue Router

An ownerless CREATE2 factory and directory of revenue splits. A split's address depends only on its tag and payee list, so a creator can name it as the pool's royalty recipient before it exists.

Deployed in production wave 1 on Robinhood Chain (chain id 4663).

| Contract | Address | Verified source | Note |
| --- | --- | --- | --- |
| `HookrRevenueRouter` | [`0x065841021611e0B831b15e62a296C8E7C403A6e0`](https://robin.etherscan.io/address/0x065841021611e0B831b15e62a296C8E7C403A6e0#code) | [Sourcify](https://repo.sourcify.dev/4663/0x065841021611e0B831b15e62a296C8E7C403A6e0) |  |

## Sources

This folder holds the block's own sources. A file's path under this folder is its source unit name in the verified metadata. The sources a block shares with the release are the release's own files in [`../../src/`](../../src/), which the metadata names `../hookr-phase-one/src/...`, and the dependencies are the pinned submodules in [`lib/`](../../../lib/), named `../../../contracts/lib/...`. [`deployments/robinhood-4663.json`](../../deployments/robinhood-4663.json) maps every source unit of every contract to its file in this repository.

Any contract above rebuilds byte for byte, metadata hash included, from its address; for the first one:

```sh
node hookr-1/standard-input.mjs 0x065841021611e0B831b15e62a296C8E7C403A6e0 > input.json
solc-0.8.37 --standard-json input.json > output.json
```
