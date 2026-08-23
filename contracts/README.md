# Hookr contracts

Foundry workspace for the Hookr generation-4 candidate. Solidity is pinned to 0.8.26 with
optimizer, via-IR, Cancun, and no metadata bytecode hash. Generation 3 is the current live release;
generation 4 is source-ready and fork-rehearsed, not deployed.

## Components

- `HookrLaunchpad.sol` — fixed-supply token launch through either the ten-tranche curve or an
  immediate pool, sender-bound launch calldata, immutable per-pool configuration, locked full-range
  POL, fee accounting, and blueprints.
- `HookrHook.sol` — shared v4 hook implementing Anti-Snipe, Surge Fees, Auto Burn, LP Rewards, and
  the deterministic Nth-buy Pot.
- `HookrSwapRouter.sol` — live-pool router with bound recipient/hook data, deadline,
  execution-time min/max, measured settlement, native refund, and callback/reentrancy guards.
- `HookrToken.sol` — fixed 1 billion supply ERC-20 without owner mint, pause, blacklist, or token
  transfer tax.

The hook permission mask is `0x28cc`:

```text
beforeInitialize | beforeAddLiquidity | beforeSwap | afterSwap |
beforeSwapReturnsDelta | afterSwapReturnsDelta
```

`beforeAddLiquidity` prevents outside positions from diluting guarded fee attribution only while a
pool's finite anti-snipe window is active. The launchpad can seed its locked positions during that
window, and permissionless LP additions resume at the exact guard boundary.

The `burnTriggerWei` field and `buybackAndBurn` selector remain only for v2 ABI migration. Every new
configuration must set the field to zero, and the legacy entrypoint always reverts.

Every generation-4 `LaunchArgs` includes a nonzero `expectedCreator`, and either launch path
requires it to equal
`msg.sender`. A copied approved calldata packet therefore cannot be launched by another account.
Names, symbols, taglines, and image URIs are intentionally not globally unique: another creator can
submit independently approved calldata with duplicate metadata, so interfaces must identify tokens
by chain and contract address rather than metadata alone.

Agent approval packets must use `launchWithIntent(args, intentId)` for the curve path or
`launchInstantWithIntent(args, poolSupplyBps, intentId)` for the instant path. Both share one
nonzero, `msg.sender`-scoped intent namespace; after success,
`launchedByIntent(creator, intentId)` returns the deployed token. Reusing that exact creator/intent
pair on either path reverts, while a failed launch rolls back the marker and can be retried. The
ordinary non-intent entrypoints remain repeatable by design.

## Verification

```bash
./setup.sh
forge fmt --check
forge build --sizes
forge test -vv
```

`setup.sh` initializes the pinned submodules and applies the one-line pragma widening inside the
vendored v4-core checkout that `foundry.toml` documents (the pinned compiler is 0.8.28; upstream
`PoolManager.sol` pins exactly 0.8.26, which trips an immutable-size codegen bug fixed in 0.8.27).

Important suites:

- `Curve.t.sol` — curve/admin/view unit and fuzz behavior;
- `RegressionLaunchpad.t.sol` — launchpad/hook validator equivalence and historical fixes;
- `Regression.t.sol` — settlement, guard, pot, Auto Burn, and LP donation regressions;
- `AdversarialAudit.t.sol` — atomic slot farming, recipient binding, JIT LP, payout recovery,
  ownership, non-flushable pot accounting, and solvency;
- `HookrSwapRouter.t.sol` — exact-input/output buy/sell settlement and failure boundaries;
- `InstantLaunch.t.sol` and `InstantLaunchDefects.t.sol` — preview/launch identity, locked instant
  liquidity, replay safety, price/float bounds, guard accounting, and adversarial regressions;
- `Fork.t.sol` — candidate integration against the canonical Robinhood Chain PoolManager.

The release matrix must prove all 32 masks of the five behavior bits can launch, configure, and
trade, including sell-out/graduation for the curve path and direct pool opening for the instant
path. A separate all-five fork case must run with
`ROBINHOOD_FORK_BLOCK` pinned to one freshly captured Robinhood block.

## Release protocol

1. Run the complete local and pinned-block fork suites; retain command, block number/hash, and SHA.
   The public Robinhood RPC is pruned, so an archive-capable endpoint is required to replay an
   older evidence block.
2. Run a no-broadcast deployment simulation and record predicted addresses/runtime hashes. The
   CREATE2 miner excludes candidates with existing code or a nonzero nonce.
3. Review the exact deployer, chain ID 4663, CREATE2 salt/flags, fees, ownership, router, and five
   seeded blueprints. The scripts also pin the reviewed PoolManager and deterministic CREATE2
   deployer runtime code hashes.
4. Only after explicit confirmation, broadcast the deployment from the expected user-controlled
   deployer.
5. Verify every receipt in order, then verify runtime hashes, `contractName()`/`contractVersion()`,
   hook/PoolManager linkage, owner, permission bits, blueprint count/params, and router linkage.
6. Present the canary transactions for confirmation. The first receipt consumes the script's fixed
   nonzero generation-4 `CANARY_INTENT_ID` through `launchInstantWithIntent`; intent consumption,
   token creation, pool opening, and locked liquidity are one atomic transaction. Verify
   `launchedByIntent(deployer, intentId)` returns that exact token and the launch record has no curve
   state. The later guarded router buy, token approval, and router sell are separate receipts.
   Verify the instant event/record, liquidity, config, Auto Burn, surge/snipe fees, LP donation,
   Nth-buy Pot, router bounds, and all emitted/postcondition values after the corresponding receipt.
7. Promote only the current generation-4 manifest after those readbacks match; retain generation 3
   in the read registry.

The canary is address- and bound-driven: set `HOOKR_LAUNCHPAD_ADDRESS`, `HOOKR_HOOK_ADDRESS`,
`HOOKR_SWAP_ROUTER_ADDRESS`, `HOOKR_LAUNCHPAD_RUNTIME_CODEHASH`, `HOOKR_HOOK_RUNTIME_CODEHASH`,
`HOOKR_SWAP_ROUTER_RUNTIME_CODEHASH`, `CANARY_BUY_MIN_TOKENS_OUT`, and
`CANARY_SELL_MIN_WEI_OUT` from the reviewed deployment/simulation packet. Runtime hashes and both
swap bounds must be nonzero. The scripts use the fixed reviewed deployer address, so simulations
need no secret. A live run must explicitly select the matching Foundry account or hardware wallet
after review; never place a private key in argv or the repository.

Never place a private key in a command line, repository, log, or report. A dry run does not
authorize a broadcast, and a deployment broadcast does not authorize the canary. Forge scripts
simulate the whole sequence atomically, but live broadcasts are multi-transaction: a later revert
or failed readback cannot roll back an earlier mined transaction.

## Release boundary

Generation 3 remains the live, write-enabled deployment until generation 4 has its own real ordered
receipts, runtime/linkage readbacks, instant canary, and promotion. Older token pools remain
immutable and readable through the retained registry; a generation-4 promotion changes the current
write target rather than rewriting historical identities. Historical v2 Foundry records are
preserved and explicitly labeled in [`evidence/v2/`](evidence/v2/README.md). Never use a local
`contracts/broadcast/**/run-latest.json` file or fork receipt as production evidence.
