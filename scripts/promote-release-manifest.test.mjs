import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { getCreate2Address, keccak256, toFunctionSelector, toHex } from "viem";

import {
  INSTANT_CANARY_SPEC,
  poolIdForKey,
  validateInstantCanaryEvidence,
} from "./lib/instant-canary-evidence.mjs";
import { V5_CANARY_SPEC } from "./lib/v5-canary-evidence.mjs";
import {
  assertRetainedReleaseHistoryPreserved,
  replaceCurrentReleaseManifest,
  retireAndReplaceCurrentReleaseManifest,
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
        generation4.replace(
          'launchModes: ["curve", "instant"]',
          'launchModes: ["curve"]',
        ),
      ),
    /refusing to replace expanded current release v4/,
  );
});

test("promotion fails closed when the current assignment is missing or ambiguous", () => {
  assert.throws(
    () => replaceCurrentReleaseManifest(retained, generation4),
    /found 0/,
  );
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
  assert.doesNotThrow(() =>
    assertRetainedReleaseHistoryPreserved(source, source),
  );
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

const generation5 = `export const CURRENT_RELEASE_MANIFEST = {
  version: 5,
  capabilities: { launchModes: ["instant", "bonded"] },
  evidence: { canaryReceipts: { kind: "instant_and_auction_round_trip_v5" } },
} as const satisfies HookrReleaseManifest;`;

test("a retiring promotion retains the expanded v4 verbatim and registers it after CURRENT", () => {
  const source = releaseSource(generation4);
  const patched = retireAndReplaceCurrentReleaseManifest(source, generation5);

  const retainedGen4 = generation4.replace(
    "export const CURRENT_RELEASE_MANIFEST =",
    "export const RETAINED_GENERATION_4_MANIFEST =",
  );
  assert.ok(
    patched.includes(retained),
    "generation 3 history must survive untouched",
  );
  assert.ok(
    patched.includes(retainedGen4),
    "generation 4 must be retained byte-for-byte",
  );
  assert.ok(patched.includes(generation5), "generation 5 must become CURRENT");
  assert.equal(
    patched.match(/export const CURRENT_RELEASE_MANIFEST =/g)?.length,
    1,
  );
  assert.ok(
    patched.includes(
      "createReleaseRegistry([\n    CURRENT_RELEASE_MANIFEST,\n    RETAINED_GENERATION_4_MANIFEST,\n    RETAINED_GENERATION_3_MANIFEST,\n",
    ),
    "READ_RELEASES must list v4 newest-first directly after CURRENT",
  );
  // The retained literal precedes the new CURRENT, so the alias-era invariants keep holding.
  assert.ok(patched.indexOf(retainedGen4) < patched.indexOf(generation5));
});

test("a retiring promotion accepts an exact re-run as a no-op and nothing else", () => {
  const source = releaseSource(generation4);
  const patched = retireAndReplaceCurrentReleaseManifest(source, generation5);
  assert.equal(
    retireAndReplaceCurrentReleaseManifest(patched, generation5),
    patched,
  );
  assert.throws(
    () =>
      retireAndReplaceCurrentReleaseManifest(
        patched,
        generation5.replace(
          'launchModes: ["instant", "bonded"]',
          'launchModes: ["instant"]',
        ),
      ),
    /refusing to retain the current release twice|advance exactly one generation/,
  );
});

test("a retiring promotion fails closed on version skips, aliases, and duplicate retention", () => {
  const source = releaseSource(generation4);
  assert.throws(
    () =>
      retireAndReplaceCurrentReleaseManifest(
        source,
        generation5.replace("version: 5", "version: 6"),
      ),
    /advance exactly one generation/,
  );
  assert.throws(
    () =>
      retireAndReplaceCurrentReleaseManifest(
        releaseSource(
          "export const CURRENT_RELEASE_MANIFEST = RETAINED_GENERATION_3_MANIFEST;",
        ),
        generation4,
      ),
    /use replaceCurrentReleaseManifest/,
  );
  const alreadyRetained = releaseSource(generation4).replace(
    retained,
    `${retained}\nexport const RETAINED_GENERATION_4_MANIFEST = {\n  version: 4,\n} as const satisfies HookrReleaseManifest;`,
  );
  assert.throws(
    () => retireAndReplaceCurrentReleaseManifest(alreadyRetained, generation5),
    /refusing to retain the current release twice/,
  );
});

test("the initial retained alias can advance exactly one generation only", () => {
  const source = releaseSource(
    "export const CURRENT_RELEASE_MANIFEST = RETAINED_GENERATION_3_MANIFEST;",
  );
  assert.throws(
    () =>
      replaceCurrentReleaseManifest(
        source,
        generation4.replace("version: 4", "version: 3"),
      ),
    /advance exactly one generation/,
  );
  assert.throws(
    () =>
      replaceCurrentReleaseManifest(
        source,
        generation4.replace("version: 4", "version: 5"),
      ),
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
  return (
    runtime.slice(0, start * 2) + value + runtime.slice((start + length) * 2)
  );
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
        optimizer: {
          enabled: true,
          runs: REVIEWED_COMPILER_SETTINGS.optimizerRuns,
        },
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
        123: [
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

const linkedRuntimeFixture = (
  artifact,
  immutableAddress = addresses.poolManager,
) => {
  let live = artifact.deployedBytecode.object;
  const immutableWord = `${"0".repeat(24)}${immutableAddress.slice(2).toLowerCase()}`;
  live = replaceRuntimeBytes(live, 8, 32, immutableWord);
  live = replaceRuntimeBytes(live, 80, 32, immutableWord);
  live = replaceRuntimeBytes(
    live,
    45,
    20,
    addresses.hook.slice(2).toLowerCase(),
  );
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
    999999: renumbered.deployedBytecode.immutableReferences["123"],
  };
  assert.equal(
    deriveRuntimeReferenceLayoutHash(renumbered),
    referenceLayoutHash,
  );

  const split = structuredClone(artifact);
  const [first, second] = split.deployedBytecode.immutableReferences["123"];
  split.deployedBytecode.immutableReferences = {
    1: [first],
    2: [second],
  };
  assert.notEqual(deriveRuntimeReferenceLayoutHash(split), referenceLayoutHash);
});

test("reviewed runtime proof rejects stale sources, wrong constructor values, and changed code", () => {
  const { artifact, normalizedTemplateHash, referenceLayoutHash } =
    runtimeArtifactFixture();
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
  const expected = getCreate2Address({
    from: factory,
    salt,
    bytecode: initCode,
  });
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
    () =>
      assertStateEvidenceAfterFinality(finalized, {
        number: 550n,
        hash: "0x1234",
      }),
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
      intentEvent: {
        creator: addresses.deployer,
        intentId: spec.intentId,
        token: addresses.token,
      },
    },
    buy: {
      transaction: transaction(
        addresses.router,
        spec.buyWei,
        receiptOrder[11].blockNumber,
      ),
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
      transaction: transaction(
        addresses.token,
        0n,
        receiptOrder[12].blockNumber,
      ),
      calldata: { spender: addresses.router, amount: approvalAmount },
      event: {
        owner: addresses.deployer,
        spender: addresses.router,
        value: approvalAmount,
      },
    },
    sell: {
      transaction: transaction(
        addresses.router,
        0n,
        receiptOrder[13].blockNumber,
      ),
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
      pool: {
        sqrtPriceX96: 123_457n,
        liquidity: 1n,
        lpFee: spec.hookParams.baseFeePips,
      },
      tokenBalances: {
        creator: 1n,
        poolManager: 1n,
        dead: 1n,
        router: 0n,
        launchpad: 0n,
      },
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
  assert.throws(
    () => validateInstantCanaryEvidence(wrongPool),
    /LpRewardsDonated names the wrong/,
  );

  const wrongCut = canaryFixture();
  wrongCut.buy.hookEvents.feesAccrued.potWeiAdded -= 1n;
  assert.throws(
    () => validateInstantCanaryEvidence(wrongCut),
    /pot cut is wrong/,
  );

  const noSurge = canaryFixture();
  const noSurgeLpFee =
    INSTANT_CANARY_SPEC.hookParams.baseFeePips +
    INSTANT_CANARY_SPEC.hookParams.snipeTaxPips;
  // Maximum protocol fee (1000 pips) combined with the no-surge LP rate.
  noSurge.buy.poolManagerEvent.fee =
    1_000 + noSurgeLpFee - Math.floor(noSurgeLpFee / 1_000);
  assert.throws(
    () => validateInstantCanaryEvidence(noSurge),
    /did not prove a surge fee/,
  );

  const excessiveCombinedFee = canaryFixture();
  const maximumLpFee =
    INSTANT_CANARY_SPEC.hookParams.maxFeePips +
    INSTANT_CANARY_SPEC.hookParams.snipeTaxPips;
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
  assert.throws(
    () => validateInstantCanaryEvidence(evidence),
    /tick spacing|pool key/,
  );
});

test("instant canary evidence rejects a wrong token", () => {
  const evidence = canaryFixture();
  evidence.approval.transaction.to =
    "0x7777777777777777777777777777777777777777";
  assert.throws(
    () => validateInstantCanaryEvidence(evidence),
    /token approval target is wrong/,
  );
});

test("instant canary evidence rejects a wrong intent", () => {
  const evidence = canaryFixture();
  evidence.launch.calldata.intentId = `0x${"12".repeat(32)}`;
  assert.throws(
    () => validateInstantCanaryEvidence(evidence),
    /intent is wrong/,
  );
});

test("instant canary evidence rejects receipts mined out of order", () => {
  const evidence = canaryFixture();
  evidence.receiptOrder[12].blockNumber = evidence.receiptOrder[10].blockNumber;
  assert.throws(
    () => validateInstantCanaryEvidence(evidence),
    /not mined strictly after/,
  );
});

/* ------------------------------------------------- generation-5 promotion wiring
   promote-release-manifest.mjs is a broadcast-consuming entrypoint, not an importable module, so
   these assertions pin its release-defining constants at the source level: artifact names, the
   staged canary layout, the canary action references, the CCA factory guard, and the v5 identity.
   Each one is a value a wrong merge could silently regress to generation 4. */
const promotionSource = readFileSync(
  new URL("./promote-release-manifest.mjs", import.meta.url),
  "utf8",
);
const escapeRegex = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const whitespaceTolerantSourcePattern = (needle) => {
  const tokens = [];
  for (let index = 0; index < needle.length;) {
    const character = needle[index];
    if (/\s/.test(character)) {
      index += 1;
      continue;
    }
    if (character === '"' || character === "'" || character === "`") {
      const quote = character;
      let token = character;
      index += 1;
      let escaped = false;
      while (index < needle.length) {
        const current = needle[index];
        token += current;
        index += 1;
        if (escaped) escaped = false;
        else if (current === "\\") escaped = true;
        else if (current === quote) break;
      }
      tokens.push(token);
      continue;
    }
    if (/[A-Za-z0-9_$]/.test(character)) {
      let token = character;
      index += 1;
      while (index < needle.length && /[A-Za-z0-9_$]/.test(needle[index])) {
        token += needle[index];
        index += 1;
      }
      tokens.push(token);
      continue;
    }
    tokens.push(character);
    index += 1;
  }
  const pattern = tokens
    .map((token, index) => {
      const optionalTrailingComma =
        index > 0 &&
        [")", "]", "}"].includes(token) &&
        tokens[index - 1] !== ","
          ? "(?:,\\s*)?"
          : "";
      return `${optionalTrailingComma}${escapeRegex(token)}`;
    })
    .join("\\s*");
  return new RegExp(pattern, "s");
};
const sourceIncludes = (source, needle) =>
  whitespaceTolerantSourcePattern(needle).test(source);
const sourceIndex = (source, needle, fromIndex = 0) => {
  const match = whitespaceTolerantSourcePattern(needle).exec(
    source.slice(fromIndex),
  );
  return match ? fromIndex + match.index : -1;
};
const preflightSource = readFileSync(
  new URL("./verify-deployment-preflight.mjs", import.meta.url),
  "utf8",
);
const canaryOperatorSource = readFileSync(
  new URL("../contracts/script/CanaryRobinhoodV5.s.sol", import.meta.url),
  "utf8",
);
const canaryWrapperSource = readFileSync(
  new URL("../contracts/run-canary-v5.sh", import.meta.url),
  "utf8",
);
const phaseAIndexSource = readFileSync(
  new URL("./build-v5-phase-a-index.mjs", import.meta.url),
  "utf8",
);

test("v5 staged canary authenticates Robinhood ArbSys before every Forge broadcast", () => {
  assert.ok(canaryOperatorSource.includes('keccak256(hex"fe")'));
  assert.ok(
    canaryOperatorSource.includes(
      'require(block.chainid == 4663, "wrong chain")',
    ),
  );
  assert.ok(
    canaryOperatorSource.includes(
      'require(currentCodehash == ROBINHOOD_ARBSYS_MARKER_CODEHASH, "ArbSys marker wrong")',
    ),
  );
  assert.ok(
    canaryOperatorSource.includes(
      'vm.envOr("HOOKR_CANARY_ALLOW_PREINSTALLED_ARBSYS_SHIM", false)',
    ),
  );
  assert.ok(
    canaryOperatorSource.includes('"preinstalled ArbSys shim forbidden"'),
  );
  assert.ok(
    canaryOperatorSource.includes('vm.etch(ARBSYS, hex"4360005260206000f3")'),
  );
  assert.ok(
    canaryOperatorSource.includes(
      "ARBSYS.codehash == ARBSYS_SIMULATION_SHIM_CODEHASH",
    ),
  );
  assert.ok(
    canaryOperatorSource.includes(
      "abi.decode(result, (uint256)) == block.number",
    ),
  );
  for (const signature of [
    "function openInstant() external",
    "function buyInstantLaunchAuction() external",
    "function launchHookrPair() external",
    "function buyHookrPair() external",
  ]) {
    const start = canaryOperatorSource.indexOf(signature);
    const body = canaryOperatorSource.slice(
      start,
      canaryOperatorSource.indexOf("vm.stopBroadcast()", start),
    );
    assert.ok(start >= 0, `${signature} is missing`);
    assert.ok(
      body.indexOf("_installArbSysSimulationShim();") <
        body.indexOf("vm.startBroadcast(me);"),
      `${signature} must install the local shim before broadcasting`,
    );
  }
  assert.ok(
    canaryWrapperSource.includes("--broadcast --slow --skip-simulation"),
  );
  assert.ok(
    canaryWrapperSource.includes(
      'env_args+=("HOOKR_CANARY_ALLOW_PREINSTALLED_ARBSYS_SHIM=true")',
    ),
  );
  assert.ok(
    canaryWrapperSource.includes(
      "unset HOOKR_CANARY_ALLOW_PREINSTALLED_ARBSYS_SHIM",
    ),
  );
  assert.ok(
    !canaryWrapperSource.includes(
      "HOOKR_CANARY_ALLOW_PREINSTALLED_ARBSYS_SHIM=false",
    ),
  );
  assert.ok(canaryWrapperSource.includes("Never use forge --resume"));
  assert.doesNotMatch(canaryWrapperSource, /forge script[^\n]*--resume/);
  assert.ok(
    canaryWrapperSource.includes(
      "ArbSys shim must never enter the broadcast transaction list",
    ),
  );
  assert.ok(canaryOperatorSource.includes('vm.envAddress("CANARY_AUCTION")'));
  assert.doesNotMatch(canaryOperatorSource, /submitBid\s*\(/);
  assert.ok(
    canaryOperatorSource.includes("This recovery artifact can never bid"),
  );
  const openStart = canaryOperatorSource.indexOf(
    "function openInstant() external",
  );
  const openEnd = canaryOperatorSource.indexOf(
    "function buyInstantLaunchAuction() external",
  );
  assert.ok(
    !canaryOperatorSource.slice(openStart, openEnd).includes("submitBid"),
  );
});

test("v5 phase A stages four raw Forge artifacts around finalized timing evidence", () => {
  for (const value of [
    "openInstant-latest.json",
    "buyInstantLaunchAuction-latest.json",
    "owner-bid-transaction.json",
    "owner-bid-receipt.json",
    "launchHookrPair-latest.json",
    "buyHookrPair-latest.json",
    "timing-shorten-transaction.json",
    "timing-shorten-receipt.json",
    "timing-restore-transaction.json",
    "timing-restore-receipt.json",
    "phase-a-evidence-v5.json",
  ]) {
    assert.ok(canaryWrapperSource.includes(value));
  }
  const promoteStart = canaryWrapperSource.indexOf("run_promote_dry_run() {");
  const promoteEnd = canaryWrapperSource.indexOf("\n}", promoteStart);
  const promoteBody = canaryWrapperSource.slice(promoteStart, promoteEnd);
  for (const flag of [
    "--canary-timing-shorten-transaction",
    "--canary-timing-shorten-receipt",
    "--canary-timing-restore-transaction",
    "--canary-timing-restore-receipt",
    "--canary-owner-bid-transaction",
    "--canary-owner-bid-receipt",
    "--canary-hookr-launch",
    "--canary-phase-b-index",
  ]) {
    assert.ok(promoteBody.includes(flag), `promote-dry-run is missing ${flag}`);
  }
  assert.ok(canaryWrapperSource.includes('export ETH_RPC_URL="$RPC"'));
  assert.ok(
    !promoteBody.includes('--rpc "$RPC"'),
    "promoter RPC must stay out of argv",
  );
  const phaseACase = canaryWrapperSource.indexOf("  phase-a)");
  const openForge = canaryWrapperSource.indexOf(
    "forge_phase 'openInstant()'",
    phaseACase,
  );
  const openFinalized = canaryWrapperSource.indexOf(
    'wait_receipts_finalized "$PHASE_A_INSTANT_LAUNCH_ABS"',
    openForge,
  );
  const shorten = canaryWrapperSource.indexOf(
    'send_timing "$CANARY_AUCTION_DURATION" "$SHORTEN_RECEIPT_ABS"',
    openFinalized,
  );
  const launchAuctionForge = canaryWrapperSource.indexOf(
    "forge_phase 'buyInstantLaunchAuction()'",
    shorten,
  );
  const restore = canaryWrapperSource.indexOf(
    'send_timing 125000 "$RESTORE_RECEIPT_ABS"',
    launchAuctionForge,
  );
  const restoredFinalized = canaryWrapperSource.indexOf(
    'wait_receipts_finalized "$RESTORE_RECEIPT_ABS"',
    restore,
  );
  const ownerBidCheck = canaryWrapperSource.indexOf(
    'owner_bid_receipt_check "$PHASE_A_OWNER_BID_TRANSACTION_ABS" "$PHASE_A_OWNER_BID_RECEIPT_ABS"',
    restoredFinalized,
  );
  const ownerBidFinalized = canaryWrapperSource.indexOf(
    'wait_owner_bid_finalized "$PHASE_A_OWNER_BID_TRANSACTION_ABS" "$PHASE_A_OWNER_BID_RECEIPT_ABS"',
    ownerBidCheck,
  );
  const hookrLaunchForge = canaryWrapperSource.indexOf(
    "forge_phase 'launchHookrPair()'",
    ownerBidFinalized,
  );
  const hookrFinalized = canaryWrapperSource.indexOf(
    'wait_receipts_finalized "$PHASE_A_HOOKR_LAUNCH_ABS"',
    hookrLaunchForge,
  );
  const hookrBuyForge = canaryWrapperSource.indexOf(
    "forge_phase 'buyHookrPair()'",
    hookrFinalized,
  );
  const finalStageFinalized = canaryWrapperSource.indexOf(
    'wait_receipts_finalized "$PHASE_A_HOOKR_APPROVE_BUY_ABS"',
    hookrBuyForge,
  );
  const indexWrite = canaryWrapperSource.indexOf(
    "phase_a_index write",
    finalStageFinalized,
  );
  assert.ok(
    phaseACase >= 0 &&
      phaseACase < openForge &&
      openForge < openFinalized &&
      openFinalized < shorten &&
      shorten < launchAuctionForge &&
      launchAuctionForge < restore &&
      restore < restoredFinalized &&
      restoredFinalized < ownerBidCheck &&
      ownerBidCheck < ownerBidFinalized &&
      ownerBidFinalized < hookrLaunchForge &&
      hookrLaunchForge < hookrFinalized &&
      hookrFinalized < hookrBuyForge &&
      hookrBuyForge < finalStageFinalized &&
      finalStageFinalized < indexWrite,
  );
  assert.ok(canaryWrapperSource.includes('verify_live_receipts "$path"'));
  const phaseAGuard = canaryWrapperSource.indexOf(
    "trap phase_a_exit_guard EXIT",
  );
  const phaseAGuardClear = canaryWrapperSource.indexOf(
    "trap - EXIT",
    phaseAGuard,
  );
  assert.ok(phaseAGuard >= 0 && phaseAGuard < openForge);
  assert.ok(phaseAGuardClear > indexWrite);
  assert.ok(canaryWrapperSource.includes("IMMEDIATE RESTORE REQUIRED:"));
  assert.match(
    canaryWrapperSource,
    /partial\/pending evidence is a manual hard stop/i,
  );
  assert.ok(
    phaseAIndexSource.includes('const KIND = "hookr-v5-phase-a-evidence-v3"'),
  );
  assert.ok(phaseAIndexSource.includes("evidencePolicy: POLICY"));
  for (const artifact of [
    'artifact: "instantLaunch"',
    'artifact: "instantBuyAuctionLaunch"',
    'artifact: "ownerBid"',
    'artifact: "hookrLaunch"',
    'artifact: "hookrApproveBuy"',
    'artifact: "shorten"',
    'artifact: "restore"',
  ])
    assert.ok(phaseAIndexSource.includes(artifact));
  assert.ok(
    phaseAIndexSource.includes(
      "transaction nonces are not consecutive across raw Forge and transaction/receipt evidence",
    ),
  );
  assert.ok(
    phaseAIndexSource.includes("calldata: pair.calldata.toLowerCase()"),
  );
});

test("v5 canary evidence keeps deployment and operator provenance distinct", () => {
  assert.ok(canaryWrapperSource.includes('kind: "hookr-v5-canary-target-v2"'));
  assert.ok(canaryWrapperSource.includes("deploymentSourceCommit"));
  assert.ok(canaryWrapperSource.includes("canaryOperatorCommit"));
  for (const source of [preflightSource, promotionSource]) {
    assert.ok(source.includes('"contracts/src"'));
    assert.ok(source.includes('"contracts/lib"'));
    assert.ok(source.includes('"contracts/foundry.toml"'));
    assert.ok(source.includes('"contracts/script/DeployRobinhoodV5.s.sol"'));
    assert.ok(source.includes('"scripts/build-v5-phase-a-index.mjs"'));
    assert.ok(source.includes('"merge-base", "--is-ancestor"'));
  }
  assert.ok(
    promotionSource.includes('canaryOperatorCommit: "${canaryOperatorCommit}"'),
  );
  assert.ok(
    promotionSource.includes('canaryRecoveryCommit: "${canaryRecoveryCommit}"'),
  );
  assert.ok(
    promotionSource.includes(
      'canaryPhaseAIndexSha256: "${phaseAIndexSnapshot.sha256}"',
    ),
  );
  assert.ok(
    promotionSource.includes(
      'canaryPhaseBIndexSha256: "${phaseBIndexSnapshot.sha256}"',
    ),
  );
  assert.ok(promotionSource.includes('"contracts/run-canary-v5.sh"'));
  assert.ok(
    promotionSource.includes('"scripts/collect-v5-phase-b-evidence.mjs"'),
  );
  assert.ok(
    promotionSource.includes('"scripts/build-v5-phase-b-evidence.mjs"'),
  );
  assert.ok(
    promotionSource.includes('"contracts/script/CanaryRobinhoodV5.s.sol"'),
  );
});

test("v5 promotion consumes Phase A plus six canonical Phase-B action references", () => {
  assert.match(
    promotionSource,
    /const RPC =\s*process\.env\.HOOKR_RPC_URL \|\|\s*process\.env\.ETH_RPC_URL \|\|\s*"https:\/\/rpc\.mainnet\.chain\.robinhood\.com";/,
    "authenticated RPC endpoints must come from the environment instead of argv",
  );
  assert.ok(!promotionSource.includes('flag("rpc"'));
  assert.ok(!promotionSource.includes("[--rpc URL]"));
  assert.ok(
    promotionSource.includes(
      'argument === "--rpc" || argument.startsWith("--rpc=")',
    ),
    "both --rpc forms must fail before parsing any other input",
  );
  assert.ok(!promotionSource.includes("is not a valid URL: ${RPC}"));
  assert.ok(!promotionSource.includes("non-https RPC (${RPC})"));
  assert.ok(promotionSource.includes("redactConfiguredRpc(msg, RPC)"));
  assert.ok(
    promotionSource.includes('process.on("uncaughtException", failUnexpected)'),
  );
  assert.ok(
    promotionSource.includes(
      'process.on("unhandledRejection", failUnexpected)',
    ),
  );
  assert.ok(
    promotionSource.includes(
      "contracts/out/HookrLaunchpadV5.sol/HookrLaunchpadV5.json",
    ),
  );
  assert.ok(
    promotionSource.includes(
      "contracts/out/HookrLaunchpadLibV5.sol/HookrLaunchpadLibV5.json",
    ),
  );
  assert.ok(promotionSource.includes('sourcePath: "src/HookrLaunchpadV5.sol"'));
  assert.ok(
    promotionSource.includes(
      'sourcePath: "src/libraries/HookrLaunchpadLibV5.sol"',
    ),
  );
  assert.ok(
    promotionSource.includes(
      "contracts/broadcast/DeployRobinhoodV5.s.sol/4663/run-latest.json",
    ),
  );
  for (const path of [
    "openInstant-latest.json",
    "buyInstantLaunchAuction-latest.json",
    "owner-bid-transaction.json",
    "owner-bid-receipt.json",
    "launchHookrPair-latest.json",
    "buyHookrPair-latest.json",
    "timing-shorten-transaction.json",
    "timing-shorten-receipt.json",
    "timing-restore-transaction.json",
    "timing-restore-receipt.json",
  ])
    assert.ok(promotionSource.includes(path), `promotion is missing ${path}`);
  assert.ok(promotionSource.includes("phase-a-evidence-v5.json"));
  assert.ok(
    promotionSource.includes(
      "contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/phase-b-evidence-v5.json",
    ),
    "the six-action Phase-B evidence index must be loaded alongside Phase A",
  );
  assert.ok(!promotionSource.includes("settle-latest.json"));
  assert.ok(
    promotionSource.includes(
      '{ type: "CREATE2", name: "HookrLaunchpadLibV5" }',
    ),
  );
  assert.ok(
    promotionSource.includes('{ type: "CREATE", name: "HookrFlywheelBurner" }'),
    "the flywheel burner must be deploy tx #1 (the hook takes it as a constructor immutable)",
  );
  assert.ok(
    promotionSource.includes('{ type: "CREATE", name: "HookrLaunchpadV5" }'),
  );
  assert.ok(promotionSource.includes("assertV5PhaseAIndex(canaryPhaseAIndex"));
  assert.ok(
    promotionSource.includes("assertV5PhaseBEvidence(canaryPhaseBIndex"),
  );
  assert.ok(promotionSource.includes("V5_PHASE_B_ACTIONS.map"));
  assert.ok(promotionSource.includes("raw.transactionSha256"));
  assert.ok(promotionSource.includes("raw.receiptSha256"));
  assert.ok(promotionSource.includes("repoEvidencePath("));
  assert.ok(
    promotionSource.includes(
      "Phase-B accrual identity differs from the authenticated Phase-A",
    ),
  );
  assert.ok(
    promotionSource.includes("const canonicalAuctionPoolId = poolIdForKey({"),
  );
  assert.ok(promotionSource.includes('method: "eth_getTransactionReceipt"'));
  assert.ok(
    promotionSource.includes(
      "assertRawReceiptMatchesLive(rawReceipt, liveRawReceipt",
    ),
  );
  assert.ok(
    promotionSource.includes(
      "persisted raw transaction differs from live RPC evidence",
    ),
  );
  assert.ok(promotionSource.includes("onchainReceiptOrder.sort("));
  assert.ok(sourceIncludes(promotionSource, "decodeCall(auctionBidRecord"));
  assert.ok(promotionSource.includes("canaryTimingShortenTransaction"));
  assert.ok(promotionSource.includes("canaryTimingRestoreReceipt"));
});

test("v5 promotion permits gas omission only for explicit unlocked Forge records", () => {
  const bindingStart = promotionSource.indexOf(
    "const rawCanaryPair = CANARY_RAW_PAIR_BY_LABEL.get(label);",
  );
  const bindingEnd = promotionSource.indexOf(
    "assertRawReceiptMatchesLive(rawReceipt, liveRawReceipt",
    bindingStart,
  );
  const binding = promotionSource.slice(bindingStart, bindingEnd);
  assert.ok(bindingStart >= 0 && bindingEnd > bindingStart);
  assert.ok(sourceIncludes(binding, 'Object.hasOwn(rawTx.transaction, "gas")'));
  assert.ok(
    sourceIncludes(
      binding,
      '!Object.hasOwn(rawTx.transaction, "gas") && rawTx.isFixedGasLimit !== false',
    ),
  );
  assert.ok(
    sourceIncludes(
      binding,
      "BigInt(rawTx.transaction.gas) !== BigInt(transaction.gas)",
    ),
  );

  const gasMatches = (rawTransaction, isFixedGasLimit, liveGas) =>
    Object.hasOwn(rawTransaction, "gas")
      ? BigInt(rawTransaction.gas) === BigInt(liveGas)
      : isFixedGasLimit === false;
  assert.equal(
    gasMatches({}, false, 500_000n),
    true,
    "the exact unlocked Forge omission must be accepted",
  );
  assert.equal(gasMatches({}, true, 500_000n), false);
  assert.equal(gasMatches({}, undefined, 500_000n), false);
  assert.equal(gasMatches({ gas: "500000" }, false, 500_000n), true);
  assert.equal(gasMatches({ gas: "500000" }, true, 500_000n), true);
  assert.equal(
    gasMatches({ gas: "500001" }, false, 500_000n),
    false,
    "present gas mutation must fail even for an unlocked record",
  );
  assert.equal(gasMatches({ gas: "500001" }, true, 500_000n), false);

  for (const mandatoryBinding of [
    "!sameHex(rawTx.hash, hash)",
    "!sameHex(rawReceipt.transactionHash, hash)",
    "!sameHex(transaction.hash, hash)",
    "!sameHex(rawTx.transaction.input, transaction.input)",
    "!sameHex(rawTx.transaction.from, transaction.from)",
    "!rawTx.transaction.to",
    "!transaction.to",
    "!sameHex(rawTx.transaction.to, transaction.to)",
    "BigInt(rawTx.transaction.value ?? 0) !== transaction.value",
    "BigInt(rawTx.transaction.nonce) !== BigInt(transaction.nonce)",
    "BigInt(rawTx.transaction.chainId) !== BigInt(transaction.chainId)",
  ]) {
    assert.ok(
      sourceIncludes(binding, mandatoryBinding),
      `raw binding weakened: ${mandatoryBinding}`,
    );
  }
});

test("v5 promotion pins the v5 identity, the CCA factory, and the scalar immutable words", () => {
  assert.ok(
    sourceIncludes(promotionSource, '"HookrLaunchpadV5", "launchpad identity"'),
  );
  assert.ok(sourceIncludes(promotionSource, '"5.0.1", "launchpad version"'));
  assert.ok(
    sourceIncludes(
      promotionSource,
      'getAddress("0x000000001F26a0044BaA66024e7b6599c61963F8")',
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      '"0xa1d2a90564f4f63580b25de42efaff92505c254b00fc666f65ab38126cce5cfa"',
    ),
    "AUCTION_FACTORY runtime codehash guard is missing",
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      "expectedImmutableAddresses: [POOL_MANAGER, AUCTION_FACTORY, HOOKR_TOKEN]",
    ),
    "the launchpad's three address immutables must include the HOOKR quote token",
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      "expectedImmutableAddresses: [POOL_MANAGER, launchpad, burner]",
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      "expectedImmutableAddresses: [POOL_MANAGER, hook, HOOKR_TOKEN]",
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      'getAddress("0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c")',
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      "expectedImmutableWords: [...LAUNCHPAD_IMMUTABLE_WORDS]",
    ),
  );
  // The launchpad + library must be proven against the V5 anchors (the un-suffixed keys retain
  // the generation-4 build), matching the preflight's keys.
  assert.ok(
    sourceIncludes(
      promotionSource,
      "REVIEWED_NORMALIZED_RUNTIME_HASHES.launchpadV5",
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      "REVIEWED_NORMALIZED_RUNTIME_HASHES.launchpadLibV5",
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      "REVIEWED_NORMALIZED_RUNTIME_HASHES.hookV5",
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      "REVIEWED_NORMALIZED_RUNTIME_HASHES.routerV5",
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      "REVIEWED_NORMALIZED_RUNTIME_HASHES.burnerV5",
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      "REVIEWED_RUNTIME_REFERENCE_LAYOUT_HASHES.launchpadV5",
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      "REVIEWED_RUNTIME_REFERENCE_LAYOUT_HASHES.launchpadLibV5",
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      "REVIEWED_RUNTIME_REFERENCE_LAYOUT_HASHES.hookV5",
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      "REVIEWED_RUNTIME_REFERENCE_LAYOUT_HASHES.routerV5",
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      "REVIEWED_RUNTIME_REFERENCE_LAYOUT_HASHES.burnerV5",
    ),
  );
  // The arithmetically checkable scalar words: the 2.5 ether ETH FDV with its 2.5 gwei open
  // price, and the 2,500,000 HOOKR FDV with its 2.5e15 open price.
  assert.ok(
    promotionSource.includes(toHex(2_500_000_000_000_000_000n, { size: 32 })),
  );
  assert.ok(promotionSource.includes(toHex(2_500_000_000n, { size: 32 })));
  assert.ok(
    promotionSource.includes(toHex(2_500_000n * 10n ** 18n, { size: 32 })),
  );
  assert.ok(
    promotionSource.includes(toHex(2_500_000_000_000_000n, { size: 32 })),
  );
  // Five ETH instant words and five HOOKR instant words (the eleventh, useArbSysClock, carries
  // its own multi-line comment).
  assert.equal(
    (promotionSource.match(/^ {2}"0x[0-9a-f]{64}", \/\/ instant/gm) ?? [])
      .length,
    5,
  );
  assert.equal(
    (promotionSource.match(/^ {2}"0x[0-9a-f]{64}", \/\/ hookr/gm) ?? []).length,
    5,
  );
});

test("v5 promotion requires the exact restored production configuration", () => {
  assert.ok(
    promotionSource.includes(
      "const PRODUCTION_AUCTION_DURATION_BLOCKS = 125_000n;",
    ),
  );
  assert.ok(
    promotionSource.includes("const PRODUCTION_CLAIM_DELAY_BLOCKS = 0n;"),
  );
  assert.ok(
    promotionSource.includes("const PRODUCTION_MIGRATION_DELAY_BLOCKS = 1n;"),
  );
  assert.ok(
    promotionSource.includes(
      "const REVIEWED_CREATION_FEE_WEI = 200_000_000_000_000n;",
    ),
  );
  assert.ok(
    promotionSource.includes(
      "const REVIEWED_MAX_BUYBACK_WEI = 250_000_000_000_000_000n;",
    ),
  );
  assert.ok(
    promotionSource.includes(
      '"launchpad production auction duration restored"',
    ),
  );
  assert.ok(
    promotionSource.includes('"launchpad production claim delay restored"'),
  );
  assert.ok(
    promotionSource.includes('"launchpad production migration delay restored"'),
  );
  assert.ok(promotionSource.includes('"launchpad creation fee"'));
  assert.ok(promotionSource.includes('"burner buyback ceiling"'));
});

test("v5 promotion pins timing flips, CCA config, bid semantics, guarded swaps, and cleanup", () => {
  for (const sourceNeedle of [
    "const CANARY_AUCTION_DURATION_BLOCKS = 20_000n;",
    "const CANARY_AUCTION_SUPPLY = 800_000_000n * 10n ** 18n;",
    "const CANARY_CCA_FLOOR_PRICE_Q96 = 1_584_563_250_285_286_700n;",
    "const CANARY_CCA_TICK_SPACING_Q96 = 15_845_632_502_852_867n;",
    "const CANARY_CCA_REQUIRED_CURRENCY = 10_000_000_000_000_000n;",
    "const CANARY_CCA_UNIFORM_MPS_PER_BLOCK = 500n;",
    "const CANARY_CCA_UNIFORM_BLOCK_DELTA = 20_000n;",
    '"function allowance(address owner,address spender) view returns (uint256)"',
    '"function currencyRaised() view returns (uint256)"',
    '"event BidSubmitted(uint256 indexed id,address indexed owner,uint256 priceQ96,uint128 amount)"',
    '"event BidExited(uint256 indexed bidId,address indexed owner,uint256 tokensFilled,uint256 currencyRefunded)"',
    '"event TokensClaimed(uint256 indexed bidId,address indexed owner,uint256 tokensFilled)"',
    '"event CurrencySwept(address indexed fundsRecipient,uint256 currencyAmount)"',
    '"event AuctionTimingSet(uint64 durationBlocks,uint64 claimDelay,uint64 migrationDelay)"',
    '"event FlywheelCollected(uint256 amountWei)"',
    'pinnedRead(canaryAuction, auctionEvidenceAbi, "startBlock")',
    'pinnedRead(canaryAuction, auctionEvidenceAbi, "endBlock")',
    'pinnedRead(canaryAuction, auctionEvidenceAbi, "claimBlock")',
    'pinnedRead(canaryAuction, auctionEvidenceAbi, "validationHook")',
    'pinnedRead(HOOKR_TOKEN, erc20EvidenceAbi, "allowance", [EXPECTED_DEPLOYER, router])',
    'pinnedRead(launchpad, launchpadEvidenceAbi, "creatorProceedsWei", [canaryAuctionToken])',
    'pinnedRead(canaryAuction, auctionEvidenceAbi, "lbpInitializationParams")',
    'pinnedRead(canaryAuction, auctionEvidenceAbi, "currencyRaised")',
    'pinnedRead(hook, hookEvidenceAbi, "poolConfig", [instantLaunchedEvent.poolId])',
    'pinnedRead(hook, hookEvidenceAbi, "poolConfig", [migratedEvent.poolId])',
    'pinnedRead(hook, hookEvidenceAbi, "poolConfig", [hookrLaunchedEvent.poolId])',
    '"event FlywheelFeeAccrued(bytes32 indexed poolId,uint256 amountWei)"',
    "const auctionInitializeEvent = indexedPhaseBEvent(",
    "const indexedCurrencySweptEvent = indexedPhaseBEvent(",
    'currencyRaisedNetAtRead: tupleField(auctionOutcomeRaw, "currencyRaised", 2)',
    "currencyRaisedGross: auctionGrossCurrencyRaised",
    "currencySweptEvent,",
  ]) {
    assert.ok(
      sourceIncludes(promotionSource, sourceNeedle),
      `promotion is missing ${sourceNeedle}`,
    );
  }
  assert.equal(
    V5_CANARY_SPEC.bidMaxPriceQ96,
    814_814_390_533_794_434_497_901_791_991_308_996_217n,
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      "V5_CANARY_SPEC.bidMaxPriceQ96 <= CANARY_CCA_FLOOR_PRICE_Q96",
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      "V5_CANARY_SPEC.bidMaxPriceQ96 % CANARY_CCA_TICK_SPACING_Q96 !== 0n",
    ),
  );
  assert.ok(
    !promotionSource.includes(
      "V5_CANARY_SPEC.bidMaxPriceQ96 !== 2n * CANARY_CCA_FLOOR_PRICE_Q96",
    ),
  );
  assert.equal(V5_CANARY_SPEC.canaryAuctionDurationBlocks, 20_000n);
  assert.equal(V5_CANARY_SPEC.productionAuctionDurationBlocks, 125_000n);
  assert.equal(V5_CANARY_SPEC.routerDeadlineSeconds, 600n);
  assert.equal(V5_CANARY_SPEC.instantHookParams.guardBlocks, 20_000);
  assert.equal(V5_CANARY_SPEC.auctionHookParams.guardBlocks, 20_000);
  assert.equal(V5_CANARY_SPEC.hookrHookParams.guardBlocks, 20_000);
  assert.ok(
    !promotionSource.includes(
      '"function claimableWei(address account) view returns (uint256)"',
    ),
  );
  assert.ok(
    !promotionSource.includes(
      '"function extsload(bytes32 slot) view returns (bytes32)"',
    ),
  );
});

test("v5 promotion accepts permissionless Phase-B receipts and owner-binds only buyback", () => {
  for (const label of [
    "CANARY_AUCTION_MIGRATE",
    "CANARY_AUCTION_EXIT",
    "CANARY_AUCTION_CLAIM",
    "CANARY_AUCTION_PROCEEDS",
    "CANARY_FLYWHEEL_COLLECT",
  ]) {
    assert.ok(
      sourceIncludes(promotionSource, `${label},`),
      `permissionless Phase-B set is missing ${label}`,
    );
  }
  assert.ok(
    sourceIncludes(
      promotionSource,
      '(phase === "canary run" || i === 5) && getAddress(tx.transaction.from) !== EXPECTED_DEPLOYER',
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      "!PERMISSIONLESS_PHASE_B_LABELS.has(label) &&\n    getAddress(onchain.from) !== EXPECTED_DEPLOYER",
    ),
  );
  assert.ok(
    !sourceIncludes(
      promotionSource,
      "phase B signer nonce is not the immediate continuation",
    ),
  );
  const targetTable = promotionSource.slice(
    promotionSource.indexOf("const ONCHAIN_TARGET = {"),
    promotionSource.indexOf("const AUCTION_TARGET_LABELS"),
  );
  for (const label of [
    "CANARY_AUCTION_MIGRATE",
    "CANARY_AUCTION_EXIT",
    "CANARY_AUCTION_CLAIM",
    "CANARY_AUCTION_PROCEEDS",
    "CANARY_FLYWHEEL_COLLECT",
  ]) {
    assert.ok(
      !targetTable.includes(label),
      `${label} must not have a top-level protocol target`,
    );
  }
  assert.ok(targetTable.includes("CANARY_FLYWHEEL_BURN"));
  for (const record of [
    "auctionMigrateRecord",
    "auctionExitRecord",
    "auctionClaimRecord",
    "auctionProceedsRecord",
    "flywheelCollectRecord",
  ]) {
    assert.ok(
      !promotionSource.includes(`decodeCall(${record}`),
      `${record} must allow helper nesting`,
    );
  }
  assert.ok(promotionSource.includes("const flywheelBurnCall = decodeCall("));
  assert.ok(promotionSource.includes('mode !== "direct" && mode !== "nested"'));
  assert.ok(promotionSource.includes('auctionClaimKind !== "nested"'));
  assert.ok(promotionSource.includes("indexedPhaseBEvent"));
});

test("v5 promotion permits shared Phase-B receipts and duplicate batch requests without weakening outcomes", () => {
  assert.ok(promotionSource.includes("const receiptInventory = ["));
  assert.ok(
    promotionSource.includes(
      "aliasable: index < V5_PHASE_B_ACTIONS.length - 1",
    ),
  );
  assert.ok(
    promotionSource.includes(
      "permissionless Phase-B aliases have different raw transactions",
    ),
  );
  assert.ok(
    promotionSource.includes(
      "permissionless Phase-B aliases have different canonical receipts",
    ),
  );
  assert.ok(
    promotionSource.includes(
      "assertAliasedCanonicalReceiptOrder(onchainReceiptOrder",
    ),
  );
  assert.ok(
    promotionSource.includes("collides outside permissionless Phase B"),
  );
  assert.ok(
    promotionSource.includes(
      "permissionless Phase-B aliases resolve to different live transactions",
    ),
  );
  assert.ok(
    promotionSource.includes(
      "permissionless Phase-B aliases resolve to different canonical receipts",
    ),
  );
  assert.ok(
    promotionSource.includes(
      "Duplicate requested ids are harmless interposition",
    ),
  );
  assert.ok(promotionSource.includes("auctionClaimRequestedBidIds.some"));
  assert.ok(!promotionSource.includes("auctionClaimRequestedBidIds.filter"));
  assert.ok(
    promotionSource.includes(
      "direct batch claim emitted duplicate TokensClaimed bid ids",
    ),
  );
  assert.ok(
    promotionSource.includes(
      "direct batch claim emitted a bid absent from calldata",
    ),
  );
  assert.ok(promotionSource.includes("ownerTransferEvents.length !== 1"));
  assert.ok(
    promotionSource.includes("ownerTransferAmount !== ownerClaimAmount"),
  );
  assert.ok(
    promotionSource.includes("auctionToOwnerTransfers.aggregateAmount"),
  );
});

test("v5 promotion accepts wrapper absolute paths but keeps indexed raw paths canonical and symlink-free", () => {
  const pathGuard = promotionSource.slice(
    promotionSource.indexOf("const REPO_ROOT = realpathSync(process.cwd());"),
    promotionSource.indexOf(
      "const authenticatedLocalInputSnapshots = new Map();",
    ),
  );
  assert.ok(
    pathGuard.includes("const REPO_ROOT = realpathSync(process.cwd());"),
  );
  assert.ok(pathGuard.includes("const absolute = resolve(value);"));
  assert.ok(
    pathGuard.includes(
      "const canonicalInput = isAbsolute(value) ? absolute : normalized;",
    ),
  );
  assert.ok(pathGuard.includes("lstatSync(cursor).isSymbolicLink()"));
  assert.ok(pathGuard.includes("resolvedRealPath = realpathSync(absolute)"));
  assert.ok(pathGuard.includes("resolvedRealPath !== absolute"));
  assert.ok(promotionSource.includes("{ requireCanonicalRelative: true }"));
  for (const wrapperArgument of [
    '--deploy "$DEPLOY_ABS"',
    '--library-evidence "$LIBRARY_EVIDENCE_ABS"',
    '--canary-timing-shorten-transaction "$SHORTEN_TRANSACTION_ABS"',
    '--canary-phase-a-index "$PHASE_A_INDEX_ABS"',
    '--canary-phase-b-index "$PHASE_B_INDEX_ABS"',
  ]) {
    assert.ok(
      canaryWrapperSource.includes(wrapperArgument),
      `wrapper-shaped absolute input is missing ${wrapperArgument}`,
    );
  }
});

test("v5 promotion snapshots every authenticated local input and deduplicates shared paths", () => {
  for (const input of [
    "DEPLOY_PATH",
    "CANARY_INSTANT_LAUNCH_PATH",
    "CANARY_INSTANT_BUY_AUCTION_LAUNCH_PATH",
    "CANARY_OWNER_BID_TRANSACTION_PATH",
    "CANARY_OWNER_BID_RECEIPT_PATH",
    "CANARY_HOOKR_LAUNCH_PATH",
    "CANARY_HOOKR_APPROVE_BUY_PATH",
    "CANARY_TIMING_SHORTEN_TRANSACTION_PATH",
    "CANARY_TIMING_SHORTEN_RECEIPT_PATH",
    "CANARY_TIMING_RESTORE_TRANSACTION_PATH",
    "CANARY_TIMING_RESTORE_RECEIPT_PATH",
  ]) {
    assert.match(
      promotionSource,
      new RegExp(`load\\(\\s*${input}\\b`),
      `${input} must be parsed from the authenticated snapshot registry`,
    );
  }
  for (const input of [
    "CANARY_PHASE_A_INDEX_PATH",
    "CANARY_PHASE_B_INDEX_PATH",
    "MANIFEST_PATH",
  ]) {
    assert.match(
      promotionSource,
      new RegExp(`authenticatedLocalInputSnapshot\\(\\s*${input}\\b`),
      `${input} must be captured before authentication`,
    );
  }
  assert.ok(
    sourceIncludes(
      promotionSource,
      "const authenticatedLocalInputSnapshots = new Map();",
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      "authenticatedLocalInputSnapshots.get(canonicalPath)",
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      "authenticatedLocalInputSnapshots.set(canonicalPath, snapshot)",
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      "V5_PHASE_B_ACTIONS.map((name) => [name, indexedPhaseBPair",
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      "load(transactionPath, `phase B/${name} transaction`)",
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      "load(receiptPath, `phase B/${name} receipt`)",
    ),
  );
  assert.ok(
    sourceIncludes(promotionSource, "Object.entries(RUNTIME_ARTIFACTS).map"),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      "load(target.path, `${key} runtime artifact`)",
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      "authenticatedLocalInputSnapshot(\n          `contracts/${sourcePath}`",
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      'load(LIBRARY_EVIDENCE_PATH, "reused-library evidence")',
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      'load(sourceArtifactPath, "reused-library source artifact")',
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      "authenticatedLocalInputRegistrySealed = true;",
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      "was first read after the local-input snapshot boundary",
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      "for (const snapshot of authenticatedLocalInputSnapshots.values())",
    ),
  );
});

test("v5 promotion closes local and on-chain finality TOCTOU windows before write", () => {
  const sourcePosition = (needle, fromIndex = 0) =>
    sourceIndex(promotionSource, needle, fromIndex);
  for (const snapshot of [
    "const phaseAIndexSnapshot = authenticatedLocalInputSnapshot(",
    "const phaseBIndexSnapshot = authenticatedLocalInputSnapshot(",
    "const manifestSourceSnapshot = authenticatedLocalInputSnapshot(",
  ]) {
    assert.ok(sourceIncludes(promotionSource, snapshot));
  }
  assert.ok(
    sourceIncludes(
      promotionSource,
      "assertAuthenticatedLocalFileUnchanged(snapshot, label)",
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      'git("rev-parse", "HEAD") !== repositoryHeadSnapshot',
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      'git("status", "--porcelain=v1", "--untracked-files=all") !== repositoryStatusSnapshot',
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      'fail("repository was not clean when promotion authentication began")',
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      'const source = manifestSourceSnapshot.bytes.toString("utf8");',
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      'canaryPhaseAIndexSha256: "${phaseAIndexSnapshot.sha256}"',
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      'canaryPhaseBIndexSha256: "${phaseBIndexSnapshot.sha256}"',
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      "phase A index sha256 ${phaseAIndexSnapshot.sha256}",
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      "phase B index sha256 ${phaseBIndexSnapshot.sha256}",
    ),
  );
  assert.ok(
    !sourceIncludes(
      promotionSource,
      "${sha256File(CANARY_PHASE_A_INDEX_PATH)}",
    ),
  );
  assert.ok(
    !sourceIncludes(
      promotionSource,
      "${sha256File(CANARY_PHASE_B_INDEX_PATH)}",
    ),
  );
  assert.ok(
    !sourceIncludes(promotionSource, 'readFileSync(MANIFEST_PATH, "utf8")'),
  );

  const localInputSeal = sourcePosition(
    "authenticatedLocalInputRegistrySealed = true;",
  );
  const initialGateRead = sourcePosition(
    "const initialReleaseGateSnapshot = await readReleaseGateSnapshot(stateHead.hash);",
  );
  const finalityWait = sourcePosition(
    "let manifestFinalityHead = finalizedHead;",
    initialGateRead,
  );
  const freshHeadRead = sourcePosition(
    "const freshReleaseStateHead = await client.getBlock({ blockTag: stateEvidenceTag });",
    finalityWait,
  );
  const freshGateRead = sourcePosition(
    "const freshReleaseGateSnapshot = await readReleaseGateSnapshot(freshReleaseStateHead.hash);",
    freshHeadRead,
  );
  const driftRefusal = sourcePosition(
    '"mutable release gates drifted while state evidence was finalizing"',
    freshGateRead,
  );
  const firstWorkspaceRecheck = sourcePosition(
    "assertPromotionWorkspaceUnchanged();",
    driftRefusal,
  );
  const manifestDerivation = sourcePosition(
    "const manifest = `export const CURRENT_RELEASE_MANIFEST",
    firstWorkspaceRecheck,
  );
  const secondWorkspaceRecheck = sourcePosition(
    "assertPromotionWorkspaceUnchanged();",
    firstWorkspaceRecheck + 1,
  );
  const manifestWrite = sourcePosition(
    "writeFileSync(manifestSourceSnapshot.path, patchedSource);",
    secondWorkspaceRecheck,
  );
  assert.ok(
    localInputSeal >= 0 &&
      localInputSeal < initialGateRead &&
      initialGateRead < finalityWait &&
      finalityWait < freshHeadRead &&
      freshHeadRead < freshGateRead &&
      freshGateRead < driftRefusal &&
      driftRefusal < firstWorkspaceRecheck &&
      firstWorkspaceRecheck < manifestDerivation &&
      manifestDerivation < secondWorkspaceRecheck &&
      secondWorkspaceRecheck < manifestWrite,
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      "freshReleaseStateHead.number < stateHead.number",
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      "freshReleaseStateHead.number < manifestFinalityHead.number",
    ),
  );
  assert.ok(
    sourceIncludes(promotionSource, "canonicalFreshReleaseStateAfterReads"),
  );
  for (const gate of [
    '"launchpad.creationFeeWei"',
    '"launchpad.auctionDurationBlocks"',
    '"launchpad.owner"',
    '"hook.flywheelRecipient"',
    '"router.quoteToken"',
    '"burner.maxBuybackWei"',
    '"burner.owner"',
    '"hookr.allowance"',
    '"auction.currencyRaised"',
    '"hook.auctionPoolConfig"',
  ]) {
    assert.ok(
      sourceIncludes(promotionSource, gate),
      `fresh release-gate snapshot is missing ${gate}`,
    );
  }
});

