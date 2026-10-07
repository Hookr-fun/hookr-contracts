# Canonical Venue Token

A token that crosses the PoolManager only through one settlement contract, launched on one Hookr pool and then traded and given liquidity only on that pool. The settlement creates its launch module and token deployer in its constructor; the periphery sells the token's fee claims and serves read helpers.

Deployed in production wave 1 on Robinhood Chain (chain id 4663).

| Contract | Address | Verified source | Note |
| --- | --- | --- | --- |
| `CanonicalVenueLaunch` | [`0xd4b860d6FC296954Ce3b882bA54C515c22122e44`](https://robin.etherscan.io/address/0xd4b860d6FC296954Ce3b882bA54C515c22122e44#code) | [Sourcify](https://repo.sourcify.dev/4663/0xd4b860d6FC296954Ce3b882bA54C515c22122e44) | created by `CanonicalVenueSettlement` |
| `CanonicalVenuePeriphery` | [`0x7c57fc23dCaB13A0B75801669C3A48A5306039d2`](https://robin.etherscan.io/address/0x7c57fc23dCaB13A0B75801669C3A48A5306039d2#code) | [Sourcify](https://repo.sourcify.dev/4663/0x7c57fc23dCaB13A0B75801669C3A48A5306039d2) |  |
| `CanonicalVenueSettlement` | [`0xD1EFf2aad81b0fDE70Ff6E43697F86931e2622f7`](https://robin.etherscan.io/address/0xD1EFf2aad81b0fDE70Ff6E43697F86931e2622f7#code) | [Sourcify](https://repo.sourcify.dev/4663/0xD1EFf2aad81b0fDE70Ff6E43697F86931e2622f7) |  |
| `CanonicalVenueTokenDeployer` | [`0xB699c043aB0410E3C1aBC97998fbb28b4F32C3c5`](https://robin.etherscan.io/address/0xB699c043aB0410E3C1aBC97998fbb28b4F32C3c5#code) | [Sourcify](https://repo.sourcify.dev/4663/0xB699c043aB0410E3C1aBC97998fbb28b4F32C3c5) | created by `CanonicalVenueSettlement` |

## Sources

This folder holds the block's own sources. A file's path under this folder is its source unit name in the verified metadata. The sources a block shares with the release are the release's own files in [`../../src/`](../../src/), which the metadata names `../hookr-phase-one/src/...`, and the dependencies are the pinned submodules in [`lib/`](../../../lib/), named `../../../contracts/lib/...`. [`deployments/robinhood-4663.json`](../../deployments/robinhood-4663.json) maps every source unit of every contract to its file in this repository.

Any contract above rebuilds byte for byte, metadata hash included, from its address; for the first one:

```sh
node hookr-1/standard-input.mjs 0xd4b860d6FC296954Ce3b882bA54C515c22122e44 > input.json
solc-0.8.37 --standard-json input.json > output.json
```
