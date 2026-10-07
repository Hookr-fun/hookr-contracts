# Hook Blocks

The Hook Blocks deployed with Hookr 1 in production waves 0 to 3 on Robinhood Chain (chain id 4663): 46 contracts in 17 blocks, each in its own folder with its sources and addresses. Every contract here is an exact match on Sourcify, and its source files are byte-identical to the verified ones.

| Wave | Block | Contracts | What it does |
| --- | --- | --- | --- |
| 0 | [Vesting Milestone](./vesting-milestone/README.md) | 1 | Escrows a launch's vesting allocation. |
| 1 | [Best Route](./best-route/README.md) | 1 | Compares one exact-input trade on a Hookr pool with Uniswap v3 fee tiers, hookless v4 pools and one-hop paths through ETH or USDG, and offers the better route as one Universal Router call only when it beats the Hookr pool by a margin. |
| 1 | [Buy/Sell Block](./buy-sell-block/README.md) | 4 | An advisory that refuses a same-block round trip (buy then sell on the pool in one block) and buys or sells inside bounded launch windows, and charges nothing. |
| 1 | [Canonical Venue Token](./canonical-venue-token/README.md) | 4 | A token that crosses the PoolManager only through one settlement contract, launched on one Hookr pool and then traded and given liquidity only on that pool. |
| 1 | [Entry Ratio Guarantee](./entry-ratio-guarantee/README.md) | 5 | A standalone Uniswap v4 custody hook. |
| 1 | [External Launch](./external-launch-adapter/README.md) | 5 | Opens a pool on a hook Hookr did not write, through that hook's admitted launch adapter, in one transaction, and records it for discovery. |
| 1 | [Market Guard](./market-guard/README.md) | 1 | An advisory that keeps a pool's price inside a band around an admitted external price feed: in REFUSE mode a swap that would leave the band is refused, in SURCHARGE mode it pays a surcharge priced from its simulated move beyond the band. |
| 1 | [Module Market](./module-market/README.md) | 3 | The bonded module marketplace: developers publish advisory modules with a frozen fee split, $HOOKR bonded in the vault stands behind each version, and the usage fee router splits each version's fees between developer, backers, protocol and reserve. |
| 1 | [Pay Later](./pay-later/README.md) | 2 | Deploys one Pay Later vault per family and beneficiary at a deterministic address, and refuses terms outside its listing bounds. |
| 1 | [Recovery Reserve](./recovery-reserve/README.md) | 1 | A small per-pool reserve, funded by a bounded slice of the pool's claims, that tops up LPs or traders after a verified incident, behind a 30-minute timelock, a reviewer attestation per claim and per-incident and per-pool caps. |
| 1 | [Revenue Router](./revenue-router/README.md) | 1 | An ownerless CREATE2 factory and directory of revenue splits. |
| 2 | [Limit Orders](./limit-orders/README.md) | 1 | Escrowed exact-input limit orders that anyone can fill through the pinned Hookr router. |
| 3 | [Builder Attribution](./builder-attribution/README.md) | 3 | Registered integration partners, one-time market vouchers and the permanent attribution record of every pool opened through the attribution launcher, which deploys the pool's revenue vault and initializes the pool with a partner tax advisory paying that vault. |
| 3 | [Credential Gate](./credential-gate/README.md) | 1 | A fail-closed advisory for gated pools: credential lists, sanctions, curated routers and restricted subjects, plus off-market session tiers, in one advisory slot. |
| 3 | [Directional Tax](./directional-tax/README.md) | 7 | Separate buy and sell taxes, each at most 10%, taken in the quote and credited to a claim queue per pool and direction that converts later, off the trade path. |
| 3 | [Swap Reward Mint](./swap-reward-mint/README.md) | 2 | An advisory that takes a fixed reward slice of each swap's quote leg (at most 5%) for a reward program, which the program's minter later turns into reward tokens. |
| 3 | [Zap Relay](./zap-relay/README.md) | 4 | A buy cut of up to 10% on a source pool, credited to the pool's zap vault, and a gated relay on a target pool that accepts buys only from those vaults. |

Blocks that were planned but not deployed in these waves are not here.
