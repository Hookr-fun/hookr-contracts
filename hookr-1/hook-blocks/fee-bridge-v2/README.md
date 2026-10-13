# Fee Bridge, keeper-run

Pays another pool's LPs. A bridge is named as a royalty payee or a tax recipient, or sent anything in its currency, and a keeper drips it: each drip donates a capped amount of what it holds to the in-range LPs of the destination pool fixed when it was made, for a tip of at most 1% of what it donates. Anyone may create a bridge, fund it and `collect()` into it; only an account its factory lists as a keeper may `record()` or `drip()`. A drip needs a keeper's record of in-range liquidity from an earlier block, the price still in that record's tick-spacing bucket, and in-range liquidity at most the bridge's jump tolerance above the record. So while the liquidity in range at the record stays, liquidity added after it takes at most `maxJumpBps / (10,000 + maxJumpBps)` of a drip: about 2% at the default tolerance of 200 bps. `HookrFeeBridgeFactory` makes the bridges at CREATE2 addresses keyed by creator and salt, and every term of a bridge is immutable. The factory's owner chooses the keepers and can never move what a bridge holds. A bridge is not a module of the hook, so it needs no registry admission, and the factory has none.

It replaces the [first factory](../fee-bridge/README.md), where anyone could record and drip, so one actor could add liquidity just before a drip and take most of it. No bridge was ever made from the first factory.

Deployed on Robinhood Chain (chain id 4663) in transaction `0xa0b7fa2ceac8a8c69c83a2cc9fd9f4283ec86f7a5b780620a613052b8fc20c27`, block 87,254,611, through the CREATE3 factory with release id `hookr-1` and role `HookrFeeBridgeFactory`. Its constructor sets the PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951`, the owner `0x8Fdfaa25e2E4dDa297F301ea06458f22186D6bE9` (Hookr's Safe) and the first keeper `0x0EFFbaB57B4051276a9d2a81f8bCC74261EC3698`.

| Contract | Address | Verified source | Note |
| --- | --- | --- | --- |
| `HookrFeeBridgeFactory` | [`0x85D2F6c536336C17B79BE740C6bbb6c7d8D9b23D`](https://robin.etherscan.io/address/0x85D2F6c536336C17B79BE740C6bbb6c7d8D9b23D#code) | [Sourcify](https://repo.sourcify.dev/4663/0x85D2F6c536336C17B79BE740C6bbb6c7d8D9b23D) | keeper-run; replaces `0x765cdea443C1688aE7467c2241E4a9a3e636990E` |

## Sources

This folder holds the bridge's own sources. Unlike the first factory, it was built in its own folder, so the verified metadata names its files `src/...`, the release's files `../hookr-phase-one/src/...` (the files in [`../../src/`](../../src/)) and the dependencies `../../../contracts/lib/...` (the pinned submodules in [`lib/`](../../../lib/)). [`deployments/robinhood-4663.json`](../../deployments/robinhood-4663.json) maps every source unit of every contract to its file in this repository; this contract's compiler settings are the profile `hook-blocks-6`, read from its verified metadata.

The contract above rebuilds byte for byte, metadata hash included, from its address:

```sh
node hookr-1/standard-input.mjs 0x85D2F6c536336C17B79BE740C6bbb6c7d8D9b23D > input.json
solc-0.8.37 --standard-json input.json > output.json
cast code 0x85D2F6c536336C17B79BE740C6bbb6c7d8D9b23D > chain.hex
node hookr-1/check-runtime.mjs 0x85D2F6c536336C17B79BE740C6bbb6c7d8D9b23D output.json chain.hex
```
