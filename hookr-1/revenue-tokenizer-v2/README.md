# Parts the revenue tokenizer reuses

This folder holds the sources of eight contracts the revenue tokenizer in [`../revenue-tokenizer-4/`](../revenue-tokenizer-4/README.md) uses where they live: the two halves of the revenue token's code and its three libraries, the Pons and Long door factories and the time shares wrapper factory. The record maps every contract built from these sources to its files; the others are on [PREVIOUS_RELEASES.md](../../PREVIOUS_RELEASES.md).

## What the revenue tokenizer uses from here

Every revenue token the tokenizer mints is created from the two code halves below and links the three token libraries below; its Pons and Long doors come from the two door factories below, and a day of its time shares wraps as an ERC-20 through the wrapper factory:

| Contract | What it is | Address | Runtime keccak256 | Verified source |
| --- | --- | --- | --- | --- |
| `HookrSignatures` | Linked library: the one signature check behind every signed path of a revenue token and its drop box (ECDSA, then ERC-1271) | [`0x48814982d5A93A8A1A8c88181a9d1af3cdbc4CAc`](https://robin.etherscan.io/address/0x48814982d5A93A8A1A8c88181a9d1af3cdbc4CAc#code) | `0x1db8ef85d6897fb15c92906497443e6a234397084e04d07e8ada2d8f8dc5d025` | [exact match](https://repo.sourcify.dev/4663/0x48814982d5A93A8A1A8c88181a9d1af3cdbc4CAc) |
| `HookrIncomeRecovery` | Linked library: bounded collection of the drops that shares held by a revenue token or its drop box earn, and of a token's income from another revenue token | [`0xf16CB3de074e4e686526f99344d98B6662A01954`](https://robin.etherscan.io/address/0xf16CB3de074e4e686526f99344d98B6662A01954#code) | `0x30aa219c2c4e2ae2c9e17c86e48a56ad27ebbd8a73e01c061a621e385ee3e319` | [exact match](https://repo.sourcify.dev/4663/0xf16CB3de074e4e686526f99344d98B6662A01954) |
| `HookrDropBoxDeployer` | Linked library: deploys each revenue token's drop box from the token's constructor | [`0x6F54ca89d03D73CadB61741452688D5a497F2342`](https://robin.etherscan.io/address/0x6F54ca89d03D73CadB61741452688D5a497F2342#code) | `0x83e03af431193afa32a4b8a302f9a58362399c82f5417eb369dc29e56200b483` | [exact match](https://repo.sourcify.dev/4663/0x6F54ca89d03D73CadB61741452688D5a497F2342) |
| `HookrRevenueTokenCode.0` | Data: a STOP byte and bytes 0 to 13,999 of the revenue token's creation code | [`0xA42Dba2fADAE31f7262618cF61274625d68B1e81`](https://robin.etherscan.io/address/0xA42Dba2fADAE31f7262618cF61274625d68B1e81#code) | `0xe198df9cc8ec70cac0b7004951118b5be8bc2dbaef262427f7aaf8bb41471d8c` | [creation match](https://repo.sourcify.dev/4663/0xA42Dba2fADAE31f7262618cF61274625d68B1e81) |
| `HookrRevenueTokenCode.1` | Data: a STOP byte and bytes 14,000 to 27,809 of the revenue token's creation code | [`0x070D0Dc1D2a7b462643E413BC2583de8C80580DC`](https://robin.etherscan.io/address/0x070D0Dc1D2a7b462643E413BC2583de8C80580DC#code) | `0x14b6e373517d73fbe35e0e91c13de40b380c5768ab3b7ee7a5b56de60e2be910` | [creation match](https://repo.sourcify.dev/4663/0x070D0Dc1D2a7b462643E413BC2583de8C80580DC) |
| `HookrPonsAdapterFactory` | Makes the Pons doors, one per Pons V2 launch's creator fee | [`0x9655a9AeAD9c33032649E3a70e152d831aCeCd1a`](https://robin.etherscan.io/address/0x9655a9AeAD9c33032649E3a70e152d831aCeCd1a#code) | `0xed8778c10c7b4f73514f0b1740b9f270f4b5a6bcf3b41330e69d889eacd08551` | [exact match](https://repo.sourcify.dev/4663/0x9655a9AeAD9c33032649E3a70e152d831aCeCd1a) |
| `HookrDopplerAdapterFactory` | Makes the Long doors, one per Long launch's beneficiary share on Doppler | [`0x7309b6aDc24d590E19079C732be7e11eF6Ba485F`](https://robin.etherscan.io/address/0x7309b6aDc24d590E19079C732be7e11eF6Ba485F#code) | `0x1cdfe5345dc6b04aaddf1c3f7a70cb918ab9330554960ed5678633d8d7b998c5` | [exact match](https://repo.sourcify.dev/4663/0x7309b6aDc24d590E19079C732be7e11eF6Ba485F) |
| `HookrTimeShareWrapperFactory` | Wraps a day of time shares as an ERC-20; it binds no tokenizer | [`0x41871eef4E231b1F6d88FF0F67fb47fcC4041BC0`](https://robin.etherscan.io/address/0x41871eef4E231b1F6d88FF0F67fb47fcC4041BC0#code) | `0x7f9b38c6e25c5fbbbff002ce2ef38a2ccedbf870b9d7f0bfdc14150405582e9b` | [exact match](https://repo.sourcify.dev/4663/0x41871eef4E231b1F6d88FF0F67fb47fcC4041BC0) |

The first seven were deployed on 2026-11-01 between blocks 103,733,671 and 103,733,743, and the wrapper factory on 2026-10-29 in block 100,475,160, each from `0x0c0967485A25F18E70262a2Ee80c7595CC64a5fC` through the CREATE3 factory at `0xc7c662Fc760FE1d5cB97fd8A68cb43A046da3F7d`, release id `hookr-1`, with the contract's name as its role. Each runtime keccak256 above is the address's code hash read from the chain at block 109,974,574, the record's `checkedAtBlock`.

The revenue token's creation code, 27,810 bytes linked to its three libraries, is larger than one contract's runtime may be, so the two `HookrRevenueTokenCode` contracts hold it and every revenue token is created from them. Their runtime is data, so Sourcify matches their creation code instead, and [`check-token-code.mjs`](./check-token-code.mjs) checks that the two together are the revenue token's creation code built from the sources here.

## Where the files are

| Folder | Holds | Build tree name |
| --- | --- | --- |
| [`src/`](./src/) | The tokenizer, its libraries, the code halves, the door factories, the state view, the leg collector and every contract they make, 83 files | `src/...`; `../hookrevenue-v2/src/...` for the add-ons |
| [`time-shares/src/`](./time-shares/src/) | The time shares add-on, 12 files | `src/...` |
| [`compounder/src/`](./compounder/src/) | The compounder add-on, 12 files | `src/...` |

Every file is byte-identical to the verified source on Sourcify, and its keccak256 is in the record's `sourceKeccak256`. The release files they import (`../hookr-phase-one/src/...` in the metadata, 10 files) are the release's own files in [`../src/`](../src/), and the dependencies (`../../../contracts/lib/...`, 47 files) are the pinned submodules in [`../../lib/`](../../lib/). The add-ons were built from folders beside the tokenizer's, so their metadata names its files `../hookrevenue-v2/src/...` (10 files, all in [`src/`](./src/)), the release's `../hookr-phase-one/src/...` (5 files) and the dependencies `../../../contracts/lib/...` (48 files).

## Building it

The libraries, code halves and door factories compile with solc 0.8.37 (`0.8.37+commit.f401782d`), via-IR, the optimizer at 50 runs, EVM version prague, and the IPFS metadata hash; the wrapper factory and the other add-ons use 200 runs. The record's settings profiles `revenue-tokenizer-v2`, `revenue-tokenizer-v2-time-shares` and `revenue-tokenizer-v2-compounder` hold the exact settings, read from the verified metadata. `node hookr-1/standard-input.mjs --list` names every contract built from these sources under `revenue-tokenizer-v2`:

```sh
node hookr-1/standard-input.mjs 0x48814982d5A93A8A1A8c88181a9d1af3cdbc4CAc > signatures.json
solc-0.8.37 --standard-json signatures.json > signatures.out.json
cast code 0x48814982d5A93A8A1A8c88181a9d1af3cdbc4CAc > signatures.hex   # with ETH_RPC_URL set to a chain 4663 node
node hookr-1/check-runtime.mjs 0x48814982d5A93A8A1A8c88181a9d1af3cdbc4CAc signatures.out.json signatures.hex
```

The code halves, from the input `check-token-code.mjs` writes for them. The last argument is the tokenizer the record lists the halves under, so the check links that set's libraries:

```sh
node hookr-1/revenue-tokenizer-v2/check-token-code.mjs --input > token-code.json
solc-0.8.37 --standard-json token-code.json > token-code.out.json
cast code 0xA42Dba2fADAE31f7262618cF61274625d68B1e81 > half0.hex
cast code 0x070D0Dc1D2a7b462643E413BC2583de8C80580DC > half1.hex
node hookr-1/revenue-tokenizer-v2/check-token-code.mjs token-code.out.json half0.hex half1.hex <tokenizer>
```

It prints `MATCH` when the halves joined are the token's creation code linked to the record's libraries, the first half holds exactly 14,000 bytes, and `HookrRevenueTokenCode` built here carries the metadata hash the record names.

Each time shares and compounder factory writes the creation code of what it makes into two data contracts, which the record lists under it as `dataContracts`. [`time-shares/check-time-shares-code.mjs`](./time-shares/check-time-shares-code.mjs) and [`../revenue-tokenizer/check-code-chunks.mjs`](../revenue-tokenizer/check-code-chunks.mjs) check them against the factory's build:

```sh
node hookr-1/standard-input.mjs <factory> > factory.json
solc-0.8.37 --standard-json factory.json > factory.out.json
node hookr-1/revenue-tokenizer-v2/time-shares/check-time-shares-code.mjs factory.out.json data0.hex data1.hex   # a time shares factory
node hookr-1/revenue-tokenizer/check-code-chunks.mjs factory.out.json chunk0.hex chunk1.hex                     # a compounder factory
```

There is no Forge profile for these folders: their metadata records the build trees' remappings, and `standard-input.mjs` is the byte-exact build.

## Status

Deployed. No independent audit of the tokenizer or its add-ons has been completed.
