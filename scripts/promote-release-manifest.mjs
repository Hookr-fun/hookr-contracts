#!/usr/bin/env node
/**
 * Hookr release promotion.
 *
 * Consumes the two live broadcast artifacts (DeployRobinhood, CanaryRobinhood), verifies every
 * receipt in order, re-reads the deployed contracts at one pinned block over live RPC, and only
 * then rewrites CURRENT_RELEASE_MANIFEST in src/lib/release-manifest.ts. Every check fails closed:
 * a mismatch prints the reason and leaves the manifest untouched.
 *
 * Usage:
 *   node scripts/promote-release-manifest.mjs \
 *     [--deploy contracts/broadcast/DeployRobinhood.s.sol/4663/run-latest.json] \
 *     [--canary contracts/broadcast/CanaryRobinhood.s.sol/4663/run-latest.json] \
 *     [--rpc https://rpc.mainnet.chain.robinhood.com] \
 *     [--dry-run]
 */
import { readFileSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import {
  createPublicClient,
  decodeEventLog,
  decodeFunctionData,
  encodeFunctionData,
  encodePacked,
  getAddress,
  http,
  keccak256,
  parseAbi,
  toHex,
  toEventSelector,
  toFunctionSelector,
} from "viem";
import {
  assertStrictReceiptOrder,
  INSTANT_CANARY_SPEC,
  validateInstantCanaryEvidence,
} from "./lib/instant-canary-evidence.mjs";
import {
  assertReceiptsWithinEvidenceBlock,
  assertStateEvidenceAfterFinality,
  assertStateEvidenceFinalized,
  canonicalCreate2Address,
  deriveLiveLaunchpadDeployBlock,
  HOOK_PARAM_FIELDS,
  validateHouseBlueprintEvidence,
} from "./lib/release-promotion-evidence.mjs";
import { replaceCurrentReleaseManifest } from "./lib/release-manifest-patch.mjs";
import {
  assertArtifactSourceHashes,
  REVIEWED_NORMALIZED_RUNTIME_HASHES,
  REVIEWED_RUNTIME_REFERENCE_LAYOUT_HASHES,
  validateReviewedRuntime,
} from "./lib/runtime-template-evidence.mjs";

const args = process.argv.slice(2);
const flag = (name, fallback) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
};
const DRY_RUN = args.includes("--dry-run");
const DEPLOY_PATH = flag("deploy", "contracts/broadcast/DeployRobinhood.s.sol/4663/run-latest.json");
const CANARY_PATH = flag("canary", "contracts/broadcast/CanaryRobinhood.s.sol/4663/run-latest.json");
const RPC = flag("rpc", "https://rpc.mainnet.chain.robinhood.com");
const rpcHostname = (() => {
  try {
    return new URL(RPC).hostname;
  } catch {
    return "";
  }
})();
const RPC_IS_LOOPBACK =
  rpcHostname === "localhost" || rpcHostname === "::1" || rpcHostname === "[::1]" ||
  /^127\./.test(rpcHostname) || /^10\./.test(rpcHostname) || /^192\.168\./.test(rpcHostname) ||
  /^172\.(1[6-9]|2\d|3[01])\./.test(rpcHostname);
const MANIFEST_PATH = "src/lib/release-manifest.ts";
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

const EXPECTED_DEPLOYER = getAddress("0x5a52D4B820Ae7F02880d270562950918ACb14aA2");
const POOL_MANAGER = getAddress("0x8366a39CC670B4001A1121B8F6A443A643e40951");
/** Canonical CREATE2 factory. Salted deployments are calls to this, not direct CREATEs. */
const CREATE2_DEPLOYER = getAddress("0x4e59b44847b379578588920cA78FbF26c0B4956C");
const POOL_MANAGER_CODEHASH = "0xbd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626";
const CREATE2_DEPLOYER_CODEHASH =
  "0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989";
const HOOK_FLAGS =
  (1n << 13n) | (1n << 11n) | (1n << 7n) | (1n << 6n) | (1n << 3n) | (1n << 2n); // 0x28cc
const INSTANT_LAUNCH_SIGNATURE =
  "launchInstantWithIntent((string,string,string,string,address,uint96,uint32,(uint32,uint16,uint24,uint24,uint24,uint16,uint16,uint96,uint16,uint16,uint32,uint96),uint256,uint256,uint16,(address,uint16)[],(int24,int24,uint16)[]),uint16,bytes32)";
const INSTANT_LAUNCH_SELECTOR = toFunctionSelector(INSTANT_LAUNCH_SIGNATURE);
const INSTANT_LAUNCHED_TOPIC = toEventSelector("InstantLaunched(address,bytes32,uint16,uint96,uint256)");

const launchpadEvidenceAbi = parseAbi([
  "function launchInstantWithIntent((string name,string symbol,string tagline,string logoURI,address expectedCreator,uint96 targetRaiseWei,uint32 blueprintId,(uint32 guardBlocks,uint16 maxBuyBps,uint24 snipeTaxPips,uint24 baseFeePips,uint24 maxFeePips,uint16 surgeSens,uint16 burnBps,uint96 burnTriggerWei,uint16 lpBps,uint16 potBps,uint32 potEveryNBuys,uint96 potMinBuyWei) custom,uint256 creatorBuyWei,uint256 minTokensOut,uint16 creatorFeeBps,(address to,uint16 bps)[] feeRecipients,(int24 startOffset,int24 endOffset,uint16 bps)[] lpTranches) args,uint16 poolSupplyBps,bytes32 intentId) payable returns (address token)",
  "function creationFeeWei() view returns (uint96)",
  "function launchedByIntent(address creator,bytes32 intentId) view returns (address token)",
  "function previewInstantLaunch(uint256 ethIn,uint16 poolSupplyBps) view returns (uint256 tokensInPool,uint96 openPriceWei,uint160 sqrtPriceX96,uint256 openFdvWei,uint8 err)",
  "function getLaunch(address token) view returns ((address token,address creator,uint40 launchBlock,uint32 blueprintId,bool graduated,uint96 basePriceWei,uint96 targetWei,uint96 reserveWei,uint128 soldTokens,uint40 graduatedAtBlock,uint160 sqrtPriceX96AtGraduation,bytes32 poolId,(uint32 guardBlocks,uint16 maxBuyBps,uint24 snipeTaxPips,uint24 baseFeePips,uint24 maxFeePips,uint16 surgeSens,uint16 burnBps,uint96 burnTriggerWei,uint16 lpBps,uint16 potBps,uint32 potEveryNBuys,uint96 potMinBuyWei) hookParams) launch)",
  "event TokenLaunched(address indexed token,address indexed creator,uint32 indexed blueprintId,string name,string symbol,string tagline,string logoURI,uint96 targetWei,uint96 basePriceWei)",
  "event Graduated(address indexed token,bytes32 indexed poolId,uint160 sqrtPriceX96,uint256 ethLiquidity,uint256 tokenLiquidity,uint256 tokensBurned)",
  "event InstantLaunched(address indexed token,bytes32 indexed poolId,uint16 poolSupplyBps,uint96 openPriceWei,uint256 ethInPool)",
  "event LaunchIntentConsumed(address indexed creator,bytes32 indexed intentId,address indexed token)",
]);
const blueprintEvidenceAbi = parseAbi([
  "function saveBlueprint(string name,(uint32 guardBlocks,uint16 maxBuyBps,uint24 snipeTaxPips,uint24 baseFeePips,uint24 maxFeePips,uint16 surgeSens,uint16 burnBps,uint96 burnTriggerWei,uint16 lpBps,uint16 potBps,uint32 potEveryNBuys,uint96 potMinBuyWei) params,uint16 royaltyBps) returns (uint32 id)",
  "function getBlueprint(uint32 id) view returns ((address author,uint16 royaltyBps,uint32 uses,uint40 savedAtBlock,string name,(uint32 guardBlocks,uint16 maxBuyBps,uint24 snipeTaxPips,uint24 baseFeePips,uint24 maxFeePips,uint16 surgeSens,uint16 burnBps,uint96 burnTriggerWei,uint16 lpBps,uint16 potBps,uint32 potEveryNBuys,uint96 potMinBuyWei) params) blueprint)",
  "event BlueprintSaved(uint32 indexed id,address indexed author,string name,uint16 royaltyBps)",
]);
const routerEvidenceAbi = parseAbi([
  "function exactInput(((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) key,bool zeroForOne,uint128 amountIn,uint128 amountOutMinimum,uint160 sqrtPriceLimitX96,address recipient,uint256 deadline) p) payable returns (uint256 amountOut)",
  "event SwapExecuted(address indexed payer,address indexed recipient,address indexed token,bool zeroForOne,bool exactInput,uint256 amountIn,uint256 amountOut)",
]);
const tokenEvidenceAbi = parseAbi([
  "function approve(address spender,uint256 amount) returns (bool)",
  "function balanceOf(address account) view returns (uint256)",
  "function creator() view returns (address)",
  "function launchpad() view returns (address)",
  "function totalSupply() view returns (uint256)",
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function tagline() view returns (string)",
  "event Approval(address indexed owner,address indexed spender,uint256 value)",
]);
const hookEvidenceAbi = parseAbi([
  "function poolConfig(bytes32 poolId) view returns (bool initialized,uint40 guardEndBlock,uint24 baseFeePips,uint24 maxFeePips,uint24 snipeTaxPips,uint16 surgeSens,uint16 burnBps,uint16 lpBps,uint16 potBps,uint16 royaltyBps,uint32 potEveryNBuys,uint96 maxBuyWei,uint96 potMinBuyWei,uint96 burnTriggerWei,address royaltyTo,address token)",
  "function guardLpEarnedWei(bytes32 poolId) view returns (uint256)",
  "function totalHookFeesWei(bytes32 poolId) view returns (uint256)",
  "function totalBurnedTokens(bytes32 poolId) view returns (uint256)",
  "function totalLpDonatedWei(bytes32 poolId) view returns (uint256)",
  "function potWei(bytes32 poolId) view returns (uint256)",
  "function potBuyCount(bytes32 poolId) view returns (uint256)",
  "function burnVaultWei(bytes32 poolId) view returns (uint256)",
  "function nativeClaimBalance() view returns (uint256)",
  "event HookFeesAccrued(bytes32 indexed poolId,uint256 burnWei,uint256 lpWei,uint256 potWeiAdded,uint256 royaltyWei,address royaltyTo)",
  "event AutoBurn(bytes32 indexed poolId,uint256 tokensBurned)",
  "event LpRewardsDonated(bytes32 indexed poolId,uint256 amountWei)",
]);
const poolManagerEvidenceAbi = parseAbi([
  "function extsload(bytes32 slot) view returns (bytes32)",
  "event Swap(bytes32 indexed id,address indexed sender,int128 amount0,int128 amount1,uint160 sqrtPriceX96,uint128 liquidity,int24 tick,uint24 fee)",
]);

