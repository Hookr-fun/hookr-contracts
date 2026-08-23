import assert from "node:assert/strict";
import test from "node:test";
import { getCreate2Address, keccak256, toHex } from "viem";

import {
  INSTANT_CANARY_SPEC,
  poolIdForKey,
  validateInstantCanaryEvidence,
} from "./lib/instant-canary-evidence.mjs";
import {
  assertRetainedReleaseHistoryPreserved,
  replaceCurrentReleaseManifest,
} from "./lib/release-manifest-patch.mjs";
import {
  assertReceiptsWithinEvidenceBlock,
  assertStateEvidenceAfterFinality,
  assertStateEvidenceFinalized,
  canonicalCreate2Address,
  deriveLiveLaunchpadDeployBlock,
  HOUSE_BLUEPRINTS,
  validateHouseBlueprintEvidence,
} from "./lib/release-promotion-evidence.mjs";
import {
  assertArtifactSourceHashes,
  deriveRuntimeReferenceLayoutHash,
  REVIEWED_COMPILER_SETTINGS,
  validateReviewedRuntime,
} from "./lib/runtime-template-evidence.mjs";

const retained = `export const RETAINED_GENERATION_3_MANIFEST = {
  version: 3,
} as const satisfies HookrReleaseManifest;`;

const generation4 = `export const CURRENT_RELEASE_MANIFEST = {
  version: 4,
  capabilities: { launchModes: ["curve", "instant"] },
  evidence: { canaryReceipts: { kind: "instant_launch_round_trip_v1" } },
} as const satisfies HookrReleaseManifest;`;

const readRegistry = `export const READ_RELEASES = validateReleaseRegistry(
  CURRENT_RELEASE_MANIFEST,
  createReleaseRegistry([
    CURRENT_RELEASE_MANIFEST,
    RETAINED_GENERATION_3_MANIFEST,
  ]),
);`;

const releaseSource = (current) => `${retained}\n${current}\n${readRegistry}\n`;

test("promotion expands only the current alias and preserves retained generation 3", () => {
  const source = releaseSource(
    "export const CURRENT_RELEASE_MANIFEST = RETAINED_GENERATION_3_MANIFEST;",
  );
  const patched = replaceCurrentReleaseManifest(source, generation4);

  assert.ok(patched.includes(retained));
  assert.ok(patched.includes(generation4));
  assert.equal(patched.match(/RETAINED_GENERATION_3_MANIFEST =/g)?.length, 1);
});

test("a same-version recovery is allowed only when it is an exact no-op", () => {
  const source = releaseSource(generation4);
  assert.equal(replaceCurrentReleaseManifest(source, generation4), source);
  assert.throws(
    () =>
      replaceCurrentReleaseManifest(
        source,
        generation4.replace("launchModes: [\"curve\", \"instant\"]", "launchModes: [\"curve\"]"),
      ),
    /refusing to replace expanded current release v4/,
  );
});

test("promotion fails closed when the current assignment is missing or ambiguous", () => {
  assert.throws(() => replaceCurrentReleaseManifest(retained, generation4), /found 0/);
  assert.throws(
    () =>
      replaceCurrentReleaseManifest(
        releaseSource(
          "export const CURRENT_RELEASE_MANIFEST = RETAINED_GENERATION_3_MANIFEST;\n" +
            "export const CURRENT_RELEASE_MANIFEST = RETAINED_GENERATION_3_MANIFEST;",
        ),
        generation4,
      ),
    /found 2/,
  );
});

test("promotion compares retained manifests and their registry registration exactly", () => {
  const source = releaseSource(
    "export const CURRENT_RELEASE_MANIFEST = RETAINED_GENERATION_3_MANIFEST;",
  );
  assert.doesNotThrow(() => assertRetainedReleaseHistoryPreserved(source, source));
  assert.throws(
    () =>
      assertRetainedReleaseHistoryPreserved(
        source,
        source.replace("version: 3", "version: 99"),
      ),
    /exact retained release history/,
  );
  assert.throws(
    () =>
      assertRetainedReleaseHistoryPreserved(
        source,
        source.replace("    RETAINED_GENERATION_3_MANIFEST,\n", ""),
      ),
    /exact retained release history/,
  );
});

test("a future promotion fails closed until v4 is atomically retained and registered", () => {
  const generation5 = generation4.replace("version: 4", "version: 5");
  const source = releaseSource(generation4);
  assert.throws(
    () => replaceCurrentReleaseManifest(source, generation5),
    /retain it atomically before any future generation/,
  );
});

