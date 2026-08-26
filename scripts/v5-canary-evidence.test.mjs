import assert from "node:assert/strict";
import {
  mkdtempSync,
  renameSync,
  rmSync,
  symlinkSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { poolIdForKey } from "./lib/instant-canary-evidence.mjs";
import {
  assertAuthenticatedLocalFileUnchanged,
  assertRawReceiptMatchesLive,
  redactConfiguredRpc,
  snapshotAuthenticatedLocalFile,
  V5_CANARY_SPEC,
  validateV5CanaryEvidence,
} from "./lib/v5-canary-evidence.mjs";

const address = (value) => `0x${value.toString(16).padStart(40, "0")}`;
const hash = (value) => `0x${value.toString(16).padStart(64, "0")}`;

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const DEAD_ADDRESS = "0x000000000000000000000000000000000000dEaD";
const Q96 = 1n << 96n;

const integerSqrt = (value) => {
  let result = value;
  let candidate = (value + 1n) / 2n;
  while (candidate < result) {
    result = candidate;
    candidate = (value / candidate + candidate) / 2n;
  }
  return result;
};

test("authenticated local snapshots reject mutation, deletion, replacement, and symlinks", () => {
  const directory = mkdtempSync(join(tmpdir(), "hookr-authenticated-input-"));
  try {
    const stablePath = join(directory, "stable.json");
    writeFileSync(stablePath, '{"stable":true}\n');
    const stable = snapshotAuthenticatedLocalFile(stablePath, "stable input");
    assert.equal(
      assertAuthenticatedLocalFileUnchanged(stable, "stable input"),
      true,
    );

    const mutatedPath = join(directory, "mutated.json");
    writeFileSync(mutatedPath, '{"value":1}\n');
    const mutated = snapshotAuthenticatedLocalFile(
      mutatedPath,
      "mutated input",
    );
    writeFileSync(mutatedPath, '{"value":2}\n');
    assert.throws(
      () => assertAuthenticatedLocalFileUnchanged(mutated, "mutated input"),
      /changed after it was authenticated/,
    );

    const deletedPath = join(directory, "deleted.json");
    writeFileSync(deletedPath, '{"deleted":false}\n');
    const deleted = snapshotAuthenticatedLocalFile(
      deletedPath,
      "deleted input",
    );
    unlinkSync(deletedPath);
    assert.throws(
      () => assertAuthenticatedLocalFileUnchanged(deleted, "deleted input"),
      /could not be re-authenticated before write/,
    );

    const replacedPath = join(directory, "replaced.json");
    const replacementPath = join(directory, "replacement.json");
    writeFileSync(replacedPath, '{"sameBytes":true}\n');
    const replaced = snapshotAuthenticatedLocalFile(
      replacedPath,
      "replaced input",
    );
    writeFileSync(replacementPath, '{"sameBytes":true}\n');
    renameSync(replacementPath, replacedPath);
    assert.throws(
      () => assertAuthenticatedLocalFileUnchanged(replaced, "replaced input"),
      /changed after it was authenticated/,
    );

    const symlinkPath = join(directory, "linked.json");
    symlinkSync(stablePath, symlinkPath);
    assert.throws(
      () => snapshotAuthenticatedLocalFile(symlinkPath, "symlink input"),
      /cannot snapshot symlink input/,
    );
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("RPC redaction removes exact and URI-encoded endpoint spellings", () => {
  const rpc =
    "https://example.invalid/v2/private-Key_123?owner=alice@example.com";
  const message = [rpc, encodeURI(rpc), encodeURIComponent(rpc), rpc].join(
    " | ",
  );
  const redacted = redactConfiguredRpc(message, rpc);
  assert.equal(
    redacted,
    [
      "<configured RPC>",
      "<configured RPC>",
      "<configured RPC>",
      "<configured RPC>",
    ].join(" | "),
  );
  assert.ok(!redacted.includes("private-Key_123"));
  assert.equal(redactConfiguredRpc("ordinary failure", ""), "ordinary failure");
});

const rawReceiptFixture = () => ({
  blockHash: hash(0xb10c),
  blockNumber: "0x64",
  contractAddress: null,
  cumulativeGasUsed: "0x5208",
  effectiveGasPrice: "0x3b9aca00",
  from: address(0x1111),
  gasUsed: "0x5000",
  gasUsedForL1: "0x123",
  l1BlockNumber: "0x3e8",
  logs: [
    {
      address: address(0x2222),
      blockHash: hash(0xb10c),
      blockNumber: "0x64",
      blockTimestamp: "0xf4240",
      data: "0x1234",
      logIndex: "0x0",
      removed: false,
      topics: [hash(0xabc), hash(0xdef)],
      transactionHash: hash(0x777),
      transactionIndex: "0x1",
    },
  ],
  logsBloom: `0x${"00".repeat(256)}`,
  status: "0x1",
  to: address(0x3333),
  transactionHash: hash(0x777),
  transactionIndex: "0x1",
  type: "0x2",
});

test("raw receipt binding compares every persisted receipt field and ordered log", () => {
  const raw = rawReceiptFixture();
  const live = structuredClone(raw);
  delete live.l1BlockNumber;
  delete live.logs[0].blockTimestamp;
  assert.doesNotThrow(() =>
    assertRawReceiptMatchesLive(raw, live, {
      label: "canary receipt",
      contractBlockNumber: 1_000n,
      blockTimestamp: 1_000_000n,
    }),
  );

  const changedLog = structuredClone(live);
  changedLog.logs[0].topics[1] = hash(0xfeed);
  assert.throws(
    () =>
      assertRawReceiptMatchesLive(raw, changedLog, {
        label: "canary receipt",
        contractBlockNumber: 1_000n,
        blockTimestamp: 1_000_000n,
      }),
    /persisted raw receipt\/logs differ/,
  );

  const changedReceipt = structuredClone(live);
  changedReceipt.gasUsed = "0x4fff";
  assert.throws(
    () =>
      assertRawReceiptMatchesLive(raw, changedReceipt, {
        label: "canary receipt",
        contractBlockNumber: 1_000n,
        blockTimestamp: 1_000_000n,
      }),
    /persisted raw receipt\/logs differ/,
  );
});

const addresses = {
  canarySender: address(0xc0ffee),
  launchpad: address(0x5001),
  hook: address(0x5002),
  router: address(0x5003),
  poolManager: address(0x5004),
  instantToken: address(0x6001),
  auctionToken: address(0x6002),
  auction: address(0x7001),
  burner: address(0x7002),
  // HOOKR-paired tokens are mined ABOVE the quote token, so the pair token sorts after HOOKR.
  hookrToken: address(0x8001),
  hookrPairToken: address(0x9001),
};

const poolKey = (token, quoteCurrency = ZERO_ADDRESS) => ({
  currency0: quoteCurrency,
  currency1: token,
  fee: V5_CANARY_SPEC.dynamicFee,
  tickSpacing: V5_CANARY_SPEC.tickSpacing,
  hooks: addresses.hook,
});

const launchArgs = (name, symbol, hookParams) => ({
  name,
  symbol,
  tagline: V5_CANARY_SPEC.tagline,
  logoURI: "",
  expectedCreator: addresses.canarySender,
  blueprintId: 0,
  custom: { ...hookParams },
  creatorFeeBps: 0,
  feeRecipients: [],
});

function fixture() {
  const spec = V5_CANARY_SPEC;
  const instantPoolId = poolIdForKey(poolKey(addresses.instantToken));
  const auctionPoolId = poolIdForKey(poolKey(addresses.auctionToken));
  const hookrPoolId = poolIdForKey(
    poolKey(addresses.hookrPairToken, addresses.hookrToken),
  );

  // Deploy receipts precede the canary in a real artifact order; the validator must extract the
  // canary receipts by label, not by position.
  const labels = [
    "launchpadLib",
    "launchpad",
    ...spec.phaseAReceiptLabels,
    ...spec.phaseBReceiptLabels,
  ];
  // Phase B is mined after the 20,000-block canary auction window.
  const blockNumbers = [
    100n,
    101n, // deploy prefix
    110n,
    111n,
    112n,
    113n,
    114n,
    115n,
    116n,
    117n,
    118n, // phase A (9)
    20_200n,
    20_201n,
    20_202n,
    20_203n,
    20_204n,
    20_205n, // phase B (6)
  ];
  const receiptOrder = labels.map((label, i) => ({
    label,
    hash: hash(BigInt(i + 1)),
    blockNumber: blockNumbers[i],
    transactionIndex: 0,
  }));
  const blockOf = (label) =>
    receiptOrder.find((r) => r.label === label).blockNumber;
  const receiptOf = (label) =>
    receiptOrder.find((record) => record.label === label);
  const eventRef = (label, logIndex) => ({
    transactionHash: receiptOf(label).hash,
    logIndex,
  });

  const allCanaryLabels = [
    ...spec.phaseAReceiptLabels,
    ...spec.phaseBReceiptLabels,
  ];
  const transaction = (to, value, blockNumber) => {
    const label = receiptOrder.find(
      (record) => record.blockNumber === blockNumber,
    )?.label;
    const sequence = allCanaryLabels.indexOf(label);
    assert.ok(
      sequence >= 0,
      `fixture transaction block ${blockNumber} has no canary label`,
    );
    return {
      from: addresses.canarySender,
      to,
      value,
      nonce: 500n + BigInt(sequence),
      blockNumber,
      contractBlockNumber: 1_000n + BigInt(sequence),
      blockTimestamp: 1_000_000n + blockNumber,
    };
  };

  const auctionEndBlock =
    blockOf("canary:auction-launch") + spec.canaryAuctionDurationBlocks;
  // A bid cap is not the uniform clearing price. Keep the outcome below the recovery bid's exact
  // high cap so this fixture models the permissionless bids that forced the owner-bid recovery.
  const clearingPriceQ96 = 3_169_126_500_570_573_400n;
  const clearingOpenPriceWei = (clearingPriceQ96 * 10n ** 18n) / Q96;
  const clearingSqrtPriceX96 = integerSqrt(
    ((10n ** 18n) << 192n) / clearingOpenPriceWei,
  );
  const proceedsWei = 2_500_000_000_000_000n;
  const instantOpenPriceWei = 2_500_000_000n;
  const hookrInstantOpenPriceWei = 2_500_000_000_000_000n; // 2.5M HOOKR FDV / 1e9 supply
  const flywheelEthIn = 3_000_000_000_000n; // the 0.3% the phase-A ETH buy accrued
  const hookrBurned = 3_494_135_610_596_751_569n;
  const effectivePoolConfig = (
    hookParams,
    token,
    configuredAtBlock,
    openPriceWei,
    flywheelFeePips,
  ) => ({
    initialized: true,
    guardEndBlock: configuredAtBlock + BigInt(hookParams.guardBlocks),
    baseFeePips: hookParams.baseFeePips,
    maxFeePips: hookParams.maxFeePips,
    snipeTaxPips: hookParams.snipeTaxPips,
    surgeSens: hookParams.surgeSens,
    burnBps: hookParams.burnBps,
    lpBps: hookParams.lpBps,
    potBps: hookParams.potBps,
    royaltyBps: 0,
    potEveryNBuys: hookParams.potEveryNBuys,
    maxBuyWei:
      (((spec.tokenSupply * BigInt(hookParams.maxBuyBps)) / 10_000n) *
        openPriceWei) /
      10n ** 18n,
    potMinBuyWei: hookParams.potMinBuyWei,
    burnTriggerWei: hookParams.burnTriggerWei,
    royaltyTo: ZERO_ADDRESS,
    token,
    flywheelFeePips,
  });

  return {
    receiptOrder,
    identities: {
      canarySender: addresses.canarySender,
      launchpad: addresses.launchpad,
      hook: addresses.hook,
      router: addresses.router,
      poolManager: addresses.poolManager,
      hookrToken: addresses.hookrToken,
      burner: addresses.burner,
    },
    timing: {
      shorten: {
        transaction: transaction(
          addresses.launchpad,
          0n,
          blockOf("canary:auction-timing-shorten"),
        ),
        calldata: {
          durationBlocks: 20_000n,
          claimDelay: 0n,
          migrationDelay: 1n,
        },
        event: { durationBlocks: 20_000n, claimDelay: 0n, migrationDelay: 1n },
      },
      restore: {
        transaction: transaction(
          addresses.launchpad,
          0n,
          blockOf("canary:auction-timing-restore"),
        ),
        calldata: {
          durationBlocks: 125_000n,
          claimDelay: 0n,
          migrationDelay: 1n,
        },
        event: { durationBlocks: 125_000n, claimDelay: 0n, migrationDelay: 1n },
      },
    },
    instant: {
      launch: {
        transaction: transaction(
          addresses.launchpad,
          spec.creationFeeWei,
          blockOf("canary:instant-launch"),
        ),
        calldata: {
          args: launchArgs(
            spec.instantName,
            spec.instantSymbol,
            spec.instantHookParams,
          ),
          quote: spec.quote.eth,
          intentId: spec.instantIntentId,
        },
        tokenEvent: {
          token: addresses.instantToken,
          creator: addresses.canarySender,
          blueprintId: 0,
          mode: spec.launchMode.instant,
          name: spec.instantName,
          symbol: spec.instantSymbol,
          tagline: spec.tagline,
          logoURI: "",
        },
        instantEvent: {
          token: addresses.instantToken,
          poolId: instantPoolId,
          openPriceWei: instantOpenPriceWei,
        },
        initializeEvent: {
          id: instantPoolId,
          currency0: "0x0000000000000000000000000000000000000000",
          currency1: addresses.instantToken,
          fee: spec.dynamicFee,
          tickSpacing: spec.tickSpacing,
          hooks: addresses.hook,
          sqrtPriceX96: 4_961_233_534_242_224_396_384n,
          tick: -184_200,
        },
      },
      buy: {
        transaction: transaction(
          addresses.router,
          spec.buyWei,
          blockOf("canary:instant-buy"),
        ),
        calldata: {
          key: poolKey(addresses.instantToken),
          zeroForOne: true,
          amountIn: spec.buyWei,
          amountOutMinimum: spec.buyMinTokensOut,
          sqrtPriceLimitX96: spec.minSqrtPriceLimitX96,
          recipient: addresses.canarySender,
          deadline: 1_000_000n + blockOf("canary:instant-buy") + 600n,
        },
        event: {
          payer: addresses.canarySender,
          recipient: addresses.canarySender,
          token: addresses.instantToken,
          zeroForOne: true,
          exactInput: true,
          amountIn: spec.buyWei,
          amountOut: spec.buyMinTokensOut + 123n,
        },
        poolManagerEvent: {
          id: instantPoolId,
          sender: addresses.router,
          sqrtPriceX96: 4_961_233_534_242_224_396_000n,
          liquidity: 1n,
          fee: 220_000,
        },
        flywheelEvent: {
          poolId: instantPoolId,
          amountWei: (spec.buyWei * spec.flywheelFeePips) / 1_000_000n,
        },
        transferEvent: {
          token: addresses.instantToken,
          from: addresses.poolManager,
          to: addresses.canarySender,
          value: spec.buyMinTokensOut + 123n,
        },
      },
    },
    auction: {
      launch: {
        transaction: transaction(
          addresses.launchpad,
          spec.creationFeeWei,
          blockOf("canary:auction-launch"),
        ),
        calldata: {
          args: launchArgs(
            spec.auctionName,
            spec.auctionSymbol,
            spec.auctionHookParams,
          ),
          quote: spec.quote.eth,
          floorFdvWei: spec.floorFdvWei,
          raiseFloorWei: spec.raiseFloorWei,
          reserveBps: spec.reserveBps,
          intentId: spec.auctionIntentId,
        },
        tokenEvent: {
          token: addresses.auctionToken,
          creator: addresses.canarySender,
          blueprintId: 0,
          mode: spec.launchMode.bonded,
          name: spec.auctionName,
          symbol: spec.auctionSymbol,
          tagline: spec.tagline,
          logoURI: "",
        },
        startedEvent: {
          token: addresses.auctionToken,
          auction: addresses.auction,
          endBlock: auctionEndBlock,
          floorFdvWei: spec.floorFdvWei,
          raiseFloorWei: spec.raiseFloorWei,
          reserveBps: spec.reserveBps,
        },
      },
      bid: {
        transaction: transaction(
          addresses.auction,
          spec.bidWei,
          blockOf("canary:auction-bid"),
        ),
        bidId: 77n,
        calldata: {
          maxPriceQ96: spec.bidMaxPriceQ96,
          amount: spec.bidWei,
          owner: addresses.canarySender,
          hookData: "0x",
        },
        event: {
          id: 77n,
          owner: addresses.canarySender,
          priceQ96: spec.bidMaxPriceQ96,
          amount: spec.bidWei,
        },
      },
      migrate: {
        transaction: transaction(
          addresses.launchpad,
          0n,
          blockOf("canary:auction-migrate"),
        ),
        calldata: { token: addresses.auctionToken },
        migratedEvent: {
          ...eventRef("canary:auction-migrate", 13n),
          token: addresses.auctionToken,
          poolId: auctionPoolId,
          sqrtPriceX96: clearingSqrtPriceX96,
          ethLiquidity: 8_000_000_000_000_000n,
          tokenLiquidity: 190_000_000n * 10n ** 18n,
          tokensBurned: 10_000_000n * 10n ** 18n,
        },
        initializeEvent: {
          ...eventRef("canary:auction-migrate", 11n),
          id: auctionPoolId,
          currency0: ZERO_ADDRESS,
          currency1: addresses.auctionToken,
          fee: spec.dynamicFee,
          tickSpacing: spec.tickSpacing,
          hooks: addresses.hook,
          sqrtPriceX96: clearingSqrtPriceX96,
          tick: -1,
        },
        proceedsEvent: {
          ...eventRef("canary:auction-migrate", 12n),
          token: addresses.auctionToken,
          creator: addresses.canarySender,
          amountWei: proceedsWei,
        },
        currencySweptEvent: {
          ...eventRef("canary:auction-migrate", 10n),
          fundsRecipient: addresses.launchpad,
          currencyAmount: spec.bidWei,
        },
      },
      exit: {
        transaction: transaction(
          addresses.auction,
          0n,
          blockOf("canary:auction-exit"),
        ),
        calldata: { bidId: 77n },
        event: {
          ...eventRef("canary:auction-exit", 10n),
          bidId: 77n,
          owner: addresses.canarySender,
          tokensFilled: 700_000_000n * 10n ** 18n,
          currencyRefunded: 500_000_000_000_000n,
        },
      },
      claimTokens: {
        transaction: transaction(
          addresses.auction,
          0n,
          blockOf("canary:auction-claim"),
        ),
        calldata: { bidId: 77n, call: "claimTokens", requestedBidIds: [77n] },
        event: {
          ...eventRef("canary:auction-claim", 10n),
          bidId: 77n,
          owner: addresses.canarySender,
          tokensFilled: 700_000_000n * 10n ** 18n,
        },
        events: [
          {
            ...eventRef("canary:auction-claim", 10n),
            bidId: 77n,
            owner: addresses.canarySender,
            tokensFilled: 700_000_000n * 10n ** 18n,
          },
        ],
        transferEvent: {
          token: addresses.auctionToken,
          from: addresses.auction,
          to: addresses.canarySender,
          value: 700_000_000n * 10n ** 18n,
        },
        transferCount: 1,
        transferLogIndexes: [11n],
      },
      proceedsClaim: {
        transaction: transaction(
          addresses.launchpad,
          0n,
          blockOf("canary:auction-proceeds"),
        ),
        calldata: { token: addresses.auctionToken },
        claimEvent: {
          ...eventRef("canary:auction-proceeds", 10n),
          token: addresses.auctionToken,
          payTo: addresses.canarySender,
          amountWei: proceedsWei,
        },
      },
    },
    hookr: {
      launch: {
        transaction: transaction(
          addresses.launchpad,
          spec.creationFeeWei,
          blockOf("canary:hookr-launch"),
        ),
        calldata: {
          args: launchArgs(
            spec.hookrName,
            spec.hookrSymbol,
            spec.hookrHookParams,
          ),
          quote: spec.quote.hookr,
          intentId: spec.hookrIntentId,
        },
        tokenEvent: {
          token: addresses.hookrPairToken,
          creator: addresses.canarySender,
          blueprintId: 0,
          mode: spec.launchMode.instant,
          name: spec.hookrName,
          symbol: spec.hookrSymbol,
          tagline: spec.tagline,
          logoURI: "",
        },
        instantEvent: {
          token: addresses.hookrPairToken,
          poolId: hookrPoolId,
          openPriceWei: hookrInstantOpenPriceWei,
        },
        initializeEvent: {
          id: hookrPoolId,
          currency0: addresses.hookrToken,
          currency1: addresses.hookrPairToken,
          fee: spec.dynamicFee,
          tickSpacing: spec.tickSpacing,
          hooks: addresses.hook,
          sqrtPriceX96: 6_178_492_422_311_209_137_741n,
          tick: -163_400,
        },
      },
      approve: {
        transaction: transaction(
          addresses.hookrToken,
          0n,
          blockOf("canary:hookr-approve"),
        ),
        calldata: { spender: addresses.router, amount: spec.hookrBuyAmount },
        event: {
          owner: addresses.canarySender,
          spender: addresses.router,
          value: spec.hookrBuyAmount,
        },
      },
      buy: {
        transaction: transaction(
          addresses.router,
          0n,
          blockOf("canary:hookr-buy"),
        ),
        calldata: {
          key: poolKey(addresses.hookrPairToken, addresses.hookrToken),
          zeroForOne: true,
          amountIn: spec.hookrBuyAmount,
          amountOutMinimum: spec.hookrBuyMinTokensOut,
          sqrtPriceLimitX96: spec.minSqrtPriceLimitX96,
          recipient: addresses.canarySender,
          deadline: 1_000_000n + blockOf("canary:hookr-buy") + 600n,
        },
        event: {
          payer: addresses.canarySender,
          recipient: addresses.canarySender,
          token: addresses.hookrPairToken,
          zeroForOne: true,
          exactInput: true,
          amountIn: spec.hookrBuyAmount,
          amountOut: spec.hookrBuyMinTokensOut + 456n,
        },
        poolManagerEvent: {
          id: hookrPoolId,
          sender: addresses.router,
          sqrtPriceX96: 6_178_492_422_311_209_100_000n,
          liquidity: 1n,
          fee: 220_000,
        },
        transferEvent: {
          token: addresses.hookrPairToken,
          from: addresses.poolManager,
          to: addresses.canarySender,
          value: spec.hookrBuyMinTokensOut + 456n,
        },
      },
    },
    flywheel: {
      collect: {
        transaction: transaction(
          addresses.burner,
          0n,
          blockOf("canary:flywheel-collect"),
        ),
        event: {
          ...eventRef("canary:flywheel-collect", 11n),
          amountWei: flywheelEthIn,
        },
        claimedEvent: {
          ...eventRef("canary:flywheel-collect", 10n),
          account: addresses.burner,
          amountWei: flywheelEthIn,
        },
      },
      burn: {
        transaction: transaction(
          addresses.burner,
          0n,
          blockOf("canary:flywheel-burn"),
        ),
        calldata: {
          ethIn: flywheelEthIn,
          minHookrOut: V5_CANARY_SPEC.flywheelMinHookrOut,
        },
        burnedEvent: {
          ...eventRef("canary:flywheel-burn", 11n),
          caller: addresses.canarySender,
          ethIn: flywheelEthIn,
          hookrBurned: hookrBurned,
        },
        deadTransferEvent: {
          ...eventRef("canary:flywheel-burn", 10n),
          token: addresses.hookrToken,
          from: addresses.burner,
          to: DEAD_ADDRESS,
          value: hookrBurned,
        },
      },
    },
    postconditions: {
      instantOpenPriceWei,
      hookrInstantOpenPriceWei,
      instantLaunch: {
        token: addresses.instantToken,
        creator: addresses.canarySender,
        launchBlock: transaction(
          addresses.launchpad,
          spec.creationFeeWei,
          blockOf("canary:instant-launch"),
        ).contractBlockNumber,
        mode: spec.launchMode.instant,
        status: spec.launchStatus.live,
        quote: spec.quote.eth,
        poolId: instantPoolId,
        hookParams: { ...spec.instantHookParams },
      },
      hookrLaunch: {
        token: addresses.hookrPairToken,
        creator: addresses.canarySender,
        launchBlock: transaction(
          addresses.launchpad,
          spec.creationFeeWei,
          blockOf("canary:hookr-launch"),
        ).contractBlockNumber,
        mode: spec.launchMode.instant,
        status: spec.launchStatus.live,
        quote: spec.quote.hookr,
        poolId: hookrPoolId,
        hookParams: { ...spec.hookrHookParams },
      },
      auctionConfig: {
        currency: ZERO_ADDRESS,
        token: addresses.auctionToken,
        totalSupply: spec.auctionSupply,
        tokensRecipient: addresses.launchpad,
        fundsRecipient: addresses.launchpad,
        startBlock: blockOf("canary:auction-launch"),
        endBlock: auctionEndBlock,
        claimBlock: auctionEndBlock,
        validationHook: ZERO_ADDRESS,
        isGraduated: true,
      },
      auctionOutcome: {
        initialPriceX96: clearingPriceQ96,
        tokensSold: 700_000_000n * 10n ** 18n,
        currencyRaisedGross: spec.bidWei,
        currencyRaisedNetAtRead: spec.bidWei,
      },
      auctionLaunch: {
        token: addresses.auctionToken,
        creator: addresses.canarySender,
        launchBlock: transaction(
          addresses.launchpad,
          spec.creationFeeWei,
          blockOf("canary:auction-launch"),
        ).contractBlockNumber,
        mode: V5_CANARY_SPEC.launchMode.bonded,
        quote: V5_CANARY_SPEC.quote.eth,
        status: V5_CANARY_SPEC.launchStatus.live,
        reserveBps: V5_CANARY_SPEC.reserveBps,
        auction: addresses.auction,
        auctionEndBlock,
        migratedAtBlock: transaction(
          addresses.launchpad,
          0n,
          blockOf("canary:auction-migrate"),
        ).contractBlockNumber,
        poolId: auctionPoolId,
        openPriceWei: clearingOpenPriceWei,
        sqrtPriceX96AtOpen: clearingSqrtPriceX96,
        hookParams: { ...spec.auctionHookParams },
      },
      hookConfigs: {
        instant: effectivePoolConfig(
          spec.instantHookParams,
          addresses.instantToken,
          transaction(
            addresses.launchpad,
            spec.creationFeeWei,
            blockOf("canary:instant-launch"),
          ).contractBlockNumber,
          instantOpenPriceWei,
          spec.flywheelFeePips,
        ),
        auction: effectivePoolConfig(
          spec.auctionHookParams,
          addresses.auctionToken,
          transaction(
            addresses.launchpad,
            0n,
            blockOf("canary:auction-migrate"),
          ).contractBlockNumber,
          clearingOpenPriceWei,
          spec.flywheelFeePips,
        ),
        hookr: effectivePoolConfig(
          spec.hookrHookParams,
          addresses.hookrPairToken,
          transaction(
            addresses.launchpad,
            spec.creationFeeWei,
            blockOf("canary:hookr-launch"),
          ).contractBlockNumber,
          hookrInstantOpenPriceWei,
          0n,
        ),
      },
      auctionCreatorProceedsWei: 0n,
      hookrAllowance: 0n,
      auctionTiming: {
        durationBlocks: 125_000n,
        claimDelay: 0n,
        migrationDelay: 1n,
      },
    },
  };
}

const zeroProceedsFixture = () => {
  const evidence = fixture();
  const migrationReceipt = evidence.receiptOrder.find(
    (record) => record.label === "canary:auction-migrate",
  );
  const proceedsReceipt = evidence.receiptOrder.find(
    (record) => record.label === "canary:auction-proceeds",
  );
  proceedsReceipt.hash = migrationReceipt.hash;
  proceedsReceipt.blockNumber = migrationReceipt.blockNumber;
  proceedsReceipt.transactionIndex = migrationReceipt.transactionIndex;
  evidence.auction.migrate.proceedsEvent = null;
  evidence.auction.migrate.currencySweptEvent.currencyAmount =
    evidence.auction.migrate.migratedEvent.ethLiquidity;
  evidence.auction.proceedsClaim = {
    transaction: structuredClone(evidence.auction.migrate.transaction),
    calldata: {
      call: "not-applicable-zero-proceeds",
      mode: "not-applicable-zero-proceeds",
    },
    claimEvent: null,
    notApplicable: {
      executionMode: "not-applicable",
      mode: "not-applicable-zero-proceeds",
      token: addresses.auctionToken,
      amountWei: "0",
      proofTransactionHash: migrationReceipt.hash,
    },
  };
  evidence.receiptOrder.sort((left, right) =>
    left.blockNumber === right.blockNumber
      ? left.transactionIndex - right.transactionIndex
      : left.blockNumber < right.blockNumber
        ? -1
        : 1,
  );
  return evidence;
};

test("v5 canary evidence binds all fifteen action references across every lane and the flywheel", () => {
  const evidence = fixture();
  assert.equal(V5_CANARY_SPEC.buyWei, 1_000_000_000_000_000n);
  assert.equal(V5_CANARY_SPEC.flywheelEthIn, 3_000_000_000_000n);
  assert.equal(V5_CANARY_SPEC.flywheelMinHookrOut, 3n * 10n ** 18n);
  assert.ok(
    evidence.flywheel.burn.burnedEvent.hookrBurned >=
      V5_CANARY_SPEC.flywheelMinHookrOut,
    "the observed output fixture must clear the reviewed 3 HOOKR floor",
  );
  assert.deepEqual(validateV5CanaryEvidence(evidence), {
    instantToken: addresses.instantToken,
    instantPoolId: poolIdForKey(poolKey(addresses.instantToken)),
    auctionToken: addresses.auctionToken,
    auctionPoolId: poolIdForKey(poolKey(addresses.auctionToken)),
    auction: addresses.auction,
    hookrPairToken: addresses.hookrPairToken,
    hookrPoolId: poolIdForKey(
      poolKey(addresses.hookrPairToken, addresses.hookrToken),
    ),
  });
});

test("v5 canary evidence authenticates an explicit zero-proceeds not-applicable claim", async (t) => {
  await t.test(
    "accepts the exact migration receipt, zero ledger, and explicit proof",
    () => {
      assert.doesNotThrow(() =>
        validateV5CanaryEvidence(zeroProceedsFixture()),
      );
    },
  );

  await t.test("rejects a separate receipt masquerading as the proof", () => {
    const evidence = zeroProceedsFixture();
    const record = evidence.receiptOrder.find(
      (candidate) => candidate.label === "canary:auction-proceeds",
    );
    record.hash = hash(0xdead);
    record.transactionIndex = 1;
    evidence.receiptOrder.sort((left, right) =>
      left.blockNumber === right.blockNumber
        ? left.transactionIndex - right.transactionIndex
        : left.blockNumber < right.blockNumber
          ? -1
          : 1,
    );
    assert.throws(
      () => validateV5CanaryEvidence(evidence),
      /does not alias the exact migration receipt/,
    );
  });

  await t.test("rejects any claimed proceeds event", () => {
    const evidence = zeroProceedsFixture();
    evidence.auction.migrate.proceedsEvent = {
      transactionHash:
        evidence.auction.proceedsClaim.notApplicable.proofTransactionHash,
      logIndex: 12n,
      token: addresses.auctionToken,
      creator: addresses.canarySender,
      amountWei: 1n,
    };
    assert.throws(
      () => validateV5CanaryEvidence(evidence),
      /must not contain AuctionProceeds evidence/,
    );
  });

  await t.test("rejects any creator-fee claim event", () => {
    const evidence = zeroProceedsFixture();
    evidence.auction.proceedsClaim.claimEvent = {
      transactionHash:
        evidence.auction.proceedsClaim.notApplicable.proofTransactionHash,
      logIndex: 12n,
      token: addresses.auctionToken,
      payTo: addresses.canarySender,
      amountWei: 1n,
    };
    assert.throws(
      () => validateV5CanaryEvidence(evidence),
      /must not contain CreatorFeesClaimed evidence/,
    );
  });

  await t.test("rejects non-conservation or a nonzero creator ledger", () => {
    const wrongSweep = zeroProceedsFixture();
    wrongSweep.auction.migrate.currencySweptEvent.currencyAmount += 1n;
    assert.throws(
      () => validateV5CanaryEvidence(wrongSweep),
      /zero-proceeds migration liquidity does not equal/,
    );

    const nonzeroLedger = zeroProceedsFixture();
    nonzeroLedger.postconditions.auctionCreatorProceedsWei = 1n;
    assert.throws(
      () => validateV5CanaryEvidence(nonzeroLedger),
      /creator proceeds ledger was not cleared/,
    );
  });

  await t.test(
    "rejects altered proof semantics or transaction identity",
    () => {
      const wrongProof = zeroProceedsFixture();
      wrongProof.auction.proceedsClaim.notApplicable.proofTransactionHash =
        hash(0xbeef);
      assert.throws(
        () => validateV5CanaryEvidence(wrongProof),
        /proof transaction hash is not the migration receipt/,
      );

      const wrongMode = zeroProceedsFixture();
      wrongMode.auction.proceedsClaim.calldata.mode = "zero";
      assert.throws(
        () => validateV5CanaryEvidence(wrongMode),
        /zero-proceeds claim mode is wrong/,
      );

      const wrongTransaction = zeroProceedsFixture();
      wrongTransaction.auction.proceedsClaim.transaction.nonce += 1n;
      assert.throws(
        () => validateV5CanaryEvidence(wrongTransaction),
        /proof transaction nonce differs from migration/,
      );
    },
  );
});

test("v5 canary evidence rejects timing, Phase-A nonce, and auction-window mutations", () => {
  const wrongShorten = fixture();
  wrongShorten.timing.shorten.calldata.durationBlocks = 2_500n;
  assert.throws(
    () => validateV5CanaryEvidence(wrongShorten),
    /timing shorten duration is wrong/,
  );

  const wrongRestoreEvent = fixture();
  wrongRestoreEvent.timing.restore.event.durationBlocks = 20_000n;
  assert.throws(
    () => validateV5CanaryEvidence(wrongRestoreEvent),
    /timing restore AuctionTimingSet fields are wrong/,
  );

  const nonceGap = fixture();
  nonceGap.auction.bid.transaction.nonce += 1n;
  assert.throws(
    () => validateV5CanaryEvidence(nonceGap),
    /phase A signer nonces are not consecutive/,
  );

  const wrongEnd = fixture();
  wrongEnd.auction.launch.startedEvent.endBlock += 1n;
  assert.throws(
    () => validateV5CanaryEvidence(wrongEnd),
    /mined launch block plus 20000/,
  );

  const finalTiming = fixture();
  finalTiming.postconditions.auctionTiming.durationBlocks = 20_000n;
  assert.throws(
    () => validateV5CanaryEvidence(finalTiming),
    /final launchpad auction timing/,
  );
});

test("v5 canary evidence accepts permissionless Phase-B keepers but owner-binds the buyback", () => {
  const evidence = fixture();
  const permissionlessSteps = [
    evidence.auction.migrate,
    evidence.auction.exit,
    evidence.auction.claimTokens,
    evidence.auction.proceedsClaim,
    evidence.flywheel.collect,
  ];
  permissionlessSteps.forEach((step, index) => {
    step.transaction.from = address(0x9000 + index);
    step.transaction.to = address(0xa000 + index);
    step.transaction.value = 1_000n + BigInt(index);
    step.transaction.nonce = 10_000n + BigInt(index * 17);
  });
  evidence.flywheel.burn.transaction.nonce = 44_444n;
  assert.doesNotThrow(() => validateV5CanaryEvidence(evidence));

  const shortCollect = fixture();
  shortCollect.flywheel.collect.event.amountWei =
    V5_CANARY_SPEC.flywheelEthIn - 1n;
  shortCollect.flywheel.collect.claimedEvent.amountWei =
    V5_CANARY_SPEC.flywheelEthIn - 1n;
  assert.throws(
    () => validateV5CanaryEvidence(shortCollect),
    /did not pull at least the receipt-proven Phase-A accrual/,
  );

  evidence.flywheel.burn.transaction.from = address(0xbeef);
  assert.throws(
    () => validateV5CanaryEvidence(evidence),
    /flywheel burn sender is not the canary owner/,
  );

  const wrongBurnTarget = fixture();
  wrongBurnTarget.flywheel.burn.transaction.to = address(0xbeef);
  assert.throws(
    () => validateV5CanaryEvidence(wrongBurnTarget),
    /flywheel burn target is wrong/,
  );

  const fundedBurn = fixture();
  fundedBurn.flywheel.burn.transaction.value = 1n;
  assert.throws(
    () => validateV5CanaryEvidence(fundedBurn),
    /flywheel burn sends native value/,
  );
});

test("v5 canary evidence pins bid payload and BidSubmitted fields", () => {
  const wrongPrice = fixture();
  wrongPrice.auction.bid.calldata.maxPriceQ96 += 1n;
  assert.throws(
    () => validateV5CanaryEvidence(wrongPrice),
    /auction bid max price is wrong/,
  );

  const hookData = fixture();
  hookData.auction.bid.calldata.hookData = "0x00";
  assert.throws(
    () => validateV5CanaryEvidence(hookData),
    /auction bid hook data is not empty/,
  );

  const wrongEventAmount = fixture();
  wrongEventAmount.auction.bid.event.amount -= 1n;
  assert.throws(
    () => validateV5CanaryEvidence(wrongEventAmount),
    /BidSubmitted amount is wrong/,
  );

  const wrongEventPrice = fixture();
  wrongEventPrice.auction.bid.event.priceQ96 -= 1n;
  assert.throws(
    () => validateV5CanaryEvidence(wrongEventPrice),
    /BidSubmitted price is wrong/,
  );
});

test("v5 canary evidence pins exposed CCA configuration to the launch receipt", () => {
  const wrongStart = fixture();
  wrongStart.postconditions.auctionConfig.startBlock += 1n;
  assert.throws(() => validateV5CanaryEvidence(wrongStart), /CCA start block/);

  const wrongRecipient = fixture();
  wrongRecipient.postconditions.auctionConfig.fundsRecipient = address(0x9999);
  assert.throws(
    () => validateV5CanaryEvidence(wrongRecipient),
    /CCA funds recipient/,
  );

  const wrongEnd = fixture();
  wrongEnd.postconditions.auctionConfig.endBlock += 1n;
  assert.throws(() => validateV5CanaryEvidence(wrongEnd), /CCA end block/);

  const wrongSupply = fixture();
  wrongSupply.postconditions.auctionConfig.totalSupply -= 1n;
  assert.throws(
    () => validateV5CanaryEvidence(wrongSupply),
    /CCA total supply/,
  );
});

test("v5 canary evidence pins router timestamps, guards, SwapExecuted, and allowance cleanup", () => {
  const staleDeadline = fixture();
  staleDeadline.instant.buy.calldata.deadline =
    staleDeadline.instant.buy.transaction.blockTimestamp - 1n;
  assert.throws(
    () => validateV5CanaryEvidence(staleDeadline),
    /600-second bound/,
  );

  const outsideGuard = fixture();
  outsideGuard.hookr.buy.transaction.contractBlockNumber =
    outsideGuard.postconditions.hookrLaunch.launchBlock +
    BigInt(V5_CANARY_SPEC.hookrHookParams.guardBlocks);
  assert.throws(
    () => validateV5CanaryEvidence(outsideGuard),
    /hookr guard window/,
  );

  const wrongSwap = fixture();
  wrongSwap.instant.buy.event.amountOut -= 1n;
  assert.throws(
    () => validateV5CanaryEvidence(wrongSwap),
    /does not match the delivered transfer/,
  );

  const wrongTransferSource = fixture();
  wrongTransferSource.hookr.buy.transferEvent.from = addresses.router;
  assert.throws(
    () => validateV5CanaryEvidence(wrongTransferSource),
    /did not come from PoolManager/,
  );

  const wrongInstantTransferSource = fixture();
  wrongInstantTransferSource.instant.buy.transferEvent.from = addresses.router;
  assert.throws(
    () => validateV5CanaryEvidence(wrongInstantTransferSource),
    /did not come from PoolManager/,
  );

  const allowance = fixture();
  allowance.postconditions.hookrAllowance = 1n;
  assert.throws(
    () => validateV5CanaryEvidence(allowance),
    /allowance.*not consumed to zero/,
  );
});

test("v5 canary evidence binds effective hook configs, guarded swap fees, and flywheel accrual", () => {
  const wrongGuard = fixture();
  wrongGuard.postconditions.hookConfigs.instant.guardEndBlock += 1n;
  assert.throws(
    () => validateV5CanaryEvidence(wrongGuard),
    /instant poolConfig guard end is wrong/,
  );

  const wrongMaxBuy = fixture();
  wrongMaxBuy.postconditions.hookConfigs.auction.maxBuyWei += 1n;
  assert.throws(
    () => validateV5CanaryEvidence(wrongMaxBuy),
    /maxBuyWei is not derived/,
  );

  const wrongFlywheelConfig = fixture();
  wrongFlywheelConfig.postconditions.hookConfigs.hookr.flywheelFeePips =
    V5_CANARY_SPEC.flywheelFeePips;
  assert.throws(
    () => validateV5CanaryEvidence(wrongFlywheelConfig),
    /hookr poolConfig flywheel fee is wrong/,
  );

  const zeroRoundedSurge = fixture();
  zeroRoundedSurge.instant.buy.poolManagerEvent.fee = 203_000n;
  assert.doesNotThrow(() => validateV5CanaryEvidence(zeroRoundedSurge));

  const belowGuardedFloor = fixture();
  belowGuardedFloor.instant.buy.poolManagerEvent.fee = 202_999n;
  assert.throws(
    () => validateV5CanaryEvidence(belowGuardedFloor),
    /below the guarded base plus snipe-tax floor/,
  );

  const aboveConfiguredCeiling = fixture();
  aboveConfiguredCeiling.instant.buy.poolManagerEvent.fee = 230_771n;
  assert.throws(
    () => validateV5CanaryEvidence(aboveConfiguredCeiling),
    /exceeds the configured maximum/,
  );

  const zeroLiquidity = fixture();
  zeroLiquidity.hookr.buy.poolManagerEvent.liquidity = 0n;
  assert.throws(
    () => validateV5CanaryEvidence(zeroLiquidity),
    /zero liquidity/,
  );

  const wrongAccrual = fixture();
  wrongAccrual.instant.buy.flywheelEvent.amountWei -= 1n;
  assert.throws(
    () => validateV5CanaryEvidence(wrongAccrual),
    /FlywheelFeeAccrued amount/,
  );

  const missingAccrual = fixture();
  missingAccrual.instant.buy.flywheelEvent = undefined;
  assert.throws(
    () => validateV5CanaryEvidence(missingAccrual),
    /no FlywheelFeeAccrued evidence/,
  );
});

test("v5 canary evidence rejects a wrong intent in any lane", () => {
  const wrongInstant = fixture();
  wrongInstant.instant.launch.calldata.intentId = `0x${"12".repeat(32)}`;
  assert.throws(
    () => validateV5CanaryEvidence(wrongInstant),
    /instant launch intent is wrong/,
  );

  const wrongAuction = fixture();
  wrongAuction.auction.launch.calldata.intentId =
    V5_CANARY_SPEC.instantIntentId;
  assert.throws(
    () => validateV5CanaryEvidence(wrongAuction),
    /auction launch intent is wrong/,
  );

  const wrongHookr = fixture();
  wrongHookr.hookr.launch.calldata.intentId = V5_CANARY_SPEC.instantIntentId;
  assert.throws(
    () => validateV5CanaryEvidence(wrongHookr),
    /hookr launch intent is wrong/,
  );
});

test("v5 canary evidence rejects a wrong quote in any launch", () => {
  const hookrOnEth = fixture();
  hookrOnEth.instant.launch.calldata.quote = V5_CANARY_SPEC.quote.hookr;
  assert.throws(
    () => validateV5CanaryEvidence(hookrOnEth),
    /instant launch quote is not ETH/,
  );

  const hookrOnAuction = fixture();
  hookrOnAuction.auction.launch.calldata.quote = V5_CANARY_SPEC.quote.hookr;
  assert.throws(
    () => validateV5CanaryEvidence(hookrOnAuction),
    /auction launch quote is not ETH/,
  );

  const ethOnHookr = fixture();
  ethOnHookr.hookr.launch.calldata.quote = V5_CANARY_SPEC.quote.eth;
  assert.throws(
    () => validateV5CanaryEvidence(ethOnHookr),
    /hookr launch quote is not HOOKR/,
  );
});

test("v5 canary evidence rejects a HOOKR stack carrying a native-cut block", () => {
  const withBurn = fixture();
  withBurn.hookr.launch.calldata.args.custom.burnBps = 100;
  assert.throws(
    () => validateV5CanaryEvidence(withBurn),
    /hookr launch hook parameter burnBps is wrong/,
  );
});

test("v5 canary evidence rejects a misdirected or mis-sized HOOKR approve", () => {
  const wrongSpender = fixture();
  wrongSpender.hookr.approve.calldata.spender = address(0x9999);
  assert.throws(
    () => validateV5CanaryEvidence(wrongSpender),
    /hookr approve spender is not the release router/,
  );

  const wrongAmount = fixture();
  wrongAmount.hookr.approve.calldata.amount =
    V5_CANARY_SPEC.hookrBuyAmount - 1n;
  assert.throws(
    () => validateV5CanaryEvidence(wrongAmount),
    /hookr approve amount is wrong/,
  );
});

test("v5 canary evidence rejects a HOOKR buy on the wrong quote or with native value", () => {
  const ethQuoteKey = fixture();
  ethQuoteKey.hookr.buy.calldata.key.currency0 = ZERO_ADDRESS;
  assert.throws(
    () => validateV5CanaryEvidence(ethQuoteKey),
    /hookr buy key currency0 is not the HOOKR token/,
  );

  const nativeValue = fixture();
  nativeValue.hookr.buy.transaction.value = 1n;
  assert.throws(
    () => validateV5CanaryEvidence(nativeValue),
    /hookr buy must not send native value/,
  );
});

test("v5 canary evidence rejects a flywheel burn without a real burn", () => {
  const belowMinimum = fixture();
  belowMinimum.flywheel.burn.burnedEvent.hookrBurned =
    V5_CANARY_SPEC.flywheelMinHookrOut - 1n;
  assert.throws(
    () => validateV5CanaryEvidence(belowMinimum),
    /output missed the reviewed minimum/,
  );

  const missingTransfer = fixture();
  missingTransfer.flywheel.burn.deadTransferEvent = undefined;
  assert.throws(
    () => validateV5CanaryEvidence(missingTransfer),
    /no dead-address HOOKR Transfer evidence/,
  );

  const shortTransfer = fixture();
  shortTransfer.flywheel.burn.deadTransferEvent.value -= 1n;
  assert.throws(
    () => validateV5CanaryEvidence(shortTransfer),
    /flywheel dead transfer does not equal the burned amount/,
  );

  const zeroEth = fixture();
  zeroEth.flywheel.burn.calldata.ethIn = 0n;
  zeroEth.flywheel.burn.burnedEvent.ethIn = 0n;
  assert.throws(
    () => validateV5CanaryEvidence(zeroEth),
    /flywheel burn calldata spends the wrong ETH amount/,
  );

  const missingBurnedEvent = fixture();
  missingBurnedEvent.flywheel.burn.burnedEvent = undefined;
  assert.throws(
    () => validateV5CanaryEvidence(missingBurnedEvent),
    /no BuybackBurned evidence/,
  );
});

test("v5 canary evidence requires the exact reviewed 3 HOOKR calldata bound", () => {
  for (const wrongMinimum of [
    V5_CANARY_SPEC.flywheelMinHookrOut - 1n,
    V5_CANARY_SPEC.flywheelMinHookrOut + 1n,
  ]) {
    const evidence = fixture();
    evidence.flywheel.burn.calldata.minHookrOut = wrongMinimum;
    assert.throws(
      () => validateV5CanaryEvidence(evidence),
      /flywheel burn does not carry the reviewed execution bound/,
    );
  }
});

test("v5 canary evidence rejects a pair token that was not mined above HOOKR", () => {
  const below = fixture();
  const belowToken = address(0x7f00); // numerically below the HOOKR quote token
  below.hookr.launch.tokenEvent.token = belowToken;
  below.hookr.launch.instantEvent.token = belowToken;
  assert.throws(
    () => validateV5CanaryEvidence(below),
    /hookr pair token was not mined above the HOOKR quote/,
  );
});

test("v5 canary evidence rejects a migration that paid no proceeds", () => {
  const zeroed = fixture();
  zeroed.auction.migrate.proceedsEvent.amountWei = 0n;
  assert.throws(
    () => validateV5CanaryEvidence(zeroed),
    /credited no creator proceeds/,
  );

  const missing = fixture();
  missing.auction.migrate.proceedsEvent = undefined;
  assert.throws(
    () => validateV5CanaryEvidence(missing),
    /no AuctionProceeds evidence/,
  );

  const shortClaim = fixture();
  shortClaim.auction.proceedsClaim.claimEvent.amountWei -= 1n;
  assert.throws(
    () => validateV5CanaryEvidence(shortClaim),
    /does not equal the migration's credited proceeds/,
  );

  const uncleared = fixture();
  uncleared.postconditions.auctionCreatorProceedsWei = 1n;
  assert.throws(
    () => validateV5CanaryEvidence(uncleared),
    /proceeds ledger was not cleared/,
  );
});

test("v5 canary evidence binds BidExited and TokensClaimed to the settled bid", () => {
  const batch = fixture();
  batch.auction.claimTokens.calldata.call = "claimTokensBatch";
  batch.auction.claimTokens.calldata.requestedBidIds = [77n, 77n, 88n, 88n];
  batch.auction.claimTokens.events.push({
    transactionHash: batch.auction.claimTokens.event.transactionHash,
    logIndex: 11n,
    bidId: 88n,
    owner: addresses.canarySender,
    tokensFilled: 123n,
  });
  batch.auction.claimTokens.transferEvent.value += 123n;
  batch.auction.claimTokens.transferLogIndexes = [12n];
  assert.doesNotThrow(() => validateV5CanaryEvidence(batch));

  const shortBatch = fixture();
  shortBatch.auction.claimTokens.calldata.call = "claimTokensBatch";
  shortBatch.auction.claimTokens.calldata.requestedBidIds = [77n, 77n];
  shortBatch.auction.claimTokens.transferEvent.value -= 1n;
  assert.throws(
    () => validateV5CanaryEvidence(shortBatch),
    /aggregate transfer does not equal the sum/,
  );

  const duplicateEmitted = fixture();
  duplicateEmitted.auction.claimTokens.calldata.call = "claimTokensBatch";
  duplicateEmitted.auction.claimTokens.calldata.requestedBidIds = [77n, 77n];
  duplicateEmitted.auction.claimTokens.events.push({
    ...duplicateEmitted.auction.claimTokens.events[0],
    logIndex: 11n,
    tokensFilled: 0n,
  });
  assert.throws(
    () => validateV5CanaryEvidence(duplicateEmitted),
    /emitted duplicate TokensClaimed bid ids/,
  );

  const unrequestedEmitted = fixture();
  unrequestedEmitted.auction.claimTokens.calldata.call = "claimTokensBatch";
  unrequestedEmitted.auction.claimTokens.calldata.requestedBidIds = [77n, 77n];
  unrequestedEmitted.auction.claimTokens.events.push({
    transactionHash:
      unrequestedEmitted.auction.claimTokens.event.transactionHash,
    logIndex: 11n,
    bidId: 88n,
    owner: addresses.canarySender,
    tokensFilled: 0n,
  });
  assert.throws(
    () => validateV5CanaryEvidence(unrequestedEmitted),
    /emitted a bid absent from calldata/,
  );

  const nested = fixture();
  nested.auction.claimTokens.calldata.call = "nested";
  nested.auction.claimTokens.calldata.requestedBidIds = undefined;
  nested.auction.claimTokens.events.push({
    transactionHash: nested.auction.claimTokens.event.transactionHash,
    logIndex: 11n,
    bidId: 88n,
    owner: addresses.canarySender,
    tokensFilled: 123n,
  });
  nested.auction.claimTokens.transferEvent.value += 123n;
  nested.auction.claimTokens.transferCount = 2;
  nested.auction.claimTokens.transferLogIndexes = [12n, 13n];
  assert.doesNotThrow(() => validateV5CanaryEvidence(nested));

  const unknownClaim = fixture();
  unknownClaim.auction.claimTokens.calldata.call = "claimAll";
  assert.throws(
    () => validateV5CanaryEvidence(unknownClaim),
    /does not identify a reviewed claim entrypoint/,
  );

  const wrongExit = fixture();
  wrongExit.auction.exit.event.bidId += 1n;
  assert.throws(
    () => validateV5CanaryEvidence(wrongExit),
    /BidExited id is not the canary bid/,
  );

  const wrongClaimOwner = fixture();
  wrongClaimOwner.auction.claimTokens.event.owner = address(0x9999);
  wrongClaimOwner.auction.claimTokens.events[0].owner = address(0x9999);
  assert.throws(
    () => validateV5CanaryEvidence(wrongClaimOwner),
    /TokensClaimed #0 owner/,
  );

  const wrongClaimAmount = fixture();
  wrongClaimAmount.auction.claimTokens.event.tokensFilled -= 1n;
  wrongClaimAmount.auction.claimTokens.events[0].tokensFilled -= 1n;
  assert.throws(
    () => validateV5CanaryEvidence(wrongClaimAmount),
    /does not match BidExited/,
  );

  const wrongClaimSource = fixture();
  wrongClaimSource.auction.claimTokens.transferEvent.from = addresses.launchpad;
  assert.throws(
    () => validateV5CanaryEvidence(wrongClaimSource),
    /did not come from the CCA/,
  );

  const wrongBurnSource = fixture();
  wrongBurnSource.flywheel.burn.deadTransferEvent.from = addresses.poolManager;
  assert.throws(
    () => validateV5CanaryEvidence(wrongBurnSource),
    /did not come from the burner/,
  );
});

test("v5 canary evidence target-binds Phase A and post-state but not permissionless Phase B helpers", () => {
  const wrongBid = fixture();
  wrongBid.auction.bid.transaction.to = address(0x9999);
  assert.throws(
    () => validateV5CanaryEvidence(wrongBid),
    /auction bid target is wrong/,
  );

  const wrongExit = fixture();
  wrongExit.auction.exit.transaction.to = address(0x9999);
  wrongExit.auction.exit.transaction.value = 999n;
  assert.doesNotThrow(() => validateV5CanaryEvidence(wrongExit));

  const wrongRecord = fixture();
  wrongRecord.postconditions.auctionLaunch.auction = address(0x9999);
  assert.throws(
    () => validateV5CanaryEvidence(wrongRecord),
    /record names a different auction/,
  );
});

test("v5 canary evidence accepts Phase-B interleaving and enforces only protocol-causal edges", () => {
  const step = (evidence, label) =>
    ({
      "canary:auction-migrate": evidence.auction.migrate,
      "canary:auction-exit": evidence.auction.exit,
      "canary:auction-claim": evidence.auction.claimTokens,
      "canary:auction-proceeds": evidence.auction.proceedsClaim,
      "canary:flywheel-collect": evidence.flywheel.collect,
      "canary:flywheel-burn": evidence.flywheel.burn,
    })[label];
  const move = (evidence, label, blockNumber, transactionIndex = 0) => {
    const receipt = evidence.receiptOrder.find(
      (record) => record.label === label,
    );
    receipt.blockNumber = blockNumber;
    receipt.transactionIndex = transactionIndex;
    step(evidence, label).transaction.blockNumber = blockNumber;
  };
  const sort = (evidence) =>
    evidence.receiptOrder.sort((left, right) =>
      left.blockNumber === right.blockNumber
        ? left.transactionIndex - right.transactionIndex
        : left.blockNumber < right.blockNumber
          ? -1
          : 1,
    );

  const interleaved = fixture();
  // collect/burn may occur after the receipt-local instant accrual but before later Phase-A lanes.
  move(interleaved, "canary:flywheel-collect", 115n, 1);
  move(interleaved, "canary:flywheel-burn", 115n, 2);
  sort(interleaved);
  assert.doesNotThrow(() => validateV5CanaryEvidence(interleaved));

  const collectBeforeAccrual = fixture();
  move(collectBeforeAccrual, "canary:flywheel-collect", 111n, 1);
  sort(collectBeforeAccrual);
  assert.throws(
    () => validateV5CanaryEvidence(collectBeforeAccrual),
    /flywheel collect was not mined after the canary accrual/,
  );

  const burnBeforeCollect = fixture();
  move(burnBeforeCollect, "canary:flywheel-burn", 20_203n, 1);
  sort(burnBeforeCollect);
  assert.throws(
    () => validateV5CanaryEvidence(burnBeforeCollect),
    /flywheel collect was not mined before buyback/,
  );

  const claimBeforeExit = fixture();
  move(claimBeforeExit, "canary:auction-claim", 20_199n);
  sort(claimBeforeExit);
  assert.throws(
    () => validateV5CanaryEvidence(claimBeforeExit),
    /auction exit was not mined before token claim/,
  );

  const proceedsBeforeMigrate = fixture();
  move(proceedsBeforeMigrate, "canary:auction-proceeds", 20_199n);
  sort(proceedsBeforeMigrate);
  assert.throws(
    () => validateV5CanaryEvidence(proceedsBeforeMigrate),
    /auction migration was not mined before proceeds claim/,
  );

  const earlyMigrate = fixture();
  const endBlock = earlyMigrate.auction.launch.startedEvent.endBlock;
  move(earlyMigrate, "canary:auction-migrate", endBlock);
  sort(earlyMigrate);
  assert.throws(
    () => validateV5CanaryEvidence(earlyMigrate),
    /not mined after the auction window closed/,
  );
});

test("v5 canary evidence accepts permissionless Phase-B receipt aliases and uses event-log causality", () => {
  const action = (evidence, label) =>
    ({
      "canary:auction-migrate": evidence.auction.migrate,
      "canary:auction-exit": evidence.auction.exit,
      "canary:auction-claim": evidence.auction.claimTokens,
      "canary:auction-proceeds": evidence.auction.proceedsClaim,
      "canary:flywheel-collect": evidence.flywheel.collect,
      "canary:flywheel-burn": evidence.flywheel.burn,
    })[label];
  const rebindEventReferences = (value, transactionHash) => {
    if (!value || typeof value !== "object") return;
    if ("logIndex" in value && "transactionHash" in value)
      value.transactionHash = transactionHash;
    for (const child of Object.values(value))
      rebindEventReferences(child, transactionHash);
  };
  const aliasTo = (evidence, label, canonicalLabel) => {
    const record = evidence.receiptOrder.find(
      (candidate) => candidate.label === label,
    );
    const canonical = evidence.receiptOrder.find(
      (candidate) => candidate.label === canonicalLabel,
    );
    record.hash = canonical.hash;
    record.blockNumber = canonical.blockNumber;
    record.transactionIndex = canonical.transactionIndex;
    action(evidence, label).transaction = {
      ...action(evidence, canonicalLabel).transaction,
    };
    rebindEventReferences(action(evidence, label), canonical.hash);
  };
  const sort = (evidence) =>
    evidence.receiptOrder.sort((left, right) =>
      left.blockNumber === right.blockNumber
        ? left.transactionIndex - right.transactionIndex
        : left.blockNumber < right.blockNumber
          ? -1
          : 1,
    );

  const aliased = fixture();
  for (const label of V5_CANARY_SPEC.phaseBReceiptLabels.slice(1, -1)) {
    aliasTo(aliased, label, "canary:auction-migrate");
  }
  aliased.auction.claimTokens.calldata.call = "nested";
  aliased.auction.claimTokens.calldata.requestedBidIds = undefined;
  aliased.auction.exit.event.logIndex = 14n;
  aliased.auction.claimTokens.event.logIndex = 15n;
  aliased.auction.claimTokens.events[0].logIndex = 15n;
  aliased.auction.claimTokens.transferLogIndexes = [16n];
  aliased.auction.proceedsClaim.claimEvent.logIndex = 17n;
  aliased.flywheel.collect.claimedEvent.logIndex = 18n;
  aliased.flywheel.collect.event.logIndex = 19n;
  sort(aliased);
  assert.doesNotThrow(() => validateV5CanaryEvidence(aliased));

  const claimBeforeExit = structuredClone(aliased);
  claimBeforeExit.auction.claimTokens.event.logIndex = 13n;
  claimBeforeExit.auction.claimTokens.events[0].logIndex = 13n;
  assert.throws(
    () => validateV5CanaryEvidence(claimBeforeExit),
    /auction exit was not mined before token claim/,
  );

  const proceedsBeforeMigration = structuredClone(aliased);
  proceedsBeforeMigration.auction.proceedsClaim.claimEvent.logIndex = 12n;
  assert.throws(
    () => validateV5CanaryEvidence(proceedsBeforeMigration),
    /auction migration was not mined before proceeds claim/,
  );

  const mismatchedAliasCoordinates = fixture();
  const exitRecord = mismatchedAliasCoordinates.receiptOrder.find(
    (record) => record.label === "canary:auction-exit",
  );
  exitRecord.hash = mismatchedAliasCoordinates.receiptOrder.find(
    (record) => record.label === "canary:auction-claim",
  ).hash;
  assert.throws(
    () => validateV5CanaryEvidence(mismatchedAliasCoordinates),
    /aliases.*different coordinates/,
  );

  const phaseACollision = fixture();
  phaseACollision.receiptOrder.find(
    (record) => record.label === "canary:auction-exit",
  ).hash = phaseACollision.receiptOrder.find(
    (record) => record.label === "canary:auction-bid",
  ).hash;
  assert.throws(
    () => validateV5CanaryEvidence(phaseACollision),
    /collides outside permissionless Phase B/,
  );

  const buybackCollision = fixture();
  buybackCollision.receiptOrder.find(
    (record) => record.label === "canary:flywheel-burn",
  ).hash = buybackCollision.receiptOrder.find(
    (record) => record.label === "canary:flywheel-collect",
  ).hash;
  assert.throws(
    () => validateV5CanaryEvidence(buybackCollision),
    /collides outside permissionless Phase B/,
  );

  const foreignEvent = fixture();
  foreignEvent.auction.exit.event.transactionHash = hash(0xfeedn);
  assert.throws(
    () => validateV5CanaryEvidence(foreignEvent),
    /BidExited transaction hash does not match/,
  );
});

test("v5 canary evidence binds the CCA outcome, migration Initialize, and reserve conservation", () => {
  const belowFloor = fixture();
  belowFloor.postconditions.auctionOutcome.initialPriceX96 = 1n;
  assert.throws(
    () => validateV5CanaryEvidence(belowFloor),
    /below the aligned launch floor/,
  );

  const underRaised = fixture();
  underRaised.postconditions.auctionOutcome.currencyRaisedGross =
    V5_CANARY_SPEC.raiseFloorWei - 1n;
  assert.throws(
    () => validateV5CanaryEvidence(underRaised),
    /gross raise did not meet the graduation raise floor/,
  );

  // Protocol fees are queried when lbpInitializationParams() is read. A controller change after
  // migration may lower this later net quote; it must not rewrite the receipt's historical sweep
  // or the gross amount that determined graduation.
  const laterFeeDrift = fixture();
  laterFeeDrift.postconditions.auctionOutcome.currencyRaisedNetAtRead =
    V5_CANARY_SPEC.raiseFloorWei - 1n;
  assert.doesNotThrow(() => validateV5CanaryEvidence(laterFeeDrift));

  const impossibleNet = fixture();
  impossibleNet.postconditions.auctionOutcome.currencyRaisedNetAtRead =
    impossibleNet.postconditions.auctionOutcome.currencyRaisedGross + 1n;
  assert.throws(
    () => validateV5CanaryEvidence(impossibleNet),
    /net-at-read raise exceeds its gross raise/,
  );

  const wrongSqrt = fixture();
  wrongSqrt.auction.migrate.migratedEvent.sqrtPriceX96 += 1n;
  assert.throws(
    () => validateV5CanaryEvidence(wrongSqrt),
    /does not derive from the CCA clearing outcome/,
  );

  const wrongInitialize = fixture();
  wrongInitialize.auction.migrate.initializeEvent.sqrtPriceX96 += 1n;
  assert.throws(
    () => validateV5CanaryEvidence(wrongInitialize),
    /Initialize sqrt price does not match Migrated/,
  );

  const missingInitialize = fixture();
  missingInitialize.auction.migrate.initializeEvent = undefined;
  assert.throws(
    () => validateV5CanaryEvidence(missingInitialize),
    /no PoolManager Initialize evidence/,
  );

  const reserveLeak = fixture();
  reserveLeak.auction.migrate.migratedEvent.tokenLiquidity -= 1n;
  assert.throws(
    () => validateV5CanaryEvidence(reserveLeak),
    /do not conserve the configured reserve/,
  );

  const mismatchedRaise = fixture();
  mismatchedRaise.auction.migrate.migratedEvent.ethLiquidity -= 1n;
  assert.throws(
    () => validateV5CanaryEvidence(mismatchedRaise),
    /do not conserve the receipt-local CCA sweep/,
  );

  const missingSweep = fixture();
  missingSweep.auction.migrate.currencySweptEvent = undefined;
  assert.throws(
    () => validateV5CanaryEvidence(missingSweep),
    /no receipt-local CurrencySwept evidence/,
  );

  const wrongSweepRecipient = fixture();
  wrongSweepRecipient.auction.migrate.currencySweptEvent.fundsRecipient =
    address(0x9999);
  assert.throws(
    () => validateV5CanaryEvidence(wrongSweepRecipient),
    /CurrencySwept funds recipient is not the launchpad/,
  );

  const wrongSweepAmount = fixture();
  wrongSweepAmount.auction.migrate.currencySweptEvent.currencyAmount -= 1n;
  assert.throws(
    () => validateV5CanaryEvidence(wrongSweepAmount),
    /do not conserve the receipt-local CCA sweep/,
  );
});
