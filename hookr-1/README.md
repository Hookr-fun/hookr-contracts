# Hookr 1

Hookr 1 is a launchpad on Uniswap v4, live on Robinhood Chain (chain id 4663). Every Hookr 1 pool runs on one shared hook, `HookrRoot` at [`0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc`](https://robin.etherscan.io/address/0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc#code).

A creator launches a token on one to eight pools in a single transaction, each with its own quote currency, price and range, and picks each pool's rules at launch: Anti-Snipe, Hookr dynamic fees, Auto Burn and LP Rewards, with every parameter set by the creator. The rules are frozen when the pool opens and stay that way for the life of the pool. A pool can also take arb recapture, which keeps the profit of arbitrage against the pool's other venues with the pool's LPs and traders instead of leaving it to outside bots, and King of the Pool, a pot paid to the largest buyer of each round. Anyone can deploy their own unmodified copy of the hook through the owned-root factory.

The shared hook's address carries its Uniswap v4 permission bits, `0x2acc`: before initialize, before add liquidity, before remove liquidity, before swap, after swap, and the before-swap and after-swap return deltas.

## What is in this folder

| Path | What it holds |
| --- | --- |
| [`src/`](./src/) | The release's sources, byte-identical to the verified sources of its 35 contracts. |
| [`foundry.toml`](./foundry.toml) | The release's compiler settings, with remappings to the pinned submodules in [`../lib/`](../lib/). |
| [`king-of-the-pool-whole-pot/`](./king-of-the-pool-whole-pot/README.md) | A second Rules contract whose King of the Pool pays the round's winner the whole pot. One source file differs from the release. |
| [`hook-blocks/`](./hook-blocks/README.md) | The 46 Hook Block contracts deployed in production waves 0 to 3, one folder per block. |
| [`deployments/robinhood-4663.json`](./deployments/robinhood-4663.json) | Every one of the 83 contracts: address, deployment, constructor arguments, linked libraries, runtime keccak256, compiler settings, and the file in this repository behind every source unit of its verified metadata. |
| [`standard-input.mjs`](./standard-input.mjs) | Writes any of those contracts' solc standard JSON input from the files here. |
| [`check-runtime.mjs`](./check-runtime.mjs) | Compares a contract's solc output with the code at its address, byte for byte. |

## Deployed contracts

Every Hookr 1 contract in production on Robinhood Chain (chain id 4663) is listed below: the release's 35, the 2 of King of the Pool whole pot, and the 46 of the Hook Blocks, 83 in all.

Release id `hookr-1`, built from artifact packet `0x83962c12ff55df431612ffae8bfc66a30041eb310035cfc30eab1bb9bdc0e031`. Every contract the release deploys itself goes through the CREATE3 factory at `0xc7c662Fc760FE1d5cB97fd8A68cb43A046da3F7d`, with a salt the factory binds to the deployer and derives from the release id and the contract's role, so nobody else can occupy these addresses. The King of the Pool whole-pot `HookrRules` and 37 of the Hook Block contracts go through the same factory. Every other contract is created by another contract in this list in its constructor, as noted. Every address below is an exact match on Sourcify, and its runtime code hashes to the value in the record.

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

## Building

The release compiles with solc 0.8.37 (`0.8.37+commit.f401782d`), via-IR, the optimizer at 200 runs, EVM version prague, and the IPFS metadata hash. The official binaries hash to `a27396e7732aa52e80ff89ad7bd8a2e46fec2a6dcc4ef20cd16e5e0c502d6821` (macOS amd64) and `5de843c2c93563cc66425c99a4fb13fdbf32b4c4ae07469480faaf126e14404a` (Linux amd64). The dependencies are the submodules in `lib/`: v4-core at `46c6834698c48bc4a463a86d8420f4eb1d7f3b75`, with its own OpenZeppelin and solmate pins, and forge-std at `c179529c064588ede54a0661ec3cc98219460d07`.

```sh
git submodule update --init --recursive
```

### Byte for byte

The verified metadata records each source by the path it had in the release's build tree: `src/...` for the release, `../hookr-phase-one/src/...` for a release file a Hook Block imports, and `../../../contracts/lib/...` for a dependency. Those paths are part of the metadata hash in the deployed code. `standard-input.mjs` rebuilds a contract's compiler input with those exact names, reading each file from where it sits here:

```sh
node hookr-1/standard-input.mjs --list
node hookr-1/standard-input.mjs 0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc > root.json
solc-0.8.37 --standard-json root.json > root.out.json
```

The deployed bytecode in the output, with the linked libraries filled in, equals the code on chain everywhere except the immutables, which the constructor writes. That holds for all 83 contracts in the record, the metadata hash included.

### Against the chain

`check-runtime.mjs` fills in the linked libraries from the record, takes only the immutables from the chain code, at the offsets solc reports for them, and requires every other byte to be equal:

```sh
cast code 0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc > root.hex   # with ETH_RPC_URL set to a chain 4663 node
node hookr-1/check-runtime.mjs 0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc root.out.json root.hex
```

It prints `MATCH` or `MISMATCH` and the first differing byte. To check all 83:

```sh
for a in $(node hookr-1/standard-input.mjs --list | cut -d' ' -f1); do
  node hookr-1/standard-input.mjs $a > in.json
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

## Status

Hookr 1 is deployed and its sources are verified. No independent audit of Hookr 1 has been completed.
