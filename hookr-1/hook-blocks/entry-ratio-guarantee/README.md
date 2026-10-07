# Entry Ratio Guarantee

A standalone Uniswap v4 custody hook. LPs deposit through the vault the hook creates. At exit their accrued fees go to the pool's reserve, and an LP that asks for its entry ratio is paid back by the reserve for the currency its position lost, up to the pool's coverage caps, while the pool price is inside the band around an allowed price reference. The hook never sees swaps. The registrar allows references through Hookr's timelock; the two references are Uniswap v3 TWAPs.

Deployed in production wave 1 on Robinhood Chain (chain id 4663).

| Contract | Address | Verified source | Note |
| --- | --- | --- | --- |
| `EntryRatioGuaranteeHook` | [`0x3FcCD4321470Be51Fca58D9C34de735a78E98301`](https://robin.etherscan.io/address/0x3FcCD4321470Be51Fca58D9C34de735a78E98301#code) | [Sourcify](https://repo.sourcify.dev/4663/0x3FcCD4321470Be51Fca58D9C34de735a78E98301) |  |
| `EntryRatioRegistrar` | [`0xdD3586bedFA8defaD2184dc672E875ceEc897793`](https://robin.etherscan.io/address/0xdD3586bedFA8defaD2184dc672E875ceEc897793#code) | [Sourcify](https://repo.sourcify.dev/4663/0xdD3586bedFA8defaD2184dc672E875ceEc897793) |  |
| `EntryRatioVault` | [`0x158E101b1dBdbe4a5f9AdF833d5D439Aa0D29552`](https://robin.etherscan.io/address/0x158E101b1dBdbe4a5f9AdF833d5D439Aa0D29552#code) | [Sourcify](https://repo.sourcify.dev/4663/0x158E101b1dBdbe4a5f9AdF833d5D439Aa0D29552) | created by `EntryRatioGuaranteeHook` |
| `ErgV3TwapReference` | [`0x465b2d75487C37c152B7f6854912051c181F7857`](https://robin.etherscan.io/address/0x465b2d75487C37c152B7f6854912051c181F7857#code) | [Sourcify](https://repo.sourcify.dev/4663/0x465b2d75487C37c152B7f6854912051c181F7857) |  |
| `ErgV3TwapReference` | [`0xAD27BCe64538D4AB20C5e0Bc94EdCD0831a64883`](https://robin.etherscan.io/address/0xAD27BCe64538D4AB20C5e0Bc94EdCD0831a64883#code) | [Sourcify](https://repo.sourcify.dev/4663/0xAD27BCe64538D4AB20C5e0Bc94EdCD0831a64883) |  |

## Sources

This folder holds the block's own sources. A file's path under this folder is its source unit name in the verified metadata. The sources a block shares with the release are the release's own files in [`../../src/`](../../src/), which the metadata names `../hookr-phase-one/src/...`, and the dependencies are the pinned submodules in [`lib/`](../../../lib/), named `../../../contracts/lib/...`. [`deployments/robinhood-4663.json`](../../deployments/robinhood-4663.json) maps every source unit of every contract to its file in this repository.

Any contract above rebuilds byte for byte, metadata hash included, from its address; for the first one:

```sh
node hookr-1/standard-input.mjs 0x3FcCD4321470Be51Fca58D9C34de735a78E98301 > input.json
solc-0.8.37 --standard-json input.json > output.json
```
