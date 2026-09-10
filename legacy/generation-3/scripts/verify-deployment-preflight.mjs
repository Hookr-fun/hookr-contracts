#!/usr/bin/env node
/**
 * Read-only, fail-closed generation-4 deployment preflight.
 *
 * This verifier runs after DeployRobinhood receipts exist but before the canary command is allowed
 * to load a signer or spend on its four transactions. It authenticates the finalized receipts,
 * CREATE/CREATE2 results, reviewed runtime templates, complete wiring, and all five house blueprint
 * semantics from live calldata + receipt logs + pinned readbacks. It never writes or broadcasts.
 *
 * Usage:
 *   node scripts/verify-deployment-preflight.mjs \
 *     --deploy contracts/broadcast/DeployRobinhood.s.sol/4663/run-latest.json \
 *     --rpc https://rpc.mainnet.chain.robinhood.com
 *
 * An explicit local fork rehearsal may add --rehearsal. That is the only mode allowed to use a
 * latest (rather than finalized) evidence head or a block header without Robinhood's l1BlockNumber.
 */
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import {
  createPublicClient,
  decodeEventLog,
  decodeFunctionData,
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
  canonicalCreate2Address,
  HOOK_PARAM_FIELDS,
  validateHouseBlueprintEvidence,
} from "./lib/release-promotion-evidence.mjs";
import {
  assertArtifactSourceHashes,
  REVIEWED_NORMALIZED_RUNTIME_HASHES,
  REVIEWED_RUNTIME_REFERENCE_LAYOUT_HASHES,
  validateReviewedRuntime,
} from "./lib/runtime-template-evidence.mjs";

const argv = process.argv.slice(2);
const flag = (name, fallback) => {
  const index = argv.indexOf(`--${name}`);
  return index >= 0 && argv[index + 1] ? argv[index + 1] : fallback;
};
const REHEARSAL = argv.includes("--rehearsal");
const DEPLOY_PATH = flag(
  "deploy",
  "contracts/broadcast/DeployRobinhood.s.sol/4663/run-latest.json",
);
const RPC = flag("rpc", "https://rpc.mainnet.chain.robinhood.com");

const rpcHostname = (() => {
  try {
    return new URL(RPC).hostname;
  } catch {
    return "";
  }
})();
const RPC_IS_LOOPBACK =
  rpcHostname === "localhost" ||
  rpcHostname === "::1" ||
  rpcHostname === "[::1]" ||
  /^127\./.test(rpcHostname);

const fail = (message) => {
  console.error(`\nDEPLOYMENT PREFLIGHT BLOCKED: ${message}`);
  process.exit(1);
};
const load = (path) => {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    fail(`cannot read ${path}: ${error.message}`);
  }
};
const sameHex = (left, right) =>
  typeof left === "string" &&
  typeof right === "string" &&
  left.toLowerCase() === right.toLowerCase();
const git = (...args) => execFileSync("git", args, { encoding: "utf8" }).trim();

if (!rpcHostname) fail(`--rpc is not a valid URL: ${RPC}`);
if (REHEARSAL && !RPC_IS_LOOPBACK) fail("--rehearsal is only allowed against loopback RPCs");
if (!REHEARSAL && RPC_IS_LOOPBACK) fail("a loopback deployment preflight requires --rehearsal");
if (!REHEARSAL && !RPC.startsWith("https://")) fail("production preflight requires an https RPC");

const EXPECTED_DEPLOYER = getAddress("0x5a52D4B820Ae7F02880d270562950918ACb14aA2");
const POOL_MANAGER = getAddress("0x8366a39CC670B4001A1121B8F6A443A643e40951");
const CREATE2_DEPLOYER = getAddress("0x4e59b44847b379578588920cA78FbF26c0B4956C");
const POOL_MANAGER_CODEHASH =
  "0xbd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626";
const CREATE2_DEPLOYER_CODEHASH =
  "0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989";
const HOOK_FLAGS =
  (1n << 13n) | (1n << 11n) | (1n << 7n) | (1n << 6n) | (1n << 3n) | (1n << 2n);