test("the initial retained alias can advance exactly one generation only", () => {
  const source = releaseSource(
    "export const CURRENT_RELEASE_MANIFEST = RETAINED_GENERATION_3_MANIFEST;",
  );
  assert.throws(
    () => replaceCurrentReleaseManifest(source, generation4.replace("version: 4", "version: 3")),
    /advance exactly one generation/,
  );
  assert.throws(
    () => replaceCurrentReleaseManifest(source, generation4.replace("version: 4", "version: 5")),
    /advance exactly one generation/,
  );
});

const addresses = {
  deployer: "0x1111111111111111111111111111111111111111",
  launchpad: "0x2222222222222222222222222222222222222222",
  hook: "0x3333333333333333333333333333333333333333",
  router: "0x4444444444444444444444444444444444444444",
  poolManager: "0x5555555555555555555555555555555555555555",
  token: "0x6666666666666666666666666666666666666666",
};

const replaceRuntimeBytes = (runtime, start, length, value) => {
  assert.equal(value.length, length * 2);
  return runtime.slice(0, start * 2) + value + runtime.slice((start + length) * 2);
};

const runtimeArtifactFixture = () => {
  const source = "contract ReviewedRuntimeFixture {}\n";
  let object = "60".repeat(160);
  object = replaceRuntimeBytes(object, 8, 32, "0".repeat(64));
  object = replaceRuntimeBytes(object, 45, 20, "_".repeat(40));
  object = replaceRuntimeBytes(object, 80, 32, "0".repeat(64));
  object = replaceRuntimeBytes(object, 120, 32, "0".repeat(64));
  const normalizedObject = replaceRuntimeBytes(object, 45, 20, "0".repeat(40));
  const artifact = {
    metadata: {
      compiler: { version: REVIEWED_COMPILER_SETTINGS.compilerVersion },
      sources: {
        "src/ReviewedRuntimeFixture.sol": {
          keccak256: keccak256(toHex(new TextEncoder().encode(source))),
        },
      },
      settings: {
        optimizer: { enabled: true, runs: REVIEWED_COMPILER_SETTINGS.optimizerRuns },
        viaIR: true,
        evmVersion: REVIEWED_COMPILER_SETTINGS.evmVersion,
        metadata: { bytecodeHash: "none" },
        libraries: {},
        compilationTarget: {
          "src/ReviewedRuntimeFixture.sol": "ReviewedRuntimeFixture",
        },
      },
    },
    deployedBytecode: {
      object,
      immutableReferences: {
        "123": [
          { start: 8, length: 32 },
          { start: 80, length: 32 },
        ],
      },
      linkReferences: {
        "src/ReviewedLibrary.sol": {
          ReviewedLibrary: [{ start: 45, length: 20 }],
        },
      },
    },
  };
  return {
    source,
    normalizedTemplateHash: keccak256(`0x${normalizedObject}`),
    referenceLayoutHash: deriveRuntimeReferenceLayoutHash(artifact),
    artifact,
  };
};

const linkedRuntimeFixture = (artifact, immutableAddress = addresses.poolManager) => {
  let live = artifact.deployedBytecode.object;
  const immutableWord = `${"0".repeat(24)}${immutableAddress.slice(2).toLowerCase()}`;
  live = replaceRuntimeBytes(live, 8, 32, immutableWord);
  live = replaceRuntimeBytes(live, 80, 32, immutableWord);
  live = replaceRuntimeBytes(live, 45, 20, addresses.hook.slice(2).toLowerCase());
  return `0x${live}`;
};

test("reviewed runtime proof masks only verified compiler reference slots", () => {
  const { artifact, source, normalizedTemplateHash, referenceLayoutHash } =
    runtimeArtifactFixture();
  assert.equal(
    assertArtifactSourceHashes(artifact, (path) => {
      assert.equal(path, "src/ReviewedRuntimeFixture.sol");
      return source;
    }),
    1,
  );
  const proof = validateReviewedRuntime({
    artifact,
    liveCode: linkedRuntimeFixture(artifact),
    expectedTarget: {
      sourcePath: "src/ReviewedRuntimeFixture.sol",
      contractName: "ReviewedRuntimeFixture",
    },
    expectedImmutableAddresses: [addresses.poolManager],
    expectedLinks: {
      "src/ReviewedLibrary.sol:ReviewedLibrary": addresses.hook,
    },
    expectedNormalizedTemplateHash: normalizedTemplateHash,
    expectedReferenceLayoutHash: referenceLayoutHash,
  });
  assert.equal(proof.byteLength, 160);
  assert.match(proof.normalizedTemplateHash, /^0x[0-9a-f]{64}$/);
  assert.equal(proof.referenceLayoutHash, referenceLayoutHash);
});

