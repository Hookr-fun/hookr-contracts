# Revenue Tokenizer

`HookrRevenueTokenizer` locks a fee right and mints a fixed-supply revenue token whose holders share the income the right earns, in the same transaction. Deployed on 2026-10-19 with its four add-ons. Nothing in it has an owner: every outside address it uses is fixed in its constructor, and no function changes a pin, pauses it or moves a locked right.

## What it does

- **Five ways in.** A new launch on the shared root (`launchAndTokenize`), a Fee Beneficiary NFT held in one of the two vaults the tokenizer admits (`tokenizeFeeb`), a new pool on the root for a token the caller does not own (`launchAndTokenize`), a bundle of Uniswap v4 position NFTs locked in a door (`tokenizePositions`), and several streams at once (`tokenizeStreams`): a launch, Fee Beneficiary NFTs, v4 and v3 positions, and any outside fee right through an `IHookrRevenueSource` door. Any way can also open the revenue token's own market at mint, one ETH-quoted pool on the root.
- **The revenue token.** A fixed-supply ERC-20 with no owner, no pause and no second mint. The tokenizer seals it once, in the transaction that locks the fee rights, so no share exists before its income is locked behind it.
- **Doors.** Each fee right reaches the token through a door fixed at the seal: a pool's Rules ledger (the pool's royalty and the Hook Block takes credited to the token), a family door (`HookrFamilyForwarder`) for launches locked in the live `HookrFamilyLock`, a Fee Beneficiary NFT door (`HookrFeebAdapter`), a v4 or v3 position door, or an outside `IHookrRevenueSource` door such as the Pons and Long doors.
- **Sync.** `sync()` and `syncSome()` pull every door and recognize what arrived by balance delta. Anyone may call them, and the caller is paid the tip fixed at mint.
- **Income.** Each arrival is released to holders over the token's release period, 1 to 14 days (7 when the creator passes zero), pro rata and without staking. Shares held by the PoolManager, `0xdead`, the drop box or the token itself earn nothing.
- **Drops.** Each revenue token has its own drop box. Anyone can drop ETH or any ERC-20 for the holders, who claim it by their balance at the end of the block before the drop. Anything sent to the token or the box without `drop` becomes a drop through `dropStray`.
- **Terms.** A right is locked for good or for a term the creator sets, at least seven days: `MIN_TERM_BLOCKS` 50,400 parent blocks and `MIN_TERM_SECONDS` 604,800. A shorter term reverts `TermTooShort`.
- **Signatures.** Every holder action can be signed and relayed: EIP-2612 `permit`, EIP-3009 transfers, and claims by signature, from an EOA or an ERC-1271 account.

## The contracts

### Tokenizer

Deployed on 2026-10-19 between blocks 92,671,571 and 92,671,601, in eight transactions from `0x0c0967485A25F18E70262a2Ee80c7595CC64a5fC`. Each transaction goes through the CREATE3 factory at `0xc7c662Fc760FE1d5cB97fd8A68cb43A046da3F7d`, release id `hookr-1`, with the contract's name as its role. Six of them are external libraries, linked at deploy as the release's own libraries are.

