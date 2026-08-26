# Arb Recapture integration candidate

Status: **source review; not deployed; route signing disabled**.

Arb Recapture is the reviewed V6 direction for attempting to keep more cross-venue price-gap value
inside a Hookr market. It is not a promise that arbitrage is prevented.

## Intended swap boundary

1. The user's Hookr swap executes first.
2. The hook validates one fixed-venue, EIP-712-signed correction candidate.
3. A bounded executor may attempt that one route under a gas stipend.
4. Only realized quote-asset profit is allocated to the trader, creator or attacher, and protocol.
5. A stale, unprofitable, or failed correction is caught so the original user swap can complete.

The first reviewed route is native-quote only and targets a fixed canonical v3 venue or a hookless,
static-fee v4 venue. Arbitrary paths, dynamic external hooks, multihop routes, and unsigned executor
instructions are outside the candidate boundary.

## Hook-block compatibility

| Hookr block | Reviewed V6 composition |
| --- | --- |
| Anti-Snipe | Compatible |
| Surge Fees | Compatible |
| Auto Burn | Compatible |
| Nth-buy Pot | Compatible |
| LP Rewards | **Excluded** — JIT donation capture conflicts with the first V6 design |

“Arbitrage protection on all hooks” therefore means an optional V6 sidecar for four current Hookr
blocks, not all five, and not every external Uniswap hook.

## Pool scope

- New Hookr launches need a V6 hook, router, and release manifest.
- An existing token can use a newly created V6 Hookr pool; its old pools remain unchanged.
- Existing V5 pools cannot be retrofitted.
- The feature starts watching only after a supported second venue exists.

## Required release evidence

- reviewed public source and dependency lock;
- passing local, invariant, adversarial, and pinned-block fork suites;
- fixed signer authority, rotation, venue, PoolKeys, profit floor, volume bound, and split math;
- no-broadcast simulation and human review of the exact deployment packet;
- ordered deployment receipts plus runtime, immutable wiring, and source verification;
- one canary that proves successful capture and one that proves failed correction leaves the user swap intact;
- allocation readback before any result is described as captured;
- promoted V6 and route-service manifests before any signer or transaction API is exposed.

Use the `executor_adapter` track for a route service or executor, `hook_token_launch` for a new token,
and `existing_token_pool` for a new market around an existing token.
