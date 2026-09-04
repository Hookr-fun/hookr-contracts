import { createHash } from "node:crypto";
import {
  closeSync,
  constants as fsConstants,
  fstatSync,
  openSync,
  readFileSync,
} from "node:fs";
import { keccak256, toBytes } from "viem";

import { poolIdForKey } from "./instant-canary-evidence.mjs";

/**
 * Capture one immutable local-evidence input through an already-open file descriptor. O_NOFOLLOW
 * closes the final-component symlink race; callers remain responsible for canonicalising and
 * checking every parent component before passing the path here.
 */
export function snapshotAuthenticatedLocalFile(
  path,
  label = "authenticated local input",
) {
  let descriptor;
  try {
    descriptor = openSync(path, fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW);
    const metadata = fstatSync(descriptor);
    if (!metadata.isFile()) throw new Error("path is not a regular file");
    const bytes = readFileSync(descriptor);
    return {
      path,
      bytes,
      sha256: createHash("sha256").update(bytes).digest("hex"),
      device: metadata.dev,
      inode: metadata.ino,
    };
  } catch (error) {
    throw new Error(`cannot snapshot ${label}: ${error.message}`);
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
  }
}

/** Re-open and compare identity plus exact bytes; mutation, deletion, and replacement all fail. */
export function assertAuthenticatedLocalFileUnchanged(
  snapshot,
  label = "authenticated local input",
) {
  let current;
  try {
    current = snapshotAuthenticatedLocalFile(snapshot.path, label);
  } catch (error) {
    throw new Error(
      `${label} could not be re-authenticated before write: ${error.message}`,
    );
  }
  if (
    current.device !== snapshot.device ||
    current.inode !== snapshot.inode ||
    current.sha256 !== snapshot.sha256 ||
    !current.bytes.equals(snapshot.bytes)
  ) {
    throw new Error(`${label} changed after it was authenticated`);
  }
  return true;
}

/**
 * Generation-5 canary constants, pinned to contracts/script/CanaryRobinhoodV5.s.sol. The intent
 * ids are DERIVED from the exact strings the canary script hashes so the two can never drift
 * silently; every other number is the literal the script broadcasts.
 */
export const V5_CANARY_SPEC = Object.freeze({
  instantIntentId: keccak256(toBytes("hookr.v5.canary.instant.1")),
  auctionIntentId: keccak256(toBytes("hookr.v5.canary.auction.1")),
  hookrIntentId: keccak256(toBytes("hookr.v5.canary.hookr.1")),
  instantName: "Canary Instant V5",
  instantSymbol: "CANV5I",
  auctionName: "Canary Auction V5",
  auctionSymbol: "CANV5A",
  hookrName: "Canary Hookr Pair V5",
  hookrSymbol: "CANV5H",
  tagline: "generation-5 canary",
  creationFeeWei: 200_000_000_000_000n,
  buyWei: 1_000_000_000_000_000n,
  flywheelEthIn: 3_000_000_000_000n,
  flywheelFeePips: 3_000n,
  buyMinTokensOut: 200_000n * 10n ** 18n,
  minSqrtPriceLimitX96: 4_295_128_740n,
  floorFdvWei: 20_000_000_000_000_000n, // 0.02 ether starting valuation
  raiseFloorWei: 10_000_000_000_000_000n, // 0.01 ether graduation threshold (contract minimum)
  reserveBps: 2_000,
  bidWei: 10_500_000_000_000_000n, // 0.0105 ether — clears the raise floor with headroom
  bidMaxPriceQ96: 814_814_390_533_794_434_497_901_791_991_308_996_217n,
  tokenSupply: 1_000_000_000n * 10n ** 18n,
  auctionSupply: 800_000_000n * 10n ** 18n,
  canaryAuctionDurationBlocks: 20_000n,
  productionAuctionDurationBlocks: 125_000n,
  claimDelayBlocks: 0n,
  migrationDelayBlocks: 1n,
  routerDeadlineSeconds: 600n,
  // The HOOKR-pair buy rides the sender's own HOOKR (runbook prep), approved for exactly this buy.
  hookrBuyAmount: 25_000n * 10n ** 18n,
  hookrBuyMinTokensOut: 1_000_000n * 10n ** 18n,
  flywheelMinHookrOut: 3n * 10n ** 18n,
  dynamicFee: 0x800000,
  tickSpacing: 60,
  launchMode: Object.freeze({ instant: 0, bonded: 1 }),
  launchStatus: Object.freeze({ auctioning: 0, live: 1, failed: 2 }),
  quote: Object.freeze({ eth: 0, hookr: 1 }),
  // Per-lane stacks: the bonded canary carries all five blocks; the instant canary carries four —
  // the zero-seed instant lane STRUCTURALLY refuses the LP-donation block (no in-range LP exists
  // at open to receive it), and the launchpad reverts `InstantRejectsLpDonation` if it is sent.
  // The HOOKR pair carries only the guard and surge blocks (native-cut blocks are refused there).
  auctionHookParams: Object.freeze({
    guardBlocks: 20_000,
    maxBuyBps: 1_000,
    snipeTaxPips: 200_000,
    baseFeePips: 3_000,
    maxFeePips: 30_000,
    surgeSens: 5,
    burnBps: 100,
    burnTriggerWei: 0n,
    lpBps: 25,
    potBps: 50,
    potEveryNBuys: 2,
    potMinBuyWei: 1_000_000_000_000_000n,
  }),
  instantHookParams: Object.freeze({
    guardBlocks: 20_000,
    maxBuyBps: 1_000,
    snipeTaxPips: 200_000,
    baseFeePips: 3_000,
    maxFeePips: 30_000,
    surgeSens: 5,
    burnBps: 100,
    burnTriggerWei: 0n,
    lpBps: 0,
    potBps: 50,
    potEveryNBuys: 2,
    potMinBuyWei: 1_000_000_000_000_000n,
  }),
  // The HOOKR-pair stack: guard + surge only. Every native-cut block (auto-burn, LP donation,
  // deterministic pot) is zero — the launchpad reverts `HookrPairRejectsNativeCutBlocks` and the
  // hook's configurePool refuses them independently on a non-native quote.
  hookrHookParams: Object.freeze({
    guardBlocks: 20_000,
    maxBuyBps: 1_000,
    snipeTaxPips: 200_000,
    baseFeePips: 3_000,
    maxFeePips: 30_000,
    surgeSens: 5,
    burnBps: 0,
    burnTriggerWei: 0n,
    lpBps: 0,
    potBps: 0,
    potEveryNBuys: 0,
    potMinBuyWei: 0n,
  }),
  // Phase A is four unmodified raw Forge artifacts (1 + 2 + 2 + 2) separated by two raw,
  // hash-bound owner timing transactions. Phase B is six canonical action references; the first
  // five may alias one permissionless helper receipt. Up to fifteen distinct receipts result.
  // The labels are the contract between this validator and
  // promotion; the two timing labels are deliberately embedded in their real nonce chronology.
  phaseAReceiptLabels: Object.freeze([
    "canary:instant-launch",
    "canary:auction-timing-shorten",
    "canary:instant-buy",
    "canary:auction-launch",
    "canary:auction-timing-restore",
    "canary:auction-bid",
    "canary:hookr-launch",
    "canary:hookr-approve",
    "canary:hookr-buy",
  ]),
  phaseACallReceiptLabels: Object.freeze([
    "canary:instant-launch",
    "canary:instant-buy",
    "canary:auction-launch",
    "canary:auction-bid",
    "canary:hookr-launch",
    "canary:hookr-approve",
    "canary:hookr-buy",
  ]),
  phaseBReceiptLabels: Object.freeze([
    "canary:auction-migrate",
    "canary:auction-exit",
    "canary:auction-claim",
    "canary:auction-proceeds",
    "canary:flywheel-collect",
    "canary:flywheel-burn",
  ]),
});

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const ZERO_BYTES32 = `0x${"00".repeat(32)}`;
const DEAD_ADDRESS = "0x000000000000000000000000000000000000dEaD";
const Q96 = 1n << 96n;
const PIPS = 1_000_000n;
const BPS = 10_000n;
const MAX_PROTOCOL_FEE_PIPS = 1_000n;
const NOT_APPLICABLE_ZERO_PROCEEDS = "not-applicable-zero-proceeds";

const sameHex = (a, b) =>
  typeof a === "string" &&
  typeof b === "string" &&
  a.toLowerCase() === b.toLowerCase();

const check = (condition, message) => {
  if (!condition) throw new Error(message);
};

const asBigInt = (value) => BigInt(value);

const receiptCoordinateCompare = (left, right) => {
  const blockDelta = asBigInt(left.blockNumber) - asBigInt(right.blockNumber);
  if (blockDelta !== 0n) return blockDelta < 0n ? -1 : 1;
  const transactionDelta =
    asBigInt(left.transactionIndex) - asBigInt(right.transactionIndex);
  return transactionDelta === 0n ? 0 : transactionDelta < 0n ? -1 : 1;
};

/**
 * Phase-B keepers may combine any of the five permissionless transitions in one helper
 * transaction. Such action labels are aliases of one canonical receipt, not duplicate receipts.
 * Phase A, deployment records, and the owner-only buyback remain collision-intolerant.
 */
const assertV5ReceiptOrder = (records, spec) => {
  check(
    Array.isArray(records) && records.length > 0,
    "receipt evidence is empty",
  );
  const permissionlessAliases = new Set(spec.phaseBReceiptLabels.slice(0, -1));
  const labels = new Set();
  const byHash = new Map();
  for (let index = 0; index < records.length; index += 1) {
    const record = records[index];
    check(record?.label && record?.hash, `receipt #${index} is malformed`);
    check(
      !labels.has(record.label),
      `receipt order repeats label ${record.label}`,
    );
    labels.add(record.label);
    const hash = String(record.hash).toLowerCase();
    const prior = byHash.get(hash);
    if (prior) {
      check(
        permissionlessAliases.has(prior.label) &&
          permissionlessAliases.has(record.label),
        `receipt hash ${record.hash} collides outside permissionless Phase B`,
      );
      check(
        receiptCoordinateCompare(prior, record) === 0,
        `permissionless Phase-B aliases for ${record.hash} have different coordinates`,
      );
    } else {
      byHash.set(hash, record);
    }
    if (index === 0) continue;
    const previous = records[index - 1];
    const order = receiptCoordinateCompare(previous, record);
    check(order <= 0, `${record.label} was mined before ${previous.label}`);
    if (order === 0) {
      check(
        sameHex(previous.hash, record.hash),
        `${record.label} shares canonical coordinates with a different transaction`,
      );
    }
  }
};

