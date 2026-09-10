#!/usr/bin/env node
/**
 * Read-only, fail-closed utility deployment verifier. Run after the standalone three-receipt
 * deployment and before loading a signer for any canary. This file never writes or broadcasts.
 *
 * Usage:
 *   node scripts/verify-utility-v2-deployment-preflight.mjs \
 *     --deploy contracts/broadcast/DeployHookrUtilitiesV2.s.sol/4663/run-latest.json \
 *     --launchpad 0x... --launchpad-codehash 0x... \
 *     --rpc https://rpc.mainnet.chain.robinhood.com
 *
 * A loopback fork rehearsal must add --rehearsal.
 */
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import {
  createPublicClient,
  decodeEventLog,
  decodeFunctionData,
  encodeDeployData,
  encodeFunctionData,
  getAddress,
  http,
  keccak256,
  parseAbi,
  toHex,
} from "viem";

import { assertStrictReceiptOrder } from "./lib/instant-canary-evidence.mjs";
import {
  assertReceiptsWithinEvidenceBlock,
  assertStateEvidenceAfterFinality,
} from "./lib/release-promotion-evidence.mjs";
import { assertArtifactSourceHashes } from "./lib/runtime-template-evidence.mjs";
import {
  REVIEWED_UTILITY_V2_NORMALIZED_RUNTIME_HASHES,
  REVIEWED_UTILITY_V2_RUNTIME_REFERENCE_LAYOUT_HASHES,
  UTILITY_V2_RUNTIME_ARTIFACTS,
  utilityV2AddressWord,
  utilityV2UintWord,
  validateReviewedUtilityV2Runtime,
} from "./lib/utility-v2-runtime-evidence.mjs";
import { verifyUtilityCorePrerequisite } from "./lib/utility-core-prerequisite.mjs";
import { validateAmbientUtilityDeploymentAccounting } from "./lib/utility-deployment-accounting.mjs";

const argv = process.argv.slice(2);
const flag = (name, fallback) => {
  const index = argv.indexOf(`--${name}`);
  return index >= 0 && argv[index + 1] ? argv[index + 1] : fallback;
};
const REHEARSAL = argv.includes("--rehearsal");
const DEPLOY_PATH = flag(
  "deploy",
  "contracts/broadcast/DeployHookrUtilitiesV2.s.sol/4663/run-latest.json",
);
const RPC = flag("rpc", "https://rpc.mainnet.chain.robinhood.com");
const LAUNCHPAD_ARG = flag("launchpad", "");
const LAUNCHPAD_CODEHASH = flag("launchpad-codehash", "").toLowerCase();
const CORE_RELEASE_PATH = flag("core-release", "");

const fail = (message) => {
  console.error(`\nUTILITY V2 DEPLOYMENT PREFLIGHT BLOCKED: ${message}`);
  process.exit(1);
};
const sameHex = (left, right) =>
  typeof left === "string" &&
  typeof right === "string" &&
  left.toLowerCase() === right.toLowerCase();
const load = (path) => {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    fail(`cannot read ${path}: ${error.message}`);
  }
};
const git = (...args) => execFileSync("git", args, { encoding: "utf8" }).trim();

let rpcUrl;
try {
  rpcUrl = new URL(RPC);
} catch {
  fail(`--rpc is not a valid URL: ${RPC}`);
}
const RPC_IS_LOOPBACK =
  rpcUrl.hostname === "localhost" ||
  rpcUrl.hostname === "::1" ||
  rpcUrl.hostname === "[::1]" ||
  /^127\./.test(rpcUrl.hostname);
if (REHEARSAL && !RPC_IS_LOOPBACK) fail("--rehearsal is only allowed against a loopback RPC");
if (!REHEARSAL && RPC_IS_LOOPBACK) fail("a loopback preflight requires --rehearsal");
if (!REHEARSAL && rpcUrl.protocol !== "https:") fail("production preflight requires an https RPC");
if (CORE_RELEASE_PATH && !REHEARSAL) fail("--core-release override is rehearsal-only");

