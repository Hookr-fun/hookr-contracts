#!/usr/bin/env node

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync, realpathSync, writeFileSync } from "node:fs";
import { isAbsolute, relative, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";
import { isDeepStrictEqual } from "node:util";
import {
  decodeFunctionData,
  decodeEventLog,
  encodeAbiParameters,
  encodeFunctionData,
  keccak256,
  parseAbi,
  toEventSelector,
} from "viem";

const KIND = "hookr-v5-phase-b-evidence-v1";
const POLICY =
  "six-canonical-action-references-permissionless-receipt-overlap-allowed";
const CHAIN_ID = 4663n;
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const DEAD_ADDRESS = "0x000000000000000000000000000000000000dead";
const FLYWHEEL_ETH_IN = 3_000_000_000_000n;
const FLYWHEEL_MIN_HOOKR_OUT = 3n * 10n ** 18n;
const DYNAMIC_FEE_FLAG = 0x800000n;
const POOL_TICK_SPACING = 60n;
const TOKEN_TOTAL_SUPPLY = 1_000_000_000n * 10n ** 18n;
const AUCTION_RESERVE_TOKENS = (TOKEN_TOTAL_SUPPLY * 2_000n) / 10_000n;
const NOT_APPLICABLE_ZERO_PROCEEDS = "not-applicable-zero-proceeds";

export const V5_PHASE_B_ACTIONS = Object.freeze([
  "migrateAuction",
  "exitBid",
  "claimTokens",
  "claimAuctionProceeds",
  "collect",
  "buybackAndBurn",
]);

const LAUNCHPAD_ABI = parseAbi([
  "function migrateAuction(address token)",
  "function claimAuctionProceeds(address token)",
  "event Migrated(address indexed token,bytes32 indexed poolId,uint160 sqrtPriceX96,uint256 ethLiquidity,uint256 tokenLiquidity,uint256 tokensBurned)",
  "event AuctionProceeds(address indexed token,address indexed creator,uint256 amountWei)",
  "event CreatorFeesClaimed(address indexed token,address indexed payTo,uint256 amountWei)",
]);
const AUCTION_ABI = parseAbi([
  "function exitBid(uint256 bidId)",
  "function claimTokens(uint256 bidId)",
  "function claimTokensBatch(address owner,uint256[] bidIds)",
  "event BidExited(uint256 indexed bidId,address indexed owner,uint256 tokensFilled,uint256 currencyRefunded)",
  "event TokensClaimed(uint256 indexed bidId,address indexed owner,uint256 tokensFilled)",
  "event CurrencySwept(address indexed fundsRecipient,uint256 currencyAmount)",
]);
const BURNER_ABI = parseAbi([
  "function collect()",
  "function buybackAndBurn(uint256 ethIn,uint256 minHookrOut) returns (uint256 burned)",
  "event FlywheelCollected(uint256 amountWei)",
  "event BuybackBurned(address indexed caller,uint256 ethIn,uint256 hookrBurned)",
]);
const POOL_MANAGER_ABI = parseAbi([
  "event Initialize(bytes32 indexed id,address indexed currency0,address indexed currency1,uint24 fee,int24 tickSpacing,address hooks,uint160 sqrtPriceX96,int24 tick)",
]);
const HOOK_ABI = parseAbi([
  "event Claimed(address indexed account,uint256 amountWei)",
]);
const TOKEN_ABI = parseAbi([
  "event Transfer(address indexed from,address indexed to,uint256 value)",
]);
const POOL_KEY_COMPONENTS = [
  { name: "currency0", type: "address" },
  { name: "currency1", type: "address" },
  { name: "fee", type: "uint24" },
  { name: "tickSpacing", type: "int24" },
  { name: "hooks", type: "address" },
];
const EVENT_TOPICS = Object.freeze({
  Migrated: toEventSelector(
    "Migrated(address,bytes32,uint160,uint256,uint256,uint256)",
  ),
  AuctionProceeds: toEventSelector("AuctionProceeds(address,address,uint256)"),
  CurrencySwept: toEventSelector("CurrencySwept(address,uint256)"),
  Initialize: toEventSelector(
    "Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)",
  ),
  BidExited: toEventSelector("BidExited(uint256,address,uint256,uint256)"),
  TokensClaimed: toEventSelector("TokensClaimed(uint256,address,uint256)"),
  CreatorFeesClaimed: toEventSelector(
    "CreatorFeesClaimed(address,address,uint256)",
  ),
  FlywheelCollected: toEventSelector("FlywheelCollected(uint256)"),
  BuybackBurned: toEventSelector("BuybackBurned(address,uint256,uint256)"),
  Claimed: toEventSelector("Claimed(address,uint256)"),
  Transfer: toEventSelector("Transfer(address,address,uint256)"),
});

const fail = (message) => {
  throw new Error(message);
};
const sameHex = (left, right) =>
  typeof left === "string" &&
  typeof right === "string" &&
  left.toLowerCase() === right.toLowerCase();
const quantity = (value, label) => {
  try {
    return BigInt(value).toString();
  } catch {
    fail(`${label} is not an integer quantity`);
  }
};
const address = (value, label, { allowZero = true, nullable = false } = {}) => {
  if (value === null && nullable) return null;
  if (!/^0x[0-9a-fA-F]{40}$/.test(String(value ?? "")))
    fail(`${label} is not an address`);
  const result = String(value).toLowerCase();
  if (!allowZero && result === ZERO_ADDRESS)
    fail(`${label} is the zero address`);
  return result;
};
const hex = (value, label) => {
  if (!/^0x(?:[0-9a-fA-F]{2})*$/.test(String(value ?? "")))
    fail(`${label} is not byte-aligned hex`);
  return String(value).toLowerCase();
};
const hash32 = (value, label) => {
  if (!/^0x[0-9a-fA-F]{64}$/.test(String(value ?? "")))
    fail(`${label} is not a bytes32 hash`);
  return String(value).toLowerCase();
};
const fullCommit = (value, label) => {
  if (!/^[0-9a-fA-F]{40}$/.test(String(value ?? "")))
    fail(`${label} is not a full source commit`);
  return String(value).toLowerCase();
};
const readJson = (path) => JSON.parse(readFileSync(path, "utf8"));
const sha256File = (path) =>
  createHash("sha256").update(readFileSync(path)).digest("hex");
const repositoryRoot = realpathSync(process.cwd());
const repoRelativePath = (path) => {
  const absolute = resolve(path);
  const result = relative(process.cwd(), absolute);
  if (
    !result ||
    result === ".." ||
    result.startsWith(`..${sep}`) ||
    isAbsolute(result)
  ) {
    fail(`raw evidence must be inside the repository: ${path}`);
  }
  let real;
  try {
    real = realpathSync(absolute);
  } catch {
    fail(`raw evidence path cannot be resolved: ${path}`);
  }
  const expectedReal = resolve(repositoryRoot, result);
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
  return result.split(sep).join("/");
};
const optionalQuantity = (value, label) =>
  value === undefined || value === null ? undefined : quantity(value, label);
const optionalHex = (value, label) =>
  value === undefined || value === null ? undefined : hex(value, label);
const optionalAddress = (value, label) =>
  value === undefined || value === null
    ? undefined
    : address(value, label, { nullable: true });

const normalizeLog = (log, index, receipt, label) => {
  if (!log || typeof log !== "object")
    fail(`${label} log #${index} is malformed`);
  if (!Array.isArray(log.topics))
    fail(`${label} log #${index} topics are missing`);
  const normalized = {
    address: address(log.address, `${label} log #${index} address`),
    topics: log.topics.map((topic, topicIndex) =>
      hash32(topic, `${label} log #${index} topic #${topicIndex}`),
    ),
    data: hex(log.data, `${label} log #${index} data`),
    blockHash: hash32(log.blockHash, `${label} log #${index} blockHash`),
    blockNumber: quantity(
      log.blockNumber,
      `${label} log #${index} blockNumber`,
    ),
    transactionHash: hash32(
      log.transactionHash,
      `${label} log #${index} transactionHash`,
    ),
    transactionIndex: quantity(
      log.transactionIndex,
      `${label} log #${index} transactionIndex`,
    ),
    logIndex: quantity(log.logIndex, `${label} log #${index} logIndex`),
    removed: Boolean(log.removed ?? false),
  };
  const blockTimestamp = optionalQuantity(
    log.blockTimestamp,
    `${label} log #${index} blockTimestamp`,
  );
  if (blockTimestamp !== undefined) normalized.blockTimestamp = blockTimestamp;
  if (
    !sameHex(normalized.blockHash, receipt.blockHash) ||
    normalized.blockNumber !== receipt.blockNumber ||
    !sameHex(normalized.transactionHash, receipt.transactionHash) ||
    normalized.transactionIndex !== receipt.transactionIndex
  ) {
    fail(
      `${label} log #${index} canonical coordinates differ from its receipt`,
    );
  }
  if (normalized.removed) fail(`${label} log #${index} is marked removed`);
  return normalized;
};

const normalizeTransaction = (transaction, label) => {
  if (!transaction || typeof transaction !== "object")
    fail(`${label} transaction is malformed`);
  return {
    hash: hash32(transaction.hash, `${label} transaction hash`),
    from: address(transaction.from, `${label} transaction sender`, {
      allowZero: false,
    }),
    to: address(transaction.to, `${label} transaction target`, {
      allowZero: false,
    }),
    nonce: quantity(transaction.nonce, `${label} transaction nonce`),
    value: quantity(transaction.value, `${label} transaction value`),
    input: hex(transaction.input, `${label} transaction input`),
    chainId: quantity(transaction.chainId, `${label} transaction chainId`),
    blockHash: hash32(transaction.blockHash, `${label} transaction blockHash`),
    blockNumber: quantity(
      transaction.blockNumber,
      `${label} transaction blockNumber`,
    ),
    transactionIndex: quantity(
      transaction.transactionIndex,
      `${label} transaction transactionIndex`,
    ),
  };
};

const normalizeReceipt = (receipt, label) => {
  if (!receipt || typeof receipt !== "object")
    fail(`${label} receipt is malformed`);
  if (!Array.isArray(receipt.logs)) fail(`${label} receipt logs are missing`);
  const normalized = {
    transactionHash: hash32(
      receipt.transactionHash,
      `${label} receipt transactionHash`,
    ),
    status: quantity(receipt.status, `${label} receipt status`),
    from: address(receipt.from, `${label} receipt sender`, {
      allowZero: false,
    }),
    to: address(receipt.to, `${label} receipt target`, { allowZero: false }),
    blockHash: hash32(receipt.blockHash, `${label} receipt blockHash`),
    blockNumber: quantity(receipt.blockNumber, `${label} receipt blockNumber`),
    transactionIndex: quantity(
      receipt.transactionIndex,
      `${label} receipt transactionIndex`,
    ),
  };
  const optionalFields = [
    ["contractAddress", optionalAddress],
    ["cumulativeGasUsed", optionalQuantity],
    ["gasUsed", optionalQuantity],
    ["effectiveGasPrice", optionalQuantity],
    ["gasUsedForL1", optionalQuantity],
    ["l1BlockNumber", optionalQuantity],
    ["type", optionalQuantity],
    ["logsBloom", optionalHex],
  ];
  for (const [field, normalize] of optionalFields) {
    const value = normalize(receipt[field], `${label} receipt ${field}`);
    if (value !== undefined) normalized[field] = value;
  }
  normalized.logs = receipt.logs.map((log, index) =>
    normalizeLog(log, index, normalized, `${label} receipt`),
  );
  for (let index = 1; index < normalized.logs.length; index += 1) {
    if (
      BigInt(normalized.logs[index].logIndex) <=
      BigInt(normalized.logs[index - 1].logIndex)
    ) {
      fail(`${label} receipt logs are not in canonical log-index order`);
    }
  }
  return normalized;
};

const normalizePair = (record, label) => {
  if (!record || typeof record !== "object")
    fail(`${label} evidence pair is missing`);
  for (const [object, path, kind] of [
    [record.transaction, record.transactionPath, "transaction"],
    [record.receipt, record.receiptPath, "receipt"],
  ]) {
    if (typeof path !== "string" || path === "")
      fail(`${label} ${kind} path is missing`);
    assert.deepStrictEqual(
      object,
      readJson(path),
      `${label} ${kind} object differs from the raw evidence bytes supplied by path`,
    );
  }
  const transaction = normalizeTransaction(record.transaction, label);
  const receipt = normalizeReceipt(record.receipt, label);
  if (!sameHex(transaction.hash, receipt.transactionHash)) {
    fail(`${label} transaction and receipt hashes differ`);
  }
  if (receipt.status !== "1") fail(`${label} transaction did not succeed`);
  if (
    !sameHex(transaction.from, receipt.from) ||
    !sameHex(transaction.to, receipt.to)
  ) {
    fail(`${label} transaction and receipt sender/target differ`);
  }
  if (
    !sameHex(transaction.blockHash, receipt.blockHash) ||
    transaction.blockNumber !== receipt.blockNumber ||
    transaction.transactionIndex !== receipt.transactionIndex
  ) {
    fail(`${label} transaction and receipt canonical coordinates differ`);
  }
  if (transaction.chainId !== CHAIN_ID.toString()) {
    fail(`${label} transaction is not on chain ${CHAIN_ID}`);
  }
  return {
    transaction,
    receipt,
    raw: {
      transactionPath: repoRelativePath(record.transactionPath),
      transactionSha256: sha256File(record.transactionPath),
      receiptPath: repoRelativePath(record.receiptPath),
      receiptSha256: sha256File(record.receiptPath),
    },
  };
};

const exactCall = (pair, target, abi, functionName, args, label) => {
  if (!sameHex(pair.transaction.to, target))
    fail(`${label} target is not ${target}`);
  if (pair.transaction.value !== "0")
    fail(`${label} sends nonzero native value`);
  const expected = encodeFunctionData({
    abi,
    functionName,
    args,
  }).toLowerCase();
  if (pair.transaction.input !== expected) {
    fail(`${label} calldata is not the exact reviewed ${functionName} call`);
  }
};

const permissionlessCallMode = (
  pair,
  target,
  abi,
  functionName,
  args,
  label,
) => {
  if (!sameHex(pair.transaction.to, target)) return "nested";
  if (pair.transaction.value !== "0")
    fail(`${label} direct call sends nonzero native value`);
  const expected = encodeFunctionData({
    abi,
    functionName,
    args,
  }).toLowerCase();
  if (!pair.transaction.input.startsWith(expected)) {
    fail(
      `${label} direct calldata is not ABI-equivalent to the reviewed ${functionName} call`,
    );
  }
  return "direct";
};

const exactClaimTokensCall = (pair, target, bid, owner, label) => {
  if (!sameHex(pair.transaction.to, target)) return "nested";
  if (pair.transaction.value !== "0")
    fail(`${label} direct call sends nonzero native value`);
  const direct = encodeFunctionData({
    abi: AUCTION_ABI,
    functionName: "claimTokens",
    args: [BigInt(bid)],
  }).toLowerCase();
  if (pair.transaction.input.startsWith(direct)) return "claimTokens";

  let decoded;
  try {
    decoded = decodeFunctionData({
      abi: AUCTION_ABI,
      data: pair.transaction.input,
    });
  } catch {
    fail(
      `${label} calldata is neither reviewed claimTokens nor claimTokensBatch`,
    );
  }
  if (decoded.functionName !== "claimTokensBatch") {
    fail(
      `${label} calldata is neither reviewed claimTokens nor claimTokensBatch`,
    );
  }
  const [batchOwner, bidIds] = decoded.args ?? [];
  if (!sameHex(batchOwner, owner) || !Array.isArray(bidIds)) {
    fail(`${label} claimTokensBatch owner/bid array is malformed`);
  }
  const matchingBids = bidIds.filter(
    (candidate) => BigInt(candidate) === BigInt(bid),
  );
  if (matchingBids.length === 0) {
    fail(`${label} claimTokensBatch must contain the canary bid`);
  }
  const canonical = encodeFunctionData({
    abi: AUCTION_ABI,
    functionName: "claimTokensBatch",
    args: [batchOwner, bidIds],
  }).toLowerCase();
  if (!pair.transaction.input.startsWith(canonical)) {
    fail(
      `${label} claimTokensBatch ABI encoding is not equivalent to the decoded call`,
    );
  }
  return "claimTokensBatch";
};

const allEvents = (pair, emitter, abi, eventName, label) => {
  const topic = EVENT_TOPICS[eventName];
  const matches = pair.receipt.logs.filter(
    (log) => sameHex(log.address, emitter) && sameHex(log.topics[0], topic),
  );
  return matches.map((log, index) => {
    try {
      return {
        log,
        args: decodeEventLog({
          abi,
          eventName,
          data: log.data,
          topics: log.topics,
          strict: true,
        }).args,
      };
    } catch {
      fail(`${label} ${eventName} event #${index} is malformed`);
    }
  });
};

const onlyEvent = (pair, emitter, abi, eventName, label) => {
  const matches = allEvents(pair, emitter, abi, eventName, label);
  if (matches.length !== 1) {
    fail(
      `${label} emitted ${matches.length} ${eventName} events from ${emitter}, expected one`,
    );
  }
  return matches[0];
};

const logCoordinateBefore = (left, right) => {
  const leftBlock = BigInt(left.blockNumber);
  const rightBlock = BigInt(right.blockNumber);
  if (leftBlock !== rightBlock) return leftBlock < rightBlock;
  const leftTransaction = BigInt(left.transactionIndex);
  const rightTransaction = BigInt(right.transactionIndex);
  if (leftTransaction !== rightTransaction)
    return leftTransaction < rightTransaction;
  return BigInt(left.logIndex) < BigInt(right.logIndex);
};

const eventLogReference = (event) => ({
  logIndex: event.log.logIndex,
  transactionHash: event.log.transactionHash,
});

/**
 * Build deterministic Phase-B evidence from six canonical action references. The five
 * permissionless outcomes intentionally have no signer/nonce relationship and may share a helper
 * transaction/receipt; only the owner-only buyback is direct and sender-bound. Consequently,
 * unrelated keeper actions may interleave while the three protocol-causal edges remain strict.
 */
export function buildV5PhaseBEvidence(context) {
  const {
    pairs,
    sourceCommit,
    token,
    auction,
    bidId,
    launchpad,
    burner,
    owner,
    poolManager,
    poolId,
    hook,
    hookrToken,
    phaseAAccrual,
  } = context ?? {};
  const source = fullCommit(sourceCommit, "sourceCommit");
  const canaryToken = address(token, "auction token", { allowZero: false });
  const canaryAuction = address(auction, "auction", { allowZero: false });
  const canaryBidId = quantity(bidId, "bid id");
  const pad = address(launchpad, "launchpad", { allowZero: false });
  const flywheel = address(burner, "burner", { allowZero: false });
  const canaryOwner = address(owner, "owner", { allowZero: false });
  const manager = address(poolManager, "PoolManager", { allowZero: false });
  const canonicalPoolId = hash32(poolId, "canonical pool id");
  const reviewedHook = address(hook, "Hookr hook", { allowZero: false });
  const reviewedHookrToken = address(hookrToken, "HOOKR token", {
    allowZero: false,
  });
  if (!phaseAAccrual || typeof phaseAAccrual !== "object") {
    fail("phase A flywheel accrual reference is missing");
  }
  const accrual = {
    transactionHash: hash32(
      phaseAAccrual.transactionHash,
      "phase A flywheel accrual transactionHash",
    ),
    blockNumber: quantity(
      phaseAAccrual.blockNumber,
      "phase A flywheel accrual blockNumber",
    ),
    transactionIndex: quantity(
      phaseAAccrual.transactionIndex,
      "phase A flywheel accrual transactionIndex",
    ),
    logIndex: quantity(
      phaseAAccrual.logIndex,
      "phase A flywheel accrual logIndex",
    ),
    poolId: hash32(phaseAAccrual.poolId, "phase A flywheel accrual poolId"),
    amountWei: quantity(
      phaseAAccrual.amountWei,
      "phase A flywheel accrual amountWei",
    ),
  };
  if (BigInt(accrual.amountWei) !== FLYWHEEL_ETH_IN) {
    fail(`phase A flywheel accrual is not exactly ${FLYWHEEL_ETH_IN}`);
  }

  const normalized = Object.fromEntries(
    V5_PHASE_B_ACTIONS.map((name) => [
      name,
      normalizePair(pairs?.[name], `phase B/${name}`),
    ]),
  );
  const migrateCall = permissionlessCallMode(
    normalized.migrateAuction,
    pad,
    LAUNCHPAD_ABI,
    "migrateAuction",
    [canaryToken],
    "phase B migrateAuction",
  );
  const exitCall = permissionlessCallMode(
    normalized.exitBid,
    canaryAuction,
    AUCTION_ABI,
    "exitBid",
    [BigInt(canaryBidId)],
    "phase B exitBid",
  );
  const claimTokensCall = exactClaimTokensCall(
    normalized.claimTokens,
    canaryAuction,
    canaryBidId,
    canaryOwner,
    "phase B claimTokens",
  );
  const collectCall = permissionlessCallMode(
    normalized.collect,
    flywheel,
    BURNER_ABI,
    "collect",
    [],
    "phase B collect",
  );
  exactCall(
    normalized.buybackAndBurn,
    flywheel,
    BURNER_ABI,
    "buybackAndBurn",
    [FLYWHEEL_ETH_IN, FLYWHEEL_MIN_HOOKR_OUT],
    "phase B buybackAndBurn",
  );
  if (!sameHex(normalized.buybackAndBurn.transaction.from, canaryOwner)) {
    fail("phase B buybackAndBurn sender is not the exact release owner");
  }

  const migratedMatches = allEvents(
    normalized.migrateAuction,
    pad,
    LAUNCHPAD_ABI,
    "Migrated",
    "phase B migrateAuction",
  ).filter(
    (event) =>
      sameHex(event.args.token, canaryToken) &&
      sameHex(event.args.poolId, canonicalPoolId),
  );
  if (migratedMatches.length !== 1) {
    fail(
      `phase B migration receipt has ${migratedMatches.length} exact canary Migrated events, expected one`,
    );
  }
  const migrated = migratedMatches[0];
  if (BigInt(migrated.args.sqrtPriceX96) === 0n) {
    fail("phase B Migrated sqrtPriceX96 is zero");
  }
  const migratedEthLiquidity = BigInt(migrated.args.ethLiquidity);
  const migratedTokenLiquidity = BigInt(migrated.args.tokenLiquidity);
  const migratedTokensBurned = BigInt(migrated.args.tokensBurned);
  if (migratedEthLiquidity === 0n || migratedTokenLiquidity === 0n) {
    fail("phase B Migrated liquidity legs must both be nonzero");
  }
  if (
    migratedTokenLiquidity + migratedTokensBurned !==
    AUCTION_RESERVE_TOKENS
  ) {
    fail(
      `phase B Migrated token liquidity and burn do not conserve the exact ${AUCTION_RESERVE_TOKENS} reserve`,
    );
  }

  const allAuctionProceeds = allEvents(
    normalized.migrateAuction,
    pad,
    LAUNCHPAD_ABI,
    "AuctionProceeds",
    "phase B migrateAuction",
  );
  const tokenAuctionProceeds = allAuctionProceeds.filter((event) =>
    sameHex(event.args.token, canaryToken),
  );
  const auctionProceedsMatches = tokenAuctionProceeds.filter((event) =>
    sameHex(event.args.creator, canaryOwner),
  );
  const proceedsPairAliasesMigration =
    isDeepStrictEqual(
      normalized.claimAuctionProceeds.transaction,
      normalized.migrateAuction.transaction,
    ) &&
    isDeepStrictEqual(
      normalized.claimAuctionProceeds.receipt,
      normalized.migrateAuction.receipt,
    );
  const proceedsNotApplicable =
    proceedsPairAliasesMigration && tokenAuctionProceeds.length === 0;
  if (
    !proceedsNotApplicable &&
    (tokenAuctionProceeds.length !== 1 || auctionProceedsMatches.length !== 1)
  ) {
    fail(
      `phase B migration receipt has ${auctionProceedsMatches.length} exact canary AuctionProceeds events, expected one`,
    );
  }
  const auctionProceeds = auctionProceedsMatches[0] ?? null;
  const auctionProceedsWei =
    auctionProceeds === null ? 0n : BigInt(auctionProceeds.args.amountWei);
  if (!proceedsNotApplicable && auctionProceedsWei === 0n) {
    fail("phase B AuctionProceeds amount is zero");
  }
  const proceedsCall = proceedsNotApplicable
    ? NOT_APPLICABLE_ZERO_PROCEEDS
    : permissionlessCallMode(
        normalized.claimAuctionProceeds,
        pad,
        LAUNCHPAD_ABI,
        "claimAuctionProceeds",
        [canaryToken],
        "phase B claimAuctionProceeds",
      );

  const currencySwept = onlyEvent(
    normalized.migrateAuction,
    canaryAuction,
    AUCTION_ABI,
    "CurrencySwept",
    "phase B migrateAuction",
  );
  if (!sameHex(currencySwept.args.fundsRecipient, pad)) {
    fail("phase B CurrencySwept funds recipient is not the launchpad");
  }
  const currencySweptWei = BigInt(currencySwept.args.currencyAmount);
  if (currencySweptWei === 0n) fail("phase B CurrencySwept amount is zero");
  if (proceedsNotApplicable) {
    if (migratedEthLiquidity !== currencySweptWei) {
      fail(
        "phase B zero-proceeds migration ETH liquidity does not equal receipt-local currency swept",
      );
    }
  } else if (migratedEthLiquidity + auctionProceedsWei !== currencySweptWei) {
    fail(
      "phase B migrated ETH liquidity plus creator proceeds does not equal receipt-local currency swept",
    );
  }

  const initializedMatches = allEvents(
    normalized.migrateAuction,
    manager,
    POOL_MANAGER_ABI,
    "Initialize",
    "phase B migrateAuction",
  ).filter((event) => sameHex(event.args.id, canonicalPoolId));
  if (initializedMatches.length !== 1) {
    fail(
      `phase B migration receipt has ${initializedMatches.length} exact canonical-pool Initialize events, expected one`,
    );
  }
  const initialized = initializedMatches[0];
  const initializedPoolId = keccak256(
    encodeAbiParameters(
      [{ type: "tuple", components: POOL_KEY_COMPONENTS }],
      [
        [
          initialized.args.currency0,
          initialized.args.currency1,
          initialized.args.fee,
          initialized.args.tickSpacing,
          initialized.args.hooks,
        ],
      ],
    ),
  );
  if (
    !sameHex(initialized.args.id, canonicalPoolId) ||
    !sameHex(initializedPoolId, canonicalPoolId)
  ) {
    fail(
      "phase B PoolManager Initialize does not reconstruct the canonical pool id",
    );
  }
  if (
    !sameHex(initialized.args.currency0, ZERO_ADDRESS) ||
    !sameHex(initialized.args.currency1, canaryToken)
  ) {
    fail("phase B PoolManager Initialize is not the auction token ETH pool");
  }
  if (
    BigInt(initialized.args.fee) !== DYNAMIC_FEE_FLAG ||
    BigInt(initialized.args.tickSpacing) !== POOL_TICK_SPACING ||
    !sameHex(initialized.args.hooks, reviewedHook)
  ) {
    fail(
      "phase B PoolManager Initialize does not use the exact reviewed fee/tick/hook key",
    );
  }
  if (
    BigInt(initialized.args.sqrtPriceX96) !== BigInt(migrated.args.sqrtPriceX96)
  ) {
    fail("phase B Migrated and PoolManager Initialize opening prices differ");
  }
  const migrationOrderValid = proceedsNotApplicable
    ? BigInt(currencySwept.log.logIndex) < BigInt(initialized.log.logIndex) &&
      BigInt(initialized.log.logIndex) < BigInt(migrated.log.logIndex)
    : BigInt(currencySwept.log.logIndex) < BigInt(initialized.log.logIndex) &&
      BigInt(initialized.log.logIndex) < BigInt(auctionProceeds.log.logIndex) &&
      BigInt(auctionProceeds.log.logIndex) < BigInt(migrated.log.logIndex);
  if (!migrationOrderValid) {
    fail(
      proceedsNotApplicable
        ? "phase B zero-proceeds migration events are not in CurrencySwept < Initialize < Migrated order"
        : "phase B migration events are not in CurrencySwept < Initialize < AuctionProceeds < Migrated order",
    );
  }

  const exitedMatches = allEvents(
    normalized.exitBid,
    canaryAuction,
    AUCTION_ABI,
    "BidExited",
    "phase B exitBid",
  ).filter(
    (event) =>
      BigInt(event.args.bidId) === BigInt(canaryBidId) &&
      sameHex(event.args.owner, canaryOwner),
  );
  if (exitedMatches.length !== 1) {
    fail(
      `phase B exit receipt has ${exitedMatches.length} exact canary BidExited events, expected one`,
    );
  }
  const exited = exitedMatches[0];
  if (BigInt(exited.args.tokensFilled) === 0n)
    fail("phase B BidExited filled zero tokens");

  const allClaimed = allEvents(
    normalized.claimTokens,
    canaryAuction,
    AUCTION_ABI,
    "TokensClaimed",
    "phase B claimTokens",
  );
  const ownerClaimed = allClaimed.filter((event) =>
    sameHex(event.args.owner, canaryOwner),
  );
  const claimedMatches = ownerClaimed.filter(
    (event) =>
      BigInt(event.args.bidId) === BigInt(canaryBidId) &&
      sameHex(event.args.owner, canaryOwner),
  );
  if (claimedMatches.length !== 1) {
    fail(
      `phase B claim receipt has ${claimedMatches.length} exact canary TokensClaimed events, expected one`,
    );
  }
  const claimed = claimedMatches[0];
  if (BigInt(claimed.args.tokensFilled) !== BigInt(exited.args.tokensFilled)) {
    fail("phase B TokensClaimed fill differs from BidExited");
  }
  if (claimTokensCall === "claimTokens" && ownerClaimed.length !== 1) {
    fail("phase B direct claim receipt contains extra TokensClaimed events");
  }
  if (claimTokensCall === "claimTokensBatch") {
    const [, bidIds] = decodeFunctionData({
      abi: AUCTION_ABI,
      data: normalized.claimTokens.transaction.input,
    }).args;
    const requestedBidIds = new Set(
      bidIds.map((candidate) => BigInt(candidate).toString()),
    );
    const emittedBidIds = new Set();
    for (const event of ownerClaimed) {
      const emittedBidId = BigInt(event.args.bidId).toString();
      if (!requestedBidIds.has(emittedBidId)) {
        fail(
          "phase B batch claim emitted TokensClaimed for a bid absent from calldata",
        );
      }
      if (emittedBidIds.has(emittedBidId)) {
        fail("phase B batch claim emitted duplicate TokensClaimed for one bid");
      }
      emittedBidIds.add(emittedBidId);
    }
  }
  const canaryTransfers = allEvents(
    normalized.claimTokens,
    canaryToken,
    TOKEN_ABI,
    "Transfer",
    "phase B claimTokens",
  ).filter(
    (event) =>
      sameHex(event.args.from, canaryAuction) &&
      sameHex(event.args.to, canaryOwner),
  );
  if (canaryTransfers.length === 0) {
    fail("phase B claim receipt has no auction-to-owner token Transfer");
  }
  if (claimTokensCall !== "nested" && canaryTransfers.length !== 1) {
    fail(
      `phase B direct claim receipt has ${canaryTransfers.length} auction-to-owner token Transfers, expected one`,
    );
  }
  const transferredToOwner = canaryTransfers.reduce(
    (sum, event) => sum + BigInt(event.args.value),
    0n,
  );
  const totalClaimed = ownerClaimed.reduce(
    (sum, event) => sum + BigInt(event.args.tokensFilled),
    0n,
  );
  if (transferredToOwner !== totalClaimed) {
    fail(
      "phase B auction-to-owner token Transfer does not equal the sum of TokensClaimed events",
    );
  }

  const allCreatorFeesClaimed = allEvents(
    normalized.claimAuctionProceeds,
    pad,
    LAUNCHPAD_ABI,
    "CreatorFeesClaimed",
    "phase B claimAuctionProceeds",
  );
  const tokenCreatorFeesClaimed = allCreatorFeesClaimed.filter((event) =>
    sameHex(event.args.token, canaryToken),
  );
  if (proceedsNotApplicable && tokenCreatorFeesClaimed.length !== 0) {
    fail(
      "phase B zero-proceeds migration receipt must not contain CreatorFeesClaimed",
    );
  }
  const proceedsMatches = tokenCreatorFeesClaimed.filter(
    (event) =>
      sameHex(event.args.payTo, canaryOwner) &&
      BigInt(event.args.amountWei) === auctionProceedsWei,
  );
  if (!proceedsNotApplicable && proceedsMatches.length !== 1) {
    fail(
      `phase B proceeds receipt has ${proceedsMatches.length} exact CreatorFeesClaimed events, expected one`,
    );
  }
  const proceeds = proceedsMatches[0] ?? null;
  if (!proceedsNotApplicable && BigInt(proceeds.args.amountWei) === 0n) {
    fail("phase B proceeds CreatorFeesClaimed amount is zero");
  }
  if (
    !proceedsNotApplicable &&
    BigInt(proceeds.args.amountWei) !== auctionProceedsWei
  ) {
    fail(
      "phase B claimed creator proceeds differ from receipt-local AuctionProceeds",
    );
  }

  const collected = onlyEvent(
    normalized.collect,
    flywheel,
    BURNER_ABI,
    "FlywheelCollected",
    "phase B collect",
  );
  const collectedWei = quantity(
    collected.args.amountWei,
    "FlywheelCollected amount",
  );
  // collect() delegates to HookrHook.claim(), which reverts at zero. The collector selects the
  // first successful post-accrual claim, so it must include at least the exact canary accrual even
  // when a permissionless keeper executed it before the owner returned.
  if (BigInt(collectedWei) < FLYWHEEL_ETH_IN) {
    fail(
      `phase B FlywheelCollected amount is below the exact ${FLYWHEEL_ETH_IN} accrual`,
    );
  }
  const hookClaimedMatches = allEvents(
    normalized.collect,
    reviewedHook,
    HOOK_ABI,
    "Claimed",
    "phase B collect",
  ).filter(
    (event) =>
      sameHex(event.args.account, flywheel) &&
      BigInt(event.args.amountWei) === BigInt(collectedWei),
  );
  if (hookClaimedMatches.length !== 1) {
    fail(
      `phase B collect receipt has ${hookClaimedMatches.length} exact hook Claimed events, expected one`,
    );
  }
  const hookClaimed = hookClaimedMatches[0];

  const burned = onlyEvent(
    normalized.buybackAndBurn,
    flywheel,
    BURNER_ABI,
    "BuybackBurned",
    "phase B buybackAndBurn",
  );
  if (!sameHex(burned.args.caller, canaryOwner)) {
    fail("phase B BuybackBurned caller is not the exact release owner");
  }
  if (BigInt(burned.args.ethIn) !== FLYWHEEL_ETH_IN) {
    fail(`phase B BuybackBurned ETH spent is not exactly ${FLYWHEEL_ETH_IN}`);
  }
  if (BigInt(burned.args.hookrBurned) < FLYWHEEL_MIN_HOOKR_OUT) {
    fail(
      `phase B BuybackBurned HOOKR burned is below ${FLYWHEEL_MIN_HOOKR_OUT}`,
    );
  }
  const deadTransfers = allEvents(
    normalized.buybackAndBurn,
    reviewedHookrToken,
    TOKEN_ABI,
    "Transfer",
    "phase B buybackAndBurn",
  ).filter(
    (event) =>
      sameHex(event.args.from, flywheel) &&
      sameHex(event.args.to, DEAD_ADDRESS),
  );
  if (deadTransfers.length !== 1) {
    fail(
      `phase B buyback receipt has ${deadTransfers.length} exact burner-to-dead HOOKR transfers, expected one`,
    );
  }
  const deadTransfer = deadTransfers[0];
  if (BigInt(deadTransfer.args.value) !== BigInt(burned.args.hookrBurned)) {
    fail("phase B HOOKR dead transfer differs from BuybackBurned output");
  }
  if (BigInt(deadTransfer.log.logIndex) >= BigInt(burned.log.logIndex)) {
    fail("phase B HOOKR dead transfer does not precede BuybackBurned");
  }

  const causalEventPairs = [
    [exited.log, claimed.log, "exitBid before claimTokens"],
    [collected.log, burned.log, "collect before buybackAndBurn"],
  ];
  if (!proceedsNotApplicable) {
    causalEventPairs.splice(1, 0, [
      migrated.log,
      proceeds.log,
      "migrateAuction before claimAuctionProceeds",
    ]);
  }
  for (const [beforeEvent, afterEvent, label] of causalEventPairs) {
    if (!logCoordinateBefore(beforeEvent, afterEvent)) {
      fail(`phase B protocol causality violated: ${label}`);
    }
  }
  const accrualBeforeCollect = logCoordinateBefore(accrual, collected.log);
  if (!accrualBeforeCollect) {
    fail("phase B protocol causality violated: Phase-A accrual before collect");
  }

  const action = (name, eventEvidence) => ({
    transaction: normalized[name].transaction,
    receipt: normalized[name].receipt,
    raw: normalized[name].raw,
    events: eventEvidence,
  });

  return {
    kind: KIND,
    evidencePolicy: POLICY,
    chainId: CHAIN_ID.toString(),
    sourceCommit: source,
    identities: {
      token: canaryToken,
      auction: canaryAuction,
      bidId: canaryBidId,
      launchpad: pad,
      burner: flywheel,
      owner: canaryOwner,
      poolManager: manager,
      poolId: canonicalPoolId,
      hook: reviewedHook,
      hookrToken: reviewedHookrToken,
      phaseAAccrual: accrual,
    },
    reviewedSemantics: {
      firstFiveCallsPermissionless: true,
      buybackOwnerOnly: true,
      buybackEthInWei: FLYWHEEL_ETH_IN.toString(),
      buybackMinHookrOut: FLYWHEEL_MIN_HOOKR_OUT.toString(),
      permissionlessPrecollectionAccepted: true,
      causalEdges: [
        "exitBid<claimTokens",
        ...(proceedsNotApplicable
          ? []
          : ["migrateAuction<claimAuctionProceeds"]),
        "collect<buybackAndBurn",
        "phaseAAccrual<collect",
      ],
    },
    actions: {
      migrateAuction: action("migrateAuction", {
        call: migrateCall,
        migrated: {
          ...eventLogReference(migrated),
          token: address(migrated.args.token, "Migrated token"),
          poolId: hash32(migrated.args.poolId, "Migrated pool id"),
          sqrtPriceX96: quantity(
            migrated.args.sqrtPriceX96,
            "Migrated sqrtPriceX96",
          ),
          ethLiquidity: quantity(
            migrated.args.ethLiquidity,
            "Migrated ethLiquidity",
          ),
          tokenLiquidity: quantity(
            migrated.args.tokenLiquidity,
            "Migrated tokenLiquidity",
          ),
          tokensBurned: quantity(
            migrated.args.tokensBurned,
            "Migrated tokensBurned",
          ),
        },
        auctionProceeds: proceedsNotApplicable
          ? null
          : {
              ...eventLogReference(auctionProceeds),
              token: address(
                auctionProceeds.args.token,
                "AuctionProceeds token",
              ),
              creator: address(
                auctionProceeds.args.creator,
                "AuctionProceeds creator",
              ),
              amountWei: quantity(
                auctionProceeds.args.amountWei,
                "AuctionProceeds amountWei",
              ),
            },
        currencySwept: {
          ...eventLogReference(currencySwept),
          fundsRecipient: address(
            currencySwept.args.fundsRecipient,
            "CurrencySwept fundsRecipient",
          ),
          amountWei: quantity(
            currencySwept.args.currencyAmount,
            "CurrencySwept currencyAmount",
          ),
        },
        poolInitialized: {
          ...eventLogReference(initialized),
          id: hash32(initialized.args.id, "Initialize pool id"),
          currency0: address(
            initialized.args.currency0,
            "Initialize currency0",
          ),
          currency1: address(
            initialized.args.currency1,
            "Initialize currency1",
          ),
          fee: quantity(initialized.args.fee, "Initialize fee"),
          tickSpacing: quantity(
            initialized.args.tickSpacing,
            "Initialize tickSpacing",
          ),
          hooks: address(initialized.args.hooks, "Initialize hooks"),
          sqrtPriceX96: quantity(
            initialized.args.sqrtPriceX96,
            "Initialize sqrtPriceX96",
          ),
          tick: quantity(initialized.args.tick, "Initialize tick"),
        },
      }),
      exitBid: action("exitBid", {
        call: exitCall,
        bidExited: {
          ...eventLogReference(exited),
          bidId: quantity(exited.args.bidId, "BidExited bidId"),
          owner: address(exited.args.owner, "BidExited owner"),
          tokensFilled: quantity(
            exited.args.tokensFilled,
            "BidExited tokensFilled",
          ),
          currencyRefunded: quantity(
            exited.args.currencyRefunded,
            "BidExited currencyRefunded",
          ),
        },
      }),
      claimTokens: action("claimTokens", {
        call: claimTokensCall,
        tokensClaimed: {
          ...eventLogReference(claimed),
          bidId: quantity(claimed.args.bidId, "TokensClaimed bidId"),
          owner: address(claimed.args.owner, "TokensClaimed owner"),
          tokensFilled: quantity(
            claimed.args.tokensFilled,
            "TokensClaimed tokensFilled",
          ),
        },
        auctionToOwnerTransfers: {
          count: canaryTransfers.length,
          aggregateAmount: transferredToOwner.toString(),
          logIndexes: canaryTransfers.map((event) => event.log.logIndex),
        },
      }),
      claimAuctionProceeds: action(
        "claimAuctionProceeds",
        proceedsNotApplicable
          ? {
              call: NOT_APPLICABLE_ZERO_PROCEEDS,
              mode: NOT_APPLICABLE_ZERO_PROCEEDS,
              executionMode: "not-applicable",
              creatorFeesClaimed: null,
              notApplicable: {
                executionMode: "not-applicable",
                mode: NOT_APPLICABLE_ZERO_PROCEEDS,
                token: canaryToken,
                amountWei: "0",
                proofTransactionHash:
                  normalized.migrateAuction.transaction.hash,
              },
            }
          : {
              call: proceedsCall,
              creatorFeesClaimed: {
                ...eventLogReference(proceeds),
                sourceCall: "claimAuctionProceeds",
                token: address(proceeds.args.token, "CreatorFeesClaimed token"),
                payTo: address(proceeds.args.payTo, "CreatorFeesClaimed payTo"),
                amountWei: quantity(
                  proceeds.args.amountWei,
                  "CreatorFeesClaimed amountWei",
                ),
              },
            },
      ),
      collect: action("collect", {
        call: collectCall,
        flywheelCollected: {
          ...eventLogReference(collected),
          amountWei: collectedWei,
        },
        hookClaimed: {
          ...eventLogReference(hookClaimed),
          account: address(hookClaimed.args.account, "Claimed account"),
          amountWei: quantity(hookClaimed.args.amountWei, "Claimed amountWei"),
        },
      }),
      buybackAndBurn: action("buybackAndBurn", {
        buybackBurned: {
          ...eventLogReference(burned),
          caller: address(burned.args.caller, "BuybackBurned caller"),
          ethSpentWei: quantity(burned.args.ethIn, "BuybackBurned ethIn"),
          hookrBurned: quantity(
            burned.args.hookrBurned,
            "BuybackBurned hookrBurned",
          ),
        },
        hookrDeadTransfer: {
          ...eventLogReference(deadTransfer),
          token: reviewedHookrToken,
          from: address(deadTransfer.args.from, "HOOKR dead transfer from"),
          to: address(deadTransfer.args.to, "HOOKR dead transfer to"),
          amount: quantity(
            deadTransfer.args.value,
            "HOOKR dead transfer amount",
          ),
        },
      }),
    },
  };
}

export function assertV5PhaseBEvidence(evidence, context) {
  const expected = buildV5PhaseBEvidence(context);
  assert.deepStrictEqual(
    evidence,
    expected,
    "phase B evidence differs from its six canonical action transaction/receipt references",
  );
  return expected;
}

const isCli =
  process.argv[1] &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href;
if (isCli) {
  const args = process.argv.slice(2);
  const flag = (name) => {
    const index = args.indexOf(`--${name}`);
    if (index < 0 || !args[index + 1]) fail(`missing --${name}`);
    return args[index + 1];
  };
  const cliNames = Object.freeze({
    migrateAuction: "migrate-auction",
    exitBid: "exit-bid",
    claimTokens: "claim-tokens",
    claimAuctionProceeds: "claim-auction-proceeds",
    collect: "collect",
    buybackAndBurn: "buyback-and-burn",
  });
  const pairs = Object.fromEntries(
    V5_PHASE_B_ACTIONS.map((name) => {
      const prefix = cliNames[name];
      const transactionPath = flag(`${prefix}-transaction`);
      const receiptPath = flag(`${prefix}-receipt`);
      return [
        name,
        {
          transactionPath,
          transaction: readJson(transactionPath),
          receiptPath,
          receipt: readJson(receiptPath),
        },
      ];
    }),
  );
  const context = {
    pairs,
    sourceCommit: flag("source-commit"),
    token: flag("token"),
    auction: flag("auction"),
    bidId: flag("bid-id"),
    launchpad: flag("launchpad"),
    burner: flag("burner"),
    owner: flag("owner"),
    poolManager: flag("pool-manager"),
    poolId: flag("pool-id"),
    hook: flag("hook"),
    hookrToken: flag("hookr-token"),
    phaseAAccrual: {
      transactionHash: flag("phase-a-accrual-transaction-hash"),
      blockNumber: flag("phase-a-accrual-block-number"),
      transactionIndex: flag("phase-a-accrual-transaction-index"),
      logIndex: flag("phase-a-accrual-log-index"),
      poolId: flag("phase-a-accrual-pool-id"),
      amountWei: flag("phase-a-accrual-amount-wei"),
    },
  };
  const outputPath = flag("output");
  const expected = buildV5PhaseBEvidence(context);
  if (args.includes("--write")) {
    writeFileSync(outputPath, `${JSON.stringify(expected, null, 2)}\n`, {
      mode: 0o600,
      flag: "wx",
    });
  } else {
    assertV5PhaseBEvidence(readJson(outputPath), context);
  }
  process.stdout.write(
    `${args.includes("--write") ? "wrote" : "verified"} ${outputPath}\n`,
  );
}