const eventLogIndex = (event, label) => {
  check(event && typeof event === "object", `${label} evidence is missing`);
  const index = asBigInt(event.logIndex);
  check(index >= 0n, `${label} log index is negative`);
  return index;
};

const bindEventToReceipt = (event, receipt, label) => {
  const index = eventLogIndex(event, label);
  check(
    sameHex(event.transactionHash, receipt.hash),
    `${label} transaction hash does not match its Phase-B receipt`,
  );
  return index;
};

const integerSqrt = (value) => {
  const x = asBigInt(value);
  if (x < 0n) throw new Error("square root input is negative");
  if (x < 2n) return x;
  let result = x;
  let candidate = (x + 1n) / 2n;
  while (candidate < result) {
    result = candidate;
    candidate = (x / candidate + candidate) / 2n;
  }
  return result;
};

const combinedSwapFeePips = (protocolFeePips, lpFeePips) =>
  protocolFeePips + lpFeePips - (protocolFeePips * lpFeePips) / PIPS;

const expectedMaxBuyWei = (hookParams, openPriceWei, tokenSupply) => {
  const uncapped =
    (((asBigInt(tokenSupply) * asBigInt(hookParams.maxBuyBps)) / BPS) *
      asBigInt(openPriceWei)) /
    10n ** 18n;
  const uint96Max = (1n << 96n) - 1n;
  return uncapped > uint96Max ? uint96Max : uncapped;
};

const canonicalQuantity = (value, label) => {
  try {
    return asBigInt(value).toString();
  } catch {
    throw new Error(`${label} is not an integer quantity`);
  }
};

const canonicalHex = (value, label, nullable = false) => {
  if (value === null && nullable) return null;
  check(
    typeof value === "string" && /^0x[0-9a-fA-F]*$/.test(value),
    `${label} is not hex`,
  );
  return value.toLowerCase();
};

const canonicalAddress = (value, label, nullable = false) => {
  if (value === null && nullable) return null;
  check(
    typeof value === "string" && /^0x[0-9a-fA-F]{40}$/.test(value),
    `${label} is not an address`,
  );
  return value.toLowerCase();
};

const canonicalReceiptLog = (log, index, fallbackBlockTimestamp) => {
  check(log && typeof log === "object", `receipt log #${index} is malformed`);
  check(Array.isArray(log.topics), `receipt log #${index} topics are missing`);
  const blockTimestamp = log.blockTimestamp ?? fallbackBlockTimestamp;
  check(
    blockTimestamp !== undefined && blockTimestamp !== null,
    `receipt log #${index} has no block timestamp`,
  );
  return {
    address: canonicalAddress(log.address, `receipt log #${index} address`),
    blockHash: canonicalHex(log.blockHash, `receipt log #${index} block hash`),
    blockNumber: canonicalQuantity(
      log.blockNumber,
      `receipt log #${index} block number`,
    ),
    blockTimestamp: canonicalQuantity(
      blockTimestamp,
      `receipt log #${index} block timestamp`,
    ),
    data: canonicalHex(log.data, `receipt log #${index} data`),
    logIndex: canonicalQuantity(
      log.logIndex,
      `receipt log #${index} log index`,
    ),
    removed: Boolean(log.removed ?? false),
    topics: log.topics.map((topic, topicIndex) =>
      canonicalHex(topic, `receipt log #${index} topic #${topicIndex}`),
    ),
    transactionHash: canonicalHex(
      log.transactionHash,
      `receipt log #${index} transaction hash`,
    ),
    transactionIndex: canonicalQuantity(
      log.transactionIndex,
      `receipt log #${index} transaction index`,
    ),
  };
};

const canonicalReceipt = (receipt, context) => {
  check(
    receipt && typeof receipt === "object",
    `${context.label} is not a receipt object`,
  );
  check(Array.isArray(receipt.logs), `${context.label} logs are missing`);
  const l1BlockNumber = receipt.l1BlockNumber ?? context.contractBlockNumber;
  check(
    l1BlockNumber !== undefined && l1BlockNumber !== null,
    `${context.label} has no l1BlockNumber`,
  );
  return {
    status: canonicalQuantity(receipt.status, `${context.label} status`),
    cumulativeGasUsed: canonicalQuantity(
      receipt.cumulativeGasUsed,
      `${context.label} cumulative gas`,
    ),
    logsBloom: canonicalHex(receipt.logsBloom, `${context.label} logs bloom`),
    type: canonicalQuantity(receipt.type, `${context.label} type`),
    transactionHash: canonicalHex(
      receipt.transactionHash,
      `${context.label} transaction hash`,
    ),
    transactionIndex: canonicalQuantity(
      receipt.transactionIndex,
      `${context.label} transaction index`,
    ),
    blockHash: canonicalHex(receipt.blockHash, `${context.label} block hash`),
    blockNumber: canonicalQuantity(
      receipt.blockNumber,
      `${context.label} block number`,
    ),
    gasUsed: canonicalQuantity(receipt.gasUsed, `${context.label} gas used`),
    effectiveGasPrice: canonicalQuantity(
      receipt.effectiveGasPrice,
      `${context.label} effective gas price`,
    ),
    from: canonicalAddress(receipt.from, `${context.label} sender`),
    to: canonicalAddress(receipt.to, `${context.label} target`, true),
    contractAddress: canonicalAddress(
      receipt.contractAddress,
      `${context.label} contract address`,
      true,
    ),
    gasUsedForL1:
      receipt.gasUsedForL1 === undefined || receipt.gasUsedForL1 === null
        ? null
        : canonicalQuantity(
            receipt.gasUsedForL1,
            `${context.label} L1 gas used`,
          ),
    l1BlockNumber: canonicalQuantity(
      l1BlockNumber,
      `${context.label} l1 block number`,
    ),
    logs: receipt.logs.map((log, index) =>
      canonicalReceiptLog(log, index, context.blockTimestamp),
    ),
  };
};

/**
 * Bind a persisted Forge/cast receipt byte-for-byte in meaning to a fresh raw RPC receipt. RPCs may
 * omit Robinhood's redundant log timestamp or receipt l1BlockNumber, so those two values are filled
 * only from the already hash-authenticated block header before the complete normalized comparison.
 */
export function assertRawReceiptMatchesLive(rawReceipt, liveReceipt, context) {
  const label = context?.label ?? "receipt";
  const normalizedContext = { ...context, label };
  const raw = canonicalReceipt(rawReceipt, normalizedContext);
  const live = canonicalReceipt(liveReceipt, normalizedContext);
  check(
    JSON.stringify(raw) === JSON.stringify(live),
    `${label} persisted raw receipt/logs differ from live RPC evidence`,
  );
  return raw;
}

/**
 * Error messages from HTTP transports may include their complete endpoint. Replace both the
 * configured spelling and the common URI encodings before an operational failure is logged.
 */
export const redactConfiguredRpc = (message, configuredRpc) => {
  const rpc = String(configuredRpc ?? "");
  if (rpc === "") return String(message);
  const spellings = new Set([rpc]);
  for (const encode of [encodeURI, encodeURIComponent]) {
    try {
      spellings.add(encode(rpc));
    } catch {
      // The exact configured spelling is still redacted if an encoder rejects malformed input.
    }
  }
  return [...spellings]
    .filter(Boolean)
    .sort((left, right) => right.length - left.length)
    .reduce(
      (redacted, spelling) => redacted.split(spelling).join("<configured RPC>"),
      String(message),
    );
};

/**
 * Every launch (all lanes) shares one canonical PoolKey shape; only the quote currency (native
 * ETH or HOOKR) and the token vary. The key in calldata/readbacks must re-derive the exact
 * PoolId the events named.
 */
const canonicalPoolKey = (quoteCurrency, token, hook) => ({
  currency0: quoteCurrency,
  currency1: token,
  fee: V5_CANARY_SPEC.dynamicFee,
  tickSpacing: V5_CANARY_SPEC.tickSpacing,
  hooks: hook,
});

const checkLaunchArgs = (args, spec, sender, label) => {
  check(args.name === spec.name, `${label} name is wrong`);
  check(args.symbol === spec.symbol, `${label} symbol is wrong`);
  check(args.tagline === V5_CANARY_SPEC.tagline, `${label} tagline is wrong`);
  check(args.logoURI === "", `${label} logo must be empty`);
  check(
    sameHex(args.expectedCreator, sender),
    `${label} expected creator is not the canary sender`,
  );
  check(
    Number(args.blueprintId) === 0,
    `${label} is not the custom canary stack`,
  );
  check(
    Number(args.creatorFeeBps) === 0,
    `${label} creator fee override is nonzero`,
  );
  check(
    args.feeRecipients.length === 0,
    `${label} has unexpected fee recipients`,
  );
  for (const [field, expected] of Object.entries(spec.hookParams)) {
    check(
      asBigInt(args.custom[field]) === asBigInt(expected),
      `${label} hook parameter ${field} is wrong`,
    );
  }
};

const checkTokenLaunchedEvent = (event, spec, sender, mode, label) => {
  check(
    !sameHex(event.token, ZERO_ADDRESS),
    `${label} TokenLaunched token is zero`,
  );
  check(
    sameHex(event.creator, sender),
    `${label} TokenLaunched creator is not the canary sender`,
  );
  check(
    Number(event.blueprintId) === 0,
    `${label} TokenLaunched blueprint is not custom`,
  );
  check(Number(event.mode) === mode, `${label} TokenLaunched mode is wrong`);
  check(
    event.name === spec.name && event.symbol === spec.symbol,
    `${label} TokenLaunched metadata is wrong`,
  );
  check(
    event.tagline === V5_CANARY_SPEC.tagline && event.logoURI === "",
    `${label} TokenLaunched presentation is wrong`,
  );
};

