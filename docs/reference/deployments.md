# Deployments

Every address on this page is live on Robinhood Chain. The Hookr addresses hold the code that `src/` in this repository compiles to; the upstream addresses are Uniswap's own deployments.

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

The root hook's address is mined by CREATE2 so its low fourteen bits equal `0x28cc`. See [Hook permissions](./hook-permissions.md).

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

### Upstream Dependencies

These are live and independently verified on chain 4663.

| Contract | Address |
| --- | --- |
| [PoolManager](https://github.com/Uniswap/v4-core/blob/main/src/PoolManager.sol) | [`0x8366a39CC670B4001A1121B8F6A443A643e40951`](https://robinhoodchain.blockscout.com/address/0x8366a39CC670B4001A1121B8F6A443A643e40951) |
| [PositionManager](https://github.com/Uniswap/v4-periphery/blob/main/src/PositionManager.sol) | [`0x58daec3116aae6D93017bAAea7749052E8a04fA7`](https://robinhoodchain.blockscout.com/address/0x58daec3116aae6D93017bAAea7749052E8a04fA7) |
| [Quoter](https://github.com/Uniswap/v4-periphery/blob/main/src/lens/V4Quoter.sol) | [`0x8dc178efb8111bb0973dd9d722ebeff267c98f94`](https://robinhoodchain.blockscout.com/address/0x8dc178efb8111bb0973dd9d722ebeff267c98f94) |
| [Permit2](https://github.com/Uniswap/permit2) | [`0x000000000022D473030F116dDEE9F6B43aC78BA3`](https://robinhoodchain.blockscout.com/address/0x000000000022D473030F116dDEE9F6B43aC78BA3) |
| [Universal Router 2.1.1](https://github.com/Uniswap/universal-router) | see the note below |

The Universal Router address on chain 4663 has two conflicting official sources. Uniswap's deployment registry gives `0x06afBA43fd06227fA663b0dAeCF536F6eaA6BF99`; the rendered deployments page gives `0x8876789976dEcBfCbBbe364623C63652db8C0904`. The fork evidence behind this package used `0x8876789976dEcBfCbBbe364623C63652db8C0904`, and swaps settled correctly through it.

Both addresses hold a deployed router, both are 24,546 bytes, and both report the same `poolManager()`. Their runtime code hashes differ, so they are not the same build:

| Address | Runtime code hash |
| --- | --- |
| [`0x06afBA43fd06227fA663b0dAeCF536F6eaA6BF99`](https://robinhoodchain.blockscout.com/address/0x06afBA43fd06227fA663b0dAeCF536F6eaA6BF99) | `0xbe8e8191bb42d843c2e948a5a55772eaab864ce01e54dcd47c9d089170b302d5` |
| [`0x8876789976dEcBfCbBbe364623C63652db8C0904`](https://robinhoodchain.blockscout.com/address/0x8876789976dEcBfCbBbe364623C63652db8C0904) | `0x2ce6aaaf9f4151f5e1cbf774668772f17f532ae11b15e9284fd0a072a8b0fbde` |

Nothing in the Hookr graph pins either one: the hook accepts any caller, and a pool's trusted-router slot holds `HookrKernelRouterV3`, not a Universal Router. The choice belongs to whoever routes through this hook. Pin the address you tested against, record its runtime code hash alongside the evidence, and say which one you pinned. This documentation does not choose for you.

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

Every Hookr contract on this page holds verified source on Blockscout, and every one is a full match: the explorer recompiles the source and gets the deployed bytes back, CBOR metadata trailer included. None is a partial match, which is what the explorer reports when the code agrees and the trailer does not. Sourcify holds the same sixteen addresses on chain 4663 as exact matches, creation and runtime bytecode both (`https://sourcify.dev/server/v2/contract/4663/<address>`).

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

The last four rows predate the rest and carry the metadata of a build that embeds the source text instead of its hash, so reproducing their trailers takes `use_literal_content = true`. Their code is identical either way. The single immutable in each of the three libraries is its own address, which is how a library refuses a direct call.

## Machine-Readable Deployments

`deployments/robinhood-4663.v2.json` carries the same set as JSON, plus, for the contracts this release deployed, the runtime code hash and size and the deployment transaction and block (the three reused libraries carry only their address and code hash, and the factory appears under `upstream`), the registry identifiers and the wiring reads above, so a consumer reads one file rather than parsing this page.

## Refilling the Addresses

`scripts/sync-from-release.mjs` writes the address cells above and `deployments/robinhood-4663.v2.json` from a deployment record:

```sh
node scripts/sync-from-release.mjs --journal /path/to/journal.json --root .
```

It refuses to overwrite an address that is already filled unless `--force` is passed, and it fills nothing it cannot read. The header comment in the script says what it will and will not touch.
