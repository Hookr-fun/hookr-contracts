# Gas bench

What Hookr's pieces cost in gas, measured on the live Hookr 1 contracts on Robinhood Chain (chain id 4663), and the one command that reproduces every number. Hookr's per-Hook-Block gas figures come from here: the command writes them to [`gas-figures.json`](./gas-figures.json).

Each figure is a whole transaction on a fork of the chain. It answers one question: how much more gas does this cost than the same action without it? "Without it" is a pool with no hook, for Hookr's own base cost, or the same Hookr pool with the piece off, for every piece on top. Only the pieces in the table below are measured; the bench says nothing about the others.

## Run it yourself

You need Foundry 1.7.1 (the version CI pins), Node 18 or later, the submodules (`git submodule update --init --recursive` at the repository root) and an archive RPC endpoint for chain 4663. The fork is pinned at **block 87,300,000**, which a node that keeps only recent state cannot serve.

Foundry reaches the endpoint through an rpc alias named `robinhood`. This repository keeps no RPC table ([CONTRIBUTING.md](../CONTRIBUTING.md)), so the alias lives in your own Foundry config, with the URL in an environment variable:

```toml
# ~/.foundry/foundry.toml, on your machine only
[rpc_endpoints]
robinhood = "${ROBINHOOD_RPC_URL}"
```

Load the variable from a file outside the repository, and keep the URL off the command line, where process listings show it:

```sh
set -a; . /path/to/rpc.env; set +a    # a file that sets ROBINHOOD_RPC_URL
```

Then, from the repository root, the one command:

```sh
node bench/gas-figures.mjs
```

It runs `forge test --isolate -vv` in `bench/`, which forks the chain at the pinned block, measures every figure and writes one file per figure under `bench/figures/`, then merges them into `bench/gas-figures.json` and checks the result against the schema below. Anything forge prints that looks like a URL is masked. The first run fetches the fork's state from your endpoint (about 15 seconds when this was written) and later runs read it from Foundry's cache.

`cd bench && forge test --isolate -vv` alone prints the same numbers and writes the per-figure files, but not `gas-figures.json`; add `--match-path test/Base.t.sol` to run one file.

### Expected output

Every test logs its figures as lines like `FIGURE base.buy 20702`. Forge's summary ends with `18 tests passed, 0 failed, 0 skipped (18 total tests)`, and the command's last line is `wrote bench/gas-figures.json: 45 figures at block 87300000`.

The pinned block, the compiler (solc 0.8.30, `prague`) and Foundry 1.7.1 fix every input, so a run reproduces these numbers to the gas: a cold and a warm Foundry cache, one thread and many, and a fresh clone all gave identical files.

