# Pay Later

Deploys one Pay Later vault per family and beneficiary at a deterministic address, and refuses terms outside its listing bounds. The vault deployer holds the vault's creation code for the factory.

Deployed in production wave 1 on Robinhood Chain (chain id 4663).

| Contract | Address | Verified source | Note |
| --- | --- | --- | --- |
| `PayLaterFactory` | [`0x87dF80a261670186286B507b7E3648Fb18A0aF69`](https://robin.etherscan.io/address/0x87dF80a261670186286B507b7E3648Fb18A0aF69#code) | [Sourcify](https://repo.sourcify.dev/4663/0x87dF80a261670186286B507b7E3648Fb18A0aF69) |  |
| `PayLaterVaultDeployer` | [`0xcfD71F8525A5ac3C52675da142652F8d9055E14A`](https://robin.etherscan.io/address/0xcfD71F8525A5ac3C52675da142652F8d9055E14A#code) | [Sourcify](https://repo.sourcify.dev/4663/0xcfD71F8525A5ac3C52675da142652F8d9055E14A) | created by `PayLaterFactory` |

## Sources

This folder holds the block's own sources. A file's path under this folder is its source unit name in the verified metadata. The sources a block shares with the release are the release's own files in [`../../src/`](../../src/), which the metadata names `../hookr-phase-one/src/...`, and the dependencies are the pinned submodules in [`lib/`](../../../lib/), named `../../../contracts/lib/...`. [`deployments/robinhood-4663.json`](../../deployments/robinhood-4663.json) maps every source unit of every contract to its file in this repository.

Any contract above rebuilds byte for byte, metadata hash included, from its address; for the first one:

```sh
node hookr-1/standard-input.mjs 0x87dF80a261670186286B507b7E3648Fb18A0aF69 > input.json
solc-0.8.37 --standard-json input.json > output.json
```
