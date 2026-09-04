import assert from "node:assert/strict";
import test from "node:test";
import { decodeFunctionData } from "viem";
import {
  composeHookParams,
  createLaunchIntent,
  hookrLaunchpadV5Abi,
  prepareInstantLaunch,
  validateFeeRecipients,
} from "../dist/esm/index.js";

const CREATOR = "0x1111111111111111111111111111111111111111";

test("prepares one replay-safe launch packet with an execution terms hash", () => {
  const intent = createLaunchIntent({
    creator: CREATOR,
    lane: "instant",
    randomBytes: new Uint8Array(32).fill(7),
  });
  const prepared = prepareInstantLaunch({
    quote: "eth",
    intent,
    creationFeeWei: 200_000_000_000_000n,
    args: {
      name: "SDK Market",
      symbol: "SDK",
      tagline: "Prepared once.",
      logoURI: "https://example.com/sdk.png",
      expectedCreator: CREATOR,
      blueprintId: 0,
      custom: composeHookParams({
        antiSnipe: { guardBlocks: 100, maxBuyBps: 50, snipeTaxPips: 40_000 },
      }),
      creatorFeeBps: 5_000,
      feeRecipients: [],
    },
  });
  assert.equal(prepared.value, 200_000_000_000_000n);
  assert.match(prepared.idempotencyKey, new RegExp(intent.id, "i"));
  assert.equal(prepared.termsHash.length, 66);
  assert.equal(
    decodeFunctionData({ abi: hookrLaunchpadV5Abi, data: prepared.data }).functionName,
    "launchInstant",
  );
});

test("rejects ambiguous fee splits", () => {
  const issues = validateFeeRecipients(5_000, [
    { to: CREATOR, bps: 6_000 },
    { to: "0x2222222222222222222222222222222222222222", bps: 3_000 },
  ]);
  assert.equal(issues.at(-1)?.code, "FEE_RECIPIENT_SUM");
});

test("rejects LP Rewards in a V5 instant launch", () => {
  const intent = createLaunchIntent({
    creator: CREATOR,
    lane: "instant",
    randomBytes: new Uint8Array(32).fill(8),
  });
  assert.throws(
    () =>
      prepareInstantLaunch({
        quote: "eth",
        intent,
        creationFeeWei: 1n,
        args: {
          name: "No LP",
          symbol: "NOLP",
          tagline: "",
          logoURI: "",
          expectedCreator: CREATOR,
          blueprintId: 0,
          custom: composeHookParams({ lpRewards: { lpBps: 25 } }),
          creatorFeeBps: 0,
          feeRecipients: [],
        },
      }),
    /instant pools reject LP Rewards/i,
  );
});