const sameHex = (left, right) =>
  typeof left === "string" &&
  typeof right === "string" &&
  left.toLowerCase() === right.toLowerCase();

const fail = (msg) => {
  console.error(`\nPROMOTION BLOCKED: ${msg}`);
  process.exit(1);
};
const finalityTimeoutSeconds = Number(flag("finality-timeout-seconds", "900"));
if (
  !Number.isSafeInteger(finalityTimeoutSeconds) ||
  finalityTimeoutSeconds < 1 ||
  finalityTimeoutSeconds > 3_600
) {
  fail("--finality-timeout-seconds must be an integer from 1 through 3600");
}
const FINALITY_TIMEOUT_MS = finalityTimeoutSeconds * 1_000;
const FINALITY_POLL_MS = 5_000;

/**
 * Refuse to promote against a fork. Every on-chain check below is only as good as the endpoint
 * answering it, and an anvil fork of 4663 answers all of them convincingly — it reports the right
 * chain id, serves the real PoolManager, and returns successful receipts for transactions that
 * only ever existed locally. Promoting against one would write productionAllowed: true naming
 * addresses that hold no code on the real chain.
 *
 * run-canary.sh already refuses to sign against a loopback RPC; this is the same guard on the step
 * that actually opens the gate. --dry-run may point anywhere, since it writes nothing.
 */
if (!DRY_RUN) {
  if (!rpcHostname) {
    fail(`--rpc is not a valid URL: ${RPC}`);
  }
  if (RPC_IS_LOOPBACK) {
    fail(`refusing to promote against a local/fork RPC (${rpcHostname}) — pass --dry-run to inspect one`);
  }
  if (!RPC.startsWith("https://")) fail(`refusing to promote over a non-https RPC (${RPC})`);
}

const load = (path) => {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    fail(`cannot read ${path}: ${error.message}`);
  }
};

const deployRun = load(DEPLOY_PATH);
const canaryRun = load(CANARY_PATH);
const runtimeArtifacts = Object.fromEntries(
  Object.entries(RUNTIME_ARTIFACTS).map(([key, target]) => [key, load(target.path)]),
);

if (deployRun.chain !== 4663 || canaryRun.chain !== 4663) fail("artifact chain is not 4663");

/**
 * Forge writes `receipts[]` in completion order, which is NOT the order of `transactions[]`.
 * Never pair them by index: key receipts by hash and look each transaction's own hash up.
 */
const receiptByHash = (run) => {
  const map = new Map();
  for (const receipt of run.receipts ?? []) {
    const hash = String(receipt.transactionHash ?? "").toLowerCase();
    if (map.has(hash)) fail(`artifact contains duplicate receipt hash ${hash}`);
    map.set(hash, receipt);
  }
  return map;
};
const pair = (run, label) => {
  const map = receiptByHash(run);
  return (run.transactions ?? []).map((tx, i) => {
    const hash = String(tx.hash ?? "").toLowerCase();
    const receipt = map.get(hash);
    if (!receipt) fail(`${label} tx #${i} (${hash}) has no matching receipt in the artifact`);
    return { tx, receipt };
  });
};

/* ------------------------------------------------------ receipt order + status */
const deployPairs = pair(deployRun, "deploy");
const canaryPairs = pair(canaryRun, "canary");
const dTx = deployPairs.map((p) => p.tx);
const dRc = deployPairs.map((p) => p.receipt);
const cTx = canaryPairs.map((p) => p.tx);
const cRc = canaryPairs.map((p) => p.receipt);
if (
  dTx.length !== 10 ||
  dRc.length !== 10 ||
  (deployRun.receipts ?? []).length !== 10
) {
  fail(
    `deploy artifact must hold exactly 10 transactions/receipts, found ${dTx.length}/${(deployRun.receipts ?? []).length}`,
  );
}
if (
  cTx.length !== 4 ||
  cRc.length !== 4 ||
  (canaryRun.receipts ?? []).length !== 4
) {
  fail(
    `canary artifact must hold exactly 4 transactions/receipts, found ${cTx.length}/${(canaryRun.receipts ?? []).length}`,
  );
}
/**
 * HookrLaunchpad exceeds EIP-170 with its arithmetic and token factory inlined, so both live in
 * HookrLaunchpadLib and are linked by DELEGATECALL. Forge deploys that library itself and PREPENDS
 * it to the broadcast, which is why the sequence is ten transactions and the library is #0. Every
 * index below is therefore one later than it was pre-library — the launchpad is #1, not #0.
 */
