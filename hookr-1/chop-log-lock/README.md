# Chop log lock

`HookrLogLock` at [`0xDa9DdAf447bA0cB93f595ae63925B8F28f038e3D`](https://robin.etherscan.io/address/0xDa9DdAf447bA0cB93f595ae63925B8F28f038e3D#code) opens a Chop log for a token, seeds the log's pair with CHOP and holds the staked liquidity until an unlock time. It is not a pool rule: no Hookr pool binds it, and it calls no Hookr contract.

## What it does

- **One call.** `open` deploys a log for the token through Chop's index manager, wraps the caller's tokens into it, adds the first liquidity of the log's pair with CHOP at the price the two amounts set, stakes that liquidity and records the position. It reverts if any wrapped token or liquidity token would be left outside the lock.
- **The lock.** A position has a beneficiary and an unlock time. `release` sends the stake to the beneficiary once the unlock time has passed; an unlock time of `type(uint64).max` never unlocks.
- **The beneficiary.** Only the beneficiary collects the position's rewards (`collect`, before and after the unlock time, and after release), hands the position to another beneficiary (`setBeneficiary`) and moves the unlock time later (`extend`). The unlock time never moves earlier.
- **Fees.** Every log opened here carries the fees Chop's index manager requires of a log. Hookr's Safe `0x8Fdfaa25e2E4dDa297F301ea06458f22186D6bE9` receives 5% of each log's fee batch, in the log's token; the share and its receiver are immutables set at construction.
- **No owner.** The contract has no owner and nothing in it can be changed after deployment.
- **What it cannot bind.** The log, the staking token and the rewards contract sit behind beacons Chop can upgrade, and a position is only as safe as they are.

## The contract

Deployed on 2026-11-18 in block 117,103,245 (03:33:39 UTC), by CREATE2 through the deployer at `0x4e59b44847b379578588920cA78FbF26c0B4956C` with salt `0x486f6f6b7220486f6f6b724c6f674c6f636b2031000000000000000000000000`, transaction `0xbc37423458216b6b475ea90bb2ddf9b424bc2c6c6c8d7bf7666201f1147557d6`, sent by `0x0c0967485A25F18E70262a2Ee80c7595CC64a5fC`.

| Contract | What it is | Address | Runtime keccak256 | Verified source |
| --- | --- | --- | --- | --- |
| `HookrLogLock` | Opens a Chop log and holds its staked liquidity until an unlock time | [`0xDa9DdAf447bA0cB93f595ae63925B8F28f038e3D`](https://robin.etherscan.io/address/0xDa9DdAf447bA0cB93f595ae63925B8F28f038e3D#code) | `0x497835c053d79b345552566917c06a92b4ba1c9a804b7f10021289e1fd88d135` | [exact match](https://repo.sourcify.dev/4663/0xDa9DdAf447bA0cB93f595ae63925B8F28f038e3D) |

Its constructor takes Chop's index manager `0xF2A26110396b4162d48A16eE8683372a6A2c3b76`, the receiver of Hookr's share and the share, 500 hundredths of a percent, and reads CHOP and the rest of Chop's canonical configuration from the index manager. The runtime keccak256 is the hash of the 6,858 bytes of code at the address, read from the chain at block 120,229,917.

## Where the files are

| Folder | Holds |
| --- | --- |
| [`src/`](./src/) | The lock, its interface and the Chop interfaces it calls, 3 files |

The other 6 files of its build are OpenZeppelin's, in the pinned submodule in [`../../lib/`](../../lib/), which its build names `../../../contracts/lib/...`. The record maps each source unit to its file; every file is byte-identical to the verified source on Sourcify.

## Building it

solc 0.8.26 (`0.8.26+commit.8a97fa7a`), via-IR, the optimizer at 200 runs, EVM version cancun, the IPFS metadata hash: the record's `chop-log-lock` settings profile, which is the exact settings of its verified metadata. The record names the compiler on the contract's entry.

```sh
node hookr-1/standard-input.mjs 0xDa9DdAf447bA0cB93f595ae63925B8F28f038e3D > lock.json
solc-0.8.26 --standard-json lock.json > lock.out.json
cast code 0xDa9DdAf447bA0cB93f595ae63925B8F28f038e3D > lock.hex   # with ETH_RPC_URL set to a chain 4663 node
node hookr-1/check-runtime.mjs 0xDa9DdAf447bA0cB93f595ae63925B8F28f038e3D lock.out.json lock.hex
```

## Status

Deployed. No independent audit of the lock has been completed.
