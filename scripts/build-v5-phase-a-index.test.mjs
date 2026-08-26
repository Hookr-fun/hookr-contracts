import assert from "node:assert/strict";
import { mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import {
  encodeAbiParameters,
  encodeFunctionData,
  keccak256,
  toBytes,
  toEventSelector,
} from "viem";

import {
  assertV5PhaseAIndex,
  assertV5PhaseAOwnerBidSemantics,
  assertV5PhaseAStageSemantics,
  buildV5PhaseAIndex,
} from "./build-v5-phase-a-index.mjs";

const sender = "0x1111111111111111111111111111111111111111";
const launchpad = "0x2222222222222222222222222222222222222222";
const router = "0x3333333333333333333333333333333333333333";
const hookrToken = "0x4444444444444444444444444444444444444444";
const auctionToken = "0x5555555555555555555555555555555555555555";
const auction = "0x6666666666666666666666666666666666666666";
const instantToken = "0x7777777777777777777777777777777777777777";
const hookrPairToken = "0x8888888888888888888888888888888888888888";
const hook = `0x${"99".repeat(18)}28cc`;
const originalOperator = "c".repeat(40);
const recoveryOperator = "e".repeat(40);
const deployment = "d".repeat(40);
const auctionEndBlock = 20_103n;
const instantDeadline = 1_800_000_500n;
const hookrDeadline = 1_800_001_000n;

const instantLaunchedTopic = toEventSelector("InstantLaunched(address,bytes32,uint96)");
const auctionStartedTopic = toEventSelector(
  "AuctionStarted(address,address,uint40,uint96,uint96,uint16)",
);
const bidSubmittedTopic =
  "0x650baad5cd8ca09b8f580be220fa04ce2ba905a041f764b6a3fe2c848eb70540";
const intentConsumedTopic = toEventSelector("LaunchIntentConsumed(address,bytes32,address)");
const poolManager = "0x8366a39cc670b4001a1121b8f6a443a643e40951";
const poolSwapTopic = toEventSelector("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
const flywheelAccruedTopic = toEventSelector("FlywheelFeeAccrued(bytes32,uint256)");
const intents = {
  instant: keccak256(toBytes("hookr.v5.canary.instant.1")),
  auction: keccak256(toBytes("hookr.v5.canary.auction.1")),
  hookr: keccak256(toBytes("hookr.v5.canary.hookr.1")),
};
const timingAbi = [{
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

const hookParamsComponents = [
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
const launchArgsComponents = [
  { name: "name", type: "string" },
  { name: "symbol", type: "string" },
  { name: "tagline", type: "string" },
  { name: "logoURI", type: "string" },
  { name: "expectedCreator", type: "address" },
  { name: "blueprintId", type: "uint32" },
  { name: "custom", type: "tuple", components: hookParamsComponents },
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
const launchpadAbi = [
  {
    type: "function",
    name: "launchInstant",
    stateMutability: "payable",
    inputs: [
      { name: "args", type: "tuple", components: launchArgsComponents },
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
      { name: "args", type: "tuple", components: launchArgsComponents },
      { name: "quote", type: "uint8" },
      { name: "floorFdvWei", type: "uint96" },
      { name: "raiseFloorWei", type: "uint96" },
      { name: "reserveBps", type: "uint16" },
      { name: "intentId", type: "bytes32" },
    ],
    outputs: [{ name: "token", type: "address" }],
  },
];
const poolKeyComponents = [
  { name: "currency0", type: "address" },
  { name: "currency1", type: "address" },
  { name: "fee", type: "uint24" },
  { name: "tickSpacing", type: "int24" },
  { name: "hooks", type: "address" },
];
const routerAbi = [{
  type: "function",
  name: "exactInput",
  stateMutability: "payable",
  inputs: [{
    name: "p",
    type: "tuple",
    components: [
      { name: "key", type: "tuple", components: poolKeyComponents },
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
const bidAbi = [{
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
const erc20Abi = [{
  type: "function",
  name: "approve",
  stateMutability: "nonpayable",
  inputs: [
    { name: "spender", type: "address" },
    { name: "amount", type: "uint256" },
  ],
  outputs: [{ name: "success", type: "bool" }],
}];

const allFive = [
  20_000, 1_000, 200_000, 3_000, 30_000, 5, 100, 0n, 25, 50, 2, 1_000_000_000_000_000n,
];
const instantFour = [...allFive.slice(0, 8), 0, ...allFive.slice(9)];
const guardTwo = [20_000, 1_000, 200_000, 3_000, 30_000, 5, 0, 0n, 0, 0, 0, 0n];
const launchArgs = (name, symbol, params) => [
  name, symbol, "generation-5 canary", "", sender, 0, params, 0, [],
];
const launchInstantCalldata = (args, quote, intent) => encodeFunctionData({
  abi: launchpadAbi,
  functionName: "launchInstant",
  args: [args, quote, intent],
});
const launchAuctionCalldata = ({ reserveBps = 2_000, floorFdv = 20_000_000_000_000_000n } = {}) =>
  encodeFunctionData({
    abi: launchpadAbi,
    functionName: "launchAuction",
    args: [
      launchArgs("Canary Auction V5", "CANV5A", allFive),
      0,
      floorFdv,
      10_000_000_000_000_000n,
      reserveBps,
      intents.auction,
    ],
  });
const swapCalldata = ({
  currency0,
  currency1,
  amountIn,
  minimum,
  deadline,
  zeroForOne = true,
  sqrtPriceLimitX96 = 4_295_128_740n,
  hooks = hook,
  recipient = sender,
}) => encodeFunctionData({
  abi: routerAbi,
  functionName: "exactInput",
  args: [[
    [currency0, currency1, 0x800000, 60, hooks],
    zeroForOne,
    amountIn,
    minimum,
    sqrtPriceLimitX96,
    recipient,
    deadline,
  ]],
});
const bidCalldata = ({
  maxPrice = 814_814_390_533_794_434_497_901_791_991_308_996_217n,
  amount = 10_500_000_000_000_000n,
  owner = sender,
  hookData = "0x",
} = {}) => encodeFunctionData({
  abi: bidAbi,
  functionName: "submitBid",
  args: [maxPrice, amount, owner, hookData],
});
const approveCalldata = ({ spender = router, amount = 25_000n * 10n ** 18n } = {}) =>
  encodeFunctionData({ abi: erc20Abi, functionName: "approve", args: [spender, amount] });
const poolId = (currency0, currency1) => keccak256(encodeAbiParameters(
  [{ type: "tuple", components: poolKeyComponents }],
  [[currency0, currency1, 0x800000, 60, hook]],
));
const instantPoolId = poolId("0x0000000000000000000000000000000000000000", instantToken);
const hookrPoolId = poolId(hookrToken, hookrPairToken);
const instantSwapCalldata = (overrides = {}) => swapCalldata({
  currency0: "0x0000000000000000000000000000000000000000",
  currency1: instantToken,
  amountIn: 1_000_000_000_000_000n,
  minimum: 200_000n * 10n ** 18n,
  deadline: instantDeadline,
  ...overrides,
});
const hookrSwapCalldata = (overrides = {}) => swapCalldata({
  currency0: hookrToken,
  currency1: hookrPairToken,
  amountIn: 25_000n * 10n ** 18n,
  minimum: 1_000_000n * 10n ** 18n,
  deadline: hookrDeadline,
  ...overrides,
});

const hash = (value) => `0x${BigInt(value).toString(16).padStart(64, "0")}`;
const quantity = (value) => `0x${BigInt(value).toString(16)}`;
const addressTopic = (value) => `0x${value.slice(2).toLowerCase().padStart(64, "0")}`;
const encodedInstantData = encodeAbiParameters([{ type: "uint96" }], [1n]);
const encodedAuctionData = (endBlock = auctionEndBlock) => encodeAbiParameters(
  [{ type: "uint40" }, { type: "uint96" }, { type: "uint96" }, { type: "uint16" }],
  [BigInt(endBlock), 20_000_000_000_000_000n, 10_000_000_000_000_000n, 2_000],
);
const timingCalldata = (duration) => encodeFunctionData({
  abi: timingAbi,
  functionName: "setAuctionTiming",
  args: [BigInt(duration), 0n, 1n],
});

const rawRun = ({ entries, commit = originalOperator }) => ({
  chain: 4663,
  commit: commit.slice(0, 7),
  transactions: entries.map((entry, index) => ({
    function: `${entry.function}(fixture)`,
    hash: hash(entry.nonce + 1_000),
    transaction: {
      from: sender,
      to: entry.target,
      nonce: quantity(entry.nonce),
      value: quantity(entry.value),
      input: entry.input ?? `0x${(index + 1).toString(16).padStart(2, "0")}`,
    },
  })),
  receipts: entries.map((entry) => {
    const transactionHash = hash(entry.nonce + 1_000);
    const blockNumber = quantity(entry.block);
    const blockHash = hash(entry.block + 2_000);
    const transactionIndex = quantity(entry.transactionIndex ?? 0);
    return {
      transactionHash,
      status: "0x1",
      blockNumber,
      blockHash,
      transactionIndex,
      logs: (entry.logs ?? []).map((log, logIndex) => ({
        ...log,
        transactionHash,
        blockNumber,
        blockHash,
        transactionIndex,
        logIndex: quantity(logIndex),
      })),
    };
  }),
  pending: [],
});

const rawTiming = ({ nonce, block, duration }) => {
  const txHash = hash(nonce + 1_000);
  const blockHash = hash(block + 2_000);
  return {
    transaction: {
      hash: txHash,
      chainId: quantity(4663),
      from: sender,
      to: launchpad,
      nonce: quantity(nonce),
      value: "0x0",
      input: timingCalldata(duration),
      blockNumber: quantity(block),
      blockHash,
    },
    receipt: {
      transactionHash: txHash,
      status: "0x1",
      from: sender,
      to: launchpad,
      blockNumber: quantity(block),
      blockHash,
      transactionIndex: "0x0",
      logs: [],
    },
  };
};

const rawOwnerBid = ({
  nonce,
  block,
  maxPrice = 814_814_390_533_794_434_497_901_791_991_308_996_217n,
  amount = 10_500_000_000_000_000n,
  owner = sender,
  bidId = 3n,
} = {}) => {
  const txHash = hash(nonce + 1_000);
  const blockHash = hash(block + 2_000);
  return {
    transaction: {
      hash: txHash,
      chainId: quantity(4663),
      from: sender,
      to: auction,
      nonce: quantity(nonce),
      value: quantity(amount),
      input: bidCalldata({ maxPrice, amount, owner }),
      blockNumber: quantity(block),
      blockHash,
      transactionIndex: "0x0",
    },
    receipt: {
      transactionHash: txHash,
      status: "0x1",
      from: sender,
      to: auction,
      blockNumber: quantity(block),
      blockHash,
      transactionIndex: "0x0",
      logs: [{
        address: auction,
        topics: [bidSubmittedTopic, hash(bidId), addressTopic(owner)],
        data: encodeAbiParameters(
          [{ type: "uint256" }, { type: "uint128" }],
          [maxPrice, amount],
        ),
        transactionHash: txHash,
        blockNumber: quantity(block),
        blockHash,
        transactionIndex: "0x0",
        logIndex: "0x0",
      }],
    },
  };
};

const instantLog = (token, poolId) => ({
  address: launchpad,
  topics: [instantLaunchedTopic, addressTopic(token), poolId],
  data: encodedInstantData,
});
const intentLog = (intent, token) => ({
  address: launchpad,
  topics: [intentConsumedTopic, addressTopic(sender), intent, addressTopic(token)],
  data: "0x",
});
const guardedSwapLog = (id, fee = 203_000n) => ({
  address: poolManager,
  topics: [poolSwapTopic, id, addressTopic(router)],
  data: encodeAbiParameters(
    [
      { type: "int128" }, { type: "int128" }, { type: "uint160" },
      { type: "uint128" }, { type: "int24" }, { type: "uint24" },
    ],
    [-1n, 1n, 1n, 1n, 0, fee],
  ),
});
const flywheelAccruedLog = (id, amount = 3_000_000_000_000n) => ({
  address: hook,
  topics: [flywheelAccruedTopic, id],
  data: encodeAbiParameters([{ type: "uint256" }], [amount]),
});

const objectToPath = {
  instantLaunchRun: "instantLaunchPath",
  instantBuyAuctionLaunchRun: "instantBuyAuctionLaunchPath",
  ownerBidTransaction: "ownerBidTransactionPath",
  ownerBidReceipt: "ownerBidReceiptPath",
  hookrLaunchRun: "hookrLaunchPath",
  hookrApproveBuyRun: "hookrApproveBuyPath",
  shortenTransaction: "shortenTransactionPath",
  shortenReceipt: "shortenReceiptPath",
  restoreTransaction: "restoreTransactionPath",
  restoreReceipt: "restoreReceiptPath",
};
const sync = (context, ...objects) => {
  for (const object of objects) {
    writeFileSync(context[objectToPath[object]], JSON.stringify(context[object]));
  }
};

const fixture = () => {
  const instantLaunchRun = rawRun({ entries: [{
    function: "launchInstant",
    target: launchpad,
    value: 200_000_000_000_000n,
    input: launchInstantCalldata(
      launchArgs("Canary Instant V5", "CANV5I", instantFour),
      0,
      intents.instant,
    ),
    nonce: 701,
    block: 100,
    logs: [
      instantLog(instantToken, instantPoolId),
      intentLog(intents.instant, instantToken),
    ],
  }] });
  const shorten = rawTiming({ nonce: 702, block: 101, duration: 20_000 });
  const instantBuyAuctionLaunchRun = rawRun({ entries: [
    {
      function: "exactInput",
      target: router,
      value: 1_000_000_000_000_000n,
      input: swapCalldata({
        currency0: "0x0000000000000000000000000000000000000000",
        currency1: instantToken,
        amountIn: 1_000_000_000_000_000n,
        minimum: 200_000n * 10n ** 18n,
        deadline: instantDeadline,
      }),
      nonce: 703,
      block: 102,
      logs: [guardedSwapLog(instantPoolId), flywheelAccruedLog(instantPoolId)],
    },
    {
      function: "launchAuction",
      target: launchpad,
      value: 200_000_000_000_000n,
      input: launchAuctionCalldata(),
      nonce: 704,
      block: 103,
      logs: [
        {
          address: launchpad,
          topics: [auctionStartedTopic, addressTopic(auctionToken), addressTopic(auction)],
          data: encodedAuctionData(),
        },
        intentLog(intents.auction, auctionToken),
      ],
    },
  ] });
  const restore = rawTiming({ nonce: 705, block: 104, duration: 125_000 });
  const ownerBid = rawOwnerBid({ nonce: 706, block: 105, bidId: 3n });
  const hookrLaunchRun = rawRun({
    commit: recoveryOperator,
    entries: [{
      function: "launchInstant",
      target: launchpad,
      value: 200_000_000_000_000n,
      input: launchInstantCalldata(
        launchArgs("Canary Hookr Pair V5", "CANV5H", guardTwo),
        1,
        intents.hookr,
      ),
      nonce: 707,
      block: 106,
      logs: [
        instantLog(hookrPairToken, hookrPoolId),
        intentLog(intents.hookr, hookrPairToken),
      ],
    }],
  });
  const hookrApproveBuyRun = rawRun({ commit: recoveryOperator, entries: [
    {
      function: "approve",
      target: hookrToken,
      value: 0n,
      input: approveCalldata(),
      nonce: 708,
      block: 107,
    },
    {
      function: "exactInput",
      target: router,
      value: 0n,
      input: swapCalldata({
        currency0: hookrToken,
        currency1: hookrPairToken,
        amountIn: 25_000n * 10n ** 18n,
        minimum: 1_000_000n * 10n ** 18n,
        deadline: hookrDeadline,
      }),
      nonce: 709,
      block: 108,
      logs: [guardedSwapLog(hookrPoolId)],
    },
  ] });

  const dir = mkdtempSync(join(process.cwd(), ".phase-a-index-test-"));
  const path = (name) => join(dir, name);
  const context = {
    instantLaunchRun,
    instantLaunchPath: path("instant-launch.json"),
    instantBuyAuctionLaunchRun,
    instantBuyAuctionLaunchPath: path("instant-buy-auction-launch.json"),
    ownerBidTransaction: ownerBid.transaction,
    ownerBidTransactionPath: path("owner-bid-transaction.json"),
    ownerBidReceipt: ownerBid.receipt,
    ownerBidReceiptPath: path("owner-bid-receipt.json"),
    hookrLaunchRun,
    hookrLaunchPath: path("hookr-launch.json"),
    hookrApproveBuyRun,
    hookrApproveBuyPath: path("hookr-approve-buy.json"),
    shortenTransaction: shorten.transaction,
    shortenTransactionPath: path("shorten-transaction.json"),
    shortenReceipt: shorten.receipt,
    shortenReceiptPath: path("shorten-receipt.json"),
    restoreTransaction: restore.transaction,
    restoreTransactionPath: path("restore-transaction.json"),
    restoreReceipt: restore.receipt,
    restoreReceiptPath: path("restore-receipt.json"),
    deploymentSourceCommit: deployment,
    originalCanaryOperatorCommit: originalOperator,
    canaryRecoveryCommit: recoveryOperator,
    sender,
    launchpad,
    router,
    hookrToken,
    hook,
    instantToken,
    auctionToken,
    auction,
    bidId: "3",
    hookrPairToken,
  };
  sync(context, ...Object.keys(objectToPath));
  return { dir, context };
};

test("each Phase A stage exact-calldata gate runs independently before the next signer boundary", () => {
  const { dir, context } = fixture();
  try {
    const common = {
      sender,
      launchpad,
      router,
      hookrToken,
      hook,
    };
    assert.equal(assertV5PhaseAStageSemantics({
      ...common,
      canaryOperatorCommit: originalOperator,
      stage: "instant-launch",
      run: context.instantLaunchRun,
      instantToken,
    }), true);
    assert.equal(assertV5PhaseAStageSemantics({
      ...common,
      canaryOperatorCommit: originalOperator,
      stage: "instant-buy-auction-launch",
      run: context.instantBuyAuctionLaunchRun,
      instantToken,
    }), true);
    assert.equal(assertV5PhaseAStageSemantics({
      ...common,
      canaryOperatorCommit: recoveryOperator,
      stage: "hookr-launch",
      run: context.hookrLaunchRun,
    }), true);
    assert.equal(assertV5PhaseAStageSemantics({
      ...common,
      canaryOperatorCommit: recoveryOperator,
      stage: "hookr-approve-buy",
      run: context.hookrApproveBuyRun,
      hookrPairToken,
    }), true);

    assert.equal(assertV5PhaseAOwnerBidSemantics({
      transaction: context.ownerBidTransaction,
      receipt: context.ownerBidReceipt,
      sender,
      auction,
      bidId: "3",
      auctionEndBlock,
    }), true);
    context.ownerBidTransaction.input = bidCalldata({
      maxPrice: 814_814_390_533_794_434_497_901_791_991_308_996_216n,
    });
    assert.throws(
      () => assertV5PhaseAOwnerBidSemantics({
        transaction: context.ownerBidTransaction,
        receipt: context.ownerBidReceipt,
        sender,
        auction,
        bidId: "3",
        auctionEndBlock,
      }),
      /exact reviewed submitBid call/,
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("stage gates require receipt-local guarded fees and exact flywheel accrual", () => {
  for (const [label, mutate, expected] of [
    [
      "unguarded fee",
      (context) => { context.instantBuyAuctionLaunchRun.receipts[0].logs[0] = guardedSwapLog(instantPoolId, 3_000n); },
      /does not prove the guarded 20% snipe tax/,
    ],
    [
      "wrong accrual",
      (context) => {
        context.instantBuyAuctionLaunchRun.receipts[0].logs[1] =
          flywheelAccruedLog(instantPoolId, 2_999_999_999_999n);
      },
      /flywheel accrual .* is not 3000000000000/,
    ],
  ]) {
    const { dir, context } = fixture();
    try {
      mutate(context);
      assert.throws(
        () => assertV5PhaseAStageSemantics({
          stage: "instant-buy-auction-launch",
          run: context.instantBuyAuctionLaunchRun,
          canaryOperatorCommit: originalOperator,
          sender,
          launchpad,
          router,
          hookrToken,
          hook,
          instantToken,
        }),
        expected,
        label,
      );
      sync(context, "instantBuyAuctionLaunchRun");
      assert.throws(() => buildV5PhaseAIndex(context), expected, `${label} aggregate`);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }
});

test("phase A index binds four Forge artifacts, the raw owner bid, timing, and derived identities", () => {
  const { dir, context } = fixture();
  try {
    const index = buildV5PhaseAIndex(context);
    assert.equal(index.kind, "hookr-v5-phase-a-evidence-v3");
    assert.equal(
      index.evidencePolicy,
      "four-unmodified-raw-forge-artifacts-plus-one-raw-owner-bid-and-two-raw-timing-transaction-pairs",
    );
    assert.deepEqual(index.transactionSequence.map((record) => record.artifact), [
      "instantLaunch",
      "shorten",
      "instantBuyAuctionLaunch",
      "instantBuyAuctionLaunch",
      "restore",
      "ownerBid",
      "hookrLaunch",
      "hookrApproveBuy",
      "hookrApproveBuy",
    ]);
    assert.deepEqual(index.transactionSequence.map((record) => record.nonce), [
      "701", "702", "703", "704", "705", "706", "707", "708", "709",
    ]);
    assert.deepEqual(index.transactionSequence.map((record) => record.calldata.slice(0, 10)), [
      "0x4477d2ab",
      "0xb45ca38b",
      "0xe7e0aee5",
      "0x1b472fc9",
      "0xb45ca38b",
      "0x140fe8ee",
      "0x4477d2ab",
      "0x095ea7b3",
      "0xe7e0aee5",
    ]);
    assert.equal(index.identities.instantPoolId, instantPoolId);
    assert.deepEqual(index.identities.instantFlywheelAccrual, {
      transactionHash: hash(1_703),
      blockNumber: "102",
      transactionIndex: "0",
      logIndex: "1",
      poolId: instantPoolId,
      amountWei: "3000000000000",
    });
    assert.equal(index.identities.hookrPoolId, hookrPoolId);
    assert.equal(index.identities.hook, hook);
    assert.equal(index.identities.auctionEndBlock, auctionEndBlock.toString());
    assert.equal(
      index.reviewedSemantics.bidMaxPriceQ96,
      "814814390533794434497901791991308996217",
    );
    assert.equal(index.reviewedSemantics.guardBlocks, "20000");
    assert.equal(index.reviewedSemantics.guardedSwapFeePips, "203000..230000");
    assert.equal(index.reviewedSemantics.flywheelFeeAccruedWei, "3000000000000");
    assert.equal(index.reviewedSemantics.bidAmountWei, "10500000000000000");
    assert.equal(index.reviewedSemantics.hookrApprovalAndBuyAmount, (25_000n * 10n ** 18n).toString());
    assert.equal(
      index.reviewedSemantics.swapDeadlineBound,
      "calldata-only-no-mined-timestamp-in-raw-forge-receipt",
    );
    assert.equal(index.rawForgeArtifacts.instantLaunch.transactions, 1);
    assert.equal(index.rawForgeArtifacts.instantBuyAuctionLaunch.transactions, 2);
    assert.equal(index.rawForgeArtifacts.hookrLaunch.transactions, 1);
    assert.equal(index.rawForgeArtifacts.hookrApproveBuy.transactions, 2);
    assert.equal(index.originalCanaryOperatorCommit, originalOperator);
    assert.equal(index.canaryRecoveryCommit, recoveryOperator);
    assert.doesNotThrow(() => assertV5PhaseAIndex(index, context));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("phase A index rejects in-repository symlinks to mutable raw evidence", () => {
  const { dir, context } = fixture();
  try {
    const linkedPath = join(dir, "instant-launch-linked.json");
    symlinkSync(context.instantLaunchPath, linkedPath);
    context.instantLaunchPath = linkedPath;
    assert.throws(
      () => buildV5PhaseAIndex(context),
      /raw evidence path must not traverse a symbolic link/,
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("phase A index rejects swapped artifacts and duplicate or missing receipts", () => {
  const swapped = fixture();
  try {
    [
      swapped.context.instantLaunchRun,
      swapped.context.hookrLaunchRun,
    ] = [
      swapped.context.hookrLaunchRun,
      swapped.context.instantLaunchRun,
    ];
    [
      swapped.context.instantLaunchPath,
      swapped.context.hookrLaunchPath,
    ] = [
      swapped.context.hookrLaunchPath,
      swapped.context.instantLaunchPath,
    ];
    assert.throws(() => buildV5PhaseAIndex(swapped.context), /instant token differs from raw InstantLaunched/);
  } finally {
    rmSync(swapped.dir, { recursive: true, force: true });
  }

  const duplicate = fixture();
  try {
    duplicate.context.instantBuyAuctionLaunchRun.receipts[1].transactionHash =
      duplicate.context.instantBuyAuctionLaunchRun.receipts[0].transactionHash;
    sync(duplicate.context, "instantBuyAuctionLaunchRun");
    assert.throws(() => buildV5PhaseAIndex(duplicate.context), /repeats receipt/);
  } finally {
    rmSync(duplicate.dir, { recursive: true, force: true });
  }

  const missing = fixture();
  try {
    missing.context.hookrLaunchRun.receipts.pop();
    sync(missing.context, "hookrLaunchRun");
    assert.throws(() => buildV5PhaseAIndex(missing.context), /has 0 receipts, expected 1/);
  } finally {
    rmSync(missing.dir, { recursive: true, force: true });
  }
});

test("phase A index detects changed transaction hash, input, value, and target", () => {
  const cases = [
    {
      label: "hash",
      object: "instantLaunchRun",
      mutate: (context) => { context.instantLaunchRun.transactions[0].hash = hash(99_999); },
      expected: /no hash-matched raw receipt/,
    },
    {
      label: "input",
      object: "instantLaunchRun",
      mutate: (context) => { context.instantLaunchRun.transactions[0].transaction.input = "0xff"; },
      expected: /exact reviewed launchInstant call/,
    },
    {
      label: "value",
      object: "instantBuyAuctionLaunchRun",
      mutate: (context) => { context.instantBuyAuctionLaunchRun.transactions[0].transaction.value = "0x1"; },
      expected: /value 1 is not/,
    },
    {
      label: "target",
      object: "ownerBidTransaction",
      mutate: (context) => { context.ownerBidTransaction.to = launchpad; },
      expected: /sender or target is wrong/,
    },
  ];
  for (const { label, object, mutate, expected } of cases) {
    const { dir, context } = fixture();
    try {
      const index = buildV5PhaseAIndex(context);
      mutate(context);
      sync(context, object);
      assert.throws(() => assertV5PhaseAIndex(index, context), expected, label);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }
});

test("phase A index pins the exact reviewed calldata semantics for six Forge calls and the owner bid", () => {
  const cases = [
    {
      label: "instant launch metadata and config",
      object: "instantLaunchRun",
      expected: /exact reviewed launchInstant call/,
      mutate: (context) => {
        const params = [...instantFour];
        params[8] = 25;
        context.instantLaunchRun.transactions[0].transaction.input = launchInstantCalldata(
          launchArgs("Wrong Instant", "CANV5I", params),
          0,
          intents.instant,
        );
      },
    },
    {
      label: "auction floor and reserve",
      object: "instantBuyAuctionLaunchRun",
      expected: /exact reviewed launchAuction call/,
      mutate: (context) => {
        context.instantBuyAuctionLaunchRun.transactions[1].transaction.input =
          launchAuctionCalldata({ reserveBps: 2_001, floorFdv: 20_000_000_000_000_001n });
      },
    },
    {
      label: "bid max price",
      object: "ownerBidTransaction",
      expected: /exact reviewed submitBid call/,
      mutate: (context) => {
        context.ownerBidTransaction.input = bidCalldata({
          maxPrice: 814_814_390_533_794_434_497_901_791_991_308_996_216n,
        });
      },
    },
    {
      label: "bid amount",
      object: "ownerBidTransaction",
      expected: /exact reviewed submitBid call/,
      mutate: (context) => {
        context.ownerBidTransaction.input =
          bidCalldata({ amount: 10_500_000_000_000_001n });
      },
    },
    {
      label: "bid owner",
      object: "ownerBidTransaction",
      expected: /exact reviewed submitBid call/,
      mutate: (context) => {
        context.ownerBidTransaction.input =
          bidCalldata({ owner: launchpad });
      },
    },
    {
      label: "bid hook data",
      object: "ownerBidTransaction",
      expected: /exact reviewed submitBid call/,
      mutate: (context) => {
        context.ownerBidTransaction.input =
          bidCalldata({ hookData: "0x01" });
      },
    },
    {
      label: "HOOKR launch quote and config",
      object: "hookrLaunchRun",
      expected: /exact reviewed launchInstant call/,
      mutate: (context) => {
        const params = [...guardTwo];
        params[6] = 100;
        context.hookrLaunchRun.transactions[0].transaction.input = launchInstantCalldata(
          launchArgs("Canary Hookr Pair V5", "CANV5H", params),
          0,
          intents.hookr,
        );
      },
    },
    {
      label: "HOOKR approval spender",
      object: "hookrApproveBuyRun",
      expected: /exact reviewed approve call/,
      mutate: (context) => {
        context.hookrApproveBuyRun.transactions[0].transaction.input = approveCalldata({ spender: sender });
      },
    },
    {
      label: "HOOKR approval amount",
      object: "hookrApproveBuyRun",
      expected: /exact reviewed approve call/,
      mutate: (context) => {
        context.hookrApproveBuyRun.transactions[0].transaction.input =
          approveCalldata({ amount: 24_999n * 10n ** 18n });
      },
    },
    {
      label: "ETH swap input",
      object: "instantBuyAuctionLaunchRun",
      expected: /exact reviewed exactInput call/,
      mutate: (context) => {
        context.instantBuyAuctionLaunchRun.transactions[0].transaction.input =
          instantSwapCalldata({ amountIn: 999_999_999_999_999n });
      },
    },
    {
      label: "ETH swap direction",
      object: "instantBuyAuctionLaunchRun",
      expected: /exact reviewed exactInput call/,
      mutate: (context) => {
        context.instantBuyAuctionLaunchRun.transactions[0].transaction.input =
          instantSwapCalldata({ zeroForOne: false });
      },
    },
    {
      label: "ETH swap minimum",
      object: "instantBuyAuctionLaunchRun",
      expected: /exact reviewed exactInput call/,
      mutate: (context) => {
        context.instantBuyAuctionLaunchRun.transactions[0].transaction.input =
          instantSwapCalldata({ minimum: 199_999n * 10n ** 18n });
      },
    },
    {
      label: "ETH swap recipient",
      object: "instantBuyAuctionLaunchRun",
      expected: /exact reviewed exactInput call/,
      mutate: (context) => {
        context.instantBuyAuctionLaunchRun.transactions[0].transaction.input =
          instantSwapCalldata({ recipient: launchpad });
      },
    },
    {
      label: "ETH swap price limit",
      object: "instantBuyAuctionLaunchRun",
      expected: /exact reviewed exactInput call/,
      mutate: (context) => {
        context.instantBuyAuctionLaunchRun.transactions[0].transaction.input =
          instantSwapCalldata({ sqrtPriceLimitX96: 4_295_128_741n });
      },
    },
    {
      label: "HOOKR swap input",
      object: "hookrApproveBuyRun",
      expected: /exact reviewed exactInput call/,
      mutate: (context) => {
        context.hookrApproveBuyRun.transactions[1].transaction.input =
          hookrSwapCalldata({ amountIn: 25_001n * 10n ** 18n });
      },
    },
    {
      label: "HOOKR swap pool token",
      object: "hookrApproveBuyRun",
      expected: /exact reviewed exactInput call/,
      mutate: (context) => {
        context.hookrApproveBuyRun.transactions[1].transaction.input =
          hookrSwapCalldata({ currency1: auctionToken });
      },
    },
  ];

  for (const { label, object, expected, mutate } of cases) {
    const { dir, context } = fixture();
    try {
      mutate(context);
      sync(context, object);
      assert.throws(() => buildV5PhaseAIndex(context), expected, label);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }
});

test("owner-bid evidence binds the canonical receipt, event outcome, and auction window", () => {
  const cases = [
    {
      label: "transaction hash",
      mutate: (context) => { context.ownerBidTransaction.hash = hash(90_001); },
      expected: /receipt does not match its raw transaction/,
    },
    {
      label: "chain",
      mutate: (context) => { context.ownerBidTransaction.chainId = quantity(1); },
      expected: /transaction is not on chain 4663/,
    },
    {
      label: "canonical coordinate",
      mutate: (context) => { context.ownerBidTransaction.transactionIndex = "0x1"; },
      expected: /canonical coordinates differ/,
    },
    {
      label: "event owner",
      mutate: (context) => {
        context.ownerBidReceipt.logs[0].topics[2] = addressTopic(launchpad);
      },
      expected: /BidSubmitted owner is wrong/,
    },
    {
      label: "event amount",
      mutate: (context) => {
        context.ownerBidReceipt.logs[0].data = encodeAbiParameters(
          [{ type: "uint256" }, { type: "uint128" }],
          [814_814_390_533_794_434_497_901_791_991_308_996_217n, 10_499_999_999_999_999n],
        );
      },
      expected: /BidSubmitted price or amount differs from the reviewed call/,
    },
    {
      label: "auction window",
      mutate: (context) => {
        context.ownerBidTransaction.blockNumber = quantity(auctionEndBlock);
        context.ownerBidReceipt.blockNumber = quantity(auctionEndBlock);
      },
      expected: /was not mined before the authenticated auction end block/,
    },
  ];

  for (const { label, mutate, expected } of cases) {
    const { dir, context } = fixture();
    try {
      mutate(context);
      assert.throws(
        () => assertV5PhaseAOwnerBidSemantics({
          transaction: context.ownerBidTransaction,
          receipt: context.ownerBidReceipt,
          sender,
          auction,
          bidId: "3",
          auctionEndBlock,
        }),
        expected,
        label,
      );
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }
});

test("phase A index bounds swap deadlines when raw receipts include mined timestamps", () => {
  const valid = fixture();
  try {
    valid.context.instantBuyAuctionLaunchRun.receipts[0].blockTimestamp =
      quantity(instantDeadline - 500n);
    valid.context.hookrApproveBuyRun.receipts[1].blockTimestamp = quantity(hookrDeadline - 1n);
    sync(valid.context, "instantBuyAuctionLaunchRun", "hookrApproveBuyRun");
    assert.equal(
      buildV5PhaseAIndex(valid.context).reviewedSemantics.swapDeadlineBound,
      "within-600-seconds-of-mined-block",
    );
  } finally {
    rmSync(valid.dir, { recursive: true, force: true });
  }

  for (const [label, minedTimestamp] of [
    ["expired", instantDeadline],
    ["too far", instantDeadline - 601n],
  ]) {
    const { dir, context } = fixture();
    try {
      context.instantBuyAuctionLaunchRun.receipts[0].blockTimestamp = quantity(minedTimestamp);
      sync(context, "instantBuyAuctionLaunchRun");
      assert.throws(
        () => buildV5PhaseAIndex(context),
        /deadline is not within 600 seconds after its mined block timestamp/,
        label,
      );
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }
});

test("phase A index rejects cross-boundary nonce gaps and receipt reordering", () => {
  const nonceGap = fixture();
  try {
    nonceGap.context.instantBuyAuctionLaunchRun.transactions[0].transaction.nonce = quantity(704);
    sync(nonceGap.context, "instantBuyAuctionLaunchRun");
    assert.throws(() => buildV5PhaseAIndex(nonceGap.context), /nonces are not consecutive/);
  } finally {
    rmSync(nonceGap.dir, { recursive: true, force: true });
  }

  const reordered = fixture();
  try {
    reordered.context.instantBuyAuctionLaunchRun.receipts[0].blockNumber = quantity(101);
    sync(reordered.context, "instantBuyAuctionLaunchRun");
    assert.throws(() => buildV5PhaseAIndex(reordered.context), /receipts are not in strict canonical order/);
  } finally {
    rmSync(reordered.dir, { recursive: true, force: true });
  }
});

test("phase A index binds receipt block hashes, both operator commits, and its own exact bytes", () => {
  const changedBlockHash = fixture();
  try {
    const index = buildV5PhaseAIndex(changedBlockHash.context);
    changedBlockHash.context.hookrApproveBuyRun.receipts[1].blockHash = hash(88_888);
    sync(changedBlockHash.context, "hookrApproveBuyRun");
    assert.throws(
      () => assertV5PhaseAIndex(index, changedBlockHash.context),
      /differs from its raw source evidence/,
    );
  } finally {
    rmSync(changedBlockHash.dir, { recursive: true, force: true });
  }

  const wrongOperator = fixture();
  try {
    wrongOperator.context.originalCanaryOperatorCommit = "f".repeat(40);
    assert.throws(() => buildV5PhaseAIndex(wrongOperator.context), /is not operator/);
  } finally {
    rmSync(wrongOperator.dir, { recursive: true, force: true });
  }

  const modifiedIndex = fixture();
  try {
    const index = buildV5PhaseAIndex(modifiedIndex.context);
    index.transactionSequence[5].value = "1";
    assert.throws(
      () => assertV5PhaseAIndex(index, modifiedIndex.context),
      /differs from its raw source evidence/,
    );
  } finally {
    rmSync(modifiedIndex.dir, { recursive: true, force: true });
  }
});

test("phase A index rejects timing hash, selector/calldata, target, value, and coordinate changes", () => {
  const cases = [
    {
      label: "hash",
      objects: ["shortenTransaction"],
      mutate: (context) => { context.shortenTransaction.hash = hash(77_777); },
      expected: /receipt does not match its raw transaction/,
    },
    {
      label: "selector",
      objects: ["shortenTransaction"],
      mutate: (context) => {
        context.shortenTransaction.input = `0xdeadbeef${timingCalldata(20_000).slice(10)}`;
      },
      expected: /calldata is not setAuctionTiming\(20000,0,1\)/,
    },
    {
      label: "calldata arguments",
      objects: ["shortenTransaction"],
      mutate: (context) => { context.shortenTransaction.input = timingCalldata(19_999); },
      expected: /calldata is not setAuctionTiming\(20000,0,1\)/,
    },
    {
      label: "target",
      objects: ["restoreTransaction", "restoreReceipt"],
      mutate: (context) => {
        context.restoreTransaction.to = router;
        context.restoreReceipt.to = router;
      },
      expected: /sender or target is wrong/,
    },
    {
      label: "value",
      objects: ["restoreTransaction"],
      mutate: (context) => { context.restoreTransaction.value = "0x1"; },
      expected: /sends nonzero value/,
    },
    {
      label: "canonical coordinate",
      objects: ["shortenTransaction"],
      mutate: (context) => { context.shortenTransaction.blockHash = hash(66_666); },
      expected: /canonical coordinates differ/,
    },
  ];
  for (const { label, objects, mutate, expected } of cases) {
    const { dir, context } = fixture();
    try {
      mutate(context);
      sync(context, ...objects);
      assert.throws(() => buildV5PhaseAIndex(context), expected, label);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }

  const reboundTiming = fixture();
  try {
    const index = buildV5PhaseAIndex(reboundTiming.context);
    const newBlockHash = hash(55_555);
    reboundTiming.context.restoreTransaction.blockHash = newBlockHash;
    reboundTiming.context.restoreReceipt.blockHash = newBlockHash;
    sync(reboundTiming.context, "restoreTransaction", "restoreReceipt");
    assert.throws(
      () => assertV5PhaseAIndex(index, reboundTiming.context),
      /differs from its raw source evidence/,
    );
  } finally {
    rmSync(reboundTiming.dir, { recursive: true, force: true });
  }
});

test("phase A index derives and binds both pool ids and enforces the auction end block", () => {
  const changedInstantPool = fixture();
  try {
    const index = buildV5PhaseAIndex(changedInstantPool.context);
    changedInstantPool.context.instantLaunchRun.receipts[0].logs[0].topics[2] = hash(12_345);
    sync(changedInstantPool.context, "instantLaunchRun");
    assert.throws(
      () => assertV5PhaseAIndex(index, changedInstantPool.context),
      /instant buy PoolKey does not match/,
    );
  } finally {
    rmSync(changedInstantPool.dir, { recursive: true, force: true });
  }

  const changedHookrPool = fixture();
  try {
    const index = buildV5PhaseAIndex(changedHookrPool.context);
    changedHookrPool.context.hookrLaunchRun.receipts[0].logs[0].topics[2] = hash(54_321);
    sync(changedHookrPool.context, "hookrLaunchRun");
    assert.throws(
      () => assertV5PhaseAIndex(index, changedHookrPool.context),
      /HOOKR buy PoolKey does not match/,
    );
  } finally {
    rmSync(changedHookrPool.dir, { recursive: true, force: true });
  }

  const wrongEnd = fixture();
  try {
    wrongEnd.context.instantBuyAuctionLaunchRun.receipts[1].logs[0].data =
      encodedAuctionData(auctionEndBlock + 1n);
    sync(wrongEnd.context, "instantBuyAuctionLaunchRun");
    assert.throws(
      () => buildV5PhaseAIndex(wrongEnd.context),
      /AuctionStarted endBlock .* is not launch block 103 \+ 20000/,
    );
  } finally {
    rmSync(wrongEnd.dir, { recursive: true, force: true });
  }

  const wrongTerms = fixture();
  try {
    wrongTerms.context.instantBuyAuctionLaunchRun.receipts[1].logs[0].data = encodeAbiParameters(
      [{ type: "uint40" }, { type: "uint96" }, { type: "uint96" }, { type: "uint16" }],
      [auctionEndBlock, 20_000_000_000_000_001n, 10_000_000_000_000_000n, 2_000],
    );
    sync(wrongTerms.context, "instantBuyAuctionLaunchRun");
    assert.throws(
      () => buildV5PhaseAIndex(wrongTerms.context),
      /AuctionStarted terms are not the reviewed floor, raise, and reserve split/,
    );
  } finally {
    rmSync(wrongTerms.dir, { recursive: true, force: true });
  }

  const malformedEnd = fixture();
  try {
    malformedEnd.context.instantBuyAuctionLaunchRun.receipts[1].logs[0].data = "0x";
    sync(malformedEnd.context, "instantBuyAuctionLaunchRun");
    assert.throws(() => buildV5PhaseAIndex(malformedEnd.context), /AuctionStarted data is malformed/);
  } finally {
    rmSync(malformedEnd.dir, { recursive: true, force: true });
  }
});
