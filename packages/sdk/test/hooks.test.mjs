import assert from "node:assert/strict";
import test from "node:test";
import {
  composeHookParams,
  validateHookParams,
} from "../dist/esm/hooks.js";

test("composes the five V5 blocks into the wire tuple", () => {
  const params = composeHookParams({
    antiSnipe: { guardBlocks: 100, maxBuyBps: 50, snipeTaxPips: 40_000 },
    surgeFees: { baseFeePips: 3_000, maxFeePips: 30_000, sensitivity: 5 },
    autoBurn: { burnBps: 100 },
    lpRewards: { lpBps: 25 },
    nthBuyPot: { potBps: 50, everyNBuys: 500, minimumBuyWei: 10n ** 16n },
  });
  assert.deepEqual(params, {
    guardBlocks: 100,
    maxBuyBps: 50,
    snipeTaxPips: 40_000,
    baseFeePips: 3_000,
    maxFeePips: 30_000,
    surgeSens: 5,
    burnBps: 100,
    burnTriggerWei: 0n,
    lpBps: 25,
    potBps: 50,
    potEveryNBuys: 500,
    potMinBuyWei: 10n ** 16n,
  });
});

test("keeps the reviewed Arb Recapture incompatibility explicit", () => {
  const params = composeHookParams({ lpRewards: { lpBps: 25 } });
  assert.equal(validateHookParams(params, { arbRecapture: true })[0]?.code, "ARB_LP_REWARDS");
});

test("limits HOOKR-quoted pools to guard and fee blocks", () => {
  const params = composeHookParams({ autoBurn: { burnBps: 100 } });
  assert.equal(validateHookParams(params, { quote: "hookr" })[0]?.code, "HOOKR_QUOTE_NATIVE_CUT");
});
