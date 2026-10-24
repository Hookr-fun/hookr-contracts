# Revenue Tokenizer v2

`HookrRevenueTokenizer` locks fee rights and mints a fixed-supply revenue token whose holders share the income the rights earn, in the same transaction, and adds more streams to that token later. Deployed on 2026-10-24 on Robinhood Chain (chain id 4663), beside the first [Revenue Tokenizer](../revenue-tokenizer/README.md), which is unchanged. Nothing in it has an owner: every outside address it uses is fixed in its constructor, and no function changes a pin, pauses it or moves a locked right before its term ends.

## What it does

- **Ways in.** `tokenize` locks any mix of streams and mints the revenue token in one transaction: a new Hookr launch on the shared root, Hookr families handed in, a pool's Rules ledger, pools.trade Fee Beneficiary NFTs, Uniswap v4 and v3 position NFTs, shares of another revenue token, and any outside fee right through an `IHookrRevenueSource` door, such as the Pons and Long doors. It can also open the revenue token's own market at mint, one pool on the root against native ETH or an ERC-20, with a Fee Bridge to the market's LPs when asked.
- **Streams only grow.** `addStreams` locks more streams into a revenue token the tokenizer made, for as long as the token has a stream manager. A token minted with `openStreams` also takes streams from anyone, of every kind but an outside source. Nothing removes or changes a stream.
- **The revenue token.** A fixed-supply ERC-20 with no owner, no pause and no second mint. It lists up to eight assets its income is paid in: native ETH first, then up to seven ERC-20s. The tokenizer mints the supply once, after the streams of `tokenize` are locked, so no share exists before its income is locked behind it.
- **Doors.** Each fee right reaches the token through a door: a pool's Rules ledger (the pool's royalty and the Hook Block takes credited to the token), the token's family door (`HookrFamilyForwarder`) for its launches, families and market, a Fee Beneficiary NFT door (`HookrFeebAdapter`), a v4 or v3 position door, a revenue token door (`HookrRevenueTokenDoor`) for shares of another revenue token, or an outside `IHookrRevenueSource` door.
- **Sync.** `sync()`, `syncRange()` and `syncSome()` pull the doors, each on its own gas stipend, and recognize what arrived by balance delta. Anyone may call them, and the caller is paid the tip fixed at mint, at most 1%.
- **Income.** Each arrival is claimable as soon as a sync recognizes it, or released to holders over the token's release period when the creator sets one, up to 14 days. It is shared pro rata, without staking. Holders claim it themselves, through an operator they approve, or by signature.
- **Drops.** Each revenue token has its own drop box. Anyone can drop ETH or any ERC-20 for the holders, who claim it by their balance at the end of the block before the drop. Anything sent to the token or its box without `drop` reaches the holders through `dropStray`.
- **Terms.** A right is locked for good or for a term the creator sets, at least seven days: `MIN_TERM_BLOCKS` 50,400 parent blocks for families and `MIN_TERM_SECONDS` 604,800 for doors. At the end of a term anyone can call `release`, and the right goes back to the account that locked it. That account can extend a term, never shorten it.
- **Signatures.** Every holder action but approving an operator can be signed and relayed: EIP-2612 `permit`, EIP-3009 transfers, and claims by signature, from an EOA or an ERC-1271 account.

## The contracts

Deployed on 2026-10-24 between blocks 96,932,339 and 96,932,399, in sixteen transactions from `0x0c0967485A25F18E70262a2Ee80c7595CC64a5fC`. Each transaction goes through the CREATE3 factory at `0xc7c662Fc760FE1d5cB97fd8A68cb43A046da3F7d`, release id `hookr-1`, with the contract's name as its role (`HookrRevenueTokenCode.0` and `HookrRevenueTokenCode.1` for the two halves of the token's code) and salt counter 1, so roles that share a name with the first tokenizer's contracts get new addresses. The tokenizer's constructor creates the seventeenth, `HookrLegCollector`. Six of them are external libraries, linked at deploy.

