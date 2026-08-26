import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import {
  encodeAbiParameters,
  encodeFunctionData,
  keccak256,
  parseAbi,
  toEventSelector,
} from "viem";

import {
  V5_PHASE_B_ACTIONS,
  assertV5PhaseBEvidence,
  buildV5PhaseBEvidence,
} from "./build-v5-phase-b-evidence.mjs";

const ZERO = "0x0000000000000000000000000000000000000000";
const token = "0x1111111111111111111111111111111111111111";
const otherToken = "0x1212121212121212121212121212121212121212";
const auction = "0x2222222222222222222222222222222222222222";
const launchpad = "0x3333333333333333333333333333333333333333";
const burner = "0x4444444444444444444444444444444444444444";
const owner = "0x5555555555555555555555555555555555555555";
const poolManager = "0x6666666666666666666666666666666666666666";
const hook = "0x7777777777777777777777777777777777777777";
const hookrToken = "0x9999999999999999999999999999999999999999";
const dead = "0x000000000000000000000000000000000000dead";
const sourceCommit = "ab".repeat(20);
const bidId = 19n;
const tokensFilled = 123_456n * 10n ** 18n;
const reviewedMinHookrOut = 3n * 10n ** 18n;
const hookrBurned = 3_494_135_610_596_751_569n;
const auctionProceedsWei = 2_000_000_000_000_000n;
const migratedEthLiquidity = 8_000_000_000_000_000n;
const currencySweptWei = migratedEthLiquidity + auctionProceedsWei;
const auctionReserveTokens = 200_000_000n * 10n ** 18n;
const tokensBurned = 7n;
const tokenLiquidity = auctionReserveTokens - tokensBurned;
const sqrtPriceX96 = 12_345_678_901_234n;
const dynamicFee = 0x800000;
const tickSpacing = 60;

const launchpadAbi = parseAbi([
  "function migrateAuction(address token)",
  "function claimAuctionProceeds(address token)",
]);
const auctionAbi = parseAbi([
  "function exitBid(uint256 bidId)",
  "function claimTokens(uint256 bidId)",
  "function claimTokensBatch(address owner,uint256[] bidIds)",
]);
const burnerAbi = parseAbi([
  "function collect()",
  "function buybackAndBurn(uint256 ethIn,uint256 minHookrOut) returns (uint256 burned)",
]);
const poolKeyComponents = [
  { name: "currency0", type: "address" },
  { name: "currency1", type: "address" },
  { name: "fee", type: "uint24" },
  { name: "tickSpacing", type: "int24" },
  { name: "hooks", type: "address" },
];
const poolId = keccak256(
  encodeAbiParameters(
    [{ type: "tuple", components: poolKeyComponents }],
    [[ZERO, token, dynamicFee, tickSpacing, hook]],
  ),
);

const word = (value) => `0x${BigInt(value).toString(16).padStart(64, "0")}`;
const qty = (value) => `0x${BigInt(value).toString(16)}`;
const addressTopic = (value) =>
  `0x${value.slice(2).toLowerCase().padStart(64, "0")}`;
const blockHash = (block) => word(BigInt(block) + 50_000n);
const transactionHash = (index) => word(BigInt(index) + 100_000n);
const data = (types, values) =>
  encodeAbiParameters(
    types.map((type) => ({ type })),
    values,
  );

const eventSpecs = {
  migrateAuction: [
    {
      address: auction,
      topics: [
        toEventSelector("CurrencySwept(address,uint256)"),
        addressTopic(launchpad),
      ],
      data: data(["uint256"], [currencySweptWei]),
    },
    {
      address: poolManager,
      topics: [
        toEventSelector(
          "Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)",
        ),
        poolId,
        addressTopic(ZERO),
        addressTopic(token),
      ],
      data: data(
        ["uint24", "int24", "address", "uint160", "int24"],
        [dynamicFee, tickSpacing, hook, sqrtPriceX96, 111],
      ),
    },
    {
      address: launchpad,
      topics: [
        toEventSelector("AuctionProceeds(address,address,uint256)"),
        addressTopic(token),
        addressTopic(owner),
      ],
      data: data(["uint256"], [auctionProceedsWei]),
    },
    {
      address: launchpad,
      topics: [
        toEventSelector(
          "Migrated(address,bytes32,uint160,uint256,uint256,uint256)",
        ),
        addressTopic(token),
        poolId,
      ],
      data: data(
        ["uint160", "uint256", "uint256", "uint256"],
        [sqrtPriceX96, migratedEthLiquidity, tokenLiquidity, tokensBurned],
      ),
    },
  ],
  exitBid: [
    {
      address: auction,
      topics: [
        toEventSelector("BidExited(uint256,address,uint256,uint256)"),
        word(bidId),
        addressTopic(owner),
      ],
      data: data(["uint256", "uint256"], [tokensFilled, 500_000_000_000_000n]),
    },
  ],
  claimTokens: [
    {
      address: auction,
      topics: [
        toEventSelector("TokensClaimed(uint256,address,uint256)"),
        word(bidId),
        addressTopic(owner),
      ],
      data: data(["uint256"], [tokensFilled]),
    },
    {
      address: token,
      topics: [
        toEventSelector("Transfer(address,address,uint256)"),
        addressTopic(auction),
        addressTopic(owner),
      ],
      data: data(["uint256"], [tokensFilled]),
    },
  ],
  claimAuctionProceeds: [
    {
      address: launchpad,
      topics: [
        toEventSelector("CreatorFeesClaimed(address,address,uint256)"),
        addressTopic(token),
        addressTopic(owner),
      ],
      data: data(["uint256"], [auctionProceedsWei]),
    },
  ],
  collect: [
    {
      address: "0x8888888888888888888888888888888888888888",
      topics: [word(999)],
      data: "0x1234",
    },
    {
      address: hook,
      topics: [
        toEventSelector("Claimed(address,uint256)"),
        addressTopic(burner),
      ],
      data: data(["uint256"], [3_000_000_000_000n]),
    },
    {
      address: burner,
      topics: [toEventSelector("FlywheelCollected(uint256)")],
      data: data(["uint256"], [3_000_000_000_000n]),
    },
  ],
  buybackAndBurn: [
    {
      address: hookrToken,
      topics: [
        toEventSelector("Transfer(address,address,uint256)"),
        addressTopic(burner),
        addressTopic(dead),
      ],
      data: data(["uint256"], [hookrBurned]),
    },
    {
      address: burner,
      topics: [
        toEventSelector("BuybackBurned(address,uint256,uint256)"),
        addressTopic(owner),
      ],
      data: data(["uint256", "uint256"], [3_000_000_000_000n, hookrBurned]),
    },
  ],
};

