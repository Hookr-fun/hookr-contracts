# Best Route

Compares one exact-input trade on a Hookr pool with Uniswap v3 fee tiers, hookless v4 pools and one-hop paths through ETH or USDG, and offers the better route as one Universal Router call only when it beats the Hookr pool by a margin.

Deployed in production wave 1 on Robinhood Chain (chain id 4663).

| Contract | Address | Verified source | Note |
| --- | --- | --- | --- |
| `HookrBestRouteQuoter` | [`0xCCCCef0E1a9C8F35B7b80D0F44Ca5C302026A65B`](https://robin.etherscan.io/address/0xCCCCef0E1a9C8F35B7b80D0F44Ca5C302026A65B#code) | [Sourcify](https://repo.sourcify.dev/4663/0xCCCCef0E1a9C8F35B7b80D0F44Ca5C302026A65B) |  |

## Sources

This folder holds the block's own sources. A file's path under this folder is its source unit name in the verified metadata. The sources a block shares with the release are the release's own files in [`../../src/`](../../src/), which the metadata names `../hookr-phase-one/src/...`, and the dependencies are the pinned submodules in [`lib/`](../../../lib/), named `../../../contracts/lib/...`. [`deployments/robinhood-4663.json`](../../deployments/robinhood-4663.json) maps every source unit of every contract to its file in this repository.

Any contract above rebuilds byte for byte, metadata hash included, from its address; for the first one:

```sh
node hookr-1/standard-input.mjs 0xCCCCef0E1a9C8F35B7b80D0F44Ca5C302026A65B > input.json
solc-0.8.37 --standard-json input.json > output.json
```