/**
 * Validate the decoded, pinned evidence for one generation-5 production canary: every lane and
 * the flywheel — the ETH instant round trip, the full bonded auction cycle, the HOOKR-quoted
 * instant launch with an approved HOOKR-pair buy, and the flywheel end to end
 * (collect -> buybackAndBurn -> dead-address transfer). Four raw Forge artifacts, two raw timing
 * transactions, and six authenticated Phase-B action references (whose permissionless receipts
 * may overlap): at most fifteen distinct receipts. Pure, so malformed evidence
 * fixtures can be covered with negative tests without an RPC.
 */
export function validateV5CanaryEvidence(evidence) {
  const spec = V5_CANARY_SPEC;
  assertV5ReceiptOrder(evidence.receiptOrder, spec);

  // ---------------------------------------------------------------- receipt binding
  // Pull the fifteen action references out of canonical chain order, require the Phase-A owner's
  // real nonce sequence, and bind every transaction shape to its ordered receipt block. The first
  // five Phase-B labels may alias one receipt; their causal edges are then proven by event log
  // indexes instead of by an invented transaction order.
  const labels = [...spec.phaseAReceiptLabels, ...spec.phaseBReceiptLabels];
  const canaryRecords = labels.map((label) => {
    const index = evidence.receiptOrder.findIndex(
      (record) => record.label === label,
    );
    check(index >= 0, `receipt order is missing ${label}`);
    return { index, record: evidence.receiptOrder[index] };
  });
  for (let i = 1; i < spec.phaseAReceiptLabels.length; i += 1) {
    check(
      receiptCoordinateCompare(
        canaryRecords[i - 1].record,
        canaryRecords[i].record,
      ) < 0,
      `${labels[i]} is not ordered after ${labels[i - 1]}`,
    );
  }
  const phaseBRecord = (label) => canaryRecords[labels.indexOf(label)];
  const distinctReceiptBefore = (before, after, message) => {
    check(
      receiptCoordinateCompare(
        phaseBRecord(before).record,
        phaseBRecord(after).record,
      ) < 0,
      message,
    );
  };
  distinctReceiptBefore(
    "canary:instant-buy",
    "canary:flywheel-collect",
    "flywheel collect was not mined after the canary accrual",
  );
  distinctReceiptBefore(
    "canary:flywheel-collect",
    "canary:flywheel-burn",
    "flywheel collect was not mined before buyback",
  );

  const {
    canarySender,
    launchpad,
    hook,
    router,
    poolManager,
    hookrToken,
    burner,
  } = evidence.identities;
  const { timing, instant, auction, hookr, flywheel, postconditions } =
    evidence;
  check(
    typeof hookrToken === "string" && !sameHex(hookrToken, ZERO_ADDRESS),
    "identities name no HOOKR token",
  );
  check(
    typeof burner === "string" && !sameHex(burner, ZERO_ADDRESS),
    "identities name no flywheel burner",
  );
  const auctionAddress = auction.launch.startedEvent.auction;
  check(
    typeof auctionAddress === "string" &&
      !sameHex(auctionAddress, ZERO_ADDRESS),
    "AuctionStarted names no auction contract",
  );

  const phaseASteps = [
    ["instant launch", instant.launch.transaction, launchpad],
    ["auction timing shorten", timing.shorten.transaction, launchpad],
    ["instant router buy", instant.buy.transaction, router],
    ["auction launch", auction.launch.transaction, launchpad],
    ["auction timing restore", timing.restore.transaction, launchpad],
    ["auction bid", auction.bid.transaction, auctionAddress],
    ["hookr launch", hookr.launch.transaction, launchpad],
    ["hookr approve", hookr.approve.transaction, hookrToken],
    ["hookr buy", hookr.buy.transaction, router],
  ];
  const phaseBSteps = [
    ["auction migrate", auction.migrate.transaction],
    ["auction exit", auction.exit.transaction],
    ["auction claim", auction.claimTokens.transaction],
    ["auction proceeds claim", auction.proceedsClaim.transaction],
    ["flywheel collect", flywheel.collect.transaction],
    ["flywheel burn", flywheel.burn.transaction],
  ];
  for (let i = 0; i < phaseASteps.length; i += 1) {
    const [label, tx, target] = phaseASteps[i];
    check(sameHex(tx.to, target), `${label} target is wrong`);
    check(
      asBigInt(tx.blockNumber) ===
        asBigInt(canaryRecords[i].record.blockNumber),
      `${label} transaction block does not match its ordered receipt`,
    );
  }
  for (let i = 0; i < phaseBSteps.length; i += 1) {
    const [label, tx] = phaseBSteps[i];
    const record = canaryRecords[phaseASteps.length + i].record;
    check(
      asBigInt(tx.blockNumber) === asBigInt(record.blockNumber),
      `${label} transaction block does not match its ordered receipt`,
    );
  }
  const firstPhaseANonce = asBigInt(phaseASteps[0][1].nonce);
  for (let i = 0; i < phaseASteps.length; i += 1) {
    const [label, tx] = phaseASteps[i];
    check(
      sameHex(tx.from, canarySender),
      `${label} sender is not the canary sender`,
    );
    check(
      asBigInt(tx.nonce) === firstPhaseANonce + BigInt(i),
      "phase A signer nonces are not consecutive in canonical transaction order",
    );
  }
  // Settlement is intentionally permissionless: a keeper may migrate, settle the canary bid,
  // claim its proceeds, and collect the hook's fees. Only the owner-gated buyback must be sent by
  // the canary owner. Consequently Phase-B sender nonces carry no protocol meaning.
  check(
    sameHex(flywheel.burn.transaction.from, canarySender),
    "flywheel burn sender is not the canary owner",
  );
  check(
    sameHex(flywheel.burn.transaction.to, burner),
    "flywheel burn target is wrong",
  );
  check(
    asBigInt(flywheel.burn.transaction.value) === 0n,
    "flywheel burn sends native value",
  );

  const checkTiming = (record, duration, label) => {
    check(
      asBigInt(record.transaction.value) === 0n,
      `${label} sends native value`,
    );
    check(
      asBigInt(record.calldata.durationBlocks) === duration,
      `${label} duration is wrong`,
    );
    check(
      asBigInt(record.calldata.claimDelay) === spec.claimDelayBlocks &&
        asBigInt(record.calldata.migrationDelay) === spec.migrationDelayBlocks,
      `${label} delays are wrong`,
    );
    const event = record.event;
    check(
      event && typeof event === "object",
      `${label} has no AuctionTimingSet evidence`,
    );
    check(
      asBigInt(event.durationBlocks) === duration &&
        asBigInt(event.claimDelay) === spec.claimDelayBlocks &&
        asBigInt(event.migrationDelay) === spec.migrationDelayBlocks,
      `${label} AuctionTimingSet fields are wrong`,
    );
  };
  checkTiming(
    timing.shorten,
    spec.canaryAuctionDurationBlocks,
    "auction timing shorten",
  );
  checkTiming(
    timing.restore,
    spec.productionAuctionDurationBlocks,
    "auction timing restore",
  );

  const checkEffectivePoolConfig = (
    config,
    {
      label,
      token,
      hookParams,
      configuredAtBlock,
      openPriceWei,
      flywheelFeePips,
    },
  ) => {
    check(
      config && typeof config === "object",
      `${label} has no effective HookrHook poolConfig readback`,
    );
    check(
      config.initialized === true,
      `${label} poolConfig is not initialized`,
    );
    check(sameHex(config.token, token), `${label} poolConfig token is wrong`);
    const expectedGuardEnd =
      asBigInt(hookParams.guardBlocks) === 0n
        ? 0n
        : asBigInt(configuredAtBlock) + asBigInt(hookParams.guardBlocks);
    check(
      asBigInt(config.guardEndBlock) === expectedGuardEnd,
      `${label} poolConfig guard end is wrong`,
    );
    for (const field of [
      "baseFeePips",
      "snipeTaxPips",
      "surgeSens",
      "burnBps",
      "lpBps",
      "potBps",
      "potEveryNBuys",
      "potMinBuyWei",
      "burnTriggerWei",
    ]) {
      check(
        asBigInt(config[field]) === asBigInt(hookParams[field]),
        `${label} poolConfig ${field} is wrong`,
      );
    }
    const expectedMaxFee =
      asBigInt(hookParams.maxFeePips) === 0n
        ? asBigInt(hookParams.baseFeePips)
        : asBigInt(hookParams.maxFeePips);
    check(
      asBigInt(config.maxFeePips) === expectedMaxFee,
      `${label} poolConfig maxFeePips is wrong`,
    );
    check(
      asBigInt(config.royaltyBps) === 0n,
      `${label} poolConfig carries an unexpected royalty`,
    );
    check(
      sameHex(config.royaltyTo, ZERO_ADDRESS),
      `${label} poolConfig royalty recipient is nonzero`,
    );
    check(
      asBigInt(config.maxBuyWei) ===
        expectedMaxBuyWei(hookParams, openPriceWei, spec.tokenSupply),
      `${label} poolConfig maxBuyWei is not derived from its opening price`,
    );
    check(
      asBigInt(config.flywheelFeePips) === asBigInt(flywheelFeePips),
      `${label} poolConfig flywheel fee is wrong`,
    );
  };

  const checkGuardedSwap = (event, hookParams, label) => {
    check(
      asBigInt(event.sqrtPriceX96) > 0n,
      `${label} PoolManager Swap has zero sqrt price`,
    );
    check(
      asBigInt(event.liquidity) > 0n,
      `${label} PoolManager Swap has zero liquidity`,
    );
    const observedFee = asBigInt(event.fee);
    // PoolManager emits the combined protocol + LP fee. The authenticated hook runtime and
    // receipt clock prove this exact buy ran inside the guard, so the LP override must include
    // base + snipe tax. A configured surge can legitimately round to zero for a small trade
    // relative to virtual in-range depth; requiring a strictly positive surge would reject that
    // valid guarded execution. The event must still prove at least the guarded LP floor and may
    // not exceed the largest combined fee allowed by the protocol and configured LP ceilings.
    const guardedFeeFloor =
      asBigInt(hookParams.baseFeePips) + asBigInt(hookParams.snipeTaxPips);
    const maximumFee = combinedSwapFeePips(
      MAX_PROTOCOL_FEE_PIPS,
      asBigInt(hookParams.maxFeePips) + asBigInt(hookParams.snipeTaxPips),
    );
    check(
      observedFee >= guardedFeeFloor,
      `${label} PoolManager fee is below the guarded base plus snipe-tax floor`,
    );
    check(
      observedFee <= maximumFee,
      `${label} PoolManager fee exceeds the configured maximum`,
    );
  };

  // ---------------------------------------------------------------- instant lane
  const iLaunch = instant.launch;
  check(
    sameHex(iLaunch.calldata.intentId, spec.instantIntentId),
    "instant launch intent is wrong",
  );
  check(
    Number(iLaunch.calldata.quote) === spec.quote.eth,
    "instant launch quote is not ETH",
  );
  checkLaunchArgs(
    iLaunch.calldata.args,
    {
      name: spec.instantName,
      symbol: spec.instantSymbol,
      hookParams: spec.instantHookParams,
    },
    canarySender,
    "instant launch",
  );
  check(
    asBigInt(iLaunch.transaction.value) === spec.creationFeeWei,
    "instant launch value is not the creation fee",
  );

  checkTokenLaunchedEvent(
    iLaunch.tokenEvent,
    { name: spec.instantName, symbol: spec.instantSymbol },
    canarySender,
    spec.launchMode.instant,
    "instant launch",
  );
  const instantToken = iLaunch.tokenEvent.token;
  const instantEvent = iLaunch.instantEvent;
  check(
    sameHex(instantEvent.token, instantToken),
    "InstantLaunched names a different token",
  );
  check(
    !sameHex(instantEvent.poolId, ZERO_BYTES32),
    "InstantLaunched pool id is zero",
  );
  const instantPoolId = instantEvent.poolId;
  check(
    sameHex(
      poolIdForKey(canonicalPoolKey(ZERO_ADDRESS, instantToken, hook)),
      instantPoolId,
    ),
    "InstantLaunched pool id does not derive from the canonical instant pool key",
  );
  check(
    asBigInt(instantEvent.openPriceWei) > 0n,
    "InstantLaunched open price is zero",
  );
  check(
    asBigInt(instantEvent.openPriceWei) ===
      asBigInt(postconditions.instantOpenPriceWei),
    "InstantLaunched open price does not match the launchpad instantOpenPriceWei readback",
  );

  const initialize = iLaunch.initializeEvent;
  check(
    initialize && typeof initialize === "object",
    "instant launch has no PoolManager Initialize evidence",
  );
  check(
    sameHex(initialize.id, instantPoolId),
    "Initialize names the wrong pool",
  );
  check(
    sameHex(initialize.currency0, ZERO_ADDRESS),
    "Initialize currency0 is not native",
  );
  check(
    sameHex(initialize.currency1, instantToken),
    "Initialize currency1 is not the instant token",
  );
  check(
    Number(initialize.fee) === spec.dynamicFee,
    "Initialize fee is not dynamic",
  );
  check(
    Number(initialize.tickSpacing) === spec.tickSpacing,
    "Initialize tick spacing is wrong",
  );
  check(
    sameHex(initialize.hooks, hook),
    "Initialize hook does not match the release",
  );
  check(
    asBigInt(initialize.sqrtPriceX96) > 0n,
    "Initialize has no opening price",
  );

  const instantRecord = postconditions.instantLaunch;
  check(
    instantRecord && typeof instantRecord === "object",
    "instant launch has no getLaunch readback",
  );
  check(
    sameHex(instantRecord.token, instantToken),
    "instant getLaunch names a different token",
  );
  check(
    sameHex(instantRecord.creator, canarySender),
    "instant getLaunch creator is wrong",
  );
  check(
    Number(instantRecord.mode) === spec.launchMode.instant,
    "instant getLaunch mode is wrong",
  );
  check(
    Number(instantRecord.status) === spec.launchStatus.live,
    "instant getLaunch status is not Live",
  );
  check(
    Number(instantRecord.quote) === spec.quote.eth,
    "instant getLaunch quote is not ETH",
  );
  check(
    sameHex(instantRecord.poolId, instantPoolId),
    "instant getLaunch pool id is wrong",
  );
  check(
    asBigInt(instantRecord.launchBlock) ===
      asBigInt(iLaunch.transaction.contractBlockNumber),
    "instant getLaunch launch block does not match the launch receipt",
  );
  for (const [field, expected] of Object.entries(spec.instantHookParams)) {
    check(
      asBigInt(instantRecord.hookParams[field]) === asBigInt(expected),
      `instant getLaunch hook parameter ${field} is wrong`,
    );
  }
  checkEffectivePoolConfig(postconditions.hookConfigs?.instant, {
    label: "instant",
    token: instantToken,
    hookParams: spec.instantHookParams,
    configuredAtBlock: iLaunch.transaction.contractBlockNumber,
    openPriceWei: instantEvent.openPriceWei,
    flywheelFeePips: spec.flywheelFeePips,
  });

  const buy = instant.buy;
  const buyKey = buy.calldata.key;
  check(
    sameHex(poolIdForKey(buyKey), instantPoolId),
    "router buy pool key does not match the instant pool id",
  );
  check(
    sameHex(buyKey.hooks, hook),
    "router buy hook does not match the release",
  );
  check(buy.calldata.zeroForOne === true, "router buy direction is wrong");
  check(
    asBigInt(buy.calldata.amountIn) === spec.buyWei,
    "router buy input is wrong",
  );
  check(
    asBigInt(buy.transaction.value) === spec.buyWei,
    "router buy native value is wrong",
  );
  check(
    asBigInt(buy.calldata.amountOutMinimum) === spec.buyMinTokensOut,
    "router buy bound is wrong",
  );
  check(
    asBigInt(buy.calldata.sqrtPriceLimitX96) === spec.minSqrtPriceLimitX96,
    "router buy price limit is wrong",
  );
  check(
    sameHex(buy.calldata.recipient, canarySender),
    "router buy recipient is wrong",
  );
  const buyTimestamp = asBigInt(buy.transaction.blockTimestamp);
  const buyDeadline = asBigInt(buy.calldata.deadline);
  check(
    buyDeadline >= buyTimestamp &&
      buyDeadline <= buyTimestamp + spec.routerDeadlineSeconds,
    "router buy deadline is outside the mined timestamp plus 600-second bound",
  );
  const instantLaunchBlock = asBigInt(instantRecord.launchBlock);
  const instantBuyContractBlock = asBigInt(buy.transaction.contractBlockNumber);
  check(
    instantBuyContractBlock >= instantLaunchBlock &&
      instantBuyContractBlock <
        instantLaunchBlock + asBigInt(spec.instantHookParams.guardBlocks),
    "router buy was not mined inside the instant guard window",
  );

  const buyEvent = buy.event;
  check(
    buyEvent && typeof buyEvent === "object",
    "router buy has no SwapExecuted evidence",
  );
  check(
    sameHex(buyEvent.payer, canarySender),
    "router buy SwapExecuted payer is wrong",
  );
  check(
    sameHex(buyEvent.recipient, canarySender),
    "router buy SwapExecuted recipient is wrong",
  );
  check(
    sameHex(buyEvent.token, instantToken),
    "router buy SwapExecuted token is wrong",
  );
  check(
    buyEvent.zeroForOne === true,
    "router buy SwapExecuted direction is wrong",
  );
  check(
    buyEvent.exactInput === true,
    "router buy SwapExecuted is not exact-input",
  );
  check(
    asBigInt(buyEvent.amountIn) === spec.buyWei,
    "router buy SwapExecuted input is wrong",
  );
  check(
    asBigInt(buyEvent.amountOut) >= spec.buyMinTokensOut,
    "router buy SwapExecuted output missed its bound",
  );

  const poolSwap = buy.poolManagerEvent;
  check(
    poolSwap && typeof poolSwap === "object",
    "router buy has no PoolManager Swap evidence",
  );
  check(
    sameHex(poolSwap.id, instantPoolId),
    "router buy swap hit the wrong pool",
  );
  check(
    sameHex(poolSwap.sender, router),
    "router buy swap sender is not the release router",
  );
  checkGuardedSwap(poolSwap, spec.instantHookParams, "router buy");

  const flywheelAccrued = buy.flywheelEvent;
  check(
    flywheelAccrued && typeof flywheelAccrued === "object",
    "router buy has no FlywheelFeeAccrued evidence",
  );
  check(
    sameHex(flywheelAccrued.poolId, instantPoolId),
    "FlywheelFeeAccrued names the wrong pool",
  );
  check(
    asBigInt(flywheelAccrued.amountWei) ===
      (spec.buyWei * spec.flywheelFeePips) / PIPS,
    "FlywheelFeeAccrued amount is not the configured cut of the canary buy",
  );

  const buyTransfer = buy.transferEvent;
  check(
    buyTransfer && typeof buyTransfer === "object",
    "router buy has no token Transfer evidence",
  );
  check(
    sameHex(buyTransfer.token, instantToken),
    "router buy delivered a different token",
  );
  check(
    sameHex(buyTransfer.from, poolManager),
    "router buy tokens did not come from PoolManager",
  );
  check(
    sameHex(buyTransfer.to, canarySender),
    "router buy tokens were not delivered to the canary sender",
  );
  check(
    asBigInt(buyTransfer.value) >= spec.buyMinTokensOut,
    "router buy delivery missed its bound",
  );
  check(
    asBigInt(buyTransfer.value) === asBigInt(buyEvent.amountOut),
    "router buy SwapExecuted output does not match the delivered transfer",
  );

  // ---------------------------------------------------------------- auction lane
  const aLaunch = auction.launch;
  check(
    sameHex(aLaunch.calldata.intentId, spec.auctionIntentId),
    "auction launch intent is wrong",
  );
  check(
    Number(aLaunch.calldata.quote) === spec.quote.eth,
    "auction launch quote is not ETH",
  );
  check(
    asBigInt(aLaunch.calldata.floorFdvWei) === spec.floorFdvWei,
    "auction launch floor FDV is not 0.02 ether",
  );
  check(
    asBigInt(aLaunch.calldata.raiseFloorWei) === spec.raiseFloorWei,
    "auction launch raise floor is not 0.01 ether",
  );
  check(
    Number(aLaunch.calldata.reserveBps) === spec.reserveBps,
    "auction launch reserve is not 2000 bps",
  );
  checkLaunchArgs(
    aLaunch.calldata.args,
    {
      name: spec.auctionName,
      symbol: spec.auctionSymbol,
      hookParams: spec.auctionHookParams,
    },
    canarySender,
    "auction launch",
  );
  check(
    asBigInt(aLaunch.transaction.value) === spec.creationFeeWei,
    "auction launch value is not the creation fee",
  );

  checkTokenLaunchedEvent(
    aLaunch.tokenEvent,
    { name: spec.auctionName, symbol: spec.auctionSymbol },
    canarySender,
    spec.launchMode.bonded,
    "auction launch",
  );
  const auctionToken = aLaunch.tokenEvent.token;
  check(
    !sameHex(auctionToken, instantToken),
    "auction launch reused the instant token",
  );

  const started = aLaunch.startedEvent;
  check(
    sameHex(started.token, auctionToken),
    "AuctionStarted names a different token",
  );
  check(
    asBigInt(started.floorFdvWei) === spec.floorFdvWei,
    "AuctionStarted floor FDV is wrong",
  );
  check(
    asBigInt(started.raiseFloorWei) === spec.raiseFloorWei,
    "AuctionStarted raise floor is wrong",
  );
  check(
    Number(started.reserveBps) === spec.reserveBps,
    "AuctionStarted reserve is wrong",
  );
  check(
    asBigInt(started.endBlock) ===
      asBigInt(aLaunch.transaction.blockNumber) +
        spec.canaryAuctionDurationBlocks,
    "AuctionStarted end block is not the mined launch block plus 20000",
  );

  const auctionConfig = postconditions.auctionConfig;
  check(
    auctionConfig && typeof auctionConfig === "object",
    "auction has no pinned CCA config readback",
  );
  check(
    sameHex(auctionConfig.currency, ZERO_ADDRESS),
    "CCA currency is not native ETH",
  );
  check(
    sameHex(auctionConfig.token, auctionToken),
    "CCA token is not the launched auction token",
  );
  check(
    asBigInt(auctionConfig.totalSupply) === spec.auctionSupply,
    "CCA total supply is wrong",
  );
  check(
    sameHex(auctionConfig.tokensRecipient, launchpad),
    "CCA tokens recipient is not the launchpad",
  );
  check(
    sameHex(auctionConfig.fundsRecipient, launchpad),
    "CCA funds recipient is not the launchpad",
  );
  check(
    sameHex(auctionConfig.validationHook, ZERO_ADDRESS),
    "CCA validation hook is not empty",
  );
  check(auctionConfig.isGraduated === true, "CCA did not graduate");
  check(
    asBigInt(auctionConfig.startBlock) ===
      asBigInt(aLaunch.transaction.blockNumber),
    "CCA start block does not equal the auction launch receipt block",
  );
  check(
    asBigInt(auctionConfig.endBlock) === asBigInt(started.endBlock),
    "CCA end block does not equal AuctionStarted",
  );
  check(
    asBigInt(auctionConfig.claimBlock) ===
      asBigInt(started.endBlock) + spec.claimDelayBlocks,
    "CCA claim block is wrong",
  );

  const bid = auction.bid;
  check(
    asBigInt(bid.transaction.value) === spec.bidWei,
    "auction bid value is not 0.0105 ether",
  );
  check(
    asBigInt(bid.calldata.maxPriceQ96) === spec.bidMaxPriceQ96,
    "auction bid max price is wrong",
  );
  check(
    asBigInt(bid.calldata.amount) === spec.bidWei,
    "auction bid amount is wrong",
  );
  check(
    sameHex(bid.calldata.owner, canarySender),
    "auction bid owner is wrong",
  );
  check(bid.calldata.hookData === "0x", "auction bid hook data is not empty");
  const bidEvent = bid.event;
  check(
    bidEvent && typeof bidEvent === "object",
    "auction bid has no BidSubmitted evidence",
  );
  check(
    asBigInt(bidEvent.id) === asBigInt(bid.bidId),
    "BidSubmitted id does not match the canary bid",
  );
  check(sameHex(bidEvent.owner, canarySender), "BidSubmitted owner is wrong");
  check(
    asBigInt(bidEvent.priceQ96) === spec.bidMaxPriceQ96,
    "BidSubmitted price is wrong",
  );
  check(
    asBigInt(bidEvent.amount) === spec.bidWei,
    "BidSubmitted amount is wrong",
  );
  // The CCA rejects bids AT endBlock, so a mined bid must precede it.
  check(
    asBigInt(bid.transaction.blockNumber) < asBigInt(started.endBlock),
    "auction bid was not mined inside the auction window",
  );

  const auctionOutcome = postconditions.auctionOutcome;
  check(
    auctionOutcome && typeof auctionOutcome === "object",
    "auction has no pinned CCA outcome readback",
  );
  const rawFloorPriceQ96 = (spec.floorFdvWei << 96n) / spec.tokenSupply;
  const tickSpacingQ96 =
    rawFloorPriceQ96 / 100n < 2n ? 2n : rawFloorPriceQ96 / 100n;
  const alignedFloorPriceQ96 =
    (rawFloorPriceQ96 / tickSpacingQ96) * tickSpacingQ96;
  const clearingPriceQ96 = asBigInt(auctionOutcome.initialPriceX96);
  check(
    clearingPriceQ96 >= alignedFloorPriceQ96,
    "CCA clearing outcome is below the aligned launch floor",
  );
  check(
    clearingPriceQ96 <= spec.bidMaxPriceQ96,
    "CCA clearing outcome exceeds the canary bid cap",
  );
  // `lbpInitializationParams().currencyRaised` is NET of the protocol fee quoted at read time.
  // That fee can change after migration, so a later LBP read is neither the historical swept net
  // amount nor the gross figure the CCA uses to graduate. The gross getter is stable after the end
  // checkpoint and, together with isGraduated above, binds the numerical graduation threshold.
  const grossCurrencyRaised = asBigInt(auctionOutcome.currencyRaisedGross);
  check(
    grossCurrencyRaised >= spec.raiseFloorWei,
    "CCA gross raise did not meet the graduation raise floor",
  );
  const netCurrencyRaisedAtRead = asBigInt(
    auctionOutcome.currencyRaisedNetAtRead,
  );
  check(
    netCurrencyRaisedAtRead <= grossCurrencyRaised,
    "CCA later net-at-read raise exceeds its gross raise",
  );
  check(
    asBigInt(auctionOutcome.tokensSold) > 0n &&
      asBigInt(auctionOutcome.tokensSold) <= spec.auctionSupply,
    "CCA outcome reports an invalid sold-token amount",
  );
  const clearingOpenPriceWei = (clearingPriceQ96 * 10n ** 18n) / Q96;
  check(
    clearingOpenPriceWei > 0n,
    "CCA clearing outcome rounds to a zero opening price",
  );
  const clearingSqrtPriceX96 = integerSqrt(
    ((10n ** 18n) << 192n) / clearingOpenPriceWei,
  );
  check(
    clearingSqrtPriceX96 > 0n,
    "CCA clearing outcome derives a zero sqrt price",
  );

  const migrate = auction.migrate;
  check(
    asBigInt(migrate.transaction.blockNumber) > asBigInt(started.endBlock),
    "auction migrate was not mined after the auction window closed",
  );
  const migrated = migrate.migratedEvent;
  check(
    migrated && typeof migrated === "object",
    "auction migrate has no Migrated evidence",
  );
  const migrateReceipt = phaseBRecord("canary:auction-migrate").record;
  const migratedLogIndex = bindEventToReceipt(
    migrated,
    migrateReceipt,
    "Migrated",
  );
  check(
    sameHex(migrated.token, auctionToken),
    "Migrated names a different token",
  );
  check(!sameHex(migrated.poolId, ZERO_BYTES32), "Migrated pool id is zero");
  check(
    sameHex(
      poolIdForKey(canonicalPoolKey(ZERO_ADDRESS, auctionToken, hook)),
      migrated.poolId,
    ),
    "Migrated pool id does not derive from the canonical auction pool key",
  );
  check(
    !sameHex(migrated.poolId, instantPoolId),
    "Migrated reused the instant pool",
  );
  check(
    asBigInt(migrated.sqrtPriceX96) === clearingSqrtPriceX96,
    "Migrated sqrt price does not derive from the CCA clearing outcome",
  );
  check(
    asBigInt(migrated.ethLiquidity) > 0n,
    "Migrated locked no ETH liquidity",
  );
  check(
    asBigInt(migrated.tokenLiquidity) > 0n,
    "Migrated locked no token liquidity",
  );
  const reservedTokens = (spec.tokenSupply * asBigInt(spec.reserveBps)) / BPS;
  check(
    asBigInt(migrated.tokenLiquidity) + asBigInt(migrated.tokensBurned) ===
      reservedTokens,
    "Migrated token liquidity and burned reserve do not conserve the configured reserve",
  );

  const auctionInitialize = migrate.initializeEvent;
  check(
    auctionInitialize && typeof auctionInitialize === "object",
    "auction migrate has no PoolManager Initialize evidence",
  );
  const initializeLogIndex = bindEventToReceipt(
    auctionInitialize,
    migrateReceipt,
    "auction PoolManager Initialize",
  );
  check(
    sameHex(auctionInitialize.id, migrated.poolId),
    "auction Initialize names the wrong pool",
  );
  check(
    sameHex(auctionInitialize.currency0, ZERO_ADDRESS),
    "auction Initialize currency0 is not native",
  );
  check(
    sameHex(auctionInitialize.currency1, auctionToken),
    "auction Initialize currency1 is wrong",
  );
  check(
    Number(auctionInitialize.fee) === spec.dynamicFee,
    "auction Initialize fee is not dynamic",
  );
  check(
    Number(auctionInitialize.tickSpacing) === spec.tickSpacing,
    "auction Initialize tick spacing is wrong",
  );
  check(
    sameHex(auctionInitialize.hooks, hook),
    "auction Initialize hook does not match the release",
  );
  check(
    asBigInt(auctionInitialize.sqrtPriceX96) ===
      asBigInt(migrated.sqrtPriceX96),
    "auction Initialize sqrt price does not match Migrated",
  );

  const proceedsClaim = auction.proceedsClaim;
  check(
    proceedsClaim && typeof proceedsClaim === "object",
    "auction proceeds claim evidence is missing",
  );
  const proceedsMode = proceedsClaim.calldata?.call;
  const proceedsNotApplicable = proceedsMode === NOT_APPLICABLE_ZERO_PROCEEDS;
  const proceeds = migrate.proceedsEvent;
  let auctionProceedsLogIndex;
  if (proceedsNotApplicable) {
    check(
      proceedsClaim.calldata?.mode === NOT_APPLICABLE_ZERO_PROCEEDS,
      "zero-proceeds claim mode is wrong",
    );
    check(
      proceeds === null,
      "zero-proceeds migration must not contain AuctionProceeds evidence",
    );
  } else {
    check(
      proceeds && typeof proceeds === "object",
      "auction migrate has no AuctionProceeds evidence",
    );
    auctionProceedsLogIndex = bindEventToReceipt(
      proceeds,
      migrateReceipt,
      "AuctionProceeds",
    );
    check(
      sameHex(proceeds.token, auctionToken),
      "AuctionProceeds names a different token",
    );
    check(
      sameHex(proceeds.creator, canarySender),
      "AuctionProceeds creator is not the canary sender",
    );
    check(
      asBigInt(proceeds.amountWei) > 0n,
      "auction migration credited no creator proceeds",
    );
  }
  const currencySwept = migrate.currencySweptEvent;
  check(
    currencySwept && typeof currencySwept === "object",
    "auction migrate has no receipt-local CurrencySwept evidence",
  );
  const currencySweptLogIndex = bindEventToReceipt(
    currencySwept,
    migrateReceipt,
    "CurrencySwept",
  );
  check(
    sameHex(currencySwept.fundsRecipient, launchpad),
    "CurrencySwept funds recipient is not the launchpad",
  );
  check(
    asBigInt(currencySwept.currencyAmount) > 0n,
    "CurrencySwept transferred no currency",
  );
  check(
    asBigInt(currencySwept.currencyAmount) <= grossCurrencyRaised,
    "receipt-local CurrencySwept amount exceeds the CCA gross raise",
  );
  if (proceedsNotApplicable) {
    check(
      asBigInt(migrated.ethLiquidity) ===
        asBigInt(currencySwept.currencyAmount),
      "zero-proceeds migration liquidity does not equal the receipt-local CCA sweep",
    );
    check(
      currencySweptLogIndex < initializeLogIndex &&
        initializeLogIndex < migratedLogIndex,
      "zero-proceeds auction migration events are not in protocol order",
    );
  } else {
    check(
      asBigInt(migrated.ethLiquidity) + asBigInt(proceeds.amountWei) ===
        asBigInt(currencySwept.currencyAmount),
      "migration liquidity and proceeds do not conserve the receipt-local CCA sweep",
    );
    check(
      currencySweptLogIndex < initializeLogIndex &&
        initializeLogIndex < auctionProceedsLogIndex &&
        auctionProceedsLogIndex < migratedLogIndex,
      "auction migration events are not in protocol order",
    );
  }

  const claimCall = auction.claimTokens.calldata.call;
  check(
    claimCall === "claimTokens" ||
      claimCall === "claimTokensBatch" ||
      claimCall === "nested",
    "auction claim does not identify a reviewed claim entrypoint",
  );
  const exitEvent = auction.exit.event;
  check(
    exitEvent && typeof exitEvent === "object",
    "auction exit has no BidExited evidence",
  );
  const exitReceipt = phaseBRecord("canary:auction-exit").record;
  const exitLogIndex = bindEventToReceipt(exitEvent, exitReceipt, "BidExited");
  check(
    asBigInt(exitEvent.bidId) === asBigInt(bid.bidId),
    "BidExited id is not the canary bid",
  );
  check(
    sameHex(exitEvent.owner, canarySender),
    "BidExited owner is not the canary sender",
  );
  check(asBigInt(exitEvent.tokensFilled) > 0n, "BidExited filled no tokens");
  check(
    asBigInt(exitEvent.tokensFilled) <= asBigInt(auctionOutcome.tokensSold),
    "canary bid fill exceeds the CCA sold-token outcome",
  );
  check(
    asBigInt(exitEvent.currencyRefunded) <= spec.bidWei,
    "BidExited refunded more than the bid",
  );

  const claimReceipt = phaseBRecord("canary:auction-claim").record;
  const claimEvents = auction.claimTokens.events;
  check(
    Array.isArray(claimEvents) && claimEvents.length > 0,
    "auction claim has no TokensClaimed event set",
  );
  for (const [index, event] of claimEvents.entries()) {
    bindEventToReceipt(event, claimReceipt, `TokensClaimed #${index}`);
    check(
      sameHex(event.owner, canarySender),
      `TokensClaimed #${index} owner is not the canary sender`,
    );
    check(
      asBigInt(event.tokensFilled) >= 0n,
      `TokensClaimed #${index} amount is negative`,
    );
  }
  const positiveCanaryEvents = claimEvents.filter(
    (event) =>
      asBigInt(event.bidId) === asBigInt(bid.bidId) &&
      sameHex(event.owner, canarySender) &&
      asBigInt(event.tokensFilled) > 0n,
  );
  check(
    positiveCanaryEvents.length === 1,
    `auction claim has ${positiveCanaryEvents.length} positive canary TokensClaimed events, expected one`,
  );
  const tokensClaimedEvent = positiveCanaryEvents[0];
  check(
    auction.claimTokens.event && typeof auction.claimTokens.event === "object",
    "auction claim has no selected TokensClaimed evidence",
  );
  check(
    asBigInt(tokensClaimedEvent.bidId) === asBigInt(bid.bidId),
    "TokensClaimed id is not the canary bid",
  );
  check(
    sameHex(tokensClaimedEvent.owner, canarySender),
    "TokensClaimed owner is not the canary sender",
  );
  check(
    asBigInt(tokensClaimedEvent.tokensFilled) ===
      asBigInt(exitEvent.tokensFilled),
    "TokensClaimed amount does not match BidExited",
  );
  check(
    asBigInt(auction.claimTokens.event.bidId) ===
      asBigInt(tokensClaimedEvent.bidId) &&
      sameHex(auction.claimTokens.event.owner, tokensClaimedEvent.owner) &&
      asBigInt(auction.claimTokens.event.tokensFilled) ===
        asBigInt(tokensClaimedEvent.tokensFilled) &&
      asBigInt(auction.claimTokens.event.logIndex) ===
        asBigInt(tokensClaimedEvent.logIndex) &&
      sameHex(
        auction.claimTokens.event.transactionHash,
        tokensClaimedEvent.transactionHash,
      ),
    "selected TokensClaimed evidence is not the unique positive canary event",
  );

  if (claimCall !== "nested") {
    const requestedBidIds = auction.claimTokens.calldata.requestedBidIds;
    check(
      Array.isArray(requestedBidIds) && requestedBidIds.length > 0,
      "direct auction claim has no decoded bid ids",
    );
    const requested = new Set(
      requestedBidIds.map((id) => asBigInt(id).toString()),
    );
    check(
      requested.has(asBigInt(bid.bidId).toString()),
      "direct auction claim does not request the canary bid",
    );
    const emitted = new Set();
    for (const event of claimEvents) {
      const emittedBidId = asBigInt(event.bidId).toString();
      check(
        requested.has(emittedBidId),
        "direct auction claim emitted a bid absent from calldata",
      );
      check(
        !emitted.has(emittedBidId),
        "direct auction claim emitted duplicate TokensClaimed bid ids",
      );
      emitted.add(emittedBidId);
    }
    if (claimCall === "claimTokens") {
      check(
        requestedBidIds.length === 1,
        "claimTokens decoded more than one bid id",
      );
    }
  }

  const sameClaimReceipt = sameHex(exitReceipt.hash, claimReceipt.hash);
  check(
    sameClaimReceipt
      ? exitLogIndex < eventLogIndex(tokensClaimedEvent, "TokensClaimed")
      : receiptCoordinateCompare(exitReceipt, claimReceipt) < 0,
    "auction exit was not mined before token claim",
  );

  const claimTransfer = auction.claimTokens.transferEvent;
  check(
    claimTransfer && typeof claimTransfer === "object",
    "auction claim has no token Transfer evidence",
  );
  check(
    sameHex(claimTransfer.token, auctionToken),
    "auction claim delivered a different token",
  );
  check(
    sameHex(claimTransfer.from, auctionAddress),
    "auction claim tokens did not come from the CCA",
  );
  check(
    sameHex(claimTransfer.to, canarySender),
    "auction claim tokens were not delivered to the canary sender",
  );
  check(
    asBigInt(claimTransfer.value) > 0n,
    "auction claim delivered no tokens",
  );
  const claimedSum = claimEvents.reduce(
    (sum, event) => sum + asBigInt(event.tokensFilled),
    0n,
  );
  check(
    asBigInt(claimTransfer.value) === claimedSum,
    "auction claim aggregate transfer does not equal the sum of TokensClaimed events",
  );
  const transferCount = Number(auction.claimTokens.transferCount);
  check(
    Number.isSafeInteger(transferCount) && transferCount > 0,
    "auction claim has no aggregate Transfer logs",
  );
  check(
    claimCall === "nested" || transferCount === 1,
    "direct auction claim did not emit exactly one aggregate Transfer",
  );
  check(
    Array.isArray(auction.claimTokens.transferLogIndexes) &&
      auction.claimTokens.transferLogIndexes.length === transferCount,
    "auction claim Transfer log-index evidence is incomplete",
  );

  const claimEvent = proceedsClaim.claimEvent;
  const proceedsReceipt = phaseBRecord("canary:auction-proceeds").record;
  check(
    asBigInt(postconditions.auctionCreatorProceedsWei) === 0n,
    "auction creator proceeds ledger was not cleared",
  );
  if (proceedsNotApplicable) {
    check(
      claimEvent === null,
      "zero-proceeds proof must not contain CreatorFeesClaimed evidence",
    );
    check(
      sameHex(migrateReceipt.hash, proceedsReceipt.hash),
      "zero-proceeds proof does not alias the exact migration receipt",
    );
    for (const field of [
      "from",
      "to",
      "value",
      "nonce",
      "blockNumber",
      "contractBlockNumber",
      "blockTimestamp",
    ]) {
      const left = migrate.transaction[field];
      const right = proceedsClaim.transaction[field];
      check(
        left === undefined ||
          left === null ||
          right === undefined ||
          right === null
          ? left === right
          : typeof left === "string" && typeof right === "string"
            ? sameHex(left, right)
            : asBigInt(left) === asBigInt(right),
        `zero-proceeds proof transaction ${field} differs from migration`,
      );
    }
    const notApplicable = proceedsClaim.notApplicable;
    check(
      notApplicable && typeof notApplicable === "object",
      "zero-proceeds proof metadata is missing",
    );
    check(
      notApplicable.mode === NOT_APPLICABLE_ZERO_PROCEEDS,
      "zero-proceeds proof mode is wrong",
    );
    check(
      notApplicable.executionMode === "not-applicable",
      "zero-proceeds proof execution mode is wrong",
    );
    check(
      sameHex(notApplicable.token, auctionToken),
      "zero-proceeds proof names a different token",
    );
    check(
      asBigInt(notApplicable.amountWei) === 0n,
      "zero-proceeds proof amount is not zero",
    );
    check(
      sameHex(notApplicable.proofTransactionHash, migrateReceipt.hash),
      "zero-proceeds proof transaction hash is not the migration receipt",
    );
  } else {
    check(
      claimEvent && typeof claimEvent === "object",
      "proceeds claim has no CreatorFeesClaimed evidence",
    );
    const creatorFeesLogIndex = bindEventToReceipt(
      claimEvent,
      proceedsReceipt,
      "CreatorFeesClaimed",
    );
    check(
      sameHex(claimEvent.token, auctionToken),
      "proceeds claim paid a different token's ledger",
    );
    check(
      sameHex(claimEvent.payTo, canarySender),
      "proceeds claim did not pay the canary sender",
    );
    // This auction token has one migration credit, so the payout must equal that receipt-local
    // AuctionProceeds amount even when an unrelated permissionless keeper submits the claim.
    check(
      asBigInt(claimEvent.amountWei) === asBigInt(proceeds.amountWei),
      "proceeds claim payout does not equal the migration's credited proceeds",
    );
    check(
      sameHex(migrateReceipt.hash, proceedsReceipt.hash)
        ? migratedLogIndex < creatorFeesLogIndex
        : receiptCoordinateCompare(migrateReceipt, proceedsReceipt) < 0,
      "auction migration was not mined before proceeds claim",
    );
  }

  // ---------------------------------------------------------------- HOOKR pair lane
  const hLaunch = hookr.launch;
  check(
    sameHex(hLaunch.calldata.intentId, spec.hookrIntentId),
    "hookr launch intent is wrong",
  );
  check(
    Number(hLaunch.calldata.quote) === spec.quote.hookr,
    "hookr launch quote is not HOOKR",
  );
  checkLaunchArgs(
    hLaunch.calldata.args,
    {
      name: spec.hookrName,
      symbol: spec.hookrSymbol,
      hookParams: spec.hookrHookParams,
    },
    canarySender,
    "hookr launch",
  );
  check(
    asBigInt(hLaunch.transaction.value) === spec.creationFeeWei,
    "hookr launch value is not the creation fee",
  );

  checkTokenLaunchedEvent(
    hLaunch.tokenEvent,
    { name: spec.hookrName, symbol: spec.hookrSymbol },
    canarySender,
    spec.launchMode.instant,
    "hookr launch",
  );
  const hookrPairToken = hLaunch.tokenEvent.token;
  check(
    !sameHex(hookrPairToken, instantToken),
    "hookr launch reused the instant token",
  );
  check(
    !sameHex(hookrPairToken, auctionToken),
    "hookr launch reused the auction token",
  );
  check(
    !sameHex(hookrPairToken, hookrToken),
    "hookr launch reused the HOOKR quote token",
  );
  // HOOKR-paired tokens are CREATE2-mined ABOVE the quote so HOOKR is always currency0 and the
  // hook's buy orientation carries over unchanged.
  check(
    BigInt(hookrPairToken) > BigInt(hookrToken),
    "hookr pair token was not mined above the HOOKR quote",
  );
  const hookrInstantEvent = hLaunch.instantEvent;
  check(
    sameHex(hookrInstantEvent.token, hookrPairToken),
    "hookr InstantLaunched names a different token",
  );
  check(
    !sameHex(hookrInstantEvent.poolId, ZERO_BYTES32),
    "hookr InstantLaunched pool id is zero",
  );
  const hookrPoolId = hookrInstantEvent.poolId;
  check(
    sameHex(
      poolIdForKey(canonicalPoolKey(hookrToken, hookrPairToken, hook)),
      hookrPoolId,
    ),
    "hookr InstantLaunched pool id does not derive from the canonical HOOKR pool key",
  );
  check(
    !sameHex(hookrPoolId, instantPoolId),
    "hookr launch reused the instant pool",
  );
  check(
    asBigInt(hookrInstantEvent.openPriceWei) > 0n,
    "hookr InstantLaunched open price is zero",
  );
  check(
    asBigInt(hookrInstantEvent.openPriceWei) ===
      asBigInt(postconditions.hookrInstantOpenPriceWei),
    "hookr InstantLaunched open price does not match the launchpad hookrInstantOpenPrice readback",
  );

  const hookrInitialize = hLaunch.initializeEvent;
  check(
    hookrInitialize && typeof hookrInitialize === "object",
    "hookr launch has no PoolManager Initialize evidence",
  );
  check(
    sameHex(hookrInitialize.id, hookrPoolId),
    "hookr Initialize names the wrong pool",
  );
  check(
    sameHex(hookrInitialize.currency0, hookrToken),
    "hookr Initialize currency0 is not the HOOKR token",
  );
  check(
    sameHex(hookrInitialize.currency1, hookrPairToken),
    "hookr Initialize currency1 is not the pair token",
  );
  check(
    Number(hookrInitialize.fee) === spec.dynamicFee,
    "hookr Initialize fee is not dynamic",
  );
  check(
    Number(hookrInitialize.tickSpacing) === spec.tickSpacing,
    "hookr Initialize tick spacing is wrong",
  );
  check(
    sameHex(hookrInitialize.hooks, hook),
    "hookr Initialize hook does not match the release",
  );
  check(
    asBigInt(hookrInitialize.sqrtPriceX96) > 0n,
    "hookr Initialize has no opening price",
  );

  const hookrRecord = postconditions.hookrLaunch;
  check(
    hookrRecord && typeof hookrRecord === "object",
    "hookr launch has no getLaunch readback",
  );
  check(
    sameHex(hookrRecord.token, hookrPairToken),
    "hookr getLaunch names a different token",
  );
  check(
    sameHex(hookrRecord.creator, canarySender),
    "hookr getLaunch creator is wrong",
  );
  check(
    Number(hookrRecord.mode) === spec.launchMode.instant,
    "hookr getLaunch mode is wrong",
  );
  check(
    Number(hookrRecord.status) === spec.launchStatus.live,
    "hookr getLaunch status is not Live",
  );
  check(
    Number(hookrRecord.quote) === spec.quote.hookr,
    "hookr getLaunch quote is not HOOKR",
  );
  check(
    sameHex(hookrRecord.poolId, hookrPoolId),
    "hookr getLaunch pool id is wrong",
  );
  check(
    asBigInt(hookrRecord.launchBlock) ===
      asBigInt(hLaunch.transaction.contractBlockNumber),
    "hookr getLaunch launch block does not match the launch receipt",
  );
  for (const [field, expected] of Object.entries(spec.hookrHookParams)) {
    check(
      asBigInt(hookrRecord.hookParams[field]) === asBigInt(expected),
      `hookr getLaunch hook parameter ${field} is wrong`,
    );
  }
  checkEffectivePoolConfig(postconditions.hookConfigs?.hookr, {
    label: "hookr",
    token: hookrPairToken,
    hookParams: spec.hookrHookParams,
    configuredAtBlock: hLaunch.transaction.contractBlockNumber,
    openPriceWei: hookrInstantEvent.openPriceWei,
    flywheelFeePips: 0n,
  });

  // The approve arms EXACTLY the router for EXACTLY the buy that follows.
  const hApprove = hookr.approve;
  check(
    sameHex(hApprove.calldata.spender, router),
    "hookr approve spender is not the release router",
  );
  check(
    asBigInt(hApprove.calldata.amount) === spec.hookrBuyAmount,
    "hookr approve amount is wrong",
  );
  check(
    asBigInt(hApprove.transaction.value) === 0n,
    "hookr approve must not send native value",
  );
  const approvalEvent = hApprove.event;
  check(
    approvalEvent && typeof approvalEvent === "object",
    "hookr approve has no Approval evidence",
  );
  check(
    sameHex(approvalEvent.owner, canarySender),
    "hookr Approval owner is not the canary sender",
  );
  check(
    sameHex(approvalEvent.spender, router),
    "hookr Approval spender is not the release router",
  );
  check(
    asBigInt(approvalEvent.value) === spec.hookrBuyAmount,
    "hookr Approval value is wrong",
  );

  const hBuy = hookr.buy;
  const hookrBuyKey = hBuy.calldata.key;
  check(
    sameHex(hookrBuyKey.currency0, hookrToken),
    "hookr buy key currency0 is not the HOOKR token",
  );
  check(
    sameHex(poolIdForKey(hookrBuyKey), hookrPoolId),
    "hookr buy pool key does not match the HOOKR pool id",
  );
  check(
    sameHex(hookrBuyKey.hooks, hook),
    "hookr buy hook does not match the release",
  );
  check(hBuy.calldata.zeroForOne === true, "hookr buy direction is wrong");
  check(
    asBigInt(hBuy.calldata.amountIn) === spec.hookrBuyAmount,
    "hookr buy input is wrong",
  );
  // An ERC-20 quote settles by transferFrom; the router pull is exact and pays no msg.value.
  check(
    asBigInt(hBuy.transaction.value) === 0n,
    "hookr buy must not send native value",
  );
  check(
    asBigInt(hBuy.calldata.amountOutMinimum) === spec.hookrBuyMinTokensOut,
    "hookr buy bound is wrong",
  );
  check(
    asBigInt(hBuy.calldata.sqrtPriceLimitX96) === spec.minSqrtPriceLimitX96,
    "hookr buy price limit is wrong",
  );
  check(
    sameHex(hBuy.calldata.recipient, canarySender),
    "hookr buy recipient is wrong",
  );
  const hookrBuyTimestamp = asBigInt(hBuy.transaction.blockTimestamp);
  const hookrBuyDeadline = asBigInt(hBuy.calldata.deadline);
  check(
    hookrBuyDeadline >= hookrBuyTimestamp &&
      hookrBuyDeadline <= hookrBuyTimestamp + spec.routerDeadlineSeconds,
    "hookr buy deadline is outside the mined timestamp plus 600-second bound",
  );
  const hookrLaunchBlock = asBigInt(hookrRecord.launchBlock);
  const hookrBuyContractBlock = asBigInt(hBuy.transaction.contractBlockNumber);
  check(
    hookrBuyContractBlock >= hookrLaunchBlock &&
      hookrBuyContractBlock <
        hookrLaunchBlock + asBigInt(spec.hookrHookParams.guardBlocks),
    "hookr buy was not mined inside the hookr guard window",
  );

  const hookrBuyEvent = hBuy.event;
  check(
    hookrBuyEvent && typeof hookrBuyEvent === "object",
    "hookr buy has no SwapExecuted evidence",
  );
  check(
    sameHex(hookrBuyEvent.payer, canarySender),
    "hookr buy SwapExecuted payer is wrong",
  );
  check(
    sameHex(hookrBuyEvent.recipient, canarySender),
    "hookr buy SwapExecuted recipient is wrong",
  );
  check(
    sameHex(hookrBuyEvent.token, hookrPairToken),
    "hookr buy SwapExecuted token is wrong",
  );
  check(
    hookrBuyEvent.zeroForOne === true,
    "hookr buy SwapExecuted direction is wrong",
  );
  check(
    hookrBuyEvent.exactInput === true,
    "hookr buy SwapExecuted is not exact-input",
  );
  check(
    asBigInt(hookrBuyEvent.amountIn) === spec.hookrBuyAmount,
    "hookr buy SwapExecuted input is wrong",
  );
  check(
    asBigInt(hookrBuyEvent.amountOut) >= spec.hookrBuyMinTokensOut,
    "hookr buy SwapExecuted output missed its bound",
  );

  const hookrPoolSwap = hBuy.poolManagerEvent;
  check(
    hookrPoolSwap && typeof hookrPoolSwap === "object",
    "hookr buy has no PoolManager Swap evidence",
  );
  check(
    sameHex(hookrPoolSwap.id, hookrPoolId),
    "hookr buy swap hit the wrong pool",
  );
  check(
    sameHex(hookrPoolSwap.sender, router),
    "hookr buy swap sender is not the release router",
  );
  checkGuardedSwap(hookrPoolSwap, spec.hookrHookParams, "hookr buy");

  const hookrBuyTransfer = hBuy.transferEvent;
  check(
    hookrBuyTransfer && typeof hookrBuyTransfer === "object",
    "hookr buy has no token Transfer evidence",
  );
  check(
    sameHex(hookrBuyTransfer.token, hookrPairToken),
    "hookr buy delivered a different token",
  );
  check(
    sameHex(hookrBuyTransfer.from, poolManager),
    "hookr buy tokens did not come from PoolManager",
  );
  check(
    sameHex(hookrBuyTransfer.to, canarySender),
    "hookr buy tokens were not delivered to the canary sender",
  );
  check(
    asBigInt(hookrBuyTransfer.value) >= spec.hookrBuyMinTokensOut,
    "hookr buy delivery missed its bound",
  );
  check(
    asBigInt(hookrBuyTransfer.value) === asBigInt(hookrBuyEvent.amountOut),
    "hookr buy SwapExecuted output does not match the delivered transfer",
  );
  check(
    asBigInt(postconditions.hookrAllowance) === 0n,
    "HOOKR allowance from the canary sender to the router was not consumed to zero",
  );

  // ---------------------------------------------------------------- flywheel round trip
  // collect() pulls the accrued 0.3% ETH-pair fee into the burner; its target and canonical
  // effects are proven by the burner's and hook's exact receipt events. A helper may have submitted
  // that permissionless call. The owner-only burn leg remains an exact direct transaction.
  const collected = flywheel.collect.event;
  check(
    collected && typeof collected === "object",
    "flywheel collect has no FlywheelCollected evidence",
  );
  const collectReceipt = phaseBRecord("canary:flywheel-collect").record;
  bindEventToReceipt(collected, collectReceipt, "FlywheelCollected");
  const hookClaimed = flywheel.collect.claimedEvent;
  check(
    hookClaimed && typeof hookClaimed === "object",
    "flywheel collect has no hook Claimed evidence",
  );
  bindEventToReceipt(hookClaimed, collectReceipt, "hook Claimed");
  check(
    sameHex(hookClaimed.account, burner),
    "hook Claimed account is not the burner",
  );
  check(
    asBigInt(hookClaimed.amountWei) === asBigInt(collected.amountWei),
    "hook Claimed amount does not equal FlywheelCollected",
  );
  // HookrHook.claim() reverts on a zero ledger, so a successful collect cannot be a no-op. Require
  // this receipt to pull at least the exact Phase-A fee that the receipt-local accrual proved.
  check(
    asBigInt(collected.amountWei) >= spec.flywheelEthIn,
    "flywheel collect did not pull at least the receipt-proven Phase-A accrual",
  );
  const burn = flywheel.burn;
  check(
    asBigInt(burn.transaction.value) === 0n,
    "flywheel burn must not send native value",
  );
  check(
    asBigInt(burn.calldata.ethIn) === spec.flywheelEthIn,
    "flywheel burn calldata spends the wrong ETH amount",
  );
  check(
    asBigInt(burn.calldata.minHookrOut) === spec.flywheelMinHookrOut,
    "flywheel burn does not carry the reviewed execution bound",
  );
  const burned = burn.burnedEvent;
  check(
    burned && typeof burned === "object",
    "flywheel burn has no BuybackBurned evidence",
  );
  const burnReceipt = phaseBRecord("canary:flywheel-burn").record;
  bindEventToReceipt(burned, burnReceipt, "BuybackBurned");
  check(
    sameHex(burned.caller, canarySender),
    "BuybackBurned caller is not the canary sender",
  );
  check(asBigInt(burned.ethIn) > 0n, "BuybackBurned spent no ETH");
  check(
    asBigInt(burned.ethIn) === asBigInt(burn.calldata.ethIn),
    "BuybackBurned ethIn does not match the calldata",
  );
  check(
    asBigInt(burned.hookrBurned) >= spec.flywheelMinHookrOut,
    "BuybackBurned output missed the reviewed minimum",
  );
  const deadTransfer = burn.deadTransferEvent;
  check(
    deadTransfer && typeof deadTransfer === "object",
    "flywheel burn has no dead-address HOOKR Transfer evidence",
  );
  bindEventToReceipt(
    deadTransfer,
    burnReceipt,
    "flywheel dead-address Transfer",
  );
  check(
    sameHex(deadTransfer.token, hookrToken),
    "flywheel burn dead transfer is not HOOKR",
  );
  check(
    sameHex(deadTransfer.from, burner),
    "flywheel burn HOOKR did not come from the burner",
  );
  check(
    sameHex(deadTransfer.to, DEAD_ADDRESS),
    "flywheel burn transfer is not to the dead address",
  );
  check(
    asBigInt(deadTransfer.value) === asBigInt(burned.hookrBurned),
    "flywheel dead transfer does not equal the burned amount",
  );

  // ---------------------------------------------------------------- pinned post-state
  const record = postconditions.auctionLaunch;
  check(
    sameHex(record.token, auctionToken),
    "auction launch record token is wrong",
  );
  check(
    sameHex(record.creator, canarySender),
    "auction launch record creator is wrong",
  );
  check(
    Number(record.mode) === spec.launchMode.bonded,
    "auction launch record mode is not Bonded",
  );
  check(
    Number(record.quote) === spec.quote.eth,
    "auction launch record quote is not ETH",
  );
  check(
    Number(record.status) === spec.launchStatus.live,
    "auction launch record status is not Live",
  );
  check(
    Number(record.reserveBps) === spec.reserveBps,
    "auction launch record reserve is wrong",
  );
  check(
    sameHex(record.auction, auctionAddress),
    "auction launch record names a different auction",
  );
  check(
    asBigInt(record.launchBlock) ===
      asBigInt(aLaunch.transaction.contractBlockNumber),
    "auction launch record block does not match the receipt l1BlockNumber",
  );
  check(
    asBigInt(record.auctionEndBlock) === asBigInt(started.endBlock),
    "auction launch record end block does not match AuctionStarted",
  );
  check(
    sameHex(record.poolId, migrated.poolId),
    "auction launch record pool does not match Migrated",
  );
  check(
    asBigInt(record.openPriceWei) === clearingOpenPriceWei,
    "auction launch record opening price does not derive from the CCA outcome",
  );
  check(
    asBigInt(record.sqrtPriceX96AtOpen) === asBigInt(migrated.sqrtPriceX96),
    "auction launch record opening sqrt price does not match Migrated",
  );
  check(
    asBigInt(record.migratedAtBlock) ===
      asBigInt(migrate.transaction.contractBlockNumber),
    "auction launch record migration block does not match the migration receipt",
  );
  for (const [field, expected] of Object.entries(spec.auctionHookParams)) {
    check(
      asBigInt(record.hookParams[field]) === asBigInt(expected),
      `auction getLaunch hook parameter ${field} is wrong`,
    );
  }
  checkEffectivePoolConfig(postconditions.hookConfigs?.auction, {
    label: "auction",
    token: auctionToken,
    hookParams: spec.auctionHookParams,
    configuredAtBlock: migrate.transaction.contractBlockNumber,
    openPriceWei: clearingOpenPriceWei,
    flywheelFeePips: spec.flywheelFeePips,
  });

  check(
    asBigInt(postconditions.auctionTiming.durationBlocks) ===
      spec.productionAuctionDurationBlocks &&
      asBigInt(postconditions.auctionTiming.claimDelay) ===
        spec.claimDelayBlocks &&
      asBigInt(postconditions.auctionTiming.migrationDelay) ===
        spec.migrationDelayBlocks,
    "final launchpad auction timing is not the production 125000/0/1 configuration",
  );

  return {
    instantToken,
    instantPoolId,
    auctionToken,
    auctionPoolId: migrated.poolId,
    auction: auctionAddress,
    hookrPairToken,
    hookrPoolId,
  };
}
