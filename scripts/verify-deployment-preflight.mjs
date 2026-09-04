#!/usr/bin/env node
/**
 * Read-only, fail-closed generation-5 deployment preflight.
 *
 * This verifier runs after DeployRobinhoodV5 receipts exist but before the canary command is
 * allowed to load a signer or spend on its transactions. It authenticates the finalized receipts,
 * CREATE/CREATE2 results, reviewed runtime templates (including the launchpad's packed scalar
 * immutables and its delegatecall-linked HookrLaunchpadLibV5), the deployed CCA auction factory
 * dependency, complete wiring, and all five house blueprint semantics from live calldata + receipt
 * logs + pinned readbacks. It never writes or broadcasts.
 *
 * Usage:
 *   node scripts/verify-deployment-preflight.mjs \
 *     --deploy contracts/broadcast/DeployRobinhoodV5.s.sol/4663/run-latest.json \
 *     --library-evidence contracts/release-evidence/v5/reused-launchpad-library.json
 *
 * Set HOOKR_RPC_URL (or ETH_RPC_URL) for a private provider. Keeping it out of argv prevents API
 * credentials from appearing in process listings. `--rpc` remains available for public URLs.
 *
 * An explicit local fork rehearsal may add --rehearsal. That is the only mode allowed to use a
 * latest (rather than finalized) evidence head or a block header without Robinhood's l1BlockNumber.
 */
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
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
const CANARY_RECOVERY = argv.includes("--canary-recovery");
const DEPLOY_PATH = flag(
  "deploy",
  "contracts/broadcast/DeployRobinhoodV5.s.sol/4663/run-latest.json",
);
const LIBRARY_EVIDENCE_PATH = flag("library-evidence", "");
const RECOVERY_INSTANT_TOKEN = flag("recovery-instant-token", "");
const RECOVERY_AUCTION_TOKEN = flag("recovery-auction-token", "");
const RECOVERY_AUCTION = flag("recovery-auction", "");
const FORBID_LEGACY_ARTIFACT = flag("forbid-legacy-artifact", "");
const RPC = flag(
  "rpc",
  process.env.HOOKR_RPC_URL ||
    process.env.ETH_RPC_URL ||
    "https://rpc.mainnet.chain.robinhood.com",
);

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

const redactRpc = (message) => {
  let redacted = String(message);
  for (const candidate of [RPC, encodeURI(RPC), encodeURIComponent(RPC)]) {
    if (candidate) redacted = redacted.split(candidate).join("<configured RPC>");
  }
  try {
    const endpoint = new URL(RPC);
    for (const secretPart of [endpoint.username, endpoint.password, endpoint.pathname, endpoint.search]) {
      if (secretPart && secretPart.length > 8) {
        redacted = redacted.split(secretPart).join("/<redacted>");
      }
    }
  } catch {
    // Invalid endpoints are rejected below without echoing their value.
  }
  return redacted;
};
const fail = (message) => {
  console.error(`\nDEPLOYMENT PREFLIGHT BLOCKED: ${redactRpc(message)}`);
  process.exit(1);
};
const failUnexpected = (reason) => {
  const detail = reason instanceof Error ? (reason.stack ?? reason.message) : String(reason);
  console.error(`\nDEPLOYMENT PREFLIGHT BLOCKED: ${redactRpc(detail)}`);
  process.exit(1);
};
process.on("uncaughtException", failUnexpected);
process.on("unhandledRejection", failUnexpected);
const load = (path) => {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    fail(`cannot read ${path}: ${error.message}`);
  }
};
const sha256File = (path) => {
  try {
    return createHash("sha256").update(readFileSync(path)).digest("hex");
  } catch (error) {
    fail(`cannot hash ${path}: ${error.message}`);
  }
};
const sameHex = (left, right) =>
  typeof left === "string" &&
  typeof right === "string" &&
  left.toLowerCase() === right.toLowerCase();
const git = (...args) => execFileSync("git", args, { encoding: "utf8" }).trim();

if (!rpcHostname) fail("configured RPC is not a valid URL");
if (REHEARSAL && !RPC_IS_LOOPBACK) fail("--rehearsal is only allowed against loopback RPCs");
if (!REHEARSAL && RPC_IS_LOOPBACK) fail("a loopback deployment preflight requires --rehearsal");
if (!REHEARSAL && !RPC.startsWith("https://")) fail("production preflight requires an https RPC");
if (CANARY_RECOVERY) {
  for (const [label, value] of [
    ["recovery instant token", RECOVERY_INSTANT_TOKEN],
    ["recovery auction token", RECOVERY_AUCTION_TOKEN],
    ["recovery auction", RECOVERY_AUCTION],
  ]) {
    try {
      getAddress(value);
    } catch {
      fail(`${label} is missing or malformed`);
    }
  }
  if (!FORBID_LEGACY_ARTIFACT)
    fail("recovery preflight requires --forbid-legacy-artifact");
  if (existsSync(FORBID_LEGACY_ARTIFACT)) {
    fail(
      "legacy combined bidLaunchHookr artifact exists; raw owner-bid recovery is not attributable",
    );
  }
}

