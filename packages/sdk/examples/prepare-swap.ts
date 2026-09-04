import type { Address } from "viem";
import { prepareExactInputSwap } from "../src/index.js";

export function prepareBoundedBuy(token: Address, recipient: Address, nowSeconds: bigint) {
  return prepareExactInputSwap({
    token,
    quote: "eth",
    side: "buy",
    amountIn: 10_000_000_000_000_000n,
    amountOutMinimum: 1n,
    recipient,
    deadline: nowSeconds + 300n,
  });
}