let coreHelpers;
try {
  coreHelpers = await import("../src/lib/release-manifest.ts");
} catch (error) {
  fail(`cannot load core release helpers: ${error.message}`);
}
const coreManifest = CORE_RELEASE_PATH ? load(CORE_RELEASE_PATH) : coreHelpers.CURRENT_RELEASE_MANIFEST;

let launchpad;
try {
  launchpad = getAddress(LAUNCHPAD_ARG);
} catch {
  fail("--launchpad must be the promoted generation-4 launchpad address");
}
if (!/^0x[0-9a-f]{64}$/.test(LAUNCHPAD_CODEHASH) || /^0x0+$/.test(LAUNCHPAD_CODEHASH)) {
  fail("--launchpad-codehash must be the promoted generation-4 runtime codehash");
}

const EXPECTED_DEPLOYER = getAddress("0x5a52D4B820Ae7F02880d270562950918ACb14aA2");
const HOOKR_TOKEN = getAddress("0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c");
const HOOKR_RUNTIME_CODEHASH =
  "0xd9346eaf1a9878650549765e1d4ce8b3d0516d93d3203e1c8b99e382428ebc8d";

const setSourceAbi = parseAbi([
  "function setRewardSourceOnce(address source)",
  "event RewardSourceSet(address indexed source)",
]);
const hookrAbi = parseAbi([
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
  "function totalSupply() view returns (uint256)",
  "function DOMAIN_SEPARATOR() view returns (bytes32)",
]);
const launchpadAbi = parseAbi([
  "function contractName() view returns (string)",
  "function contractVersion() view returns (string)",
]);
const rewardsAbi = parseAbi([
  "function contractName() view returns (string)",
  "function contractVersion() view returns (string)",
  "function hookrToken() view returns (address)",
  "function configurator() view returns (address)",
  "function rewardSource() view returns (address)",
  "function EPOCH_LENGTH() view returns (uint40)",
  "function MONDAY_EPOCH_OFFSET() view returns (uint40)",
  "function BOOTSTRAP_EPOCH_LENGTH() view returns (uint40)",
  "function bootstrapStartedAt() view returns (uint40)",
  "function feeEpochStartsAt() view returns (uint40)",
  "function claimEpochStartsAt() view returns (uint40)",
  "function weeklyEpochsStartAt() view returns (uint40)",
  "function checkpointCurrent() view returns (bool)",
  "function currentEligibleWeight() view returns (uint256)",
  "function positionCount() view returns (uint256)",
  "function roundingCarry() view returns (uint256)",
  "function tierConfig(uint8 tier) view returns (uint40 durationSeconds,uint16 multiplierBps)",
  "function totalLockedPrincipal() view returns (uint256)",
  "function rewardReserve() view returns (uint256)",
  "function cumulativeBoostFeesNotified() view returns (uint256)",
  "function cumulativeRewardsClaimed() view returns (uint256)",
  "function solvency() view returns (uint256 balance,uint256 principalLiability,uint256 rewardLiability,uint256 surplus,bool solvent)",
]);
const boostAbi = parseAbi([
  "function contractName() view returns (string)",
  "function contractVersion() view returns (string)",
  "function hookrToken() view returns (address)",
  "function launchpad() view returns (address)",
  "function lockRewards() view returns (address)",
  "function BOOST_FEE_BPS() view returns (uint16)",
  "function MIN_GROSS_BOOST() view returns (uint256)",
  "function MAX_ACTIVE_BOOSTS() view returns (uint16)",
  "function boostingOpensAt() view returns (uint40)",
  "function boostingOpen() view returns (bool)",
  "function totalBoostPrincipal() view returns (uint256)",
  "function cumulativeGrossBoosted() view returns (uint256)",
  "function cumulativePrincipalAdded() view returns (uint256)",
  "function cumulativeFeesForwarded() view returns (uint256)",
  "function boostedTokensCount() view returns (uint256)",
  "function solvency() view returns (uint256 balance,uint256 principalLiability,uint256 surplus,bool solvent)",
]);

const deployRun = load(DEPLOY_PATH);
if (deployRun.chain !== 4663) fail(`artifact chain is ${deployRun.chain}, expected 4663`);