const EXPECTED_DEPLOYER = getAddress("0x5a52D4B820Ae7F02880d270562950918ACb14aA2");
const POOL_MANAGER = getAddress("0x8366a39CC670B4001A1121B8F6A443A643e40951");
const CREATE2_DEPLOYER = getAddress("0x4e59b44847b379578588920cA78FbF26c0B4956C");
// Uniswap Labs' deployed, permissionless CCA factory: a constructor dependency of the v5
// launchpad, not deployed by Hookr. Its runtime codehash is pinned so a wrong or moved factory
// blocks the canary before any spend, exactly as DeployRobinhoodV5 blocks the simulation.
const AUCTION_FACTORY = getAddress("0x000000001F26a0044BaA66024e7b6599c61963F8");
// The HOOKR token: the alternative quote currency (a launchpad + router constructor immutable)
// and the asset the flywheel burner buys and burns.
const HOOKR_TOKEN = getAddress("0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c");
const HOOKR_TOKEN_CODEHASH =
  "0xd9346eaf1a9878650549765e1d4ce8b3d0516d93d3203e1c8b99e382428ebc8d";
const HOOKR_INSTANT_OPEN_FDV = 2_500_000n * 10n ** 18n;
const PRODUCTION_AUCTION_DURATION_BLOCKS = 125_000n;
const PRODUCTION_CLAIM_DELAY_BLOCKS = 0n;
const PRODUCTION_MIGRATION_DELAY_BLOCKS = 1n;
const REVIEWED_CREATION_FEE_WEI = 200_000_000_000_000n;
const RECOVERY_PROTOCOL_FEES_WEI = 400_000_000_000_000n;
const RECOVERY_MIN_FLYWHEEL_CLAIMABLE_WEI = 3_000_000_000_000n;
const RECOVERY_SENDER_NONCE = 713n;
const INTENT_INSTANT = keccak256(toHex("hookr.v5.canary.instant.1"));
const INTENT_AUCTION = keccak256(toHex("hookr.v5.canary.auction.1"));
const INTENT_HOOKR = keccak256(toHex("hookr.v5.canary.hookr.1"));
const REVIEWED_MAX_BUYBACK_WEI = 250_000_000_000_000_000n;
const HOOKR_POOL_FEE = 2500;
const HOOKR_POOL_TICK_SPACING = 25;
const POOL_MANAGER_CODEHASH =
  "0xbd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626";
const CREATE2_DEPLOYER_CODEHASH =
  "0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989";
const AUCTION_FACTORY_CODEHASH =
  "0xa1d2a90564f4f63580b25de42efaff92505c254b00fc666f65ab38126cce5cfa";
/**
 * The eleven packed scalar immutables of HookrLaunchpadV5 as their exact 32-byte runtime slot
 * words (uints zero-extended, int24 ticks sign-extended): the five ETH instant-open words, the
 * five HOOKR instant-open words (fixed 2,500,000 HOOKR FDV), and the ArbSys clock flag. Derived
 * from the reviewed constructor input by contracts/test/V5ImmutableReadout.t.sol, which also
 * proves the encoding against a deployed runtime's declared immutable slots. Re-derive whenever
 * a DeployRobinhoodV5 constructor constant or the instant-open geometry changes.
 */
const LAUNCHPAD_V5_SCALAR_IMMUTABLE_WORDS = Object.freeze([
  // instantOpenFdvWei = 2.5e18
  "0x00000000000000000000000000000000000000000000000022b1c8c1227a0000",
  // instantOpenPriceWei = 2.5e9
  "0x000000000000000000000000000000000000000000000000000000009502f900",
  // instantSqrtPriceX96
  "0x0000000000000000000000000000000000004e0c5b34079842b3d1eec3228cd2",
  // instantBandLower (negative tick, sign-extended)
  "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffdd14",
  // instantBandUpper
  "0x00000000000000000000000000000000000000000000000000000000000305ac",
  // hookrInstantOpenFdv = 2.5e24 (2,500,000 HOOKR)
  "0x0000000000000000000000000000000000000000000211654585005212800000",
  // hookrInstantOpenPrice = 2.5e15
  "0x0000000000000000000000000000000000000000000000000008e1bc9bf04000",
  // hookrInstantSqrtPriceX96
  "0x0000000000000000000000000000000000000013f65f97a717582763a2a2c41a",
  // hookrBandLower (negative tick, sign-extended)
  "0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffffffdc150",
  // hookrBandUpper
  "0x000000000000000000000000000000000000000000000000000000000000e9e8",
  // useArbSysClock: TRUE on live 4663 (the constructor probe finds the ArbSys precompile, so
  // auction timing rides the CCA's clock). A plain-EVM deployment of the same bytes encodes 0.
  "0x0000000000000000000000000000000000000000000000000000000000000001",
]);
const BURNER_V5_SCALAR_IMMUTABLE_WORDS = Object.freeze([
  `0x${BigInt(HOOKR_POOL_FEE).toString(16).padStart(64, "0")}`,
  `0x${BigInt(HOOKR_POOL_TICK_SPACING).toString(16).padStart(64, "0")}`,
]);
const HOOK_FLAGS =
  (1n << 13n) | (1n << 11n) | (1n << 7n) | (1n << 6n) | (1n << 3n) | (1n << 2n);

