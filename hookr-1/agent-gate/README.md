# Agent gate

`HookrAgentGate` at [`0xF95e6c8eEdA88b4D8Dfd43A087D153059A5107b0`](https://robin.etherscan.io/address/0xF95e6c8eEdA88b4D8Dfd43A087D153059A5107b0#code) is an advisory that makes a pool agents-only. A buy, a sell or a liquidity add on a pool bound to it goes through only for a wallet that holds an ERC-8004 agent identity, or is the registered agent wallet or owner of an identity it linked here; removals are never gated. At bind, a pool can also freeze a minimum reputation score from a reviewer it picks, a fee tier that charges an LP-fee surcharge to agents below a score, and a minimum age of the wallet's link. It is optional per pool and frozen once the pool is bound.

## What it does

- **Fail closed.** The gate is admitted on the registry as an ADVISORY and bound before the swap, so a swap or an add it refuses reverts. By default (`CHECK_BENEFICIARY`, a flag frozen at bind) a buyer's recipient must be an agent too. Legs traded by the pool's frozen arb recapture executor pass on the root's word alone while the pool's lane is on.
- **Adds through Uniswap's PositionManager.** An add through the PositionManager is screened on the wallet the PositionManager names through `msgSender()`, never on the PositionManager itself. The gate pins the PositionManager by address and code at construction.
- **Contract wallets.** A wallet with ordinary runtime code is an agent only through a link it made itself, proved with its own ERC-1271 signature over the gate's link digest (`linkWithProof`). A wallet without code, or an EIP-7702 delegated one, passes by its balance and links without a proof (`link`).
- **The creator.** The launch's family owner is screened at bind: a launch a non-agent would own reverts with `InvalidPoolConfig(11)`, a revenue token's stream launch included.
- **Link age.** `Terms.minAge`, at most 30 days, is the minimum time since the wallet first linked its identity here.
- **The registries.** It reads the ERC-8004 Identity Registry `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` and Reputation Registry `0x8004BAa17C55a88189AE136b182e5fdA19dE9b63`. They are upgradeable proxies: the gate pins their code and version, and while either differs from its pin, entries are refused and sells stay open. The owner can re-pin after a reviewed upgrade, 30 minutes after queueing it (`queueRepin`, `repin`).
- **State.** Stateless on the swap path: every read is a static call. After bind nothing about a pool changes; the only writes are a wallet's own link, a reviewer set (content-addressed, immutable) and the owner's suspend, resume and re-pin. Storage is keyed by the binder, so a bind by another root writes only its own namespace.
- **Owner.** Hookr's Safe `0x8Fdfaa25e2E4dDa297F301ea06458f22186D6bE9`, which can suspend and resume the gate and re-pin the registries. There is no one-way retire.

## The contract

Deployed on 2026-11-06 in block 107,220,906 (02:11:41 UTC), by a plain CREATE from `0xC87AC3AD8d2270e9A66f8369f03B7CF197e7B72F` at its nonce 53, transaction `0x25babdf59e8c2bcf6a287823ac7d929ec18262b24e94f8826f1d18cdae1b12c0`. The registry owner `0x0c0967485A25F18E70262a2Ee80c7595CC64a5fC` queued its admission (nonce 545, block 107,227,050) and admitted it after the registry's delay (nonce 546, block 107,250,878).

| Contract | What it is | Address | Runtime keccak256 | Verified source |
| --- | --- | --- | --- | --- |
| `HookrAgentGate` | The Agent gate: a fail-closed advisory that makes a pool agents-only | [`0xF95e6c8eEdA88b4D8Dfd43A087D153059A5107b0`](https://robin.etherscan.io/address/0xF95e6c8eEdA88b4D8Dfd43A087D153059A5107b0#code) | `0xbcbb8b8aa24efd5c532e56ba2dad28fa3b28371d074285e5960f7c2601cb87cc` | [exact match](https://repo.sourcify.dev/4663/0xF95e6c8eEdA88b4D8Dfd43A087D153059A5107b0) |

Its constructor pins the Identity Registry, the Reputation Registry, the PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951`, Uniswap's PositionManager `0x58daec3116aae6D93017bAAea7749052E8a04fA7` and the owner. The runtime keccak256 is the address's code hash read from the chain at block 109,974,574, the record's `checkedAtBlock`.

## Where the files are

| Folder | Holds |
| --- | --- |
| [`src/`](./src/) | The gate, its interface and the ERC-8004, ERC-1271 and PositionManager reads it makes, 5 files |

The other 24 files of its build are already here: 9 under [`../src/`](../src/), the release's, which its build names `lib/hookr-phase-one/src/...`, and 15 in the pinned submodules in [`../../lib/`](../../lib/), named `../../../contracts/lib/...`. The record maps each source unit to its file; every file is byte-identical to the verified source on Sourcify.

## Building it

solc 0.8.37 (`0.8.37+commit.f401782d`), via-IR, the optimizer at 200 runs, EVM version prague, the IPFS metadata hash: the record's `agent-gate` settings profile, which is the exact settings of its verified metadata.

```sh
node hookr-1/standard-input.mjs 0xF95e6c8eEdA88b4D8Dfd43A087D153059A5107b0 > gate.json
solc-0.8.37 --standard-json gate.json > gate.out.json
cast code 0xF95e6c8eEdA88b4D8Dfd43A087D153059A5107b0 > gate.hex   # with ETH_RPC_URL set to a chain 4663 node
node hookr-1/check-runtime.mjs 0xF95e6c8eEdA88b4D8Dfd43A087D153059A5107b0 gate.out.json gate.hex
```

## Status

Deployed and admitted. New pools that turn the Agent gate on bind it. No independent audit of the gate has been completed.
