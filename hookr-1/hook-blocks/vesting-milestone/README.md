# Vesting Milestone

Escrows a launch's vesting allocation. One factory at a fixed address; each escrow is a CREATE2 deploy from it, one per launch and salt.

Deployed on Robinhood Chain (chain id 4663). A factory takes only the pools of the launcher its constructor names: the first, from production wave 0, serves the release's `HookrLauncher` `0x1cf2748A6670572425eAbf9Ab9e5BC4eb2eB8Ef4`, and the second, deployed on 2026-11-06 (block 107,263,825) from the same creation code with salt counter 1, serves the core's `HookrLauncher` `0x70a66ADF39B5c9FfEE4A9F081C182edfbb7DBD0C`.

| Contract | Address | Verified source | Note |
| --- | --- | --- | --- |
| `HookrVestingMilestoneFactory` | [`0x964618850934Daa4f37CB5954BEdFb2bB86C5D26`](https://robin.etherscan.io/address/0x964618850934Daa4f37CB5954BEdFb2bB86C5D26#code) | [Sourcify](https://repo.sourcify.dev/4663/0x964618850934Daa4f37CB5954BEdFb2bB86C5D26) | for the release's launcher |
| `HookrVestingMilestoneFactory` | [`0xCBe4Fa6Ca5f14Ed30435524dc9629DC1719DbCB0`](https://robin.etherscan.io/address/0xCBe4Fa6Ca5f14Ed30435524dc9629DC1719DbCB0#code) | [Sourcify](https://repo.sourcify.dev/4663/0xCBe4Fa6Ca5f14Ed30435524dc9629DC1719DbCB0) | for the core's launcher |

## Sources

This folder holds the block's own sources. A file's path under this folder is its source unit name in the verified metadata. The sources a block shares with the release are the release's own files in [`../../src/`](../../src/), which the metadata names `../hookr-phase-one/src/...`, and the dependencies are the pinned submodules in [`lib/`](../../../lib/), named `../../../contracts/lib/...`. [`deployments/robinhood-4663.json`](../../deployments/robinhood-4663.json) maps every source unit of every contract to its file in this repository.

Any contract above rebuilds byte for byte, metadata hash included, from its address; for the first one:

```sh
node hookr-1/standard-input.mjs 0x964618850934Daa4f37CB5954BEdFb2bB86C5D26 > input.json
solc-0.8.37 --standard-json input.json > output.json
```
