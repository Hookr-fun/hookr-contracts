#!/usr/bin/env node

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync, realpathSync, writeFileSync } from "node:fs";
import { isAbsolute, relative, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";
import {
  decodeAbiParameters,
  decodeFunctionData,
  encodeAbiParameters,
  encodeFunctionData,
  keccak256,
  toBytes,
  toEventSelector,
} from "viem";

const KIND = "hookr-v5-phase-a-evidence-v3";
const POLICY =
  "four-unmodified-raw-forge-artifacts-plus-one-raw-owner-bid-and-two-raw-timing-transaction-pairs";
const ARBSYS = "0x0000000000000000000000000000000000000064";
const POOL_MANAGER = "0x8366a39cc670b4001a1121b8f6a443a643e40951";
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const CANARY_AUCTION_DURATION_BLOCKS = 20_000n;
const CANARY_GUARD_BLOCKS = 20_000;
const CANARY_CREATION_FEE_WEI = 200_000_000_000_000n;
const CANARY_BUY_WEI = 1_000_000_000_000_000n;
const CANARY_BID_WEI = 10_500_000_000_000_000n;
// The original fixed bid cap was overtaken by permissionless bids after the CCA launch finalized.
// This exact tick-aligned cap is the successful, sender-owned recovery bid mined at nonce 712.
// The bid's native outlay remains bounded independently by CANARY_BID_WEI.
const CANARY_BID_MAX_PRICE_Q96 = 814_814_390_533_794_434_497_901_791_991_308_996_217n;
const CANARY_HOOKR_BUY = 25_000n * 10n ** 18n;
const CANARY_FLOOR_FDV = 20_000_000_000_000_000n;
const CANARY_RAISE_FLOOR = 10_000_000_000_000_000n;
const CANARY_RESERVE_BPS = 2_000;
const BUY_MIN_TOKENS_OUT = 200_000n * 10n ** 18n;
const HOOKR_BUY_MIN_TOKENS_OUT = 1_000_000n * 10n ** 18n;
const DYNAMIC_FEE_FLAG = 0x800000;
const POOL_TICK_SPACING = 60;
const MIN_SQRT_PRICE_LIMIT = 4_295_128_740n;
const EXPECTED_HOOK_FLAGS = 0x28ccn;
const HOOK_PERMISSION_MASK = 0x3fffn;
const SWAP_DEADLINE_WINDOW_SECONDS = 600n;
const INSTANT_LAUNCHED_TOPIC = toEventSelector("InstantLaunched(address,bytes32,uint96)");
const AUCTION_STARTED_TOPIC = toEventSelector("AuctionStarted(address,address,uint40,uint96,uint96,uint16)");
const BID_SUBMITTED_TOPIC = "0x650baad5cd8ca09b8f580be220fa04ce2ba905a041f764b6a3fe2c848eb70540";
const INTENT_CONSUMED_TOPIC = toEventSelector("LaunchIntentConsumed(address,bytes32,address)");
const FLYWHEEL_FEE_ACCRUED_TOPIC = toEventSelector("FlywheelFeeAccrued(bytes32,uint256)");
const POOL_MANAGER_SWAP_TOPIC = toEventSelector("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
const INTENTS = Object.freeze({
  instant: keccak256(toBytes("hookr.v5.canary.instant.1")),
  auction: keccak256(toBytes("hookr.v5.canary.auction.1")),
  hookr: keccak256(toBytes("hookr.v5.canary.hookr.1")),
});
const TIMING_ABI = [{
  type: "function",
  name: "setAuctionTiming",
  stateMutability: "nonpayable",
  inputs: [
    { name: "durationBlocks", type: "uint64" },
    { name: "claimDelay", type: "uint64" },
    { name: "migrationDelay", type: "uint64" },
  ],
  outputs: [],
}];

const HOOK_PARAMS_COMPONENTS = [
  { name: "guardBlocks", type: "uint32" },
  { name: "maxBuyBps", type: "uint16" },
  { name: "snipeTaxPips", type: "uint24" },
  { name: "baseFeePips", type: "uint24" },
  { name: "maxFeePips", type: "uint24" },
  { name: "surgeSens", type: "uint16" },
  { name: "burnBps", type: "uint16" },
  { name: "burnTriggerWei", type: "uint96" },
  { name: "lpBps", type: "uint16" },
  { name: "potBps", type: "uint16" },
  { name: "potEveryNBuys", type: "uint32" },
  { name: "potMinBuyWei", type: "uint96" },
];
const LAUNCH_ARGS_COMPONENTS = [
  { name: "name", type: "string" },
  { name: "symbol", type: "string" },
  { name: "tagline", type: "string" },
  { name: "logoURI", type: "string" },
  { name: "expectedCreator", type: "address" },
  { name: "blueprintId", type: "uint32" },
  { name: "custom", type: "tuple", components: HOOK_PARAMS_COMPONENTS },
  { name: "creatorFeeBps", type: "uint16" },
  {
    name: "feeRecipients",
    type: "tuple[]",
    components: [
      { name: "to", type: "address" },
      { name: "bps", type: "uint16" },
    ],
  },
];
const LAUNCHPAD_ABI = [
  {
    type: "function",
    name: "launchInstant",
    stateMutability: "payable",
    inputs: [
      { name: "args", type: "tuple", components: LAUNCH_ARGS_COMPONENTS },
      { name: "quote", type: "uint8" },
      { name: "intentId", type: "bytes32" },
    ],
    outputs: [{ name: "token", type: "address" }],
  },
  {
    type: "function",
    name: "launchAuction",
    stateMutability: "payable",
    inputs: [
      { name: "args", type: "tuple", components: LAUNCH_ARGS_COMPONENTS },
      { name: "quote", type: "uint8" },
      { name: "floorFdvWei", type: "uint96" },
      { name: "raiseFloorWei", type: "uint96" },
      { name: "reserveBps", type: "uint16" },
      { name: "intentId", type: "bytes32" },
    ],
    outputs: [{ name: "token", type: "address" }],
  },
];
const POOL_KEY_COMPONENTS = [
  { name: "currency0", type: "address" },
  { name: "currency1", type: "address" },
  { name: "fee", type: "uint24" },
  { name: "tickSpacing", type: "int24" },
  { name: "hooks", type: "address" },
];
const ROUTER_ABI = [{
  type: "function",
  name: "exactInput",
  stateMutability: "payable",
  inputs: [{
    name: "p",
    type: "tuple",
    components: [
      { name: "key", type: "tuple", components: POOL_KEY_COMPONENTS },
      { name: "zeroForOne", type: "bool" },
      { name: "amountIn", type: "uint128" },
      { name: "amountOutMinimum", type: "uint128" },
      { name: "sqrtPriceLimitX96", type: "uint160" },
      { name: "recipient", type: "address" },
      { name: "deadline", type: "uint256" },
    ],
  }],
  outputs: [{ name: "amountOut", type: "uint256" }],
}];
const BID_ABI = [{
  type: "function",
  name: "submitBid",
  stateMutability: "payable",
  inputs: [
    { name: "maxPriceQ96", type: "uint256" },
    { name: "amount", type: "uint128" },
    { name: "owner", type: "address" },
    { name: "hookData", type: "bytes" },
  ],
  outputs: [{ name: "bidId", type: "uint256" }],
}];
const ERC20_ABI = [{
  type: "function",
  name: "approve",
  stateMutability: "nonpayable",
  inputs: [
    { name: "spender", type: "address" },
    { name: "amount", type: "uint256" },
  ],
  outputs: [{ name: "success", type: "bool" }],
}];

const ALL_FIVE = Object.freeze([
  CANARY_GUARD_BLOCKS, 1_000, 200_000, 3_000, 30_000, 5, 100, 0n, 25, 50, 2, CANARY_BUY_WEI,
]);
const INSTANT_FOUR = Object.freeze([...ALL_FIVE.slice(0, 8), 0, ...ALL_FIVE.slice(9)]);
const GUARD_TWO = Object.freeze([
  CANARY_GUARD_BLOCKS, 1_000, 200_000, 3_000, 30_000, 5, 0, 0n, 0, 0, 0, 0n,
]);

const fail = (message) => { throw new Error(message); };
const sameHex = (a, b) =>
  typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();
const address = (value, label) => {
  if (!/^0x[0-9a-fA-F]{40}$/.test(String(value ?? ""))) fail(`${label} is not an address`);
  return value.toLowerCase();
};
const hash32 = (value, label) => {
  if (!/^0x[0-9a-fA-F]{64}$/.test(String(value ?? ""))) fail(`${label} is not a bytes32 hash`);
  return value.toLowerCase();
};
const fullCommit = (value, label) => {
  if (!/^[0-9a-fA-F]{40}$/.test(String(value ?? ""))) fail(`${label} is not a full commit`);
  return value.toLowerCase();
};
const decimal = (value, label) => {
  try { return BigInt(value).toString(); }
  catch { fail(`${label} is not an integer`); }
};
const readJson = (path) => JSON.parse(readFileSync(path, "utf8"));
const sha256File = (path) => createHash("sha256").update(readFileSync(path)).digest("hex");
const repositoryRoot = realpathSync(process.cwd());
const repoRelativePath = (path) => {
  const absolute = resolve(path);
  const rel = relative(process.cwd(), absolute);
  if (!rel || rel === ".." || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
    fail(`raw evidence must be inside the repository: ${path}`);
  }
  let real;
  try { real = realpathSync(absolute); }
  catch { fail(`raw evidence path cannot be resolved: ${path}`); }
  const expectedReal = resolve(repositoryRoot, rel);
  const realRelative = relative(repositoryRoot, real);
  if (
    real !== expectedReal ||
    !realRelative ||
    realRelative === ".." ||
    realRelative.startsWith(`..${sep}`) ||
    isAbsolute(realRelative)
  ) {
    fail(`raw evidence path must not traverse a symbolic link: ${path}`);
  }
  return rel.split(sep).join("/");
};
const topicAddress = (topic, label) => {
  if (!/^0x[0-9a-fA-F]{64}$/.test(String(topic ?? ""))) fail(`${label} is not an indexed address`);
  return address(`0x${topic.slice(-40)}`, label);
};

const topicBytes32 = (topic, label) => hash32(topic, label);

const launchArgs = (name, symbol, creator, hookParams) => [
  name,
  symbol,
  "generation-5 canary",
  "",
  creator,
  0,
  hookParams,
  0,
  [],
];

const exactCalldata = (pair, abi, functionName, args, label) => {
  const expected = encodeFunctionData({ abi, functionName, args }).toLowerCase();
  if (pair.calldata.toLowerCase() !== expected) {
    fail(`${label} calldata is not the exact reviewed ${functionName} call`);
  }
};

const decodeSwap = (pair, label) => {
  try {
    const decoded = decodeFunctionData({ abi: ROUTER_ABI, data: pair.calldata });
    if (decoded.functionName !== "exactInput" || !decoded.args?.[0]) throw new Error("wrong function");
    return decoded.args[0];
  } catch {
    fail(`${label} calldata is not a decodable exactInput call`);
  }
};

const poolId = (key) => keccak256(encodeAbiParameters(
  [{ type: "tuple", components: POOL_KEY_COMPONENTS }],
  [[key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks]],
));

const assertDeadline = (deadline, receipt, label) => {
  const value = BigInt(deadline);
  if (value === 0n) fail(`${label} deadline is zero`);
  // Raw Forge receipts ordinarily omit the mined block timestamp. If an evidence collector adds
  // the canonical timestamp, enforce the script's exact `block.timestamp + 10 minutes` ceiling.
  // The lower delta may be below 600 seconds because time can advance between simulation and mine.
  if (receipt?.blockTimestamp !== undefined && receipt?.blockTimestamp !== null) {
    const mined = BigInt(receipt.blockTimestamp);
    const remaining = value - mined;
    if (remaining <= 0n || remaining > SWAP_DEADLINE_WINDOW_SECONDS) {
      fail(`${label} deadline is not within 600 seconds after its mined block timestamp`);
    }
  }
  return value;
};

const auctionConfigFromLog = (log) => {
  try {
    const [endBlock, floorFdvWei, raiseFloorWei, reserveBps] = decodeAbiParameters(
      [
        { type: "uint40" },
        { type: "uint96" },
        { type: "uint96" },
        { type: "uint16" },
      ],
      log?.data,
    );
    return {
      endBlock: BigInt(endBlock),
      floorFdvWei: BigInt(floorFdvWei),
      raiseFloorWei: BigInt(raiseFloorWei),
      reserveBps: Number(reserveBps),
    };
  } catch {
    fail("phase A AuctionStarted data is malformed");
  }
};

const matchOnlyLog = (receipt, contract, topic, label) => {
  const matches = (receipt.logs ?? []).filter(
    (log) => sameHex(log.address, contract) && sameHex(log.topics?.[0], topic),
  );
  if (matches.length !== 1) fail(`${label} emitted ${matches.length} matching events, expected one`);
  return matches[0];
};

const assertGuardedSwapReceipt = ({ pair, key, hook, router, label, flywheelWei }) => {
  const expectedPoolId = poolId(key);
  const swapLog = matchOnlyLog(pair.receipt, POOL_MANAGER, POOL_MANAGER_SWAP_TOPIC, `${label} PoolManager swap`);
  if (!sameHex(swapLog.topics?.[1], expectedPoolId) ||
      topicAddress(swapLog.topics?.[2], `${label} PoolManager sender`) !== address(router, `${label} router`)) {
    fail(`${label} PoolManager Swap pool or sender is wrong`);
  }
  let fee;
  try {
    [, , , , , fee] = decodeAbiParameters(
      [
        { type: "int128" }, { type: "int128" }, { type: "uint160" },
        { type: "uint128" }, { type: "int24" }, { type: "uint24" },
      ],
      swapLog.data,
    );
  } catch {
    fail(`${label} PoolManager Swap data is malformed`);
  }
  const feePips = BigInt(fee);
  if (feePips < 203_000n || feePips > 230_000n) {
    fail(`${label} PoolManager fee ${feePips} does not prove the guarded 20% snipe tax`);
  }

  const accruals = (pair.receipt.logs ?? []).filter((log) =>
    sameHex(log.address, hook) && sameHex(log.topics?.[0], FLYWHEEL_FEE_ACCRUED_TOPIC) &&
    sameHex(log.topics?.[1], expectedPoolId));
  if (flywheelWei === 0n) {
    if (accruals.length !== 0) fail(`${label} unexpectedly accrued a native flywheel fee`);
  } else {
    if (accruals.length !== 1) fail(`${label} emitted ${accruals.length} flywheel accruals, expected one`);
    let amount;
    try { [amount] = decodeAbiParameters([{ type: "uint256" }], accruals[0].data); }
    catch { fail(`${label} FlywheelFeeAccrued data is malformed`); }
    if (BigInt(amount) !== flywheelWei) {
      fail(`${label} flywheel accrual ${amount} is not ${flywheelWei}`);
    }
  }

  const flywheelAccrual = flywheelWei === 0n ? null : {
    transactionHash: hash32(
      accruals[0]?.transactionHash ?? pair.receipt?.transactionHash,
      `${label} FlywheelFeeAccrued transactionHash`,
    ),
    blockNumber: decimal(
      accruals[0]?.blockNumber ?? pair.receipt?.blockNumber,
      `${label} FlywheelFeeAccrued blockNumber`,
    ),
    transactionIndex: decimal(
      accruals[0]?.transactionIndex ?? pair.receipt?.transactionIndex,
      `${label} FlywheelFeeAccrued transactionIndex`,
    ),
    logIndex: decimal(accruals[0]?.logIndex, `${label} FlywheelFeeAccrued logIndex`),
    poolId: expectedPoolId.toLowerCase(),
    amountWei: flywheelWei.toString(),
  };

  return { feePips: feePips.toString(), flywheelAccrual };
};

const pairRawForgeRun = (run, label, expectedFunctions, expectedTargets, expectedValues) => {
  if (run?.chain !== 4663) fail(`${label} raw Forge artifact is not chain 4663`);
  if (!Array.isArray(run.transactions) || run.transactions.length !== expectedFunctions.length) {
    fail(`${label} raw Forge artifact has ${run?.transactions?.length ?? 0} transactions, expected ${expectedFunctions.length}`);
  }
  if (!Array.isArray(run.receipts) || run.receipts.length !== expectedFunctions.length) {
    fail(`${label} raw Forge artifact has ${run?.receipts?.length ?? 0} receipts, expected ${expectedFunctions.length}`);
  }
  if (!Array.isArray(run.pending) || run.pending.length !== 0) {
    fail(`${label} raw Forge artifact has a nonempty or missing pending set`);
  }
  const receipts = new Map();
  for (const [index, receipt] of run.receipts.entries()) {
    const txHash = hash32(receipt?.transactionHash, `${label} receipt #${index} transactionHash`);
    if (receipts.has(txHash)) fail(`${label} raw Forge artifact repeats receipt ${txHash}`);
    receipts.set(txHash, receipt);
  }
  return run.transactions.map((tx, index) => {
    if (!String(tx?.function ?? "").startsWith(expectedFunctions[index])) {
      fail(`${label} transaction #${index} is not ${expectedFunctions[index]}()`);
    }
    const txHash = hash32(tx?.hash, `${label} transaction #${index} hash`);
    const receipt = receipts.get(txHash);
    if (!receipt) fail(`${label} transaction #${index} has no hash-matched raw receipt`);
    if (decimal(receipt.status, `${label} receipt #${index} status`) !== "1") {
      fail(`${label} transaction #${index} did not succeed`);
    }
    const to = address(tx?.transaction?.to, `${label} transaction #${index} target`);
    if (!sameHex(to, expectedTargets[index])) {
      fail(`${label} transaction #${index} target ${to} is not ${expectedTargets[index]}`);
    }
    if (sameHex(to, ARBSYS)) fail(`${label} transaction #${index} targets ArbSys`);
    // Forge omits `value` entirely for zero-value calls in real broadcast JSON. Missing therefore
    // means zero; every nonzero canary call is still compared to a nonzero reviewed value below.
    const value = decimal(tx?.transaction?.value ?? 0, `${label} transaction #${index} value`);
    if (value !== expectedValues[index]) {
      fail(`${label} transaction #${index} value ${value} is not ${expectedValues[index]}`);
    }
    const calldata = String(tx?.transaction?.input ?? "");
    if (!/^0x(?:[0-9a-fA-F]{2})+$/.test(calldata)) fail(`${label} transaction #${index} calldata is malformed`);
    return { tx, receipt, txHash, to, value, calldata };
  });
};

const pairRawTiming = ({ transaction, receipt, label, sender, launchpad, duration }) => {
  const txHash = hash32(transaction?.hash, `${label} transaction hash`);
  if (decimal(transaction?.chainId, `${label} chain id`) !== "4663") {
    fail(`${label} transaction is not on chain 4663`);
  }
  if (!sameHex(receipt?.transactionHash, txHash)) fail(`${label} receipt does not match its raw transaction`);
  if (decimal(receipt?.status, `${label} receipt status`) !== "1") fail(`${label} receipt did not succeed`);
  const from = address(transaction?.from, `${label} sender`);
  const to = address(transaction?.to, `${label} target`);
  if (!sameHex(from, sender) || !sameHex(to, launchpad)) fail(`${label} sender or target is wrong`);
  if (!sameHex(receipt?.from, sender) || !sameHex(receipt?.to, launchpad)) fail(`${label} receipt sender or target is wrong`);
  const value = decimal(transaction?.value, `${label} value`);
  if (value !== "0") fail(`${label} sends nonzero value`);
  const calldata = String(transaction?.input ?? "").toLowerCase();
  const expectedCalldata = encodeFunctionData({
    abi: TIMING_ABI,
    functionName: "setAuctionTiming",
    args: [BigInt(duration), 0n, 1n],
  }).toLowerCase();
  if (calldata !== expectedCalldata) fail(`${label} calldata is not setAuctionTiming(${duration},0,1)`);
  if (!sameHex(transaction?.blockHash, receipt?.blockHash) ||
      decimal(transaction?.blockNumber, `${label} transaction block`) !== decimal(receipt?.blockNumber, `${label} receipt block`)) {
    fail(`${label} transaction and receipt canonical coordinates differ`);
  }
  return { tx: { hash: txHash, transaction }, receipt, txHash, to, value, calldata };
};

const pairRawOwnerBid = ({ transaction, receipt, sender, auction }) => {
  const label = "phase A/owner bid recovery";
  const canarySender = address(sender, `${label} expected sender`);
  const canaryAuction = address(auction, `${label} expected auction`);
  const txHash = hash32(transaction?.hash, `${label} transaction hash`);
  if (decimal(transaction?.chainId, `${label} chain id`) !== "4663") {
    fail(`${label} transaction is not on chain 4663`);
  }
  if (!sameHex(receipt?.transactionHash, txHash)) fail(`${label} receipt does not match its raw transaction`);
  if (decimal(receipt?.status, `${label} receipt status`) !== "1") fail(`${label} receipt did not succeed`);
  const from = address(transaction?.from, `${label} sender`);
  const to = address(transaction?.to, `${label} target`);
  if (!sameHex(from, canarySender) || !sameHex(to, canaryAuction)) fail(`${label} sender or target is wrong`);
  if (!sameHex(receipt?.from, canarySender) || !sameHex(receipt?.to, canaryAuction)) {
    fail(`${label} receipt sender or target is wrong`);
  }
  const value = decimal(transaction?.value, `${label} value`);
  if (value !== CANARY_BID_WEI.toString()) fail(`${label} value is not the reviewed bounded bid amount`);
  const calldata = String(transaction?.input ?? "").toLowerCase();
  const pair = { tx: { hash: txHash, transaction }, receipt, txHash, to, value, calldata };
  exactCalldata(
    pair,
    BID_ABI,
    "submitBid",
    [CANARY_BID_MAX_PRICE_Q96, CANARY_BID_WEI, canarySender, "0x"],
    label,
  );
  if (
    !sameHex(transaction?.blockHash, receipt?.blockHash) ||
    decimal(transaction?.blockNumber, `${label} transaction block`) !==
      decimal(receipt?.blockNumber, `${label} receipt block`) ||
    decimal(transaction?.transactionIndex, `${label} transaction index`) !==
      decimal(receipt?.transactionIndex, `${label} receipt index`)
  ) {
    fail(`${label} transaction and receipt canonical coordinates differ`);
  }
  const bidLog = matchOnlyLog(receipt, canaryAuction, BID_SUBMITTED_TOPIC, label);
  if (topicAddress(bidLog.topics?.[2], `${label} owner`) !== canarySender) {
    fail(`${label} BidSubmitted owner is wrong`);
  }
  let eventPrice;
  let eventAmount;
  try {
    [eventPrice, eventAmount] = decodeAbiParameters(
      [{ type: "uint256" }, { type: "uint128" }],
      bidLog.data,
    );
  } catch {
    fail(`${label} BidSubmitted data is malformed`);
  }
  if (BigInt(eventPrice) !== CANARY_BID_MAX_PRICE_Q96 || BigInt(eventAmount) !== CANARY_BID_WEI) {
    fail(`${label} BidSubmitted price or amount differs from the reviewed call`);
  }
  return { ...pair, bidId: decimal(bidLog.topics?.[1], `${label} bid id`) };
};

/** Authenticate the mined owner-bid recovery pair before any later signer boundary. */
export function assertV5PhaseAOwnerBidSemantics(context) {
  const pair = pairRawOwnerBid(context);
  if (context.bidId !== undefined && pair.bidId !== decimal(context.bidId, "expected owner bid id")) {
    fail("phase A owner bid id differs from its authenticated recovery target");
  }
  if (context.auctionEndBlock !== undefined && BigInt(pair.receipt.blockNumber) >= BigInt(context.auctionEndBlock)) {
    fail("phase A owner bid was not mined before the authenticated auction end block");
  }
  return true;
}

const rawCommit = (run, label, operatorCommit) => {
  const commit = String(run?.commit ?? "").toLowerCase();
  if (!/^[0-9a-f]{7,40}$/.test(commit) || !operatorCommit.startsWith(commit)) {
    fail(`${label} raw Forge artifact commit ${commit || "<missing>"} is not operator ${operatorCommit}`);
  }
  return commit;
};

/**
 * Authenticate one completed Phase-A Forge artifact before any later signing boundary.
 *
 * The aggregate evidence index repeats these checks after all four stages have finalized, but
 * waiting until then is too late: a complete-looking artifact with forged `function` metadata or
 * altered calldata must not authorize the next wallet prompt. This stage gate deliberately needs
 * only identities that were already finalized before the stage began.
 */
export function assertV5PhaseAStageSemantics(context) {
  const {
    stage, run, canaryOperatorCommit, sender, launchpad, router, hookrToken, hook,
    instantToken, hookrPairToken,
  } = context;
  const operatorCommit = fullCommit(canaryOperatorCommit, "canary operator commit");
  const canarySender = address(sender, "canary sender");
  const pad = address(launchpad, "launchpad");
  const swapRouter = address(router, "router");
  const hookr = address(hookrToken, "HOOKR token");
  const reviewedHook = address(hook, "Hookr hook");
  if ((BigInt(reviewedHook) & HOOK_PERMISSION_MASK) !== EXPECTED_HOOK_FLAGS) {
    fail("reviewed Hookr hook address does not carry the expected permission flags");
  }
  rawCommit(run, `phase A/${stage}`, operatorCommit);

  let pairs;
  if (stage === "instant-launch") {
    pairs = pairRawForgeRun(
      run, "phase A/instant-launch", ["launchInstant"], [pad],
      [CANARY_CREATION_FEE_WEI.toString()],
    );
    exactCalldata(
      pairs[0], LAUNCHPAD_ABI, "launchInstant",
      [launchArgs("Canary Instant V5", "CANV5I", canarySender, INSTANT_FOUR), 0, INTENTS.instant],
      "phase A instant launch",
    );
    if (instantToken) {
      const minedInstantToken = address(instantToken, "instant token");
      const log = matchOnlyLog(pairs[0].receipt, pad, INSTANT_LAUNCHED_TOPIC, "phase A instant launch");
      if (topicAddress(log.topics?.[1], "InstantLaunched token") !== minedInstantToken) {
        fail("phase A instant stage token differs from raw InstantLaunched");
      }
    }
  } else if (stage === "instant-buy-auction-launch") {
    const minedInstantToken = address(instantToken, "instant token");
    pairs = pairRawForgeRun(
      run, "phase A/instant-buy-auction-launch", ["exactInput", "launchAuction"],
      [swapRouter, pad], [CANARY_BUY_WEI.toString(), CANARY_CREATION_FEE_WEI.toString()],
    );
    const swap = decodeSwap(pairs[0], "phase A instant buy");
    const deadline = assertDeadline(swap.deadline, pairs[0].receipt, "phase A instant buy");
    exactCalldata(
      pairs[0], ROUTER_ABI, "exactInput",
      [[
        [ZERO_ADDRESS, minedInstantToken, DYNAMIC_FEE_FLAG, POOL_TICK_SPACING, reviewedHook],
        true, CANARY_BUY_WEI, BUY_MIN_TOKENS_OUT, MIN_SQRT_PRICE_LIMIT, canarySender, deadline,
      ]],
      "phase A instant buy",
    );
    assertGuardedSwapReceipt({
      pair: pairs[0], key: swap.key, hook: reviewedHook, router: swapRouter,
      label: "phase A instant buy", flywheelWei: 3_000_000_000_000n,
    });
    exactCalldata(
      pairs[1], LAUNCHPAD_ABI, "launchAuction",
      [
        launchArgs("Canary Auction V5", "CANV5A", canarySender, ALL_FIVE),
        0, CANARY_FLOOR_FDV, CANARY_RAISE_FLOOR, CANARY_RESERVE_BPS, INTENTS.auction,
      ],
      "phase A auction launch",
    );
  } else if (stage === "hookr-launch") {
    pairs = pairRawForgeRun(
      run,
      "phase A/hookr-launch",
      ["launchInstant"],
      [pad],
      [CANARY_CREATION_FEE_WEI.toString()],
    );
    exactCalldata(
      pairs[0], LAUNCHPAD_ABI, "launchInstant",
      [launchArgs("Canary Hookr Pair V5", "CANV5H", canarySender, GUARD_TWO), 1, INTENTS.hookr],
      "phase A HOOKR launch",
    );
  } else if (stage === "hookr-approve-buy") {
    const minedHookrPairToken = address(hookrPairToken, "HOOKR pair token");
    pairs = pairRawForgeRun(
      run, "phase A/hookr-approve-buy", ["approve", "exactInput"],
      [hookr, swapRouter], ["0", "0"],
    );
    exactCalldata(
      pairs[0], ERC20_ABI, "approve", [swapRouter, CANARY_HOOKR_BUY],
      "phase A HOOKR approval",
    );
    const swap = decodeSwap(pairs[1], "phase A HOOKR buy");
    const deadline = assertDeadline(swap.deadline, pairs[1].receipt, "phase A HOOKR buy");
    exactCalldata(
      pairs[1], ROUTER_ABI, "exactInput",
      [[
        [hookr, minedHookrPairToken, DYNAMIC_FEE_FLAG, POOL_TICK_SPACING, reviewedHook],
        true, CANARY_HOOKR_BUY, HOOKR_BUY_MIN_TOKENS_OUT, MIN_SQRT_PRICE_LIMIT,
        canarySender, deadline,
      ]],
      "phase A HOOKR buy",
    );
    assertGuardedSwapReceipt({
      pair: pairs[1], key: swap.key, hook: reviewedHook, router: swapRouter,
      label: "phase A HOOKR buy", flywheelWei: 0n,
    });
  } else {
    fail(`unknown Phase-A stage ${stage}`);
  }

  for (const [index, pair] of pairs.entries()) {
    if (!sameHex(pair.tx?.transaction?.from, canarySender)) {
      fail(`phase A/${stage} transaction #${index} sender is wrong`);
    }
  }
  return true;
}

export function buildV5PhaseAIndex(context) {
  const {
    instantLaunchRun, instantLaunchPath,
    instantBuyAuctionLaunchRun, instantBuyAuctionLaunchPath,
    ownerBidTransaction, ownerBidTransactionPath, ownerBidReceipt, ownerBidReceiptPath,
    hookrLaunchRun, hookrLaunchPath,
    hookrApproveBuyRun, hookrApproveBuyPath,
    shortenTransaction, shortenTransactionPath, shortenReceipt, shortenReceiptPath,
    restoreTransaction, restoreTransactionPath, restoreReceipt, restoreReceiptPath,
    deploymentSourceCommit, originalCanaryOperatorCommit, canaryRecoveryCommit,
    sender, launchpad, router, hookrToken, hook: expectedHook,
    instantToken, auctionToken, auction, bidId, hookrPairToken,
  } = context;
  for (const [object, path, label] of [
    [instantLaunchRun, instantLaunchPath, "instant-launch"],
    [instantBuyAuctionLaunchRun, instantBuyAuctionLaunchPath, "instant-buy-auction-launch"],
    [ownerBidTransaction, ownerBidTransactionPath, "owner bid transaction"],
    [ownerBidReceipt, ownerBidReceiptPath, "owner bid receipt"],
    [hookrLaunchRun, hookrLaunchPath, "hookr-launch"],
    [hookrApproveBuyRun, hookrApproveBuyPath, "hookr-approve-buy"],
    [shortenTransaction, shortenTransactionPath, "shorten transaction"],
    [shortenReceipt, shortenReceiptPath, "shorten receipt"],
    [restoreTransaction, restoreTransactionPath, "restore transaction"],
    [restoreReceipt, restoreReceiptPath, "restore receipt"],
  ]) {
    assert.deepStrictEqual(object, readJson(path), `${label} object differs from raw evidence bytes supplied by path`);
  }

  const sourceCommit = fullCommit(deploymentSourceCommit, "deployment source commit");
  const originalOperatorCommit = fullCommit(
    originalCanaryOperatorCommit,
    "original canary operator commit",
  );
  const recoveryCommit = fullCommit(canaryRecoveryCommit, "canary recovery commit");
  if (originalOperatorCommit === recoveryCommit) {
    fail("canary recovery commit must be a distinct reviewed descendant");
  }
  const canarySender = address(sender, "canary sender");
  const pad = address(launchpad, "launchpad");
  const swapRouter = address(router, "router");
  const hookr = address(hookrToken, "HOOKR token");
  const minedInstantToken = address(instantToken, "instant token");
  const minedAuctionToken = address(auctionToken, "auction token");
  const minedAuction = address(auction, "auction");
  const minedBidId = decimal(bidId, "bid id");
  const minedHookrPairToken = address(hookrPairToken, "HOOKR pair token");

  const instantLaunchPairs = pairRawForgeRun(
    instantLaunchRun,
    "phase A/instant-launch",
    ["launchInstant"],
    [pad],
    [CANARY_CREATION_FEE_WEI.toString()],
  );
  const instantBuyAuctionLaunchPairs = pairRawForgeRun(
    instantBuyAuctionLaunchRun,
    "phase A/instant-buy-auction-launch",
    ["exactInput", "launchAuction"],
    [swapRouter, pad],
    [CANARY_BUY_WEI.toString(), CANARY_CREATION_FEE_WEI.toString()],
  );
  const ownerBidPair = pairRawOwnerBid({
    transaction: ownerBidTransaction,
    receipt: ownerBidReceipt,
    sender: canarySender,
    auction: minedAuction,
  });
  const hookrLaunchPairs = pairRawForgeRun(
    hookrLaunchRun,
    "phase A/hookr-launch",
    ["launchInstant"],
    [pad],
    [CANARY_CREATION_FEE_WEI.toString()],
  );
  const hookrApproveBuyPairs = pairRawForgeRun(
    hookrApproveBuyRun,
    "phase A/hookr-approve-buy",
    ["approve", "exactInput"],
    [hookr, swapRouter],
    ["0", "0"],
  );
  const shortenPair = pairRawTiming({
    transaction: shortenTransaction, receipt: shortenReceipt, label: "phase A/shorten",
    sender: canarySender, launchpad: pad, duration: 20_000,
  });
  const restorePair = pairRawTiming({
    transaction: restoreTransaction, receipt: restoreReceipt, label: "phase A/restore",
    sender: canarySender, launchpad: pad, duration: 125_000,
  });

  const instantLog = matchOnlyLog(
    instantLaunchPairs[0].receipt, pad, INSTANT_LAUNCHED_TOPIC, "phase A instant launch",
  );
  if (topicAddress(instantLog.topics?.[1], "InstantLaunched token") !== minedInstantToken) {
    fail("phase A index instant token differs from raw InstantLaunched");
  }
  const instantPoolId = topicBytes32(instantLog.topics?.[2], "InstantLaunched pool id");
  const auctionLog = matchOnlyLog(
    instantBuyAuctionLaunchPairs[1].receipt, pad, AUCTION_STARTED_TOPIC, "phase A auction launch",
  );
  if (topicAddress(auctionLog.topics?.[1], "AuctionStarted token") !== minedAuctionToken ||
      topicAddress(auctionLog.topics?.[2], "AuctionStarted auction") !== minedAuction) {
    fail("phase A index auction identities differ from raw AuctionStarted");
  }
  const auctionConfig = auctionConfigFromLog(auctionLog);
  const auctionEndBlock = auctionConfig.endBlock;
  if (
    auctionConfig.floorFdvWei !== CANARY_FLOOR_FDV ||
    auctionConfig.raiseFloorWei !== CANARY_RAISE_FLOOR ||
    auctionConfig.reserveBps !== CANARY_RESERVE_BPS
  ) {
    fail("phase A AuctionStarted terms are not the reviewed floor, raise, and reserve split");
  }
  const auctionLaunchBlock = BigInt(instantBuyAuctionLaunchPairs[1].receipt.blockNumber);
  if (auctionEndBlock !== auctionLaunchBlock + CANARY_AUCTION_DURATION_BLOCKS) {
    fail(
      `phase A AuctionStarted endBlock ${auctionEndBlock} is not launch block ${auctionLaunchBlock} + ${CANARY_AUCTION_DURATION_BLOCKS}`,
    );
  }
  const bidLog = matchOnlyLog(
    ownerBidPair.receipt,
    minedAuction,
    BID_SUBMITTED_TOPIC,
    "phase A auction bid",
  );
  if (topicAddress(bidLog.topics?.[2], "BidSubmitted owner") !== canarySender ||
      decimal(bidLog.topics?.[1], "BidSubmitted id") !== minedBidId) {
    fail("phase A index bid id/owner differs from raw BidSubmitted");
  }
  if (ownerBidPair.bidId !== minedBidId) fail("phase A owner bid pair derives a different bid id");
  if (BigInt(ownerBidPair.receipt.blockNumber) >= auctionEndBlock) {
    fail("phase A owner bid was not mined before the authenticated auction end block");
  }
  const hookrLog = matchOnlyLog(
    hookrLaunchPairs[0].receipt, pad, INSTANT_LAUNCHED_TOPIC, "phase A HOOKR launch",
  );
  if (topicAddress(hookrLog.topics?.[1], "HOOKR InstantLaunched token") !== minedHookrPairToken) {
    fail("phase A index HOOKR pair differs from raw InstantLaunched");
  }
  const hookrPoolId = topicBytes32(hookrLog.topics?.[2], "HOOKR InstantLaunched pool id");

  // Bind every signer call to the reviewed CanaryRobinhoodV5 semantics. Function labels in a
  // Forge artifact are presentation metadata; only exact calldata proves the selector and args.
  exactCalldata(
    instantLaunchPairs[0],
    LAUNCHPAD_ABI,
    "launchInstant",
    [launchArgs("Canary Instant V5", "CANV5I", canarySender, INSTANT_FOUR), 0, INTENTS.instant],
    "phase A instant launch",
  );
  exactCalldata(
    instantBuyAuctionLaunchPairs[1],
    LAUNCHPAD_ABI,
    "launchAuction",
    [
      launchArgs("Canary Auction V5", "CANV5A", canarySender, ALL_FIVE),
      0,
      CANARY_FLOOR_FDV,
      CANARY_RAISE_FLOOR,
      CANARY_RESERVE_BPS,
      INTENTS.auction,
    ],
    "phase A auction launch",
  );
  exactCalldata(
    hookrLaunchPairs[0],
    LAUNCHPAD_ABI,
    "launchInstant",
    [launchArgs("Canary Hookr Pair V5", "CANV5H", canarySender, GUARD_TWO), 1, INTENTS.hookr],
    "phase A HOOKR launch",
  );
  exactCalldata(
    hookrApproveBuyPairs[0],
    ERC20_ABI,
    "approve",
    [swapRouter, CANARY_HOOKR_BUY],
    "phase A HOOKR approval",
  );

  const instantSwap = decodeSwap(instantBuyAuctionLaunchPairs[0], "phase A instant buy");
  const hook = address(instantSwap.key?.hooks, "phase A pool hook");
  if (hook === ZERO_ADDRESS || (BigInt(hook) & HOOK_PERMISSION_MASK) !== EXPECTED_HOOK_FLAGS) {
    fail("phase A pool hook address does not carry the reviewed Hookr permission flags");
  }
  if (expectedHook && !sameHex(hook, address(expectedHook, "reviewed Hookr hook"))) {
    fail("phase A pool hook is not the authenticated release hook");
  }
  const instantDeadline = assertDeadline(
    instantSwap.deadline,
    instantBuyAuctionLaunchPairs[0].receipt,
    "phase A instant buy",
  );
  exactCalldata(
    instantBuyAuctionLaunchPairs[0],
    ROUTER_ABI,
    "exactInput",
    [[
      [ZERO_ADDRESS, minedInstantToken, DYNAMIC_FEE_FLAG, POOL_TICK_SPACING, hook],
      true,
      CANARY_BUY_WEI,
      BUY_MIN_TOKENS_OUT,
      MIN_SQRT_PRICE_LIMIT,
      canarySender,
      instantDeadline,
    ]],
    "phase A instant buy",
  );
  const instantSwapEvidence = assertGuardedSwapReceipt({
    pair: instantBuyAuctionLaunchPairs[0], key: instantSwap.key, hook, router: swapRouter,
    label: "phase A instant buy", flywheelWei: 3_000_000_000_000n,
  });
  if (!sameHex(poolId(instantSwap.key), instantPoolId)) {
    fail("phase A instant buy PoolKey does not match the launched instant pool id");
  }

  const hookrSwap = decodeSwap(hookrApproveBuyPairs[1], "phase A HOOKR buy");
  if (!sameHex(hookrSwap.key?.hooks, hook)) fail("phase A buys do not use the same Hookr hook");
  const hookrDeadline = assertDeadline(
    hookrSwap.deadline,
    hookrApproveBuyPairs[1].receipt,
    "phase A HOOKR buy",
  );
  exactCalldata(
    hookrApproveBuyPairs[1],
    ROUTER_ABI,
    "exactInput",
    [[
      [hookr, minedHookrPairToken, DYNAMIC_FEE_FLAG, POOL_TICK_SPACING, hook],
      true,
      CANARY_HOOKR_BUY,
      HOOKR_BUY_MIN_TOKENS_OUT,
      MIN_SQRT_PRICE_LIMIT,
      canarySender,
      hookrDeadline,
    ]],
    "phase A HOOKR buy",
  );
  assertGuardedSwapReceipt({
    pair: hookrApproveBuyPairs[1], key: hookrSwap.key, hook, router: swapRouter,
    label: "phase A HOOKR buy", flywheelWei: 0n,
  });
  if (!sameHex(poolId(hookrSwap.key), hookrPoolId)) {
    fail("phase A HOOKR buy PoolKey does not match the launched HOOKR pool id");
  }

  for (const [receipt, intent, token, label] of [
    [instantLaunchPairs[0].receipt, INTENTS.instant, minedInstantToken, "instant"],
    [instantBuyAuctionLaunchPairs[1].receipt, INTENTS.auction, minedAuctionToken, "auction"],
    [hookrLaunchPairs[0].receipt, INTENTS.hookr, minedHookrPairToken, "HOOKR"],
  ]) {
    const log = matchOnlyLog(receipt, pad, INTENT_CONSUMED_TOPIC, `${label} intent`);
    if (topicAddress(log.topics?.[1], `${label} intent creator`) !== canarySender ||
        !sameHex(log.topics?.[2], intent) || topicAddress(log.topics?.[3], `${label} intent token`) !== token) {
      fail(`${label} LaunchIntentConsumed event is wrong`);
    }
  }

  const chronological = [
    { ...instantLaunchPairs[0], kind: "forge", artifact: "instantLaunch", artifactIndex: 0, function: "launchInstant" },
    { ...shortenPair, kind: "timing", artifact: "shorten", artifactIndex: 0, function: "setAuctionTiming" },
    ...instantBuyAuctionLaunchPairs.map((pair, artifactIndex) => ({
      ...pair, kind: "forge", artifact: "instantBuyAuctionLaunch", artifactIndex,
      function: artifactIndex === 0 ? "exactInput" : "launchAuction",
    })),
    { ...restorePair, kind: "timing", artifact: "restore", artifactIndex: 0, function: "setAuctionTiming" },
    { ...ownerBidPair, kind: "raw", artifact: "ownerBid", artifactIndex: 0, function: "submitBid" },
    { ...hookrLaunchPairs[0], kind: "forge", artifact: "hookrLaunch", artifactIndex: 0, function: "launchInstant" },
    ...hookrApproveBuyPairs.map((pair, artifactIndex) => ({
      ...pair, kind: "forge", artifact: "hookrApproveBuy", artifactIndex,
      function: artifactIndex === 0 ? "approve" : "exactInput",
    })),
  ];
  for (let index = 0; index < chronological.length; index += 1) {
    const pair = chronological[index];
    if (!sameHex(pair.tx.transaction.from, canarySender)) fail(`phase A transaction #${index} sender is wrong`);
    const nonce = BigInt(pair.tx.transaction.nonce);
    if (index > 0 && nonce !== BigInt(chronological[0].tx.transaction.nonce) + BigInt(index)) {
      fail("phase A transaction nonces are not consecutive across raw Forge and transaction/receipt evidence");
    }
    const block = BigInt(pair.receipt.blockNumber);
    const transactionIndex = BigInt(pair.receipt.transactionIndex);
    if (index > 0) {
      const previous = chronological[index - 1];
      const previousBlock = BigInt(previous.receipt.blockNumber);
      const previousIndex = BigInt(previous.receipt.transactionIndex);
      if (block < previousBlock || (block === previousBlock && transactionIndex <= previousIndex)) {
        fail("phase A receipts are not in strict canonical order");
      }
    }
  }

  const forgeMetadata = (run, path, label, operatorCommit) => ({
    path: repoRelativePath(path), sha256: sha256File(path),
    commit: rawCommit(run, label, operatorCommit),
    transactions: run.transactions.length, receipts: run.receipts.length, pending: 0,
  });
  const rawTimingMetadata = (transactionPath, receiptPath) => ({
    transactionPath: repoRelativePath(transactionPath), transactionSha256: sha256File(transactionPath),
    receiptPath: repoRelativePath(receiptPath), receiptSha256: sha256File(receiptPath),
  });

  return {
    kind: KIND,
    evidencePolicy: POLICY,
    chainId: 4663,
    deploymentSourceCommit: sourceCommit,
    originalCanaryOperatorCommit: originalOperatorCommit,
    canaryRecoveryCommit: recoveryCommit,
    identities: {
      sender: canarySender, launchpad: pad, router: swapRouter, hookrToken: hookr,
      hook,
      instantToken: minedInstantToken, instantPoolId,
      instantFlywheelAccrual: instantSwapEvidence.flywheelAccrual,
      auctionToken: minedAuctionToken, auction: minedAuction, auctionEndBlock: auctionEndBlock.toString(),
      bidId: minedBidId, hookrPairToken: minedHookrPairToken, hookrPoolId,
    },
    reviewedSemantics: {
      instantQuote: "ETH",
      auctionQuote: "ETH",
      hookrPairQuote: "HOOKR",
      auctionDurationBlocks: CANARY_AUCTION_DURATION_BLOCKS.toString(),
      guardBlocks: CANARY_GUARD_BLOCKS.toString(),
      guardedSwapFeePips: "203000..230000",
      flywheelFeeAccruedWei: "3000000000000",
      auctionFloorFdvWei: CANARY_FLOOR_FDV.toString(),
      auctionRaiseFloorWei: CANARY_RAISE_FLOOR.toString(),
      auctionReserveBps: CANARY_RESERVE_BPS,
      bidMaxPriceQ96: CANARY_BID_MAX_PRICE_Q96.toString(),
      bidAmountWei: CANARY_BID_WEI.toString(),
      instantBuyAmountWei: CANARY_BUY_WEI.toString(),
      instantBuyDeadline: instantDeadline.toString(),
      hookrApprovalAndBuyAmount: CANARY_HOOKR_BUY.toString(),
      hookrBuyDeadline: hookrDeadline.toString(),
      swapDeadlineBound: instantBuyAuctionLaunchPairs[0].receipt?.blockTimestamp === undefined ||
        hookrApproveBuyPairs[1].receipt?.blockTimestamp === undefined
        ? "calldata-only-no-mined-timestamp-in-raw-forge-receipt"
        : "within-600-seconds-of-mined-block",
    },
    rawForgeArtifacts: {
      instantLaunch: forgeMetadata(
        instantLaunchRun,
        instantLaunchPath,
        "instant-launch",
        originalOperatorCommit,
      ),
      instantBuyAuctionLaunch: forgeMetadata(
        instantBuyAuctionLaunchRun,
        instantBuyAuctionLaunchPath,
        "instant-buy-auction-launch",
        originalOperatorCommit,
      ),
      hookrLaunch: forgeMetadata(
        hookrLaunchRun,
        hookrLaunchPath,
        "hookr-launch",
        recoveryCommit,
      ),
      hookrApproveBuy: forgeMetadata(
        hookrApproveBuyRun,
        hookrApproveBuyPath,
        "hookr-approve-buy",
        recoveryCommit,
      ),
    },
    rawOwnerBidEvidence: rawTimingMetadata(ownerBidTransactionPath, ownerBidReceiptPath),
    rawTimingEvidence: {
      shorten: rawTimingMetadata(shortenTransactionPath, shortenReceiptPath),
      restore: rawTimingMetadata(restoreTransactionPath, restoreReceiptPath),
    },
    transactionSequence: chronological.map((pair, sequence) => ({
      sequence,
      kind: pair.kind,
      artifact: pair.artifact,
      artifactIndex: pair.artifactIndex,
      function: pair.function,
      hash: pair.txHash,
      nonce: decimal(pair.tx.transaction.nonce, `transaction #${sequence} nonce`),
      from: address(pair.tx.transaction.from, `transaction #${sequence} sender`),
      to: pair.to,
      value: pair.value,
      calldata: pair.calldata.toLowerCase(),
      receipt: {
        transactionHash: hash32(pair.receipt.transactionHash, `receipt #${sequence} transactionHash`),
        status: decimal(pair.receipt.status, `receipt #${sequence} status`),
        blockNumber: decimal(pair.receipt.blockNumber, `receipt #${sequence} blockNumber`),
        blockHash: hash32(pair.receipt.blockHash, `receipt #${sequence} blockHash`),
        transactionIndex: decimal(pair.receipt.transactionIndex, `receipt #${sequence} transactionIndex`),
      },
    })),
  };
}

export function assertV5PhaseAIndex(index, context) {
  const expected = buildV5PhaseAIndex(context);
  assert.deepStrictEqual(index, expected, "phase A evidence index differs from its raw source evidence");
  return expected;
}

const isCli = process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href;
if (isCli) {
  const args = process.argv.slice(2);
  const flag = (name) => {
    const index = args.indexOf(`--${name}`);
    if (index < 0 || !args[index + 1]) fail(`missing --${name}`);
    return args[index + 1];
  };
  const optionalFlag = (name) => {
    const index = args.indexOf(`--${name}`);
    return index < 0 ? undefined : args[index + 1];
  };
  if (args.includes("--owner-bid-only")) {
    assertV5PhaseAOwnerBidSemantics({
      transaction: readJson(flag("owner-bid-transaction")),
      receipt: readJson(flag("owner-bid-receipt")),
      sender: flag("sender"),
      auction: flag("auction"),
      bidId: optionalFlag("bid-id"),
      auctionEndBlock: optionalFlag("auction-end-block"),
    });
    process.stdout.write("verified exact Phase-A owner-bid recovery semantics\n");
    process.exit(0);
  }
  if (args.includes("--stage-only")) {
    const artifactPath = flag("artifact");
    assertV5PhaseAStageSemantics({
      stage: flag("stage"),
      run: readJson(artifactPath),
      canaryOperatorCommit: flag("canary-operator-commit"),
      sender: flag("sender"),
      launchpad: flag("launchpad"),
      router: flag("router"),
      hookrToken: flag("hookr-token"),
      hook: flag("hook"),
      instantToken: optionalFlag("instant-token"),
      hookrPairToken: optionalFlag("hookr-pair-token"),
    });
    process.stdout.write(`verified exact Phase-A stage semantics: ${flag("stage")}\n`);
    process.exit(0);
  }
  const paths = {
    instantLaunchPath: flag("instant-launch"),
    instantBuyAuctionLaunchPath: flag("instant-buy-auction-launch"),
    ownerBidTransactionPath: flag("owner-bid-transaction"),
    ownerBidReceiptPath: flag("owner-bid-receipt"),
    hookrLaunchPath: flag("hookr-launch"),
    hookrApproveBuyPath: flag("hookr-approve-buy"),
    shortenTransactionPath: flag("shorten-transaction"),
    shortenReceiptPath: flag("shorten-receipt"),
    restoreTransactionPath: flag("restore-transaction"),
    restoreReceiptPath: flag("restore-receipt"),
  };
  const outputPath = flag("output");
  const context = {
    ...paths,
    instantLaunchRun: readJson(paths.instantLaunchPath),
    instantBuyAuctionLaunchRun: readJson(paths.instantBuyAuctionLaunchPath),
    ownerBidTransaction: readJson(paths.ownerBidTransactionPath),
    ownerBidReceipt: readJson(paths.ownerBidReceiptPath),
    hookrLaunchRun: readJson(paths.hookrLaunchPath),
    hookrApproveBuyRun: readJson(paths.hookrApproveBuyPath),
    shortenTransaction: readJson(paths.shortenTransactionPath),
    shortenReceipt: readJson(paths.shortenReceiptPath),
    restoreTransaction: readJson(paths.restoreTransactionPath),
    restoreReceipt: readJson(paths.restoreReceiptPath),
    deploymentSourceCommit: flag("deployment-source-commit"),
    originalCanaryOperatorCommit: flag("original-canary-operator-commit"),
    canaryRecoveryCommit: flag("canary-recovery-commit"),
    sender: flag("sender"), launchpad: flag("launchpad"), router: flag("router"),
    hookrToken: flag("hookr-token"), hook: optionalFlag("hook"), instantToken: flag("instant-token"),
    auctionToken: flag("auction-token"), auction: flag("auction"), bidId: flag("bid-id"),
    hookrPairToken: flag("hookr-pair-token"),
  };
  const expected = buildV5PhaseAIndex(context);
  if (args.includes("--write")) {
    writeFileSync(outputPath, `${JSON.stringify(expected, null, 2)}\n`, { mode: 0o600, flag: "wx" });
  } else {
    const current = readJson(outputPath);
    assert.deepStrictEqual(current, expected, "phase A evidence index differs from its raw source evidence");
  }
  process.stdout.write(`${args.includes("--write") ? "wrote" : "verified"} ${outputPath}\n`);
}
