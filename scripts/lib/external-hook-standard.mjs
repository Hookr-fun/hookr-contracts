const ADDRESS = /^0x[a-fA-F0-9]{40}$/;
const BYTES32 = /^0x[a-fA-F0-9]{64}$/;
const COMMIT = /^[a-fA-F0-9]{40}$/;
const EXTERNAL_HOOK_V2_SCHEMA = "https://hookr.fun/schemas/external-hook.v2.json";

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
const REGULAR_CALLBACKS = Object.freeze([
  "beforeInitialize",
  "afterInitialize",
  "beforeAddLiquidity",
  "afterAddLiquidity",
  "beforeRemoveLiquidity",
  "afterRemoveLiquidity",
  "beforeSwap",
  "afterSwap",
  "beforeDonate",
  "afterDonate",
]);
const RETURN_DELTA_REQUIREMENTS = Object.freeze({
  beforeSwapReturnsDelta: "beforeSwap",
  afterSwapReturnsDelta: "afterSwap",
  afterAddLiquidityReturnsDelta: "afterAddLiquidity",
  afterRemoveLiquidityReturnsDelta: "afterRemoveLiquidity",
});
const ROUTE_QUADRANTS = Object.freeze([
  "exactInputZeroForOne",
  "exactInputOneForZero",
  "exactOutputZeroForOne",
  "exactOutputOneForZero",
]);
const ROUTE_STATUSES = new Set([
  "untested",
  "source-tested",
  "fork-tested",
  "live-verified",
  "unsupported",
]);
const ROUTE_FAMILIES = new Set([
  "dedicated-router",
  "pool-swap-test",
  "universal-router",
  "direct-pool-manager",
  "alf-multiplexer",
  "other",
]);