// Deliberately not global script order: independent keepers exit and collect before migration,
// and the owner burns before migration/proceeds. Only the three causal edges are ordered.
const actionSpec = {
  migrateAuction: {
    sender: "0xa100000000000000000000000000000000000001",
    nonce: 91,
    block: 102,
    transactionIndex: 4,
    target: launchpad,
    input: encodeFunctionData({
      abi: launchpadAbi,
      functionName: "migrateAuction",
      args: [token],
    }),
  },
  exitBid: {
    sender: "0xa200000000000000000000000000000000000002",
    nonce: 3,
    block: 100,
    transactionIndex: 7,
    target: auction,
    input: encodeFunctionData({
      abi: auctionAbi,
      functionName: "exitBid",
      args: [bidId],
    }),
  },
  claimTokens: {
    sender: "0xa300000000000000000000000000000000000003",
    nonce: 777,
    block: 103,
    transactionIndex: 0,
    target: auction,
    input: encodeFunctionData({
      abi: auctionAbi,
      functionName: "claimTokens",
      args: [bidId],
    }),
  },
  claimAuctionProceeds: {
    sender: "0xa400000000000000000000000000000000000004",
    nonce: 1,
    block: 105,
    transactionIndex: 2,
    target: launchpad,
    input: encodeFunctionData({
      abi: launchpadAbi,
      functionName: "claimAuctionProceeds",
      args: [token],
    }),
  },
  collect: {
    sender: "0xa500000000000000000000000000000000000005",
    nonce: 9_001,
    block: 101,
    transactionIndex: 8,
    target: burner,
    input: encodeFunctionData({
      abi: burnerAbi,
      functionName: "collect",
      args: [],
    }),
  },
  buybackAndBurn: {
    sender: owner,
    nonce: 42,
    block: 101,
    transactionIndex: 9,
    target: burner,
    input: encodeFunctionData({
      abi: burnerAbi,
      functionName: "buybackAndBurn",
      args: [3_000_000_000_000n, reviewedMinHookrOut],
    }),
  },
};

const writeRecord = (record) => {
  writeFileSync(
    record.transactionPath,
    `${JSON.stringify(record.transaction, null, 2)}\n`,
  );
  writeFileSync(
    record.receiptPath,
    `${JSON.stringify(record.receipt, null, 2)}\n`,
  );
};
const writeAll = (context) => {
  for (const name of V5_PHASE_B_ACTIONS) writeRecord(context.pairs[name]);
};
const relocatePair = (record, block, transactionIndex) => {
  const hash = blockHash(block);
  for (const object of [record.transaction, record.receipt]) {
    object.blockNumber = qty(block);
    object.blockHash = hash;
    object.transactionIndex = qty(transactionIndex);
  }
  for (const log of record.receipt.logs) {
    log.blockNumber = qty(block);
    log.blockHash = hash;
    log.transactionIndex = qty(transactionIndex);
    log.blockTimestamp = qty(1_800_000_000 + block);
  }
};

const fixture = () => {
  const directory = mkdtempSync(join(process.cwd(), ".tmp-v5-phase-b-"));
  const pairs = {};
  V5_PHASE_B_ACTIONS.forEach((name, actionIndex) => {
    const spec = actionSpec[name];
    const txHash = transactionHash(actionIndex);
    const canonicalBlockHash = blockHash(spec.block);
    const transaction = {
      hash: txHash,
      from: spec.sender,
      to: spec.target,
      nonce: qty(spec.nonce),
      value: "0x0",
      input: spec.input,
      chainId: qty(4663),
      blockHash: canonicalBlockHash,
      blockNumber: qty(spec.block),
      transactionIndex: qty(spec.transactionIndex),
      gas: "0x7a120",
    };
    const logs = eventSpecs[name].map((event, eventIndex) => ({
      ...event,
      topics: [...event.topics],
      blockHash: canonicalBlockHash,
      blockNumber: qty(spec.block),
      blockTimestamp: qty(1_800_000_000 + spec.block),
      transactionHash: txHash,
      transactionIndex: qty(spec.transactionIndex),
      logIndex: qty(actionIndex * 10 + eventIndex + 1),
      removed: false,
    }));
    const receipt = {
      transactionHash: txHash,
      status: "0x1",
      from: spec.sender,
      to: spec.target,
      blockHash: canonicalBlockHash,
      blockNumber: qty(spec.block),
      transactionIndex: qty(spec.transactionIndex),
      contractAddress: null,
      cumulativeGasUsed: "0x100000",
      gasUsed: "0x50000",
      effectiveGasPrice: "0x1",
      gasUsedForL1: "0x222",
      l1BlockNumber: qty(spec.block - 2),
      type: "0x2",
      logsBloom: `0x${"00".repeat(256)}`,
      logs,
    };
    pairs[name] = {
      transaction,
      transactionPath: join(directory, `${name}.transaction.json`),
      receipt,
      receiptPath: join(directory, `${name}.receipt.json`),
    };
  });
  const context = {
    pairs,
    sourceCommit,
    token,
    auction,
    bidId: bidId.toString(),
    launchpad,
    burner,
    owner,
    poolManager,
    poolId,
    hook,
    hookrToken,
    phaseAAccrual: {
      transactionHash: word(80_001),
      blockNumber: "99",
      transactionIndex: "9",
      logIndex: "88",
      poolId: word(70_001),
      amountWei: "3000000000000",
    },
  };
  writeAll(context);
  return { context, directory };
};

