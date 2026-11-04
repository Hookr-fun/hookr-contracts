# Agent gate

`HookrAgentGate` is an advisory that makes a pool agents-only. A buy, a sell or a liquidity add on a pool bound to it goes through only for a wallet that holds an ERC-8004 agent identity, or is the registered agent wallet of an identity it linked here; removals are never gated. A pool can also freeze, at bind, a least reputation score from a reviewer it picks, and a fee tier that charges agents below a score an LP-fee surcharge. It is optional per pool and frozen once the pool is bound.

## What it does

- **Fail closed.** The gate is admitted on the registry as an ADVISORY and bound before the swap, so a swap or an add it refuses reverts. By default (`CHECK_BENEFICIARY`, a flag frozen at bind) a buyer's recipient must be an agent too. The pool's frozen arb recapture executor's legs pass on the root's word alone while the pool's lane is on.
- **The registries.** It reads the ERC-8004 Identity Registry `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` and Reputation Registry `0x8004BAa17C55a88189AE136b182e5fdA19dE9b63`. They are upgradeable proxies: the gate pins their runtime code and version at construction and refuses entries when either moves.
- **State.** Stateless on the swap path: every read is a static call. After bind nothing about a pool changes; the only writes are a wallet's own link, a reviewer set (content-addressed, immutable) and the owner's retire. Storage is keyed by the binder, so a bind by another root writes only its own namespace.
- **Owner.** Hookr's Safe `0x8Fdfaa25e2E4dDa297F301ea06458f22186D6bE9`, whose one power is to retire the gate for good.

## The contract

Deployed on 2026-10-31 in block 102,144,809 (00:26:08 UTC), by a plain CREATE from `0xC87AC3AD8d2270e9A66f8369f03B7CF197e7B72F` at its nonce 52, transaction `0x795f698d6c31cffed91017d6968c8a5ea8ddf3a83987d71000fec56d5b1011c4`. The registry owner `0x0c0967485A25F18E70262a2Ee80c7595CC64a5fC` queued its admission (nonce 457) and admitted it after the registry's delay (nonce 458).

| Contract | What it is | Address | Runtime keccak256 | Verified source |
| --- | --- | --- | --- | --- |
| `HookrAgentGate` | The Agent gate: a fail-closed advisory that makes a pool agents-only | [`0x3b1aC66a6Fd9e9d8F063d145003cf29eac4Fb0C9`](https://robin.etherscan.io/address/0x3b1aC66a6Fd9e9d8F063d145003cf29eac4Fb0C9#code) | `0x9aa76e84dabf5fbc568f620c5a0ea9817d55ea74a75cb43adfe58847a7db8d7c` | [exact match](https://repo.sourcify.dev/4663/0x3b1aC66a6Fd9e9d8F063d145003cf29eac4Fb0C9) |

Its constructor pins the Identity Registry, the Reputation Registry, the PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951` and the owner. The runtime keccak256 is the address's code hash read from the chain at block 105,937,713, the record's `checkedAtBlock`.

## Where the files are

| Folder | Holds |
| --- | --- |
| [`src/`](./src/) | The gate, its interface and the ERC-8004 reads it makes, 3 files |

The other 24 files of its build are already here: 9 under [`../src/`](../src/), the release's, which its build names `../hookr-phase-one/src/...`, and 15 in the pinned submodules in [`../../lib/`](../../lib/), named `../../../contracts/lib/...`. The record maps each source unit to its file; every file is byte-identical to the verified source on Sourcify.

## Building it

solc 0.8.37 (`0.8.37+commit.f401782d`), via-IR, the optimizer at 200 runs, EVM version prague, the IPFS metadata hash: the record's `hook-blocks` settings profile, which is the exact settings of its verified metadata.

```sh
node hookr-1/standard-input.mjs 0x3b1aC66a6Fd9e9d8F063d145003cf29eac4Fb0C9 > gate.json
solc-0.8.37 --standard-json gate.json > gate.out.json
cast code 0x3b1aC66a6Fd9e9d8F063d145003cf29eac4Fb0C9 > gate.hex   # with ETH_RPC_URL set to a chain 4663 node
node hookr-1/check-runtime.mjs 0x3b1aC66a6Fd9e9d8F063d145003cf29eac4Fb0C9 gate.out.json gate.hex
```

## Status

Deployed and admitted. No independent audit of the gate has been completed.
