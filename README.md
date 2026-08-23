# Hookr contracts

Foundry workspace for [Hookr](https://hookr.fun) — a token launchpad on Robinhood Chain where the market rules are a Uniswap v4 hook you compose yourself.

A token sells along a ten-tranche bonding curve; when the curve fills, the launch graduates atomically into a full-range Uniswap v4 position owned by the launchpad — which has no function to remove it — with your hook attached.

## The five blocks

The hook is up to five composable blocks, each running inside the swap on the pool's own callbacks. There is no keeper, no off-chain trigger, and no oracle:

| Block | What it does |
| --- | --- |
| Anti-Snipe | For N blocks after graduation, caps each buy at a share of supply and adds an extra LP fee. Exact-output buys are blocked so the cap cannot be routed around. |
| Surge Fees | Scales the LP fee with how much of in-range depth a trade consumes, from your base to your ceiling. |
| Auto Burn | Sends a share of actual buy output straight to the dead address, inside the swap. |
| LP Rewards | Donates an ETH-side share of a buy to in-range LPs, in that same swap. |
| Nth-buy Pot | Fills a pot from an ETH-side share; a public counter advances at most once per pool per block and the Nth qualifying slot wins. |

Cuts apply to exact-input buys; sells pay the LP fee only. Once a pool graduates, no owner function can retune any of it — not the creator's, not ours.

## Live deployment

Release generation 3 is live on Robinhood Chain (chain ID 4663):

| Contract | Address |
|---|---|
| `HookrLaunchpad` | [`0xaAed6fab06D53311220F35421Dda5cc6D6e9d6C3`](https://robinhoodchain.blockscout.com/address/0xaAed6fab06D53311220F35421Dda5cc6D6e9d6C3) |
| `HookrLaunchpadLib` | [`0x2d1610b7d5212F5D6726834CFfd1c3f8b425f04f`](https://robinhoodchain.blockscout.com/address/0x2d1610b7d5212F5D6726834CFfd1c3f8b425f04f) |
| `HookrHook` | [`0xd0005624Da88a688BcaB3DBFB4d1Cb23d32Ca0CC`](https://robinhoodchain.blockscout.com/address/0xd0005624Da88a688BcaB3DBFB4d1Cb23d32Ca0CC) |
| `HookrSwapRouter` | [`0x3f6E7BA9689d3c78A00d68931b7C223f51e0f21b`](https://robinhoodchain.blockscout.com/address/0x3f6E7BA9689d3c78A00d68931b7C223f51e0f21b) |
| Uniswap v4 `PoolManager` | [`0x8366a39CC670B4001A1121B8F6A443A643e40951`](https://robinhoodchain.blockscout.com/address/0x8366a39CC670B4001A1121B8F6A443A643e40951) |

The launchpad links `HookrLaunchpadLib` by `DELEGATECALL`: it does not fit under EIP-170 with its bonding-curve arithmetic and token factory inlined. Nothing here is independently audited; the adversarial test suites and the release protocol below are our own review evidence, not a substitute for one.

Superseded generations stay on chain and immutable, with their broadcast records preserved under [`contracts/evidence/`](contracts/evidence/v2/README.md).

## Layout

```text
contracts/src/       launchpad, shared hook, token, production router, leverage research lane
contracts/test/      unit, fuzz, adversarial, invariant, exhaustive-stack, and fork integration tests
contracts/script/    dry-run/deployment scripts and user-confirmed canary scripts
contracts/audit-poc/ proof-of-concept exploits and their verifications
contracts/evidence/  immutable historical broadcast records, hash-pinned
scripts/             deployment preflight, receipt verification, and release-promotion tooling
docs/                utility terms and chain-extension notes
```

## Components

- `HookrLaunchpad.sol` — fixed-supply token launch through either the ten-tranche curve or an immediate pool, sender-bound launch calldata, immutable per-pool configuration, locked full-range POL, fee accounting, and blueprints.
- `HookrHook.sol` — shared v4 hook implementing all five blocks.
- `HookrSwapRouter.sol` — live-pool router with bound recipient/hook data, deadline, execution-time min/max, measured settlement, native refund, and callback/reentrancy guards.
- `HookrToken.sol` — fixed 1 billion supply ERC-20 without owner mint, pause, blacklist, or transfer tax.
- `Leverage*.sol` — leveraged-hooks research lane: deployed for verification, writes closed. See [`LEVERAGED_HOOKS_ARCHITECTURE.md`](contracts/LEVERAGED_HOOKS_ARCHITECTURE.md) and [`AUDIT.md`](contracts/AUDIT.md).

## Build and test

```bash
cd contracts
forge fmt --check
forge build --sizes
forge test -vv
```

Key suites:

- `Curve.t.sol`, `Regression.t.sol`, `RegressionLaunchpad.t.sol` — unit behavior and historical regressions;
- `AdversarialAudit.t.sol` — atomic slot farming, recipient binding, JIT LP, payout recovery, solvency;
- `InstantLaunch*.t.sol`, `GuardPartialFillAudit.t.sol` — instant-lane previews, locked liquidity, replay safety;
- `Leverage*` tests — exploit reproductions, invariants, and math checks for the research lane;
- `Fork.t.sol` — candidate integration against the canonical Robinhood Chain PoolManager.

Robinhood's public RPC is pruned, so fork replay of older blocks needs an archive-capable endpoint.

## Release protocol

Releases are gated by ordered evidence, never by a boolean: complete local and pinned-block fork runs, a no-broadcast simulation, human review of deployer/salts/fees/ownership, explicit confirmation before each broadcast, per-receipt verification, runtime/linkage readbacks, a canary that consumes a fixed intent id exactly once, and only then promotion of a release manifest. The tooling in [`scripts/`](scripts/) verifies every step against live RPC state.

Deployment scripts simulate without broadcasting and pin the reviewed sender address, so a dry run loads no key material. Never place a private key in argv, the repository, a log, or a report.

See [`contracts/README.md`](contracts/README.md), [`contracts/RELEASE.md`](contracts/RELEASE.md), and [`contracts/UTILITY_RELEASE.md`](contracts/UTILITY_RELEASE.md) for the full checklists.

## License

MIT
