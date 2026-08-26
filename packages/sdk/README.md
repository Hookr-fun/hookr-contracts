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

Arb Recapture is described by capability metadata only. The reviewed V6 design has no production
deployment or route-signing manifest, so this SDK intentionally exposes no Arb transaction or
signature API.

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
