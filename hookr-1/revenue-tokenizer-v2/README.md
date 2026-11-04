# Revenue Tokenizer v2

`HookrRevenueTokenizer` locks fee rights and mints a fixed-supply revenue token whose holders share the income the rights earn, in the same transaction, and adds more streams to that token later. It is the current tokenizer on Robinhood Chain (chain id 4663); the first [Revenue Tokenizer](../revenue-tokenizer/README.md) is the earlier version and is unchanged. Nothing in it has an owner: every outside address it uses is fixed in its constructor, and no function changes a pin, pauses it or moves a locked right before its term ends.

It is deployed three times from the same sources and settings. The first set went live on 2026-10-24. The second set went live on 2026-10-28 with the [combined core](../combined-core/README.md) first in its Rules list, so the market `defaultMarket` opens for a revenue token binds the core; its time shares and compounder add-ons followed on 2026-10-29. Neither of the first two tokenizers had minted a revenue token at block 100,509,391. The third set went live on 2026-11-01 with [core 2](../core-2/README.md) first in its Rules list and core 2's launcher, and its own time shares and compounder factories followed on 2026-11-02.

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

### The first set

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

Each runtime keccak256 above and below is the address's code hash read from the chain at block 100,509,391 and again at block 105,937,713, the record's `checkedAtBlock`.

The tokenizer's pins: `HookrLauncher` `0x1cf2748A6670572425eAbf9Ab9e5BC4eb2eB8Ef4`, `HookrFamilyLock` `0xfAFEcE64099C1E791C4B46189c277f00c0c7e00b`, `HookrRoot` `0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc`, the release's Rules `0x4a71c270b1520F94064268102AebD744b0DE7942` and the King of the Pool whole-pot Rules `0x10f684361b35C8411a2c07F68A6fB1F4B7e555F7`, `HookrTreasury` `0x2242F7FC75606500503075f29ea8cDA684EfB4a9`, the Fee Beneficiary vaults `0xd35E9CA72F64C7F93BE30fad67524323396B36D7` and `0x26d2F7AcB07707034406a0dC458351Bb63C02553`, the Fee Bridge factory `0x85D2F6c536336C17B79BE740C6bbb6c7d8D9b23D`, Uniswap's v4 PositionManager `0x58daec3116aae6D93017bAAea7749052E8a04fA7` and v3 NonfungiblePositionManager `0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3`, the six door factories and the two code halves above, and the code hash of the pools.trade fee splitters, `0x8238e5106b3a895514083110d1f3b4e51be61148604f35113719af56ae325f42`. Its constructor checks that the four door factories pinned to it (v4, v3, Fee Beneficiary NFT and revenue token) name it.

The other contracts' pins: the v4 door factory, the PositionManager, `HookrRoot` and the tokenizer; the v3 door factory, the v3 NonfungiblePositionManager and the tokenizer; the Fee Beneficiary NFT door factory, the tokenizer, the PositionManager and the fee splitters' code hash; the revenue token door factory and the state view, the tokenizer; the Pons door factory, the Pons V2 launch factory `0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e`; the Long door factory, the Doppler hook initializer `0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544` and the integrator `0x92d435C96E63c43E12d6D0AB28f6b0B04072F765`; the leg collector, `HookrTreasury`.

### The second set

Deployed on 2026-10-28 between blocks 100,179,470 and 100,179,563, in sixteen transactions from the same account (nonces 410 to 425), the same way as the first set but with salt counter 2, so every role gets a new address. The tokenizer's constructor creates the seventeenth, `HookrLegCollector`. Its sources and settings are the first set's, file for file.