| Contract | Address | Verified source |
| --- | --- | --- |
| `HookrRevenueTokenizer` | [`0xfb3c1501c727f30883cd7B36Ec380381af7412Ef`](https://robin.etherscan.io/address/0xfb3c1501c727f30883cd7B36Ec380381af7412Ef#code) | [Sourcify](https://repo.sourcify.dev/4663/0xfb3c1501c727f30883cd7B36Ec380381af7412Ef) |
| `HookrLegCollector`, created by the tokenizer in its constructor | [`0x7D79010cF29e548B55224f0cEEdAEd2275d65781`](https://robin.etherscan.io/address/0x7D79010cF29e548B55224f0cEEdAEd2275d65781#code) | [Sourcify](https://repo.sourcify.dev/4663/0x7D79010cF29e548B55224f0cEEdAEd2275d65781) |
| `HookrPositionNftDoorFactory`, created by the tokenizer in its constructor | [`0x4A0211091376cAA2032d899ebB633a0D9FC65dFc`](https://robin.etherscan.io/address/0x4A0211091376cAA2032d899ebB633a0D9FC65dFc#code) | [Sourcify](https://repo.sourcify.dev/4663/0x4A0211091376cAA2032d899ebB633a0D9FC65dFc) |
| `HookrV3PositionNftDoorFactory`, created by the tokenizer in its constructor | [`0xd9df572D99f08fBaAEecbF2aBafD70084Ffa558f`](https://robin.etherscan.io/address/0xd9df572D99f08fBaAEecbF2aBafD70084Ffa558f#code) | [Sourcify](https://repo.sourcify.dev/4663/0xd9df572D99f08fBaAEecbF2aBafD70084Ffa558f) |
| `HookrDropBoxDeployer`, a linked library | [`0xdD61c33DB3a3e2fC00b4566a12561d1De2696ea8`](https://robin.etherscan.io/address/0xdD61c33DB3a3e2fC00b4566a12561d1De2696ea8#code) | [Sourcify](https://repo.sourcify.dev/4663/0xdD61c33DB3a3e2fC00b4566a12561d1De2696ea8) |
| `HookrRevenueTokenDeployer`, a linked library | [`0x63b3A6bf73C82D24F704632b2CbBe4BC0A4475D7`](https://robin.etherscan.io/address/0x63b3A6bf73C82D24F704632b2CbBe4BC0A4475D7#code) | [Sourcify](https://repo.sourcify.dev/4663/0x63b3A6bf73C82D24F704632b2CbBe4BC0A4475D7) |
| `HookrRevenueDoorDeployer`, a linked library | [`0xFeAD2B2601248Ab18573E7B8E5CDE0A21D00511B`](https://robin.etherscan.io/address/0xFeAD2B2601248Ab18573E7B8E5CDE0A21D00511B#code) | [Sourcify](https://repo.sourcify.dev/4663/0xFeAD2B2601248Ab18573E7B8E5CDE0A21D00511B) |
| `HookrRevenueMarketOpener`, a linked library | [`0x09EEef9Ee9E079C82315d675709ff1528Da6DD79`](https://robin.etherscan.io/address/0x09EEef9Ee9E079C82315d675709ff1528Da6DD79#code) | [Sourcify](https://repo.sourcify.dev/4663/0x09EEef9Ee9E079C82315d675709ff1528Da6DD79) |
| `HookrRevenueStreams`, a linked library | [`0x0F493ddd01221075229AC3f03abeAAE8f5429b7B`](https://robin.etherscan.io/address/0x0F493ddd01221075229AC3f03abeAAE8f5429b7B#code) | [Sourcify](https://repo.sourcify.dev/4663/0x0F493ddd01221075229AC3f03abeAAE8f5429b7B) |
| `HookrV3DoorFactoryDeployer`, a linked library | [`0x759Af627c50e82ce0b50AD6A5780fa6047CdCFa6`](https://robin.etherscan.io/address/0x759Af627c50e82ce0b50AD6A5780fa6047CdCFa6#code) | [Sourcify](https://repo.sourcify.dev/4663/0x759Af627c50e82ce0b50AD6A5780fa6047CdCFa6) |
| `HookrPonsAdapterFactory` | [`0xca16D264750BDd79004B80e265F9D3d0992957d2`](https://robin.etherscan.io/address/0xca16D264750BDd79004B80e265F9D3d0992957d2#code) | [Sourcify](https://repo.sourcify.dev/4663/0xca16D264750BDd79004B80e265F9D3d0992957d2) |

The tokenizer's pins: `HookrLauncher` `0x1cf2748A6670572425eAbf9Ab9e5BC4eb2eB8Ef4`, `HookrFamilyLock` `0xfAFEcE64099C1E791C4B46189c277f00c0c7e00b`, `HookrRoot` `0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc`, the release's Rules `0x4a71c270b1520F94064268102AebD744b0DE7942` and the King of the Pool whole-pot Rules `0x10f684361b35C8411a2c07F68A6fB1F4B7e555F7`, `HookrTreasury` `0x2242F7FC75606500503075f29ea8cDA684EfB4a9`, the Fee Beneficiary vaults `0xd35E9CA72F64C7F93BE30fad67524323396B36D7` and `0x26d2F7AcB07707034406a0dC458351Bb63C02553`, the Fee Bridge factory `0x85D2F6c536336C17B79BE740C6bbb6c7d8D9b23D`, Uniswap's v4 PositionManager `0x58daec3116aae6D93017bAAea7749052E8a04fA7` and v3 NonfungiblePositionManager `0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3`. The Pons adapter factory's one pin is the Pons V2 launch factory `0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e`.

### Add-ons

Deployed on 2026-10-19 between blocks 92,743,158 and 92,743,174, in five transactions from the same deployer, through the same CREATE3 factory under release id `hookr-1`. Each works on revenue tokens the tokenizer made, and none of them is needed for one.

| Add-on | Contract | Address | Verified source |
| --- | --- | --- | --- |
| [Time shares](./time-shares/src/) | `HookrTimeSharesFactory` | [`0x07bDc86Ce9E0aD55344A3DBDEc7c1571D2c0380b`](https://robin.etherscan.io/address/0x07bDc86Ce9E0aD55344A3DBDEc7c1571D2c0380b#code) | [Sourcify](https://repo.sourcify.dev/4663/0x07bDc86Ce9E0aD55344A3DBDEc7c1571D2c0380b) |
| [Time shares](./time-shares/src/) | `HookrTimeShareWrapperFactory` | [`0x1082A41130F3088812e784Cbd1e5046a528a7449`](https://robin.etherscan.io/address/0x1082A41130F3088812e784Cbd1e5046a528a7449#code) | [Sourcify](https://repo.sourcify.dev/4663/0x1082A41130F3088812e784Cbd1e5046a528a7449) |
| [Compounder](./compounder/src/) | `HookrRevenueCompounderFactory` | [`0xF32205941a11Ac428Be079773B3Ea583E55BC764`](https://robin.etherscan.io/address/0xF32205941a11Ac428Be079773B3Ea583E55BC764#code) | [Sourcify](https://repo.sourcify.dev/4663/0xF32205941a11Ac428Be079773B3Ea583E55BC764) |
| [Compounder](./compounder/src/) | `HookrCompounderLens` | [`0xE6a08A2056aa617aCF669d96646dd91700D38bcB`](https://robin.etherscan.io/address/0xE6a08A2056aa617aCF669d96646dd91700D38bcB#code) | [Sourcify](https://repo.sourcify.dev/4663/0xE6a08A2056aa617aCF669d96646dd91700D38bcB) |
| [Long door](./doppler-adapter/src/) | `HookrDopplerAdapterFactory` | [`0xA863D22772efC34E5E331AbfAb9a1B126C1b5663`](https://robin.etherscan.io/address/0xA863D22772efC34E5E331AbfAb9a1B126C1b5663#code) | [Sourcify](https://repo.sourcify.dev/4663/0xA863D22772efC34E5E331AbfAb9a1B126C1b5663) |

- **Time shares.** Lock revenue tokens for whole UTC days, or forever, and get one ERC-6909 unit per locked revenue token for each day of the lock; a day's units earn only that day's income. The wrapper is the ERC-20 form of one day's units. `roll()` books the income the token owes the time shares to the days it belongs to.
- **Compounder.** One opt-in vault per revenue token. Deposits earn the token's income, the vault places that income in the token's pool as single-sided liquidity, and shares redeem pro rata for everything the vault holds. `poke()` claims the income and places it. `HookrCompounderLens` holds the vault's reads. The factory is pinned to the PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951` and the tokenizer.
- **Long door (`HookrDopplerAdapter`).** One door per Long launch on Doppler, holding the launch's beneficiary share as a stream of a revenue token minted after it. The factory is pinned to the Doppler hook initializer `0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544` and the integrator `0x92d435C96E63c43E12d6D0AB28f6b0B04072F765`.

`sync`, `roll` and `poke` are calls anyone can make, and each can pay its caller a tip. The contracts never call them on their own: until someone does, income waits in the doors, in the time shares or in the vault.

### Contracts made later

These have no address yet. Each is created by a contract above, from creation code compiled into it from the sources here, so the record checks them through their creators.

| Contract | Made by | Source |
| --- | --- | --- |
| `HookrRevenueToken`, one per tokenization | `HookrRevenueTokenDeployer` | [`src/HookrRevenueToken.sol`](./src/HookrRevenueToken.sol) |
| `HookrDropBox`, one per revenue token | `HookrDropBoxDeployer`, from the token's constructor | [`src/HookrDropBox.sol`](./src/HookrDropBox.sol) |
| `HookrFamilyForwarder` and `HookrFeebAdapter` | `HookrRevenueDoorDeployer` | [`src/HookrFamilyForwarder.sol`](./src/HookrFamilyForwarder.sol), [`src/HookrFeebAdapter.sol`](./src/HookrFeebAdapter.sol) |
| `HookrPositionNftDoor`, the v4 door | `HookrPositionNftDoorFactory` | [`src/HookrPositionNftDoor.sol`](./src/HookrPositionNftDoor.sol) |
| `HookrV3PositionNftDoor`, the v3 door | `HookrV3PositionNftDoorFactory` | [`src/HookrV3PositionNftDoor.sol`](./src/HookrV3PositionNftDoor.sol) |
| `HookrPonsAdapter`, the source for one Pons V2 launch's creator fee | `HookrPonsAdapterFactory` | [`src/HookrPonsAdapter.sol`](./src/HookrPonsAdapter.sol) |
| `HookrTimeShares` and `HookrTimeShareWrapper` | `HookrTimeSharesFactory`, `HookrTimeShareWrapperFactory` | [`time-shares/src/`](./time-shares/src/) |
| `HookrRevenueCompounder` | `HookrRevenueCompounderFactory`, from its code chunks | [`compounder/src/HookrRevenueCompounder.sol`](./compounder/src/HookrRevenueCompounder.sol) |
| `HookrDopplerAdapter` | `HookrDopplerAdapterFactory` | [`doppler-adapter/src/HookrDopplerAdapter.sol`](./doppler-adapter/src/HookrDopplerAdapter.sol) |

### The compounder's code chunks

The compounder's creation code, 28,348 bytes, is larger than one contract's runtime may be, so `HookrRevenueCompounderFactory` writes it at its construction into two `HookrCodeChunk` contracts and deploys every compounder from them. Each chunk's runtime is a STOP byte followed by its piece. They are data, not verified source, and the record lists them under the factory as `dataContracts`:

| Chunk | Address | Holds |
| --- | --- | --- |
| 0, the factory's CREATE nonce 1 | [`0x2e9e3e42E0351563e7206FE505140ec777bca386`](https://robin.etherscan.io/address/0x2e9e3e42E0351563e7206FE505140ec777bca386#code) | bytes 0 to 23,999 |
| 1, the factory's CREATE nonce 2 | [`0xcc879898625b089bE1249b19E8085d7fE28f15eC`](https://robin.etherscan.io/address/0xcc879898625b089bE1249b19E8085d7fE28f15eC#code) | bytes 24,000 to 28,347 |

`codeChunks()` on the factory returns both. [`check-code-chunks.mjs`](./check-code-chunks.mjs) checks that the two together are the creation code of `HookrRevenueCompounder` built from the sources here (section "Building it").

### CREATE3 proxies

Each of the thirteen CREATE3 deployments above leaves the factory's 8-byte proxy (`0x363d3d37363d34f0`) at its own address. The record lists each one as its contract's `deployment.proxy`, as it does for every other CREATE3 deployment.

## Hookr's leg

When a tokenized stream does not already pay Hookr through its hook (a Fee Beneficiary NFT, a position off the root, a v3 position, an outside source), the tokenizer mints 5% of the supply to `HookrLegCollector` (`HOOKR_LEG_BPS_OUTSIDE`, 500). When it does (a launch or a new pool on the root, positions that all sit on the root), Hookr's leg is zero (`HOOKR_LEG_BPS_HOOKR`, 0). Both are constants, fixed per token when it is minted. The collector never transfers its shares; anyone can sweep what they earn to `HookrTreasury`'s current `target()`.

Hookr passes 1 point of that 5% leg, 1% of the supply minted, on to What The Hook (WTH). The contracts do not do this: the collector sweeps the whole leg to the treasury's target, and Hookr sends WTH its point from there.

## Where the files are

| Folder | Holds | Build tree name |
| --- | --- | --- |
| [`src/`](./src/) | The tokenizer, its libraries, its created contracts and every contract they make, 55 files | `src/...` for the tokenizer's eleven contracts, `../fee-tokenizer/src/...` for the add-ons |
| [`time-shares/src/`](./time-shares/src/) | The time shares add-on, 12 files | `src/...` |
| [`compounder/src/`](./compounder/src/) | The compounder add-on, 12 files | `src/...` |
| [`doppler-adapter/src/`](./doppler-adapter/src/) | The Long door add-on, 5 files | `src/...` |

Every file is byte-identical to the verified source on Sourcify, and its keccak256 is in the record's `sourceKeccak256`. The release files they import (`../hookr-phase-one/src/...` in the metadata) are the release's own files in [`../src/`](../src/), and the dependencies are the pinned submodules in [`../../lib/`](../../lib/).

## Building it

The compiler input for any of the 16 comes from the record, which maps each source unit name to its file here:

```sh
node hookr-1/standard-input.mjs 0xfb3c1501c727f30883cd7B36Ec380381af7412Ef > tokenizer.json
solc-0.8.37 --standard-json tokenizer.json > tokenizer.out.json
cast code 0xfb3c1501c727f30883cd7B36Ec380381af7412Ef > tokenizer.hex   # with ETH_RPC_URL set to a chain 4663 node
node hookr-1/check-runtime.mjs 0xfb3c1501c727f30883cd7B36Ec380381af7412Ef tokenizer.out.json tokenizer.hex
```

`check-runtime.mjs` links the tokenizer's four runtime libraries from the record. The same four lines with any other address check that contract. The four settings profiles, `revenue-tokenizer`, `revenue-tokenizer-time-shares`, `revenue-tokenizer-compounder` and `revenue-tokenizer-doppler-adapter`, are read from the verified metadata; they differ from each other only in their remappings.

The code chunks, from the compounder factory's output:

```sh
node hookr-1/standard-input.mjs 0xF32205941a11Ac428Be079773B3Ea583E55BC764 > compounder.json
solc-0.8.37 --standard-json compounder.json > compounder.out.json
cast code 0x2e9e3e42E0351563e7206FE505140ec777bca386 > chunk0.hex
cast code 0xcc879898625b089bE1249b19E8085d7fE28f15eC > chunk1.hex
node hookr-1/revenue-tokenizer/check-code-chunks.mjs compounder.out.json chunk0.hex chunk1.hex
```

There is no Forge profile for these folders: their metadata records the build tree's remappings, and `standard-input.mjs` is the byte-exact build.

## Status

Deployed, and every one of the 16 contracts is an exact runtime match on Sourcify. No independent audit of the tokenizer or its add-ons has been completed.