const RUNTIME_ARTIFACTS = Object.freeze({
  launchpad: {
    path: "contracts/out/HookrLaunchpad.sol/HookrLaunchpad.json",
    sourcePath: "src/HookrLaunchpad.sol",
    contractName: "HookrLaunchpad",
  },
  hook: {
    path: "contracts/out/HookrHook.sol/HookrHook.json",
    sourcePath: "src/HookrHook.sol",
    contractName: "HookrHook",
  },
  router: {
    path: "contracts/out/HookrSwapRouter.sol/HookrSwapRouter.json",
    sourcePath: "src/HookrSwapRouter.sol",
    contractName: "HookrSwapRouter",
  },
  launchpadLib: {
    path: "contracts/out/HookrLaunchpadLib.sol/HookrLaunchpadLib.json",
    sourcePath: "src/libraries/HookrLaunchpadLib.sol",
    contractName: "HookrLaunchpadLib",
  },
});

const identityAbi = parseAbi([
  "function contractName() view returns (string)",
  "function contractVersion() view returns (string)",
  "function hook() view returns (address)",
  "function launchpad() view returns (address)",
  "function poolManager() view returns (address)",
  "function owner() view returns (address)",
  "function blueprintsCount() view returns (uint256)",
]);
const setHookAbi = parseAbi(["function setHook(address newHook)"]);
const blueprintAbi = parseAbi([
  "function saveBlueprint(string name,(uint32 guardBlocks,uint16 maxBuyBps,uint24 snipeTaxPips,uint24 baseFeePips,uint24 maxFeePips,uint16 surgeSens,uint16 burnBps,uint96 burnTriggerWei,uint16 lpBps,uint16 potBps,uint32 potEveryNBuys,uint96 potMinBuyWei) params,uint16 royaltyBps) returns (uint32 id)",
  "function getBlueprint(uint32 id) view returns ((address author,uint16 royaltyBps,uint32 uses,uint40 savedAtBlock,string name,(uint32 guardBlocks,uint16 maxBuyBps,uint24 snipeTaxPips,uint24 baseFeePips,uint24 maxFeePips,uint16 surgeSens,uint16 burnBps,uint96 burnTriggerWei,uint16 lpBps,uint16 potBps,uint32 potEveryNBuys,uint96 potMinBuyWei) params) blueprint)",
  "event BlueprintSaved(uint32 indexed id,address indexed author,string name,uint16 royaltyBps)",
]);

const deployRun = load(DEPLOY_PATH);
if (deployRun.chain !== 4663) fail(`deploy artifact chain is ${deployRun.chain}, expected 4663`);
const runtimeArtifacts = Object.fromEntries(
  Object.entries(RUNTIME_ARTIFACTS).map(([key, target]) => [key, load(target.path)]),
);

const receiptMap = new Map();
for (const receipt of deployRun.receipts ?? []) {
  const hash = String(receipt.transactionHash ?? "").toLowerCase();
  if (receiptMap.has(hash)) fail(`deploy artifact contains duplicate receipt hash ${hash}`);
  receiptMap.set(hash, receipt);
}
const deployPairs = (deployRun.transactions ?? []).map((tx, index) => {
  const receipt = receiptMap.get(String(tx.hash ?? "").toLowerCase());
  if (!receipt) fail(`deploy tx #${index} has no hash-matched artifact receipt`);
  return { tx, receipt };
});
if (
  deployPairs.length !== 10 ||
  (deployRun.receipts ?? []).length !== 10 ||
  receiptMap.size !== 10
) {
  fail(
    `deploy artifact must contain exactly 10 transactions/receipts, found ${deployPairs.length}/${(deployRun.receipts ?? []).length}`,
  );
}
if (new Set(deployPairs.map(({ tx }) => String(tx.hash).toLowerCase())).size !== 10) {
  fail("deploy artifact contains duplicate transaction hashes");
}

const expectedShape = [
  { type: "CREATE2", contractName: "HookrLaunchpadLib" },
  { type: "CREATE", contractName: "HookrLaunchpad" },
  { type: "CREATE2", contractName: "HookrHook" },
  { type: "CREATE", contractName: "HookrSwapRouter" },
  { fn: "setHook" },
  { fn: "saveBlueprint" },
  { fn: "saveBlueprint" },
  { fn: "saveBlueprint" },
  { fn: "saveBlueprint" },
  { fn: "saveBlueprint" },
];
for (let index = 0; index < expectedShape.length; index += 1) {
  const expected = expectedShape[index];
  const { tx, receipt } = deployPairs[index];
  if (receipt.status !== "0x1") fail(`artifact tx #${index} is not successful`);
  if (getAddress(tx.transaction.from) !== EXPECTED_DEPLOYER) {
    fail(`artifact tx #${index} is not from the expected deployer`);
  }
  if (expected.type && tx.transactionType !== expected.type) {
    fail(`artifact tx #${index} is ${tx.transactionType}, expected ${expected.type}`);
  }
  if (expected.contractName && tx.contractName !== expected.contractName) {
    fail(`artifact tx #${index} is ${tx.contractName}, expected ${expected.contractName}`);
  }
  if (expected.fn && !String(tx.function ?? "").startsWith(expected.fn)) {
    fail(`artifact tx #${index} is ${tx.function}, expected ${expected.fn}()`);
  }
}

