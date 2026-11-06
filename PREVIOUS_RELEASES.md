# Previous releases

The [README](./README.md) lists the contracts Hookr runs today. This page keeps what a builder still needs about the contracts that came before them. A pool never changes its hook, so a pool opened on these contracts keeps trading on them, and nothing here can retune it.

Newest first: the first Agent gate, the revenue tokenizer on fixed Rules, the revenue tokenizer that minted tokens before 29 October 2026, the modular roots (V2), and launch generations 3, 4 and 5.

## The first Agent gate

`HookrAgentGate` at [`0x3b1aC66a6Fd9e9d8F063d145003cf29eac4Fb0C9`](https://robin.etherscan.io/address/0x3b1aC66a6Fd9e9d8F063d145003cf29eac4Fb0C9#code), an exact match on Sourcify. The pools that bound it keep it; new pools bind the Agent gate in the [README](./README.md#deployments).

## The revenue tokenizer on fixed Rules

`HookrRevenueTokenizer` at [`0x522723A7a09684515881568Ab8247f3846D66F43`](https://robin.etherscan.io/address/0x522723A7a09684515881568Ab8247f3846D66F43#code), its `HookrRevenueStateView` at [`0x007EA7554DDD113Fa441f37F1d16f66030E1B81E`](https://robin.etherscan.io/address/0x007EA7554DDD113Fa441f37F1d16f66030E1B81E#code) and its `HookrLegCollector` at [`0x5a28571362d1dd512299deb80b895C72F705D8c3`](https://robin.etherscan.io/address/0x5a28571362d1dd512299deb80b895C72F705D8c3#code), each an exact match on Sourcify. It takes the three Rules its constructor fixed and has minted no revenue tokens. New revenue tokens mint through the tokenizer in the [README](./README.md#deployments).

## Revenue tokens minted before 29 October 2026

The first `HookrRevenueTokenizer`, deployed on 2026-10-19 with four add-ons, minted them, and they keep running on it. Its 16 contracts, their sources and addresses are in [`hookr-1/revenue-tokenizer/`](./hookr-1/revenue-tokenizer/README.md). New revenue tokens mint through the tokenizer in the [README](./README.md#deployments).

## Modular roots (V2)

Two Uniswap v4 hooks on one registry, `HookrStackRegistryV2`, sharing one accounting kernel, one module, one coordinator, one router, one quoter and one treasury forwarder. Both addresses are mined so their low fourteen bits equal `0x28cc`. A pool names one root and freezes its configuration at creation.

- **The default root**, `HookrModularHookV6`, runs five rules: a surge LP fee that rises with trade size against in-range depth, a guard window on new launches, an auto-burn on exact-input buys, an in-swap LP reward and an Nth-buy pot. Uniswap's routing service allowlists it on Robinhood Chain.
- **The arb recapture root**, `HookrModularHookV6WthV5`, runs the same five rules and, on every swap of an ETH-quoted pool, asks What The Hook's executor through `HookrWthExecutorAdapterV1` to trade the pool's price gap against its other venues. Its profit splits 40% to the pool's creator, 20% to the trader, 20% to the pool's LPs, 10% to What The Hook and 10% to Hookr.

| Contract | Address | What it is |
| --- | --- | --- |
| `HookrModularHookV6` | [`0xb3cA29cF721380CEe8b8e4755F3865Ebc68Fe8cC`](https://robinhoodchain.blockscout.com/address/0xb3cA29cF721380CEe8b8e4755F3865Ebc68Fe8cC) | Default root. Kernel id `0x1be0c118b1c6520d97de31ee9f0c33069f0e715ffcdcb16c87a343752bb5be14` |
| `HookrModularHookV6WthV5` | [`0xb914f955294799de4b891bd2EA8AF628Fa1c68CC`](https://robinhoodchain.blockscout.com/address/0xb914f955294799de4b891bd2EA8AF628Fa1c68CC) | Arb recapture root. Kernel id `0xd8b6c165b82efc3b7498081f071ea4f2476e2fb9c61b2e614aba2a016f94555a` |
| `HookrStackRegistryV2` | [`0x5b7f1A117A83aaac15B0698Aa4eB9D53fE5f5BA3`](https://robinhoodchain.blockscout.com/address/0x5b7f1A117A83aaac15B0698Aa4eB9D53fE5f5BA3) | Registry: sealed root profiles, one frozen stack per pool |
| `HookrModuleCatalogV1` | [`0x6a3561d5B6305E2229F30EDF66702e8Bc4fA19D1`](https://robinhoodchain.blockscout.com/address/0x6a3561d5B6305E2229F30EDF66702e8Bc4fA19D1) | Catalog: admits module implementations |
| `HookrMarketCoordinatorV5` | [`0x53A192A3fCeE94Da77916B461E0cCa2Dd6402442`](https://robinhoodchain.blockscout.com/address/0x53A192A3fCeE94Da77916B461E0cCa2Dd6402442) | Coordinator: opens markets on both roots |
| `HookrSwapAccountingKernelV3` | [`0x530523DEcC9523dDF8A87842fFBBD24a59C7E060`](https://robinhoodchain.blockscout.com/address/0x530523DEcC9523dDF8A87842fFBBD24a59C7E060) | Kernel: the callback bodies both roots delegate to |
| `HookrNativeMechanicsBlockV2` | [`0xD700492b504ba5A72D7de28dDe11Cd7985a7F1ae`](https://robinhoodchain.blockscout.com/address/0xD700492b504ba5A72D7de28dDe11Cd7985a7F1ae) | The module that holds the five rules and their claims |
| `HookrKernelRouterV3` | [`0xf0E528c39f33F565876cbaa7e0DFaCa38Df966E9`](https://robinhoodchain.blockscout.com/address/0xf0E528c39f33F565876cbaa7e0DFaCa38Df966E9) | Router: swaps that carry an authenticated payer |
| `HookrKernelQuoterV1` | [`0x5Ba8FBbB4aB20Ff6Daf0ecDEBe3784f869BcB1B5`](https://robinhoodchain.blockscout.com/address/0x5Ba8FBbB4aB20Ff6Daf0ecDEBe3784f869BcB1B5) | Quoter: simulates a swap and reverts with the result |
| `HookrTreasuryForwarderV1` | [`0x9BB7c01571ef6e59a8834A6a89A6b024822BAf6f`](https://robinhoodchain.blockscout.com/address/0x9BB7c01571ef6e59a8834A6a89A6b024822BAf6f) | Protocol fee recipient with one owner-set target |
| `HookrWthExecutorAdapterV1` | [`0x28AF7A3645080e926a3101461e0Ec0594D42D806`](https://robinhoodchain.blockscout.com/address/0x28AF7A3645080e926a3101461e0Ec0594D42D806) | Bound once to What The Hook's executor [`0xc356cf51134e0DF02BFE880115DD8c66Ead45803`](https://robinhoodchain.blockscout.com/address/0xc356cf51134e0DF02BFE880115DD8c66Ead45803), What The Hook's contract |

The libraries linked into them, and the factory the roots were mined through:

| Contract | Linked into | Address |
| --- | --- | --- |
| `HookrNativeMechanicsCoordinatorLibV2` | the coordinator | [`0xafC0a7656DF8B1aA5A173d04612a9661C4b9c7E2`](https://robinhoodchain.blockscout.com/address/0xafC0a7656DF8B1aA5A173d04612a9661C4b9c7E2) |
| `HookrMarketCoordinatorInitialBuyLibV4` | the coordinator | [`0xE12f58f1662293B8b4fF3f0227384bD9D2a6e382`](https://robinhoodchain.blockscout.com/address/0xE12f58f1662293B8b4fF3f0227384bD9D2a6e382) |
| `HookrMarketCoordinatorTokenDeployerV3` | the coordinator | [`0x7A2821F7Ea0e4d0C5a409D479cd457d5B34F9399`](https://robinhoodchain.blockscout.com/address/0x7A2821F7Ea0e4d0C5a409D479cd457d5B34F9399) |
| `HookrMarketCoordinatorKernelReservationLibV1` | the coordinator | [`0x8C2E208eDFf0eF7535B20AE8F13dfBF71133521d`](https://robinhoodchain.blockscout.com/address/0x8C2E208eDFf0eF7535B20AE8F13dfBF71133521d) |
| `HookrStatefulSettlementLibV1` | the kernel | [`0xde7Ae40c713D5C9EC2C8e2E28810C6C7Eb791706`](https://robinhoodchain.blockscout.com/address/0xde7Ae40c713D5C9EC2C8e2E28810C6C7Eb791706) |
| `HookrModularCorrectionLibV2` | the default root | [`0xd2832D5F64C7116bE2c7B32D8c06d60023b479D8`](https://robinhoodchain.blockscout.com/address/0xd2832D5F64C7116bE2c7B32D8c06d60023b479D8) |
| `HookrModularCorrectionLibV3` | the arb recapture root; its address holds no verified source | [`0x11996B4e04571718d49454fC52830dc7fA0FF99C`](https://robinhoodchain.blockscout.com/address/0x11996B4e04571718d49454fC52830dc7fA0FF99C) |
| `HookrReleaseCreate2FactoryV1` | the factory both roots were mined through | [`0xBc54e888C1A5B71744B035DfeC5611B4DC69ccDe`](https://robinhoodchain.blockscout.com/address/0xBc54e888C1A5B71744B035DfeC5611B4DC69ccDe) |

The deployer, and the owner of the registry, catalog, coordinator and forwarder, is [`0xF4Ab4698554D5c95874986d5e956c62e5E6aB3eE`](https://robinhoodchain.blockscout.com/address/0xF4Ab4698554D5c95874986d5e956c62e5E6aB3eE).

Three arb recapture roots came before `HookrModularHookV6WthV5` on the same registry. Each was superseded by the next, and their only pools are Hookr's own canary and rehearsal pools: [`0xc7c516CD5546bCB2592Fe3f8aa91C2A4bA3768CC`](https://robinhoodchain.blockscout.com/address/0xc7c516CD5546bCB2592Fe3f8aa91C2A4bA3768CC) (first, verified on Blockscout as `HookrModularHookV6Wth`), [`0xa99902a2922014bBe2Bf2dCF15742ac5104828Cc`](https://robinhoodchain.blockscout.com/address/0xa99902a2922014bBe2Bf2dCF15742ac5104828Cc) (third) and [`0xE5429dB8f63912E632E86733905667AaEb6ea8cC`](https://robinhoodchain.blockscout.com/address/0xE5429dB8f63912E632E86733905667AaEb6ea8cC) (fourth).

### Sources

These files at the repository root belong to these roots:

- [`src/`](./src/) is a byte-for-byte copy of the 47 files their deployed code was compiled from, pinned by [`SOURCE_MANIFEST.json`](./SOURCE_MANIFEST.json) and [`STORAGE_LAYOUT.json`](./STORAGE_LAYOUT.json). A few of those files carry older names: a deployed contract inherits from them or links a library that lives in them.
- [`deployments/robinhood-4663.v2.json`](./deployments/robinhood-4663.v2.json) lists every address, with its runtime code hash, size and deployment transaction where it records them.
- [`foundry.toml`](./foundry.toml) is the build profile: Solidity 0.8.26, via-IR, the optimizer at 200 runs, `evm_version = cancun`, `bytecode_hash = ipfs`.

```sh
git submodule update --init --recursive
forge build --sizes
node check-source-manifest.mjs
node check-storage-layout.mjs
```

A build reproduces the runtime bytes, metadata trailer included, of the twelve contracts behind the default root, the arb recapture root and its adapter; each is a full match on Blockscout and an exact match on Sourcify. The three reused libraries and the CREATE2 factory were compiled with their source text in the metadata, so their trailers take `use_literal_content = true`. `HookrModularCorrectionLibV3` holds no verified source; its code matches the build up to its trailer. No independent audit of these contracts has been completed.

The full documentation of these roots is at [`docs/` in commit `5ba9dfc`](https://github.com/Hookr-fun/hookr-contracts/tree/5ba9dfc9cc3d1b463315518f17dda8bb07f48d3b/docs).

## Launch generations 3, 4 and 5

The launchers that came before the modular roots. Pools opened on them keep running, and no owner function on any of them can retune a pool after it opens.

| Generation | Launches | Launcher | Hook | Router |
| --- | --- | --- | --- | --- |
| 3 | a ten-tranche bonding curve that graduates into a locked full-range position | [`0xaAed6fab06D53311220F35421Dda5cc6D6e9d6C3`](https://robinhoodchain.blockscout.com/address/0xaAed6fab06D53311220F35421Dda5cc6D6e9d6C3) | [`0xd0005624Da88a688BcaB3DBFB4d1Cb23d32Ca0CC`](https://robinhoodchain.blockscout.com/address/0xd0005624Da88a688BcaB3DBFB4d1Cb23d32Ca0CC) | [`0x3f6E7BA9689d3c78A00d68931b7C223f51e0f21b`](https://robinhoodchain.blockscout.com/address/0x3f6E7BA9689d3c78A00d68931b7C223f51e0f21b) |
| 4 | instant launches straight into a pool, beside the curve | [`0x5Ce779D23D2e99D322004F203813389B6a426e3B`](https://robinhoodchain.blockscout.com/address/0x5Ce779D23D2e99D322004F203813389B6a426e3B) | [`0xa0F267571847Ce91318798578A1BCc77D77c28cC`](https://robinhoodchain.blockscout.com/address/0xa0F267571847Ce91318798578A1BCc77D77c28cC) | [`0x98F3A734860a89711e111cc692E8020Cac2A4fC5`](https://robinhoodchain.blockscout.com/address/0x98F3A734860a89711e111cc692E8020Cac2A4fC5) |
| 5 | instant launches quoted in ETH or HOOKR, and ETH launches through a continuous clearing auction | [`0xa043caBE645636899dDe91Cce4693C00a015e660`](https://robinhoodchain.blockscout.com/address/0xa043caBE645636899dDe91Cce4693C00a015e660) | [`0xe7c3461A4c762fF9dB4F91BeE3Cf8deAaFc2E8CC`](https://robinhoodchain.blockscout.com/address/0xe7c3461A4c762fF9dB4F91BeE3Cf8deAaFc2E8CC) | [`0x644ac2e784059e1C01F24f99DF7795aE2be06ca0`](https://robinhoodchain.blockscout.com/address/0x644ac2e784059e1C01F24f99DF7795aE2be06ca0) |

Generation 5 also has a burner at [`0x8Cee20FA000aF3266AC2cD2cBeEFbcD19D98FD89`](https://robinhoodchain.blockscout.com/address/0x8Cee20FA000aF3266AC2cD2cBeEFbcD19D98FD89) that turns collected pool fees into HOOKR and burns it. All three use the Uniswap v4 PoolManager at [`0x8366a39CC670B4001A1121B8F6A443A643e40951`](https://robinhoodchain.blockscout.com/address/0x8366a39CC670B4001A1121B8F6A443A643e40951) and HOOKR at [`0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c`](https://robinhoodchain.blockscout.com/address/0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c).

Generation 3's workspace, with its sources, tests, scripts and broadcast records, is kept whole under [`legacy/generation-3/`](./legacy/generation-3/README.md). The sources of generations 4 and 5 are not in this repository; they are verified on the explorer at the addresses above.
