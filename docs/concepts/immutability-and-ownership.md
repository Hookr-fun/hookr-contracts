# Immutability and ownership

A Hookr pool's behaviour is fixed at creation. This page lists exactly what the owner can do, and what nobody can do.

## What Is Frozen per Pool

At creation the registry stores one `StackCore` for the `PoolId` holding the kernel, the subject, the quote, the stack hash, the trusted router and quoter with their code hashes and the per-pool caps, and stores the frozen config hash of each module alongside it. The module's config is frozen with it.

On every swap and every liquidity add the module re-reads that record and re-derives `keccak256(config)`. A mismatch reverts. Anything that could change a pool's rules would have to change a hash that nothing can write.

That covers: the base LP fee, the surge ceiling and sensitivity, the guard window and its three parameters, the burn, LP-reward, pot and royalty rates, the royalty recipient, the pot floor and interval, the protocol share, the protocol recipient, and the trusted router and quoter. The founding-position fee recipient is frozen the same way in effect, written once into the coordinator's market record with no setter.

## Owner Powers

There are four owner slots in this system, all under two-step transfer (`proposeOwner` then `acceptOwnership`): the coordinator's, the registry's, the catalog's and the forwarder's. One address holds all four in the deployed release.

| Contract | Function | Effect | Reaches a live pool? |
| --- | --- | --- | --- |
| Coordinator | `setMarketOpeningPaused(bool)` | While paused only the owner may open markets. The owner may always open. | No |
| Coordinator | `setDefaultProtocolShareBps(uint24)` | Changes the share future markets resolve to, bounded by `MAX_PROTOCOL_SHARE_BPS`. | No |
| Coordinator | `setCreatorTier(address, uint24)` / `clearCreatorTier(address)` | Sets or clears one launcher's share, same bound. | No |
| Coordinator | `proposeOwner` / `acceptOwnership` | Two-step ownership transfer. | No |
| Registry | `registerIntegration` / `retireIntegration` | Admits or retires a router, quoter, or correction executor for future stacks. | No |
| Registry | `registerKernel` / `retireKernel` | Admits or retires a root implementation for future stacks. | No |
| Registry | `setCoordinatorOnce(address)` | Binds the one coordinator. Irreversible, callable once. | No |
| Registry | `sealRootProfile(...)` | Seals the admission envelope. Irreversible, callable once per kernel. | No |
| Catalog | `registerModule` / `retireModule` | Admits or retires a module implementation for future stacks. Registration caps are permanent. | No |
| Catalog | `setCanonicalStatefulModuleOnce(address)` | Binds the one stateful module. Irreversible, callable once. | No |
| Forwarder | `setTarget` / `setTargetAndCollect` | Rotates where collected protocol shares are paid. | No |
| Forwarder | `setNativeBlock(address)` | Points the forwarder at a module that already names it. | No |
| Forwarder | `proposeOwner` / `acceptOwnership` | Two-step ownership transfer. | No |

Retiring a module, integration or kernel affects future admission only. A sealed profile and every open pool keep working.

## What Nobody Can Do

- Change any parameter of a pool that is already open.
- Pause, freeze, halt, or blacklist a pool, a swap, or a trader.
- Remove the new-token founding position. The coordinator holds it and exposes no removal path.
- Take a share of the base LP fee.
- Raise `MAX_PROTOCOL_SHARE_BPS`. It is a module constant with no setter; raising it needs a new module, which needs a new catalog, registry and root, because the binds above are one-shot.
- Change a module's `protocolRecipient`, or the coordinator's `treasury`. Both are set at construction.
- Upgrade anything. There are no proxies in this system.
- Move funds owed to somebody else. The claim ledger pays `msg.sender` or an address `msg.sender` names.

## Permissionless Functions

Four things anyone can call, by design:

- `openExistingTokenMarket` opens a pool for any deployed token, subject to the opening pause.
- `collectLpFees(poolId)` collects the founding position's fees to the creator's chosen recipient.
- `collect(quote)` and `sweep(token)` on the forwarder push accrued protocol shares to the owner-set target.
- `claim(quote)` and `claimTo(quote, to)` on the module pay out a pot win, a royalty, or an accrual to whoever it is owed to.

None of these lets the caller redirect value. They only move value along a path that was fixed at creation.

## One Thing to Read Carefully

`openExistingTokenMarket` is permissionless and performs no ownership check on the subject token. `market.creator` records who opened the pool and nothing more. An interface must not present it as token ownership or as an endorsement by the token's team.
