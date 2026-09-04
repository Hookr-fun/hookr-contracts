# Hookr integrations

This directory is the public, versioned developer contract for integrating with Hookr.

- [`partners/`](partners/README.md) defines six technical outcome tracks and public brief schemas.
- [`hooks/`](hooks/README.md) defines the external-hook manifest and Uniswap submission boundary.
  Schema V2 adds instance provenance, callback semantics, route-quadrant evidence, exact router
  identity, final-amount evidence, and non-authoritative scanner assessments. Schema V1 remains a
  frozen compatibility record.
- [`capabilities/current.v2.json`](capabilities/current.v2.json) states what is live, review-only,
  or blocked on a new release. Its `v6IntegrationModel` records the one-root-per-`PoolKey` checkout
  grammar, the native, subordinate-executor, exclusive-external, existing-token, and launchpad
  paths, and the exact caller/creator/beneficiary launch binding and versioned fee-policy boundary.
  [`current.v1.json`](capabilities/current.v1.json) and
  [`schema.v1.json`](capabilities/schema.v1.json) are frozen evidence for the superseded WTH-v1
  fixed-share interface; consumers must not treat them as the V6.1 candidate ABI.
- [`ARB_RECAPTURE.md`](ARB_RECAPTURE.md) explains the inactive WTH-labeled V6.1 source profile,
  including its conditional Anti-Snipe guard behavior, without presenting it as a verified
  service, deployed protection, or LP distribution.
- [`../packages/sdk/`](../packages/sdk/README.md) contains the `@hookr/sdk` release candidate.

Public files exclude names, emails, credentials, private chat, signatures, unpublished addresses,
and confidential launch material. Use the private form at
[`hookr.fun/integrate/hooks`](https://hookr.fun/integrate/hooks#private-brief) for private context.

## Evidence boundary

Source, tests, deployment, transaction receipt, runtime verification, registry submission, and
routing support are separate states. A manifest may advance only when its own evidence exists.
Nothing in this directory authorizes a wallet action, deployment, npm publication, Uniswap
submission, or partner announcement.

The public SDK remains generation 5. The V6.1 capability record is source-review metadata only,
is not production, and exposes no V6 or V6.1 transaction API. WTH-v2 fixes Hookr and WTH at 10%
each and lets a pool lock the remaining creator/trader/trigger-pool 80% (default 40%/20%/20), but
recipient authentication, service ABI acceptance, rounding, routing, deployment, and LP delivery
remain release blockers. `tx.origin` is not an accepted authenticated-recipient mechanism.
The clean candidate source is pinned at `5168888ed69cc738492368203197ee72a009a964`; that SHA is
neither a deployment identity nor a production manifest.
