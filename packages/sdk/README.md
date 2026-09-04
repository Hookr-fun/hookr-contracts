# @hookr/sdk

Typed integration helpers for Hookr generation 5 on Robinhood Chain.

The release candidate covers the public partner boundary:

- compose and validate the five live Hookr blocks;
- prepare replay-safe instant and bonded launch transactions;
- prepare blueprint publication and bounded router swaps;
- carry stable lifecycle and idempotency fields into partner callbacks;
- reconcile a launch from `launchedByIntent` after its receipt;
- verify current runtime hashes, contract identities, and immutable wiring.

## Release status

`0.1.0-rc.1` is a source and package candidate. It is not evidence that the npm package has been
published. The public V5 source is synchronized in this release candidate; merge review, npm
authority, provenance publication, registry readback, and an exact-version consumer smoke remain
separate gates before this candidate can become stable.

Arb Recapture is described by
[`integration-capabilities.v2`](../../integrations/capabilities/current.v2.json) metadata only.
“WTH” is a source profile label, not proof of a verified service or partnership:
service/operator identity, production recipient, external ABI acceptance, rounding semantics, and
an LP distributor are all absent or unverified. The optional profile belongs to a separately
versioned V6.1 source candidate, is inactive, and has no production deployment or route-signing
manifest. This SDK therefore exposes no Arb, V6, or V6.1 transaction or signature API. The frozen
V1 capability record remains historical evidence for the superseded fixed-share V6/WTH-v1
interface; it is not the current candidate contract.

The V6.1 metadata pins clean source checkpoint
`5168888ed69cc738492368203197ee72a009a964`, without treating it as merged, deployed, promoted, or
available through this package.

The capability record also keeps the accounting boundaries explicit. Hookr and WTH each receive a
fixed 10% of gross realized quote profit. A pool must lock creator, authenticated swap recipient,
and trigger-pool shares that total the remaining 80%; the source default is 40%/20%/20%. The
authenticated recipient cannot be inferred from `tx.origin`: until WTH accepts an envelope-bound
recipient or a disabled/escrowed alternative, that external semantic remains blocked. The default
20% trigger-pool amount is PoolId-scoped adapter escrow, not distributed or claimable by LPs.

Existing-token admission checks only 18 decimals and the exact balance delta during the initial
factory pull; later mutable tax, rebase, pause/freeze, blacklist, callback/reentrancy, or code
behavior is unsupported. Anti-Snipe compatibility is conditional: while its opening guard is
active, outer-buy Arb corrections can operate, but outer-sell corrections require an exact-output
target buy and fail open until the guard ends.

Routing support is also route-specific. The Hookr router is required for authenticated, gated,
Nth-buy Pot, and WTH paths. Candidate source supports generic empty-data ungated exact-input buys
and exact-input exits; gated buys and pot-qualifying buys are unsupported, and exact-output exits
remain conditional and unverified. A quote is executable evidence only when its caller-supplied
simulation actor is bound to the active wallet. Robinhood Universal Router addresses conflict
across official sources and no exact fork matrix is complete. A Blockaid warning and one successful
V5 sell prove neither V6.1 sellability nor scanner clearance.

Its `v6IntegrationModel` is architecture metadata, not executable SDK support. It fixes one root
hook profile per `PoolKey`; separates reviewed native blocks, an optional exact-profile subordinate
executor, and an exclusive external root; requires existing-token integrations to create a new
pool; and requires launchpad adapters to atomically bind profile, config, caller, creator,
beneficiary, funding, deadline, and nonce. Existing deployed hooks cannot be inserted as native
blocks, and monetization requires an explicit versioned `feePolicyHash` plus recipient accounting.
No V6 or V6.1 transaction entrypoint is exported.

## Install

After the package is published:

```bash
npm install @hookr/sdk viem
```

## Prepare one launch

```ts
import { createPublicClient, http } from "viem";
import {
  composeHookParams,
  createLaunchIntent,
  prepareInstantLaunch,
  readLaunchConfiguration,
  reconcileLaunchIntent,
  robinhoodChain,
} from "@hookr/sdk";

const publicClient = createPublicClient({
  chain: robinhoodChain,
  transport: http(),
});

const creator = "0x1111111111111111111111111111111111111111";
const config = await readLaunchConfiguration(publicClient);
const intent = createLaunchIntent({ creator, lane: "instant" });
const custom = composeHookParams({
  antiSnipe: { guardBlocks: 100, maxBuyBps: 50, snipeTaxPips: 40_000 },
  surgeFees: { baseFeePips: 3_000, maxFeePips: 30_000, sensitivity: 5 },
});

const prepared = prepareInstantLaunch({
  quote: "eth",
  intent,
  creationFeeWei: config.creationFeeWei,
  args: {
    name: "Example Market",
    symbol: "EXAMPLE",
    tagline: "A partner-created programmable market.",
    logoURI: "https://example.com/token.png",
    expectedCreator: creator,
    blueprintId: 0,
    custom,
    creatorFeeBps: 5_000,
    feeRecipients: [],
  },
});

// 1. Simulate `prepared.request` with the exact creator account.
// 2. Show the same `termsHash`, calldata, value, recipient splits, and intent to the user.
// 3. Ask the user's wallet to sign that simulated request.
// 4. Wait for the canonical receipt.
// 5. Reconcile the intent from chain; never infer success from wallet submission alone.
const readback = await reconcileLaunchIntent(publicClient, intent);
```

`prepared.termsHash` binds calldata and value. Use it as the preview/execution equality key in a
partner adapter. `prepared.idempotencyKey` is stable for the release, creator, and intent pair.

## Send a bounded swap

```ts
import { prepareExactInputSwap } from "@hookr/sdk/router";

const swap = prepareExactInputSwap({
  token: "0x2222222222222222222222222222222222222222",
  quote: "eth",
  side: "buy",
  amountIn: 10_000_000_000_000_000n,
  amountOutMinimum: 1n,
  recipient: "0x1111111111111111111111111111111111111111",
  deadline: BigInt(Math.floor(Date.now() / 1_000) + 300),
});

// Simulate `swap.request`, then ask the wallet to sign it. A token input exposes an explicit
// `swap.approval` requirement; native input exposes the exact `swap.value`.
```

Never ship a production trade with a placeholder `amountOutMinimum`, `amountInMaximum`, recipient,
or deadline. The SDK checks that a bound exists; the integrating product owns the quote and
slippage policy that produces it.

## Verify the promoted release

```ts
import { verifyHookrRelease } from "@hookr/sdk/verification";

const report = await verifyHookrRelease(publicClient);
if (!report.ok) throw new Error(JSON.stringify(report.issues));
```

This is a current runtime and wiring check. It does not replace transaction receipts, source
verification, an audit, or a postcondition readback for a specific write.

## Partner lifecycle

The SDK separates these states on purpose:

1. `prepared` — exact calldata, value, intent, and terms hash exist;
2. `simulated` — the intended account simulated the exact request;
3. `submitted` — a wallet returned a transaction hash;
4. `confirmed` — a canonical success receipt exists;
5. `reconciled` — `launchedByIntent` and `getLaunch` match the intended creator and token;
6. `failed` — a simulation, receipt, or readback failed.

Use `createLaunchLifecycleEvent` to project those states into a partner callback or database. The
SDK returns data; it never calls a partner URL, signs, broadcasts, or retries a transaction itself.
