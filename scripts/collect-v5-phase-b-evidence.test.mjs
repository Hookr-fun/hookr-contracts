import assert from "node:assert/strict";
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import test from "node:test";
import {
  encodeAbiParameters,
  encodeFunctionData,
  encodeFunctionResult,
  parseAbi,
  toEventSelector,
  zeroAddress,
} from "viem";

import {
  buildV5PhaseBEvidence,
  V5_PHASE_B_ACTIONS,
} from "./build-v5-phase-b-evidence.mjs";
import {
  PHASE_B_ACTIONS,
  collectV5PhaseBEvidence,
  redactRpcMessage,
  validatePhaseACollectorIndex,
} from "./collect-v5-phase-b-evidence.mjs";
import { poolIdForKey } from "./lib/instant-canary-evidence.mjs";

const CHAIN_ID = 4_663n;
const POOL_MANAGER = "0x8366a39cc670b4001a1121b8f6a443a643e40951";
const DEAD = "0x000000000000000000000000000000000000dead";
const OWNER = "0x1111111111111111111111111111111111111111";
const LAUNCHPAD = "0x2222222222222222222222222222222222222222";
const HOOK = "0x3333333333333333333333333333333333333333";
const HOOKR = "0x4444444444444444444444444444444444444444";
const INSTANT_TOKEN = "0x5555555555555555555555555555555555555555";
const AUCTION_TOKEN = "0x6666666666666666666666666666666666666666";
const AUCTION = "0x7777777777777777777777777777777777777777";
const BURNER = "0x8888888888888888888888888888888888888888";
const ROUTER = "0x9999999999999999999999999999999999999999";
const HELPER = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const OTHER_OWNER = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const OTHER_TOKEN = "0xcccccccccccccccccccccccccccccccccccccccc";
const SOURCE_COMMIT = "ab".repeat(20);
const RECOVERY_COMMIT = "ef".repeat(20);
const DEPLOYMENT_COMMIT = "cd".repeat(20);
const BID_ID = 19n;
const AUCTION_END = 120n;
const FILL = 100n * 10n ** 18n;
const PROCEEDS = 8_000_000_000_000_000n;
const ETH_LIQUIDITY = 2_000_000_000_000_000n;
const CURRENCY_SWEPT = ETH_LIQUIDITY + PROCEEDS;
const FLYWHEEL = 3_000_000_000_000n;
const REVIEWED_MIN_HOOKR_OUT = 3n * 10n ** 18n;
const REVIEWED_BID_AMOUNT = 10_500_000_000_000_000n;
const REVIEWED_RECOVERY_BID_MAX_PRICE =
  814_814_390_533_794_434_497_901_791_991_308_996_217n;
const HOOKR_BURNED = 3_494_135_610_596_751_569n;
const SQRT_PRICE = 12_345_678_901_234n;
const DYNAMIC_FEE = 0x800000;
const TICK_SPACING = 60;

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

const INSTANT_POOL_ID = poolIdForKey({
  currency0: zeroAddress,
  currency1: INSTANT_TOKEN,
  fee: DYNAMIC_FEE,
  tickSpacing: TICK_SPACING,
  hooks: HOOK,
}).toLowerCase();
const AUCTION_POOL_ID = poolIdForKey({
  currency0: zeroAddress,
  currency1: AUCTION_TOKEN,
  fee: DYNAMIC_FEE,
  tickSpacing: TICK_SPACING,
  hooks: HOOK,
}).toLowerCase();

const quantity = (value) => `0x${BigInt(value).toString(16)}`;
const word = (value) => `0x${BigInt(value).toString(16).padStart(64, "0")}`;
const addressTopic = (value) =>
  `0x${value.slice(2).toLowerCase().padStart(64, "0")}`;
const blockHash = (block) => word(50_000n + BigInt(block));
const transactionHash = (index) => word(100_000n + BigInt(index));
const eventData = (types, values) =>
  encodeAbiParameters(
    types.map((type) => ({ type })),
    values,
  );
const sameHex = (left, right) =>
  typeof left === "string" &&
  typeof right === "string" &&
  left.toLowerCase() === right.toLowerCase();

const actionSpecs = Object.freeze({
  instantBuy: {
    block: 100n,
    transactionIndex: 2n,
    sender: OWNER,
    target: ROUTER,
    nonce: 40n,
    input: "0x12345678",
  },
  ownerBid: {
    block: 119n,
    transactionIndex: 9n,
    sender: OWNER,
    target: AUCTION,
    nonce: 43n,
    value: REVIEWED_BID_AMOUNT,
    input: encodeFunctionData({
      abi: AUCTION_ABI,
      functionName: "submitBid",
      args: [REVIEWED_RECOVERY_BID_MAX_PRICE, REVIEWED_BID_AMOUNT, OWNER, "0x"],
    }),
  },
  collect: {
    block: 101n,
    transactionIndex: 4n,
    sender: "0xa100000000000000000000000000000000000001",
    target: BURNER,
    nonce: 91n,
    input: encodeFunctionData({ abi: BURNER_ABI, functionName: "collect" }),
  },
  exitBid: {
    block: 120n,
    transactionIndex: 7n,
    sender: "0xa200000000000000000000000000000000000002",
    target: AUCTION,
    nonce: 3n,
    input: encodeFunctionData({
      abi: AUCTION_ABI,
      functionName: "exitBid",
      args: [BID_ID],
    }),
  },
  migrateAuction: {
    block: 121n,
    transactionIndex: 1n,
    sender: "0xa300000000000000000000000000000000000003",
    target: LAUNCHPAD,
    nonce: 808n,
    input: encodeFunctionData({
      abi: LAUNCHPAD_ABI,
      functionName: "migrateAuction",
      args: [AUCTION_TOKEN],
    }),
  },
  claimTokens: {
    block: 122n,
    transactionIndex: 5n,
    sender: "0xa400000000000000000000000000000000000004",
    target: AUCTION,
    nonce: 1n,
    input: encodeFunctionData({
      abi: AUCTION_ABI,
      functionName: "claimTokensBatch",
      args: [OWNER, [7n, BID_ID, 29n]],
    }),
  },
  claimAuctionProceeds: {
    block: 123n,
    transactionIndex: 8n,
    sender: "0xa500000000000000000000000000000000000005",
    target: LAUNCHPAD,
    nonce: 33n,
    input: encodeFunctionData({
      abi: LAUNCHPAD_ABI,
      functionName: "claimAuctionProceeds",
      args: [AUCTION_TOKEN],
    }),
  },
  buybackAndBurn: {
    block: 124n,
    transactionIndex: 2n,
    sender: OWNER,
    target: BURNER,
    nonce: 41n,
    input: encodeFunctionData({
      abi: BURNER_ABI,
      functionName: "buybackAndBurn",
      args: [FLYWHEEL, REVIEWED_MIN_HOOKR_OUT],
    }),
  },
});
const rawEvent = (address, signature, indexed, types, values) => ({
  address,
  topics: [toEventSelector(signature), ...indexed],
  data: eventData(types, values),
});

const eventSpecs = Object.freeze({
  instantBuy: [
    { address: ROUTER, topics: [word(999n)], data: "0x" },
    rawEvent(
      HOOK,
      "FlywheelFeeAccrued(bytes32,uint256)",
      [INSTANT_POOL_ID],
      ["uint256"],
      [FLYWHEEL],
    ),
  ],
  ownerBid: [],
  collect: [
    rawEvent(
      HOOK,
      "Claimed(address,uint256)",
      [addressTopic(BURNER)],
      ["uint256"],
      [FLYWHEEL],
    ),
    rawEvent(BURNER, "FlywheelCollected(uint256)", [], ["uint256"], [FLYWHEEL]),
  ],
  exitBid: [
    rawEvent(
      AUCTION,
      "BidExited(uint256,address,uint256,uint256)",
      [word(BID_ID), addressTopic(OWNER)],
      ["uint256", "uint256"],
      [FILL, 500_000_000_000_000n],
    ),
  ],
  migrateAuction: [
    rawEvent(
      AUCTION,
      "CurrencySwept(address,uint256)",
      [addressTopic(LAUNCHPAD)],
      ["uint256"],
      [CURRENCY_SWEPT],
    ),
    rawEvent(
      POOL_MANAGER,
      "Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)",
      [AUCTION_POOL_ID, addressTopic(zeroAddress), addressTopic(AUCTION_TOKEN)],
      ["uint24", "int24", "address", "uint160", "int24"],
      [DYNAMIC_FEE, TICK_SPACING, HOOK, SQRT_PRICE, 111],
    ),
    rawEvent(
      LAUNCHPAD,
      "AuctionProceeds(address,address,uint256)",
      [addressTopic(AUCTION_TOKEN), addressTopic(OWNER)],
      ["uint256"],
      [PROCEEDS],
    ),
    rawEvent(
      LAUNCHPAD,
      "Migrated(address,bytes32,uint160,uint256,uint256,uint256)",
      [addressTopic(AUCTION_TOKEN), AUCTION_POOL_ID],
      ["uint160", "uint256", "uint256", "uint256"],
      [SQRT_PRICE, ETH_LIQUIDITY, 200_000_000n * 10n ** 18n - 7n, 7n],
    ),
  ],
  claimTokens: [
    rawEvent(
      AUCTION,
      "TokensClaimed(uint256,address,uint256)",
      [word(BID_ID), addressTopic(OWNER)],
      ["uint256"],
      [FILL],
    ),
    rawEvent(
      AUCTION,
      "TokensClaimed(uint256,address,uint256)",
      [word(7n), addressTopic(OWNER)],
      ["uint256"],
      [10n * 10n ** 18n],
    ),
    rawEvent(
      AUCTION_TOKEN,
      "Transfer(address,address,uint256)",
      [addressTopic(AUCTION), addressTopic(OWNER)],
      ["uint256"],
      [110n * 10n ** 18n],
    ),
  ],
  claimAuctionProceeds: [
    rawEvent(
      LAUNCHPAD,
      "CreatorFeesClaimed(address,address,uint256)",
      [addressTopic(AUCTION_TOKEN), addressTopic(OWNER)],
      ["uint256"],
      [PROCEEDS],
    ),
  ],
  buybackAndBurn: [
    rawEvent(
      HOOKR,
      "Transfer(address,address,uint256)",
      [addressTopic(BURNER), addressTopic(DEAD)],
      ["uint256"],
      [HOOKR_BURNED],
    ),
    rawEvent(
      BURNER,
      "BuybackBurned(address,uint256,uint256)",
      [addressTopic(OWNER)],
      ["uint256", "uint256"],
      [FLYWHEEL, HOOKR_BURNED],
    ),
  ],
});

