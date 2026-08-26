# Hookr integrations

This directory is the public, versioned developer contract for integrating with Hookr.

- [`partners/`](partners/README.md) defines six technical outcome tracks and public brief schemas.
- [`hooks/`](hooks/README.md) defines the external-hook manifest and Uniswap submission boundary.
- [`capabilities/`](capabilities/current.v1.json) states what is live, review-only, or blocked on a new release.
- [`ARB_RECAPTURE.md`](ARB_RECAPTURE.md) explains the reviewed V6 arbitrage-capture candidate without presenting it as deployed protection.
- [`../packages/sdk/`](../packages/sdk/README.md) contains the `@hookr/sdk` release candidate.

Public files exclude names, emails, credentials, private chat, signatures, unpublished addresses,
and confidential launch material. Use the private form at
[`hookr.fun/integrate/hooks`](https://hookr.fun/integrate/hooks#private-brief) for private context.

## Evidence boundary

Source, tests, deployment, transaction receipt, runtime verification, registry submission, and
routing support are separate states. A manifest may advance only when its own evidence exists.
Nothing in this directory authorizes a wallet action, deployment, npm publication, Uniswap
submission, or partner announcement.
