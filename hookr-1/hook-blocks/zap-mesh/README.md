# Pool Mesh

One zap vault that feeds up to four Zap Relay targets on one quote. Source pools pay a frozen buy cut of up to 10% into the mesh, and anyone may call `zap()` to spend it on buys of the targets, one leg per target, split by weight or sent to the target furthest below its weight in quote depth. `HookrZapMeshAccrual` is the source pools' advisory and the only factory of meshes and their legs. It records every leg with its target, so the deployed [`HookrGatedRelay`](../zap-relay/README.md) admits a leg as a feeder of its target as it admits a zap vault. The contracts call it a zap mesh. The accrual creates its session lens and its mesh and leg deployers in its constructor.

Deployed with the HookrBook connectors on Robinhood Chain (chain id 4663) in transaction `0x2239e055f70178fa232ac2a2c2029c58bbaa88ba8bd34339d992915863d635e1`, block 86,244,980. `HookrZapMeshAccrual` is admitted on `HookrRoot` as an ADVISORY with the Zap Relay accrual's schema: registry operation `0x083f8459cedc3a00f7906e74ba29aef080808252251da26ce03d75b8d8c6f9d5`, queued at block 86,244,990 and executed at block 86,305,019.

| Contract | Address | Verified source | Note |
| --- | --- | --- | --- |
| `HookrZapMeshAccrual` | [`0x4ffFCC9bc83da95Ed1E04C8008a31ef2743C1d42`](https://robin.etherscan.io/address/0x4ffFCC9bc83da95Ed1E04C8008a31ef2743C1d42#code) | [Sourcify](https://repo.sourcify.dev/4663/0x4ffFCC9bc83da95Ed1E04C8008a31ef2743C1d42) |  |
| `ZapMeshDeployer` | [`0x3675C3647B3F8b7CAe2f4a3B08C5CCDf9d5c153e`](https://robin.etherscan.io/address/0x3675C3647B3F8b7CAe2f4a3B08C5CCDf9d5c153e#code) | [Sourcify](https://repo.sourcify.dev/4663/0x3675C3647B3F8b7CAe2f4a3B08C5CCDf9d5c153e) | created by `HookrZapMeshAccrual` |
| `ZapMeshLegDeployer` | [`0xE347ef34ad78b7f1008b1Fd22425f75eD44bCcad`](https://robin.etherscan.io/address/0xE347ef34ad78b7f1008b1Fd22425f75eD44bCcad#code) | [Sourcify](https://repo.sourcify.dev/4663/0xE347ef34ad78b7f1008b1Fd22425f75eD44bCcad) | created by `HookrZapMeshAccrual` |
| `ZapSessionLens` | [`0x0F48792eed1a8196644540E98E5b508A03cA977c`](https://robin.etherscan.io/address/0x0F48792eed1a8196644540E98E5b508A03cA977c#code) | [Sourcify](https://repo.sourcify.dev/4663/0x0F48792eed1a8196644540E98E5b508A03cA977c) | created by `HookrZapMeshAccrual` |

## Sources

This folder holds the mesh's own sources. The three connectors were built together from the Family Pinger's folder, so the verified metadata names the mesh's files `../zap-mesh/src/...`, the Zap Relay files it shares `../zap-relay/src/...` (the files in [`../zap-relay/src/`](../zap-relay/src/)), the release's files `../hookr-phase-one/src/...` (the files in [`../../src/`](../../src/)) and the dependencies `../../../contracts/lib/...` (the pinned submodules in [`lib/`](../../../lib/)). `ZapSessionLens` is the Zap Relay block's own source. [`deployments/robinhood-4663.json`](../../deployments/robinhood-4663.json) maps every source unit of every contract to its file in this repository.

Any contract above rebuilds byte for byte, metadata hash included, from its address; for the first one:

```sh
node hookr-1/standard-input.mjs 0x4ffFCC9bc83da95Ed1E04C8008a31ef2743C1d42 > input.json
solc-0.8.37 --standard-json input.json > output.json
```
