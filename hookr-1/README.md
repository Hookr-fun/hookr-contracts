# Hookr 1

Hookr 1 is a launchpad on Uniswap v4, live on Robinhood Chain (chain id 4663). Every Hookr 1 pool runs on one shared hook, `HookrRoot` at [`0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc`](https://robin.etherscan.io/address/0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc#code).

A creator launches a token on one to eight pools in a single transaction, each with its own quote currency, price and range, and picks each pool's rules at launch: Anti-Snipe, Hookr dynamic fees, Auto Burn and LP Rewards, with every parameter set by the creator. The rules are frozen when the pool opens and stay that way for the life of the pool. A pool can also take arb recapture, which keeps the profit of arbitrage against the pool's other venues with the pool's LPs and traders instead of leaving it to outside bots, and King of the Pool, a pot paid to the largest buyer of each round. A pool launched on the Wallet Cap Rules also caps how much of its token one wallet can buy while its launch guard lasts. A fee right can be locked behind a revenue token, whose holders share the income the right earns. Anyone can deploy their own unmodified copy of the hook through the owned-root factory. The combined core, a Rules contract with every Hook Block built in, runs on the shared hook beside the release's Rules, and owned-root factory v2 makes own hooks on it: a root v2 with its own copy of the core, in one transaction. Core 2, the core new pools bind since 2026-11-01, carries new Hook Block code and comes with a launcher whose tokens keep their holders' lots. The Agent gate makes a pool agents-only. The release is being deployed on Arbitrum One (chain id 42161), at the same addresses.

The shared hook's address carries its Uniswap v4 permission bits, `0x2acc`: before initialize, before add liquidity, before remove liquidity, before swap, after swap, and the before-swap and after-swap return deltas.

## What is in this folder

| Path | What it holds |
| --- | --- |
| [`src/`](./src/) | The release's sources, byte-identical to the verified sources of its 35 contracts. |
| [`foundry.toml`](./foundry.toml) | The release's compiler settings, with remappings to the pinned submodules in [`../lib/`](../lib/). |
| [`test/`](./test/README.md) | The release's unit, fuzz and invariant tests, which CI runs against `src/`. [`script/`](./script/) holds three helpers they import and [`snapshots/`](./snapshots/) the gas figures and code sizes their benches check. |
| [`king-of-the-pool-whole-pot/`](./king-of-the-pool-whole-pot/README.md) | A second Rules contract whose King of the Pool pays the round's winner the whole pot. One source file differs from the release. |
| [`wallet-cap/`](./wallet-cap/README.md) | The Wallet Cap Rules: the whole-pot Rules plus a cap on how much of a pool's token one wallet can buy while the pool's launch guard lasts. One source file is added to the whole-pot Rules' sources. |
| [`revenue-tokenizer/`](./revenue-tokenizer/README.md) | The Revenue Tokenizer and its add-ons: lock a fee right and mint a fixed-supply revenue token whose holders share its income, 16 contracts. Their sources are added to the release's. |
| [`revenue-tokenizer-v2/`](./revenue-tokenizer-v2/README.md) | Revenue Tokenizer v2, the current tokenizer: lock fee rights, mint a fixed-supply revenue token whose holders share their income, and add streams to it later. Three sets of 17 contracts from the same sources, and the time shares and compounder add-ons of the second set, 4 contracts, and of the third, 2 contracts. Their sources are added to the release's. |
| [`combined-core/`](./combined-core/README.md) | The combined core, its blocks and modules, 7 contracts; owned-root factory v2 with its three code stores, lane v2, two swap modules and the redeployed LP Boost, 8 contracts; and root v2, which the factory builds per own hook. |
| [`core-2/`](./core-2/README.md) | Core 2, its binder, Hook Blocks, settle library and recapture module, 5 contracts, and its launcher, token deployer, family router and family lock, 4 contracts. The files that differ from the combined core's and the release's. |
| [`agent-gate/`](./agent-gate/README.md) | The Agent gate, 1 contract: an advisory that makes a pool agents-only. |
| [`hook-blocks/`](./hook-blocks/README.md) | The 46 Hook Block contracts deployed in production waves 0 to 3 and the 7 contracts of the three HookrBook connectors, one folder per block or connector. |
| [`deployments/robinhood-4663.json`](./deployments/robinhood-4663.json) | Every one of the 190 contracts: address, deployment, constructor arguments, linked libraries, runtime keccak256, compiler settings, and the file in this repository behind every source unit of its verified metadata. |
| [`deployments/arbitrum-42161.json`](./deployments/arbitrum-42161.json) | The release's contracts with code on Arbitrum One (chain id 42161), 22 at its `checkedAtBlock`, in the same form, each with the sources and settings of its 4663 entry. |
| [`standard-input.mjs`](./standard-input.mjs) | Writes any of those contracts' solc standard JSON input from the files here; `--chain 42161` reads the Arbitrum record. |
| [`check-runtime.mjs`](./check-runtime.mjs) | Compares a contract's solc output with the code at its address, byte for byte. |

## Deployed contracts

Every Hookr 1 contract in production on Robinhood Chain (chain id 4663) is listed below: the release's 35, the 2 of King of the Pool whole pot, the 2 of Wallet Cap, the 46 of the Hook Blocks, the 7 of the HookrBook connectors, the 16 of the Revenue Tokenizer, the 57 of Revenue Tokenizer v2 and its add-ons, the 15 of the combined core and own hooks, the 9 of core 2 and its launcher, and the 1 of the Agent gate, 190 in all.

Release id `hookr-1`, built from artifact packet `0x83962c12ff55df431612ffae8bfc66a30041eb310035cfc30eab1bb9bdc0e031`. Every contract the release deploys itself goes through the CREATE3 factory at `0xc7c662Fc760FE1d5cB97fd8A68cb43A046da3F7d`, with a salt the factory binds to the deployer and derives from the release id and the contract's role, so nobody else can occupy these addresses. The King of the Pool whole-pot `HookrRules`, `HookrRulesWalletCap`, 37 of the Hook Block contracts, 3 of the connector contracts, 13 of the Revenue Tokenizer contracts, 54 of Revenue Tokenizer v2's, all 15 of the combined core's and all 9 of core 2's go through the same factory. The Agent gate is a plain CREATE from `0xC87AC3AD8d2270e9A66f8369f03B7CF197e7B72F`. Every other contract is created by another contract in this list in its constructor, as noted. Every address below but nine is an exact match on Sourcify. The other nine are data: the six halves of Revenue Tokenizer v2's revenue token code, whose creation code matches exactly, and the combined core's three code stores, whose content [`combined-core/check-code-stores.mjs`](./combined-core/README.md#the-code-stores) checks against the sources here. Every address's runtime code hashes to the value in the record.

### Hook and rules

| Contract | Address | Sourcify | What it does |
| --- | --- | --- | --- |
| `HookrRoot` | [`0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc`](https://robin.etherscan.io/address/0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc#code) | [match](https://repo.sourcify.dev/4663/0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc) | The shared Uniswap v4 hook of every Hookr 1 pool. Freezes each pool's terms when the pool opens. |
| `HookrRules` | [`0x4a71c270b1520F94064268102AebD744b0DE7942`](https://robin.etherscan.io/address/0x4a71c270b1520F94064268102AebD744b0DE7942#code) | [match](https://repo.sourcify.dev/4663/0x4a71c270b1520F94064268102AebD744b0DE7942) | Anti-Snipe, Hookr dynamic fees, Auto Burn and LP Rewards, and the ledger of every claim they create. Bound to the root. |
| `HookrRecapture` | [`0xF83569E564d70daebc35950f66a73f2e2B915583`](https://robin.etherscan.io/address/0xF83569E564d70daebc35950f66a73f2e2B915583#code) | [match](https://repo.sourcify.dev/4663/0xF83569E564d70daebc35950f66a73f2e2B915583) | The arb recapture split and King of the Pool, a module the Rules reach by DELEGATECALL. Created by `HookrRules`. |
| `HookrLane` | [`0x9A8a1006469BA196f8FEfc017a53505C83A060BB`](https://robin.etherscan.io/address/0x9A8a1006469BA196f8FEfc017a53505C83A060BB#code) | [match](https://repo.sourcify.dev/4663/0x9A8a1006469BA196f8FEfc017a53505C83A060BB) | The root's arb recapture module, reached by DELEGATECALL. Created by `HookrRoot`. |
| `HookrRegistry` | [`0x463c82beA1a52F4Cc05ca0741a24F0AD24bA4602`](https://robin.etherscan.io/address/0x463c82beA1a52F4Cc05ca0741a24F0AD24bA4602#code) | [match](https://repo.sourcify.dev/4663/0x463c82beA1a52F4Cc05ca0741a24F0AD24bA4602) | Timelocked admissions, root registration, launchers, the quote catalog and the guardian's brake on new pools. |
| `HookrRegistryAdmin` | [`0x675ac2102E8c69E2467F64656E3c235AF3901Ac1`](https://robin.etherscan.io/address/0x675ac2102E8c69E2467F64656E3c235AF3901Ac1#code) | [match](https://repo.sourcify.dev/4663/0x675ac2102E8c69E2467F64656E3c235AF3901Ac1) | The registry's write paths, a linked library. |
| `HookrRegistryChecks` | [`0xB9F5c54E5Cc7ac6c7a96335E5A334Cf4eA496E98`](https://robin.etherscan.io/address/0xB9F5c54E5Cc7ac6c7a96335E5A334Cf4eA496E98#code) | [match](https://repo.sourcify.dev/4663/0xB9F5c54E5Cc7ac6c7a96335E5A334Cf4eA496E98) | The registry's checks, a linked library. |

### Launching

| Contract | Address | Sourcify | What it does |
| --- | --- | --- | --- |
| `HookrLauncher` | [`0x1cf2748A6670572425eAbf9Ab9e5BC4eb2eB8Ef4`](https://robin.etherscan.io/address/0x1cf2748A6670572425eAbf9Ab9e5BC4eb2eB8Ef4#code) | [match](https://repo.sourcify.dev/4663/0x1cf2748A6670572425eAbf9Ab9e5BC4eb2eB8Ef4) | Funded launches of one to eight pools in one transaction, refunds, and the owner's liquidity management. |
| `HookrLaunchChecks` | [`0x8567369a70100828611BB6F44ec051B48F10fb59`](https://robin.etherscan.io/address/0x8567369a70100828611BB6F44ec051B48F10fb59#code) | [match](https://repo.sourcify.dev/4663/0x8567369a70100828611BB6F44ec051B48F10fb59) | The launcher's checks and launch fee, a linked library. |
| `HookrTokenDeployer` | [`0x1B23D6d7beBcB61E39317E9F0Bc02AEB91aFCcAe`](https://robin.etherscan.io/address/0x1B23D6d7beBcB61E39317E9F0Bc02AEB91aFCcAe#code) | [match](https://repo.sourcify.dev/4663/0x1B23D6d7beBcB61E39317E9F0Bc02AEB91aFCcAe) | Creates the fixed-supply tokens the launcher launches, a linked library. |
| `HookrFamilyRouter` | [`0x854f3Fa7AC342B244DF0d9A8c8F597b051aAE559`](https://robin.etherscan.io/address/0x854f3Fa7AC342B244DF0d9A8c8F597b051aAE559#code) | [match](https://repo.sourcify.dev/4663/0x854f3Fa7AC342B244DF0d9A8c8F597b051aAE559) | Splits one trade across a family's pools. |
| `HookrFamilyLock` | [`0xfAFEcE64099C1E791C4B46189c277f00c0c7e00b`](https://robin.etherscan.io/address/0xfAFEcE64099C1E791C4B46189c277f00c0c7e00b#code) | [match](https://repo.sourcify.dev/4663/0xfAFEcE64099C1E791C4B46189c277f00c0c7e00b) | Keeps a family's liquidity in its pools until an unlock block, or for good, while its beneficiary collects the fees. |
| `HookrRootFactory` | [`0x21E438FaBE10770afb4407cF6b09d32369CBdCE4`](https://robin.etherscan.io/address/0x21E438FaBE10770afb4407cF6b09d32369CBdCE4#code) | [match](https://repo.sourcify.dev/4663/0x21E438FaBE10770afb4407cF6b09d32369CBdCE4) | Deploys, registers and initializes single-pool pair roots, permissionlessly. |
| `HookrOwnedRootFactory` | [`0xA6c2a401597301dFf57A59bC8F70a9622499f3ec`](https://robin.etherscan.io/address/0xA6c2a401597301dFf57A59bC8F70a9622499f3ec#code) | [match](https://repo.sourcify.dev/4663/0xA6c2a401597301dFf57A59bC8F70a9622499f3ec) | Deploys an unmodified copy of the root with its own Rules for anyone, from a listed profile. |
| `HookrOwnedProfiles` | [`0xb46c318B6AEA2d6274f5566da414b09fDa6CC325`](https://robin.etherscan.io/address/0xb46c318B6AEA2d6274f5566da414b09fDa6CC325#code) | [match](https://repo.sourcify.dev/4663/0xb46c318B6AEA2d6274f5566da414b09fDa6CC325) | The profile book for owned roots. |
| `HookrOwnedRootsLens` | [`0x6Bb5c9d21dD095F788cb8373d0143429ad277366`](https://robin.etherscan.io/address/0x6Bb5c9d21dD095F788cb8373d0143429ad277366#code) | [match](https://repo.sourcify.dev/4663/0x6Bb5c9d21dD095F788cb8373d0143429ad277366) | Read-only views over owned roots. |

### Trading

| Contract | Address | Sourcify | What it does |
| --- | --- | --- | --- |
| `HookrRouter` | [`0xC2Bc9a3fe6c4Ce8C2F7EB4655b0869b01D8c93C9`](https://robin.etherscan.io/address/0xC2Bc9a3fe6c4Ce8C2F7EB4655b0869b01D8c93C9#code) | [match](https://repo.sourcify.dev/4663/0xC2Bc9a3fe6c4Ce8C2F7EB4655b0869b01D8c93C9) | Authenticated swaps on Hookr pools. |
| `HookrQuoter` | [`0x445D7891381Aa7F91F5048EdBC6a611ccBDe7865`](https://robin.etherscan.io/address/0x445D7891381Aa7F91F5048EdBC6a611ccBDe7865#code) | [match](https://repo.sourcify.dev/4663/0x445D7891381Aa7F91F5048EdBC6a611ccBDe7865) | Quotes by reverting simulation. |
| `HookrForwarder` | [`0xe7863CC0E2Fb783b44c279aB159bcD812c2ceA1c`](https://robin.etherscan.io/address/0xe7863CC0E2Fb783b44c279aB159bcD812c2ceA1c#code) | [match](https://repo.sourcify.dev/4663/0xe7863CC0E2Fb783b44c279aB159bcD812c2ceA1c) | Gasless swaps: one Permit2-witness signature covers the token pull and the exact swap. |

### Advisories

| Contract | Address | Sourcify | What it does |
| --- | --- | --- | --- |
| `HookrFeeAdvisory` | [`0x3B6b3f00684987B831fcF9EB5f0d5B806afF7306`](https://robin.etherscan.io/address/0x3B6b3f00684987B831fcF9EB5f0d5B806afF7306#code) | [match](https://repo.sourcify.dev/4663/0x3B6b3f00684987B831fcF9EB5f0d5B806afF7306) | An LP surcharge a keeper reprices inside bounds the creator froze at launch. |
| `HookrSessionAdvisory` | [`0x78Bc6b7302Dda8632e661c8d74966bdBea1c66b1`](https://robin.etherscan.io/address/0x78Bc6b7302Dda8632e661c8d74966bdBea1c66b1#code) | [match](https://repo.sourcify.dev/4663/0x78Bc6b7302Dda8632e661c8d74966bdBea1c66b1) | An LP surcharge that follows the US equity session, for tokenized-stock pools. |
| `HookrCompliance` | [`0x9D205e8a68464761A9d84bdeCcEa0C3CB1e7B1EC`](https://robin.etherscan.io/address/0x9D205e8a68464761A9d84bdeCcEa0C3CB1e7B1EC#code) | [match](https://repo.sourcify.dev/4663/0x9D205e8a68464761A9d84bdeCcEa0C3CB1e7B1EC) | Opt-in credential lists and wallet sanctions. |
| `HookrComplianceGuard` | [`0x6CD70db1ac99344416a6fD7184e23FA8f09f313A`](https://robin.etherscan.io/address/0x6CD70db1ac99344416a6fD7184e23FA8f09f313A#code) | [match](https://repo.sourcify.dev/4663/0x6CD70db1ac99344416a6fD7184e23FA8f09f313A) | The fail-closed advisory that admits only permitted wallets into a gated pool's swaps and liquidity. |

### Liquidity

| Contract | Address | Sourcify | What it does |
| --- | --- | --- | --- |
| `HookrLiquidityVault` | [`0xA408923EF811945Ef119Bc700B1950Dab65467Fc`](https://robin.etherscan.io/address/0xA408923EF811945Ef119Bc700B1950Dab65467Fc#code) | [match](https://repo.sourcify.dev/4663/0xA408923EF811945Ef119Bc700B1950Dab65467Fc) | Pools LP liquidity into one position per pool and range, with ERC-6909 shares. |
| `HookrLpBoost` | [`0x52536F5F4E5BC7cEA2197c8F1BB49bf2B133E7f1`](https://robin.etherscan.io/address/0x52536F5F4E5BC7cEA2197c8F1BB49bf2B133E7f1#code) | [match](https://repo.sourcify.dev/4663/0x52536F5F4E5BC7cEA2197c8F1BB49bf2B133E7f1) | The LP Time-Lock Boost: funded gauges for locked full-range positions. |

### Programs and referrals

| Contract | Address | Sourcify | What it does |
| --- | --- | --- | --- |
| `HookrPrograms` | [`0x9fA204AC99176782Fd20615b2b2A516D1F8C328F`](https://robin.etherscan.io/address/0x9fA204AC99176782Fd20615b2b2A516D1F8C328F#code) | [match](https://repo.sourcify.dev/4663/0x9fA204AC99176782Fd20615b2b2A516D1F8C328F) | Creator programs, Bux budgets, daily allocations and milestone NFT claims. |
| `HookrProgramsAdmin` | [`0x40B40D65543E70a9C757eda1A2208517a8BC7292`](https://robin.etherscan.io/address/0x40B40D65543E70a9C757eda1A2208517a8BC7292#code) | [match](https://repo.sourcify.dev/4663/0x40B40D65543E70a9C757eda1A2208517a8BC7292) | The programs' Bux approvals and milestone NFT delivery, a linked library. |
| `HookrProgramValidator` | [`0x33e0249083Be7Cd8bD2fe175E0671AcfD0516850`](https://robin.etherscan.io/address/0x33e0249083Be7Cd8bD2fe175E0671AcfD0516850#code) | [match](https://repo.sourcify.dev/4663/0x33e0249083Be7Cd8bD2fe175E0671AcfD0516850) | The checks a new program must pass. Created by `HookrPrograms`. |
| `HookrMilestoneNFTFactory` | [`0xa340F964F1E685c681dC3ABB5B0405E608914d00`](https://robin.etherscan.io/address/0xa340F964F1E685c681dC3ABB5B0405E608914d00#code) | [match](https://repo.sourcify.dev/4663/0xa340F964F1E685c681dC3ABB5B0405E608914d00) | Creates each program's milestone NFT collection. Created by `HookrPrograms`. |
| `HookrReferralRegistry` | [`0xefD1DfBA80c06E72F793601706c3a1c71aab3057`](https://robin.etherscan.io/address/0xefD1DfBA80c06E72F793601706c3a1c71aab3057#code) | [match](https://repo.sourcify.dev/4663/0xefD1DfBA80c06E72F793601706c3a1c71aab3057) | Referral bindings, authorized by the payer ahead of time. |
| `HookrReferralDistributor` | [`0x690539c53212899A9c6AEEE3b4B6737A5c4851d9`](https://robin.etherscan.io/address/0x690539c53212899A9c6AEEE3b4B6737A5c4851d9#code) | [match](https://repo.sourcify.dev/4663/0x690539c53212899A9c6AEEE3b4B6737A5c4851d9) | Funded referral commissions, paid against reviewed fee evidence. |

### Treasury and gas

| Contract | Address | Sourcify | What it does |
| --- | --- | --- | --- |
| `HookrTreasury` | [`0x2242F7FC75606500503075f29ea8cDA684EfB4a9`](https://robin.etherscan.io/address/0x2242F7FC75606500503075f29ea8cDA684EfB4a9#code) | [match](https://repo.sourcify.dev/4663/0x2242F7FC75606500503075f29ea8cDA684EfB4a9) | Collects the protocol's claims and governs the fee terms new pools bind with. |
| `HookrPaymaster` | [`0x1c4682915092E742231ea038C4fcA61e96a83c99`](https://robin.etherscan.io/address/0x1c4682915092E742231ea038C4fcA61e96a83c99#code) | [match](https://repo.sourcify.dev/4663/0x1c4682915092E742231ea038C4fcA61e96a83c99) | An ERC-4337 v0.7 paymaster that rebates operations which paid the Hookr fee. |
| `HookrPaymasterAdmin` | [`0x1d81F4B131832f741392edf7B91b4CF099FbB008`](https://robin.etherscan.io/address/0x1d81F4B131832f741392edf7B91b4CF099FbB008#code) | [match](https://repo.sourcify.dev/4663/0x1d81F4B131832f741392edf7B91b4CF099FbB008) | The paymaster's configuration paths, a linked library. |
| `HookrAccountCalls` | [`0x0579a95A7760070E2d6D34e5beCe571e5F1c4818`](https://robin.etherscan.io/address/0x0579a95A7760070E2d6D34e5beCe571e5F1c4818#code) | [match](https://repo.sourcify.dev/4663/0x0579a95A7760070E2d6D34e5beCe571e5F1c4818) | Decodes an account's calls and checks them against the paymaster's policy, a linked library. |

### King of the Pool, whole pot

Deployed on 2026-10-07. The registry admits these Rules on the root next to the release's Rules. [`king-of-the-pool-whole-pot/`](./king-of-the-pool-whole-pot/README.md) has what differs from the release.

| Contract | Address | Sourcify |
| --- | --- | --- |
| `HookrRecapture`, created by the whole-pot `HookrRules` in its constructor | [`0x60Efc4a41498e9433be2155b6cc1677AEC31D649`](https://robin.etherscan.io/address/0x60Efc4a41498e9433be2155b6cc1677AEC31D649#code) | [match](https://repo.sourcify.dev/4663/0x60Efc4a41498e9433be2155b6cc1677AEC31D649) |
| `HookrRules` | [`0x10f684361b35C8411a2c07F68A6fB1F4B7e555F7`](https://robin.etherscan.io/address/0x10f684361b35C8411a2c07F68A6fB1F4B7e555F7#code) | [match](https://repo.sourcify.dev/4663/0x10f684361b35C8411a2c07F68A6fB1F4B7e555F7) |

### Wallet Cap

Deployed on 2026-10-12 (block 87,010,819). The registry admits these Rules on the root next to the release's Rules and the whole-pot Rules. [`wallet-cap/`](./wallet-cap/README.md) has the cap's rules and what differs from the release.

| Contract | Address | Sourcify |
| --- | --- | --- |
| `HookrRecapture`, created by `HookrRulesWalletCap` in its constructor | [`0xbbC43DC2f01F5E7882caCd78EF094A44eF0E4d23`](https://robin.etherscan.io/address/0xbbC43DC2f01F5E7882caCd78EF094A44eF0E4d23#code) | [match](https://repo.sourcify.dev/4663/0xbbC43DC2f01F5E7882caCd78EF094A44eF0E4d23) |
| `HookrRulesWalletCap` | [`0xb67b73E28C522a3AAC438bE970bf94976Deee52a`](https://robin.etherscan.io/address/0xb67b73E28C522a3AAC438bE970bf94976Deee52a#code) | [match](https://repo.sourcify.dev/4663/0xb67b73E28C522a3AAC438bE970bf94976Deee52a) |

### Hook Blocks

The 46 contracts of the 17 Hook Blocks deployed in production waves 0 to 3. Each block's folder in [`hook-blocks/`](./hook-blocks/README.md) says what its contracts do.

| Wave | Block | Contract | Address | Sourcify |
| --- | --- | --- | --- | --- |
| 0 | [Vesting Milestone](./hook-blocks/vesting-milestone/README.md) | `HookrVestingMilestoneFactory` | [`0x964618850934Daa4f37CB5954BEdFb2bB86C5D26`](https://robin.etherscan.io/address/0x964618850934Daa4f37CB5954BEdFb2bB86C5D26#code) | [match](https://repo.sourcify.dev/4663/0x964618850934Daa4f37CB5954BEdFb2bB86C5D26) |
| 1 | [Best Route](./hook-blocks/best-route/README.md) | `HookrBestRouteQuoter` | [`0xCCCCef0E1a9C8F35B7b80D0F44Ca5C302026A65B`](https://robin.etherscan.io/address/0xCCCCef0E1a9C8F35B7b80D0F44Ca5C302026A65B#code) | [match](https://repo.sourcify.dev/4663/0xCCCCef0E1a9C8F35B7b80D0F44Ca5C302026A65B) |
| 1 | [Buy/Sell Block](./hook-blocks/buy-sell-block/README.md) | `HookrBuySellBlock` | [`0xffefEA428C13813D4526fc77A8CA0df0c787626f`](https://robin.etherscan.io/address/0xffefEA428C13813D4526fc77A8CA0df0c787626f#code) | [match](https://repo.sourcify.dev/4663/0xffefEA428C13813D4526fc77A8CA0df0c787626f) |
| 1 | [Buy/Sell Block](./hook-blocks/buy-sell-block/README.md) | `HookrRecapture`, created by `HookrRulesRoundTrip` in its constructor | [`0xddFF6326E5CB9AA98b88e9064d9A9570f777f8A3`](https://robin.etherscan.io/address/0xddFF6326E5CB9AA98b88e9064d9A9570f777f8A3#code) | [match](https://repo.sourcify.dev/4663/0xddFF6326E5CB9AA98b88e9064d9A9570f777f8A3) |
| 1 | [Buy/Sell Block](./hook-blocks/buy-sell-block/README.md) | `HookrRoundTripRecords`, created by `HookrRulesRoundTrip` in its constructor | [`0xb63B051Cf7C3FE6b03E4FcbA1e9D2130416d53c5`](https://robin.etherscan.io/address/0xb63B051Cf7C3FE6b03E4FcbA1e9D2130416d53c5#code) | [match](https://repo.sourcify.dev/4663/0xb63B051Cf7C3FE6b03E4FcbA1e9D2130416d53c5) |
| 1 | [Buy/Sell Block](./hook-blocks/buy-sell-block/README.md) | `HookrRulesRoundTrip` | [`0x3d7e31746127FD9a14d3C7fC12E73611D2e8cb34`](https://robin.etherscan.io/address/0x3d7e31746127FD9a14d3C7fC12E73611D2e8cb34#code) | [match](https://repo.sourcify.dev/4663/0x3d7e31746127FD9a14d3C7fC12E73611D2e8cb34) |
| 1 | [Canonical Venue Token](./hook-blocks/canonical-venue-token/README.md) | `CanonicalVenueLaunch`, created by `CanonicalVenueSettlement` in its constructor | [`0xd4b860d6FC296954Ce3b882bA54C515c22122e44`](https://robin.etherscan.io/address/0xd4b860d6FC296954Ce3b882bA54C515c22122e44#code) | [match](https://repo.sourcify.dev/4663/0xd4b860d6FC296954Ce3b882bA54C515c22122e44) |
| 1 | [Canonical Venue Token](./hook-blocks/canonical-venue-token/README.md) | `CanonicalVenuePeriphery` | [`0x7c57fc23dCaB13A0B75801669C3A48A5306039d2`](https://robin.etherscan.io/address/0x7c57fc23dCaB13A0B75801669C3A48A5306039d2#code) | [match](https://repo.sourcify.dev/4663/0x7c57fc23dCaB13A0B75801669C3A48A5306039d2) |
| 1 | [Canonical Venue Token](./hook-blocks/canonical-venue-token/README.md) | `CanonicalVenueSettlement` | [`0xD1EFf2aad81b0fDE70Ff6E43697F86931e2622f7`](https://robin.etherscan.io/address/0xD1EFf2aad81b0fDE70Ff6E43697F86931e2622f7#code) | [match](https://repo.sourcify.dev/4663/0xD1EFf2aad81b0fDE70Ff6E43697F86931e2622f7) |
| 1 | [Canonical Venue Token](./hook-blocks/canonical-venue-token/README.md) | `CanonicalVenueTokenDeployer`, created by `CanonicalVenueSettlement` in its constructor | [`0xB699c043aB0410E3C1aBC97998fbb28b4F32C3c5`](https://robin.etherscan.io/address/0xB699c043aB0410E3C1aBC97998fbb28b4F32C3c5#code) | [match](https://repo.sourcify.dev/4663/0xB699c043aB0410E3C1aBC97998fbb28b4F32C3c5) |
| 1 | [Entry Ratio Guarantee](./hook-blocks/entry-ratio-guarantee/README.md) | `EntryRatioGuaranteeHook` | [`0x3FcCD4321470Be51Fca58D9C34de735a78E98301`](https://robin.etherscan.io/address/0x3FcCD4321470Be51Fca58D9C34de735a78E98301#code) | [match](https://repo.sourcify.dev/4663/0x3FcCD4321470Be51Fca58D9C34de735a78E98301) |
| 1 | [Entry Ratio Guarantee](./hook-blocks/entry-ratio-guarantee/README.md) | `EntryRatioRegistrar` | [`0xdD3586bedFA8defaD2184dc672E875ceEc897793`](https://robin.etherscan.io/address/0xdD3586bedFA8defaD2184dc672E875ceEc897793#code) | [match](https://repo.sourcify.dev/4663/0xdD3586bedFA8defaD2184dc672E875ceEc897793) |
| 1 | [Entry Ratio Guarantee](./hook-blocks/entry-ratio-guarantee/README.md) | `EntryRatioVault`, created by `EntryRatioGuaranteeHook` in its constructor | [`0x158E101b1dBdbe4a5f9AdF833d5D439Aa0D29552`](https://robin.etherscan.io/address/0x158E101b1dBdbe4a5f9AdF833d5D439Aa0D29552#code) | [match](https://repo.sourcify.dev/4663/0x158E101b1dBdbe4a5f9AdF833d5D439Aa0D29552) |
| 1 | [Entry Ratio Guarantee](./hook-blocks/entry-ratio-guarantee/README.md) | `ErgV3TwapReference` | [`0x465b2d75487C37c152B7f6854912051c181F7857`](https://robin.etherscan.io/address/0x465b2d75487C37c152B7f6854912051c181F7857#code) | [match](https://repo.sourcify.dev/4663/0x465b2d75487C37c152B7f6854912051c181F7857) |
| 1 | [Entry Ratio Guarantee](./hook-blocks/entry-ratio-guarantee/README.md) | `ErgV3TwapReference` | [`0xAD27BCe64538D4AB20C5e0Bc94EdCD0831a64883`](https://robin.etherscan.io/address/0xAD27BCe64538D4AB20C5e0Bc94EdCD0831a64883#code) | [match](https://repo.sourcify.dev/4663/0xAD27BCe64538D4AB20C5e0Bc94EdCD0831a64883) |
| 1 | [External Launch](./hook-blocks/external-launch-adapter/README.md) | `HooklessLaunchAdapter` | [`0x524Ae074223711ee9BC6FC425E7e359aca30151E`](https://robin.etherscan.io/address/0x524Ae074223711ee9BC6FC425E7e359aca30151E#code) | [match](https://repo.sourcify.dev/4663/0x524Ae074223711ee9BC6FC425E7e359aca30151E) |
| 1 | [External Launch](./hook-blocks/external-launch-adapter/README.md) | `HookrExternalHookBook` | [`0x96D01E30cd4980D16e757f0Ab2a1d24caFf02f86`](https://robin.etherscan.io/address/0x96D01E30cd4980D16e757f0Ab2a1d24caFf02f86#code) | [match](https://repo.sourcify.dev/4663/0x96D01E30cd4980D16e757f0Ab2a1d24caFf02f86) |
| 1 | [External Launch](./hook-blocks/external-launch-adapter/README.md) | `HookrExternalLauncher` | [`0x4F121366e6F44f219dC87Ce382e6054c66fA860e`](https://robin.etherscan.io/address/0x4F121366e6F44f219dC87Ce382e6054c66fA860e#code) | [match](https://repo.sourcify.dev/4663/0x4F121366e6F44f219dC87Ce382e6054c66fA860e) |
| 1 | [External Launch](./hook-blocks/external-launch-adapter/README.md) | `HookrTokenDeployer` | [`0xA3B750366F3Bc54dE57C3A455E25C212cC176ac6`](https://robin.etherscan.io/address/0xA3B750366F3Bc54dE57C3A455E25C212cC176ac6#code) | [match](https://repo.sourcify.dev/4663/0xA3B750366F3Bc54dE57C3A455E25C212cC176ac6) |
| 1 | [External Launch](./hook-blocks/external-launch-adapter/README.md) | `PlainInitializeLaunchAdapter` | [`0xa5Db222fe6B144Fe43b20fEfD6a14bc81896222d`](https://robin.etherscan.io/address/0xa5Db222fe6B144Fe43b20fEfD6a14bc81896222d#code) | [match](https://repo.sourcify.dev/4663/0xa5Db222fe6B144Fe43b20fEfD6a14bc81896222d) |
| 1 | [Market Guard](./hook-blocks/market-guard/README.md) | `HookrMarketGuard` | [`0xFc5CAE364FDEE4347D97E2aEB82f3155068693A4`](https://robin.etherscan.io/address/0xFc5CAE364FDEE4347D97E2aEB82f3155068693A4#code) | [match](https://repo.sourcify.dev/4663/0xFc5CAE364FDEE4347D97E2aEB82f3155068693A4) |
| 1 | [Module Market](./hook-blocks/module-market/README.md) | `HookrBondVault` | [`0xeC09A4BfE1076D1cC928EC475D6C27188b9B1F90`](https://robin.etherscan.io/address/0xeC09A4BfE1076D1cC928EC475D6C27188b9B1F90#code) | [match](https://repo.sourcify.dev/4663/0xeC09A4BfE1076D1cC928EC475D6C27188b9B1F90) |
| 1 | [Module Market](./hook-blocks/module-market/README.md) | `HookrModuleMarket` | [`0xbAcE47373D6FF5B017e08a3EcA5a93ec49680f15`](https://robin.etherscan.io/address/0xbAcE47373D6FF5B017e08a3EcA5a93ec49680f15#code) | [match](https://repo.sourcify.dev/4663/0xbAcE47373D6FF5B017e08a3EcA5a93ec49680f15) |
| 1 | [Module Market](./hook-blocks/module-market/README.md) | `HookrUsageFeeRouter` | [`0xf98A8701325f2AB5cD92FAB3775615F98C70F3f1`](https://robin.etherscan.io/address/0xf98A8701325f2AB5cD92FAB3775615F98C70F3f1#code) | [match](https://repo.sourcify.dev/4663/0xf98A8701325f2AB5cD92FAB3775615F98C70F3f1) |
| 1 | [Pay Later](./hook-blocks/pay-later/README.md) | `PayLaterFactory` | [`0x87dF80a261670186286B507b7E3648Fb18A0aF69`](https://robin.etherscan.io/address/0x87dF80a261670186286B507b7E3648Fb18A0aF69#code) | [match](https://repo.sourcify.dev/4663/0x87dF80a261670186286B507b7E3648Fb18A0aF69) |
| 1 | [Pay Later](./hook-blocks/pay-later/README.md) | `PayLaterVaultDeployer`, created by `PayLaterFactory` in its constructor | [`0xcfD71F8525A5ac3C52675da142652F8d9055E14A`](https://robin.etherscan.io/address/0xcfD71F8525A5ac3C52675da142652F8d9055E14A#code) | [match](https://repo.sourcify.dev/4663/0xcfD71F8525A5ac3C52675da142652F8d9055E14A) |
| 1 | [Recovery Reserve](./hook-blocks/recovery-reserve/README.md) | `HookrRecoveryReserve` | [`0xF5F802A1B39a90e6c0b15DeB9D6acE7070643250`](https://robin.etherscan.io/address/0xF5F802A1B39a90e6c0b15DeB9D6acE7070643250#code) | [match](https://repo.sourcify.dev/4663/0xF5F802A1B39a90e6c0b15DeB9D6acE7070643250) |
| 1 | [Revenue Router](./hook-blocks/revenue-router/README.md) | `HookrRevenueRouter` | [`0x065841021611e0B831b15e62a296C8E7C403A6e0`](https://robin.etherscan.io/address/0x065841021611e0B831b15e62a296C8E7C403A6e0#code) | [match](https://repo.sourcify.dev/4663/0x065841021611e0B831b15e62a296C8E7C403A6e0) |
| 2 | [Limit Orders](./hook-blocks/limit-orders/README.md) | `HookrLimitOrders` | [`0x0c376cc30b1AC98b8ef80a4F516212D3B99402fA`](https://robin.etherscan.io/address/0x0c376cc30b1AC98b8ef80a4F516212D3B99402fA#code) | [match](https://repo.sourcify.dev/4663/0x0c376cc30b1AC98b8ef80a4F516212D3B99402fA) |
| 3 | [Builder Attribution](./hook-blocks/builder-attribution/README.md) | `HookrAttributionLauncher` | [`0x4aa429Bcc4A92e7F8601D1387E72e325a920b2C8`](https://robin.etherscan.io/address/0x4aa429Bcc4A92e7F8601D1387E72e325a920b2C8#code) | [match](https://repo.sourcify.dev/4663/0x4aa429Bcc4A92e7F8601D1387E72e325a920b2C8) |
| 3 | [Builder Attribution](./hook-blocks/builder-attribution/README.md) | `HookrDirectionalTax` | [`0x99012422e1acBdf53C42BB378eb2f4e468005d3c`](https://robin.etherscan.io/address/0x99012422e1acBdf53C42BB378eb2f4e468005d3c#code) | [match](https://repo.sourcify.dev/4663/0x99012422e1acBdf53C42BB378eb2f4e468005d3c) |
| 3 | [Builder Attribution](./hook-blocks/builder-attribution/README.md) | `HookrPartnerRegistry` | [`0x48FE32A6a1b1507D6981A51f907d53595C16e862`](https://robin.etherscan.io/address/0x48FE32A6a1b1507D6981A51f907d53595C16e862#code) | [match](https://repo.sourcify.dev/4663/0x48FE32A6a1b1507D6981A51f907d53595C16e862) |
| 3 | [Credential Gate](./hook-blocks/credential-gate/README.md) | `HookrCredentialGate` | [`0x9fddb25D80B71022384AcCE128bD8B76E3206266`](https://robin.etherscan.io/address/0x9fddb25D80B71022384AcCE128bD8B76E3206266#code) | [match](https://repo.sourcify.dev/4663/0x9fddb25D80B71022384AcCE128bD8B76E3206266) |
| 3 | [Directional Tax](./hook-blocks/directional-tax/README.md) | `HookrClaimRedeemer` | [`0x79B3A3C610c3F5E0926F2b2a08Aa4c7b00776De4`](https://robin.etherscan.io/address/0x79B3A3C610c3F5E0926F2b2a08Aa4c7b00776De4#code) | [match](https://repo.sourcify.dev/4663/0x79B3A3C610c3F5E0926F2b2a08Aa4c7b00776De4) |
| 3 | [Directional Tax](./hook-blocks/directional-tax/README.md) | `HookrDirectionalTax` | [`0xE73fAD0d773b9571a7a9d2A1edc01132fF5f1e1F`](https://robin.etherscan.io/address/0xE73fAD0d773b9571a7a9d2A1edc01132fF5f1e1F#code) | [match](https://repo.sourcify.dev/4663/0xE73fAD0d773b9571a7a9d2A1edc01132fF5f1e1F) |
| 3 | [Directional Tax](./hook-blocks/directional-tax/README.md) | `HookrFeeRouteAuthorizer` | [`0x05B0A56432c7692326eF2EcC41997B0fb3d33020`](https://robin.etherscan.io/address/0x05B0A56432c7692326eF2EcC41997B0fb3d33020#code) | [match](https://repo.sourcify.dev/4663/0x05B0A56432c7692326eF2EcC41997B0fb3d33020) |
| 3 | [Directional Tax](./hook-blocks/directional-tax/README.md) | `HookrFeeRouteRegistry` | [`0xC9B5Ded0c6f1eeFFf2a41607d6EE4e71be88763A`](https://robin.etherscan.io/address/0xC9B5Ded0c6f1eeFFf2a41607d6EE4e71be88763A#code) | [match](https://repo.sourcify.dev/4663/0xC9B5Ded0c6f1eeFFf2a41607d6EE4e71be88763A) |
| 3 | [Directional Tax](./hook-blocks/directional-tax/README.md) | `HookrFeeSwapExecutor` | [`0x0Eb5076E91803194281Dcfd94aDF453d5D1575B0`](https://robin.etherscan.io/address/0x0Eb5076E91803194281Dcfd94aDF453d5D1575B0#code) | [match](https://repo.sourcify.dev/4663/0x0Eb5076E91803194281Dcfd94aDF453d5D1575B0) |
| 3 | [Directional Tax](./hook-blocks/directional-tax/README.md) | `HookrTaxQueue`, created by `HookrDirectionalTax` in its constructor | [`0x2C2Fd39520165e5Ee5a9DD69297fe0BE02F29619`](https://robin.etherscan.io/address/0x2C2Fd39520165e5Ee5a9DD69297fe0BE02F29619#code) | [match](https://repo.sourcify.dev/4663/0x2C2Fd39520165e5Ee5a9DD69297fe0BE02F29619) |
| 3 | [Directional Tax](./hook-blocks/directional-tax/README.md) | `HookrV4ExactInputAdapter` | [`0x7AeD9F3Ca84e36f66814734aED557F3FC914eb48`](https://robin.etherscan.io/address/0x7AeD9F3Ca84e36f66814734aED557F3FC914eb48#code) | [match](https://repo.sourcify.dev/4663/0x7AeD9F3Ca84e36f66814734aED557F3FC914eb48) |
| 3 | [Swap Reward Mint](./hook-blocks/swap-reward-mint/README.md) | `HookrSwapRewardAdvisory` | [`0x1e909Fc57419389F7964078287f8654C6415d68D`](https://robin.etherscan.io/address/0x1e909Fc57419389F7964078287f8654C6415d68D#code) | [match](https://repo.sourcify.dev/4663/0x1e909Fc57419389F7964078287f8654C6415d68D) |
| 3 | [Swap Reward Mint](./hook-blocks/swap-reward-mint/README.md) | `HookrSwapRewardMinterFactory` | [`0xC80161AFDE6e9278360994D30761aB0b3B29B00D`](https://robin.etherscan.io/address/0xC80161AFDE6e9278360994D30761aB0b3B29B00D#code) | [match](https://repo.sourcify.dev/4663/0xC80161AFDE6e9278360994D30761aB0b3B29B00D) |
| 3 | [Zap Relay](./hook-blocks/zap-relay/README.md) | `HookrGatedRelay` | [`0x59834ed88E72c59EB4fB0eF3cB0D95eCA98223E3`](https://robin.etherscan.io/address/0x59834ed88E72c59EB4fB0eF3cB0D95eCA98223E3#code) | [match](https://repo.sourcify.dev/4663/0x59834ed88E72c59EB4fB0eF3cB0D95eCA98223E3) |
| 3 | [Zap Relay](./hook-blocks/zap-relay/README.md) | `HookrZapAccrual` | [`0xA3d07234F6Ecb7012b8f46F277E9BaDae6e55bAD`](https://robin.etherscan.io/address/0xA3d07234F6Ecb7012b8f46F277E9BaDae6e55bAD#code) | [match](https://repo.sourcify.dev/4663/0xA3d07234F6Ecb7012b8f46F277E9BaDae6e55bAD) |
| 3 | [Zap Relay](./hook-blocks/zap-relay/README.md) | `ZapSessionLens`, created by `HookrZapAccrual` in its constructor | [`0xA413F059741Fab1246F36E6eFb464A18F796205D`](https://robin.etherscan.io/address/0xA413F059741Fab1246F36E6eFb464A18F796205D#code) | [match](https://repo.sourcify.dev/4663/0xA413F059741Fab1246F36E6eFb464A18F796205D) |
| 3 | [Zap Relay](./hook-blocks/zap-relay/README.md) | `ZapVaultDeployer`, created by `HookrZapAccrual` in its constructor | [`0x02779BE78Dd6f59fdF5D7e57A0560ce38f52C779`](https://robin.etherscan.io/address/0x02779BE78Dd6f59fdF5D7e57A0560ce38f52C779#code) | [match](https://repo.sourcify.dev/4663/0x02779BE78Dd6f59fdF5D7e57A0560ce38f52C779) |

### HookrBook connectors

The 7 contracts of the three HookrBook connectors: 6 deployed on 2026-10-12 (blocks 86,244,980 to 86,244,987), and the Fee Bridge's keeper-run factory, deployed on 2026-10-13 (block 87,254,611), which replaces the first Fee Bridge factory. Each connector's folder in [`hook-blocks/`](./hook-blocks/README.md#hookrbook-connectors) says what its contracts do. `HookrZapMeshAccrual` is admitted on `HookrRoot` as an ADVISORY.

| Connector | Contract | Address | Sourcify |
| --- | --- | --- | --- |
| [Pool Mesh](./hook-blocks/zap-mesh/README.md) | `HookrZapMeshAccrual` | [`0x4ffFCC9bc83da95Ed1E04C8008a31ef2743C1d42`](https://robin.etherscan.io/address/0x4ffFCC9bc83da95Ed1E04C8008a31ef2743C1d42#code) | [match](https://repo.sourcify.dev/4663/0x4ffFCC9bc83da95Ed1E04C8008a31ef2743C1d42) |
| [Pool Mesh](./hook-blocks/zap-mesh/README.md) | `ZapMeshDeployer`, created by `HookrZapMeshAccrual` in its constructor | [`0x3675C3647B3F8b7CAe2f4a3B08C5CCDf9d5c153e`](https://robin.etherscan.io/address/0x3675C3647B3F8b7CAe2f4a3B08C5CCDf9d5c153e#code) | [match](https://repo.sourcify.dev/4663/0x3675C3647B3F8b7CAe2f4a3B08C5CCDf9d5c153e) |
| [Pool Mesh](./hook-blocks/zap-mesh/README.md) | `ZapMeshLegDeployer`, created by `HookrZapMeshAccrual` in its constructor | [`0xE347ef34ad78b7f1008b1Fd22425f75eD44bCcad`](https://robin.etherscan.io/address/0xE347ef34ad78b7f1008b1Fd22425f75eD44bCcad#code) | [match](https://repo.sourcify.dev/4663/0xE347ef34ad78b7f1008b1Fd22425f75eD44bCcad) |
| [Pool Mesh](./hook-blocks/zap-mesh/README.md) | `ZapSessionLens`, created by `HookrZapMeshAccrual` in its constructor | [`0x0F48792eed1a8196644540E98E5b508A03cA977c`](https://robin.etherscan.io/address/0x0F48792eed1a8196644540E98E5b508A03cA977c#code) | [match](https://repo.sourcify.dev/4663/0x0F48792eed1a8196644540E98E5b508A03cA977c) |
| [Fee Bridge](./hook-blocks/fee-bridge/README.md) | `HookrFeeBridgeFactory`, the first factory, superseded | [`0x765cdea443C1688aE7467c2241E4a9a3e636990E`](https://robin.etherscan.io/address/0x765cdea443C1688aE7467c2241E4a9a3e636990E#code) | [match](https://repo.sourcify.dev/4663/0x765cdea443C1688aE7467c2241E4a9a3e636990E) |
| [Fee Bridge](./hook-blocks/fee-bridge-v2/README.md) | `HookrFeeBridgeFactory`, keeper-run | [`0x85D2F6c536336C17B79BE740C6bbb6c7d8D9b23D`](https://robin.etherscan.io/address/0x85D2F6c536336C17B79BE740C6bbb6c7d8D9b23D#code) | [match](https://repo.sourcify.dev/4663/0x85D2F6c536336C17B79BE740C6bbb6c7d8D9b23D) |
| [Family Pinger](./hook-blocks/family-pinger/README.md) | `HookrFamilyPingerFactory` | [`0x3C78cCFB5b5328896A834a5DB96CBaD9ED10EbD1`](https://robin.etherscan.io/address/0x3C78cCFB5b5328896A834a5DB96CBaD9ED10EbD1#code) | [match](https://repo.sourcify.dev/4663/0x3C78cCFB5b5328896A834a5DB96CBaD9ED10EbD1) |

### Revenue Tokenizer

The tokenizer and its libraries, deployed on 2026-10-19 (blocks 92,671,571 to 92,671,601), and its four add-ons, deployed the same day (blocks 92,743,158 to 92,743,174). The six libraries are linked at deploy. Nothing here has an owner. The tokenizer opens its pools on `HookrRoot` and takes the release's Rules and the whole-pot Rules, the two its constructor fixed. [`revenue-tokenizer/`](./revenue-tokenizer/README.md) says what each contract does.

| Contract | Address | Sourcify |
| --- | --- | --- |
| `HookrRevenueTokenizer` | [`0xfb3c1501c727f30883cd7B36Ec380381af7412Ef`](https://robin.etherscan.io/address/0xfb3c1501c727f30883cd7B36Ec380381af7412Ef#code) | [match](https://repo.sourcify.dev/4663/0xfb3c1501c727f30883cd7B36Ec380381af7412Ef) |
| `HookrLegCollector`, created by `HookrRevenueTokenizer` in its constructor | [`0x7D79010cF29e548B55224f0cEEdAEd2275d65781`](https://robin.etherscan.io/address/0x7D79010cF29e548B55224f0cEEdAEd2275d65781#code) | [match](https://repo.sourcify.dev/4663/0x7D79010cF29e548B55224f0cEEdAEd2275d65781) |
| `HookrPositionNftDoorFactory`, created by `HookrRevenueTokenizer` in its constructor | [`0x4A0211091376cAA2032d899ebB633a0D9FC65dFc`](https://robin.etherscan.io/address/0x4A0211091376cAA2032d899ebB633a0D9FC65dFc#code) | [match](https://repo.sourcify.dev/4663/0x4A0211091376cAA2032d899ebB633a0D9FC65dFc) |
| `HookrV3PositionNftDoorFactory`, created by `HookrRevenueTokenizer` in its constructor | [`0xd9df572D99f08fBaAEecbF2aBafD70084Ffa558f`](https://robin.etherscan.io/address/0xd9df572D99f08fBaAEecbF2aBafD70084Ffa558f#code) | [match](https://repo.sourcify.dev/4663/0xd9df572D99f08fBaAEecbF2aBafD70084Ffa558f) |
| `HookrDropBoxDeployer` | [`0xdD61c33DB3a3e2fC00b4566a12561d1De2696ea8`](https://robin.etherscan.io/address/0xdD61c33DB3a3e2fC00b4566a12561d1De2696ea8#code) | [match](https://repo.sourcify.dev/4663/0xdD61c33DB3a3e2fC00b4566a12561d1De2696ea8) |
| `HookrRevenueTokenDeployer` | [`0x63b3A6bf73C82D24F704632b2CbBe4BC0A4475D7`](https://robin.etherscan.io/address/0x63b3A6bf73C82D24F704632b2CbBe4BC0A4475D7#code) | [match](https://repo.sourcify.dev/4663/0x63b3A6bf73C82D24F704632b2CbBe4BC0A4475D7) |
| `HookrRevenueDoorDeployer` | [`0xFeAD2B2601248Ab18573E7B8E5CDE0A21D00511B`](https://robin.etherscan.io/address/0xFeAD2B2601248Ab18573E7B8E5CDE0A21D00511B#code) | [match](https://repo.sourcify.dev/4663/0xFeAD2B2601248Ab18573E7B8E5CDE0A21D00511B) |
| `HookrRevenueMarketOpener` | [`0x09EEef9Ee9E079C82315d675709ff1528Da6DD79`](https://robin.etherscan.io/address/0x09EEef9Ee9E079C82315d675709ff1528Da6DD79#code) | [match](https://repo.sourcify.dev/4663/0x09EEef9Ee9E079C82315d675709ff1528Da6DD79) |
| `HookrRevenueStreams` | [`0x0F493ddd01221075229AC3f03abeAAE8f5429b7B`](https://robin.etherscan.io/address/0x0F493ddd01221075229AC3f03abeAAE8f5429b7B#code) | [match](https://repo.sourcify.dev/4663/0x0F493ddd01221075229AC3f03abeAAE8f5429b7B) |
| `HookrV3DoorFactoryDeployer` | [`0x759Af627c50e82ce0b50AD6A5780fa6047CdCFa6`](https://robin.etherscan.io/address/0x759Af627c50e82ce0b50AD6A5780fa6047CdCFa6#code) | [match](https://repo.sourcify.dev/4663/0x759Af627c50e82ce0b50AD6A5780fa6047CdCFa6) |
| `HookrPonsAdapterFactory` | [`0xca16D264750BDd79004B80e265F9D3d0992957d2`](https://robin.etherscan.io/address/0xca16D264750BDd79004B80e265F9D3d0992957d2#code) | [match](https://repo.sourcify.dev/4663/0xca16D264750BDd79004B80e265F9D3d0992957d2) |
| `HookrTimeSharesFactory`, add-on | [`0x07bDc86Ce9E0aD55344A3DBDEc7c1571D2c0380b`](https://robin.etherscan.io/address/0x07bDc86Ce9E0aD55344A3DBDEc7c1571D2c0380b#code) | [match](https://repo.sourcify.dev/4663/0x07bDc86Ce9E0aD55344A3DBDEc7c1571D2c0380b) |
| `HookrTimeShareWrapperFactory`, add-on | [`0x1082A41130F3088812e784Cbd1e5046a528a7449`](https://robin.etherscan.io/address/0x1082A41130F3088812e784Cbd1e5046a528a7449#code) | [match](https://repo.sourcify.dev/4663/0x1082A41130F3088812e784Cbd1e5046a528a7449) |
| `HookrRevenueCompounderFactory`, add-on | [`0xF32205941a11Ac428Be079773B3Ea583E55BC764`](https://robin.etherscan.io/address/0xF32205941a11Ac428Be079773B3Ea583E55BC764#code) | [match](https://repo.sourcify.dev/4663/0xF32205941a11Ac428Be079773B3Ea583E55BC764) |
| `HookrCompounderLens`, add-on | [`0xE6a08A2056aa617aCF669d96646dd91700D38bcB`](https://robin.etherscan.io/address/0xE6a08A2056aa617aCF669d96646dd91700D38bcB#code) | [match](https://repo.sourcify.dev/4663/0xE6a08A2056aa617aCF669d96646dd91700D38bcB) |
| `HookrDopplerAdapterFactory`, add-on | [`0xA863D22772efC34E5E331AbfAb9a1B126C1b5663`](https://robin.etherscan.io/address/0xA863D22772efC34E5E331AbfAb9a1B126C1b5663#code) | [match](https://repo.sourcify.dev/4663/0xA863D22772efC34E5E331AbfAb9a1B126C1b5663) |

### Revenue Tokenizer v2

The second tokenizer, its leg collector, its six libraries, its door factories, its state view and the two halves of its revenue token's code, deployed on 2026-10-24 (blocks 96,932,339 to 96,932,399). The libraries are linked at deploy. Nothing here has an owner. The first tokenizer and everything it made are unchanged. [`revenue-tokenizer-v2/`](./revenue-tokenizer-v2/README.md) says what each contract does.

| Contract | Address | Sourcify |
| --- | --- | --- |
| `HookrRevenueTokenizer` | [`0xAD0F7575F6476d5a37a4aBAF109Dd7f84089B90c`](https://robin.etherscan.io/address/0xAD0F7575F6476d5a37a4aBAF109Dd7f84089B90c#code) | [match](https://repo.sourcify.dev/4663/0xAD0F7575F6476d5a37a4aBAF109Dd7f84089B90c) |
| `HookrLegCollector`, created by `HookrRevenueTokenizer` in its constructor | [`0xAb5cBbC2C5b98F9b9E8f800eaa735E49C7f7A625`](https://robin.etherscan.io/address/0xAb5cBbC2C5b98F9b9E8f800eaa735E49C7f7A625#code) | [match](https://repo.sourcify.dev/4663/0xAb5cBbC2C5b98F9b9E8f800eaa735E49C7f7A625) |
| `HookrRevenueStreams` | [`0x8AF409136d1C6F036F47638EeaDA3AE7f3Fad490`](https://robin.etherscan.io/address/0x8AF409136d1C6F036F47638EeaDA3AE7f3Fad490#code) | [match](https://repo.sourcify.dev/4663/0x8AF409136d1C6F036F47638EeaDA3AE7f3Fad490) |
| `HookrRevenueMarketOpener` | [`0x7689cd313A0eAb4d3Fb4549D22A653D04b27cd3f`](https://robin.etherscan.io/address/0x7689cd313A0eAb4d3Fb4549D22A653D04b27cd3f#code) | [match](https://repo.sourcify.dev/4663/0x7689cd313A0eAb4d3Fb4549D22A653D04b27cd3f) |
| `HookrRevenueDoorDeployer` | [`0x122e24aF927A4E762167665A06a8f34682E86465`](https://robin.etherscan.io/address/0x122e24aF927A4E762167665A06a8f34682E86465#code) | [match](https://repo.sourcify.dev/4663/0x122e24aF927A4E762167665A06a8f34682E86465) |
| `HookrSignatures` | [`0x0A0F8bE151846B848122214Ee2F9861a828036eA`](https://robin.etherscan.io/address/0x0A0F8bE151846B848122214Ee2F9861a828036eA#code) | [match](https://repo.sourcify.dev/4663/0x0A0F8bE151846B848122214Ee2F9861a828036eA) |
| `HookrIncomeRecovery` | [`0x425c8b42502B9BA2d96b4C56e6962DCA0E3c5785`](https://robin.etherscan.io/address/0x425c8b42502B9BA2d96b4C56e6962DCA0E3c5785#code) | [match](https://repo.sourcify.dev/4663/0x425c8b42502B9BA2d96b4C56e6962DCA0E3c5785) |
| `HookrDropBoxDeployer` | [`0x25844bA027af0b25132209B58d399196E350DE22`](https://robin.etherscan.io/address/0x25844bA027af0b25132209B58d399196E350DE22#code) | [match](https://repo.sourcify.dev/4663/0x25844bA027af0b25132209B58d399196E350DE22) |
| `HookrRevenueTokenCode`, half 0 of the revenue token's code, data | [`0x99b498Aa5f073b70De35e317A8bFB1BB8386a78A`](https://robin.etherscan.io/address/0x99b498Aa5f073b70De35e317A8bFB1BB8386a78A#code) | [creation match](https://repo.sourcify.dev/4663/0x99b498Aa5f073b70De35e317A8bFB1BB8386a78A) |
| `HookrRevenueTokenCode`, half 1 of the revenue token's code, data | [`0xcccD15Ac6aA42d77874Af26b7b73DF634512d6e0`](https://robin.etherscan.io/address/0xcccD15Ac6aA42d77874Af26b7b73DF634512d6e0#code) | [creation match](https://repo.sourcify.dev/4663/0xcccD15Ac6aA42d77874Af26b7b73DF634512d6e0) |
| `HookrPositionNftDoorFactory` | [`0x78aBe03F35FD9B0D6D72aB74E1f65cB2cB3A49c1`](https://robin.etherscan.io/address/0x78aBe03F35FD9B0D6D72aB74E1f65cB2cB3A49c1#code) | [match](https://repo.sourcify.dev/4663/0x78aBe03F35FD9B0D6D72aB74E1f65cB2cB3A49c1) |
| `HookrV3PositionNftDoorFactory` | [`0xBefB5aAa1c18Cb298643421dF191BFd06bB00325`](https://robin.etherscan.io/address/0xBefB5aAa1c18Cb298643421dF191BFd06bB00325#code) | [match](https://repo.sourcify.dev/4663/0xBefB5aAa1c18Cb298643421dF191BFd06bB00325) |
| `HookrFeebAdapterFactory` | [`0x517AB33C67b7855eC0514818918eb2A857feAE4a`](https://robin.etherscan.io/address/0x517AB33C67b7855eC0514818918eb2A857feAE4a#code) | [match](https://repo.sourcify.dev/4663/0x517AB33C67b7855eC0514818918eb2A857feAE4a) |
| `HookrRevenueTokenDoorFactory` | [`0x51049eB3254B4b218fd41f5b91A7010F0Ea0B049`](https://robin.etherscan.io/address/0x51049eB3254B4b218fd41f5b91A7010F0Ea0B049#code) | [match](https://repo.sourcify.dev/4663/0x51049eB3254B4b218fd41f5b91A7010F0Ea0B049) |
| `HookrPonsAdapterFactory` | [`0x6DDDd86F71717CAFcf0CeFeeFC6E79b50775B7f0`](https://robin.etherscan.io/address/0x6DDDd86F71717CAFcf0CeFeeFC6E79b50775B7f0#code) | [match](https://repo.sourcify.dev/4663/0x6DDDd86F71717CAFcf0CeFeeFC6E79b50775B7f0) |
| `HookrDopplerAdapterFactory` | [`0xC1D50AF2FDFdD37B5B7c95A3dd5175B661bD7142`](https://robin.etherscan.io/address/0xC1D50AF2FDFdD37B5B7c95A3dd5175B661bD7142#code) | [match](https://repo.sourcify.dev/4663/0xC1D50AF2FDFdD37B5B7c95A3dd5175B661bD7142) |
| `HookrRevenueStateView` | [`0xe3280D57E4a1F9a07997E3C34499d728dc9fa275`](https://robin.etherscan.io/address/0xe3280D57E4a1F9a07997E3C34499d728dc9fa275#code) | [match](https://repo.sourcify.dev/4663/0xe3280D57E4a1F9a07997E3C34499d728dc9fa275) |

The second set of Revenue Tokenizer v2 and its add-ons, deployed on 2026-10-28 (blocks 100,179,470 to 100,179,563) and 2026-10-29 (blocks 100,475,141 to 100,475,160), from the same sources as the first set. The second set's Rules list starts with the combined core.

| Contract | Address | Sourcify |
| --- | --- | --- |
| `HookrRevenueTokenizer` | [`0x522723A7a09684515881568Ab8247f3846D66F43`](https://robin.etherscan.io/address/0x522723A7a09684515881568Ab8247f3846D66F43#code) | [match](https://repo.sourcify.dev/4663/0x522723A7a09684515881568Ab8247f3846D66F43) |
| `HookrLegCollector`, created by `HookrRevenueTokenizer` in its constructor | [`0x5a28571362d1dd512299deb80b895C72F705D8c3`](https://robin.etherscan.io/address/0x5a28571362d1dd512299deb80b895C72F705D8c3#code) | [match](https://repo.sourcify.dev/4663/0x5a28571362d1dd512299deb80b895C72F705D8c3) |
| `HookrRevenueStreams` | [`0x2303faa3322D2Ef935C3e9ab90388F9AeBFAC98f`](https://robin.etherscan.io/address/0x2303faa3322D2Ef935C3e9ab90388F9AeBFAC98f#code) | [match](https://repo.sourcify.dev/4663/0x2303faa3322D2Ef935C3e9ab90388F9AeBFAC98f) |
| `HookrRevenueMarketOpener` | [`0x3c278bd8449d127E02517f520bfBc1f3d84F3B21`](https://robin.etherscan.io/address/0x3c278bd8449d127E02517f520bfBc1f3d84F3B21#code) | [match](https://repo.sourcify.dev/4663/0x3c278bd8449d127E02517f520bfBc1f3d84F3B21) |
| `HookrRevenueDoorDeployer` | [`0x69FdAcEf9988E3e540FeADE656e7B710215510F3`](https://robin.etherscan.io/address/0x69FdAcEf9988E3e540FeADE656e7B710215510F3#code) | [match](https://repo.sourcify.dev/4663/0x69FdAcEf9988E3e540FeADE656e7B710215510F3) |
| `HookrSignatures` | [`0xCCfAc915b6070446FC387773B401924333c95240`](https://robin.etherscan.io/address/0xCCfAc915b6070446FC387773B401924333c95240#code) | [match](https://repo.sourcify.dev/4663/0xCCfAc915b6070446FC387773B401924333c95240) |
| `HookrIncomeRecovery` | [`0xA82C607A4B38C7762Ab5aD3734AB5A0b0cF5001c`](https://robin.etherscan.io/address/0xA82C607A4B38C7762Ab5aD3734AB5A0b0cF5001c#code) | [match](https://repo.sourcify.dev/4663/0xA82C607A4B38C7762Ab5aD3734AB5A0b0cF5001c) |
| `HookrDropBoxDeployer` | [`0x0c97e8EBaA43D28e94f9e6AD1c78ac134FFF145E`](https://robin.etherscan.io/address/0x0c97e8EBaA43D28e94f9e6AD1c78ac134FFF145E#code) | [match](https://repo.sourcify.dev/4663/0x0c97e8EBaA43D28e94f9e6AD1c78ac134FFF145E) |
| `HookrRevenueTokenCode`, half 0 of the revenue token's code, data | [`0x012198fFb092479c6fefd6F2C632264699954758`](https://robin.etherscan.io/address/0x012198fFb092479c6fefd6F2C632264699954758#code) | [creation match](https://repo.sourcify.dev/4663/0x012198fFb092479c6fefd6F2C632264699954758) |
| `HookrRevenueTokenCode`, half 1 of the revenue token's code, data | [`0xd5492dDC0E0f436B2AFdB2b9BDf2117063540Ef3`](https://robin.etherscan.io/address/0xd5492dDC0E0f436B2AFdB2b9BDf2117063540Ef3#code) | [creation match](https://repo.sourcify.dev/4663/0xd5492dDC0E0f436B2AFdB2b9BDf2117063540Ef3) |
| `HookrPositionNftDoorFactory` | [`0xef47D719Ed82fCE84F7538D5D77280972eC479b2`](https://robin.etherscan.io/address/0xef47D719Ed82fCE84F7538D5D77280972eC479b2#code) | [match](https://repo.sourcify.dev/4663/0xef47D719Ed82fCE84F7538D5D77280972eC479b2) |
| `HookrV3PositionNftDoorFactory` | [`0xB2E5d429CD36efacCc3B01a7C1E523319755Bf99`](https://robin.etherscan.io/address/0xB2E5d429CD36efacCc3B01a7C1E523319755Bf99#code) | [match](https://repo.sourcify.dev/4663/0xB2E5d429CD36efacCc3B01a7C1E523319755Bf99) |
| `HookrFeebAdapterFactory` | [`0xE14f2B06877A74174C210F4d5E4587cdb8F06e10`](https://robin.etherscan.io/address/0xE14f2B06877A74174C210F4d5E4587cdb8F06e10#code) | [match](https://repo.sourcify.dev/4663/0xE14f2B06877A74174C210F4d5E4587cdb8F06e10) |
| `HookrRevenueTokenDoorFactory` | [`0xCAfb37DD5e490714aEcA1597c91ca0F22D30dC57`](https://robin.etherscan.io/address/0xCAfb37DD5e490714aEcA1597c91ca0F22D30dC57#code) | [match](https://repo.sourcify.dev/4663/0xCAfb37DD5e490714aEcA1597c91ca0F22D30dC57) |
| `HookrPonsAdapterFactory` | [`0x73711e882ef4a7AACD50306EE5E7201E778d00E3`](https://robin.etherscan.io/address/0x73711e882ef4a7AACD50306EE5E7201E778d00E3#code) | [match](https://repo.sourcify.dev/4663/0x73711e882ef4a7AACD50306EE5E7201E778d00E3) |
| `HookrDopplerAdapterFactory` | [`0xFBBD8E687d223864dcF083B6778C62a70aC6BA3A`](https://robin.etherscan.io/address/0xFBBD8E687d223864dcF083B6778C62a70aC6BA3A#code) | [match](https://repo.sourcify.dev/4663/0xFBBD8E687d223864dcF083B6778C62a70aC6BA3A) |
| `HookrRevenueStateView` | [`0x007EA7554DDD113Fa441f37F1d16f66030E1B81E`](https://robin.etherscan.io/address/0x007EA7554DDD113Fa441f37F1d16f66030E1B81E#code) | [match](https://repo.sourcify.dev/4663/0x007EA7554DDD113Fa441f37F1d16f66030E1B81E) |
| `HookrTimeSharesFactory`, add-on | [`0x861e5E8f9D6a2471A1e013248265cE2cF0718dad`](https://robin.etherscan.io/address/0x861e5E8f9D6a2471A1e013248265cE2cF0718dad#code) | [match](https://repo.sourcify.dev/4663/0x861e5E8f9D6a2471A1e013248265cE2cF0718dad) |
| `HookrTimeShareWrapperFactory`, add-on | [`0x41871eef4E231b1F6d88FF0F67fb47fcC4041BC0`](https://robin.etherscan.io/address/0x41871eef4E231b1F6d88FF0F67fb47fcC4041BC0#code) | [match](https://repo.sourcify.dev/4663/0x41871eef4E231b1F6d88FF0F67fb47fcC4041BC0) |
| `HookrRevenueCompounderFactory`, add-on | [`0x3D3C0538e81E169d51693c3Ac7F0fb7d672d9e46`](https://robin.etherscan.io/address/0x3D3C0538e81E169d51693c3Ac7F0fb7d672d9e46#code) | [match](https://repo.sourcify.dev/4663/0x3D3C0538e81E169d51693c3Ac7F0fb7d672d9e46) |
| `HookrCompounderLens`, add-on | [`0x4F05627CD245b09ca021252B9463FD3a871Aa4E8`](https://robin.etherscan.io/address/0x4F05627CD245b09ca021252B9463FD3a871Aa4E8#code) | [match](https://repo.sourcify.dev/4663/0x4F05627CD245b09ca021252B9463FD3a871Aa4E8) |

The third set of Revenue Tokenizer v2 and its add-ons, deployed on 2026-11-01 (blocks 103,733,671 to 103,733,775) and 2026-11-02 (blocks 103,975,727 and 103,975,860), from the same sources as the first set. The third set's Rules list starts with core 2, and it launches through core 2's launcher. The second set's wrapper factory and compounder lens serve it too.

| Contract | Address | Sourcify |
| --- | --- | --- |
| `HookrRevenueTokenizer` | [`0xE1968Fde816b71Afc804005329A284e034019637`](https://robin.etherscan.io/address/0xE1968Fde816b71Afc804005329A284e034019637#code) | [match](https://repo.sourcify.dev/4663/0xE1968Fde816b71Afc804005329A284e034019637) |
| `HookrLegCollector`, created by `HookrRevenueTokenizer` in its constructor | [`0x6Cefe8cB2814E28eA1124b4e0ba330bc4d6c7315`](https://robin.etherscan.io/address/0x6Cefe8cB2814E28eA1124b4e0ba330bc4d6c7315#code) | [match](https://repo.sourcify.dev/4663/0x6Cefe8cB2814E28eA1124b4e0ba330bc4d6c7315) |
| `HookrRevenueStreams` | [`0x17Bef8C291D278b3f9266320C588E8aa24387f97`](https://robin.etherscan.io/address/0x17Bef8C291D278b3f9266320C588E8aa24387f97#code) | [match](https://repo.sourcify.dev/4663/0x17Bef8C291D278b3f9266320C588E8aa24387f97) |
| `HookrRevenueMarketOpener` | [`0x5D47E722a0A3fE84bf912D97cd69c60845461556`](https://robin.etherscan.io/address/0x5D47E722a0A3fE84bf912D97cd69c60845461556#code) | [match](https://repo.sourcify.dev/4663/0x5D47E722a0A3fE84bf912D97cd69c60845461556) |
| `HookrRevenueDoorDeployer` | [`0x2e114D98816374126eAef89dCB66D6e25349A0e4`](https://robin.etherscan.io/address/0x2e114D98816374126eAef89dCB66D6e25349A0e4#code) | [match](https://repo.sourcify.dev/4663/0x2e114D98816374126eAef89dCB66D6e25349A0e4) |
| `HookrSignatures` | [`0x48814982d5A93A8A1A8c88181a9d1af3cdbc4CAc`](https://robin.etherscan.io/address/0x48814982d5A93A8A1A8c88181a9d1af3cdbc4CAc#code) | [match](https://repo.sourcify.dev/4663/0x48814982d5A93A8A1A8c88181a9d1af3cdbc4CAc) |
| `HookrIncomeRecovery` | [`0xf16CB3de074e4e686526f99344d98B6662A01954`](https://robin.etherscan.io/address/0xf16CB3de074e4e686526f99344d98B6662A01954#code) | [match](https://repo.sourcify.dev/4663/0xf16CB3de074e4e686526f99344d98B6662A01954) |
| `HookrDropBoxDeployer` | [`0x6F54ca89d03D73CadB61741452688D5a497F2342`](https://robin.etherscan.io/address/0x6F54ca89d03D73CadB61741452688D5a497F2342#code) | [match](https://repo.sourcify.dev/4663/0x6F54ca89d03D73CadB61741452688D5a497F2342) |
| `HookrRevenueTokenCode`, half 0 of the revenue token's code, data | [`0xA42Dba2fADAE31f7262618cF61274625d68B1e81`](https://robin.etherscan.io/address/0xA42Dba2fADAE31f7262618cF61274625d68B1e81#code) | [creation match](https://repo.sourcify.dev/4663/0xA42Dba2fADAE31f7262618cF61274625d68B1e81) |
| `HookrRevenueTokenCode`, half 1 of the revenue token's code, data | [`0x070D0Dc1D2a7b462643E413BC2583de8C80580DC`](https://robin.etherscan.io/address/0x070D0Dc1D2a7b462643E413BC2583de8C80580DC#code) | [creation match](https://repo.sourcify.dev/4663/0x070D0Dc1D2a7b462643E413BC2583de8C80580DC) |
| `HookrPositionNftDoorFactory` | [`0x587e98fE9B3937466eEdE5f15C5bd9576df3800F`](https://robin.etherscan.io/address/0x587e98fE9B3937466eEdE5f15C5bd9576df3800F#code) | [match](https://repo.sourcify.dev/4663/0x587e98fE9B3937466eEdE5f15C5bd9576df3800F) |
| `HookrV3PositionNftDoorFactory` | [`0xbaaF5726fB927aa7e61e8865a31C3183579c2F50`](https://robin.etherscan.io/address/0xbaaF5726fB927aa7e61e8865a31C3183579c2F50#code) | [match](https://repo.sourcify.dev/4663/0xbaaF5726fB927aa7e61e8865a31C3183579c2F50) |
| `HookrFeebAdapterFactory` | [`0x4E8763114B90aE4d323bE56849FE069d3898EF68`](https://robin.etherscan.io/address/0x4E8763114B90aE4d323bE56849FE069d3898EF68#code) | [match](https://repo.sourcify.dev/4663/0x4E8763114B90aE4d323bE56849FE069d3898EF68) |
| `HookrRevenueTokenDoorFactory` | [`0x77aC74A1e1CA904C8D90D66A9F1486Ec7301Ed6D`](https://robin.etherscan.io/address/0x77aC74A1e1CA904C8D90D66A9F1486Ec7301Ed6D#code) | [match](https://repo.sourcify.dev/4663/0x77aC74A1e1CA904C8D90D66A9F1486Ec7301Ed6D) |
| `HookrPonsAdapterFactory` | [`0x9655a9AeAD9c33032649E3a70e152d831aCeCd1a`](https://robin.etherscan.io/address/0x9655a9AeAD9c33032649E3a70e152d831aCeCd1a#code) | [match](https://repo.sourcify.dev/4663/0x9655a9AeAD9c33032649E3a70e152d831aCeCd1a) |
| `HookrDopplerAdapterFactory` | [`0x7309b6aDc24d590E19079C732be7e11eF6Ba485F`](https://robin.etherscan.io/address/0x7309b6aDc24d590E19079C732be7e11eF6Ba485F#code) | [match](https://repo.sourcify.dev/4663/0x7309b6aDc24d590E19079C732be7e11eF6Ba485F) |
| `HookrRevenueStateView` | [`0x2Ea3546912F308438e16F1a4fdEbCc27598718C6`](https://robin.etherscan.io/address/0x2Ea3546912F308438e16F1a4fdEbCc27598718C6#code) | [match](https://repo.sourcify.dev/4663/0x2Ea3546912F308438e16F1a4fdEbCc27598718C6) |
| `HookrTimeSharesFactory`, add-on | [`0x4127C181a4b8E43806099e1B5a5EF7c22dd70785`](https://robin.etherscan.io/address/0x4127C181a4b8E43806099e1B5a5EF7c22dd70785#code) | [match](https://repo.sourcify.dev/4663/0x4127C181a4b8E43806099e1B5a5EF7c22dd70785) |
| `HookrRevenueCompounderFactory`, add-on | [`0x977E77424a69C2C3a5E48Be9a61F5a1A54650bf8`](https://robin.etherscan.io/address/0x977E77424a69C2C3a5E48Be9a61F5a1A54650bf8#code) | [match](https://repo.sourcify.dev/4663/0x977E77424a69C2C3a5E48Be9a61F5a1A54650bf8) |

### Combined core and own hooks

The combined core, deployed on 2026-10-26 (blocks 98,419,467 to 98,419,487), and owned-root factory v2 with lane v2, its code stores, two swap modules and the redeployed LP Boost, deployed on 2026-10-28 (blocks 100,433,558 to 100,433,591). The core's constructor also creates eight brake keys, one per Hook Block; [`combined-core/`](./combined-core/README.md#the-core) lists them, and like the other contracts made in a constructor without a role of their own, they are not counted in the 190. [`combined-core/`](./combined-core/README.md) says what each contract does.

| Contract | Address | Sourcify |
| --- | --- | --- |
| `HookrRules`, the core | [`0x8AD0aC66DbeBcc047e8d216666C925E797e5e52e`](https://robin.etherscan.io/address/0x8AD0aC66DbeBcc047e8d216666C925E797e5e52e#code) | [match](https://repo.sourcify.dev/4663/0x8AD0aC66DbeBcc047e8d216666C925E797e5e52e) |
| `HookrRecapture` | [`0x1172a3cC44ce8E8E3F1f0e58a9A0E9678b7118f8`](https://robin.etherscan.io/address/0x1172a3cC44ce8E8E3F1f0e58a9A0E9678b7118f8#code) | [match](https://repo.sourcify.dev/4663/0x1172a3cC44ce8E8E3F1f0e58a9A0E9678b7118f8) |
| `HookrCoreBlocks` | [`0xFA66c713bb10298B47E0afC43389212F279E8245`](https://robin.etherscan.io/address/0xFA66c713bb10298B47E0afC43389212F279E8245#code) | [match](https://repo.sourcify.dev/4663/0xFA66c713bb10298B47E0afC43389212F279E8245) |
| `HookrLimitBlocks` | [`0xc42E47679dd06DDcC07acc72ca710f6E60ACC3A9`](https://robin.etherscan.io/address/0xc42E47679dd06DDcC07acc72ca710f6E60ACC3A9#code) | [match](https://repo.sourcify.dev/4663/0xc42E47679dd06DDcC07acc72ca710f6E60ACC3A9) |
| `HookrBinder` | [`0xe5FCbB899C95B4c7cd3afFfd1f4EB093138870A2`](https://robin.etherscan.io/address/0xe5FCbB899C95B4c7cd3afFfd1f4EB093138870A2#code) | [match](https://repo.sourcify.dev/4663/0xe5FCbB899C95B4c7cd3afFfd1f4EB093138870A2) |
| `HookrClaims` | [`0x8D0583b408e2959FA0450c54F749C1A4Dad3d335`](https://robin.etherscan.io/address/0x8D0583b408e2959FA0450c54F749C1A4Dad3d335#code) | [match](https://repo.sourcify.dev/4663/0x8D0583b408e2959FA0450c54F749C1A4Dad3d335) |
| `HookrViewSwap` | [`0x844faE4347517180bf4656b67E4BFc27D194693F`](https://robin.etherscan.io/address/0x844faE4347517180bf4656b67E4BFc27D194693F#code) | [match](https://repo.sourcify.dev/4663/0x844faE4347517180bf4656b67E4BFc27D194693F) |
| `HookrOwnedRootFactoryV2`, factory v2 | [`0x4888f030F9D789Bf71F45B275dA7A7812036dE7e`](https://robin.etherscan.io/address/0x4888f030F9D789Bf71F45B275dA7A7812036dE7e#code) | [match](https://repo.sourcify.dev/4663/0x4888f030F9D789Bf71F45B275dA7A7812036dE7e) |
| `HookrLane`, lane v2 | [`0xa83007AB66cF977132c58F5a138E1e92A005Fff3`](https://robin.etherscan.io/address/0xa83007AB66cF977132c58F5a138E1e92A005Fff3#code) | [match](https://repo.sourcify.dev/4663/0xa83007AB66cF977132c58F5a138E1e92A005Fff3) |
| `HookrCodeStore`, root v2's creation code, data | [`0xB41EB84679855602522ecd0093ff6343EB3ceEc4`](https://robin.etherscan.io/address/0xB41EB84679855602522ecd0093ff6343EB3ceEc4#code) | none |
| `HookrCodeStore`, half 0 of the core's creation code, data | [`0xd71167314A50589C7C8CD9Cc9C81939f5DDDb190`](https://robin.etherscan.io/address/0xd71167314A50589C7C8CD9Cc9C81939f5DDDb190#code) | [creation match](https://repo.sourcify.dev/4663/0xd71167314A50589C7C8CD9Cc9C81939f5DDDb190) |
| `HookrCodeStore`, half 1 of the core's creation code, data | [`0xe4731fFC8a0A0C10213C872F5c17b3f895A82a83`](https://robin.etherscan.io/address/0xe4731fFC8a0A0C10213C872F5c17b3f895A82a83#code) | none |
| `HookrRamsesV3Fill`, swap module | [`0x446e409484dE756662f2C238c9bDECB9f50f5B8F`](https://robin.etherscan.io/address/0x446e409484dE756662f2C238c9bDECB9f50f5B8F#code) | [match](https://repo.sourcify.dev/4663/0x446e409484dE756662f2C238c9bDECB9f50f5B8F) |
| `HookrPonsCurveFill`, swap module | [`0xEa0A512dFA4D8CcaFA31E485bd189703D8BaAa27`](https://robin.etherscan.io/address/0xEa0A512dFA4D8CcaFA31E485bd189703D8BaAa27#code) | [match](https://repo.sourcify.dev/4663/0xEa0A512dFA4D8CcaFA31E485bd189703D8BaAa27) |
| `HookrLpBoost`, redeployed | [`0xa301A960716a070394826092e6fF113A156A80D1`](https://robin.etherscan.io/address/0xa301A960716a070394826092e6fF113A156A80D1#code) | [match](https://repo.sourcify.dev/4663/0xa301A960716a070394826092e6fF113A156A80D1) |

### Core 2 and its launcher

Core 2's binder and `HookrRules`, deployed on 2026-11-01 (blocks 103,412,316 and 103,412,338), with its Hook Blocks, settle library and recapture module and its launcher, token deployer, family router and family lock, deployed the same day (blocks 103,300,199 to 103,300,246). Core 2's constructor creates eight brake keys, one per Hook Block; [`core-2/`](./core-2/README.md#the-core) lists them, and they are not counted in the 190. [`core-2/`](./core-2/README.md) says what each contract does.

| Contract | Address | Sourcify |
| --- | --- | --- |
| `HookrRules`, core 2 | [`0x342bAA22e202954593b04B7eD1663621E0565d46`](https://robin.etherscan.io/address/0x342bAA22e202954593b04B7eD1663621E0565d46#code) | [match](https://repo.sourcify.dev/4663/0x342bAA22e202954593b04B7eD1663621E0565d46) |
| `HookrBinder` | [`0x0B0f08c381ed6902FAb74b470fe7f8A58E8EA269`](https://robin.etherscan.io/address/0x0B0f08c381ed6902FAb74b470fe7f8A58E8EA269#code) | [match](https://repo.sourcify.dev/4663/0x0B0f08c381ed6902FAb74b470fe7f8A58E8EA269) |
| `HookrCoreBlocks` | [`0xdA360B744F8C816acbb97fF65cC4Cd81e27Df375`](https://robin.etherscan.io/address/0xdA360B744F8C816acbb97fF65cC4Cd81e27Df375#code) | [match](https://repo.sourcify.dev/4663/0xdA360B744F8C816acbb97fF65cC4Cd81e27Df375) |
| `HookrCoreSettle` | [`0x7E169f0c49Db67F1a4f6f3c48A69B2e244b85191`](https://robin.etherscan.io/address/0x7E169f0c49Db67F1a4f6f3c48A69B2e244b85191#code) | [match](https://repo.sourcify.dev/4663/0x7E169f0c49Db67F1a4f6f3c48A69B2e244b85191) |
| `HookrRecapture` | [`0x97D440593912234b78432A030fb5186BD2A3Bc86`](https://robin.etherscan.io/address/0x97D440593912234b78432A030fb5186BD2A3Bc86#code) | [match](https://repo.sourcify.dev/4663/0x97D440593912234b78432A030fb5186BD2A3Bc86) |
| `HookrLauncher` | [`0x70a66ADF39B5c9FfEE4A9F081C182edfbb7DBD0C`](https://robin.etherscan.io/address/0x70a66ADF39B5c9FfEE4A9F081C182edfbb7DBD0C#code) | [match](https://repo.sourcify.dev/4663/0x70a66ADF39B5c9FfEE4A9F081C182edfbb7DBD0C) |
| `HookrTokenDeployer` | [`0xE703F2Cd21A8dEE05dbC81b693201D602772B2d8`](https://robin.etherscan.io/address/0xE703F2Cd21A8dEE05dbC81b693201D602772B2d8#code) | [match](https://repo.sourcify.dev/4663/0xE703F2Cd21A8dEE05dbC81b693201D602772B2d8) |
| `HookrFamilyRouter` | [`0xbc56F48f873841d26a5a02575263d82f68e12864`](https://robin.etherscan.io/address/0xbc56F48f873841d26a5a02575263d82f68e12864#code) | [match](https://repo.sourcify.dev/4663/0xbc56F48f873841d26a5a02575263d82f68e12864) |
| `HookrFamilyLock` | [`0x5248AF9139DaDEf0C5296342b7BE441deDf0adC2`](https://robin.etherscan.io/address/0x5248AF9139DaDEf0C5296342b7BE441deDf0adC2#code) | [match](https://repo.sourcify.dev/4663/0x5248AF9139DaDEf0C5296342b7BE441deDf0adC2) |

### Agent gate

Deployed on 2026-10-31 (block 102,144,809) and admitted on the registry as an advisory. [`agent-gate/`](./agent-gate/README.md) says what it does.

| Contract | Address | Sourcify |
| --- | --- | --- |
| `HookrAgentGate` | [`0x3b1aC66a6Fd9e9d8F063d145003cf29eac4Fb0C9`](https://robin.etherscan.io/address/0x3b1aC66a6Fd9e9d8F063d145003cf29eac4Fb0C9#code) | [match](https://repo.sourcify.dev/4663/0x3b1aC66a6Fd9e9d8F063d145003cf29eac4Fb0C9) |

## Arbitrum One

The release is being deployed on Arbitrum One (chain id 42161) from release id `hookr-1`, artifact packet `0x71f067cb9b9b34d639b8d708fc4e675cde415a08f6f196f600bfc02b5a936d8e`, by the same deployer through the same CREATE3 factory at `0xc7c662Fc760FE1d5cB97fd8A68cb43A046da3F7d` with the same salts, so every contract lands at its 4663 address. Its 35 contracts compile from the same sources and settings as on 4663, file for file: the packet's metadata names the same source units with the same keccak256 for each. The bootstrap, 18 transactions from `0x0c0967485A25F18E70262a2Ee80c7595CC64a5fC` (nonces 2 to 19), landed on 2026-11-04 between blocks 521,168,780 and 521,168,929; the constructors of `HookrRoot`, `HookrRules` and `HookrPrograms` created the other four. The rest of the release follows in later stages, and the record gains each contract once it has code.

[`deployments/arbitrum-42161.json`](./deployments/arbitrum-42161.json) lists the 22 with code at block 521,189,124, its `checkedAtBlock`, with their Arbitrum constructor arguments and creation transactions. Rebuilt from the files here, each one's runtime is the code at its address byte for byte, immutables aside, and each one's creation code followed by its constructor arguments is the code its creation transaction ran. On Sourcify, 14 are exact matches on chain 42161, 1 is a partial match and 7 are not verified yet.

| Contract | Address | Runtime keccak256 | Sourcify (42161) |
| --- | --- | --- | --- |
| `HookrFamilyLock` | [`0xfAFEcE64099C1E791C4B46189c277f00c0c7e00b`](https://arbiscan.io/address/0xfAFEcE64099C1E791C4B46189c277f00c0c7e00b#code) | `0xae39388f136afcaaced649814fef1453eb6d3a6e923a3480cb6daf1a729aa6ab` | [partial match](https://repo.sourcify.dev/42161/0xfAFEcE64099C1E791C4B46189c277f00c0c7e00b), see below |
| `HookrFamilyRouter` | [`0x854f3Fa7AC342B244DF0d9A8c8F597b051aAE559`](https://arbiscan.io/address/0x854f3Fa7AC342B244DF0d9A8c8F597b051aAE559#code) | `0x69b3f314b03e0c92f7ebab02bdc7ab693e45aba48bd84cd2d5e0ee19ab438f27` | [exact match](https://repo.sourcify.dev/42161/0x854f3Fa7AC342B244DF0d9A8c8F597b051aAE559) |
| `HookrForwarder` | [`0xe7863CC0E2Fb783b44c279aB159bcD812c2ceA1c`](https://arbiscan.io/address/0xe7863CC0E2Fb783b44c279aB159bcD812c2ceA1c#code) | `0x3242bd3dea1be9c1ffd17b23475f2d1d11fb5ee9cdbe8328b309b7adb8427043` | [exact match](https://repo.sourcify.dev/42161/0xe7863CC0E2Fb783b44c279aB159bcD812c2ceA1c) |
| `HookrLane` | [`0x9A8a1006469BA196f8FEfc017a53505C83A060BB`](https://arbiscan.io/address/0x9A8a1006469BA196f8FEfc017a53505C83A060BB#code) | `0xfb985b31a354c5312b56ecac000e8fec0b8682ff5299234b0a092a601b7486f2` | not yet |
| `HookrLaunchChecks` | [`0x8567369a70100828611BB6F44ec051B48F10fb59`](https://arbiscan.io/address/0x8567369a70100828611BB6F44ec051B48F10fb59#code) | `0xb9f17232100ac1ac05e9b662e916abad854f650156c67585bde7e99237d3cfca` | not yet |
| `HookrLauncher` | [`0x1cf2748A6670572425eAbf9Ab9e5BC4eb2eB8Ef4`](https://arbiscan.io/address/0x1cf2748A6670572425eAbf9Ab9e5BC4eb2eB8Ef4#code) | `0xd165631c5f10ef5941f22f17b2299c728f2f65d1c0807f3ab2ec0fb8a1958f19` | [exact match](https://repo.sourcify.dev/42161/0x1cf2748A6670572425eAbf9Ab9e5BC4eb2eB8Ef4) |
| `HookrMilestoneNFTFactory` | [`0xa340F964F1E685c681dC3ABB5B0405E608914d00`](https://arbiscan.io/address/0xa340F964F1E685c681dC3ABB5B0405E608914d00#code) | `0xd4930c97722e023cb7465e2579e6de6f56c9dcd290b44896d7c0f5bb38439832` | [exact match](https://repo.sourcify.dev/42161/0xa340F964F1E685c681dC3ABB5B0405E608914d00) |
| `HookrProgramValidator` | [`0x33e0249083Be7Cd8bD2fe175E0671AcfD0516850`](https://arbiscan.io/address/0x33e0249083Be7Cd8bD2fe175E0671AcfD0516850#code) | `0x24b9f397b14b775f539bcf1be5ac73aafd3c72b0512efccfd7102434524c23ba` | [exact match](https://repo.sourcify.dev/42161/0x33e0249083Be7Cd8bD2fe175E0671AcfD0516850) |
| `HookrPrograms` | [`0x9fA204AC99176782Fd20615b2b2A516D1F8C328F`](https://arbiscan.io/address/0x9fA204AC99176782Fd20615b2b2A516D1F8C328F#code) | `0x10c706f5c9888366e52152c93cb43297c0c82e7f6a5061906243602865886d49` | [exact match](https://repo.sourcify.dev/42161/0x9fA204AC99176782Fd20615b2b2A516D1F8C328F) |
| `HookrProgramsAdmin` | [`0x40B40D65543E70a9C757eda1A2208517a8BC7292`](https://arbiscan.io/address/0x40B40D65543E70a9C757eda1A2208517a8BC7292#code) | `0x02a9506376ad14aa01690fb8a2087a408e65a44c7c519f8fb01ca0511832e222` | not yet |
| `HookrQuoter` | [`0x445D7891381Aa7F91F5048EdBC6a611ccBDe7865`](https://arbiscan.io/address/0x445D7891381Aa7F91F5048EdBC6a611ccBDe7865#code) | `0x70e40aa6bddfb338334403e25b4a0f0e5c7f56d88557ed1343247cec5a29a64c` | [exact match](https://repo.sourcify.dev/42161/0x445D7891381Aa7F91F5048EdBC6a611ccBDe7865) |
| `HookrRecapture` | [`0xF83569E564d70daebc35950f66a73f2e2B915583`](https://arbiscan.io/address/0xF83569E564d70daebc35950f66a73f2e2B915583#code) | `0x02e30cbd1806c7567a4f6a3691503fa28487d66daa91d4d942d920d705f806ff` | [exact match](https://repo.sourcify.dev/42161/0xF83569E564d70daebc35950f66a73f2e2B915583) |
| `HookrReferralDistributor` | [`0x690539c53212899A9c6AEEE3b4B6737A5c4851d9`](https://arbiscan.io/address/0x690539c53212899A9c6AEEE3b4B6737A5c4851d9#code) | `0x66b72c0818a51f1f22b8d7e2c053e02606dc170754917d6fbd815fc42701ba9d` | [exact match](https://repo.sourcify.dev/42161/0x690539c53212899A9c6AEEE3b4B6737A5c4851d9) |
| `HookrReferralRegistry` | [`0xefD1DfBA80c06E72F793601706c3a1c71aab3057`](https://arbiscan.io/address/0xefD1DfBA80c06E72F793601706c3a1c71aab3057#code) | `0xa46ba192f532e5a5cedf2fd1b60ea074073960084f7635a3aa31065d52d8c603` | [exact match](https://repo.sourcify.dev/42161/0xefD1DfBA80c06E72F793601706c3a1c71aab3057) |
| `HookrRegistry` | [`0x463c82beA1a52F4Cc05ca0741a24F0AD24bA4602`](https://arbiscan.io/address/0x463c82beA1a52F4Cc05ca0741a24F0AD24bA4602#code) | `0x081b9ef680ea8490f09060c4a66ed93910c415ad432ec50252ef0df19009afcc` | [exact match](https://repo.sourcify.dev/42161/0x463c82beA1a52F4Cc05ca0741a24F0AD24bA4602) |
| `HookrRegistryAdmin` | [`0x675ac2102E8c69E2467F64656E3c235AF3901Ac1`](https://arbiscan.io/address/0x675ac2102E8c69E2467F64656E3c235AF3901Ac1#code) | `0x070ba14bedd7b9c3c259998af44032ace80a49dc5d741d604fa1b82fd7737abc` | not yet |
| `HookrRegistryChecks` | [`0xB9F5c54E5Cc7ac6c7a96335E5A334Cf4eA496E98`](https://arbiscan.io/address/0xB9F5c54E5Cc7ac6c7a96335E5A334Cf4eA496E98#code) | `0xbf12974a6e59bc744e8d29bf9308c888e97e562693324dca7e8bdf20e0f81349` | [exact match](https://repo.sourcify.dev/42161/0xB9F5c54E5Cc7ac6c7a96335E5A334Cf4eA496E98) |
| `HookrRoot` | [`0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc`](https://arbiscan.io/address/0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc#code) | `0x3b7fec54142e45ad619fad2261c6cea50db0bb0030950612cd90b701b271c943` | [exact match](https://repo.sourcify.dev/42161/0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc) |
| `HookrRouter` | [`0xC2Bc9a3fe6c4Ce8C2F7EB4655b0869b01D8c93C9`](https://arbiscan.io/address/0xC2Bc9a3fe6c4Ce8C2F7EB4655b0869b01D8c93C9#code) | `0xcacf310fb3a49d51be434c1a9cfc93a46cf92167ca90750c60794ca9fc78e79f` | not yet |
| `HookrRules` | [`0x4a71c270b1520F94064268102AebD744b0DE7942`](https://arbiscan.io/address/0x4a71c270b1520F94064268102AebD744b0DE7942#code) | `0x7d71630d3ee4d9c3d5ad8e2f33141906f46e3948047b3d52b8e6ce2ca0f4c68a` | not yet |
| `HookrTokenDeployer` | [`0x1B23D6d7beBcB61E39317E9F0Bc02AEB91aFCcAe`](https://arbiscan.io/address/0x1B23D6d7beBcB61E39317E9F0Bc02AEB91aFCcAe#code) | `0x724642470fbeef5a98a04b009376e10af722b96f932d992b256e412c4ea989b5` | not yet |
| `HookrTreasury` | [`0x2242F7FC75606500503075f29ea8cDA684EfB4a9`](https://arbiscan.io/address/0x2242F7FC75606500503075f29ea8cDA684EfB4a9#code) | `0x42a775d16e8a7b07809a6c67cca48a9403a2c2710c5f3dfd2dc4f2ecee72a3b9` | [exact match](https://repo.sourcify.dev/42161/0x2242F7FC75606500503075f29ea8cDA684EfB4a9) |

`HookrFamilyLock`'s partial match on chain 42161 was made from another contract's sources: core 2's family lock `0x5248AF9139DaDEf0C5296342b7BE441deDf0adC2`, which compiles to the same bytes but for the metadata hash. The release's sources here give its runtime exactly, metadata hash included.

The same checks as on 4663, with `--chain 42161`:

```sh
node hookr-1/standard-input.mjs --chain 42161 0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc > root.json
solc-0.8.37 --standard-json root.json > root.out.json
cast code 0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc --rpc-url <an Arbitrum One node> > root.hex
node hookr-1/check-runtime.mjs --chain 42161 0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc root.out.json root.hex
```

## Building

The release compiles with solc 0.8.37 (`0.8.37+commit.f401782d`), via-IR, the optimizer at 200 runs, EVM version prague, and the IPFS metadata hash. The official binaries hash to `a27396e7732aa52e80ff89ad7bd8a2e46fec2a6dcc4ef20cd16e5e0c502d6821` (macOS amd64) and `5de843c2c93563cc66425c99a4fb13fdbf32b4c4ae07469480faaf126e14404a` (Linux amd64). The dependencies are the submodules in `lib/`: v4-core at `46c6834698c48bc4a463a86d8420f4eb1d7f3b75`, with its own OpenZeppelin and solmate pins, and forge-std at `c179529c064588ede54a0661ec3cc98219460d07`.

```sh
git submodule update --init --recursive
```

### Byte for byte

The verified metadata records each source by the path it had in the release's build tree: `src/...` for the release, `../hookr-phase-one/src/...` for a release file a Hook Block imports, and `../../../contracts/lib/...` for a dependency. The connectors were built from the Family Pinger's folder, so their metadata also names `../zap-mesh/src/...`, `../fee-bridge/src/...` and `../zap-relay/src/...`, the folders beside it in `hook-blocks/`. The Revenue Tokenizer's add-ons were built from folders beside the tokenizer's, so their metadata names its sources `../fee-tokenizer/src/...`; [`revenue-tokenizer/`](./revenue-tokenizer/README.md#where-the-files-are) has the mapping. Revenue Tokenizer v2 was built from a folder of its own, so its `src/...` names are the files in [`revenue-tokenizer-v2/src/`](./revenue-tokenizer-v2/README.md#where-the-files-are), and it compiles with the optimizer at 50 runs instead of 200; its add-ons name its files `../hookrevenue-v2/src/...`. Core 2 was built from two trees, the core's and the launcher's, and the Agent gate names the release's files `../hookr-phase-one/src/...`; [`core-2/`](./core-2/README.md#where-the-files-are) and [`agent-gate/`](./agent-gate/README.md#where-the-files-are) have the mapping. The combined core was built from four trees, each with its own `src/...` and its own depth of `../contracts/lib/...`, and lane v2's tree records the dependencies under an absolute path, which the record writes as `<build-root>` and `standard-input.mjs` takes as a second argument; [`combined-core/`](./combined-core/README.md#where-the-files-are) has the mapping. Those paths are part of the metadata hash in the deployed code. `standard-input.mjs` rebuilds a contract's compiler input with those exact names, reading each file from where it sits here:

```sh
node hookr-1/standard-input.mjs --list
node hookr-1/standard-input.mjs 0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc > root.json
solc-0.8.37 --standard-json root.json > root.out.json
```

The deployed bytecode in the output, with the linked libraries filled in, equals the code on chain everywhere except the immutables, which the constructor writes. That holds for all 181 contracts in the record's list, the metadata hash included. The six halves of Revenue Tokenizer v2's revenue token code are listed under its tokenizers as data contracts, and the combined core's three code stores under factory v2, with root v2 as its template: [`combined-core/check-code-stores.mjs`](./combined-core/README.md#building-it) checks the stores; [`revenue-tokenizer-v2/check-token-code.mjs`](./revenue-tokenizer-v2/README.md#building-it) checks them.

### Against the chain

`check-runtime.mjs` fills in the linked libraries from the record, takes only the immutables from the chain code, at the offsets solc reports for them, and requires every other byte to be equal:

```sh
cast code 0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc > root.hex   # with ETH_RPC_URL set to a chain 4663 node
node hookr-1/check-runtime.mjs 0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc root.out.json root.hex
```

It prints `MATCH` or `MISMATCH` and the first differing byte. To check all 181 in the list, with `BUILD_ROOT` set to the build root lane v2 needs ([`combined-core/`](./combined-core/README.md#where-the-files-are)); every other contract ignores it:

```sh
for a in $(node hookr-1/standard-input.mjs --list | cut -d' ' -f1); do
  node hookr-1/standard-input.mjs $a "$BUILD_ROOT" > in.json
  solc-0.8.37 --standard-json in.json > out.json
  cast code $a > chain.hex
  node hookr-1/check-runtime.mjs $a out.json chain.hex
done
```

### With Forge

From the repository root:

```sh
forge build --root hookr-1
```

This builds the release from the same files with the same settings. Its metadata records this repository's paths instead of the build tree's, so the metadata hashes differ from the deployed code's; the rest of each contract matches. Four contracts embed another contract's creation code (`HookrFamilyLock`, `HookrMilestoneNFTFactory`, `HookrRootFactory` and `HookrTokenDeployer`), and the embedded metadata hash differs too.

That command also compiles the tests in [`test/`](./test/README.md), which takes about 20 minutes and more than 20 GB of memory. To build the release alone, run `forge build src` from `hookr-1/`; its output for every release contract is the same.

## Status

Hookr 1 is deployed and its sources are verified. No independent audit of Hookr 1 has been completed.
