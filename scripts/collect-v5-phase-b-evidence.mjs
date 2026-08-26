#!/usr/bin/env node

import { createHash } from "node:crypto";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import {
  decodeEventLog,
  decodeFunctionData,
  decodeFunctionResult,
  encodeFunctionData,
  getAddress,
  parseAbi,
  parseAbiItem,
  toEventSelector,
  toHex,
  zeroAddress,
} from "viem";
import { createPublicClient, http } from "viem";

import { poolIdForKey } from "./lib/instant-canary-evidence.mjs";

export const PHASE_B_COLLECTOR_KIND = "hookr-v5-phase-b-collector-v1";
export const PHASE_B_EVIDENCE_KIND = "hookr-v5-phase-b-evidence-v1";

const CHAIN_ID = 4_663n;
const POOL_MANAGER = getAddress("0x8366a39CC670B4001A1121B8F6A443A643e40951");
const DEAD = getAddress("0x000000000000000000000000000000000000dEaD");
const DYNAMIC_FEE = 0x800000;
const TICK_SPACING = 60;
const MIGRATION_DELAY_BLOCKS = 1n;
const CANARY_FLYWHEEL_WEI = 3_000_000_000_000n;
const CANARY_MIN_HOOKR_OUT = 3n * 10n ** 18n;
const CANARY_BID_WEI = 10_500_000_000_000_000n;
const CANARY_RECOVERY_BID_MAX_PRICE_Q96 =
  814_814_390_533_794_434_497_901_791_991_308_996_217n;
const AUCTION_RESERVE_TOKENS = 200_000_000n * 10n ** 18n;
const PHASE_A_V2_KIND = "hookr-v5-phase-a-evidence-v2";
const PHASE_A_V3_KIND = "hookr-v5-phase-a-evidence-v3";
const PHASE_A_V3_POLICY =
  "four-unmodified-raw-forge-artifacts-plus-one-raw-owner-bid-and-two-raw-timing-transaction-pairs";
const DEFAULT_PHASE_A_INDEX =
  "contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/phase-a-evidence-v5.json";
const DEFAULT_LOG_CHUNK_BLOCKS = 2_000n;

const ACTIONS = Object.freeze([
  { key: "migrateAuction", slug: "migrate-auction" },
  { key: "exitBid", slug: "exit-bid" },
  { key: "claimTokens", slug: "claim-tokens" },
  { key: "claimAuctionProceeds", slug: "claim-auction-proceeds" },
  { key: "collect", slug: "collect" },
  { key: "buybackAndBurn", slug: "buyback-and-burn" },
]);
export const PHASE_B_ACTIONS = ACTIONS;

const LAUNCHPAD_ABI = parseAbi([
  "function migrateAuction(address token)",
  "function claimAuctionProceeds(address token)",
  "function creatorProceedsWei(address token) view returns (uint256)",
  "function getLaunch(address token) view returns ((address token,address creator,uint40 launchBlock,uint32 blueprintId,uint8 mode,uint8 status,uint96 openPriceWei,uint96 openFdvWei,uint16 reserveBps,address auction,uint40 auctionEndBlock,uint40 migratedAtBlock,uint160 sqrtPriceX96AtOpen,bytes32 poolId,uint8 quote,(uint32 guardBlocks,uint16 maxBuyBps,uint24 snipeTaxPips,uint24 baseFeePips,uint24 maxFeePips,uint16 surgeSens,uint16 burnBps,uint96 burnTriggerWei,uint16 lpBps,uint16 potBps,uint32 potEveryNBuys,uint96 potMinBuyWei) hookParams) launch)",
]);
const AUCTION_ABI = parseAbi([
  "function submitBid(uint256 maxPriceQ96,uint128 amount,address owner,bytes hookData) payable returns (uint256 bidId)",
  "function exitBid(uint256 bidId)",
  "function claimTokens(uint256 bidId)",
  "function claimTokensBatch(address owner,uint256[] bidIds)",
  "function bids(uint256 bidId) view returns ((uint64 startBlock,uint24 startCumulativeMps,uint64 exitedBlock,uint256 maxPrice,address owner,uint256 amountQ96,uint256 tokensFilled) bid)",
]);
const HOOK_ABI = parseAbi([
  "function flywheelRecipient() view returns (address)",
  "function claimableWei(address account) view returns (uint256)",
]);
const BURNER_ABI = parseAbi([
  "function owner() view returns (address)",
  "function collect()",
  "function buybackAndBurn(uint256 ethIn,uint256 minHookrOut) returns (uint256 burned)",
  "function totalEthSpent() view returns (uint256)",
  "function totalHookrBurned() view returns (uint256)",
  "function lastBuybackBlock() view returns (uint40)",
]);

const EVENTS = Object.freeze({
  migrated: parseAbiItem(
    "event Migrated(address indexed token,bytes32 indexed poolId,uint160 sqrtPriceX96,uint256 ethLiquidity,uint256 tokenLiquidity,uint256 tokensBurned)",
  ),
  auctionProceeds: parseAbiItem(
    "event AuctionProceeds(address indexed token,address indexed creator,uint256 amountWei)",
  ),
  currencySwept: parseAbiItem(
    "event CurrencySwept(address indexed fundsRecipient,uint256 currencyAmount)",
  ),
  initialize: parseAbiItem(
    "event Initialize(bytes32 indexed id,address indexed currency0,address indexed currency1,uint24 fee,int24 tickSpacing,address hooks,uint160 sqrtPriceX96,int24 tick)",
  ),
  bidExited: parseAbiItem(
    "event BidExited(uint256 indexed bidId,address indexed owner,uint256 tokensFilled,uint256 currencyRefunded)",
  ),
  tokensClaimed: parseAbiItem(
    "event TokensClaimed(uint256 indexed bidId,address indexed owner,uint256 tokensFilled)",
  ),
  creatorFeesClaimed: parseAbiItem(
    "event CreatorFeesClaimed(address indexed token,address indexed payTo,uint256 amountWei)",
  ),
  flywheelFeeAccrued: parseAbiItem(
    "event FlywheelFeeAccrued(bytes32 indexed poolId,uint256 amountWei)",
  ),
  claimed: parseAbiItem(
    "event Claimed(address indexed account,uint256 amountWei)",
  ),
  flywheelCollected: parseAbiItem("event FlywheelCollected(uint256 amountWei)"),
  buybackBurned: parseAbiItem(
    "event BuybackBurned(address indexed caller,uint256 ethIn,uint256 hookrBurned)",
  ),
  balanceMigrated: parseAbiItem(
    "event BalanceMigrated(address indexed to,uint256 amountWei)",
  ),
  transfer: parseAbiItem(
    "event Transfer(address indexed from,address indexed to,uint256 value)",
  ),
});
const TOPICS = Object.freeze(
  Object.fromEntries(
    Object.entries(EVENTS).map(([key, event]) => [key, toEventSelector(event)]),
  ),
);

const HASH_RE = /^0x[0-9a-fA-F]{64}$/;
const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const SHA256_RE = /^[0-9a-fA-F]{64}$/;
const sameHex = (left, right) =>
  typeof left === "string" &&
  typeof right === "string" &&
  left.toLowerCase() === right.toLowerCase();
const check = (condition, message) => {
  if (!condition) throw new Error(message);
};
const bigint = (value, label) => {
  try {
    return BigInt(value);
  } catch {
    throw new Error(`${label} is not an integer`);
  }
};
const address = (value, label) => {
  check(
    typeof value === "string" && ADDRESS_RE.test(value),
    `${label} is not an address`,
  );
  return getAddress(value);
};
const hash32 = (value, label) => {
  check(
    typeof value === "string" && HASH_RE.test(value),
    `${label} is not bytes32`,
  );
  return value.toLowerCase();
};
const sourceCommit = (value, label) => {
  check(
    typeof value === "string" && /^[0-9a-fA-F]{40}$/.test(value),
    `${label} is not a full source commit`,
  );
  return value.toLowerCase();
};
const sha256 = (value, label) => {
  check(
    typeof value === "string" && SHA256_RE.test(value),
    `${label} is not SHA-256`,
  );
  return value.toLowerCase();
};
const evidencePath = (value, label) => {
  check(
    typeof value === "string" && value.length > 0,
    `${label} path is missing`,
  );
  check(
    !value.startsWith("/") && !value.split("/").includes(".."),
    `${label} path is not repository-relative`,
  );
  return value;
};
const topicAddress = (value) =>
  `0x${address(value, "topic address").slice(2).toLowerCase().padStart(64, "0")}`;
const topicUint = (value) => toHex(bigint(value, "topic uint"), { size: 32 });
const quantity = (value) => toHex(bigint(value, "quantity"));
const jsonSafe = (value) => {
  if (typeof value === "bigint") return value.toString();
  if (Array.isArray(value)) return value.map(jsonSafe);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([key, item]) => [key, jsonSafe(item)]),
    );
  }
  return value;
};
const stableJson = (value) => `${JSON.stringify(jsonSafe(value), null, 2)}\n`;
const sha256Bytes = (value) => createHash("sha256").update(value).digest("hex");
const position = (log) => ({
  blockNumber: bigint(log.blockNumber, "log blockNumber"),
  transactionIndex: bigint(log.transactionIndex, "log transactionIndex"),
  logIndex: bigint(log.logIndex, "logIndex"),
});
const comparePosition = (left, right) =>
  left.blockNumber === right.blockNumber
    ? left.transactionIndex === right.transactionIndex
      ? left.logIndex < right.logIndex
        ? -1
        : left.logIndex > right.logIndex
          ? 1
          : 0
      : left.transactionIndex < right.transactionIndex
        ? -1
        : 1
    : left.blockNumber < right.blockNumber
      ? -1
      : 1;
const isAfter = (candidate, boundary) =>
  comparePosition(position(candidate), boundary) > 0;
const tupleField = (tuple, name, index) => tuple?.[name] ?? tuple?.[index];