| Figure | Gas | What it measures |
| --- | ---: | --- |
| `base.buy` | 20,702 | A Hookr pool of an existing token with nothing on, over a pool with no hook: a buy |
| `base.sell` | 20,680 | A Hookr pool of an existing token with nothing on, over a pool with no hook: a sell |
| `lp-rewards.buy` | 51,451 | LP Rewards, a 1% slice of buys: a buy |
| `lp-rewards.with-royalty-and-auto-burn.buy` | 75,949 | LP Rewards, royalty and Auto Burn together: a buy |
| `lp-rewards.sell` | 27,675 | LP Rewards, a 1% slice of buys: a sell |
| `lp-rewards.with-royalty-and-auto-burn.sell` | 27,675 | LP Rewards, royalty and Auto Burn together: a sell |
| `creator-royalty.buy` | 7,893 | Creator royalty, 10% of LP Rewards, over LP Rewards: a buy |
| `creator-royalty.sell` | 0 | Creator royalty, 10% of LP Rewards, over LP Rewards: a sell |
| `auto-burn.buy` | 68,084 | Auto Burn, a 1% slice of buys: a buy |
| `auto-burn.sell` | 27,675 | Auto Burn, a 1% slice of buys: a sell |
| `anti-snipe.first-buy` | 61,141 | Anti-Snipe in the window: a wallet's first buy |
| `anti-snipe.repeat-buy` | 61,878 | Anti-Snipe in the window: the same wallet buys again |
| `anti-snipe.sell` | 32,268 | Anti-Snipe in the window: a sell |
| `anti-snipe.after-window` | -28 | Anti-Snipe after the window: a buy |
| `anti-snipe.launch` | 20,611 | Anti-Snipe at launch: a new token with a dev buy, over the same launch without a guard |
| `wallet-cap.first-buy` | 24,260 | Wallet Cap in the window: a wallet's first buy |
| `wallet-cap.first-buy.uncurated-router` | 35,169 | Wallet Cap in the window: a wallet's first buy, through a router the root does not curate |
| `wallet-cap.repeat-buy` | 6,427 | Wallet Cap in the window: the same wallet buys again |
| `wallet-cap.repeat-buy.uncurated-router` | 17,336 | Wallet Cap in the window: the same wallet buys again, through a router the root does not curate |
| `wallet-cap.sell` | 251 | Wallet Cap in the window: a sell |
| `wallet-cap.sell.uncurated-router` | 251 | Wallet Cap in the window: a sell, through a router the root does not curate |
| `wallet-cap.after-window` | 48 | Wallet Cap after the window: a buy |
| `wallet-cap.after-window.uncurated-router` | 48 | Wallet Cap after the window: a buy, through a router the root does not curate |
| `wallet-cap.launch` | 528 | Wallet Cap at launch: over the same launch on the whole-pot Rules with the same guard |
| `dynamic-fees.large-buy` | 183,451 | Hookr dynamic fee: a large buy across four ticks |
| `dynamic-fees.small-buy` | 91,970 | Hookr dynamic fee: a small buy, no tick crossed |
| `dynamic-fees.large-sell` | 179,811 | Hookr dynamic fee: a large sell across four ticks |
| `dynamic-fees.small-sell` | 87,082 | Hookr dynamic fee: a small sell, no tick crossed |
| `king-of-the-pool.buy` | 21,920 | King of the Pool, over the same lane pool without the pot: a buy |
| `king-of-the-pool.sell` | 20,201 | King of the Pool, over the same lane pool without the pot: a sell |
| `arb-recapture.buy` | 190,028 | Arb recapture lane with an idle executor: a buy |
| `arb-recapture.sell` | 188,218 | Arb recapture lane with an idle executor: a sell |
| `limit-orders.place` | 262,249 | Limit order: place, escrowing the sell and a bounty |
| `limit-orders.cancel` | 75,057 | Limit order: cancel, refunding the escrow and the bounty |
| `limit-orders.fill` | 331,686 | Limit order: fill, by a keeper, with the swap included |
| `limit-orders.per-swap` | 0 | Limit orders: a buy on a pool whose book holds an open order |
| `liquidity-lock.collect` | 164,574 | Liquidity lock: the beneficiary collects the LP fees |
| `liquidity-lock.per-swap` | 0 | Liquidity lock: a buy on a locked pool |
| `market-guard.buy` | 55,746 | Market Guard, refusing outside a 10% band of the feed: a buy inside the band |
| `market-guard.sell` | 55,774 | Market Guard, refusing outside a 10% band of the feed: a sell inside the band |
| `buy-sell-block.buy` | 55,607 | Buy/Sell Block, refusing a round trip in a block: a trader's first buy of the block |
| `buy-sell-block.sell` | 53,845 | Buy/Sell Block, refusing a round trip in a block: a trader's first sell of the block |
| `launch.existing-token-fee-only` | 868,265 | Launch an existing token with nothing on but the base fee |
| `launch.new-token-with-anti-snipe` | 1,924,981 | Launch a new token with a dev buy and Anti-Snipe |
| `claim.eth` | 56,038 | Claim ETH from the Rules (what a royalty recipient takes) |

## What a number is

**A whole transaction.** `forge test --isolate` runs every call a test makes as a transaction of its own, so a figure includes the 21,000 intrinsic gas, the calldata, every cold access and the refunds, and transient storage resets between swaps as it does on chain. It is L2 execution gas: the L1 data fee a transaction also pays is not in it.

**Extra gas.** A piece's figure is the same action on the same pool shape with the piece on, less with it off. The launcher opens one market per token, quote and tick spacing, so the two pools trade two bench tokens deployed the same way. Both pools are warmed with the same swaps (a buy and a sell before anything is measured, so no figure pays a pool's first-ever writes) and are measured in consecutive blocks. What "off" is for each piece:

