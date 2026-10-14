# Wallet Cap

Another Rules contract for the Hookr 1 root, deployed on 2026-10-12. While a pool's launch guard lasts, no wallet can buy more than the pool's cap of its token. Everything else is the King of the Pool whole-pot Rules: the release's Rules with the whole-pot King of the Pool. The registry admits these Rules on the Hookr 1 root next to the release's Rules and the whole-pot Rules.

| Contract | Address | Verified source |
| --- | --- | --- |
| `HookrRulesWalletCap` | [`0xb67b73E28C522a3AAC438bE970bf94976Deee52a`](https://robin.etherscan.io/address/0xb67b73E28C522a3AAC438bE970bf94976Deee52a#code) | [Sourcify](https://repo.sourcify.dev/4663/0xb67b73E28C522a3AAC438bE970bf94976Deee52a) |
| `HookrRecapture`, created by those Rules in their constructor | [`0xbbC43DC2f01F5E7882caCd78EF094A44eF0E4d23`](https://robin.etherscan.io/address/0xbbC43DC2f01F5E7882caCd78EF094A44eF0E4d23#code) | [Sourcify](https://repo.sourcify.dev/4663/0xbbC43DC2f01F5E7882caCd78EF094A44eF0E4d23) |

Both were deployed in transaction `0x111de55d14abdbf4f16434f508cfe1e775f3835125c71957b9c38d846a2e0b74` at block 87,010,819, the Rules through the same CREATE3 factory as the release, under release id `hookr-1-wallet-cap-v2` and role `HookrRulesWalletCap`. The Rules take the same constructor arguments as the release's Rules: the PoolManager, the Hookr 1 registry, the treasury, the Hookr 1 root and a 2,000 bps floor on the protocol's share of rule fees. The registry admitted them on the root with the whole-pot Rules' terms in transaction `0xb26b75215327bce5c2e7ac6de9174866d5852b190465a7be4edf8614396ade02`, and the treasury admitted them as a source it collects from in transaction `0xa3369965715a33bffbc3e51248e719f69684c93fd8fd38116b2e39d6ab8a1bf3`.

## The cap

- Each pool on these Rules has a cap, set by its creator at launch and frozen with the pool's other rules: the most of the token one wallet may buy while the pool's launch guard lasts, in the token's raw units. It is carried in the pool's `RulesConfig.potMinBuyQuote`, which the release's Rules require to be zero.
- Every pool here has a launch guard and a nonzero cap; a pool without them launches on the release's Rules. The guard ends at a block the creator sets, 1 to 100,000 blocks after the launch, counted in `block.number`, which on Robinhood Chain is Ethereum's block height, about 12 seconds a block.
- A buy counts the tokens it delivers, after any Auto Burn, against its wallet: the payer that `HookrRouter`, `HookrForwarder` or the Universal Router names, or the transaction's signer for a swap that names none.
- The count adds up across the pools of one launch, the token's pools opened in the same transaction. A later launch of the same token counts on its own, and selling frees no room.
- The launch buy (`HookrLauncher`'s dev buy, which the launcher bounds itself) and the swaps of the pool's arb recapture executor do not count.
- A buy that would take its wallet past the cap reverts with `GuardWalletLimit(wallet, total, cap)`. When the guard ends, so does the cap.
- `extsload(bytes32)` returns any word of the Rules' storage, as Uniswap v4's `Extsload` does. A wallet's count is `State.bought[token][launch][wallet]`, a mapping at the `erc7201:hookr.rules` root plus 13, and a pool's launch is the top 32 bits of the first word of its `State.pools` entry. The cap less the count is what the wallet can still buy.

## What differs from the release

Two files: [`src/core/HookrRulesWalletCap.sol`](./src/core/HookrRulesWalletCap.sol), in this folder, and `src/core/HookrRecapture.sol`, the whole-pot copy in [`../king-of-the-pool-whole-pot/`](../king-of-the-pool-whole-pot/README.md). Every other source of both contracts is the release's own file in [`../src/`](../src/).

`HookrRulesWalletCap.sol` is the release's [`src/core/HookrRules.sol`](../src/core/HookrRules.sol) with the cap added, and `diff ../src/core/HookrRules.sol src/core/HookrRulesWalletCap.sol` shows every change:

- the `bought` count per token, launch and wallet, stored after every field that `HookrRecapture`'s copy of the Rules' storage layout knows, so the module never reaches it;
- the count and the `GuardWalletLimit` check in the swap's settlement while the guard lasts;
- `extsload(bytes32)`;
- at launch, `potMinBuyQuote` must be nonzero where the release requires zero, and a pool must have a guard where the release allows none.

The `HookrRecapture` these Rules create is the whole-pot module: the same source and the same verified metadata as [`0x60Efc4a41498e9433be2155b6cc1677AEC31D649`](https://robin.etherscan.io/address/0x60Efc4a41498e9433be2155b6cc1677AEC31D649#code), and the same code except where its constructor writes the module's own address.

## Building it

The compiler input for either contract comes from the record, which maps `src/core/HookrRulesWalletCap.sol` to this folder, `src/core/HookrRecapture.sol` to the whole-pot folder and every other source to the release:

```sh
node hookr-1/standard-input.mjs 0xb67b73E28C522a3AAC438bE970bf94976Deee52a > rules.json
solc-0.8.37 --standard-json rules.json > rules.out.json
cast code 0xb67b73E28C522a3AAC438bE970bf94976Deee52a > rules.hex   # with ETH_RPC_URL set to a chain 4663 node
node hookr-1/check-runtime.mjs 0xb67b73E28C522a3AAC438bE970bf94976Deee52a rules.out.json rules.hex
```

The same four lines with `0xbbC43DC2f01F5E7882caCd78EF094A44eF0E4d23` check the module. To build it with Forge, copy `hookr-1/`, replace `src/core/HookrRecapture.sol` with the whole-pot copy and add this folder's `src/core/HookrRulesWalletCap.sol`. That build matches the deployed code up to the metadata hash, as a Forge build of the release does.

An earlier build of these Rules, `0x9695fAB3cff64044669D73575966c2E2A9B1a7C1` (release id `hookr-1-wallet-cap`, block 86,982,684), with its `HookrRecapture` at `0x97CC10f1ca06699eE956A1df0e34a3f599f74518`, was deployed first and never queued or admitted. Nothing uses it, and it is not in the record.
