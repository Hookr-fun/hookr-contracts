import {
  getAddress,
  keccak256,
  parseAbi,
  stringToHex,
  zeroAddress,
} from "viem";

export const UTILITY_CORE_RELEASE_ID = "hookr-4663-v4";
export const UTILITY_CORE_VERSION = 4;
export const UTILITY_CORE_CHAIN_ID = 4663;
export const UTILITY_CORE_EXPECTED_DEPLOYER = getAddress(
  "0x5a52D4B820Ae7F02880d270562950918ACb14aA2",
);
export const UTILITY_CORE_CANARY_INTENT = keccak256(
  stringToHex("hookr.v4.canary.instant.all-five.1"),
);
export const UTILITY_CORE_CANARY_DEPOSIT_WEI = 10_000_000_000_000_000n;
export const UTILITY_CORE_CANARY_POOL_SUPPLY_BPS = 5_000;

export const utilityCoreLaunchpadAbi = parseAbi([
  "function previewInstantLaunch(uint256 ethIn,uint16 poolSupplyBps) view returns (uint256 tokensInPool,uint96 openPriceWei,uint160 sqrtPriceX96,uint256 openFdvWei,uint8 err)",
  "function launchedByIntent(address creator,bytes32 intentId) view returns (address token)",
  "function getLaunch(address token) view returns ((address token,address creator,uint40 launchBlock,uint32 blueprintId,bool graduated,uint96 basePriceWei,uint96 targetWei,uint96 reserveWei,uint128 soldTokens,uint40 graduatedAtBlock,uint160 sqrtPriceX96AtGraduation,bytes32 poolId,(uint32 guardBlocks,uint16 maxBuyBps,uint24 snipeTaxPips,uint24 baseFeePips,uint24 maxFeePips,uint16 surgeSens,uint16 burnBps,uint96 burnTriggerWei,uint16 lpBps,uint16 potBps,uint32 potEveryNBuys,uint96 potMinBuyWei) hookParams) launch)",
]);

function sameHex(left, right) {
  return typeof left === "string" &&
    typeof right === "string" &&
    left.toLowerCase() === right.toLowerCase();
}

function runtimeHash(value, label) {
  const hash = String(value ?? "").toLowerCase();
  if (!/^0x[0-9a-f]{64}$/.test(hash) || /^0x0+$/.test(hash)) {
    throw new Error(`${label} is not a nonzero runtime codehash`);
  }
  return hash;
}

function tupleField(value, name, index) {
  const named = value && typeof value === "object" ? value[name] : undefined;
  if (named !== undefined) return named;
  return Array.isArray(value) ? value[index] : undefined;
}

function integer(value, label) {
  try {
    return BigInt(value);
  } catch {
    throw new Error(`${label} is not an integer`);
  }
}

function requireInteger(value, expected, label) {
  const actual = integer(value, label);
  if (actual !== expected) throw new Error(`${label}: expected ${expected}, read ${actual}`);
  return actual;
}

function requireAddress(value, expected, label) {
  let actual;
  try {
    actual = getAddress(value);
  } catch {
    throw new Error(`${label} is not an address`);
  }
  if (actual !== expected) throw new Error(`${label}: expected ${expected}, read ${actual}`);
  return actual;
}

