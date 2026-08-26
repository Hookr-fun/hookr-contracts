import assert from "node:assert/strict";
import test from "node:test";
import { decodeFunctionData } from "viem";
import {
  hookrSwapRouterAbi,
  prepareExactInputSwap,
  prepareExactOutputSwap,
} from "../dist/esm/index.js";

const TOKEN = "0x2222222222222222222222222222222222222222";
const USER = "0x1111111111111111111111111111111111111111";

test("binds native exact-input buys to value, recipient, minimum output, and deadline", () => {
  const prepared = prepareExactInputSwap({
    token: TOKEN,
    quote: "eth",
    side: "buy",
    amountIn: 100n,
    amountOutMinimum: 90n,
    recipient: USER,
    deadline: 1_000n,
  });
  assert.equal(prepared.value, 100n);
  assert.equal(prepared.approval, null);
  const decoded = decodeFunctionData({ abi: hookrSwapRouterAbi, data: prepared.data });
  assert.equal(decoded.functionName, "exactInput");
  assert.equal(decoded.args[0].recipient, USER);
  assert.equal(decoded.args[0].amountOutMinimum, 90n);
});

test("makes token approvals and exact-output guard behavior explicit", () => {
  const prepared = prepareExactOutputSwap({
    token: TOKEN,
    quote: "hookr",
    side: "buy",
    amountOut: 90n,
    amountInMaximum: 100n,
    recipient: USER,
    deadline: 1_000n,
  });
  assert.equal(prepared.value, 0n);
  assert.equal(prepared.approval?.amount, 100n);
  assert.match(prepared.warnings[0], /Anti-Snipe/);
});