test("runtime layout anchors ignore solc AST renumbering but retain immutable group boundaries", () => {
  const { artifact, referenceLayoutHash } = runtimeArtifactFixture();
  const renumbered = structuredClone(artifact);
  renumbered.deployedBytecode.immutableReferences = {
    "999999": renumbered.deployedBytecode.immutableReferences["123"],
  };
  assert.equal(deriveRuntimeReferenceLayoutHash(renumbered), referenceLayoutHash);

  const split = structuredClone(artifact);
  const [first, second] = split.deployedBytecode.immutableReferences["123"];
  split.deployedBytecode.immutableReferences = {
    "1": [first],
    "2": [second],
  };
  assert.notEqual(deriveRuntimeReferenceLayoutHash(split), referenceLayoutHash);
});

test("reviewed runtime proof rejects stale sources, wrong constructor values, and changed code", () => {
  const { artifact, normalizedTemplateHash, referenceLayoutHash } = runtimeArtifactFixture();
  assert.throws(
    () => assertArtifactSourceHashes(artifact, () => "changed source"),
    /source hash mismatch/,
  );
  const input = {
    artifact,
    expectedTarget: {
      sourcePath: "src/ReviewedRuntimeFixture.sol",
      contractName: "ReviewedRuntimeFixture",
    },
    expectedImmutableAddresses: [addresses.poolManager],
    expectedLinks: {
      "src/ReviewedLibrary.sol:ReviewedLibrary": addresses.hook,
    },
    expectedNormalizedTemplateHash: normalizedTemplateHash,
    expectedReferenceLayoutHash: referenceLayoutHash,
  };
  assert.throws(
    () =>
      validateReviewedRuntime({
        ...input,
        liveCode: linkedRuntimeFixture(artifact, addresses.router),
      }),
    /immutable address set differs/,
  );
  const changed = replaceRuntimeBytes(
    linkedRuntimeFixture(artifact).slice(2),
    1,
    1,
    "61",
  );
  assert.throws(
    () => validateReviewedRuntime({ ...input, liveCode: `0x${changed}` }),
    /differs from reviewed source at byte 1/,
  );
  assert.throws(
    () =>
      validateReviewedRuntime({
        ...input,
        liveCode: linkedRuntimeFixture(artifact),
        expectedNormalizedTemplateHash: `0x${"00".repeat(32)}`,
      }),
    /normalized template hash is not the reviewed anchor/,
  );
  const widenedArtifact = structuredClone(artifact);
  widenedArtifact.deployedBytecode.immutableReferences["123"].push({
    start: 120,
    length: 32,
  });
  assert.throws(
    () =>
      validateReviewedRuntime({
        ...input,
        artifact: widenedArtifact,
        liveCode: linkedRuntimeFixture(widenedArtifact),
      }),
    /compiler reference layout is not the reviewed anchor/,
  );
});

const blueprintFixture = () => ({
  identities: {
    deployer: addresses.deployer,
    launchpad: addresses.launchpad,
  },
  blueprints: HOUSE_BLUEPRINTS.map((blueprint) => {
    const blockNumber = 200n + BigInt(blueprint.id);
    const contractBlockNumber = 100n + BigInt(blueprint.id);
    return {
      id: blueprint.id,
      transaction: {
        from: addresses.deployer,
        to: addresses.launchpad,
        value: 0n,
        blockNumber,
        contractBlockNumber,
      },
      calldata: {
        name: blueprint.name,
        royaltyBps: blueprint.royaltyBps,
        params: { ...blueprint.params },
      },
      event: {
        id: blueprint.id,
        author: addresses.deployer,
        name: blueprint.name,
        royaltyBps: blueprint.royaltyBps,
      },
      readback: {
        author: addresses.deployer,
        royaltyBps: blueprint.royaltyBps,
        uses: 0,
        savedAtBlock: contractBlockNumber,
        name: blueprint.name,
        params: { ...blueprint.params },
      },
    };
  }),
});