| Figure | Over |
| --- | --- |
| `base` | a pool with the same pair, tick spacing, liquidity and fee and no hook (the hookless twin) |
| `lp-rewards`, `auto-burn`, `dynamic-fees`, `market-guard`, `buy-sell-block` | the Hookr pool with nothing on but the base fee, which the root answers without calling the Rules |
| `lp-rewards.with-royalty-and-auto-burn` | the same fee-only pool |
| `creator-royalty` | a Hookr pool with LP Rewards, because the Rules allow a royalty only on LP Rewards |
| `anti-snipe`, in the window and after it | the fee-only pool |
| `anti-snipe.launch` | the same launch of a new token with a dev buy and no guard, which binds Hookr's minimum fee instead (a token the launcher mints, with nothing that earns Hookr a share, always does) |
| `wallet-cap` | a pool with the same launch guard on the whole-pot Rules, which the Wallet Cap Rules are built on, so the difference is the cap |
| `king-of-the-pool` | the same lane pool without the pot |
| `arb-recapture` | the fee-only pool on the whole-pot Rules |
| `limit-orders.per-swap`, `liquidity-lock.per-swap` | the same buy from the same state before the order is placed or the family is locked |
| `limit-orders.place`, `cancel`, `fill`, `liquidity-lock.collect`, `launch.*`, `claim.eth` | nothing: the whole transaction |

A piece on top of the base costs the base as well: a pool with LP Rewards costs `base` plus `lp-rewards` over a pool with no hook. `base` is the fee-only pool of an existing token, which is what a pool has when nothing is on. A pool of a token the launcher mints, with no rule that earns Hookr a share, is not fee-only: it binds Hookr's minimum fee (1,000 pips by default), so every swap calls the Rules, and `base` does not describe it.

**The pool.** A bench token, a plain 18-decimal ERC-20, quoted in WETH at price 1 with tick spacing 60, a 0.3% LP fee and 1e24 of liquidity over ticks -60,000 to 60,000. A Hookr pool is the shared root's market for that token, opened by the live `HookrLauncher`. Its hookless twin has the same pair, tick spacing, liquidity and fee, with no hook and a static fee where the launcher's key carries the dynamic-fee flag. The measured swap is a buy of 1e21 WETH or a sell of 1e21 tokens. The exceptions are in the tests: the in-window sells sell 5e20 tokens, and Market Guard buys 1 WETH and sells 2,000 tokens against a pool priced at its feed. The dynamic fee pools carry four more positions (L = 1e23, edges at ±120, ±240, ±480 and ±720) and the same seven-swap history, and each figure is the first swap of a new block. A large swap (5e22) crosses four of the stacked ticks and a small one (1e20) crosses none, and the test requires the dynamic fee pool and the fee-only pool to cross the same ticks. `launch.new-token-with-anti-snipe`, `anti-snipe.launch` and `wallet-cap.launch` open a new token with its whole supply in one band from the lowest tick to the opening price, and a dev buy of 0.001 WETH; `launch.existing-token-fee-only` opens the pool above for an existing token. `claim.eth` is the claim itself, on a pool quoted in ETH, the only place the bench uses a native quote.

**The routers.** Unless a figure says otherwise it is a swap through the Universal Router 2.1.1 that the Hookr root curates (`0x8876…0904`): the root asks that router who the payer is, so the swap is authenticated. `wallet-cap.*.uncurated-router` goes through the second router in Uniswap's deployment registry (`0x06Af…bf99`), a later deployment with different bytecode that the root does not curate. The swap is then unauthenticated, with the router as its payer: the Wallet Cap Rules ask the root whether the sender is the pool's arb recapture executor, then count the buy against `tx.origin`. That is about 10,900 gas more per buy (`wallet-cap.first-buy.uncurated-router` less `wallet-cap.first-buy`). Limit order fills go through the book, which swaps through `HookrRouter`.

**The settings.** Anti-Snipe is 15 parent blocks of a Snipe tax that starts at 10% and falls to zero over 180 seconds, with a cap on each parent block's net buys. LP Rewards and Auto Burn are each a 1% slice of a buy, of which Hookr takes 20% (the floor the live Rules enforce) and the rest goes to the LPs or is burned, and the royalty is 10% of the LP Rewards slice. King of the Pool takes 2,500 bps of each recapture beside 5,000 for the LPs and 2,500 for the trader, as a pot that the whole-pot Rules pay out whole to the round's winner; the measured buys do not take the lead. Market Guard is at its defaults: it refuses a swap that would leave a 10% band around the ETH / USD feed. Buy/Sell Block refuses a round trip in one block, and its figures are a trader's first trade of a block, which the Rules record, so they carry the round-trip Rules' two calls and the advisory's one.