const artifactCommit = String(deployRun.commit ?? "").trim();
if (!artifactCommit) fail("deploy artifact has no source commit");
let sourceCommit;
try {
  sourceCommit = git("rev-parse", artifactCommit);
} catch {
  fail(`artifact commit ${artifactCommit} is not in this repository`);
}
const headCommit = git("rev-parse", "HEAD");
if (sourceCommit !== headCommit) {
  fail(
    `artifact commit ${sourceCommit.slice(0, 12)} is not current HEAD ${headCommit.slice(0, 12)}`,
  );
}
if (!REHEARSAL) {
  const dirty = git(
    "status",
    "--porcelain",
    "--",
    "contracts/src",
    "contracts/script",
    "contracts/lib",
    "contracts/foundry.toml",
    "contracts/run-canary.sh",
    "scripts/verify-deployment-preflight.mjs",
    "scripts/lib/release-promotion-evidence.mjs",
    "scripts/lib/runtime-template-evidence.mjs",
  );
  if (dirty) fail("deployment/canary source inputs are dirty; provenance is not attributable");
}
for (const [key, target] of Object.entries(RUNTIME_ARTIFACTS)) {
  try {
    assertArtifactSourceHashes(
      runtimeArtifacts[key],
      (sourcePath) => readFileSync(`contracts/${sourcePath}`),
      target.contractName,
    );
  } catch (error) {
    fail(`reviewed ${target.contractName} artifact: ${error.message}`);
  }
}

const launchpadLib = getAddress(deployPairs[0].tx.contractAddress);
const launchpad = getAddress(deployPairs[1].tx.contractAddress);
const hook = getAddress(deployPairs[2].tx.contractAddress);
const router = getAddress(deployPairs[3].tx.contractAddress);
if ((BigInt(hook) & 0x3fffn) !== HOOK_FLAGS) fail("hook address does not carry the 0x28cc flags");