test("promotion derives its floor from the live launchpad receipt", () => {
  const liveLaunchpadReceipt = {
    status: "success",
    contractAddress: addresses.launchpad,
    blockNumber: 123n,
  };
  assert.equal(
    deriveLiveLaunchpadDeployBlock(liveLaunchpadReceipt, addresses.launchpad),
    123n,
  );
  assert.throws(
    () =>
      deriveLiveLaunchpadDeployBlock(
        { ...liveLaunchpadReceipt, contractAddress: addresses.hook },
        addresses.launchpad,
      ),
    /wrong address/,
  );
  assert.throws(
    () =>
      deriveLiveLaunchpadDeployBlock(
        { ...liveLaunchpadReceipt, status: "reverted" },
        addresses.launchpad,
      ),
    /did not succeed/,
  );
});

test("promotion binds canonical CREATE2 salt and initcode to the claimed address", () => {
  const factory = "0x4e59b44847b379578588920cA78FbF26c0B4956C";
  const salt = `0x${"42".repeat(32)}`;
  const initCode = "0x600060005560016000f3";
  const calldata = `${salt}${initCode.slice(2)}`;
  const expected = getCreate2Address({ from: factory, salt, bytecode: initCode });
  assert.equal(canonicalCreate2Address(factory, calldata), expected);
  assert.notEqual(
    canonicalCreate2Address(factory, `${salt}600160005560016000f3`),
    expected,
  );
  assert.throws(() => canonicalCreate2Address(factory, salt), /no init code/);
});

test("promotion requires every receipt at or below the finalized evidence block", () => {
  const evidenceBlock = { number: 500n, hash: `0x${"ab".repeat(32)}` };
  assert.equal(
    assertReceiptsWithinEvidenceBlock(
      [
        { label: "deploy", blockNumber: 499n },
        { label: "canary", blockNumber: 500n },
      ],
      evidenceBlock,
    ),
    500n,
  );
  assert.throws(
    () =>
      assertReceiptsWithinEvidenceBlock(
        [{ label: "canary", blockNumber: 501n }],
        evidenceBlock,
      ),
    /canary is not finalized/,
  );
});

test("state evidence is hash-pinned at or after the finalized receipt head", () => {
  const finalized = { number: 500n, hash: `0x${"ab".repeat(32)}` };
  assert.equal(
    assertStateEvidenceAfterFinality(finalized, {
      number: 500n,
      hash: `0x${"cd".repeat(32)}`,
    }),
    500n,
  );
  assert.equal(
    assertStateEvidenceAfterFinality(finalized, {
      number: 550n,
      hash: `0x${"ef".repeat(32)}`,
    }),
    550n,
  );
  assert.throws(
    () =>
      assertStateEvidenceAfterFinality(finalized, {
        number: 499n,
        hash: `0x${"12".repeat(32)}`,
      }),
    /precedes finalized receipt evidence/,
  );
  assert.throws(
    () => assertStateEvidenceAfterFinality(finalized, { number: 550n, hash: "0x1234" }),
    /state evidence block hash is missing/,
  );
});

test("a persisted state-evidence hash must become finalized without changing canonicality", () => {
  const state = { number: 550n, hash: `0x${"cd".repeat(32)}` };
  assert.equal(
    assertStateEvidenceFinalized(
      { number: 551n, hash: `0x${"ab".repeat(32)}` },
      state,
      { ...state },
    ),
    550n,
  );
  assert.throws(
    () =>
      assertStateEvidenceFinalized(
        { number: 549n, hash: `0x${"ab".repeat(32)}` },
        state,
        { ...state },
      ),
    /has not reached the state evidence block/,
  );
  assert.throws(
    () =>
      assertStateEvidenceFinalized(
        { number: 551n, hash: `0x${"ab".repeat(32)}` },
        state,
        { number: 550n, hash: `0x${"ef".repeat(32)}` },
      ),
    /not canonical after finalization/,
  );
});

test("house blueprint proof binds exact calldata, event, and pinned readback for all five", () => {
  assert.deepEqual(
    validateHouseBlueprintEvidence(blueprintFixture()),
    HOUSE_BLUEPRINTS.map(({ id, name }) => ({ id, name })),
  );
});

test("house blueprint proof rejects a changed calldata parameter", () => {
  const evidence = blueprintFixture();
  evidence.blueprints[1].calldata.params.guardBlocks = 99;
  assert.throws(
    () => validateHouseBlueprintEvidence(evidence),
    /calldata hook parameter guardBlocks is wrong/,
  );
});

