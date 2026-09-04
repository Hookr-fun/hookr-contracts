#!/usr/bin/env node
/**
 * Hookr generation-5 release promotion.
 *
 * Consumes five live Forge broadcast artifacts (DeployRobinhoodV5 plus four staged Phase-A canary
 * entrypoints), the raw owner-bid recovery pair, both raw owner timing pairs, the hash-bound Phase-A
 * evidence index v3, and the six-action canonical Phase-B evidence index (permissionless actions may
 * alias one helper transaction/receipt),
 * verifies every receipt in order, re-reads the deployed contracts at one pinned block over live
 * RPC, and only then rewrites CURRENT_RELEASE_MANIFEST in src/lib/release-manifest.ts — retaining
 * the outgoing generation-4 manifest verbatim in the same atomic write. Every check fails closed:
 * a mismatch prints the reason and leaves the manifest untouched.
 *
 * Usage:
 *   node scripts/promote-release-manifest.mjs \
 *     [--deploy contracts/broadcast/DeployRobinhoodV5.s.sol/4663/run-latest.json] \
 *     [--library-evidence contracts/release-evidence/v5/reused-launchpad-library.json] \
 *     [--canary-instant-launch contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/openInstant-latest.json] \
 *     [--canary-instant-buy-auction-launch contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/buyInstantLaunchAuction-latest.json] \
 *     [--canary-owner-bid-transaction contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/owner-bid-transaction.json] \
 *     [--canary-owner-bid-receipt contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/owner-bid-receipt.json] \
 *     [--canary-hookr-launch contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/launchHookrPair-latest.json] \
 *     [--canary-hookr-approve-buy contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/buyHookrPair-latest.json] \
 *     [--canary-timing-shorten-transaction contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/timing-shorten-transaction.json] \
 *     [--canary-timing-shorten-receipt contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/timing-shorten-receipt.json] \
 *     [--canary-timing-restore-transaction contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/timing-restore-transaction.json] \
 *     [--canary-timing-restore-receipt contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/timing-restore-receipt.json] \
 *     [--canary-phase-a-index contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/phase-a-evidence-v5.json] \
 *     [--canary-phase-b-index contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/phase-b-evidence-v5.json] \
 *     [--dry-run]
 *
 * RPC defaults to HOOKR_RPC_URL, then ETH_RPC_URL, then Robinhood's public mainnet endpoint.
 * Prefer the environment variables for authenticated endpoints so credentials do not enter argv.
 */
import assert from "node:assert/strict";
import { lstatSync, realpathSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { isAbsolute, relative, resolve, sep } from "node:path";
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
  toEventSelector,
  toFunctionSelector,
} from "viem";
import { poolIdForKey } from "./lib/instant-canary-evidence.mjs";
import { assertV5PhaseAIndex } from "./build-v5-phase-a-index.mjs";
import {
  assertV5PhaseBEvidence,
  V5_PHASE_B_ACTIONS,
} from "./build-v5-phase-b-evidence.mjs";
import {
  assertAuthenticatedLocalFileUnchanged,
  assertRawReceiptMatchesLive,
  redactConfiguredRpc,
  snapshotAuthenticatedLocalFile,
  V5_CANARY_SPEC,
  validateV5CanaryEvidence,
} from "./lib/v5-canary-evidence.mjs";
import {
  assertReceiptsWithinEvidenceBlock,
  assertStateEvidenceAfterFinality,
  assertStateEvidenceFinalized,
  canonicalCreate2Address,
  deriveLiveLaunchpadDeployBlock,
  HOOK_PARAM_FIELDS,
  validateHouseBlueprintEvidence,
} from "./lib/release-promotion-evidence.mjs";
import { retireAndReplaceCurrentReleaseManifest } from "./lib/release-manifest-patch.mjs";
import {
  assertArtifactSourceHashes,
  REVIEWED_NORMALIZED_RUNTIME_HASHES,
  REVIEWED_RUNTIME_REFERENCE_LAYOUT_HASHES,
  validateReviewedRuntime,
} from "./lib/runtime-template-evidence.mjs";

const args = process.argv.slice(2);
if (
  args.some((argument) => argument === "--rpc" || argument.startsWith("--rpc="))
) {
  console.error(
    "\nPROMOTION BLOCKED: --rpc is forbidden; configure HOOKR_RPC_URL or ETH_RPC_URL in the environment",
  );
  process.exit(1);
}
const flag = (name, fallback) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
};
const DRY_RUN = args.includes("--dry-run");
const DEPLOY_PATH = flag(
  "deploy",
  "contracts/broadcast/DeployRobinhoodV5.s.sol/4663/run-latest.json",
);
const LIBRARY_EVIDENCE_PATH = flag("library-evidence", "");
// Forge names per-signature artifacts after the entrypoint it broadcast. Phase A is deliberately
// split so the CCA target comes from the mined launch receipt/readback, never local prediction.
const CANARY_INSTANT_LAUNCH_PATH = flag(
  "canary-instant-launch",
  "contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/openInstant-latest.json",
);
const CANARY_INSTANT_BUY_AUCTION_LAUNCH_PATH = flag(
  "canary-instant-buy-auction-launch",
  "contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/buyInstantLaunchAuction-latest.json",
);
const CANARY_OWNER_BID_TRANSACTION_PATH = flag(
  "canary-owner-bid-transaction",
  "contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/owner-bid-transaction.json",
);
const CANARY_OWNER_BID_RECEIPT_PATH = flag(
  "canary-owner-bid-receipt",
  "contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/owner-bid-receipt.json",
);
const CANARY_HOOKR_LAUNCH_PATH = flag(
  "canary-hookr-launch",
  "contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/launchHookrPair-latest.json",
);
const CANARY_HOOKR_APPROVE_BUY_PATH = flag(
  "canary-hookr-approve-buy",
  "contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/buyHookrPair-latest.json",
);
const CANARY_TIMING_SHORTEN_TRANSACTION_PATH = flag(
  "canary-timing-shorten-transaction",
  "contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/timing-shorten-transaction.json",
);
const CANARY_TIMING_SHORTEN_RECEIPT_PATH = flag(
  "canary-timing-shorten-receipt",
  "contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/timing-shorten-receipt.json",
);
const CANARY_TIMING_RESTORE_TRANSACTION_PATH = flag(
  "canary-timing-restore-transaction",
  "contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/timing-restore-transaction.json",
);
const CANARY_TIMING_RESTORE_RECEIPT_PATH = flag(
  "canary-timing-restore-receipt",
  "contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/timing-restore-receipt.json",
);
const CANARY_PHASE_A_INDEX_PATH = flag(
  "canary-phase-a-index",
  "contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/phase-a-evidence-v5.json",
);
const CANARY_PHASE_B_INDEX_PATH = flag(
  "canary-phase-b-index",
  "contracts/broadcast/CanaryRobinhoodV5.s.sol/4663/phase-b-evidence-v5.json",
);
const RPC =
  process.env.HOOKR_RPC_URL ||
  process.env.ETH_RPC_URL ||
  "https://rpc.mainnet.chain.robinhood.com";
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
  /^127\./.test(rpcHostname) ||
  /^10\./.test(rpcHostname) ||
  /^192\.168\./.test(rpcHostname) ||
  /^172\.(1[6-9]|2\d|3[01])\./.test(rpcHostname);
const MANIFEST_PATH = "src/lib/release-manifest.ts";
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

const EXPECTED_DEPLOYER = getAddress(
  "0x5a52D4B820Ae7F02880d270562950918ACb14aA2",
);
const ZERO_ADDRESS = getAddress("0x0000000000000000000000000000000000000000");
const NOT_APPLICABLE_ZERO_PROCEEDS = "not-applicable-zero-proceeds";
const POOL_MANAGER = getAddress("0x8366a39CC670B4001A1121B8F6A443A643e40951");
/** Uniswap Labs' deployed CCA factory: a constructor dependency of the launchpad, not ours. */
const AUCTION_FACTORY = getAddress(
  "0x000000001F26a0044BaA66024e7b6599c61963F8",
);
/** Canonical CREATE2 factory. Salted deployments are calls to this, not direct CREATEs. */
const CREATE2_DEPLOYER = getAddress(
  "0x4e59b44847b379578588920cA78FbF26c0B4956C",
);
/** The HOOKR token: the alternative quote currency and the asset the flywheel burner burns. */
const HOOKR_TOKEN = getAddress("0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c");
const HOOKR_TOKEN_CODEHASH =
  "0xd9346eaf1a9878650549765e1d4ce8b3d0516d93d3203e1c8b99e382428ebc8d";
/** The fixed HOOKR-quoted instant opening valuation (2,500,000 HOOKR), a launchpad immutable. */
const HOOKR_INSTANT_OPEN_FDV = 2_500_000n * 10n ** 18n;
/** The ETH-pair flywheel protocol fee, written into the manifest's flywheel section. */
const FLYWHEEL_FEE_PIPS = 3000;
const HOOKR_POOL_FEE = 2500;
const HOOKR_POOL_TICK_SPACING = 25;
const PRODUCTION_AUCTION_DURATION_BLOCKS = 125_000n;
const PRODUCTION_CLAIM_DELAY_BLOCKS = 0n;
const PRODUCTION_MIGRATION_DELAY_BLOCKS = 1n;
const CANARY_AUCTION_DURATION_BLOCKS = 20_000n;
const CANARY_AUCTION_SUPPLY = 800_000_000n * 10n ** 18n;
const CANARY_CCA_FLOOR_PRICE_Q96 = 1_584_563_250_285_286_700n;
const CANARY_CCA_TICK_SPACING_Q96 = 15_845_632_502_852_867n;
const CANARY_CCA_REQUIRED_CURRENCY = 10_000_000_000_000_000n;
const CANARY_CCA_UNIFORM_MPS_PER_BLOCK = 500n;
const CANARY_CCA_UNIFORM_BLOCK_DELTA = 20_000n;
const REVIEWED_CREATION_FEE_WEI = 200_000_000_000_000n;
const REVIEWED_MAX_BUYBACK_WEI = 250_000_000_000_000_000n;
const POOL_MANAGER_CODEHASH =
  "0xbd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626";
const AUCTION_FACTORY_CODEHASH =
  "0xa1d2a90564f4f63580b25de42efaff92505c254b00fc666f65ab38126cce5cfa";
const CREATE2_DEPLOYER_CODEHASH =
  "0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989";
const HOOK_FLAGS =
  (1n << 13n) | (1n << 11n) | (1n << 7n) | (1n << 6n) | (1n << 3n) | (1n << 2n); // 0x28cc
/**
 * The launchpad's eleven SCALAR immutable words, exactly as solc stores them in runtime code
 * (uints zero-extended, int24 band ticks sign-extended): the five ETH instant-open words, the
 * five HOOKR instant-open words (fixed 2,500,000 HOOKR FDV), and the ArbSys clock flag. They
 * derive from library math over the deploy constants, so they cannot be read from the artifact
 * template — contracts/test/V5ImmutableReadout.t.sol reconstructs them with the byte-identical
 * constructor input and proves the encoding against a freshly deployed runtime. Re-derive there
 * on any change to the deploy constants or the instant-open geometry.
 */
const LAUNCHPAD_IMMUTABLE_WORDS = Object.freeze([
  "0x00000000000000000000000000000000000000000000000022b1c8c1227a0000", // instantOpenFdvWei (2.5e18)
  "0x000000000000000000000000000000000000000000000000000000009502f900", // instantOpenPriceWei
  "0x0000000000000000000000000000000000004e0c5b34079842b3d1eec3228cd2", // instantSqrtPriceX96
  "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffdd14", // instantBandLower
  "0x00000000000000000000000000000000000000000000000000000000000305ac", // instantBandUpper
  "0x0000000000000000000000000000000000000000000211654585005212800000", // hookrInstantOpenFdv (2.5e24)
  "0x0000000000000000000000000000000000000000000000000008e1bc9bf04000", // hookrInstantOpenPrice
  "0x0000000000000000000000000000000000000013f65f97a717582763a2a2c41a", // hookrInstantSqrtPriceX96
  "0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffffffdc150", // hookrBandLower
  "0x000000000000000000000000000000000000000000000000000000000000e9e8", // hookrBandUpper
  // useArbSysClock: TRUE on 4663 — the constructor's ArbSys probe finds the live precompile, so
  // the launchpad reads auction timing from the CCA's own clock (arbBlockNumber). A local or
  // plain-EVM deployment of the same bytes encodes FALSE here; this list pins PRODUCTION.
  "0x0000000000000000000000000000000000000000000000000000000000000001", // useArbSysClock
]);
const BURNER_IMMUTABLE_WORDS = Object.freeze([
  `0x${BigInt(HOOKR_POOL_FEE).toString(16).padStart(64, "0")}`,
  `0x${BigInt(HOOKR_POOL_TICK_SPACING).toString(16).padStart(64, "0")}`,
]);

const LAUNCH_ARGS_TUPLE =
  "(string,string,string,string,address,uint32,(uint32,uint16,uint24,uint24,uint24,uint16,uint16,uint96,uint16,uint16,uint32,uint96),uint16,(address,uint16)[])";
// The generation-5 lanes take a `quote` uint8 (0 = ETH, 1 = HOOKR) right after the LaunchArgs
// tuple; the tuple itself is unchanged from the pre-flywheel v5 surface.
const LAUNCH_INSTANT_SELECTOR = toFunctionSelector(
  `launchInstant(${LAUNCH_ARGS_TUPLE},uint8,bytes32)`,
);
const LAUNCH_AUCTION_SELECTOR = toFunctionSelector(
  `launchAuction(${LAUNCH_ARGS_TUPLE},uint8,uint96,uint96,uint16,bytes32)`,
);
const SET_AUCTION_TIMING_SELECTOR = toFunctionSelector(
  "setAuctionTiming(uint64,uint64,uint64)",
);
const ERC20_APPROVE_SELECTOR = toFunctionSelector("approve(address,uint256)");
const BUYBACK_AND_BURN_SELECTOR = toFunctionSelector(
  "buybackAndBurn(uint256,uint256)",
);
const INSTANT_LAUNCHED_TOPIC = toEventSelector(
  "InstantLaunched(address,bytes32,uint96)",
);
const AUCTION_STARTED_TOPIC = toEventSelector(
  "AuctionStarted(address,address,uint40,uint96,uint96,uint16)",
);
const AUCTION_TIMING_SET_TOPIC = toEventSelector(
  "AuctionTimingSet(uint64,uint64,uint64)",
);
const BID_SUBMITTED_TOPIC = toEventSelector(
  "BidSubmitted(uint256,address,uint256,uint128)",
);
const BUYBACK_BURNED_TOPIC = toEventSelector(
  "BuybackBurned(address,uint256,uint256)",
);

const HOOK_PARAMS_ABI_FIELDS =
  "uint32 guardBlocks,uint16 maxBuyBps,uint24 snipeTaxPips,uint24 baseFeePips,uint24 maxFeePips,uint16 surgeSens,uint16 burnBps,uint96 burnTriggerWei,uint16 lpBps,uint16 potBps,uint32 potEveryNBuys,uint96 potMinBuyWei";
const LAUNCH_ARGS_ABI_FIELDS = `string name,string symbol,string tagline,string logoURI,address expectedCreator,uint32 blueprintId,(${HOOK_PARAMS_ABI_FIELDS}) custom,uint16 creatorFeeBps,(address to,uint16 bps)[] feeRecipients`;
const launchpadEvidenceAbi = parseAbi([
  `function launchInstant((${LAUNCH_ARGS_ABI_FIELDS}) args,uint8 quote,bytes32 intentId) payable returns (address token)`,
  `function launchAuction((${LAUNCH_ARGS_ABI_FIELDS}) args,uint8 quote,uint96 floorFdvWei,uint96 raiseFloorWei,uint16 reserveBps,bytes32 intentId) payable returns (address token)`,
  "function migrateAuction(address token)",
  "function claimAuctionProceeds(address token)",
  "function setAuctionTiming(uint64 durationBlocks,uint64 claimDelay,uint64 migrationDelay)",
  "function creationFeeWei() view returns (uint96)",
  "function instantOpenPriceWei() view returns (uint96)",
  "function hookrInstantOpenPrice() view returns (uint96)",
  "function creatorProceedsWei(address token) view returns (uint256)",
  "function launchedByIntent(address creator,bytes32 intentId) view returns (address token)",
  `function getLaunch(address token) view returns ((address token,address creator,uint40 launchBlock,uint32 blueprintId,uint8 mode,uint8 status,uint96 openPriceWei,uint96 openFdvWei,uint16 reserveBps,address auction,uint40 auctionEndBlock,uint40 migratedAtBlock,uint160 sqrtPriceX96AtOpen,bytes32 poolId,uint8 quote,(${HOOK_PARAMS_ABI_FIELDS}) hookParams) launch)`,
  "event TokenLaunched(address indexed token,address indexed creator,uint32 indexed blueprintId,uint8 mode,string name,string symbol,string tagline,string logoURI)",
  "event InstantLaunched(address indexed token,bytes32 indexed poolId,uint96 openPriceWei)",
  "event AuctionStarted(address indexed token,address indexed auction,uint40 endBlock,uint96 floorFdvWei,uint96 raiseFloorWei,uint16 reserveBps)",
  "event AuctionProceeds(address indexed token,address indexed creator,uint256 amountWei)",
  "event AuctionTimingSet(uint64 durationBlocks,uint64 claimDelay,uint64 migrationDelay)",
  "event Migrated(address indexed token,bytes32 indexed poolId,uint160 sqrtPriceX96,uint256 ethLiquidity,uint256 tokenLiquidity,uint256 tokensBurned)",
  "event CreatorFeesClaimed(address indexed token,address indexed payTo,uint256 amountWei)",
  "event LaunchIntentConsumed(address indexed creator,bytes32 indexed intentId,address indexed token)",
]);
const blueprintEvidenceAbi = parseAbi([
  `function saveBlueprint(string name,(${HOOK_PARAMS_ABI_FIELDS}) params,uint16 royaltyBps) returns (uint32 id)`,
  `function getBlueprint(uint32 id) view returns ((address author,uint16 royaltyBps,uint32 uses,uint40 savedAtBlock,string name,(${HOOK_PARAMS_ABI_FIELDS}) params) blueprint)`,
  "event BlueprintSaved(uint32 indexed id,address indexed author,string name,uint16 royaltyBps)",
]);
const routerEvidenceAbi = parseAbi([
  "function exactInput(((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) key,bool zeroForOne,uint128 amountIn,uint128 amountOutMinimum,uint160 sqrtPriceLimitX96,address recipient,uint256 deadline) p) payable returns (uint256 amountOut)",
  "event SwapExecuted(address indexed payer,address indexed recipient,address indexed token,bool zeroForOne,bool exactInput,uint256 amountIn,uint256 amountOut)",
]);
const auctionEvidenceAbi = parseAbi([
  "function submitBid(uint256 maxPriceQ96,uint128 amount,address owner,bytes hookData) payable returns (uint256)",
  "function exitBid(uint256 bidId)",
  "function claimTokens(uint256 bidId)",
  "function claimTokensBatch(address owner,uint256[] bidIds)",
  "function currency() view returns (address)",
  "function token() view returns (address)",
  "function totalSupply() view returns (uint128)",
  "function tokensRecipient() view returns (address)",
  "function fundsRecipient() view returns (address)",
  "function startBlock() view returns (uint64)",
  "function endBlock() view returns (uint64)",
  "function claimBlock() view returns (uint64)",
  "function validationHook() view returns (address)",
  "function currencyRaised() view returns (uint256)",
  "function isGraduated() view returns (bool)",
  "function lbpInitializationParams() view returns ((uint256 initialPriceX96,uint256 tokensSold,uint256 currencyRaised) params)",
  "event BidSubmitted(uint256 indexed id,address indexed owner,uint256 priceQ96,uint128 amount)",
  "event BidExited(uint256 indexed bidId,address indexed owner,uint256 tokensFilled,uint256 currencyRefunded)",
  "event TokensClaimed(uint256 indexed bidId,address indexed owner,uint256 tokensFilled)",
  "event CurrencySwept(address indexed fundsRecipient,uint256 currencyAmount)",
]);
const tokenEvidenceAbi = parseAbi([
  "event Transfer(address indexed from,address indexed to,uint256 value)",
]);
const erc20EvidenceAbi = parseAbi([
  "function approve(address spender,uint256 amount) returns (bool)",
  "function allowance(address owner,address spender) view returns (uint256)",
  "event Approval(address indexed owner,address indexed spender,uint256 value)",
]);
const hookEvidenceAbi = parseAbi([
  "function poolConfig(bytes32 id) view returns (bool initialized,uint40 guardEndBlock,uint24 baseFeePips,uint24 maxFeePips,uint24 snipeTaxPips,uint16 surgeSens,uint16 burnBps,uint16 lpBps,uint16 potBps,uint16 royaltyBps,uint32 potEveryNBuys,uint96 maxBuyWei,uint96 potMinBuyWei,uint96 burnTriggerWei,address royaltyTo,address token,uint24 flywheelFeePips)",
  "event FlywheelFeeAccrued(bytes32 indexed poolId,uint256 amountWei)",
]);
const burnerEvidenceAbi = parseAbi([
  "function collect()",
  "function buybackAndBurn(uint256 ethIn,uint256 minHookrOut) returns (uint256 burned)",
  "event FlywheelCollected(uint256 amountWei)",
  "event BuybackBurned(address indexed caller,uint256 ethIn,uint256 hookrBurned)",
]);
const poolManagerEvidenceAbi = parseAbi([
  "event Initialize(bytes32 indexed id,address indexed currency0,address indexed currency1,uint24 fee,int24 tickSpacing,address hooks,uint160 sqrtPriceX96,int24 tick)",
  "event Swap(bytes32 indexed id,address indexed sender,int128 amount0,int128 amount1,uint160 sqrtPriceX96,uint128 liquidity,int24 tick,uint24 fee)",
]);