const runtimeArtifacts = Object.fromEntries(
  Object.entries(UTILITY_V2_RUNTIME_ARTIFACTS).map(([key, target]) => [key, load(target.path)]),
);
for (const [key, target] of Object.entries(UTILITY_V2_RUNTIME_ARTIFACTS)) {
  try {
    assertArtifactSourceHashes(
      runtimeArtifacts[key],
      (sourcePath) => readFileSync(`contracts/${sourcePath}`),
      target.contractName,
    );
  } catch (error) {
    fail(`${target.contractName} artifact: ${error.message}`);
  }
}

const receiptMap = new Map();
for (const receipt of deployRun.receipts ?? []) {
  const hash = String(receipt.transactionHash ?? "").toLowerCase();
  if (!/^0x[0-9a-f]{64}$/.test(hash)) fail("artifact contains a malformed receipt hash");
  if (receiptMap.has(hash)) fail(`artifact contains duplicate receipt ${hash}`);
  receiptMap.set(hash, receipt);
}
const deployPairs = (deployRun.transactions ?? []).map((tx, index) => {
  const receipt = receiptMap.get(String(tx.hash ?? "").toLowerCase());
  if (!receipt) fail(`artifact transaction #${index} has no hash-matched receipt`);
  return { tx, receipt };
});
if (deployPairs.length !== 3 || receiptMap.size !== 3) {
  fail(`utility artifact must contain exactly 3 transactions/receipts, found ${deployPairs.length}/${receiptMap.size}`);
}

const expectedShape = [
  { type: "CREATE", contractName: "HookrLockRewardsV2" },
  { type: "CREATE", contractName: "HookrLaunchBoostV2" },
  { fn: "setRewardSourceOnce" },
];
for (let index = 0; index < expectedShape.length; index += 1) {
  const expected = expectedShape[index];
  const { tx, receipt } = deployPairs[index];
  if (receipt.status !== "0x1") fail(`artifact transaction #${index} did not succeed`);
  if (getAddress(tx.transaction.from) !== EXPECTED_DEPLOYER) {
    fail(`artifact transaction #${index} is not from the expected deployer`);
  }
  if (BigInt(tx.transaction.value ?? 0) !== 0n) fail(`artifact transaction #${index} sent native value`);
  if (expected.type && tx.transactionType !== expected.type) {
    fail(`artifact transaction #${index} is ${tx.transactionType}, expected ${expected.type}`);
  }
  if (expected.contractName && tx.contractName !== expected.contractName) {
    fail(`artifact transaction #${index} is ${tx.contractName}, expected ${expected.contractName}`);
  }
  if (expected.fn && !String(tx.function ?? "").startsWith(expected.fn)) {
    fail(`artifact transaction #${index} is not ${expected.fn}()`);
  }
}

const artifactCommit = String(deployRun.commit ?? "").trim();
if (!artifactCommit) fail("artifact has no source commit");
let sourceCommit;
try {
  sourceCommit = git("rev-parse", artifactCommit);
} catch {
  fail(`artifact commit ${artifactCommit} is not in this repository`);
}
const headCommit = git("rev-parse", "HEAD");
if (sourceCommit !== headCommit) {
  fail(`artifact commit ${sourceCommit.slice(0, 12)} is not HEAD ${headCommit.slice(0, 12)}`);
}
if (!REHEARSAL) {
  const dirty = git(
    "status",
    "--porcelain",
    "--",
    "contracts/src/HookrLockRewardsV2.sol",
    "contracts/src/HookrLaunchBoostV2.sol",
    "contracts/src/HookrLaunchpad.sol",
    "contracts/src/interfaces/IHookrLockRewardsV2.sol",
    "contracts/src/libraries/HookrTokenTransfer.sol",
    "contracts/script/DeployHookrUtilitiesV2.s.sol",
    "contracts/foundry.toml",
    "src/lib/release-manifest.ts",
    "scripts/verify-utility-v2-deployment-preflight.mjs",
    "scripts/verify-utility-core-prerequisite.mjs",
    "scripts/lib/utility-core-prerequisite.mjs",
    "scripts/lib/utility-deployment-accounting.mjs",
    "scripts/lib/instant-canary-evidence.mjs",
    "scripts/lib/release-promotion-evidence.mjs",
    "scripts/lib/runtime-template-evidence.mjs",
    "scripts/lib/utility-terms.mjs",
    "scripts/lib/utility-v2-release-candidate.mjs",
    "scripts/lib/utility-v2-runtime-evidence.mjs",
    "scripts/promote-utility-v2-release-candidate.mjs",
    "scripts/verify-utility-v2-canary-evidence.mjs",
    "docs/HOOKR_UTILITY_TERMS_V2.md",
    "public/terms/HOOKR_UTILITY_TERMS_V2.md",
    "src/lib/utility-release-manifest.ts",
    "src/lib/utility-terms.generated.json",
    "src/lib/utility-terms.ts",
  );
  if (dirty) fail("utility source or verifier inputs are dirty; deployment provenance is not attributable");
}