**What the lane figures mean.** A fresh token trades on one venue only, so the live arb recapture executor finds nothing to recapture. `arb-recapture` is the lane's cost with the executor idle: the root runs the executor before the swap and after it, asks it once whether the swap closes a v3 arbitrage, and a pool with a lane always calls its Rules. A swap that does recapture also pays for the executor's work, which these figures leave out. With nothing recaptured the pot stays empty, so `king-of-the-pool` is the per-swap bookkeeping of the pot alone.

**How exact.** The numbers are exact for this setup and move with it. The PoolManager's own swap math costs a few hundred gas more or less with different amounts, prices and timing, so a piece that adds a fixed amount of work can measure up to about a thousand gas differently on another pool shape. `dynamic-fees` is not such a piece: the root simulates the whole swap to price it, so its figure grows with the swap (compare `dynamic-fees.small-buy` and `dynamic-fees.large-buy`). After the window Anti-Snipe and Wallet Cap run no code: the root's frames are identical on a guarded pool and on a fee-only one, and the tens of gas by which `after-window` misses zero are the PoolManager's swap math on two pools at slightly different prices. Pinning block 87,330,000 instead gave the same figures to the gas, except `wallet-cap.after-window` and its `uncurated-router` twin, which moved from 48 to 36.

**If it fails.** A test that cannot fork stops with a message, never with a passing result: `` environment variable `ROBINHOOD_RPC_URL` not found `` means the variable the alias names is not exported in this shell, `invalid rpc url: robinhood` means the alias is not in your Foundry config, and an error about missing state or a missing block means the endpoint cannot serve block 87,300,000, as a node that is not an archive node cannot.

## The live contracts

The bench deploys none of these; it calls them at the pinned block. The Hookr 1 names and addresses are those of [`hookr-1/deployments/robinhood-4663.json`](../hookr-1/deployments/robinhood-4663.json), except the Wallet Cap Rules, deployed on 2026-10-12.

| Contract | Address | Used for |
| --- | --- | --- |
| `HookrRoot` | `0x89c9FB50d1f03192230FFB1c279BB6E7d3Fe6aCc` | the shared root every Hookr pool uses as its hook |
| `HookrLauncher` | `0x1cf2748A6670572425eAbf9Ab9e5BC4eb2eB8Ef4` | opening every pool and every launch |
| `HookrRules` (release) | `0x4a71c270b1520F94064268102AebD744b0DE7942` | LP Rewards, creator royalty, Auto Burn, Anti-Snipe, dynamic fees and the fee-only pools |
| `HookrRules` (whole-pot) | `0x10f684361b35C8411a2c07F68A6fB1F4B7e555F7` | the arb recapture lane, King of the Pool, and the control for Wallet Cap |
| `HookrRulesWalletCap` | `0xb67b73E28C522a3AAC438bE970bf94976Deee52a` | Wallet Cap v2 |
| `HookrRulesRoundTrip` | `0x3d7e31746127FD9a14d3C7fC12E73611D2e8cb34` | the Rules Buy/Sell Block sits on |
| `HookrLimitOrders` | `0x0c376cc30b1AC98b8ef80a4F516212D3B99402fA` | limit orders |
| `HookrFamilyLock` | `0xfAFEcE64099C1E791C4B46189c277f00c0c7e00b` | the liquidity lock |
| `HookrMarketGuard` | `0xFc5CAE364FDEE4347D97E2aEB82f3155068693A4` | Market Guard |
| `HookrBuySellBlock` | `0xffefEA428C13813D4526fc77A8CA0df0c787626f` | Buy/Sell Block |
| Universal Router 2.1.1 | `0x8876789976dEcBfCbBbe364623C63652db8C0904` | the router the root curates |
| Universal Router (second) | `0x06AfBA43Fd06227fA663b0DAecF536f6EaA6bf99` | the router the root does not curate; runtime code hash `0xbe8e…02d5`, as [`deployments/robinhood-4663.v2.json`](../deployments/robinhood-4663.v2.json) records |
| ETH / USD price feed | `0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9` | the feed Market Guard prices against |
| `PoolManager`, Permit2, WETH | `0x8366a39CC670B4001A1121B8F6A443A643e40951`, `0x000000000022D473030F116dDEE9F6B43aC78BA3`, `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` | the chain's own |

## gas-figures.json