const sameHex = (left, right) =>
  typeof left === "string" &&
  typeof right === "string" &&
  left.toLowerCase() === right.toLowerCase();

const fail = (msg) => {
  console.error(`\nPROMOTION BLOCKED: ${redactConfiguredRpc(msg, RPC)}`);
  process.exit(1);
};
const failUnexpected = (reason) => {
  const detail =
    reason instanceof Error ? (reason.stack ?? reason.message) : String(reason);
  console.error(`\nPROMOTION BLOCKED: ${redactConfiguredRpc(detail, RPC)}`);
  process.exit(1);
};
// Top-level viem/transport failures do not necessarily pass through an explicit fail() call.
// Redact those process-level reports too so the configured endpoint is never printed by Node.
process.on("uncaughtException", failUnexpected);
process.on("unhandledRejection", failUnexpected);
const finalityTimeoutSeconds = Number(flag("finality-timeout-seconds", "1800"));
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
    fail("configured RPC endpoint is not a valid URL");
  }
  if (RPC_IS_LOOPBACK) {
    fail(
      `refusing to promote against a local/fork RPC (${rpcHostname}) — pass --dry-run to inspect one`,
    );
  }
  if (!RPC.startsWith("https://")) {
    fail(
      `refusing to promote over a non-https RPC (${rpcHostname || "unknown host"})`,
    );
  }
}

const REPO_ROOT = realpathSync(process.cwd());
const repoEvidencePath = (
  value,
  label,
  { requireCanonicalRelative = false } = {},
) => {
  if (typeof value !== "string" || value === "")
    fail(`${label} path is missing`);
  const absolute = resolve(value);
  const result = relative(REPO_ROOT, absolute);
  if (
    !result ||
    result === ".." ||
    result.startsWith(`..${sep}`) ||
    isAbsolute(result)
  ) {
    fail(`${label} must be inside the repository`);
  }
  const normalized = result.split(sep).join("/");
  if (requireCanonicalRelative && value !== normalized) {
    fail(`${label} must be a canonical repo-relative path`);
  }
  if (!requireCanonicalRelative) {
    const canonicalInput = isAbsolute(value) ? absolute : normalized;
    if (value !== canonicalInput) fail(`${label} path is not canonical`);
  }
  let resolvedRealPath;
  try {
    let cursor = REPO_ROOT;
    for (const component of result.split(sep)) {
      cursor = resolve(cursor, component);
      if (lstatSync(cursor).isSymbolicLink())
        fail(`${label} must not traverse a symlink`);
    }
    resolvedRealPath = realpathSync(absolute);
  } catch (error) {
    fail(`${label} cannot be resolved canonically: ${error.message}`);
  }
  if (resolvedRealPath !== absolute)
    fail(`${label} real path differs from its canonical path`);
  return normalized;
};
// One registry for every local byte used to authenticate the promotion. Repeated Phase-B aliases
// resolve to one canonical path and therefore one snapshot/recheck entry.
const authenticatedLocalInputSnapshots = new Map();
let authenticatedLocalInputRegistrySealed = false;
const authenticatedLocalInputSnapshot = (path, label) => {
  const canonicalPath = repoEvidencePath(path, label);
  const prior = authenticatedLocalInputSnapshots.get(canonicalPath);
  if (prior) {
    prior.labels.add(label);
    return prior;
  }
  if (authenticatedLocalInputRegistrySealed) {
    fail(`${label} was first read after the local-input snapshot boundary`);
  }
  try {
    const snapshot = snapshotAuthenticatedLocalFile(canonicalPath, label);
    snapshot.labels = new Set([label]);
    authenticatedLocalInputSnapshots.set(canonicalPath, snapshot);
    return snapshot;
  } catch (error) {
    fail(error.message);
  }
};
const load = (path, label = "evidence file") => {
  const snapshot = authenticatedLocalInputSnapshot(path, label);
  try {
    return JSON.parse(snapshot.bytes.toString("utf8"));
  } catch (error) {
    fail(`cannot parse ${snapshot.path}: ${error.message}`);
  }
};
const sha256File = (path, label = "evidence file") =>
  authenticatedLocalInputSnapshot(path, label).sha256;
const assertRepoFileSnapshotUnchanged = (snapshot, label) => {
  const canonicalPath = repoEvidencePath(snapshot.path, label);
  if (canonicalPath !== snapshot.path)
    fail(`${label} canonical path changed after authentication`);
  try {
    assertAuthenticatedLocalFileUnchanged(snapshot, label);
  } catch (error) {
    fail(error.message);
  }
};
const phaseAIndexSnapshot = authenticatedLocalInputSnapshot(
  CANARY_PHASE_A_INDEX_PATH,
  "Phase-A evidence index",
);
const phaseBIndexSnapshot = authenticatedLocalInputSnapshot(
  CANARY_PHASE_B_INDEX_PATH,
  "Phase-B evidence index",
);
const manifestSourceSnapshot = authenticatedLocalInputSnapshot(
  MANIFEST_PATH,
  "release manifest source",
);
const parseSnapshotJson = (snapshot, label) => {
  try {
    return JSON.parse(snapshot.bytes.toString("utf8"));
  } catch (error) {
    fail(`cannot parse ${label}: ${error.message}`);
  }
};
const indexedPhaseBPair = (index, name) => {
  const raw = index?.actions?.[name]?.raw;
  if (!raw || typeof raw !== "object")
    fail(`phase B/${name} raw evidence metadata is missing`);
  const transactionPath = repoEvidencePath(
    raw.transactionPath,
    `phase B/${name} transaction`,
    { requireCanonicalRelative: true },
  );
  const receiptPath = repoEvidencePath(
    raw.receiptPath,
    `phase B/${name} receipt`,
    { requireCanonicalRelative: true },
  );
  for (const [path, expected, label] of [
    [transactionPath, raw.transactionSha256, `phase B/${name} transaction`],
    [receiptPath, raw.receiptSha256, `phase B/${name} receipt`],
  ]) {
    const reviewedSha = String(expected ?? "").toLowerCase();
    if (
      !/^[0-9a-f]{64}$/.test(reviewedSha) ||
      sha256File(path, label) !== reviewedSha
    ) {
      fail(`${label} SHA-256 differs from the Phase-B evidence index`);
    }
  }
  return {
    transactionPath,
    transaction: load(transactionPath, `phase B/${name} transaction`),
    receiptPath,
    receipt: load(receiptPath, `phase B/${name} receipt`),
  };
};

const deployRun = load(DEPLOY_PATH, "deployment artifact");
const canaryInstantLaunch = load(
  CANARY_INSTANT_LAUNCH_PATH,
  "Phase-A instant-launch artifact",
);
const canaryInstantBuyAuctionLaunch = load(
  CANARY_INSTANT_BUY_AUCTION_LAUNCH_PATH,
  "Phase-A instant-buy/auction-launch artifact",
);
const canaryOwnerBidTransaction = load(
  CANARY_OWNER_BID_TRANSACTION_PATH,
  "Phase-A owner-bid transaction",
);
const canaryOwnerBidReceipt = load(
  CANARY_OWNER_BID_RECEIPT_PATH,
  "Phase-A owner-bid receipt",
);
const canaryHookrLaunch = load(
  CANARY_HOOKR_LAUNCH_PATH,
  "Phase-A HOOKR-launch artifact",
);
const canaryHookrApproveBuy = load(
  CANARY_HOOKR_APPROVE_BUY_PATH,
  "Phase-A HOOKR-approve/buy artifact",
);
const canaryTimingShortenTransaction = load(
  CANARY_TIMING_SHORTEN_TRANSACTION_PATH,
  "Phase-A timing-shorten transaction",
);
const canaryTimingShortenReceipt = load(
  CANARY_TIMING_SHORTEN_RECEIPT_PATH,
  "Phase-A timing-shorten receipt",
);
const canaryTimingRestoreTransaction = load(
  CANARY_TIMING_RESTORE_TRANSACTION_PATH,
  "Phase-A timing-restore transaction",
);
const canaryTimingRestoreReceipt = load(
  CANARY_TIMING_RESTORE_RECEIPT_PATH,
  "Phase-A timing-restore receipt",
);
const canaryPhaseAIndex = parseSnapshotJson(
  phaseAIndexSnapshot,
  "Phase-A evidence index",
);
const canaryPhaseBIndex = parseSnapshotJson(
  phaseBIndexSnapshot,
  "Phase-B evidence index",
);
const canaryPhaseBRawPairs = Object.fromEntries(
  V5_PHASE_B_ACTIONS.map((name) => [
    name,
    indexedPhaseBPair(canaryPhaseBIndex, name),
  ]),
);
const runtimeArtifacts = Object.fromEntries(
  Object.entries(RUNTIME_ARTIFACTS).map(([key, target]) => [
    key,
    load(target.path, `${key} runtime artifact`),
  ]),
);

if (
  deployRun.chain !== 4663 ||
  canaryInstantLaunch.chain !== 4663 ||
  canaryInstantBuyAuctionLaunch.chain !== 4663 ||
  canaryHookrLaunch.chain !== 4663 ||
  canaryHookrApproveBuy.chain !== 4663
) {
  fail("artifact chain is not 4663");
}
if (String(canaryPhaseBIndex.chainId) !== "4663")
  fail("Phase-B evidence index chain is not 4663");

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
  const pairs = (run.transactions ?? []).map((tx, i) => {
    const hash = String(tx.hash ?? "").toLowerCase();
    const receipt = map.get(hash);
    if (!receipt)
      fail(
        `${label} tx #${i} (${hash}) has no matching receipt in the artifact`,
      );
    return { tx, receipt };
  });
  if (
    pairs.length !== map.size ||
    pairs.length !== (run.receipts ?? []).length
  ) {
    fail(
      `${label} transaction/receipt cardinality differs: ${pairs.length}/${(run.receipts ?? []).length}`,
    );
  }
  if (
    new Set(pairs.map(({ tx }) => String(tx.hash).toLowerCase())).size !==
    pairs.length
  ) {
    fail(`${label} contains duplicate transaction hashes`);
  }
  return pairs;
};

/* ------------------------------------------------------ receipt order + status */
const mainDeployPairs = pair(deployRun, "deploy");
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
  libraryEvidence = load(LIBRARY_EVIDENCE_PATH, "reused-library evidence");
  if (
    libraryEvidence.kind !== "reused-library-evidence-v1" ||
    libraryEvidence.chainId !== 4663
  ) {
    fail("library evidence kind or chain is not reviewed");
  }
  const sourceArtifactPath = String(libraryEvidence.sourceArtifact ?? "");
  if (!sourceArtifactPath) fail("library evidence has no source artifact path");
  if (
    sha256File(sourceArtifactPath, "reused-library source artifact") !==
    String(libraryEvidence.sourceArtifactSha256 ?? "").toLowerCase()
  ) {
    fail(
      "library source artifact SHA-256 differs from the reviewed provenance record",
    );
  }
  libraryRun = load(sourceArtifactPath, "reused-library source artifact");
  if (libraryRun.chain !== 4663)
    fail("library deploy artifact chain is not 4663");
  const shape = libraryEvidence.sourceArtifactShape ?? {};
  if (
    (libraryRun.transactions ?? []).length !== shape.transactions ||
    (libraryRun.receipts ?? []).length !== shape.receipts ||
    (libraryRun.pending ?? []).length !== shape.pending
  ) {
    fail(
      "library source artifact shape differs from the reviewed provenance record",
    );
  }
  const transactionIndex = Number(libraryEvidence.transactionIndex);
  const libraryTx = libraryRun.transactions?.[transactionIndex];
  if (
    !Number.isInteger(transactionIndex) ||
    !libraryTx ||
    libraryTx.transactionType !== "CREATE2" ||
    libraryTx.contractName !== "HookrLaunchpadLibV5"
  ) {
    fail(
      "library evidence does not select the reviewed HookrLaunchpadLibV5 CREATE2 record",
    );
  }
  if (!sameHex(libraryTx.hash, libraryEvidence.transactionHash)) {
    fail("library evidence transaction hash differs from the raw Forge record");
  }
  if (
    !sameHex(
      keccak256(libraryTx.transaction.input),
      libraryEvidence.calldataHash,
    )
  ) {
    fail("library evidence calldata hash differs from the raw Forge record");
  }
  if (
    getAddress(libraryTx.contractAddress) !==
    getAddress(libraryEvidence.address)
  ) {
    fail("library evidence address differs from the raw Forge record");
  }
  const pendingHashes = libraryRun.pending ?? [];
  if (
    new Set(pendingHashes.map((hash) => String(hash).toLowerCase())).size !==
    pendingHashes.length
  ) {
    fail("raw Forge artifact contains duplicate pending transaction hashes");
  }
  if (!pendingHashes.some((hash) => sameHex(hash, libraryTx.hash))) {
    fail(
      "raw Forge artifact does not mark the selected library transaction as pending recovery",
    );
  }
  const excludedPending = libraryEvidence.excludedPendingTransactions ?? [];
  if (
    !Array.isArray(excludedPending) ||
    excludedPending.length + 1 !== pendingHashes.length
  ) {
    fail(
      "library evidence must classify every raw pending transaction exactly once",
    );
  }
  const classifiedPending = new Set([String(libraryTx.hash).toLowerCase()]);
  for (const excluded of excludedPending) {
    const excludedHash = String(excluded.transactionHash ?? "").toLowerCase();
    if (!excludedHash || classifiedPending.has(excludedHash)) {
      fail(
        "library evidence repeats or excludes the selected library transaction",
      );
    }
    if (!pendingHashes.some((hash) => sameHex(hash, excludedHash))) {
      fail(
        `excluded pending transaction ${excluded.transactionHash} is absent from the raw artifact`,
      );
    }
    const rawExcluded = (libraryRun.transactions ?? []).find((tx) =>
      sameHex(tx.hash, excludedHash),
    );
    if (
      !rawExcluded ||
      getAddress(rawExcluded.contractAddress) !==
        getAddress(excluded.contractAddress)
    ) {
      fail(
        `excluded pending transaction ${excluded.transactionHash} has the wrong contract address`,
      );
    }
    if (typeof excluded.reason !== "string" || excluded.reason.trim() === "") {
      fail(
        `excluded pending transaction ${excluded.transactionHash} has no recorded reason`,
      );
    }
    classifiedPending.add(excludedHash);
  }
  if (
    !pendingHashes.every((hash) =>
      classifiedPending.has(String(hash).toLowerCase()),
    )
  ) {
    fail("library evidence leaves a raw pending transaction unclassified");
  }
  const libraryReceipt = libraryEvidence.receipt;
  if (
    !libraryReceipt ||
    libraryReceipt.status !== "0x1" ||
    !sameHex(libraryReceipt.transactionHash, libraryTx.hash)
  ) {
    fail(
      "library evidence receipt is missing, failed, or names a different transaction",
    );
  }
  deployPairs = [
    { tx: libraryTx, receipt: libraryReceipt },
    ...mainDeployPairs,
  ];
  reusedLibrary = true;
} else {
  fail(
    `deploy artifact must hold exactly 11 or 12 transactions/receipts, found ${mainDeployPairs.length}`,
  );
}
const canaryInstantLaunchPairs = pair(
  canaryInstantLaunch,
  "canary instant launch",
);
const canaryInstantBuyAuctionLaunchPairs = pair(
  canaryInstantBuyAuctionLaunch,
  "canary instant buy + auction launch",
);
const canaryHookrLaunchPairs = pair(canaryHookrLaunch, "canary HOOKR launch");
const canaryHookrApproveBuyPairs = pair(
  canaryHookrApproveBuy,
  "canary HOOKR approve + buy",
);
// Phase B carries six canonical action references. Permissionless references may point to the same
// helper transaction/receipt; assertV5PhaseBEvidence authenticates every action's exact events,
// identities, paths, and raw bytes while keeping the owner-only buyback direct.
const canaryPhaseBPairs = V5_PHASE_B_ACTIONS.map((name) => {
  const raw = canaryPhaseBRawPairs[name];
  return {
    tx: {
      hash: raw.transaction.hash,
      function: name,
      transaction: raw.transaction,
    },
    receipt: raw.receipt,
  };
});
const timingPair = (transaction, receipt, label) => {
  if (!sameHex(transaction?.hash, receipt?.transactionHash)) {
    fail(`${label} raw transaction/receipt hashes differ`);
  }
  return {
    tx: {
      hash: transaction.hash,
      function: "setAuctionTiming(uint64,uint64,uint64)",
      transaction,
    },
    receipt,
  };
};
const canaryTimingShortenPair = timingPair(
  canaryTimingShortenTransaction,
  canaryTimingShortenReceipt,
  "canary timing shorten",
);
const canaryTimingRestorePair = timingPair(
  canaryTimingRestoreTransaction,
  canaryTimingRestoreReceipt,
  "canary timing restore",
);
const canaryOwnerBidPair = {
  tx: {
    hash: canaryOwnerBidTransaction.hash,
    function: "submitBid(uint256,uint128,address,bytes)",
    transaction: canaryOwnerBidTransaction,
  },
  receipt: canaryOwnerBidReceipt,
};
if (
  !sameHex(
    canaryOwnerBidTransaction?.hash,
    canaryOwnerBidReceipt?.transactionHash,
  )
) {
  fail("canary owner-bid raw transaction/receipt hashes differ");
}
const dTx = deployPairs.map((p) => p.tx);
const dRc = deployPairs.map((p) => p.receipt);
const canaryRunPairs = [
  canaryInstantLaunchPairs[0],
  canaryTimingShortenPair,
  canaryInstantBuyAuctionLaunchPairs[0],
  canaryInstantBuyAuctionLaunchPairs[1],
  canaryTimingRestorePair,
  canaryOwnerBidPair,
  canaryHookrLaunchPairs[0],
  canaryHookrApproveBuyPairs[0],
  canaryHookrApproveBuyPairs[1],
];
const caTx = canaryRunPairs.map((p) => p.tx);
const caRc = canaryRunPairs.map((p) => p.receipt);
const cbTx = canaryPhaseBPairs.map((p) => p.tx);
const cbRc = canaryPhaseBPairs.map((p) => p.receipt);
if (dTx.length !== 12 || dRc.length !== 12)
  fail("combined deployment evidence must hold 12 transactions/receipts");