const rewards = getAddress(deployPairs[0].tx.contractAddress);
const boost = getAddress(deployPairs[1].tx.contractAddress);
if (!deployPairs[2].tx.transaction.to || getAddress(deployPairs[2].tx.transaction.to) !== rewards) {
  fail("reward-source artifact transaction targeted the wrong contract");
}
const expectedRewardsInit = encodeDeployData({
  abi: runtimeArtifacts.lockRewards.abi,
  bytecode: runtimeArtifacts.lockRewards.bytecode.object,
  args: [HOOKR_TOKEN, EXPECTED_DEPLOYER],
});
const expectedBoostInit = encodeDeployData({
  abi: runtimeArtifacts.launchBoost.abi,
  bytecode: runtimeArtifacts.launchBoost.bytecode.object,
  args: [HOOKR_TOKEN, launchpad, rewards],
});
if (!sameHex(deployPairs[0].tx.transaction.input, expectedRewardsInit)) {
  fail("LockRewards artifact initcode is not the canonical reviewed constructor encoding");
}
if (!sameHex(deployPairs[1].tx.transaction.input, expectedBoostInit)) {
  fail("LaunchBoost artifact initcode is not the canonical reviewed constructor encoding");
}
let sourceCall;
try {
  sourceCall = decodeFunctionData({ abi: setSourceAbi, data: deployPairs[2].tx.transaction.input });
} catch (error) {
  fail(`reward-source calldata cannot be decoded: ${error.message}`);
}
if (
  sourceCall.functionName !== "setRewardSourceOnce" ||
  getAddress(sourceCall.args[0]) !== boost ||
  !sameHex(
    encodeFunctionData({ abi: setSourceAbi, functionName: sourceCall.functionName, args: sourceCall.args }),
    deployPairs[2].tx.transaction.input,
  )
) {
  fail("reward-source transaction is not canonical one-shot linkage to LaunchBoost");
}

const client = createPublicClient({ transport: http(RPC) });
if ((await client.getChainId()) !== 4663) fail("RPC is not Robinhood Chain 4663");
const finalizedTag = REHEARSAL ? "latest" : "finalized";
const finalizedHead = await client.getBlock({ blockTag: finalizedTag });
if (!finalizedHead.hash) fail(`${finalizedTag} evidence head has no hash`);
const canonicalFinalized = await client.getBlock({ blockNumber: finalizedHead.number });
if (!sameHex(canonicalFinalized.hash, finalizedHead.hash)) fail(`${finalizedTag} head is not canonical`);
const stateTag = REHEARSAL ? "latest" : "safe";
const stateHead = await client.getBlock({ blockTag: stateTag });
try {
  assertStateEvidenceAfterFinality(finalizedHead, stateHead);
} catch (error) {
  fail(`state evidence head: ${error.message}`);
}
const at = { blockHash: stateHead.hash };
let coreProof;
try {
  coreProof = await verifyUtilityCorePrerequisite({
    client,
    manifest: coreManifest,
    releaseGateBlockers: coreHelpers.releaseGateBlockers,
    releaseIdOf: coreHelpers.releaseIdOf,
    expectedLaunchpadAddress: launchpad,
    expectedLaunchpadRuntimeHash: LAUNCHPAD_CODEHASH,
    blockTag: stateTag,
    pinnedBlock: stateHead,
  });
} catch (error) {
  fail(`generation-4 core prerequisite: ${error.message}`);
}