const client = createPublicClient({ transport: http(RPC) });
const chainId = await client.getChainId();
if (chainId !== 4663) fail(`RPC chain id is ${chainId}, expected 4663`);
// Robinhood's production RPC authenticates a `finalized` header but rejects eth_call/getCode at
// that tag, its exact height, and its EIP-1898 hash. Keep receipt finality independent from state
// availability: every deploy receipt must be at or below the canonical finalized head, while all
// runtime/config/readback evidence uses one later exact safe block hash. Local Anvil rehearsals do
// not finalize newly mined transactions, so their latest head is both boundaries instead.
const receiptEvidenceTag = REHEARSAL ? "latest" : "finalized";
const finalizedHead = await client.getBlock({ blockTag: receiptEvidenceTag });
if (!finalizedHead?.hash || finalizedHead.number === null || finalizedHead.number === undefined) {
  fail(`${receiptEvidenceTag} receipt evidence head has no number or hash`);
}
const canonicalFinalizedHead = await client.getBlock({ blockNumber: finalizedHead.number });
if (!sameHex(canonicalFinalizedHead.hash, finalizedHead.hash)) {
  fail(`${receiptEvidenceTag} receipt evidence head is not canonical at its block number`);
}
const stateEvidenceTag = REHEARSAL ? "latest" : "safe";
const stateHead = await client.getBlock({ blockTag: stateEvidenceTag });
try {
  assertStateEvidenceAfterFinality(finalizedHead, stateHead);
} catch (error) {
  fail(`state evidence head: ${error.message}`);
}
// EIP-1898 hash pinning prevents the many parallel runtime/readback calls from observing different
// states. Continued canonicality is checked again after the last read and before success. This
// pre-spend verifier does not persist the safe hash; the promoter separately requires its state
// evidence hash to become finalized before writing it into the manifest.
const at = { blockHash: stateHead.hash };

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
];
const records = new Map();
const receiptOrder = [];
const blockCache = new Map();
for (let index = 0; index < labels.length; index += 1) {
  const label = labels[index];
  const { tx: artifactTx, receipt: artifactReceipt } = deployPairs[index];
  const hash = artifactTx.hash;
  let receipt;
  try {
    receipt = await client.getTransactionReceipt({ hash });
  } catch {
    fail(`${label} receipt ${hash} is not on the selected chain`);
  }
  const transaction = await client.getTransaction({ hash });
  if (receipt.status !== "success") fail(`${label} receipt did not succeed`);
  if (getAddress(receipt.from) !== EXPECTED_DEPLOYER || getAddress(transaction.from) !== EXPECTED_DEPLOYER) {
    fail(`${label} was not sent by the expected deployer`);
  }
  if (!sameHex(transaction.input, artifactTx.transaction.input)) {
    fail(`${label} live calldata differs from the attributed artifact`);
  }
  if (BigInt(artifactReceipt.blockNumber) !== receipt.blockNumber) {
    fail(`${label} artifact block differs from its live receipt`);
  }
  if (!sameHex(artifactReceipt.blockHash, receipt.blockHash)) {
    fail(`${label} artifact block hash differs from its live receipt`);
  }

  const cacheKey = receipt.blockNumber.toString();
  let block = blockCache.get(cacheKey);
  if (!block) {
    block = await client.request({
      method: "eth_getBlockByNumber",
      params: [toHex(receipt.blockNumber), false],
    });
    blockCache.set(cacheKey, block);
  }
  if (
    !block ||
    BigInt(block.number) !== receipt.blockNumber ||
    !sameHex(block.hash, receipt.blockHash)
  ) {
    fail(`${label} receipt is not bound to its canonical block header`);
  }
  const hasL1BlockNumber =
    typeof block.l1BlockNumber === "string" && /^0x[0-9a-fA-F]+$/.test(block.l1BlockNumber);
  if (!hasL1BlockNumber && !REHEARSAL) {
    fail(`${label} receipt header has no Robinhood l1BlockNumber`);
  }
  const contractBlockNumber = hasL1BlockNumber
    ? BigInt(block.l1BlockNumber)
    : receipt.blockNumber;
  receiptOrder.push({
    label,
    hash,
    blockNumber: receipt.blockNumber,
    transactionIndex: receipt.transactionIndex,
    contractBlockNumber,
  });
  records.set(label, { receipt, transaction, contractBlockNumber });
}
try {
  assertStrictReceiptOrder(receiptOrder);
  assertReceiptsWithinEvidenceBlock(receiptOrder, finalizedHead);
} catch (error) {
  fail(`${receiptEvidenceTag} receipt evidence: ${error.message}`);
}

const requireCall = (label, target) => {
  const record = records.get(label);
  if (!record.transaction.to || getAddress(record.transaction.to) !== target) {
    fail(`${label} targeted ${record.transaction.to ?? "nothing"}, expected ${target}`);
  }
  if (BigInt(record.transaction.value) !== 0n) fail(`${label} sent native value`);
};
for (const [label, target] of [
  ["launchpadLib", CREATE2_DEPLOYER],
  ["hook", CREATE2_DEPLOYER],
  ["setHook", launchpad],
  ["blueprint#1", launchpad],
  ["blueprint#2", launchpad],
  ["blueprint#3", launchpad],
  ["blueprint#4", launchpad],
  ["blueprint#5", launchpad],
]) requireCall(label, target);
for (const [label, expectedAddress] of [
  ["launchpad", launchpad],
  ["router", router],
]) {
  const record = records.get(label);
  if (!record.receipt.contractAddress || getAddress(record.receipt.contractAddress) !== expectedAddress) {
    fail(`${label} receipt created the wrong address`);
  }
  if (record.transaction.to !== null) fail(`${label} CREATE transaction unexpectedly has a target`);
  if (BigInt(record.transaction.value) !== 0n) fail(`${label} CREATE transaction sent native value`);
}
for (const [label, expectedAddress] of [
  ["launchpadLib", launchpadLib],
  ["hook", hook],
]) {
  let derived;
  try {
    derived = canonicalCreate2Address(CREATE2_DEPLOYER, records.get(label).transaction.input);
  } catch (error) {
    fail(`${label} CREATE2 calldata: ${error.message}`);
  }
  if (derived !== expectedAddress) {
    fail(`${label} CREATE2 calldata derives ${derived}, expected ${expectedAddress}`);
  }
}