const makePair = (key, ordinal) => {
  const spec = actionSpecs[key];
  const hash = transactionHash(ordinal);
  const canonicalBlockHash = blockHash(spec.block);
  const transaction = {
    hash,
    from: spec.sender,
    to: spec.target,
    nonce: quantity(spec.nonce),
    value: quantity(spec.value ?? 0n),
    input: spec.input,
    chainId: quantity(CHAIN_ID),
    blockHash: canonicalBlockHash,
    blockNumber: quantity(spec.block),
    transactionIndex: quantity(spec.transactionIndex),
  };
  const receipt = {
    transactionHash: hash,
    status: "0x1",
    from: spec.sender,
    to: spec.target,
    blockHash: canonicalBlockHash,
    blockNumber: quantity(spec.block),
    transactionIndex: quantity(spec.transactionIndex),
    logs: eventSpecs[key].map((log, logIndex) => ({
      ...log,
      blockHash: canonicalBlockHash,
      blockNumber: quantity(spec.block),
      transactionHash: hash,
      transactionIndex: quantity(spec.transactionIndex),
      logIndex: quantity(logIndex),
      removed: false,
    })),
  };
  return { transaction, receipt };
};

const encodeResult = (abi, functionName, result) =>
  encodeFunctionResult({ abi, functionName, result });

