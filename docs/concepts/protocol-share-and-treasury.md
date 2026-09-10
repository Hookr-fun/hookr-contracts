# Protocol share and treasury

The protocol's revenue is one number per pool, `protocolShareBps`, and one address, the treasury forwarder. This page covers how the number is chosen and how the money moves.

## Resolving the Share

`HookrMarketCoordinatorV5.protocolShareBps(creator)` is two steps and nothing else:

```solidity
function protocolShareBps(address creator) public view returns (uint24 shareBps) {
    Tier memory tier = creatorTier[creator];
    if (tier.set) return tier.shareBps;
    return defaultProtocolShareBps;
}
```

`defaultProtocolShareBps` starts at 2,000 (20%). `creatorTier[creator]` is an owner-set override. Both are bounded by `MAX_PROTOCOL_SHARE_BPS = 5,000` on write and revert `ProtocolShareAboveCeiling` above it. `clearCreatorTier` returns a launcher to the default.

Nothing about the market enters the resolution. The subject, the quote, the royalty and the cuts play no part; only the address that calls the open function does.

## Tiers Are Keyed on the Caller

`creator` is whatever address calls `openNewTokenMarket` or `openExistingTokenMarket`. A tier granted to a contract launcher therefore applies to every market that contract opens, for every one of its end users, until the tier is cleared. That is the intended integrator mechanism: a partner front end deploys one launcher contract, receives a tier, and passes the rate on to its users.

A tier granted to an EOA covers only that EOA's own launches.

## Frozen at Creation

Admission reads `protocolShareBps(creator)` and reverts `ProtocolShareTierMismatch(expected, actual)` unless the config carries exactly that value. The value then lives in the pool's frozen config, and the hook re-derives the config hash on every swap and every liquidity add.

A later change to the default or to a tier cannot reach a pool that is already open. There is no function anywhere in the system that changes a live pool's share.

## The Forwarder

`HookrNativeMechanicsBlockV2.protocolRecipient` is immutable, and the admission library only admits a market while that recipient equals `coordinator.treasuryBeneficiary()`. The coordinator's `treasury` is constructor-only; there is no `setTreasury`.

Pinning an EOA at either end would mean that rotating the payout destination requires redeploying both contracts, which would de-admit every future market. `HookrTreasuryForwarderV1` is pinned instead. Its address never changes. Its owner-settable `target` does.

The forwarder holds no protocol authority. It cannot open markets, change tiers, pause anything, or touch a pool. It can only move funds it is already owed to one destination.

## Collecting

Protocol shares accrue inside the module as `claimable[quote][protocolRecipient]`, one ledger per quote currency. Two permissionless functions move them:

```solidity
function collect(address quote) external returns (uint256 collected);
function sweep(address token) external;
```

`collect` claims the module's balance for that quote into the forwarder and forwards it to `target` in the same call. If the target rejects the payment the accrual is already out of the module, `ForwardDeferred` is emitted, and the funds rest on the forwarder until someone calls `sweep`. When nothing is owed it returns zero rather than reverting.

`sweep` pushes whatever the forwarder itself holds to `target`. Unlike `collect` it reverts when the target rejects, because at that point there is nothing left to rescue.

Anyone can call either one. Only the destination is governed.

## Rotating the Target

`setTarget(address)` is owner-only. `setTargetAndCollect(address newTarget, address[] quotes)` rotates and drains in the same transaction, which closes the window where a compromised old target could still be paid. Broadcast that one through a private relay if the old target is believed compromised; a public mempool still exposes the intent, just not a claimable gap.

Three destinations are rejected outright by `_requireSafeTarget`: the forwarder itself, the bound module, and the PoolManager. Paying the PoolManager would leave the balance takeable by whoever calls `take` next.

## Binding the Module

`setNativeBlock(address)` is owner-gated and deliberately not one-shot. The candidate must already read back this forwarder as its own `protocolRecipient`, so the owner can only ever point at a module that already pays here.

Mutable was chosen over one-shot on purpose. Every accrual lives in its own module's `claimable[quote][forwarder]` mapping and `claimTo` always pays whatever address the forwarder holds at call time, so re-pointing strands nothing. A one-shot bind has the worse failure: binding the wrong module once would strand every market's protocol share forever, because a module's recipient is immutable and can never be moved to a second forwarder.

## What the Share Is Not

It is never taken from the base LP fee. It is never taken in subject tokens. It is never added on top of what the trader agreed to pay. And it is zero on a pool that runs on its base fee alone.
