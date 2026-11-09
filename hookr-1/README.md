# Release `hookr-1`

`HookrRoot` at [`0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc`](https://robin.etherscan.io/address/0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc#code) is Hookr's shared Uniswap v4 hook on Robinhood Chain (chain id 4663). New pools on hookr.fun bind the core, `HookrRules` at [`0x342bAA22e202954593b04B7eD1663621E0565d46`](https://robin.etherscan.io/address/0x342bAA22e202954593b04B7eD1663621E0565d46#code), which the [README](../README.md#deployments) lists. This folder holds the core, described in [`core-2/`](./core-2/README.md), the release it runs on, and the release's own Rules, which Canonical Venue Token, lane and partner launches bind.

On the release's Rules, a creator launches a token on one to eight pools in a single transaction, each with its own quote currency, price and range, and picks each pool's rules at launch: Anti-Snipe, Hookr dynamic fees, Auto Burn and LP Rewards, with every parameter set by the creator. The rules are frozen when the pool opens and stay that way for the life of the pool. A pool can also take King of the Pool, a pot paid to the largest buyer of each round, and arb recapture, in which What The Hook's executor trades the gap between the pool's price and its other venues and the pool keeps half of each recapture's profit. A fee right can be locked behind a revenue token, whose holders share the income the right earns. Anyone can deploy their own unmodified copy of the hook through the owned-root factory.

The shared hook's address carries its Uniswap v4 permission bits, `0x2acc`: before initialize, before add liquidity, before remove liquidity, before swap, after swap, and the before-swap and after-swap return deltas.

## What is in this folder

| Path | What it holds |
| --- | --- |
| [`src/`](./src/) | The release's sources, byte-identical to the verified sources of its 35 contracts. |
| [`foundry.toml`](./foundry.toml) | The release's compiler settings, with remappings to the pinned submodules in [`../lib/`](../lib/). |
| [`test/`](./test/README.md) | The release's unit, fuzz and invariant tests, which CI runs against `src/`. [`script/`](./script/) holds three helpers they import and [`snapshots/`](./snapshots/) the gas figures and code sizes their benches check. |
| [`king-of-the-pool-whole-pot/`](./king-of-the-pool-whole-pot/README.md) | A second Rules contract whose King of the Pool pays the round's winner the whole pot. One source file differs from the release. |
| [`wallet-cap/`](./wallet-cap/README.md) | The Wallet Cap Rules: the whole-pot Rules plus a cap on how much of a pool's token one wallet can buy while the pool's launch guard lasts. One source file is added to the whole-pot Rules' sources. |
| [`revenue-tokenizer-4/`](./revenue-tokenizer-4/README.md) | `HookrRevenueTokenizer` at `0x08De138e558a9258c6B4077E8bdeB9ad1fB46a4B`: lock fee rights and mint a fixed-supply revenue token whose holders share their income, on any Rules the registry admits, with its libraries, door factories and time shares factory, 11 contracts. Their sources are added to the release's. |
| [`core-2/`](./core-2/README.md) | The core, `HookrRules` at `0x342bAA22e202954593b04B7eD1663621E0565d46`, its binder, Hook Blocks, settle library and recapture module, 5 contracts, and its launcher, token deployer, family router and family lock, 4 contracts. The files that differ from the combined core's and the release's. |
| [`combined-core/`](./combined-core/README.md) | The combined `HookrRules` at `0x8AD0aC66DbeBcc047e8d216666C925E797e5e52e`, its blocks and modules, 7 contracts; owned-root factory v2 with its three code stores, lane v2, two swap modules and the redeployed LP Boost, 5 contracts; and root v2, which the factory builds per own hook. |
| [`agent-gate/`](./agent-gate/README.md) | The Agent gate, `HookrAgentGate` at `0xF95e6c8eEdA88b4D8Dfd43A087D153059A5107b0`: an advisory that makes a pool agents-only. |
| [`revenue-tokenizer-v2/`](./revenue-tokenizer-v2/README.md) | The sources of the eight contracts the revenue tokenizer reuses: the revenue token's code and its three libraries, the Pons and Long door factories and the time shares wrapper factory. |
| [`hook-blocks/`](./hook-blocks/README.md) | The 46 Hook Block contracts deployed in production waves 0 to 3, the Vesting Milestone and Pay Later factories built for the core's launcher, 3 contracts, and the 7 contracts of the three HookrBook connectors, one folder per block or connector. |
| [`revenue-tokenizer/`](./revenue-tokenizer/), [`agent-gate-1/`](./agent-gate-1/) | Sources of contracts on [PREVIOUS_RELEASES.md](../PREVIOUS_RELEASES.md). |
| [`deployments/robinhood-4663.json`](./deployments/robinhood-4663.json) | Every one of the 196 contracts: address, deployment, constructor arguments, linked libraries, runtime keccak256, compiler settings, and the file in this repository behind every source unit of its verified metadata. |
| [`standard-input.mjs`](./standard-input.mjs) | Writes any of those contracts' solc standard JSON input from the files here. |
| [`check-runtime.mjs`](./check-runtime.mjs) | Compares a contract's solc output with the code at its address, byte for byte. |

## Deployed contracts

The contracts whose sources are in this folder, all deployed on Robinhood Chain (chain id 4663): the release's 35, the 2 of King of the Pool whole pot, the 2 of Wallet Cap, the 9 of the core and its launcher, the 12 of the combined core and own hooks, the Agent gate, the 49 of the Hook Blocks, the 7 of the HookrBook connectors, the 11 of the revenue tokenizer and 6 of the 8 contracts it reuses (the other 2 are data contracts the record lists under the entry they were deployed with), and 62 entries that belong to contracts on [PREVIOUS_RELEASES.md](../PREVIOUS_RELEASES.md), 196 in all.

Release id `hookr-1`, built from artifact packet `0x83962c12ff55df431612ffae8bfc66a30041eb310035cfc30eab1bb9bdc0e031`. Every contract the release deploys itself goes through the CREATE3 factory at `0xc7c662Fc760FE1d5cB97fd8A68cb43A046da3F7d`, with a salt the factory binds to the deployer and derives from the release id and the contract's role, so nobody else can occupy these addresses. The King of the Pool whole-pot `HookrRules`, `HookrRulesWalletCap`, the 9 of the core and its launcher, the 12 of the combined core and own hooks, 39 of the Hook Block contracts, 4 of the connector contracts, 10 of the revenue tokenizer's contracts and the 6 it reuses go through the same factory. The Agent gate is a plain CREATE from `0xC87AC3AD8d2270e9A66f8369f03B7CF197e7B72F`. Every other contract is created by another contract in this list in its constructor, as noted. The record gives the deployment of each of the 62 other entries. Every address below is an exact match on Sourcify, except the data contracts the tables mark as data, and its runtime code hashes to the value in the record.

### Hook and rules

| Contract | Address | Sourcify | What it does |
| --- | --- | --- | --- |
| `HookrRoot` | [`0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc`](https://robin.etherscan.io/address/0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc#code) | [match](https://repo.sourcify.dev/4663/0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc) | Hookr's shared Uniswap v4 hook. Freezes each pool's terms when the pool opens. |
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

Deployed on 2026-10-12 (block 87,010,819). The registry revoked their admission on the root on 2026-11-06 (block 107,365,907), so no new pool can bind them; the pools already on them keep them. [`wallet-cap/`](./wallet-cap/README.md) has the cap's rules and what differs from the release.

| Contract | Address | Sourcify |
| --- | --- | --- |
| `HookrRecapture`, created by `HookrRulesWalletCap` in its constructor | [`0xbbC43DC2f01F5E7882caCd78EF094A44eF0E4d23`](https://robin.etherscan.io/address/0xbbC43DC2f01F5E7882caCd78EF094A44eF0E4d23#code) | [match](https://repo.sourcify.dev/4663/0xbbC43DC2f01F5E7882caCd78EF094A44eF0E4d23) |
| `HookrRulesWalletCap` | [`0xb67b73E28C522a3AAC438bE970bf94976Deee52a`](https://robin.etherscan.io/address/0xb67b73E28C522a3AAC438bE970bf94976Deee52a#code) | [match](https://repo.sourcify.dev/4663/0xb67b73E28C522a3AAC438bE970bf94976Deee52a) |

### The core and its launcher

The core's binder and the core, the `HookrRules` new pools on hookr.fun bind, were deployed on 2026-11-01 (blocks 103,412,316 and 103,412,338). Its Hook Blocks, settle library and recapture module, and its launcher, token deployer, family router and family lock, were deployed the same day (blocks 103,300,199 to 103,300,246). The core also uses the combined core's `HookrClaims`, `HookrLimitBlocks` and `HookrViewSwap`, below. Its constructor creates eight brake keys, one per Hook Block; [`core-2/`](./core-2/README.md#the-core) lists them, and the record files them under the core's entry, so they are not counted in the 196. [`core-2/`](./core-2/README.md) says what each contract does.

| Contract | Address | Sourcify |
| --- | --- | --- |
| `HookrRules`, the core | [`0x342bAA22e202954593b04B7eD1663621E0565d46`](https://robin.etherscan.io/address/0x342bAA22e202954593b04B7eD1663621E0565d46#code) | [match](https://repo.sourcify.dev/4663/0x342bAA22e202954593b04B7eD1663621E0565d46) |
| `HookrBinder` | [`0x0B0f08c381ed6902FAb74b470fe7f8A58E8EA269`](https://robin.etherscan.io/address/0x0B0f08c381ed6902FAb74b470fe7f8A58E8EA269#code) | [match](https://repo.sourcify.dev/4663/0x0B0f08c381ed6902FAb74b470fe7f8A58E8EA269) |
| `HookrCoreBlocks` | [`0xdA360B744F8C816acbb97fF65cC4Cd81e27Df375`](https://robin.etherscan.io/address/0xdA360B744F8C816acbb97fF65cC4Cd81e27Df375#code) | [match](https://repo.sourcify.dev/4663/0xdA360B744F8C816acbb97fF65cC4Cd81e27Df375) |
| `HookrCoreSettle` | [`0x7E169f0c49Db67F1a4f6f3c48A69B2e244b85191`](https://robin.etherscan.io/address/0x7E169f0c49Db67F1a4f6f3c48A69B2e244b85191#code) | [match](https://repo.sourcify.dev/4663/0x7E169f0c49Db67F1a4f6f3c48A69B2e244b85191) |
| `HookrRecapture` | [`0x97D440593912234b78432A030fb5186BD2A3Bc86`](https://robin.etherscan.io/address/0x97D440593912234b78432A030fb5186BD2A3Bc86#code) | [match](https://repo.sourcify.dev/4663/0x97D440593912234b78432A030fb5186BD2A3Bc86) |
| `HookrLauncher` | [`0x70a66ADF39B5c9FfEE4A9F081C182edfbb7DBD0C`](https://robin.etherscan.io/address/0x70a66ADF39B5c9FfEE4A9F081C182edfbb7DBD0C#code) | [match](https://repo.sourcify.dev/4663/0x70a66ADF39B5c9FfEE4A9F081C182edfbb7DBD0C) |
| `HookrTokenDeployer` | [`0xE703F2Cd21A8dEE05dbC81b693201D602772B2d8`](https://robin.etherscan.io/address/0xE703F2Cd21A8dEE05dbC81b693201D602772B2d8#code) | [match](https://repo.sourcify.dev/4663/0xE703F2Cd21A8dEE05dbC81b693201D602772B2d8) |
| `HookrFamilyRouter` | [`0xbc56F48f873841d26a5a02575263d82f68e12864`](https://robin.etherscan.io/address/0xbc56F48f873841d26a5a02575263d82f68e12864#code) | [match](https://repo.sourcify.dev/4663/0xbc56F48f873841d26a5a02575263d82f68e12864) |
| `HookrFamilyLock` | [`0x5248AF9139DaDEf0C5296342b7BE441deDf0adC2`](https://robin.etherscan.io/address/0x5248AF9139DaDEf0C5296342b7BE441deDf0adC2#code) | [match](https://repo.sourcify.dev/4663/0x5248AF9139DaDEf0C5296342b7BE441deDf0adC2) |

### Combined core and own hooks

The combined `HookrRules`, its blocks and modules were deployed on 2026-10-26 (blocks 98,419,467 to 98,419,487). Own hooks copy the combined `HookrRules`, and the pools bound to it keep it. Owned-root factory v2, lane v2, the code stores, two swap modules and the redeployed LP Boost were deployed on 2026-10-28 (blocks 100,433,558 to 100,433,591). The combined core's constructor creates eight brake keys, one per Hook Block; [`combined-core/`](./combined-core/README.md#the-core) lists them, and they are not counted in the 196. The three code stores are data, held to the sources by [`combined-core/check-code-stores.mjs`](./combined-core/README.md#the-code-stores), and not counted either. [`combined-core/`](./combined-core/README.md) says what each contract does.

| Contract | Address | Sourcify |
| --- | --- | --- |
| `HookrRules`, combined | [`0x8AD0aC66DbeBcc047e8d216666C925E797e5e52e`](https://robin.etherscan.io/address/0x8AD0aC66DbeBcc047e8d216666C925E797e5e52e#code) | [match](https://repo.sourcify.dev/4663/0x8AD0aC66DbeBcc047e8d216666C925E797e5e52e) |
| `HookrRecapture` | [`0x1172a3cC44ce8E8E3F1f0e58a9A0E9678b7118f8`](https://robin.etherscan.io/address/0x1172a3cC44ce8E8E3F1f0e58a9A0E9678b7118f8#code) | [match](https://repo.sourcify.dev/4663/0x1172a3cC44ce8E8E3F1f0e58a9A0E9678b7118f8) |
| `HookrCoreBlocks` | [`0xFA66c713bb10298B47E0afC43389212F279E8245`](https://robin.etherscan.io/address/0xFA66c713bb10298B47E0afC43389212F279E8245#code) | [match](https://repo.sourcify.dev/4663/0xFA66c713bb10298B47E0afC43389212F279E8245) |
| `HookrLimitBlocks` | [`0xc42E47679dd06DDcC07acc72ca710f6E60ACC3A9`](https://robin.etherscan.io/address/0xc42E47679dd06DDcC07acc72ca710f6E60ACC3A9#code) | [match](https://repo.sourcify.dev/4663/0xc42E47679dd06DDcC07acc72ca710f6E60ACC3A9) |
| `HookrBinder` | [`0xe5FCbB899C95B4c7cd3afFfd1f4EB093138870A2`](https://robin.etherscan.io/address/0xe5FCbB899C95B4c7cd3afFfd1f4EB093138870A2#code) | [match](https://repo.sourcify.dev/4663/0xe5FCbB899C95B4c7cd3afFfd1f4EB093138870A2) |
| `HookrClaims` | [`0x8D0583b408e2959FA0450c54F749C1A4Dad3d335`](https://robin.etherscan.io/address/0x8D0583b408e2959FA0450c54F749C1A4Dad3d335#code) | [match](https://repo.sourcify.dev/4663/0x8D0583b408e2959FA0450c54F749C1A4Dad3d335) |
| `HookrViewSwap` | [`0x844faE4347517180bf4656b67E4BFc27D194693F`](https://robin.etherscan.io/address/0x844faE4347517180bf4656b67E4BFc27D194693F#code) | [match](https://repo.sourcify.dev/4663/0x844faE4347517180bf4656b67E4BFc27D194693F) |
| `HookrOwnedRootFactoryV2`, factory v2 | [`0x4888f030F9D789Bf71F45B275dA7A7812036dE7e`](https://robin.etherscan.io/address/0x4888f030F9D789Bf71F45B275dA7A7812036dE7e#code) | [match](https://repo.sourcify.dev/4663/0x4888f030F9D789Bf71F45B275dA7A7812036dE7e) |
| `HookrLane`, lane v2 | [`0xa83007AB66cF977132c58F5a138E1e92A005Fff3`](https://robin.etherscan.io/address/0xa83007AB66cF977132c58F5a138E1e92A005Fff3#code) | [match](https://repo.sourcify.dev/4663/0xa83007AB66cF977132c58F5a138E1e92A005Fff3) |
| `HookrRamsesV3Fill`, swap module | [`0x446e409484dE756662f2C238c9bDECB9f50f5B8F`](https://robin.etherscan.io/address/0x446e409484dE756662f2C238c9bDECB9f50f5B8F#code) | [match](https://repo.sourcify.dev/4663/0x446e409484dE756662f2C238c9bDECB9f50f5B8F) |
| `HookrPonsCurveFill`, swap module | [`0xEa0A512dFA4D8CcaFA31E485bd189703D8BaAa27`](https://robin.etherscan.io/address/0xEa0A512dFA4D8CcaFA31E485bd189703D8BaAa27#code) | [match](https://repo.sourcify.dev/4663/0xEa0A512dFA4D8CcaFA31E485bd189703D8BaAa27) |
| `HookrLpBoost`, redeployed | [`0xa301A960716a070394826092e6fF113A156A80D1`](https://robin.etherscan.io/address/0xa301A960716a070394826092e6fF113A156A80D1#code) | [match](https://repo.sourcify.dev/4663/0xa301A960716a070394826092e6fF113A156A80D1) |
| `HookrCodeStore`, root v2's creation code, data | [`0xB41EB84679855602522ecd0093ff6343EB3ceEc4`](https://robin.etherscan.io/address/0xB41EB84679855602522ecd0093ff6343EB3ceEc4#code) | none |
| `HookrCodeStore`, half 0 of the core's creation code, data | [`0xd71167314A50589C7C8CD9Cc9C81939f5DDDb190`](https://robin.etherscan.io/address/0xd71167314A50589C7C8CD9Cc9C81939f5DDDb190#code) | [creation match](https://repo.sourcify.dev/4663/0xd71167314A50589C7C8CD9Cc9C81939f5DDDb190) |
| `HookrCodeStore`, half 1 of the core's creation code, data | [`0xe4731fFC8a0A0C10213C872F5c17b3f895A82a83`](https://robin.etherscan.io/address/0xe4731fFC8a0A0C10213C872F5c17b3f895A82a83#code) | none |

### Agent gate

Deployed on 2026-11-06 (block 107,220,906) and admitted on the registry as an advisory (block 107,250,878). [`agent-gate/`](./agent-gate/README.md) says what it does.

| Contract | Address | Sourcify |
| --- | --- | --- |
| `HookrAgentGate` | [`0xF95e6c8eEdA88b4D8Dfd43A087D153059A5107b0`](https://robin.etherscan.io/address/0xF95e6c8eEdA88b4D8Dfd43A087D153059A5107b0#code) | [match](https://repo.sourcify.dev/4663/0xF95e6c8eEdA88b4D8Dfd43A087D153059A5107b0) |

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

### Vesting Milestone and Pay Later for the core's launcher

A Vesting Milestone or Pay Later factory takes only the pools of the launcher it was built with. These were built for the core's `HookrLauncher` `0x70a66ADF39B5c9FfEE4A9F081C182edfbb7DBD0C` and deployed on 2026-11-06 (blocks 107,263,825 and 107,263,866), from the same creation code as the wave 0 and wave 1 factories above, with that launcher as the first constructor argument and salt counter 1. [`hook-blocks/vesting-milestone/`](./hook-blocks/vesting-milestone/README.md) and [`hook-blocks/pay-later/`](./hook-blocks/pay-later/README.md) say what they do.

| Contract | Address | Sourcify |
| --- | --- | --- |
| `HookrVestingMilestoneFactory` | [`0xCBe4Fa6Ca5f14Ed30435524dc9629DC1719DbCB0`](https://robin.etherscan.io/address/0xCBe4Fa6Ca5f14Ed30435524dc9629DC1719DbCB0#code) | [match](https://repo.sourcify.dev/4663/0xCBe4Fa6Ca5f14Ed30435524dc9629DC1719DbCB0) |
| `PayLaterFactory` | [`0xFc3e9e435C79e1712CF949C6ea921fA165cadEf3`](https://robin.etherscan.io/address/0xFc3e9e435C79e1712CF949C6ea921fA165cadEf3#code) | [match](https://repo.sourcify.dev/4663/0xFc3e9e435C79e1712CF949C6ea921fA165cadEf3) |
| `PayLaterVaultDeployer`, created by `PayLaterFactory` in its constructor | [`0xd9129fDA63E427399f055f7DE0Af19A605BE89Fc`](https://robin.etherscan.io/address/0xd9129fDA63E427399f055f7DE0Af19A605BE89Fc#code) | [match](https://repo.sourcify.dev/4663/0xd9129fDA63E427399f055f7DE0Af19A605BE89Fc) |

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

### Revenue tokenizer

The tokenizer, its libraries, door factories, state view and time shares factory were deployed on 2026-11-06 (blocks 107,699,158 to 107,699,953). Three libraries are linked at deploy. Nothing here has an owner. The tokenizer opens its pools on `HookrRoot` and takes any Rules `HookrRegistry` admits there. [`revenue-tokenizer-4/`](./revenue-tokenizer-4/README.md) says what each contract does and which parts it reuses.

| Contract | Address | Sourcify |
| --- | --- | --- |
| `HookrRevenueTokenizer` | [`0x08De138e558a9258c6B4077E8bdeB9ad1fB46a4B`](https://robin.etherscan.io/address/0x08De138e558a9258c6B4077E8bdeB9ad1fB46a4B#code) | [match](https://repo.sourcify.dev/4663/0x08De138e558a9258c6B4077E8bdeB9ad1fB46a4B) |
| `HookrLegCollector`, created by `HookrRevenueTokenizer` in its constructor | [`0x2b8dd989D34256b7685E3Bd8F10299A4891F1Af2`](https://robin.etherscan.io/address/0x2b8dd989D34256b7685E3Bd8F10299A4891F1Af2#code) | [match](https://repo.sourcify.dev/4663/0x2b8dd989D34256b7685E3Bd8F10299A4891F1Af2) |
| `HookrRevenueStateView` | [`0x83B8F1650a22b7da9Fac45A09F51e0685C47E944`](https://robin.etherscan.io/address/0x83B8F1650a22b7da9Fac45A09F51e0685C47E944#code) | [match](https://repo.sourcify.dev/4663/0x83B8F1650a22b7da9Fac45A09F51e0685C47E944) |
| `HookrRevenueStreams` | [`0x2DB0Bfd85F233D09Da55835e08cBe7A68b6AFEb9`](https://robin.etherscan.io/address/0x2DB0Bfd85F233D09Da55835e08cBe7A68b6AFEb9#code) | [match](https://repo.sourcify.dev/4663/0x2DB0Bfd85F233D09Da55835e08cBe7A68b6AFEb9) |
| `HookrRevenueMarketOpener` | [`0x2fE3B06A5827E0ADec5a407308aDe2C3801b7366`](https://robin.etherscan.io/address/0x2fE3B06A5827E0ADec5a407308aDe2C3801b7366#code) | [match](https://repo.sourcify.dev/4663/0x2fE3B06A5827E0ADec5a407308aDe2C3801b7366) |
| `HookrRevenueDoorDeployer` | [`0xC4Df7F66c5e55316a545E4d78b2c6a5449088bb3`](https://robin.etherscan.io/address/0xC4Df7F66c5e55316a545E4d78b2c6a5449088bb3#code) | [match](https://repo.sourcify.dev/4663/0xC4Df7F66c5e55316a545E4d78b2c6a5449088bb3) |
| `HookrPositionNftDoorFactory` | [`0x29fB09eC8bb27299710040a894fEaF82d7341772`](https://robin.etherscan.io/address/0x29fB09eC8bb27299710040a894fEaF82d7341772#code) | [match](https://repo.sourcify.dev/4663/0x29fB09eC8bb27299710040a894fEaF82d7341772) |
| `HookrV3PositionNftDoorFactory` | [`0xBA5b0171f77F28D9381FA0ED96B6BB1412D8Ce1e`](https://robin.etherscan.io/address/0xBA5b0171f77F28D9381FA0ED96B6BB1412D8Ce1e#code) | [match](https://repo.sourcify.dev/4663/0xBA5b0171f77F28D9381FA0ED96B6BB1412D8Ce1e) |
| `HookrFeebAdapterFactory` | [`0xb6D6C144deca5D5ef59C8Fcf3E657C50883e67B9`](https://robin.etherscan.io/address/0xb6D6C144deca5D5ef59C8Fcf3E657C50883e67B9#code) | [match](https://repo.sourcify.dev/4663/0xb6D6C144deca5D5ef59C8Fcf3E657C50883e67B9) |
| `HookrRevenueTokenDoorFactory` | [`0x85644897Adc52d3270b35C649CAE69989f8C583d`](https://robin.etherscan.io/address/0x85644897Adc52d3270b35C649CAE69989f8C583d#code) | [match](https://repo.sourcify.dev/4663/0x85644897Adc52d3270b35C649CAE69989f8C583d) |
| `HookrTimeSharesFactory`, add-on | [`0x05fDb5654e1D52593Ee774cae964717d5834dF1B`](https://robin.etherscan.io/address/0x05fDb5654e1D52593Ee774cae964717d5834dF1B#code) | [match](https://repo.sourcify.dev/4663/0x05fDb5654e1D52593Ee774cae964717d5834dF1B) |

It reuses eight contracts deployed before it, built from the sources in [`revenue-tokenizer-v2/`](./revenue-tokenizer-v2/README.md#what-the-revenue-tokenizer-uses-from-here), which says what each does:

| Contract | Address | Sourcify |
| --- | --- | --- |
| `HookrSignatures` | [`0x48814982d5A93A8A1A8c88181a9d1af3cdbc4CAc`](https://robin.etherscan.io/address/0x48814982d5A93A8A1A8c88181a9d1af3cdbc4CAc#code) | [match](https://repo.sourcify.dev/4663/0x48814982d5A93A8A1A8c88181a9d1af3cdbc4CAc) |
| `HookrIncomeRecovery` | [`0xf16CB3de074e4e686526f99344d98B6662A01954`](https://robin.etherscan.io/address/0xf16CB3de074e4e686526f99344d98B6662A01954#code) | [match](https://repo.sourcify.dev/4663/0xf16CB3de074e4e686526f99344d98B6662A01954) |
| `HookrDropBoxDeployer` | [`0x6F54ca89d03D73CadB61741452688D5a497F2342`](https://robin.etherscan.io/address/0x6F54ca89d03D73CadB61741452688D5a497F2342#code) | [match](https://repo.sourcify.dev/4663/0x6F54ca89d03D73CadB61741452688D5a497F2342) |
| `HookrRevenueTokenCode.0`, data | [`0xA42Dba2fADAE31f7262618cF61274625d68B1e81`](https://robin.etherscan.io/address/0xA42Dba2fADAE31f7262618cF61274625d68B1e81#code) | [creation match](https://repo.sourcify.dev/4663/0xA42Dba2fADAE31f7262618cF61274625d68B1e81) |
| `HookrRevenueTokenCode.1`, data | [`0x070D0Dc1D2a7b462643E413BC2583de8C80580DC`](https://robin.etherscan.io/address/0x070D0Dc1D2a7b462643E413BC2583de8C80580DC#code) | [creation match](https://repo.sourcify.dev/4663/0x070D0Dc1D2a7b462643E413BC2583de8C80580DC) |
| `HookrPonsAdapterFactory` | [`0x9655a9AeAD9c33032649E3a70e152d831aCeCd1a`](https://robin.etherscan.io/address/0x9655a9AeAD9c33032649E3a70e152d831aCeCd1a#code) | [match](https://repo.sourcify.dev/4663/0x9655a9AeAD9c33032649E3a70e152d831aCeCd1a) |
| `HookrDopplerAdapterFactory` | [`0x7309b6aDc24d590E19079C732be7e11eF6Ba485F`](https://robin.etherscan.io/address/0x7309b6aDc24d590E19079C732be7e11eF6Ba485F#code) | [match](https://repo.sourcify.dev/4663/0x7309b6aDc24d590E19079C732be7e11eF6Ba485F) |
| `HookrTimeShareWrapperFactory` | [`0x41871eef4E231b1F6d88FF0F67fb47fcC4041BC0`](https://robin.etherscan.io/address/0x41871eef4E231b1F6d88FF0F67fb47fcC4041BC0#code) | [match](https://repo.sourcify.dev/4663/0x41871eef4E231b1F6d88FF0F67fb47fcC4041BC0) |

### Other entries in the record

The record's other 62 entries, with their sources here, belong to contracts on [PREVIOUS_RELEASES.md](../PREVIOUS_RELEASES.md).

## Building

The release compiles with solc 0.8.37 (`0.8.37+commit.f401782d`), via-IR, the optimizer at 200 runs, EVM version prague, and the IPFS metadata hash. The official binaries hash to `a27396e7732aa52e80ff89ad7bd8a2e46fec2a6dcc4ef20cd16e5e0c502d6821` (macOS amd64) and `5de843c2c93563cc66425c99a4fb13fdbf32b4c4ae07469480faaf126e14404a` (Linux amd64). The dependencies are the submodules in `lib/`: v4-core at `46c6834698c48bc4a463a86d8420f4eb1d7f3b75`, with its own OpenZeppelin and solmate pins, and forge-std at `c179529c064588ede54a0661ec3cc98219460d07`.

```sh
git submodule update --init --recursive
```

### Byte for byte

The verified metadata records each source by the path it had in the release's build tree: `src/...` for the release, `../hookr-phase-one/src/...` for a release file a Hook Block imports, and `../../../contracts/lib/...` for a dependency. The connectors were built from the Family Pinger's folder, so their metadata also names `../zap-mesh/src/...`, `../fee-bridge/src/...` and `../zap-relay/src/...`, the folders beside it in `hook-blocks/`. The add-ons in `revenue-tokenizer/` were built from folders beside their tokenizer's, so their metadata names its sources `../fee-tokenizer/src/...`; [`revenue-tokenizer/`](./revenue-tokenizer/README.md#where-the-files-are) has the mapping. The revenue tokenizer's time shares factory names its sources `../hookrevenue-v2/src/...`; [`revenue-tokenizer-4/`](./revenue-tokenizer-4/README.md#where-the-files-are) has the mapping. The contracts in [`revenue-tokenizer-v2/`](./revenue-tokenizer-v2/README.md#where-the-files-are) were built from a folder of their own, with the optimizer at 50 runs for the tokenizer sets. The core was built from two trees, the core's and the launcher's, and the Agent gate names the release's files `lib/hookr-phase-one/src/...`; [`core-2/`](./core-2/README.md#where-the-files-are) and [`agent-gate/`](./agent-gate/README.md#where-the-files-are) have the mapping. The combined core was built from four trees, each with its own `src/...` and its own depth of `../contracts/lib/...`, and lane v2's tree records the dependencies under an absolute path, which the record writes as `<build-root>` and `standard-input.mjs` takes as a second argument, read from the remappings of lane v2's verified metadata on Sourcify; [`combined-core/`](./combined-core/README.md#where-the-files-are) has the mapping. Those paths are part of the metadata hash in the deployed code. `standard-input.mjs` rebuilds a contract's compiler input with those exact names, reading each file from where it sits here:

```sh
node hookr-1/standard-input.mjs --list
node hookr-1/standard-input.mjs 0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc > root.json
solc-0.8.37 --standard-json root.json > root.out.json
```

The deployed bytecode in the output, with the linked libraries filled in, equals the code on chain everywhere except the immutables, which the constructor writes. That holds for all 196 contracts in the record's list, the metadata hash included. The data contracts listed under their contracts, code that other contracts read, are checked against the sources here by the scripts beside them: [`combined-core/check-code-stores.mjs`](./combined-core/check-code-stores.mjs), [`revenue-tokenizer-v2/check-token-code.mjs`](./revenue-tokenizer-v2/check-token-code.mjs), the two `check-time-shares-code.mjs` and [`revenue-tokenizer/check-code-chunks.mjs`](./revenue-tokenizer/check-code-chunks.mjs).

### Against the chain

`check-runtime.mjs` fills in the linked libraries from the record, takes only the immutables from the chain code, at the offsets solc reports for them, and requires every other byte to be equal:

```sh
cast code 0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc > root.hex   # with ETH_RPC_URL set to a chain 4663 node
node hookr-1/check-runtime.mjs 0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc root.out.json root.hex
```

It prints `MATCH` or `MISMATCH` and the first differing byte. To check all 196, with `BUILD_ROOT` set to lane v2's build root (every other contract ignores it):

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

The release is deployed and its sources are verified. No independent audit has been completed.
