# Swap Reward Mint

An advisory that takes a fixed reward slice of each swap's quote leg (at most 5%) for a reward program, which the program's minter later turns into reward tokens. The factory deploys and attests the programs.

Deployed in production wave 3 on Robinhood Chain (chain id 4663).

| Contract | Address | Verified source | Note |
| --- | --- | --- | --- |
| `HookrSwapRewardAdvisory` | [`0x1e909Fc57419389F7964078287f8654C6415d68D`](https://robin.etherscan.io/address/0x1e909Fc57419389F7964078287f8654C6415d68D#code) | [Sourcify](https://repo.sourcify.dev/4663/0x1e909Fc57419389F7964078287f8654C6415d68D) |  |
| `HookrSwapRewardMinterFactory` | [`0xC80161AFDE6e9278360994D30761aB0b3B29B00D`](https://robin.etherscan.io/address/0xC80161AFDE6e9278360994D30761aB0b3B29B00D#code) | [Sourcify](https://repo.sourcify.dev/4663/0xC80161AFDE6e9278360994D30761aB0b3B29B00D) |  |

## Sources

This folder holds the block's own sources. A file's path under this folder is its source unit name in the verified metadata. The sources a block shares with the release are the release's own files in [`../../src/`](../../src/), which the metadata names `../hookr-phase-one/src/...`, and the dependencies are the pinned submodules in [`lib/`](../../../lib/), named `../../../contracts/lib/...`. [`deployments/robinhood-4663.json`](../../deployments/robinhood-4663.json) maps every source unit of every contract to its file in this repository.

Any contract above rebuilds byte for byte, metadata hash included, from its address; for the first one:

```sh
node hookr-1/standard-input.mjs 0x1e909Fc57419389F7964078287f8654C6415d68D > input.json
solc-0.8.37 --standard-json input.json > output.json
```
