# King of the Pool, whole pot

A second Rules contract for the Hookr 1 root, deployed on 2026-10-07. Its King of the Pool pays the round's winner the whole pot. Everything else is the release's Rules, unchanged.

| Contract | Address | Verified source |
| --- | --- | --- |
| `HookrRules` | [`0x10f684361b35C8411a2c07F68A6fB1F4B7e555F7`](https://robin.etherscan.io/address/0x10f684361b35C8411a2c07F68A6fB1F4B7e555F7#code) | [Sourcify](https://repo.sourcify.dev/4663/0x10f684361b35C8411a2c07F68A6fB1F4B7e555F7) |
| `HookrRecapture`, created by those Rules in their constructor | [`0x60Efc4a41498e9433be2155b6cc1677AEC31D649`](https://robin.etherscan.io/address/0x60Efc4a41498e9433be2155b6cc1677AEC31D649#code) | [Sourcify](https://repo.sourcify.dev/4663/0x60Efc4a41498e9433be2155b6cc1677AEC31D649) |

Both were deployed in transaction `0x133dcefd312eb7ea3b97e75ec91852178a84987f03cf3ffb0920ac4c3c40a5e9`, the Rules through the same CREATE3 factory as the release. The Rules take the same constructor arguments as the release's Rules: the PoolManager, the Hookr 1 registry, the treasury, the Hookr 1 root and a 2,000 bps floor on the protocol's share of rule fees.

## What differs from the release

One file: [`src/core/HookrRecapture.sol`](./src/core/HookrRecapture.sol). Every other source of both contracts is the release's own file in [`../src/`](../src/). `HookrRules` is the release's source too; it is deployed again because its constructor creates the recapture module, so new module code means new Rules.

- **The winner takes the whole pot.** When a round closes with a leader, the leader is credited the entire pot as a claim in the pool's quote. Nothing is released to LPs and nothing carries to the next round. In the release, the prize was the smaller of the pot and a share of the winning buy.
- **The pot can be all of the pool's arb share.** A pool may put up to 100% of its share of each arb recapture profit (what is left after the partner's and Hookr's cuts) in the pot: `MAX_POT_BPS` is 10,000, up from 5,000. The split still sums to 10,000 and the trader's share may be zero.
- **No buy fee behind the prize, and no prize cap.** The pot is funded only by arb recapture profit, so the prize is no longer bounded by the protocol fee a buy pays. `maxPrizeBps` must be exactly 10,000, and a pool needs neither LP Rewards nor Auto Burn to run King of the Pool. `prizeBound` and `prizeBoundFor` keep their signatures and return 10,000.
- **A round with no leader** releases `potReleaseBps` of the pot to the pool's LPs and carries the rest, as before.

The leader rules are the release's: the largest buy of at least `minBuyQuote` in the round leads; a sell on the pool in the same transaction voids the lead; the arb recapture executor's own legs never lead.

## Building it

The compiler input for either contract comes from the record, which maps `src/core/HookrRecapture.sol` to this folder and every other source to the release:

```sh
node hookr-1/standard-input.mjs 0x10f684361b35C8411a2c07F68A6fB1F4B7e555F7 > rules.json
solc-0.8.37 --standard-json rules.json > rules.out.json
```

To build it with Forge, copy `hookr-1/` and replace `src/core/HookrRecapture.sol` with this folder's copy.
