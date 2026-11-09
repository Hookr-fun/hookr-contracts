# Pay Later

Deploys one Pay Later vault per family and beneficiary at a deterministic address, and refuses terms outside its listing bounds. The vault deployer holds the vault's creation code for the factory.

Deployed on Robinhood Chain (chain id 4663). A factory takes only the pools of the launcher its constructor names: the first, from production wave 1, serves the release's `HookrLauncher` `0x1cf2748A6670572425eAbf9Ab9e5BC4eb2eB8Ef4`, and the second, deployed on 2026-11-06 (block 107,263,866) from the same creation code with salt counter 1, serves the core's `HookrLauncher` `0x70a66ADF39B5c9FfEE4A9F081C182edfbb7DBD0C`. Each factory creates its own vault deployer in its constructor.

| Contract | Address | Verified source | Note |
| --- | --- | --- | --- |
| `PayLaterFactory` | [`0x87dF80a261670186286B507b7E3648Fb18A0aF69`](https://robin.etherscan.io/address/0x87dF80a261670186286B507b7E3648Fb18A0aF69#code) | [Sourcify](https://repo.sourcify.dev/4663/0x87dF80a261670186286B507b7E3648Fb18A0aF69) | for the release's launcher |
| `PayLaterVaultDeployer` | [`0xcfD71F8525A5ac3C52675da142652F8d9055E14A`](https://robin.etherscan.io/address/0xcfD71F8525A5ac3C52675da142652F8d9055E14A#code) | [Sourcify](https://repo.sourcify.dev/4663/0xcfD71F8525A5ac3C52675da142652F8d9055E14A) | created by `PayLaterFactory` `0x87dF…aF69` |
| `PayLaterFactory` | [`0xFc3e9e435C79e1712CF949C6ea921fA165cadEf3`](https://robin.etherscan.io/address/0xFc3e9e435C79e1712CF949C6ea921fA165cadEf3#code) | [Sourcify](https://repo.sourcify.dev/4663/0xFc3e9e435C79e1712CF949C6ea921fA165cadEf3) | for the core's launcher |
| `PayLaterVaultDeployer` | [`0xd9129fDA63E427399f055f7DE0Af19A605BE89Fc`](https://robin.etherscan.io/address/0xd9129fDA63E427399f055f7DE0Af19A605BE89Fc#code) | [Sourcify](https://repo.sourcify.dev/4663/0xd9129fDA63E427399f055f7DE0Af19A605BE89Fc) | created by `PayLaterFactory` `0xFc3e…dEf3` |

## Sources

This folder holds the block's own sources. A file's path under this folder is its source unit name in the verified metadata. The sources a block shares with the release are the release's own files in [`../../src/`](../../src/), which the metadata names `../hookr-phase-one/src/...`, and the dependencies are the pinned submodules in [`lib/`](../../../lib/), named `../../../contracts/lib/...`. [`deployments/robinhood-4663.json`](../../deployments/robinhood-4663.json) maps every source unit of every contract to its file in this repository.

Any contract above rebuilds byte for byte, metadata hash included, from its address; for the first one:

```sh
node hookr-1/standard-input.mjs 0x87dF80a261670186286B507b7E3648Fb18A0aF69 > input.json
solc-0.8.37 --standard-json input.json > output.json
```