/** Redact the configured RPC and stable secret-bearing URL components from every fatal path. */
export function redactRpcMessage(message, configuredRpc) {
  const raw = String(configuredRpc ?? "");
  const patterns = new Set();
  if (raw) {
    for (const candidate of [
      raw,
      encodeURI(raw),
      encodeURIComponent(raw),
      JSON.stringify(raw).slice(1, -1),
    ]) {
      if (candidate.length >= 8) patterns.add(candidate);
    }
    try {
      const url = new URL(raw);
      for (const candidate of [
        url.hostname,
        url.username,
        url.password,
        ...url.pathname.split("/"),
        ...url.searchParams.values(),
      ]) {
        if (candidate.length >= 8) patterns.add(candidate);
      }
    } catch {
      // The exact configured spelling is still covered.
    }
  }
  return [...patterns]
    .sort((left, right) => right.length - left.length)
    .reduce(
      (redacted, pattern) => redacted.split(pattern).join("<configured RPC>"),
      String(message),
    );
}
const readJson = (file) => JSON.parse(readFileSync(file, "utf8"));

const V3_SEQUENCE = Object.freeze([
  ["forge", "instantLaunch", 0, "launchInstant"],
  ["timing", "shorten", 0, "setAuctionTiming"],
  ["forge", "instantBuyAuctionLaunch", 0, "exactInput"],
  ["forge", "instantBuyAuctionLaunch", 1, "launchAuction"],
  ["timing", "restore", 0, "setAuctionTiming"],
  ["raw", "ownerBid", 0, "submitBid"],
  ["forge", "hookrLaunch", 0, "launchInstant"],
  ["forge", "hookrApproveBuy", 0, "approve"],
  ["forge", "hookrApproveBuy", 1, "exactInput"],
]);

const validateRawPairMetadata = (metadata, label) => ({
  transactionPath: evidencePath(
    metadata?.transactionPath,
    `${label} transaction`,
  ),
  transactionSha256: sha256(
    metadata?.transactionSha256,
    `${label} transaction`,
  ),
  receiptPath: evidencePath(metadata?.receiptPath, `${label} receipt`),
  receiptSha256: sha256(metadata?.receiptSha256, `${label} receipt`),
});

const validateV3ForgeMetadata = (
  metadata,
  label,
  expectedCommit,
  transactions,
) => {
  const commit = String(metadata?.commit ?? "").toLowerCase();
  check(
    commit.length >= 7 && expectedCommit.startsWith(commit),
    `${label} commit is not its reviewed lineage`,
  );
  check(
    Number(metadata?.transactions) === transactions,
    `${label} transaction count is wrong`,
  );
  check(
    Number(metadata?.receipts) === transactions,
    `${label} receipt count is wrong`,
  );
  check(Number(metadata?.pending) === 0, `${label} has pending receipts`);
  return {
    path: evidencePath(metadata?.path, label),
    sha256: sha256(metadata?.sha256, label),
    commit,
    transactions,
    receipts: transactions,
    pending: 0,
  };
};

const normalizedSequenceRecord = (item, expected, sequence, owner) => {
  const [kind, artifact, artifactIndex, functionName] = expected;
  check(
    bigint(item?.sequence, `phase A transaction #${sequence} sequence`) ===
      BigInt(sequence),
    `phase A transaction #${sequence} sequence is wrong`,
  );
  check(
    item?.kind === kind,
    `phase A transaction #${sequence} kind is not ${kind}`,
  );
  check(
    item?.artifact === artifact,
    `phase A transaction #${sequence} artifact is not ${artifact}`,
  );
  check(
    Number(item?.artifactIndex) === artifactIndex,
    `phase A transaction #${sequence} artifact index is wrong`,
  );
  check(
    item?.function === functionName,
    `phase A transaction #${sequence} function is not ${functionName}`,
  );
  const normalized = {
    ...item,
    hash: hash32(item?.hash, `phase A transaction #${sequence} hash`),
    nonce: bigint(item?.nonce, `phase A transaction #${sequence} nonce`),
    from: address(item?.from, `phase A transaction #${sequence} sender`),
    to: address(item?.to, `phase A transaction #${sequence} target`),
    value: bigint(item?.value, `phase A transaction #${sequence} value`),
    receipt: {
      transactionHash: hash32(
        item?.receipt?.transactionHash,
        `phase A transaction #${sequence} receipt hash`,
      ),
      status: bigint(
        item?.receipt?.status,
        `phase A transaction #${sequence} receipt status`,
      ),
      blockNumber: bigint(
        item?.receipt?.blockNumber,
        `phase A transaction #${sequence} receipt block`,
      ),
      blockHash: hash32(
        item?.receipt?.blockHash,
        `phase A transaction #${sequence} block hash`,
      ),
      transactionIndex: bigint(
        item?.receipt?.transactionIndex,
        `phase A transaction #${sequence} receipt index`,
      ),
    },
  };
  check(
    typeof item?.calldata === "string" &&
      /^0x(?:[0-9a-fA-F]{2})+$/.test(item.calldata),
    `phase A transaction #${sequence} calldata is not bytes`,
  );
  check(
    sameHex(normalized.from, owner),
    `phase A transaction #${sequence} sender is not the Phase-A owner`,
  );
  check(
    sameHex(normalized.hash, normalized.receipt.transactionHash),
    `phase A transaction #${sequence} hash differs from its receipt`,
  );
  check(
    normalized.receipt.status === 1n,
    `phase A transaction #${sequence} did not succeed`,
  );
  return normalized;
};

const validateV3Provenance = (index, identities, sequence) => {
  check(
    index.evidencePolicy === PHASE_A_V3_POLICY,
    "phase A v3 evidence policy is wrong",
  );
  const deploymentSourceCommit = sourceCommit(
    index.deploymentSourceCommit,
    "phase A deployment source commit",
  );
  const originalCanaryOperatorCommit = sourceCommit(
    index.originalCanaryOperatorCommit,
    "phase A original canary operator commit",
  );
  const canaryRecoveryCommit = sourceCommit(
    index.canaryRecoveryCommit,
    "phase A canary recovery commit",
  );
  check(
    originalCanaryOperatorCommit !== canaryRecoveryCommit,
    "phase A canary recovery commit is not distinct from the original operator",
  );

  const forge = index.rawForgeArtifacts ?? {};
  validateV3ForgeMetadata(
    forge.instantLaunch,
    "phase A instant-launch artifact",
    originalCanaryOperatorCommit,
    1,
  );
  validateV3ForgeMetadata(
    forge.instantBuyAuctionLaunch,
    "phase A instant-buy/auction-launch artifact",
    originalCanaryOperatorCommit,
    2,
  );
  validateV3ForgeMetadata(
    forge.hookrLaunch,
    "phase A HOOKR-launch artifact",
    canaryRecoveryCommit,
    1,
  );
  validateV3ForgeMetadata(
    forge.hookrApproveBuy,
    "phase A HOOKR-approve/buy artifact",
    canaryRecoveryCommit,
    2,
  );
  const rawOwnerBidEvidence = validateRawPairMetadata(
    index.rawOwnerBidEvidence,
    "phase A owner-bid evidence",
  );
  const rawTimingEvidence = {
    shorten: validateRawPairMetadata(
      index.rawTimingEvidence?.shorten,
      "phase A timing-shorten evidence",
    ),
    restore: validateRawPairMetadata(
      index.rawTimingEvidence?.restore,
      "phase A timing-restore evidence",
    ),
  };

  check(
    sequence.length === V3_SEQUENCE.length,
    `phase A v3 transaction sequence has ${sequence.length} records, expected ${V3_SEQUENCE.length}`,
  );
  const records = sequence.map((item, itemIndex) =>
    normalizedSequenceRecord(
      item,
      V3_SEQUENCE[itemIndex],
      itemIndex,
      identities.owner,
    ),
  );
  for (let index = 0; index < records.length; index += 1) {
    const record = records[index];
    if (index > 0) {
      check(
        record.nonce === records[0].nonce + BigInt(index),
        "phase A v3 transaction nonces are not consecutive",
      );
      const prior = records[index - 1].receipt;
      check(
        record.receipt.blockNumber > prior.blockNumber ||
          (record.receipt.blockNumber === prior.blockNumber &&
            record.receipt.transactionIndex > prior.transactionIndex),
        "phase A v3 receipts are not in strict canonical order",
      );
    }
  }
  const expectedTargets = [
    identities.launchpad,
    identities.launchpad,
    identities.router,
    identities.launchpad,
    identities.launchpad,
    identities.auction,
    identities.launchpad,
    identities.hookrToken,
    identities.router,
  ];
  for (const [recordIndex, target] of expectedTargets.entries()) {
    check(
      sameHex(records[recordIndex].to, target),
      `phase A transaction #${recordIndex} target differs from its indexed identity`,
    );
  }

  const ownerBid = records[5];
  check(
    ownerBid.value === CANARY_BID_WEI,
    "phase A owner bid value is not the reviewed amount",
  );
  check(
    ownerBid.receipt.blockNumber < identities.auctionEndBlock,
    "phase A owner bid was not mined before the indexed auction end",
  );
  let bidCall;
  try {
    bidCall = decodeFunctionData({ abi: AUCTION_ABI, data: ownerBid.calldata });
  } catch (error) {
    throw new Error(
      `phase A owner-bid calldata cannot be decoded: ${error.message}`,
    );
  }
  check(
    bidCall.functionName === "submitBid",
    "phase A owner-bid selector is not submitBid",
  );
  check(
    bigint(bidCall.args[0], "phase A owner-bid max price") ===
      CANARY_RECOVERY_BID_MAX_PRICE_Q96,
    "phase A owner-bid max price is not the reviewed recovery cap",
  );
  check(
    bigint(bidCall.args[1], "phase A owner-bid amount") === CANARY_BID_WEI,
    "phase A owner-bid calldata amount is not reviewed",
  );
  check(
    sameHex(bidCall.args[2], identities.owner),
    "phase A owner-bid calldata owner is wrong",
  );
  check(bidCall.args[3] === "0x", "phase A owner-bid hook data is not empty");
  check(
    bigint(index.reviewedSemantics?.bidAmountWei, "reviewed bid amount") ===
      CANARY_BID_WEI,
    "phase A reviewed bid amount is wrong",
  );
  check(
    bigint(
      index.reviewedSemantics?.bidMaxPriceQ96,
      "reviewed bid max price",
    ) === CANARY_RECOVERY_BID_MAX_PRICE_Q96,
    "phase A reviewed bid max price is wrong",
  );

  return {
    sourceCommit: canaryRecoveryCommit,
    deploymentSourceCommit,
    originalCanaryOperatorCommit,
    canaryRecoveryCommit,
    rawOwnerBidEvidence,
    rawTimingEvidence,
    ownerBid,
    records,
  };
};

