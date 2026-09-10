#!/usr/bin/env node
/**
 * Read-only verifier for the exact 3 deployment + 5 staged utility-canary receipts. It never
 * signs, broadcasts, or writes. `--json` emits the deterministic verified evidence object used by
 * the candidate promoter; all failures go to stderr and exit nonzero.
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
  assertStateEvidenceFinalized,
} from "./lib/release-promotion-evidence.mjs";
import {
  assertArtifactSourceHashes,
  validateReviewedRuntime,
} from "./lib/runtime-template-evidence.mjs";
import {
  REVIEWED_UTILITY_NORMALIZED_RUNTIME_HASHES,
  REVIEWED_UTILITY_RUNTIME_REFERENCE_LAYOUT_HASHES,
  UTILITY_RUNTIME_ARTIFACTS,
} from "./lib/utility-runtime-evidence.mjs";
import {
  UTILITY_CANARY_SPEC,
  UTILITY_RECEIPT_LABELS,
  validateUtilityCanaryEvidence,
} from "./lib/utility-canary-evidence.mjs";
import { verifyUtilityCorePrerequisite } from "./lib/utility-core-prerequisite.mjs";

const argv = process.argv.slice(2);
const flag = (name, fallback) => {
  const index = argv.indexOf(`--${name}`);
  return index >= 0 && argv[index + 1] ? argv[index + 1] : fallback;
};
const REHEARSAL = argv.includes("--rehearsal");
const JSON_OUTPUT = argv.includes("--json");
const RPC = flag("rpc", "https://rpc.mainnet.chain.robinhood.com");
const DEPLOY_PATH = flag("deploy", "contracts/broadcast/DeployHookrUtilities.s.sol/4663/run-latest.json");
const LOCK_PATH = flag("lock", "contracts/broadcast/CanaryHookrUtilitiesLock.s.sol/4663/run-latest.json");
const BOOST_PATH = flag("boost", "contracts/broadcast/CanaryHookrUtilitiesBoost.s.sol/4663/run-latest.json");
const CLAIM_PATH = flag("claim", "contracts/broadcast/CanaryHookrUtilitiesClaim.s.sol/4663/run-latest.json");
const CORE_RELEASE_PATH = flag("core-release", "");
const finalityTimeoutSeconds = Number(flag("finality-timeout-seconds", "300"));
if (!Number.isSafeInteger(finalityTimeoutSeconds) || finalityTimeoutSeconds < 0 || finalityTimeoutSeconds > 3600) {
  throw new Error("--finality-timeout-seconds must be an integer from 0 to 3600");
}

const fail = (message) => {
  console.error(`\nUTILITY CANARY EVIDENCE BLOCKED: ${message}`);
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
const asSafeNumber = (value, label) => {
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number < 0) fail(`${label} is not a safe nonnegative integer`);
  return number;
};
const jsonSafe = (value) =>
  JSON.parse(JSON.stringify(value, (_, item) => (typeof item === "bigint" ? item.toString() : item)));

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
if (!REHEARSAL && RPC_IS_LOOPBACK) fail("a loopback verifier requires --rehearsal");
if (!REHEARSAL && rpcUrl.protocol !== "https:") fail("production verification requires an https RPC");
if (CORE_RELEASE_PATH && !REHEARSAL) fail("--core-release override is rehearsal-only");

let core;
let coreHelpers;
try {
  coreHelpers = await import("../src/lib/release-manifest.ts");
} catch (error) {
  fail(`cannot load current core release helpers: ${error.message}`);
}
core = CORE_RELEASE_PATH ? load(CORE_RELEASE_PATH) : coreHelpers.CURRENT_RELEASE_MANIFEST;
if (Number(core?.chainId) !== 4663 || Number(core?.version) !== 4 || core?.productionAllowed !== true) {
  fail("current supported core release is not production-enabled generation 4");
}
const coreLaunchpad = getAddress(core.contracts.launchpad.address);
const coreLaunchpadHash = String(core.contracts.launchpad.runtimeCodeHash ?? core.contracts.launchpad.runtimeHash);
if (!/^0x[0-9a-fA-F]{64}$/.test(coreLaunchpadHash)) fail("core launchpad runtime hash is malformed");
const coreSourceCommit = String(core.evidence?.sourceCommit ?? core.sourceCommit ?? "").replace(/^0x/, "");
if (!/^[0-9a-fA-F]{40}$/.test(coreSourceCommit)) fail("core source commit is malformed");
const coreDeployBlock = asSafeNumber(core.deployBlock, "core deploy block");
if (coreDeployBlock === 0) fail("core deploy block is zero");
if (
  !Array.isArray(core.capabilities?.launchModes) ||
  !core.capabilities.launchModes.includes("curve") ||
  !core.capabilities.launchModes.includes("instant")
) {
  fail("supported core release does not evidence curve and instant launches");
}
const blockers = coreHelpers.releaseGateBlockers(core);
if (blockers.length !== 0) fail(`supported core release gate is closed: ${blockers.join("; ")}`);
const supportedCoreReleaseId = coreHelpers.releaseIdOf(core);
if (!/^hookr-4663-v4$/.test(supportedCoreReleaseId)) fail("supported core release id is not generation 4");

const artifactPairs = (path, expectedCount, label) => {
  const artifact = load(path);
  if (artifact.chain !== 4663) fail(`${label} artifact chain is ${artifact.chain}, expected 4663`);
  const receipts = new Map();
  for (const receipt of artifact.receipts ?? []) {
    const hash = String(receipt.transactionHash ?? "").toLowerCase();
    if (!/^0x[0-9a-f]{64}$/.test(hash)) fail(`${label} artifact has malformed receipt hash`);
    if (receipts.has(hash)) fail(`${label} artifact has duplicate receipt ${hash}`);
    receipts.set(hash, receipt);
  }
  const pairs = (artifact.transactions ?? []).map((tx, index) => {
    const receipt = receipts.get(String(tx.hash ?? "").toLowerCase());
    if (!receipt) fail(`${label} transaction #${index} has no hash-matched receipt`);
    if (receipt.status !== "0x1") fail(`${label} transaction #${index} did not succeed`);
    return { artifactTx: tx, artifactReceipt: receipt };
  });
  if (pairs.length !== expectedCount || receipts.size !== expectedCount) {
    fail(`${label} artifact must contain exactly ${expectedCount} transactions/receipts`);
  }
  return { artifact, pairs };
};

const deployArtifact = artifactPairs(DEPLOY_PATH, 3, "utility deploy");
const lockArtifact = artifactPairs(LOCK_PATH, 2, "lock stage");
const boostArtifact = artifactPairs(BOOST_PATH, 2, "boost stage");
const claimArtifact = artifactPairs(CLAIM_PATH, 1, "claim stage");
const artifacts = [deployArtifact, lockArtifact, boostArtifact, claimArtifact];

const artifactCommits = [];
for (const { artifact } of artifacts) {
  const commit = String(artifact.commit ?? "").trim();
  if (!commit) fail("one or more artifacts have no source commit");
  try {
    artifactCommits.push(git("rev-parse", commit));
  } catch {
    fail(`artifact commit ${commit} is not in this repository`);
  }
}
const sourceCommitRaw = artifactCommits[0];
const relevantPaths = [
  "contracts/foundry.toml",
  "contracts/src/HookrLockRewardsV1.sol",
  "contracts/src/HookrLaunchBoostV1.sol",
  "contracts/src/HookrLaunchpad.sol",
  "contracts/src/interfaces/IHookrLockRewardsV1.sol",
  "contracts/src/libraries/HookrTokenTransfer.sol",
  "contracts/script/DeployHookrUtilities.s.sol",
  "contracts/script/HookrUtilityCanaryBase.s.sol",
  "contracts/script/CanaryHookrUtilitiesLock.s.sol",
  "contracts/script/CanaryHookrUtilitiesBoost.s.sol",
  "contracts/script/CanaryHookrUtilitiesClaim.s.sol",
  "scripts/lib/utility-runtime-evidence.mjs",
  "scripts/lib/utility-core-prerequisite.mjs",
  "scripts/lib/utility-deployment-accounting.mjs",
  "scripts/lib/utility-canary-evidence.mjs",
  "scripts/verify-utility-core-prerequisite.mjs",
  "scripts/verify-utility-deployment-preflight.mjs",
  "scripts/verify-utility-canary-evidence.mjs",
  "scripts/promote-utility-release-candidate.mjs",
  "docs/HOOKR_UTILITY_TERMS_V1.md",
  "src/lib/boost-policy.ts",
  "src/lib/release-manifest.ts",
  "src/lib/utility-release-manifest.ts",
];
const differsOnRelevantPaths = (left, right) => {
  try {
    execFileSync("git", ["diff", "--quiet", left, right, "--", ...relevantPaths], { stdio: "ignore" });
    return false;
  } catch {
    return true;
  }
};
for (const artifactCommit of artifactCommits.slice(1)) {
  if (differsOnRelevantPaths(sourceCommitRaw, artifactCommit)) {
    fail("utility source/evidence inputs changed between deployment and a staged canary artifact");
  }
}
const headCommit = git("rev-parse", "HEAD");
if (differsOnRelevantPaths(sourceCommitRaw, headCommit)) {
  fail("current utility source/evidence inputs differ from the deployment source commit");
}
if (!REHEARSAL) {
  const dirty = git("status", "--porcelain", "--", ...relevantPaths);
  if (dirty) fail("utility source/evidence inputs are dirty; provenance is not attributable");
}

const runtimeArtifacts = Object.fromEntries(
  Object.entries(UTILITY_RUNTIME_ARTIFACTS).map(([key, target]) => [key, load(target.path)]),
);
for (const [key, target] of Object.entries(UTILITY_RUNTIME_ARTIFACTS)) {
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

const lockRewards = getAddress(deployArtifact.pairs[0].artifactTx.contractAddress);
const launchBoost = getAddress(deployArtifact.pairs[1].artifactTx.contractAddress);
const expectedDeployShape = [
  ["CREATE", "HookrLockRewardsV1"],
  ["CREATE", "HookrLaunchBoostV1"],
];
for (let index = 0; index < expectedDeployShape.length; index += 1) {
  const tx = deployArtifact.pairs[index].artifactTx;
  if (tx.transactionType !== expectedDeployShape[index][0] || tx.contractName !== expectedDeployShape[index][1]) {
    fail(`utility deployment transaction #${index} shape is wrong`);
  }
}
if (
  !deployArtifact.pairs[2].artifactTx.transaction.to ||
  getAddress(deployArtifact.pairs[2].artifactTx.transaction.to) !== lockRewards ||
  !String(deployArtifact.pairs[2].artifactTx.function ?? "").startsWith("setRewardSourceOnce")
) {
  fail("utility reward-source artifact transaction is wrong");
}
const expectedRewardsInit = encodeDeployData({
  abi: runtimeArtifacts.lockRewards.abi,
  bytecode: runtimeArtifacts.lockRewards.bytecode.object,
  args: [UTILITY_CANARY_SPEC.hookrToken, UTILITY_CANARY_SPEC.deployer],
});
const expectedBoostInit = encodeDeployData({
  abi: runtimeArtifacts.launchBoost.abi,
  bytecode: runtimeArtifacts.launchBoost.bytecode.object,
  args: [UTILITY_CANARY_SPEC.hookrToken, coreLaunchpad, lockRewards],
});
if (!sameHex(deployArtifact.pairs[0].artifactTx.transaction.input, expectedRewardsInit)) {
  fail("LockRewards deployment initcode is not the canonical reviewed constructor encoding");
}
if (!sameHex(deployArtifact.pairs[1].artifactTx.transaction.input, expectedBoostInit)) {
  fail("LaunchBoost deployment initcode is not the canonical reviewed constructor encoding");
}

const allPairs = [
  ...deployArtifact.pairs,
  ...lockArtifact.pairs,
  ...boostArtifact.pairs,
  ...claimArtifact.pairs,
];
const client = createPublicClient({ transport: http(RPC) });
if ((await client.getChainId()) !== 4663) fail("RPC is not Robinhood Chain 4663");

const receiptTag = REHEARSAL ? "latest" : "finalized";
const finalizedHead = await client.getBlock({ blockTag: receiptTag });
if (!finalizedHead?.hash) fail(`${receiptTag} head has no hash`);
const canonicalFinalized = await client.getBlock({ blockNumber: finalizedHead.number });
if (!sameHex(canonicalFinalized.hash, finalizedHead.hash)) fail(`${receiptTag} head is not canonical`);

const records = [];
const blockCache = new Map();
for (let index = 0; index < allPairs.length; index += 1) {
  const label = UTILITY_RECEIPT_LABELS[index];
  const pair = allPairs[index];
  const hash = pair.artifactTx.hash;
  let receipt;
  try {
    receipt = await client.getTransactionReceipt({ hash });
  } catch {
    fail(`${label} receipt is not on the selected chain`);
  }
  const transaction = await client.getTransaction({ hash });
  if (receipt.status !== "success") fail(`${label} receipt did not succeed`);
  if (
    getAddress(receipt.from) !== UTILITY_CANARY_SPEC.deployer ||
    getAddress(transaction.from) !== UTILITY_CANARY_SPEC.deployer
  ) {
    fail(`${label} sender is not the expected deployer`);
  }
  if (!sameHex(transaction.input, pair.artifactTx.transaction.input)) fail(`${label} live calldata differs from artifact`);
  if (receipt.blockNumber !== BigInt(pair.artifactReceipt.blockNumber)) fail(`${label} artifact block number is wrong`);
  if (!sameHex(receipt.blockHash, pair.artifactReceipt.blockHash)) fail(`${label} artifact block hash is wrong`);
  if (transaction.value !== 0n) fail(`${label} sent native value`);

  const blockKey = receipt.blockNumber.toString();
  let block = blockCache.get(blockKey);
  if (!block) {
    block = await client.request({ method: "eth_getBlockByNumber", params: [toHex(receipt.blockNumber), false] });
    blockCache.set(blockKey, block);
  }
  if (!block || !sameHex(block.hash, receipt.blockHash)) fail(`${label} is not bound to its canonical header`);
  const hasL1Clock = /^0x[0-9a-fA-F]+$/.test(String(block.l1BlockNumber ?? ""));
  if (!REHEARSAL && !hasL1Clock) fail(`${label} header has no Robinhood l1BlockNumber`);
  records.push({
    label,
    hash,
    receipt,
    transaction,
    blockNumber: receipt.blockNumber,
    transactionIndex: receipt.transactionIndex,
    timestamp: BigInt(block.timestamp),
    contractBlockNumber: hasL1Clock ? BigInt(block.l1BlockNumber) : receipt.blockNumber,
  });
}
try {
  assertStrictReceiptOrder(records);
  assertReceiptsWithinEvidenceBlock(records, finalizedHead);
} catch (error) {
  fail(`canonical receipt order/finality: ${error.message}`);
}

for (let index = 0; index < 2; index += 1) {
  const expected = index === 0 ? lockRewards : launchBoost;
  if (records[index].transaction.to !== null) fail(`${records[index].label} unexpectedly has a call target`);
  if (!records[index].receipt.contractAddress || getAddress(records[index].receipt.contractAddress) !== expected) {
    fail(`${records[index].label} created the wrong contract`);
  }
}
const expectedTargets = [
  lockRewards,
  UTILITY_CANARY_SPEC.hookrToken,
  lockRewards,
  UTILITY_CANARY_SPEC.hookrToken,
  launchBoost,
  lockRewards,
];
for (let index = 2; index < records.length; index += 1) {
  const expected = expectedTargets[index - 2];
  if (!records[index].transaction.to || getAddress(records[index].transaction.to) !== expected) {
    fail(`${records[index].label} targeted the wrong contract`);
  }
}

const tokenAbi = parseAbi([
  "function approve(address spender,uint256 amount) returns (bool)",
  "function allowance(address owner,address spender) view returns (uint256)",
  "event Approval(address indexed owner,address indexed spender,uint256 amount)",
  "event Transfer(address indexed from,address indexed to,uint256 amount)",
]);
const sourceAbi = parseAbi([
  "function setRewardSourceOnce(address source)",
  "event RewardSourceSet(address indexed source)",
]);
const rewardsAbi = parseAbi([
  "function lock(uint256 amount,uint8 tier,uint32 maxActivationEpoch,uint40 maxUnlockAt,uint256 deadline) returns (uint256 positionId)",
  "function claim(uint256 positionId,address to) returns (uint256 reward)",
  "function position(uint256 positionId) view returns ((address owner,uint128 principal,uint128 weight,uint40 unlockAt,uint32 activationEpoch,uint32 expiryEpoch,uint32 lastClaimEpoch,uint8 tier,bool withdrawn))",
  "function positionCount() view returns (uint256)",
  "function positionsOfCount(address owner) view returns (uint256)",
  "function positionsOf(address owner,uint256 offset,uint256 limit) view returns (uint256[] ids)",
  "function rewardIndexAtEpoch(uint32 epoch) view returns (uint256)",
  "function totalLockedPrincipal() view returns (uint256)",
  "function rewardReserve() view returns (uint256)",
  "function roundingCarry() view returns (uint256)",
  "function cumulativeBoostFeesNotified() view returns (uint256)",
  "function cumulativeRewardsClaimed() view returns (uint256)",
  "function checkpointCurrent() view returns (bool)",
  "function rewardSource() view returns (address)",
  "function configurator() view returns (address)",
  "function hookrToken() view returns (address)",
  "function solvency() view returns (uint256 balance,uint256 principal,uint256 rewards,uint256 surplus,bool solvent)",
  "event RewardSourceSet(address indexed source)",
  "event Locked(uint256 indexed positionId,address indexed owner,uint256 principal,uint8 tier,uint16 multiplierBps,uint32 activationEpoch,uint32 expiryEpoch,uint40 unlockAt,uint256 weight)",
  "event BoostFeeNotified(address indexed source,uint32 indexed epoch,uint256 amount)",
  "event RewardsClaimed(uint256 indexed positionId,address indexed owner,address indexed to,uint256 amount)",
]);
const boostAbi = parseAbi([
  "function boostByIntent(bytes32 intentId,uint256 grossAmount,uint8 tier,uint256 maxRewardFee,uint256 minPrincipalAdded,uint256 deadline) returns (address token,uint256 principalAdded,uint256 rewardFee)",
  "function boostOf(address token) view returns ((address creator,uint128 principal,uint40 startedAt,uint40 unlockAt,uint40 startedAtBlock,uint8 tier))",
  "function scoreOf(address token) view returns (uint256)",
  "function activePrincipalOf(address token) view returns (uint256)",
  "function boostedTokensCount() view returns (uint256)",
  "function boostedTokenIndexPlusOne(address token) view returns (uint16)",
  "function isBoostRegistered(address token) view returns (bool)",
  "function totalBoostPrincipal() view returns (uint256)",
  "function cumulativeGrossBoosted() view returns (uint256)",
  "function cumulativePrincipalAdded() view returns (uint256)",
  "function cumulativeFeesForwarded() view returns (uint256)",
  "function MIN_GROSS_BOOST() view returns (uint256)",
  "function MAX_ACTIVE_BOOSTS() view returns (uint16)",
  "function hookrToken() view returns (address)",
  "function launchpad() view returns (address)",
  "function lockRewards() view returns (address)",
  "function solvency() view returns (uint256 balance,uint256 principal,uint256 surplus,bool solvent)",
  "event BoostDeposited(address indexed token,address indexed creator,uint256 grossAmount,uint256 principalAdded,uint256 rewardFee,bool feeApplied,uint256 totalPrincipal,uint8 tier,uint16 multiplierBps,uint40 unlockAt,uint256 score)",
]);
const launchpadAbi = load("contracts/out/HookrLaunchpad.sol/HookrLaunchpad.json").abi;

const decodeCall = (record, abi, functionName) => {
  let decoded;
  try {
    decoded = decodeFunctionData({ abi, data: record.transaction.input });
  } catch (error) {
    fail(`${record.label} calldata cannot be decoded: ${error.message}`);
  }
  if (decoded.functionName !== functionName) fail(`${record.label} is not ${functionName}()`);
  if (!sameHex(encodeFunctionData({ abi, functionName, args: decoded.args }), record.transaction.input)) {
    fail(`${record.label} calldata is not canonical`);
  }
  return decoded.args;
};
const onlyEvents = (record, address, abi, eventName) => {
  const events = [];
  for (const log of record.receipt.logs) {
    if (getAddress(log.address) !== getAddress(address)) continue;
    try {
      const decoded = decodeEventLog({ abi, eventName, data: log.data, topics: log.topics, strict: true });
      if (decoded.eventName === eventName) events.push(decoded.args);
    } catch {
      // Other events from the same contract cannot satisfy this event proof.
    }
  }
  return events;
};
const exactlyOne = (events, label) => {
  if (events.length !== 1) fail(`${label} emitted ${events.length} matching events, expected exactly one`);
  return events[0];
};

const sourceArgs = decodeCall(records[2], sourceAbi, "setRewardSourceOnce");
if (getAddress(sourceArgs[0]) !== launchBoost) fail("reward-source calldata names the wrong source");
const sourceEvent = exactlyOne(onlyEvents(records[2], lockRewards, sourceAbi, "RewardSourceSet"), "reward source");
if (getAddress(sourceEvent.source) !== launchBoost) fail("RewardSourceSet event names the wrong source");

const approveLockArgs = decodeCall(records[3], tokenAbi, "approve");
const approveLockEvent = exactlyOne(onlyEvents(records[3], UTILITY_CANARY_SPEC.hookrToken, tokenAbi, "Approval"), "lock approval");
const lockArgs = decodeCall(records[4], rewardsAbi, "lock");
const lockTransfers = onlyEvents(records[4], UTILITY_CANARY_SPEC.hookrToken, tokenAbi, "Transfer");
const lockTransfer = exactlyOne(lockTransfers, "lock transfer");
const lockedEvent = exactlyOne(onlyEvents(records[4], lockRewards, rewardsAbi, "Locked"), "lock");

const approveBoostArgs = decodeCall(records[5], tokenAbi, "approve");
const approveBoostEvent = exactlyOne(onlyEvents(records[5], UTILITY_CANARY_SPEC.hookrToken, tokenAbi, "Approval"), "boost approval");
const boostArgs = decodeCall(records[6], boostAbi, "boostByIntent");
const boostTransfers = onlyEvents(records[6], UTILITY_CANARY_SPEC.hookrToken, tokenAbi, "Transfer");
if (boostTransfers.length !== 2) fail(`boost emitted ${boostTransfers.length} HOOKR transfers, expected exactly two`);
const feeEvent = exactlyOne(onlyEvents(records[6], lockRewards, rewardsAbi, "BoostFeeNotified"), "boost fee");
const boostEvent = exactlyOne(onlyEvents(records[6], launchBoost, boostAbi, "BoostDeposited"), "boost deposit");

const claimArgs = decodeCall(records[7], rewardsAbi, "claim");
const claimTransfer = exactlyOne(onlyEvents(records[7], UTILITY_CANARY_SPEC.hookrToken, tokenAbi, "Transfer"), "claim transfer");
const claimEvent = exactlyOne(onlyEvents(records[7], lockRewards, rewardsAbi, "RewardsClaimed"), "reward claim");

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
    manifest: core,
    releaseGateBlockers: coreHelpers.releaseGateBlockers,
    releaseIdOf: coreHelpers.releaseIdOf,
    expectedLaunchpadAddress: coreLaunchpad,
    expectedLaunchpadRuntimeHash: coreLaunchpadHash,
    blockTag: stateTag,
    pinnedBlock: stateHead,
  });
} catch (error) {
  fail(`generation-4 core prerequisite: ${error.message}`);
}
const runtime = async (address, label) => {
  const code = await client.getCode({ address, ...at });
  if (!code || code === "0x") fail(`${label} has no runtime at the pinned state head`);
  return code;
};
const [hookrCode, rewardsCode, boostCode, launchpadCode] = await Promise.all([
  runtime(UTILITY_CANARY_SPEC.hookrToken, "HOOKR token"),
  runtime(lockRewards, "LockRewards"),
  runtime(launchBoost, "LaunchBoost"),
  runtime(coreLaunchpad, "supported launchpad"),
]);
const runtimes = {
  hookrToken: keccak256(hookrCode),
  lockRewards: keccak256(rewardsCode),
  launchBoost: keccak256(boostCode),
  launchpad: keccak256(launchpadCode),
};
if (!sameHex(runtimes.hookrToken, UTILITY_CANARY_SPEC.hookrRuntimeCodehash)) fail("HOOKR runtime is not reviewed");
if (!sameHex(runtimes.launchpad, coreLaunchpadHash)) fail("launchpad runtime differs from supported core release");
try {
  validateReviewedRuntime({
    artifact: runtimeArtifacts.lockRewards,
    liveCode: rewardsCode,
    expectedTarget: UTILITY_RUNTIME_ARTIFACTS.lockRewards,
    expectedImmutableAddresses: [UTILITY_CANARY_SPEC.hookrToken],
    expectedNormalizedTemplateHash: REVIEWED_UTILITY_NORMALIZED_RUNTIME_HASHES.lockRewards,
    expectedReferenceLayoutHash: REVIEWED_UTILITY_RUNTIME_REFERENCE_LAYOUT_HASHES.lockRewards,
  });
  validateReviewedRuntime({
    artifact: runtimeArtifacts.launchBoost,
    liveCode: boostCode,
    expectedTarget: UTILITY_RUNTIME_ARTIFACTS.launchBoost,
    expectedImmutableAddresses: [UTILITY_CANARY_SPEC.hookrToken, coreLaunchpad, lockRewards],
    expectedNormalizedTemplateHash: REVIEWED_UTILITY_NORMALIZED_RUNTIME_HASHES.launchBoost,
    expectedReferenceLayoutHash: REVIEWED_UTILITY_RUNTIME_REFERENCE_LAYOUT_HASHES.launchBoost,
  });
} catch (error) {
  fail(`reviewed utility runtime comparison: ${error.message}`);
}

const read = (address, abi, functionName, args = []) =>
  client.readContract({ address, abi, functionName, args, ...at });
const launchToken = coreProof.canaryToken;
const launch = await read(coreLaunchpad, launchpadAbi, "getLaunch", [launchToken]);
if (getAddress(launch.token ?? launch[0]) !== launchToken) fail("canonical launch readback token is wrong");
if (getAddress(launch.creator ?? launch[1]) !== UTILITY_CANARY_SPEC.deployer) fail("canonical launch creator is wrong");

const lockedPositionId = BigInt(lockedEvent.positionId);
if (lockedPositionId <= 0n) fail("lock receipt has a zero position id");
const ownerPositionIds = await read(lockRewards, rewardsAbi, "positionsOf", [UTILITY_CANARY_SPEC.deployer, 0n, 2n]);
if (ownerPositionIds.length !== 1 || ownerPositionIds[0] !== lockedPositionId) {
  fail("deployer position list does not identify the lock receipt position");
}
const canaryPositionId = ownerPositionIds[0];
const lockPosition = await read(lockRewards, rewardsAbi, "position", [canaryPositionId]);
const boostPosition = await read(launchBoost, boostAbi, "boostOf", [launchToken]);
const lockSolvency = await read(lockRewards, rewardsAbi, "solvency");
const boostSolvency = await read(launchBoost, boostAbi, "solvency");
if (getAddress(await read(lockRewards, rewardsAbi, "hookrToken")) !== UTILITY_CANARY_SPEC.hookrToken) fail("LockRewards token link is wrong");
if (getAddress(await read(lockRewards, rewardsAbi, "rewardSource")) !== launchBoost) fail("reward source link is wrong");
if (getAddress(await read(lockRewards, rewardsAbi, "configurator")) !== getAddress("0x0000000000000000000000000000000000000000")) fail("configurator was not burned");
if (getAddress(await read(launchBoost, boostAbi, "hookrToken")) !== UTILITY_CANARY_SPEC.hookrToken) fail("LaunchBoost token link is wrong");
if (getAddress(await read(launchBoost, boostAbi, "launchpad")) !== coreLaunchpad) fail("LaunchBoost core link is wrong");
if (getAddress(await read(launchBoost, boostAbi, "lockRewards")) !== lockRewards) fail("LaunchBoost rewards link is wrong");
if (await read(launchBoost, boostAbi, "MIN_GROSS_BOOST") !== UTILITY_CANARY_SPEC.minGrossBoost) {
  fail("LaunchBoost minimum gross policy is wrong");
}
if (await read(launchBoost, boostAbi, "MAX_ACTIVE_BOOSTS") !== UTILITY_CANARY_SPEC.maxActiveBoosts) {
  fail("LaunchBoost active capacity policy is wrong");
}

const named = (tuple, names) => Object.fromEntries(names.map((name, index) => [name, tuple?.[name] ?? tuple?.[index]]));
const lockPositionNamed = named(lockPosition, [
  "owner", "principal", "weight", "unlockAt", "activationEpoch", "expiryEpoch", "lastClaimEpoch", "tier", "withdrawn",
]);
const boostPositionNamed = named(boostPosition, ["creator", "principal", "startedAt", "unlockAt", "startedAtBlock", "tier"]);
const claimStartEpoch = Number(lockPositionNamed.activationEpoch);
const claimEndEpoch = claimStartEpoch + 1;
const [claimStartIndex, claimEndIndex] = await Promise.all([
  read(lockRewards, rewardsAbi, "rewardIndexAtEpoch", [claimStartEpoch]),
  read(lockRewards, rewardsAbi, "rewardIndexAtEpoch", [claimEndEpoch]),
]);

const evidence = {
  chainId: 4663,
  sourceCommit: `0x${sourceCommitRaw}`,
  core: {
    id: supportedCoreReleaseId,
    version: 4,
    productionAllowed: true,
    sourceCommit: `0x${coreSourceCommit}`,
    launchpad: { address: coreLaunchpad, runtimeCodehash: coreLaunchpadHash },
  },
  identities: {
    deployer: UTILITY_CANARY_SPEC.deployer,
    hookrToken: UTILITY_CANARY_SPEC.hookrToken,
    lockRewards,
    launchBoost,
    launchpad: coreLaunchpad,
    launchToken,
  },
  runtimes,
  receiptOrder: records.map((record) => ({
    label: record.label,
    hash: record.hash,
    blockNumber: asSafeNumber(record.blockNumber, `${record.label} block`),
    transactionIndex: record.transactionIndex,
  })),
  receipts: {
    deployment: {
      lockRewardsDeploy: records[0].hash,
      launchBoostDeploy: records[1].hash,
      rewardSourceSet: records[2].hash,
    },
    canary: {
      approveLock: records[3].hash,
      lock: records[4].hash,
      approveBoost: records[5].hash,
      boost: records[6].hash,
      claim: records[7].hash,
    },
  },
  stages: {
    approveLock: {
      transaction: { from: records[3].transaction.from, to: records[3].transaction.to, value: records[3].transaction.value },
      calldata: { spender: approveLockArgs[0], amount: approveLockArgs[1] },
      event: approveLockEvent,
    },
    lock: {
      transaction: {
        from: records[4].transaction.from,
        to: records[4].transaction.to,
        value: records[4].transaction.value,
        timestamp: records[4].timestamp,
        blockNumber: records[4].blockNumber,
        contractBlockNumber: records[4].contractBlockNumber,
      },
      calldata: {
        amount: lockArgs[0],
        tier: lockArgs[1],
        maxActivationEpoch: lockArgs[2],
        maxUnlockAt: lockArgs[3],
        deadline: lockArgs[4],
      },
      transfer: lockTransfer,
      event: lockedEvent,
    },
    approveBoost: {
      transaction: { from: records[5].transaction.from, to: records[5].transaction.to, value: records[5].transaction.value },
      calldata: { spender: approveBoostArgs[0], amount: approveBoostArgs[1] },
      event: approveBoostEvent,
    },
    boost: {
      transaction: {
        from: records[6].transaction.from,
        to: records[6].transaction.to,
        value: records[6].transaction.value,
        timestamp: records[6].timestamp,
        blockNumber: records[6].blockNumber,
        contractBlockNumber: records[6].contractBlockNumber,
      },
      calldata: {
        intentId: boostArgs[0],
        grossAmount: boostArgs[1],
        tier: boostArgs[2],
        maxRewardFee: boostArgs[3],
        minPrincipalAdded: boostArgs[4],
        deadline: boostArgs[5],
      },
      grossTransfer: boostTransfers[0],
      feeTransfer: boostTransfers[1],
      feeEvent,
      event: boostEvent,
    },
    claim: {
      transaction: {
        from: records[7].transaction.from,
        to: records[7].transaction.to,
        value: records[7].transaction.value,
        timestamp: records[7].timestamp,
        blockNumber: records[7].blockNumber,
        contractBlockNumber: records[7].contractBlockNumber,
      },
      calldata: { positionId: claimArgs[0], to: claimArgs[1] },
      transfer: claimTransfer,
      event: claimEvent,
    },
  },
  canonicalLaunch: {
    intentId: UTILITY_CANARY_SPEC.coreIntentId,
    token: launchToken,
    creator: launch.creator ?? launch[1],
  },
  postconditions: {
    lockPosition: { positionId: canaryPositionId, ...lockPositionNamed },
    claimProof: {
      startEpoch: claimStartEpoch,
      endEpoch: claimEndEpoch,
      startIndex: claimStartIndex,
      endIndex: claimEndIndex,
    },
    boostPosition: boostPositionNamed,
    allowances: {
      lockRewards: await read(UTILITY_CANARY_SPEC.hookrToken, tokenAbi, "allowance", [
        UTILITY_CANARY_SPEC.deployer,
        lockRewards,
      ]),
      launchBoost: await read(UTILITY_CANARY_SPEC.hookrToken, tokenAbi, "allowance", [
        UTILITY_CANARY_SPEC.deployer,
        launchBoost,
      ]),
    },
    lockAccounting: {
      positionCount: await read(lockRewards, rewardsAbi, "positionCount"),
      ownerPositionCount: await read(lockRewards, rewardsAbi, "positionsOfCount", [UTILITY_CANARY_SPEC.deployer]),
      totalPrincipal: await read(lockRewards, rewardsAbi, "totalLockedPrincipal"),
      rewardReserve: await read(lockRewards, rewardsAbi, "rewardReserve"),
      roundingCarry: await read(lockRewards, rewardsAbi, "roundingCarry"),
      feesNotified: await read(lockRewards, rewardsAbi, "cumulativeBoostFeesNotified"),
      rewardsClaimed: await read(lockRewards, rewardsAbi, "cumulativeRewardsClaimed"),
      checkpointCurrent: await read(lockRewards, rewardsAbi, "checkpointCurrent"),
    },
    boostAccounting: {
      maxActiveBoosts: await read(launchBoost, boostAbi, "MAX_ACTIVE_BOOSTS"),
      boostedTokensCount: await read(launchBoost, boostAbi, "boostedTokensCount"),
      tokenIndexPlusOne: await read(launchBoost, boostAbi, "boostedTokenIndexPlusOne", [launchToken]),
      registered: await read(launchBoost, boostAbi, "isBoostRegistered", [launchToken]),
      totalPrincipal: await read(launchBoost, boostAbi, "totalBoostPrincipal"),
      grossBoosted: await read(launchBoost, boostAbi, "cumulativeGrossBoosted"),
      principalAdded: await read(launchBoost, boostAbi, "cumulativePrincipalAdded"),
      feesForwarded: await read(launchBoost, boostAbi, "cumulativeFeesForwarded"),
      score: await read(launchBoost, boostAbi, "scoreOf", [launchToken]),
      activePrincipal: await read(launchBoost, boostAbi, "activePrincipalOf", [launchToken]),
    },
    lockSolvency: named(lockSolvency, ["balance", "principal", "rewards", "surplus", "solvent"]),
    boostSolvency: named(boostSolvency, ["balance", "principal", "surplus", "solvent"]),
  },
  linkage: {
    blockNumber: asSafeNumber(stateHead.number, "state evidence block"),
    blockHash: stateHead.hash,
  },
};

try {
  validateUtilityCanaryEvidence(evidence);
} catch (error) {
  fail(`semantic evidence: ${error.message}`);
}

const canonicalStateHead = await client.getBlock({ blockNumber: stateHead.number });
if (!sameHex(canonicalStateHead.hash, stateHead.hash)) fail(`pinned ${stateTag} state block was reorged`);

let finalityConfirmation = finalizedHead;
if (!REHEARSAL) {
  const deadline = Date.now() + finalityTimeoutSeconds * 1000;
  while (finalityConfirmation.number < stateHead.number) {
    if (Date.now() >= deadline) {
      fail(`state evidence block ${stateHead.number} is not finalized; rerun after finality advances`);
    }
    await new Promise((resolve) => setTimeout(resolve, 5_000));
    finalityConfirmation = await client.getBlock({ blockTag: "finalized" });
  }
  const finalizedStateHeader = await client.getBlock({ blockNumber: stateHead.number });
  try {
    assertStateEvidenceFinalized(finalityConfirmation, stateHead, finalizedStateHeader);
  } catch (error) {
    fail(`state evidence finalization: ${error.message}`);
  }
}

const output = jsonSafe({
  ...evidence,
  finality: {
    receiptHead: { blockNumber: asSafeNumber(finalizedHead.number, "receipt finality block"), blockHash: finalizedHead.hash },
    readbackFinalizedThrough: {
      blockNumber: asSafeNumber(finalityConfirmation.number, "readback finality block"),
      blockHash: finalityConfirmation.hash,
    },
  },
});

if (JSON_OUTPUT) {
  process.stdout.write(`${JSON.stringify(output)}\n`);
} else {
  console.log("UTILITY CANARY EVIDENCE OK (read-only)");
  console.log(`  source ${output.sourceCommit}`);
  console.log(`  core   ${output.core.id} ${output.identities.launchpad}`);
  console.log(`  deploy 3/3 exact; canary 5/5 exact`);
  console.log(`  readback #${output.linkage.blockNumber} ${output.linkage.blockHash} finalized`);
}