const expectDeploy = [
  { type: "CREATE2", name: "HookrLaunchpadLib" },
  { type: "CREATE", name: "HookrLaunchpad" },
  { type: "CREATE2", name: "HookrHook" },
  { type: "CREATE", name: "HookrSwapRouter" },
  { fn: "setHook" },
  { fn: "saveBlueprint" },
  { fn: "saveBlueprint" },
  { fn: "saveBlueprint" },
  { fn: "saveBlueprint" },
  { fn: "saveBlueprint" },
];
expectDeploy.forEach((want, i) => {
  const tx = dTx[i];
  const rc = dRc[i];
  if (rc.status !== "0x1") fail(`deploy tx #${i} (${want.name ?? want.fn}) not successful`);
  if (getAddress(tx.transaction.from) !== EXPECTED_DEPLOYER) fail(`deploy tx #${i} not from the expected deployer`);
  if (want.type && tx.transactionType !== want.type) {
    fail(`deploy tx #${i} expected ${want.type}, found ${tx.transactionType}`);
  }
  if (want.name && tx.contractName !== want.name) {
    fail(`deploy tx #${i} expected contract ${want.name}, found ${tx.contractName}`);
  }
  if (want.fn && !(tx.function ?? "").startsWith(want.fn)) {
    fail(`deploy tx #${i} expected ${want.fn}(), found ${tx.function}`);
  }
});
const expectCanary = ["launchInstantWithIntent", "exactInput", "approve", "exactInput"];
expectCanary.forEach((fn, i) => {
  const tx = cTx[i];
  const rc = cRc[i];
  if (rc.status !== "0x1") fail(`canary tx #${i} (${fn}) not successful`);
  if (getAddress(tx.transaction.from) !== EXPECTED_DEPLOYER) fail(`canary tx #${i} not from the expected deployer`);
  if (!(tx.function ?? "").startsWith(fn)) fail(`canary tx #${i} expected ${fn}(), found ${tx.function}`);
});
if (!String(cTx[0].transaction.input ?? "").toLowerCase().startsWith(INSTANT_LAUNCH_SELECTOR)) {
  fail("canary tx #0 artifact calldata is not launchInstantWithIntent()");
}

const launchpadLib = getAddress(dTx[0].contractAddress);
const launchpad = getAddress(dTx[1].contractAddress);
const hook = getAddress(dTx[2].contractAddress);
const router = getAddress(dTx[3].contractAddress);
if ((BigInt(hook) & 0x3fffn) !== HOOK_FLAGS) fail("hook address does not carry the 0x28cc flag bits");

// The canary must have exercised exactly this deployment.
if (getAddress(cTx[0].transaction.to) !== launchpad) fail("canary launch did not target the deployed launchpad");
if (getAddress(cTx[1].transaction.to) !== router) fail("canary buy did not go through the deployed router");
if (getAddress(cTx[3].transaction.to) !== router) fail("canary sell did not go through the deployed router");

const receipts = {
  launchpadLib: dRc[0].transactionHash,
  launchpad: dRc[1].transactionHash,
  hook: dRc[2].transactionHash,
  router: dRc[3].transactionHash,
  setHook: dRc[4].transactionHash,
  blueprints: dRc.slice(5, 10).map((r) => r.transactionHash),
  canary: {
    instantLaunch: cRc[0].transactionHash,
    routerBuy: cRc[1].transactionHash,
    tokenApproval: cRc[2].transactionHash,
    routerSell: cRc[3].transactionHash,
  },
};
const all = [
  receipts.launchpadLib, receipts.launchpad, receipts.hook, receipts.router, receipts.setHook,
  ...receipts.blueprints,
  receipts.canary.instantLaunch, receipts.canary.routerBuy,
  receipts.canary.tokenApproval, receipts.canary.routerSell,
];
if (new Set(all.map((h) => h.toLowerCase())).size !== all.length) fail("duplicate receipt hashes");

/* ----------------------------------------------------------- source commit
   The manifest must name the commit whose contracts were actually broadcast, which Forge
   records in the artifact. Promote-time HEAD is only accepted when it resolves to the same
   commit, so a later app-only commit can never silently re-attribute deployed bytecode. */
const git = (...argv) => execFileSync("git", argv, { encoding: "utf8" }).trim();
const artifactCommit = String(deployRun.commit ?? "").trim();
if (!artifactCommit) fail("deploy artifact carries no commit field; cannot attribute the bytecode");
let sourceCommit;
try {
  sourceCommit = git("rev-parse", artifactCommit);
} catch {
  fail(`artifact commit ${artifactCommit} is not in this repository`);
}
const canaryCommit = String(canaryRun.commit ?? "").trim();
if (!canaryCommit) fail("canary artifact carries no commit field; cannot attribute the canary");
let resolvedCanary;
try {
  resolvedCanary = git("rev-parse", canaryCommit);
} catch {
  fail(`canary artifact commit ${canaryCommit} is not in this repository`);
}
if (resolvedCanary !== sourceCommit) {
  fail(`deploy (${sourceCommit.slice(0, 12)}) and canary (${resolvedCanary.slice(0, 12)}) were broadcast from different commits`);
}
const contractsDirty = git(
  "status",
  "--porcelain",
  "--",
  "contracts/src",
  "contracts/script",
  "contracts/lib",
  "contracts/foundry.toml",
);
if (contractsDirty !== "" && !DRY_RUN) {
  fail("contract sources, scripts, dependencies, or compiler settings are dirty; deployed bytecode cannot be attributed");
}
const contractsDiff = git(
  "diff",
  "--name-only",
  sourceCommit,
  "HEAD",
  "--",
  "contracts/src",
  "contracts/lib",
  "contracts/foundry.toml",
);
if (contractsDiff !== "" && !DRY_RUN) {
  fail(`contract source inputs changed since the deployed commit (${contractsDiff.split("\n").join(", ")}); redeploy or promote from that commit`);
}
for (const [key, target] of Object.entries(RUNTIME_ARTIFACTS)) {
  try {
    assertArtifactSourceHashes(
      runtimeArtifacts[key],
      (sourcePath) => readFileSync(`contracts/${sourcePath}`),
      target.contractName,
    );
  } catch (error) {
    fail(`reviewed runtime artifact: ${error.message}; rebuild contracts/out from the attributed source`);
  }
}

/* --------------------------------------- finalized receipts + pinned state readback */
const client = createPublicClient({ transport: http(RPC) });
const abi = parseAbi([
  "function contractName() view returns (string)",
  "function contractVersion() view returns (string)",
  "function hook() view returns (address)",
  "function launchpad() view returns (address)",
  "function poolManager() view returns (address)",
  "function owner() view returns (address)",
  "function blueprintsCount() view returns (uint256)",
]);

const chainId = await client.getChainId();
if (chainId !== 4663) fail(`RPC chain id ${chainId}, expected 4663`);
// Receipt finality and state readback deliberately use two authenticated heads. Robinhood's
// official RPC serves the `finalized` header but rejects eth_call/getCode at that tag/height with
// "metadata is not found". Receipts still must be at or below that finalized head. Immutable code,
// wiring/config, and monotonic postconditions are read at one exact `safe` block hash, then that
// exact hash must itself become finalized before it can be persisted in a production manifest.
// Anvil does not finalize locally-mined transactions, so only a non-writing loopback rehearsal may
// use latest for both boundaries and skip the finalization wait.
const receiptEvidenceTag = DRY_RUN && RPC_IS_LOOPBACK ? "latest" : "finalized";
const finalizedHead = await client.getBlock({ blockTag: receiptEvidenceTag });
if (!finalizedHead?.hash || finalizedHead.number === null || finalizedHead.number === undefined) {
  fail(`${receiptEvidenceTag} receipt evidence block is missing its number or hash`);
}
const finalizedCanonical = await client.getBlock({ blockNumber: finalizedHead.number });
if (!sameHex(finalizedCanonical.hash, finalizedHead.hash)) {
  fail(`${receiptEvidenceTag} receipt evidence head is not canonical at its block number`);
}
const stateEvidenceTag = DRY_RUN && RPC_IS_LOOPBACK ? "latest" : "safe";
const stateHead = await client.getBlock({ blockTag: stateEvidenceTag });
try {
  assertStateEvidenceAfterFinality(finalizedHead, stateHead);
} catch (error) {
  fail(`state evidence head: ${error.message}`);
}
// EIP-1898 block-hash pinning makes every state call use the same exact snapshot. The hash is
// checked for continued canonicality after all reads and then required to finalize before write.
const at = { blockHash: stateHead.hash };

