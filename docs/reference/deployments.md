# Deployments

Every address on this page is live on Robinhood Chain. The Hookr addresses hold the code that `src/` in this repository compiles to; the upstream addresses are Uniswap's own deployments, and one address under the recapture root, WTH's executor, is a partner's contract that Hookr neither wrote nor can verify.

Explorer: [Robinhood Blockscout](https://robinhoodchain.blockscout.com).

## Mainnet Deployments

### Robinhood Chain: 4663

The contracts, in deployment order.

| Contract | Address |
| --- | --- |
| HookrModuleCatalogV1 | [`0x6a3561d5B6305E2229F30EDF66702e8Bc4fA19D1`](https://robinhoodchain.blockscout.com/address/0x6a3561d5B6305E2229F30EDF66702e8Bc4fA19D1) |
| HookrStackRegistryV2 | [`0x5b7f1A117A83aaac15B0698Aa4eB9D53fE5f5BA3`](https://robinhoodchain.blockscout.com/address/0x5b7f1A117A83aaac15B0698Aa4eB9D53fE5f5BA3) |
| HookrTreasuryForwarderV1 | [`0x9BB7c01571ef6e59a8834A6a89A6b024822BAf6f`](https://robinhoodchain.blockscout.com/address/0x9BB7c01571ef6e59a8834A6a89A6b024822BAf6f) |
| HookrNativeMechanicsCoordinatorLibV2 | [`0xafC0a7656DF8B1aA5A173d04612a9661C4b9c7E2`](https://robinhoodchain.blockscout.com/address/0xafC0a7656DF8B1aA5A173d04612a9661C4b9c7E2) |
| HookrMarketCoordinatorV5 | [`0x53A192A3fCeE94Da77916B461E0cCa2Dd6402442`](https://robinhoodchain.blockscout.com/address/0x53A192A3fCeE94Da77916B461E0cCa2Dd6402442) |
| HookrSwapAccountingKernelV3 | [`0x530523DEcC9523dDF8A87842fFBBD24a59C7E060`](https://robinhoodchain.blockscout.com/address/0x530523DEcC9523dDF8A87842fFBBD24a59C7E060) |
| HookrKernelRouterV3 | [`0xf0E528c39f33F565876cbaa7e0DFaCa38Df966E9`](https://robinhoodchain.blockscout.com/address/0xf0E528c39f33F565876cbaa7e0DFaCa38Df966E9) |
| HookrKernelQuoterV1 | [`0x5Ba8FBbB4aB20Ff6Daf0ecDEBe3784f869BcB1B5`](https://robinhoodchain.blockscout.com/address/0x5Ba8FBbB4aB20Ff6Daf0ecDEBe3784f869BcB1B5) |
| HookrNativeMechanicsBlockV2 | [`0xD700492b504ba5A72D7de28dDe11Cd7985a7F1ae`](https://robinhoodchain.blockscout.com/address/0xD700492b504ba5A72D7de28dDe11Cd7985a7F1ae) |
| HookrModularHookV6 | [`0xb3cA29cF721380CEe8b8e4755F3865Ebc68Fe8cC`](https://robinhoodchain.blockscout.com/address/0xb3cA29cF721380CEe8b8e4755F3865Ebc68Fe8cC) |

These are the default lineage, in deployment order; `HookrModularHookV6` is the default root. The recapture root and the two contracts around it are in their own section below. Both roots' addresses are mined by CREATE2 so their low fourteen bits equal `0x28cc`. See [Hook permissions](./hook-permissions.md).

| Root | Address | Kernel id | Uniswap routing allowlist | Uniswap hooklist |
| --- | --- | --- | --- | --- |
| Default, `HookrModularHookV6` | [`0xb3cA29cF721380CEe8b8e4755F3865Ebc68Fe8cC`](https://robinhoodchain.blockscout.com/address/0xb3cA29cF721380CEe8b8e4755F3865Ebc68Fe8cC) | `0x1be0c118b1c6520d97de31ee9f0c33069f0e715ffcdcb16c87a343752bb5be14` | yes | yes |
| Recapture, `HookrModularHookV6WthV5` | [`0xb914f955294799de4b891bd2EA8AF628Fa1c68CC`](https://robinhoodchain.blockscout.com/address/0xb914f955294799de4b891bd2EA8AF628Fa1c68CC) | `0xd8b6c165b82efc3b7498081f071ea4f2476e2fb9c61b2e614aba2a016f94555a` | no | no |

Listing status as checked on 2026-09-21. Listing is Uniswap's decision and a separate submission per root; pools on either root trade through the Universal Router and the Hookr router regardless, because both hooks accept any caller.

### Linked Libraries

`HookrMarketCoordinatorV5`, `HookrSwapAccountingKernelV3` and `HookrModularHookV6` link libraries. Each is compiled without them: the addresses below are written into the `__$…$__` placeholders in the compiled bytecode, so the deployed code carries the metadata of a library-free compilation. Three of these libraries already stood on chain holding the same runtime code, apart from the immutable each one keeps for its own address, and are linked where they stand. `HookrMarketCoordinatorTokenDeployerV3` holds different code at the address it could have been linked from, so it has one of its own.

| Library | Linked into | Address |
| --- | --- | --- |
| HookrMarketCoordinatorTokenDeployerV3 | HookrMarketCoordinatorV5 | [`0x7A2821F7Ea0e4d0C5a409D479cd457d5B34F9399`](https://robinhoodchain.blockscout.com/address/0x7A2821F7Ea0e4d0C5a409D479cd457d5B34F9399) |
| HookrMarketCoordinatorKernelReservationLibV1 | HookrMarketCoordinatorV5 | [`0x8C2E208eDFf0eF7535B20AE8F13dfBF71133521d`](https://robinhoodchain.blockscout.com/address/0x8C2E208eDFf0eF7535B20AE8F13dfBF71133521d) |
| HookrStatefulSettlementLibV1 | HookrSwapAccountingKernelV3 | [`0xde7Ae40c713D5C9EC2C8e2E28810C6C7Eb791706`](https://robinhoodchain.blockscout.com/address/0xde7Ae40c713D5C9EC2C8e2E28810C6C7Eb791706) |
| HookrModularCorrectionLibV2 | HookrModularHookV6 | [`0xd2832D5F64C7116bE2c7B32D8c06d60023b479D8`](https://robinhoodchain.blockscout.com/address/0xd2832D5F64C7116bE2c7B32D8c06d60023b479D8) |
| HookrMarketCoordinatorInitialBuyLibV4 | HookrMarketCoordinatorV5 | [`0xE12f58f1662293B8b4fF3f0227384bD9D2a6e382`](https://robinhoodchain.blockscout.com/address/0xE12f58f1662293B8b4fF3f0227384bD9D2a6e382) |
| HookrNativeMechanicsCoordinatorLibV2 | HookrMarketCoordinatorV5 | [`0xafC0a7656DF8B1aA5A173d04612a9661C4b9c7E2`](https://robinhoodchain.blockscout.com/address/0xafC0a7656DF8B1aA5A173d04612a9661C4b9c7E2) |

The CREATE2 factory the root hook is mined through is `HookrReleaseCreate2FactoryV1` at [`0xBc54e888C1A5B71744B035DfeC5611B4DC69ccDe`](https://robinhoodchain.blockscout.com/address/0xBc54e888C1A5B71744B035DfeC5611B4DC69ccDe). Its `authorizedDeployer()` is the deployer address below, and only that address can deploy through it.

### Recapture Root

The second root, sealed on the same registry on 2026-09-12. It shares every address in the tables above except the default root itself and the V2 correction library; what it adds is the three rows here.

| Contract | Address | Deployed |
| --- | --- | --- |
| HookrWthExecutorAdapterV1 | [`0x28AF7A3645080e926a3101461e0Ec0594D42D806`](https://robinhoodchain.blockscout.com/address/0x28AF7A3645080e926a3101461e0Ec0594D42D806) | tx [`0x99f7bc3a…9be42`](https://robinhoodchain.blockscout.com/tx/0x99f7bc3a9a1f46a3f0d6d763fd7e8be1e2d2cd327a0cb1b5efff6721fed9be42), block 61,264,312 |
| HookrModularHookV6WthV5 | [`0xb914f955294799de4b891bd2EA8AF628Fa1c68CC`](https://robinhoodchain.blockscout.com/address/0xb914f955294799de4b891bd2EA8AF628Fa1c68CC) | tx [`0xbe054779…680f0`](https://robinhoodchain.blockscout.com/tx/0xbe054779ef042dae6988f72ac7727c6d645915594040ab91b8148bd1451680f0), block 61,270,834, CREATE2 through the same factory, salt `0x7a973dabaf3e3bc1eb1b0c02f49fb11669f5e7f098d1f4007a14e724d3e6bb80` |

| Library | Linked into | Address | Deployed |
| --- | --- | --- | --- |
| HookrModularCorrectionLibV3 | HookrModularHookV6WthV5 | [`0x11996B4e04571718d49454fC52830dc7fA0FF99C`](https://robinhoodchain.blockscout.com/address/0x11996B4e04571718d49454fC52830dc7fA0FF99C) | tx [`0xaed05dd5…975fc2`](https://robinhoodchain.blockscout.com/tx/0xaed05dd54ab488975d1f60ca982b7cae785cf6da053369c316ec258ce6975fc2), block 60,326,894, for an earlier recapture root and linked where it stands |

The root's constructor arguments, decoded from its verified entry, are the PoolManager, the registry `0x5b7f…5BA3`, the coordinator `0x53A1…2442` and the accounting kernel `0x5305…E060`: the same four the default root was built with. The adapter's are the deployer as owner, the PoolManager, the registry and the execution clock below.

Wiring, read back from the chain on 2026-09-21:

| Read | Value | Verification |
| --- | --- | --- |
| `HookrModularHookV6WthV5.accountingKernel()` | [`0x530523DEcC9523dDF8A87842fFBBD24a59C7E060`](https://robinhoodchain.blockscout.com/address/0x530523DEcC9523dDF8A87842fFBBD24a59C7E060) | the shared accounting kernel, full match |
| `HookrModularHookV6WthV5.REQUIRED_FLAGS()` | 10444 (`0x28cc`) | |
| `HookrWthExecutorAdapterV1.wthExecutor()` | [`0xc356cf51134e0DF02BFE880115DD8c66Ead45803`](https://robinhoodchain.blockscout.com/address/0xc356cf51134e0DF02BFE880115DD8c66Ead45803) | WTH's executor, not Hookr's; closed source, unverified on Blockscout and Sourcify; 62,358 bytes; bound once by `setExecutorOnce` in tx [`0xf49c1330…36614`](https://robinhoodchain.blockscout.com/tx/0xf49c1330a13832fcacbfd3e972273738c2b3eae7cf27e4aca3b8dce6b3736614), block 61,272,510 |
| `HookrWthExecutorAdapterV1.executionClock()` | [`0x72841e61d6701dEf8eDB3D780b13d3b44E6A0F92`](https://robinhoodchain.blockscout.com/address/0x72841e61d6701dEf8eDB3D780b13d3b44E6A0F92) | `HookrArbSysBlockClockV1`, 340 bytes, deployed 2026-09-08; not verified on Blockscout, exact match on Sourcify; its source is not in this export |
| `HookrWthExecutorAdapterV1.feePolicyId()` | `0xd2653e091cb7002585fd8b1192b58f11b9c951061dc797123e37d5e2ccb45cef` | equals `HookrWthFeePolicyV2.FEE_POLICY_ID` |
| `HookrWthExecutorAdapterV1.owner()` | [`0xF4Ab4698554D5c95874986d5e956c62e5E6aB3eE`](https://robinhoodchain.blockscout.com/address/0xF4Ab4698554D5c95874986d5e956c62e5E6aB3eE) | the deployer; ownership no longer controls anything the lane does, because the executor cannot be moved |
| `HookrStackRegistryV2.rootProfile(0xd8b6c165…)` | `isSealed = true`, `allowsExceptionalInstances = false`, `moduleCount = 1`, `profileVersion = 1` | sealed in tx [`0x48870c31…8adcb`](https://robinhoodchain.blockscout.com/tx/0x48870c31a5c64099e9448875f490e0d3743f1cf752617d0545fd41f17008adcb), block 61,272,550 |
| `HookrStackRegistryV2.kernel(0xd8b6c165…)` | implementation `0xb914…68CC`, code hash `0xd25dbcdc…3c28`, hook flags `0x28cc`, version 1 | |
| `HookrStackRegistryV2.integration(0xc4ae59ad…)` | implementation `0x28AF…D806`, code hash `0xd842cd7f…3ba8`, version 1 | the correction-executor integration the profile names |

#### Recapture root identifiers

| Identifier | Value |
| --- | --- |
| Kernel id | `0xd8b6c165b82efc3b7498081f071ea4f2476e2fb9c61b2e614aba2a016f94555a` |
| Root profile id | `0x9caac337e176ae6f2df97f1b153dc95a1ab0e73808155e3e1c969456832c9f78`, `keccak256("HOOKR_LAUNCH_V2_MIN_WTH_ROOT_PROFILE_V5")` |
| Root profile manifest hash | `0xdaa4fb5df3a94ca355e77dab6ba718fcd3b464294c03e1a8a90a848ec99f7f4e` |
| Module set hash | `0x8fafd562dd2b8dbb0d67a4d8cbc40c5cd2177836b0788028f8e855a8d96d8304`, identical to the default profile's: the same one module |
| Correction-executor integration id | `0xc4ae59ad11d59ac158b587ee1eed79594de1b0be1b13c86e7403f95dfd20f72c` |
| Correction-executor integration kind | `0x6a1418d9bfb6c90eb5ef654cb59024d67946df272310d833799228ea58e217dc`, `keccak256("HOOKR_KERNEL_INTEGRATION_CORRECTION_EXECUTOR")` |
| Fee policy id | `0xd2653e091cb7002585fd8b1192b58f11b9c951061dc797123e37d5e2ccb45cef`, `HookrWthFeePolicyV2.FEE_POLICY_ID`: creator 4,000 / trader 2,000 / triggering pool's LPs 2,000 / WTH 1,000 / Hookr 1,000 bps |
| Fee policy integration id | `0xd49d445cfb1f944f40848794320f9ba89f9a8830fcbedf98c236f82476f7d680`, `keccak256("hookr.integration.wth-arb.v2")` |

The module id, the router and quoter integration ids and the kernel family id are the same values as in [Registry Identifiers](#registry-identifiers) below; the recapture profile names the same module, router and quoter.

#### Superseded recapture roots

Three earlier recapture roots were sealed on this registry before the current one. They are listed here because their pools are still open and still trade; none is offered for new markets, none is exported, and no page in this repository describes them further.

| Address | Status |
| --- | --- |
| [`0xc7c516CD5546bCB2592Fe3f8aa91C2A4bA3768CC`](https://robinhoodchain.blockscout.com/address/0xc7c516CD5546bCB2592Fe3f8aa91C2A4bA3768CC) | superseded; its only pools are Hookr's own canary and rehearsal pools, verified on Blockscout as `HookrModularHookV6Wth` |
| [`0xa99902a2922014bBe2Bf2dCF15742ac5104828Cc`](https://robinhoodchain.blockscout.com/address/0xa99902a2922014bBe2Bf2dCF15742ac5104828Cc) | superseded; its only pools are Hookr's own canary and rehearsal pools, unverified |
| [`0xE5429dB8f63912E632E86733905667AaEb6ea8cC`](https://robinhoodchain.blockscout.com/address/0xE5429dB8f63912E632E86733905667AaEb6ea8cC) | superseded; its only pools are Hookr's own canary and rehearsal pools, unverified |

### Upstream Dependencies

These are live and independently verified on chain 4663.

| Contract | Address |
| --- | --- |
| [PoolManager](https://github.com/Uniswap/v4-core/blob/main/src/PoolManager.sol) | [`0x8366a39CC670B4001A1121B8F6A443A643e40951`](https://robinhoodchain.blockscout.com/address/0x8366a39CC670B4001A1121B8F6A443A643e40951) |
| [PositionManager](https://github.com/Uniswap/v4-periphery/blob/main/src/PositionManager.sol) | [`0x58daec3116aae6D93017bAAea7749052E8a04fA7`](https://robinhoodchain.blockscout.com/address/0x58daec3116aae6D93017bAAea7749052E8a04fA7) |
| [Quoter](https://github.com/Uniswap/v4-periphery/blob/main/src/lens/V4Quoter.sol) | [`0x8dc178efb8111bb0973dd9d722ebeff267c98f94`](https://robinhoodchain.blockscout.com/address/0x8dc178efb8111bb0973dd9d722ebeff267c98f94) |
| [Permit2](https://github.com/Uniswap/permit2) | [`0x000000000022D473030F116dDEE9F6B43aC78BA3`](https://robinhoodchain.blockscout.com/address/0x000000000022D473030F116dDEE9F6B43aC78BA3) |
| [Universal Router 2.1.1](https://github.com/Uniswap/universal-router) | [`0x8876789976dEcBfCbBbe364623C63652db8C0904`](https://robinhoodchain.blockscout.com/address/0x8876789976dEcBfCbBbe364623C63652db8C0904) |

Hookr pins one Universal Router: `0x8876789976dEcBfCbBbe364623C63652db8C0904`, runtime code hash `0x2ce6aaaf9f4151f5e1cbf774668772f17f532ae11b15e9284fd0a072a8b0fbde`, deployed at block 48,954. The fork rehearsals, the canary swaps and the app's swap paths settle through it. The app keeps the pin in `src/lib/universal-router.ts` and reads the code hash back from the chain in CI.

Uniswap's deployment registry lists a second router, [`0x06afBA43fd06227fA663b0dAeCF536F6eaA6BF99`](https://robinhoodchain.blockscout.com/address/0x06afBA43fd06227fA663b0dAeCF536F6eaA6BF99), runtime code hash `0xbe8e8191bb42d843c2e948a5a55772eaab864ce01e54dcd47c9d089170b302d5`. It is a later deployment with different bytecode. Nothing in Hookr routes through it. Re-pinning needs a fork rehearsal of the swap paths against the new address first.

### Tokens on Chain 4663

| Token | Address |
| --- | --- |
| HOOKR | [`0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c`](https://robinhoodchain.blockscout.com/address/0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c) |
| USDG | [`0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`](https://robinhoodchain.blockscout.com/address/0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168) |
| NFLX | [`0xE0444EF8BF4eD74f74FD73686e2ddF4C1c5591E8`](https://robinhoodchain.blockscout.com/address/0xE0444EF8BF4eD74f74FD73686e2ddF4C1c5591E8) |
| AAPL | [`0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9`](https://robinhoodchain.blockscout.com/address/0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9) |

NFLX and AAPL are Robinhood tokenized stocks. Read [RWA and ERC-20 quotes](../concepts/rwa-and-erc20-quotes.md) before pairing one.

## Wiring, Read Back From the Chain

Every one-shot bind and every pinned address, as the chain reports them.

| Read | Value |
| --- | --- |
| `HookrStackRegistryV2.coordinator()` | [`0x53A192A3fCeE94Da77916B461E0cCa2Dd6402442`](https://robinhoodchain.blockscout.com/address/0x53A192A3fCeE94Da77916B461E0cCa2Dd6402442) |
| `HookrMarketCoordinatorV5.treasuryBeneficiary()` | [`0x9BB7c01571ef6e59a8834A6a89A6b024822BAf6f`](https://robinhoodchain.blockscout.com/address/0x9BB7c01571ef6e59a8834A6a89A6b024822BAf6f) |
| `HookrNativeMechanicsBlockV2.protocolRecipient()` | [`0x9BB7c01571ef6e59a8834A6a89A6b024822BAf6f`](https://robinhoodchain.blockscout.com/address/0x9BB7c01571ef6e59a8834A6a89A6b024822BAf6f) |
| `HookrTreasuryForwarderV1.nativeBlock()` | [`0xD700492b504ba5A72D7de28dDe11Cd7985a7F1ae`](https://robinhoodchain.blockscout.com/address/0xD700492b504ba5A72D7de28dDe11Cd7985a7F1ae) |
| `HookrTreasuryForwarderV1.target()` | [`0xF4Ab4698554D5c95874986d5e956c62e5E6aB3eE`](https://robinhoodchain.blockscout.com/address/0xF4Ab4698554D5c95874986d5e956c62e5E6aB3eE) |
| `HookrModuleCatalogV1.canonicalStatefulModule()` | [`0xD700492b504ba5A72D7de28dDe11Cd7985a7F1ae`](https://robinhoodchain.blockscout.com/address/0xD700492b504ba5A72D7de28dDe11Cd7985a7F1ae) |
| `HookrMarketCoordinatorV5.defaultProtocolShareBps()` | 2000 |
| `HookrMarketCoordinatorV5.marketOpeningPaused()` | `false` (the owner unpaused it after deployment, so both lanes are open to any caller; read 2026-09-08) |
| `HookrKernelRouterV3.integrationVersion()` | 3 |
| `HookrKernelQuoterV1.integrationVersion()` | 1 |
| `HookrReleaseCreate2FactoryV1.authorizedDeployer()` | [`0xF4Ab4698554D5c95874986d5e956c62e5E6aB3eE`](https://robinhoodchain.blockscout.com/address/0xF4Ab4698554D5c95874986d5e956c62e5E6aB3eE) |

The coordinator, the registry, the catalog and the forwarder are all owned by the deployer. The forwarder's target is the same address today; rotating it is the one payout change that does not touch a pinned address. See [Immutability and ownership](../concepts/immutability-and-ownership.md).

## Registry Identifiers

The values `registerModule`, `registerIntegration`, `registerKernel` and `sealRootProfile` returned, which an integrator reads back rather than recomputing.

| Identifier | Value |
| --- | --- |
| Module id | `0x961091565aaf4eaa4996296fda9772957e61d18d90b965111a59ded2bbb5e774` |
| Router integration id | `0xc9ddc18b51d83cdafa6da985c67b4db41895dcde37b719597bdda9db6396c455` |
| Quoter integration id | `0x6e5a5b6aa6d141ccaf3b9f25f60e87919fc7a724cc845d146581eb49c079a9a9` |
| Kernel id | `0x1be0c118b1c6520d97de31ee9f0c33069f0e715ffcdcb16c87a343752bb5be14` |
| Root profile manifest hash | `0x74f018eb9afa65dcf38eb682397a21937b8568572c9884faa12465833bbcf213` |
| Kernel family id | `0x8b1849873123e8aae0521342fa900a748f6ac5f572800cddb1e71027474213b0` |
| Module key | `0xb7e3f7cb75273b57fec1d1eec0c8e7c59568c1537ce2135df897d1f14ef74304` |
| Root profile id | `0x460f3441e5dc6f26fe4729ecb80ad7aa9ba896af54bed88a47f1218588129d72` |

The last three are hashes of fixed strings and read back off the contracts that hold them: the kernel family id is `HookrKernelRouterV3.KERNEL_FAMILY_ID` and `HookrKernelQuoterV1.KERNEL_FAMILY_ID`, both `keccak256("HOOKR_SWAP_DELTA_V1")`; the module key is `HookrNativeMechanicsBlockV2.MODULE_KEY`, `keccak256("HOOKR_NATIVE_MECHANICS")`; the root profile id is `keccak256("HOOKR_LAUNCH_V2_MIN_ROOT_PROFILE")`, the permanent identity of the sealed profile.

## Source Verification

Every contract of the default lineage on this page, sixteen addresses, holds verified source on Blockscout, and every one is a full match: the explorer recompiles the source and gets the deployed bytes back, CBOR metadata trailer included. None is a partial match, which is what the explorer reports when the code agrees and the trailer does not. Sourcify holds the same sixteen addresses on chain 4663 as exact matches, creation and runtime bytecode both (`https://sourcify.dev/server/v2/contract/4663/<address>`). Of the recapture root's three addresses, the root and the adapter are Blockscout full matches and Sourcify exact matches; the linked correction library is not verified at its address on either, for the reason its row gives. WTH's executor and the execution clock are outside this claim.

The build is Solidity `v0.8.26+commit.8a97fa7a` through via-IR, the optimizer at 200 runs, `evm_version = cancun`, `bytecode_hash = ipfs`, CBOR metadata appended. `foundry.toml` in this repository is that profile, with its ten remappings written out rather than detected, because a contract's metadata records them and the metadata is hashed into the trailer.

To rebuild and compare a contract against its address:

```sh
git submodule update --init --recursive
forge build
cast code <address> --rpc-url https://rpc.mainnet.chain.robinhood.com
```

`out/<file>.sol/<Contract>.json` holds the runtime object to compare. For a contract that links libraries, write the addresses from the linked-library table into the placeholders that `deployedBytecode.linkReferences` locates; pinning the addresses in the compiler profile instead changes the metadata and the trailer stops matching. Zero the spans in `deployedBytecode.immutableReferences` on both sides, because those hold values fixed at construction rather than compiled bytes.

| Contract | Address | Runtime | Immutables | Rebuilt | Blockscout |
| --- | --- | --- | --- | --- | --- |
| `HookrModuleCatalogV1` | [`0x6a3561d5B6305E2229F30EDF66702e8Bc4fA19D1`](https://robinhoodchain.blockscout.com/address/0x6a3561d5B6305E2229F30EDF66702e8Bc4fA19D1) | 6,448 B | none | identical | verified, full match |
| `HookrStackRegistryV2` | [`0x5b7f1A117A83aaac15B0698Aa4eB9D53fE5f5BA3`](https://robinhoodchain.blockscout.com/address/0x5b7f1A117A83aaac15B0698Aa4eB9D53fE5f5BA3) | 23,307 B | 9 slots | identical once masked | verified, full match |
| `HookrTreasuryForwarderV1` | [`0x9BB7c01571ef6e59a8834A6a89A6b024822BAf6f`](https://robinhoodchain.blockscout.com/address/0x9BB7c01571ef6e59a8834A6a89A6b024822BAf6f) | 3,272 B | 2 slots | identical once masked | verified, full match |
| `HookrNativeMechanicsCoordinatorLibV2` | [`0xafC0a7656DF8B1aA5A173d04612a9661C4b9c7E2`](https://robinhoodchain.blockscout.com/address/0xafC0a7656DF8B1aA5A173d04612a9661C4b9c7E2) | 3,713 B | 1 slot | identical once masked | verified, full match |
| `HookrMarketCoordinatorInitialBuyLibV4` | [`0xE12f58f1662293B8b4fF3f0227384bD9D2a6e382`](https://robinhoodchain.blockscout.com/address/0xE12f58f1662293B8b4fF3f0227384bD9D2a6e382) | 2,209 B | 1 slot | identical once masked | verified, full match |
| `HookrMarketCoordinatorTokenDeployerV3` | [`0x7A2821F7Ea0e4d0C5a409D479cd457d5B34F9399`](https://robinhoodchain.blockscout.com/address/0x7A2821F7Ea0e4d0C5a409D479cd457d5B34F9399) | 10,541 B | 1 slot | identical once masked | verified, full match |
| `HookrMarketCoordinatorV5` | [`0x53A192A3fCeE94Da77916B461E0cCa2Dd6402442`](https://robinhoodchain.blockscout.com/address/0x53A192A3fCeE94Da77916B461E0cCa2Dd6402442) | 22,865 B | 26 slots | identical once masked | verified, full match |
| `HookrSwapAccountingKernelV3` | [`0x530523DEcC9523dDF8A87842fFBBD24a59C7E060`](https://robinhoodchain.blockscout.com/address/0x530523DEcC9523dDF8A87842fFBBD24a59C7E060) | 23,965 B | 19 slots | identical once masked | verified, full match |
| `HookrKernelRouterV3` | [`0xf0E528c39f33F565876cbaa7e0DFaCa38Df966E9`](https://robinhoodchain.blockscout.com/address/0xf0E528c39f33F565876cbaa7e0DFaCa38Df966E9) | 10,178 B | 10 slots | identical once masked | verified, full match |
| `HookrKernelQuoterV1` | [`0x5Ba8FBbB4aB20Ff6Daf0ecDEBe3784f869BcB1B5`](https://robinhoodchain.blockscout.com/address/0x5Ba8FBbB4aB20Ff6Daf0ecDEBe3784f869BcB1B5) | 5,412 B | 5 slots | identical once masked | verified, full match |
| `HookrNativeMechanicsBlockV2` | [`0xD700492b504ba5A72D7de28dDe11Cd7985a7F1ae`](https://robinhoodchain.blockscout.com/address/0xD700492b504ba5A72D7de28dDe11Cd7985a7F1ae) | 16,889 B | 12 slots | identical once masked | verified, full match |
| `HookrModularHookV6` | [`0xb3cA29cF721380CEe8b8e4755F3865Ebc68Fe8cC`](https://robinhoodchain.blockscout.com/address/0xb3cA29cF721380CEe8b8e4755F3865Ebc68Fe8cC) | 8,474 B | 12 slots | identical once masked | verified, full match |
| `HookrMarketCoordinatorKernelReservationLibV1` | [`0x8C2E208eDFf0eF7535B20AE8F13dfBF71133521d`](https://robinhoodchain.blockscout.com/address/0x8C2E208eDFf0eF7535B20AE8F13dfBF71133521d) | 483 B | 1 slot | identical once masked | verified, full match |
| `HookrStatefulSettlementLibV1` | [`0xde7Ae40c713D5C9EC2C8e2E28810C6C7Eb791706`](https://robinhoodchain.blockscout.com/address/0xde7Ae40c713D5C9EC2C8e2E28810C6C7Eb791706) | 2,715 B | 1 slot | identical once masked | verified, full match |
| `HookrModularCorrectionLibV2` | [`0xd2832D5F64C7116bE2c7B32D8c06d60023b479D8`](https://robinhoodchain.blockscout.com/address/0xd2832D5F64C7116bE2c7B32D8c06d60023b479D8) | 3,063 B | 1 slot | identical once masked | verified, full match |
| `HookrReleaseCreate2FactoryV1` | [`0xBc54e888C1A5B71744B035DfeC5611B4DC69ccDe`](https://robinhoodchain.blockscout.com/address/0xBc54e888C1A5B71744B035DfeC5611B4DC69ccDe) | 972 B | 2 slots | identical once masked | verified, full match |
| `HookrModularHookV6WthV5` | [`0xb914f955294799de4b891bd2EA8AF628Fa1c68CC`](https://robinhoodchain.blockscout.com/address/0xb914f955294799de4b891bd2EA8AF628Fa1c68CC) | 9,853 B | 12 slots | identical once masked | verified, full match (2026-09-12); Sourcify exact runtime match |
| `HookrWthExecutorAdapterV1` | [`0x28AF7A3645080e926a3101461e0Ec0594D42D806`](https://robinhoodchain.blockscout.com/address/0x28AF7A3645080e926a3101461e0Ec0594D42D806) | 4,492 B | 3 slots | identical once masked | verified, full match (2026-09-13); Sourcify exact creation and runtime match |
| `HookrModularCorrectionLibV3` | [`0x11996B4e04571718d49454fC52830dc7fA0FF99C`](https://robinhoodchain.blockscout.com/address/0x11996B4e04571718d49454fC52830dc7fA0FF99C) | 3,007 B | 1 slot | 2,995 code bytes identical once the trailer and the immutable are masked | not verified; deployed without the metadata hash, so its trailer is `solc` only and no full match is reachable at this address; the source is in the root's verified bundle |

Rows thirteen to sixteen predate the rest and carry the metadata of a build that embeds the source text instead of its hash, so reproducing their trailers takes `use_literal_content = true`. Their code is identical either way. The single immutable in each of the four libraries is its own address, which is how a library refuses a direct call. The last three rows are the recapture root's set; the root's and the adapter's runtime bytes reproduce from this build with the trailer included, and the library's reproduce without it.

## Machine-Readable Deployments

`deployments/robinhood-4663.v2.json` carries the same set as JSON, plus, for the contracts this release deployed, the runtime code hash and size and the deployment transaction and block (the three reused libraries carry only their address and code hash, and the factory appears under `upstream`), the registry identifiers and the wiring reads above, so a consumer reads one file rather than parsing this page. The recapture root is under `contracts.recaptureRootHook` and `contracts.wthExecutorAdapter`, its library under `reusedLibraries.modularCorrectionLibV3`, its identifiers under `identifiers.recapture`, its wiring under `wiring.adapterWthExecutor` and `wiring.adapterExecutionClock`, each root's listing status under `roots`, and the superseded recapture roots under `supersededRoots`.

## Refilling the Addresses

`scripts/sync-from-release.mjs` writes the default lineage's address cells above and the matching keys of `deployments/robinhood-4663.v2.json` from a deployment record; the recapture rows were filled by hand from the chain reads on this page:

```sh
node scripts/sync-from-release.mjs --journal /path/to/journal.json --root .
```

It refuses to overwrite an address that is already filled unless `--force` is passed, and it fills nothing it cannot read. The header comment in the script says what it will and will not touch.
