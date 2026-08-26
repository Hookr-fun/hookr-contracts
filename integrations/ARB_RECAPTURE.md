# Hookr x WTH Arb Recapture integration candidate

Status: **source-only and inactive; not deployed; route signing disabled**.

WTH Arb Recapture is an **optional** reviewed V6 profile for attempting to keep more cross-venue
price-gap value inside a Hookr market. It is not a promise that arbitrage is prevented.

“WTH” is a source profile label, not proof of an active WTH service or partnership. No WTH
service/operator identity, production recipient, external ABI acceptance, or live service is
verified. The profile cannot be activated until those items and a reviewed LP distributor exist.

The integration and fee-policy identities are frozen in source as
`hookr.integration.wth-arb.v1` and
`hookr.fee-policy.wth-arb.v1:creator=4000,trader=2000,trigger-pool-lp=2000,wth=1000,hookr=1000`.
Their onchain `keccak256` ids are `0x96b4bee6c464c61145bc4ddbff93ba0bc5e303003b633a6676dbe491acd3e651`
and `0xe786145bacf8a9afb49db278f5c581557d335b51cebbed990a5c5e0871910499`.
Those identities are release inputs, not evidence that a market is already bound or live.

## V6 integration grammar

The machine-readable `v6IntegrationModel` capability records the reviewed architecture boundary:

- every v4 `PoolKey` selects exactly one root hook profile at checkout;
- native Hookr blocks compose only through a reviewed schema compiled into a new immutable Hookr
  generation;
- an optional subordinate executor must be bound through its exact versioned profile;
- an exclusive external root cannot combine with native Hookr blocks and needs a purpose-built
  adapter plus explicit router and quoter policy;
- an existing-token integration creates a new `PoolKey` and leaves old pools unchanged;
- a launchpad adapter atomically binds the exact profile, config, caller, creator, beneficiary,
  funding, deadline, and nonce;
- an already deployed hook cannot be inserted as a native block; and
- monetization exists only through an explicit versioned `feePolicyHash` and recipient accounting.

This is source-review metadata, not a production claim. The public SDK remains V5-only and exposes
no V6 transaction API.

## Intended swap boundary

1. The user's Hookr swap executes first.
2. The hook validates one fixed-venue, EIP-712-signed correction candidate.
3. A bounded executor may attempt that one route under a gas stipend.
4. Only realized quote-asset profit enters the fixed waterfall below.
5. A stale, unprofitable, or failed correction is caught so the original user swap can complete.

The first reviewed route is native-quote only and targets a fixed canonical v3 venue or a hookless,
static-fee v4 venue. Arbitrary paths, dynamic external hooks, multihop routes, and unsigned executor
instructions are outside the candidate boundary.

## Fixed realized-profit waterfall

The Builder does not expose allocation sliders. The source-only profile fixes this proposed split
of gross realized quote-asset profit:

| Beneficiary | Share |
| --- | ---: |
| Launch-token creator, or authorized attacher for an existing-token pool | 40% |
| Authenticated triggering swap recipient | 20% |
| PoolId-scoped LP escrow (not distributed) | 20% |
| Proposed WTH service recipient (identity and recipient unverified) | 10% |
| Hookr | 10% |

The current source reserves the LP allocation in pool-scoped adapter escrow. It does **not** yet
prove distribution to eligible LP positions. A reviewed distributor that binds the exact trigger
PoolKey, plus receipt and balance readback, remains a release blocker.
No LP receives or can claim this escrow today.

## Hook-block compatibility

| Hookr block | Reviewed V6 composition |
| --- | --- |
| Anti-Snipe | **Conditional** — while the opening guard is active, outer-buy Arb corrections can operate; outer-sell corrections require an exact-output target buy and fail open until the guard ends |
| Surge Fees | Compatible |
| Auto Burn | Compatible |
| Nth-buy Pot | Compatible |
| LP Rewards | **Excluded** — JIT donation capture conflicts with the first V6 design |

“Offering Arb Recapture across Hookr profiles” therefore means an optional, exact-profile V6
subordinate executor for three unconditionally compatible blocks plus conditional Anti-Snipe
support, not all five, and not every external Uniswap hook. Fail-open means the correction is
skipped so the original user swap can continue; it does not convert a guarded outer sell into an
unguarded trade.

## Pool scope

- New Hookr launches need a V6 hook, router, and release manifest.
- An existing token can use a newly created V6 Hookr pool; its old pools remain unchanged. The
  governance-authorized attacher is the 40% creator beneficiary for that new market.
- Existing-token admission requires `decimals()` to return 18 and the initial factory pull to
  produce the exact requested balance delta. Those admission checks do not certify later behavior;
  tokens that can later tax, rebase, pause/freeze, blacklist, invoke callbacks/reentrancy, lose
  code, or otherwise mutate transfer semantics are unsupported.
- Existing V5 pools cannot be retrofitted.
- After every activation gate, the intended feature would start watching only after a supported
  second venue exists. No current pool is active or watching under this profile.

## Required release evidence

- reviewed public source and dependency lock;
- passing local, invariant, adversarial, and pinned-block fork suites;
- fixed signer authority, rotation, venue, PoolKeys, profit floor, volume bound, and split math;
- no-broadcast simulation and human review of the exact deployment packet;
- ordered deployment receipts plus runtime, immutable wiring, and source verification;
- one canary that proves successful capture and one that proves failed correction leaves the user swap intact;
- allocation readback before any result is described as captured;
- atomic market binding to the exact integration and fee-policy identities;
- verified WTH service/operator identity, exact production recipient, external ABI, and policy
  acceptance;
- a reviewed PoolId-bound LP distributor plus receipt and balance proof of delivery;
- promoted V6 and route-service manifests before any signer or transaction API is exposed.

The public `@hookr/sdk` release candidate remains V5-only. WTH/V6 transaction methods stay absent
until the promoted V6 manifest, runtime wiring, signer authority, LP distributor, and canary
readback all exist.

Use the `executor_adapter` track for a route service or executor, `hook_token_launch` for a new token,
and `existing_token_pool` for a new market around an existing token.
