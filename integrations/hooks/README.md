# Hookr external hook standard

This directory is the portable integration boundary for third-party Uniswap v4 hooks. It keeps a
hook's source identity, product compatibility, security posture, deployments, and listing evidence
in one versioned manifest without copying the third party's contracts into Hookr.

## Two integration lanes

- `composable-blueprint`: parameters and rules implemented by Hookr's deployed hook chassis.
- `standalone-hook-product`: a separately deployed hook system with its own factory, router,
  dependencies, PoolKey, and lifecycle. Looong, Luck, and Wager use this lane.

Each manifest also declares `integration.supportedTracks` from the partner standard in
`integrations/partners/`. A hook can be eligible for publication, hook-plus-token launches,
existing-token markets, launchpad adapters, generators, or executor work without claiming that any
of those integrations has already shipped.

Existing Uniswap v4 pools cannot be retrofitted with another hook because the hook address is part
of the pool's immutable `PoolKey`. A standalone integration therefore creates a new verified hook
deployment and pool; it is not an attachment to an existing Hookr pool.

## Contributor flow

1. Open the **External hook integration** GitHub issue with the repository, exact commit, contract
   paths, integration lane, and current security status. Do not post private contact details.
2. Add one JSON manifest under `manifests/` and validate it with `npm run hooks:validate`.
3. Keep the manifest `source-only` until there is a real receipt, runtime-code hash, verified source,
   PoolManager binding, initialized pool, and liquidity evidence.
4. After a supported mainnet deployment, add a deployment record and run the listing executor in
   dry-run mode. Its packet must pass every gate before external writes are enabled.
5. The executor prepares and attempts a submission in the public `Uniswap/hooklist` registry. It
   submits Uniswap Labs' routing form only when the official routing rules require manual review.

`source-only`, `production-verified`, `listing-submitted`, and `listed` are deliberately separate
states. A passing test, source manifest, Hooklist issue, or routing-form receipt is not a deployment,
an audit, a routing approval, or an endorsement.

## Automatic listing boundary

Hookr's current user launches reuse the same Hookr hook deployment. They must not submit one
Uniswap request per token. The listing executor is for a newly deployed, unique hook address only.
Future deployment workflows can call it after their receipt and readback gates:

```sh
npm run hooks:submit:uniswap -- \
  --manifest integrations/hooks/manifests/<slug>.json \
  --deployment <deployment-id>
```

That command is dry-run by default. Execution additionally requires an explicit external-write
acknowledgement, a private contact-and-consent file, a GitHub token, and a durable GitHub issue
ledger. The contact file is read at runtime, never committed or printed, and never written to the
receipt. The executor fails closed if Uniswap's live form definition differs from the pinned policy.
The reusable `.github/workflows/uniswap-hook-submission.yml` workflow exposes the same executor via
`workflow_call`, so a future unique-hook deployment workflow can invoke it only after its own
production verification job succeeds. The companion `uniswap-hook-autosubmit.yml` workflow detects
a newly promoted production deployment on `main` and calls that executor automatically. Source-only,
testnet-only, previously seen, and fully resolved hook addresses are excluded from its matrix.

Repository automation needs `HOOKR_UNISWAP_GITHUB_TOKEN` with permission to inspect and attempt the
public Hooklist issue. Hooks that trigger manual routing review also need the private
`HOOKR_UNISWAP_CONTACT_JSON` Actions secret. Its `legalConsent` values must match the pinned policy,
represent the named person's current consent, and use an `acceptedAt` timestamp from the last 30
days. Never commit that payload. A missing, stale, or changed consent/form contract stops before the
external form write.

The secret has this shape; copy every policy value from `uniswap-policy.v1.json` at consent time:

```json
{
  "firstName": "Submitting operator",
  "lastName": "Optional",
  "email": "operator@example.com",
  "telegramHandle": "@operator_handle",
  "legalConsent": {
    "consentToProcess": true,
    "communicationsConsent": true,
    "acceptedAt": "<current ISO date-time>",
    "formDefinitionUpdatedAt": "<pinned policy value>",
    "communicationTypeId": "<pinned policy value>",
    "termsUrl": "<pinned policy value>",
    "privacyUrl": "<pinned policy value>"
  }
}
```

## Uniswap destinations

- **Hooklist registry:** a GitHub issue containing chain, hook address, name, description, deployer,
  and audit URL. Registry inclusion does not change Uniswap routing. Uniswap's current automation
  starts when its repository applies the `submission` label; Hookr records whether that label was
  actually present and never treats an unlabeled issue as processed. As observed on 2026-08-25,
  public issue creation is restricted; without an authorized account, the executor records that
  boundary while continuing the separate routing decision.
- **Uniswap Labs routing:** no form is needed for most hooks. Manual review is required when the
  address starts with `0x91`, a return-delta flag is enabled, or dynamic fees are used. The form also
  requires an initialized pool with liquidity, verified source, contact details, and legal consent.

Policy inputs are pinned in `uniswap-policy.v1.json`. Refresh and review that file when Uniswap's
Hooklist schema, supported chains, routing guidance, or HubSpot form definition changes.

## Deployment evidence

A production deployment record includes:

- supported mainnet chain and exact hook, deployer, and PoolManager addresses;
- deployment transaction, block, runtime bytecode hash, and block-pinned observation;
- verified explorer source explicitly tied to the pinned source commit;
- at least one pool identifier with initialization receipt and block, later liquidity receipt and
  block, a post-liquidity observation, and an independent evidence URL;
- explicit eligibility attestations for protocol fees, ordinary-router compatibility, and known
  malicious or extractive behavior; and
- distinct Hooklist and routing statuses with receipt URLs when they exist.

The schema is intentionally stricter than the UI. Integrators can consume the read-only catalog at
`/api/hooks/integrations` without receiving private contact or consent data.
