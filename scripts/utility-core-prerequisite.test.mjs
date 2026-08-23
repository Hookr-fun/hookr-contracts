import assert from "node:assert/strict";
import test from "node:test";
import { getAddress, keccak256 } from "viem";

import {
  UTILITY_CORE_CANARY_DEPOSIT_WEI,
  UTILITY_CORE_EXPECTED_DEPLOYER,
  validateUtilityCoreManifest,
  verifyUtilityCorePrerequisite,
} from "./lib/utility-core-prerequisite.mjs";

const address = (value) => getAddress(`0x${value.toString(16).padStart(40, "0")}`);
const hash = (value) => `0x${value.toString(16).padStart(64, "0")}`;
const launchpad = address(0x1001);
const token = address(0x1002);
const code = "0x6001600055";
const codehash = keccak256(code);
const block = { number: 100n, hash: hash(100) };

function manifest(overrides = {}) {
  return {
    chainId: 4663,
    version: 4,
    productionAllowed: true,
    capabilities: { launchModes: ["curve", "instant"] },
    contracts: { launchpad: { address: launchpad, runtimeCodeHash: codehash } },
    ...overrides,
  };
}

function launch(overrides = {}) {
  return {
    token,
    creator: UTILITY_CORE_EXPECTED_DEPLOYER,
    launchBlock: 50n,
    blueprintId: 0,
    graduated: true,
    basePriceWei: 20_000_000n,
    targetWei: UTILITY_CORE_CANARY_DEPOSIT_WEI,
    reserveWei: 0n,
    soldTokens: 0n,
    graduatedAtBlock: 50n,
    sqrtPriceX96AtGraduation: 123n,
    poolId: hash(5),
    hookParams: {
      guardBlocks: 200,
      maxBuyBps: 1_000,
      snipeTaxPips: 200_000,
      baseFeePips: 3_000,
      maxFeePips: 30_000,
      surgeSens: 5,
      burnBps: 100,
      burnTriggerWei: 0n,
      lpBps: 25,
      potBps: 50,
      potEveryNBuys: 10,
      potMinBuyWei: 1_000_000_000_000_000n,
    },
    ...overrides,
  };
}

function client(overrides = {}) {
  return {
    getChainId: async () => 4663,
    getBlock: async (request) => request.blockNumber === block.number ? block : block,
    getCode: async () => code,
    readContract: async ({ functionName }) => {
      if (functionName === "previewInstantLaunch") {
        return [500_000_000_000_000_000_000_000_000n, 20_000_000n, 123n, 20_000_000_000_000_000n, 0];
      }
      if (functionName === "launchedByIntent") return token;
      if (functionName === "getLaunch") return launch();
      throw new Error(`unexpected ${functionName}`);
    },
    ...overrides,
  };
}

const base = {
  releaseGateBlockers: () => [],
  releaseIdOf: (value) => `hookr-${value.chainId}-v${value.version}`,
  expectedLaunchpadAddress: launchpad,
  expectedLaunchpadRuntimeHash: codehash,
};

test("rejects the currently retained generation-3 manifest", () => {
  assert.throws(
    () => validateUtilityCoreManifest({ ...base, manifest: manifest({ version: 3, capabilities: { launchModes: ["curve"] } }) }),
    /not generation 4/,
  );
});

test("rejects closed gates, incomplete capabilities, and wrong launchpad assertions", () => {
  assert.throws(
    () => validateUtilityCoreManifest({ ...base, manifest: manifest(), releaseGateBlockers: () => ["PRODUCTION_NOT_ALLOWED"] }),
    /gate is closed/,
  );
  assert.throws(
    () => validateUtilityCoreManifest({ ...base, manifest: manifest({ capabilities: { launchModes: ["curve"] } }) }),
    /exactly curve and instant/,
  );
  assert.throws(
    () => validateUtilityCoreManifest({ ...base, manifest: manifest(), expectedLaunchpadAddress: address(0x9999) }),
    /does not match current manifest/,
  );
  assert.throws(
    () => validateUtilityCoreManifest({ ...base, manifest: manifest(), expectedLaunchpadRuntimeHash: hash(999) }),
    /does not match current manifest/,
  );
});

test("rejects a v4-shaped core missing the instant selector or fixed canary", async () => {
  await assert.rejects(
    verifyUtilityCorePrerequisite({ ...base, manifest: manifest(), client: client({ readContract: async () => { throw new Error("selector missing"); } }), pinnedBlock: block }),
    /selector missing/,
  );
  await assert.rejects(
    verifyUtilityCorePrerequisite({ ...base, manifest: manifest(), client: client({ readContract: async ({ functionName }) => functionName === "previewInstantLaunch" ? [500_000_000_000_000_000_000_000_000n, 20_000_000n, 123n, 20_000_000_000_000_000n, 0] : functionName === "launchedByIntent" ? address(0) : launch() }), pinnedBlock: block }),
    /fixed all-five canary is missing/,
  );
});

test("rejects malformed preview and canary state", async () => {
  await assert.rejects(
    verifyUtilityCorePrerequisite({ ...base, manifest: manifest(), client: client({ readContract: async ({ functionName }) => functionName === "previewInstantLaunch" ? [499n, 20_000_000n, 123n, 20_000_000_000_000_000n, 0] : functionName === "launchedByIntent" ? token : launch() }), pinnedBlock: block }),
    /pool supply/,
  );
  await assert.rejects(
    verifyUtilityCorePrerequisite({ ...base, manifest: manifest(), client: client({ readContract: async ({ functionName }) => functionName === "previewInstantLaunch" ? [500_000_000_000_000_000_000_000_000n, 20_000_000n, 123n, 20_000_000_000_000_000n, 0] : functionName === "launchedByIntent" ? token : launch({ reserveWei: 1n }) }), pinnedBlock: block }),
    /reserve/,
  );
});

test("accepts the promoted v4 identity, exact preview, and all-five canary at one canonical block", async () => {
  const proof = await verifyUtilityCorePrerequisite({
    ...base,
    manifest: manifest(),
    client: client(),
    pinnedBlock: block,
  });
  assert.equal(proof.releaseId, "hookr-4663-v4");
  assert.equal(proof.launchpad, launchpad);
  assert.equal(proof.canaryToken, token);
  assert.equal(proof.blockHash, block.hash);
});