for (const [label, run, txs, expectedCount] of [
  [
    "canary instant launch",
    canaryInstantLaunch,
    canaryInstantLaunchPairs.map((pair) => pair.tx),
    1,
  ],
  [
    "canary instant buy + auction launch",
    canaryInstantBuyAuctionLaunch,
    canaryInstantBuyAuctionLaunchPairs.map((pair) => pair.tx),
    2,
  ],
  [
    "canary HOOKR launch",
    canaryHookrLaunch,
    canaryHookrLaunchPairs.map((pair) => pair.tx),
    1,
  ],
  [
    "canary HOOKR approve + buy",
    canaryHookrApproveBuy,
    canaryHookrApproveBuyPairs.map((pair) => pair.tx),
    2,
  ],
]) {
  if (
    txs.length !== expectedCount ||
    (run.receipts ?? []).length !== expectedCount ||
    !Array.isArray(run.pending) ||
    run.pending.length !== 0
  ) {
    fail(
      `${label} artifact must hold exactly ${expectedCount} transactions/receipts and no pending set, ` +
        `found ${txs.length}/${(run.receipts ?? []).length}/${run.pending?.length ?? "missing"}`,
    );
  }
}
/**
 * HookrLaunchpadV5 exceeds EIP-170 with its arithmetic and token factory inlined, so both live in
 * HookrLaunchpadLibV5 and are linked by DELEGATECALL. Forge deploys that library itself and
 * PREPENDS it to the broadcast, which is why the library is #0 and every index below is one later
 * than the script's own numbering. The flywheel burner is #1 (the hook takes it as a constructor
 * immutable, so it must exist before the hook), and both wiring calls follow the router: the
 * launchpad's setHook then the burner's setHook — twelve transactions in all.
 */
const expectDeploy = [
  { type: "CREATE2", name: "HookrLaunchpadLibV5" },
  { type: "CREATE", name: "HookrFlywheelBurner" },
  { type: "CREATE", name: "HookrLaunchpadV5" },
  { type: "CREATE2", name: "HookrHook" },
  { type: "CREATE", name: "HookrSwapRouter" },
  { fn: "setHook" }, // pad.setHook(hook)
  { fn: "setHook" }, // burner.setHook(hook)
  { fn: "saveBlueprint" },
  { fn: "saveBlueprint" },
  { fn: "saveBlueprint" },
  { fn: "saveBlueprint" },
  { fn: "saveBlueprint" },
];
expectDeploy.forEach((want, i) => {
  const tx = dTx[i];
  const rc = dRc[i];
  if (rc.status !== "0x1")
    fail(`deploy tx #${i} (${want.name ?? want.fn}) not successful`);
  if (getAddress(tx.transaction.from) !== EXPECTED_DEPLOYER)
    fail(`deploy tx #${i} not from the expected deployer`);
  if (want.type && tx.transactionType !== want.type) {
    fail(`deploy tx #${i} expected ${want.type}, found ${tx.transactionType}`);
  }
  if (want.name && tx.contractName !== want.name) {
    fail(
      `deploy tx #${i} expected contract ${want.name}, found ${tx.contractName}`,
    );
  }
  if (want.fn && !(tx.function ?? "").startsWith(want.fn)) {
    fail(`deploy tx #${i} expected ${want.fn}(), found ${tx.function}`);
  }
});
/* Phase A exercises every launch lane — the ETH instant round trip, the bonded auction with its
   clearing bid, and the HOOKR-quoted instant launch with its approved pair buy. Phase B settles
   the auction after its window and then runs the flywheel end to end (collect + buybackAndBurn).
   The bid, exit, and claim target the CCA the launchpad itself created — an address no artifact
   is trusted for. It is derived below from the live AuctionStarted event and only then
   cross-checked against what these artifacts claimed. */
const expectCanaryRun = [
  "launchInstant",
  "setAuctionTiming",
  "exactInput",
  "launchAuction",
  "setAuctionTiming",
  "submitBid",
  "launchInstant",
  "approve",
  "exactInput",
];
const expectCanarySettle = [
  "migrateAuction",
  "exitBid",
  "claimTokens",
  "claimAuctionProceeds",
  "collect",
  "buybackAndBurn",
];
if (cbTx.length !== 6 || cbRc.length !== 6) {
  fail("Phase-B evidence index must bind exactly six action references");
}
for (const [phase, txs, rcs, expected] of [
  ["canary run", caTx, caRc, expectCanaryRun],
  ["canary phase B", cbTx, cbRc, expectCanarySettle],
]) {
  expected.forEach((fn, i) => {
    const tx = txs[i];
    const rc = rcs[i];
    if (BigInt(rc.status) !== 1n)
      fail(`${phase} tx #${i} (${fn}) not successful`);
    // Phase-B settlement is permissionless except for the burner owner's buybackAndBurn call.
    // Preserve the owner binding for every Phase-A action and the final Phase-B transaction only.
    if (
      (phase === "canary run" || i === 5) &&
      getAddress(tx.transaction.from) !== EXPECTED_DEPLOYER
    ) {
      fail(`${phase} tx #${i} not from the expected deployer`);
    }
    if (!(tx.function ?? "").startsWith(fn))
      fail(`${phase} tx #${i} expected ${fn}(), found ${tx.function}`);
  });
}
if (
  !String(caTx[0].transaction.input ?? "")
    .toLowerCase()
    .startsWith(LAUNCH_INSTANT_SELECTOR)
) {
  fail("canary run tx #0 artifact calldata is not launchInstant()");
}
if (
  !String(caTx[3].transaction.input ?? "")
    .toLowerCase()
    .startsWith(LAUNCH_AUCTION_SELECTOR)
) {
  fail("canary run tx #3 artifact calldata is not launchAuction()");
}
if (
  !String(caTx[6].transaction.input ?? "")
    .toLowerCase()
    .startsWith(LAUNCH_INSTANT_SELECTOR)
) {
  fail("canary run tx #6 artifact calldata is not launchInstant()");
}

const launchpadLib = getAddress(dTx[0].contractAddress);
const burner = getAddress(dTx[1].contractAddress);
const launchpad = getAddress(dTx[2].contractAddress);
const hook = getAddress(dTx[3].contractAddress);
const router = getAddress(dTx[4].contractAddress);
if ((BigInt(hook) & 0x3fffn) !== HOOK_FLAGS)
  fail("hook address does not carry the 0x28cc flag bits");

// The canary must have exercised exactly this deployment (and, for the pair legs, exactly the
// pinned HOOKR token and the burner this broadcast deployed).
if (getAddress(caTx[0].transaction.to) !== launchpad)
  fail("canary instant launch did not target the deployed launchpad");
if (getAddress(caTx[1].transaction.to) !== launchpad)
  fail("canary timing shorten did not target the deployed launchpad");
if (getAddress(caTx[2].transaction.to) !== router)
  fail("canary buy did not go through the deployed router");
if (getAddress(caTx[3].transaction.to) !== launchpad)
  fail("canary auction launch did not target the deployed launchpad");
if (getAddress(caTx[4].transaction.to) !== launchpad)
  fail("canary timing restore did not target the deployed launchpad");
if (getAddress(caTx[6].transaction.to) !== launchpad)
  fail("canary hookr launch did not target the deployed launchpad");
if (getAddress(caTx[7].transaction.to) !== HOOKR_TOKEN)
  fail("canary hookr approve did not target the HOOKR token");
if (getAddress(caTx[8].transaction.to) !== router)
  fail("canary hookr buy did not go through the deployed router");
if (getAddress(cbTx[5].transaction.to) !== burner)
  fail("canary flywheel burn did not target the deployed burner");

const receipts = {
  launchpadLib: dRc[0].transactionHash,
  burner: dRc[1].transactionHash,
  launchpad: dRc[2].transactionHash,
  hook: dRc[3].transactionHash,
  router: dRc[4].transactionHash,
  setHook: dRc[5].transactionHash,
  burnerSetHook: dRc[6].transactionHash,
  blueprints: dRc.slice(7, 12).map((r) => r.transactionHash),
  canary: {
    instantLaunch: caRc[0].transactionHash,
    auctionTimingShorten: caRc[1].transactionHash,
    instantRouterBuy: caRc[2].transactionHash,
    auctionLaunch: caRc[3].transactionHash,
    auctionTimingRestore: caRc[4].transactionHash,
    auctionBid: caRc[5].transactionHash,
    hookrLaunch: caRc[6].transactionHash,
    hookrApprove: caRc[7].transactionHash,
    hookrBuy: caRc[8].transactionHash,
    auctionMigrate: cbRc[0].transactionHash,
    auctionExit: cbRc[1].transactionHash,
    auctionClaim: cbRc[2].transactionHash,
    auctionProceedsClaim: cbRc[3].transactionHash,
    flywheelCollect: cbRc[4].transactionHash,
    flywheelBurn: cbRc[5].transactionHash,
  },
};
// A permissionless helper may combine any of the first five Phase-B transitions. In that case the
// five action names alias one raw canonical transaction/receipt; every other collision (deploy,
// Phase A, or the owner-only buyback) remains forbidden. Equal hashes are insufficient by
// themselves: the complete persisted transaction and receipt objects must also be identical.
const receiptInventory = [
  ...deployPairs.map((pair_, index) => ({
    label: `deploy#${index}`,
    pair: pair_,
    aliasable: false,
  })),
  ...canaryRunPairs.map((pair_, index) => ({
    label: `phase-a#${index}`,
    pair: pair_,
    aliasable: false,
  })),
  ...canaryPhaseBPairs.map((pair_, index) => ({
    label: `phase-b/${V5_PHASE_B_ACTIONS[index]}`,
    pair: pair_,
    aliasable: index < V5_PHASE_B_ACTIONS.length - 1,
  })),
];
const receiptInventoryByHash = new Map();
for (const entry of receiptInventory) {
  const hash = String(entry.pair.receipt.transactionHash ?? "").toLowerCase();
  const prior = receiptInventoryByHash.get(hash);
  if (!prior) {
    receiptInventoryByHash.set(hash, entry);
    continue;
  }
  if (!prior.aliasable || !entry.aliasable) {
    fail(`receipt hash ${hash} collides outside permissionless Phase B`);
  }
  try {
    assert.deepStrictEqual(
      entry.pair.tx.transaction,
      prior.pair.tx.transaction,
      "permissionless Phase-B aliases have different raw transactions",
    );
    assert.deepStrictEqual(
      entry.pair.receipt,
      prior.pair.receipt,
      "permissionless Phase-B aliases have different canonical receipts",
    );
  } catch (error) {
    fail(error.message);
  }
}

/* ----------------------------------------------------------- source commit
   The manifest must name the commit whose contracts were actually broadcast, which Forge
   records in the deployment artifact. The original and recovery Forge artifacts may name two clean,
   ordered descendant operator commits only when every deployed contract/source input is byte-for-byte
   unchanged. All three commits are persisted, and later HEADs must retain the recovery canary script. */
const git = (...argv) => execFileSync("git", argv, { encoding: "utf8" }).trim();
const repositoryHeadSnapshot = git("rev-parse", "HEAD");
const repositoryStatusSnapshot = git(
  "status",
  "--porcelain=v1",
  "--untracked-files=all",
);
if (!DRY_RUN && repositoryStatusSnapshot !== "") {
  fail("repository was not clean when promotion authentication began");
}
const assertPromotionWorkspaceUnchanged = () => {
  for (const snapshot of authenticatedLocalInputSnapshots.values()) {
    assertRepoFileSnapshotUnchanged(
      snapshot,
      [...snapshot.labels].sort().join(" / "),
    );
  }
  if (git("rev-parse", "HEAD") !== repositoryHeadSnapshot) {
    fail("repository HEAD changed after promotion authentication began");
  }
  if (
    git("status", "--porcelain=v1", "--untracked-files=all") !==
    repositoryStatusSnapshot
  ) {
    fail("repository worktree changed after promotion authentication began");
  }
};
const artifactCommit = String(deployRun.commit ?? "").trim();
if (!artifactCommit)
  fail(
    "deploy artifact carries no commit field; cannot attribute the bytecode",
  );
let sourceCommit;
try {
  sourceCommit = git("rev-parse", artifactCommit);
} catch {
  fail(`artifact commit ${artifactCommit} is not in this repository`);
}
let librarySourceCommit = sourceCommit;
if (reusedLibrary) {
  const libraryArtifactCommit = String(libraryRun?.commit ?? "").trim();
  if (!libraryArtifactCommit)
    fail("library deploy artifact carries no commit field");
  try {
    librarySourceCommit = git("rev-parse", libraryArtifactCommit);
    if (librarySourceCommit !== String(libraryEvidence.sourceCommit ?? "")) {
      fail(
        "library evidence source commit differs from its raw Forge artifact",
      );
    }
    git("merge-base", "--is-ancestor", librarySourceCommit, sourceCommit);
  } catch {
    fail(
      `library artifact commit ${libraryArtifactCommit} is not an ancestor of the deployed commit`,
    );
  }
}
const resolveArtifactCommit = (label, run) => {
  const commit = String(run.commit ?? "").trim();
  if (!commit)
    fail(
      `${label} artifact carries no commit field; cannot attribute the canary`,
    );
  try {
    return git("rev-parse", commit);
  } catch {
    fail(`${label} artifact commit ${commit} is not in this repository`);
  }
};
const sharedArtifactCommit = (label, entries) => {
  const resolved = entries.map(([artifactLabel, run]) =>
    resolveArtifactCommit(artifactLabel, run),
  );
  if (new Set(resolved).size !== 1) {
    fail(
      `${label} artifacts were broadcast from different operator commits (${resolved.map((commit) => commit.slice(0, 12)).join(", ")})`,
    );
  }
  return resolved[0];
};
const canaryOperatorCommit = sharedArtifactCommit("original canary", [
  ["canary instant launch", canaryInstantLaunch],
  ["canary instant buy + auction launch", canaryInstantBuyAuctionLaunch],
]);
const canaryRecoveryCommit = sharedArtifactCommit("canary recovery", [
  ["canary HOOKR launch", canaryHookrLaunch],
  ["canary HOOKR approve + buy", canaryHookrApproveBuy],
]);
try {
  git("merge-base", "--is-ancestor", sourceCommit, canaryOperatorCommit);
} catch {
  fail(
    `deployment source ${sourceCommit.slice(0, 12)} is not an ancestor of canary operator ${canaryOperatorCommit.slice(0, 12)}`,
  );
}
if (sourceCommit === canaryOperatorCommit) {
  fail(
    "canary operator must be a descendant commit carrying the reviewed ArbSys shim",
  );
}
if (canaryOperatorCommit === canaryRecoveryCommit) {
  fail("canary recovery commit must be a distinct reviewed descendant");
}
try {
  git(
    "merge-base",
    "--is-ancestor",
    canaryOperatorCommit,
    canaryRecoveryCommit,
  );
} catch {
  fail(
    `original canary operator ${canaryOperatorCommit.slice(0, 12)} is not an ancestor of recovery ${canaryRecoveryCommit.slice(0, 12)}`,
  );
}
const canaryScriptLineageDiff = git(
  "diff",
  "--name-only",
  sourceCommit,
  canaryOperatorCommit,
  "--",
  "contracts/script/CanaryRobinhoodV5.s.sol",
);
if (canaryScriptLineageDiff !== "contracts/script/CanaryRobinhoodV5.s.sol") {
  fail(
    "canary operator does not carry the reviewed CanaryRobinhoodV5 source update",
  );
}
const canaryDeployedSourceDiff = git(
  "diff",
  "--name-only",
  sourceCommit,
  canaryOperatorCommit,
  "--",
  "contracts/src",
  "contracts/lib",
  "contracts/foundry.toml",
  "contracts/script/DeployRobinhoodV5.s.sol",
);
if (canaryDeployedSourceDiff !== "") {
  fail(
    `deployed contract/source inputs changed in canary operator ${canaryOperatorCommit.slice(0, 12)} (${canaryDeployedSourceDiff.split("\n").join(", ")})`,
  );
}
const recoveryDeployedSourceDiff = git(
  "diff",
  "--name-only",
  sourceCommit,
  canaryRecoveryCommit,
  "--",
  "contracts/src",
  "contracts/lib",
  "contracts/foundry.toml",
  "contracts/script/DeployRobinhoodV5.s.sol",
);
if (recoveryDeployedSourceDiff !== "") {
  fail(
    `deployed contract/source inputs changed in canary recovery ${canaryRecoveryCommit.slice(0, 12)} (${recoveryDeployedSourceDiff.split("\n").join(", ")})`,
  );
}
try {
  assertV5PhaseAIndex(canaryPhaseAIndex, {
    instantLaunchRun: canaryInstantLaunch,
    instantLaunchPath: CANARY_INSTANT_LAUNCH_PATH,
    instantBuyAuctionLaunchRun: canaryInstantBuyAuctionLaunch,
    instantBuyAuctionLaunchPath: CANARY_INSTANT_BUY_AUCTION_LAUNCH_PATH,
    ownerBidTransaction: canaryOwnerBidTransaction,
    ownerBidTransactionPath: CANARY_OWNER_BID_TRANSACTION_PATH,
    ownerBidReceipt: canaryOwnerBidReceipt,
    ownerBidReceiptPath: CANARY_OWNER_BID_RECEIPT_PATH,
    hookrLaunchRun: canaryHookrLaunch,
    hookrLaunchPath: CANARY_HOOKR_LAUNCH_PATH,
    hookrApproveBuyRun: canaryHookrApproveBuy,
    hookrApproveBuyPath: CANARY_HOOKR_APPROVE_BUY_PATH,
    shortenTransaction: canaryTimingShortenTransaction,
    shortenTransactionPath: CANARY_TIMING_SHORTEN_TRANSACTION_PATH,
    shortenReceipt: canaryTimingShortenReceipt,
    shortenReceiptPath: CANARY_TIMING_SHORTEN_RECEIPT_PATH,
    restoreTransaction: canaryTimingRestoreTransaction,
    restoreTransactionPath: CANARY_TIMING_RESTORE_TRANSACTION_PATH,
    restoreReceipt: canaryTimingRestoreReceipt,
    restoreReceiptPath: CANARY_TIMING_RESTORE_RECEIPT_PATH,
    deploymentSourceCommit: sourceCommit,
    originalCanaryOperatorCommit: canaryOperatorCommit,
    canaryRecoveryCommit,
    sender: EXPECTED_DEPLOYER,
    launchpad,
    router,
    hookrToken: HOOKR_TOKEN,
    hook,
    instantToken: canaryPhaseAIndex?.identities?.instantToken,
    auctionToken: canaryPhaseAIndex?.identities?.auctionToken,
    auction: canaryPhaseAIndex?.identities?.auction,
    bidId: canaryPhaseAIndex?.identities?.bidId,
    hookrPairToken: canaryPhaseAIndex?.identities?.hookrPairToken,
  });
} catch (error) {
  fail(`phase A evidence index: ${error.message}`);
}
const phaseAAccrual = canaryPhaseAIndex?.identities?.instantFlywheelAccrual;
try {
  assert.deepStrictEqual(
    canaryPhaseBIndex?.identities?.phaseAAccrual,
    phaseAAccrual,
    "Phase-B accrual identity differs from the authenticated Phase-A receipt-local event",
  );
} catch (error) {
  fail(error.message);
}
const canonicalAuctionPoolId = poolIdForKey({
  currency0: ZERO_ADDRESS,
  currency1: getAddress(canaryPhaseAIndex.identities.auctionToken),
  fee: V5_CANARY_SPEC.dynamicFee,
  tickSpacing: V5_CANARY_SPEC.tickSpacing,
  hooks: hook,
});
if (!sameHex(canaryPhaseBIndex?.identities?.poolId, canonicalAuctionPoolId)) {
  fail(
    "Phase-B pool id is not the canonical ETH/auction-token/release-hook pool",
  );
}
let authenticatedPhaseBIndex;
try {
  authenticatedPhaseBIndex = assertV5PhaseBEvidence(canaryPhaseBIndex, {
    pairs: canaryPhaseBRawPairs,
    sourceCommit: canaryRecoveryCommit,
    token: canaryPhaseAIndex.identities.auctionToken,
    auction: canaryPhaseAIndex.identities.auction,
    bidId: canaryPhaseAIndex.identities.bidId,
    launchpad,
    burner,
    owner: EXPECTED_DEPLOYER,
    poolManager: POOL_MANAGER,
    poolId: canonicalAuctionPoolId,
    hook,
    hookrToken: HOOKR_TOKEN,
    phaseAAccrual,
  });
} catch (error) {
  fail(`phase B evidence index: ${error.message}`);
}
const headCommit = repositoryHeadSnapshot;
try {
  git("merge-base", "--is-ancestor", canaryRecoveryCommit, headCommit);
} catch {
  fail(
    `canary recovery ${canaryRecoveryCommit.slice(0, 12)} is not an ancestor of current HEAD ${headCommit.slice(0, 12)}`,
  );
}
const canaryScriptDiff = git(
  "diff",
  "--name-only",
  canaryRecoveryCommit,
  headCommit,
  "--",
  "contracts/script/CanaryRobinhoodV5.s.sol",
);
if (canaryScriptDiff !== "") {
  fail(
    `canary script changed after recovery commit (${canaryScriptDiff.split("\n").join(", ")})`,
  );
}
const contractsDirty = git(
  "status",
  "--porcelain",
  "--",
  "contracts/src",
  "contracts/script",
  "contracts/lib",
  "contracts/foundry.toml",
  "contracts/run-canary-v5.sh",
  "scripts/build-v5-phase-a-index.mjs",
  "scripts/collect-v5-phase-b-evidence.mjs",
  "scripts/build-v5-phase-b-evidence.mjs",
  "scripts/redact-rpc-stream.mjs",
  "contracts/release-evidence/v5/reused-launchpad-library.json",
  "contracts/broadcast/DeployRobinhoodV5.s.sol/4663/run-1787263839227.json",
  "scripts/promote-release-manifest.mjs",
  "scripts/verify-deployment-preflight.mjs",
  "scripts/lib/instant-canary-evidence.mjs",
  "scripts/lib/release-promotion-evidence.mjs",
  "scripts/lib/release-manifest-patch.mjs",
  "scripts/lib/runtime-template-evidence.mjs",
  "scripts/lib/v5-canary-evidence.mjs",
  "src/lib/release-manifest.ts",
);
if (contractsDirty !== "" && !DRY_RUN) {
  fail(
    "contract sources, scripts, dependencies, or compiler settings are dirty; deployed bytecode cannot be attributed",
  );
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
  "contracts/script/DeployRobinhoodV5.s.sol",
);
if (contractsDiff !== "" && !DRY_RUN) {
  fail(
    `contract source inputs changed since the deployed commit (${contractsDiff.split("\n").join(", ")}); redeploy or promote from that commit`,
  );
}
for (const [key, target] of Object.entries(RUNTIME_ARTIFACTS)) {
  try {
    assertArtifactSourceHashes(
      runtimeArtifacts[key],
      (sourcePath) =>
        authenticatedLocalInputSnapshot(
          `contracts/${sourcePath}`,
          `${target.contractName} source`,
        ).bytes,
      target.contractName,
    );
  } catch (error) {
    fail(
      `reviewed runtime artifact: ${error.message}; rebuild contracts/out from the attributed source`,
    );
  }
}
authenticatedLocalInputRegistrySealed = true;