const withFixture = async (run) => {
  const built = fixture();
  try {
    await run(built.context, built.directory);
  } finally {
    rmSync(built.directory, { recursive: true, force: true });
  }
};

const aliasClaimToMigration = (context) => {
  const migration = context.pairs.migrateAuction;
  context.pairs.claimAuctionProceeds = {
    transaction: structuredClone(migration.transaction),
    transactionPath: migration.transactionPath,
    receipt: structuredClone(migration.receipt),
    receiptPath: migration.receiptPath,
  };
};

const makeZeroProceeds = (context, { alias = true } = {}) => {
  const migrationLogs = context.pairs.migrateAuction.receipt.logs;
  const proceedsIndex = migrationLogs.findIndex(
    (log) =>
      log.topics[0].toLowerCase() ===
      toEventSelector("AuctionProceeds(address,address,uint256)").toLowerCase(),
  );
  assert.notEqual(
    proceedsIndex,
    -1,
    "fixture must contain AuctionProceeds before zeroing it",
  );
  migrationLogs.splice(proceedsIndex, 1);
  migrationLogs[0].data = data(["uint256"], [migratedEthLiquidity]);
  if (alias) aliasClaimToMigration(context);
  writeAll(context);
};

test("builds six hash-bound canonical pairs without a shared sender, nonce lane, or global order", async () => {
  await withFixture((context) => {
    const evidence = buildV5PhaseBEvidence(context);
    assert.equal(evidence.kind, "hookr-v5-phase-b-evidence-v1");
    assert.equal(evidence.chainId, "4663");
    assert.equal(evidence.identities.poolId, poolId);
    assert.equal(
      evidence.actions.collect.events.flywheelCollected.amountWei,
      "3000000000000",
    );
    assert.equal(
      evidence.actions.buybackAndBurn.events.buybackBurned.ethSpentWei,
      "3000000000000",
    );
    assert.equal(
      evidence.actions.buybackAndBurn.events.buybackBurned.hookrBurned,
      hookrBurned.toString(),
    );
    assert.equal(
      evidence.reviewedSemantics.buybackMinHookrOut,
      reviewedMinHookrOut.toString(),
    );
    assert.ok(
      BigInt(
        evidence.actions.buybackAndBurn.events.buybackBurned.hookrBurned,
      ) >= reviewedMinHookrOut,
      "the observed output fixture must clear the reviewed 3 HOOKR floor",
    );
    assert.equal(
      evidence.actions.collect.receipt.logs.length,
      3,
      "the complete ordered log stream is retained",
    );
    assert.deepEqual(
      V5_PHASE_B_ACTIONS.slice(0, 5).map(
        (name) => evidence.actions[name].transaction.from,
      ),
      V5_PHASE_B_ACTIONS.slice(0, 5).map((name) =>
        actionSpec[name].sender.toLowerCase(),
      ),
    );
    assert.deepEqual(
      V5_PHASE_B_ACTIONS.map(
        (name) => evidence.actions[name].transaction.nonce,
      ),
      ["91", "3", "777", "1", "9001", "42"],
    );
    for (const name of V5_PHASE_B_ACTIONS) {
      const raw = evidence.actions[name].raw;
      assert.match(raw.transactionPath, /^\.tmp-v5-phase-b-/);
      assert.equal(raw.transactionSha256.length, 64);
      assert.equal(raw.receiptSha256.length, 64);
    }
    assert.deepEqual(assertV5PhaseBEvidence(evidence, context), evidence);
  });
});

