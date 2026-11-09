# Hookr

Modular infrastructure for surfacing, composing and integrating custom Uniswap hooks.

`HookrRoot` is Hookr's shared Uniswap v4 hook on Robinhood Chain. A pool on it binds a Rules contract at launch and picks its Hook Blocks and their parameters. The settings freeze when the pool opens, for the life of the pool.

Arb recapture is on by default for new pools. What The Hook's executor trades the gap between a pool's price and other venues and keeps 25% of each recapture's profit. On the core, `HookrRules` at `0x342b…5d46`, Hookr takes 15%, less any integrator's slice, and the pool keeps 60%. On the other two Rules below, Hookr takes 25% and the pool keeps 50%.

## Deployments

### Robinhood Chain (4663)

| Contract | Address | What it does |
| --- | --- | --- |
| `HookrRoot` | [`0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc`](https://robin.etherscan.io/address/0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc#code) | Hookr's shared hook. Freezes each pool's terms when the pool opens. |
| `HookrRules`, the core | [`0x342bAA22e202954593b04B7eD1663621E0565d46`](https://robin.etherscan.io/address/0x342bAA22e202954593b04B7eD1663621E0565d46#code) | Rules with the Hook Blocks built in. New pools on hookr.fun bind it. |
| `HookrBinder` | [`0x0B0f08c381ed6902FAb74b470fe7f8A58E8EA269`](https://robin.etherscan.io/address/0x0B0f08c381ed6902FAb74b470fe7f8A58E8EA269#code) | The core's `bind` and `blockCall`, run in the core's storage. |
| `HookrLauncher` | [`0x70a66ADF39B5c9FfEE4A9F081C182edfbb7DBD0C`](https://robin.etherscan.io/address/0x70a66ADF39B5c9FfEE4A9F081C182edfbb7DBD0C#code) | Launches a token on one to eight pools in one transaction, bound to the core. |
| `HookrRules`, combined | [`0x8AD0aC66DbeBcc047e8d216666C925E797e5e52e`](https://robin.etherscan.io/address/0x8AD0aC66DbeBcc047e8d216666C925E797e5e52e#code) | Rules with the Hook Blocks built in. Hooks of your own bind it. |
| `HookrRules`, the release's | [`0x4a71c270b1520F94064268102AebD744b0DE7942`](https://robin.etherscan.io/address/0x4a71c270b1520F94064268102AebD744b0DE7942#code) | Canonical Venue Token, lane and partner launches bind it. |
| `HookrLane` | [`0x9A8a1006469BA196f8FEfc017a53505C83A060BB`](https://robin.etherscan.io/address/0x9A8a1006469BA196f8FEfc017a53505C83A060BB#code) | Arb recapture. Its executor is What The Hook's [`0x4B4c16681401454140a9dBca55e5c186BBE8D728`](https://robin.etherscan.io/address/0x4B4c16681401454140a9dBca55e5c186BBE8D728). |
| `HookrRegistry` | [`0x463c82beA1a52F4Cc05ca0741a24F0AD24bA4602`](https://robin.etherscan.io/address/0x463c82beA1a52F4Cc05ca0741a24F0AD24bA4602#code) | Timelocked admissions of Rules and advisories, launchers and the guardian's brake on new pools. |
| `HookrRouter` | [`0xC2Bc9a3fe6c4Ce8C2F7EB4655b0869b01D8c93C9`](https://robin.etherscan.io/address/0xC2Bc9a3fe6c4Ce8C2F7EB4655b0869b01D8c93C9#code) | Swaps on Hookr pools. |
| `HookrQuoter` | [`0x445D7891381Aa7F91F5048EdBC6a611ccBDe7865`](https://robin.etherscan.io/address/0x445D7891381Aa7F91F5048EdBC6a611ccBDe7865#code) | Quotes. |
| `HookrTreasury` | [`0x2242F7FC75606500503075f29ea8cDA684EfB4a9`](https://robin.etherscan.io/address/0x2242F7FC75606500503075f29ea8cDA684EfB4a9#code) | Collects Hookr's claims and holds the fee terms new pools bind with. |
| `HookrOwnedRootFactoryV2` | [`0x4888f030F9D789Bf71F45B275dA7A7812036dE7e`](https://robin.etherscan.io/address/0x4888f030F9D789Bf71F45B275dA7A7812036dE7e#code) | Deploys a hook of your own in one transaction. |
| `HookrVestingMilestoneFactory` | [`0xCBe4Fa6Ca5f14Ed30435524dc9629DC1719DbCB0`](https://robin.etherscan.io/address/0xCBe4Fa6Ca5f14Ed30435524dc9629DC1719DbCB0#code) | Vesting Milestone for tokens `HookrLauncher` launched. |
| `PayLaterFactory` | [`0xFc3e9e435C79e1712CF949C6ea921fA165cadEf3`](https://robin.etherscan.io/address/0xFc3e9e435C79e1712CF949C6ea921fA165cadEf3#code) | Pay Later for tokens `HookrLauncher` launched. |
| `HookrAgentGate` | [`0xF95e6c8eEdA88b4D8Dfd43A087D153059A5107b0`](https://robin.etherscan.io/address/0xF95e6c8eEdA88b4D8Dfd43A087D153059A5107b0#code) | Makes a pool agents-only. |
| `HookrRevenueTokenizer` | [`0x08De138e558a9258c6B4077E8bdeB9ad1fB46a4B`](https://robin.etherscan.io/address/0x08De138e558a9258c6B4077E8bdeB9ad1fB46a4B#code) | Locks fee rights behind a revenue token whose holders share their income. Takes any Rules `HookrRegistry` admits on `HookrRoot`. |
| `HookrRevenueStateView` | [`0x83B8F1650a22b7da9Fac45A09F51e0685C47E944`](https://robin.etherscan.io/address/0x83B8F1650a22b7da9Fac45A09F51e0685C47E944#code) | Reads a revenue token's streams. |
| `HookrLegCollector` | [`0x2b8dd989D34256b7685E3Bd8F10299A4891F1Af2`](https://robin.etherscan.io/address/0x2b8dd989D34256b7685E3Bd8F10299A4891F1Af2#code) | Takes Hookr's leg of revenue tokens and sweeps it to the treasury's target. |
| `HookrTimeSharesFactory` | [`0x05fDb5654e1D52593Ee774cae964717d5834dF1B`](https://robin.etherscan.io/address/0x05fDb5654e1D52593Ee774cae964717d5834dF1B#code) | Time shares on those revenue tokens: lock them by the day and earn each day's income. |
| `PoolManager` | [`0x8366a39CC670B4001A1121B8F6A443A643e40951`](https://robin.etherscan.io/address/0x8366a39CC670B4001A1121B8F6A443A643e40951#code) | Uniswap v4's singleton. Every Hookr pool lives in it. |

`HookrRoot` is on the allowlist of Uniswap's routing service for Robinhood Chain.

### Sources

Every contract in the table but `PoolManager` has its source in this repository, byte-identical to its verified source, and is an exact match on [Sourcify](https://sourcify.dev):

- `HookrRoot`, the release's `HookrRules`, `HookrLane`, `HookrRegistry`, `HookrRouter`, `HookrQuoter` and `HookrTreasury`: [`hookr-1/src/`](./hookr-1/src/).
- The core, `HookrBinder` and `HookrLauncher`: [`hookr-1/core-2/`](./hookr-1/core-2/README.md).
- The combined `HookrRules` and `HookrOwnedRootFactoryV2`: [`hookr-1/combined-core/`](./hookr-1/combined-core/README.md).
- `HookrVestingMilestoneFactory` and `PayLaterFactory`, built for `HookrLauncher`: [`hookr-1/hook-blocks/vesting-milestone/`](./hookr-1/hook-blocks/vesting-milestone/README.md) and [`hookr-1/hook-blocks/pay-later/`](./hookr-1/hook-blocks/pay-later/README.md).
- `HookrAgentGate`: [`hookr-1/agent-gate/`](./hookr-1/agent-gate/README.md).
- The revenue tokenizer and its time shares factory: [`hookr-1/revenue-tokenizer-4/`](./hookr-1/revenue-tokenizer-4/README.md), and the eight contracts it reuses: [`hookr-1/revenue-tokenizer-v2/`](./hookr-1/revenue-tokenizer-v2/README.md).

[`hookr-1/README.md`](./hookr-1/README.md#deployed-contracts) lists the release's other contracts and the Hook Blocks, each with its source. [`hookr-1/deployments/robinhood-4663.json`](./hookr-1/deployments/robinhood-4663.json) has the same set as JSON.

## Repository structure

```
hookr-1/
├── src/                          HookrRoot, the release's Rules, registry, launcher, router, quoter and the rest
├── core-2/                       the core, its binder, blocks and recapture module, and its launcher
├── combined-core/                the combined Rules, owned-root factory v2, lane v2 and the swap modules
├── agent-gate/                   the Agent gate
├── revenue-tokenizer-4/          the revenue tokenizer, its libraries, door factories and time shares factory
├── revenue-tokenizer-v2/         the token code, token libraries and door factories the revenue tokenizer reuses
├── hook-blocks/                  Hook Blocks and the HookrBook connectors, one folder each
├── wallet-cap/                   Wallet Cap Rules
├── king-of-the-pool-whole-pot/   King of the Pool Rules that pay the round's winner the whole pot
├── test/                         unit, fuzz and invariant tests
├── deployments/                  every address, deployment and build setting, as JSON
├── standard-input.mjs            a contract's solc input, from the files here
└── check-runtime.mjs             a build against the code on chain, byte for byte
bench/                            gas per Hook Block, measured on a fork of the chain
labs/                             templates and prototypes, by pull request
```

The contract sources under `hookr-1/` are byte-identical to the verified sources of their contracts.

## Build

Foundry, with the v4-core and forge-std submodules:

```sh
git submodule update --init --recursive
forge build --root hookr-1
forge test --root hookr-1
```

The contracts were compiled with solc 0.8.37, via-IR, the optimizer at 200 runs and EVM version prague, except the tokenizer sets in `hookr-1/revenue-tokenizer-4/` and `hookr-1/revenue-tokenizer-v2/`, which use 50 runs; their add-ons use 200. Every contract in [`hookr-1/deployments/robinhood-4663.json`](./hookr-1/deployments/robinhood-4663.json) rebuilds byte for byte, metadata hash included:

```sh
node hookr-1/standard-input.mjs <address> > in.json
solc-0.8.37 --standard-json in.json > out.json
cast code <address> > chain.hex            # with ETH_RPC_URL set to a chain 4663 node
node hookr-1/check-runtime.mjs <address> out.json chain.hex
```

[`hookr-1/README.md`](./hookr-1/README.md#building) has the details.

## Security

No independent audit has been completed. Report a vulnerability privately, as [SECURITY.md](./SECURITY.md) explains.

## Contributing

Issues and pull requests are welcome; [CONTRIBUTING.md](./CONTRIBUTING.md) explains what lands here and how to propose a Hook Block. Discussions are off, so an issue is the place for a question.

## Previous releases

[PREVIOUS_RELEASES.md](./PREVIOUS_RELEASES.md)

## License

MIT.
