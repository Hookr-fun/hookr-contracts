# Combined core and own hooks

The combined core is a Rules contract for the shared hook, `HookrRoot` at [`0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc`](https://robin.etherscan.io/address/0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc#code), with every Hook Block built in. The registry admits it on the shared hook beside the release's Rules, so a pool can name it the way it names those. Owned-root factory v2 makes own hooks on it: each one a root v2 of its own with its own copy of the core, made in one transaction, sharing lane v2, and with an outside swap module when its creator picks one. The LP Time-Lock Boost is redeployed beside them. Nothing deployed earlier changes: the release, its Rules and every pool on them run as before.

## What it does

- **The core.** `HookrRules` at `0x8AD0aC66DbeBcc047e8d216666C925E797e5e52e` carries the release's rules (Anti-Snipe, Hookr dynamic fees, Auto Burn, LP Rewards and Royalty) and the Hook Blocks in two slots: Swap Cut, Exit Clock, Holder Pot, Storm Fee and Sandwich Guard in `HookrCoreBlocks`, Wallet Cap and the buy and sell launch windows in `HookrLimitBlocks`. King of the Pool and the arb recapture split are in `HookrRecapture`. A pool's choices are frozen when it opens.
- **Arb recapture is on by default.** A pool on the core takes the recapture lane unless its creator opts out (bit 18 of `RulesConfig.potEveryNBuys`, `NO_RECAPTURE`). The profit of arbitrage against the pool's other venues is split by `HookrRecapture`.
- **Brake keys.** The core's constructor creates eight `HookrBlockKey` contracts by CREATE2, one per Hook Block. The registry admits a Hook Block on the core under its key, so each block can be stopped for new pools on its own. At block 100,509,391 it admits seven of the eight keys: Holder Pot's key, index 2, is not admitted yet, so the core refuses a new Holder Pot pool until the registry admits it.
- **Own hooks.** `HookrOwnedRootFactoryV2` makes an own hook in one transaction, with no code in the calldata: it checks the profile the creator names (a live admission of the core on the shared hook), creates root v2 by CREATE3 from the root store, creates the own hook's copy of the core by CREATE2 from the two core stores, and checks that copy's code equals the core's outside its per-root immutables. Root v2 takes the shared hook's permission flags, `0x2acc`. With the profile's `publicOpening` on, anyone may open pools on an own hook; otherwise only its owner. The factory has no owner, holds no funds and has no upgrade path; the registry admits it pinned to its runtime code hash, which commits to every store, to root v2's creation code hash and to the core's.
- **Lane v2.** `HookrLane` holds root v2's initialization and its arb recapture lane, reached by DELEGATECALL, so it runs as the root. One lane v2 serves every root v2. A pool freezes its lane at initialization; each lane swap runs a recapture frame before it is quoted and one after it settles, each with the gas cap the executor's switch sets, and a swap below the lane's gas floor reverts, so no caller can make a recapture skip. Inside a frame the executor may leg on any lane pool of the same own hook, at most seven besides the frame's own, and the frame checks that nothing is left behind.
- **Swap modules.** A swap module trades an outside venue while the venue beats the Hookr pool's own price after its LP fee, and the pool fills the rest. Root v2 reaches it through `HookrFill`, which gives the module exactly its admitted gas and refuses a fill worse than the pool's own price. `HookrRamsesV3Fill` fills from Ramses V3 (admitted at 1,200,000 gas) and `HookrPonsCurveFill` from Pons V2 curves, never buying a curve's last token (admitted at 400,000 gas). Neither has an owner, a setter or storage, and every venue call is caught, so a missing or failing venue fills nothing and never stops the pool. The registry admits both under the core, before the swap only.
- **LP Boost.** `HookrLpBoost` pays time-lock boost rewards on full-range v4 positions of Hookr pools, one gauge per pool, and holds each staked position until its staker withdraws it from maturity on. Against the earlier LP Boost at `0x52536F5F4E5BC7cEA2197c8F1BB49bf2B133E7f1`, a pause now runs out after seven days, the guardian's pauses share one window and a rest of seven days, and a pause never blocks `withdraw`. The earlier one keeps its gauges and stakes.

## The contracts

### The core

Deployed on 2026-10-26 in blocks 98,419,467 to 98,419,487, in seven transactions from `0x0c0967485A25F18E70262a2Ee80c7595CC64a5fC` (nonces 386 to 392), each through the CREATE3 factory at `0xc7c662Fc760FE1d5cB97fd8A68cb43A046da3F7d`, release id `hookr-1`, with the contract's name as its role and salt counter 1. `HookrViewSwap`'s address is a library in the compiler settings of the other six; the core links it. The registry admits the core on the shared hook as a RULES module pinned to its code hash.

| Contract | What it is | Address | Runtime keccak256 | Verified source |
| --- | --- | --- | --- | --- |
| `HookrRules` | The core: the Rules a pool on the core names. Fees, Hook Block dispatch, the claim ledger and protocol accounting | [`0x8AD0aC66DbeBcc047e8d216666C925E797e5e52e`](https://robin.etherscan.io/address/0x8AD0aC66DbeBcc047e8d216666C925E797e5e52e#code) | `0x26dc86731245621bc765a95ebee7636c4eb726c4e9bc8e8946294d223404a677` | [exact match](https://repo.sourcify.dev/4663/0x8AD0aC66DbeBcc047e8d216666C925E797e5e52e) |
| `HookrRecapture` | The arb recapture split and King of the Pool, a module the core reaches by DELEGATECALL | [`0x1172a3cC44ce8E8E3F1f0e58a9A0E9678b7118f8`](https://robin.etherscan.io/address/0x1172a3cC44ce8E8E3F1f0e58a9A0E9678b7118f8#code) | `0xb1d8b1d6a6626ee859cc0c5a2725078fb62245d730015b3405974928fba6e5c1` | [exact match](https://repo.sourcify.dev/4663/0x1172a3cC44ce8E8E3F1f0e58a9A0E9678b7118f8) |
| `HookrCoreBlocks` | Hook Block slot 1: Swap Cut, Exit Clock, Holder Pot, Storm Fee and Sandwich Guard | [`0xFA66c713bb10298B47E0afC43389212F279E8245`](https://robin.etherscan.io/address/0xFA66c713bb10298B47E0afC43389212F279E8245#code) | `0x6731ed800a1eb9d083f640ad8c00f94dc0cb3461c3f5124a21349ad30c8e6e28` | [exact match](https://repo.sourcify.dev/4663/0xFA66c713bb10298B47E0afC43389212F279E8245) |
| `HookrLimitBlocks` | Hook Block slot 0: Wallet Cap and the buy and sell launch windows | [`0xc42E47679dd06DDcC07acc72ca710f6E60ACC3A9`](https://robin.etherscan.io/address/0xc42E47679dd06DDcC07acc72ca710f6E60ACC3A9#code) | `0x9f810ec150181c58ed3af00c5b1be7b5d974b5b34450c7d1918d0cf70c5ac2ae` | [exact match](https://repo.sourcify.dev/4663/0xc42E47679dd06DDcC07acc72ca710f6E60ACC3A9) |
| `HookrBinder` | The core's `bind`, run once per pool by DELEGATECALL, kept out of the core so the core fits EIP-170 | [`0xe5FCbB899C95B4c7cd3afFfd1f4EB093138870A2`](https://robin.etherscan.io/address/0xe5FCbB899C95B4c7cd3afFfd1f4EB093138870A2#code) | `0x479a933df7325219942f75f36046f731ed7409f96e0c279e9912e2d0ed5ee0ed` | [exact match](https://repo.sourcify.dev/4663/0xe5FCbB899C95B4c7cd3afFfd1f4EB093138870A2) |
| `HookrClaims` | The claim code, reached through the core's fallback | [`0x8D0583b408e2959FA0450c54F749C1A4Dad3d335`](https://robin.etherscan.io/address/0x8D0583b408e2959FA0450c54F749C1A4Dad3d335#code) | `0x1825f945ef04d5304707da468929c33dcf125db20d9c0292d98952455a393775` | [exact match](https://repo.sourcify.dev/4663/0x8D0583b408e2959FA0450c54F749C1A4Dad3d335) |
| `HookrViewSwap` | Linked library: a read-only v4 swap preview that prices Hookr dynamic fees on where a swap ends | [`0x844faE4347517180bf4656b67E4BFc27D194693F`](https://robin.etherscan.io/address/0x844faE4347517180bf4656b67E4BFc27D194693F#code) | `0x06637360f73ecae521e086778631d773201521dca2a5146e0cae6bc097ccf3eb` | [exact match](https://repo.sourcify.dev/4663/0x844faE4347517180bf4656b67E4BFc27D194693F) |

The core's pins: the PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951`, the registry `0x463c82beA1a52F4Cc05ca0741a24F0AD24bA4602`, `HookrTreasury` `0x2242F7FC75606500503075f29ea8cDA684EfB4a9` as the protocol recipient, the shared hook, and the six contracts above by address and code hash. `HookrClaims` and `HookrRecapture` are pinned to the PoolManager and the treasury, `HookrCoreBlocks` to the PoolManager.

The eight brake keys, each a `HookrBlockKey` created by the core in its constructor with salt `keccak256("hookr.rules.block.v1." ++ index)`. Each one's runtime is the 57 bytes of an empty contract, keccak256 `0x4ff3630dd3d4ca59d00c08a7c8be527f6b90ffd700a7cc6a36a837de2ee4565e`, which the build here gives:

| Index | Hook Block | Address |
| --- | --- | --- |
| 0 | Swap Cut | [`0x19455CCA21AadEEc27091ded344dC7bac1c79d6e`](https://robin.etherscan.io/address/0x19455CCA21AadEEc27091ded344dC7bac1c79d6e#code) |
| 1 | Exit Clock | [`0xF4F081fFEC0E40D50C67210FCf56EAbcb10aCA6f`](https://robin.etherscan.io/address/0xF4F081fFEC0E40D50C67210FCf56EAbcb10aCA6f#code) |
| 2 | Holder Pot | [`0x8301Ace7Ab004C157CaCE296bfce8aD549d51094`](https://robin.etherscan.io/address/0x8301Ace7Ab004C157CaCE296bfce8aD549d51094#code) |
| 3 | Storm Fee | [`0x09a9C803Af1C2A82c02B895cCb732597BB2986Da`](https://robin.etherscan.io/address/0x09a9C803Af1C2A82c02B895cCb732597BB2986Da#code) |
| 4 | Wallet Cap | [`0x74288b31E2913Ea1Cf2472412424E6EA1B1D99Dd`](https://robin.etherscan.io/address/0x74288b31E2913Ea1Cf2472412424E6EA1B1D99Dd#code) |
| 5 | Buy and sell launch windows | [`0x3851d2202C32a50A78257Ba18098f0e045fF871f`](https://robin.etherscan.io/address/0x3851d2202C32a50A78257Ba18098f0e045fF871f#code) |
| 6 | Sandwich Guard | [`0xfb77Effb52c878fdD045f12E32cB94d627E027fe`](https://robin.etherscan.io/address/0xfb77Effb52c878fdD045f12E32cB94d627E027fe#code) |
| 7 | King of the Pool | [`0xD2F2046786E4620c9C7B708E6e6Fd2cE380f1B21`](https://robin.etherscan.io/address/0xD2F2046786E4620c9C7B708E6e6Fd2cE380f1B21#code) |

### Own hooks and the LP Boost

Deployed on 2026-10-28 in blocks 100,433,558 to 100,433,591, in eight transactions from the same account (nonces 426 to 433), the same way, salt counter 1. Nineteen transactions after them (nonces 434 to 452) registered factory v2 as a root factory, admitted the two swap modules under the core and configured the LP Boost with the earlier one's reward tokens and supply bounds, each behind a 1,800-second delay, and wrote the `core` profile on the profile book, the template own hooks are made from.

| Contract | What it is | Address | Runtime keccak256 | Verified source |
| --- | --- | --- | --- | --- |
| `HookrOwnedRootFactoryV2` | Owned-root factory v2: makes an own hook (root v2 and its copy of the core) in one transaction | [`0x4888f030F9D789Bf71F45B275dA7A7812036dE7e`](https://robin.etherscan.io/address/0x4888f030F9D789Bf71F45B275dA7A7812036dE7e#code) | `0x3597b04862b071dd63f023b2a03bc9f31bc042916a23c36d88ec5cd51972a909` | [exact match](https://repo.sourcify.dev/4663/0x4888f030F9D789Bf71F45B275dA7A7812036dE7e) |
| `HookrLane` | Lane v2: initialization and the arb recapture lane of every root v2, reached by DELEGATECALL | [`0xa83007AB66cF977132c58F5a138E1e92A005Fff3`](https://robin.etherscan.io/address/0xa83007AB66cF977132c58F5a138E1e92A005Fff3#code) | `0x731ec310ecd56cf21cffa123efcd7c3594e6bf04468cc928a8d0cf25aaad01a7` | [exact match](https://repo.sourcify.dev/4663/0xa83007AB66cF977132c58F5a138E1e92A005Fff3) |
| `HookrCodeStore` | Data: root v2's creation code (the root store) | [`0xB41EB84679855602522ecd0093ff6343EB3ceEc4`](https://robin.etherscan.io/address/0xB41EB84679855602522ecd0093ff6343EB3ceEc4#code) | `0x633f1b41d8bf3f8f5e3b24f21facc0c411b46f72d64f65015996ef5e5507f51d` | none |
| `HookrCodeStore` | Data: the first half of the core's creation code (core store 0) | [`0xd71167314A50589C7C8CD9Cc9C81939f5DDDb190`](https://robin.etherscan.io/address/0xd71167314A50589C7C8CD9Cc9C81939f5DDDb190#code) | `0x78543c6419a30c871be58ebc340b5be6da601adeec9574b841ee7e01eaa3c933` | [creation match](https://repo.sourcify.dev/4663/0xd71167314A50589C7C8CD9Cc9C81939f5DDDb190) |
| `HookrCodeStore` | Data: the second half of the core's creation code (core store 1) | [`0xe4731fFC8a0A0C10213C872F5c17b3f895A82a83`](https://robin.etherscan.io/address/0xe4731fFC8a0A0C10213C872F5c17b3f895A82a83#code) | `0x4791f3c2441851d66a241e5005bd5ec2fbef74a0d8c94f0ddd1913664199bbe1` | none |
| `HookrRamsesV3Fill` | Swap module: fills from Ramses V3 pools of tick spacing 1 | [`0x446e409484dE756662f2C238c9bDECB9f50f5B8F`](https://robin.etherscan.io/address/0x446e409484dE756662f2C238c9bDECB9f50f5B8F#code) | `0x591c363926150b8870882927188ff2b7c630a07d20fcd3d4313700ad3844fed0` | [exact match](https://repo.sourcify.dev/4663/0x446e409484dE756662f2C238c9bDECB9f50f5B8F) |
| `HookrPonsCurveFill` | Swap module: fills from Pons V2 curves | [`0xEa0A512dFA4D8CcaFA31E485bd189703D8BaAa27`](https://robin.etherscan.io/address/0xEa0A512dFA4D8CcaFA31E485bd189703D8BaAa27#code) | `0x1a2c1884566bbf4d73c29a2d2df89cca3a67c2926f1f7d282465127634236206` | [exact match](https://repo.sourcify.dev/4663/0xEa0A512dFA4D8CcaFA31E485bd189703D8BaAa27) |
| `HookrLpBoost` | The LP Time-Lock Boost, redeployed: funded gauges for locked full-range positions | [`0xa301A960716a070394826092e6fF113A156A80D1`](https://robin.etherscan.io/address/0xa301A960716a070394826092e6fF113A156A80D1#code) | `0xcc150f8b0578c7c597856f9dedc6316c3c82658e42e46fdeaa7d13b576ae45a8` | [exact match](https://repo.sourcify.dev/4663/0xa301A960716a070394826092e6fF113A156A80D1) |

Each runtime keccak256 above is the address's code hash read from the chain at block 100,509,391 and again at block 109,974,574, the record's `checkedAtBlock`.

The pins: factory v2, the registry, the profile book `0xb46c318B6AEA2d6274f5566da414b09fDa6CC325`, the shared hook, the treasury, lane v2, the three stores with their runtime hashes, the hash of root v2's creation code and the hash of the core's creation code with the core's layout; lane v2, the PoolManager and the registry; the Ramses module, the PoolManager, WETH `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`, the Ramses V3 pool deployer `0x4b37359BF291AbE8453692DB58d515a8b013Dca9`, its pool init code hash and tick spacing 1; the Pons module, the PoolManager and the Pons V2 launch factory `0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e`; the LP Boost, the registry, `HookrLauncher` `0x1cf2748A6670572425eAbf9Ab9e5BC4eb2eB8Ef4`, Uniswap's v4 PositionManager `0x58daec3116aae6D93017bAAea7749052E8a04fA7`, its owner and a delay of 1,800 seconds.

### The code stores

Factory v2 builds from three `HookrCodeStore` contracts. Each one's runtime is a STOP byte followed by its data: the root store holds root v2's creation code (23,376 bytes), and the two core stores hold the core's creation code as deployed at `0x8AD0aC66DbeBcc047e8d216666C925E797e5e52e`, with `HookrViewSwap` linked, in two halves of 13,899 bytes. A store has no function, no owner and no way to change its code.

Their runtime is data, so no compiled runtime can match it, and Sourcify has no runtime match for them. Their content is bound here instead: [`check-code-stores.mjs`](./check-code-stores.mjs) checks that the root store holds exactly root v2's creation code built from the sources here, metadata hash included, and that the two core stores joined are exactly the core's creation code built here. `HookrCodeStore` itself is 245 bytes of creation code with no metadata hash: Sourcify lists core store 0 as a creation match (a match without a metadata hash cannot be exact) and holds no record of the other two, whose creation code is the same 245 bytes followed by their own data. The record lists the three under factory v2 as `dataContracts`.

### Contracts made later

These have no fixed address. Each is made per own hook or per swap module by a contract above, from code compiled into it or held in its stores.

| Contract | Made by | Source |
| --- | --- | --- |
| `HookrRoot`, root v2, one per own hook | `HookrOwnedRootFactoryV2`, by CREATE3 from the root store | [`root-v2/src/core/HookrRoot.sol`](./root-v2/src/core/HookrRoot.sol) |
| `HookrRules`, the own hook's copy of the core | `HookrOwnedRootFactoryV2`, by CREATE2 from the two core stores | [`core/src/core/HookrRules.sol`](./core/src/core/HookrRules.sol) |
| `HookrFill`, one per swap module, gas limit and scope, made the first time an own hook picks it | `HookrOwnedRootFactoryV2` | [`root-v2/src/core/HookrFill.sol`](./root-v2/src/core/HookrFill.sol) |

Root v2 compiles with the settings of lane v2's build. The record lists it under factory v2 as a `template`, with its sources, settings and the code hash of its creation code, `0xd342e0303f449af89275b7a2d83344f0582bb005910e395d6215341328920117`. No root v2 is verified on Sourcify; the root store and `check-code-stores.mjs` are what binds its code to these sources. Seven of its files are in no verified contract's sources: `HookrRoot.sol`, `HookrReleased.sol`, `HookrRelease.sol`, `IHookrLaneRoot.sol`, `IHookrReleased.sol`, `IHookrRootRoute.sol` and `IHookrRootState.sol`, all under [`root-v2/src/`](./root-v2/src/).

### CREATE3 proxies

Each of the fifteen CREATE3 deployments leaves the factory's 8-byte proxy (`0x363d3d37363d34f0`) at its own address. The record lists each one as its contract's `deployment.proxy`.

## Where the files are

The contracts were built from four build trees, and each one's metadata names its files by their path in that tree. Each tree has a folder here.

| Folder | Holds | Build tree names |
| --- | --- | --- |
| [`core/src/`](./core/src/) | The core, its blocks, binder, claims, recapture and library, 55 files | `src/...` |
| [`periphery/src/`](./periphery/src/) | Factory v2, the code store and the LP Boost, 32 files | `src/...`; root v2's files as `candidate-root-v2/src/...` |
| [`root-v2/src/`](./root-v2/src/) | Root v2, lane v2 and `HookrFill`, 26 files | `src/...` |
| [`swap-modules/src/`](./swap-modules/src/) | The Ramses and Pons modules, 2 files | `src/...`; root v2's files as `../candidate-root-v2/src/...` |

The dependencies are the pinned submodules in [`../../lib/`](../../lib/), 54 files, each byte-identical to the one the metadata records. The core's build names them `../../../../../contracts/lib/...`, factory v2's and the LP Boost's `../../../contracts/lib/...` and the swap modules' `../../../../contracts/lib/...`. Lane v2's and root v2's build names them by an absolute path, which the record writes as `<build-root>/contracts/lib/...`. Those names are part of the metadata hash in the deployed code; the build root is in the remappings of lane v2's verified metadata on Sourcify, and `standard-input.mjs` takes it as an argument. The core's `HookrTypes.sol` differs from the periphery's, which is one reason the trees keep folders of their own.

Every file is byte-identical to the verified source on Sourcify, except root v2's seven files above, which no verified contract compiles and `check-code-stores.mjs` checks; each file's keccak256 is in the record's `sourceKeccak256`.

## Building it

Every contract here compiles with solc 0.8.37 (`0.8.37+commit.f401782d`), via-IR, the optimizer at 200 runs, EVM version prague, and the IPFS metadata hash. The record's settings profiles `combined-core`, `combined-core-periphery`, `combined-core-root-v2` and `combined-core-swap-modules` hold the exact settings of each tree, read from the verified metadata, the core's with `HookrViewSwap`'s address as a library.

The compiler input for any of the twelve contracts with code comes from the record; `node hookr-1/standard-input.mjs --list` names them under `combined-core`. Lane v2's also takes the build root, as a second argument.

```sh
node hookr-1/standard-input.mjs 0x8AD0aC66DbeBcc047e8d216666C925E797e5e52e > core.json
solc-0.8.37 --standard-json core.json > core.out.json
cast code 0x8AD0aC66DbeBcc047e8d216666C925E797e5e52e > core.hex   # with ETH_RPC_URL set to a chain 4663 node
node hookr-1/check-runtime.mjs 0x8AD0aC66DbeBcc047e8d216666C925E797e5e52e core.out.json core.hex
```

The same four lines with any other address in the tables check that contract. The code stores, from root v2's input, which `check-code-stores.mjs` writes, and the core's output above:

```sh
node hookr-1/combined-core/check-code-stores.mjs --input <build root> > root.json
solc-0.8.37 --standard-json root.json > root.out.json
cast code 0xB41EB84679855602522ecd0093ff6343EB3ceEc4 > root-store.hex
cast code 0xd71167314A50589C7C8CD9Cc9C81939f5DDDb190 > core-store-0.hex
cast code 0xe4731fFC8a0A0C10213C872F5c17b3f895A82a83 > core-store-1.hex
node hookr-1/combined-core/check-code-stores.mjs root.out.json core.out.json root-store.hex core-store-0.hex core-store-1.hex
```

It prints `MATCH` when both hold. The brake keys' runtime is `evm.deployedBytecode` of `src/core/HookrBlockKey.sol:HookrBlockKey` in `core.out.json`.

There is no Forge profile for these folders: their metadata records the build trees' remappings, and `standard-input.mjs` is the byte-exact build.

## Verification

The twelve contracts with code are exact matches on Sourcify: runtime and creation code, metadata hash included. The code stores are data: Sourcify lists core store 0 as a creation match and has no record of the root store or core store 1, and `check-code-stores.mjs` binds all three to the sources here.

## Status

Deployed. The release's own `HookrRoot`, its Rules and the earlier LP Boost are unchanged. No independent audit of the combined core, lane v2, root v2, factory v2, the swap modules or the LP Boost has been completed.