function fixture({
  omit = [],
  finalizedBlock = 200n,
  reorgAtFinal = false,
  phaseAVersion = 2,
  claimBatchBidIds = [7n, BID_ID, 29n],
  includeExtraClaim = true,
  sharedPermissionlessHelper = false,
  replacementBuyback = false,
  zeroAuctionProceeds = false,
  creatorProceedsOverride,
} = {}) {
  const omitted = new Set(omit);
  const pairs = new Map();
  let ordinal = 1;
  for (const key of [
    "instantBuy",
    "collect",
    "exitBid",
    "migrateAuction",
    "claimTokens",
    "claimAuctionProceeds",
    "buybackAndBurn",
  ]) {
    if (!omitted.has(key)) pairs.set(key, makePair(key, ordinal));
    ordinal += 1;
  }
  pairs.set("ownerBid", makePair("ownerBid", ordinal));
  const claimPair = pairs.get("claimTokens");
  if (claimPair) {
    claimPair.transaction.input = encodeFunctionData({
      abi: AUCTION_ABI,
      functionName: "claimTokensBatch",
      args: [OWNER, claimBatchBidIds],
    });
    if (!includeExtraClaim) {
      const [canaryClaim, , aggregateTransfer] = claimPair.receipt.logs;
      aggregateTransfer.data = eventData(["uint256"], [FILL]);
      aggregateTransfer.logIndex = quantity(1n);
      claimPair.receipt.logs = [canaryClaim, aggregateTransfer];
    }
  }
  if (zeroAuctionProceeds) {
    assert.equal(
      sharedPermissionlessHelper,
      false,
      "zero-proceeds fixtures do not use the shared helper fixture",
    );
    const migrationLogs = pairs.get("migrateAuction").receipt.logs;
    migrationLogs[0].data = eventData(["uint256"], [ETH_LIQUIDITY]);
    migrationLogs.splice(2, 1);
    migrationLogs.forEach((log, logIndex) => {
      log.logIndex = quantity(logIndex);
    });
    pairs.delete("claimAuctionProceeds");
  }
  if (replacementBuyback) {
    const pair = pairs.get("buybackAndBurn");
    const replacementBlock = 125n;
    const replacementHash = transactionHash(190n);
    const replacementBlockHash = blockHash(replacementBlock);
    pair.transaction.hash = replacementHash;
    pair.transaction.nonce = quantity(909n);
    pair.transaction.blockHash = replacementBlockHash;
    pair.transaction.blockNumber = quantity(replacementBlock);
    pair.receipt.transactionHash = replacementHash;
    pair.receipt.blockHash = replacementBlockHash;
    pair.receipt.blockNumber = quantity(replacementBlock);
    for (const log of pair.receipt.logs) {
      log.transactionHash = replacementHash;
      log.blockHash = replacementBlockHash;
      log.blockNumber = quantity(replacementBlock);
    }
  }
  if (sharedPermissionlessHelper) {
    const permissionlessKeys = [
      "migrateAuction",
      "exitBid",
      "claimTokens",
      "claimAuctionProceeds",
      "collect",
    ];
    const migrationLogs = pairs.get("migrateAuction").receipt.logs;
    const exitLog = pairs.get("exitBid").receipt.logs[0];
    const claimLogs = pairs.get("claimTokens").receipt.logs;
    const proceedsLog = pairs.get("claimAuctionProceeds").receipt.logs[0];
    const collectLogs = pairs.get("collect").receipt.logs;
    const unrelatedAmount = 777n;
    const orderedLogs = [
      rawEvent(
        LAUNCHPAD,
        "Migrated(address,bytes32,uint160,uint256,uint256,uint256)",
        [addressTopic(OTHER_TOKEN), word(555n)],
        ["uint160", "uint256", "uint256", "uint256"],
        [1n, 2n, 3n, 4n],
      ),
      migrationLogs[0],
      migrationLogs[1],
      rawEvent(
        LAUNCHPAD,
        "AuctionProceeds(address,address,uint256)",
        [addressTopic(OTHER_TOKEN), addressTopic(OTHER_OWNER)],
        ["uint256"],
        [unrelatedAmount],
      ),
      migrationLogs[2],
      migrationLogs[3],
      rawEvent(
        AUCTION,
        "BidExited(uint256,address,uint256,uint256)",
        [word(88n), addressTopic(OTHER_OWNER)],
        ["uint256", "uint256"],
        [unrelatedAmount, 0n],
      ),
      exitLog,
      rawEvent(
        AUCTION,
        "TokensClaimed(uint256,address,uint256)",
        [word(88n), addressTopic(OTHER_OWNER)],
        ["uint256"],
        [unrelatedAmount],
      ),
      claimLogs[0],
      claimLogs[1],
      rawEvent(
        AUCTION_TOKEN,
        "Transfer(address,address,uint256)",
        [addressTopic(AUCTION), addressTopic(OTHER_OWNER)],
        ["uint256"],
        [unrelatedAmount],
      ),
      claimLogs[2],
      rawEvent(
        LAUNCHPAD,
        "CreatorFeesClaimed(address,address,uint256)",
        [addressTopic(OTHER_TOKEN), addressTopic(OTHER_OWNER)],
        ["uint256"],
        [unrelatedAmount],
      ),
      proceedsLog,
      rawEvent(
        HOOK,
        "Claimed(address,uint256)",
        [addressTopic(OTHER_OWNER)],
        ["uint256"],
        [unrelatedAmount],
      ),
      rawEvent(
        BURNER,
        "FlywheelCollected(uint256)",
        [],
        ["uint256"],
        [unrelatedAmount],
      ),
      collectLogs[0],
      collectLogs[1],
    ];
    const sharedBlock = 123n;
    const sharedIndex = 6n;
    const sharedHash = transactionHash(90n);
    const sharedBlockHash = blockHash(sharedBlock);
    const sharedTransaction = {
      ...pairs.get("migrateAuction").transaction,
      hash: sharedHash,
      from: "0xd100000000000000000000000000000000000001",
      to: HELPER,
      nonce: quantity(444n),
      value: quantity(42n),
      input: "0xdecafbad",
      blockHash: sharedBlockHash,
      blockNumber: quantity(sharedBlock),
      transactionIndex: quantity(sharedIndex),
    };
    const sharedReceipt = {
      ...pairs.get("migrateAuction").receipt,
      transactionHash: sharedHash,
      from: sharedTransaction.from,
      to: HELPER,
      blockHash: sharedBlockHash,
      blockNumber: quantity(sharedBlock),
      transactionIndex: quantity(sharedIndex),
      logs: orderedLogs.map((log, logIndex) => ({
        ...log,
        topics: [...log.topics],
        blockHash: sharedBlockHash,
        blockNumber: quantity(sharedBlock),
        transactionHash: sharedHash,
        transactionIndex: quantity(sharedIndex),
        logIndex: quantity(logIndex),
        removed: false,
      })),
    };
    const sharedPair = {
      transaction: sharedTransaction,
      receipt: sharedReceipt,
    };
    for (const key of permissionlessKeys) pairs.set(key, sharedPair);
  }
  const instantBuy = pairs.get("instantBuy");
  const phaseAIndex = {
    kind: "hookr-v5-phase-a-evidence-v2",
    chainId: Number(CHAIN_ID),
    deploymentSourceCommit: DEPLOYMENT_COMMIT,
    canaryOperatorCommit: SOURCE_COMMIT,
    identities: {
      sender: OWNER,
      launchpad: LAUNCHPAD,
      hook: HOOK,
      hookrToken: HOOKR,
      instantToken: INSTANT_TOKEN,
      instantPoolId: INSTANT_POOL_ID,
      instantFlywheelAccrual: {
        transactionHash: instantBuy.transaction.hash,
        blockNumber: actionSpecs.instantBuy.block.toString(),
        transactionIndex: actionSpecs.instantBuy.transactionIndex.toString(),
        logIndex: "1",
        poolId: INSTANT_POOL_ID,
        amountWei: FLYWHEEL.toString(),
      },
      auctionToken: AUCTION_TOKEN,
      auction: AUCTION,
      auctionEndBlock: AUCTION_END.toString(),
      bidId: BID_ID.toString(),
    },
    reviewedSemantics: { bidAmountWei: "10500000000000000" },
    transactionSequence: [
      {
        artifact: "instantBuyAuctionLaunch",
        artifactIndex: 0,
        function: "exactInput",
        hash: instantBuy.transaction.hash,
        receipt: {
          transactionHash: instantBuy.receipt.transactionHash,
          blockNumber: instantBuy.receipt.blockNumber,
          blockHash: instantBuy.receipt.blockHash,
          transactionIndex: instantBuy.receipt.transactionIndex,
        },
      },
    ],
  };

  if (phaseAVersion === 3) {
    const indexedRecord = ({
      sequence,
      kind,
      artifact,
      artifactIndex,
      functionName,
      target,
      block,
      pair,
    }) => {
      const hash =
        pair?.transaction.hash ?? transactionHash(300n + BigInt(sequence));
      const nonce = pair?.transaction.nonce ?? quantity(38n + BigInt(sequence));
      const value = pair?.transaction.value ?? "0x0";
      const calldata = pair?.transaction.input ?? "0x01";
      const receiptBlock = pair ? BigInt(pair.receipt.blockNumber) : block;
      const receiptIndex = pair ? BigInt(pair.receipt.transactionIndex) : 1n;
      const receiptBlockHash =
        pair?.receipt.blockHash ?? blockHash(receiptBlock);
      return {
        sequence,
        kind,
        artifact,
        artifactIndex,
        function: functionName,
        hash,
        nonce: BigInt(nonce).toString(),
        from: OWNER,
        to: pair?.transaction.to ?? target,
        value: BigInt(value).toString(),
        calldata,
        receipt: {
          transactionHash: pair?.receipt.transactionHash ?? hash,
          status: "1",
          blockNumber: receiptBlock.toString(),
          blockHash: receiptBlockHash,
          transactionIndex: receiptIndex.toString(),
        },
      };
    };
    const originalCommit = SOURCE_COMMIT.slice(0, 7);
    const recoveryCommit = RECOVERY_COMMIT.slice(0, 7);
    const forgeMetadata = (name, commit, transactions) => ({
      path: `contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/${name}.json`,
      sha256: "12".repeat(32),
      commit,
      transactions,
      receipts: transactions,
      pending: 0,
    });
    const rawPairMetadata = (name) => ({
      transactionPath: `contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/${name}-transaction.json`,
      transactionSha256: "34".repeat(32),
      receiptPath: `contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/${name}-receipt.json`,
      receiptSha256: "56".repeat(32),
    });
    Object.assign(phaseAIndex, {
      kind: "hookr-v5-phase-a-evidence-v3",
      evidencePolicy:
        "four-unmodified-raw-forge-artifacts-plus-one-raw-owner-bid-and-two-raw-timing-transaction-pairs",
      originalCanaryOperatorCommit: SOURCE_COMMIT,
      canaryRecoveryCommit: RECOVERY_COMMIT,
      rawForgeArtifacts: {
        instantLaunch: forgeMetadata("openInstant-latest", originalCommit, 1),
        instantBuyAuctionLaunch: forgeMetadata(
          "buyInstantLaunchAuction-latest",
          originalCommit,
          2,
        ),
        hookrLaunch: forgeMetadata("launchHookrPair-latest", recoveryCommit, 1),
        hookrApproveBuy: forgeMetadata(
          "buyHookrPair-latest",
          recoveryCommit,
          2,
        ),
      },
      rawOwnerBidEvidence: rawPairMetadata("owner-bid"),
      rawTimingEvidence: {
        shorten: rawPairMetadata("timing-shorten"),
        restore: rawPairMetadata("timing-restore"),
      },
    });
    delete phaseAIndex.canaryOperatorCommit;
    Object.assign(phaseAIndex.identities, {
      router: ROUTER,
      hookrPairToken: OTHER_TOKEN,
      hookrPoolId: word(777n),
    });
    Object.assign(phaseAIndex.reviewedSemantics, {
      bidAmountWei: REVIEWED_BID_AMOUNT.toString(),
      bidMaxPriceQ96: REVIEWED_RECOVERY_BID_MAX_PRICE.toString(),
    });
    phaseAIndex.transactionSequence = [
      indexedRecord({
        sequence: 0,
        kind: "forge",
        artifact: "instantLaunch",
        artifactIndex: 0,
        functionName: "launchInstant",
        target: LAUNCHPAD,
        block: 90n,
      }),
      indexedRecord({
        sequence: 1,
        kind: "timing",
        artifact: "shorten",
        artifactIndex: 0,
        functionName: "setAuctionTiming",
        target: LAUNCHPAD,
        block: 91n,
      }),
      indexedRecord({
        sequence: 2,
        kind: "forge",
        artifact: "instantBuyAuctionLaunch",
        artifactIndex: 0,
        functionName: "exactInput",
        pair: pairs.get("instantBuy"),
      }),
      indexedRecord({
        sequence: 3,
        kind: "forge",
        artifact: "instantBuyAuctionLaunch",
        artifactIndex: 1,
        functionName: "launchAuction",
        target: LAUNCHPAD,
        block: 105n,
      }),
      indexedRecord({
        sequence: 4,
        kind: "timing",
        artifact: "restore",
        artifactIndex: 0,
        functionName: "setAuctionTiming",
        target: LAUNCHPAD,
        block: 110n,
      }),
      indexedRecord({
        sequence: 5,
        kind: "raw",
        artifact: "ownerBid",
        artifactIndex: 0,
        functionName: "submitBid",
        pair: pairs.get("ownerBid"),
      }),
      indexedRecord({
        sequence: 6,
        kind: "forge",
        artifact: "hookrLaunch",
        artifactIndex: 0,
        functionName: "launchInstant",
        target: LAUNCHPAD,
        block: 130n,
      }),
      indexedRecord({
        sequence: 7,
        kind: "forge",
        artifact: "hookrApproveBuy",
        artifactIndex: 0,
        functionName: "approve",
        target: HOOKR,
        block: 131n,
      }),
      indexedRecord({
        sequence: 8,
        kind: "forge",
        artifact: "hookrApproveBuy",
        artifactIndex: 1,
        functionName: "exactInput",
        target: ROUTER,
        block: 132n,
      }),
    ];
  }

  const live = !omitted.has("migrateAuction");
  const exited = !omitted.has("exitBid");
  const claimed = !omitted.has("claimTokens");
  const proceedsClaimed = pairs.has("claimAuctionProceeds");
  const burned = !omitted.has("buybackAndBurn");
  const launchResult = {
    token: AUCTION_TOKEN,
    creator: OWNER,
    launchBlock: 10,
    blueprintId: 0,
    mode: 1,
    status: live ? 1 : 0,
    openPriceWei: live ? 100 : 0,
    openFdvWei: 10_000,
    reserveBps: 2_000,
    auction: AUCTION,
    auctionEndBlock: AUCTION_END,
    migratedAtBlock: live ? actionSpecs.migrateAuction.block : 0,
    sqrtPriceX96AtOpen: live ? SQRT_PRICE : 0,
    poolId: live ? AUCTION_POOL_ID : word(0),
    quote: 0,
    hookParams: {
      guardBlocks: 200,
      maxBuyBps: 1_000,
      snipeTaxPips: 200_000,
      baseFeePips: 3_000,
      maxFeePips: 30_000,
      surgeSens: 5,
      burnBps: 100,
      burnTriggerWei: 0,
      lpBps: 25,
      potBps: 50,
      potEveryNBuys: 2,
      potMinBuyWei: 1_000_000_000_000_000n,
    },
  };
  const bidResult = {
    startBlock: 20,
    startCumulativeMps: 0,
    exitedBlock: exited ? actionSpecs.exitBid.block : 0,
    maxPrice: 3_169_126_500_570_573_400n,
    owner: OWNER,
    amountQ96: 99,
    tokensFilled: claimed ? 0 : exited ? FILL : 0,
  };
  const callResults = new Map();
  const addCall = (target, abi, functionName, result) => {
    const data = encodeFunctionData({
      abi,
      functionName,
      args:
        functionName === "getLaunch" || functionName === "creatorProceedsWei"
          ? [AUCTION_TOKEN]
          : functionName === "bids"
            ? [BID_ID]
            : functionName === "claimableWei"
              ? [BURNER]
              : [],
    });
    callResults.set(
      `${target.toLowerCase()}:${data.slice(0, 10)}`,
      encodeResult(abi, functionName, result),
    );
  };
  addCall(HOOK, HOOK_ABI, "flywheelRecipient", BURNER);
  addCall(BURNER, BURNER_ABI, "owner", OWNER);
  addCall(LAUNCHPAD, LAUNCHPAD_ABI, "getLaunch", launchResult);
  addCall(AUCTION, AUCTION_ABI, "bids", bidResult);
  addCall(
    LAUNCHPAD,
    LAUNCHPAD_ABI,
    "creatorProceedsWei",
    creatorProceedsOverride ??
      (zeroAuctionProceeds ? 0n : live && !proceedsClaimed ? PROCEEDS : 0n),
  );
  addCall(HOOK, HOOK_ABI, "claimableWei", 0n);
  addCall(BURNER, BURNER_ABI, "totalEthSpent", burned ? FLYWHEEL : 0n);
  addCall(BURNER, BURNER_ABI, "totalHookrBurned", burned ? HOOKR_BURNED : 0n);
  addCall(
    BURNER,
    BURNER_ABI,
    "lastBuybackBlock",
    burned ? BigInt(pairs.get("buybackAndBurn").receipt.blockNumber) : 0n,
  );

  const transactionPairs = [
    ...new Map(
      [...pairs.values()].map((pair) => [
        pair.transaction.hash.toLowerCase(),
        pair,
      ]),
    ).values(),
  ];
  const transactions = new Map(
    transactionPairs.map((pair) => [
      pair.transaction.hash.toLowerCase(),
      pair.transaction,
    ]),
  );
  const receipts = new Map(
    transactionPairs.map((pair) => [
      pair.receipt.transactionHash.toLowerCase(),
      pair.receipt,
    ]),
  );
  const allLogs = transactionPairs.flatMap((pair) => pair.receipt.logs);
  const requestedMethods = [];
  const client = {
    async request({ method, params }) {
      requestedMethods.push(method);
      if (method === "eth_chainId") return quantity(CHAIN_ID);
      if (method === "eth_getTransactionByHash")
        return transactions.get(params[0].toLowerCase()) ?? null;
      if (method === "eth_getTransactionReceipt")
        return receipts.get(params[0].toLowerCase()) ?? null;
      if (method === "eth_getBlockByNumber") {
        const tag = params[0];
        const number =
          tag === "latest"
            ? 200n
            : tag === "finalized"
              ? finalizedBlock
              : BigInt(tag);
        if (number > 200n) return null;
        return {
          number: quantity(number),
          hash:
            reorgAtFinal && tag === quantity(200n)
              ? word(999_999n)
              : blockHash(number),
        };
      }
      if (method === "eth_getLogs") {
        const filter = params[0];
        const from = BigInt(filter.fromBlock);
        const to = BigInt(filter.toBlock);
        return allLogs.filter((log) => {
          const inRange =
            BigInt(log.blockNumber) >= from && BigInt(log.blockNumber) <= to;
          const addressMatches = sameHex(log.address, filter.address);
          const topicsMatch = (filter.topics ?? []).every((expected, index) => {
            if (expected == null) return true;
            if (Array.isArray(expected))
              return expected.some((candidate) =>
                sameHex(candidate, log.topics[index]),
              );
            return sameHex(expected, log.topics[index]);
          });
          return inRange && addressMatches && topicsMatch;
        });
      }
      if (method === "eth_call") {
        const call = params[0];
        const key = `${call.to.toLowerCase()}:${call.data.slice(0, 10)}`;
        assert.ok(callResults.has(key), `unexpected eth_call ${key}`);
        return callResults.get(key);
      }
      throw new Error(`unexpected RPC method ${method}`);
    },
  };
  return { client, phaseAIndex, pairs, requestedMethods };
}