export function validateUtilityCoreManifest({
  manifest,
  releaseGateBlockers,
  releaseIdOf,
  expectedLaunchpadAddress,
  expectedLaunchpadRuntimeHash,
}) {
  if (!manifest || typeof manifest !== "object") {
    throw new Error("current core release manifest is unavailable");
  }
  if (Number(manifest.chainId) !== UTILITY_CORE_CHAIN_ID) {
    throw new Error("current core release is not on Robinhood Chain 4663");
  }
  if (Number(manifest.version) !== UTILITY_CORE_VERSION) {
    throw new Error("current core release is not generation 4");
  }
  const releaseId = typeof releaseIdOf === "function"
    ? releaseIdOf(manifest)
    : `hookr-${manifest.chainId}-v${manifest.version}`;
  if (releaseId !== UTILITY_CORE_RELEASE_ID) {
    throw new Error(`current core release id is ${releaseId}, expected ${UTILITY_CORE_RELEASE_ID}`);
  }
  if (manifest.productionAllowed !== true) {
    throw new Error("current generation-4 core release is not production-enabled");
  }
  if (typeof releaseGateBlockers !== "function") {
    throw new Error("core release gate validator is unavailable");
  }
  const blockers = releaseGateBlockers(manifest);
  if (!Array.isArray(blockers) || blockers.length !== 0) {
    throw new Error(`current generation-4 core release gate is closed: ${Array.isArray(blockers) ? blockers.join("; ") : "invalid gate result"}`);
  }
  const modes = manifest.capabilities?.launchModes;
  if (
    !Array.isArray(modes) ||
    modes.length !== 2 ||
    new Set(modes).size !== 2 ||
    !modes.includes("curve") ||
    !modes.includes("instant")
  ) {
    throw new Error("current generation-4 core must evidence exactly curve and instant launch modes");
  }

  let manifestLaunchpad;
  let assertedLaunchpad;
  try {
    manifestLaunchpad = getAddress(manifest.contracts?.launchpad?.address);
    assertedLaunchpad = getAddress(expectedLaunchpadAddress);
  } catch {
    throw new Error("generation-4 launchpad address is missing or malformed");
  }
  if (manifestLaunchpad !== assertedLaunchpad) {
    throw new Error(`launchpad assertion ${assertedLaunchpad} does not match current manifest ${manifestLaunchpad}`);
  }
  const manifestHash = runtimeHash(
    manifest.contracts?.launchpad?.runtimeCodeHash ?? manifest.contracts?.launchpad?.runtimeHash,
    "manifest launchpad runtime hash",
  );
  const assertedHash = runtimeHash(expectedLaunchpadRuntimeHash, "asserted launchpad runtime hash");
  if (!sameHex(manifestHash, assertedHash)) {
    throw new Error(`launchpad codehash assertion ${assertedHash} does not match current manifest ${manifestHash}`);
  }

  return Object.freeze({
    releaseId,
    version: UTILITY_CORE_VERSION,
    launchpad: manifestLaunchpad,
    launchpadRuntimeHash: manifestHash,
  });
}

function validateInstantPreview(preview) {
  requireInteger(tupleField(preview, "tokensInPool", 0), 500_000_000_000_000_000_000_000_000n, "v4 instant preview pool supply");
  requireInteger(tupleField(preview, "openPriceWei", 1), 20_000_000n, "v4 instant preview opening price");
  const sqrtPriceX96 = integer(tupleField(preview, "sqrtPriceX96", 2), "v4 instant preview sqrt price");
  if (sqrtPriceX96 <= 0n) throw new Error("v4 instant preview sqrt price is zero");
  requireInteger(tupleField(preview, "openFdvWei", 3), 20_000_000_000_000_000n, "v4 instant preview FDV");
  requireInteger(tupleField(preview, "err", 4), 0n, "v4 instant preview error");
  return { sqrtPriceX96 };
}

function validateAllFiveCanary(launch, token, preview) {
  requireAddress(tupleField(launch, "token", 0), token, "v4 core canary token");
  requireAddress(tupleField(launch, "creator", 1), UTILITY_CORE_EXPECTED_DEPLOYER, "v4 core canary creator");
  const launchBlock = integer(tupleField(launch, "launchBlock", 2), "v4 core canary launch block");
  if (launchBlock <= 0n) throw new Error("v4 core canary launch block is zero");
  requireInteger(tupleField(launch, "blueprintId", 3), 0n, "v4 core canary blueprint");
  if (tupleField(launch, "graduated", 4) !== true) throw new Error("v4 core canary is not graduated");
  requireInteger(tupleField(launch, "basePriceWei", 5), 20_000_000n, "v4 core canary opening price");
  requireInteger(tupleField(launch, "targetWei", 6), UTILITY_CORE_CANARY_DEPOSIT_WEI, "v4 core canary deposit");
  requireInteger(tupleField(launch, "reserveWei", 7), 0n, "v4 core canary reserve");
  requireInteger(tupleField(launch, "soldTokens", 8), 0n, "v4 core canary curve sales");
  requireInteger(tupleField(launch, "graduatedAtBlock", 9), launchBlock, "v4 core canary instant graduation block");
  requireInteger(tupleField(launch, "sqrtPriceX96AtGraduation", 10), preview.sqrtPriceX96, "v4 core canary sqrt price");
  const poolId = tupleField(launch, "poolId", 11);
  if (typeof poolId !== "string" || !/^0x[0-9a-fA-F]{64}$/.test(poolId) || /^0x0+$/.test(poolId)) {
    throw new Error("v4 core canary pool id is missing");
  }

  const params = tupleField(launch, "hookParams", 12);
  requireInteger(tupleField(params, "guardBlocks", 0), 200n, "v4 core canary guard blocks");
  requireInteger(tupleField(params, "maxBuyBps", 1), 1_000n, "v4 core canary max buy");
  requireInteger(tupleField(params, "snipeTaxPips", 2), 200_000n, "v4 core canary snipe tax");
  requireInteger(tupleField(params, "baseFeePips", 3), 3_000n, "v4 core canary base fee");
  requireInteger(tupleField(params, "maxFeePips", 4), 30_000n, "v4 core canary max fee");
  requireInteger(tupleField(params, "surgeSens", 5), 5n, "v4 core canary surge sensitivity");
  requireInteger(tupleField(params, "burnBps", 6), 100n, "v4 core canary burn share");
  requireInteger(tupleField(params, "burnTriggerWei", 7), 0n, "v4 core canary burn trigger");
  requireInteger(tupleField(params, "lpBps", 8), 25n, "v4 core canary LP share");
  requireInteger(tupleField(params, "potBps", 9), 50n, "v4 core canary pot share");
  requireInteger(tupleField(params, "potEveryNBuys", 10), 10n, "v4 core canary pot interval");
  requireInteger(tupleField(params, "potMinBuyWei", 11), 1_000_000_000_000_000n, "v4 core canary pot minimum");
}

