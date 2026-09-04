import { encodeFunctionData, getAddress, type Address, type Hex } from "viem";
import { erc20ApprovalAbi, hookrSwapRouterAbi } from "./abi.js";
import { HOOKR_CHAIN_ID, ZERO_ADDRESS } from "./chain.js";
import type { HookrQuote } from "./hooks.js";
import { HOOKR_V5_RELEASE } from "./release.js";

export type HookrPoolKey = Readonly<{
  currency0: Address;
  currency1: Address;
  fee: number;
  tickSpacing: number;
  hooks: Address;
}>;

export type SwapSide = "buy" | "sell";

export type ApprovalRequirement = Readonly<{
  token: Address;
  spender: Address;
  amount: bigint;
}>;

export const DYNAMIC_FEE_FLAG = 0x80_00_00;
export const HOOKR_TICK_SPACING = 60;
export const MIN_SQRT_PRICE_LIMIT_X96 = 4_295_128_740n;
export const MAX_SQRT_PRICE_LIMIT_X96 = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341n;
const MAX_UINT128 = (1n << 128n) - 1n;

export function createHookrPoolKey(token: Address, quote: HookrQuote): HookrPoolKey {
  const normalizedToken = getAddress(token);
  if (normalizedToken === ZERO_ADDRESS) throw new Error("Pool token cannot be the zero address.");
  const currency0: Address =
    quote === "eth" ? ZERO_ADDRESS : HOOKR_V5_RELEASE.contracts.quoteToken.address;
  if (normalizedToken.toLowerCase() === currency0.toLowerCase()) {
    throw new Error("Pool token and quote token must be different.");
  }
  return Object.freeze({
    currency0,
    currency1: normalizedToken,
    fee: DYNAMIC_FEE_FLAG,
    tickSpacing: HOOKR_TICK_SPACING,
    hooks: HOOKR_V5_RELEASE.contracts.hook.address,
  });
}

function positiveUint128(value: bigint, label: string): void {
  if (value <= 0n || value > MAX_UINT128) throw new Error(`${label} must be a positive uint128.`);
}

function validDeadline(deadline: bigint): void {
  if (deadline <= 0n) throw new Error("Swap deadline must be a positive Unix timestamp.");
}

function swapSettlement(
  key: HookrPoolKey,
  side: SwapSide,
  amountMaximum: bigint,
): { value: bigint; approval: ApprovalRequirement | null } {
  const nativeInput = side === "buy" && key.currency0 === ZERO_ADDRESS;
  if (nativeInput) return { value: amountMaximum, approval: null };
  const token = side === "buy" ? key.currency0 : key.currency1;
  return {
    value: 0n,
    approval: {
      token,
      spender: HOOKR_V5_RELEASE.contracts.router.address,
      amount: amountMaximum,
    },
  };
}

export function prepareExactInputSwap(input: Readonly<{
  token: Address;
  quote: HookrQuote;
  side: SwapSide;
  amountIn: bigint;
  amountOutMinimum: bigint;
  recipient: Address;
  deadline: bigint;
  sqrtPriceLimitX96?: bigint;
}>) {
  positiveUint128(input.amountIn, "amountIn");
  positiveUint128(input.amountOutMinimum, "amountOutMinimum");
  validDeadline(input.deadline);
  const recipient = getAddress(input.recipient);
  if (recipient === ZERO_ADDRESS) throw new Error("Swap recipient cannot be the zero address.");
  const key = createHookrPoolKey(input.token, input.quote);
  const zeroForOne = input.side === "buy";
  const sqrtPriceLimitX96 =
    input.sqrtPriceLimitX96 ??
    (zeroForOne ? MIN_SQRT_PRICE_LIMIT_X96 : MAX_SQRT_PRICE_LIMIT_X96);
  if (sqrtPriceLimitX96 <= 0n) throw new Error("sqrtPriceLimitX96 must be nonzero.");
  const params = {
    key,
    zeroForOne,
    amountIn: input.amountIn,
    amountOutMinimum: input.amountOutMinimum,
    sqrtPriceLimitX96,
    recipient,
    deadline: input.deadline,
  } as const;
  const args = [params] as const;
  const settlement = swapSettlement(key, input.side, input.amountIn);
  const address = HOOKR_V5_RELEASE.contracts.router.address;
  return Object.freeze({
    schemaVersion: "hookr.prepared-swap.v1" as const,
    chainId: HOOKR_CHAIN_ID,
    kind: "exact-input" as const,
    side: input.side,
    quote: input.quote,
    address,
    value: settlement.value,
    approval: settlement.approval,
    warnings: [] as readonly string[],
    data: encodeFunctionData({ abi: hookrSwapRouterAbi, functionName: "exactInput", args }),
    request: {
      address,
      abi: hookrSwapRouterAbi,
      functionName: "exactInput" as const,
      args,
      value: settlement.value,
    },
  });
}

