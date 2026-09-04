export type HookrQuote = "eth" | "hookr";
export type HookrLaunchLane = "instant" | "bonded";

export type HookParams = Readonly<{
  guardBlocks: number;
  maxBuyBps: number;
  snipeTaxPips: number;
  baseFeePips: number;
  maxFeePips: number;
  surgeSens: number;
  burnBps: number;
  burnTriggerWei: bigint;
  lpBps: number;
  potBps: number;
  potEveryNBuys: number;
  potMinBuyWei: bigint;
}>;

export type HookComposition = Readonly<{
  baseFeePips?: number;
  antiSnipe?: Readonly<{
    guardBlocks: number;
    maxBuyBps: number;
    snipeTaxPips: number;
  }>;
  surgeFees?: Readonly<{
    baseFeePips: number;
    maxFeePips: number;
    sensitivity: number;
  }>;
  autoBurn?: Readonly<{ burnBps: number }>;
  lpRewards?: Readonly<{ lpBps: number }>;
  nthBuyPot?: Readonly<{
    potBps: number;
    everyNBuys: number;
    minimumBuyWei: bigint;
  }>;
}>;

export type HookValidationContext = Readonly<{
  quote?: HookrQuote;
  lane?: HookrLaunchLane;
  arbRecapture?: boolean;
}>;

export type HookValidationIssue = Readonly<{
  code: string;
  path: keyof HookParams | "composition";
  message: string;
}>;

export const DEFAULT_BASE_FEE_PIPS = 3_000;
export const MAX_TOTAL_FEE_PIPS = 500_000;
export const MAX_NATIVE_CUT_BPS = 1_000;
export const MIN_POT_BUY_WEI = 1_000_000_000_000_000n;

export const ZERO_HOOK_PARAMS: HookParams = Object.freeze({
  guardBlocks: 0,
  maxBuyBps: 0,
  snipeTaxPips: 0,
  baseFeePips: DEFAULT_BASE_FEE_PIPS,
  maxFeePips: DEFAULT_BASE_FEE_PIPS,
  surgeSens: 0,
  burnBps: 0,
  burnTriggerWei: 0n,
  lpBps: 0,
  potBps: 0,
  potEveryNBuys: 0,
  potMinBuyWei: 0n,
});

/** Compose the five live V5 hook blocks into the exact onchain tuple. */
export function composeHookParams(composition: HookComposition = {}): HookParams {
  const baseFeePips =
    composition.surgeFees?.baseFeePips ?? composition.baseFeePips ?? DEFAULT_BASE_FEE_PIPS;
  const params: HookParams = {
    guardBlocks: composition.antiSnipe?.guardBlocks ?? 0,
    maxBuyBps: composition.antiSnipe?.maxBuyBps ?? 0,
    snipeTaxPips: composition.antiSnipe?.snipeTaxPips ?? 0,
    baseFeePips,
    maxFeePips: composition.surgeFees?.maxFeePips ?? baseFeePips,
    surgeSens: composition.surgeFees?.sensitivity ?? 0,
    burnBps: composition.autoBurn?.burnBps ?? 0,
    burnTriggerWei: 0n,
    lpBps: composition.lpRewards?.lpBps ?? 0,
    potBps: composition.nthBuyPot?.potBps ?? 0,
    potEveryNBuys: composition.nthBuyPot?.everyNBuys ?? 0,
    potMinBuyWei: composition.nthBuyPot?.minimumBuyWei ?? 0n,
  };
  assertValidHookParams(params);
  return Object.freeze(params);
}

function integerIssue(
  issues: HookValidationIssue[],
  path: keyof HookParams,
  value: number,
): void {
  if (!Number.isSafeInteger(value) || value < 0) {
    issues.push({ code: "INVALID_UNSIGNED_INTEGER", path, message: `${path} must be a non-negative safe integer.` });
  }
}