test("v5 promotion authenticates reused-library provenance before carrying it into evidence", () => {
  assert.ok(
    promotionSource.includes(
      "[--library-evidence contracts/release-evidence/v5/reused-launchpad-library.json]",
    ),
  );
  assert.ok(
    promotionSource.includes(
      'const LIBRARY_EVIDENCE_PATH = flag("library-evidence", "");',
    ),
  );
  assert.ok(
    promotionSource.includes(
      'libraryEvidence.kind !== "reused-library-evidence-v1"',
    ),
  );
  assert.ok(
    promotionSource.includes(
      'sha256File(sourceArtifactPath, "reused-library source artifact")',
    ),
  );
  assert.ok(promotionSource.includes("libraryEvidence.sourceArtifactSha256"));
  assert.ok(promotionSource.includes("libraryEvidence.calldataHash"));
  assert.ok(promotionSource.includes("libraryEvidence.sourceCommit"));
  assert.ok(
    promotionSource.includes('librarySourceCommit: "${librarySourceCommit}"'),
  );
  assert.ok(promotionSource.includes('library: "${receipts.launchpadLib}"'));
});

test("v5 promotion verifies owner-bound calldata and Phase-A selectors while Phase B is event-bound", () => {
  const launchArgsTuple =
    "(string,string,string,string,address,uint32,(uint32,uint16,uint24,uint24,uint24,uint16,uint16,uint96,uint16,uint16,uint32,uint96),uint16,(address,uint16)[])";
  // Recompute the selectors the script derives; the signatures live in the script as
  // template-joined strings, so match on the tuple and entrypoint names it must join. Both lanes
  // take a `quote` uint8 right after the (unchanged) LaunchArgs tuple.
  assert.equal(
    toFunctionSelector(`launchInstant(${launchArgsTuple},uint8,bytes32)`)
      .length,
    10,
  );
  assert.ok(sourceIncludes(promotionSource, JSON.stringify(launchArgsTuple)));
  assert.ok(
    sourceIncludes(
      promotionSource,
      "`launchInstant(${LAUNCH_ARGS_TUPLE},uint8,bytes32)`",
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      "`launchAuction(${LAUNCH_ARGS_TUPLE},uint8,uint96,uint96,uint16,bytes32)`",
    ),
  );
  assert.ok(
    !sourceIncludes(
      promotionSource,
      "`launchInstant(${LAUNCH_ARGS_TUPLE},bytes32)`",
    ),
    "the pre-flywheel quote-less instant selector must be gone",
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      'toFunctionSelector("setAuctionTiming(uint64,uint64,uint64)")',
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      'toFunctionSelector("approve(address,uint256)")',
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      'toFunctionSelector("buybackAndBurn(uint256,uint256)")',
    ),
  );
  assert.ok(
    !sourceIncludes(
      promotionSource,
      'toFunctionSelector("migrateAuction(address)")',
    ),
  );
  assert.ok(
    !sourceIncludes(
      promotionSource,
      'toFunctionSelector("claimAuctionProceeds(address)")',
    ),
  );
  assert.ok(
    !sourceIncludes(promotionSource, 'toFunctionSelector("collect()")'),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      'toEventSelector("InstantLaunched(address,bytes32,uint96)")',
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      'toEventSelector("AuctionStarted(address,address,uint40,uint96,uint96,uint16)")',
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      'toEventSelector("AuctionTimingSet(uint64,uint64,uint64)")',
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      'indexedPhaseBEvent("migrateAuction", "migrated", "canary Migrated")',
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      '"auctionProceeds",\n    "canary AuctionProceeds"',
    ),
  );
  assert.ok(
    sourceIncludes(
      promotionSource,
      'toEventSelector("BuybackBurned(address,uint256,uint256)")',
    ),
    "the flywheel burn must be verified from the live BuybackBurned event",
  );
  assert.ok(
    !sourceIncludes(promotionSource, "launchInstantWithIntent"),
    "the v4 entrypoint must be gone",
  );
});

