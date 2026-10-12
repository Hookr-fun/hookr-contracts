# Family Pinger

One contract per family that runs every action that is due in one call: a zap vault or Pool Mesh that is ready, a Fee Bridge drip or the liquidity record a later drip needs, and the payout of Hookr's set-aside share. When an action did real work, the pinger adds a tip from its own native budget. `HookrFamilyPingerFactory` makes the pingers at CREATE2 addresses keyed by creator and salt, and admits only vaults the Zap Relay accrual made, meshes the Pool Mesh accrual made and bridges the Fee Bridge factory made. A pinger is not a module of the hook, so it needs no registry admission, and the factory has none.

Deployed with the HookrBook connectors on Robinhood Chain (chain id 4663) in transaction `0xf05c56573a45f0d9dee263447c1bafe4dbc873cc1060625b28267e7dbfa3bcc0`, block 86,244,987. Its constructor names the Zap Relay accrual `0xA3d07234F6Ecb7012b8f46F277E9BaDae6e55bAD`, the [Pool Mesh](../zap-mesh/README.md) accrual and the [Fee Bridge](../fee-bridge/README.md) factory.

| Contract | Address | Verified source | Note |
| --- | --- | --- | --- |
| `HookrFamilyPingerFactory` | [`0x3C78cCFB5b5328896A834a5DB96CBaD9ED10EbD1`](https://robin.etherscan.io/address/0x3C78cCFB5b5328896A834a5DB96CBaD9ED10EbD1#code) | [Sourcify](https://repo.sourcify.dev/4663/0x3C78cCFB5b5328896A834a5DB96CBaD9ED10EbD1) |  |

## Sources

This folder holds the pinger's own sources. A file's path under this folder is its source unit name in the verified metadata. The connectors it calls sit beside it, so the metadata's `../zap-mesh/src/...`, `../fee-bridge/src/...` and `../zap-relay/src/...` are the files in [`../zap-mesh/src/`](../zap-mesh/src/), [`../fee-bridge/src/`](../fee-bridge/src/) and [`../zap-relay/src/`](../zap-relay/src/). The sources it shares with the release are the release's own files in [`../../src/`](../../src/), which the metadata names `../hookr-phase-one/src/...`, and the dependencies are the pinned submodules in [`lib/`](../../../lib/), named `../../../contracts/lib/...`. [`deployments/robinhood-4663.json`](../../deployments/robinhood-4663.json) maps every source unit of every contract to its file in this repository.

The contract above rebuilds byte for byte, metadata hash included, from its address:

```sh
node hookr-1/standard-input.mjs 0x3C78cCFB5b5328896A834a5DB96CBaD9ED10EbD1 > input.json
solc-0.8.37 --standard-json input.json > output.json
```
