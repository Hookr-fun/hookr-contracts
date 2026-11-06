# Revenue Tokenizer

`HookrRevenueTokenizer` at [`0x08De138e558a9258c6B4077E8bdeB9ad1fB46a4B`](https://robin.etherscan.io/address/0x08De138e558a9258c6B4077E8bdeB9ad1fB46a4B#code) locks fee rights and mints a fixed-supply revenue token whose holders share the income those fee rights earn, in the same transaction, and adds more streams to that token later. It keeps no list of Rules: on every launch and every new Rules stream it asks `HookrRegistry` whether that Rules is admitted on `HookrRoot`.

Nothing here has an owner. Every outside address the tokenizer uses, but the Rules, is fixed in its constructor, and no function changes a pin, pauses it or moves a locked fee right before its term ends. Anyone can call it directly.

## Which Rules it takes

- A Rules counts while `HookrRegistry` admits it on `HookrRoot` as a Rules contract, with the code and schema the root checks, and while it trusts the root. `isAdmittedRules(rules)` answers live.
- A newly admitted Rules is usable as soon as its admission executes. Nothing here is deployed again.
- A revoked Rules is refused at once for a launch, a market and a Rules stream. A family already open on it can still be handed in. Tokens already minted on it keep their pools, doors and income, and none of them reads the registry again after the mint.
- The registry's owner decides what is admitted, with a 30-minute delay. The owner or the registry's guardian can revoke at once.

## What it does

- **Ways in.** `tokenize` locks any streams and mints the revenue token in one transaction: a new Hookr launch on `HookrRoot`, Hookr families handed in, a pool's Rules ledger, Fee Beneficiary NFTs, Uniswap v4 and v3 position NFTs, shares of another revenue token, and any outside fee right through an `IHookrRevenueSource` door. It can also open the revenue token's own market at mint.
- **The market.** `defaultMarket(rules, token, quote, sqrtPriceX96, seed)` builds the market's terms on the Rules you name.
- **Streams only grow.** `addStreams` locks more streams into a revenue token the tokenizer made, for as long as the token has a stream manager. A token minted with `openStreams` also takes streams from anyone, of every kind but an outside `IHookrRevenueSource` door. Nothing removes a stream or changes its door or its leg.
- **The revenue token.** A fixed-supply ERC-20 with no owner, no pause and no second mint. It lists up to eight assets its income is paid in: native ETH first, then up to seven ERC-20s.
- **Doors.** Each fee right reaches the token through a door: a pool's Rules ledger, the token's family door (`HookrFamilyForwarder`), a Fee Beneficiary NFT door, a v4 or v3 position door, a revenue token door, or an outside `IHookrRevenueSource` door.
- **Sync.** `sync()`, `syncRange()` and `syncSome()` pull the doors, each on its own gas stipend, and recognize what arrived by balance delta. Anyone may call them, and the caller is paid the tip fixed at mint, at most 1% of the ETH the doors delivered, once they deliver 0.001 ETH.
- **Income.** Each arrival is claimable as soon as a sync recognizes it, or released to holders over the token's release period when the creator sets one, up to 14 days. It is shared pro rata, without staking.
- **Recapture in another currency.** `addRulesCredits(i, member)` on the family door lists a recapture currency that is neither side of a pool, so that income reaches the holders. Anyone may call it.
- **Drops.** Each revenue token has its own drop box. Anyone can drop ETH or any ERC-20 for the holders, who claim it by their balance at the end of the block before the drop.
- **Terms.** A fee right in a family, position, Fee Beneficiary NFT or revenue token door is locked for good or for a term the creator sets, at least seven days. The account that locked it can move the end later, never earlier (`extendTerm`). At the end of a term anyone can call `release`, and the fee right goes back to that account. A Rules ledger has no term, and an outside `IHookrRevenueSource` door answers its own end, which can be revocable.
- **Hook Blocks.** Every block the registry admits binds on a tokenized launch as on a normal one. Tax + Conversion's creator payout must name the revenue token (`AdvisoryRecipientMismatch` otherwise). Any other block admitted to take quote pays its own payee and is reported (`AdvisoryPayeeUnchecked`).

## The contracts

Deployed on 2026-11-06 between blocks 107,699,158 and 107,699,953, in ten transactions from `0x0c0967485A25F18E70262a2Ee80c7595CC64a5fC`. Each goes through the CREATE3 factory at `0xc7c662Fc760FE1d5cB97fd8A68cb43A046da3F7d`, release id `hookr-1`, with the contract's name as its role and salt counter 4. The tokenizer's constructor creates `HookrLegCollector`, and the time shares factory's constructor creates its two data contracts.

| Contract | What it is | Address | Verified source |
| --- | --- | --- | --- |
| `HookrRevenueTokenizer` | The tokenizer | [`0x08De138e558a9258c6B4077E8bdeB9ad1fB46a4B`](https://robin.etherscan.io/address/0x08De138e558a9258c6B4077E8bdeB9ad1fB46a4B#code) | [exact match](https://repo.sourcify.dev/4663/0x08De138e558a9258c6B4077E8bdeB9ad1fB46a4B) |
| `HookrLegCollector` | Takes Hookr's leg and sweeps it to the treasury's target | [`0x2b8dd989D34256b7685E3Bd8F10299A4891F1Af2`](https://robin.etherscan.io/address/0x2b8dd989D34256b7685E3Bd8F10299A4891F1Af2#code) | [exact match](https://repo.sourcify.dev/4663/0x2b8dd989D34256b7685E3Bd8F10299A4891F1Af2) |
| `HookrRevenueStateView` | Read-only lens: a token's terms and assets, its doors, and a holder's claimable income and open drops, each in one call | [`0x83B8F1650a22b7da9Fac45A09F51e0685C47E944`](https://robin.etherscan.io/address/0x83B8F1650a22b7da9Fac45A09F51e0685C47E944#code) | [exact match](https://repo.sourcify.dev/4663/0x83B8F1650a22b7da9Fac45A09F51e0685C47E944) |
| `HookrTimeSharesFactory` | Time shares on this tokenizer's revenue tokens | [`0x05fDb5654e1D52593Ee774cae964717d5834dF1B`](https://robin.etherscan.io/address/0x05fDb5654e1D52593Ee774cae964717d5834dF1B#code) | [exact match](https://repo.sourcify.dev/4663/0x05fDb5654e1D52593Ee774cae964717d5834dF1B) |
| `HookrRevenueStreams` | Linked library: `tokenize` and `addStreams` in full | [`0x2DB0Bfd85F233D09Da55835e08cBe7A68b6AFEb9`](https://robin.etherscan.io/address/0x2DB0Bfd85F233D09Da55835e08cBe7A68b6AFEb9#code) | [exact match](https://repo.sourcify.dev/4663/0x2DB0Bfd85F233D09Da55835e08cBe7A68b6AFEb9) |
| `HookrRevenueMarketOpener` | Linked library: a new Hookr launch, and the revenue token's own market | [`0x2fE3B06A5827E0ADec5a407308aDe2C3801b7366`](https://robin.etherscan.io/address/0x2fE3B06A5827E0ADec5a407308aDe2C3801b7366#code) | [exact match](https://repo.sourcify.dev/4663/0x2fE3B06A5827E0ADec5a407308aDe2C3801b7366) |
| `HookrRevenueDoorDeployer` | Linked library: the family doors, the checks of a launch, a market and an outside door, and the position doors | [`0xC4Df7F66c5e55316a545E4d78b2c6a5449088bb3`](https://robin.etherscan.io/address/0xC4Df7F66c5e55316a545E4d78b2c6a5449088bb3#code) | [exact match](https://repo.sourcify.dev/4663/0xC4Df7F66c5e55316a545E4d78b2c6a5449088bb3) |
| `HookrPositionNftDoorFactory` | Makes the v4 position doors | [`0x29fB09eC8bb27299710040a894fEaF82d7341772`](https://robin.etherscan.io/address/0x29fB09eC8bb27299710040a894fEaF82d7341772#code) | [exact match](https://repo.sourcify.dev/4663/0x29fB09eC8bb27299710040a894fEaF82d7341772) |
| `HookrV3PositionNftDoorFactory` | Makes the v3 position doors | [`0xBA5b0171f77F28D9381FA0ED96B6BB1412D8Ce1e`](https://robin.etherscan.io/address/0xBA5b0171f77F28D9381FA0ED96B6BB1412D8Ce1e#code) | [exact match](https://repo.sourcify.dev/4663/0xBA5b0171f77F28D9381FA0ED96B6BB1412D8Ce1e) |
| `HookrFeebAdapterFactory` | Makes the Fee Beneficiary NFT doors | [`0xb6D6C144deca5D5ef59C8Fcf3E657C50883e67B9`](https://robin.etherscan.io/address/0xb6D6C144deca5D5ef59C8Fcf3E657C50883e67B9#code) | [exact match](https://repo.sourcify.dev/4663/0xb6D6C144deca5D5ef59C8Fcf3E657C50883e67B9) |
| `HookrRevenueTokenDoorFactory` | Makes the revenue token doors, which hold shares of another revenue token as a stream | [`0x85644897Adc52d3270b35C649CAE69989f8C583d`](https://robin.etherscan.io/address/0x85644897Adc52d3270b35C649CAE69989f8C583d#code) | [exact match](https://repo.sourcify.dev/4663/0x85644897Adc52d3270b35C649CAE69989f8C583d) |

`HookrTimeSharesFactory` writes the creation code of `HookrTimeShares` at its construction into two data contracts and creates every time shares contract from them. Each data contract's runtime is its piece of the code, so they have no source match of their own: [`time-shares/check-time-shares-code.mjs`](./time-shares/check-time-shares-code.mjs) checks them against the sources here.

| Data contract | Address | Holds |
| --- | --- | --- |
| 0, the factory's CREATE nonce 1 | [`0x2999D1E72bf3Cc2d6a4e76695c0Fd01d59dba0f3`](https://robin.etherscan.io/address/0x2999D1E72bf3Cc2d6a4e76695c0Fd01d59dba0f3#code) | bytes 0 to 12,618 |
| 1, the factory's CREATE nonce 2 | [`0x670636b2E5032146c5592399599fCd6B34038435`](https://robin.etherscan.io/address/0x670636b2E5032146c5592399599fCd6B34038435#code) | bytes 12,619 to 25,237 |

### Parts it reuses

These were deployed before it and are used where they live. Each is on Sourcify.

| Contract | What it is | Address | Verified source |
| --- | --- | --- | --- |
| `HookrSignatures` | Linked library: the signature check behind every signed path of a revenue token and its drop box | [`0x48814982d5A93A8A1A8c88181a9d1af3cdbc4CAc`](https://robin.etherscan.io/address/0x48814982d5A93A8A1A8c88181a9d1af3cdbc4CAc#code) | [exact match](https://repo.sourcify.dev/4663/0x48814982d5A93A8A1A8c88181a9d1af3cdbc4CAc) |
| `HookrIncomeRecovery` | Linked library: bounded collection of what shares held by a revenue token or its drop box earn | [`0xf16CB3de074e4e686526f99344d98B6662A01954`](https://robin.etherscan.io/address/0xf16CB3de074e4e686526f99344d98B6662A01954#code) | [exact match](https://repo.sourcify.dev/4663/0xf16CB3de074e4e686526f99344d98B6662A01954) |
| `HookrDropBoxDeployer` | Linked library: deploys each revenue token's drop box | [`0x6F54ca89d03D73CadB61741452688D5a497F2342`](https://robin.etherscan.io/address/0x6F54ca89d03D73CadB61741452688D5a497F2342#code) | [exact match](https://repo.sourcify.dev/4663/0x6F54ca89d03D73CadB61741452688D5a497F2342) |
| `HookrRevenueTokenCode.0`, `.1` | Data: the two halves of the revenue token's creation code | [`0xA42Dba2fADAE31f7262618cF61274625d68B1e81`](https://robin.etherscan.io/address/0xA42Dba2fADAE31f7262618cF61274625d68B1e81#code), [`0x070D0Dc1D2a7b462643E413BC2583de8C80580DC`](https://robin.etherscan.io/address/0x070D0Dc1D2a7b462643E413BC2583de8C80580DC#code) | [creation match](https://repo.sourcify.dev/4663/0xA42Dba2fADAE31f7262618cF61274625d68B1e81), [creation match](https://repo.sourcify.dev/4663/0x070D0Dc1D2a7b462643E413BC2583de8C80580DC) |
| `HookrPonsAdapterFactory` | Makes the Pons doors, one per Pons V2 launch's creator fee | [`0x9655a9AeAD9c33032649E3a70e152d831aCeCd1a`](https://robin.etherscan.io/address/0x9655a9AeAD9c33032649E3a70e152d831aCeCd1a#code) | [exact match](https://repo.sourcify.dev/4663/0x9655a9AeAD9c33032649E3a70e152d831aCeCd1a) |
| `HookrDopplerAdapterFactory` | Makes the Long doors, one per Long launch's beneficiary share on Doppler | [`0x7309b6aDc24d590E19079C732be7e11eF6Ba485F`](https://robin.etherscan.io/address/0x7309b6aDc24d590E19079C732be7e11eF6Ba485F#code) | [exact match](https://repo.sourcify.dev/4663/0x7309b6aDc24d590E19079C732be7e11eF6Ba485F) |
| `HookrTimeShareWrapperFactory` | Wraps a day of time shares as an ERC-20 | [`0x41871eef4E231b1F6d88FF0F67fb47fcC4041BC0`](https://robin.etherscan.io/address/0x41871eef4E231b1F6d88FF0F67fb47fcC4041BC0#code) | [exact match](https://repo.sourcify.dev/4663/0x41871eef4E231b1F6d88FF0F67fb47fcC4041BC0) |

## Where the files are

| Folder | Holds | Build tree name |
| --- | --- | --- |
| [`src/`](./src/) | The tokenizer, its libraries, its door factories, its state view and the interfaces they import | `src/...`, and `../hookrevenue-v2/src/...` from the time shares |
| [`time-shares/src/`](./time-shares/src/) | The time shares factory and `HookrTimeShares` | `src/...` |

Every file is byte-identical to the verified source, and its keccak256 is in the record's `sourceKeccak256`. The release files they import (`../hookr-phase-one/src/...` in the metadata) are the release's own files in [`../src/`](../src/), and the dependencies are the pinned submodules in [`../../lib/`](../../lib/).

## Building it

Solc 0.8.37, via-IR, EVM version prague, the IPFS metadata hash. The optimizer runs at 50 for the tokenizer set and at 200 for the time shares factory: the record's settings profiles `revenue-tokenizer-4` and `revenue-tokenizer-4-time-shares`. The compiler input for any of the eleven comes from the record, which maps each source unit name to its file here:

```sh
node hookr-1/standard-input.mjs 0x08De138e558a9258c6B4077E8bdeB9ad1fB46a4B > tokenizer.json
solc-0.8.37 --standard-json tokenizer.json > tokenizer.out.json
cast code 0x08De138e558a9258c6B4077E8bdeB9ad1fB46a4B > tokenizer.hex   # with ETH_RPC_URL set to a chain 4663 node
node hookr-1/check-runtime.mjs 0x08De138e558a9258c6B4077E8bdeB9ad1fB46a4B tokenizer.out.json tokenizer.hex
```

The time shares' data contracts, from the factory's output:

```sh
node hookr-1/standard-input.mjs 0x05fDb5654e1D52593Ee774cae964717d5834dF1B > time-shares.json
solc-0.8.37 --standard-json time-shares.json > time-shares.out.json
cast code 0x2999D1E72bf3Cc2d6a4e76695c0Fd01d59dba0f3 > data0.hex
cast code 0x670636b2E5032146c5592399599fCd6B34038435 > data1.hex
node hookr-1/revenue-tokenizer-4/time-shares/check-time-shares-code.mjs time-shares.out.json data0.hex data1.hex
```

There is no Forge profile for these folders: their metadata records the build tree's remappings, and `standard-input.mjs` is the byte-exact build.

## Fee

Set per door when the door is added. `HOOKR_LEG_BPS_HOOKR`, 0, for a stream that already pays Hookr through its hook: a Hookr family, the market, a Rules ledger, v4 positions whose pools all sit on `HookrRoot`, a revenue token door. `HOOKR_LEG_BPS_OUTSIDE`, 500, 5% of what the door delivers, for anything else. The token's sync takes the leg to `HookrLegCollector`, which sweeps it to the treasury's target. No shares are minted to Hookr.

## Status

Deployed and verified. No independent audit has been completed.
