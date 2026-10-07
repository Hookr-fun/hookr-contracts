# Hookr 1

Hookr 1 is a launchpad on Uniswap v4, live on Robinhood Chain (chain id 4663). Every Hookr 1 pool runs on one shared hook, `HookrRoot` at [`0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc`](https://robin.etherscan.io/address/0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc#code).

A creator launches a token on one to eight pools in a single transaction, each with its own quote currency, price and range, and picks each pool's rules at launch: Anti-Snipe, Hookr dynamic fees, Auto Burn and LP Rewards, with every parameter the creator's to set. The rules are frozen when the pool opens and stay that way for the life of the pool. A pool can also take arb recapture, which keeps the profit of arbitrage against the pool's other venues with the pool's LPs and traders instead of leaving it to outside bots, and King of the Pool, a pot paid to the largest buyer of each round. Anyone can deploy their own unmodified copy of the hook through the owned-root factory.

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

## Deployed contracts

Release id `hookr-1`, built from artifact packet `0x83962c12ff55df431612ffae8bfc66a30041eb310035cfc30eab1bb9bdc0e031`. Every contract the release deploys itself goes through the CREATE3 factory at `0xc7c662Fc760FE1d5cB97fd8A68cb43A046da3F7d`, with a salt the factory binds to the deployer and derives from the release id and the contract's role, so nobody else can occupy these addresses. The others are created by a release contract in its constructor, as noted. Every address below holds an exact match on Sourcify, and its runtime code hashes to the value in the record.

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

## Building

The release compiles with solc 0.8.37 (`0.8.37+commit.f401782d`), via-IR, the optimizer at 200 runs, EVM version prague, and the IPFS metadata hash. The official binaries hash to `a27396e7732aa52e80ff89ad7bd8a2e46fec2a6dcc4ef20cd16e5e0c502d6821` (macOS amd64) and `5de843c2c93563cc66425c99a4fb13fdbf32b4c4ae07469480faaf126e14404a` (Linux amd64). The dependencies are the submodules in `lib/`: v4-core at `46c6834698c48bc4a463a86d8420f4eb1d7f3b75`, with its own OpenZeppelin and solmate pins, and forge-std at `c179529c064588ede54a0661ec3cc98219460d07`.

```sh
git submodule update --init --recursive
```

**Byte for byte.** The verified metadata records each source by the path it had in the release's build tree: `src/...` for the release, `../hookr-phase-one/src/...` for a release file a Hook Block imports, and `../../../contracts/lib/...` for a dependency. Those paths are part of the metadata hash in the deployed code. `standard-input.mjs` rebuilds a contract's compiler input with those exact names, reading each file from where it sits here:

```sh
node hookr-1/standard-input.mjs --list
node hookr-1/standard-input.mjs 0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc > root.json
solc-0.8.37 --standard-json root.json > root.out.json
```

The deployed bytecode in the output, with the linked libraries filled in, equals the code on chain everywhere except the immutables, which the constructor writes. That holds for all 83 contracts in the record, the metadata hash included.

**With Forge.** From the repository root:

```sh
forge build --root hookr-1
```

This builds the release from the same files with the same settings. Its metadata records this repository's paths instead of the build tree's, so the metadata hashes differ from the deployed code's; the rest of each contract matches. Four contracts embed another contract's creation code (`HookrFamilyLock`, `HookrMilestoneNFTFactory`, `HookrRootFactory` and `HookrTokenDeployer`), and the embedded metadata hash differs too.

## Status

Hookr 1 is deployed and its sources are verified. No independent audit of Hookr 1 has been completed.