const makeOutputDir = () =>
  mkdtempSync(join(process.cwd(), ".phase-b-collector-test-"));
const jsonFiles = (root) => {
  const files = [];
  const visit = (directory) => {
    for (const entry of readdirSync(directory)) {
      const candidate = join(directory, entry);
      if (statSync(candidate).isDirectory()) visit(candidate);
      else if (entry.endsWith(".json")) files.push(candidate);
    }
  };
  visit(root);
  return files.sort();
};

test("authenticates Phase-A recovery v3 and carries split provenance into Phase-B inputs", async () => {
  const outputDir = makeOutputDir();
  try {
    const context = fixture({ phaseAVersion: 3 });
    const result = await collectV5PhaseBEvidence({
      client: context.client,
      phaseAIndex: context.phaseAIndex,
      phaseAIndexPath: "contracts/broadcast/test-phase-a-v3.json",
      outputDir,
    });
    assert.equal(result.complete, true);
    assert.equal(result.promotionReady, true);
    assert.equal(result.identities.sourceCommit, RECOVERY_COMMIT);
    assert.equal(result.phaseAIndex.kind, "hookr-v5-phase-a-evidence-v3");
    assert.equal(result.phaseAIndex.deploymentSourceCommit, DEPLOYMENT_COMMIT);
    assert.equal(
      result.phaseAIndex.originalCanaryOperatorCommit,
      SOURCE_COMMIT,
    );
    assert.equal(result.phaseAIndex.canaryRecoveryCommit, RECOVERY_COMMIT);
    assert.equal(
      result.phaseAIndex.ownerBidTransactionHash,
      context.phaseAIndex.transactionSequence[5].hash,
    );
    assert.equal(result.phaseAIndex.canaryOperatorCommit, undefined);
    const sourceFlag = result.builderArgs.indexOf("--source-commit");
    assert.equal(result.builderArgs[sourceFlag + 1], RECOVERY_COMMIT);
  } finally {
    rmSync(outputDir, { recursive: true, force: true });
  }
});

test("rejects Phase-A v3 provenance and raw-identity tampering before collection", async (t) => {
  const cases = [
    {
      name: "recovery commit is not distinct",
      reason: /recovery commit is not distinct/,
      mutate(index) {
        index.canaryRecoveryCommit = index.originalCanaryOperatorCommit;
      },
    },
    {
      name: "recovery Forge artifact names the original lineage",
      reason: /HOOKR-launch artifact commit is not its reviewed lineage/,
      mutate(index) {
        index.rawForgeArtifacts.hookrLaunch.commit =
          index.originalCanaryOperatorCommit.slice(0, 7);
      },
    },
    {
      name: "owner bid targets another auction",
      reason: /transaction #5 target differs from its indexed identity/,
      mutate(index) {
        index.transactionSequence[5].to = OTHER_TOKEN;
      },
    },
    {
      name: "owner bid encodes another maximum",
      reason: /owner-bid max price is not the reviewed recovery cap/,
      mutate(index) {
        index.transactionSequence[5].calldata = encodeFunctionData({
          abi: AUCTION_ABI,
          functionName: "submitBid",
          args: [
            REVIEWED_RECOVERY_BID_MAX_PRICE - 1n,
            REVIEWED_BID_AMOUNT,
            OWNER,
            "0x",
          ],
        });
      },
    },
  ];
  for (const scenario of cases) {
    await t.test(scenario.name, () => {
      const context = fixture({ phaseAVersion: 3 });
      scenario.mutate(context.phaseAIndex);
      assert.throws(
        () => validatePhaseACollectorIndex(context.phaseAIndex),
        scenario.reason,
      );
    });
  }
});

test("rejects a Phase-A v3 owner-bid record that differs from canonical RPC", async () => {
  const outputDir = makeOutputDir();
  try {
    const context = fixture({ phaseAVersion: 3 });
    context.pairs.get("ownerBid").transaction.input += "00";
    await assert.rejects(
      collectV5PhaseBEvidence({
        client: context.client,
        phaseAIndex: context.phaseAIndex,
        outputDir,
      }),
      /phase A v3 owner bid calldata drifted/,
    );
    assert.equal(readdirSync(outputDir).length, 0);
  } finally {
    rmSync(outputDir, { recursive: true, force: true });
  }
});