test("v5 promotion preserves a zero-proceeds migration as an explicit not-applicable action", () => {
  for (const sourceNeedle of [
    'const NOT_APPLICABLE_ZERO_PROCEEDS = "not-applicable-zero-proceeds"',
    "phaseBProceedsEvents.creatorFeesClaimed !== null",
    "authenticatedPhaseBIndex.actions.migrateAuction.events.auctionProceeds !== null",
    'phaseBZeroProceedsProof?.executionMode !== "not-applicable"',
    "zero-proceeds action does not alias the exact migration transaction",
    "zero-proceeds action does not alias the exact migration receipt",
    "const auctionProceedsEvent = phaseBProceedsNotApplicable",
    "const proceedsClaimEvent = phaseBProceedsNotApplicable",
    "...(phaseBProceedsNotApplicable ? { notApplicable: phaseBZeroProceedsProof } : {})",
  ]) {
    assert.ok(
      sourceIncludes(promotionSource, sourceNeedle),
      `promotion is missing ${sourceNeedle}`,
    );
  }
});

test("v5 promotion writes all action receipt references, including shared Phase-B hashes, and retains v4", () => {
  for (const field of [
    "instantLaunch",
    "auctionTimingShorten",
    "instantRouterBuy",
    "auctionLaunch",
    "auctionTimingRestore",
    "auctionBid",
    "hookrLaunch",
    "hookrApprove",
    "hookrBuy",
    "auctionMigrate",
    "auctionExit",
    "auctionClaim",
    "auctionProceedsClaim",
    "flywheelCollect",
    "flywheelBurn",
  ]) {
    assert.ok(
      promotionSource.includes(`${field}: "\${receipts.canary.${field}}"`),
      `manifest canary receipt ${field} is missing`,
    );
  }
  assert.ok(
    promotionSource.includes('kind: "all_lanes_and_flywheel_round_trip_v5"'),
  );
  assert.ok(
    !promotionSource.includes('kind: "instant_and_auction_round_trip_v5"'),
    "the pre-flywheel canary kind must no longer be written",
  );
  assert.ok(promotionSource.includes('launchModes: ["instant", "bonded"]'));
  assert.ok(promotionSource.includes("version: 5,"));
  assert.ok(
    promotionSource.includes(
      "retireAndReplaceCurrentReleaseManifest(source, manifest)",
    ),
  );
  assert.ok(
    !promotionSource.includes('"curve"'),
    "generation 5 must not re-declare the curve lane",
  );
});

