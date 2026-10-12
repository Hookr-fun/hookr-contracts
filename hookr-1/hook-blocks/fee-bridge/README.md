# Fee Bridge

Pays another pool's LPs. A bridge is named as a royalty payee or a tax recipient, or sent anything in its currency, and anyone may call `drip()` to donate a capped amount of what it holds to the in-range LPs of the destination pool fixed when it was made, for a tip of at most 1% of what it donates. `HookrFeeBridgeFactory` makes the bridges at CREATE2 addresses keyed by creator and salt. Every term of a bridge is immutable. A bridge is not a module of the hook, so it needs no registry admission, and the factory has none.

Deployed with the HookrBook connectors on Robinhood Chain (chain id 4663) in transaction `0x65db130e431c26c9ec0f94caea7a1d49a669d2bfd0df84cf5fcad4e0fef6b685`, block 86,244,983.

| Contract | Address | Verified source | Note |
| --- | --- | --- | --- |
| `HookrFeeBridgeFactory` | [`0x765cdea443C1688aE7467c2241E4a9a3e636990E`](https://robin.etherscan.io/address/0x765cdea443C1688aE7467c2241E4a9a3e636990E#code) | [Sourcify](https://repo.sourcify.dev/4663/0x765cdea443C1688aE7467c2241E4a9a3e636990E) |  |

## Sources

This folder holds the bridge's own sources. The three connectors were built together from the Family Pinger's folder, so the verified metadata names the bridge's files `../fee-bridge/src/...`, the release's files `../hookr-phase-one/src/...` (the files in [`../../src/`](../../src/)) and the dependencies `../../../contracts/lib/...` (the pinned submodules in [`lib/`](../../../lib/)). [`deployments/robinhood-4663.json`](../../deployments/robinhood-4663.json) maps every source unit of every contract to its file in this repository.

The contract above rebuilds byte for byte, metadata hash included, from its address:

```sh
node hookr-1/standard-input.mjs 0x765cdea443C1688aE7467c2241E4a9a3e636990E > input.json
solc-0.8.37 --standard-json input.json > output.json
```
