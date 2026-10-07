# Vesting Milestone

Escrows a launch's vesting allocation. One factory at a fixed address; each escrow is a CREATE2 deploy from it, one per launch and salt.

Deployed in production wave 0 on Robinhood Chain (chain id 4663).

| Contract | Address | Verified source | Note |
| --- | --- | --- | --- |
| `HookrVestingMilestoneFactory` | [`0x964618850934Daa4f37CB5954BEdFb2bB86C5D26`](https://robin.etherscan.io/address/0x964618850934Daa4f37CB5954BEdFb2bB86C5D26#code) | [Sourcify](https://repo.sourcify.dev/4663/0x964618850934Daa4f37CB5954BEdFb2bB86C5D26) |  |

## Sources

This folder holds the block's own sources. A file's path under this folder is its source unit name in the verified metadata. The sources a block shares with the release are the release's own files in [`../../src/`](../../src/), which the metadata names `../hookr-phase-one/src/...`, and the dependencies are the pinned submodules in [`lib/`](../../../lib/), named `../../../contracts/lib/...`. [`deployments/robinhood-4663.json`](../../deployments/robinhood-4663.json) maps every source unit of every contract to its file in this repository.

Any contract above rebuilds byte for byte, metadata hash included, from its address; for the first one:

```sh
node hookr-1/standard-input.mjs 0x964618850934Daa4f37CB5954BEdFb2bB86C5D26 > input.json
solc-0.8.37 --standard-json input.json > output.json
```