test("v5 promotion writes the flywheel section from live readbacks", () => {
  assert.ok(
    promotionSource.includes('burner: "${burner}"'),
    "flywheel burner must come from the deploy receipts",
  );
  assert.ok(
    promotionSource.includes('runtimeCodeHash: "${burnerHash}"'),
    "the manifest must pin the authenticated burner runtime",
  );
  assert.ok(promotionSource.includes('hookrToken: "${HOOKR_TOKEN}"'));
  assert.ok(promotionSource.includes("feePips: ${FLYWHEEL_FEE_PIPS}"));
  assert.ok(promotionSource.includes("const FLYWHEEL_FEE_PIPS = 3000;"));
  // The flywheel triangle readbacks that gate the section.
  assert.ok(promotionSource.includes('"hook->burner flywheel wiring"'));
  assert.ok(promotionSource.includes('"burner->hook wiring"'));
  assert.ok(promotionSource.includes('"burner->HOOKR wiring"'));
  assert.ok(promotionSource.includes('"launchpad->HOOKR quote wiring"'));
  assert.ok(promotionSource.includes('"launchpad HOOKR instant FDV"'));
  assert.ok(promotionSource.includes('"router->HOOKR quote wiring"'));
});

test("v5 promotion drives the canary validator with the spec's own receipt labels", () => {
  assert.ok(promotionSource.includes('from "./lib/v5-canary-evidence.mjs"'));
  assert.ok(
    promotionSource.includes("validateV5CanaryEvidence(canaryEvidence)"),
  );
  assert.ok(promotionSource.includes("V5_CANARY_SPEC.phaseAReceiptLabels"));
  assert.ok(promotionSource.includes("V5_CANARY_SPEC.phaseBReceiptLabels"));
  assert.equal(V5_CANARY_SPEC.phaseAReceiptLabels.length, 9);
  assert.equal(V5_CANARY_SPEC.phaseACallReceiptLabels.length, 7);
  assert.equal(V5_CANARY_SPEC.phaseBReceiptLabels.length, 6);
  assert.equal(V5_CANARY_SPEC.buyWei, 1_000_000_000_000_000n);
  assert.equal(V5_CANARY_SPEC.flywheelEthIn, 3_000_000_000_000n);
  assert.equal(V5_CANARY_SPEC.flywheelMinHookrOut, 3n * 10n ** 18n);
  assert.ok(V5_CANARY_SPEC.phaseAReceiptLabels.includes("canary:hookr-launch"));
  assert.ok(
    V5_CANARY_SPEC.phaseAReceiptLabels.includes("canary:hookr-approve"),
  );
  assert.ok(V5_CANARY_SPEC.phaseAReceiptLabels.includes("canary:hookr-buy"));
  assert.ok(
    V5_CANARY_SPEC.phaseBReceiptLabels.includes("canary:flywheel-collect"),
  );
  assert.ok(
    V5_CANARY_SPEC.phaseBReceiptLabels.includes("canary:flywheel-burn"),
  );
  assert.ok(!promotionSource.includes("validateInstantCanaryEvidence"));
});
