# Buy/Sell Block

An advisory that refuses a same-block round trip (buy then sell on the pool in one block) and buys or sells inside bounded launch windows, and charges nothing. It reads the round-trip record kept by a Rules variant, `HookrRulesRoundTrip`, which is deployed with its own recapture module and record module.

Deployed in production wave 1 on Robinhood Chain (chain id 4663).

| Contract | Address | Verified source | Note |
| --- | --- | --- | --- |
| `HookrBuySellBlock` | [`0xffefEA428C13813D4526fc77A8CA0df0c787626f`](https://robin.etherscan.io/address/0xffefEA428C13813D4526fc77A8CA0df0c787626f#code) | [Sourcify](https://repo.sourcify.dev/4663/0xffefEA428C13813D4526fc77A8CA0df0c787626f) |  |
| `HookrRecapture` | [`0xddFF6326E5CB9AA98b88e9064d9A9570f777f8A3`](https://robin.etherscan.io/address/0xddFF6326E5CB9AA98b88e9064d9A9570f777f8A3#code) | [Sourcify](https://repo.sourcify.dev/4663/0xddFF6326E5CB9AA98b88e9064d9A9570f777f8A3) | created by `HookrRulesRoundTrip` |
| `HookrRoundTripRecords` | [`0xb63B051Cf7C3FE6b03E4FcbA1e9D2130416d53c5`](https://robin.etherscan.io/address/0xb63B051Cf7C3FE6b03E4FcbA1e9D2130416d53c5#code) | [Sourcify](https://repo.sourcify.dev/4663/0xb63B051Cf7C3FE6b03E4FcbA1e9D2130416d53c5) | created by `HookrRulesRoundTrip` |
| `HookrRulesRoundTrip` | [`0x3d7e31746127FD9a14d3C7fC12E73611D2e8cb34`](https://robin.etherscan.io/address/0x3d7e31746127FD9a14d3C7fC12E73611D2e8cb34#code) | [Sourcify](https://repo.sourcify.dev/4663/0x3d7e31746127FD9a14d3C7fC12E73611D2e8cb34) |  |

## Sources

This folder holds the block's own sources. A file's path under this folder is its source unit name in the verified metadata. The sources a block shares with the release are the release's own files in [`../../src/`](../../src/), which the metadata names `../hookr-phase-one/src/...` or `src/...`, and the dependencies are the pinned submodules in [`lib/`](../../../lib/), named `../../../contracts/lib/...`. [`deployments/robinhood-4663.json`](../../deployments/robinhood-4663.json) maps every source unit of every contract to its file in this repository.

Any contract above rebuilds byte for byte, metadata hash included, from its address; for the first one:

```sh
node hookr-1/standard-input.mjs 0xffefEA428C13813D4526fc77A8CA0df0c787626f > input.json
solc-0.8.37 --standard-json input.json > output.json
```