/** Mirrors `HookrLaunchpadLibV5.validateHookParams`, then applies lane-specific V5 boundaries. */
export function validateHookParams(
  params: HookParams,
  context: HookValidationContext = {},
): readonly HookValidationIssue[] {
  const issues: HookValidationIssue[] = [];
  const numericKeys = [
    "guardBlocks",
    "maxBuyBps",
    "snipeTaxPips",
    "baseFeePips",
    "maxFeePips",
    "surgeSens",
    "burnBps",
    "lpBps",
    "potBps",
    "potEveryNBuys",
  ] as const;
  for (const key of numericKeys) integerIssue(issues, key, params[key]);
  if (params.burnTriggerWei < 0n) {
    issues.push({ code: "INVALID_UNSIGNED_INTEGER", path: "burnTriggerWei", message: "burnTriggerWei cannot be negative." });
  }
  if (params.potMinBuyWei < 0n) {
    issues.push({ code: "INVALID_UNSIGNED_INTEGER", path: "potMinBuyWei", message: "potMinBuyWei cannot be negative." });
  }

  const effectiveMaxFee = params.maxFeePips === 0 ? params.baseFeePips : params.maxFeePips;
  if (
    params.baseFeePips > MAX_TOTAL_FEE_PIPS ||
    effectiveMaxFee > MAX_TOTAL_FEE_PIPS ||
    effectiveMaxFee < params.baseFeePips
  ) {
    issues.push({ code: "FEE_RANGE", path: "maxFeePips", message: "Base and maximum fees must be ordered and at most 500,000 pips." });
  }
  if (params.baseFeePips + params.snipeTaxPips > MAX_TOTAL_FEE_PIPS) {
    issues.push({ code: "SNIPE_FEE_RANGE", path: "snipeTaxPips", message: "Base fee plus Anti-Snipe fee cannot exceed 500,000 pips." });
  }
  if (params.burnBps + params.lpBps + params.potBps > MAX_NATIVE_CUT_BPS) {
    issues.push({ code: "NATIVE_CUT_RANGE", path: "composition", message: "Auto Burn, LP Rewards, and Nth-buy Pot cuts cannot exceed 1,000 bps in total." });
  }
  if (params.burnTriggerWei !== 0n) {
    issues.push({ code: "LEGACY_BURN_TRIGGER", path: "burnTriggerWei", message: "burnTriggerWei is a retired ABI field and must be zero." });
  }
  if (
    params.potBps > 0 &&
    (params.potEveryNBuys < 2 || params.potEveryNBuys > 100_000)
  ) {
    issues.push({ code: "POT_INTERVAL", path: "potEveryNBuys", message: "An enabled Nth-buy Pot must pay between every 2 and 100,000 qualifying buys." });
  }
  if (params.potBps > 0 && params.potMinBuyWei < MIN_POT_BUY_WEI) {
    issues.push({ code: "POT_MINIMUM", path: "potMinBuyWei", message: "An enabled Nth-buy Pot requires a minimum qualifying buy of at least 0.001 ETH." });
  }
  if (params.surgeSens > 10) {
    issues.push({ code: "SURGE_SENSITIVITY", path: "surgeSens", message: "Surge sensitivity cannot exceed 10." });
  }
  if (params.guardBlocks > 100_000) {
    issues.push({ code: "GUARD_WINDOW", path: "guardBlocks", message: "The Anti-Snipe guard cannot exceed 100,000 blocks." });
  }
  if (params.maxBuyBps > 10_000) {
    issues.push({ code: "MAX_BUY", path: "maxBuyBps", message: "The guarded maximum buy cannot exceed 10,000 bps." });
  }

  if (context.quote === "hookr" && params.burnBps + params.lpBps + params.potBps !== 0) {
    issues.push({ code: "HOOKR_QUOTE_NATIVE_CUT", path: "composition", message: "HOOKR-quoted pools support Anti-Snipe and Surge Fees only; native-cut blocks must be zero." });
  }
  if (context.lane === "instant" && params.lpBps !== 0) {
    issues.push({ code: "INSTANT_LP_REWARDS", path: "lpBps", message: "V5 instant pools reject LP Rewards because they open with zero in-range liquidity." });
  }
  if (context.arbRecapture && params.lpBps !== 0) {
    issues.push({ code: "ARB_LP_REWARDS", path: "lpBps", message: "The reviewed V6 Arb Recapture design excludes LP Rewards." });
  }
  return issues;
}

export class HookrValidationError extends Error {
  readonly issues: readonly HookValidationIssue[];

  constructor(message: string, issues: readonly HookValidationIssue[]) {
    super(message);
    this.name = "HookrValidationError";
    this.issues = issues;
  }
}

export function assertValidHookParams(
  params: HookParams,
  context: HookValidationContext = {},
): void {
  const issues = validateHookParams(params, context);
  if (issues.length) throw new HookrValidationError(issues[0]?.message ?? "Invalid hook parameters.", issues);
}