| Contract | What it is | Address | Runtime keccak256 | Verified source |
| --- | --- | --- | --- | --- |
| `HookrRevenueTokenizer` | The tokenizer | [`0x522723A7a09684515881568Ab8247f3846D66F43`](https://robin.etherscan.io/address/0x522723A7a09684515881568Ab8247f3846D66F43#code) | `0x7354921cc2efdf91d7f760917c1bdadefd5ce24909fd729b02a5b35f33548a9e` | [exact match](https://repo.sourcify.dev/4663/0x522723A7a09684515881568Ab8247f3846D66F43) |
| `HookrLegCollector` | Created by the tokenizer in its constructor: takes Hookr's leg and sweeps it to the treasury's target | [`0x5a28571362d1dd512299deb80b895C72F705D8c3`](https://robin.etherscan.io/address/0x5a28571362d1dd512299deb80b895C72F705D8c3#code) | `0x442162f15638b66d8e71ce9a48926165fd55a1823d986696e24b11c3217cc200` | [exact match](https://repo.sourcify.dev/4663/0x5a28571362d1dd512299deb80b895C72F705D8c3) |
| `HookrRevenueStreams` | Linked library: `tokenize` and `addStreams` in full | [`0x2303faa3322D2Ef935C3e9ab90388F9AeBFAC98f`](https://robin.etherscan.io/address/0x2303faa3322D2Ef935C3e9ab90388F9AeBFAC98f#code) | `0x18d2284d8f8f8795fe4d45014a34939210d1cb7e6b51439f778c4b99b74d38e9` | [exact match](https://repo.sourcify.dev/4663/0x2303faa3322D2Ef935C3e9ab90388F9AeBFAC98f) |
| `HookrRevenueMarketOpener` | Linked library: a new Hookr launch, and the revenue token's own market with its Fee Bridge | [`0x3c278bd8449d127E02517f520bfBc1f3d84F3B21`](https://robin.etherscan.io/address/0x3c278bd8449d127E02517f520bfBc1f3d84F3B21#code) | `0x642fc4ced8d1c5086edad8a3dd22ada019c520d8fb2369e86774468f0e367dd9` | [exact match](https://repo.sourcify.dev/4663/0x3c278bd8449d127E02517f520bfBc1f3d84F3B21) |
| `HookrRevenueDoorDeployer` | Linked library: the family doors, the checks of a launch, a market and an outside source, and the position doors | [`0x69FdAcEf9988E3e540FeADE656e7B710215510F3`](https://robin.etherscan.io/address/0x69FdAcEf9988E3e540FeADE656e7B710215510F3#code) | `0xc0763b0da75748efa865ac168e53e7e1d5f9a0d275336ab79bb4d97735daec47` | [exact match](https://repo.sourcify.dev/4663/0x69FdAcEf9988E3e540FeADE656e7B710215510F3) |
| `HookrSignatures` | Linked library: the one signature check behind every signed path of a revenue token and its drop box (ECDSA, then ERC-1271) | [`0xCCfAc915b6070446FC387773B401924333c95240`](https://robin.etherscan.io/address/0xCCfAc915b6070446FC387773B401924333c95240#code) | `0x1db8ef85d6897fb15c92906497443e6a234397084e04d07e8ada2d8f8dc5d025` | [exact match](https://repo.sourcify.dev/4663/0xCCfAc915b6070446FC387773B401924333c95240) |
| `HookrIncomeRecovery` | Linked library: bounded collection of the drops that shares held by a revenue token or its drop box earn, and of a token's income from another revenue token | [`0xA82C607A4B38C7762Ab5aD3734AB5A0b0cF5001c`](https://robin.etherscan.io/address/0xA82C607A4B38C7762Ab5aD3734AB5A0b0cF5001c#code) | `0x6069c2680603602ca8eef32ff482cf2bb9f3d06b33024d13c66ab00e8d08e297` | [exact match](https://repo.sourcify.dev/4663/0xA82C607A4B38C7762Ab5aD3734AB5A0b0cF5001c) |
| `HookrDropBoxDeployer` | Linked library: deploys each revenue token's drop box from the token's constructor | [`0x0c97e8EBaA43D28e94f9e6AD1c78ac134FFF145E`](https://robin.etherscan.io/address/0x0c97e8EBaA43D28e94f9e6AD1c78ac134FFF145E#code) | `0x6eaddb5beec5986ed5acfc5084fc348d7886f0282ff05646dfe828aa20ba6a2d` | [exact match](https://repo.sourcify.dev/4663/0x0c97e8EBaA43D28e94f9e6AD1c78ac134FFF145E) |
| `HookrRevenueTokenCode.0` | Data: a STOP byte and bytes 0 to 13,999 of the revenue token's creation code | [`0x012198fFb092479c6fefd6F2C632264699954758`](https://robin.etherscan.io/address/0x012198fFb092479c6fefd6F2C632264699954758#code) | `0x628bdf1131753d2efe08c7e4112f1fdcdad577f9f5b27efd1e8e8bb02414b5ee` | [creation match](https://repo.sourcify.dev/4663/0x012198fFb092479c6fefd6F2C632264699954758) |
| `HookrRevenueTokenCode.1` | Data: a STOP byte and bytes 14,000 to 27,809 of the revenue token's creation code | [`0xd5492dDC0E0f436B2AFdB2b9BDf2117063540Ef3`](https://robin.etherscan.io/address/0xd5492dDC0E0f436B2AFdB2b9BDf2117063540Ef3#code) | `0xe7e355ee0df032de5efc43e90aacdaac94180f1ef6f25c529aad1836d5dfc8a2` | [creation match](https://repo.sourcify.dev/4663/0xd5492dDC0E0f436B2AFdB2b9BDf2117063540Ef3) |
| `HookrPositionNftDoorFactory` | Makes the v4 position doors | [`0xef47D719Ed82fCE84F7538D5D77280972eC479b2`](https://robin.etherscan.io/address/0xef47D719Ed82fCE84F7538D5D77280972eC479b2#code) | `0xf0a158959142c5933c48cb70293b8c940e594f9e4e38a118a1f0df8f3b996f60` | [exact match](https://repo.sourcify.dev/4663/0xef47D719Ed82fCE84F7538D5D77280972eC479b2) |
| `HookrV3PositionNftDoorFactory` | Makes the v3 position doors | [`0xB2E5d429CD36efacCc3B01a7C1E523319755Bf99`](https://robin.etherscan.io/address/0xB2E5d429CD36efacCc3B01a7C1E523319755Bf99#code) | `0xf158a943cd6aea586ca7e4d771dc874dc8a7b055a793ace3e36d6fd821715688` | [exact match](https://repo.sourcify.dev/4663/0xB2E5d429CD36efacCc3B01a7C1E523319755Bf99) |
| `HookrFeebAdapterFactory` | Makes the Fee Beneficiary NFT doors | [`0xE14f2B06877A74174C210F4d5E4587cdb8F06e10`](https://robin.etherscan.io/address/0xE14f2B06877A74174C210F4d5E4587cdb8F06e10#code) | `0x2a6416f082be9be5534a011d17727101c71c6d550e9f6024f56f16a7df2b3273` | [exact match](https://repo.sourcify.dev/4663/0xE14f2B06877A74174C210F4d5E4587cdb8F06e10) |
| `HookrRevenueTokenDoorFactory` | Makes the revenue token doors, which hold shares of another revenue token as a stream | [`0xCAfb37DD5e490714aEcA1597c91ca0F22D30dC57`](https://robin.etherscan.io/address/0xCAfb37DD5e490714aEcA1597c91ca0F22D30dC57#code) | `0x7273901e68e500f1b8c757f9cbdd8248b4babdae7f2bee03df339ae973130c28` | [exact match](https://repo.sourcify.dev/4663/0xCAfb37DD5e490714aEcA1597c91ca0F22D30dC57) |
| `HookrPonsAdapterFactory` | Makes the Pons doors, one per Pons V2 launch's creator fee | [`0x73711e882ef4a7AACD50306EE5E7201E778d00E3`](https://robin.etherscan.io/address/0x73711e882ef4a7AACD50306EE5E7201E778d00E3#code) | `0xed8778c10c7b4f73514f0b1740b9f270f4b5a6bcf3b41330e69d889eacd08551` | [exact match](https://repo.sourcify.dev/4663/0x73711e882ef4a7AACD50306EE5E7201E778d00E3) |
| `HookrDopplerAdapterFactory` | Makes the Long doors, one per Long launch's beneficiary share on Doppler | [`0xFBBD8E687d223864dcF083B6778C62a70aC6BA3A`](https://robin.etherscan.io/address/0xFBBD8E687d223864dcF083B6778C62a70aC6BA3A#code) | `0x1cdfe5345dc6b04aaddf1c3f7a70cb918ab9330554960ed5678633d8d7b998c5` | [exact match](https://repo.sourcify.dev/4663/0xFBBD8E687d223864dcF083B6778C62a70aC6BA3A) |
| `HookrRevenueStateView` | Read-only lens: a token's terms, assets, doors, and a holder's claimable income and open drops in one call | [`0x007EA7554DDD113Fa441f37F1d16f66030E1B81E`](https://robin.etherscan.io/address/0x007EA7554DDD113Fa441f37F1d16f66030E1B81E#code) | `0x283b0c2bb0991ce2218816b4c9b992abc9deab03837bff4585d8179b5fd30660` | [exact match](https://repo.sourcify.dev/4663/0x007EA7554DDD113Fa441f37F1d16f66030E1B81E) |

Its pins are the first set's but for two things. Its door factories and code halves are its own, the ones in the table above. Its Rules list is the core `0x8AD0aC66DbeBcc047e8d216666C925E797e5e52e`, then the release's Rules `0x4a71c270b1520F94064268102AebD744b0DE7942` and the King of the Pool whole-pot Rules `0x10f684361b35C8411a2c07F68A6fB1F4B7e555F7`; the first is the one `defaultMarket` binds.

### The third set

Deployed on 2026-11-01 between blocks 103,733,671 and 103,733,775, in sixteen transactions from the same account (nonces 524 to 539), the same way as the first two sets but with salt counter 3, so every role gets a new address. The tokenizer's constructor creates the seventeenth, `HookrLegCollector`. Its sources and settings are the first set's, file for file, and each contract's metadata hash is the first two sets'.

| Contract | What it is | Address | Runtime keccak256 | Verified source |
| --- | --- | --- | --- | --- |
| `HookrRevenueTokenizer` | The tokenizer | [`0xE1968Fde816b71Afc804005329A284e034019637`](https://robin.etherscan.io/address/0xE1968Fde816b71Afc804005329A284e034019637#code) | `0x45354da70c2df0042dbf3693ee672f6d930d6be107c4d027b1ce7857973660e4` | [exact match](https://repo.sourcify.dev/4663/0xE1968Fde816b71Afc804005329A284e034019637) |
| `HookrLegCollector` | Created by the tokenizer in its constructor: takes Hookr's leg and sweeps it to the treasury's target | [`0x6Cefe8cB2814E28eA1124b4e0ba330bc4d6c7315`](https://robin.etherscan.io/address/0x6Cefe8cB2814E28eA1124b4e0ba330bc4d6c7315#code) | `0x442162f15638b66d8e71ce9a48926165fd55a1823d986696e24b11c3217cc200` | [exact match](https://repo.sourcify.dev/4663/0x6Cefe8cB2814E28eA1124b4e0ba330bc4d6c7315) |
| `HookrRevenueStreams` | Linked library: `tokenize` and `addStreams` in full | [`0x17Bef8C291D278b3f9266320C588E8aa24387f97`](https://robin.etherscan.io/address/0x17Bef8C291D278b3f9266320C588E8aa24387f97#code) | `0xe5c78001c156f4a153b6f501968b4632acf98486cf8555637d86d0ec6b3a28d7` | [exact match](https://repo.sourcify.dev/4663/0x17Bef8C291D278b3f9266320C588E8aa24387f97) |
| `HookrRevenueMarketOpener` | Linked library: a new Hookr launch, and the revenue token's own market with its Fee Bridge | [`0x5D47E722a0A3fE84bf912D97cd69c60845461556`](https://robin.etherscan.io/address/0x5D47E722a0A3fE84bf912D97cd69c60845461556#code) | `0x6e526f0c801478ed9ee1a4d0ac9777e634c97bce22d2427f1bad6f576d409847` | [exact match](https://repo.sourcify.dev/4663/0x5D47E722a0A3fE84bf912D97cd69c60845461556) |
| `HookrRevenueDoorDeployer` | Linked library: the family doors, the checks of a launch, a market and an outside source, and the position doors | [`0x2e114D98816374126eAef89dCB66D6e25349A0e4`](https://robin.etherscan.io/address/0x2e114D98816374126eAef89dCB66D6e25349A0e4#code) | `0xefbc46d7f9cd92442681e9bcb1f11cb85ba79760a74b3d282daf016f83583e75` | [exact match](https://repo.sourcify.dev/4663/0x2e114D98816374126eAef89dCB66D6e25349A0e4) |
| `HookrSignatures` | Linked library: the one signature check behind every signed path of a revenue token and its drop box (ECDSA, then ERC-1271) | [`0x48814982d5A93A8A1A8c88181a9d1af3cdbc4CAc`](https://robin.etherscan.io/address/0x48814982d5A93A8A1A8c88181a9d1af3cdbc4CAc#code) | `0x1db8ef85d6897fb15c92906497443e6a234397084e04d07e8ada2d8f8dc5d025` | [exact match](https://repo.sourcify.dev/4663/0x48814982d5A93A8A1A8c88181a9d1af3cdbc4CAc) |
| `HookrIncomeRecovery` | Linked library: bounded collection of the drops that shares held by a revenue token or its drop box earn, and of a token's income from another revenue token | [`0xf16CB3de074e4e686526f99344d98B6662A01954`](https://robin.etherscan.io/address/0xf16CB3de074e4e686526f99344d98B6662A01954#code) | `0x30aa219c2c4e2ae2c9e17c86e48a56ad27ebbd8a73e01c061a621e385ee3e319` | [exact match](https://repo.sourcify.dev/4663/0xf16CB3de074e4e686526f99344d98B6662A01954) |
| `HookrDropBoxDeployer` | Linked library: deploys each revenue token's drop box from the token's constructor | [`0x6F54ca89d03D73CadB61741452688D5a497F2342`](https://robin.etherscan.io/address/0x6F54ca89d03D73CadB61741452688D5a497F2342#code) | `0x83e03af431193afa32a4b8a302f9a58362399c82f5417eb369dc29e56200b483` | [exact match](https://repo.sourcify.dev/4663/0x6F54ca89d03D73CadB61741452688D5a497F2342) |
| `HookrRevenueTokenCode.0` | Data: a STOP byte and bytes 0 to 13,999 of the revenue token's creation code | [`0xA42Dba2fADAE31f7262618cF61274625d68B1e81`](https://robin.etherscan.io/address/0xA42Dba2fADAE31f7262618cF61274625d68B1e81#code) | `0xe198df9cc8ec70cac0b7004951118b5be8bc2dbaef262427f7aaf8bb41471d8c` | [creation match](https://repo.sourcify.dev/4663/0xA42Dba2fADAE31f7262618cF61274625d68B1e81) |
| `HookrRevenueTokenCode.1` | Data: a STOP byte and bytes 14,000 to 27,809 of the revenue token's creation code | [`0x070D0Dc1D2a7b462643E413BC2583de8C80580DC`](https://robin.etherscan.io/address/0x070D0Dc1D2a7b462643E413BC2583de8C80580DC#code) | `0x14b6e373517d73fbe35e0e91c13de40b380c5768ab3b7ee7a5b56de60e2be910` | [creation match](https://repo.sourcify.dev/4663/0x070D0Dc1D2a7b462643E413BC2583de8C80580DC) |
| `HookrPositionNftDoorFactory` | Makes the v4 position doors | [`0x587e98fE9B3937466eEdE5f15C5bd9576df3800F`](https://robin.etherscan.io/address/0x587e98fE9B3937466eEdE5f15C5bd9576df3800F#code) | `0xe65bd01d4fb9e35f778758e032fa7da2d6121a09ff8610487696060830d013c3` | [exact match](https://repo.sourcify.dev/4663/0x587e98fE9B3937466eEdE5f15C5bd9576df3800F) |
| `HookrV3PositionNftDoorFactory` | Makes the v3 position doors | [`0xbaaF5726fB927aa7e61e8865a31C3183579c2F50`](https://robin.etherscan.io/address/0xbaaF5726fB927aa7e61e8865a31C3183579c2F50#code) | `0x063dea6f4505645de9fd544d665ede5306087342bb9f42f2cd4ae68f04516421` | [exact match](https://repo.sourcify.dev/4663/0xbaaF5726fB927aa7e61e8865a31C3183579c2F50) |
| `HookrFeebAdapterFactory` | Makes the Fee Beneficiary NFT doors | [`0x4E8763114B90aE4d323bE56849FE069d3898EF68`](https://robin.etherscan.io/address/0x4E8763114B90aE4d323bE56849FE069d3898EF68#code) | `0xcd23cb9a50ff62faa5daf61ecd6e5a6c5dc13bfe112107437b84535926b08664` | [exact match](https://repo.sourcify.dev/4663/0x4E8763114B90aE4d323bE56849FE069d3898EF68) |
| `HookrRevenueTokenDoorFactory` | Makes the revenue token doors, which hold shares of another revenue token as a stream | [`0x77aC74A1e1CA904C8D90D66A9F1486Ec7301Ed6D`](https://robin.etherscan.io/address/0x77aC74A1e1CA904C8D90D66A9F1486Ec7301Ed6D#code) | `0xbe6e48c4dc9877deeeb8f653880f9a58b9d133ac08ed994ee6b90a0734b1d285` | [exact match](https://repo.sourcify.dev/4663/0x77aC74A1e1CA904C8D90D66A9F1486Ec7301Ed6D) |
| `HookrPonsAdapterFactory` | Makes the Pons doors, one per Pons V2 launch's creator fee | [`0x9655a9AeAD9c33032649E3a70e152d831aCeCd1a`](https://robin.etherscan.io/address/0x9655a9AeAD9c33032649E3a70e152d831aCeCd1a#code) | `0xed8778c10c7b4f73514f0b1740b9f270f4b5a6bcf3b41330e69d889eacd08551` | [exact match](https://repo.sourcify.dev/4663/0x9655a9AeAD9c33032649E3a70e152d831aCeCd1a) |
| `HookrDopplerAdapterFactory` | Makes the Long doors, one per Long launch's beneficiary share on Doppler | [`0x7309b6aDc24d590E19079C732be7e11eF6Ba485F`](https://robin.etherscan.io/address/0x7309b6aDc24d590E19079C732be7e11eF6Ba485F#code) | `0x1cdfe5345dc6b04aaddf1c3f7a70cb918ab9330554960ed5678633d8d7b998c5` | [exact match](https://repo.sourcify.dev/4663/0x7309b6aDc24d590E19079C732be7e11eF6Ba485F) |
| `HookrRevenueStateView` | Read-only lens: a token's terms, assets, doors, and a holder's claimable income and open drops in one call | [`0x2Ea3546912F308438e16F1a4fdEbCc27598718C6`](https://robin.etherscan.io/address/0x2Ea3546912F308438e16F1a4fdEbCc27598718C6#code) | `0xcc016b36a1b9f2a9a5cc0fabcfd36f9c412026c09c29ef565c078cf287516b05` | [exact match](https://repo.sourcify.dev/4663/0x2Ea3546912F308438e16F1a4fdEbCc27598718C6) |

Its pins are the second set's but for three things. Its door factories and code halves are its own, the ones in the table above. Its launcher and family lock are [core 2](../core-2/README.md)'s, `HookrLauncher` `0x70a66ADF39B5c9FfEE4A9F081C182edfbb7DBD0C` and `HookrFamilyLock` `0x5248AF9139DaDEf0C5296342b7BE441deDf0adC2`. Its Rules list is core 2 `0x342bAA22e202954593b04B7eD1663621E0565d46`, then the combined core `0x8AD0aC66DbeBcc047e8d216666C925E797e5e52e`, the release's Rules `0x4a71c270b1520F94064268102AebD744b0DE7942` and the King of the Pool whole-pot Rules `0x10f684361b35C8411a2c07F68A6fB1F4B7e555F7`; the first is the one `defaultMarket` binds.

### The add-ons

Deployed on 2026-10-29 between blocks 100,475,141 and 100,475,160, in four transactions from the same account (nonces 453 to 456), through the same CREATE3 factory, salt counter 1. They serve the second set's revenue tokens: the time shares factory is pinned to its tokenizer `0x522723A7a09684515881568Ab8247f3846D66F43`, and the compounder factory to that tokenizer and the PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951`.

| Contract | What it is | Address | Runtime keccak256 | Verified source |
| --- | --- | --- | --- | --- |
| `HookrTimeSharesFactory` | Makes one time shares contract per revenue token of the second set | [`0x861e5E8f9D6a2471A1e013248265cE2cF0718dad`](https://robin.etherscan.io/address/0x861e5E8f9D6a2471A1e013248265cE2cF0718dad#code) | `0x93b140beff249ac1ade5542137201b34124eec1e5a5e40b03d02d331e640ebba` | [exact match](https://repo.sourcify.dev/4663/0x861e5E8f9D6a2471A1e013248265cE2cF0718dad) |
| `HookrTimeShareWrapperFactory` | Makes one wrapper per time shares contract and day: the ERC-20 form of that day's units | [`0x41871eef4E231b1F6d88FF0F67fb47fcC4041BC0`](https://robin.etherscan.io/address/0x41871eef4E231b1F6d88FF0F67fb47fcC4041BC0#code) | `0x7f9b38c6e25c5fbbbff002ce2ef38a2ccedbf870b9d7f0bfdc14150405582e9b` | [exact match](https://repo.sourcify.dev/4663/0x41871eef4E231b1F6d88FF0F67fb47fcC4041BC0) |
| `HookrRevenueCompounderFactory` | Makes one compounder vault per revenue token of the second set | [`0x3D3C0538e81E169d51693c3Ac7F0fb7d672d9e46`](https://robin.etherscan.io/address/0x3D3C0538e81E169d51693c3Ac7F0fb7d672d9e46#code) | `0xd8d0610497e345cc020f3f3621cd0037e700dca579bbd26b7b7920591d7bd329` | [exact match](https://repo.sourcify.dev/4663/0x3D3C0538e81E169d51693c3Ac7F0fb7d672d9e46) |
| `HookrCompounderLens` | The compounder's reads, computed from the vault and the PoolManager; stateless | [`0x4F05627CD245b09ca021252B9463FD3a871Aa4E8`](https://robin.etherscan.io/address/0x4F05627CD245b09ca021252B9463FD3a871Aa4E8#code) | `0x222e18ba0f51f4b728875190bece21d8d2f902e0b1184e320985582747c414e7` | [exact match](https://repo.sourcify.dev/4663/0x4F05627CD245b09ca021252B9463FD3a871Aa4E8) |

- **Time shares.** Lock revenue tokens for whole UTC days, or forever, and get one ERC-6909 unit per locked revenue token for each day of the lock; a day's units earn only that day's income, in every asset the token pays. The revenue tokens go back once the last day has ended; a forever lock never returns. A drop to the token's holders is paid to the locks that held at its snapshot block, through `claimLock`. The wrapper is the ERC-20 form of one day's units. `roll()` books the income the token owes the time shares to the days it belongs to.
- **Compounder.** One opt-in vault per revenue token. Deposits earn the token's income, the vault places that income in the token's pool as single-sided liquidity, and shares redeem pro rata for everything the vault holds. `poke()` claims the income and places it.

`roll` and `poke` are calls anyone can make, and each can pay its caller a tip. Each factory's constructor writes the creation code of what it makes into two data contracts, and makes every instance from them. The record lists them under their factories as `dataContracts`:

| Contract | Address | Runtime keccak256 | Holds |
| --- | --- | --- | --- |
| `HookrCodeChunk` | [`0x37bf682069785d6974cA80508eAE87284254f016`](https://robin.etherscan.io/address/0x37bf682069785d6974cA80508eAE87284254f016#code) | `0x6b475b07ec51e7dc75d317039a915a3a86c1783b3cca671a23cf0c0435f70471` | bytes 0 to 23,999 of the creation code of src/HookrRevenueCompounder.sol:HookrRevenueCompounder, after a leading STOP byte |
| `HookrCodeChunk` | [`0x86aB752c22c9EEd829Eae0Ac914e0D449e5b51A9`](https://robin.etherscan.io/address/0x86aB752c22c9EEd829Eae0Ac914e0D449e5b51A9#code) | `0x32d799e93c1d64742aa0d01b90b389af760f1ac332fa1ae084db1f93c38e7d9a` | bytes 24,000 to 28,772 of the creation code of src/HookrRevenueCompounder.sol:HookrRevenueCompounder, after a leading STOP byte |
| `HookrTimeSharesData` | [`0x9D95b0B3e4103e429E49fE62dD5E88a9913BC084`](https://robin.etherscan.io/address/0x9D95b0B3e4103e429E49fE62dD5E88a9913BC084#code) | `0x5b90cdf4659023c9855272f22e725ceeb918762cb1492e4e038d11690cf8e1d0` | bytes 0 to 12,618 of the creation code of src/HookrTimeShares.sol:HookrTimeShares |
| `HookrTimeSharesData` | [`0x2Df8a1DC447bdCf3710aA0FAE96F11cc45fE8723`](https://robin.etherscan.io/address/0x2Df8a1DC447bdCf3710aA0FAE96F11cc45fE8723#code) | `0x6442cb0b6f64d17e37259ab68a68dac58d2ee24c9fc8c026dd5d6f06e82b617e` | bytes 12,619 to 25,237 of the creation code of src/HookrTimeShares.sol:HookrTimeShares |

A compounder code chunk's runtime is a STOP byte followed by its piece; a time shares data contract's runtime is its piece alone, half the code each. They are data, not verified source. [`../revenue-tokenizer/check-code-chunks.mjs`](../revenue-tokenizer/check-code-chunks.mjs) and [`time-shares/check-time-shares-code.mjs`](./time-shares/check-time-shares-code.mjs) check that each pair is the creation code built from the sources here (section "Building it").

### The third set's add-ons

Deployed on 2026-11-02 in blocks 103,975,727 and 103,975,860, in two transactions from the same account (nonces 540 and 541), through the same CREATE3 factory, salt counter 3. They are the second set's time shares and compounder factories, file for file, pinned to the third tokenizer `0xE1968Fde816b71Afc804005329A284e034019637` (and the compounder factory to the PoolManager). `HookrTimeShareWrapperFactory` and `HookrCompounderLens` above take no tokenizer and serve the third set too.

| Contract | What it is | Address | Runtime keccak256 | Verified source |
| --- | --- | --- | --- | --- |
| `HookrTimeSharesFactory` | Makes one time shares contract per revenue token of the third set | [`0x4127C181a4b8E43806099e1B5a5EF7c22dd70785`](https://robin.etherscan.io/address/0x4127C181a4b8E43806099e1B5a5EF7c22dd70785#code) | `0x98ab8fd66dbfd99c6b5539cb84b4a25b43b68e8108eb9847e3585543219c1abf` | [exact match](https://repo.sourcify.dev/4663/0x4127C181a4b8E43806099e1B5a5EF7c22dd70785) |
| `HookrRevenueCompounderFactory` | Makes one compounder vault per revenue token of the third set | [`0x977E77424a69C2C3a5E48Be9a61F5a1A54650bf8`](https://robin.etherscan.io/address/0x977E77424a69C2C3a5E48Be9a61F5a1A54650bf8#code) | `0x958f89ce8e40d25a85f1e429a14e694dd22e21330b377e6ae2e0a60c4fbadf83` | [exact match](https://repo.sourcify.dev/4663/0x977E77424a69C2C3a5E48Be9a61F5a1A54650bf8) |

Each factory's constructor wrote its data contracts, which the record lists under it as `dataContracts`, and which the same two scripts check:

| Contract | Address | Runtime keccak256 | Holds |
| --- | --- | --- | --- |
| `HookrCodeChunk` | [`0xFF97fb4f3893c56a44C52F546d5E23C3B356Cb98`](https://robin.etherscan.io/address/0xFF97fb4f3893c56a44C52F546d5E23C3B356Cb98#code) | `0x6b475b07ec51e7dc75d317039a915a3a86c1783b3cca671a23cf0c0435f70471` | bytes 0 to 23,999 of the creation code of src/HookrRevenueCompounder.sol:HookrRevenueCompounder, after a leading STOP byte |
| `HookrCodeChunk` | [`0x0D1C1e94cD9890493B76347f126Def2a6dDFbDC5`](https://robin.etherscan.io/address/0x0D1C1e94cD9890493B76347f126Def2a6dDFbDC5#code) | `0x32d799e93c1d64742aa0d01b90b389af760f1ac332fa1ae084db1f93c38e7d9a` | bytes 24,000 to 28,772 of the creation code of src/HookrRevenueCompounder.sol:HookrRevenueCompounder, after a leading STOP byte |
| `HookrTimeSharesData` | [`0xbbA5E4140770e59A5758693beec0132F7C256846`](https://robin.etherscan.io/address/0xbbA5E4140770e59A5758693beec0132F7C256846#code) | `0x5b90cdf4659023c9855272f22e725ceeb918762cb1492e4e038d11690cf8e1d0` | bytes 0 to 12,618 of the creation code of src/HookrTimeShares.sol:HookrTimeShares |
| `HookrTimeSharesData` | [`0x915417E338367AFeaA0a3182f26dB9895ce3F2aC`](https://robin.etherscan.io/address/0x915417E338367AFeaA0a3182f26dB9895ce3F2aC#code) | `0x6442cb0b6f64d17e37259ab68a68dac58d2ee24c9fc8c026dd5d6f06e82b617e` | bytes 12,619 to 25,237 of the creation code of src/HookrTimeShares.sol:HookrTimeShares |

### Contracts made later

These have no fixed address. Each is created by a contract above, from creation code compiled into it from the sources here, once per set of the tokenizer.

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
| `HookrTimeShares`, one per revenue token, and `HookrTimeShareWrapper`, one per time shares contract and day | `HookrTimeSharesFactory`, from its data contracts, and `HookrTimeShareWrapperFactory` | [`time-shares/src/`](./time-shares/src/) |
| `HookrRevenueCompounder`, one per revenue token | `HookrRevenueCompounderFactory`, from its code chunks | [`compounder/src/HookrRevenueCompounder.sol`](./compounder/src/HookrRevenueCompounder.sol) |

### The revenue token's code halves

The revenue token's creation code, 27,810 bytes linked to its three libraries (`HookrSignatures`, `HookrIncomeRecovery` and `HookrDropBoxDeployer`), is larger than one contract's runtime may be. Two `HookrRevenueTokenCode` contracts hold it: each one's runtime is a STOP byte followed by its half, bytes 0 to 13,999 in `HookrRevenueTokenCode.0` and bytes 14,000 to 27,809 in `HookrRevenueTokenCode.1`. The tokenizer reads both and creates every revenue token from them.

Their runtime is data, so no compiled runtime can match it. Sourcify matches their creation code instead, exactly, and every revenue token's own exact match binds their content: a token's code is what the two halves hold. The record lists the halves under the tokenizer as `dataContracts`, each with the sources and settings of its creation match. [`check-token-code.mjs`](./check-token-code.mjs) checks that the two together are the revenue token's creation code built from the sources here, linked to the three libraries above (section "Building it").

### CREATE3 proxies

Each of the fifty-four CREATE3 deployments leaves the factory's 8-byte proxy (`0x363d3d37363d34f0`) at its own address. The record lists each one as its contract's `deployment.proxy`, as it does for every other CREATE3 deployment.

## Hookr's leg

Hookr's leg is 5% (`HOOKR_LEG_BPS_OUTSIDE`, 500) of what each door outside the Hookr root delivers: a Fee Beneficiary NFT door, v4 positions off the root, a v3 position door and an outside source. The token sends it to `HookrLegCollector` in the sync that pulls the door, in each listed asset that arrived. A door that already pays Hookr through its hook (a Rules ledger, a family door, v4 positions that sit on the root) and a revenue token door carry no leg (`HOOKR_LEG_BPS_HOOKR`, 0). Both are constants, fixed per door when it is added. The first tokenizer minted its leg as shares of each revenue token; this one mints none to the collector.

Hookr passes 1 point of that 5% leg on to What The Hook (WTH). The contracts do not do this: the collector sweeps the whole leg to the treasury's target, and Hookr sends WTH its point from there.

The collector keeps nothing for itself: anyone can sweep what it holds to `HookrTreasury`'s current `target()`.

## Not in this release

The experimental lending module and the campaign periphery are not part of this release. None of their code is deployed, and none of it is in this folder: the files here are exactly the sources compiled into the contracts above.

## Where the files are

| Folder | Holds | Build tree name |
| --- | --- | --- |
| [`src/`](./src/) | The tokenizer, its libraries, the code halves, the door factories, the state view, the leg collector and every contract they make, 83 files | `src/...`; `../hookrevenue-v2/src/...` for the add-ons |
| [`time-shares/src/`](./time-shares/src/) | The time shares add-on, 12 files | `src/...` |
| [`compounder/src/`](./compounder/src/) | The compounder add-on, 12 files | `src/...` |

Every file is byte-identical to the verified source on Sourcify, and its keccak256 is in the record's `sourceKeccak256`. The release files they import (`../hookr-phase-one/src/...` in the metadata, 10 files) are the release's own files in [`../src/`](../src/), and the dependencies (`../../../contracts/lib/...`, 47 files) are the pinned submodules in [`../../lib/`](../../lib/). Those 57 files were already published, and each one's keccak256 equals the one the metadata of the contracts here records. The add-ons were built from folders beside the tokenizer's, so their metadata names its files `../hookrevenue-v2/src/...` (10 files, all in [`src/`](./src/)), the release's `../hookr-phase-one/src/...` (5 files) and the dependencies `../../../contracts/lib/...` (48 files).

## Building it

All three sets of seventeen compile with solc 0.8.37 (`0.8.37+commit.f401782d`), via-IR, the optimizer at 50 runs, EVM version prague, and the IPFS metadata hash. The release itself uses 200 runs, and so do the add-ons. The record's settings profiles `revenue-tokenizer-v2`, `revenue-tokenizer-v2-time-shares` and `revenue-tokenizer-v2-compounder` hold the exact settings, read from the verified metadata.

The compiler input for any of the fifty-one exact matches comes from the record, which maps each source unit name to its file here; `node hookr-1/standard-input.mjs --list` names them under `revenue-tokenizer-v2`:

```sh
node hookr-1/standard-input.mjs 0xAD0F7575F6476d5a37a4aBAF109Dd7f84089B90c > tokenizer.json
solc-0.8.37 --standard-json tokenizer.json > tokenizer.out.json
cast code 0xAD0F7575F6476d5a37a4aBAF109Dd7f84089B90c > tokenizer.hex   # with ETH_RPC_URL set to a chain 4663 node
node hookr-1/check-runtime.mjs 0xAD0F7575F6476d5a37a4aBAF109Dd7f84089B90c tokenizer.out.json tokenizer.hex
```

`check-runtime.mjs` links the tokenizer's three runtime libraries from the record. The same four lines with any other address in the tables check that contract.

The code halves, from the input `check-token-code.mjs` writes for them:

```sh
node hookr-1/revenue-tokenizer-v2/check-token-code.mjs --input > token-code.json
solc-0.8.37 --standard-json token-code.json > token-code.out.json
cast code 0x99b498Aa5f073b70De35e317A8bFB1BB8386a78A > half0.hex
cast code 0xcccD15Ac6aA42d77874Af26b7b73DF634512d6e0 > half1.hex
node hookr-1/revenue-tokenizer-v2/check-token-code.mjs token-code.out.json half0.hex half1.hex
```

It prints `MATCH` when the halves joined are the token's creation code linked to the record's libraries, the first half holds exactly `SPLIT` (14,000) bytes, and `HookrRevenueTokenCode` built here carries the metadata hash the record names. The second and third sets' halves come from the same input; name the set's tokenizer last, so the check links that set's libraries:

```sh
cast code 0x012198fFb092479c6fefd6F2C632264699954758 > half0.hex
cast code 0xd5492dDC0E0f436B2AFdB2b9BDf2117063540Ef3 > half1.hex
node hookr-1/revenue-tokenizer-v2/check-token-code.mjs token-code.out.json half0.hex half1.hex 0x522723A7a09684515881568Ab8247f3846D66F43
cast code 0xA42Dba2fADAE31f7262618cF61274625d68B1e81 > half0.hex
cast code 0x070D0Dc1D2a7b462643E413BC2583de8C80580DC > half1.hex
node hookr-1/revenue-tokenizer-v2/check-token-code.mjs token-code.out.json half0.hex half1.hex 0xE1968Fde816b71Afc804005329A284e034019637
```

The add-ons' data contracts, from their factories' outputs:

```sh
node hookr-1/standard-input.mjs 0x3D3C0538e81E169d51693c3Ac7F0fb7d672d9e46 > compounder.json
solc-0.8.37 --standard-json compounder.json > compounder.out.json
cast code 0x37bf682069785d6974cA80508eAE87284254f016 > chunk0.hex
cast code 0x86aB752c22c9EEd829Eae0Ac914e0D449e5b51A9 > chunk1.hex
node hookr-1/revenue-tokenizer/check-code-chunks.mjs compounder.out.json chunk0.hex chunk1.hex

node hookr-1/standard-input.mjs 0x861e5E8f9D6a2471A1e013248265cE2cF0718dad > time-shares.json
solc-0.8.37 --standard-json time-shares.json > time-shares.out.json
cast code 0x9D95b0B3e4103e429E49fE62dD5E88a9913BC084 > data0.hex
cast code 0x2Df8a1DC447bdCf3710aA0FAE96F11cc45fE8723 > data1.hex
node hookr-1/revenue-tokenizer-v2/time-shares/check-time-shares-code.mjs time-shares.out.json data0.hex data1.hex
```

There is no Forge profile for these folders: their metadata records the build trees' remappings, and `standard-input.mjs` is the byte-exact build.

## Verification

In each set, the fourteen roles other than the two halves, and the leg collector, are exact matches on Sourcify: runtime and creation code, metadata hash included, and so are the six add-ons. The halves are exact creation matches, with no runtime match, as their runtime is data. The add-ons' code chunks and data contracts have no source of their own; the checks above bind them, and so will the exact match of every vault and time shares contract made from them.

## Status

Deployed. The first Revenue Tokenizer, `0xfb3c1501c727f30883cd7B36Ec380381af7412Ef`, its add-ons and every revenue token it made are unchanged: each set of this release deploys new contracts beside them and changes none of theirs. No independent audit of the tokenizer or its add-ons has been completed.
