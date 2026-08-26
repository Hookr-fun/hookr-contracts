const ADDRESS = /^0x[a-fA-F0-9]{40}$/;
const BYTES32 = /^0x[a-fA-F0-9]{64}$/;
const COMMIT = /^[a-fA-F0-9]{40}$/;
const HTTPS_URL = /^https:\/\//;

export const HOOK_FLAG_BITS = Object.freeze({
  beforeInitialize: 13,
  afterInitialize: 12,
  beforeAddLiquidity: 11,
  afterAddLiquidity: 10,
  beforeRemoveLiquidity: 9,
  afterRemoveLiquidity: 8,
  beforeSwap: 7,
  afterSwap: 6,
  beforeDonate: 5,
  afterDonate: 4,
  beforeSwapReturnsDelta: 3,
  afterSwapReturnsDelta: 2,
  afterAddLiquidityReturnsDelta: 1,
  afterRemoveLiquidityReturnsDelta: 0,
});

export const EXTERNAL_HOOK_STATUSES = Object.freeze([
  "source-only",
  "testnet-verified",
  "production-verified",
  "listing-submitted",
  "listed",
]);

const PRODUCTION_STATUSES = new Set(["production-verified", "listing-submitted", "listed"]);
const SWAP_ACCESS = new Set(["none", "temporal", "allowlist", "governance", "other"]);
const PARTNER_TRACKS = new Set([
  "hook_publication",
  "hook_token_launch",
  "existing_token_pool",
  "launchpad_sdk",
  "hook_generator",
  "executor_adapter",
]);
const NON_PRODUCTION_ADDRESSES = new Set([
  "0x0000000000000000000000000000000000000000",
  "0x000000000000000000000000000000000000dead",
]);
const ZERO_BYTES32 = `0x${"0".repeat(64)}`;

