#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import { keccak256, toBytes } from "viem";

const root = process.cwd();
const schema = JSON.parse(
  await readFile(resolve(root, "integrations/capabilities/schema.v2.json"), "utf8"),
);
const manifest = JSON.parse(
  await readFile(resolve(root, "integrations/capabilities/current.v2.json"), "utf8"),
);
const ajv = new Ajv2020({ allErrors: true, strict: true });
addFormats(ajv);
const validate = ajv.compile(schema);
if (!validate(manifest)) {
  throw new Error(`Invalid integration capability manifest: ${ajv.errorsText(validate.errors)}`);
}

const v6Model = manifest.capabilities.v6IntegrationModel;
if (
  v6Model.availability !== "source-review" ||
  v6Model.production !== false ||
  v6Model.sdkTransactionApi !== false ||
  v6Model.poolKeyRoot.rootHookSlots !== 1 ||
  v6Model.poolKeyRoot.checkoutSelection !== "one-root-profile"
) {
  throw new Error("V6 must remain a one-root-per-PoolKey source model with no production or SDK transaction API claim");
}
if (
  v6Model.paths.nativeRootBlocks.requiresNewImmutableHookrGeneration !== true ||
  v6Model.paths.nativeRootBlocks.composition !== "reviewed-schema-only" ||
  v6Model.paths.typedSubordinateExecutor.optional !== true ||
  v6Model.paths.typedSubordinateExecutor.binding !== "exact-versioned-profile" ||
  v6Model.paths.exclusiveExternalRoot.composesWithNativeBlocks !== false
) {
  throw new Error("V6 root and subordinate execution paths drifted from the reviewed composition model");
}
const requiredExternalPolicyBindings = new Set([
  "purpose-built-adapter",
  "router-policy",
  "quoter-policy",
]);
if (
  v6Model.paths.exclusiveExternalRoot.requiredPolicyBindings.length !==
    requiredExternalPolicyBindings.size ||
  v6Model.paths.exclusiveExternalRoot.requiredPolicyBindings.some(
    (binding) => !requiredExternalPolicyBindings.has(binding),
  )
) {
  throw new Error("An exclusive external root must retain purpose-built adapter, router, and quoter policy bindings");
}
const requiredLaunchpadBindingFields = new Set([
  "profile",
  "config",
  "caller",
  "creator",
  "beneficiary",
  "funding",
  "deadline",
  "nonce",
]);
if (
  v6Model.paths.launchpadAdapter.binding !== "atomic" ||
  v6Model.paths.launchpadAdapter.exactFields.length !== requiredLaunchpadBindingFields.size ||
  v6Model.paths.launchpadAdapter.exactFields.some(
    (field) => !requiredLaunchpadBindingFields.has(field),
  )
) {
  throw new Error("A V6 launchpad adapter must atomically bind the exact profile, config, caller, creator, beneficiary, funding, deadline, and nonce");
}
if (
  v6Model.paths.existingToken.poolSemantics !== "new-pool-key" ||
  v6Model.paths.existingToken.existingPoolsChanged !== false ||
  v6Model.existingDeployedHookAsNativeBlock !== "unsupported"
) {
  throw new Error("V6 cannot mutate an old pool or insert a deployed hook as a native Hookr block");
}
if (
  v6Model.monetization.availability !== "explicit-versioned-policy-only" ||
  v6Model.monetization.feePolicyIdentity !== "versioned-feePolicyHash" ||
  v6Model.monetization.recipientAccounting !== "explicit"
) {
  throw new Error("V6 monetization must remain bound to an explicit versioned feePolicyHash and recipient accounting");
}

const arb = manifest.capabilities.arbRecapture;
const compatible = new Set(arb.compatibleHookBlocks);
const conditional = new Map(
  arb.conditionalHookBlocks.map((entry) => [entry.block, entry]),
);
const incompatible = new Set(arb.incompatibleHookBlocks);
const reviewedCompatibleBlocks = new Set(["surge-fees", "auto-burn", "nth-buy-pot"]);
const reviewedIncompatibleBlocks = new Set(["lp-rewards"]);
if (
  arb.compatibleHookBlocks.length !== reviewedCompatibleBlocks.size ||
  compatible.size !== reviewedCompatibleBlocks.size ||
  [...reviewedCompatibleBlocks].some((block) => !compatible.has(block))
) {
  throw new Error("Arb Recapture must retain the exact reviewed Surge Fees, Auto Burn, and Nth-buy Pot compatibility set");
}
if (
  arb.incompatibleHookBlocks.length !== reviewedIncompatibleBlocks.size ||
  incompatible.size !== reviewedIncompatibleBlocks.size ||
  [...reviewedIncompatibleBlocks].some((block) => !incompatible.has(block))
) {
  throw new Error("Arb Recapture must retain exactly the reviewed LP Rewards exclusion");
}
for (const block of compatible) {
  if (conditional.has(block) || incompatible.has(block)) {
    throw new Error(`Arb block cannot have overlapping compatibility states: ${block}`);
  }
}
for (const block of conditional.keys()) {
  if (incompatible.has(block)) {
    throw new Error(`Arb block cannot have overlapping compatibility states: ${block}`);
  }
}
const antiSnipe = conditional.get("anti-snipe");
const antiSnipeNote =
  "During the Anti-Snipe guard, outer-buy Arb corrections can operate. Outer-sell corrections require an exact-output target buy and fail open until the guard ends.";