const RUNTIME_ARTIFACTS = Object.freeze({
  launchpad: {
    path: "contracts/out/HookrLaunchpadV5.sol/HookrLaunchpadV5.json",
    sourcePath: "src/HookrLaunchpadV5.sol",
    contractName: "HookrLaunchpadV5",
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
  burner: {
    path: "contracts/out/HookrFlywheelBurner.sol/HookrFlywheelBurner.json",
    sourcePath: "src/HookrFlywheelBurner.sol",
    contractName: "HookrFlywheelBurner",
  },
  launchpadLib: {
    path: "contracts/out/HookrLaunchpadLibV5.sol/HookrLaunchpadLibV5.json",
    sourcePath: "src/libraries/HookrLaunchpadLibV5.sol",
    contractName: "HookrLaunchpadLibV5",
  },
});

const identityAbi = parseAbi([
  "function contractName() view returns (string)",
  "function contractVersion() view returns (string)",
  "function hook() view returns (address)",
  "function launchpad() view returns (address)",
  "function poolManager() view returns (address)",
  "function auctionFactory() view returns (address)",
  "function owner() view returns (address)",
  "function blueprintsCount() view returns (uint256)",
  "function tokensCount() view returns (uint256)",
  "function allTokens(uint256 index) view returns (address)",
  "function launchedByIntent(address creator,bytes32 intentId) view returns (address)",
  "function getLaunch(address token) view returns ((address token,address creator,uint40 launchBlock,uint32 blueprintId,uint8 mode,uint8 status,uint96 floorFdvWei,uint96 raiseFloorWei,uint16 reserveBps,address auction,uint40 auctionEndBlock,uint40 migratedAtBlock,uint160 clearingSqrtPriceX96,bytes32 poolId,uint8 quote,(uint32 guardBlocks,uint16 maxBuyBps,uint24 snipeTaxPips,uint24 baseFeePips,uint24 maxFeePips,uint16 surgeSens,uint16 burnBps,uint96 burnTriggerWei,uint16 lpBps,uint16 potBps,uint32 potEveryNBuys,uint96 potMinBuyWei) params) launch)",
  "function creationFeeWei() view returns (uint96)",
  "function protocolFeesWei() view returns (uint256)",
  "function flywheelRecipient() view returns (address)",
  "function claimableWei(address recipient) view returns (uint256)",
  "function quoteToken() view returns (address)",
  "function hookrToken() view returns (address)",
  "function maxBuybackWei() view returns (uint96)",
  "function totalEthSpent() view returns (uint256)",
  "function totalHookrBurned() view returns (uint256)",
  "function hookrInstantOpenFdv() view returns (uint96)",
  "function auctionDurationBlocks() view returns (uint64)",
  "function claimDelayBlocks() view returns (uint64)",
  "function migrationDelayBlocks() view returns (uint64)",
  "function poolFee() view returns (uint24)",
  "function poolTickSpacing() view returns (int24)",
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

const pairRun = (run, label) => {
  const receiptMap = new Map();
  for (const receipt of run.receipts ?? []) {
    const hash = String(receipt.transactionHash ?? "").toLowerCase();
    if (!hash) fail(`${label} contains a receipt without a transaction hash`);
    if (receiptMap.has(hash)) fail(`${label} contains duplicate receipt hash ${hash}`);
    receiptMap.set(hash, receipt);
  }
  const pairs = (run.transactions ?? []).map((tx, index) => {
    const receipt = receiptMap.get(String(tx.hash ?? "").toLowerCase());
    if (!receipt) fail(`${label} tx #${index} has no hash-matched artifact receipt`);
    return { tx, receipt };
  });
  if (pairs.length !== receiptMap.size || pairs.length !== (run.receipts ?? []).length) {
    fail(
      `${label} transaction/receipt cardinality differs: ${pairs.length}/${(run.receipts ?? []).length}`,
    );
  }
  if (new Set(pairs.map(({ tx }) => String(tx.hash).toLowerCase())).size !== pairs.length) {
    fail(`${label} contains duplicate transaction hashes`);
  }
  return pairs;
};

const mainDeployPairs = pairRun(deployRun, "deploy artifact");
let deployPairs;
let reusedLibrary = false;
let libraryRun = null;
let libraryEvidence = null;
if (mainDeployPairs.length === 12) {
  deployPairs = mainDeployPairs;
} else if (mainDeployPairs.length === 11) {
  if (!LIBRARY_EVIDENCE_PATH) {
    fail(
      "an 11-transaction deployment reused the linked library; pass --library-evidence with its reviewed provenance record",
    );
  }
  libraryEvidence = load(LIBRARY_EVIDENCE_PATH);
  if (libraryEvidence.kind !== "reused-library-evidence-v1" || libraryEvidence.chainId !== 4663) {
    fail("library evidence kind or chain is not reviewed");
  }
  const sourceArtifactPath = String(libraryEvidence.sourceArtifact ?? "");
  if (!sourceArtifactPath) fail("library evidence has no source artifact path");
  const sourceArtifactSha256 = sha256File(sourceArtifactPath);
  if (sourceArtifactSha256 !== String(libraryEvidence.sourceArtifactSha256 ?? "").toLowerCase()) {
    fail("library source artifact SHA-256 differs from the reviewed provenance record");
  }
  libraryRun = load(sourceArtifactPath);
  if (libraryRun.chain !== 4663) {
    fail(`library deploy artifact chain is ${libraryRun.chain}, expected 4663`);
  }
  const shape = libraryEvidence.sourceArtifactShape ?? {};
  if (
    (libraryRun.transactions ?? []).length !== shape.transactions ||
    (libraryRun.receipts ?? []).length !== shape.receipts ||
    (libraryRun.pending ?? []).length !== shape.pending
  ) {
    fail("library source artifact shape differs from the reviewed provenance record");
  }
  const transactionIndex = Number(libraryEvidence.transactionIndex);
  const libraryTx = libraryRun.transactions?.[transactionIndex];
  if (
    !Number.isInteger(transactionIndex) ||
    !libraryTx ||
    libraryTx.transactionType !== "CREATE2" ||
    libraryTx.contractName !== "HookrLaunchpadLibV5"
  ) {
    fail("library evidence does not select the reviewed HookrLaunchpadLibV5 CREATE2 record");
  }
  if (!sameHex(libraryTx.hash, libraryEvidence.transactionHash)) {
    fail("library evidence transaction hash differs from the raw Forge record");
  }
  if (!sameHex(keccak256(libraryTx.transaction.input), libraryEvidence.calldataHash)) {
    fail("library evidence calldata hash differs from the raw Forge record");
  }
  if (getAddress(libraryTx.contractAddress) !== getAddress(libraryEvidence.address)) {
    fail("library evidence address differs from the raw Forge record");
  }
  const pendingHashes = libraryRun.pending ?? [];
  if (new Set(pendingHashes.map((hash) => String(hash).toLowerCase())).size !== pendingHashes.length) {
    fail("raw Forge artifact contains duplicate pending transaction hashes");
  }
  if (!pendingHashes.some((hash) => sameHex(hash, libraryTx.hash))) {
    fail("raw Forge artifact does not mark the selected library transaction as pending recovery");
  }
  const excludedPending = libraryEvidence.excludedPendingTransactions ?? [];
  if (!Array.isArray(excludedPending) || excludedPending.length + 1 !== pendingHashes.length) {
    fail("library evidence must classify every raw pending transaction exactly once");
  }
  const classifiedPending = new Set([String(libraryTx.hash).toLowerCase()]);
  for (const excluded of excludedPending) {
    const excludedHash = String(excluded.transactionHash ?? "").toLowerCase();
    if (!excludedHash || classifiedPending.has(excludedHash)) {
      fail("library evidence repeats or excludes the selected library transaction");
    }
    if (!pendingHashes.some((hash) => sameHex(hash, excludedHash))) {
      fail(`excluded pending transaction ${excluded.transactionHash} is absent from the raw artifact`);
    }
    const rawExcluded = (libraryRun.transactions ?? []).find((tx) => sameHex(tx.hash, excludedHash));
    if (!rawExcluded || getAddress(rawExcluded.contractAddress) !== getAddress(excluded.contractAddress)) {
      fail(`excluded pending transaction ${excluded.transactionHash} has the wrong contract address`);
    }
    if (typeof excluded.reason !== "string" || excluded.reason.trim() === "") {
      fail(`excluded pending transaction ${excluded.transactionHash} has no recorded reason`);
    }
    classifiedPending.add(excludedHash);
  }
  if (!pendingHashes.every((hash) => classifiedPending.has(String(hash).toLowerCase()))) {
    fail("library evidence leaves a raw pending transaction unclassified");
  }
  const libraryReceipt = libraryEvidence.receipt;
  if (
    !libraryReceipt ||
    libraryReceipt.status !== "0x1" ||
    !sameHex(libraryReceipt.transactionHash, libraryTx.hash)
  ) {
    fail("library evidence receipt is missing, failed, or names a different transaction");
  }
  deployPairs = [{ tx: libraryTx, receipt: libraryReceipt }, ...mainDeployPairs];
  reusedLibrary = true;
} else {
  fail(`deploy artifact must contain exactly 11 or 12 transactions/receipts, found ${mainDeployPairs.length}`);
}
if (new Set(deployPairs.map(({ tx }) => String(tx.hash).toLowerCase())).size !== 12) {
  fail("combined deployment evidence contains duplicate transaction hashes");
}

// Forge PREPENDS the linked library (#0); the flywheel burner (#1) must exist before the hook,
// whose constructor takes it as an immutable; both wiring calls follow the router — the
// launchpad's setHook then the burner's setHook.
const expectedShape = [
  { type: "CREATE2", contractName: "HookrLaunchpadLibV5" },
  { type: "CREATE", contractName: "HookrFlywheelBurner" },
  { type: "CREATE", contractName: "HookrLaunchpadV5" },
  { type: "CREATE2", contractName: "HookrHook" },
  { type: "CREATE", contractName: "HookrSwapRouter" },
  { fn: "setHook" }, // pad.setHook(hook)
  { fn: "setHook" }, // burner.setHook(hook)
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
try {
  git("merge-base", "--is-ancestor", sourceCommit, headCommit);
} catch {
  fail(
    `deployment source ${sourceCommit.slice(0, 12)} is not an ancestor of canary operator ${headCommit.slice(0, 12)}`,
  );
}
if (sourceCommit === headCommit) {
  fail("canary operator must be a descendant commit carrying the reviewed ArbSys shim");
}
const canaryScriptLineageDiff = git(
  "diff",
  "--name-only",
  sourceCommit,
  headCommit,
  "--",
  "contracts/script/CanaryRobinhoodV5.s.sol",
);
if (canaryScriptLineageDiff !== "contracts/script/CanaryRobinhoodV5.s.sol") {
  fail("canary operator does not carry the reviewed CanaryRobinhoodV5 source update");
}
const deployedSourceDiff = git(
  "diff",
  "--name-only",
  sourceCommit,
  headCommit,
  "--",
  "contracts/src",
  "contracts/lib",
  "contracts/foundry.toml",
  "contracts/script/DeployRobinhoodV5.s.sol",
);
if (deployedSourceDiff !== "") {
  fail(
    `deployed contract/source inputs changed after ${sourceCommit.slice(0, 12)} (${deployedSourceDiff.split("\n").join(", ")})`,
  );
}
const canaryOperatorCommit = headCommit;
let librarySourceCommit = sourceCommit;
if (reusedLibrary) {
  const artifactCommit = String(libraryRun?.commit ?? "").trim();
  if (!artifactCommit) fail("library deploy artifact has no source commit");
  try {
    librarySourceCommit = git("rev-parse", artifactCommit);
    if (librarySourceCommit !== String(libraryEvidence.sourceCommit ?? "")) {
      fail("library evidence source commit differs from its raw Forge artifact");
    }
    git("merge-base", "--is-ancestor", librarySourceCommit, headCommit);
  } catch {
    fail(`library artifact commit ${artifactCommit} is not an ancestor of current HEAD`);
  }
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
    "contracts/run-canary-v5.sh",
    "scripts/build-v5-phase-a-index.mjs",
    "scripts/collect-v5-phase-b-evidence.mjs",
    "scripts/build-v5-phase-b-evidence.mjs",
    "scripts/redact-rpc-stream.mjs",
    "scripts/verify-deployment-preflight.mjs",
    "scripts/lib/instant-canary-evidence.mjs",
    "scripts/lib/release-promotion-evidence.mjs",
    "scripts/lib/runtime-template-evidence.mjs",
    "scripts/lib/v5-canary-evidence.mjs",
    "contracts/release-evidence/v5/reused-launchpad-library.json",
    "contracts/broadcast/DeployRobinhoodV5.s.sol/4663/run-1787263839227.json",
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
const burner = getAddress(deployPairs[1].tx.contractAddress);
const launchpad = getAddress(deployPairs[2].tx.contractAddress);
const hook = getAddress(deployPairs[3].tx.contractAddress);
const router = getAddress(deployPairs[4].tx.contractAddress);
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
// Recovery is a current-state readiness gate: its immutable prefix is independently finalized,
// while nonce, intent, status, fee, and flywheel conditions must still hold immediately before the
// next signature. Robinhood's public RPC can prune the older `safe` state even while serving the
// canonical safe header, so bind recovery reads to one exact latest block hash and re-check that
// hash after every read. Fresh deployment preflight keeps the stronger `safe` state boundary.
const stateEvidenceTag = REHEARSAL || CANARY_RECOVERY ? "latest" : "safe";
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
  "burner",
  "launchpad",
  "hook",
  "router",
  "setHook",
  "burnerSetHook",
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
  ["burnerSetHook", burner],
  ["blueprint#1", launchpad],
  ["blueprint#2", launchpad],
  ["blueprint#3", launchpad],
  ["blueprint#4", launchpad],
  ["blueprint#5", launchpad],
]) requireCall(label, target);
for (const [label, expectedAddress] of [
  ["burner", burner],
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
// The burner's one-shot wiring shares the setHook(address) selector; it must name the same hook.
const burnerSetHookCall = decodeCall(records.get("burnerSetHook"), setHookAbi, "setHook", "burnerSetHook");
if (getAddress(burnerSetHookCall.args[0]) !== hook) fail("burner setHook calldata names the wrong hook");

const runtime = async (address, label) => {
  const code = await client.getCode({ address, ...at });
  if (!code || code === "0x") fail(`${label} has no runtime at the state evidence head`);
  return code;
};
const [
  launchpadCode,
  hookCode,
  routerCode,
  burnerCode,
  launchpadLibCode,
  poolManagerCode,
  create2Code,
  auctionFactoryCode,
  hookrTokenCode,
] = await Promise.all([
  runtime(launchpad, "launchpad"),
  runtime(hook, "hook"),
  runtime(router, "router"),
  runtime(burner, "flywheel burner"),
  runtime(launchpadLib, "launchpad library"),
  runtime(POOL_MANAGER, "PoolManager"),
  runtime(CREATE2_DEPLOYER, "canonical CREATE2 deployer"),
  runtime(AUCTION_FACTORY, "CCA auction factory"),
  runtime(HOOKR_TOKEN, "HOOKR token"),
]);
if (hookrTokenCode === "0x") fail("HOOKR token has no runtime");
if (!sameHex(keccak256(hookrTokenCode), HOOKR_TOKEN_CODEHASH)) {
  fail("HOOKR token runtime codehash is not reviewed");
}
if (!sameHex(keccak256(poolManagerCode), POOL_MANAGER_CODEHASH)) {
  fail("PoolManager runtime codehash is not reviewed");
}
if (!sameHex(keccak256(create2Code), CREATE2_DEPLOYER_CODEHASH)) {
  fail("canonical CREATE2 deployer runtime codehash is not reviewed");
}
if (!sameHex(keccak256(auctionFactoryCode), AUCTION_FACTORY_CODEHASH)) {
  fail("CCA auction factory runtime codehash is not reviewed");
}
try {
  validateReviewedRuntime({
    artifact: runtimeArtifacts.launchpad,
    liveCode: launchpadCode,
    expectedTarget: RUNTIME_ARTIFACTS.launchpad,
    expectedImmutableAddresses: [POOL_MANAGER, AUCTION_FACTORY, HOOKR_TOKEN],
    expectedImmutableWords: LAUNCHPAD_V5_SCALAR_IMMUTABLE_WORDS,
    expectedLinks: { "src/libraries/HookrLaunchpadLibV5.sol:HookrLaunchpadLibV5": launchpadLib },
    expectedNormalizedTemplateHash: REVIEWED_NORMALIZED_RUNTIME_HASHES.launchpadV5,
    expectedReferenceLayoutHash: REVIEWED_RUNTIME_REFERENCE_LAYOUT_HASHES.launchpadV5,
  });
  validateReviewedRuntime({
    artifact: runtimeArtifacts.hook,
    liveCode: hookCode,
    expectedTarget: RUNTIME_ARTIFACTS.hook,
    // The hook's constructor is (pm, launchpad, burner) — the flywheel recipient is immutable.
    expectedImmutableAddresses: [POOL_MANAGER, launchpad, burner],
    expectedNormalizedTemplateHash: REVIEWED_NORMALIZED_RUNTIME_HASHES.hookV5,
    expectedReferenceLayoutHash: REVIEWED_RUNTIME_REFERENCE_LAYOUT_HASHES.hookV5,
  });
  validateReviewedRuntime({
    artifact: runtimeArtifacts.router,
    liveCode: routerCode,
    expectedTarget: RUNTIME_ARTIFACTS.router,
    // The router's constructor is (pm, hook, HOOKR) — HOOKR is its one accepted ERC-20 quote.
    expectedImmutableAddresses: [POOL_MANAGER, hook, HOOKR_TOKEN],
    expectedNormalizedTemplateHash: REVIEWED_NORMALIZED_RUNTIME_HASHES.routerV5,
    expectedReferenceLayoutHash: REVIEWED_RUNTIME_REFERENCE_LAYOUT_HASHES.routerV5,
  });
  validateReviewedRuntime({
    artifact: runtimeArtifacts.burner,
    liveCode: burnerCode,
    expectedTarget: RUNTIME_ARTIFACTS.burner,
    expectedImmutableAddresses: [POOL_MANAGER, HOOKR_TOKEN],
    expectedImmutableWords: BURNER_V5_SCALAR_IMMUTABLE_WORDS,
    expectedNormalizedTemplateHash: REVIEWED_NORMALIZED_RUNTIME_HASHES.burnerV5,
    expectedReferenceLayoutHash: REVIEWED_RUNTIME_REFERENCE_LAYOUT_HASHES.burnerV5,
  });
  validateReviewedRuntime({
    artifact: runtimeArtifacts.launchpadLib,
    liveCode: launchpadLibCode,
    expectedTarget: RUNTIME_ARTIFACTS.launchpadLib,
    expectedImmutableAddresses: [launchpadLib],
    expectedNormalizedTemplateHash: REVIEWED_NORMALIZED_RUNTIME_HASHES.launchpadLibV5,
    expectedReferenceLayoutHash: REVIEWED_RUNTIME_REFERENCE_LAYOUT_HASHES.launchpadLibV5,
  });
} catch (error) {
  fail(`reviewed runtime comparison: ${error.message}`);
}

const read = (address, functionName) =>
  client.readContract({ address, abi: identityAbi, functionName, ...at });
const readWithArgs = (address, functionName, args) =>
  client.readContract({ address, abi: identityAbi, functionName, args, ...at });
const checks = [
  [await read(launchpad, "contractName"), "HookrLaunchpadV5", "launchpad identity"],
  [await read(launchpad, "contractVersion"), "5.0.1", "launchpad version"],
  [await read(hook, "contractName"), "HookrHook", "hook identity"],
  [await read(hook, "contractVersion"), "1.0.0", "hook version"],
  [await read(router, "contractName"), "HookrSwapRouter", "router identity"],
  [await read(router, "contractVersion"), "1.0.0", "router version"],
  [await read(burner, "contractName"), "HookrFlywheelBurner", "burner identity"],
  [await read(burner, "contractVersion"), "1.0.1", "burner version"],
  [getAddress(await read(launchpad, "hook")), hook, "launchpad hook"],
  [getAddress(await read(launchpad, "auctionFactory")), AUCTION_FACTORY, "launchpad CCA factory"],
  [getAddress(await read(launchpad, "hookrToken")), HOOKR_TOKEN, "launchpad HOOKR quote"],
  [await read(launchpad, "hookrInstantOpenFdv"), HOOKR_INSTANT_OPEN_FDV, "launchpad HOOKR instant FDV"],
  [getAddress(await read(hook, "launchpad")), launchpad, "hook launchpad"],
  [getAddress(await read(hook, "poolManager")), POOL_MANAGER, "hook PoolManager"],
  // The flywheel triangle: hook accrues to the burner, the burner claims from the hook, the
  // burner burns the pinned HOOKR token. All three must agree before the canary may spend.
  [getAddress(await read(hook, "flywheelRecipient")), burner, "hook flywheel recipient"],
  [getAddress(await read(burner, "hook")), hook, "burner hook"],
  [getAddress(await read(burner, "hookrToken")), HOOKR_TOKEN, "burner HOOKR token"],
  [getAddress(await read(burner, "poolManager")), POOL_MANAGER, "burner PoolManager"],
  [await read(burner, "poolFee"), HOOKR_POOL_FEE, "burner pool fee"],
  [await read(burner, "poolTickSpacing"), HOOKR_POOL_TICK_SPACING, "burner pool tick spacing"],
  [getAddress(await read(burner, "owner")), EXPECTED_DEPLOYER, "burner owner"],
  [await read(burner, "maxBuybackWei"), REVIEWED_MAX_BUYBACK_WEI, "burner buyback ceiling"],
  [await read(burner, "totalEthSpent"), 0n, "burner pre-canary ETH spend"],
  [await read(burner, "totalHookrBurned"), 0n, "burner pre-canary HOOKR burn"],
  [getAddress(await read(router, "hook")), hook, "router hook"],
  [getAddress(await read(router, "poolManager")), POOL_MANAGER, "router PoolManager"],
  [getAddress(await read(router, "quoteToken")), HOOKR_TOKEN, "router HOOKR quote"],
  [getAddress(await read(launchpad, "owner")), EXPECTED_DEPLOYER, "launchpad owner"],
  [await read(launchpad, "creationFeeWei"), REVIEWED_CREATION_FEE_WEI, "launchpad creation fee"],
  [
    await read(launchpad, "auctionDurationBlocks"),
    PRODUCTION_AUCTION_DURATION_BLOCKS,
    "launchpad production auction duration",
  ],
  [
    await read(launchpad, "claimDelayBlocks"),
    PRODUCTION_CLAIM_DELAY_BLOCKS,
    "launchpad production claim delay",
  ],
  [
    await read(launchpad, "migrationDelayBlocks"),
    PRODUCTION_MIGRATION_DELAY_BLOCKS,
    "launchpad production migration delay",
  ],
];
for (const [actual, expected, label] of checks) {
  if (actual !== expected)
    fail(`${label}: expected ${expected}, read ${actual}`);
}
const tokenCount = BigInt(await read(launchpad, "tokensCount"));
const protocolFeesWei = BigInt(await read(launchpad, "protocolFeesWei"));
if (CANARY_RECOVERY) {
  // Launches and pool-fee collection are permissionless. Preserve the exact reviewed prefix and
  // minimum creation-fee baseline without letting unrelated ambient activity grief recovery.
  if (tokenCount < 2n)
    fail(
      `launchpad recovery token count is ${tokenCount}, expected at least 2`,
    );
  if (protocolFeesWei < RECOVERY_PROTOCOL_FEES_WEI) {
    fail(
      `launchpad recovery protocol fees are ${protocolFeesWei}, expected at least ${RECOVERY_PROTOCOL_FEES_WEI}`,
    );
  }
} else {
  if (tokenCount !== 0n)
    fail(`launchpad pre-canary token count: expected 0, read ${tokenCount}`);
  if (protocolFeesWei !== 0n) {
    fail(
      `launchpad pre-canary protocol fees: expected 0, read ${protocolFeesWei}`,
    );
  }
}
const claimableToBurner = BigInt(
  await readWithArgs(hook, "claimableWei", [burner]),
);
const burnerNativeBalance = await client.getBalance({ address: burner, ...at });
if (CANARY_RECOVERY) {
  if (
    claimableToBurner + burnerNativeBalance <
    RECOVERY_MIN_FLYWHEEL_CLAIMABLE_WEI
  ) {
    fail(
      "recovery flywheel accrual is below the exact Phase-A minimum across hook and burner",
    );
  }
} else if (claimableToBurner !== 0n || burnerNativeBalance !== 0n) {
  fail("fresh preflight found pre-canary flywheel value in the hook or burner");
}

if (CANARY_RECOVERY) {
  const zeroAddress = "0x0000000000000000000000000000000000000000";
  const expectedInstantToken = getAddress(RECOVERY_INSTANT_TOKEN);
  const expectedAuctionToken = getAddress(RECOVERY_AUCTION_TOKEN);
  const expectedAuction = getAddress(RECOVERY_AUCTION);
  if (
    expectedInstantToken === zeroAddress ||
    expectedAuctionToken === zeroAddress ||
    expectedAuction === zeroAddress ||
    expectedInstantToken === expectedAuctionToken
  ) {
    fail("recovery launch identities are zero or aliased");
  }

  const [
    token0,
    token1,
    instantIntentToken,
    auctionIntentToken,
    hookrIntentToken,
  ] = await Promise.all([
    readWithArgs(launchpad, "allTokens", [0n]),
    readWithArgs(launchpad, "allTokens", [1n]),
    readWithArgs(launchpad, "launchedByIntent", [
      EXPECTED_DEPLOYER,
      INTENT_INSTANT,
    ]),
    readWithArgs(launchpad, "launchedByIntent", [
      EXPECTED_DEPLOYER,
      INTENT_AUCTION,
    ]),
    readWithArgs(launchpad, "launchedByIntent", [
      EXPECTED_DEPLOYER,
      INTENT_HOOKR,
    ]),
  ]);
  for (const [actual, expected, label] of [
    [token0, expectedInstantToken, "allTokens[0] instant prefix"],
    [token1, expectedAuctionToken, "allTokens[1] auction prefix"],
    [instantIntentToken, expectedInstantToken, "instant intent"],
    [auctionIntentToken, expectedAuctionToken, "auction intent"],
    [hookrIntentToken, zeroAddress, "unused HOOKR intent"],
  ]) {
    if (getAddress(actual) !== expected)
      fail(`${label}: expected ${expected}, read ${actual}`);
  }

  const [
    instantCode,
    auctionTokenCode,
    auctionCode,
    instantLaunch,
    auctionLaunch,
  ] = await Promise.all([
    runtime(expectedInstantToken, "recovery instant token"),
    runtime(expectedAuctionToken, "recovery auction token"),
    runtime(expectedAuction, "recovery CCA"),
    readWithArgs(launchpad, "getLaunch", [expectedInstantToken]),
    readWithArgs(launchpad, "getLaunch", [expectedAuctionToken]),
  ]);
  // Retain the values so lint and future review cannot mistake the runtime reads for dead calls.
  if (
    instantCode === "0x" ||
    auctionTokenCode === "0x" ||
    auctionCode === "0x"
  ) {
    fail("recovery launch runtime is missing");
  }
  const launchField = (value, name, index) => value?.[name] ?? value?.[index];
  const assertLaunch = (
    launch,
    expectedToken,
    expectedMode,
    acceptedStatuses,
    expectedAuctionAddress,
    label,
  ) => {
    const actualToken = getAddress(launchField(launch, "token", 0));
    const creator = getAddress(launchField(launch, "creator", 1));
    const mode = Number(launchField(launch, "mode", 4));
    const status = Number(launchField(launch, "status", 5));
    const auctionAddress = getAddress(launchField(launch, "auction", 9));
    const quote = Number(launchField(launch, "quote", 14));
    if (
      actualToken !== expectedToken ||
      creator !== EXPECTED_DEPLOYER ||
      mode !== expectedMode ||
      !acceptedStatuses.includes(status) ||
      auctionAddress !== expectedAuctionAddress ||
      quote !== 0
    ) {
      fail(
        `${label} identity, mode, status, auction, or quote is not the reviewed recovery launch`,
      );
    }
  };
  assertLaunch(
    instantLaunch,
    expectedInstantToken,
    0,
    [1],
    zeroAddress,
    "instant recovery launch",
  );
  assertLaunch(
    auctionLaunch,
    expectedAuctionToken,
    1,
    [0, 1],
    expectedAuction,
    "auction recovery launch",
  );

  const latestRead = (address, functionName, args) =>
    client.readContract({ address, abi: identityAbi, functionName, args });
  const [
    latestHookrIntent,
    latestClaimable,
    latestBurnerBalance,
    latestSpent,
    latestBurned,
  ] = await Promise.all([
    latestRead(launchpad, "launchedByIntent", [
      EXPECTED_DEPLOYER,
      INTENT_HOOKR,
    ]),
    latestRead(hook, "claimableWei", [burner]),
    client.getBalance({ address: burner, blockTag: "latest" }),
    latestRead(burner, "totalEthSpent"),
    latestRead(burner, "totalHookrBurned"),
  ]);
  if (getAddress(latestHookrIntent) !== zeroAddress)
    fail("HOOKR recovery intent became used at latest");
  if (
    BigInt(latestClaimable) + latestBurnerBalance <
    RECOVERY_MIN_FLYWHEEL_CLAIMABLE_WEI
  ) {
    fail(
      "latest recovery flywheel value is below the exact Phase-A accrual minimum",
    );
  }
  if (BigInt(latestSpent) !== 0n || BigInt(latestBurned) !== 0n) {
    fail("flywheel spend or burn occurred before recovery");
  }
  const [latestNonce, pendingNonce] = await Promise.all([
    client.getTransactionCount({
      address: EXPECTED_DEPLOYER,
      blockTag: "latest",
    }),
    client.getTransactionCount({
      address: EXPECTED_DEPLOYER,
      blockTag: "pending",
    }),
  ]);
  if (
    BigInt(latestNonce) !== RECOVERY_SENDER_NONCE ||
    BigInt(pendingNonce) !== RECOVERY_SENDER_NONCE
  ) {
    fail(
      `recovery sender nonce changed: latest=${latestNonce} pending=${pendingNonce}, expected ${RECOVERY_SENDER_NONCE}`,
    );
  }
}
if (BigInt(await read(launchpad, "blueprintsCount")) < 6n)
  fail("house blueprints are missing");

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
console.log(`  deployment source ${sourceCommit}`);
console.log(`  canary operator   ${canaryOperatorCommit}`);
console.log(`  launchpad ${launchpad} ${keccak256(launchpadCode)}`);
console.log(`  hook      ${hook} ${keccak256(hookCode)}`);
console.log(`  router    ${router} ${keccak256(routerCode)}`);
console.log(`  library   ${launchpadLib} ${keccak256(launchpadLibCode)}`);
console.log(`  burner    ${burner} ${keccak256(burnerCode)}`);
if (reusedLibrary) {
  console.log(`  lib source ${librarySourceCommit} (${LIBRARY_EVIDENCE_PATH})`);
}
console.log(
  `  proof     ${reusedLibrary ? "11 current + 1 reused library" : "12/12"} receipts canonical and ${REHEARSAL ? "rehearsal-latest" : "finalized"}; blueprints 5/5 exact`,
);