```json
{
  "schema": 1,
  "chainId": 4663,
  "forkBlock": 87300000,
  "source": "Hookr-fun/hookr-contracts@<commit> bench",
  "measuredAt": "<YYYY-MM-DD>",
  "method": "<one sentence>",
  "figures": [
    {
      "id": "wallet-cap.first-buy",
      "piece": "wallet-cap",
      "label": "Wallet Cap in the window: a wallet's first buy",
      "action": "first-buy",
      "gas": 24260,
      "baseline": "same-pool-without-piece",
      "router": "Universal Router 2.1.1 (curated by the root)",
      "test": "bench/test/WalletCap.t.sol:test_curatedRouter"
    }
  ]
}
```

| Field | Meaning |
| --- | --- |
| `id` | stable name of the figure |
| `piece` | the Hook Block's slug on `hookr.fun/hooks/<slug>`, or `base`, `launch` or `claim`. `lp-rewards.with-royalty-and-auto-burn` is filed under `lp-rewards`: it is the three fee rules together, not a page of its own |
| `label` | the figure in plain words |
| `action` | `buy`, `sell`, `first-buy`, `repeat-buy`, `after-window`, `launch`, `claim`, `place`, `cancel`, `fill`, `collect` or `per-swap` |
| `gas` | whole-transaction gas, an integer: the extra gas of the piece, or the whole transaction when the baseline is `absolute` |
| `baseline` | `hookless-pool`, `same-pool-without-piece` or `absolute`, as the table above says. For `wallet-cap` and `buy-sell-block` the pool without the piece is on another Rules contract (the whole-pot Rules, and the release Rules), because the piece is a Rules contract or sits on one |
| `router` | how the transaction reached the pool |
| `test` | the test that measures it, `file:function` from the repository root |

`source` names the last commit that changed what the figures are measured with: `bench/foundry.toml`, `bench/gas-figures.mjs`, `bench/src`, `bench/test`, the Hookr interfaces, types and Hook Block libraries the tests compile (`hookr-1/src/interfaces`, `hookr-1/src/types`, `hookr-1/hook-blocks/limit-orders/src`, `hookr-1/hook-blocks/market-guard/src`) and the `lib` submodule pins. Committing the JSON and this README does not change it. The script refuses to run while those paths have uncommitted changes, and `--check` fails when they differ from the commit `source` names. A squash merge replaces that commit: the check then says the commit is not in the history and passes, and running the command once on the merged tree restamps it.

## In CI

CI does not run the fork: it needs an archive RPC endpoint and this repository keeps no RPC secret. The `bench` job checks the bench's formatting, builds it and runs `node bench/gas-figures.mjs --check`, which verifies the committed `gas-figures.json` against the schema above, that every `test` names a real test, that this README's table agrees with the file and that what the figures are measured with has not changed since the commit `source` names. `make bench` runs the same three commands locally and is part of `make check`; the fork itself is not.

## Files

| Path | What it is |
| --- | --- |
| `gas-figures.mjs` | the command: runs the bench, merges the figures, checks them |
| `gas-figures.json` | the figures, the file hookr.fun reads |
| `src/BenchToken.sol`, `src/LiquidityAdder.sol` | the bench token, and the helper that adds a position to a hookless pool |
| `src/interfaces/` | the Universal Router, Permit2 and price feed calls the tests make |
| `test/LiveContracts.sol`, `test/Fork.sol`, `test/Figures.sol`, `test/Swaps.sol`, `test/Pools.sol` | the live addresses, the fork, how a figure is recorded, how a swap is sent, and the pools |
| `test/Base.t.sol` | `base` |
| `test/FeeRules.t.sol` | `lp-rewards`, `creator-royalty`, `auto-burn` |
| `test/AntiSnipe.t.sol`, `test/WalletCap.t.sol` | `anti-snipe`, `wallet-cap` |
| `test/DynamicFee.t.sol` | `dynamic-fees` |
| `test/Lane.t.sol` | `arb-recapture`, `king-of-the-pool` |
| `test/LimitOrders.t.sol`, `test/FamilyLock.t.sol` | `limit-orders`, `liquidity-lock` |
| `test/MarketGuard.t.sol`, `test/BuySellBlock.t.sol` | `market-guard`, `buy-sell-block` |
| `test/Launch.t.sol`, `test/Claim.t.sol` | `launch`, `claim` |

To add a figure, add the test, run the command, and add its row to the table above; the check fails until the README and the file agree.