test("authenticates zero creator proceeds as an explicit not-applicable action without fabricating a claim", async (t) => {
  await t.test(
    "accepts only the exact migration pair as the zero-proceeds proof",
    () =>
      withFixture((context) => {
        makeZeroProceeds(context);
        const evidence = buildV5PhaseBEvidence(context);
        assert.equal(
          evidence.actions.migrateAuction.events.auctionProceeds,
          null,
        );
        assert.equal(
          evidence.actions.claimAuctionProceeds.events.call,
          "not-applicable-zero-proceeds",
        );
        assert.equal(
          evidence.actions.claimAuctionProceeds.events.mode,
          "not-applicable-zero-proceeds",
        );
        assert.equal(
          evidence.actions.claimAuctionProceeds.events.executionMode,
          "not-applicable",
        );
        assert.equal(
          evidence.actions.claimAuctionProceeds.events.creatorFeesClaimed,
          null,
        );
        assert.deepEqual(
          evidence.actions.claimAuctionProceeds.events.notApplicable,
          {
            executionMode: "not-applicable",
            mode: "not-applicable-zero-proceeds",
            token,
            amountWei: "0",
            proofTransactionHash:
              evidence.actions.migrateAuction.transaction.hash,
          },
        );
        assert.deepEqual(
          evidence.actions.claimAuctionProceeds.transaction,
          evidence.actions.migrateAuction.transaction,
        );
        assert.deepEqual(
          evidence.actions.claimAuctionProceeds.receipt,
          evidence.actions.migrateAuction.receipt,
        );
        assert.ok(
          !evidence.reviewedSemantics.causalEdges.includes(
            "migrateAuction<claimAuctionProceeds",
          ),
        );
        assert.deepEqual(assertV5PhaseBEvidence(evidence, context), evidence);
      }),
  );

  await t.test(
    "rejects a separate pair when migration emitted no proceeds",
    () =>
      withFixture((context) => {
        makeZeroProceeds(context, { alias: false });
        assert.throws(
          () => buildV5PhaseBEvidence(context),
          /0 exact canary AuctionProceeds events/,
        );
      }),
  );

  await t.test(
    "allows unrelated-token proceeds events in an aliased helper receipt",
    () =>
      withFixture((context) => {
        const unrelatedAuctionProceeds = structuredClone(
          context.pairs.migrateAuction.receipt.logs[2],
        );
        const unrelatedCreatorFeesClaimed = structuredClone(
          context.pairs.claimAuctionProceeds.receipt.logs[0],
        );
        makeZeroProceeds(context);
        const migration = context.pairs.migrateAuction;
        for (const [log, logIndex] of [
          [unrelatedAuctionProceeds, 5],
          [unrelatedCreatorFeesClaimed, 6],
        ]) {
          Object.assign(log, {
            blockHash: migration.receipt.blockHash,
            blockNumber: migration.receipt.blockNumber,
            blockTimestamp: migration.receipt.logs[0].blockTimestamp,
            transactionHash: migration.receipt.transactionHash,
            transactionIndex: migration.receipt.transactionIndex,
            logIndex: qty(logIndex),
          });
          log.topics[1] = addressTopic(otherToken);
          migration.receipt.logs.push(log);
        }
        aliasClaimToMigration(context);
        writeAll(context);
        const evidence = buildV5PhaseBEvidence(context);
        assert.equal(
          evidence.actions.claimAuctionProceeds.events.call,
          "not-applicable-zero-proceeds",
        );
        assert.equal(
          evidence.actions.migrateAuction.events.auctionProceeds,
          null,
        );
      }),
  );

  await t.test(
    "rejects CreatorFeesClaimed in a zero-proceeds migration receipt",
    () =>
      withFixture((context) => {
        const creatorFeesClaimed = structuredClone(
          context.pairs.claimAuctionProceeds.receipt.logs[0],
        );
        makeZeroProceeds(context);
        const migration = context.pairs.migrateAuction;
        Object.assign(creatorFeesClaimed, {
          blockHash: migration.receipt.blockHash,
          blockNumber: migration.receipt.blockNumber,
          blockTimestamp: migration.receipt.logs[0].blockTimestamp,
          transactionHash: migration.receipt.transactionHash,
          transactionIndex: migration.receipt.transactionIndex,
          logIndex: qty(5),
        });
        migration.receipt.logs.push(creatorFeesClaimed);
        aliasClaimToMigration(context);
        writeAll(context);
        assert.throws(
          () => buildV5PhaseBEvidence(context),
          /zero-proceeds migration receipt must not contain CreatorFeesClaimed/,
        );
      }),
  );

  await t.test(
    "rejects a swept amount above exact migrated ETH liquidity",
    () =>
      withFixture((context) => {
        makeZeroProceeds(context);
        context.pairs.migrateAuction.receipt.logs[0].data = data(
          ["uint256"],
          [migratedEthLiquidity + 1n],
        );
        aliasClaimToMigration(context);
        writeAll(context);
        assert.throws(
          () => buildV5PhaseBEvidence(context),
          /zero-proceeds migration ETH liquidity does not equal receipt-local currency swept/,
        );
      }),
  );

  await t.test(
    "rejects a not-applicable proof changed after construction",
    () =>
      withFixture((context) => {
        makeZeroProceeds(context);
        const evidence = buildV5PhaseBEvidence(context);
        evidence.actions.claimAuctionProceeds.events.notApplicable.amountWei =
          "1";
        assert.throws(
          () => assertV5PhaseBEvidence(evidence, context),
          /differs from its six canonical action/,
        );
      }),
  );
});

test("assert rejects an index changed after construction or raw bytes changed underneath it", async () => {
  await withFixture((context) => {
    const evidence = buildV5PhaseBEvidence(context);
    evidence.actions.collect.events.flywheelCollected.amountWei = "1";
    assert.throws(
      () => assertV5PhaseBEvidence(evidence, context),
      /differs from its six canonical action/,
    );

    const fresh = buildV5PhaseBEvidence(context);
    writeFileSync(
      context.pairs.collect.transactionPath,
      `${JSON.stringify(context.pairs.collect.transaction)} \n`,
    );
    assert.throws(
      () => assertV5PhaseBEvidence(fresh, context),
      /differs from its six canonical action/,
    );
  });
});

test("rejects in-repository symlinks to mutable raw evidence", async () => {
  await withFixture((context, directory) => {
    const linkedPath = join(directory, "collect-linked.transaction.json");
    symlinkSync(context.pairs.collect.transactionPath, linkedPath);
    context.pairs.collect.transactionPath = linkedPath;
    assert.throws(
      () => buildV5PhaseBEvidence(context),
      /raw evidence path must not traverse a symbolic link/,
    );
  });
});

test("rejects raw objects that are not exactly the objects parsed from their bound paths", async () => {
  await withFixture((context) => {
    context.pairs.exitBid.transaction.nonce = "0x4";
    assert.throws(
      () => buildV5PhaseBEvidence(context),
      /differs from the raw evidence bytes/,
    );
  });
});

test("accepts event-proven nested permissionless outcomes but pins direct calls and owner buyback", async (t) => {
  await t.test("permissionless collect may be nested through a helper", () =>
    withFixture((context) => {
      context.pairs.collect.transaction.to = launchpad;
      context.pairs.collect.receipt.to = launchpad;
      writeAll(context);
      assert.equal(
        buildV5PhaseBEvidence(context).actions.collect.events.call,
        "nested",
      );
    }),
  );
  await t.test("nonzero value", () =>
    withFixture((context) => {
      context.pairs.exitBid.transaction.value = "0x1";
      writeAll(context);
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /exitBid direct call sends nonzero/,
      );
    }),
  );
  await t.test("wrong bid", () =>
    withFixture((context) => {
      context.pairs.claimTokens.transaction.input = encodeFunctionData({
        abi: auctionAbi,
        functionName: "claimTokens",
        args: [bidId + 1n],
      });
      writeAll(context);
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /neither reviewed claimTokens/,
      );
    }),
  );
  await t.test("creator fee call cannot masquerade as proceeds claim", () =>
    withFixture((context) => {
      const wrongAbi = parseAbi(["function claimCreatorFees(address token)"]);
      context.pairs.claimAuctionProceeds.transaction.input = encodeFunctionData(
        {
          abi: wrongAbi,
          functionName: "claimCreatorFees",
          args: [token],
        },
      );
      writeAll(context);
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /not ABI-equivalent to the reviewed claimAuctionProceeds/,
      );
    }),
  );
  await t.test("buyback minimum is exact", () =>
    withFixture((context) => {
      context.pairs.buybackAndBurn.transaction.input = encodeFunctionData({
        abi: burnerAbi,
        functionName: "buybackAndBurn",
        args: [3_000_000_000_000n, reviewedMinHookrOut + 1n],
      });
      writeAll(context);
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /exact reviewed buybackAndBurn/,
      );
    }),
  );
  await t.test(
    "direct permissionless calls tolerate ABI-equivalent trailing bytes",
    () =>
      withFixture((context) => {
        context.pairs.migrateAuction.transaction.input += "00";
        context.pairs.collect.transaction.input += "deadbeef";
        writeAll(context);
        const evidence = buildV5PhaseBEvidence(context);
        assert.equal(evidence.actions.migrateAuction.events.call, "direct");
        assert.equal(evidence.actions.collect.events.call, "direct");
      }),
  );
  await t.test("owner buyback remains byte-exact", () =>
    withFixture((context) => {
      context.pairs.buybackAndBurn.transaction.input += "00";
      writeAll(context);
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /exact reviewed buybackAndBurn/,
      );
    }),
  );
});