test("reconciles six interposed actions, persists 12 immutable raw files, and feeds the builder", async () => {
  const outputDir = makeOutputDir();
  try {
    const context = fixture();
    const result = await collectV5PhaseBEvidence({
      client: context.client,
      phaseAIndex: context.phaseAIndex,
      phaseAIndexPath: "contracts/broadcast/test-phase-a.json",
      outputDir,
    });
    assert.equal(result.complete, true);
    assert.equal(result.promotionReady, true);
    assert.deepEqual(result.missingActions, []);
    assert.deepEqual(result.unfinalizedActions, []);
    assert.equal(result.actions.claimTokens.semantics.mode, "claimTokensBatch");
    assert.equal(
      result.actions.claimTokens.semantics.tokensClaimedEventCount,
      2,
    );
    assert.equal(
      result.actions.claimTokens.semantics.transferred,
      (110n * 10n ** 18n).toString(),
    );
    assert.equal(
      result.phaseAAccrual.transactionHash,
      context.phaseAIndex.identities.instantFlywheelAccrual.transactionHash,
    );
    assert.equal(
      result.actions.migrateAuction.semantics.proceedsMode,
      undefined,
    );
    assert.equal(result.phaseAAccrual.logIndex, "1");
    assert.equal(result.identities.burner.toLowerCase(), BURNER);
    assert.equal(result.identities.auctionPoolId, AUCTION_POOL_ID);
    assert.equal(
      result.actions.buybackAndBurn.semantics.minHookrOut,
      REVIEWED_MIN_HOOKR_OUT.toString(),
    );
    assert.equal(
      result.actions.buybackAndBurn.semantics.hookrBurned,
      HOOKR_BURNED.toString(),
    );
    assert.ok(
      BigInt(result.actions.buybackAndBurn.semantics.hookrBurned) >=
        REVIEWED_MIN_HOOKR_OUT,
      "the observed output fixture must clear the reviewed 3 HOOKR floor",
    );
    assert.equal(jsonFiles(outputDir).length, 12);
    for (const { key } of PHASE_B_ACTIONS) {
      assert.equal(result.actions[key].created, true);
      assert.ok(existsSync(result.actions[key].transactionPath));
      assert.ok(existsSync(result.actions[key].receiptPath));
    }
    const sourceFlag = result.builderArgs.indexOf("--source-commit");
    assert.equal(result.builderArgs[sourceFlag + 1], SOURCE_COMMIT);
    for (const flag of [
      "--hook",
      "--hookr-token",
      "--phase-a-accrual-transaction-hash",
      "--phase-a-accrual-block-number",
      "--phase-a-accrual-transaction-index",
      "--phase-a-accrual-log-index",
      "--phase-a-accrual-pool-id",
      "--phase-a-accrual-amount-wei",
    ])
      assert.ok(
        result.builderArgs.includes(flag),
        `missing builder flag ${flag}`,
      );

    const builderPairs = Object.fromEntries(
      V5_PHASE_B_ACTIONS.map((key) => [
        key,
        {
          transactionPath: result.actions[key].transactionPath,
          transaction: JSON.parse(
            readFileSync(result.actions[key].transactionPath, "utf8"),
          ),
          receiptPath: result.actions[key].receiptPath,
          receipt: JSON.parse(
            readFileSync(result.actions[key].receiptPath, "utf8"),
          ),
        },
      ]),
    );
    const evidence = buildV5PhaseBEvidence({
      pairs: builderPairs,
      sourceCommit: SOURCE_COMMIT,
      token: AUCTION_TOKEN,
      auction: AUCTION,
      bidId: BID_ID,
      launchpad: LAUNCHPAD,
      burner: BURNER,
      owner: OWNER,
      poolManager: POOL_MANAGER,
      poolId: AUCTION_POOL_ID,
      hook: HOOK,
      hookrToken: HOOKR,
      phaseAAccrual: result.phaseAAccrual,
    });
    assert.equal(evidence.kind, "hookr-v5-phase-b-evidence-v1");
    assert.equal(evidence.actions.claimTokens.events.call, "claimTokensBatch");
    assert.equal(
      evidence.reviewedSemantics.buybackMinHookrOut,
      REVIEWED_MIN_HOOKR_OUT.toString(),
    );

    const second = await collectV5PhaseBEvidence({
      client: context.client,
      phaseAIndex: context.phaseAIndex,
      outputDir,
    });
    for (const { key } of PHASE_B_ACTIONS)
      assert.equal(second.actions[key].created, false);
    assert.equal(jsonFiles(outputDir).length, 12);
    assert.ok(
      context.requestedMethods.every((method) =>
        [
          "eth_chainId",
          "eth_getBlockByNumber",
          "eth_getTransactionByHash",
          "eth_getTransactionReceipt",
          "eth_getLogs",
          "eth_call",
        ].includes(method),
      ),
    );
    assert.ok(
      !context.requestedMethods.some((method) => method.startsWith("eth_send")),
    );
  } finally {
    rmSync(outputDir, { recursive: true, force: true });
  }
});

test("accepts a canonical zero-proceeds migration and emits explicit claim no-op evidence", async () => {
  const outputDir = makeOutputDir();
  try {
    const context = fixture({ zeroAuctionProceeds: true });
    assert.equal(context.pairs.has("claimAuctionProceeds"), false);
    const result = await collectV5PhaseBEvidence({
      client: context.client,
      phaseAIndex: context.phaseAIndex,
      outputDir,
    });

    assert.equal(result.complete, true);
    assert.equal(result.promotionReady, true);
    assert.deepEqual(result.missingActions, []);
    assert.deepEqual(result.unfinalizedActions, []);
    assert.equal(result.actions.migrateAuction.semantics.proceedsWei, "0");
    assert.equal(
      result.actions.migrateAuction.semantics.proceedsMode,
      "zero-creator-proceeds",
    );

    const migration = result.actions.migrateAuction;
    const claim = result.actions.claimAuctionProceeds;
    assert.equal(claim.transactionHash, migration.transactionHash);
    assert.equal(claim.finalized, true);
    assert.equal(claim.semantics.executionMode, "not-applicable");
    assert.equal(claim.semantics.mode, "not-applicable-zero-proceeds");
    assert.equal(claim.semantics.token.toLowerCase(), AUCTION_TOKEN);
    assert.equal(claim.semantics.amountWei, "0");
    assert.equal(
      claim.semantics.proofTransactionHash,
      migration.transactionHash,
    );
    assert.equal(result.stateReadbacks.creatorProceedsWei, "0");
    assert.equal(jsonFiles(outputDir).length, 12);
    assert.equal(
      readFileSync(claim.transactionPath, "utf8"),
      readFileSync(migration.transactionPath, "utf8"),
    );
    assert.equal(
      readFileSync(claim.receiptPath, "utf8"),
      readFileSync(migration.receiptPath, "utf8"),
    );
    const claimTransactionFlag = result.builderArgs.indexOf(
      "--claim-auction-proceeds-transaction",
    );
    const claimReceiptFlag = result.builderArgs.indexOf(
      "--claim-auction-proceeds-receipt",
    );
    assert.ok(claimTransactionFlag >= 0);
    assert.ok(claimReceiptFlag >= 0);
    assert.equal(
      result.builderArgs[claimTransactionFlag + 1],
      claim.transactionPath,
    );
    assert.equal(result.builderArgs[claimReceiptFlag + 1], claim.receiptPath);
  } finally {
    rmSync(outputDir, { recursive: true, force: true });
  }
});

test("keeps zero-proceeds aliases unpersisted until the migration finalizes", async () => {
  const outputDir = makeOutputDir();
  try {
    const context = fixture({
      zeroAuctionProceeds: true,
      finalizedBlock: 120n,
    });
    const result = await collectV5PhaseBEvidence({
      client: context.client,
      phaseAIndex: context.phaseAIndex,
      outputDir,
    });

    assert.equal(result.complete, true);
    assert.equal(result.promotionReady, false);
    assert.ok(result.unfinalizedActions.includes("migrateAuction"));
    assert.ok(result.unfinalizedActions.includes("claimAuctionProceeds"));
    assert.equal(result.actions.migrateAuction.finalized, false);
    assert.equal(result.actions.claimAuctionProceeds.finalized, false);
    assert.equal(result.actions.migrateAuction.transactionPath, undefined);
    assert.equal(
      result.actions.claimAuctionProceeds.transactionPath,
      undefined,
    );
    assert.equal(existsSync(join(outputDir, "migrate-auction")), false);
    assert.equal(existsSync(join(outputDir, "claim-auction-proceeds")), false);
    assert.equal(
      result.builderArgs.includes("--migrate-auction-transaction"),
      false,
    );
    assert.equal(
      result.builderArgs.includes("--claim-auction-proceeds-transaction"),
      false,
    );
  } finally {
    rmSync(outputDir, { recursive: true, force: true });
  }
});

test("rejects zero-proceeds migration evidence when the latest creator ledger is nonzero", async () => {
  const outputDir = makeOutputDir();
  try {
    const context = fixture({
      zeroAuctionProceeds: true,
      creatorProceedsOverride: 1n,
    });
    await assert.rejects(
      collectV5PhaseBEvidence({
        client: context.client,
        phaseAIndex: context.phaseAIndex,
        outputDir,
      }),
      /zero-proceeds migration has a nonzero creator proceeds ledger/,
    );
    assert.equal(readdirSync(outputDir).length, 0);
  } finally {
    rmSync(outputDir, { recursive: true, force: true });
  }
});

test("reports rejected migration details when live state would otherwise mask them", async () => {
  const outputDir = makeOutputDir();
  try {
    const context = fixture({ zeroAuctionProceeds: true });
    context.pairs.get("migrateAuction").receipt.logs[0].data = eventData(
      ["uint256"],
      [ETH_LIQUIDITY + 1n],
    );
    await assert.rejects(
      collectV5PhaseBEvidence({
        client: context.client,
        phaseAIndex: context.phaseAIndex,
        outputDir,
      }),
      /no Migrated evidence but launch status is 1; rejected candidates: .*Migrated ETH liquidity plus AuctionProceeds differs from CurrencySwept/,
    );
    assert.equal(readdirSync(outputDir).length, 0);
  } finally {
    rmSync(outputDir, { recursive: true, force: true });
  }
});