if (
  compatible.has("anti-snipe") ||
  arb.conditionalHookBlocks.length !== 1 ||
  conditional.size !== 1 ||
  !antiSnipe ||
  antiSnipe.duringGuard.outerBuyCorrection !== "supported" ||
  antiSnipe.duringGuard.outerSellCorrection !== "fail-open" ||
  antiSnipe.duringGuard.outerSellRequirement !== "exact-output-target-buy" ||
  antiSnipe.afterGuard !== "supported" ||
  antiSnipe.note !== antiSnipeNote
) {
  throw new Error("Anti-Snipe must remain conditional: outer buys are supported during the guard, while outer sells require an exact-output target buy and fail open until the guard ends");
}
if (arb.production || arb.routeSigning || arb.activationStatus !== "inactive") {
  throw new Error("Arb Recapture must remain inactive without a promoted V6 release");
}
if (arb.name !== "WTH Arb Recapture" || arb.selection !== "optional") {
  throw new Error("The V6 candidate must remain an optional, explicitly named WTH profile");
}
if (
  arb.integrationProfile.candidateGeneration !== "v6.1" ||
  arb.integrationProfile.sourceBoundary !== "separate-versioned-release-required" ||
  arb.integrationProfile.sourceCheckpointStatus !== "clean-v61-source-checkpoint" ||
  arb.integrationProfile.sourceCheckpointSha !== "5168888ed69cc738492368203197ee72a009a964" ||
  arb.integrationProfile.profileLabel !== "WTH" ||
  arb.integrationProfile.profileLabelStatus !== "source-label" ||
  arb.integrationProfile.serviceIdentity.status !== "unverified" ||
  arb.integrationProfile.serviceIdentity.productionRecipient !== null ||
  arb.integrationProfile.serviceIdentity.externalAbiAcceptance !== "unaccepted"
) {
  throw new Error("WTH must remain a source label until service identity, recipient, and ABI acceptance are verified");
}
if (
  arb.integrationProfile.integrationId !==
    "0xd49d445cfb1f944f40848794320f9ba89f9a8830fcbedf98c236f82476f7d680" ||
  arb.integrationProfile.feePolicyId !==
    "0x656d4d246973da37dc2020b1c4494018646a8033d212c09dc3bb82a4b0898ba7" ||
  arb.integrationProfile.binding !== "release-required"
) {
  throw new Error("The WTH integration or fee-policy identity drifted from the source profile");
}
if (
  keccak256(toBytes(arb.integrationProfile.integrationIdPreimage)) !==
    arb.integrationProfile.integrationId ||
  keccak256(toBytes(arb.integrationProfile.feePolicyIdPreimage)) !==
    arb.integrationProfile.feePolicyId
) {
  throw new Error("The published WTH identity does not match its canonical preimage");
}
const fixed = arb.feePolicy.fixedProtocolShares;
const configurable = arb.feePolicy.configurablePoolShares;
const defaults = configurable.defaults;
if (
  arb.feePolicy.generation !== "v2" ||
  fixed.wthBps !== 1_000 ||
  fixed.hookrBps !== 1_000 ||
  configurable.sumBps !== 8_000 ||
  configurable.abiStruct !== "ProfitSplit" ||
  configurable.lockedAt !== "pool-configuration" ||
  defaults.traderBps !== 2_000 ||
  defaults.creatorBps !== 4_000 ||
  defaults.triggerPoolBps !== 2_000 ||
  configurable.semantics.creator !== "pool-configured-creator-or-authorized-attacher" ||
  configurable.semantics.traderBps !== "authenticated-rebate-recipient-never-tx-origin" ||
  configurable.semantics.triggerPoolBps !== "pool-id-scoped-lp-escrow-not-position-distribution" ||
  arb.feePolicy.recipientIdentity.hookr !== "hookr.eth-resolved-address-pinned-at-release" ||
  arb.feePolicy.recipientIdentity.wth !== "whatthehook.eth-resolved-address-pinned-at-release" ||
  arb.feePolicy.externalRoundingAcceptance !== "unverified" ||
  arb.feePolicy.externalRecipientSemanticsAcceptance !== "unverified-no-tx-origin"
) {
  throw new Error("WTH v2 must keep fixed 10/10 protocol shares and the pool-locked default 40/20/20 remainder");
}
const abiFields = configurable.abiFields;
const configurableFields = new Set(configurable.bpsFields);
if (
  abiFields.length !== 4 ||
  abiFields[0] !== "creator" ||
  abiFields[1] !== "traderBps" ||
  abiFields[2] !== "creatorBps" ||
  abiFields[3] !== "triggerPoolBps" ||
  configurableFields.size !== 3 ||
  !configurableFields.has("traderBps") ||
  !configurableFields.has("creatorBps") ||
  !configurableFields.has("triggerPoolBps") ||
  defaults.traderBps + defaults.creatorBps + defaults.triggerPoolBps !== 8_000 ||
  fixed.wthBps + fixed.hookrBps + configurable.sumBps !== 10_000
) {
  throw new Error("WTH v2 configurable shares must contain exactly three fields, sum to 8,000 bps, and conserve 10,000 bps with fixed shares");
}
if (
  arb.triggerPoolLpDelivery.status !== "adapter-escrow" ||
  arb.triggerPoolLpDelivery.distributed !== false ||
  arb.triggerPoolLpDelivery.claimableByLps !== false ||
  arb.triggerPoolLpDelivery.distributorStatus !== "absent"
) {
  throw new Error("LP accounting must remain non-distributed adapter escrow until a reviewed distributor proves delivery");
}
if (
  arb.routingAndScanner.canonicalRouter !== "required-for-authenticated-gated-pot-and-wth-routes" ||
  arb.routingAndScanner.genericEmptyData.gatedBuy !== "unsupported" ||
  arb.routingAndScanner.genericEmptyData.potQualifyingBuy !== "unsupported" ||
  arb.routingAndScanner.quoter.simulationActor !== "caller-supplied" ||
  arb.routingAndScanner.quoter.executableOnlyWhenBoundToActiveWallet !== true ||
  arb.routingAndScanner.robinhoodUniversalRouter.status !== "unverified" ||
  arb.routingAndScanner.robinhoodUniversalRouter.officialSourceState !== "conflicting-addresses" ||
  arb.routingAndScanner.robinhoodUniversalRouter.exactForkMatrix !== false ||
  arb.routingAndScanner.scannerEvidence.authoritative !== false ||
  arb.routingAndScanner.scannerEvidence.conclusion !== "sellability-proved-for-one-route-not-scanner-clearance"
) {
  throw new Error("V6.1 routing, quoter-actor, Universal Router, and scanner boundaries drifted");
}
if (
  arb.existingTokenAttach.poolSemantics !== "new-pool-key" ||
  arb.existingTokenAttach.existingPoolsChanged !== false ||
  arb.existingTokenAttach.creatorBeneficiary !== "authorized-attacher" ||
  arb.existingTokenAttach.admission.scope !== "initial-pull-only" ||
  arb.existingTokenAttach.admission.requiredDecimals !== 18 ||
  arb.existingTokenAttach.admission.initialFactoryBalanceDelta !== "exact-requested-amount" ||
  arb.existingTokenAttach.admission.laterMutableTransferSemantics !== "unsupported"
) {
  throw new Error("Existing-token attach semantics drifted from the reviewed admission-only new-pool boundary");
}
const requiredUnsupportedBehaviors = new Set([
  "transfer-tax",
  "rebase",
  "pause-or-freeze",
  "blacklist",
  "callback-or-reentrancy",
  "code-loss",
]);
if (
  arb.existingTokenAttach.admission.unsupportedLaterBehaviors.length !==
    requiredUnsupportedBehaviors.size ||
  arb.existingTokenAttach.admission.unsupportedLaterBehaviors.some(
    (behavior) => !requiredUnsupportedBehaviors.has(behavior),
  )
) {
  throw new Error("Existing-token attach must enumerate every unsupported later-mutable behavior");
}
if (
  manifest.capabilities.partnerSdk.generation !== 5 ||
  arb.v6Sdk.transactionApi !== false ||
  v6Model.sdkTransactionApi !== false
) {
  throw new Error("The public SDK must remain V5-only while the V6 release is unpromoted");
}

process.stdout.write("valid integration capabilities (V6 integration grammar is source review only; V5 SDK only)\n");