test("house blueprint proof rejects a relabelled event", () => {
  const evidence = blueprintFixture();
  evidence.blueprints[3].event.name = "Not Surge Fees";
  assert.throws(
    () => validateHouseBlueprintEvidence(evidence),
    /event name is wrong/,
  );
});

test("house blueprint proof permits mutable use counts but rejects a wrong contract clock", () => {
  const used = blueprintFixture();
  used.blueprints[4].readback.uses = 12;
  assert.doesNotThrow(() => validateHouseBlueprintEvidence(used));

  const wrongBlock = blueprintFixture();
  wrongBlock.blueprints[0].readback.savedAtBlock += 1n;
  assert.throws(
    () => validateHouseBlueprintEvidence(wrongBlock),
    /savedAtBlock does not match its receipt block l1BlockNumber/,
  );
});

const canaryFixture = () => {
  const spec = INSTANT_CANARY_SPEC;
  const key = {
    currency0: "0x0000000000000000000000000000000000000000",
    currency1: addresses.token,
    fee: spec.dynamicFee,
    tickSpacing: spec.tickSpacing,
    hooks: addresses.hook,
  };
  const poolId = poolIdForKey(key);
  const hookParams = { ...spec.hookParams };
  const labels = [
    "launchpadLib",
    "launchpad",
    "hook",
    "router",
    "setHook",
    "blueprint#1",
    "blueprint#2",
    "blueprint#3",
    "blueprint#4",
    "blueprint#5",
    "canary:launch",
    "canary:buy",
    "canary:approve",
    "canary:sell",
  ];
  const receiptOrder = labels.map((label, i) => ({
    label,
    hash: `0x${(i + 1).toString(16).padStart(64, "0")}`,
    blockNumber: 100n + BigInt(i),
    transactionIndex: 0,
  }));
  const launchRpcBlock = receiptOrder[10].blockNumber;
  const launchBlock = 80n;
  const approvalAmount = 100_000n * 10n ** 18n;
  const instantEvent = {
    token: addresses.token,
    poolId,
    poolSupplyBps: spec.poolSupplyBps,
    openPriceWei: spec.openPriceWei,
    ethInPool: spec.depositWei - 121n,
  };
  const transaction = (to, value, blockNumber, contractBlockNumber) => ({
    from: addresses.deployer,
    to,
    value,
    blockNumber,
    ...(contractBlockNumber === undefined ? {} : { contractBlockNumber }),
  });

  return {
    receiptOrder,
    identities: { ...addresses, token: undefined },
    launch: {
      transaction: transaction(
        addresses.launchpad,
        spec.creationFeeWei + spec.depositWei,
        launchRpcBlock,
        launchBlock,
      ),
      calldata: {
        args: {
          name: spec.name,
          symbol: spec.symbol,
          tagline: spec.tagline,
          logoURI: "",
          expectedCreator: addresses.deployer,
          targetRaiseWei: 0n,
          blueprintId: 0,
          custom: hookParams,
          creatorBuyWei: spec.depositWei,
          minTokensOut: 0n,
          creatorFeeBps: 0,
          feeRecipients: [],
          lpTranches: [],
        },
        poolSupplyBps: spec.poolSupplyBps,
        intentId: spec.intentId,
      },
      event: instantEvent,
      tokenEvent: {
        token: addresses.token,
        creator: addresses.deployer,
        blueprintId: 0,
        name: spec.name,
        symbol: spec.symbol,
        tagline: spec.tagline,
        logoURI: "",
        targetWei: spec.depositWei,
        basePriceWei: spec.openPriceWei,
      },
      graduatedEvent: {
        token: addresses.token,
        poolId,
        sqrtPriceX96: 123_456n,
        ethLiquidity: instantEvent.ethInPool,
        tokenLiquidity: spec.poolTokens - 1n,
        tokensBurned: spec.poolTokens,
      },
      intentEvent: { creator: addresses.deployer, intentId: spec.intentId, token: addresses.token },
    },
    buy: {
      transaction: transaction(addresses.router, spec.buyWei, receiptOrder[11].blockNumber),
      calldata: {
        key: { ...key },
        zeroForOne: true,
        amountIn: spec.buyWei,
        amountOutMinimum: spec.buyMinTokensOut,
        sqrtPriceLimitX96: spec.minSqrtPriceLimitX96,
        recipient: addresses.deployer,
        deadline: 1_000n,
      },
      event: {
        payer: addresses.deployer,
        recipient: addresses.deployer,
        token: addresses.token,
        zeroForOne: true,
        exactInput: true,
        amountIn: spec.buyWei,
        amountOut: spec.buyMinTokensOut + 1n,
      },
      poolManagerEvent: {
        id: poolId,
        sender: addresses.router,
        amount0: -spec.buyWei,
        amount1: spec.buyMinTokensOut + 1n,
        sqrtPriceX96: 123_457n,
        liquidity: 1n,
        tick: 1,
        fee: 220_000,
      },
      hookEvents: {
        feesAccrued: {
          poolId,
          burnWei: 0n,
          lpWei: 2_500_000_000_000n,
          potWeiAdded: 5_000_000_000_000n,
          royaltyWei: 0n,
          royaltyTo: "0x0000000000000000000000000000000000000000",
        },
        lpDonation: { poolId, amountWei: 2_500_000_000_000n },
        autoBurn: { poolId, tokensBurned: 1n },
      },
    },
    approval: {
      transaction: transaction(addresses.token, 0n, receiptOrder[12].blockNumber),
      calldata: { spender: addresses.router, amount: approvalAmount },
      event: { owner: addresses.deployer, spender: addresses.router, value: approvalAmount },
    },
    sell: {
      transaction: transaction(addresses.router, 0n, receiptOrder[13].blockNumber),
      calldata: {
        key: { ...key },
        zeroForOne: false,
        amountIn: approvalAmount,
        amountOutMinimum: spec.sellMinWeiOut,
        sqrtPriceLimitX96: spec.maxSqrtPriceLimitX96,
        recipient: addresses.deployer,
        deadline: 1_000n,
      },
      event: {
        payer: addresses.deployer,
        recipient: addresses.deployer,
        token: addresses.token,
        zeroForOne: false,
        exactInput: true,
        amountIn: approvalAmount,
        amountOut: spec.sellMinWeiOut + 1n,
      },
    },
    postconditions: {
      creationFeeWei: spec.creationFeeWei,
      intentToken: addresses.token,
      launch: {
        token: addresses.token,
        creator: addresses.deployer,
        launchBlock,
        blueprintId: 0,
        graduated: true,
        basePriceWei: spec.openPriceWei,
        targetWei: spec.depositWei,
        reserveWei: 0n,
        soldTokens: 0n,
        graduatedAtBlock: launchBlock,
        sqrtPriceX96AtGraduation: 123_456n,
        poolId,
        hookParams,
      },
      preview: {
        tokensInPool: spec.poolTokens,
        openPriceWei: spec.openPriceWei,
        sqrtPriceX96: 123_456n,
        openFdvWei: spec.openFdvWei,
        err: 0,
      },
      hook: {
        config: {
          initialized: true,
          guardEndBlock: launchBlock + BigInt(spec.hookParams.guardBlocks),
          baseFeePips: spec.hookParams.baseFeePips,
          maxFeePips: spec.hookParams.maxFeePips,
          snipeTaxPips: spec.hookParams.snipeTaxPips,
          surgeSens: spec.hookParams.surgeSens,
          burnBps: spec.hookParams.burnBps,
          lpBps: spec.hookParams.lpBps,
          potBps: spec.hookParams.potBps,
          royaltyBps: 0,
          potEveryNBuys: spec.hookParams.potEveryNBuys,
          maxBuyWei: spec.buyWei,
          potMinBuyWei: spec.hookParams.potMinBuyWei,
          burnTriggerWei: 0n,
          royaltyTo: "0x0000000000000000000000000000000000000000",
          token: addresses.token,
        },
        ledgers: {
          guardLpEarnedWei: 250_000_000_000_000n,
          totalHookFeesWei: 7_500_000_000_000n,
          totalBurnedTokens: 1n,
          totalLpDonatedWei: 2_500_000_000_000n,
          potWei: 5_000_000_000_000n,
          potBuyCount: 1n,
          burnVaultWei: 0n,
          nativeClaimBalance: 5_000_000_000_000n,
        },
      },
      pool: { sqrtPriceX96: 123_457n, liquidity: 1n, lpFee: spec.hookParams.baseFeePips },
      tokenBalances: { creator: 1n, poolManager: 1n, dead: 1n, router: 0n, launchpad: 0n },
      tokenIdentity: {
        creator: addresses.deployer,
        launchpad: addresses.launchpad,
        totalSupply: spec.poolTokens * 2n,
        name: spec.name,
        symbol: spec.symbol,
        tagline: spec.tagline,
      },
      deadAddress: "0x000000000000000000000000000000000000dEaD",
      nativeBalances: { hook: 0n, router: 0n },
      poolManagerAddress: addresses.poolManager,
    },
  };
};