test("accepts the deployed direct claimTokens(0) Transfer-before-TokensClaimed order", async () => {
  const outputDir = makeOutputDir();
  try {
    const context = fixture({ includeExtraClaim: false });
    context.phaseAIndex.identities.bidId = "0";

    const exitPair = context.pairs.get("exitBid");
    exitPair.transaction.input = encodeFunctionData({
      abi: AUCTION_ABI,
      functionName: "exitBid",
      args: [0n],
    });
    exitPair.receipt.logs[0].topics = [...exitPair.receipt.logs[0].topics];
    exitPair.receipt.logs[0].topics[1] = word(0n);

    const claimPair = context.pairs.get("claimTokens");
    claimPair.transaction.input = encodeFunctionData({
      abi: AUCTION_ABI,
      functionName: "claimTokens",
      args: [0n],
    });
    const [tokensClaimed, transfer] = claimPair.receipt.logs;
    tokensClaimed.topics = [...tokensClaimed.topics];
    tokensClaimed.topics[1] = word(0n);
    transfer.logIndex = quantity(0n);
    tokensClaimed.logIndex = quantity(1n);
    claimPair.receipt.logs = [transfer, tokensClaimed];

    const result = await collectV5PhaseBEvidence({
      client: context.client,
      phaseAIndex: context.phaseAIndex,
      outputDir,
    });
    assert.equal(result.complete, true);
    assert.equal(result.actions.claimTokens.semantics.executionMode, "direct");
    assert.equal(result.actions.claimTokens.semantics.mode, "claimTokens");
    assert.equal(result.actions.claimTokens.semantics.bidId, "0");
    assert.equal(
      result.actions.claimTokens.semantics.tokensFilled,
      FILL.toString(),
    );
    assert.equal(
      result.actions.claimTokens.semantics.transferred,
      FILL.toString(),
    );
    const storedReceipt = JSON.parse(
      readFileSync(result.actions.claimTokens.receiptPath, "utf8"),
    );
    assert.equal(storedReceipt.logs[0].address.toLowerCase(), AUCTION_TOKEN);
    assert.equal(storedReceipt.logs[1].address.toLowerCase(), AUCTION);
    assert.equal(BigInt(storedReceipt.logs[0].logIndex), 0n);
    assert.equal(BigInt(storedReceipt.logs[1].logIndex), 1n);
  } finally {
    rmSync(outputDir, { recursive: true, force: true });
  }
});

test("accepts a helper-wrapped single claim with Transfer before TokensClaimed", async () => {
  const outputDir = makeOutputDir();
  try {
    const context = fixture({ sharedPermissionlessHelper: true });
    const pair = context.pairs.get("claimTokens");
    const canaryClaim = pair.receipt.logs.find(
      (log) =>
        sameHex(log.address, AUCTION) &&
        sameHex(
          log.topics[0],
          toEventSelector("TokensClaimed(uint256,address,uint256)"),
        ) &&
        sameHex(log.topics[1], word(BID_ID)),
    );
    const extraOwnerClaim = pair.receipt.logs.find(
      (log) =>
        sameHex(log.address, AUCTION) &&
        sameHex(
          log.topics[0],
          toEventSelector("TokensClaimed(uint256,address,uint256)"),
        ) &&
        sameHex(log.topics[1], word(7n)) &&
        sameHex(log.topics[2], addressTopic(OWNER)),
    );
    const transfer = pair.receipt.logs.find(
      (log) =>
        sameHex(log.address, AUCTION_TOKEN) &&
        sameHex(
          log.topics[0],
          toEventSelector("Transfer(address,address,uint256)"),
        ) &&
        sameHex(log.topics[1], addressTopic(AUCTION)) &&
        sameHex(log.topics[2], addressTopic(OWNER)),
    );
    assert.ok(canaryClaim && extraOwnerClaim && transfer);
    extraOwnerClaim.topics = [...extraOwnerClaim.topics];
    extraOwnerClaim.topics[2] = addressTopic(OTHER_OWNER);
    transfer.data = eventData(["uint256"], [FILL]);
    pair.receipt.logs.splice(pair.receipt.logs.indexOf(transfer), 1);
    pair.receipt.logs.splice(
      pair.receipt.logs.indexOf(canaryClaim),
      0,
      transfer,
    );
    pair.receipt.logs.forEach((log, logIndex) => {
      log.logIndex = quantity(logIndex);
    });

    const result = await collectV5PhaseBEvidence({
      client: context.client,
      phaseAIndex: context.phaseAIndex,
      outputDir,
    });
    assert.equal(result.complete, true);
    assert.equal(result.actions.claimTokens.semantics.executionMode, "helper");
    assert.equal(result.actions.claimTokens.semantics.mode, "helper");
    assert.equal(
      result.actions.claimTokens.semantics.tokensClaimedEventCount,
      1,
    );
    assert.equal(
      result.actions.claimTokens.semantics.transferred,
      FILL.toString(),
    );
  } finally {
    rmSync(outputDir, { recursive: true, force: true });
  }
});

test("rejects a helper claim whose owner transfer aggregate does not conserve owner claims", async () => {
  const outputDir = makeOutputDir();
  try {
    const context = fixture({ sharedPermissionlessHelper: true });
    const pair = context.pairs.get("claimTokens");
    const transfer = pair.receipt.logs.find(
      (log) =>
        sameHex(log.address, AUCTION_TOKEN) &&
        sameHex(
          log.topics[0],
          toEventSelector("Transfer(address,address,uint256)"),
        ) &&
        sameHex(log.topics[1], addressTopic(AUCTION)) &&
        sameHex(log.topics[2], addressTopic(OWNER)),
    );
    assert.ok(transfer);
    transfer.data = eventData(["uint256"], [110n * 10n ** 18n - 1n]);

    const result = await collectV5PhaseBEvidence({
      client: context.client,
      phaseAIndex: context.phaseAIndex,
      outputDir,
    });
    assert.equal(result.complete, false);
    assert.equal(result.actions.claimTokens, null);
    assert.ok(
      result.rejectedCandidates.claimTokens.some(({ reason }) =>
        /claim Transfer differs from the sum of TokensClaimed events/.test(
          reason,
        ),
      ),
    );
  } finally {
    rmSync(outputDir, { recursive: true, force: true });
  }
});

test("discovers five helper-interposed actions in one receipt and persists per-action raw references", async () => {
  const outputDir = makeOutputDir();
  try {
    const context = fixture({ sharedPermissionlessHelper: true });
    const result = await collectV5PhaseBEvidence({
      client: context.client,
      phaseAIndex: context.phaseAIndex,
      outputDir,
    });
    assert.equal(result.complete, true);
    const permissionless = [
      "migrateAuction",
      "exitBid",
      "claimTokens",
      "claimAuctionProceeds",
      "collect",
    ];
    const sharedHash = result.actions.migrateAuction.transactionHash;
    for (const key of permissionless) {
      assert.equal(result.actions[key].transactionHash, sharedHash);
      assert.equal(result.actions[key].to.toLowerCase(), HELPER);
      assert.equal(result.actions[key].semantics.executionMode, "helper");
    }
    assert.equal(result.actions.claimTokens.semantics.mode, "helper");
    assert.equal(
      result.actions.claimTokens.semantics.tokensClaimedEventCount,
      2,
    );
    assert.equal(
      result.actions.collect.semantics.amountWei,
      FLYWHEEL.toString(),
    );
    assert.equal(
      result.actions.migrateAuction.semantics.proceedsWei,
      PROCEEDS.toString(),
    );
    assert.equal(
      new Set(permissionless.map((key) => result.actions[key].transactionPath))
        .size,
      5,
    );
    assert.equal(
      new Set(permissionless.map((key) => result.actions[key].receiptPath))
        .size,
      5,
    );
    const sharedTransactions = permissionless.map((key) =>
      readFileSync(result.actions[key].transactionPath, "utf8"),
    );
    const sharedReceipts = permissionless.map((key) =>
      readFileSync(result.actions[key].receiptPath, "utf8"),
    );
    assert.equal(new Set(sharedTransactions).size, 1);
    assert.equal(new Set(sharedReceipts).size, 1);
    const rawHelperTransaction = JSON.parse(sharedTransactions[0]);
    assert.equal(rawHelperTransaction.input, "0xdecafbad");
    assert.equal(rawHelperTransaction.value, quantity(42n));
    assert.equal(jsonFiles(outputDir).length, 12);
  } finally {
    rmSync(outputDir, { recursive: true, force: true });
  }
});

test("accepts trailing bytes on ABI-equivalent direct permissionless calls", async () => {
  const outputDir = makeOutputDir();
  try {
    const context = fixture();
    for (const key of [
      "migrateAuction",
      "exitBid",
      "claimTokens",
      "claimAuctionProceeds",
      "collect",
    ]) {
      context.pairs.get(key).transaction.input += "deadbeef";
    }
    const result = await collectV5PhaseBEvidence({
      client: context.client,
      phaseAIndex: context.phaseAIndex,
      outputDir,
    });
    assert.equal(result.complete, true);
    for (const key of [
      "migrateAuction",
      "exitBid",
      "claimTokens",
      "claimAuctionProceeds",
      "collect",
    ]) {
      assert.equal(result.actions[key].semantics.executionMode, "direct");
    }
    assert.equal(result.actions.claimTokens.semantics.mode, "claimTokensBatch");
  } finally {
    rmSync(outputDir, { recursive: true, force: true });
  }
});