test("allows arbitrary callers for five permissionless calls but requires owner for buyback", async () => {
  await withFixture((context) => {
    context.pairs.migrateAuction.transaction.from =
      context.pairs.collect.transaction.from;
    context.pairs.migrateAuction.receipt.from =
      context.pairs.collect.transaction.from;
    writeAll(context);
    assert.doesNotThrow(() => buildV5PhaseBEvidence(context));

    context.pairs.buybackAndBurn.transaction.from = actionSpec.collect.sender;
    context.pairs.buybackAndBurn.receipt.from = actionSpec.collect.sender;
    writeAll(context);
    assert.throws(
      () => buildV5PhaseBEvidence(context),
      /sender is not the exact release owner/,
    );
  });
});

test("one helper receipt may canonically satisfy multiple permissionless outcomes", async () => {
  await withFixture((context) => {
    const helper = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const helperCaller = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const helperHash = word(880_001);
    const helperBlock = 104;
    const helperTransactionIndex = 5;
    const combinedLogs = [
      ...structuredClone(context.pairs.exitBid.receipt.logs),
      ...structuredClone(context.pairs.claimTokens.receipt.logs),
      ...structuredClone(context.pairs.collect.receipt.logs),
      ...structuredClone(context.pairs.migrateAuction.receipt.logs),
      ...structuredClone(context.pairs.claimAuctionProceeds.receipt.logs),
    ];
    combinedLogs.forEach((log, index) => {
      log.blockHash = blockHash(helperBlock);
      log.blockNumber = qty(helperBlock);
      log.blockTimestamp = qty(1_800_000_000 + helperBlock);
      log.transactionHash = helperHash;
      log.transactionIndex = qty(helperTransactionIndex);
      log.logIndex = qty(index + 1);
    });
    const helperTransaction = {
      ...structuredClone(context.pairs.migrateAuction.transaction),
      hash: helperHash,
      from: helperCaller,
      to: helper,
      nonce: qty(77),
      value: "0x1",
      input: "0x12345678",
      blockHash: blockHash(helperBlock),
      blockNumber: qty(helperBlock),
      transactionIndex: qty(helperTransactionIndex),
    };
    const helperReceipt = {
      ...structuredClone(context.pairs.migrateAuction.receipt),
      transactionHash: helperHash,
      from: helperCaller,
      to: helper,
      blockHash: blockHash(helperBlock),
      blockNumber: qty(helperBlock),
      transactionIndex: qty(helperTransactionIndex),
      logs: combinedLogs,
    };
    for (const name of V5_PHASE_B_ACTIONS.slice(0, 5)) {
      context.pairs[name].transaction = structuredClone(helperTransaction);
      context.pairs[name].receipt = structuredClone(helperReceipt);
    }
    relocatePair(context.pairs.buybackAndBurn, 106, 1);
    writeAll(context);
    const evidence = buildV5PhaseBEvidence(context);
    assert.equal(
      new Set(
        V5_PHASE_B_ACTIONS.slice(0, 5).map(
          (name) => evidence.actions[name].transaction.hash,
        ),
      ).size,
      1,
    );
    for (const name of [
      "migrateAuction",
      "exitBid",
      "claimTokens",
      "claimAuctionProceeds",
      "collect",
    ]) {
      assert.equal(evidence.actions[name].events.call, "nested");
    }
  });
});

test("requires canonical transaction/receipt pairing and the complete ordered log coordinates", async (t) => {
  await t.test("failed status", () =>
    withFixture((context) => {
      context.pairs.collect.receipt.status = "0x0";
      writeAll(context);
      assert.throws(() => buildV5PhaseBEvidence(context), /did not succeed/);
    }),
  );
  await t.test("hash pairing", () =>
    withFixture((context) => {
      context.pairs.claimTokens.receipt.transactionHash = word(999_999);
      for (const log of context.pairs.claimTokens.receipt.logs)
        log.transactionHash = word(999_999);
      writeAll(context);
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /transaction and receipt hashes differ/,
      );
    }),
  );
  await t.test("canonical coordinates", () =>
    withFixture((context) => {
      context.pairs.exitBid.transaction.transactionIndex = "0x8";
      writeAll(context);
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /canonical coordinates differ/,
      );
    }),
  );
  await t.test("log coordinates", () =>
    withFixture((context) => {
      context.pairs.collect.receipt.logs[0].blockHash = word(123);
      writeAll(context);
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /log #0 canonical coordinates differ/,
      );
    }),
  );
  await t.test("ordered logs", () =>
    withFixture((context) => {
      context.pairs.collect.receipt.logs[1].logIndex =
        context.pairs.collect.receipt.logs[0].logIndex;
      writeAll(context);
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /not in canonical log-index order/,
      );
    }),
  );
});

