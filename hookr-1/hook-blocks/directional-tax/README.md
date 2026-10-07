# Directional Tax

Separate buy and sell taxes, each at most 10%, taken in the quote and credited to a claim queue per pool and direction that converts later, off the trade path. Conversions run only on routes registered through a timelock, signed through a paused-by-default signer and executed through the v4 exact-input adapter; the claim redeemer turns ERC-6909 claims back into tokens for holders that cannot unlock the PoolManager.

Deployed in production wave 3 on Robinhood Chain (chain id 4663).

| Contract | Address | Verified source | Note |
| --- | --- | --- | --- |
| `HookrClaimRedeemer` | [`0x79B3A3C610c3F5E0926F2b2a08Aa4c7b00776De4`](https://robin.etherscan.io/address/0x79B3A3C610c3F5E0926F2b2a08Aa4c7b00776De4#code) | [Sourcify](https://repo.sourcify.dev/4663/0x79B3A3C610c3F5E0926F2b2a08Aa4c7b00776De4) |  |
| `HookrDirectionalTax` | [`0xE73fAD0d773b9571a7a9d2A1edc01132fF5f1e1F`](https://robin.etherscan.io/address/0xE73fAD0d773b9571a7a9d2A1edc01132fF5f1e1F#code) | [Sourcify](https://repo.sourcify.dev/4663/0xE73fAD0d773b9571a7a9d2A1edc01132fF5f1e1F) |  |
| `HookrFeeRouteAuthorizer` | [`0x05B0A56432c7692326eF2EcC41997B0fb3d33020`](https://robin.etherscan.io/address/0x05B0A56432c7692326eF2EcC41997B0fb3d33020#code) | [Sourcify](https://repo.sourcify.dev/4663/0x05B0A56432c7692326eF2EcC41997B0fb3d33020) |  |
| `HookrFeeRouteRegistry` | [`0xC9B5Ded0c6f1eeFFf2a41607d6EE4e71be88763A`](https://robin.etherscan.io/address/0xC9B5Ded0c6f1eeFFf2a41607d6EE4e71be88763A#code) | [Sourcify](https://repo.sourcify.dev/4663/0xC9B5Ded0c6f1eeFFf2a41607d6EE4e71be88763A) |  |
| `HookrFeeSwapExecutor` | [`0x0Eb5076E91803194281Dcfd94aDF453d5D1575B0`](https://robin.etherscan.io/address/0x0Eb5076E91803194281Dcfd94aDF453d5D1575B0#code) | [Sourcify](https://repo.sourcify.dev/4663/0x0Eb5076E91803194281Dcfd94aDF453d5D1575B0) |  |
| `HookrTaxQueue` | [`0x2C2Fd39520165e5Ee5a9DD69297fe0BE02F29619`](https://robin.etherscan.io/address/0x2C2Fd39520165e5Ee5a9DD69297fe0BE02F29619#code) | [Sourcify](https://repo.sourcify.dev/4663/0x2C2Fd39520165e5Ee5a9DD69297fe0BE02F29619) | created by `HookrDirectionalTax` |
| `HookrV4ExactInputAdapter` | [`0x7AeD9F3Ca84e36f66814734aED557F3FC914eb48`](https://robin.etherscan.io/address/0x7AeD9F3Ca84e36f66814734aED557F3FC914eb48#code) | [Sourcify](https://repo.sourcify.dev/4663/0x7AeD9F3Ca84e36f66814734aED557F3FC914eb48) |  |

## Sources

This folder holds the block's own sources. A file's path under this folder is its source unit name in the verified metadata. The sources a block shares with the release are the release's own files in [`../../src/`](../../src/), which the metadata names `../hookr-phase-one/src/...`, and the dependencies are the pinned submodules in [`lib/`](../../../lib/), named `../../../contracts/lib/...`. [`deployments/robinhood-4663.json`](../../deployments/robinhood-4663.json) maps every source unit of every contract to its file in this repository.

Any contract above rebuilds byte for byte, metadata hash included, from its address; for the first one:

```sh
node hookr-1/standard-input.mjs 0x79B3A3C610c3F5E0926F2b2a08Aa4c7b00776De4 > input.json
solc-0.8.37 --standard-json input.json > output.json
```