/* --------------------------------------- finalized receipts + pinned state readback */
const client = createPublicClient({ transport: http(RPC) });
const abi = parseAbi([
  "function contractName() view returns (string)",
  "function contractVersion() view returns (string)",
  "function hook() view returns (address)",
  "function launchpad() view returns (address)",
  "function poolManager() view returns (address)",
  "function auctionFactory() view returns (address)",
  "function owner() view returns (address)",
  "function blueprintsCount() view returns (uint256)",
  "function creationFeeWei() view returns (uint96)",
  "function flywheelRecipient() view returns (address)",
  "function quoteToken() view returns (address)",
  "function hookrToken() view returns (address)",
  "function maxBuybackWei() view returns (uint96)",
  "function hookrInstantOpenFdv() view returns (uint96)",
  "function auctionDurationBlocks() view returns (uint64)",
  "function claimDelayBlocks() view returns (uint64)",
  "function migrationDelayBlocks() view returns (uint64)",
  "function poolFee() view returns (uint24)",
  "function poolTickSpacing() view returns (int24)",
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
if (
  !finalizedHead?.hash ||
  finalizedHead.number === null ||
  finalizedHead.number === undefined
) {
  fail(
    `${receiptEvidenceTag} receipt evidence block is missing its number or hash`,
  );
}
const finalizedCanonical = await client.getBlock({
  blockNumber: finalizedHead.number,
});
if (!sameHex(finalizedCanonical.hash, finalizedHead.hash)) {
  fail(
    `${receiptEvidenceTag} receipt evidence head is not canonical at its block number`,
  );
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

/* One label per receipt, canary labels exactly as V5_CANARY_SPEC declares them — they are the
   contract between this wiring and the pure evidence validator. */
const RECEIPT_LABELS = [
  ["launchpadLib", receipts.launchpadLib],
  ["burner", receipts.burner],
  ["launchpad", receipts.launchpad],
  ["hook", receipts.hook],
  ["router", receipts.router],
  ["setHook", receipts.setHook],
  ["burnerSetHook", receipts.burnerSetHook],
  ...receipts.blueprints.map((hash, index) => [`blueprint#${index + 1}`, hash]),
  [V5_CANARY_SPEC.phaseAReceiptLabels[0], receipts.canary.instantLaunch],
  [V5_CANARY_SPEC.phaseAReceiptLabels[1], receipts.canary.auctionTimingShorten],
  [V5_CANARY_SPEC.phaseAReceiptLabels[2], receipts.canary.instantRouterBuy],
  [V5_CANARY_SPEC.phaseAReceiptLabels[3], receipts.canary.auctionLaunch],
  [V5_CANARY_SPEC.phaseAReceiptLabels[4], receipts.canary.auctionTimingRestore],
  [V5_CANARY_SPEC.phaseAReceiptLabels[5], receipts.canary.auctionBid],
  [V5_CANARY_SPEC.phaseAReceiptLabels[6], receipts.canary.hookrLaunch],
  [V5_CANARY_SPEC.phaseAReceiptLabels[7], receipts.canary.hookrApprove],
  [V5_CANARY_SPEC.phaseAReceiptLabels[8], receipts.canary.hookrBuy],
  [V5_CANARY_SPEC.phaseBReceiptLabels[0], receipts.canary.auctionMigrate],
  [V5_CANARY_SPEC.phaseBReceiptLabels[1], receipts.canary.auctionExit],
  [V5_CANARY_SPEC.phaseBReceiptLabels[2], receipts.canary.auctionClaim],
  [V5_CANARY_SPEC.phaseBReceiptLabels[3], receipts.canary.auctionProceedsClaim],
  [V5_CANARY_SPEC.phaseBReceiptLabels[4], receipts.canary.flywheelCollect],
  [V5_CANARY_SPEC.phaseBReceiptLabels[5], receipts.canary.flywheelBurn],
];
const [
  CANARY_INSTANT_LAUNCH,
  CANARY_TIMING_SHORTEN,
  CANARY_INSTANT_BUY,
  CANARY_AUCTION_LAUNCH,
  CANARY_TIMING_RESTORE,
  CANARY_AUCTION_BID,
  CANARY_HOOKR_LAUNCH,
  CANARY_HOOKR_APPROVE,
  CANARY_HOOKR_BUY,
] = V5_CANARY_SPEC.phaseAReceiptLabels;
const [
  CANARY_AUCTION_MIGRATE,
  CANARY_AUCTION_EXIT,
  CANARY_AUCTION_CLAIM,
  CANARY_AUCTION_PROCEEDS,
  CANARY_FLYWHEEL_COLLECT,
  CANARY_FLYWHEEL_BURN,
] = V5_CANARY_SPEC.phaseBReceiptLabels;
const CANARY_RAW_PAIR_BY_LABEL = new Map([
  ...V5_CANARY_SPEC.phaseAReceiptLabels.map((label, index) => [
    label,
    canaryRunPairs[index],
  ]),
  ...V5_CANARY_SPEC.phaseBReceiptLabels.map((label, index) => [
    label,
    canaryPhaseBPairs[index],
  ]),
]);
if (CANARY_RAW_PAIR_BY_LABEL.size !== 15)
  fail("raw canary artifact labels are incomplete or duplicated");

// Fail before expensive runtime/state comparisons when any claimed receipt is newer than the
// finalized evidence head. Full status, canonical-header, calldata, and postcondition checks still
// run below; this first pass establishes that the release evidence is old enough to be final.
const finalizedReceiptRecords = await Promise.all(
  RECEIPT_LABELS.map(async ([label, hash]) => {
    try {
      const receipt = await client.getTransactionReceipt({ hash });
      return { label, blockNumber: receipt.blockNumber };
    } catch {
      fail(
        `${label} receipt ${hash} is not on the chain this RPC serves (fork artifact?)`,
      );
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
      fail(
        `${label} receipt block hash disagrees with the cached block header`,
      );
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
    header.hash.toLowerCase() !== receipt.blockHash.toLowerCase() ||
    typeof header.timestamp !== "string" ||
    !/^0x[0-9a-fA-F]+$/.test(header.timestamp)
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
  if (contractBlockNumber <= 0n)
    fail(`${label} receipt block l1BlockNumber is zero`);
  contractBlockCache.set(key, {
    hash: header.hash,
    contractBlockNumber,
    blockTimestamp: BigInt(header.timestamp),
  });
  return contractBlockNumber;
};

const runtime = async (address) => {
  const code = await client.getCode({ address, ...at });
  if (!code || code === "0x") fail(`no runtime code at ${address}`);
  return code;
};
const codehash = async (address) => keccak256(await runtime(address));
const read = (address, functionName) =>
  client.readContract({ address, abi, functionName, ...at });

const [
  padCode,
  hookCode,
  routerCode,
  launchpadLibCode,
  pmHash,
  auctionFactoryHash,
  create2DeployerHash,
  burnerCode,
  hookrTokenCode,
] = await Promise.all([
  runtime(launchpad),
  runtime(hook),
  runtime(router),
  runtime(launchpadLib),
  codehash(POOL_MANAGER),
  codehash(AUCTION_FACTORY),
  codehash(CREATE2_DEPLOYER),
  runtime(burner),
  runtime(HOOKR_TOKEN),
]);
if (!burnerCode || !hookrTokenCode)
  fail("burner or HOOKR token runtime missing at the pinned block");
const padHash = keccak256(padCode);
const hookHash = keccak256(hookCode);
const routerHash = keccak256(routerCode);
const burnerHash = keccak256(burnerCode);
const hookrTokenHash = keccak256(hookrTokenCode);
if (pmHash !== POOL_MANAGER_CODEHASH)
  fail("PoolManager runtime codehash changed");
if (auctionFactoryHash !== AUCTION_FACTORY_CODEHASH) {
  fail("CCA auction factory runtime codehash changed");
}
if (hookrTokenHash !== HOOKR_TOKEN_CODEHASH)
  fail("HOOKR token runtime codehash changed");
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
      expectedImmutableAddresses: [POOL_MANAGER, AUCTION_FACTORY, HOOKR_TOKEN],
      // The eleven scalar constructor immutables (fixed ETH + HOOKR instant open geometry and
      // the ArbSys clock flag), pinned as exact runtime words — see LAUNCHPAD_IMMUTABLE_WORDS
      // and V5ImmutableReadout.t.sol.
      expectedImmutableWords: [...LAUNCHPAD_IMMUTABLE_WORDS],
      expectedLinks: {
        "src/libraries/HookrLaunchpadLibV5.sol:HookrLaunchpadLibV5":
          launchpadLib,
      },
      expectedNormalizedTemplateHash:
        REVIEWED_NORMALIZED_RUNTIME_HASHES.launchpadV5,
      expectedReferenceLayoutHash:
        REVIEWED_RUNTIME_REFERENCE_LAYOUT_HASHES.launchpadV5,
    }),
    hook: validateReviewedRuntime({
      artifact: runtimeArtifacts.hook,
      liveCode: hookCode,
      expectedTarget: RUNTIME_ARTIFACTS.hook,
      // The hook's constructor is (pm, launchpad, burner) — the flywheel recipient is immutable.
      expectedImmutableAddresses: [POOL_MANAGER, launchpad, burner],
      expectedNormalizedTemplateHash: REVIEWED_NORMALIZED_RUNTIME_HASHES.hookV5,
      expectedReferenceLayoutHash:
        REVIEWED_RUNTIME_REFERENCE_LAYOUT_HASHES.hookV5,
    }),
    router: validateReviewedRuntime({
      artifact: runtimeArtifacts.router,
      liveCode: routerCode,
      expectedTarget: RUNTIME_ARTIFACTS.router,
      // The router's constructor is (pm, hook, HOOKR) — HOOKR is its one accepted ERC-20 quote.
      expectedImmutableAddresses: [POOL_MANAGER, hook, HOOKR_TOKEN],
      expectedNormalizedTemplateHash:
        REVIEWED_NORMALIZED_RUNTIME_HASHES.routerV5,
      expectedReferenceLayoutHash:
        REVIEWED_RUNTIME_REFERENCE_LAYOUT_HASHES.routerV5,
    }),
    burner: validateReviewedRuntime({
      artifact: runtimeArtifacts.burner,
      liveCode: burnerCode,
      expectedTarget: RUNTIME_ARTIFACTS.burner,
      expectedImmutableAddresses: [POOL_MANAGER, HOOKR_TOKEN],
      expectedImmutableWords: [...BURNER_IMMUTABLE_WORDS],
      expectedNormalizedTemplateHash:
        REVIEWED_NORMALIZED_RUNTIME_HASHES.burnerV5,
      expectedReferenceLayoutHash:
        REVIEWED_RUNTIME_REFERENCE_LAYOUT_HASHES.burnerV5,
    }),
    launchpadLib: validateReviewedRuntime({
      artifact: runtimeArtifacts.launchpadLib,
      liveCode: launchpadLibCode,
      expectedTarget: RUNTIME_ARTIFACTS.launchpadLib,
      expectedImmutableAddresses: [launchpadLib],
      expectedNormalizedTemplateHash:
        REVIEWED_NORMALIZED_RUNTIME_HASHES.launchpadLibV5,
      expectedReferenceLayoutHash:
        REVIEWED_RUNTIME_REFERENCE_LAYOUT_HASHES.launchpadLibV5,
    }),
  };
} catch (error) {
  fail(`reviewed runtime comparison: ${error.message}`);
}
if (
  runtimeProofs.launchpad.runtimeCodeHash !== padHash ||
  runtimeProofs.hook.runtimeCodeHash !== hookHash ||
  runtimeProofs.router.runtimeCodeHash !== routerHash ||
  runtimeProofs.burner.runtimeCodeHash !== burnerHash
) {
  fail("reviewed runtime proof hashes disagree with manifest runtime hashes");
}

/* The launchpad DELEGATECALLs its arithmetic and its token factory into HookrLaunchpadLibV5, whose
   address solc bakes into the launchpad's runtime at every call site. Prove on chain that the
   deployed launchpad is linked to the library this same broadcast deployed — otherwise a launchpad
   linked against some other (or non-existent) address would promote as if it were wired correctly,
   and every launch would revert. `contracts.launchpad.runtimeCodeHash` in the manifest then pins
   that linkage transitively, which is why the library needs no manifest field of its own. */
const linkNeedle = launchpadLib.slice(2).toLowerCase();
const linkCount = padCode.toLowerCase().split(linkNeedle).length - 1;
if (linkCount === 0) {
  fail(
    `deployed launchpad does not reference HookrLaunchpadLibV5 at ${launchpadLib}; it is linked elsewhere`,
  );
}

/* What each receipt must have created or targeted, checked against the chain rather than against
   the artifact that named it.

   The two deployment mechanics differ on chain and must be checked differently. A plain `new X()`
   is a CREATE from the EOA: `to` is null and the receipt carries `contractAddress`. A salted
   `new X{salt:}()` is a CREATE2 routed through the canonical deployer, so the receipt's `to` is
   0x4e59… and `contractAddress` is NULL. The canonical proxy's live calldata is `salt || initCode`,
   so promotion derives CREATE2(factory, salt, keccak256(initCode)) and requires it to equal the
   claimed library/hook address in addition to checking the factory target and runtime.

   The bid, exit, and claim are resolved after the auction-launch receipt: their target must be the
   CCA indexed by that launchpad's `AuctionStarted` event, not an address trusted from either
   canary artifact. */
const ONCHAIN_TARGET = {
  launchpadLib: ["calls", CREATE2_DEPLOYER],
  burner: ["creates", burner],
  launchpad: ["creates", launchpad],
  hook: ["calls", CREATE2_DEPLOYER],
  router: ["creates", router],
  setHook: ["calls", launchpad],
  burnerSetHook: ["calls", burner],
  [CANARY_INSTANT_LAUNCH]: ["calls", launchpad],
  [CANARY_TIMING_SHORTEN]: ["calls", launchpad],
  [CANARY_INSTANT_BUY]: ["calls", router],
  [CANARY_AUCTION_LAUNCH]: ["calls", launchpad],
  [CANARY_TIMING_RESTORE]: ["calls", launchpad],
  [CANARY_HOOKR_LAUNCH]: ["calls", launchpad],
  [CANARY_HOOKR_APPROVE]: ["calls", HOOKR_TOKEN],
  [CANARY_HOOKR_BUY]: ["calls", router],
  [CANARY_FLYWHEEL_BURN]: ["calls", burner],
  ...Object.fromEntries(
    receipts.blueprints.map((_, i) => [
      `blueprint#${i + 1}`,
      ["calls", launchpad],
    ]),
  ),
};
const AUCTION_TARGET_LABELS = new Set([CANARY_AUCTION_BID]);
const PERMISSIONLESS_PHASE_B_LABELS = new Set([
  CANARY_AUCTION_MIGRATE,
  CANARY_AUCTION_EXIT,
  CANARY_AUCTION_CLAIM,
  CANARY_AUCTION_PROCEEDS,
  CANARY_FLYWHEEL_COLLECT,
]);
const compareReceiptCoordinates = (left, right) => {
  if (left.blockNumber !== right.blockNumber)
    return left.blockNumber < right.blockNumber ? -1 : 1;
  if (left.transactionIndex === right.transactionIndex) return 0;
  return left.transactionIndex < right.transactionIndex ? -1 : 1;
};
const assertAliasedCanonicalReceiptOrder = (records, recordsByLabel) => {
  const byHash = new Map();
  const labels = new Set();
  for (let index = 0; index < records.length; index += 1) {
    const record = records[index];
    if (labels.has(record.label))
      fail(`receipt order repeats label ${record.label}`);
    labels.add(record.label);
    const hash = String(record.hash).toLowerCase();
    const prior = byHash.get(hash);
    if (prior) {
      if (
        !PERMISSIONLESS_PHASE_B_LABELS.has(prior.label) ||
        !PERMISSIONLESS_PHASE_B_LABELS.has(record.label)
      ) {
        fail(
          `receipt hash ${record.hash} collides outside permissionless Phase B`,
        );
      }
      if (compareReceiptCoordinates(prior, record) !== 0) {
        fail(
          `permissionless Phase-B aliases for ${record.hash} have different canonical coordinates`,
        );
      }
      try {
        assert.deepStrictEqual(
          recordsByLabel.get(record.label)?.transaction,
          recordsByLabel.get(prior.label)?.transaction,
          "permissionless Phase-B aliases resolve to different live transactions",
        );
        assert.deepStrictEqual(
          recordsByLabel.get(record.label)?.receipt,
          recordsByLabel.get(prior.label)?.receipt,
          "permissionless Phase-B aliases resolve to different canonical receipts",
        );
      } catch (error) {
        fail(error.message);
      }
    } else {
      byHash.set(hash, record);
    }
    if (index === 0) continue;
    const previous = records[index - 1];
    const order = compareReceiptCoordinates(previous, record);
    if (order > 0) fail(`${record.label} was mined before ${previous.label}`);
    if (order === 0 && !sameHex(previous.hash, record.hash)) {
      fail(
        `${record.label} shares canonical coordinates with a different transaction`,
      );
    }
  }
};
let canaryInstantToken;
let canaryInstantPoolId;
let canaryAuctionToken;
let canaryAuction;
let canaryAuctionEndBlock;
let canaryBidId;
let canaryHookrToken;
let canaryHookrPoolId;
const onchainReceiptOrder = [];
const onchainTransactions = new Map();

const indexedTopicAddress = (log, topicIndex, label) => {
  const topic = log.topics[topicIndex];
  if (!topic || topic.length !== 66)
    fail(`${label} has a malformed indexed address topic`);
  return getAddress(`0x${topic.slice(-40)}`);
};
const findOnlyTopicLog = (onchain, address, topic, label) => {
  const matches = onchain.logs.filter(
    (log) =>
      getAddress(log.address) === address &&
      String(log.topics[0] ?? "").toLowerCase() === topic.toLowerCase(),
  );
  if (matches.length !== 1)
    fail(
      `${label} emitted ${matches.length} matching events, expected exactly one`,
    );
  return matches[0];
};

/* Every receipt hash in the manifest must exist on THIS chain, have succeeded, come from the
   expected deployer. The launchpad receipt below establishes the release floor from live chain
   data; the linked-library and burner transactions are intentionally earlier. Without these live
   checks, a fork artifact promotes cleanly — the failure mode that made rehearsal look like a
   real release. */
for (const [label, hash] of RECEIPT_LABELS) {
  let onchain;
  try {
    onchain = await client.getTransactionReceipt({ hash });
  } catch {
    fail(
      `${label} receipt ${hash} is not on the chain this RPC serves (fork artifact?)`,
    );
  }
  if (onchain.status !== "success")
    fail(`${label} receipt ${hash} did not succeed on chain`);
  if (
    !PERMISSIONLESS_PHASE_B_LABELS.has(label) &&
    getAddress(onchain.from) !== EXPECTED_DEPLOYER
  ) {
    fail(`${label} receipt ${hash} was not sent by the expected deployer`);
  }
  const contractBlockNumber = await contractBlockNumberForReceipt(
    onchain,
    label,
  );
  onchainReceiptOrder.push({
    label,
    hash,
    blockNumber: onchain.blockNumber,
    transactionIndex: onchain.transactionIndex,
    contractBlockNumber,
  });

  const transaction = await client.getTransaction({ hash });
  onchainTransactions.set(label, { receipt: onchain, transaction });

  // The two indexes hash-bind every raw canary file, but promotion independently binds every raw
  // record to this RPC. Transaction hashes are not accepted as opaque labels: calldata, value,
  // sender, target, nonce, and canonical receipt/log coordinates must all match the persisted raw
  // record before the semantic V5 decoder below is allowed to interpret the action references.
  const rawCanaryPair = CANARY_RAW_PAIR_BY_LABEL.get(label);
  if (rawCanaryPair) {
    const rawTx = rawCanaryPair.tx;
    const rawReceipt = rawCanaryPair.receipt;
    const authenticatedHeader = contractBlockCache.get(
      onchain.blockNumber.toString(),
    );
    if (!authenticatedHeader)
      fail(`${label} authenticated receipt header was not cached`);
    let liveRawReceipt;
    try {
      liveRawReceipt = await client.request({
        method: "eth_getTransactionReceipt",
        params: [hash],
      });
    } catch (error) {
      fail(`${label} raw RPC receipt could not be read: ${error.message}`);
    }
    if (
      !sameHex(rawTx.hash, hash) ||
      !sameHex(rawReceipt.transactionHash, hash) ||
      !sameHex(transaction.hash, hash) ||
      !sameHex(rawTx.transaction.input, transaction.input) ||
      !sameHex(rawTx.transaction.from, transaction.from) ||
      !rawTx.transaction.to ||
      !transaction.to ||
      !sameHex(rawTx.transaction.to, transaction.to) ||
      // Forge omits `value` for zero-value calls in real broadcast JSON.
      BigInt(rawTx.transaction.value ?? 0) !== transaction.value ||
      BigInt(rawTx.transaction.nonce) !== BigInt(transaction.nonce) ||
      BigInt(rawTx.transaction.chainId) !== BigInt(transaction.chainId) ||
      // Only Forge's explicit unlocked shape may omit `gas`. Fixed/unknown shapes must carry it;
      // whenever present, the raw limit remains exact evidence against the live RPC transaction.
      (!Object.hasOwn(rawTx.transaction, "gas") &&
        rawTx.isFixedGasLimit !== false) ||
      (Object.hasOwn(rawTx.transaction, "gas") &&
        BigInt(rawTx.transaction.gas) !== BigInt(transaction.gas))
    ) {
      fail(`${label} persisted raw transaction differs from live RPC evidence`);
    }
    try {
      assertRawReceiptMatchesLive(rawReceipt, liveRawReceipt, {
        label,
        blockTimestamp: authenticatedHeader.blockTimestamp,
        contractBlockNumber,
      });
    } catch (error) {
      fail(error.message);
    }
  }

  if (label === "launchpadLib" || label === "hook") {
    const expectedCreate2Address =
      label === "launchpadLib" ? launchpadLib : hook;
    let derived;
    try {
      derived = canonicalCreate2Address(CREATE2_DEPLOYER, transaction.input);
    } catch (error) {
      fail(`${label} CREATE2 evidence: ${error.message}`);
    }
    if (derived !== expectedCreate2Address) {
      fail(
        `${label} CREATE2 calldata derives ${derived}, expected ${expectedCreate2Address}`,
      );
    }
    if (BigInt(transaction.value) !== 0n)
      fail(`${label} CREATE2 transaction sent native value`);
  }

  // The artifact's human-readable `function` field is only a convenience label. For the
  // capability-defining transactions, verify the calldata and the emitted event from the chain
  // itself: generation 5 may not be promoted from relabelled transactions in a hand-built
  // artifact. Both lanes anchor here — the instant token from InstantLaunched, and the auction
  // token + CCA address from AuctionStarted (which also resolves the bid/exit/claim targets).
  if (label === CANARY_INSTANT_LAUNCH) {
    if (!transaction.input.toLowerCase().startsWith(LAUNCH_INSTANT_SELECTOR)) {
      fail(
        `canary instant launch receipt ${hash} is not a live launchInstant() transaction`,
      );
    }
    const log = findOnlyTopicLog(
      onchain,
      launchpad,
      INSTANT_LAUNCHED_TOPIC,
      "canary instant launch",
    );
    canaryInstantToken = indexedTopicAddress(log, 1, "canary instant launch");
    canaryInstantPoolId = log.topics[2];
  }
  if (label === CANARY_TIMING_SHORTEN || label === CANARY_TIMING_RESTORE) {
    if (
      !transaction.input.toLowerCase().startsWith(SET_AUCTION_TIMING_SELECTOR)
    ) {
      fail(
        `${label} receipt ${hash} is not a live setAuctionTiming() transaction`,
      );
    }
    findOnlyTopicLog(onchain, launchpad, AUCTION_TIMING_SET_TOPIC, label);
  }
  if (label === CANARY_AUCTION_LAUNCH) {
    if (!transaction.input.toLowerCase().startsWith(LAUNCH_AUCTION_SELECTOR)) {
      fail(
        `canary auction launch receipt ${hash} is not a live launchAuction() transaction`,
      );
    }
    const log = findOnlyTopicLog(
      onchain,
      launchpad,
      AUCTION_STARTED_TOPIC,
      "canary auction launch",
    );
    canaryAuctionToken = indexedTopicAddress(log, 1, "canary auction launch");
    canaryAuction = indexedTopicAddress(log, 2, "canary auction launch");
    try {
      const decoded = decodeEventLog({
        abi: launchpadEvidenceAbi,
        eventName: "AuctionStarted",
        data: log.data,
        topics: log.topics,
        strict: true,
      });
      canaryAuctionEndBlock = BigInt(decoded.args.endBlock);
    } catch (error) {
      fail(`canary AuctionStarted could not be decoded: ${error.message}`);
    }
    if (canaryAuction === launchpad || canaryAuction === canaryAuctionToken) {
      fail("AuctionStarted names an implausible auction contract");
    }
  }
  if (label === CANARY_HOOKR_LAUNCH) {
    if (!transaction.input.toLowerCase().startsWith(LAUNCH_INSTANT_SELECTOR)) {
      fail(
        `canary hookr launch receipt ${hash} is not a live launchInstant() transaction`,
      );
    }
    const log = findOnlyTopicLog(
      onchain,
      launchpad,
      INSTANT_LAUNCHED_TOPIC,
      "canary hookr launch",
    );
    canaryHookrToken = indexedTopicAddress(log, 1, "canary hookr launch");
    canaryHookrPoolId = log.topics[2];
  }
  if (label === CANARY_HOOKR_APPROVE) {
    if (!transaction.input.toLowerCase().startsWith(ERC20_APPROVE_SELECTOR)) {
      fail(
        `canary hookr approve receipt ${hash} is not a live approve() transaction`,
      );
    }
  }
  if (label === CANARY_FLYWHEEL_BURN) {
    if (
      !transaction.input.toLowerCase().startsWith(BUYBACK_AND_BURN_SELECTOR)
    ) {
      fail(
        `canary flywheel burn receipt ${hash} is not a live buybackAndBurn() transaction`,
      );
    }
    findOnlyTopicLog(
      onchain,
      burner,
      BUYBACK_BURNED_TOPIC,
      "canary flywheel burn",
    );
  }
  if (label === CANARY_AUCTION_BID) {
    if (!canaryAuction)
      fail("canary bid was processed before the live AuctionStarted anchor");
    const log = findOnlyTopicLog(
      onchain,
      canaryAuction,
      BID_SUBMITTED_TOPIC,
      "canary auction bid",
    );
    const ownerTopic = `0x${EXPECTED_DEPLOYER.slice(2).toLowerCase().padStart(64, "0")}`;
    if (
      String(log.topics[2] ?? "").toLowerCase() !== ownerTopic ||
      !log.topics[1]
    ) {
      fail(
        "canary BidSubmitted event does not bind the canary sender and bid id",
      );
    }
    canaryBidId = BigInt(log.topics[1]);
  }

  /* Verify WHAT each transaction touched, from the chain — not from the artifact. Creations are
     checked against the address they actually created, calls against their target; the CCA-lane
     targets come from the AuctionStarted event decoded above, never from artifact fields. The
     phase-A evidence index is therefore only a hash/order binding over the four raw Forge artifacts,
     the direct owner-bid pair, and the two timing pairs; it cannot substitute synthetic records. */
  const expectedTarget = AUCTION_TARGET_LABELS.has(label)
    ? canaryAuction
      ? ["calls", canaryAuction]
      : fail(`${label} was processed before AuctionStarted evidence`)
    : ONCHAIN_TARGET[label];
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
if (
  !canaryInstantToken ||
  !canaryInstantPoolId ||
  !canaryAuctionToken ||
  !canaryAuction ||
  canaryAuctionEndBlock === undefined ||
  !canaryHookrToken ||
  !canaryHookrPoolId
) {
  fail(
    "live canary lane anchors (instant token, auction token, auction, hookr pair token) are incomplete",
  );
}
if (
  getAddress(canaryPhaseAIndex.identities.instantToken) !==
    canaryInstantToken ||
  !sameHex(canaryPhaseAIndex.identities.instantPoolId, canaryInstantPoolId) ||
  getAddress(canaryPhaseAIndex.identities.auctionToken) !==
    canaryAuctionToken ||
  getAddress(canaryPhaseAIndex.identities.auction) !== canaryAuction ||
  BigInt(canaryPhaseAIndex.identities.auctionEndBlock) !==
    canaryAuctionEndBlock ||
  canaryBidId === undefined ||
  BigInt(canaryPhaseAIndex.identities.bidId) !== canaryBidId ||
  getAddress(canaryPhaseAIndex.identities.hookrPairToken) !==
    canaryHookrToken ||
  !sameHex(canaryPhaseAIndex.identities.hookrPoolId, canaryHookrPoolId)
) {
  fail(
    "phase A evidence index does not match the live launchpad-derived lane identities",
  );
}
// The Phase-A bid is a direct owner action and must target the CCA proven by AuctionStarted.
// Permissionless Phase-B effects may be nested in a helper and are instead bound by the
// authenticated protocol events below.
if (getAddress(caTx[5].transaction.to) !== canaryAuction) {
  fail(
    "canary run artifact bid target disagrees with the live AuctionStarted auction",
  );
}

// RECEIPT_LABELS is only a lookup inventory. Keeper calls may interleave with Phase A and with
// each other, so construct the evidence order from authenticated chain coordinates instead of
// imposing label order. The pure validators below enforce only their protocol-causal DAG edges.
onchainReceiptOrder.sort((left, right) => {
  if (left.blockNumber !== right.blockNumber)
    return left.blockNumber < right.blockNumber ? -1 : 1;
  if (left.transactionIndex === right.transactionIndex) return 0;
  return left.transactionIndex < right.transactionIndex ? -1 : 1;
});
try {
  assertAliasedCanonicalReceiptOrder(onchainReceiptOrder, onchainTransactions);
  assertReceiptsWithinEvidenceBlock(onchainReceiptOrder, finalizedHead);
} catch (error) {
  fail(`receipt order: ${error.message}`);
}

const liveLaunchpadRecord = onchainTransactions.get("launchpad");
if (!liveLaunchpadRecord)
  fail("live launchpad deployment transaction evidence is missing");
let deployBlock;
try {
  deployBlock = deriveLiveLaunchpadDeployBlock(
    liveLaunchpadRecord.receipt,
    launchpad,
  );
} catch (error) {
  fail(`launchpad deployment evidence: ${error.message}`);
}
let artifactLaunchpadBlock;
try {
  artifactLaunchpadBlock = BigInt(dRc[2].blockNumber);
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
// The library (#0) and the burner (#1) are intentionally mined before the launchpad; everything
// after the launchpad receipt must sit at or past its block.
for (const record of onchainReceiptOrder.slice(2)) {
  if (record.blockNumber < deployBlock) {
    fail(
      `${record.label} receipt ${record.hash} predates the live launchpad deployment block`,
    );
  }
}

const checks = [
  [
    await read(launchpad, "contractName"),
    "HookrLaunchpadV5",
    "launchpad identity",
  ],
  [await read(launchpad, "contractVersion"), "5.0.1", "launchpad version"],
  [await read(hook, "contractName"), "HookrHook", "hook identity"],
  [await read(hook, "contractVersion"), "1.0.0", "hook version"],
  [await read(router, "contractName"), "HookrSwapRouter", "router identity"],
  [await read(router, "contractVersion"), "1.0.0", "router version"],
  [
    await read(burner, "contractName"),
    "HookrFlywheelBurner",
    "burner identity",
  ],
  [await read(burner, "contractVersion"), "1.0.1", "burner version"],
  [getAddress(await read(launchpad, "hook")), hook, "launchpad->hook wiring"],
  [
    getAddress(await read(launchpad, "auctionFactory")),
    AUCTION_FACTORY,
    "launchpad->CCA factory wiring",
  ],
  [
    getAddress(await read(launchpad, "hookrToken")),
    HOOKR_TOKEN,
    "launchpad->HOOKR quote wiring",
  ],
  [
    await read(launchpad, "hookrInstantOpenFdv"),
    HOOKR_INSTANT_OPEN_FDV,
    "launchpad HOOKR instant FDV",
  ],
  [
    getAddress(await read(hook, "launchpad")),
    launchpad,
    "hook->launchpad wiring",
  ],
  [
    getAddress(await read(hook, "poolManager")),
    POOL_MANAGER,
    "hook->PM wiring",
  ],
  // The flywheel triangle: the hook accrues to the burner, the burner claims from the hook, and
  // the burner burns the pinned HOOKR token. All three must agree before the manifest may carry
  // a flywheel section.
  [
    getAddress(await read(hook, "flywheelRecipient")),
    burner,
    "hook->burner flywheel wiring",
  ],
  [getAddress(await read(burner, "hook")), hook, "burner->hook wiring"],
  [
    getAddress(await read(burner, "hookrToken")),
    HOOKR_TOKEN,
    "burner->HOOKR wiring",
  ],
  [
    getAddress(await read(burner, "poolManager")),
    POOL_MANAGER,
    "burner->PM wiring",
  ],
  [getAddress(await read(burner, "owner")), EXPECTED_DEPLOYER, "burner owner"],
  [
    await read(burner, "maxBuybackWei"),
    REVIEWED_MAX_BUYBACK_WEI,
    "burner buyback ceiling",
  ],
  [await read(burner, "poolFee"), HOOKR_POOL_FEE, "burner pool fee"],
  [
    await read(burner, "poolTickSpacing"),
    HOOKR_POOL_TICK_SPACING,
    "burner pool tick spacing",
  ],
  [getAddress(await read(router, "hook")), hook, "router->hook wiring"],
  [
    getAddress(await read(router, "poolManager")),
    POOL_MANAGER,
    "router->PM wiring",
  ],
  [
    getAddress(await read(router, "quoteToken")),
    HOOKR_TOKEN,
    "router->HOOKR quote wiring",
  ],
  [
    getAddress(await read(launchpad, "owner")),
    EXPECTED_DEPLOYER,
    "launchpad owner",
  ],
  [
    await read(launchpad, "creationFeeWei"),
    REVIEWED_CREATION_FEE_WEI,
    "launchpad creation fee",
  ],
  [
    await read(launchpad, "auctionDurationBlocks"),
    PRODUCTION_AUCTION_DURATION_BLOCKS,
    "launchpad production auction duration restored",
  ],
  [
    await read(launchpad, "claimDelayBlocks"),
    PRODUCTION_CLAIM_DELAY_BLOCKS,
    "launchpad production claim delay restored",
  ],
  [
    await read(launchpad, "migrationDelayBlocks"),
    PRODUCTION_MIGRATION_DELAY_BLOCKS,
    "launchpad production migration delay restored",
  ],
];
for (const [actual, expected, label] of checks) {
  if (actual !== expected)
    fail(`${label}: expected ${expected}, read ${actual}`);
}
const blueprintsCount = BigInt(await read(launchpad, "blueprintsCount"));
if (blueprintsCount < 6n) {
  fail(
    `blueprint count ${blueprintsCount} is missing the sentinel or one of five house blueprints`,
  );
}

/* ----------------------------------- blueprint + v5 canary semantic evidence
   Successful calls to the expected contracts are insufficient release evidence: unrelated
   transactions can be relabelled in a hand-built artifact. Decode the five house-blueprint calls
   and events and compare their complete pinned readbacks first. Then decode all canary action
   references — every lane plus the flywheel — and hand the pure v5 validator the exact calldata,
   events, and pinned post-state it binds to one instant token/pool, one auction token/CCA/pool,
   one HOOKR pair token/pool, and one collect + buyback-burn round trip. */
const decodeCall = (record, abi_, functionName, label) => {
  try {
    const decoded = decodeFunctionData({
      abi: abi_,
      data: record.transaction.input,
    });
    if (decoded.functionName !== functionName) {
      fail(
        `${label} decoded as ${decoded.functionName}(), expected ${functionName}()`,
      );
    }
    const canonicalInput = encodeFunctionData({
      abi: abi_,
      functionName,
      args: decoded.args,
    });
    if (
      canonicalInput.toLowerCase() !== record.transaction.input.toLowerCase()
    ) {
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
      const decoded = decodeEventLog({
        abi: abi_,
        eventName,
        data: log.data,
        topics: log.topics,
        strict: true,
      });
      if (decoded.eventName === eventName) matches.push(decoded.args);
    } catch {
      // This contract emits several event types in the same receipt; only the named event counts.
    }
  }
  if (matches.length !== 1)
    fail(
      `${label} emitted ${matches.length} ${eventName} events, expected exactly one`,
    );
  return matches[0];
};
const decodeAllEvents = (record, address, abi_, eventName, label) => {
  const matches = [];
  for (const log of record.receipt.logs) {
    if (getAddress(log.address) !== address) continue;
    try {
      const decoded = decodeEventLog({
        abi: abi_,
        eventName,
        data: log.data,
        topics: log.topics,
        strict: true,
      });
      if (decoded.eventName === eventName) {
        matches.push({
          ...decoded.args,
          transactionHash: log.transactionHash,
          logIndex: log.logIndex,
        });
      }
    } catch {
      // Only a strict decode of the named event from the exact emitter is evidence.
    }
  }
  if (matches.length === 0)
    fail(`${label} emitted no ${eventName} events from ${address}`);
  return matches;
};
/* The swap/claim/burn delivery proof: exactly one ERC20 Transfer on `token` whose recipient is
   the expected account (the canary sender for deliveries, the dead address for the flywheel
   burn). The token address is folded into the returned shape because the validator binds it back
   to the lane's token. */
const decodeOnlyTransferTo = (record, token, recipient, label) => {
  const matches = [];
  for (const log of record.receipt.logs) {
    if (getAddress(log.address) !== token) continue;
    try {
      const decoded = decodeEventLog({
        abi: tokenEvidenceAbi,
        eventName: "Transfer",
        data: log.data,
        topics: log.topics,
        strict: true,
      });
      if (getAddress(decoded.args.to) === recipient) matches.push(decoded.args);
    } catch {
      // Non-Transfer token logs are not delivery evidence.
    }
  }
  if (matches.length !== 1) {
    fail(
      `${label} emitted ${matches.length} token transfers to the expected recipient, expected exactly one`,
    );
  }
  return {
    token,
    from: matches[0].from,
    to: matches[0].to,
    value: matches[0].value,
  };
};
const tupleField = (value, name, index) => value?.[name] ?? value?.[index];
const hookParamsShape = (value) =>
  Object.fromEntries(
    HOOK_PARAM_FIELDS.map((field, index) => [
      field,
      tupleField(value, field, index),
    ]),
  );
const pinnedRead = (address, abi_, functionName, args_ = []) =>
  client.readContract({ address, abi: abi_, functionName, args: args_, ...at });

const blueprintEvidence = await Promise.all(
  receipts.blueprints.map(async (_, index) => {
    const id = index + 1;
    const label = `blueprint#${id}`;
    const record = onchainTransactions.get(label);
    if (!record) fail(`${label} live transaction evidence is missing`);
    const call = decodeCall(
      record,
      blueprintEvidenceAbi,
      "saveBlueprint",
      label,
    );
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
    const contractBlockNumber = await contractBlockNumberForReceipt(
      record.receipt,
      label,
    );
    return {
      id,
      transaction: {
        from: record.transaction.from,
        to: record.transaction.to,
        value: record.transaction.value,
        blockNumber: record.receipt.blockNumber,
        contractBlockNumber,
      },
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

/* -------------------------------------------------- canary evidence (both lanes)
   The CCA's window arithmetic runs on ITS clock — ArbSys.arbBlockNumber(), which on 4663 IS the
   rollup height that receipts report — and since the launchpad's clock fix, AuctionStarted's
   endBlock is denominated in that same clock. So canary evidence uses plain receipt block
   numbers throughout: ordered blocks, transaction blocks, and the auction window all live on one
   clock, directly comparable. (The parent-chain l1BlockNumber conversion remains only where the
   contract really writes block.number: blueprint savedAtBlock evidence.) */
const canaryRecord = (label) => {
  const record = onchainTransactions.get(label);
  if (!record) fail(`${label} live transaction evidence is missing`);
  return record;
};
const canaryLabels = new Set([
  ...V5_CANARY_SPEC.phaseAReceiptLabels,
  ...V5_CANARY_SPEC.phaseBReceiptLabels,
]);
for (const label of canaryLabels) canaryRecord(label); // presence check, fail-closed
const canaryReceiptOrder = onchainReceiptOrder
  .filter((record) => canaryLabels.has(record.label))
  .map((record) => ({
    label: record.label,
    hash: record.hash,
    blockNumber: record.blockNumber,
    transactionIndex: record.transactionIndex,
  }));
const canaryOrderByLabel = new Map(
  onchainReceiptOrder
    .filter((record) => canaryLabels.has(record.label))
    .map((record) => [record.label, record]),
);
const canaryBlockTimestampByLabel = new Map();
for (const label of [CANARY_INSTANT_BUY, CANARY_HOOKR_BUY]) {
  const record = canaryRecord(label);
  const block = await client.getBlock({
    blockNumber: record.receipt.blockNumber,
  });
  if (!sameHex(block.hash, record.receipt.blockHash)) {
    fail(`${label} block timestamp is not bound to its receipt hash`);
  }
  canaryBlockTimestampByLabel.set(label, block.timestamp);
}
const canaryTxShape = (label) => {
  const record = canaryRecord(label);
  const order = canaryOrderByLabel.get(label);
  if (!order) fail(`${label} has no ordered receipt clock evidence`);
  return {
    from: record.transaction.from,
    to: record.transaction.to,
    value: record.transaction.value,
    nonce: record.transaction.nonce,
    blockNumber: record.receipt.blockNumber,
    contractBlockNumber: order.contractBlockNumber,
    blockTimestamp: canaryBlockTimestampByLabel.get(label),
  };
};

const instantLaunchRecord = canaryRecord(CANARY_INSTANT_LAUNCH);
const timingShortenRecord = canaryRecord(CANARY_TIMING_SHORTEN);
const instantBuyRecord = canaryRecord(CANARY_INSTANT_BUY);
const auctionLaunchRecord = canaryRecord(CANARY_AUCTION_LAUNCH);
const timingRestoreRecord = canaryRecord(CANARY_TIMING_RESTORE);
const auctionBidRecord = canaryRecord(CANARY_AUCTION_BID);
const hookrLaunchRecord = canaryRecord(CANARY_HOOKR_LAUNCH);
const hookrApproveRecord = canaryRecord(CANARY_HOOKR_APPROVE);
const hookrBuyRecord = canaryRecord(CANARY_HOOKR_BUY);
const auctionMigrateRecord = canaryRecord(CANARY_AUCTION_MIGRATE);
const auctionExitRecord = canaryRecord(CANARY_AUCTION_EXIT);
const auctionClaimRecord = canaryRecord(CANARY_AUCTION_CLAIM);
const auctionProceedsRecord = canaryRecord(CANARY_AUCTION_PROCEEDS);
const flywheelCollectRecord = canaryRecord(CANARY_FLYWHEEL_COLLECT);
const flywheelBurnRecord = canaryRecord(CANARY_FLYWHEEL_BURN);
const phaseBRecordByAction = {
  migrateAuction: auctionMigrateRecord,
  exitBid: auctionExitRecord,
  claimTokens: auctionClaimRecord,
  claimAuctionProceeds: auctionProceedsRecord,
  collect: flywheelCollectRecord,
  buybackAndBurn: flywheelBurnRecord,
};
const indexedPhaseBEvent = (actionName, eventName, label) => {
  const event =
    authenticatedPhaseBIndex.actions[actionName]?.events?.[eventName];
  const record = phaseBRecordByAction[actionName];
  if (!event || typeof event !== "object")
    fail(`${label} is missing from authenticated Phase-B evidence`);
  if (!sameHex(event.transactionHash, record.receipt.transactionHash)) {
    fail(
      `${label} transaction hash differs from its authenticated Phase-B receipt`,
    );
  }
  if (BigInt(event.logIndex) < 0n) fail(`${label} log index is negative`);
  return event;
};

const instantLaunchCall = decodeCall(
  instantLaunchRecord,
  launchpadEvidenceAbi,
  "launchInstant",
  "canary instant launch",
);
const timingShortenCall = decodeCall(
  timingShortenRecord,
  launchpadEvidenceAbi,
  "setAuctionTiming",
  "canary timing shorten",
);
const instantBuyCall = decodeCall(
  instantBuyRecord,
  routerEvidenceAbi,
  "exactInput",
  "canary buy",
);
const auctionLaunchCall = decodeCall(
  auctionLaunchRecord,
  launchpadEvidenceAbi,
  "launchAuction",
  "canary auction launch",
);
const timingRestoreCall = decodeCall(
  timingRestoreRecord,
  launchpadEvidenceAbi,
  "setAuctionTiming",
  "canary timing restore",
);
const auctionBidCall = decodeCall(
  auctionBidRecord,
  auctionEvidenceAbi,
  "submitBid",
  "canary bid",
);
const hookrLaunchCall = decodeCall(
  hookrLaunchRecord,
  launchpadEvidenceAbi,
  "launchInstant",
  "canary hookr launch",
);
const hookrApproveCall = decodeCall(
  hookrApproveRecord,
  erc20EvidenceAbi,
  "approve",
  "canary hookr approve",
);
const hookrBuyCall = decodeCall(
  hookrBuyRecord,
  routerEvidenceAbi,
  "exactInput",
  "canary hookr buy",
);
const phaseBProceedsEvents =
  authenticatedPhaseBIndex.actions.claimAuctionProceeds.events;
const phaseBProceedsNotApplicable =
  phaseBProceedsEvents.call === NOT_APPLICABLE_ZERO_PROCEEDS;
for (const actionName of [
  "migrateAuction",
  "exitBid",
  "claimAuctionProceeds",
  "collect",
]) {
  const mode = authenticatedPhaseBIndex.actions[actionName].events.call;
  if (actionName === "claimAuctionProceeds" && phaseBProceedsNotApplicable)
    continue;
  if (mode !== "direct" && mode !== "nested") {
    fail(`Phase-B ${actionName} evidence names an unreviewed call mode`);
  }
}
let phaseBZeroProceedsProof = null;
if (phaseBProceedsNotApplicable) {
  if (
    phaseBProceedsEvents.mode !== NOT_APPLICABLE_ZERO_PROCEEDS ||
    phaseBProceedsEvents.executionMode !== "not-applicable" ||
    phaseBProceedsEvents.creatorFeesClaimed !== null ||
    authenticatedPhaseBIndex.actions.migrateAuction.events.auctionProceeds !==
      null
  ) {
    fail(
      "Phase-B zero-proceeds evidence does not explicitly prove both settlement events absent",
    );
  }
  phaseBZeroProceedsProof = phaseBProceedsEvents.notApplicable;
  if (
    phaseBZeroProceedsProof?.executionMode !== "not-applicable" ||
    phaseBZeroProceedsProof?.mode !== NOT_APPLICABLE_ZERO_PROCEEDS ||
    !sameHex(
      phaseBZeroProceedsProof?.token,
      canaryPhaseAIndex.identities.auctionToken,
    ) ||
    BigInt(phaseBZeroProceedsProof?.amountWei) !== 0n ||
    !sameHex(
      phaseBZeroProceedsProof?.proofTransactionHash,
      authenticatedPhaseBIndex.actions.migrateAuction.transaction.hash,
    )
  ) {
    fail(
      "Phase-B zero-proceeds proof metadata differs from the authenticated migration",
    );
  }
  try {
    assert.deepStrictEqual(
      auctionProceedsRecord.transaction,
      auctionMigrateRecord.transaction,
      "zero-proceeds action does not alias the exact migration transaction",
    );
    assert.deepStrictEqual(
      auctionProceedsRecord.receipt,
      auctionMigrateRecord.receipt,
      "zero-proceeds action does not alias the exact migration receipt",
    );
  } catch (error) {
    fail(error.message);
  }
}
const auctionClaimKind =
  authenticatedPhaseBIndex.actions.claimTokens.events.call;
if (
  auctionClaimKind !== "claimTokens" &&
  auctionClaimKind !== "claimTokensBatch" &&
  auctionClaimKind !== "nested"
) {
  fail("Phase-B claim evidence names an unreviewed claim entrypoint");
}
let auctionClaimRequestedBidIds;
if (auctionClaimKind !== "nested") {
  let decoded;
  try {
    decoded = decodeFunctionData({
      abi: auctionEvidenceAbi,
      data: auctionClaimRecord.transaction.input,
    });
  } catch (error) {
    fail(
      `direct canary claim calldata could not be ABI-decoded: ${error.message}`,
    );
  }
  if (decoded.functionName !== auctionClaimKind) {
    fail(
      `direct canary claim decoded as ${decoded.functionName}(), expected ${auctionClaimKind}()`,
    );
  }
  if (auctionClaimKind === "claimTokens") {
    auctionClaimRequestedBidIds = [decoded.args[0]];
  } else {
    if (getAddress(decoded.args[0]) !== EXPECTED_DEPLOYER) {
      fail("canary batch claim owner is not the canary owner");
    }
    auctionClaimRequestedBidIds = [...decoded.args[1]];
  }
  // Duplicate requested ids are harmless interposition: the CCA must still emit one unique,
  // positive canary TokensClaimed event. Require inclusion, not exact-once calldata occurrence.
  if (!auctionClaimRequestedBidIds.some((id) => BigInt(id) === canaryBidId)) {
    fail("direct canary claim does not contain the sender-owned bid");
  }
}
const flywheelBurnCall = decodeCall(
  flywheelBurnRecord,
  burnerEvidenceAbi,
  "buybackAndBurn",
  "canary flywheel burn",
);
if (canaryBidId === undefined)
  fail("canary bid id is missing from the live BidSubmitted event");
if (getAddress(auctionBidCall.args[2]) !== EXPECTED_DEPLOYER) {
  fail("canary bid owner is not the canary sender");
}

const instantTokenEvent = decodeOnlyEvent(
  instantLaunchRecord,
  launchpad,
  launchpadEvidenceAbi,
  "TokenLaunched",
  "canary instant launch",
);
const instantLaunchedEvent = decodeOnlyEvent(
  instantLaunchRecord,
  launchpad,
  launchpadEvidenceAbi,
  "InstantLaunched",
  "canary instant launch",
);
const instantInitializeEvent = decodeOnlyEvent(
  instantLaunchRecord,
  POOL_MANAGER,
  poolManagerEvidenceAbi,
  "Initialize",
  "canary instant launch",
);
const instantIntentEvent = decodeOnlyEvent(
  instantLaunchRecord,
  launchpad,
  launchpadEvidenceAbi,
  "LaunchIntentConsumed",
  "canary instant launch",
);
const timingShortenEvent = decodeOnlyEvent(
  timingShortenRecord,
  launchpad,
  launchpadEvidenceAbi,
  "AuctionTimingSet",
  "canary timing shorten",
);
const buySwapExecutedEvent = decodeOnlyEvent(
  instantBuyRecord,
  router,
  routerEvidenceAbi,
  "SwapExecuted",
  "canary buy",
);
const buyPoolManagerEvent = decodeOnlyEvent(
  instantBuyRecord,
  POOL_MANAGER,
  poolManagerEvidenceAbi,
  "Swap",
  "canary buy",
);
const instantFlywheelFeeEvent = decodeOnlyEvent(
  instantBuyRecord,
  hook,
  hookEvidenceAbi,
  "FlywheelFeeAccrued",
  "canary buy",
);
const buyTransferEvent = decodeOnlyTransferTo(
  instantBuyRecord,
  canaryInstantToken,
  EXPECTED_DEPLOYER,
  "canary buy",
);
const auctionTokenEvent = decodeOnlyEvent(
  auctionLaunchRecord,
  launchpad,
  launchpadEvidenceAbi,
  "TokenLaunched",
  "canary auction launch",
);
const auctionStartedEvent = decodeOnlyEvent(
  auctionLaunchRecord,
  launchpad,
  launchpadEvidenceAbi,
  "AuctionStarted",
  "canary auction launch",
);
const auctionIntentEvent = decodeOnlyEvent(
  auctionLaunchRecord,
  launchpad,
  launchpadEvidenceAbi,
  "LaunchIntentConsumed",
  "canary auction launch",
);
const timingRestoreEvent = decodeOnlyEvent(
  timingRestoreRecord,
  launchpad,
  launchpadEvidenceAbi,
  "AuctionTimingSet",
  "canary timing restore",
);
const auctionBidEvent = decodeOnlyEvent(
  auctionBidRecord,
  canaryAuction,
  auctionEvidenceAbi,
  "BidSubmitted",
  "canary auction bid",
);
const migratedEvent = indexedPhaseBEvent(
  "migrateAuction",
  "migrated",
  "canary Migrated",
);
const auctionInitializeEvent = indexedPhaseBEvent(
  "migrateAuction",
  "poolInitialized",
  "canary PoolManager Initialize",
);
const auctionProceedsEvent = phaseBProceedsNotApplicable
  ? null
  : indexedPhaseBEvent(
      "migrateAuction",
      "auctionProceeds",
      "canary AuctionProceeds",
    );
// This receipt-local CCA event is the historical NET currency actually transferred to the
// launchpad. A later lbpInitializationParams() read re-quotes the mutable protocol fee and cannot
// substitute for the amount swept in this migration transaction.
const indexedCurrencySweptEvent = indexedPhaseBEvent(
  "migrateAuction",
  "currencySwept",
  "canary CurrencySwept",
);
const currencySweptEvent = {
  ...indexedCurrencySweptEvent,
  currencyAmount: indexedCurrencySweptEvent.amountWei,
};
const bidExitedEvent = indexedPhaseBEvent(
  "exitBid",
  "bidExited",
  "canary BidExited",
);

// A direct batch may request duplicate canary or unrelated ids; only emitted settlement counts.
// Decode every owner-scoped receipt event, require unique/subset semantics when the top-level call
// is directly decodable, and prove the aggregate auction->owner transfer equals their exact sum.
const phaseBClaimEvents = authenticatedPhaseBIndex.actions.claimTokens.events;
const allClaimEvents = decodeAllEvents(
  auctionClaimRecord,
  canaryAuction,
  auctionEvidenceAbi,
  "TokensClaimed",
  "canary claim",
);
const ownerClaimEvents = allClaimEvents.filter(
  (event) => getAddress(event.owner) === EXPECTED_DEPLOYER,
);
const exactCanaryClaimEvents = ownerClaimEvents.filter(
  (event) =>
    BigInt(event.bidId) === canaryBidId && BigInt(event.tokensFilled) > 0n,
);
if (exactCanaryClaimEvents.length !== 1) {
  fail(
    `canary claim emitted ${exactCanaryClaimEvents.length} positive canary TokensClaimed events, expected one`,
  );
}
const tokensClaimedEvent = exactCanaryClaimEvents[0];
const indexedTokensClaimedEvent = indexedPhaseBEvent(
  "claimTokens",
  "tokensClaimed",
  "selected canary TokensClaimed",
);
if (
  BigInt(indexedTokensClaimedEvent.bidId) !==
    BigInt(tokensClaimedEvent.bidId) ||
  getAddress(indexedTokensClaimedEvent.owner) !==
    getAddress(tokensClaimedEvent.owner) ||
  BigInt(indexedTokensClaimedEvent.tokensFilled) !==
    BigInt(tokensClaimedEvent.tokensFilled) ||
  BigInt(indexedTokensClaimedEvent.logIndex) !==
    BigInt(tokensClaimedEvent.logIndex)
) {
  fail(
    "authenticated Phase-B TokensClaimed selection differs from the live canonical receipt",
  );
}
if (auctionClaimKind !== "nested") {
  const requested = new Set(
    auctionClaimRequestedBidIds.map((id) => BigInt(id).toString()),
  );
  const emitted = new Set();
  for (const event of ownerClaimEvents) {
    const bidId = BigInt(event.bidId).toString();
    if (!requested.has(bidId))
      fail("direct batch claim emitted a bid absent from calldata");
    if (emitted.has(bidId))
      fail("direct batch claim emitted duplicate TokensClaimed bid ids");
    emitted.add(bidId);
  }
}
const ownerTransferEvents = decodeAllEvents(
  auctionClaimRecord,
  canaryAuctionToken,
  tokenEvidenceAbi,
  "Transfer",
  "canary claim",
).filter(
  (event) =>
    getAddress(event.from) === canaryAuction &&
    getAddress(event.to) === EXPECTED_DEPLOYER,
);
if (ownerTransferEvents.length === 0)
  fail("canary claim emitted no auction-to-owner Transfer");
if (auctionClaimKind !== "nested" && ownerTransferEvents.length !== 1) {
  fail("direct canary claim did not emit exactly one aggregate Transfer");
}
const ownerTransferAmount = ownerTransferEvents.reduce(
  (sum, event) => sum + BigInt(event.value),
  0n,
);
const ownerClaimAmount = ownerClaimEvents.reduce(
  (sum, event) => sum + BigInt(event.tokensFilled),
  0n,
);
if (ownerTransferAmount !== ownerClaimAmount) {
  fail(
    "canary claim aggregate Transfer does not equal the sum of TokensClaimed events",
  );
}
if (
  Number(phaseBClaimEvents.auctionToOwnerTransfers.count) !==
    ownerTransferEvents.length ||
  BigInt(phaseBClaimEvents.auctionToOwnerTransfers.aggregateAmount) !==
    ownerTransferAmount ||
  phaseBClaimEvents.auctionToOwnerTransfers.logIndexes.length !==
    ownerTransferEvents.length ||
  phaseBClaimEvents.auctionToOwnerTransfers.logIndexes.some(
    (logIndex, index) =>
      BigInt(logIndex) !== BigInt(ownerTransferEvents[index].logIndex),
  )
) {
  fail(
    "authenticated Phase-B transfer aggregate differs from the live canonical receipt",
  );
}
const claimTransferEvent = {
  token: canaryAuctionToken,
  from: canaryAuction,
  to: EXPECTED_DEPLOYER,
  value: ownerTransferAmount,
};
const proceedsClaimEvent = phaseBProceedsNotApplicable
  ? null
  : indexedPhaseBEvent(
      "claimAuctionProceeds",
      "creatorFeesClaimed",
      "canary CreatorFeesClaimed",
    );
const hookrTokenEvent = decodeOnlyEvent(
  hookrLaunchRecord,
  launchpad,
  launchpadEvidenceAbi,
  "TokenLaunched",
  "canary hookr launch",
);
const hookrLaunchedEvent = decodeOnlyEvent(
  hookrLaunchRecord,
  launchpad,
  launchpadEvidenceAbi,
  "InstantLaunched",
  "canary hookr launch",
);
const hookrInitializeEvent = decodeOnlyEvent(
  hookrLaunchRecord,
  POOL_MANAGER,
  poolManagerEvidenceAbi,
  "Initialize",
  "canary hookr launch",
);
const hookrIntentEvent = decodeOnlyEvent(
  hookrLaunchRecord,
  launchpad,
  launchpadEvidenceAbi,
  "LaunchIntentConsumed",
  "canary hookr launch",
);
const hookrApprovalEvent = decodeOnlyEvent(
  hookrApproveRecord,
  HOOKR_TOKEN,
  erc20EvidenceAbi,
  "Approval",
  "canary hookr approve",
);
const hookrBuySwapExecutedEvent = decodeOnlyEvent(
  hookrBuyRecord,
  router,
  routerEvidenceAbi,
  "SwapExecuted",
  "canary hookr buy",
);
const hookrBuyPoolManagerEvent = decodeOnlyEvent(
  hookrBuyRecord,
  POOL_MANAGER,
  poolManagerEvidenceAbi,
  "Swap",
  "canary hookr buy",
);
const hookrBuyTransferEvent = decodeOnlyTransferTo(
  hookrBuyRecord,
  canaryHookrToken,
  EXPECTED_DEPLOYER,
  "canary hookr buy",
);
const indexedBuybackBurnedEvent = indexedPhaseBEvent(
  "buybackAndBurn",
  "buybackBurned",
  "canary BuybackBurned",
);
const buybackBurnedEvent = {
  ...indexedBuybackBurnedEvent,
  ethIn: indexedBuybackBurnedEvent.ethSpentWei,
};
const flywheelCollectedEvent = indexedPhaseBEvent(
  "collect",
  "flywheelCollected",
  "canary FlywheelCollected",
);
const flywheelHookClaimedEvent = indexedPhaseBEvent(
  "collect",
  "hookClaimed",
  "canary hook Claimed",
);
// The flywheel's proof of destruction: exactly one HOOKR transfer to the dead address in the
// same receipt that emitted BuybackBurned.
const indexedFlywheelDeadTransferEvent = indexedPhaseBEvent(
  "buybackAndBurn",
  "hookrDeadTransfer",
  "canary flywheel dead-address Transfer",
);
const flywheelDeadTransferEvent = {
  ...indexedFlywheelDeadTransferEvent,
  value: indexedFlywheelDeadTransferEvent.amount,
};

// The intent registry must bind each lane's intent to the exact token the events proved, at the
// pinned block — a replayed or foreign launch cannot satisfy both the event and this readback.
const [
  instantOpenPriceWei,
  hookrInstantOpenPriceWei,
  instantIntentToken,
  auctionIntentToken,
  hookrIntentToken,
  instantLaunchStateRaw,
  auctionLaunchStateRaw,
  hookrLaunchStateRaw,
  hookrAllowance,
  auctionCreatorProceedsWei,
  instantPoolConfigRaw,
  auctionPoolConfigRaw,
  hookrPoolConfigRaw,
  auctionOutcomeRaw,
  auctionGrossCurrencyRaised,
  finalAuctionDurationBlocks,
  finalClaimDelayBlocks,
  finalMigrationDelayBlocks,
] = await Promise.all([
  pinnedRead(launchpad, launchpadEvidenceAbi, "instantOpenPriceWei"),
  pinnedRead(launchpad, launchpadEvidenceAbi, "hookrInstantOpenPrice"),
  pinnedRead(launchpad, launchpadEvidenceAbi, "launchedByIntent", [
    EXPECTED_DEPLOYER,
    V5_CANARY_SPEC.instantIntentId,
  ]),
  pinnedRead(launchpad, launchpadEvidenceAbi, "launchedByIntent", [
    EXPECTED_DEPLOYER,
    V5_CANARY_SPEC.auctionIntentId,
  ]),
  pinnedRead(launchpad, launchpadEvidenceAbi, "launchedByIntent", [
    EXPECTED_DEPLOYER,
    V5_CANARY_SPEC.hookrIntentId,
  ]),
  pinnedRead(launchpad, launchpadEvidenceAbi, "getLaunch", [
    canaryInstantToken,
  ]),
  pinnedRead(launchpad, launchpadEvidenceAbi, "getLaunch", [
    canaryAuctionToken,
  ]),
  pinnedRead(launchpad, launchpadEvidenceAbi, "getLaunch", [canaryHookrToken]),
  pinnedRead(HOOKR_TOKEN, erc20EvidenceAbi, "allowance", [
    EXPECTED_DEPLOYER,
    router,
  ]),
  pinnedRead(launchpad, launchpadEvidenceAbi, "creatorProceedsWei", [
    canaryAuctionToken,
  ]),
  pinnedRead(hook, hookEvidenceAbi, "poolConfig", [
    instantLaunchedEvent.poolId,
  ]),
  pinnedRead(hook, hookEvidenceAbi, "poolConfig", [migratedEvent.poolId]),
  pinnedRead(hook, hookEvidenceAbi, "poolConfig", [hookrLaunchedEvent.poolId]),
  pinnedRead(canaryAuction, auctionEvidenceAbi, "lbpInitializationParams"),
  pinnedRead(canaryAuction, auctionEvidenceAbi, "currencyRaised"),
  read(launchpad, "auctionDurationBlocks"),
  read(launchpad, "claimDelayBlocks"),
  read(launchpad, "migrationDelayBlocks"),
]);
if (getAddress(instantIntentToken) !== canaryInstantToken) {
  fail(
    "pinned launchedByIntent(instant) does not name the canary instant token",
  );
}
if (getAddress(auctionIntentToken) !== canaryAuctionToken) {
  fail(
    "pinned launchedByIntent(auction) does not name the canary auction token",
  );
}
if (getAddress(hookrIntentToken) !== canaryHookrToken) {
  fail(
    "pinned launchedByIntent(hookr) does not name the canary hookr pair token",
  );
}
if (getAddress(instantIntentEvent.token) !== canaryInstantToken) {
  fail("instant LaunchIntentConsumed names a different token");
}
if (getAddress(auctionIntentEvent.token) !== canaryAuctionToken) {
  fail("auction LaunchIntentConsumed names a different token");
}
if (getAddress(hookrIntentEvent.token) !== canaryHookrToken) {
  fail("hookr LaunchIntentConsumed names a different token");
}

const poolConfigShape = (raw) => ({
  initialized: tupleField(raw, "initialized", 0),
  guardEndBlock: tupleField(raw, "guardEndBlock", 1),
  baseFeePips: tupleField(raw, "baseFeePips", 2),
  maxFeePips: tupleField(raw, "maxFeePips", 3),
  snipeTaxPips: tupleField(raw, "snipeTaxPips", 4),
  surgeSens: tupleField(raw, "surgeSens", 5),
  burnBps: tupleField(raw, "burnBps", 6),
  lpBps: tupleField(raw, "lpBps", 7),
  potBps: tupleField(raw, "potBps", 8),
  royaltyBps: tupleField(raw, "royaltyBps", 9),
  potEveryNBuys: tupleField(raw, "potEveryNBuys", 10),
  maxBuyWei: tupleField(raw, "maxBuyWei", 11),
  potMinBuyWei: tupleField(raw, "potMinBuyWei", 12),
  burnTriggerWei: tupleField(raw, "burnTriggerWei", 13),
  royaltyTo: tupleField(raw, "royaltyTo", 14),
  token: tupleField(raw, "token", 15),
  flywheelFeePips: tupleField(raw, "flywheelFeePips", 16),
});
const instantPoolConfig = poolConfigShape(instantPoolConfigRaw);
const auctionPoolConfig = poolConfigShape(auctionPoolConfigRaw);
const hookrPoolConfig = poolConfigShape(hookrPoolConfigRaw);
const auctionOutcome = {
  initialPriceX96: tupleField(auctionOutcomeRaw, "initialPriceX96", 0),
  tokensSold: tupleField(auctionOutcomeRaw, "tokensSold", 1),
  // Informational only for net settlement: this is calculated using the protocol fee at PINNED_BLOCK,
  // which may differ from the fee used by the historical sweep. CurrencySwept is authoritative there.
  currencyRaisedNetAtRead: tupleField(auctionOutcomeRaw, "currencyRaised", 2),
  // Stable post-checkpoint gross accounting used by the CCA's graduation predicate.
  currencyRaisedGross: auctionGrossCurrencyRaised,
};

const launchStateShape = (raw) => ({
  token: tupleField(raw, "token", 0),
  creator: tupleField(raw, "creator", 1),
  launchBlock: tupleField(raw, "launchBlock", 2),
  blueprintId: tupleField(raw, "blueprintId", 3),
  mode: tupleField(raw, "mode", 4),
  status: tupleField(raw, "status", 5),
  openPriceWei: tupleField(raw, "openPriceWei", 6),
  openFdvWei: tupleField(raw, "openFdvWei", 7),
  reserveBps: tupleField(raw, "reserveBps", 8),
  auction: tupleField(raw, "auction", 9),
  auctionEndBlock: tupleField(raw, "auctionEndBlock", 10),
  migratedAtBlock: tupleField(raw, "migratedAtBlock", 11),
  sqrtPriceX96AtOpen: tupleField(raw, "sqrtPriceX96AtOpen", 12),
  poolId: tupleField(raw, "poolId", 13),
  quote: tupleField(raw, "quote", 14),
  hookParams: hookParamsShape(tupleField(raw, "hookParams", 15)),
});
const instantLaunchState = launchStateShape(instantLaunchStateRaw);
const auctionLaunchState = launchStateShape(auctionLaunchStateRaw);
const hookrLaunchState = launchStateShape(hookrLaunchStateRaw);

const [
  auctionCurrency,
  auctionConfigToken,
  auctionTotalSupply,
  auctionTokensRecipient,
  auctionFundsRecipient,
  auctionStartBlock,
  auctionEndBlock,
  auctionClaimBlock,
  auctionValidationHook,
  auctionGraduated,
] = await Promise.all([
  pinnedRead(canaryAuction, auctionEvidenceAbi, "currency"),
  pinnedRead(canaryAuction, auctionEvidenceAbi, "token"),
  pinnedRead(canaryAuction, auctionEvidenceAbi, "totalSupply"),
  pinnedRead(canaryAuction, auctionEvidenceAbi, "tokensRecipient"),
  pinnedRead(canaryAuction, auctionEvidenceAbi, "fundsRecipient"),
  pinnedRead(canaryAuction, auctionEvidenceAbi, "startBlock"),
  pinnedRead(canaryAuction, auctionEvidenceAbi, "endBlock"),
  pinnedRead(canaryAuction, auctionEvidenceAbi, "claimBlock"),
  pinnedRead(canaryAuction, auctionEvidenceAbi, "validationHook"),
  pinnedRead(canaryAuction, auctionEvidenceAbi, "isGraduated"),
]);
if (BigInt(auctionTotalSupply) !== CANARY_AUCTION_SUPPLY) {
  fail(
    `CCA total supply ${auctionTotalSupply} is not the reviewed ${CANARY_AUCTION_SUPPLY}`,
  );
}
// This immutable CCA release exposes currency/token/supply/recipients/start/end/claim/hook but
// deliberately has no getters for FLOOR_PRICE_Q96, TICK_SPACING_Q96, REQUIRED_CURRENCY_RAISED,
// or the packed uniform step. Bind every exposed immutable above; bind the unexposed values by
// exact launch calldata + AuctionStarted fields, the reviewed launchpad runtime/source, and the
// same deterministic derivation the linked library executes.
const rawCanaryFloorQ96 =
  (V5_CANARY_SPEC.floorFdvWei << 96n) / (1_000_000_000n * 10n ** 18n);
const derivedCanaryTickSpacingQ96 = rawCanaryFloorQ96 / 100n;
const derivedCanaryFloorQ96 =
  (rawCanaryFloorQ96 / derivedCanaryTickSpacingQ96) *
  derivedCanaryTickSpacingQ96;
if (
  derivedCanaryFloorQ96 !== CANARY_CCA_FLOOR_PRICE_Q96 ||
  derivedCanaryTickSpacingQ96 !== CANARY_CCA_TICK_SPACING_Q96 ||
  V5_CANARY_SPEC.raiseFloorWei !== CANARY_CCA_REQUIRED_CURRENCY ||
  CANARY_CCA_UNIFORM_BLOCK_DELTA !== CANARY_AUCTION_DURATION_BLOCKS ||
  10_000_000n / CANARY_CCA_UNIFORM_BLOCK_DELTA !==
    CANARY_CCA_UNIFORM_MPS_PER_BLOCK
) {
  fail("reviewed CCA floor, tick, raise, or uniform-step derivation drifted");
}
// The recovered owner bid deliberately no longer uses the original 2x-floor cap: permissionless
// bids overtook it before the auction closed. Its exact replacement is authenticated independently
// by the raw owner-bid transaction/receipt, BidSubmitted event, stored bid and Phase-A index. Keep
// only the CCA relationships that remain true of that reviewed replacement here.
if (
  V5_CANARY_SPEC.bidMaxPriceQ96 <= CANARY_CCA_FLOOR_PRICE_Q96 ||
  V5_CANARY_SPEC.bidMaxPriceQ96 % CANARY_CCA_TICK_SPACING_Q96 !== 0n
) {
  fail(
    "reviewed recovered owner bid cap is not above the floor and tick-aligned",
  );
}

const canaryEvidence = {
  receiptOrder: canaryReceiptOrder,
  identities: {
    canarySender: EXPECTED_DEPLOYER,
    launchpad,
    hook,
    router,
    poolManager: POOL_MANAGER,
    hookrToken: HOOKR_TOKEN,
    burner,
  },
  timing: {
    shorten: {
      transaction: canaryTxShape(CANARY_TIMING_SHORTEN),
      calldata: {
        durationBlocks: timingShortenCall.args[0],
        claimDelay: timingShortenCall.args[1],
        migrationDelay: timingShortenCall.args[2],
      },
      event: timingShortenEvent,
    },
    restore: {
      transaction: canaryTxShape(CANARY_TIMING_RESTORE),
      calldata: {
        durationBlocks: timingRestoreCall.args[0],
        claimDelay: timingRestoreCall.args[1],
        migrationDelay: timingRestoreCall.args[2],
      },
      event: timingRestoreEvent,
    },
  },
  instant: {
    launch: {
      transaction: canaryTxShape(CANARY_INSTANT_LAUNCH),
      calldata: {
        args: instantLaunchCall.args[0],
        quote: instantLaunchCall.args[1],
        intentId: instantLaunchCall.args[2],
      },
      tokenEvent: instantTokenEvent,
      instantEvent: instantLaunchedEvent,
      initializeEvent: instantInitializeEvent,
    },
    buy: {
      transaction: canaryTxShape(CANARY_INSTANT_BUY),
      calldata: instantBuyCall.args[0],
      event: buySwapExecutedEvent,
      poolManagerEvent: buyPoolManagerEvent,
      flywheelEvent: instantFlywheelFeeEvent,
      transferEvent: buyTransferEvent,
    },
  },
  auction: {
    launch: {
      transaction: canaryTxShape(CANARY_AUCTION_LAUNCH),
      calldata: {
        args: auctionLaunchCall.args[0],
        quote: auctionLaunchCall.args[1],
        floorFdvWei: auctionLaunchCall.args[2],
        raiseFloorWei: auctionLaunchCall.args[3],
        reserveBps: auctionLaunchCall.args[4],
        intentId: auctionLaunchCall.args[5],
      },
      tokenEvent: auctionTokenEvent,
      startedEvent: auctionStartedEvent,
    },
    bid: {
      transaction: canaryTxShape(CANARY_AUCTION_BID),
      bidId: canaryBidId,
      calldata: {
        maxPriceQ96: auctionBidCall.args[0],
        amount: auctionBidCall.args[1],
        owner: auctionBidCall.args[2],
        hookData: auctionBidCall.args[3],
      },
      event: auctionBidEvent,
    },
    migrate: {
      transaction: canaryTxShape(CANARY_AUCTION_MIGRATE),
      calldata: {
        call: authenticatedPhaseBIndex.actions.migrateAuction.events.call,
      },
      migratedEvent,
      initializeEvent: auctionInitializeEvent,
      proceedsEvent: auctionProceedsEvent,
      currencySweptEvent,
    },
    exit: {
      transaction: canaryTxShape(CANARY_AUCTION_EXIT),
      calldata: { call: authenticatedPhaseBIndex.actions.exitBid.events.call },
      event: bidExitedEvent,
    },
    claimTokens: {
      transaction: canaryTxShape(CANARY_AUCTION_CLAIM),
      calldata: {
        call: auctionClaimKind,
        requestedBidIds: auctionClaimRequestedBidIds,
      },
      event: tokensClaimedEvent,
      events: ownerClaimEvents,
      transferEvent: claimTransferEvent,
      transferCount: ownerTransferEvents.length,
      transferLogIndexes: ownerTransferEvents.map((event) => event.logIndex),
    },
    proceedsClaim: {
      transaction: canaryTxShape(CANARY_AUCTION_PROCEEDS),
      calldata: {
        call: phaseBProceedsEvents.call,
        ...(phaseBProceedsNotApplicable
          ? { mode: phaseBProceedsEvents.mode }
          : {}),
      },
      claimEvent: proceedsClaimEvent,
      ...(phaseBProceedsNotApplicable
        ? { notApplicable: phaseBZeroProceedsProof }
        : {}),
    },
  },
  hookr: {
    launch: {
      transaction: canaryTxShape(CANARY_HOOKR_LAUNCH),
      calldata: {
        args: hookrLaunchCall.args[0],
        quote: hookrLaunchCall.args[1],
        intentId: hookrLaunchCall.args[2],
      },
      tokenEvent: hookrTokenEvent,
      instantEvent: hookrLaunchedEvent,
      initializeEvent: hookrInitializeEvent,
    },
    approve: {
      transaction: canaryTxShape(CANARY_HOOKR_APPROVE),
      calldata: {
        spender: hookrApproveCall.args[0],
        amount: hookrApproveCall.args[1],
      },
      event: hookrApprovalEvent,
    },
    buy: {
      transaction: canaryTxShape(CANARY_HOOKR_BUY),
      calldata: hookrBuyCall.args[0],
      event: hookrBuySwapExecutedEvent,
      poolManagerEvent: hookrBuyPoolManagerEvent,
      transferEvent: hookrBuyTransferEvent,
    },
  },
  flywheel: {
    collect: {
      transaction: canaryTxShape(CANARY_FLYWHEEL_COLLECT),
      event: flywheelCollectedEvent,
      claimedEvent: flywheelHookClaimedEvent,
    },
    burn: {
      transaction: canaryTxShape(CANARY_FLYWHEEL_BURN),
      calldata: {
        ethIn: flywheelBurnCall.args[0],
        minHookrOut: flywheelBurnCall.args[1],
      },
      burnedEvent: buybackBurnedEvent,
      deadTransferEvent: flywheelDeadTransferEvent,
    },
  },
  postconditions: {
    instantOpenPriceWei,
    hookrInstantOpenPriceWei,
    instantLaunch: instantLaunchState,
    hookrLaunch: hookrLaunchState,
    auctionConfig: {
      currency: auctionCurrency,
      token: auctionConfigToken,
      totalSupply: auctionTotalSupply,
      tokensRecipient: auctionTokensRecipient,
      fundsRecipient: auctionFundsRecipient,
      startBlock: auctionStartBlock,
      endBlock: auctionEndBlock,
      claimBlock: auctionClaimBlock,
      validationHook: auctionValidationHook,
      isGraduated: auctionGraduated,
    },
    auctionOutcome,
    auctionLaunch: auctionLaunchState,
    hookConfigs: {
      instant: instantPoolConfig,
      auction: auctionPoolConfig,
      hookr: hookrPoolConfig,
    },
    auctionCreatorProceedsWei,
    hookrAllowance,
    auctionTiming: {
      durationBlocks: finalAuctionDurationBlocks,
      claimDelay: finalClaimDelayBlocks,
      migrationDelay: finalMigrationDelayBlocks,
    },
  },
};

let canaryProof;
try {
  canaryProof = validateV5CanaryEvidence(canaryEvidence);
} catch (error) {
  fail(`v5 canary evidence: ${error.message}`);
}
if (
  getAddress(canaryProof.instantToken) !== canaryInstantToken ||
  getAddress(canaryProof.auctionToken) !== canaryAuctionToken ||
  getAddress(canaryProof.auction) !== canaryAuction ||
  getAddress(canaryProof.hookrPairToken) !== canaryHookrToken
) {
  fail("validated canary evidence disagrees with the indexed on-chain anchors");
}

// Finalization can take up to thirty minutes. Capture every mutable gate used by promotion at the
// authenticated state hash, then re-read the same surface from a fresh canonical safe/latest hash
// after finality. The write is refused if ownership, wiring, timing, fees, allowances, launch
// records, pool configs, auction state, blueprint state, or runtime code drifted while we waited.
const releaseGateCalls = [
  ["launchpad.contractName", launchpad, abi, "contractName", []],
  ["launchpad.contractVersion", launchpad, abi, "contractVersion", []],
  ["launchpad.hook", launchpad, abi, "hook", []],
  ["launchpad.auctionFactory", launchpad, abi, "auctionFactory", []],
  ["launchpad.hookrToken", launchpad, abi, "hookrToken", []],
  ["launchpad.hookrInstantOpenFdv", launchpad, abi, "hookrInstantOpenFdv", []],
  ["launchpad.owner", launchpad, abi, "owner", []],
  ["launchpad.creationFeeWei", launchpad, abi, "creationFeeWei", []],
  [
    "launchpad.auctionDurationBlocks",
    launchpad,
    abi,
    "auctionDurationBlocks",
    [],
  ],
  ["launchpad.claimDelayBlocks", launchpad, abi, "claimDelayBlocks", []],
  [
    "launchpad.migrationDelayBlocks",
    launchpad,
    abi,
    "migrationDelayBlocks",
    [],
  ],
  ["launchpad.blueprintsCount", launchpad, abi, "blueprintsCount", []],
  [
    "launchpad.instantOpenPriceWei",
    launchpad,
    launchpadEvidenceAbi,
    "instantOpenPriceWei",
    [],
  ],
  [
    "launchpad.hookrInstantOpenPrice",
    launchpad,
    launchpadEvidenceAbi,
    "hookrInstantOpenPrice",
    [],
  ],
  [
    "launchpad.instantIntent",
    launchpad,
    launchpadEvidenceAbi,
    "launchedByIntent",
    [EXPECTED_DEPLOYER, V5_CANARY_SPEC.instantIntentId],
  ],
  [
    "launchpad.auctionIntent",
    launchpad,
    launchpadEvidenceAbi,
    "launchedByIntent",
    [EXPECTED_DEPLOYER, V5_CANARY_SPEC.auctionIntentId],
  ],
  [
    "launchpad.hookrIntent",
    launchpad,
    launchpadEvidenceAbi,
    "launchedByIntent",
    [EXPECTED_DEPLOYER, V5_CANARY_SPEC.hookrIntentId],
  ],
  [
    "launchpad.instantLaunch",
    launchpad,
    launchpadEvidenceAbi,
    "getLaunch",
    [canaryInstantToken],
  ],
  [
    "launchpad.auctionLaunch",
    launchpad,
    launchpadEvidenceAbi,
    "getLaunch",
    [canaryAuctionToken],
  ],
  [
    "launchpad.hookrLaunch",
    launchpad,
    launchpadEvidenceAbi,
    "getLaunch",
    [canaryHookrToken],
  ],
  [
    "launchpad.creatorProceeds",
    launchpad,
    launchpadEvidenceAbi,
    "creatorProceedsWei",
    [canaryAuctionToken],
  ],
  ["hook.contractName", hook, abi, "contractName", []],
  ["hook.contractVersion", hook, abi, "contractVersion", []],
  ["hook.launchpad", hook, abi, "launchpad", []],
  ["hook.poolManager", hook, abi, "poolManager", []],
  ["hook.flywheelRecipient", hook, abi, "flywheelRecipient", []],
  [
    "hook.instantPoolConfig",
    hook,
    hookEvidenceAbi,
    "poolConfig",
    [instantLaunchedEvent.poolId],
  ],
  [
    "hook.auctionPoolConfig",
    hook,
    hookEvidenceAbi,
    "poolConfig",
    [migratedEvent.poolId],
  ],
  [
    "hook.hookrPoolConfig",
    hook,
    hookEvidenceAbi,
    "poolConfig",
    [hookrLaunchedEvent.poolId],
  ],
  ["router.contractName", router, abi, "contractName", []],
  ["router.contractVersion", router, abi, "contractVersion", []],
  ["router.hook", router, abi, "hook", []],
  ["router.poolManager", router, abi, "poolManager", []],
  ["router.quoteToken", router, abi, "quoteToken", []],
  ["burner.contractName", burner, abi, "contractName", []],
  ["burner.contractVersion", burner, abi, "contractVersion", []],
  ["burner.hook", burner, abi, "hook", []],
  ["burner.hookrToken", burner, abi, "hookrToken", []],
  ["burner.poolManager", burner, abi, "poolManager", []],
  ["burner.owner", burner, abi, "owner", []],
  ["burner.maxBuybackWei", burner, abi, "maxBuybackWei", []],
  ["burner.poolFee", burner, abi, "poolFee", []],
  ["burner.poolTickSpacing", burner, abi, "poolTickSpacing", []],
  [
    "hookr.allowance",
    HOOKR_TOKEN,
    erc20EvidenceAbi,
    "allowance",
    [EXPECTED_DEPLOYER, router],
  ],
  ["auction.currency", canaryAuction, auctionEvidenceAbi, "currency", []],
  ["auction.token", canaryAuction, auctionEvidenceAbi, "token", []],
  ["auction.totalSupply", canaryAuction, auctionEvidenceAbi, "totalSupply", []],
  [
    "auction.tokensRecipient",
    canaryAuction,
    auctionEvidenceAbi,
    "tokensRecipient",
    [],
  ],
  [
    "auction.fundsRecipient",
    canaryAuction,
    auctionEvidenceAbi,
    "fundsRecipient",
    [],
  ],
  ["auction.startBlock", canaryAuction, auctionEvidenceAbi, "startBlock", []],
  ["auction.endBlock", canaryAuction, auctionEvidenceAbi, "endBlock", []],
  ["auction.claimBlock", canaryAuction, auctionEvidenceAbi, "claimBlock", []],
  [
    "auction.validationHook",
    canaryAuction,
    auctionEvidenceAbi,
    "validationHook",
    [],
  ],
  ["auction.isGraduated", canaryAuction, auctionEvidenceAbi, "isGraduated", []],
  [
    "auction.outcome",
    canaryAuction,
    auctionEvidenceAbi,
    "lbpInitializationParams",
    [],
  ],
  [
    "auction.currencyRaised",
    canaryAuction,
    auctionEvidenceAbi,
    "currencyRaised",
    [],
  ],
  ...Array.from({ length: 5 }, (_, index) => [
    `blueprint.${index + 1}`,
    launchpad,
    blueprintEvidenceAbi,
    "getBlueprint",
    [index + 1],
  ]),
];
const releaseRuntimeAddresses = {
  launchpad,
  hook,
  router,
  burner,
  launchpadLib,
  poolManager: POOL_MANAGER,
  auctionFactory: AUCTION_FACTORY,
  hookrToken: HOOKR_TOKEN,
};
const readReleaseGateSnapshot = async (blockHash) => ({
  reads: Object.fromEntries(
    await Promise.all(
      releaseGateCalls.map(
        async ([label, address_, abi_, functionName, args_]) => [
          label,
          await client.readContract({
            address: address_,
            abi: abi_,
            functionName,
            args: args_,
            blockHash,
          }),
        ],
      ),
    ),
  ),
  runtime: Object.fromEntries(
    await Promise.all(
      Object.entries(releaseRuntimeAddresses).map(async ([label, address_]) => [
        label,
        await client.getCode({ address: address_, blockHash }),
      ]),
    ),
  ),
});
const initialReleaseGateSnapshot = await readReleaseGateSnapshot(
  stateHead.hash,
);

// EIP-1898 kept all reads on the original hash. First reject any reorg during verification. For a
// production/remote proof, then wait until the authenticated finalized head reaches this state
// height and confirm that its canonical header still has the exact hash we read. Robinhood serves
// state while the block is `safe` but not once it is historical/finalized, so the order matters.
const canonicalStateHead = await client.getBlock({
  blockNumber: stateHead.number,
});
if (!sameHex(canonicalStateHead.hash, stateHead.hash)) {
  fail(
    `pinned ${stateEvidenceTag} state evidence block was reorged during verification`,
  );
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
      const finalizedStateHeader = await client.getBlock({
        blockNumber: stateHead.number,
      });
      try {
        assertStateEvidenceFinalized(
          manifestFinalityHead,
          stateHead,
          finalizedStateHeader,
        );
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

// The finalized proof above authenticates the historical evidence snapshot. Promotion also needs
// a current-state safety decision: pin a fresh safe/latest header after the wait and require every
// mutable release gate to be byte-for-byte equal to the snapshot checked before the wait.
const freshReleaseStateHead = await client.getBlock({
  blockTag: stateEvidenceTag,
});
if (
  !freshReleaseStateHead?.hash ||
  freshReleaseStateHead.number === null ||
  freshReleaseStateHead.number === undefined
) {
  fail(`fresh ${stateEvidenceTag} release-gate head has no number or hash`);
}
if (freshReleaseStateHead.number < stateHead.number) {
  fail(
    `fresh ${stateEvidenceTag} release-gate head regressed behind the authenticated state head`,
  );
}
if (freshReleaseStateHead.number < manifestFinalityHead.number) {
  fail(
    `fresh ${stateEvidenceTag} release-gate head regressed behind the confirmed finality head`,
  );
}
const canonicalFreshReleaseStateHead = await client.getBlock({
  blockNumber: freshReleaseStateHead.number,
});
if (!sameHex(canonicalFreshReleaseStateHead.hash, freshReleaseStateHead.hash)) {
  fail(
    `fresh ${stateEvidenceTag} release-gate head is not canonical at its block number`,
  );
}
const freshReleaseGateSnapshot = await readReleaseGateSnapshot(
  freshReleaseStateHead.hash,
);
const canonicalFreshReleaseStateAfterReads = await client.getBlock({
  blockNumber: freshReleaseStateHead.number,
});
if (
  !sameHex(
    canonicalFreshReleaseStateAfterReads.hash,
    freshReleaseStateHead.hash,
  )
) {
  fail(
    `fresh ${stateEvidenceTag} release-gate head was reorged during re-authentication`,
  );
}
try {
  assert.deepStrictEqual(
    freshReleaseGateSnapshot,
    initialReleaseGateSnapshot,
    "mutable release gates drifted while state evidence was finalizing",
  );
} catch (error) {
  fail(error.message);
}

// The finality wait is also a local TOCTOU boundary. Re-authenticate the exact index and manifest
// bytes plus the Git head/worktree state before deriving any bytes that could be written.
assertPromotionWorkspaceUnchanged();

/* --------------------------------------------------------------- write patch */
const manifest = `export const CURRENT_RELEASE_MANIFEST = {
  manifestVersion: RELEASE_MANIFEST_SCHEMA_VERSION,
  chainId: 4663,
  version: 5,
  productionAllowed: true,
  deployBlock: ${deployBlock}n,
  capabilities: {
    launchModes: ["instant", "bonded"],
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
  flywheel: {
    burner: "${burner}",
    runtimeCodeHash: "${burnerHash}",
    hookrToken: "${HOOKR_TOKEN}",
    feePips: ${FLYWHEEL_FEE_PIPS},
  },
  evidence: {
    sourceCommit: "${sourceCommit}",
    canaryOperatorCommit: "${canaryOperatorCommit}",
    canaryRecoveryCommit: "${canaryRecoveryCommit}",
    canaryPhaseAIndexSha256: "${phaseAIndexSnapshot.sha256}",
    canaryPhaseBIndexSha256: "${phaseBIndexSnapshot.sha256}",
    librarySourceCommit: "${librarySourceCommit}",
    deploymentReceipts: {
      library: "${receipts.launchpadLib}",
      burner: "${receipts.burner}",
      burnerSetHook: "${receipts.burnerSetHook}",
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
      kind: "all_lanes_and_flywheel_round_trip_v5",
      instantLaunch: "${receipts.canary.instantLaunch}",
      auctionTimingShorten: "${receipts.canary.auctionTimingShorten}",
      instantRouterBuy: "${receipts.canary.instantRouterBuy}",
      auctionLaunch: "${receipts.canary.auctionLaunch}",
      auctionTimingRestore: "${receipts.canary.auctionTimingRestore}",
      auctionBid: "${receipts.canary.auctionBid}",
      hookrLaunch: "${receipts.canary.hookrLaunch}",
      hookrApprove: "${receipts.canary.hookrApprove}",
      hookrBuy: "${receipts.canary.hookrBuy}",
      auctionMigrate: "${receipts.canary.auctionMigrate}",
      auctionExit: "${receipts.canary.auctionExit}",
      auctionClaim: "${receipts.canary.auctionClaim}",
      auctionProceedsClaim: "${receipts.canary.auctionProceedsClaim}",
      flywheelCollect: "${receipts.canary.flywheelCollect}",
      flywheelBurn: "${receipts.canary.flywheelBurn}",
    },
  },
} as const satisfies HookrReleaseManifest;`;

const source = manifestSourceSnapshot.bytes.toString("utf8");
let patchedSource;
try {
  // The outgoing generation-4 CURRENT is retained verbatim as RETAINED_GENERATION_4_MANIFEST and
  // registered in READ_RELEASES in the same rewrite — promotion may never orphan the addresses
  // that read old tokens.
  patchedSource = retireAndReplaceCurrentReleaseManifest(source, manifest);
} catch (error) {
  fail(`${error.message} in ${MANIFEST_PATH}`);
}

console.log(
  "All live-block, causal-order, five-blueprint, up-to-15-receipt all-lane canary (timing + instant + auction + HOOKR pair + flywheel), wiring, linkage, and pinned-block checks passed.",
);
console.log(
  `  launchpadLib ${launchpadLib} (linked at ${linkCount} call sites)`,
);
console.log(`  launchpad ${launchpad}`);
console.log(`  hook      ${hook}`);
console.log(`  router    ${router}`);
console.log(
  `  burner    ${burner} (flywheel, ${FLYWHEEL_FEE_PIPS} pips on ETH pairs)`,
);
console.log(`  HOOKR     ${HOOKR_TOKEN}`);
console.log(`  CCA factory ${AUCTION_FACTORY}`);
console.log(`  canary instant token ${canaryProof.instantToken}`);
console.log(
  `  canary auction token ${canaryProof.auctionToken} (auction ${canaryProof.auction})`,
);
console.log(`  canary hookr pair token ${canaryProof.hookrPairToken}`);
console.log(
  `  launchpad reviewed template ${runtimeProofs.launchpad.normalizedTemplateHash}`,
);
console.log(
  `  hook reviewed template      ${runtimeProofs.hook.normalizedTemplateHash}`,
);
console.log(
  `  router reviewed template    ${runtimeProofs.router.normalizedTemplateHash}`,
);
console.log(
  `  burner reviewed template    ${runtimeProofs.burner.normalizedTemplateHash}`,
);
console.log(
  `  library reviewed template   ${runtimeProofs.launchpadLib.normalizedTemplateHash}`,
);
console.log(
  `  receipts finalized through ${finalizedHead.number} (${finalizedHead.hash}); state ${stateEvidenceTag} #${stateHead.number} finalized through ${manifestFinalityHead.number} (${stateHead.hash})`,
);
console.log(`  live launchpad deploy block ${deployBlock}`);
console.log(`  source commit ${sourceCommit}`);
console.log(`  canary operator ${canaryOperatorCommit}`);
console.log(`  canary recovery ${canaryRecoveryCommit}`);
console.log(`  phase A index sha256 ${phaseAIndexSnapshot.sha256}`);
console.log(`  phase B index sha256 ${phaseBIndexSnapshot.sha256}`);

if (DRY_RUN) {
  console.log("\n--dry-run: manifest not written. Generated object:\n");
  console.log(manifest);
  process.exit(0);
}

// Close the last local race immediately before mutation. This deliberately rejects even a
// same-byte inode replacement and re-runs canonical/no-symlink path resolution.
assertPromotionWorkspaceUnchanged();
writeFileSync(manifestSourceSnapshot.path, patchedSource);
// These must match RELEASE.md section 4. They drifted once already — claiming a test edit that
// is not needed, and naming an evidence directory that does not exist.
console.log(
  `\nPatched ${MANIFEST_PATH} (v4 retained as RETAINED_GENERATION_4_MANIFEST). Next:`,
);
console.log(
  "  1. npm test && npm run lint && npx tsc --noEmit && npm run build",
);
console.log(
  "     (release-manifest.test.ts needs no edit: it asserts relationships, not a snapshot",
);
console.log(
  "      of the open/closed state, so it passes before and after promotion)",
);
console.log("  2. (cd contracts && forge test && forge build --sizes)");
console.log(
  "  3. archive deploy + four Phase-A Forge artifacts + the raw owner-bid pair + both raw timing pairs",
);
console.log(
  "     + six Phase-B raw action pairs (aliases may share bytes) + the hash-bound indexes under contracts/evidence/v5/",
);
console.log(
  "  4. commit (sourceCommit is deployed contracts; canaryOperatorCommit is original canary; canaryRecoveryCommit is split recovery)",
);