test("binds migration and PoolManager initialization to one reconstructed canonical ETH pool", async (t) => {
  await t.test("missing receipt-local CurrencySwept", () =>
    withFixture((context) => {
      context.pairs.migrateAuction.receipt.logs.splice(0, 1);
      writeAll(context);
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /0 CurrencySwept events/,
      );
    }),
  );
  await t.test("missing Initialize", () =>
    withFixture((context) => {
      context.pairs.migrateAuction.receipt.logs.splice(1, 1);
      writeAll(context);
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /0 exact canonical-pool Initialize events/,
      );
    }),
  );
  await t.test("wrong PoolKey", () =>
    withFixture((context) => {
      context.pairs.migrateAuction.receipt.logs[1].data = data(
        ["uint24", "int24", "address", "uint160", "int24"],
        [
          dynamicFee,
          tickSpacing,
          "0x9999999999999999999999999999999999999999",
          sqrtPriceX96,
          111,
        ],
      );
      writeAll(context);
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /does not reconstruct the canonical pool id/,
      );
    }),
  );
  await t.test("opening price mismatch", () =>
    withFixture((context) => {
      context.pairs.migrateAuction.receipt.logs[3].data = data(
        ["uint160", "uint256", "uint256", "uint256"],
        [sqrtPriceX96 + 1n, migratedEthLiquidity, tokenLiquidity, tokensBurned],
      );
      writeAll(context);
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /opening prices differ/,
      );
    }),
  );
  await t.test("missing receipt-local AuctionProceeds", () =>
    withFixture((context) => {
      context.pairs.migrateAuction.receipt.logs.splice(2, 1);
      writeAll(context);
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /0 exact canary AuctionProceeds events/,
      );
    }),
  );
  await t.test("migrated reserve conservation is exact", () =>
    withFixture((context) => {
      context.pairs.migrateAuction.receipt.logs[3].data = data(
        ["uint160", "uint256", "uint256", "uint256"],
        [sqrtPriceX96, migratedEthLiquidity, tokenLiquidity + 1n, tokensBurned],
      );
      writeAll(context);
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /do not conserve the exact/,
      );
    }),
  );
  await t.test(
    "swept net currency conserves pool liquidity plus creator proceeds",
    () =>
      withFixture((context) => {
        context.pairs.migrateAuction.receipt.logs[0].data = data(
          ["uint256"],
          [currencySweptWei + 1n],
        );
        writeAll(context);
        assert.throws(
          () => buildV5PhaseBEvidence(context),
          /does not equal receipt-local currency swept/,
        );
      }),
  );
  await t.test("CurrencySwept recipient is the launchpad", () =>
    withFixture((context) => {
      context.pairs.migrateAuction.receipt.logs[0].topics[1] =
        addressTopic(owner);
      writeAll(context);
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /funds recipient is not the launchpad/,
      );
    }),
  );
  await t.test("migration receipt preserves source event order", () =>
    withFixture((context) => {
      const currency = context.pairs.migrateAuction.receipt.logs[0];
      const initialize = context.pairs.migrateAuction.receipt.logs[1];
      const currencyPayload = {
        address: currency.address,
        topics: currency.topics,
        data: currency.data,
      };
      currency.address = initialize.address;
      currency.topics = initialize.topics;
      currency.data = initialize.data;
      initialize.address = currencyPayload.address;
      initialize.topics = currencyPayload.topics;
      initialize.data = currencyPayload.data;
      writeAll(context);
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /CurrencySwept < Initialize < AuctionProceeds < Migrated/,
      );
    }),
  );
  await t.test(
    "canonical id alone cannot substitute an unreviewed fee key",
    () =>
      withFixture((context) => {
        const unreviewedFee = 3_000;
        const unreviewedPoolId = keccak256(
          encodeAbiParameters(
            [{ type: "tuple", components: poolKeyComponents }],
            [[ZERO, token, unreviewedFee, tickSpacing, hook]],
          ),
        );
        context.poolId = unreviewedPoolId;
        context.pairs.migrateAuction.receipt.logs[1].topics[1] =
          unreviewedPoolId;
        context.pairs.migrateAuction.receipt.logs[1].data = data(
          ["uint24", "int24", "address", "uint160", "int24"],
          [unreviewedFee, tickSpacing, hook, sqrtPriceX96, 111],
        );
        context.pairs.migrateAuction.receipt.logs[3].topics[2] =
          unreviewedPoolId;
        writeAll(context);
        assert.throws(
          () => buildV5PhaseBEvidence(context),
          /exact reviewed fee\/tick\/hook key/,
        );
      }),
  );
});

test("binds bid exit, token claim, and proceeds event identities to the reviewed auction", async (t) => {
  await t.test("claim fill differs from exit", () =>
    withFixture((context) => {
      context.pairs.claimTokens.receipt.logs[0].data = data(
        ["uint256"],
        [tokensFilled - 1n],
      );
      writeAll(context);
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /fill differs from BidExited/,
      );
    }),
  );
  await t.test("proceeds event must be in the exact claim receipt", () =>
    withFixture((context) => {
      context.pairs.claimAuctionProceeds.receipt.logs = [];
      writeAll(context);
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /0 exact CreatorFeesClaimed events/,
      );
    }),
  );
  await t.test("proceeds payee is owner", () =>
    withFixture((context) => {
      context.pairs.claimAuctionProceeds.receipt.logs[0].topics[2] =
        addressTopic(actionSpec.collect.sender);
      writeAll(context);
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /0 exact CreatorFeesClaimed events/,
      );
    }),
  );
  await t.test("claimed proceeds equal the migration receipt allocation", () =>
    withFixture((context) => {
      context.pairs.claimAuctionProceeds.receipt.logs[0].data = data(
        ["uint256"],
        [auctionProceedsWei + 1n],
      );
      writeAll(context);
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /0 exact CreatorFeesClaimed events/,
      );
    }),
  );
  await t.test("direct claim Transfer must equal TokensClaimed", () =>
    withFixture((context) => {
      context.pairs.claimTokens.receipt.logs[1].data = data(
        ["uint256"],
        [tokensFilled + 1n],
      );
      writeAll(context);
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /does not equal the sum of TokensClaimed/,
      );
    }),
  );
});