const labels = ["LockRewards CREATE", "LaunchBoost CREATE", "reward-source linkage"];
const liveRecords = [];
const order = [];
const blockCache = new Map();
for (let index = 0; index < deployPairs.length; index += 1) {
  const label = labels[index];
  const { tx: artifactTx, receipt: artifactReceipt } = deployPairs[index];
  let receipt;
  try {
    receipt = await client.getTransactionReceipt({ hash: artifactTx.hash });
  } catch {
    fail(`${label} receipt is not on the selected chain`);
  }
  const transaction = await client.getTransaction({ hash: artifactTx.hash });
  if (receipt.status !== "success") fail(`${label} receipt did not succeed`);
  if (getAddress(receipt.from) !== EXPECTED_DEPLOYER || getAddress(transaction.from) !== EXPECTED_DEPLOYER) {
    fail(`${label} sender is wrong`);
  }
  if (!sameHex(transaction.input, artifactTx.transaction.input)) fail(`${label} live calldata differs from artifact`);
  if (receipt.blockNumber !== BigInt(artifactReceipt.blockNumber)) fail(`${label} artifact block is wrong`);
  if (!sameHex(receipt.blockHash, artifactReceipt.blockHash)) fail(`${label} artifact block hash is wrong`);
  if (BigInt(transaction.value) !== 0n) fail(`${label} sent native value`);

  const cacheKey = receipt.blockNumber.toString();
  let block = blockCache.get(cacheKey);
  if (!block) {
    block = await client.request({
      method: "eth_getBlockByNumber",
      params: [toHex(receipt.blockNumber), false],
    });
    blockCache.set(cacheKey, block);
  }
  if (!block || !sameHex(block.hash, receipt.blockHash)) fail(`${label} is not bound to its canonical header`);
  if (!REHEARSAL && !/^0x[0-9a-fA-F]+$/.test(String(block.l1BlockNumber ?? ""))) {
    fail(`${label} header has no Robinhood l1BlockNumber`);
  }

  liveRecords.push({ receipt, transaction });
  order.push({
    label,
    hash: artifactTx.hash,
    blockNumber: receipt.blockNumber,
    transactionIndex: receipt.transactionIndex,
  });
}
try {
  assertStrictReceiptOrder(order);
  assertReceiptsWithinEvidenceBlock(order, finalizedHead);
} catch (error) {
  fail(`receipt evidence: ${error.message}`);
}

for (const [index, expectedAddress] of [[0, rewards], [1, boost]]) {
  const { receipt, transaction } = liveRecords[index];
  if (transaction.to !== null) fail(`${labels[index]} unexpectedly has a call target`);
  if (!receipt.contractAddress || getAddress(receipt.contractAddress) !== expectedAddress) {
    fail(`${labels[index]} created the wrong address`);
  }
}
if (!liveRecords[2].transaction.to || getAddress(liveRecords[2].transaction.to) !== rewards) {
  fail("reward-source linkage targeted the wrong contract");
}
const sourceEvents = [];
for (const log of liveRecords[2].receipt.logs) {
  if (getAddress(log.address) !== rewards) continue;
  try {
    const decoded = decodeEventLog({
      abi: setSourceAbi,
      eventName: "RewardSourceSet",
      data: log.data,
      topics: log.topics,
      strict: true,
    });
    if (decoded.eventName === "RewardSourceSet") sourceEvents.push(decoded.args);
  } catch {
    // Unrelated logs cannot satisfy the linkage proof.
  }
}
if (sourceEvents.length !== 1 || getAddress(sourceEvents[0].source) !== boost) {
  fail("reward-source linkage did not emit the exact RewardSourceSet(boost) event");
}