// Fail before expensive runtime/state comparisons when any claimed receipt is newer than the
// finalized evidence head. Full status, canonical-header, calldata, and postcondition checks still
// run below; this first pass establishes that the release evidence is old enough to be final.
const finalizedReceiptLabels = [
  ["launchpadLib", receipts.launchpadLib],
  ["launchpad", receipts.launchpad],
  ["hook", receipts.hook],
  ["router", receipts.router],
  ["setHook", receipts.setHook],
  ...receipts.blueprints.map((hash, index) => [`blueprint#${index + 1}`, hash]),
  ["canary:launch", receipts.canary.instantLaunch],
  ["canary:buy", receipts.canary.routerBuy],
  ["canary:approve", receipts.canary.tokenApproval],
  ["canary:sell", receipts.canary.routerSell],
];
const finalizedReceiptRecords = await Promise.all(
  finalizedReceiptLabels.map(async ([label, hash]) => {
    try {
      const receipt = await client.getTransactionReceipt({ hash });
      return { label, blockNumber: receipt.blockNumber };
    } catch {
      fail(`${label} receipt ${hash} is not on the chain this RPC serves (fork artifact?)`);
    }
  }),
);
try {
  assertReceiptsWithinEvidenceBlock(finalizedReceiptRecords, finalizedHead);
} catch (error) {
  fail(`${receiptEvidenceTag} receipt evidence: ${error.message}`);
}

/* Chain 4663 has two heights: receipts use the rollup RPC height, while Solidity block.number is
   the parent-chain height exposed as l1BlockNumber on that receipt block's header. Bind the header
   hash to the receipt before using the contract-visible clock in any state proof. */
const contractBlockCache = new Map();
const contractBlockNumberForReceipt = async (receipt, label) => {
  if (typeof receipt.blockHash !== "string") {
    fail(`${label} receipt has no block hash`);
  }
  const key = receipt.blockNumber.toString();
  const cached = contractBlockCache.get(key);
  if (cached) {
    if (cached.hash.toLowerCase() !== receipt.blockHash.toLowerCase()) {
      fail(`${label} receipt block hash disagrees with the cached block header`);
    }
    return cached.contractBlockNumber;
  }
  let header;
  try {
    header = await client.request({
      method: "eth_getBlockByNumber",
      params: [toHex(receipt.blockNumber), false],
    });
  } catch (error) {
    fail(`${label} receipt block header could not be read: ${error.message}`);
  }
  if (
    !header ||
    typeof header.number !== "string" ||
    BigInt(header.number) !== receipt.blockNumber ||
    typeof header.hash !== "string" ||
    header.hash.toLowerCase() !== receipt.blockHash.toLowerCase()
  ) {
    fail(`${label} receipt is not bound to the returned block header`);
  }
  const hasL1BlockNumber =
    typeof header.l1BlockNumber === "string" &&
    /^0x[0-9a-fA-F]+$/.test(header.l1BlockNumber);
  // Anvil strips Robinhood's non-standard l1BlockNumber field from blocks it mines locally and
  // makes Solidity block.number equal its own receipt height. Permit that clock only for an
  // explicitly non-writing loopback rehearsal; production and remote dry-runs still require the
  // authenticated Robinhood header field.
  if (!hasL1BlockNumber && !(DRY_RUN && RPC_IS_LOOPBACK)) {
    fail(`${label} receipt block header has no valid l1BlockNumber`);
  }
  const contractBlockNumber = hasL1BlockNumber
    ? BigInt(header.l1BlockNumber)
    : receipt.blockNumber;
  if (contractBlockNumber <= 0n) fail(`${label} receipt block l1BlockNumber is zero`);
  contractBlockCache.set(key, { hash: header.hash, contractBlockNumber });
  return contractBlockNumber;
};

const runtime = async (address) => {
  const code = await client.getCode({ address, ...at });
  if (!code || code === "0x") fail(`no runtime code at ${address}`);
  return code;
};
const codehash = async (address) => keccak256(await runtime(address));
const read = (address, functionName) => client.readContract({ address, abi, functionName, ...at });

const [padCode, hookCode, routerCode, launchpadLibCode, pmHash, create2DeployerHash] = await Promise.all([
  runtime(launchpad),
  runtime(hook),
  runtime(router),
  runtime(launchpadLib),
  codehash(POOL_MANAGER),
  codehash(CREATE2_DEPLOYER),
]);
const padHash = keccak256(padCode);
const hookHash = keccak256(hookCode);
const routerHash = keccak256(routerCode);
if (pmHash !== POOL_MANAGER_CODEHASH) fail("PoolManager runtime codehash changed");
if (create2DeployerHash !== CREATE2_DEPLOYER_CODEHASH) {
  fail("canonical CREATE2 deployer runtime codehash changed");
}

let runtimeProofs;
try {
  runtimeProofs = {
    launchpad: validateReviewedRuntime({
      artifact: runtimeArtifacts.launchpad,
      liveCode: padCode,
      expectedTarget: RUNTIME_ARTIFACTS.launchpad,
      expectedImmutableAddresses: [POOL_MANAGER],
      expectedLinks: {
        "src/libraries/HookrLaunchpadLib.sol:HookrLaunchpadLib": launchpadLib,
      },
      expectedNormalizedTemplateHash: REVIEWED_NORMALIZED_RUNTIME_HASHES.launchpad,
      expectedReferenceLayoutHash: REVIEWED_RUNTIME_REFERENCE_LAYOUT_HASHES.launchpad,
    }),
    hook: validateReviewedRuntime({
      artifact: runtimeArtifacts.hook,
      liveCode: hookCode,
      expectedTarget: RUNTIME_ARTIFACTS.hook,
      expectedImmutableAddresses: [POOL_MANAGER, launchpad],
      expectedNormalizedTemplateHash: REVIEWED_NORMALIZED_RUNTIME_HASHES.hook,
      expectedReferenceLayoutHash: REVIEWED_RUNTIME_REFERENCE_LAYOUT_HASHES.hook,
    }),
    router: validateReviewedRuntime({
      artifact: runtimeArtifacts.router,
      liveCode: routerCode,
      expectedTarget: RUNTIME_ARTIFACTS.router,
      expectedImmutableAddresses: [POOL_MANAGER, hook],
      expectedNormalizedTemplateHash: REVIEWED_NORMALIZED_RUNTIME_HASHES.router,
      expectedReferenceLayoutHash: REVIEWED_RUNTIME_REFERENCE_LAYOUT_HASHES.router,
    }),
    launchpadLib: validateReviewedRuntime({
      artifact: runtimeArtifacts.launchpadLib,
      liveCode: launchpadLibCode,
      expectedTarget: RUNTIME_ARTIFACTS.launchpadLib,
      expectedImmutableAddresses: [launchpadLib],
      expectedNormalizedTemplateHash: REVIEWED_NORMALIZED_RUNTIME_HASHES.launchpadLib,
      expectedReferenceLayoutHash: REVIEWED_RUNTIME_REFERENCE_LAYOUT_HASHES.launchpadLib,
    }),
  };
} catch (error) {
  fail(`reviewed runtime comparison: ${error.message}`);
}
if (
  runtimeProofs.launchpad.runtimeCodeHash !== padHash ||
  runtimeProofs.hook.runtimeCodeHash !== hookHash ||
  runtimeProofs.router.runtimeCodeHash !== routerHash
) {
  fail("reviewed runtime proof hashes disagree with manifest runtime hashes");
}

/* The launchpad DELEGATECALLs its arithmetic and its token factory into HookrLaunchpadLib, whose
   address solc bakes into the launchpad's runtime at every call site. Prove on chain that the
   deployed launchpad is linked to the library this same broadcast deployed — otherwise a launchpad
   linked against some other (or non-existent) address would promote as if it were wired correctly,
   and every launch would revert. `contracts.launchpad.runtimeCodeHash` in the manifest then pins
   that linkage transitively, which is why the library needs no manifest field of its own. */