test("instant canary evidence binds all four transactions to one token, pool, and intent", () => {
  const evidence = canaryFixture();
  assert.deepEqual(validateInstantCanaryEvidence(evidence), {
    token: addresses.token,
    poolId: evidence.launch.event.poolId,
    intentId: INSTANT_CANARY_SPEC.intentId,
  });
});

test("instant canary evidence tolerates later permissionless pool and hook activity", () => {
  const evidence = canaryFixture();
  const ledgers = evidence.postconditions.hook.ledgers;
  ledgers.guardLpEarnedWei += 10n ** 18n;
  ledgers.totalHookFeesWei += 10n ** 18n;
  ledgers.totalBurnedTokens += 10n ** 18n;
  ledgers.totalLpDonatedWei += 10n ** 18n;
  ledgers.potBuyCount = 20n;
  ledgers.potWei = 0n;
  // This is hook-global and may include claims backing other public pools.
  ledgers.nativeClaimBalance = 10n ** 18n;
  assert.doesNotThrow(() => validateInstantCanaryEvidence(evidence));
});

test("instant canary evidence rejects relabelled or incomplete buy-scoped hook evidence", () => {
  const wrongPool = canaryFixture();
  wrongPool.buy.hookEvents.lpDonation.poolId = `0x${"12".repeat(32)}`;
  assert.throws(() => validateInstantCanaryEvidence(wrongPool), /LpRewardsDonated names the wrong/);

  const wrongCut = canaryFixture();
  wrongCut.buy.hookEvents.feesAccrued.potWeiAdded -= 1n;
  assert.throws(() => validateInstantCanaryEvidence(wrongCut), /pot cut is wrong/);

  const noSurge = canaryFixture();
  const noSurgeLpFee =
    INSTANT_CANARY_SPEC.hookParams.baseFeePips + INSTANT_CANARY_SPEC.hookParams.snipeTaxPips;
  // Maximum protocol fee (1000 pips) combined with the no-surge LP rate.
  noSurge.buy.poolManagerEvent.fee = 1_000 + noSurgeLpFee - Math.floor(noSurgeLpFee / 1_000);
  assert.throws(() => validateInstantCanaryEvidence(noSurge), /did not prove a surge fee/);

  const excessiveCombinedFee = canaryFixture();
  const maximumLpFee =
    INSTANT_CANARY_SPEC.hookParams.maxFeePips + INSTANT_CANARY_SPEC.hookParams.snipeTaxPips;
  excessiveCombinedFee.buy.poolManagerEvent.fee =
    1_001 + maximumLpFee - Math.floor((1_001 * maximumLpFee) / 1_000_000);
  assert.throws(
    () => validateInstantCanaryEvidence(excessiveCombinedFee),
    /exceeds the configured maximum/,
  );
});

test("instant canary evidence rejects a wrong pool", () => {
  const evidence = canaryFixture();
  evidence.sell.calldata.key.tickSpacing = 120;
  assert.throws(() => validateInstantCanaryEvidence(evidence), /tick spacing|pool key/);
});

test("instant canary evidence rejects a wrong token", () => {
  const evidence = canaryFixture();
  evidence.approval.transaction.to = "0x7777777777777777777777777777777777777777";
  assert.throws(() => validateInstantCanaryEvidence(evidence), /token approval target is wrong/);
});

test("instant canary evidence rejects a wrong intent", () => {
  const evidence = canaryFixture();
  evidence.launch.calldata.intentId = `0x${"12".repeat(32)}`;
  assert.throws(() => validateInstantCanaryEvidence(evidence), /intent is wrong/);
});

test("instant canary evidence rejects receipts mined out of order", () => {
  const evidence = canaryFixture();
  evidence.receiptOrder[12].blockNumber = evidence.receiptOrder[10].blockNumber;
  assert.throws(() => validateInstantCanaryEvidence(evidence), /not mined strictly after/);
});