export function validatePhaseACollectorIndex(index) {
  check(
    index?.kind === PHASE_A_V2_KIND || index?.kind === PHASE_A_V3_KIND,
    `phase A evidence kind is not ${PHASE_A_V2_KIND} or ${PHASE_A_V3_KIND}`,
  );
  check(
    bigint(index.chainId, "phase A chainId") === CHAIN_ID,
    "phase A evidence is not chain 4663",
  );
  const identities = index.identities ?? {};
  const normalized = {
    owner: address(identities.sender, "phase A sender"),
    launchpad: address(identities.launchpad, "phase A launchpad"),
    router:
      index.kind === PHASE_A_V3_KIND
        ? address(identities.router, "phase A router")
        : null,
    hook: address(identities.hook, "phase A hook"),
    hookrToken: address(identities.hookrToken, "phase A HOOKR token"),
    instantToken: address(identities.instantToken, "phase A instant token"),
    instantPoolId: hash32(identities.instantPoolId, "phase A instant pool id"),
    auctionToken: address(identities.auctionToken, "phase A auction token"),
    auction: address(identities.auction, "phase A auction"),
    auctionEndBlock: bigint(
      identities.auctionEndBlock,
      "phase A auction end block",
    ),
    bidId: bigint(identities.bidId, "phase A bid id"),
    instantFlywheelAccrual: {
      transactionHash: hash32(
        identities.instantFlywheelAccrual?.transactionHash,
        "phase A indexed accrual transaction hash",
      ),
      blockNumber: bigint(
        identities.instantFlywheelAccrual?.blockNumber,
        "phase A indexed accrual block number",
      ),
      transactionIndex: bigint(
        identities.instantFlywheelAccrual?.transactionIndex,
        "phase A indexed accrual transaction index",
      ),
      logIndex: bigint(
        identities.instantFlywheelAccrual?.logIndex,
        "phase A indexed accrual log index",
      ),
      poolId: hash32(
        identities.instantFlywheelAccrual?.poolId,
        "phase A indexed accrual pool id",
      ),
      amountWei: bigint(
        identities.instantFlywheelAccrual?.amountWei,
        "phase A indexed accrual amount",
      ),
    },
  };
  const sequence = Array.isArray(index.transactionSequence)
    ? index.transactionSequence
    : [];
  const provenance =
    index.kind === PHASE_A_V3_KIND
      ? validateV3Provenance(index, normalized, sequence)
      : {
          sourceCommit: sourceCommit(
            index.canaryOperatorCommit,
            "phase A canary operator commit",
          ),
          deploymentSourceCommit: sourceCommit(
            index.deploymentSourceCommit,
            "phase A deployment source commit",
          ),
          canaryOperatorCommit: sourceCommit(
            index.canaryOperatorCommit,
            "phase A canary operator commit",
          ),
          ownerBid: null,
        };
  normalized.sourceCommit = provenance.sourceCommit;
  const expectedInstantPool = poolIdForKey({
    currency0: zeroAddress,
    currency1: normalized.instantToken,
    fee: DYNAMIC_FEE,
    tickSpacing: TICK_SPACING,
    hooks: normalized.hook,
  });
  check(
    sameHex(expectedInstantPool, normalized.instantPoolId),
    "phase A instant pool id is not canonical",
  );
  const instantBuy = sequence.filter(
    (item) =>
      item?.artifact === "instantBuyAuctionLaunch" &&
      Number(item.artifactIndex) === 0,
  );
  check(
    instantBuy.length === 1,
    "phase A index does not identify exactly one instant buy",
  );
  check(
    instantBuy[0].function === "exactInput",
    "phase A instant-buy record is not exactInput",
  );
  check(
    sameHex(instantBuy[0].receipt?.transactionHash, instantBuy[0].hash),
    "phase A instant-buy hash mismatch",
  );
  check(
    sameHex(
      normalized.instantFlywheelAccrual.transactionHash,
      instantBuy[0].hash,
    ),
    "phase A indexed accrual is not in the indexed instant-buy transaction",
  );
  check(
    sameHex(normalized.instantFlywheelAccrual.poolId, normalized.instantPoolId),
    "phase A indexed accrual pool is not the instant pool",
  );
  check(
    normalized.instantFlywheelAccrual.amountWei === CANARY_FLYWHEEL_WEI,
    "phase A indexed accrual amount is not the reviewed canary amount",
  );
  return {
    identities: normalized,
    instantBuy: instantBuy[0],
    ownerBid: provenance.ownerBid,
    provenance,
  };
}

const decodeEvent = (log, event, label) => {
  try {
    return decodeEventLog({
      abi: [event],
      data: log.data,
      topics: log.topics,
      strict: true,
    }).args;
  } catch (error) {
    throw new Error(`${label} cannot be decoded: ${error.message}`);
  }
};
const matchingReceiptLogs = (receipt, contract, event) =>
  (receipt.logs ?? []).filter(
    (log) =>
      sameHex(log.address, contract) &&
      sameHex(log.topics?.[0], toEventSelector(event)),
  );
const onlyDecodedReceiptEvent = (
  receipt,
  contract,
  event,
  label,
  predicate = () => true,
) => {
  const matches = matchingReceiptLogs(receipt, contract, event)
    .map((log) => ({ log, args: decodeEvent(log, event, label) }))
    .filter(({ args }) => predicate(args));
  check(
    matches.length === 1,
    `${label} expected one matching event, found ${matches.length}`,
  );
  return matches[0];
};

const request = (client, method, params) => client.request({ method, params });
const rawCall = async (
  client,
  target,
  abi,
  functionName,
  args,
  blockNumber,
) => {
  const data = encodeFunctionData({ abi, functionName, args });
  const result = await request(client, "eth_call", [
    { to: target, data },
    quantity(blockNumber),
  ]);
  return decodeFunctionResult({ abi, functionName, data: result });
};

const blockCache = new Map();
const canonicalBlock = async (client, blockNumber) => {
  const key = bigint(blockNumber, "block number").toString();
  if (blockCache.has(key)) return blockCache.get(key);
  const block = await request(client, "eth_getBlockByNumber", [
    quantity(blockNumber),
    false,
  ]);
  check(
    block && HASH_RE.test(String(block.hash ?? "")),
    `canonical block ${key} is unavailable`,
  );
  check(
    bigint(block.number, `canonical block ${key} number`) === BigInt(key),
    `canonical block ${key} number drifted`,
  );
  blockCache.set(key, block);
  return block;
};

const pairCache = new Map();
const canonicalPair = async (client, transactionHash, scanHead) => {
  const hash = hash32(transactionHash, "transaction hash");
  if (pairCache.has(hash)) return pairCache.get(hash);
  const [transaction, receipt] = await Promise.all([
    request(client, "eth_getTransactionByHash", [hash]),
    request(client, "eth_getTransactionReceipt", [hash]),
  ]);
  check(transaction && receipt, `transaction/receipt ${hash} is unavailable`);
  check(
    sameHex(transaction.hash, hash),
    `transaction ${hash} returned another hash`,
  );
  check(
    sameHex(receipt.transactionHash, hash),
    `receipt ${hash} returned another hash`,
  );
  check(
    bigint(receipt.status, `receipt ${hash} status`) === 1n,
    `receipt ${hash} did not succeed`,
  );
  check(
    transaction.blockNumber != null && receipt.blockNumber != null,
    `transaction ${hash} is not mined`,
  );
  check(
    bigint(transaction.blockNumber, `transaction ${hash} block`) ===
      bigint(receipt.blockNumber, `receipt ${hash} block`),
    `transaction/receipt ${hash} block numbers differ`,
  );
  check(
    sameHex(transaction.blockHash, receipt.blockHash),
    `transaction/receipt ${hash} block hashes differ`,
  );
  check(
    sameHex(transaction.from, receipt.from),
    `transaction/receipt ${hash} senders differ`,
  );
  check(
    transaction.to == null
      ? receipt.to == null
      : sameHex(transaction.to, receipt.to),
    `transaction/receipt ${hash} targets differ`,
  );
  check(
    bigint(transaction.transactionIndex, `transaction ${hash} index`) ===
      bigint(receipt.transactionIndex, `receipt ${hash} index`),
    `transaction/receipt ${hash} transaction indexes differ`,
  );
  check(
    bigint(receipt.blockNumber, `receipt ${hash} block`) <= scanHead.number,
    `receipt ${hash} is newer than the fixed scan head`,
  );
  if (transaction.chainId != null) {
    check(
      bigint(transaction.chainId, `transaction ${hash} chainId`) === CHAIN_ID,
      `transaction ${hash} is not chain 4663`,
    );
  }
  const block = await canonicalBlock(client, receipt.blockNumber);
  check(
    sameHex(block.hash, receipt.blockHash),
    `receipt ${hash} is no longer canonical`,
  );
  check(Array.isArray(receipt.logs), `receipt ${hash} has no logs array`);
  let previousLogIndex = -1n;
  for (const [index, log] of receipt.logs.entries()) {
    check(
      sameHex(log.transactionHash, hash),
      `receipt ${hash} log #${index} has another transaction`,
    );
    check(
      sameHex(log.blockHash, receipt.blockHash),
      `receipt ${hash} log #${index} has another block`,
    );
    check(
      bigint(log.blockNumber, `receipt ${hash} log #${index} block`) ===
        bigint(receipt.blockNumber, `receipt ${hash} block`),
      `receipt ${hash} log #${index} block number differs`,
    );
    check(
      bigint(
        log.transactionIndex,
        `receipt ${hash} log #${index} transaction index`,
      ) ===
        bigint(receipt.transactionIndex, `receipt ${hash} transaction index`),
      `receipt ${hash} log #${index} transaction index differs`,
    );
    const currentLogIndex = bigint(
      log.logIndex,
      `receipt ${hash} log #${index} index`,
    );
    check(
      currentLogIndex > previousLogIndex,
      `receipt ${hash} logs are not in canonical order`,
    );
    previousLogIndex = currentLogIndex;
    check(log.removed !== true, `receipt ${hash} log #${index} is removed`);
  }
  const pair = { transaction, receipt, block };
  pairCache.set(hash, pair);
  return pair;
};