const linkNeedle = launchpadLib.slice(2).toLowerCase();
const linkCount = padCode.toLowerCase().split(linkNeedle).length - 1;
if (linkCount === 0) {
  fail(`deployed launchpad does not reference HookrLaunchpadLib at ${launchpadLib}; it is linked elsewhere`);
}

/* What each receipt must have created or targeted, checked against the chain rather than against
   the artifact that named it.

   The two deployment mechanics differ on chain and must be checked differently. A plain `new X()`
   is a CREATE from the EOA: `to` is null and the receipt carries `contractAddress`. A salted
   `new X{salt:}()` is a CREATE2 routed through the canonical deployer, so the receipt's `to` is
   0x4e59… and `contractAddress` is NULL. The canonical proxy's live calldata is `salt || initCode`,
   so promotion derives CREATE2(factory, salt, keccak256(initCode)) and requires it to equal the
   claimed library/hook address in addition to checking the factory target and runtime.

   `canary:approve` is resolved after the instant receipt: its target must be the token indexed by
   that launchpad's `InstantLaunched` event, not an address trusted from either artifact. */
const ONCHAIN_TARGET = {
  launchpadLib: ["calls", CREATE2_DEPLOYER],
  launchpad: ["creates", launchpad],
  hook: ["calls", CREATE2_DEPLOYER],
  router: ["creates", router],
  setHook: ["calls", launchpad],
  "canary:launch": ["calls", launchpad],
  "canary:buy": ["calls", router],
  "canary:sell": ["calls", router],
  ...Object.fromEntries(receipts.blueprints.map((_, i) => [`blueprint#${i + 1}`, ["calls", launchpad]])),
};
let canaryToken;
const onchainReceiptOrder = [];
const onchainTransactions = new Map();

/* Every receipt hash in the manifest must exist on THIS chain, have succeeded, come from the
   expected deployer. The launchpad receipt below establishes the release floor from live chain
   data; the linked-library transaction is intentionally earlier. Without these live checks, a fork
   artifact promotes cleanly — the failure mode that made rehearsal look like a real release. */
for (const [label, hash] of [
  ["launchpadLib", receipts.launchpadLib],
  ["launchpad", receipts.launchpad],
  ["hook", receipts.hook],
  ["router", receipts.router],
  ["setHook", receipts.setHook],
  ...receipts.blueprints.map((h, i) => [`blueprint#${i + 1}`, h]),
  ["canary:launch", receipts.canary.instantLaunch],
  ["canary:buy", receipts.canary.routerBuy],
  ["canary:approve", receipts.canary.tokenApproval],
  ["canary:sell", receipts.canary.routerSell],
]) {
  let onchain;
  try {
    onchain = await client.getTransactionReceipt({ hash });
  } catch {
    fail(`${label} receipt ${hash} is not on the chain this RPC serves (fork artifact?)`);
  }
  if (onchain.status !== "success") fail(`${label} receipt ${hash} did not succeed on chain`);
  if (getAddress(onchain.from) !== EXPECTED_DEPLOYER) {
    fail(`${label} receipt ${hash} was not sent by the expected deployer`);
  }
  const contractBlockNumber = await contractBlockNumberForReceipt(onchain, label);
  onchainReceiptOrder.push({
    label,
    hash,
    blockNumber: onchain.blockNumber,
    transactionIndex: onchain.transactionIndex,
    contractBlockNumber,
  });

  const transaction = await client.getTransaction({ hash });
  onchainTransactions.set(label, { receipt: onchain, transaction });

  if (label === "launchpadLib" || label === "hook") {
    const expectedCreate2Address = label === "launchpadLib" ? launchpadLib : hook;
    let derived;
    try {
      derived = canonicalCreate2Address(CREATE2_DEPLOYER, transaction.input);
    } catch (error) {
      fail(`${label} CREATE2 evidence: ${error.message}`);
    }
    if (derived !== expectedCreate2Address) {
      fail(`${label} CREATE2 calldata derives ${derived}, expected ${expectedCreate2Address}`);
    }
    if (BigInt(transaction.value) !== 0n) fail(`${label} CREATE2 transaction sent native value`);
  }

  // The artifact's human-readable `function` field is only a convenience label. For the one
  // capability-defining transaction, verify the calldata and emitted event from the chain itself:
  // generation 4 may not be promoted from a curve launch relabelled as an instant canary.
  if (label === "canary:launch") {
    if (!transaction.input.toLowerCase().startsWith(INSTANT_LAUNCH_SELECTOR)) {
      fail(`canary launch receipt ${hash} is not a live launchInstantWithIntent() transaction`);
    }
    const instantLaunchLog = onchain.logs.find(
      (log) =>
        getAddress(log.address) === launchpad &&
        String(log.topics[0] ?? "").toLowerCase() === INSTANT_LAUNCHED_TOPIC.toLowerCase(),
    );
    if (!instantLaunchLog) fail(`canary launch receipt ${hash} emitted no InstantLaunched event`);
    const indexedToken = instantLaunchLog.topics[1];
    if (!indexedToken || indexedToken.length !== 66) fail(`canary launch receipt ${hash} has a malformed token topic`);
    canaryToken = getAddress(`0x${indexedToken.slice(-40)}`);
  }

  /* Verify WHAT each transaction touched, from the chain — not from the artifact. Until now this
     loop confirmed only that a hash succeeded, while the addresses it was credited with came from
     the artifact's own `to`/`contractAddress` fields. RELEASE.md tells an operator to hand-assemble
     an artifact from receipt hashes when a canary needs manual recovery, and promises it is
     "checked exactly as strictly as a scripted one" — which was not true: a hand-written artifact
     could label any four successful transactions as the canary sequence and they would be accepted.
     Creations are checked against the address they actually created, calls against their target. */
  const expectedTarget =
    label === "canary:approve" && canaryToken ? ["calls", canaryToken] : ONCHAIN_TARGET[label];
  if (expectedTarget) {
    const [kind, want] = expectedTarget;
    const got = kind === "creates" ? onchain.contractAddress : onchain.to;
    if (!got || getAddress(got) !== want) {
      fail(
        `${label} receipt ${hash} ${kind === "creates" ? "created" : "targeted"} ${got ?? "nothing"}, expected ${want}`,
      );
    }
  }
}

try {
  assertStrictReceiptOrder(onchainReceiptOrder);
  assertReceiptsWithinEvidenceBlock(onchainReceiptOrder, finalizedHead);
} catch (error) {
  fail(`receipt order: ${error.message}`);
}

const liveLaunchpadRecord = onchainTransactions.get("launchpad");
if (!liveLaunchpadRecord) fail("live launchpad deployment transaction evidence is missing");
let deployBlock;
try {
  deployBlock = deriveLiveLaunchpadDeployBlock(liveLaunchpadRecord.receipt, launchpad);
} catch (error) {
  fail(`launchpad deployment evidence: ${error.message}`);
}
let artifactLaunchpadBlock;
try {
  artifactLaunchpadBlock = BigInt(dRc[1].blockNumber);
} catch {
  fail("deploy artifact launchpad receipt has no valid block number");
}
if (artifactLaunchpadBlock !== deployBlock) {
  fail(
    `artifact launchpad block ${artifactLaunchpadBlock} disagrees with live receipt block ${deployBlock}`,
  );
}
if (finalizedHead.number < deployBlock) {
  fail("finalized receipt head precedes the live launchpad deployment block");
}
for (const record of onchainReceiptOrder.slice(1)) {
  if (record.blockNumber < deployBlock) {
    fail(`${record.label} receipt ${record.hash} predates the live launchpad deployment block`);
  }
}