test("enforces causal action and outcome order inside a shared helper receipt", async (t) => {
  const cases = [
    {
      name: "exit precedes token claim",
      missing: "claimTokens",
      earlier(log) {
        return (
          sameHex(log.address, AUCTION) &&
          sameHex(
            log.topics[0],
            toEventSelector("TokensClaimed(uint256,address,uint256)"),
          ) &&
          sameHex(log.topics[1], word(BID_ID))
        );
      },
      later(log) {
        return (
          sameHex(log.address, AUCTION) &&
          sameHex(
            log.topics[0],
            toEventSelector("BidExited(uint256,address,uint256,uint256)"),
          ) &&
          sameHex(log.topics[1], word(BID_ID))
        );
      },
    },
    {
      name: "migration precedes proceeds claim",
      missing: "claimAuctionProceeds",
      error: /unclaimed proceeds ledger differs from AuctionProceeds/,
      earlier(log) {
        return (
          sameHex(log.address, LAUNCHPAD) &&
          sameHex(
            log.topics[0],
            toEventSelector("CreatorFeesClaimed(address,address,uint256)"),
          ) &&
          sameHex(log.topics[1], addressTopic(AUCTION_TOKEN))
        );
      },
      later(log) {
        return (
          sameHex(log.address, LAUNCHPAD) &&
          sameHex(
            log.topics[0],
            toEventSelector(
              "Migrated(address,bytes32,uint160,uint256,uint256,uint256)",
            ),
          ) &&
          sameHex(log.topics[1], addressTopic(AUCTION_TOKEN))
        );
      },
    },
    {
      name: "hook claim precedes burner collection",
      missing: "collect",
      earlier(log) {
        return (
          sameHex(log.address, BURNER) &&
          sameHex(
            log.topics[0],
            toEventSelector("FlywheelCollected(uint256)"),
          ) &&
          BigInt(log.data) === FLYWHEEL
        );
      },
      later(log) {
        return (
          sameHex(log.address, HOOK) &&
          sameHex(log.topics[0], toEventSelector("Claimed(address,uint256)")) &&
          sameHex(log.topics[1], addressTopic(BURNER))
        );
      },
    },
  ];

  for (const scenario of cases) {
    await t.test(scenario.name, async () => {
      const outputDir = makeOutputDir();
      try {
        const context = fixture({ sharedPermissionlessHelper: true });
        const logs = context.pairs.get("migrateAuction").receipt.logs;
        const earlierIndex = logs.findIndex(scenario.earlier);
        const laterIndex = logs.findIndex(scenario.later);
        assert.ok(
          earlierIndex > laterIndex,
          "fixture outcome starts in valid causal order",
        );
        [logs[earlierIndex], logs[laterIndex]] = [
          logs[laterIndex],
          logs[earlierIndex],
        ];
        logs.forEach((log, logIndex) => {
          log.logIndex = quantity(logIndex);
        });
        const collection = collectV5PhaseBEvidence({
          client: context.client,
          phaseAIndex: context.phaseAIndex,
          outputDir,
        });
        if (scenario.error) {
          await assert.rejects(collection, scenario.error);
        } else {
          const result = await collection;
          assert.equal(result.complete, false);
          assert.equal(result.actions[scenario.missing], null);
        }
      } finally {
        rmSync(outputDir, { recursive: true, force: true });
      }
    });
  }
});

test("keeps owner buyback exact and direct", async () => {
  const outputDir = makeOutputDir();
  try {
    const context = fixture();
    const pair = context.pairs.get("buybackAndBurn");
    pair.transaction.to = HELPER;
    pair.transaction.input = "0xdecafbad";
    pair.transaction.value = quantity(42n);
    pair.receipt.to = HELPER;
    const result = await collectV5PhaseBEvidence({
      client: context.client,
      phaseAIndex: context.phaseAIndex,
      outputDir,
    });
    assert.equal(result.complete, false);
    assert.equal(result.actions.buybackAndBurn, null);
    assert.ok(
      result.rejectedCandidates.buybackAndBurn.some(({ reason }) =>
        /target is wrong/.test(reason),
      ),
    );
  } finally {
    rmSync(outputDir, { recursive: true, force: true });
  }
});

test("rejects trailing bytes on the byte-exact owner buyback", async () => {
  const outputDir = makeOutputDir();
  try {
    const context = fixture();
    context.pairs.get("buybackAndBurn").transaction.input += "deadbeef";
    const result = await collectV5PhaseBEvidence({
      client: context.client,
      phaseAIndex: context.phaseAIndex,
      outputDir,
    });
    assert.equal(result.complete, false);
    assert.equal(result.actions.buybackAndBurn, null);
    assert.ok(
      result.rejectedCandidates.buybackAndBurn.some(({ reason }) =>
        /calldata is not byte-exact/.test(reason),
      ),
    );
  } finally {
    rmSync(outputDir, { recursive: true, force: true });
  }
});

test("requires the exact reviewed 3 HOOKR buyback minimum", async (t) => {
  for (const wrongMinimum of [
    REVIEWED_MIN_HOOKR_OUT - 1n,
    REVIEWED_MIN_HOOKR_OUT + 1n,
  ]) {
    await t.test(wrongMinimum.toString(), async () => {
      const outputDir = makeOutputDir();
      try {
        const context = fixture();
        context.pairs.get("buybackAndBurn").transaction.input =
          encodeFunctionData({
            abi: BURNER_ABI,
            functionName: "buybackAndBurn",
            args: [FLYWHEEL, wrongMinimum],
          });
        const result = await collectV5PhaseBEvidence({
          client: context.client,
          phaseAIndex: context.phaseAIndex,
          outputDir,
        });
        assert.equal(result.complete, false);
        assert.equal(result.actions.buybackAndBurn, null);
        assert.ok(
          result.rejectedCandidates.buybackAndBurn.some(({ reason }) =>
            /buyback minimum is wrong/.test(reason),
          ),
        );
      } finally {
        rmSync(outputDir, { recursive: true, force: true });
      }
    });
  }
});

test("rejects a matching burn and dead transfer one wei below the 3 HOOKR floor", async () => {
  const outputDir = makeOutputDir();
  try {
    const context = fixture();
    const pair = context.pairs.get("buybackAndBurn");
    pair.receipt.logs[0].data = eventData(
      ["uint256"],
      [REVIEWED_MIN_HOOKR_OUT - 1n],
    );
    pair.receipt.logs[1].data = eventData(
      ["uint256", "uint256"],
      [FLYWHEEL, REVIEWED_MIN_HOOKR_OUT - 1n],
    );
    const result = await collectV5PhaseBEvidence({
      client: context.client,
      phaseAIndex: context.phaseAIndex,
      outputDir,
    });
    assert.equal(result.complete, false);
    assert.equal(result.actions.buybackAndBurn, null);
    assert.ok(
      result.rejectedCandidates.buybackAndBurn.some(({ reason }) =>
        /missed the reviewed minimum/.test(reason),
      ),
    );
  } finally {
    rmSync(outputDir, { recursive: true, force: true });
  }
});

test("accepts duplicate batch calldata IDs while binding unique emitted claim outcomes", async (t) => {
  const cases = [
    {
      name: "duplicate canary IDs",
      fixtureOptions: {
        claimBatchBidIds: [BID_ID, BID_ID],
        includeExtraClaim: false,
      },
      eventCount: 1,
      transferred: FILL,
    },
    {
      name: "duplicate emitted and non-emitted extra IDs",
      fixtureOptions: { claimBatchBidIds: [7n, 7n, BID_ID, 29n, 29n] },
      eventCount: 2,
      transferred: 110n * 10n ** 18n,
    },
  ];

  for (const scenario of cases) {
    await t.test(scenario.name, async () => {
      const outputDir = makeOutputDir();
      try {
        const context = fixture(scenario.fixtureOptions);
        const result = await collectV5PhaseBEvidence({
          client: context.client,
          phaseAIndex: context.phaseAIndex,
          outputDir,
        });
        assert.equal(result.complete, true);
        assert.equal(
          result.actions.claimTokens.semantics.mode,
          "claimTokensBatch",
        );
        assert.equal(
          result.actions.claimTokens.semantics.tokensClaimedEventCount,
          scenario.eventCount,
        );
        assert.equal(
          result.actions.claimTokens.semantics.transferred,
          scenario.transferred.toString(),
        );
        assert.equal(
          JSON.parse(
            readFileSync(result.actions.claimTokens.transactionPath, "utf8"),
          ).input,
          context.pairs.get("claimTokens").transaction.input,
        );
      } finally {
        rmSync(outputDir, { recursive: true, force: true });
      }
    });
  }
});

test("duplicate calldata tolerance preserves every receipt-level batch claim invariant", async (t) => {
  const cases = [
    {
      name: "positive canary claim",
      reason: /canary TokensClaimed amount is not positive/,
      mutate(pair) {
        pair.receipt.logs[0].data = eventData(["uint256"], [0n]);
      },
    },
    {
      name: "emitted IDs are a calldata subset",
      reason: /batch claim emitted a bid absent from calldata/,
      mutate(pair) {
        pair.receipt.logs[1].topics = [...pair.receipt.logs[1].topics];
        pair.receipt.logs[1].topics[1] = word(8n);
      },
    },
    {
      name: "emitted IDs remain unique",
      reason: /batch claim emitted duplicate TokensClaimed for one bid/,
      mutate(pair) {
        const [canaryClaim, extraClaim, aggregateTransfer] = pair.receipt.logs;
        const duplicateExtraClaim = {
          ...extraClaim,
          topics: [...extraClaim.topics],
          logIndex: quantity(2n),
        };
        aggregateTransfer.logIndex = quantity(3n);
        pair.receipt.logs = [
          canaryClaim,
          extraClaim,
          duplicateExtraClaim,
          aggregateTransfer,
        ];
      },
    },
    {
      name: "one aggregate transfer conserves every emitted amount",
      reason: /claim Transfer differs from the sum of TokensClaimed events/,
      mutate(pair) {
        pair.receipt.logs[2].data = eventData(["uint256"], [FILL]);
      },
    },
  ];

  for (const scenario of cases) {
    await t.test(scenario.name, async () => {
      const outputDir = makeOutputDir();
      try {
        const context = fixture({
          claimBatchBidIds: [7n, 7n, BID_ID, BID_ID, 29n, 29n],
        });
        scenario.mutate(context.pairs.get("claimTokens"));
        const result = await collectV5PhaseBEvidence({
          client: context.client,
          phaseAIndex: context.phaseAIndex,
          outputDir,
        });
        assert.equal(result.complete, false);
        assert.equal(result.actions.claimTokens, null);
        assert.ok(
          result.rejectedCandidates.claimTokens.some(({ reason }) =>
            scenario.reason.test(reason),
          ),
          `missing rejection matching ${scenario.reason}`,
        );
      } finally {
        rmSync(outputDir, { recursive: true, force: true });
      }
    });
  }
});