const runtime = async (address, label) => {
  const code = await client.getCode({ address, ...at });
  if (!code || code === "0x") fail(`${label} has no runtime at the pinned state head`);
  return code;
};
const [rewardsCode, boostCode, hookrCode, launchpadCode] = await Promise.all([
  runtime(rewards, "LockRewards"),
  runtime(boost, "LaunchBoost"),
  runtime(HOOKR_TOKEN, "HOOKR token"),
  runtime(launchpad, "supported launchpad"),
]);
if (!sameHex(keccak256(hookrCode), HOOKR_RUNTIME_CODEHASH)) fail("HOOKR token runtime is not reviewed");
if (!sameHex(keccak256(launchpadCode), LAUNCHPAD_CODEHASH)) fail("launchpad runtime hash is not promoted");
const read = (address, abi, functionName, args = []) =>
  client.readContract({ address, abi, functionName, args, ...at });
const [
  bootstrapEpochLength,
  bootstrapStartedAt,
  feeEpochStartsAt,
  claimEpochStartsAt,
  weeklyEpochsStartAt,
  boostingOpensAt,
  boostingOpen,
] = await Promise.all([
  read(rewards, rewardsAbi, "BOOTSTRAP_EPOCH_LENGTH"),
  read(rewards, rewardsAbi, "bootstrapStartedAt"),
  read(rewards, rewardsAbi, "feeEpochStartsAt"),
  read(rewards, rewardsAbi, "claimEpochStartsAt"),
  read(rewards, rewardsAbi, "weeklyEpochsStartAt"),
  read(boost, boostAbi, "boostingOpensAt"),
  read(boost, boostAbi, "boostingOpen"),
]);
const rewardsDeployHeader = blockCache.get(liveRecords[0].receipt.blockNumber.toString());
const rewardsDeployTimestamp = BigInt(rewardsDeployHeader?.timestamp ?? -1);
const bootstrapStart = BigInt(bootstrapStartedAt);
const feeStart = BigInt(feeEpochStartsAt);
const claimStart = BigInt(claimEpochStartsAt);
const weeklyStart = BigInt(weeklyEpochsStartAt);
const bootstrapLength = BigInt(bootstrapEpochLength);
if (bootstrapLength !== 7_200n) fail("bootstrap epoch length is not exactly two hours");
if (bootstrapStart !== rewardsDeployTimestamp) fail("bootstrap start does not equal the Rewards deployment block timestamp");
if (feeStart !== bootstrapStart + bootstrapLength) fail("fee epoch does not start exactly two hours after deployment");
if (claimStart !== feeStart + bootstrapLength) fail("claim epoch does not start exactly two hours after fee opening");
const mondayOffset = 4n * 24n * 60n * 60n;
const week = 7n * 24n * 60n * 60n;
const currentMonday = mondayOffset + ((claimStart - mondayOffset) / week) * week;
const strictNextMonday = currentMonday > claimStart ? currentMonday : currentMonday + week;
if (weeklyStart !== strictNextMonday) fail("weekly epochs do not start on the first Monday strictly after claim opening");
if (BigInt(boostingOpensAt) !== feeStart) fail("LaunchBoost opening does not equal the immutable fee epoch start");
if (boostingOpen !== (BigInt(stateHead.timestamp) >= feeStart)) fail("LaunchBoost open state disagrees with the pinned state timestamp");
try {
  validateReviewedUtilityV2Runtime({
    artifact: runtimeArtifacts.lockRewards,
    liveCode: rewardsCode,
    expectedTarget: UTILITY_V2_RUNTIME_ARTIFACTS.lockRewards,
    expectedImmutableWords: [
      utilityV2AddressWord(HOOKR_TOKEN),
      utilityV2UintWord(bootstrapStart),
      utilityV2UintWord(feeStart),
      utilityV2UintWord(claimStart),
      utilityV2UintWord(weeklyStart),
    ],
    expectedNormalizedTemplateHash: REVIEWED_UTILITY_V2_NORMALIZED_RUNTIME_HASHES.lockRewards,
    expectedReferenceLayoutHash: REVIEWED_UTILITY_V2_RUNTIME_REFERENCE_LAYOUT_HASHES.lockRewards,
  });
  validateReviewedUtilityV2Runtime({
    artifact: runtimeArtifacts.launchBoost,
    liveCode: boostCode,
    expectedTarget: UTILITY_V2_RUNTIME_ARTIFACTS.launchBoost,
    expectedImmutableWords: [
      utilityV2AddressWord(HOOKR_TOKEN),
      utilityV2AddressWord(launchpad),
      utilityV2AddressWord(rewards),
      utilityV2UintWord(feeStart),
    ],
    expectedNormalizedTemplateHash: REVIEWED_UTILITY_V2_NORMALIZED_RUNTIME_HASHES.launchBoost,
    expectedReferenceLayoutHash: REVIEWED_UTILITY_V2_RUNTIME_REFERENCE_LAYOUT_HASHES.launchBoost,
  });
} catch (error) {
  fail(`reviewed utility runtime comparison: ${error.message}`);
}