const checks = [
  [await read(launchpad, "contractName"), "HookrLaunchpad", "launchpad identity"],
  [await read(launchpad, "contractVersion"), "1.0.0", "launchpad version"],
  [await read(hook, "contractName"), "HookrHook", "hook identity"],
  [await read(hook, "contractVersion"), "1.0.0", "hook version"],
  [await read(router, "contractName"), "HookrSwapRouter", "router identity"],
  [await read(router, "contractVersion"), "1.0.0", "router version"],
  [getAddress(await read(launchpad, "hook")), hook, "launchpad->hook wiring"],
  [getAddress(await read(hook, "launchpad")), launchpad, "hook->launchpad wiring"],
  [getAddress(await read(hook, "poolManager")), POOL_MANAGER, "hook->PM wiring"],
  [getAddress(await read(router, "hook")), hook, "router->hook wiring"],
  [getAddress(await read(router, "poolManager")), POOL_MANAGER, "router->PM wiring"],
  [getAddress(await read(launchpad, "owner")), EXPECTED_DEPLOYER, "launchpad owner"],
];
for (const [actual, expected, label] of checks) {
  if (actual !== expected) fail(`${label}: expected ${expected}, read ${actual}`);
}
const blueprintsCount = BigInt(await read(launchpad, "blueprintsCount"));
if (blueprintsCount < 6n) {
  fail(`blueprint count ${blueprintsCount} is missing the sentinel or one of five house blueprints`);
}

/* ----------------------------------- blueprint + instant canary semantic evidence
   Successful calls to the expected contracts are insufficient release evidence: unrelated
   transactions can be relabelled in a hand-built artifact. Decode the five house-blueprint calls
   and events and compare their complete pinned readbacks first. Then bind every canary step to the
   exact instant token and PoolId and repeat its postconditions at the manifest's pinned block. */
const decodeCall = (record, abi_, functionName, label) => {
  try {
    const decoded = decodeFunctionData({ abi: abi_, data: record.transaction.input });
    if (decoded.functionName !== functionName) {
      fail(`${label} decoded as ${decoded.functionName}(), expected ${functionName}()`);
    }
    const canonicalInput = encodeFunctionData({
      abi: abi_,
      functionName,
      args: decoded.args,
    });
    if (canonicalInput.toLowerCase() !== record.transaction.input.toLowerCase()) {
      fail(`${label} calldata is not the exact canonical encoding`);
    }
    return decoded;
  } catch (error) {
    fail(`${label} calldata could not be decoded: ${error.message}`);
  }
};
const decodeOnlyEvent = (record, address, abi_, eventName, label) => {
  const matches = [];
  for (const log of record.receipt.logs) {
    if (getAddress(log.address) !== address) continue;
    try {
      const decoded = decodeEventLog({ abi: abi_, eventName, data: log.data, topics: log.topics, strict: true });
      if (decoded.eventName === eventName) matches.push(decoded.args);
    } catch {
      // This contract emits several event types in the same receipt; only the named event counts.
    }
  }
  if (matches.length !== 1) fail(`${label} emitted ${matches.length} ${eventName} events, expected exactly one`);
  return matches[0];
};
const tupleField = (value, name, index) => value?.[name] ?? value?.[index];
const hookParamsShape = (value) =>
  Object.fromEntries(
    HOOK_PARAM_FIELDS.map((field, index) => [field, tupleField(value, field, index)]),
  );
const pinnedRead = (address, abi_, functionName, args_ = []) =>
  client.readContract({ address, abi: abi_, functionName, args: args_, ...at });
const txShape = (record, contractBlockNumber) => ({
  from: record.transaction.from,
  to: record.transaction.to,
  value: record.transaction.value,
  blockNumber: record.receipt.blockNumber,
  ...(contractBlockNumber === undefined ? {} : { contractBlockNumber }),
});

const blueprintEvidence = await Promise.all(
  receipts.blueprints.map(async (_, index) => {
    const id = index + 1;
    const label = `blueprint#${id}`;
    const record = onchainTransactions.get(label);
    if (!record) fail(`${label} live transaction evidence is missing`);
    const call = decodeCall(record, blueprintEvidenceAbi, "saveBlueprint", label);
    const event = decodeOnlyEvent(
      record,
      launchpad,
      blueprintEvidenceAbi,
      "BlueprintSaved",
      label,
    );
    const readbackRaw = await pinnedRead(
      launchpad,
      blueprintEvidenceAbi,
      "getBlueprint",
      [id],
    );
    const contractBlockNumber = await contractBlockNumberForReceipt(record.receipt, label);
    return {
      id,
      transaction: txShape(record, contractBlockNumber),
      calldata: {
        name: call.args[0],
        params: hookParamsShape(call.args[1]),
        royaltyBps: call.args[2],
      },
      event,
      readback: {
        author: tupleField(readbackRaw, "author", 0),
        royaltyBps: tupleField(readbackRaw, "royaltyBps", 1),
        uses: tupleField(readbackRaw, "uses", 2),
        savedAtBlock: tupleField(readbackRaw, "savedAtBlock", 3),
        name: tupleField(readbackRaw, "name", 4),
        params: hookParamsShape(tupleField(readbackRaw, "params", 5)),
      },
    };
  }),
);
try {
  validateHouseBlueprintEvidence({
    identities: { deployer: EXPECTED_DEPLOYER, launchpad },
    blueprints: blueprintEvidence,
  });
} catch (error) {
  fail(`house blueprint evidence: ${error.message}`);
}

const launchRecord = onchainTransactions.get("canary:launch");
const buyRecord = onchainTransactions.get("canary:buy");
const approvalRecord = onchainTransactions.get("canary:approve");
const sellRecord = onchainTransactions.get("canary:sell");
if (!launchRecord || !buyRecord || !approvalRecord || !sellRecord) fail("live canary transaction evidence is incomplete");
const launchContractBlockNumber = await contractBlockNumberForReceipt(
  launchRecord.receipt,
  "canary launch",
);

const launchCall = decodeCall(launchRecord, launchpadEvidenceAbi, "launchInstantWithIntent", "canary launch");
const buyCall = decodeCall(buyRecord, routerEvidenceAbi, "exactInput", "canary buy");
const approvalCall = decodeCall(approvalRecord, tokenEvidenceAbi, "approve", "canary approval");
const sellCall = decodeCall(sellRecord, routerEvidenceAbi, "exactInput", "canary sell");

const instantEvent = decodeOnlyEvent(
  launchRecord,
  launchpad,
  launchpadEvidenceAbi,
  "InstantLaunched",
  "canary launch",
);
const tokenEvent = decodeOnlyEvent(launchRecord, launchpad, launchpadEvidenceAbi, "TokenLaunched", "canary launch");
const graduatedEvent = decodeOnlyEvent(launchRecord, launchpad, launchpadEvidenceAbi, "Graduated", "canary launch");
const intentEvent = decodeOnlyEvent(
  launchRecord,
  launchpad,
  launchpadEvidenceAbi,
  "LaunchIntentConsumed",
  "canary launch",
);
const buyEvent = decodeOnlyEvent(buyRecord, router, routerEvidenceAbi, "SwapExecuted", "canary buy");
const buyPoolManagerEvent = decodeOnlyEvent(
  buyRecord,
  POOL_MANAGER,
  poolManagerEvidenceAbi,
  "Swap",
  "canary buy",
);
const buyHookFeesEvent = decodeOnlyEvent(
  buyRecord,
  hook,
  hookEvidenceAbi,
  "HookFeesAccrued",
  "canary buy",
);
const buyLpDonationEvent = decodeOnlyEvent(
  buyRecord,
  hook,
  hookEvidenceAbi,
  "LpRewardsDonated",
  "canary buy",
);
const buyAutoBurnEvent = decodeOnlyEvent(
  buyRecord,
  hook,
  hookEvidenceAbi,
  "AutoBurn",
  "canary buy",
);
const approvalEvent = decodeOnlyEvent(
  approvalRecord,
  getAddress(instantEvent.token),
  tokenEvidenceAbi,
  "Approval",
  "canary approval",
);
const sellEvent = decodeOnlyEvent(sellRecord, router, routerEvidenceAbi, "SwapExecuted", "canary sell");

const liveToken = getAddress(instantEvent.token);
if (liveToken !== canaryToken) fail("decoded InstantLaunched token disagrees with its indexed topic");
const poolId = instantEvent.poolId;
const launchArgs = launchCall.args[0];
const buyArgs = buyCall.args[0];
const sellArgs = sellCall.args[0];