test("reports a missing owner buyback in machine-readable form while retaining found actions", async () => {
  const outputDir = makeOutputDir();
  try {
    const context = fixture({ omit: ["buybackAndBurn"] });
    const result = await collectV5PhaseBEvidence({
      client: context.client,
      phaseAIndex: context.phaseAIndex,
      outputDir,
    });
    assert.equal(result.complete, false);
    assert.equal(result.promotionReady, false);
    assert.deepEqual(result.missingActions, [
      {
        action: "buybackAndBurn",
        reason: "no exact owner buyback receipt after collection",
        blockedBy: [],
      },
    ]);
    assert.equal(result.actions.buybackAndBurn, null);
    assert.equal(jsonFiles(outputDir).length, 10);
    assert.equal(
      result.builderArgs.includes("--buyback-and-burn-transaction"),
      false,
    );
  } finally {
    rmSync(outputDir, { recursive: true, force: true });
  }
});

test("keeps complete but unfinalized evidence out of promotion readiness, with a rehearsal override", async () => {
  const outputDir = makeOutputDir();
  const rehearsalDir = makeOutputDir();
  try {
    const production = fixture({ finalizedBlock: 123n });
    const result = await collectV5PhaseBEvidence({
      client: production.client,
      phaseAIndex: production.phaseAIndex,
      outputDir,
    });
    assert.equal(result.complete, true);
    assert.equal(result.promotionReady, false);
    assert.deepEqual(result.unfinalizedActions, ["buybackAndBurn"]);
    assert.equal(result.finalityPolicy, "production-finalized-tag");
    assert.equal(result.actions.buybackAndBurn.transactionPath, undefined);
    assert.equal(existsSync(join(outputDir, "buyback-and-burn")), false);
    assert.equal(jsonFiles(outputDir).length, 10);
    assert.equal(
      result.builderArgs.includes("--buyback-and-burn-transaction"),
      false,
    );

    const rehearsal = fixture({ finalizedBlock: 123n });
    const rehearsalResult = await collectV5PhaseBEvidence({
      client: rehearsal.client,
      phaseAIndex: rehearsal.phaseAIndex,
      outputDir: rehearsalDir,
      rehearsal: true,
    });
    assert.equal(rehearsalResult.promotionReady, true);
    assert.deepEqual(rehearsalResult.unfinalizedActions, []);
    assert.equal(rehearsalResult.finalityPolicy, "loopback-latest-rehearsal");
    assert.ok(
      existsSync(rehearsalResult.actions.buybackAndBurn.transactionPath),
    );
    assert.equal(jsonFiles(rehearsalDir).length, 12);
  } finally {
    rmSync(outputDir, { recursive: true, force: true });
    rmSync(rehearsalDir, { recursive: true, force: true });
  }
});

test("a finalized restart safely replaces a reorged unfinalized observation", async () => {
  const outputDir = makeOutputDir();
  try {
    const unfinalized = fixture({ finalizedBlock: 123n });
    const first = await collectV5PhaseBEvidence({
      client: unfinalized.client,
      phaseAIndex: unfinalized.phaseAIndex,
      outputDir,
    });
    const unfinalizedHash = first.actions.buybackAndBurn.transactionHash;
    assert.equal(first.complete, true);
    assert.equal(first.promotionReady, false);
    assert.equal(first.actions.buybackAndBurn.finalized, false);
    assert.equal(first.actions.buybackAndBurn.receiptPath, undefined);
    assert.equal(existsSync(join(outputDir, "buyback-and-burn")), false);
    assert.equal(jsonFiles(outputDir).length, 10);

    const replacement = fixture({
      finalizedBlock: 200n,
      replacementBuyback: true,
    });
    const second = await collectV5PhaseBEvidence({
      client: replacement.client,
      phaseAIndex: replacement.phaseAIndex,
      outputDir,
    });
    assert.equal(second.complete, true);
    assert.equal(second.promotionReady, true);
    assert.equal(second.actions.buybackAndBurn.finalized, true);
    assert.notEqual(
      second.actions.buybackAndBurn.transactionHash,
      unfinalizedHash,
    );
    assert.equal(second.actions.buybackAndBurn.created, true);
    assert.ok(existsSync(second.actions.buybackAndBurn.transactionPath));
    assert.ok(existsSync(second.actions.buybackAndBurn.receiptPath));
    assert.equal(
      JSON.parse(
        readFileSync(second.actions.buybackAndBurn.transactionPath, "utf8"),
      ).hash,
      second.actions.buybackAndBurn.transactionHash,
    );
    assert.equal(jsonFiles(outputDir).length, 12);
    for (const key of [
      "migrateAuction",
      "exitBid",
      "claimTokens",
      "claimAuctionProceeds",
      "collect",
    ]) {
      assert.equal(second.actions[key].created, false);
    }

    const third = await collectV5PhaseBEvidence({
      client: replacement.client,
      phaseAIndex: replacement.phaseAIndex,
      outputDir,
    });
    assert.equal(third.promotionReady, true);
    assert.equal(third.actions.buybackAndBurn.created, false);
    assert.equal(jsonFiles(outputDir).length, 12);
  } finally {
    rmSync(outputDir, { recursive: true, force: true });
  }
});

test("rejects a Phase-A indexed accrual coordinate that differs from the live receipt", async () => {
  const outputDir = makeOutputDir();
  try {
    const context = fixture();
    context.phaseAIndex.identities.instantFlywheelAccrual.logIndex = "2";
    await assert.rejects(
      collectV5PhaseBEvidence({
        client: context.client,
        phaseAIndex: context.phaseAIndex,
        outputDir,
      }),
      /live Phase-A accrual differs from identities\.instantFlywheelAccrual/,
    );
    assert.equal(readdirSync(outputDir).length, 0);
  } finally {
    rmSync(outputDir, { recursive: true, force: true });
  }
});

test("detects a scan-head reorg before creating any immutable evidence directory", async () => {
  const outputDir = makeOutputDir();
  try {
    const context = fixture({ reorgAtFinal: true });
    await assert.rejects(
      collectV5PhaseBEvidence({
        client: context.client,
        phaseAIndex: context.phaseAIndex,
        outputDir,
      }),
      /latest scan head reorged/,
    );
    assert.equal(readdirSync(outputDir).length, 0);
  } finally {
    rmSync(outputDir, { recursive: true, force: true });
  }
});

test("never overwrites a conflicting raw evidence directory", async () => {
  const outputDir = makeOutputDir();
  try {
    const context = fixture();
    const first = await collectV5PhaseBEvidence({
      client: context.client,
      phaseAIndex: context.phaseAIndex,
      outputDir,
    });
    const transactionPath = first.actions.exitBid.transactionPath;
    const tampered = JSON.parse(readFileSync(transactionPath, "utf8"));
    tampered.nonce = "0xffff";
    writeFileSync(transactionPath, `${JSON.stringify(tampered, null, 2)}\n`);
    await assert.rejects(
      collectV5PhaseBEvidence({
        client: context.client,
        phaseAIndex: context.phaseAIndex,
        outputDir,
      }),
      /differs from current canonical RPC evidence/,
    );
    assert.equal(
      JSON.parse(readFileSync(transactionPath, "utf8")).nonce,
      "0xffff",
    );
  } finally {
    rmSync(outputDir, { recursive: true, force: true });
  }
});

test("redacts the full configured RPC and all stable secret-bearing URL components", () => {
  const rpc =
    "https://rpc-user:rpc-password@alchemy.example/v2/secretToken123?apiKey=apiSecret456";
  const message = [
    rpc,
    encodeURI(rpc),
    encodeURIComponent(rpc),
    "alchemy.example secretToken123 apiSecret456 rpc-password",
  ].join(" | ");
  const redacted = redactRpcMessage(message, rpc);
  for (const secret of [
    rpc,
    "alchemy.example",
    "secretToken123",
    "apiSecret456",
    "rpc-password",
  ]) {
    assert.equal(redacted.includes(secret), false, `leaked ${secret}`);
  }
  assert.match(redacted, /<configured RPC>/);
});

test("collector source has no signer, wallet client, broadcast RPC, or argv RPC credential path", () => {
  const source = readFileSync(
    new URL("./collect-v5-phase-b-evidence.mjs", import.meta.url),
    "utf8",
  );
  for (const forbidden of [
    "createWalletClient",
    "privateKeyToAccount",
    "writeContract",
    "sendTransaction",
    "eth_sendRawTransaction",
    'args.value("rpc")',
  ])
    assert.equal(
      source.includes(forbidden),
      false,
      `collector contains forbidden surface ${forbidden}`,
    );
});