| Contract | What it is | Address | Runtime keccak256 | Verified source |
| --- | --- | --- | --- | --- |
| `HookrRevenueTokenizer` | The tokenizer | [`0xAD0F7575F6476d5a37a4aBAF109Dd7f84089B90c`](https://robin.etherscan.io/address/0xAD0F7575F6476d5a37a4aBAF109Dd7f84089B90c#code) | `0xe4c9c940c66bad917fc050e7fda3340b99c52ab5c3a115bdfc96481cac65d90e` | [exact match](https://repo.sourcify.dev/4663/0xAD0F7575F6476d5a37a4aBAF109Dd7f84089B90c) |
| `HookrLegCollector` | Created by the tokenizer in its constructor: takes Hookr's leg and sweeps it to the treasury's target | [`0xAb5cBbC2C5b98F9b9E8f800eaa735E49C7f7A625`](https://robin.etherscan.io/address/0xAb5cBbC2C5b98F9b9E8f800eaa735E49C7f7A625#code) | `0x442162f15638b66d8e71ce9a48926165fd55a1823d986696e24b11c3217cc200` | [exact match](https://repo.sourcify.dev/4663/0xAb5cBbC2C5b98F9b9E8f800eaa735E49C7f7A625) |
| `HookrRevenueStreams` | Linked library: `tokenize` and `addStreams` in full | [`0x8AF409136d1C6F036F47638EeaDA3AE7f3Fad490`](https://robin.etherscan.io/address/0x8AF409136d1C6F036F47638EeaDA3AE7f3Fad490#code) | `0x11aef932247708aff6ecacf830733b2a4fe7b4b2e5304956ed2095d279e64347` | [exact match](https://repo.sourcify.dev/4663/0x8AF409136d1C6F036F47638EeaDA3AE7f3Fad490) |
| `HookrRevenueMarketOpener` | Linked library: a new Hookr launch, and the revenue token's own market with its Fee Bridge | [`0x7689cd313A0eAb4d3Fb4549D22A653D04b27cd3f`](https://robin.etherscan.io/address/0x7689cd313A0eAb4d3Fb4549D22A653D04b27cd3f#code) | `0x893b390e98e89b69f917479d47e52776a52a10ba798aad20da8ea49c3affe1e9` | [exact match](https://repo.sourcify.dev/4663/0x7689cd313A0eAb4d3Fb4549D22A653D04b27cd3f) |
| `HookrRevenueDoorDeployer` | Linked library: the family doors, the checks of a launch, a market and an outside source, and the position doors | [`0x122e24aF927A4E762167665A06a8f34682E86465`](https://robin.etherscan.io/address/0x122e24aF927A4E762167665A06a8f34682E86465#code) | `0x404fa1a86684addb4162c7f3395bd170064f6ed6f8b66a1d6841364d2d2da259` | [exact match](https://repo.sourcify.dev/4663/0x122e24aF927A4E762167665A06a8f34682E86465) |
| `HookrSignatures` | Linked library: the one signature check behind every signed path of a revenue token and its drop box (ECDSA, then ERC-1271) | [`0x0A0F8bE151846B848122214Ee2F9861a828036eA`](https://robin.etherscan.io/address/0x0A0F8bE151846B848122214Ee2F9861a828036eA#code) | `0x1db8ef85d6897fb15c92906497443e6a234397084e04d07e8ada2d8f8dc5d025` | [exact match](https://repo.sourcify.dev/4663/0x0A0F8bE151846B848122214Ee2F9861a828036eA) |
| `HookrIncomeRecovery` | Linked library: bounded collection of the drops that shares held by a revenue token or its drop box earn, and of a token's income from another revenue token | [`0x425c8b42502B9BA2d96b4C56e6962DCA0E3c5785`](https://robin.etherscan.io/address/0x425c8b42502B9BA2d96b4C56e6962DCA0E3c5785#code) | `0xf3d957aef8b1ade9f400e673794f15cb967d3c4b9c8b68410f9a6cf04e6b14fa` | [exact match](https://repo.sourcify.dev/4663/0x425c8b42502B9BA2d96b4C56e6962DCA0E3c5785) |
| `HookrDropBoxDeployer` | Linked library: deploys each revenue token's drop box from the token's constructor | [`0x25844bA027af0b25132209B58d399196E350DE22`](https://robin.etherscan.io/address/0x25844bA027af0b25132209B58d399196E350DE22#code) | `0x4e8f6c95ce7770d0ca7521cb18187f1d369019907e3f0b504c4804cbee975530` | [exact match](https://repo.sourcify.dev/4663/0x25844bA027af0b25132209B58d399196E350DE22) |
| `HookrRevenueTokenCode.0` | Data: a STOP byte and bytes 0 to 13,999 of the revenue token's creation code | [`0x99b498Aa5f073b70De35e317A8bFB1BB8386a78A`](https://robin.etherscan.io/address/0x99b498Aa5f073b70De35e317A8bFB1BB8386a78A#code) | `0x28d2a40c09ac930d01efc6c53e7ee526a510c8ba76c51c327f485663e03ae4b8` | [creation match](https://repo.sourcify.dev/4663/0x99b498Aa5f073b70De35e317A8bFB1BB8386a78A) |
| `HookrRevenueTokenCode.1` | Data: a STOP byte and bytes 14,000 to 27,809 of the revenue token's creation code | [`0xcccD15Ac6aA42d77874Af26b7b73DF634512d6e0`](https://robin.etherscan.io/address/0xcccD15Ac6aA42d77874Af26b7b73DF634512d6e0#code) | `0xc5ec7d21b4edcda06e588136e35c61e3028a95900a94df42a82de58992197281` | [creation match](https://repo.sourcify.dev/4663/0xcccD15Ac6aA42d77874Af26b7b73DF634512d6e0) |
| `HookrPositionNftDoorFactory` | Makes the v4 position doors | [`0x78aBe03F35FD9B0D6D72aB74E1f65cB2cB3A49c1`](https://robin.etherscan.io/address/0x78aBe03F35FD9B0D6D72aB74E1f65cB2cB3A49c1#code) | `0x9e756a0e9f1d713047527bb63c61c89cfefe124093772efe2af1f8c27e131db1` | [exact match](https://repo.sourcify.dev/4663/0x78aBe03F35FD9B0D6D72aB74E1f65cB2cB3A49c1) |
| `HookrV3PositionNftDoorFactory` | Makes the v3 position doors | [`0xBefB5aAa1c18Cb298643421dF191BFd06bB00325`](https://robin.etherscan.io/address/0xBefB5aAa1c18Cb298643421dF191BFd06bB00325#code) | `0x5a8559173de02fe832fa4dd48e088bc5ac0425bd66480b82054ed45609fe25cd` | [exact match](https://repo.sourcify.dev/4663/0xBefB5aAa1c18Cb298643421dF191BFd06bB00325) |
| `HookrFeebAdapterFactory` | Makes the Fee Beneficiary NFT doors | [`0x517AB33C67b7855eC0514818918eb2A857feAE4a`](https://robin.etherscan.io/address/0x517AB33C67b7855eC0514818918eb2A857feAE4a#code) | `0xf477f23d6e5feac02d33d87b80e4f0a5fd34f613235ed4ffbd23dee7b0879c37` | [exact match](https://repo.sourcify.dev/4663/0x517AB33C67b7855eC0514818918eb2A857feAE4a) |
| `HookrRevenueTokenDoorFactory` | Makes the revenue token doors, which hold shares of another revenue token as a stream | [`0x51049eB3254B4b218fd41f5b91A7010F0Ea0B049`](https://robin.etherscan.io/address/0x51049eB3254B4b218fd41f5b91A7010F0Ea0B049#code) | `0x6148f150e4ccfc3047869a9cbcf496e1e18b7a4593c8a108cc646f96616bd443` | [exact match](https://repo.sourcify.dev/4663/0x51049eB3254B4b218fd41f5b91A7010F0Ea0B049) |
| `HookrPonsAdapterFactory` | Makes the Pons doors, one per Pons V2 launch's creator fee | [`0x6DDDd86F71717CAFcf0CeFeeFC6E79b50775B7f0`](https://robin.etherscan.io/address/0x6DDDd86F71717CAFcf0CeFeeFC6E79b50775B7f0#code) | `0xed8778c10c7b4f73514f0b1740b9f270f4b5a6bcf3b41330e69d889eacd08551` | [exact match](https://repo.sourcify.dev/4663/0x6DDDd86F71717CAFcf0CeFeeFC6E79b50775B7f0) |
| `HookrDopplerAdapterFactory` | Makes the Long doors, one per Long launch's beneficiary share on Doppler | [`0xC1D50AF2FDFdD37B5B7c95A3dd5175B661bD7142`](https://robin.etherscan.io/address/0xC1D50AF2FDFdD37B5B7c95A3dd5175B661bD7142#code) | `0x1cdfe5345dc6b04aaddf1c3f7a70cb918ab9330554960ed5678633d8d7b998c5` | [exact match](https://repo.sourcify.dev/4663/0xC1D50AF2FDFdD37B5B7c95A3dd5175B661bD7142) |
| `HookrRevenueStateView` | Read-only lens: a token's terms, assets, doors, and a holder's claimable income and open drops in one call | [`0xe3280D57E4a1F9a07997E3C34499d728dc9fa275`](https://robin.etherscan.io/address/0xe3280D57E4a1F9a07997E3C34499d728dc9fa275#code) | `0x34ae53f3ad699cbd5b6a471a739ef4ddfda79ae68bdbfd56d4ccc25dd20742d7` | [exact match](https://repo.sourcify.dev/4663/0xe3280D57E4a1F9a07997E3C34499d728dc9fa275) |

Each runtime keccak256 above is the address's code hash read from the chain at block 96,938,171, the record's `checkedAtBlock`.

The tokenizer's pins: `HookrLauncher` `0x1cf2748A6670572425eAbf9Ab9e5BC4eb2eB8Ef4`, `HookrFamilyLock` `0xfAFEcE64099C1E791C4B46189c277f00c0c7e00b`, `HookrRoot` `0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc`, the release's Rules `0x4a71c270b1520F94064268102AebD744b0DE7942` and the King of the Pool whole-pot Rules `0x10f684361b35C8411a2c07F68A6fB1F4B7e555F7`, `HookrTreasury` `0x2242F7FC75606500503075f29ea8cDA684EfB4a9`, the Fee Beneficiary vaults `0xd35E9CA72F64C7F93BE30fad67524323396B36D7` and `0x26d2F7AcB07707034406a0dC458351Bb63C02553`, the Fee Bridge factory `0x85D2F6c536336C17B79BE740C6bbb6c7d8D9b23D`, Uniswap's v4 PositionManager `0x58daec3116aae6D93017bAAea7749052E8a04fA7` and v3 NonfungiblePositionManager `0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3`, the six door factories and the two code halves above, and the code hash of the pools.trade fee splitters, `0x8238e5106b3a895514083110d1f3b4e51be61148604f35113719af56ae325f42`. Its constructor checks that the four door factories pinned to it (v4, v3, Fee Beneficiary NFT and revenue token) name it.

The other contracts' pins: the v4 door factory, the PositionManager, `HookrRoot` and the tokenizer; the v3 door factory, the v3 NonfungiblePositionManager and the tokenizer; the Fee Beneficiary NFT door factory, the tokenizer, the PositionManager and the fee splitters' code hash; the revenue token door factory and the state view, the tokenizer; the Pons door factory, the Pons V2 launch factory `0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e`; the Long door factory, the Doppler hook initializer `0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544` and the integrator `0x92d435C96E63c43E12d6D0AB28f6b0B04072F765`; the leg collector, `HookrTreasury`.

### Contracts made later

These have no address yet. Each is created by a contract above, from creation code compiled into it from the sources here.

| Contract | Made by | Source |
| --- | --- | --- |
| `HookrRevenueToken`, one per tokenization | `HookrRevenueTokenizer`, by CREATE2 from its own address, from the two code halves | [`src/HookrRevenueToken.sol`](./src/HookrRevenueToken.sol) |
| `HookrDropBox`, one per revenue token | `HookrDropBoxDeployer`, from the token's constructor | [`src/HookrDropBox.sol`](./src/HookrDropBox.sol) |
| `HookrFamilyForwarder`, the family door, one per revenue token that locks a family | `HookrRevenueDoorDeployer` | [`src/doors/HookrFamilyForwarder.sol`](./src/doors/HookrFamilyForwarder.sol) |
| `HookrFeebAdapter`, the Fee Beneficiary NFT door | `HookrFeebAdapterFactory` | [`src/doors/HookrFeebAdapter.sol`](./src/doors/HookrFeebAdapter.sol) |
| `HookrPositionNftDoor`, the v4 door | `HookrPositionNftDoorFactory` | [`src/doors/HookrPositionNftDoor.sol`](./src/doors/HookrPositionNftDoor.sol) |
| `HookrV3PositionNftDoor`, the v3 door | `HookrV3PositionNftDoorFactory` | [`src/doors/HookrV3PositionNftDoor.sol`](./src/doors/HookrV3PositionNftDoor.sol) |
| `HookrRevenueTokenDoor`, the revenue token door | `HookrRevenueTokenDoorFactory` | [`src/doors/HookrRevenueTokenDoor.sol`](./src/doors/HookrRevenueTokenDoor.sol) |
| `HookrPonsAdapter`, the Pons door | `HookrPonsAdapterFactory` | [`src/doors/HookrPonsAdapter.sol`](./src/doors/HookrPonsAdapter.sol) |
| `HookrDopplerAdapter`, the Long door | `HookrDopplerAdapterFactory` | [`src/doors/HookrDopplerAdapter.sol`](./src/doors/HookrDopplerAdapter.sol) |

### The revenue token's code halves

The revenue token's creation code, 27,810 bytes linked to its three libraries (`HookrSignatures`, `HookrIncomeRecovery` and `HookrDropBoxDeployer`), is larger than one contract's runtime may be. Two `HookrRevenueTokenCode` contracts hold it: each one's runtime is a STOP byte followed by its half, bytes 0 to 13,999 in `HookrRevenueTokenCode.0` and bytes 14,000 to 27,809 in `HookrRevenueTokenCode.1`. The tokenizer reads both and creates every revenue token from them.

Their runtime is data, so no compiled runtime can match it. Sourcify matches their creation code instead, exactly, and every revenue token's own exact match binds their content: a token's code is what the two halves hold. The record lists the halves under the tokenizer as `dataContracts`, each with the sources and settings of its creation match. [`check-token-code.mjs`](./check-token-code.mjs) checks that the two together are the revenue token's creation code built from the sources here, linked to the three libraries above (section "Building it").

### CREATE3 proxies

Each of the sixteen CREATE3 deployments leaves the factory's 8-byte proxy (`0x363d3d37363d34f0`) at its own address. The record lists each one as its contract's `deployment.proxy`, as it does for every other CREATE3 deployment.

## Hookr's leg

Hookr's leg is 5% (`HOOKR_LEG_BPS_OUTSIDE`, 500) of what each door outside the Hookr root delivers: a Fee Beneficiary NFT door, v4 positions off the root, a v3 position door and an outside source. The token sends it to `HookrLegCollector` in the sync that pulls the door, in each listed asset that arrived. A door that already pays Hookr through its hook (a Rules ledger, a family door, v4 positions that sit on the root) and a revenue token door carry no leg (`HOOKR_LEG_BPS_HOOKR`, 0). Both are constants, fixed per door when it is added. The first tokenizer minted its leg as shares of each revenue token; this one mints none to the collector.

Hookr passes 1 point of that 5% leg on to What The Hook (WTH). The contracts do not do this: the collector sweeps the whole leg to the treasury's target, and Hookr sends WTH its point from there.

The collector keeps nothing for itself: anyone can sweep what it holds to `HookrTreasury`'s current `target()`.

## Not in this release

The experimental lending module and the campaign periphery are not part of this release. None of their code is deployed, and none of it is in this folder: the files here are exactly the sources compiled into the seventeen contracts above.

## Where the files are

| Folder | Holds | Build tree name |
| --- | --- | --- |
| [`src/`](./src/) | The tokenizer, its libraries, the code halves, the door factories, the state view, the leg collector and every contract they make, 83 files | `src/...` |

Every file is byte-identical to the verified source on Sourcify, and its keccak256 is in the record's `sourceKeccak256`. The release files they import (`../hookr-phase-one/src/...` in the metadata, 10 files) are the release's own files in [`../src/`](../src/), and the dependencies (`../../../contracts/lib/...`, 47 files) are the pinned submodules in [`../../lib/`](../../lib/). Those 57 files were already published, and each one's keccak256 equals the one the metadata of the contracts here records.

## Building it

The seventeen compile with solc 0.8.37 (`0.8.37+commit.f401782d`), via-IR, the optimizer at 50 runs, EVM version prague, and the IPFS metadata hash. The release itself uses 200 runs. The record's settings profile `revenue-tokenizer-v2` holds the exact settings, read from the verified metadata.

The compiler input for any of the fifteen exact matches comes from the record, which maps each source unit name to its file here; `node hookr-1/standard-input.mjs --list` names them under `revenue-tokenizer-v2`:

```sh
node hookr-1/standard-input.mjs 0xAD0F7575F6476d5a37a4aBAF109Dd7f84089B90c > tokenizer.json
solc-0.8.37 --standard-json tokenizer.json > tokenizer.out.json
cast code 0xAD0F7575F6476d5a37a4aBAF109Dd7f84089B90c > tokenizer.hex   # with ETH_RPC_URL set to a chain 4663 node
node hookr-1/check-runtime.mjs 0xAD0F7575F6476d5a37a4aBAF109Dd7f84089B90c tokenizer.out.json tokenizer.hex
```

`check-runtime.mjs` links the tokenizer's three runtime libraries from the record. The same four lines with any other address in the table check that contract.

The code halves, from the input `check-token-code.mjs` writes for them:

```sh
node hookr-1/revenue-tokenizer-v2/check-token-code.mjs --input > token-code.json
solc-0.8.37 --standard-json token-code.json > token-code.out.json
cast code 0x99b498Aa5f073b70De35e317A8bFB1BB8386a78A > half0.hex
cast code 0xcccD15Ac6aA42d77874Af26b7b73DF634512d6e0 > half1.hex
node hookr-1/revenue-tokenizer-v2/check-token-code.mjs token-code.out.json half0.hex half1.hex
```

It prints `MATCH` when the halves joined are the token's creation code linked to the record's libraries, the first half holds exactly `SPLIT` (14,000) bytes, and `HookrRevenueTokenCode` built here carries the metadata hash the record names.

There is no Forge profile for this folder: its metadata records the build tree's remappings, and `standard-input.mjs` is the byte-exact build.

## Verification

The fourteen roles other than the two halves, and the leg collector, are exact matches on Sourcify: runtime and creation code, metadata hash included. The two halves are exact creation matches, with no runtime match, as their runtime is data.

## Status

Deployed. The first Revenue Tokenizer, `0xfb3c1501c727f30883cd7B36Ec380381af7412Ef`, its add-ons and every revenue token it made are unchanged: this release deploys new contracts beside them and changes none of theirs. No independent audit of the tokenizer has been completed.
