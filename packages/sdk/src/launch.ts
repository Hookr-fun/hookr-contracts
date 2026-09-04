import {
  encodeFunctionData,
  encodePacked,
  getAddress,
  isAddressEqual,
  keccak256,
  stringToHex,
  toHex,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import { hookrLaunchpadV5Abi } from "./abi.js";
import { HOOKR_CHAIN_ID, ZERO_ADDRESS } from "./chain.js";
import {
  assertValidHookParams,
  validateHookParams,
  type HookParams,
  type HookrLaunchLane,
  type HookrQuote,
  type HookValidationIssue,
} from "./hooks.js";
import { HOOKR_V5_RELEASE } from "./release.js";

export type FeeRecipient = Readonly<{ to: Address; bps: number }>;

export type LaunchArgs = Readonly<{
  name: string;
  symbol: string;
  tagline: string;
  logoURI: string;
  expectedCreator: Address;
  blueprintId: number;
  custom: HookParams;
  creatorFeeBps: number;
  feeRecipients: readonly FeeRecipient[];
}>;

export type LaunchIntent = Readonly<{
  id: Hex;
  creator: Address;
  launchpad: Address;
  chainId: typeof HOOKR_CHAIN_ID;
  lane: HookrLaunchLane;
}>;

export type LaunchValidationIssue = Readonly<{
  code: string;
  path: string;
  message: string;
}>;

type PreparedLaunchBase = Readonly<{
  schemaVersion: "hookr.prepared-launch.v1";
  chainId: typeof HOOKR_CHAIN_ID;
  address: Address;
  lane: HookrLaunchLane;
  quote: HookrQuote;
  creator: Address;
  intentId: Hex;
  idempotencyKey: string;
  value: bigint;
  data: Hex;
  termsHash: Hex;
}>;

export type PreparedInstantLaunch = PreparedLaunchBase &
  Readonly<{
    lane: "instant";
    request: Readonly<{
      address: Address;
      abi: typeof hookrLaunchpadV5Abi;
      functionName: "launchInstant";
      args: readonly [LaunchArgs, number, Hex];
      value: bigint;
    }>;
  }>;

export type PreparedBondedLaunch = PreparedLaunchBase &
  Readonly<{
    lane: "bonded";
    request: Readonly<{
      address: Address;
      abi: typeof hookrLaunchpadV5Abi;
      functionName: "launchAuction";
      args: readonly [LaunchArgs, number, bigint, bigint, number, Hex];
      value: bigint;
    }>;
  }>;

export type PreparedLaunch = PreparedInstantLaunch | PreparedBondedLaunch;

export const MIN_FLOOR_FDV_WEI = 10_000_000_000_000_000n;
export const MAX_FLOOR_FDV_WEI = 10_000n * 10n ** 18n;
export const MIN_RAISE_FLOOR_WEI = 10_000_000_000_000_000n;
export const MAX_RAISE_FLOOR_WEI = 1_000n * 10n ** 18n;
export const MIN_HOOKR_TERM = 10_000n * 10n ** 18n;
export const MAX_HOOKR_TERM = 1_000_000_000n * 10n ** 18n;
export const MIN_RESERVE_BPS = 2_000;
export const MAX_RESERVE_BPS = 5_000;
export const MAX_CREATOR_FEE_BPS = 8_000;
export const MAX_FEE_RECIPIENTS = 4;
export const MAX_BLUEPRINT_ROYALTY_BPS = 1_000;

const ZERO_BYTES32 = `0x${"0".repeat(64)}` as Hex;
const INTENT_DOMAINS = Object.freeze({
  instant: keccak256(stringToHex("hookr.sdk.instant-launch.v1")),
  bonded: keccak256(stringToHex("hookr.sdk.bonded-launch.v1")),
});

function isBytes32(value: unknown): value is Hex {
  return typeof value === "string" && /^0x[0-9a-fA-F]{64}$/.test(value);
}

function utf8Length(value: string): number {
  return new TextEncoder().encode(value).length;
}

function quoteWire(quote: HookrQuote): number {
  return quote === "eth" ? 0 : 1;
}

export function createLaunchIntent(input: Readonly<{
  creator: Address;
  lane: HookrLaunchLane;
  randomBytes?: Uint8Array;
}>): LaunchIntent {
  const random = input.randomBytes ?? globalThis.crypto?.getRandomValues(new Uint8Array(32));
  if (!random || random.length !== 32) {
    throw new Error("A secure 32-byte launch nonce is required.");
  }
  const randomHex = toHex(random);
  if (randomHex === ZERO_BYTES32) throw new Error("The launch nonce cannot be all zeroes.");
  const creator = getAddress(input.creator);
  const launchpad = HOOKR_V5_RELEASE.contracts.launchpad.address;
  const id = keccak256(
    encodePacked(
      ["bytes32", "uint256", "address", "address", "bytes32"],
      [INTENT_DOMAINS[input.lane], BigInt(HOOKR_CHAIN_ID), launchpad, creator, randomHex],
    ),
  );
  if (id === ZERO_BYTES32) throw new Error("Could not derive a nonzero launch intent.");
  return Object.freeze({ id, creator, launchpad, chainId: HOOKR_CHAIN_ID, lane: input.lane });
}

export function validateFeeRecipients(
  creatorFeeBps: number,
  recipients: readonly FeeRecipient[],
): readonly LaunchValidationIssue[] {
  const issues: LaunchValidationIssue[] = [];
  if (!Number.isSafeInteger(creatorFeeBps) || creatorFeeBps < 0 || creatorFeeBps > MAX_CREATOR_FEE_BPS) {
    issues.push({ code: "CREATOR_FEE_RANGE", path: "creatorFeeBps", message: "Creator fee share must be an integer from 0 to 8,000 bps." });
  }
  if (recipients.length > MAX_FEE_RECIPIENTS) {
    issues.push({ code: "TOO_MANY_FEE_RECIPIENTS", path: "feeRecipients", message: "At most four fee recipients are supported." });
  }
  const seen = new Set<string>();
  let totalBps = 0;
  for (const [index, recipient] of recipients.entries()) {
    let normalized: Address | null = null;
    try {
      normalized = getAddress(recipient.to);
    } catch {
      issues.push({ code: "INVALID_FEE_RECIPIENT", path: `feeRecipients.${index}.to`, message: "Fee recipient must be a valid address." });
    }
    if (normalized === ZERO_ADDRESS) {
      issues.push({ code: "ZERO_FEE_RECIPIENT", path: `feeRecipients.${index}.to`, message: "Fee recipient cannot be the zero address." });
    }
    const key = normalized?.toLowerCase();
    if (key && seen.has(key)) {
      issues.push({ code: "DUPLICATE_FEE_RECIPIENT", path: `feeRecipients.${index}.to`, message: "Fee recipients must be unique." });
    }
    if (key) seen.add(key);
    if (!Number.isSafeInteger(recipient.bps) || recipient.bps <= 0 || recipient.bps > 10_000) {
      issues.push({ code: "FEE_RECIPIENT_BPS", path: `feeRecipients.${index}.bps`, message: "Every fee recipient needs a positive integer bps share." });
    } else {
      totalBps += recipient.bps;
    }
  }
  if (recipients.length > 0 && totalBps !== 10_000) {
    issues.push({ code: "FEE_RECIPIENT_SUM", path: "feeRecipients", message: "Fee recipient shares must sum to 10,000 bps." });
  }
  return issues;
}

function validateLaunch(
  args: LaunchArgs,
  intent: LaunchIntent,
  quote: HookrQuote,
  lane: HookrLaunchLane,
  resolvedBlueprintParams?: HookParams,
): readonly LaunchValidationIssue[] {
  const issues: LaunchValidationIssue[] = [];
  if (utf8Length(args.name) < 1 || utf8Length(args.name) > 48) {
    issues.push({ code: "NAME_LENGTH", path: "name", message: "Token name must be 1–48 UTF-8 bytes." });
  }
  if (utf8Length(args.symbol) < 1 || utf8Length(args.symbol) > 12) {
    issues.push({ code: "SYMBOL_LENGTH", path: "symbol", message: "Token symbol must be 1–12 UTF-8 bytes." });
  }
  if (utf8Length(args.tagline) > 160) {
    issues.push({ code: "TAGLINE_LENGTH", path: "tagline", message: "Tagline cannot exceed 160 UTF-8 bytes." });
  }
  if (utf8Length(args.logoURI) > 300) {
    issues.push({ code: "LOGO_URI_LENGTH", path: "logoURI", message: "Logo URI cannot exceed 300 UTF-8 bytes." });
  }
  let creator: Address | null = null;
  try {
    creator = getAddress(args.expectedCreator);
  } catch {
    issues.push({ code: "INVALID_CREATOR", path: "expectedCreator", message: "Expected creator must be a valid address." });
  }
  if (creator === ZERO_ADDRESS) {
    issues.push({ code: "ZERO_CREATOR", path: "expectedCreator", message: "Expected creator cannot be the zero address." });
  }
  if (!Number.isSafeInteger(args.blueprintId) || args.blueprintId < 0 || args.blueprintId > 0xffff_ffff) {
    issues.push({ code: "BLUEPRINT_ID", path: "blueprintId", message: "Blueprint id must fit uint32." });
  }
  if (!isBytes32(intent.id) || intent.id === ZERO_BYTES32) {
    issues.push({ code: "INVALID_INTENT", path: "intent.id", message: "Partner launches require a nonzero bytes32 intent id." });
  }
  if (intent.chainId !== HOOKR_CHAIN_ID || intent.lane !== lane) {
    issues.push({ code: "INTENT_SCOPE", path: "intent", message: "Intent lane and chain must match the prepared launch." });
  }
  if (!isAddressEqual(intent.launchpad, HOOKR_V5_RELEASE.contracts.launchpad.address)) {
    issues.push({ code: "INTENT_RELEASE", path: "intent.launchpad", message: "Intent is bound to a different launchpad release." });
  }
  if (creator && !isAddressEqual(intent.creator, creator)) {
    issues.push({ code: "INTENT_CREATOR", path: "intent.creator", message: "Intent creator must match expectedCreator." });
  }
  issues.push(...validateFeeRecipients(args.creatorFeeBps, args.feeRecipients));

  const resolved = args.blueprintId === 0 ? args.custom : resolvedBlueprintParams;
  if (!resolved) {
    issues.push({ code: "BLUEPRINT_PARAMS_REQUIRED", path: "resolvedBlueprintParams", message: "Resolve the selected blueprint before preparing a partner launch." });
  } else {
    issues.push(
      ...validateHookParams(resolved, { quote, lane }).map((issue: HookValidationIssue) => ({
        code: issue.code,
        path: `hookParams.${issue.path}`,
        message: issue.message,
      })),
    );
  }
  return issues;
}

export class HookrLaunchValidationError extends Error {
  readonly issues: readonly LaunchValidationIssue[];

  constructor(issues: readonly LaunchValidationIssue[]) {
    super(issues[0]?.message ?? "Invalid Hookr launch request.");
    this.name = "HookrLaunchValidationError";
    this.issues = issues;
  }
}

function assertLaunch(
  args: LaunchArgs,
  intent: LaunchIntent,
  quote: HookrQuote,
  lane: HookrLaunchLane,
  creationFeeWei: bigint,
  resolvedBlueprintParams?: HookParams,
): void {
  const issues = [...validateLaunch(args, intent, quote, lane, resolvedBlueprintParams)];
  if (creationFeeWei < 0n) {
    issues.push({ code: "CREATION_FEE", path: "creationFeeWei", message: "Creation fee cannot be negative." });
  }
  if (issues.length) throw new HookrLaunchValidationError(issues);
}

function preparedBase(
  lane: HookrLaunchLane,
  quote: HookrQuote,
  creator: Address,
  intentId: Hex,
  value: bigint,
  data: Hex,
): PreparedLaunchBase {
  const address = HOOKR_V5_RELEASE.contracts.launchpad.address;
  return {
    schemaVersion: "hookr.prepared-launch.v1",
    chainId: HOOKR_CHAIN_ID,
    address,
    lane,
    quote,
    creator,
    intentId,
    idempotencyKey: `${HOOKR_CHAIN_ID}:${address.toLowerCase()}:${creator.toLowerCase()}:${intentId.toLowerCase()}`,
    value,
    data,
    termsHash: keccak256(encodePacked(["bytes", "uint256"], [data, value])),
  };
}

export function prepareInstantLaunch(input: Readonly<{
  args: LaunchArgs;
  quote: HookrQuote;
  intent: LaunchIntent;
  creationFeeWei: bigint;
  resolvedBlueprintParams?: HookParams;
}>): PreparedInstantLaunch {
  assertLaunch(input.args, input.intent, input.quote, "instant", input.creationFeeWei, input.resolvedBlueprintParams);
  const args = [input.args, quoteWire(input.quote), input.intent.id] as const;
  const data = encodeFunctionData({ abi: hookrLaunchpadV5Abi, functionName: "launchInstant", args });
  const request = {
    address: HOOKR_V5_RELEASE.contracts.launchpad.address,
    abi: hookrLaunchpadV5Abi,
    functionName: "launchInstant" as const,
    args,
    value: input.creationFeeWei,
  };
  return Object.freeze({
    ...preparedBase("instant", input.quote, getAddress(input.args.expectedCreator), input.intent.id, input.creationFeeWei, data),
    lane: "instant" as const,
    request,
  });
}

export function prepareBondedLaunch(input: Readonly<{
  args: LaunchArgs;
  quote: HookrQuote;
  intent: LaunchIntent;
  creationFeeWei: bigint;
  floorFdvWei: bigint;
  raiseFloorWei: bigint;
  reserveBps: number;
  resolvedBlueprintParams?: HookParams;
}>): PreparedBondedLaunch {
  assertLaunch(input.args, input.intent, input.quote, "bonded", input.creationFeeWei, input.resolvedBlueprintParams);
  const [minimum, floorMaximum, raiseMaximum] =
    input.quote === "eth"
      ? [MIN_FLOOR_FDV_WEI, MAX_FLOOR_FDV_WEI, MAX_RAISE_FLOOR_WEI]
      : [MIN_HOOKR_TERM, MAX_HOOKR_TERM, MAX_HOOKR_TERM];
  const issues: LaunchValidationIssue[] = [];
  if (input.floorFdvWei < minimum || input.floorFdvWei > floorMaximum) {
    issues.push({ code: "FLOOR_FDV_RANGE", path: "floorFdvWei", message: "Auction floor FDV is outside the selected quote's contract range." });
  }
  const raiseMinimum = input.quote === "eth" ? MIN_RAISE_FLOOR_WEI : MIN_HOOKR_TERM;
  if (input.raiseFloorWei < raiseMinimum || input.raiseFloorWei > raiseMaximum) {
    issues.push({ code: "RAISE_FLOOR_RANGE", path: "raiseFloorWei", message: "Auction raise floor is outside the selected quote's contract range." });
  }
  if (!Number.isSafeInteger(input.reserveBps) || input.reserveBps < MIN_RESERVE_BPS || input.reserveBps > MAX_RESERVE_BPS) {
    issues.push({ code: "RESERVE_RANGE", path: "reserveBps", message: "Auction reserve must be 2,000–5,000 bps." });
  }
  if (issues.length) throw new HookrLaunchValidationError(issues);

  const args = [
    input.args,
    quoteWire(input.quote),
    input.floorFdvWei,
    input.raiseFloorWei,
    input.reserveBps,
    input.intent.id,
  ] as const;
  const data = encodeFunctionData({ abi: hookrLaunchpadV5Abi, functionName: "launchAuction", args });
  const request = {
    address: HOOKR_V5_RELEASE.contracts.launchpad.address,
    abi: hookrLaunchpadV5Abi,
    functionName: "launchAuction" as const,
    args,
    value: input.creationFeeWei,
  };
  return Object.freeze({
    ...preparedBase("bonded", input.quote, getAddress(input.args.expectedCreator), input.intent.id, input.creationFeeWei, data),
    lane: "bonded" as const,
    request,
  });
}

export function prepareBlueprint(input: Readonly<{
  name: string;
  params: HookParams;
  royaltyBps: number;
}>): Readonly<{
  chainId: typeof HOOKR_CHAIN_ID;
  address: Address;
  data: Hex;
  request: Readonly<{
    address: Address;
    abi: typeof hookrLaunchpadV5Abi;
    functionName: "saveBlueprint";
    args: readonly [string, HookParams, number];
  }>;
}> {
  if (utf8Length(input.name) < 1 || utf8Length(input.name) > 48) {
    throw new HookrLaunchValidationError([{ code: "BLUEPRINT_NAME", path: "name", message: "Blueprint name must be 1–48 UTF-8 bytes." }]);
  }
  assertValidHookParams(input.params);
  if (!Number.isSafeInteger(input.royaltyBps) || input.royaltyBps < 0 || input.royaltyBps > MAX_BLUEPRINT_ROYALTY_BPS) {
    throw new HookrLaunchValidationError([{ code: "BLUEPRINT_ROYALTY", path: "royaltyBps", message: "Blueprint royalty must be 0–1,000 bps." }]);
  }
  if (input.royaltyBps > 0 && input.params.lpBps + input.params.potBps === 0) {
    throw new HookrLaunchValidationError([{ code: "BLUEPRINT_ROYALTY_SOURCE", path: "royaltyBps", message: "A royalty needs LP Rewards or Nth-buy Pot fee flow." }]);
  }
  const args = [input.name, input.params, input.royaltyBps] as const;
  const address = HOOKR_V5_RELEASE.contracts.launchpad.address;
  return Object.freeze({
    chainId: HOOKR_CHAIN_ID,
    address,
    data: encodeFunctionData({ abi: hookrLaunchpadV5Abi, functionName: "saveBlueprint", args }),
    request: { address, abi: hookrLaunchpadV5Abi, functionName: "saveBlueprint" as const, args },
  });
}

export type LaunchLifecycleStatus = "prepared" | "simulated" | "submitted" | "confirmed" | "reconciled" | "failed";

export function createLaunchLifecycleEvent(
  prepared: PreparedLaunch,
  status: LaunchLifecycleStatus,
  details: Readonly<{ transactionHash?: Hex; token?: Address; blockNumber?: bigint; reason?: string }> = {},
) {
  return Object.freeze({
    schemaVersion: "hookr.launch-lifecycle.v1" as const,
    idempotencyKey: prepared.idempotencyKey,
    termsHash: prepared.termsHash,
    chainId: prepared.chainId,
    launchpad: prepared.address,
    creator: prepared.creator,
    intentId: prepared.intentId,
    lane: prepared.lane,
    quote: prepared.quote,
    status,
    ...details,
  });
}

export async function readLaunchConfiguration(client: PublicClient) {
  const address = HOOKR_V5_RELEASE.contracts.launchpad.address;
  const [creationFeeWei, blueprintsCount, instantOpenFdvWei, hookrInstantOpenFdv, auctionDurationBlocks, claimDelayBlocks, migrationDelayBlocks] =
    await Promise.all([
      client.readContract({ address, abi: hookrLaunchpadV5Abi, functionName: "creationFeeWei" }),
      client.readContract({ address, abi: hookrLaunchpadV5Abi, functionName: "blueprintsCount" }),
      client.readContract({ address, abi: hookrLaunchpadV5Abi, functionName: "instantOpenFdvWei" }),
      client.readContract({ address, abi: hookrLaunchpadV5Abi, functionName: "hookrInstantOpenFdv" }),
      client.readContract({ address, abi: hookrLaunchpadV5Abi, functionName: "auctionDurationBlocks" }),
      client.readContract({ address, abi: hookrLaunchpadV5Abi, functionName: "claimDelayBlocks" }),
      client.readContract({ address, abi: hookrLaunchpadV5Abi, functionName: "migrationDelayBlocks" }),
    ]);
  return Object.freeze({
    blockNumber: await client.getBlockNumber(),
    creationFeeWei,
    blueprintsCount,
    instantOpenFdvWei,
    hookrInstantOpenFdv,
    auctionDurationBlocks,
    claimDelayBlocks,
    migrationDelayBlocks,
  });
}

export async function resolveBlueprintParams(client: PublicClient, blueprintId: number): Promise<HookParams> {
  if (!Number.isSafeInteger(blueprintId) || blueprintId <= 0 || blueprintId > 0xffff_ffff) {
    throw new Error("A public blueprint id must be a positive uint32.");
  }
  const blueprint = await client.readContract({
    address: HOOKR_V5_RELEASE.contracts.launchpad.address,
    abi: hookrLaunchpadV5Abi,
    functionName: "getBlueprint",
    args: [blueprintId],
  });
  return blueprint.params;
}

export async function reconcileLaunchIntent(client: PublicClient, intent: LaunchIntent) {
  const address = HOOKR_V5_RELEASE.contracts.launchpad.address;
  const token = await client.readContract({
    address,
    abi: hookrLaunchpadV5Abi,
    functionName: "launchedByIntent",
    args: [intent.creator, intent.id],
  });
  if (token === ZERO_ADDRESS) {
    return Object.freeze({ status: "not-found" as const, token: null, launch: null });
  }
  const launch = await client.readContract({
    address,
    abi: hookrLaunchpadV5Abi,
    functionName: "getLaunch",
    args: [token],
  });
  if (!isAddressEqual(launch.creator, intent.creator) || !isAddressEqual(launch.token, token)) {
    throw new Error("Launch intent readback did not match its creator and token identity.");
  }
  return Object.freeze({ status: "reconciled" as const, token, launch });
}
