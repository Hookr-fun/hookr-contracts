# Hookr partner integration tracks

This directory is the public, contact-free handoff that sits before an external hook manifest. It
standardizes what a builder wants to do without mixing private relationship details into Git.

## Six tracks

| Track | Deliverable | Minimum technical handoff |
| --- | --- | --- |
| `hook_publication` | source issue + external-hook manifest | repository, commit, contract paths, behavior, dependencies |
| `hook_token_launch` | launch brief + external-hook manifest | hook/token source, chain, PoolKey, liquidity and authority plan |
| `existing_token_pool` | existing-token market brief | token, current pools, new hook, new PoolKey and liquidity plan |
| `launchpad_sdk` | adapter + lifecycle contract | launch API/SDK, signer boundaries, preview/receipt/failure callbacks |
| `hook_generator` | generator export + provenance packet | generator version, reproducible source, compiler/dependency/test output |
| `executor_adapter` | interface + fork-test packet | executor ABI, caller/rotation auth, every PoolKey, profit and recovery rules |

Discovery, exchange listing, distribution, and general ecosystem conversations remain partner
leads, but they do not receive a technical track until a concrete integration exists.

## Public/private boundary

- Put public source identity, immutable configuration, interfaces, and reproducible evidence in a
  brief that validates against `schema.v1.json`.
- Put names, email addresses, private chat summaries, unpublished launch details, credentials, and
  legal consent only in Hookr's private intake/partner command center.
- Link the final public technical brief from the private lead. Do not copy private conversation
  bodies into the repository.

Validate the examples and any new brief with `npm run partners:validate`. A valid technical brief
does not prove audit, deployment, launch readiness, Uniswap Hooklist inclusion, routing approval, or
partnership acceptance.

Public contributors can start with `.github/ISSUE_TEMPLATE/partner-integration.yml`; machine clients
can discover the same six definitions at `/api/integrations/tracks`. The issue is a public routing
brief, not a contact form. Builders with private context use
`/integrate/hooks#private-brief`, which stores the selected track and contact details only in the
operator-only intake and partner tables.

## Promotion into the hook registry

Tracks that produce a hook eventually add or update a manifest under `integrations/hooks/`. The
manifest owns source, runtime, PoolKey, liquidity, and Uniswap-listing evidence. The partner brief
owns intent and interface requirements. Keeping them separate prevents a promising chat or design
document from being mistaken for a verified deployment.