const [creationFee, intentToken, launchState, previewState, hookConfigRaw] = await Promise.all([
  pinnedRead(launchpad, launchpadEvidenceAbi, "creationFeeWei"),
  pinnedRead(launchpad, launchpadEvidenceAbi, "launchedByIntent", [EXPECTED_DEPLOYER, launchCall.args[2]]),
  pinnedRead(launchpad, launchpadEvidenceAbi, "getLaunch", [liveToken]),
  pinnedRead(launchpad, launchpadEvidenceAbi, "previewInstantLaunch", [
    INSTANT_CANARY_SPEC.depositWei,
    INSTANT_CANARY_SPEC.poolSupplyBps,
  ]),
  pinnedRead(hook, hookEvidenceAbi, "poolConfig", [poolId]),
]);

const [
  guardLpEarnedWei,
  totalHookFeesWei,
  totalBurnedTokens,
  totalLpDonatedWei,
  potWei,
  potBuyCount,
  burnVaultWei,
  nativeClaimBalance,
] = await Promise.all(
  [
    "guardLpEarnedWei",
    "totalHookFeesWei",
    "totalBurnedTokens",
    "totalLpDonatedWei",
    "potWei",
    "potBuyCount",
    "burnVaultWei",
    "nativeClaimBalance",
  ].map((functionName) => pinnedRead(hook, hookEvidenceAbi, functionName, functionName === "nativeClaimBalance" ? [] : [poolId])),
);

const deadAddress = getAddress("0x000000000000000000000000000000000000dEaD");
const [
  creatorTokenBalance,
  poolManagerTokenBalance,
  deadTokenBalance,
  routerTokenBalance,
  launchpadTokenBalance,
  tokenCreator,
  tokenLaunchpad,
  tokenTotalSupply,
  tokenName,
  tokenSymbol,
  tokenTagline,
  hookNativeBalance,
  routerNativeBalance,
] = await Promise.all([
  pinnedRead(liveToken, tokenEvidenceAbi, "balanceOf", [EXPECTED_DEPLOYER]),
  pinnedRead(liveToken, tokenEvidenceAbi, "balanceOf", [POOL_MANAGER]),
  pinnedRead(liveToken, tokenEvidenceAbi, "balanceOf", [deadAddress]),
  pinnedRead(liveToken, tokenEvidenceAbi, "balanceOf", [router]),
  pinnedRead(liveToken, tokenEvidenceAbi, "balanceOf", [launchpad]),
  pinnedRead(liveToken, tokenEvidenceAbi, "creator"),
  pinnedRead(liveToken, tokenEvidenceAbi, "launchpad"),
  pinnedRead(liveToken, tokenEvidenceAbi, "totalSupply"),
  pinnedRead(liveToken, tokenEvidenceAbi, "name"),
  pinnedRead(liveToken, tokenEvidenceAbi, "symbol"),
  pinnedRead(liveToken, tokenEvidenceAbi, "tagline"),
  client.getBalance({ address: hook, ...at }),
  client.getBalance({ address: router, ...at }),
]);

// StateLibrary derives Pool.State from keccak256(abi.encodePacked(poolId, bytes32(uint256(6))));
// slot0 is that word and liquidity is the low uint128 at offset +3.
const poolStateSlot = keccak256(
  encodePacked(["bytes32", "bytes32"], [poolId, toHex(6n, { size: 32 })]),
);
const liquiditySlot = toHex(BigInt(poolStateSlot) + 3n, { size: 32 });
const [slot0Word, liquidityWord] = await Promise.all([
  pinnedRead(POOL_MANAGER, poolManagerEvidenceAbi, "extsload", [poolStateSlot]),
  pinnedRead(POOL_MANAGER, poolManagerEvidenceAbi, "extsload", [liquiditySlot]),
]);
const slot0 = BigInt(slot0Word);
const poolSqrtPriceX96 = slot0 & ((1n << 160n) - 1n);
const poolLpFee = Number((slot0 >> 208n) & 0xff_ffffn);
const poolLiquidity = BigInt(liquidityWord) & ((1n << 128n) - 1n);

const hookConfig = {
  initialized: tupleField(hookConfigRaw, "initialized", 0),
  guardEndBlock: tupleField(hookConfigRaw, "guardEndBlock", 1),
  baseFeePips: tupleField(hookConfigRaw, "baseFeePips", 2),
  maxFeePips: tupleField(hookConfigRaw, "maxFeePips", 3),
  snipeTaxPips: tupleField(hookConfigRaw, "snipeTaxPips", 4),
  surgeSens: tupleField(hookConfigRaw, "surgeSens", 5),
  burnBps: tupleField(hookConfigRaw, "burnBps", 6),
  lpBps: tupleField(hookConfigRaw, "lpBps", 7),
  potBps: tupleField(hookConfigRaw, "potBps", 8),
  royaltyBps: tupleField(hookConfigRaw, "royaltyBps", 9),
  potEveryNBuys: tupleField(hookConfigRaw, "potEveryNBuys", 10),
  maxBuyWei: tupleField(hookConfigRaw, "maxBuyWei", 11),
  potMinBuyWei: tupleField(hookConfigRaw, "potMinBuyWei", 12),
  burnTriggerWei: tupleField(hookConfigRaw, "burnTriggerWei", 13),
  royaltyTo: tupleField(hookConfigRaw, "royaltyTo", 14),
  token: tupleField(hookConfigRaw, "token", 15),
};
const launchStateShape = {
  token: tupleField(launchState, "token", 0),
  creator: tupleField(launchState, "creator", 1),
  launchBlock: tupleField(launchState, "launchBlock", 2),
  blueprintId: tupleField(launchState, "blueprintId", 3),
  graduated: tupleField(launchState, "graduated", 4),
  basePriceWei: tupleField(launchState, "basePriceWei", 5),
  targetWei: tupleField(launchState, "targetWei", 6),
  reserveWei: tupleField(launchState, "reserveWei", 7),
  soldTokens: tupleField(launchState, "soldTokens", 8),
  graduatedAtBlock: tupleField(launchState, "graduatedAtBlock", 9),
  sqrtPriceX96AtGraduation: tupleField(launchState, "sqrtPriceX96AtGraduation", 10),
  poolId: tupleField(launchState, "poolId", 11),
  hookParams: tupleField(launchState, "hookParams", 12),
};
const previewShape = {
  tokensInPool: tupleField(previewState, "tokensInPool", 0),
  openPriceWei: tupleField(previewState, "openPriceWei", 1),
  sqrtPriceX96: tupleField(previewState, "sqrtPriceX96", 2),
  openFdvWei: tupleField(previewState, "openFdvWei", 3),
  err: tupleField(previewState, "err", 4),
};

const canaryEvidence = {
  receiptOrder: onchainReceiptOrder,
  identities: {
    deployer: EXPECTED_DEPLOYER,
    launchpad,
    hook,
    router,
    poolManager: POOL_MANAGER,
  },
  launch: {
    transaction: txShape(launchRecord, launchContractBlockNumber),
    calldata: {
      args: launchArgs,
      poolSupplyBps: launchCall.args[1],
      intentId: launchCall.args[2],
    },
    event: instantEvent,
    tokenEvent,
    graduatedEvent,
    intentEvent,
  },
  buy: {
    transaction: txShape(buyRecord),
    calldata: buyArgs,
    event: buyEvent,
    poolManagerEvent: buyPoolManagerEvent,
    hookEvents: {
      feesAccrued: buyHookFeesEvent,
      lpDonation: buyLpDonationEvent,
      autoBurn: buyAutoBurnEvent,
    },
  },
  approval: {
    transaction: txShape(approvalRecord),
    calldata: { spender: approvalCall.args[0], amount: approvalCall.args[1] },
    event: approvalEvent,
  },
  sell: { transaction: txShape(sellRecord), calldata: sellArgs, event: sellEvent },
  postconditions: {
    creationFeeWei: creationFee,
    intentToken,
    launch: launchStateShape,
    preview: previewShape,
    hook: {
      config: hookConfig,
      ledgers: {
        guardLpEarnedWei,
        totalHookFeesWei,
        totalBurnedTokens,
        totalLpDonatedWei,
        potWei,
        potBuyCount,
        burnVaultWei,
        nativeClaimBalance,
      },
    },
    pool: { sqrtPriceX96: poolSqrtPriceX96, liquidity: poolLiquidity, lpFee: poolLpFee },
    tokenBalances: {
      creator: creatorTokenBalance,
      poolManager: poolManagerTokenBalance,
      dead: deadTokenBalance,
      router: routerTokenBalance,
      launchpad: launchpadTokenBalance,
    },
    tokenIdentity: {
      creator: tokenCreator,
      launchpad: tokenLaunchpad,
      totalSupply: tokenTotalSupply,
      name: tokenName,
      symbol: tokenSymbol,
      tagline: tokenTagline,
    },
    deadAddress,
    nativeBalances: { hook: hookNativeBalance, router: routerNativeBalance },
    poolManagerAddress: POOL_MANAGER,
  },
};