const equalityChecks = [
  [await read(HOOKR_TOKEN, hookrAbi, "name"), "Hookr.fun", "HOOKR name"],
  [await read(HOOKR_TOKEN, hookrAbi, "symbol"), "HOOKR", "HOOKR symbol"],
  [await read(HOOKR_TOKEN, hookrAbi, "decimals"), 18, "HOOKR decimals"],
  [await read(HOOKR_TOKEN, hookrAbi, "totalSupply"), 1000000000000000000000000000n, "HOOKR supply"],
  [await read(launchpad, launchpadAbi, "contractName"), "HookrLaunchpad", "launchpad identity"],
  [await read(launchpad, launchpadAbi, "contractVersion"), "1.0.0", "launchpad version"],
  [await read(rewards, rewardsAbi, "contractName"), "HookrLockRewards", "LockRewards identity"],
  [await read(rewards, rewardsAbi, "contractVersion"), "2", "LockRewards version"],
  [getAddress(await read(rewards, rewardsAbi, "hookrToken")), HOOKR_TOKEN, "LockRewards token"],
  [getAddress(await read(rewards, rewardsAbi, "configurator")), getAddress("0x0000000000000000000000000000000000000000"), "burned configurator"],
  [getAddress(await read(rewards, rewardsAbi, "rewardSource")), boost, "reward source"],
  [await read(rewards, rewardsAbi, "EPOCH_LENGTH"), 604800, "weekly epoch"],
  [await read(rewards, rewardsAbi, "MONDAY_EPOCH_OFFSET"), 345600, "Monday offset"],
  [bootstrapEpochLength, 7200, "bootstrap epoch"],
  [bootstrapStartedAt, Number(bootstrapStart), "bootstrap start"],
  [feeEpochStartsAt, Number(feeStart), "fee epoch start"],
  [claimEpochStartsAt, Number(claimStart), "claim epoch start"],
  [weeklyEpochsStartAt, Number(weeklyStart), "weekly epoch start"],
  [await read(boost, boostAbi, "contractName"), "HookrLaunchBoost", "LaunchBoost identity"],
  [await read(boost, boostAbi, "contractVersion"), "2", "LaunchBoost version"],
  [getAddress(await read(boost, boostAbi, "hookrToken")), HOOKR_TOKEN, "LaunchBoost token"],
  [getAddress(await read(boost, boostAbi, "launchpad")), launchpad, "LaunchBoost launchpad"],
  [getAddress(await read(boost, boostAbi, "lockRewards")), rewards, "LaunchBoost rewards"],
  [await read(boost, boostAbi, "BOOST_FEE_BPS"), 100, "boost fee bps"],
  [await read(boost, boostAbi, "MIN_GROSS_BOOST"), 100_000_000_000_000_000_000n, "minimum gross boost"],
  [await read(boost, boostAbi, "MAX_ACTIVE_BOOSTS"), 512, "active boost capacity"],
  [boostingOpensAt, Number(feeStart), "Boost opening time"],
];
for (const [actual, expected, label] of equalityChecks) {
  if (actual !== expected) fail(`${label}: expected ${expected}, read ${actual}`);
}
if (/^0x0+$/.test(await read(HOOKR_TOKEN, hookrAbi, "DOMAIN_SEPARATOR"))) {
  fail("HOOKR EIP-2612 domain separator is zero");
}
for (const [tier, duration, multiplier] of [[0, 2592000, 10000], [1, 7776000, 11500], [2, 15552000, 12500]]) {
  const config = await read(rewards, rewardsAbi, "tierConfig", [tier]);
  if (config[0] !== duration || config[1] !== multiplier) fail(`tier ${tier} policy is wrong`);
}
const [
  currentEligibleWeight,
  positionCount,
  roundingCarry,
  totalLockedPrincipal,
  rewardReserve,
  cumulativeBoostFeesNotified,
  cumulativeRewardsClaimed,
  totalBoostPrincipal,
  cumulativeGrossBoosted,
  cumulativePrincipalAdded,
  cumulativeFeesForwarded,
  boostedTokensCount,
] = await Promise.all([
  read(rewards, rewardsAbi, "currentEligibleWeight"),
  read(rewards, rewardsAbi, "positionCount"),
  read(rewards, rewardsAbi, "roundingCarry"),
  read(rewards, rewardsAbi, "totalLockedPrincipal"),
  read(rewards, rewardsAbi, "rewardReserve"),
  read(rewards, rewardsAbi, "cumulativeBoostFeesNotified"),
  read(rewards, rewardsAbi, "cumulativeRewardsClaimed"),
  read(boost, boostAbi, "totalBoostPrincipal"),
  read(boost, boostAbi, "cumulativeGrossBoosted"),
  read(boost, boostAbi, "cumulativePrincipalAdded"),
  read(boost, boostAbi, "cumulativeFeesForwarded"),
  read(boost, boostAbi, "boostedTokensCount"),
]);
try {
  validateAmbientUtilityDeploymentAccounting({
    rewardReserve,
    cumulativeRewardsClaimed,
    cumulativeBoostFeesNotified,
    roundingCarry,
    cumulativeFeesForwarded,
    cumulativeGrossBoosted,
    cumulativePrincipalAdded,
    totalBoostPrincipal,
    boostedTokensCount,
    maxActiveBoosts: 512n,
  });
} catch (error) {
  fail(`ambient accounting: ${error.message}`);
}
if (!(await read(rewards, rewardsAbi, "checkpointCurrent"))) fail("LockRewards checkpoint is not current");
const rewardsSolvency = await read(rewards, rewardsAbi, "solvency");
if (!rewardsSolvency[4] || rewardsSolvency[0] !== rewardsSolvency[1] + rewardsSolvency[2] + rewardsSolvency[3]) {
  fail("LockRewards solvency identity failed");
}
const boostSolvency = await read(boost, boostAbi, "solvency");
if (!boostSolvency[3] || boostSolvency[0] !== boostSolvency[1] + boostSolvency[2]) {
  fail("LaunchBoost solvency identity failed");
}