const scanLogs = async (
  client,
  { address: contract, topics, fromBlock, toBlock, chunkBlocks },
) => {
  const records = new Map();
  for (let start = fromBlock; start <= toBlock; start += chunkBlocks) {
    const end =
      start + chunkBlocks - 1n > toBlock ? toBlock : start + chunkBlocks - 1n;
    const logs = await request(client, "eth_getLogs", [
      {
        address: contract,
        topics,
        fromBlock: quantity(start),
        toBlock: quantity(end),
      },
    ]);
    check(Array.isArray(logs), "eth_getLogs did not return an array");
    for (const log of logs) {
      check(log.removed !== true, "eth_getLogs returned a removed log");
      const key = `${String(log.transactionHash).toLowerCase()}:${bigint(log.logIndex, "log index")}`;
      const serialized = JSON.stringify(log);
      if (records.has(key))
        check(
          records.get(key).serialized === serialized,
          `conflicting duplicate log ${key}`,
        );
      else records.set(key, { log, serialized });
    }
  }
  return [...records.values()]
    .map(({ log }) => log)
    .sort((left, right) => comparePosition(position(left), position(right)));
};

const exactTargetAndValue = (pair, target, label) => {
  check(
    pair.transaction.to && sameHex(pair.transaction.to, target),
    `${label} target is wrong`,
  );
  check(
    bigint(pair.transaction.value ?? "0x0", `${label} value`) === 0n,
    `${label} sends native value`,
  );
  check(
    pair.receipt.to == null || sameHex(pair.receipt.to, target),
    `${label} receipt target is wrong`,
  );
};
const decodeCall = (pair, abi, expectedNames, label) => {
  let decoded;
  try {
    decoded = decodeFunctionData({ abi, data: pair.transaction.input });
  } catch (error) {
    throw new Error(`${label} calldata cannot be decoded: ${error.message}`);
  }
  check(
    expectedNames.includes(decoded.functionName),
    `${label} selector is not ${expectedNames.join(" or ")}`,
  );
  return decoded;
};
const protocolCall = (pair, target, abi, expectedNames, label) => {
  if (!pair.transaction.to || !sameHex(pair.transaction.to, target)) {
    return { executionMode: "helper", call: null };
  }
  exactTargetAndValue(pair, target, label);
  return {
    executionMode: "direct",
    call: decodeCall(pair, abi, expectedNames, label),
  };
};
const sameReceiptLog = (left, right) =>
  sameHex(left?.transactionHash, right?.transactionHash) &&
  bigint(left?.logIndex, "left log index") ===
    bigint(right?.logIndex, "right log index");
const metadata = (pair, semantics, finalizedNumber) => ({
  transactionHash: pair.transaction.hash.toLowerCase(),
  from: address(pair.transaction.from, "action sender"),
  to:
    pair.transaction.to == null
      ? null
      : address(pair.transaction.to, "action target"),
  blockNumber: bigint(pair.receipt.blockNumber, "action block").toString(),
  blockHash: hash32(pair.receipt.blockHash, "action block hash"),
  transactionIndex: bigint(
    pair.receipt.transactionIndex,
    "action transaction index",
  ).toString(),
  finalized:
    bigint(pair.receipt.blockNumber, "action block") <= finalizedNumber,
  semantics: jsonSafe(semantics),
});

const assertLivePairMatchesV3Record = (
  pair,
  record,
  label,
  finalizedNumber,
) => {
  check(
    sameHex(pair.transaction.hash, record.hash),
    `${label} transaction hash drifted`,
  );
  check(sameHex(pair.transaction.from, record.from), `${label} sender drifted`);
  check(
    pair.transaction.to && sameHex(pair.transaction.to, record.to),
    `${label} target drifted`,
  );
  check(
    bigint(pair.transaction.nonce, `${label} live nonce`) === record.nonce,
    `${label} nonce drifted`,
  );
  check(
    bigint(pair.transaction.value ?? 0, `${label} live value`) === record.value,
    `${label} value drifted`,
  );
  check(
    sameHex(pair.transaction.input, record.calldata),
    `${label} calldata drifted`,
  );
  check(
    bigint(pair.receipt.blockNumber, `${label} live receipt block`) ===
      record.receipt.blockNumber &&
      sameHex(pair.receipt.blockHash, record.receipt.blockHash) &&
      bigint(pair.receipt.transactionIndex, `${label} live receipt index`) ===
        record.receipt.transactionIndex,
    `${label} receipt coordinate drifted`,
  );
  check(
    record.receipt.blockNumber <= finalizedNumber,
    `${label} is not finalized`,
  );
};

const firstValid = async (logs, validator) => {
  const rejectedCandidates = [];
  for (const log of logs) {
    try {
      return { match: await validator(log), rejectedCandidates };
    } catch (error) {
      rejectedCandidates.push({
        transactionHash: String(log.transactionHash ?? "").toLowerCase(),
        reason: String(error.message ?? error),
      });
    }
  }
  return { match: null, rejectedCandidates };
};

const actionPaths = (root, slug) => ({
  directory: join(root, slug),
  transaction: join(root, slug, "transaction.json"),
  receipt: join(root, slug, "receipt.json"),
});
const assertExistingPair = (paths, pair) => {
  check(
    existsSync(paths.transaction) && existsSync(paths.receipt),
    `${paths.directory} is partial`,
  );
  const existingTransaction = readJson(paths.transaction);
  const existingReceipt = readJson(paths.receipt);
  check(
    stableJson(existingTransaction) === stableJson(pair.transaction),
    `${paths.transaction} differs from current canonical RPC evidence`,
  );
  check(
    stableJson(existingReceipt) === stableJson(pair.receipt),
    `${paths.receipt} differs from current canonical RPC evidence`,
  );
};

/** Persist a transaction/receipt pair as one atomically-installed directory, never overwriting. */
export function persistRawPair(outputRoot, slug, pair) {
  mkdirSync(outputRoot, { recursive: true, mode: 0o700 });
  chmodSync(outputRoot, 0o700);
  const paths = actionPaths(outputRoot, slug);
  if (existsSync(paths.directory)) {
    assertExistingPair(paths, pair);
    return { ...paths, created: false };
  }
  const temporary = mkdtempSync(join(outputRoot, `.${slug}.tmp-`));
  try {
    writeFileSync(
      join(temporary, "transaction.json"),
      stableJson(pair.transaction),
      { flag: "wx", mode: 0o600 },
    );
    writeFileSync(join(temporary, "receipt.json"), stableJson(pair.receipt), {
      flag: "wx",
      mode: 0o600,
    });
    try {
      renameSync(temporary, paths.directory);
    } catch (error) {
      if (!existsSync(paths.directory)) throw error;
      assertExistingPair(paths, pair);
      rmSync(temporary, { recursive: true });
      return { ...paths, created: false };
    }
    chmodSync(paths.directory, 0o700);
    return { ...paths, created: true };
  } catch (error) {
    if (existsSync(temporary)) rmSync(temporary, { recursive: true });
    throw error;
  }
}

const missing = (key, reason, blockedBy = []) => ({
  action: key,
  reason,
  blockedBy,
});

/**
 * Reconcile every Phase-B transition from canonical logs and raw RPC transaction/receipt objects.
 * This function owns no signer and exposes no write-capable client method.
 */