function object(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function at(value, key) {
  return object(value) ? value[key] : undefined;
}

function isHttpsUrl(value) {
  if (typeof value !== "string") return false;
  try {
    const url = new URL(value);
    return url.protocol === "https:" && url.hostname.trim().length > 0;
  } catch {
    return false;
  }
}

function requireString(errors, value, path, { pattern, validate, maxLength } = {}) {
  if (typeof value !== "string" || value.length === 0) {
    errors.push(`${path} must be a non-empty string`);
    return;
  }
  if ((pattern && !pattern.test(value)) || (validate && !validate(value))) {
    errors.push(`${path} has an invalid format`);
  }
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

function validateEvidenceUrls(errors, value, path, { requireNonEmpty = false } = {}) {
  if (!Array.isArray(value)) {
    errors.push(`${path} must be an array`);
    return;
  }
  if (requireNonEmpty && value.length === 0) {
    errors.push(`${path} must contain at least one exact evidence URL`);
  }
  for (const [index, url] of value.entries()) {
    requireString(errors, url, `${path}[${index}]`, { validate: isHttpsUrl });
  }
}

function validateRouteMatrix(errors, value, path, { requireLiveEvidence = false } = {}) {
  if (!object(value)) {
    errors.push(`${path} must be an object`);
    return;
  }
  for (const quadrant of ROUTE_QUADRANTS) {
    const record = value[quadrant];
    if (!object(record)) {
      errors.push(`${path}.${quadrant} must be an object`);
      continue;
    }
    if (!ROUTE_STATUSES.has(record.status)) {
      errors.push(`${path}.${quadrant}.status is not supported`);
    }
    if (requireLiveEvidence && record.status !== "live-verified") {
      errors.push(`${path}.${quadrant}.status must be live-verified for a production deployment`);
    }
    if (!Array.isArray(record.routers)) {
      errors.push(`${path}.${quadrant}.routers must be an array`);
    } else if (record.status === "unsupported" && record.routers.length !== 0) {
      errors.push(`${path}.${quadrant}.routers must be empty when status is unsupported`);
    } else if (!["untested", "unsupported"].includes(record.status) && record.routers.length === 0) {
      errors.push(`${path}.${quadrant}.routers must include route evidence for ${record.status}`);
    }

    let hasExactLiveEvidence = false;
    if (Array.isArray(record.routers)) {
      for (const [routerIndex, route] of record.routers.entries()) {
        const routePath = `${path}.${quadrant}.routers[${routerIndex}]`;
        if (!object(route)) {
          errors.push(`${routePath} must be an object`);
          continue;
        }
        if (!ROUTE_FAMILIES.has(route.family)) {
          errors.push(`${routePath}.family is not supported`);
        }
        requireString(errors, route.identity, `${routePath}.identity`, { maxLength: 240 });
        if (!ROUTE_STATUSES.has(route.status)) {
          errors.push(`${routePath}.status is not supported`);
        }
        validateEvidenceUrls(errors, route.evidenceUrls, `${routePath}.evidenceUrls`, {
          requireNonEmpty: true,
        });
        if (
          route.status === "live-verified" &&
          typeof route.identity === "string" &&
          route.identity.trim().length > 0 &&
          Array.isArray(route.evidenceUrls) &&
          route.evidenceUrls.some(isHttpsUrl)
        ) {
          hasExactLiveEvidence = true;
        }
      }
    }
    if ((requireLiveEvidence || record.status === "live-verified") && !hasExactLiveEvidence) {
      errors.push(
        `${path}.${quadrant}.routers must include live-verified route evidence with a non-empty identity and evidenceUrls`,
      );
    }
  }
}

function validateFinalSettlement(errors, value, path, { requireLiveEvidence = false } = {}) {
  if (!object(value)) {
    errors.push(`${path} must be an object`);
    return;
  }
  if (!ROUTE_STATUSES.has(value.status)) {
    errors.push(`${path}.status is not supported`);
  }
  if (requireLiveEvidence && value.status !== "live-verified") {
    errors.push(`${path}.status must be live-verified for a production deployment`);
  }
  validateEvidenceUrls(errors, value.walletDeltaEvidenceUrls, `${path}.walletDeltaEvidenceUrls`, {
    requireNonEmpty: requireLiveEvidence,
  });
  validateEvidenceUrls(errors, value.routerEventEvidenceUrls, `${path}.routerEventEvidenceUrls`, {
    requireNonEmpty: requireLiveEvidence,
  });
}

function validateDeploymentRouteEvidence(errors, deployment, path, { requireLiveEvidence = false } = {}) {
  const routeEvidence = deployment?.routeEvidence;
  if (!object(routeEvidence)) {
    errors.push(`${path}.routeEvidence must be an object for v2 deployments`);
    return;
  }
  validateRouteMatrix(errors, routeEvidence.swapMatrix, `${path}.routeEvidence.swapMatrix`, {
    requireLiveEvidence,
  });
  validateFinalSettlement(errors, routeEvidence.finalSettlement, `${path}.routeEvidence.finalSettlement`, {
    requireLiveEvidence,
  });

  const scannerAssessments = routeEvidence.scannerAssessments;
  if (!Array.isArray(scannerAssessments)) {
    errors.push(`${path}.routeEvidence.scannerAssessments must be an array`);
  } else {
    for (const [scannerIndex, assessment] of scannerAssessments.entries()) {
      const scannerPath = `${path}.routeEvidence.scannerAssessments[${scannerIndex}]`;
      requireString(errors, assessment?.provider, `${scannerPath}.provider`, { maxLength: 120 });
      requireDate(errors, assessment?.observedAt, `${scannerPath}.observedAt`);
      if (assessment?.nonAuthoritative !== true) {
        errors.push(`${scannerPath}.nonAuthoritative must be true`);
      }
    }
  }
}

export function validateProductionDeploymentEvidence(deployment, path = "deployment") {
  const errors = [];
  validateDeploymentRouteEvidence(errors, deployment, path, { requireLiveEvidence: true });
  return errors;
}

function validateV2Manifest(errors, manifest, flags) {
  const provenance = manifest.provenance;
  const hookProperties = at(manifest.uniswapClassification, "properties");
  if (!object(provenance)) {
    errors.push("provenance must be an object for v2 manifests");
  } else {
    requireBoolean(errors, provenance.allowlistedFactoryInterface, "provenance.allowlistedFactoryInterface");
    if (provenance.allowlistedFactoryInterface === true && provenance.factoryInterface === "none") {
      errors.push("provenance.factoryInterface cannot be none when an allowlisted interface is claimed");
    }
    if (provenance.deploymentModel === "allowlisted-factory") {
      if (typeof provenance.factoryContract !== "string" || provenance.factoryContract.trim().length === 0) {
        errors.push("allowlisted-factory provenance requires a non-blank factoryContract");
      }
      if (!new Set(["typed", "versioned"]).has(provenance.factoryInterface)) {
        errors.push("allowlisted-factory provenance requires a typed or versioned factoryInterface");
      }
      if (provenance.allowlistedFactoryInterface !== true) {
        errors.push("allowlisted-factory provenance requires an allowlisted factory interface");
      }
    }
  }
  if (
    (provenance?.proxyModel === "upgradeable-proxy") !==
    (hookProperties?.upgradeable === true)
  ) {
    errors.push(
      "provenance.proxyModel must be upgradeable-proxy if and only if uniswapClassification.properties.upgradeable is true",
    );
  }

  const routing = at(manifest.integration, "routingCompatibility");
  if (!object(routing)) {
    errors.push("integration.routingCompatibility must be an object for v2 manifests");
  } else {
    validateRouteMatrix(errors, routing.swapMatrix, "integration.routingCompatibility.swapMatrix");
    const universalRouter = routing.officialUniversalRouter;
    if (!object(universalRouter)) {
      errors.push("integration.routingCompatibility.officialUniversalRouter must be an object");
    } else {
      requireBoolean(
        errors,
        universalRouter.requiredAddressIdentity,
        "integration.routingCompatibility.officialUniversalRouter.requiredAddressIdentity",
      );
      if (universalRouter.status === "live-verified" && universalRouter.requiredAddressIdentity !== true) {
        errors.push("live-verified Universal Router evidence must bind an exact deployed address identity");
      }
    }
    if (routing.finalAmountEvidence?.poolManagerSwapBasis !== "pre-after-swap-return-delta") {
      errors.push(
        "integration.routingCompatibility.finalAmountEvidence.poolManagerSwapBasis must be pre-after-swap-return-delta",
      );
    }
    if (
      routing.hookData?.mode === "required-versioned" &&
      (hookProperties?.requiresCustomSwapData !== true ||
        hookProperties?.customDataMode !== "ordinary-swap-required")
    ) {
      errors.push(
        "required-versioned hookData requires requiresCustomSwapData=true and customDataMode ordinary-swap-required",
      );
    }
  }

  for (const [deltaFlag, callback] of Object.entries(RETURN_DELTA_REQUIREMENTS)) {
    if (flags?.[deltaFlag] === true && flags?.[callback] !== true) {
      errors.push(`uniswapClassification.flags.${deltaFlag} requires ${callback}`);
    }
  }
  const callbackSemantics = at(manifest.uniswapClassification, "callbackSemantics");
  if (!Array.isArray(callbackSemantics)) {
    errors.push("uniswapClassification.callbackSemantics must be an array for v2 manifests");
  } else {
    const names = callbackSemantics.map((entry) => entry?.name);
    if (new Set(names).size !== names.length) {
      errors.push("uniswapClassification.callbackSemantics cannot contain duplicate callback names");
    }
    const enabled = REGULAR_CALLBACKS.filter((name) => flags?.[name] === true).sort();
    const declared = names.filter((name) => REGULAR_CALLBACKS.includes(name)).sort();
    if (JSON.stringify(enabled) !== JSON.stringify(declared)) {
      errors.push("uniswapClassification.callbackSemantics must describe every and only enabled callback");
    }
    for (const [index, callback] of callbackSemantics.entries()) {
      requireBoolean(
        errors,
        callback?.externalCalls,
        `uniswapClassification.callbackSemantics[${index}].externalCalls`,
      );
      requireString(
        errors,
        callback?.reentrancyBoundary,
        `uniswapClassification.callbackSemantics[${index}].reentrancyBoundary`,
        { maxLength: 500 },
      );
      requireString(
        errors,
        callback?.gasBoundary,
        `uniswapClassification.callbackSemantics[${index}].gasBoundary`,
        { maxLength: 500 },
      );
    }
  }

  const auditUrls = at(manifest.security, "auditUrls");
  if (manifest.security?.auditStatus === "audited" && (!Array.isArray(auditUrls) || auditUrls.length === 0)) {
    errors.push("security.auditUrls must contain at least one URL when auditStatus is audited");
  }

  const framework = at(manifest.security, "frameworkAssessment");
  if (!object(framework)) {
    errors.push("security.frameworkAssessment must be an object for v2 manifests");
  } else {
    if (framework.frameworkUrl !== "https://developers.uniswap.org/docs/protocols/v4/security") {
      errors.push("security.frameworkAssessment.frameworkUrl must pin the official Uniswap v4 security framework");
    }
    if (framework.scoreStatus === "unscored" && framework.score !== null) {
      errors.push("security.frameworkAssessment.score must be null while unscored");
    }
    if (framework.scoreStatus === "scored" && !Number.isInteger(framework.score)) {
      errors.push("security.frameworkAssessment.score must be an integer when scored");
    }
    if (framework.scoreStatus === "scored") {
      requireDate(errors, framework.assessedAt, "security.frameworkAssessment.assessedAt");
    }
    if (!Array.isArray(framework.featureTriggers) || framework.featureTriggers.length === 0) {
      errors.push("security.frameworkAssessment.featureTriggers must be non-empty");
    }
    if (!Array.isArray(framework.requiredActions) || framework.requiredActions.length === 0) {
      errors.push("security.frameworkAssessment.requiredActions must be non-empty");
    }
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

  if (!new Set(["hookr.external-hook.v1", "hookr.external-hook.v2"]).has(manifest.schemaVersion)) {
    errors.push("schemaVersion must be hookr.external-hook.v1 or hookr.external-hook.v2");
  }
  if (manifest.schemaVersion === "hookr.external-hook.v2" && manifest.$schema !== EXTERNAL_HOOK_V2_SCHEMA) {
    errors.push(`$schema must be ${EXTERNAL_HOOK_V2_SCHEMA} for v2 manifests`);
  }
  requireString(errors, manifest.slug, "slug", {
    pattern: /^[a-z0-9]+(?:-[a-z0-9]+)*$/,
    maxLength: 80,
  });
  requireString(errors, manifest.name, "name", { maxLength: 100 });
  requireString(errors, manifest.summary, "summary", { maxLength: 500 });
  if (!EXTERNAL_HOOK_STATUSES.includes(manifest.status)) errors.push("status is not supported");
  if (PRODUCTION_STATUSES.has(manifest.status) && manifest.schemaVersion !== "hookr.external-hook.v2") {
    errors.push(`${manifest.status} manifests must use hookr.external-hook.v2 production evidence`);
  }
  if (!new Set(["composable-blueprint", "standalone-hook-product"]).has(manifest.integrationMode)) {
    errors.push("integrationMode is not supported");
  }

  requireString(errors, at(manifest.author, "github"), "author.github", {
    pattern: /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$/,
  });
  requireString(errors, at(manifest.source, "repository"), "source.repository", {
    validate: isHttpsUrl,
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
  if (
    manifest.schemaVersion === "hookr.external-hook.v2" &&
    !new Set(["none", "optional-feature", "ordinary-swap-required"]).has(at(properties, "customDataMode"))
  ) {
    errors.push("uniswapClassification.properties.customDataMode is not supported");
  }
  if (
    manifest.schemaVersion === "hookr.external-hook.v2" &&
    properties?.requiresCustomSwapData === true &&
    properties?.customDataMode !== "ordinary-swap-required"
  ) {
    errors.push("requiresCustomSwapData=true requires customDataMode ordinary-swap-required");
  }
  if (
    manifest.schemaVersion === "hookr.external-hook.v2" &&
    properties?.customDataMode === "ordinary-swap-required" &&
    properties?.requiresCustomSwapData !== true
  ) {
    errors.push("customDataMode ordinary-swap-required requires requiresCustomSwapData=true");
  }
  if (!SWAP_ACCESS.has(at(properties, "swapAccess"))) {
    errors.push("uniswapClassification.properties.swapAccess is not supported");
  }
  if (manifest.schemaVersion === "hookr.external-hook.v2") {
    validateV2Manifest(errors, manifest, flags);
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
    if (PRODUCTION_STATUSES.has(manifest.status) && deployment.environment !== "mainnet") {
      errors.push(`${path}.environment must be mainnet for ${manifest.status}`);
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
      validate: isHttpsUrl,
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
          validate: isHttpsUrl,
        });
        requireDate(errors, pool.observedAt, `${poolPath}.observedAt`);
        if (manifest.schemaVersion === "hookr.external-hook.v2" || pool.majorTokenPair !== undefined) {
          requireBoolean(errors, pool.majorTokenPair, `${poolPath}.majorTokenPair`);
        }
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

    if (manifest.schemaVersion === "hookr.external-hook.v2") {
      validateDeploymentRouteEvidence(errors, deployment, path, {
        requireLiveEvidence: PRODUCTION_STATUSES.has(manifest.status),
      });
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

    const hooklist = at(at(deployment, "uniswap"), "hooklist");
    const routing = at(at(deployment, "uniswap"), "routing");
    const hooklistStatus = hooklist?.status;
    const routingStatus = routing?.status;
    if (!new Set(["not-submitted", "pending", "listed", "rejected"]).has(hooklistStatus)) {
      errors.push(`${path}.uniswap.hooklist.status is not supported`);
    }
    if (hooklistStatus === "pending") {
      requireString(errors, hooklist?.issueUrl, `${path}.uniswap.hooklist.issueUrl`, {
        validate: isHttpsUrl,
      });
    }
    if (hooklistStatus === "listed") {
      requireString(errors, hooklist?.listingUrl, `${path}.uniswap.hooklist.listingUrl`, {
        validate: isHttpsUrl,
      });
    }
    if (manifest.status === "listing-submitted" && hooklistStatus !== "pending") {
      errors.push(`${path}.uniswap.hooklist.status must be pending for listing-submitted`);
    }
    if (manifest.status === "listed" && hooklistStatus !== "listed") {
      errors.push(`${path}.uniswap.hooklist.status must be listed for listed`);
    }
    if (!new Set(["not-evaluated", "automatic", "review-required", "submitted", "allowlisted", "rejected"]).has(routingStatus)) {
      errors.push(`${path}.uniswap.routing.status is not supported`);
    }
    if (new Set(["submitted", "allowlisted"]).has(routingStatus)) {
      requireString(errors, routing?.receiptUrl, `${path}.uniswap.routing.receiptUrl`, {
        validate: isHttpsUrl,
      });
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