function object(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function at(value, key) {
  return object(value) ? value[key] : undefined;
}

function requireString(errors, value, path, { pattern, maxLength } = {}) {
  if (typeof value !== "string" || value.length === 0) {
    errors.push(`${path} must be a non-empty string`);
    return;
  }
  if (pattern && !pattern.test(value)) errors.push(`${path} has an invalid format`);
  if (maxLength && value.length > maxLength) errors.push(`${path} exceeds ${maxLength} characters`);
}

function requireBoolean(errors, value, path) {
  if (typeof value !== "boolean") errors.push(`${path} must be a boolean`);
}

function requireDate(errors, value, path) {
  requireString(errors, value, path);
  if (typeof value === "string" && !Number.isFinite(Date.parse(value))) {
    errors.push(`${path} must be an ISO date-time`);
  }
}

export function decodeHookFlags(hookAddress) {
  if (!ADDRESS.test(hookAddress)) throw new Error("hook address must be a 20-byte 0x address");
  const lowBits = BigInt(hookAddress) & ((1n << 14n) - 1n);
  return Object.fromEntries(
    Object.entries(HOOK_FLAG_BITS).map(([name, bit]) => [name, (lowBits & (1n << BigInt(bit))) !== 0n]),
  );
}

export function hookFlagsMatchAddress(hookAddress, declaredFlags) {
  const decoded = decodeHookFlags(hookAddress);
  return Object.keys(HOOK_FLAG_BITS).every((name) => decoded[name] === declaredFlags?.[name]);
}

export function validateExternalHookManifest(manifest, policy) {
  const errors = [];
  if (!object(manifest)) return ["manifest must be an object"];
  if (!object(policy) || !object(policy.chains)) return ["Uniswap policy is missing chain data"];

  if (manifest.schemaVersion !== "hookr.external-hook.v1") {
    errors.push("schemaVersion must be hookr.external-hook.v1");
  }
  requireString(errors, manifest.slug, "slug", {
    pattern: /^[a-z0-9]+(?:-[a-z0-9]+)*$/,
    maxLength: 80,
  });
  requireString(errors, manifest.name, "name", { maxLength: 100 });
  requireString(errors, manifest.summary, "summary", { maxLength: 500 });
  if (!EXTERNAL_HOOK_STATUSES.includes(manifest.status)) errors.push("status is not supported");
  if (!new Set(["composable-blueprint", "standalone-hook-product"]).has(manifest.integrationMode)) {
    errors.push("integrationMode is not supported");
  }

  requireString(errors, at(manifest.author, "github"), "author.github", {
    pattern: /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$/,
  });
  requireString(errors, at(manifest.source, "repository"), "source.repository", {
    pattern: HTTPS_URL,
  });
  requireString(errors, at(manifest.source, "pinnedCommit"), "source.pinnedCommit", {
    pattern: COMMIT,
  });
  requireString(errors, at(manifest.source, "hookContract"), "source.hookContract");
  if (!Array.isArray(at(manifest.source, "contracts")) || manifest.source.contracts.length === 0) {
    errors.push("source.contracts must contain at least one contract path");
  } else if (!manifest.source.contracts.includes(manifest.source.hookContract)) {
    errors.push("source.contracts must include source.hookContract");
  }

  const supportedTracks = at(manifest.integration, "supportedTracks");
  if (!Array.isArray(supportedTracks) || supportedTracks.length === 0) {
    errors.push("integration.supportedTracks must contain at least one partner track");
  } else {
    for (const track of supportedTracks) {
      if (!PARTNER_TRACKS.has(track)) {
        errors.push(`integration.supportedTracks contains unsupported track: ${track}`);
      }
    }
    if (new Set(supportedTracks).size !== supportedTracks.length) {
      errors.push("integration.supportedTracks cannot contain duplicates");
    }
  }

  const flags = at(manifest.uniswapClassification, "flags");
  for (const flag of Object.keys(HOOK_FLAG_BITS)) requireBoolean(errors, at(flags, flag), `uniswapClassification.flags.${flag}`);
  const properties = at(manifest.uniswapClassification, "properties");
  for (const property of ["dynamicFee", "upgradeable", "requiresCustomSwapData", "vanillaSwap"]) {
    requireBoolean(errors, at(properties, property), `uniswapClassification.properties.${property}`);
  }
  if (!SWAP_ACCESS.has(at(properties, "swapAccess"))) {
    errors.push("uniswapClassification.properties.swapAccess is not supported");
  }

  const deployments = manifest.deployments;
  if (!Array.isArray(deployments)) {
    errors.push("deployments must be an array");
    return errors;
  }
  if (manifest.status === "source-only" && deployments.length !== 0) {
    errors.push("source-only manifests cannot claim deployments");
  }
  if (manifest.status !== "source-only" && deployments.length === 0) {
    errors.push(`${manifest.status} manifests must include a deployment`);
  }

  const deploymentIds = new Set();
  const deploymentAddresses = new Set();
  for (const [index, deployment] of deployments.entries()) {
    const path = `deployments[${index}]`;
    requireString(errors, deployment.deploymentId, `${path}.deploymentId`, {
      pattern: /^[a-z0-9]+(?:-[a-z0-9]+)*$/,
    });
    if (deploymentIds.has(deployment.deploymentId)) errors.push(`${path}.deploymentId is duplicated`);
    deploymentIds.add(deployment.deploymentId);

    const chain = policy.chains[deployment.chain];
    if (deployment.environment === "mainnet" && !chain) {
      errors.push(`${path}.chain is not in the pinned Uniswap Hooklist chain set`);
    }
    if (!Number.isInteger(deployment.chainId) || deployment.chainId < 1) {
      errors.push(`${path}.chainId must be a positive integer`);
    } else if (deployment.environment === "mainnet" && chain && chain.chainId !== deployment.chainId) {
      errors.push(`${path}.chainId does not match policy for ${deployment.chain}`);
    }
    if (!new Set(["testnet", "mainnet"]).has(deployment.environment)) {
      errors.push(`${path}.environment must be testnet or mainnet`);
    }
    if (manifest.status === "testnet-verified" && deployment.environment !== "testnet") {
      errors.push(`${path} must be a testnet deployment for status testnet-verified`);
    }

    for (const field of ["hookAddress", "deployerAddress", "poolManagerAddress"]) {
      requireString(errors, deployment[field], `${path}.${field}`, { pattern: ADDRESS });
      if (
        typeof deployment[field] === "string" &&
        NON_PRODUCTION_ADDRESSES.has(deployment[field].toLowerCase())
      ) {
        errors.push(`${path}.${field} cannot be a zero or burn address`);
      }
    }
    requireString(errors, deployment.transactionHash, `${path}.transactionHash`, { pattern: BYTES32 });
    requireString(errors, deployment.runtimeCodeHash, `${path}.runtimeCodeHash`, { pattern: BYTES32 });
    requireString(errors, deployment.verifiedSourceCommit, `${path}.verifiedSourceCommit`, {
      pattern: COMMIT,
    });
    if (deployment.transactionHash?.toLowerCase() === ZERO_BYTES32) {
      errors.push(`${path}.transactionHash cannot be zero`);
    }
    if (deployment.runtimeCodeHash?.toLowerCase() === ZERO_BYTES32) {
      errors.push(`${path}.runtimeCodeHash cannot be zero`);
    }
    if (!Number.isInteger(deployment.blockNumber) || deployment.blockNumber < 1) {
      errors.push(`${path}.blockNumber must be a positive integer`);
    }
    requireBoolean(errors, deployment.sourceVerified, `${path}.sourceVerified`);
    requireString(errors, deployment.sourceVerificationUrl, `${path}.sourceVerificationUrl`, {
      pattern: HTTPS_URL,
    });
    if (deployment.verifiedSourceCommit !== manifest.source.pinnedCommit) {
      errors.push(`${path}.verifiedSourceCommit must equal source.pinnedCommit`);
    }
    if (!Number.isInteger(deployment.observedBlock) || deployment.observedBlock < deployment.blockNumber) {
      errors.push(`${path}.observedBlock must be at or after the deployment block`);
    }
    requireDate(errors, deployment.observedAt, `${path}.observedAt`);
    if (PRODUCTION_STATUSES.has(manifest.status) && deployment.sourceVerified !== true) {
      errors.push(`${path}.sourceVerified must be true for ${manifest.status}`);
    }

    if (ADDRESS.test(deployment.hookAddress ?? "")) {
      const key = `${deployment.chain}:${deployment.hookAddress.toLowerCase()}`;
      if (deploymentAddresses.has(key)) errors.push(`${path}.hookAddress is duplicated on ${deployment.chain}`);
      deploymentAddresses.add(key);
      if (!hookFlagsMatchAddress(deployment.hookAddress, flags)) {
        errors.push(`${path}.hookAddress permission bits do not match uniswapClassification.flags`);
      }
    }

    if (!Array.isArray(deployment.pools) || deployment.pools.length === 0) {
      errors.push(`${path}.pools must contain at least one initialized pool`);
    } else {
      for (const [poolIndex, pool] of deployment.pools.entries()) {
        const poolPath = `${path}.pools[${poolIndex}]`;
        requireString(errors, pool.poolId, `${poolPath}.poolId`, { pattern: BYTES32 });
        requireString(errors, pool.routingFormPoolReference, `${poolPath}.routingFormPoolReference`, {
          pattern: /^0x(?:[a-fA-F0-9]{40}|[a-fA-F0-9]{64})$/,
        });
        requireString(errors, pool.initializationTransactionHash, `${poolPath}.initializationTransactionHash`, {
          pattern: BYTES32,
        });
        if (!Number.isInteger(pool.initializationBlockNumber) || pool.initializationBlockNumber < 1) {
          errors.push(`${poolPath}.initializationBlockNumber must be a positive integer`);
        }
        requireString(errors, pool.liquidityTransactionHash, `${poolPath}.liquidityTransactionHash`, {
          pattern: BYTES32,
        });
        if (!Number.isInteger(pool.liquidityBlockNumber) || pool.liquidityBlockNumber < 1) {
          errors.push(`${poolPath}.liquidityBlockNumber must be a positive integer`);
        }
        requireString(errors, pool.liquidityEvidenceUrl, `${poolPath}.liquidityEvidenceUrl`, {
          pattern: HTTPS_URL,
        });
        requireDate(errors, pool.observedAt, `${poolPath}.observedAt`);
        if (pool.poolId?.toLowerCase() === ZERO_BYTES32) errors.push(`${poolPath}.poolId cannot be zero`);
        if (pool.initializationTransactionHash?.toLowerCase() === ZERO_BYTES32) {
          errors.push(`${poolPath}.initializationTransactionHash cannot be zero`);
        }
        if (pool.liquidityTransactionHash?.toLowerCase() === ZERO_BYTES32) {
          errors.push(`${poolPath}.liquidityTransactionHash cannot be zero`);
        }
        if (pool.initializationBlockNumber < deployment.blockNumber) {
          errors.push(`${poolPath}.initializationBlockNumber cannot predate the hook deployment`);
        }
        if (pool.liquidityBlockNumber < pool.initializationBlockNumber) {
          errors.push(`${poolPath}.liquidityBlockNumber cannot predate pool initialization`);
        }
        if (deployment.observedBlock < pool.liquidityBlockNumber) {
          errors.push(`${path}.observedBlock must include the recorded liquidity block`);
        }
      }
    }

    const eligibility = deployment.uniswapEligibility;
    for (const field of [
      "modifiesOrBypassesProtocolFee",
      "requiresRouterModificationForOrdinarySwaps",
      "knownMaliciousOrExtractiveBehavior",
    ]) {
      requireBoolean(errors, at(eligibility, field), `${path}.uniswapEligibility.${field}`);
    }
    requireDate(errors, at(eligibility, "attestedAt"), `${path}.uniswapEligibility.attestedAt`);
    requireString(errors, at(eligibility, "attestedBy"), `${path}.uniswapEligibility.attestedBy`);

    const hooklistStatus = at(at(deployment, "uniswap"), "hooklist")?.status;
    const routingStatus = at(at(deployment, "uniswap"), "routing")?.status;
    if (!new Set(["not-submitted", "pending", "listed", "rejected"]).has(hooklistStatus)) {
      errors.push(`${path}.uniswap.hooklist.status is not supported`);
    }
    if (!new Set(["not-evaluated", "automatic", "review-required", "submitted", "allowlisted", "rejected"]).has(routingStatus)) {
      errors.push(`${path}.uniswap.routing.status is not supported`);
    }
  }

  if (
    PRODUCTION_STATUSES.has(manifest.status) &&
    !deployments.some((deployment) => deployment.environment === "mainnet")
  ) {
    errors.push(`${manifest.status} manifests must include at least one mainnet deployment`);
  }

  return errors;
}

export function assertExternalHookManifest(manifest, policy) {
  const errors = validateExternalHookManifest(manifest, policy);
  if (errors.length) throw new Error(`Invalid external hook manifest:\n- ${errors.join("\n- ")}`);
  return manifest;
}