export async function collectV5PhaseBEvidence({
  client,
  phaseAIndex,
  phaseAIndexPath = "<memory>",
  phaseAIndexBytes,
  outputDir,
  rehearsal = false,
  logChunkBlocks = DEFAULT_LOG_CHUNK_BLOCKS,
}) {
  blockCache.clear();
  pairCache.clear();
  const { identities, instantBuy, ownerBid, provenance } =
    validatePhaseACollectorIndex(phaseAIndex);
  const chainId = bigint(
    await request(client, "eth_chainId", []),
    "RPC chain id",
  );
  check(chainId === CHAIN_ID, `RPC serves chain ${chainId}, expected 4663`);

  const latest = await request(client, "eth_getBlockByNumber", [
    "latest",
    false,
  ]);
  check(
    latest && HASH_RE.test(String(latest.hash ?? "")),
    "latest block is unavailable",
  );
  const latestHead = {
    number: bigint(latest.number, "latest block number"),
    hash: hash32(latest.hash, "latest hash"),
  };
  blockCache.set(latestHead.number.toString(), latest);
  let finalized = latest;
  if (!rehearsal) {
    finalized = await request(client, "eth_getBlockByNumber", [
      "finalized",
      false,
    ]);
    check(
      finalized && HASH_RE.test(String(finalized.hash ?? "")),
      "finalized block is unavailable",
    );
  }
  const finalizedHead = {
    number: bigint(finalized.number, "finalized block number"),
    hash: hash32(finalized.hash, "finalized hash"),
  };
  check(
    finalizedHead.number <= latestHead.number,
    "finalized block is above latest",
  );

  const liveInstantBuy = await canonicalPair(
    client,
    instantBuy.hash,
    latestHead,
  );
  check(
    bigint(liveInstantBuy.receipt.blockNumber, "instant-buy receipt block") ===
      bigint(instantBuy.receipt.blockNumber, "indexed instant-buy block") &&
      sameHex(liveInstantBuy.receipt.blockHash, instantBuy.receipt.blockHash) &&
      bigint(
        liveInstantBuy.receipt.transactionIndex,
        "instant-buy receipt index",
      ) ===
        bigint(
          instantBuy.receipt.transactionIndex,
          "indexed instant-buy index",
        ),
    "phase A instant-buy receipt differs from its index",
  );
  if (phaseAIndex.kind === PHASE_A_V3_KIND) {
    const indexedInstantBuy = provenance.records[2];
    assertLivePairMatchesV3Record(
      liveInstantBuy,
      indexedInstantBuy,
      "phase A v3 instant buy",
      finalizedHead.number,
    );
    const liveOwnerBid = await canonicalPair(client, ownerBid.hash, latestHead);
    assertLivePairMatchesV3Record(
      liveOwnerBid,
      ownerBid,
      "phase A v3 owner bid",
      finalizedHead.number,
    );
  }
  const accrualMatches = matchingReceiptLogs(
    liveInstantBuy.receipt,
    identities.hook,
    EVENTS.flywheelFeeAccrued,
  )
    .map((log) => ({
      log,
      args: decodeEvent(
        log,
        EVENTS.flywheelFeeAccrued,
        "phase A FlywheelFeeAccrued",
      ),
    }))
    .filter(
      ({ args }) =>
        sameHex(args.poolId, identities.instantPoolId) &&
        bigint(args.amountWei, "phase A flywheel amount") ===
          CANARY_FLYWHEEL_WEI,
    );
  check(
    accrualMatches.length === 1,
    `phase A instant buy has ${accrualMatches.length} exact flywheel accruals`,
  );
  const accrual = accrualMatches[0];
  const accrualPosition = position(accrual.log);
  const indexedAccrual = identities.instantFlywheelAccrual;
  check(
    sameHex(accrual.log.transactionHash, indexedAccrual.transactionHash) &&
      accrualPosition.blockNumber === indexedAccrual.blockNumber &&
      accrualPosition.transactionIndex === indexedAccrual.transactionIndex &&
      accrualPosition.logIndex === indexedAccrual.logIndex &&
      sameHex(accrual.args.poolId, indexedAccrual.poolId) &&
      bigint(accrual.args.amountWei, "live phase A accrual amount") ===
        indexedAccrual.amountWei,
    "live Phase-A accrual differs from identities.instantFlywheelAccrual",
  );

  const burner = address(
    await rawCall(
      client,
      identities.hook,
      HOOK_ABI,
      "flywheelRecipient",
      [],
      latestHead.number,
    ),
    "hook flywheel recipient",
  );
  const burnerOwner = address(
    await rawCall(client, burner, BURNER_ABI, "owner", [], latestHead.number),
    "burner owner",
  );
  check(
    sameHex(burnerOwner, identities.owner),
    "burner owner is not the Phase-A sender",
  );
  const expectedAuctionPoolId = poolIdForKey({
    currency0: zeroAddress,
    currency1: identities.auctionToken,
    fee: DYNAMIC_FEE,
    tickSpacing: TICK_SPACING,
    hooks: identities.hook,
  }).toLowerCase();

  const chunkBlocks = bigint(logChunkBlocks, "log chunk size");
  check(chunkBlocks > 0n, "log chunk size must be positive");
  const common = { toBlock: latestHead.number, chunkBlocks };
  const [
    migrateLogs,
    exitLogs,
    claimLogs,
    proceedsLogs,
    collectLogs,
    burnLogs,
    balanceMigrationLogs,
  ] = await Promise.all([
    scanLogs(client, {
      ...common,
      address: identities.launchpad,
      topics: [TOPICS.migrated, topicAddress(identities.auctionToken)],
      fromBlock: identities.auctionEndBlock + MIGRATION_DELAY_BLOCKS,
    }),
    scanLogs(client, {
      ...common,
      address: identities.auction,
      topics: [
        TOPICS.bidExited,
        topicUint(identities.bidId),
        topicAddress(identities.owner),
      ],
      fromBlock: identities.auctionEndBlock,
    }),
    scanLogs(client, {
      ...common,
      address: identities.auction,
      topics: [
        TOPICS.tokensClaimed,
        topicUint(identities.bidId),
        topicAddress(identities.owner),
      ],
      fromBlock: identities.auctionEndBlock,
    }),
    scanLogs(client, {
      ...common,
      address: identities.launchpad,
      topics: [
        TOPICS.creatorFeesClaimed,
        topicAddress(identities.auctionToken),
        topicAddress(identities.owner),
      ],
      fromBlock: identities.auctionEndBlock,
    }),
    scanLogs(client, {
      ...common,
      address: identities.hook,
      topics: [TOPICS.claimed, topicAddress(burner)],
      fromBlock: accrualPosition.blockNumber,
    }),
    scanLogs(client, {
      ...common,
      address: burner,
      topics: [TOPICS.buybackBurned, topicAddress(identities.owner)],
      fromBlock: accrualPosition.blockNumber,
    }),
    scanLogs(client, {
      ...common,
      address: burner,
      topics: [TOPICS.balanceMigrated],
      fromBlock: accrualPosition.blockNumber,
    }),
  ]);

  const migrated = await firstValid(migrateLogs, async (log) => {
    const pair = await canonicalPair(client, log.transactionHash, latestHead);
    const topLevel = protocolCall(
      pair,
      identities.launchpad,
      LAUNCHPAD_ABI,
      ["migrateAuction"],
      "migrateAuction",
    );
    if (topLevel.call) {
      check(
        sameHex(topLevel.call.args[0], identities.auctionToken),
        "migrateAuction names another token",
      );
    }
    check(
      bigint(pair.receipt.blockNumber, "migrate block") >=
        identities.auctionEndBlock + 1n,
      "migration is too early",
    );
    const event = onlyDecodedReceiptEvent(
      pair.receipt,
      identities.launchpad,
      EVENTS.migrated,
      "Migrated",
      (args) => sameHex(args.token, identities.auctionToken),
    );
    check(
      sameHex(event.args.poolId, expectedAuctionPoolId),
      "Migrated pool id is not canonical",
    );
    check(
      bigint(event.args.sqrtPriceX96, "Migrated sqrt price") > 0n,
      "Migrated sqrt price is zero",
    );
    const ethLiquidity = bigint(
      event.args.ethLiquidity,
      "Migrated ETH liquidity",
    );
    const tokenLiquidity = bigint(
      event.args.tokenLiquidity,
      "Migrated token liquidity",
    );
    const tokensBurned = bigint(
      event.args.tokensBurned,
      "Migrated tokens burned",
    );
    check(
      ethLiquidity > 0n && tokenLiquidity > 0n,
      "Migrated liquidity legs must both be nonzero",
    );
    check(
      tokenLiquidity + tokensBurned === AUCTION_RESERVE_TOKENS,
      "Migrated token liquidity and burn do not conserve the reviewed auction reserve",
    );
    const proceedsMatches = matchingReceiptLogs(
      pair.receipt,
      identities.launchpad,
      EVENTS.auctionProceeds,
    )
      .map((proceedsLog) => ({
        log: proceedsLog,
        args: decodeEvent(
          proceedsLog,
          EVENTS.auctionProceeds,
          "AuctionProceeds",
        ),
      }))
      .filter(({ args }) => sameHex(args.token, identities.auctionToken));
    check(
      proceedsMatches.length <= 1,
      `AuctionProceeds expected at most one matching event, found ${proceedsMatches.length}`,
    );
    const proceeds = proceedsMatches[0] ?? null;
    const proceedsWei = proceeds
      ? bigint(proceeds.args.amountWei, "AuctionProceeds amount")
      : 0n;
    if (proceeds) {
      check(
        sameHex(proceeds.args.creator, identities.owner),
        "AuctionProceeds creator is wrong",
      );
      check(proceedsWei > 0n, "AuctionProceeds amount is zero");
    } else {
      const claimEventsForToken = matchingReceiptLogs(
        pair.receipt,
        identities.launchpad,
        EVENTS.creatorFeesClaimed,
      )
        .map((claimLog) =>
          decodeEvent(
            claimLog,
            EVENTS.creatorFeesClaimed,
            "CreatorFeesClaimed",
          ),
        )
        .filter(({ token }) => sameHex(token, identities.auctionToken));
      check(
        claimEventsForToken.length === 0,
        "zero-proceeds migration receipt contains CreatorFeesClaimed for token",
      );
    }
    const currencySwept = onlyDecodedReceiptEvent(
      pair.receipt,
      identities.auction,
      EVENTS.currencySwept,
      "CurrencySwept",
      (args) => sameHex(args.fundsRecipient, identities.launchpad),
    );
    const currencySweptWei = bigint(
      currencySwept.args.currencyAmount,
      "CurrencySwept amount",
    );
    check(currencySweptWei > 0n, "CurrencySwept amount is zero");
    check(
      ethLiquidity + proceedsWei === currencySweptWei,
      "Migrated ETH liquidity plus AuctionProceeds differs from CurrencySwept",
    );
    const initialized = onlyDecodedReceiptEvent(
      pair.receipt,
      POOL_MANAGER,
      EVENTS.initialize,
      "auction Initialize",
      (args) => sameHex(args.id, expectedAuctionPoolId),
    );
    check(
      sameHex(initialized.args.currency0, zeroAddress),
      "auction Initialize currency0 is not native ETH",
    );
    check(
      sameHex(initialized.args.currency1, identities.auctionToken),
      "auction Initialize currency1 is wrong",
    );
    check(
      Number(initialized.args.fee) === DYNAMIC_FEE,
      "auction Initialize fee is wrong",
    );
    check(
      Number(initialized.args.tickSpacing) === TICK_SPACING,
      "auction Initialize tick spacing is wrong",
    );
    check(
      sameHex(initialized.args.hooks, identities.hook),
      "auction Initialize hook is wrong",
    );
    check(
      bigint(initialized.args.sqrtPriceX96, "Initialize sqrt price") ===
        bigint(event.args.sqrtPriceX96, "Migrated sqrt price"),
      "Initialize and Migrated opening prices differ",
    );
    const migrationOrderValid = proceeds
      ? comparePosition(
          position(currencySwept.log),
          position(initialized.log),
        ) < 0 &&
        comparePosition(position(initialized.log), position(proceeds.log)) <
          0 &&
        comparePosition(position(proceeds.log), position(event.log)) < 0
      : comparePosition(
          position(currencySwept.log),
          position(initialized.log),
        ) < 0 &&
        comparePosition(position(initialized.log), position(event.log)) < 0;
    check(
      migrationOrderValid,
      proceeds
        ? "migration events are not CurrencySwept < Initialize < AuctionProceeds < Migrated"
        : "zero-proceeds migration events are not CurrencySwept < Initialize < Migrated",
    );
    return {
      pair,
      metadata: metadata(
        pair,
        {
          executionMode: topLevel.executionMode,
          token: identities.auctionToken,
          poolId: event.args.poolId,
          sqrtPriceX96: event.args.sqrtPriceX96,
          ethLiquidity,
          tokenLiquidity,
          tokensBurned,
          proceedsWei,
          ...(proceeds ? {} : { proceedsMode: "zero-creator-proceeds" }),
          currencySweptWei,
        },
        finalizedHead.number,
      ),
      position: position(event.log),
      proceedsWei,
      zeroProceeds: proceeds === null,
      sqrtPriceX96: bigint(event.args.sqrtPriceX96, "Migrated sqrt price"),
    };
  });

  const exited = await firstValid(exitLogs, async (log) => {
    const pair = await canonicalPair(client, log.transactionHash, latestHead);
    const topLevel = protocolCall(
      pair,
      identities.auction,
      AUCTION_ABI,
      ["exitBid"],
      "exitBid",
    );
    if (topLevel.call) {
      check(
        bigint(topLevel.call.args[0], "exitBid id") === identities.bidId,
        "exitBid names another bid",
      );
    }
    const event = onlyDecodedReceiptEvent(
      pair.receipt,
      identities.auction,
      EVENTS.bidExited,
      "BidExited",
      (args) =>
        bigint(args.bidId, "BidExited id") === identities.bidId &&
        sameHex(args.owner, identities.owner),
    );
    check(
      bigint(event.args.tokensFilled, "BidExited tokens") > 0n,
      "BidExited filled no tokens",
    );
    const bidWei = bigint(
      phaseAIndex.reviewedSemantics?.bidAmountWei,
      "reviewed bid amount",
    );
    check(
      bigint(event.args.currencyRefunded, "BidExited refund") <= bidWei,
      "BidExited refund exceeds bid",
    );
    return {
      pair,
      metadata: metadata(
        pair,
        {
          executionMode: topLevel.executionMode,
          bidId: identities.bidId,
          owner: identities.owner,
          tokensFilled: event.args.tokensFilled,
          currencyRefunded: event.args.currencyRefunded,
        },
        finalizedHead.number,
      ),
      position: position(event.log),
      tokensFilled: bigint(event.args.tokensFilled, "BidExited tokens"),
    };
  });

  const claimed = exited.match
    ? await firstValid(
        claimLogs.filter((log) => isAfter(log, exited.match.position)),
        async (log) => {
          const pair = await canonicalPair(
            client,
            log.transactionHash,
            latestHead,
          );
          const topLevel = protocolCall(
            pair,
            identities.auction,
            AUCTION_ABI,
            ["claimTokens", "claimTokensBatch"],
            "token claim",
          );
          const receiptClaimedEvents = matchingReceiptLogs(
            pair.receipt,
            identities.auction,
            EVENTS.tokensClaimed,
          ).map((claimedLog) => ({
            log: claimedLog,
            args: decodeEvent(
              claimedLog,
              EVENTS.tokensClaimed,
              "TokensClaimed",
            ),
          }));
          const ownerTransfers = matchingReceiptLogs(
            pair.receipt,
            identities.auctionToken,
            EVENTS.transfer,
          )
            .map((transferLog) => ({
              log: transferLog,
              args: decodeEvent(
                transferLog,
                EVENTS.transfer,
                "auction-token Transfer",
              ),
            }))
            .filter(
              ({ args }) =>
                sameHex(args.from, identities.auction) &&
                sameHex(args.to, identities.owner),
            );

          let claimedEvents;
          let transfers;
          if (topLevel.call) {
            const call = topLevel.call;
            if (call.functionName === "claimTokens") {
              check(
                bigint(call.args[0], "claimTokens id") === identities.bidId,
                "claimTokens names another bid",
              );
            } else {
              check(
                sameHex(call.args[0], identities.owner),
                "claimTokensBatch owner is wrong",
              );
              const matches = call.args[1].filter(
                (id) => bigint(id, "batch bid id") === identities.bidId,
              );
              check(
                matches.length > 0,
                "claimTokensBatch does not contain the canary bid",
              );
            }
            claimedEvents = receiptClaimedEvents;
            check(
              claimedEvents.every(({ args }) =>
                sameHex(args.owner, identities.owner),
              ),
              "direct token claim contains TokensClaimed for another owner",
            );
            if (call.functionName === "claimTokens") {
              check(
                claimedEvents.length === 1,
                "direct token claim contains extra TokensClaimed events",
              );
            } else {
              const requestedBidIds = new Set(
                call.args[1].map((id) => bigint(id, "batch bid id").toString()),
              );
              const emittedBidIds = new Set();
              for (const claimedEvent of claimedEvents) {
                const emittedBidId = bigint(
                  claimedEvent.args.bidId,
                  "TokensClaimed id",
                ).toString();
                check(
                  requestedBidIds.has(emittedBidId),
                  "batch claim emitted a bid absent from calldata",
                );
                check(
                  !emittedBidIds.has(emittedBidId),
                  "batch claim emitted duplicate TokensClaimed for one bid",
                );
                emittedBidIds.add(emittedBidId);
              }
            }
            check(
              ownerTransfers.length === 1,
              `token claim has ${ownerTransfers.length} auction-to-owner Transfers, expected one`,
            );
            transfers = ownerTransfers;
          } else {
            claimedEvents = receiptClaimedEvents.filter(({ args }) =>
              sameHex(args.owner, identities.owner),
            );
            const emittedBidIds = new Set();
            for (const claimedEvent of claimedEvents) {
              const emittedBidId = bigint(
                claimedEvent.args.bidId,
                "TokensClaimed id",
              ).toString();
              check(
                !emittedBidIds.has(emittedBidId),
                "helper claim emitted duplicate TokensClaimed for one bid",
              );
              emittedBidIds.add(emittedBidId);
            }
            check(
              ownerTransfers.length > 0,
              "helper token claim has no auction-to-owner Transfer",
            );
            transfers = ownerTransfers;
          }
          const canaryClaimed = claimedEvents.filter(
            ({ args }) =>
              bigint(args.bidId, "TokensClaimed id") === identities.bidId &&
              sameHex(args.owner, identities.owner),
          );
          check(
            canaryClaimed.length === 1,
            `token claim has ${canaryClaimed.length} exact canary TokensClaimed events`,
          );
          const event = canaryClaimed[0];
          const claimedAmount = bigint(
            event.args.tokensFilled,
            "TokensClaimed amount",
          );
          check(
            claimedAmount > 0n,
            "canary TokensClaimed amount is not positive",
          );
          check(
            claimedAmount === exited.match.tokensFilled,
            "TokensClaimed amount differs from BidExited",
          );
          const transferred = transfers.reduce(
            (total, ownerTransfer) =>
              total + bigint(ownerTransfer.args.value, "claim transfer amount"),
            0n,
          );
          const totalClaimed = claimedEvents.reduce(
            (total, claimedEvent) =>
              total +
              bigint(claimedEvent.args.tokensFilled, "TokensClaimed amount"),
            0n,
          );
          check(
            transferred === totalClaimed,
            "claim Transfer differs from the sum of TokensClaimed events",
          );
          const causalLog = [
            ...claimedEvents.map(({ log: claimedLog }) => claimedLog),
            ...transfers.map(({ log: transferLog }) => transferLog),
          ].reduce((later, candidate) =>
            comparePosition(position(candidate), position(later)) > 0
              ? candidate
              : later,
          );
          return {
            pair,
            metadata: metadata(
              pair,
              {
                executionMode: topLevel.executionMode,
                mode: topLevel.call?.functionName ?? "helper",
                bidId: identities.bidId,
                owner: identities.owner,
                tokensFilled: claimedAmount,
                transferred,
                tokensClaimedEventCount: claimedEvents.length,
              },
              finalizedHead.number,
            ),
            position: position(causalLog),
          };
        },
      )
    : { match: null, rejectedCandidates: [] };

  const proceedsClaimed = migrated.match?.zeroProceeds
    ? {
        match: {
          pair: migrated.match.pair,
          metadata: metadata(
            migrated.match.pair,
            {
              executionMode: "not-applicable",
              mode: "not-applicable-zero-proceeds",
              token: identities.auctionToken,
              amountWei: 0n,
              proofTransactionHash:
                migrated.match.pair.transaction.hash.toLowerCase(),
            },
            finalizedHead.number,
          ),
          position: migrated.match.position,
          noOp: true,
        },
        rejectedCandidates: [],
      }
    : migrated.match
      ? await firstValid(
          proceedsLogs.filter((log) => isAfter(log, migrated.match.position)),
          async (log) => {
            const pair = await canonicalPair(
              client,
              log.transactionHash,
              latestHead,
            );
            const topLevel = protocolCall(
              pair,
              identities.launchpad,
              LAUNCHPAD_ABI,
              ["claimAuctionProceeds"],
              "claimAuctionProceeds",
            );
            if (topLevel.call) {
              check(
                sameHex(topLevel.call.args[0], identities.auctionToken),
                "claimAuctionProceeds names another token",
              );
            }
            const event = onlyDecodedReceiptEvent(
              pair.receipt,
              identities.launchpad,
              EVENTS.creatorFeesClaimed,
              "proceeds CreatorFeesClaimed",
              (args) =>
                sameHex(args.token, identities.auctionToken) &&
                sameHex(args.payTo, identities.owner),
            );
            check(
              bigint(event.args.amountWei, "claimed proceeds") ===
                migrated.match.proceedsWei,
              "claimed proceeds differ from AuctionProceeds",
            );
            return {
              pair,
              metadata: metadata(
                pair,
                {
                  executionMode: topLevel.executionMode,
                  token: identities.auctionToken,
                  payTo: identities.owner,
                  amountWei: event.args.amountWei,
                },
                finalizedHead.number,
              ),
              position: position(event.log),
            };
          },
        )
      : { match: null, rejectedCandidates: [] };

  const collected = await firstValid(
    collectLogs.filter((log) => isAfter(log, accrualPosition)),
    async (log) => {
      const pair = await canonicalPair(client, log.transactionHash, latestHead);
      const topLevel = protocolCall(
        pair,
        burner,
        BURNER_ABI,
        ["collect"],
        "collect",
      );
      const hookClaims = matchingReceiptLogs(
        pair.receipt,
        identities.hook,
        EVENTS.claimed,
      )
        .map((claimLog) => ({
          log: claimLog,
          args: decodeEvent(claimLog, EVENTS.claimed, "hook Claimed"),
        }))
        .filter(({ args }) => sameHex(args.account, burner));
      const matchingHookClaims = hookClaims.filter(({ log: claimLog }) =>
        sameReceiptLog(claimLog, log),
      );
      check(
        matchingHookClaims.length === 1,
        `collect candidate has ${matchingHookClaims.length} matching hook Claimed events`,
      );
      const hookClaim = matchingHookClaims[0];
      const claimedWei = bigint(
        hookClaim.args.amountWei,
        "hook Claimed amount",
      );
      check(
        claimedWei >= CANARY_FLYWHEEL_WEI,
        "post-accrual collect is below the canary fee",
      );
      const nextHookClaim = hookClaims.find(
        ({ log: claimLog }) =>
          comparePosition(position(claimLog), position(hookClaim.log)) > 0,
      );
      const burnerCollects = matchingReceiptLogs(
        pair.receipt,
        burner,
        EVENTS.flywheelCollected,
      )
        .map((collectLog) => ({
          log: collectLog,
          args: decodeEvent(
            collectLog,
            EVENTS.flywheelCollected,
            "FlywheelCollected",
          ),
        }))
        .filter(
          ({ log: collectLog, args }) =>
            bigint(args.amountWei, "FlywheelCollected amount") === claimedWei &&
            comparePosition(position(collectLog), position(hookClaim.log)) >
              0 &&
            (!nextHookClaim ||
              comparePosition(
                position(collectLog),
                position(nextHookClaim.log),
              ) < 0),
        );
      check(
        burnerCollects.length === 1,
        `collect expected one later matching FlywheelCollected, found ${burnerCollects.length}`,
      );
      const burnerCollect = burnerCollects[0];
      return {
        pair,
        metadata: metadata(
          pair,
          { executionMode: topLevel.executionMode, amountWei: claimedWei },
          finalizedHead.number,
        ),
        position: position(burnerCollect.log),
        amountWei: claimedWei,
      };
    },
  );

  const burned = collected.match
    ? await firstValid(
        burnLogs.filter((log) => isAfter(log, collected.match.position)),
        async (log) => {
          const pair = await canonicalPair(
            client,
            log.transactionHash,
            latestHead,
          );
          exactTargetAndValue(pair, burner, "buybackAndBurn");
          check(
            sameHex(pair.transaction.from, identities.owner),
            "buybackAndBurn sender is not the owner",
          );
          const call = decodeCall(
            pair,
            BURNER_ABI,
            ["buybackAndBurn"],
            "buybackAndBurn",
          );
          check(
            bigint(call.args[0], "buyback ETH input") === CANARY_FLYWHEEL_WEI,
            "buyback ETH input is wrong",
          );
          check(
            bigint(call.args[1], "buyback minimum") === CANARY_MIN_HOOKR_OUT,
            "buyback minimum is wrong",
          );
          const reviewedInput = encodeFunctionData({
            abi: BURNER_ABI,
            functionName: "buybackAndBurn",
            args: [CANARY_FLYWHEEL_WEI, CANARY_MIN_HOOKR_OUT],
          });
          check(
            sameHex(pair.transaction.input, reviewedInput),
            "buybackAndBurn calldata is not byte-exact",
          );
          const event = onlyDecodedReceiptEvent(
            pair.receipt,
            burner,
            EVENTS.buybackBurned,
            "BuybackBurned",
            (args) => sameHex(args.caller, identities.owner),
          );
          const spent = bigint(event.args.ethIn, "BuybackBurned ETH");
          const hookrBurned = bigint(
            event.args.hookrBurned,
            "BuybackBurned HOOKR",
          );
          check(
            spent === CANARY_FLYWHEEL_WEI,
            "buyback did not spend the exact canary fee",
          );
          check(
            hookrBurned >= CANARY_MIN_HOOKR_OUT,
            "buyback burn missed the reviewed minimum",
          );
          const migratedBetween = balanceMigrationLogs.some(
            (candidate) =>
              isAfter(candidate, collected.match.position) &&
              comparePosition(position(candidate), position(event.log)) < 0,
          );
          check(
            !migratedBetween,
            "burner balance migrated between collect and buyback",
          );
          const transfer = onlyDecodedReceiptEvent(
            pair.receipt,
            identities.hookrToken,
            EVENTS.transfer,
            "HOOKR dead Transfer",
            (args) => sameHex(args.from, burner) && sameHex(args.to, DEAD),
          );
          check(
            bigint(transfer.args.value, "dead transfer") === hookrBurned,
            "dead transfer differs from BuybackBurned",
          );
          check(
            comparePosition(position(transfer.log), position(event.log)) < 0,
            "HOOKR dead Transfer does not precede BuybackBurned",
          );
          return {
            pair,
            metadata: metadata(
              pair,
              {
                executionMode: "direct",
                ethIn: spent,
                minHookrOut: call.args[1],
                hookrBurned,
              },
              finalizedHead.number,
            ),
            position: position(event.log),
          };
        },
      )
    : { match: null, rejectedCandidates: [] };

  const launchRaw = await rawCall(
    client,
    identities.launchpad,
    LAUNCHPAD_ABI,
    "getLaunch",
    [identities.auctionToken],
    latestHead.number,
  );
  const bidRaw = await rawCall(
    client,
    identities.auction,
    AUCTION_ABI,
    "bids",
    [identities.bidId],
    latestHead.number,
  );
  const [
    creatorProceedsWei,
    flywheelClaimableWei,
    totalEthSpent,
    totalHookrBurned,
    lastBuybackBlock,
  ] = await Promise.all([
    rawCall(
      client,
      identities.launchpad,
      LAUNCHPAD_ABI,
      "creatorProceedsWei",
      [identities.auctionToken],
      latestHead.number,
    ),
    rawCall(
      client,
      identities.hook,
      HOOK_ABI,
      "claimableWei",
      [burner],
      latestHead.number,
    ),
    rawCall(client, burner, BURNER_ABI, "totalEthSpent", [], latestHead.number),
    rawCall(
      client,
      burner,
      BURNER_ABI,
      "totalHookrBurned",
      [],
      latestHead.number,
    ),
    rawCall(
      client,
      burner,
      BURNER_ABI,
      "lastBuybackBlock",
      [],
      latestHead.number,
    ),
  ]);
  const launchState = {
    status: Number(tupleField(launchRaw, "status", 5)),
    auction: address(
      tupleField(launchRaw, "auction", 9),
      "launch-state auction",
    ),
    auctionEndBlock: bigint(
      tupleField(launchRaw, "auctionEndBlock", 10),
      "launch-state end block",
    ).toString(),
    migratedAtBlock: bigint(
      tupleField(launchRaw, "migratedAtBlock", 11),
      "launch-state migration block",
    ).toString(),
    sqrtPriceX96AtOpen: bigint(
      tupleField(launchRaw, "sqrtPriceX96AtOpen", 12),
      "launch-state sqrt price",
    ).toString(),
    poolId: hash32(tupleField(launchRaw, "poolId", 13), "launch-state pool id"),
  };
  const bidState = {
    startBlock: bigint(
      tupleField(bidRaw, "startBlock", 0),
      "bid-state start block",
    ).toString(),
    exitedBlock: bigint(
      tupleField(bidRaw, "exitedBlock", 2),
      "bid-state exited block",
    ).toString(),
    maxPrice: bigint(
      tupleField(bidRaw, "maxPrice", 3),
      "bid-state max price",
    ).toString(),
    owner: address(tupleField(bidRaw, "owner", 4), "bid-state owner"),
    amountQ96: bigint(
      tupleField(bidRaw, "amountQ96", 5),
      "bid-state amount",
    ).toString(),
    tokensFilled: bigint(
      tupleField(bidRaw, "tokensFilled", 6),
      "bid-state filled tokens",
    ).toString(),
  };
  check(
    sameHex(launchState.auction, identities.auction),
    "launch state names another auction",
  );
  check(
    BigInt(launchState.auctionEndBlock) === identities.auctionEndBlock,
    "launch-state auction end drifted",
  );
  check(sameHex(bidState.owner, identities.owner), "bid state owner drifted");
  if (migrated.match) {
    check(
      launchState.status === 1,
      "Migrated evidence exists but launch state is not Live",
    );
    check(
      sameHex(launchState.poolId, expectedAuctionPoolId),
      "Live launch pool id is wrong",
    );
    check(
      BigInt(launchState.sqrtPriceX96AtOpen) > 0n,
      "Live launch has no opening sqrt price",
    );
    check(
      BigInt(launchState.sqrtPriceX96AtOpen) === migrated.match.sqrtPriceX96,
      "Live launch opening sqrt price differs from Migrated",
    );
  } else {
    const rejectedDetail = migrated.rejectedCandidates.length
      ? `; rejected candidates: ${migrated.rejectedCandidates
          .map(({ transactionHash, reason }) => `${transactionHash}: ${reason}`)
          .join(" | ")}`
      : "";
    check(
      launchState.status === 0,
      `no Migrated evidence but launch status is ${launchState.status}${rejectedDetail}`,
    );
  }
  if (exited.match)
    check(
      BigInt(bidState.exitedBlock) > 0n,
      "BidExited evidence exists but bid state is unexited",
    );
  else
    check(
      BigInt(bidState.exitedBlock) === 0n,
      "bid state is exited without discoverable BidExited evidence",
    );
  if (claimed.match)
    check(
      BigInt(bidState.tokensFilled) === 0n,
      "TokensClaimed evidence exists but bid remains claimable",
    );
  if (proceedsClaimed.match?.noOp) {
    check(
      bigint(creatorProceedsWei, "creator proceeds state") === 0n,
      "zero-proceeds migration has a nonzero creator proceeds ledger",
    );
  } else if (proceedsClaimed.match) {
    check(
      bigint(creatorProceedsWei, "creator proceeds state") === 0n,
      "claimed proceeds ledger is nonzero",
    );
  } else if (migrated.match) {
    check(
      bigint(creatorProceedsWei, "creator proceeds state") ===
        migrated.match.proceedsWei,
      "unclaimed proceeds ledger differs from AuctionProceeds",
    );
  }
  if (burned.match) {
    check(
      bigint(totalEthSpent, "total ETH spent") >= CANARY_FLYWHEEL_WEI,
      "burner total ETH spent is too low",
    );
    check(
      bigint(totalHookrBurned, "total HOOKR burned") >= CANARY_MIN_HOOKR_OUT,
      "burner total HOOKR burned is too low",
    );
  }

  const matches = {
    migrateAuction: migrated.match,
    exitBid: exited.match,
    claimTokens: claimed.match,
    claimAuctionProceeds: proceedsClaimed.match,
    collect: collected.match,
    buybackAndBurn: burned.match,
  };
  const rejected = {
    migrateAuction: migrated.rejectedCandidates,
    exitBid: exited.rejectedCandidates,
    claimTokens: claimed.rejectedCandidates,
    claimAuctionProceeds: proceedsClaimed.rejectedCandidates,
    collect: collected.rejectedCandidates,
    buybackAndBurn: burned.rejectedCandidates,
  };
  const missingActions = [];
  if (!matches.migrateAuction)
    missingActions.push(
      missing("migrateAuction", "no exact canonical migration receipt"),
    );
  if (!matches.exitBid)
    missingActions.push(
      missing("exitBid", "no exact canonical bid-exit receipt"),
    );
  if (!matches.claimTokens)
    missingActions.push(
      missing(
        "claimTokens",
        "no exact canonical single or batch token-claim receipt",
        matches.exitBid ? [] : ["exitBid"],
      ),
    );
  if (!matches.claimAuctionProceeds)
    missingActions.push(
      missing(
        "claimAuctionProceeds",
        "no exact canonical proceeds-claim receipt",
        matches.migrateAuction ? [] : ["migrateAuction"],
      ),
    );
  if (!matches.collect)
    missingActions.push(
      missing("collect", "no exact collect receipt after Phase-A accrual"),
    );
  if (!matches.buybackAndBurn)
    missingActions.push(
      missing(
        "buybackAndBurn",
        "no exact owner buyback receipt after collection",
        matches.collect ? [] : ["collect"],
      ),
    );

  // Recheck the pinned scan head before making any filesystem mutation. A reorged run leaves no
  // stale immutable directories that would require a new evidence root on retry.
  const finalLatest = await request(client, "eth_getBlockByNumber", [
    quantity(latestHead.number),
    false,
  ]);
  check(
    finalLatest && sameHex(finalLatest.hash, latestHead.hash),
    "latest scan head reorged while collecting evidence",
  );

  const persisted = {};
  for (const { key, slug } of ACTIONS) {
    // A latest-head receipt may still be replaced by a reorg. Do not install it under the
    // immutable action slug until the selected finality policy says its block is final.
    if (!matches[key] || !matches[key].metadata.finalized) continue;
    const paths = persistRawPair(outputDir, slug, matches[key].pair);
    persisted[key] = {
      transactionPath: resolve(paths.transaction),
      receiptPath: resolve(paths.receipt),
      created: paths.created,
    };
  }
  const unfinalizedActions = Object.entries(matches)
    .filter(([, match]) => match && !match.metadata.finalized)
    .map(([key]) => key);
  const complete = missingActions.length === 0;
  const promotionReady = complete && unfinalizedActions.length === 0;

  const builderArgs = [
    "--source-commit",
    identities.sourceCommit,
    "--token",
    identities.auctionToken,
    "--auction",
    identities.auction,
    "--bid-id",
    identities.bidId.toString(),
    "--launchpad",
    identities.launchpad,
    "--burner",
    burner,
    "--owner",
    identities.owner,
    "--pool-manager",
    POOL_MANAGER,
    "--pool-id",
    expectedAuctionPoolId,
    "--hook",
    identities.hook,
    "--hookr-token",
    identities.hookrToken,
    "--phase-a-accrual-transaction-hash",
    indexedAccrual.transactionHash,
    "--phase-a-accrual-block-number",
    indexedAccrual.blockNumber.toString(),
    "--phase-a-accrual-transaction-index",
    indexedAccrual.transactionIndex.toString(),
    "--phase-a-accrual-log-index",
    indexedAccrual.logIndex.toString(),
    "--phase-a-accrual-pool-id",
    indexedAccrual.poolId,
    "--phase-a-accrual-amount-wei",
    indexedAccrual.amountWei.toString(),
  ];
  for (const { key, slug } of ACTIONS) {
    const paths = persisted[key];
    if (!paths) continue;
    builderArgs.push(
      `--${slug}-transaction`,
      paths.transactionPath,
      `--${slug}-receipt`,
      paths.receiptPath,
    );
  }
  const orphanedEvidence = ACTIONS.filter(
    ({ key, slug }) =>
      !matches[key] && existsSync(actionPaths(outputDir, slug).directory),
  ).map(({ key, slug }) => ({
    action: key,
    directory: resolve(actionPaths(outputDir, slug).directory),
  }));

  return jsonSafe({
    kind: PHASE_B_COLLECTOR_KIND,
    evidenceKind: PHASE_B_EVIDENCE_KIND,
    chainId: Number(CHAIN_ID),
    finalityPolicy: rehearsal
      ? "loopback-latest-rehearsal"
      : "production-finalized-tag",
    phaseAIndex: {
      path:
        phaseAIndexPath === "<memory>"
          ? phaseAIndexPath
          : resolve(phaseAIndexPath),
      sha256: sha256Bytes(
        phaseAIndexBytes ?? Buffer.from(stableJson(phaseAIndex)),
      ),
      kind: phaseAIndex.kind,
      deploymentSourceCommit: provenance.deploymentSourceCommit,
      sourceCommit: provenance.sourceCommit,
      ...(phaseAIndex.kind === PHASE_A_V3_KIND
        ? {
            originalCanaryOperatorCommit:
              provenance.originalCanaryOperatorCommit,
            canaryRecoveryCommit: provenance.canaryRecoveryCommit,
            ownerBidTransactionHash: ownerBid.hash,
          }
        : { canaryOperatorCommit: provenance.canaryOperatorCommit }),
    },
    identities: {
      sourceCommit: identities.sourceCommit,
      token: identities.auctionToken,
      owner: identities.owner,
      launchpad: identities.launchpad,
      hook: identities.hook,
      burner,
      hookrToken: identities.hookrToken,
      poolManager: POOL_MANAGER,
      auctionToken: identities.auctionToken,
      auction: identities.auction,
      bidId: identities.bidId,
      poolId: expectedAuctionPoolId,
      auctionPoolId: expectedAuctionPoolId,
    },
    phaseAAccrual: {
      transactionHash: indexedAccrual.transactionHash,
      blockNumber: indexedAccrual.blockNumber,
      blockHash: liveInstantBuy.receipt.blockHash,
      transactionIndex: indexedAccrual.transactionIndex,
      logIndex: indexedAccrual.logIndex,
      poolId: indexedAccrual.poolId,
      amountWei: indexedAccrual.amountWei,
    },
    scan: {
      fromBlock: accrualPosition.blockNumber,
      latestHead,
      finalizedHead,
      logChunkBlocks: chunkBlocks,
    },
    actions: Object.fromEntries(
      ACTIONS.map(({ key }) => [
        key,
        matches[key] ? { ...matches[key].metadata, ...persisted[key] } : null,
      ]),
    ),
    stateReadbacks: {
      launch: launchState,
      bid: bidState,
      creatorProceedsWei,
      flywheelClaimableWei,
      totalEthSpent,
      totalHookrBurned,
      lastBuybackBlock,
    },
    rejectedCandidates: rejected,
    missingActions,
    orphanedEvidence,
    unfinalizedActions,
    complete,
    promotionReady,
    builderArgs,
  });
}

