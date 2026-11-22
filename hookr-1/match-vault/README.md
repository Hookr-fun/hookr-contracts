# Match vault

`HookrMatchVault` at [`0x1Ea7141a4603139D84a02E1270130C63F889f9c0`](https://robin.etherscan.io/address/0x1Ea7141a4603139D84a02E1270130C63F889f9c0#code) matches an approved asset with HOOKR. A wallet brings only the asset to the one approved pool of that asset and HOOKR on `HookrRoot`; the vault adds, from its own balance, the HOOKR the pool's price asks for, and mints the full-range liquidity as two Uniswap v4 positions, the provider's and Hookr's. `HookrPriceLog` at [`0x28b6493639bCAd4A0DDd7A3d6fe961EDa29BF817`](https://robin.etherscan.io/address/0x28b6493639bCAd4A0DDd7A3d6fe961EDa29BF817#code) is the price log the vault checks a pool's price against.

## What the vault does

- **A match.** `deposit` takes the asset, adds the HOOKR and mints the two positions: the provider's, 60% of the liquidity by default, and Hookr's. The vault holds both until the match's unlock time, 21 days by default, and the provider collects the fees meanwhile (`collectFees`).
- **Custody.** The two PositionManager NFTs are held by the vault. No function decreases, burns, approves or re-points them. `withdraw`, by the match's owner from the unlock time, and `sweep`, by anyone from the unlock time, are the only calls that move one, each exactly once. Both are plain NFT transfers that touch no pool, so no Hook Block, pause, keeper or list change can stop an unlock.
- **Price.** The HOOKR added is what a full-range mint at the pool's own price pulls, so the two sides are equal in value at that price. A deposit is refused unless the price log's average over the pool's window is fresh, the pool's tick and the log's newest record are within the pool's band of that average, tick and average are inside the corridor the owner set, and the pool holds its least liquidity. These bound the price of the add against the average, not against any outside price.
- **Limits.** Counted in HOOKR on live matches: per wallet, per pool, in total and per UTC day. The vault's HOOKR balance is the budget: it never adds more than it holds, and it holds nothing of a provider's between transactions.
- **Settings.** Stored, bounded by the contract's constants, and they reach new matches only: a match keeps its unlock time, its split and its fee rule. `settings()` reads the ones in force.
- **Owner.** Hookr's Safe `0x8Fdfaa25e2E4dDa297F301ea06458f22186D6bE9`, behind the release's timelock base, `HookrGoverned`, with a 30-minute delay: it approves pools, sets the settings, lists the Rules whose pools may be approved and takes back tokens the vault holds outside any match. The owner or the registry's guardian pauses new matches; exits are never paused.

## What the price log does

`HookrPriceLog` is a shared price log for Uniswap v4 pools on one PoolManager, with no owner and no admin key. Anyone opens a log for a pool, anyone records into it, and any contract reads its time-weighted means.

- **A log** is a pool plus its frozen parameters; its id is the hash of both, and nothing about a log changes after it is opened.
- **A record** is the pool's spot tick, written at most once per interval, clamped to a set step from the previous record and refused while the PoolManager is unlocked.
- **A mean** is time-weighted over the records, and a record weighs nothing in a window that ends when it is written. A record taken while the pool's in-range liquidity is under the log's minimum is marked thin, and a mean that weighs a thin record fails closed.

## The contracts

Both are plain CREATEs from `0x0c0967485A25F18E70262a2Ee80c7595CC64a5fC`, deployed on 2026-11-16: the price log at its nonce 599 in block 115,621,102 (08:21:04 UTC), transaction `0x2da13e6899ff06bccaced86f9349f5f70016fa2ec6a5529971d5c3cc85e78dce`, and the vault at its nonce 600 in block 115,623,730 (08:25:46 UTC), transaction `0x38b6242f9ff0b2ffb162823e48ee66f2bdd7ec030d219f70fbd5103b2f88e17f`.

| Contract | What it is | Address | Runtime keccak256 | Verified source |
| --- | --- | --- | --- | --- |
| `HookrMatchVault` | Matches an approved asset with HOOKR and holds the match's two positions until its unlock time | [`0x1Ea7141a4603139D84a02E1270130C63F889f9c0`](https://robin.etherscan.io/address/0x1Ea7141a4603139D84a02E1270130C63F889f9c0#code) | `0x973f0cc76a65db492b62bc2f7e082a0418f5a23dde5214a9d96cd34d0f550c2d` | [exact match](https://repo.sourcify.dev/4663/0x1Ea7141a4603139D84a02E1270130C63F889f9c0) |
| `HookrPriceLog` | A shared price log for Uniswap v4 pools, with no owner | [`0x28b6493639bCAd4A0DDd7A3d6fe961EDa29BF817`](https://robin.etherscan.io/address/0x28b6493639bCAd4A0DDd7A3d6fe961EDa29BF817#code) | `0x34d3d6e5de5031f679633e62c9922e30a7e6483e9c417e9f7f1db23f0a1db130` | [exact match](https://repo.sourcify.dev/4663/0x28b6493639bCAd4A0DDd7A3d6fe961EDa29BF817) |

The vault's constructor takes Uniswap's PositionManager `0x58daec3116aae6D93017bAAea7749052E8a04fA7`, `HookrRoot` `0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc`, HOOKR `0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c`, the price log, the owner, the delay and the settings it starts with; the record has the arguments. The price log's constructor takes the PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951`. Each runtime keccak256 is the hash of the code at the address, 36,281 bytes for the vault and 6,020 for the price log, read from the chain at block 120,229,917.

## Where the files are

| Folder | Holds |
| --- | --- |
| [`src/`](./src/) | The vault, its interface, the price log's interface as the vault reads it and its math library, 4 files |
| [`price-log/src/`](./price-log/src/) | The price log, 1 file |

The other 47 files of the vault's build are already here: 8 under [`../src/`](../src/), the release's, which its build names `vendor/hookr-1/src/...`, and 39 in the pinned submodules in [`../../lib/`](../../lib/), named `../../../contracts/lib/...`. The price log's build names its one file `vendor/price-log/HookrPriceLog.sol`, and its other 26 files are in the pinned v4-core submodule. The record maps each source unit to its file; every file is byte-identical to the verified source on Sourcify.

## Building them

The vault: solc 0.8.37 (`0.8.37+commit.f401782d`), via-IR, the optimizer at 200 runs, EVM version prague, the IPFS metadata hash, the record's `match-vault` settings profile. The price log: solc 0.8.26 (`0.8.26+commit.8a97fa7a`), via-IR, the optimizer at 200 runs, EVM version cancun, the IPFS metadata hash, the record's `match-vault-price-log` settings profile; the record names the compiler on its entry. Each profile is the exact settings of the contract's verified metadata.

```sh
node hookr-1/standard-input.mjs 0x1Ea7141a4603139D84a02E1270130C63F889f9c0 > vault.json
solc-0.8.37 --standard-json vault.json > vault.out.json
cast code 0x1Ea7141a4603139D84a02E1270130C63F889f9c0 > vault.hex   # with ETH_RPC_URL set to a chain 4663 node
node hookr-1/check-runtime.mjs 0x1Ea7141a4603139D84a02E1270130C63F889f9c0 vault.out.json vault.hex

node hookr-1/standard-input.mjs 0x28b6493639bCAd4A0DDd7A3d6fe961EDa29BF817 > log.json
solc-0.8.26 --standard-json log.json > log.out.json
cast code 0x28b6493639bCAd4A0DDd7A3d6fe961EDa29BF817 > log.hex
node hookr-1/check-runtime.mjs 0x28b6493639bCAd4A0DDd7A3d6fe961EDa29BF817 log.out.json log.hex
```

## Status

Deployed. No independent audit of the vault or the price log has been completed.