const decodeCall = (record, abi, functionName, label) => {
  let decoded;
  try {
    decoded = decodeFunctionData({ abi, data: record.transaction.input });
  } catch (error) {
    fail(`${label} calldata cannot be decoded: ${error.message}`);
  }
  if (decoded.functionName !== functionName) fail(`${label} is not ${functionName}()`);
  if (
    !sameHex(
      encodeFunctionData({ abi, functionName, args: decoded.args }),
      record.transaction.input,
    )
  ) {
    fail(`${label} calldata is not canonical`);
  }
  return decoded;
};
const setHookCall = decodeCall(records.get("setHook"), setHookAbi, "setHook", "setHook");
if (getAddress(setHookCall.args[0]) !== hook) fail("setHook calldata names the wrong hook");

const runtime = async (address, label) => {
  const code = await client.getCode({ address, ...at });
  if (!code || code === "0x") fail(`${label} has no runtime at the state evidence head`);
  return code;
};
const [launchpadCode, hookCode, routerCode, launchpadLibCode, poolManagerCode, create2Code] =
  await Promise.all([
    runtime(launchpad, "launchpad"),
    runtime(hook, "hook"),
    runtime(router, "router"),
    runtime(launchpadLib, "launchpad library"),
    runtime(POOL_MANAGER, "PoolManager"),
    runtime(CREATE2_DEPLOYER, "canonical CREATE2 deployer"),
  ]);
if (!sameHex(keccak256(poolManagerCode), POOL_MANAGER_CODEHASH)) {
  fail("PoolManager runtime codehash is not reviewed");
}
if (!sameHex(keccak256(create2Code), CREATE2_DEPLOYER_CODEHASH)) {
  fail("canonical CREATE2 deployer runtime codehash is not reviewed");
}
try {
  validateReviewedRuntime({
    artifact: runtimeArtifacts.launchpad,
    liveCode: launchpadCode,
    expectedTarget: RUNTIME_ARTIFACTS.launchpad,
    expectedImmutableAddresses: [POOL_MANAGER],
    expectedLinks: { "src/libraries/HookrLaunchpadLib.sol:HookrLaunchpadLib": launchpadLib },
    expectedNormalizedTemplateHash: REVIEWED_NORMALIZED_RUNTIME_HASHES.launchpad,
    expectedReferenceLayoutHash: REVIEWED_RUNTIME_REFERENCE_LAYOUT_HASHES.launchpad,
  });
  validateReviewedRuntime({
    artifact: runtimeArtifacts.hook,
    liveCode: hookCode,
    expectedTarget: RUNTIME_ARTIFACTS.hook,
    expectedImmutableAddresses: [POOL_MANAGER, launchpad],
    expectedNormalizedTemplateHash: REVIEWED_NORMALIZED_RUNTIME_HASHES.hook,
    expectedReferenceLayoutHash: REVIEWED_RUNTIME_REFERENCE_LAYOUT_HASHES.hook,
  });
  validateReviewedRuntime({
    artifact: runtimeArtifacts.router,
    liveCode: routerCode,
    expectedTarget: RUNTIME_ARTIFACTS.router,
    expectedImmutableAddresses: [POOL_MANAGER, hook],
    expectedNormalizedTemplateHash: REVIEWED_NORMALIZED_RUNTIME_HASHES.router,
    expectedReferenceLayoutHash: REVIEWED_RUNTIME_REFERENCE_LAYOUT_HASHES.router,
  });
  validateReviewedRuntime({
    artifact: runtimeArtifacts.launchpadLib,
    liveCode: launchpadLibCode,
    expectedTarget: RUNTIME_ARTIFACTS.launchpadLib,
    expectedImmutableAddresses: [launchpadLib],
    expectedNormalizedTemplateHash: REVIEWED_NORMALIZED_RUNTIME_HASHES.launchpadLib,
    expectedReferenceLayoutHash: REVIEWED_RUNTIME_REFERENCE_LAYOUT_HASHES.launchpadLib,
  });
} catch (error) {
  fail(`reviewed runtime comparison: ${error.message}`);
}

const read = (address, functionName) =>
  client.readContract({ address, abi: identityAbi, functionName, ...at });
