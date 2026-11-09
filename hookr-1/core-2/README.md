# The core

The core is the Rules contract new pools on the shared hook, `HookrRoot` at [`0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc`](https://robin.etherscan.io/address/0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc#code), bind since 2026-11-01: a Rules contract with every Hook Block built in, as the [combined core](../combined-core/README.md) is, with new Hook Block code and a launcher whose tokens keep their holders' lots. The registry admits it on the shared hook beside the release's Rules and the combined core. Nothing deployed earlier changes: the release, the combined core and every pool on them run as before.

## What it does

- **The core.** `HookrRules` at `0x342bAA22e202954593b04B7eD1663621E0565d46` is the combined core's `HookrRules`, file for file and setting for setting, so its code is the combined core's outside its immutables. What differs is what it is pinned to: the binder, the Hook Block slot 1 and the recapture module below. It keeps the combined core's `HookrClaims` `0x8D0583b408e2959FA0450c54F749C1A4Dad3d335`, `HookrLimitBlocks` `0xc42E47679dd06DDcC07acc72ca710f6E60ACC3A9` (Hook Block slot 0) and the linked library `HookrViewSwap` `0x844faE4347517180bf4656b67E4BFc27D194693F`, which [`../combined-core/`](../combined-core/README.md) has.
- **Hook Blocks.** `HookrCoreBlocks` runs Swap Cut, Exit Clock, Holder Pot, Storm Fee and Sandwich Guard. Exit Clock prices a sell by the age of the seller's tokens, read from the token's lots (`lotsBefore`), on a `HookrToken` whose runtime code hash is the one `HookrHoldTokenCodeHash` pins; on any other token it uses per-holder records when the pool picked them at launch, or else the pool-wide rate for the pool's age. Sandwich Guard reprices a sale that carries the price past the window's opening. Holder Pot pays each closed UTC day's takings by the balance-time each wallet held, read from the token's meter (`IHookrTokenMeter`), with no keeper. The settle-time work of all three is in `HookrCoreSettle`, a linked library the Hook Block reaches by DELEGATECALL, which keeps the Hook Block under EIP-170.
- **Arb recapture.** `HookrRecapture` holds the arb recapture split and King of the Pool, and adds a least cashback a pool may credit the trader and the frozen integrator's slice of the protocol's cut (`RecaptureIntegratorSlice`).
- **Brake keys.** The core's constructor creates eight `HookrBlockKey` contracts by CREATE2, one per Hook Block, with the combined core's salts. The registry admits a Hook Block on the core under its key, so each block can be stopped for new pools on its own.
- **The launcher.** `HookrLauncher` launches the same funded families as the release's launcher, through its own `HookrTokenDeployer`, `HookrFamilyRouter` and `HookrFamilyLock`. Its `HookrToken` keeps each holder's tokens as a fresh lot and an aged bag (`lots`, `lotsBefore`), which Exit Clock reads, and meters every wallet's balance-time by UTC day, which Holder Pot reads. Its supply is at most `HookrTokenBounds.MAX_SUPPLY`, which the token and the launcher both enforce.

## The contracts

### The core

Deployed on 2026-11-01. The binder and the core are from blocks 103,412,316 and 103,412,338 (13:17:59 and 13:18:01 UTC), two transactions from `0x0c0967485A25F18E70262a2Ee80c7595CC64a5fC` (nonces 498 and 499) through the CREATE3 factory at `0xc7c662Fc760FE1d5cB97fd8A68cb43A046da3F7d`, release id `hookr-1`, with the contract's name as its role and salt counter 3. The other three are from blocks 103,300,199 to 103,300,204, nonces 461 to 463, salt counter 2. Twenty-four transactions after the core (nonces 500 to 523) queued and admitted it on the shared hook, its eight brake keys and the two swap modules under it, each behind the registry's delay, admitted it as a treasury source and wrote the `core` profile on the profile book. `HookrViewSwap`'s address is a library in the compiler settings of all five, and `HookrCoreSettle`'s in those of the last three.

| Contract | What it is | Address | Runtime keccak256 | Verified source |
| --- | --- | --- | --- | --- |
| `HookrRules` | The core: the Rules a pool on it names. Same sources, settings and code as the combined core's `HookrRules`, pinned to the binder, blocks and recapture below | [`0x342bAA22e202954593b04B7eD1663621E0565d46`](https://robin.etherscan.io/address/0x342bAA22e202954593b04B7eD1663621E0565d46#code) | `0xd9562958e6ecb3bfea31590b1d0201c281365b2becc1924ac4c5419e9cc1c32f` | [exact match](https://repo.sourcify.dev/4663/0x342bAA22e202954593b04B7eD1663621E0565d46) |
| `HookrBinder` | The core's `bind` and `blockCall`, run by DELEGATECALL in the core's storage, kept out of the core so the core fits EIP-170 | [`0x0B0f08c381ed6902FAb74b470fe7f8A58E8EA269`](https://robin.etherscan.io/address/0x0B0f08c381ed6902FAb74b470fe7f8A58E8EA269#code) | `0xd48b4c4fb93299f401452de225d70df49a903f4874bccb0b98f44f0951b1b5cb` | [exact match](https://repo.sourcify.dev/4663/0x0B0f08c381ed6902FAb74b470fe7f8A58E8EA269) |
| `HookrCoreBlocks` | Hook Block slot 1: Swap Cut, Exit Clock, Holder Pot, Storm Fee and Sandwich Guard | [`0xdA360B744F8C816acbb97fF65cC4Cd81e27Df375`](https://robin.etherscan.io/address/0xdA360B744F8C816acbb97fF65cC4Cd81e27Df375#code) | `0xbc34e16733f65147eae2f6d5247847c19327ed4d2d40b84549b79ce17e40c450` | [exact match](https://repo.sourcify.dev/4663/0xdA360B744F8C816acbb97fF65cC4Cd81e27Df375) |
| `HookrCoreSettle` | Linked library of `HookrCoreBlocks`, run by DELEGATECALL: Exit Clock's rebate at settle, Sandwich Guard's reprice and Holder Pot's days | [`0x7E169f0c49Db67F1a4f6f3c48A69B2e244b85191`](https://robin.etherscan.io/address/0x7E169f0c49Db67F1a4f6f3c48A69B2e244b85191#code) | `0xbe2ad2b3b0d41e3b46790925f4cceff5361cd8e0cec4f6951bc92f68f4b1834f` | [exact match](https://repo.sourcify.dev/4663/0x7E169f0c49Db67F1a4f6f3c48A69B2e244b85191) |
| `HookrRecapture` | The arb recapture split and King of the Pool, a module the core reaches by DELEGATECALL | [`0x97D440593912234b78432A030fb5186BD2A3Bc86`](https://robin.etherscan.io/address/0x97D440593912234b78432A030fb5186BD2A3Bc86#code) | `0x1f622db841d81a460cced260dc6cc89810ea0b20d5ecaeaa12e170ba4d110823` | [exact match](https://repo.sourcify.dev/4663/0x97D440593912234b78432A030fb5186BD2A3Bc86) |

The core's pins: the PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951`, the registry `0x463c82beA1a52F4Cc05ca0741a24F0AD24bA4602`, `HookrTreasury` `0x2242F7FC75606500503075f29ea8cDA684EfB4a9` as the protocol recipient, the shared hook, and `HookrRecapture`, `HookrClaims`, `HookrLimitBlocks`, `HookrCoreBlocks` and `HookrBinder` above by address and code hash. `HookrRecapture` is pinned to the PoolManager and the treasury, `HookrCoreBlocks` to the PoolManager.

The eight brake keys, each a `HookrBlockKey` created by the core in its constructor with salt `keccak256("hookr.rules.block.v1." ++ index)`. Each one's runtime is the 57 bytes of an empty contract, keccak256 `0x4ff3630dd3d4ca59d00c08a7c8be527f6b90ffd700a7cc6a36a837de2ee4565e`, which the build here gives, and each sits at the CREATE2 address that salt and the build's `HookrBlockKey` creation code give:

| Index | Hook Block | Address |
| --- | --- | --- |
| 0 | Swap Cut | [`0x9394881A6Fe570adEC4480471B4D52652d263878`](https://robin.etherscan.io/address/0x9394881A6Fe570adEC4480471B4D52652d263878#code) |
| 1 | Exit Clock | [`0x2b6aB976d05Dcc7Cad53bF9324Fe892511036348`](https://robin.etherscan.io/address/0x2b6aB976d05Dcc7Cad53bF9324Fe892511036348#code) |
| 2 | Holder Pot | [`0x740b2Da80eBB44613C2b44f380D55ECBECbFf11f`](https://robin.etherscan.io/address/0x740b2Da80eBB44613C2b44f380D55ECBECbFf11f#code) |
| 3 | Storm Fee | [`0xD577087cbf9bEC0Ca0392efD8A83C3fE6A09Bd1f`](https://robin.etherscan.io/address/0xD577087cbf9bEC0Ca0392efD8A83C3fE6A09Bd1f#code) |
| 4 | Wallet Cap | [`0xfe5c29D2d6B7aC383A63291a771197e4D83E1d9c`](https://robin.etherscan.io/address/0xfe5c29D2d6B7aC383A63291a771197e4D83E1d9c#code) |
| 5 | Buy and sell launch windows | [`0xa64be3B5eC9B7310CBd3F77736ca5D6Fa81C5BCb`](https://robin.etherscan.io/address/0xa64be3B5eC9B7310CBd3F77736ca5D6Fa81C5BCb#code) |
| 6 | Sandwich Guard | [`0xa214e747d1a8E767F88ed2170be62E22ED79a269`](https://robin.etherscan.io/address/0xa214e747d1a8E767F88ed2170be62E22ED79a269#code) |
| 7 | King of the Pool | [`0xD691021b7cbee6bFB1ACF73A3E1126603D1B26F9`](https://robin.etherscan.io/address/0xD691021b7cbee6bFB1ACF73A3E1126603D1B26F9#code) |

### The launcher

Deployed on 2026-11-01 in blocks 103,300,223 to 103,300,246, four transactions from the same account (nonces 466 to 469), the same way, salt counter 2. The registry set it as a launcher and admitted its family router as a gate, and the revenue tokenizer in [`../revenue-tokenizer-4/`](../revenue-tokenizer-4/README.md) launches through it. The Vesting Milestone and Pay Later factories built for it are in [`../hook-blocks/vesting-milestone/`](../hook-blocks/vesting-milestone/README.md) and [`../hook-blocks/pay-later/`](../hook-blocks/pay-later/README.md).

| Contract | What it is | Address | Runtime keccak256 | Verified source |
| --- | --- | --- | --- | --- |
| `HookrLauncher` | Funded launches of one to eight pools in one transaction, of tokens that keep their holders' lots | [`0x70a66ADF39B5c9FfEE4A9F081C182edfbb7DBD0C`](https://robin.etherscan.io/address/0x70a66ADF39B5c9FfEE4A9F081C182edfbb7DBD0C#code) | `0xf1a77b5576a56082679dc590f1a02dc4e834e91cc984e4996b8b08d0f11c1714` | [exact match](https://repo.sourcify.dev/4663/0x70a66ADF39B5c9FfEE4A9F081C182edfbb7DBD0C) |
| `HookrTokenDeployer` | Linked library of the launcher: creates the fixed-supply `HookrToken` it launches | [`0xE703F2Cd21A8dEE05dbC81b693201D602772B2d8`](https://robin.etherscan.io/address/0xE703F2Cd21A8dEE05dbC81b693201D602772B2d8#code) | `0xb54e618fb33b3fb0591e482cb878ef5d7fcc3758576f6b9840eeb6557fc063f8` | [exact match](https://repo.sourcify.dev/4663/0xE703F2Cd21A8dEE05dbC81b693201D602772B2d8) |
| `HookrFamilyRouter` | Splits one trade across a family's pools, every leg's minimum and the total checked, all legs or none | [`0xbc56F48f873841d26a5a02575263d82f68e12864`](https://robin.etherscan.io/address/0xbc56F48f873841d26a5a02575263d82f68e12864#code) | `0x9e5741dabd7ac598ea5f5cc618272189a27b09cdec02b9a5eed77dc95acf0eec` | [exact match](https://repo.sourcify.dev/4663/0xbc56F48f873841d26a5a02575263d82f68e12864) |
| `HookrFamilyLock` | Keeps a family's liquidity in its pools until an unlock block, or for good, while its beneficiary collects the fees | [`0x5248AF9139DaDEf0C5296342b7BE441deDf0adC2`](https://robin.etherscan.io/address/0x5248AF9139DaDEf0C5296342b7BE441deDf0adC2#code) | `0x488b7321770121eb0edc0f4b393f077d19eb6403416ab392713b0c29009a5dc1` | [exact match](https://repo.sourcify.dev/4663/0x5248AF9139DaDEf0C5296342b7BE441deDf0adC2) |

The pins: the launcher, the PoolManager and the registry, with `HookrLaunchChecks` `0x8567369a70100828611BB6F44ec051B48F10fb59` (the release's) and `HookrTokenDeployer` above as linked libraries; the family router, the release's `HookrRouter` `0xC2Bc9a3fe6c4Ce8C2F7EB4655b0869b01D8c93C9`, the launcher and Permit2 `0x000000000022D473030F116dDEE9F6B43aC78BA3`; the family lock, the launcher.

Each runtime keccak256 above is the address's code hash read from the chain at block 109,974,574, the record's `checkedAtBlock`.

### CREATE3 proxies

Each of the nine CREATE3 deployments leaves the factory's 8-byte proxy (`0x363d3d37363d34f0`) at its own address. The record lists each one as its contract's `deployment.proxy`.

## Where the files are

The contracts were built from two build trees, and each one's metadata names its files by their path in that tree. A file either tree shares byte for byte with a folder already here is not copied: the record maps that source unit to the existing file.

| Folder | Holds | Build tree names |
| --- | --- | --- |
| [`src/`](./src/) | The core tree's files that differ from the combined core's: the binder, the Hook Blocks, the recapture module, their settle library and checks, 13 files. The other 44 come from [`../combined-core/core/src/`](../combined-core/core/src/) | `src/...` |
| [`launcher/src/`](./launcher/src/) | The launcher tree's files that differ from the release's: the launcher, the family router, the token and their types, 8 files. The other 25 come from [`../src/`](../src/) and [`../combined-core/`](../combined-core/) | `src/...` |

The dependencies are the pinned submodules in [`../../lib/`](../../lib/), each byte-identical to the one the metadata records. The core tree names them `../../../../../contracts/lib/...`, the launcher tree `../../../../contracts/lib/...`. Every file is byte-identical to the verified source on Sourcify; each file's keccak256 is in the record's `sourceKeccak256`.

## Building it

Every contract here compiles with solc 0.8.37 (`0.8.37+commit.f401782d`), via-IR, the optimizer at 200 runs, EVM version prague, and the IPFS metadata hash. The record's settings profiles hold the exact settings of each, read from the verified metadata: `combined-core` for the core and the binder (with `HookrViewSwap` as a library), `core-2` for the Hook Blocks, the settle library and the recapture module (with `HookrViewSwap` and `HookrCoreSettle`), and `core-2-launcher` for the launcher tree.

```sh
node hookr-1/standard-input.mjs 0x342bAA22e202954593b04B7eD1663621E0565d46 > core.json
solc-0.8.37 --standard-json core.json > core.out.json
cast code 0x342bAA22e202954593b04B7eD1663621E0565d46 > core.hex   # with ETH_RPC_URL set to a chain 4663 node
node hookr-1/check-runtime.mjs 0x342bAA22e202954593b04B7eD1663621E0565d46 core.out.json core.hex
```

The same four lines with any other address in the tables check that contract; `node hookr-1/standard-input.mjs --list` names them under `core-2`. The brake keys' runtime is `evm.deployedBytecode` of `src/core/HookrBlockKey.sol:HookrBlockKey` in `core.out.json`.

## Verification

The nine contracts are exact matches on Sourcify: runtime and creation code, metadata hash included. Rebuilt from the files here, each one's runtime is the code at its address byte for byte, immutables aside, at block 109,974,574.

## Status

Deployed. The release's own `HookrRoot`, its Rules and the combined core are unchanged. No independent audit of the core or its launcher has been completed.