test("accepts a permissionless batch front-run containing the exact owner and canary bid", async (t) => {
  await t.test("batch may aggregate additional owner transfers", () =>
    withFixture((context) => {
      context.pairs.claimTokens.transaction.input = encodeFunctionData({
        abi: auctionAbi,
        functionName: "claimTokensBatch",
        args: [owner, [bidId, bidId + 1n]],
      });
      const transfer = context.pairs.claimTokens.receipt.logs[1];
      transfer.logIndex = qty(BigInt(transfer.logIndex) + 1n);
      transfer.data = data(["uint256"], [tokensFilled + 999n]);
      const extraClaim = {
        ...context.pairs.claimTokens.receipt.logs[0],
        topics: [
          toEventSelector("TokensClaimed(uint256,address,uint256)"),
          word(bidId + 1n),
          addressTopic(owner),
        ],
        data: data(["uint256"], [999n]),
        logIndex: qty(BigInt(transfer.logIndex) - 1n),
      };
      context.pairs.claimTokens.receipt.logs.splice(1, 0, extraClaim);
      writeAll(context);
      const evidence = buildV5PhaseBEvidence(context);
      assert.equal(
        evidence.actions.claimTokens.events.call,
        "claimTokensBatch",
      );
      assert.equal(
        evidence.actions.claimTokens.events.auctionToOwnerTransfers
          .aggregateAmount,
        (tokensFilled + 999n).toString(),
      );
    }),
  );
  await t.test(
    "batch may repeat the canary bid after its first positive claim",
    () =>
      withFixture((context) => {
        context.pairs.claimTokens.transaction.input = encodeFunctionData({
          abi: auctionAbi,
          functionName: "claimTokensBatch",
          args: [owner, [bidId, bidId]],
        });
        writeAll(context);
        const evidence = buildV5PhaseBEvidence(context);
        assert.equal(
          evidence.actions.claimTokens.events.tokensClaimed.bidId,
          bidId.toString(),
        );
      }),
  );
  await t.test(
    "batch may repeat another bid while accounting its one positive event exactly",
    () =>
      withFixture((context) => {
        context.pairs.claimTokens.transaction.input = encodeFunctionData({
          abi: auctionAbi,
          functionName: "claimTokensBatch",
          args: [owner, [bidId, bidId + 1n, bidId + 1n]],
        });
        const transfer = context.pairs.claimTokens.receipt.logs[1];
        transfer.logIndex = qty(BigInt(transfer.logIndex) + 1n);
        transfer.data = data(["uint256"], [tokensFilled + 999n]);
        context.pairs.claimTokens.receipt.logs.splice(1, 0, {
          ...context.pairs.claimTokens.receipt.logs[0],
          topics: [
            toEventSelector("TokensClaimed(uint256,address,uint256)"),
            word(bidId + 1n),
            addressTopic(owner),
          ],
          data: data(["uint256"], [999n]),
          logIndex: qty(BigInt(transfer.logIndex) - 1n),
        });
        writeAll(context);
        assert.doesNotThrow(() => buildV5PhaseBEvidence(context));
      }),
  );
  await t.test("batch transfer cannot contain unexplained excess", () =>
    withFixture((context) => {
      context.pairs.claimTokens.transaction.input = encodeFunctionData({
        abi: auctionAbi,
        functionName: "claimTokensBatch",
        args: [owner, [bidId, bidId + 1n]],
      });
      context.pairs.claimTokens.receipt.logs[1].data = data(
        ["uint256"],
        [tokensFilled + 999n],
      );
      writeAll(context);
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /does not equal the sum of TokensClaimed/,
      );
    }),
  );
  await t.test("batch owner is exact canary owner", () =>
    withFixture((context) => {
      context.pairs.claimTokens.transaction.input = encodeFunctionData({
        abi: auctionAbi,
        functionName: "claimTokensBatch",
        args: [actionSpec.collect.sender, [bidId]],
      });
      writeAll(context);
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /owner\/bid array is malformed/,
      );
    }),
  );
});

