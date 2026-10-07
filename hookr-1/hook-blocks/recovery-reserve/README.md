# Recovery Reserve

A small per-pool reserve, funded by a bounded slice of the pool's claims, that tops up LPs or traders after a verified incident, behind a 30-minute timelock, a reviewer attestation per claim and per-incident and per-pool caps.

Deployed in production wave 1 on Robinhood Chain (chain id 4663).

| Contract | Address | Verified source | Note |
| --- | --- | --- | --- |
| `HookrRecoveryReserve` | [`0xF5F802A1B39a90e6c0b15DeB9D6acE7070643250`](https://robin.etherscan.io/address/0xF5F802A1B39a90e6c0b15DeB9D6acE7070643250#code) | [Sourcify](https://repo.sourcify.dev/4663/0xF5F802A1B39a90e6c0b15DeB9D6acE7070643250) |  |

## Sources

This folder holds the block's own sources. A file's path under this folder is its source unit name in the verified metadata. The sources a block shares with the release are the release's own files in [`../../src/`](../../src/), which the metadata names `../hookr-phase-one/src/...`, and the dependencies are the pinned submodules in [`lib/`](../../../lib/), named `../../../contracts/lib/...`. [`deployments/robinhood-4663.json`](../../deployments/robinhood-4663.json) maps every source unit of every contract to its file in this repository.

Any contract above rebuilds byte for byte, metadata hash included, from its address; for the first one:

```sh
node hookr-1/standard-input.mjs 0xF5F802A1B39a90e6c0b15DeB9D6acE7070643250 > input.json
solc-0.8.37 --standard-json input.json > output.json
```