try {
  validateInstantCanaryEvidence(canaryEvidence);
} catch (error) {
  fail(`instant canary evidence: ${error.message}`);
}

// EIP-1898 kept all reads on the original hash. First reject any reorg during verification. For a
// production/remote proof, then wait until the authenticated finalized head reaches this state
// height and confirm that its canonical header still has the exact hash we read. Robinhood serves
// state while the block is `safe` but not once it is historical/finalized, so the order matters.
const canonicalStateHead = await client.getBlock({ blockNumber: stateHead.number });
if (!sameHex(canonicalStateHead.hash, stateHead.hash)) {
  fail(`pinned ${stateEvidenceTag} state evidence block was reorged during verification`);
}
let manifestFinalityHead = finalizedHead;
if (!(DRY_RUN && RPC_IS_LOOPBACK)) {
  const deadline = Date.now() + FINALITY_TIMEOUT_MS;
  let waitAnnounced = false;
  while (true) {
    manifestFinalityHead = await client.getBlock({ blockTag: "finalized" });
    if (
      !manifestFinalityHead?.hash ||
      manifestFinalityHead.number === null ||
      manifestFinalityHead.number === undefined
    ) {
      fail("finalized confirmation head has no number or hash");
    }
    const canonicalFinalityHead = await client.getBlock({
      blockNumber: manifestFinalityHead.number,
    });
    if (!sameHex(canonicalFinalityHead.hash, manifestFinalityHead.hash)) {
      fail("finalized confirmation head is not canonical at its block number");
    }
    if (manifestFinalityHead.number >= stateHead.number) {
      const finalizedStateHeader = await client.getBlock({ blockNumber: stateHead.number });
      try {
        assertStateEvidenceFinalized(manifestFinalityHead, stateHead, finalizedStateHeader);
      } catch (error) {
        fail(`state evidence finalization: ${error.message}`);
      }
      break;
    }
    if (Date.now() >= deadline) {
      fail(
        `state evidence block ${stateHead.number} did not finalize within ${finalityTimeoutSeconds}s ` +
          `(finalized head ${manifestFinalityHead.number}); manifest was not written`,
      );
    }
    if (!waitAnnounced) {
      console.log(
        `State proof read at ${stateEvidenceTag} #${stateHead.number}; waiting up to ` +
          `${finalityTimeoutSeconds}s for that exact hash to finalize...`,
      );
      waitAnnounced = true;
    }
    await new Promise((resolve) => setTimeout(resolve, FINALITY_POLL_MS));
  }
}

/* --------------------------------------------------------------- write patch */
const manifest = `export const CURRENT_RELEASE_MANIFEST = {
  manifestVersion: RELEASE_MANIFEST_SCHEMA_VERSION,
  chainId: 4663,
  version: 4,
  productionAllowed: true,
  deployBlock: ${deployBlock}n,
  capabilities: {
    launchModes: ["curve", "instant"],
  },
  contracts: {
    launchpad: {
      address: "${launchpad}",
      runtimeCodeHash: "${padHash}",
    },
    hook: {
      address: "${hook}",
      runtimeCodeHash: "${hookHash}",
    },
    router: {
      address: "${router}",
      runtimeCodeHash: "${routerHash}",
      kind: "hookr_bounded_swap_router_v1",
    },
    poolManager: {
      address: "${POOL_MANAGER}",
      runtimeCodeHash: "${pmHash}",
    },
  },
  evidence: {
    sourceCommit: "${sourceCommit}",
    deploymentReceipts: {
      launchpad: "${receipts.launchpad}",
      hook: "${receipts.hook}",
      router: "${receipts.router}",
      setHook: "${receipts.setHook}",
      blueprints: [
        "${receipts.blueprints[0]}",
        "${receipts.blueprints[1]}",
        "${receipts.blueprints[2]}",
        "${receipts.blueprints[3]}",
        "${receipts.blueprints[4]}",
      ],
    },
    fixedBlockFork: {
      blockNumber: ${stateHead.number}n,
      blockHash: "${stateHead.hash}",
    },
    linkageReadback: {
      blockNumber: ${stateHead.number}n,
      blockHash: "${stateHead.hash}",
    },
    canaryReceipts: {
      kind: "instant_launch_round_trip_v1",
      instantLaunch: "${receipts.canary.instantLaunch}",
      routerBuy: "${receipts.canary.routerBuy}",
      tokenApproval: "${receipts.canary.tokenApproval}",
      routerSell: "${receipts.canary.routerSell}",
    },
  },
} as const satisfies HookrReleaseManifest;`;

const source = readFileSync(MANIFEST_PATH, "utf8");
let patchedSource;
try {
  patchedSource = replaceCurrentReleaseManifest(source, manifest);
} catch (error) {
  fail(`${error.message} in ${MANIFEST_PATH}`);
}

console.log("All live-block, strict-order, five-blueprint, instant token/pool/intent, wiring, linkage, and pinned-block checks passed.");
console.log(`  launchpadLib ${launchpadLib} (linked at ${linkCount} call sites)`);
console.log(`  launchpad ${launchpad}`);
console.log(`  hook      ${hook}`);
console.log(`  router    ${router}`);
console.log(`  launchpad reviewed template ${runtimeProofs.launchpad.normalizedTemplateHash}`);
console.log(`  hook reviewed template      ${runtimeProofs.hook.normalizedTemplateHash}`);
console.log(`  router reviewed template    ${runtimeProofs.router.normalizedTemplateHash}`);
console.log(`  library reviewed template   ${runtimeProofs.launchpadLib.normalizedTemplateHash}`);
console.log(
  `  receipts finalized through ${finalizedHead.number} (${finalizedHead.hash}); state ${stateEvidenceTag} #${stateHead.number} finalized through ${manifestFinalityHead.number} (${stateHead.hash})`,
);
console.log(`  live launchpad deploy block ${deployBlock}`);
console.log(`  source commit ${sourceCommit}`);

if (DRY_RUN) {
  console.log("\n--dry-run: manifest not written. Generated object:\n");
  console.log(manifest);
  process.exit(0);
}

writeFileSync(MANIFEST_PATH, patchedSource);
// These must match RELEASE.md section 4. They drifted once already — claiming a test edit that
// is not needed, and naming an evidence directory that does not exist.
console.log(`\nPatched ${MANIFEST_PATH}. Next:`);
console.log("  1. npm test && npm run lint && npx tsc --noEmit && npm run build");
console.log("     (release-manifest.test.ts needs no edit: it asserts relationships, not a snapshot");
console.log("      of the open/closed state, so it passes before and after promotion)");
console.log("  2. (cd contracts && forge test && forge build --sizes)");
console.log("  3. archive both run-latest.json artifacts under contracts/evidence/v4/ with hashes");
console.log("  4. commit (the manifest's sourceCommit refers to the *deployed contracts* commit)");