test("requires the successful post-accrual collect and proves exact spend and minimum burn", async (t) => {
  await t.test("zero collection is impossible and rejected", () =>
    withFixture((context) => {
      context.pairs.collect.receipt.logs[1].data = data(["uint256"], [0n]);
      context.pairs.collect.receipt.logs[2].data = data(["uint256"], [0n]);
      writeAll(context);
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /below the exact 3000000000000 accrual/,
      );
    }),
  );
  await t.test("wrong ETH spent", () =>
    withFixture((context) => {
      context.pairs.buybackAndBurn.receipt.logs[1].data = data(
        ["uint256", "uint256"],
        [2_999_999_999_999n, hookrBurned],
      );
      writeAll(context);
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /ETH spent is not exactly/,
      );
    }),
  );
  await t.test("burn below reviewed minimum", () =>
    withFixture((context) => {
      context.pairs.buybackAndBurn.receipt.logs[1].data = data(
        ["uint256", "uint256"],
        [3_000_000_000_000n, reviewedMinHookrOut - 1n],
      );
      writeAll(context);
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /HOOKR burned is below/,
      );
    }),
  );
  await t.test(
    "collect binds the hook Claimed account and amount in the same receipt",
    () =>
      withFixture((context) => {
        context.pairs.collect.receipt.logs[1].data = data(["uint256"], [1n]);
        writeAll(context);
        assert.throws(
          () => buildV5PhaseBEvidence(context),
          /0 exact hook Claimed events/,
        );
      }),
  );
  await t.test("buyback requires the same-receipt HOOKR dead transfer", () =>
    withFixture((context) => {
      context.pairs.buybackAndBurn.receipt.logs.shift();
      writeAll(context);
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /0 exact burner-to-dead HOOKR transfers/,
      );
    }),
  );
  await t.test("buyback rejects a dead transfer from another token", () =>
    withFixture((context) => {
      context.pairs.buybackAndBurn.receipt.logs[0].address = token;
      writeAll(context);
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /0 exact burner-to-dead HOOKR transfers/,
      );
    }),
  );
  await t.test("buyback rejects a dead transfer from another account", () =>
    withFixture((context) => {
      context.pairs.buybackAndBurn.receipt.logs[0].topics[1] =
        addressTopic(owner);
      writeAll(context);
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /0 exact burner-to-dead HOOKR transfers/,
      );
    }),
  );
  await t.test("buyback rejects a transfer to another recipient", () =>
    withFixture((context) => {
      context.pairs.buybackAndBurn.receipt.logs[0].topics[2] =
        addressTopic(owner);
      writeAll(context);
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /0 exact burner-to-dead HOOKR transfers/,
      );
    }),
  );
  await t.test("buyback dead transfer amount equals the emitted burn", () =>
    withFixture((context) => {
      context.pairs.buybackAndBurn.receipt.logs[0].data = data(
        ["uint256"],
        [hookrBurned + 1n],
      );
      writeAll(context);
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /dead transfer differs from BuybackBurned/,
      );
    }),
  );
  await t.test("buyback transfers HOOKR before emitting BuybackBurned", () =>
    withFixture((context) => {
      const transfer = context.pairs.buybackAndBurn.receipt.logs[0];
      const burnedEvent = context.pairs.buybackAndBurn.receipt.logs[1];
      const transferPayload = {
        address: transfer.address,
        topics: transfer.topics,
        data: transfer.data,
      };
      transfer.address = burnedEvent.address;
      transfer.topics = burnedEvent.topics;
      transfer.data = burnedEvent.data;
      burnedEvent.address = transferPayload.address;
      burnedEvent.topics = transferPayload.topics;
      burnedEvent.data = transferPayload.data;
      writeAll(context);
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /dead transfer does not precede BuybackBurned/,
      );
    }),
  );
});

test("enforces only the three protocol-causal edges", async (t) => {
  await t.test("exit before claim", () =>
    withFixture((context) => {
      relocatePair(context.pairs.exitBid, 106, 0);
      writeAll(context);
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /exitBid before claimTokens/,
      );
    }),
  );
  await t.test("migrate before proceeds", () =>
    withFixture((context) => {
      relocatePair(context.pairs.migrateAuction, 105, 3);
      writeAll(context);
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /migrateAuction before claimAuctionProceeds/,
      );
    }),
  );
  await t.test("collect before burn", () =>
    withFixture((context) => {
      relocatePair(context.pairs.collect, 104, 2);
      writeAll(context);
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /collect before buybackAndBurn/,
      );
    }),
  );
  await t.test("Phase-A accrual before collect", () =>
    withFixture((context) => {
      context.phaseAAccrual.blockNumber = "101";
      context.phaseAAccrual.transactionIndex = "9";
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /Phase-A accrual before collect/,
      );
    }),
  );
  await t.test("Phase-A accrual amount is exact", () =>
    withFixture((context) => {
      context.phaseAAccrual.amountWei = "2999999999999";
      assert.throws(
        () => buildV5PhaseBEvidence(context),
        /flywheel accrual is not exactly/,
      );
    }),
  );
});

test("CLI writes and then verifies the same SHA-bound evidence", async () => {
  await withFixture((context, directory) => {
    const output = join(directory, "phase-b-evidence.json");
    const cliNames = {
      migrateAuction: "migrate-auction",
      exitBid: "exit-bid",
      claimTokens: "claim-tokens",
      claimAuctionProceeds: "claim-auction-proceeds",
      collect: "collect",
      buybackAndBurn: "buyback-and-burn",
    };
    const rawFlags = V5_PHASE_B_ACTIONS.flatMap((name) => [
      `--${cliNames[name]}-transaction`,
      context.pairs[name].transactionPath,
      `--${cliNames[name]}-receipt`,
      context.pairs[name].receiptPath,
    ]);
    const flags = [
      ...rawFlags,
      "--source-commit",
      context.sourceCommit,
      "--token",
      context.token,
      "--auction",
      context.auction,
      "--bid-id",
      context.bidId,
      "--launchpad",
      context.launchpad,
      "--burner",
      context.burner,
      "--owner",
      context.owner,
      "--pool-manager",
      context.poolManager,
      "--pool-id",
      context.poolId,
      "--hook",
      context.hook,
      "--hookr-token",
      context.hookrToken,
      "--phase-a-accrual-transaction-hash",
      context.phaseAAccrual.transactionHash,
      "--phase-a-accrual-block-number",
      context.phaseAAccrual.blockNumber,
      "--phase-a-accrual-transaction-index",
      context.phaseAAccrual.transactionIndex,
      "--phase-a-accrual-log-index",
      context.phaseAAccrual.logIndex,
      "--phase-a-accrual-pool-id",
      context.phaseAAccrual.poolId,
      "--phase-a-accrual-amount-wei",
      context.phaseAAccrual.amountWei,
      "--output",
      output,
    ];
    const script = join(process.cwd(), "scripts/build-v5-phase-b-evidence.mjs");
    const write = spawnSync(process.execPath, [script, ...flags, "--write"], {
      cwd: process.cwd(),
      encoding: "utf8",
    });
    assert.equal(write.status, 0, write.stderr);
    assert.match(write.stdout, /wrote/);
    const verify = spawnSync(process.execPath, [script, ...flags], {
      cwd: process.cwd(),
      encoding: "utf8",
    });
    assert.equal(verify.status, 0, verify.stderr);
    assert.match(verify.stdout, /verified/);

    const digest = createHash("sha256")
      .update(
        JSON.stringify(context.pairs.migrateAuction.transaction, null, 2) +
          "\n",
      )
      .digest("hex");
    assert.equal(
      buildV5PhaseBEvidence(context).actions.migrateAuction.raw
        .transactionSha256,
      digest,
    );
  });
});
