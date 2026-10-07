# Market Guard

An advisory that keeps a pool's price inside a band around an admitted external price feed: in REFUSE mode a swap that would leave the band is refused, in SURCHARGE mode it pays a surcharge priced from its simulated move beyond the band.

Deployed in production wave 1 on Robinhood Chain (chain id 4663).

| Contract | Address | Verified source | Note |
| --- | --- | --- | --- |
| `HookrMarketGuard` | [`0xFc5CAE364FDEE4347D97E2aEB82f3155068693A4`](https://robin.etherscan.io/address/0xFc5CAE364FDEE4347D97E2aEB82f3155068693A4#code) | [Sourcify](https://repo.sourcify.dev/4663/0xFc5CAE364FDEE4347D97E2aEB82f3155068693A4) |  |

## Sources

This folder holds the block's own sources. A file's path under this folder is its source unit name in the verified metadata. The sources a block shares with the release are the release's own files in [`../../src/`](../../src/), which the metadata names `../hookr-phase-one/src/...`, and the dependencies are the pinned submodules in [`lib/`](../../../lib/), named `../../../contracts/lib/...`. [`deployments/robinhood-4663.json`](../../deployments/robinhood-4663.json) maps every source unit of every contract to its file in this repository.

Any contract above rebuilds byte for byte, metadata hash included, from its address; for the first one:

```sh
node hookr-1/standard-input.mjs 0xFc5CAE364FDEE4347D97E2aEB82f3155068693A4 > input.json
solc-0.8.37 --standard-json input.json > output.json
```
