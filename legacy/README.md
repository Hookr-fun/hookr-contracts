# Earlier generations

Every generation of Hookr that ever went live on Robinhood Chain, chain id 4663, is still there. Pools opened on an earlier generation keep running on it; a later generation never touches them, and no owner function on any generation can retune a pool after it opens.

| Generation | Launchpad | Hook | Router | Notes |
| --- | --- | --- | --- | --- |
| 3 | [`0xaAed6fab06D53311220F35421Dda5cc6D6e9d6C3`](https://robinhoodchain.blockscout.com/address/0xaAed6fab06D53311220F35421Dda5cc6D6e9d6C3) | [`0xd0005624Da88a688BcaB3DBFB4d1Cb23d32Ca0CC`](https://robinhoodchain.blockscout.com/address/0xd0005624Da88a688BcaB3DBFB4d1Cb23d32Ca0CC) | [`0x3f6E7BA9689d3c78A00d68931b7C223f51e0f21b`](https://robinhoodchain.blockscout.com/address/0x3f6E7BA9689d3c78A00d68931b7C223f51e0f21b) | Ten-tranche bonding curve that graduates into a locked full-range position. Sources, tests, scripts and broadcast records under [`generation-3/`](./generation-3/README.md). |
| 4 | [`0x5Ce779D23D2e99D322004F203813389B6a426e3B`](https://robinhoodchain.blockscout.com/address/0x5Ce779D23D2e99D322004F203813389B6a426e3B) | [`0xa0F267571847Ce91318798578A1BCc77D77c28cC`](https://robinhoodchain.blockscout.com/address/0xa0F267571847Ce91318798578A1BCc77D77c28cC) | [`0x98F3A734860a89711e111cc692E8020Cac2A4fC5`](https://robinhoodchain.blockscout.com/address/0x98F3A734860a89711e111cc692E8020Cac2A4fC5) | Instant launches straight into a pool, alongside the curve. |
| 5 | [`0xa043caBE645636899dDe91Cce4693C00a015e660`](https://robinhoodchain.blockscout.com/address/0xa043caBE645636899dDe91Cce4693C00a015e660) | [`0xe7c3461A4c762fF9dB4F91BeE3Cf8deAaFc2E8CC`](https://robinhoodchain.blockscout.com/address/0xe7c3461A4c762fF9dB4F91BeE3Cf8deAaFc2E8CC) | [`0x644ac2e784059e1C01F24f99DF7795aE2be06ca0`](https://robinhoodchain.blockscout.com/address/0x644ac2e784059e1C01F24f99DF7795aE2be06ca0) | Instant launches quoted in ETH or HOOKR, and bonded ETH launches through a continuous clearing auction. The flywheel burner at [`0x8Cee20FA000aF3266AC2cD2cBeEFbcD19D98FD89`](https://robinhoodchain.blockscout.com/address/0x8Cee20FA000aF3266AC2cD2cBeEFbcD19D98FD89) converts collected pool fees into HOOKR and burns it. |

All three share the Uniswap v4 PoolManager at [`0x8366a39CC670B4001A1121B8F6A443A643e40951`](https://robinhoodchain.blockscout.com/address/0x8366a39CC670B4001A1121B8F6A443A643e40951) and the HOOKR token at [`0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c`](https://robinhoodchain.blockscout.com/address/0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c).

The current release, the modular hook described in the [root README](../README.md), opens new pools on a different hook and does not migrate anything from these generations. Generation 4 and 5 sources are not exported here; their verified sources are on the explorer at the addresses above.

## Superseded recapture roots

Before the current recapture root, three earlier recapture roots were sealed on the same registry as the current release. Each was superseded by the next; none is offered for new markets. Pools opened on them are still open and still trade, and nothing can retune them. Their sources are not exported here.

| Root | Address | Status | Source verification |
| --- | --- | --- | --- |
| First recapture root | [`0xc7c516CD5546bCB2592Fe3f8aa91C2A4bA3768CC`](https://robinhoodchain.blockscout.com/address/0xc7c516CD5546bCB2592Fe3f8aa91C2A4bA3768CC) | superseded, pools still open | verified on Blockscout as `HookrModularHookV6Wth`, no Sourcify match; its correction lane needs more gas than an ordinary swap carries, so on real traffic only the five rules run |
| Third recapture root | [`0xa99902a2922014bBe2Bf2dCF15742ac5104828Cc`](https://robinhoodchain.blockscout.com/address/0xa99902a2922014bBe2Bf2dCF15742ac5104828Cc) | superseded, pools still open | not verified; built without the release profile, so a full match is unreachable at its address |
| Fourth recapture root | [`0xE5429dB8f63912E632E86733905667AaEb6ea8cC`](https://robinhoodchain.blockscout.com/address/0xE5429dB8f63912E632E86733905667AaEb6ea8cC) | superseded, pools still open | not verified at its address |

The current recapture root, `HookrModularHookV6WthV5` at `0xb914f955294799de4b891bd2EA8AF628Fa1c68CC`, is the one the [root README](../README.md) and [Deployments](../docs/reference/deployments.md) describe.