const canonicalStateHead = await client.getBlock({ blockNumber: stateHead.number });
if (!sameHex(canonicalStateHead.hash, stateHead.hash)) fail(`pinned ${stateTag} state head was reorged`);

console.log("UTILITY V2 DEPLOYMENT PREFLIGHT OK (read-only)");
console.log(`  receipts ${finalizedTag} #${finalizedHead.number} ${finalizedHead.hash}`);
console.log(`  state    ${stateTag} #${stateHead.number} ${stateHead.hash}`);
console.log(`  source   ${sourceCommit}`);
console.log(`  core     ${coreProof.releaseId} canary ${coreProof.canaryToken}`);
console.log(`  launchpad ${launchpad} ${keccak256(launchpadCode)}`);
console.log(`  rewards   ${rewards} ${keccak256(rewardsCode)}`);
console.log(`  boost     ${boost} ${keccak256(boostCode)}`);
console.log(`  bootstrap ${bootstrapStart} -> fee ${feeStart} -> claim ${claimStart} -> weekly ${weeklyStart}`);
console.log(`  ambient   ${positionCount} positions; ${boostedTokensCount} boosts; ${totalLockedPrincipal} locked; ${currentEligibleWeight} eligible`);
console.log("  proof     3/3 canonical receipts; constructors, scalar immutables, one-shot linkage, policy and ambient-safe accounting exact");