export async function verifyUtilityCorePrerequisite({
  client,
  manifest,
  releaseGateBlockers,
  releaseIdOf,
  expectedLaunchpadAddress,
  expectedLaunchpadRuntimeHash,
  blockTag = "safe",
  pinnedBlock,
}) {
  const identity = validateUtilityCoreManifest({
    manifest,
    releaseGateBlockers,
    releaseIdOf,
    expectedLaunchpadAddress,
    expectedLaunchpadRuntimeHash,
  });
  if ((await client.getChainId()) !== UTILITY_CORE_CHAIN_ID) {
    throw new Error("RPC is not Robinhood Chain 4663");
  }
  const block = pinnedBlock ?? await client.getBlock({ blockTag });
  if (!block?.hash || block.number === undefined || block.number === null) {
    throw new Error(`${blockTag} core prerequisite block is unavailable`);
  }
  const at = { blockHash: block.hash };
  const code = await client.getCode({ address: identity.launchpad, ...at });
  if (!code || code === "0x") throw new Error("generation-4 launchpad has no runtime at the pinned block");
  const liveRuntimeHash = keccak256(code);
  if (!sameHex(liveRuntimeHash, identity.launchpadRuntimeHash)) {
    throw new Error(`generation-4 launchpad live runtime ${liveRuntimeHash} does not match manifest ${identity.launchpadRuntimeHash}`);
  }

  const previewRaw = await client.readContract({
    address: identity.launchpad,
    abi: utilityCoreLaunchpadAbi,
    functionName: "previewInstantLaunch",
    args: [UTILITY_CORE_CANARY_DEPOSIT_WEI, UTILITY_CORE_CANARY_POOL_SUPPLY_BPS],
    ...at,
  });
  const preview = validateInstantPreview(previewRaw);
  const tokenRaw = await client.readContract({
    address: identity.launchpad,
    abi: utilityCoreLaunchpadAbi,
    functionName: "launchedByIntent",
    args: [UTILITY_CORE_EXPECTED_DEPLOYER, UTILITY_CORE_CANARY_INTENT],
    ...at,
  });
  let token;
  try {
    token = getAddress(tokenRaw);
  } catch {
    throw new Error("generation-4 fixed all-five canary intent returned a malformed token");
  }
  if (token === zeroAddress) throw new Error("generation-4 fixed all-five canary is missing");
  const launch = await client.readContract({
    address: identity.launchpad,
    abi: utilityCoreLaunchpadAbi,
    functionName: "getLaunch",
    args: [token],
    ...at,
  });
  validateAllFiveCanary(launch, token, preview);

  const canonical = await client.getBlock({ blockNumber: block.number });
  if (!canonical?.hash || !sameHex(canonical.hash, block.hash)) {
    throw new Error(`pinned ${blockTag} core prerequisite block was reorged`);
  }
  return Object.freeze({
    ...identity,
    blockNumber: block.number,
    blockHash: block.hash,
    canaryToken: token,
    canaryIntent: UTILITY_CORE_CANARY_INTENT,
    liveRuntimeHash,
  });
}
