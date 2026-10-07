# Zap Relay

A buy cut of up to 10% on a source pool, credited to the pool's zap vault, and a gated relay on a target pool that accepts buys only from those vaults. The accrual creates its session lens and vault deployer in its constructor.

Deployed in production wave 3 on Robinhood Chain (chain id 4663).

| Contract | Address | Verified source | Note |
| --- | --- | --- | --- |
| `HookrGatedRelay` | [`0x59834ed88E72c59EB4fB0eF3cB0D95eCA98223E3`](https://robin.etherscan.io/address/0x59834ed88E72c59EB4fB0eF3cB0D95eCA98223E3#code) | [Sourcify](https://repo.sourcify.dev/4663/0x59834ed88E72c59EB4fB0eF3cB0D95eCA98223E3) |  |
| `HookrZapAccrual` | [`0xA3d07234F6Ecb7012b8f46F277E9BaDae6e55bAD`](https://robin.etherscan.io/address/0xA3d07234F6Ecb7012b8f46F277E9BaDae6e55bAD#code) | [Sourcify](https://repo.sourcify.dev/4663/0xA3d07234F6Ecb7012b8f46F277E9BaDae6e55bAD) |  |
| `ZapSessionLens` | [`0xA413F059741Fab1246F36E6eFb464A18F796205D`](https://robin.etherscan.io/address/0xA413F059741Fab1246F36E6eFb464A18F796205D#code) | [Sourcify](https://repo.sourcify.dev/4663/0xA413F059741Fab1246F36E6eFb464A18F796205D) | created by `HookrZapAccrual` |
| `ZapVaultDeployer` | [`0x02779BE78Dd6f59fdF5D7e57A0560ce38f52C779`](https://robin.etherscan.io/address/0x02779BE78Dd6f59fdF5D7e57A0560ce38f52C779#code) | [Sourcify](https://repo.sourcify.dev/4663/0x02779BE78Dd6f59fdF5D7e57A0560ce38f52C779) | created by `HookrZapAccrual` |

## Sources

This folder holds the block's own sources. A file's path under this folder is its source unit name in the verified metadata. The sources a block shares with the release are the release's own files in [`../../src/`](../../src/), which the metadata names `../hookr-phase-one/src/...`, and the dependencies are the pinned submodules in [`lib/`](../../../lib/), named `../../../contracts/lib/...`. [`deployments/robinhood-4663.json`](../../deployments/robinhood-4663.json) maps every source unit of every contract to its file in this repository.

Any contract above rebuilds byte for byte, metadata hash included, from its address; for the first one:

```sh
node hookr-1/standard-input.mjs 0x59834ed88E72c59EB4fB0eF3cB0D95eCA98223E3 > input.json
solc-0.8.37 --standard-json input.json > output.json
```
