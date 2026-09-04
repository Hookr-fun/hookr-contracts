# Hookr x WTH Arb Recapture integration candidate

Status: **source-only and inactive; not deployed; route signing disabled**.

WTH Arb Recapture is an **optional** V6.1 source-review profile for attempting to keep more cross-venue
price-gap value inside a Hookr market. It is not a promise that arbitrage is prevented.

“WTH” is a source profile label, not proof of an active WTH service or partnership. No WTH
service/operator identity, production recipient, external ABI acceptance, or live service is
verified. The profile cannot be activated until those items and a reviewed LP distributor exist.

The separately versioned V6.1 integration and fee-policy identities are
`hookr.integration.wth-arb.v2` and
`hookr.fee-policy.wth-arb.v2:hookr=1000,wth=1000,configurable-creator-trader-trigger-pool-sum=8000`.
Their onchain `keccak256` ids are `0xd49d445cfb1f944f40848794320f9ba89f9a8830fcbedf98c236f82476f7d680`
and `0x656d4d246973da37dc2020b1c4494018646a8033d212c09dc3bb82a4b0898ba7`.
Those identities are release inputs, not evidence that a market is already bound or live.
The clean V6.1 source checkpoint is
`5168888ed69cc738492368203197ee72a009a964`. It is review provenance only—not a merge,
deployment, promoted manifest, accepted WTH runtime, or transaction API.
The frozen V6/WTH-v1 reference uses a superseded flat-split ABI and must not be linked or deployed
as WTH-v2. V6.1 contracts, libraries, EIP-712 types, executor interface, quoter, and release evidence
remain separate identities.

## V6.1 integration grammar

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
no V6 or V6.1 transaction API.

## Intended swap boundary

1. The user's Hookr swap executes first.
2. The hook validates one fixed-venue, EIP-712-signed correction candidate.
3. A bounded executor may attempt that one route under a gas stipend.
4. Only realized quote-asset profit enters the versioned waterfall below.
5. A stale, unprofitable, or failed correction is caught so the original user swap can complete.

The first reviewed route is native-quote only and targets a fixed canonical v3 venue or a hookless,
static-fee v4 venue. Arbitrary paths, dynamic external hooks, multihop routes, and unsigned executor
instructions are outside the candidate boundary.

## Fixed protocol shares and pool-locked remainder

WTH's v2 boundary fixes only the two protocol shares. Hookr supplies a pool-locked `ProfitSplit`
containing the creator address plus creator, authenticated-swap-recipient, and trigger-pool basis
points. Those three fields must total 8,000 bps. The current source default is 4,000 / 2,000 /
2,000, but a reviewed V6.1 market may choose another conserving split at configuration time.

| Beneficiary | Share |
| --- | ---: |
| Launch-token creator, or authorized attacher for an existing-token pool | Configurable; default 40% |
| Authenticated triggering swap recipient | Configurable; default 20% |
| PoolId-scoped LP escrow (not distributed) | Configurable; default 20% |
| Proposed WTH service recipient (identity and address unverified) | Fixed 10% |
| Hookr | Fixed 10% plus any explicitly accepted rounding residual |

The current source reserves the LP allocation in pool-scoped adapter escrow. It does **not** yet
prove distribution to eligible LP positions. A reviewed distributor that binds the exact trigger
PoolKey, plus receipt and balance readback, remains a release blocker.
No LP receives or can claim this escrow today.

## Hook-block compatibility

| Hookr block | Reviewed V6.1 source composition |
| --- | --- |
| Anti-Snipe | **Conditional** — while the opening guard is active, outer-buy Arb corrections can operate; outer-sell corrections require an exact-output target buy and fail open until the guard ends |
| Surge Fees | Compatible |
| Auto Burn | Compatible |
| Nth-buy Pot | Compatible |
| LP Rewards | **Excluded** — JIT donation capture conflicts with the first Arb design |

“Offering Arb Recapture across Hookr profiles” therefore means an optional, exact-profile V6.1
subordinate executor for three unconditionally compatible blocks plus conditional Anti-Snipe
support, not all five, and not every external Uniswap hook. Fail-open means the correction is
skipped so the original user swap can continue; it does not convert a guarded outer sell into an
unguarded trade.

## Pool scope

- New Hookr launches need the separately versioned V6.1 hook, router, and release manifest.
- An existing token can use a newly created V6.1 Hookr pool; its old pools remain unchanged. The
  governance-authorized attacher is the creator beneficiary for that new market at the pool's
  configured creator share.
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
- fixed signer authority, rotation, venue, PoolKeys, profit floor, volume bound, fixed 10/10
  protocol shares, and a pool-locked creator/trader/trigger-pool split summing to 8,000 bps;
- no-broadcast simulation and human review of the exact deployment packet;
- ordered deployment receipts plus runtime, immutable wiring, and source verification;
- one canary that proves successful capture and one that proves failed correction leaves the user swap intact;
- allocation readback before any result is described as captured;
- atomic market binding to the exact integration and fee-policy identities;
- verified WTH service/operator identity, exact production recipients, the minimal
  `executeArbitrage(ExecutionRequest)` ABI and profit event, rounding behavior, and policy
  acceptance;
- authenticated trader-recipient semantics accepted by WTH. `tx.origin` is prohibited because a
  relayer, Universal Router filler, or smart-account bundler can be the transaction origin; the
  rebate recipient must be bound to Hookr's authenticated payer/recipient envelope or the trader
  share must remain disabled or escrowed;
- a reviewed PoolId-bound LP distributor plus receipt and balance proof of delivery;
- promoted V6.1 and route-service manifests before any signer or transaction API is exposed.

The public `@hookr/sdk` release candidate remains V5-only. WTH/V6.1 transaction methods stay absent
until the promoted V6.1 manifest, runtime wiring, signer authority, LP distributor, and canary
readback all exist.

Use the `executor_adapter` track for a route service or executor, `hook_token_launch` for a new token,
and `existing_token_pool` for a new market around an existing token.