const checks = [
  [await read(launchpad, "contractName"), "HookrLaunchpad", "launchpad identity"],
  [await read(launchpad, "contractVersion"), "1.0.0", "launchpad version"],
  [await read(hook, "contractName"), "HookrHook", "hook identity"],
  [await read(hook, "contractVersion"), "1.0.0", "hook version"],
  [await read(router, "contractName"), "HookrSwapRouter", "router identity"],
  [await read(router, "contractVersion"), "1.0.0", "router version"],
  [getAddress(await read(launchpad, "hook")), hook, "launchpad hook"],
  [getAddress(await read(hook, "launchpad")), launchpad, "hook launchpad"],
  [getAddress(await read(hook, "poolManager")), POOL_MANAGER, "hook PoolManager"],
  [getAddress(await read(router, "hook")), hook, "router hook"],
  [getAddress(await read(router, "poolManager")), POOL_MANAGER, "router PoolManager"],
  [getAddress(await read(launchpad, "owner")), EXPECTED_DEPLOYER, "launchpad owner"],
];
for (const [actual, expected, label] of checks) {
  if (actual !== expected) fail(`${label}: expected ${expected}, read ${actual}`);
}
if (BigInt(await read(launchpad, "blueprintsCount")) < 6n) fail("house blueprints are missing");

const tupleField = (value, name, index) => value?.[name] ?? value?.[index];
const hookParamsShape = (value) =>
  Object.fromEntries(
    HOOK_PARAM_FIELDS.map((field, index) => [field, tupleField(value, field, index)]),
  );
const decodeOnlyBlueprintEvent = (record, label) => {
  const matches = [];
  for (const log of record.receipt.logs) {
    if (getAddress(log.address) !== launchpad) continue;
    try {
      const decoded = decodeEventLog({
        abi: blueprintAbi,
        eventName: "BlueprintSaved",
        data: log.data,
        topics: log.topics,
        strict: true,
      });
      if (decoded.eventName === "BlueprintSaved") matches.push(decoded.args);
    } catch {
      // Other launchpad events do not count.
    }
  }
  if (matches.length !== 1) fail(`${label} emitted ${matches.length} BlueprintSaved events`);
  return matches[0];
};
const blueprints = [];
for (let index = 0; index < 5; index += 1) {
  const id = index + 1;
  const label = `blueprint#${id}`;
  const record = records.get(label);
  const call = decodeCall(record, blueprintAbi, "saveBlueprint", label);
  const raw = await client.readContract({
    address: launchpad,
    abi: blueprintAbi,
    functionName: "getBlueprint",
    args: [id],
    ...at,
  });
  blueprints.push({
    id,
    transaction: {
      from: record.transaction.from,
      to: record.transaction.to,
      value: record.transaction.value,
      blockNumber: record.receipt.blockNumber,
      contractBlockNumber: record.contractBlockNumber,
    },
    calldata: {
      name: call.args[0],
      params: hookParamsShape(call.args[1]),
      royaltyBps: call.args[2],
    },
    event: decodeOnlyBlueprintEvent(record, label),
    readback: {
      author: tupleField(raw, "author", 0),
      royaltyBps: tupleField(raw, "royaltyBps", 1),
      uses: tupleField(raw, "uses", 2),
      savedAtBlock: tupleField(raw, "savedAtBlock", 3),
      name: tupleField(raw, "name", 4),
      params: hookParamsShape(tupleField(raw, "params", 5)),
    },
  });
}
try {
  validateHouseBlueprintEvidence({
    identities: { deployer: EXPECTED_DEPLOYER, launchpad },
    blueprints,
  });
} catch (error) {
  fail(`house blueprint evidence: ${error.message}`);
}

const canonicalStateHead = await client.getBlock({ blockNumber: stateHead.number });
if (!sameHex(canonicalStateHead.hash, stateHead.hash)) {
  fail(`pinned ${stateEvidenceTag} state evidence block was reorged during preflight`);
}

console.log("DEPLOYMENT PREFLIGHT OK (read-only)");
console.log(
  `  receipts ${receiptEvidenceTag} #${finalizedHead.number} ${finalizedHead.hash}`,
);
console.log(`  state    ${stateEvidenceTag} #${stateHead.number} ${stateHead.hash}`);
console.log(`  source   ${sourceCommit}`);
console.log(`  launchpad ${launchpad} ${keccak256(launchpadCode)}`);
console.log(`  hook      ${hook} ${keccak256(hookCode)}`);
console.log(`  router    ${router} ${keccak256(routerCode)}`);
console.log(`  library   ${launchpadLib} ${keccak256(launchpadLibCode)}`);
console.log(
  `  proof     10/10 receipts canonical and ${REHEARSAL ? "rehearsal-latest" : "finalized"}; blueprints 5/5 exact`,
);