const parseArgs = (argv) => {
  const values = new Map();
  const booleans = new Set();
  const booleanFlags = new Set([
    "rehearsal",
    "require-complete",
    "require-finalized",
  ]);
  for (let index = 0; index < argv.length; index += 1) {
    const raw = argv[index];
    check(raw.startsWith("--"), `unexpected argument ${raw}`);
    const name = raw.slice(2);
    if (booleanFlags.has(name)) booleans.add(name);
    else {
      check(
        index + 1 < argv.length && !argv[index + 1].startsWith("--"),
        `missing value for --${name}`,
      );
      values.set(name, argv[++index]);
    }
  }
  return {
    value: (name, fallback) => values.get(name) ?? fallback,
    has: (name) => booleans.has(name),
  };
};

async function cli() {
  const args = parseArgs(process.argv.slice(2));
  // Environment wins so a credential never needs to appear in argv or process listings.
  const rpc =
    process.env.HOOKR_RPC_URL ||
    process.env.ETH_RPC_URL ||
    "https://rpc.mainnet.chain.robinhood.com";
  const phaseAIndexPath = resolve(
    process.env.HOOKR_V5_PHASE_A_INDEX ||
      args.value("phase-a-index", DEFAULT_PHASE_A_INDEX),
  );
  const outputDir = resolve(
    process.env.HOOKR_V5_PHASE_B_EVIDENCE_DIR ||
      args.value(
        "output-dir",
        join(dirname(phaseAIndexPath), "phase-b-evidence-v5"),
      ),
  );
  const phaseAIndexBytes = readFileSync(phaseAIndexPath);
  const phaseAIndex = JSON.parse(phaseAIndexBytes.toString("utf8"));
  const client = createPublicClient({ transport: http(rpc) });
  const result = await collectV5PhaseBEvidence({
    client,
    phaseAIndex,
    phaseAIndexPath,
    phaseAIndexBytes,
    outputDir,
    rehearsal: args.has("rehearsal"),
    logChunkBlocks: bigint(
      process.env.HOOKR_V5_LOG_CHUNK_BLOCKS ||
        args.value("log-chunk-blocks", DEFAULT_LOG_CHUNK_BLOCKS),
      "log chunk size",
    ),
  });
  const summaryOutput = args.value("summary-output");
  if (summaryOutput)
    writeFileSync(resolve(summaryOutput), stableJson(result), {
      flag: "wx",
      mode: 0o600,
    });
  process.stdout.write(stableJson(result));
  if (args.has("require-complete") && !result.complete) process.exitCode = 3;
  if (args.has("require-finalized") && !result.promotionReady)
    process.exitCode = 4;
}

const isCli =
  process.argv[1] &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href;
if (isCli) {
  const rpcForRedaction =
    process.env.HOOKR_RPC_URL || process.env.ETH_RPC_URL || "";
  let failed = false;
  const failUnexpected = (reason) => {
    if (failed) return;
    failed = true;
    const detail =
      reason instanceof Error
        ? (reason.stack ?? reason.message)
        : String(reason);
    process.stderr.write(
      `PHASE-B COLLECTOR BLOCKED: ${redactRpcMessage(detail, rpcForRedaction)}\n`,
    );
    process.exitCode = 1;
  };
  process.on("uncaughtException", failUnexpected);
  process.on("unhandledRejection", failUnexpected);
  cli().catch(failUnexpected);
}