export function prepareExactOutputSwap(input: Readonly<{
  token: Address;
  quote: HookrQuote;
  side: SwapSide;
  amountOut: bigint;
  amountInMaximum: bigint;
  recipient: Address;
  deadline: bigint;
  sqrtPriceLimitX96?: bigint;
}>) {
  positiveUint128(input.amountOut, "amountOut");
  positiveUint128(input.amountInMaximum, "amountInMaximum");
  validDeadline(input.deadline);
  const recipient = getAddress(input.recipient);
  if (recipient === ZERO_ADDRESS) throw new Error("Swap recipient cannot be the zero address.");
  const key = createHookrPoolKey(input.token, input.quote);
  const zeroForOne = input.side === "buy";
  const sqrtPriceLimitX96 =
    input.sqrtPriceLimitX96 ??
    (zeroForOne ? MIN_SQRT_PRICE_LIMIT_X96 : MAX_SQRT_PRICE_LIMIT_X96);
  if (sqrtPriceLimitX96 <= 0n) throw new Error("sqrtPriceLimitX96 must be nonzero.");
  const params = {
    key,
    zeroForOne,
    amountOut: input.amountOut,
    amountInMaximum: input.amountInMaximum,
    sqrtPriceLimitX96,
    recipient,
    deadline: input.deadline,
  } as const;
  const args = [params] as const;
  const settlement = swapSettlement(key, input.side, input.amountInMaximum);
  const address = HOOKR_V5_RELEASE.contracts.router.address;
  const warnings = input.side === "buy"
    ? ["Exact-output buys are blocked while a pool's Anti-Snipe guard is active."]
    : [];
  return Object.freeze({
    schemaVersion: "hookr.prepared-swap.v1" as const,
    chainId: HOOKR_CHAIN_ID,
    kind: "exact-output" as const,
    side: input.side,
    quote: input.quote,
    address,
    value: settlement.value,
    approval: settlement.approval,
    warnings,
    data: encodeFunctionData({ abi: hookrSwapRouterAbi, functionName: "exactOutput", args }),
    request: {
      address,
      abi: hookrSwapRouterAbi,
      functionName: "exactOutput" as const,
      args,
      value: settlement.value,
    },
  });
}

export function prepareApproval(requirement: ApprovalRequirement): Readonly<{
  chainId: typeof HOOKR_CHAIN_ID;
  address: Address;
  data: Hex;
  request: Readonly<{
    address: Address;
    abi: typeof erc20ApprovalAbi;
    functionName: "approve";
    args: readonly [Address, bigint];
  }>;
}> {
  const token = getAddress(requirement.token);
  const spender = getAddress(requirement.spender);
  positiveUint128(requirement.amount, "approval amount");
  const args = [spender, requirement.amount] as const;
  return Object.freeze({
    chainId: HOOKR_CHAIN_ID,
    address: token,
    data: encodeFunctionData({ abi: erc20ApprovalAbi, functionName: "approve", args }),
    request: { address: token, abi: erc20ApprovalAbi, functionName: "approve" as const, args },
  });
}
