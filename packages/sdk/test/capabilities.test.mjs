import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { keccak256, toBytes } from "viem";
import {
  HOOKR_INTEGRATION_CAPABILITIES,
  HOOKR_V5_RELEASE,
} from "../dist/esm/release.js";

test("keeps public capability JSON aligned with the SDK", async () => {
  const publicManifest = JSON.parse(
    await readFile(new URL("../../../integrations/capabilities/current.v2.json", import.meta.url)),
  );
  const frozenV1Manifest = JSON.parse(
    await readFile(new URL("../../../integrations/capabilities/current.v1.json", import.meta.url)),
  );
  const arb = HOOKR_INTEGRATION_CAPABILITIES.capabilities.arbRecapture;
  const v6Model = HOOKR_INTEGRATION_CAPABILITIES.capabilities.v6IntegrationModel;
  const packageManifest = JSON.parse(
    await readFile(new URL("../package.json", import.meta.url)),
  );
  assert.deepEqual(publicManifest, HOOKR_INTEGRATION_CAPABILITIES);
  assert.equal(publicManifest.schemaVersion, "hookr.integration-capabilities.v2");
  assert.equal(publicManifest.release.publicSourceStatus, "current");
  assert.equal(HOOKR_V5_RELEASE.releaseEvidence.publicSourceStatus, "current");
  assert.equal(HOOKR_INTEGRATION_CAPABILITIES.release.generation, 5);
  assert.deepEqual(v6Model, {
    availability: "source-review",
    production: false,
    sdkTransactionApi: false,
    poolKeyRoot: {
      rootHookSlots: 1,
      checkoutSelection: "one-root-profile",
    },
    paths: {
      nativeRootBlocks: {
        requiresNewImmutableHookrGeneration: true,
        composition: "reviewed-schema-only",
      },
      typedSubordinateExecutor: {
        optional: true,
        binding: "exact-versioned-profile",
      },
      exclusiveExternalRoot: {
        composesWithNativeBlocks: false,
        requiredPolicyBindings: [
          "purpose-built-adapter",
          "router-policy",
          "quoter-policy",
        ],
      },
      existingToken: {
        poolSemantics: "new-pool-key",
        existingPoolsChanged: false,
      },
      launchpadAdapter: {
        binding: "atomic",
        exactFields: [
          "profile",
          "config",
          "caller",
          "creator",
          "beneficiary",
          "funding",
          "deadline",
          "nonce",
        ],
      },
    },
    existingDeployedHookAsNativeBlock: "unsupported",
    monetization: {
      availability: "explicit-versioned-policy-only",
      feePolicyIdentity: "versioned-feePolicyHash",
      recipientAccounting: "explicit",
    },
  });
  assert.equal(
    publicManifest.capabilities.partnerSdk.version,
    packageManifest.version,
  );
  assert.equal(publicManifest.capabilities.arbRecapture.availability, arb.availability);
  assert.deepEqual(publicManifest.capabilities.arbRecapture.compatibleHookBlocks, arb.compatibleHookBlocks);
  assert.deepEqual(publicManifest.capabilities.arbRecapture.conditionalHookBlocks, arb.conditionalHookBlocks);
  assert.deepEqual(arb.conditionalHookBlocks, [
    {
      block: "anti-snipe",
      duringGuard: {
        outerBuyCorrection: "supported",
        outerSellCorrection: "fail-open",
        outerSellRequirement: "exact-output-target-buy",
      },
      afterGuard: "supported",
      note: "During the Anti-Snipe guard, outer-buy Arb corrections can operate. Outer-sell corrections require an exact-output target buy and fail open until the guard ends.",
    },
  ]);
  assert.deepEqual(publicManifest.capabilities.arbRecapture.incompatibleHookBlocks, arb.incompatibleHookBlocks);
  assert.equal(publicManifest.capabilities.arbRecapture.production, false);
  assert.equal(publicManifest.capabilities.arbRecapture.routeSigning, false);
  assert.equal(publicManifest.capabilities.arbRecapture.activationStatus, "inactive");
  assert.equal(arb.activationStatus, "inactive");
  assert.deepEqual(publicManifest.capabilities.arbRecapture.integrationProfile.serviceIdentity, {
    status: "unverified",
    productionRecipient: null,
    externalAbiAcceptance: "unaccepted",
  });
  assert.equal(publicManifest.capabilities.arbRecapture.integrationProfile.candidateGeneration, "v6.1");
  assert.equal(
    publicManifest.capabilities.arbRecapture.integrationProfile.sourceBoundary,
    "separate-versioned-release-required",
  );
  assert.equal(publicManifest.capabilities.arbRecapture.integrationProfile.profileLabel, "WTH");
  assert.equal(publicManifest.capabilities.arbRecapture.integrationProfile.profileLabelStatus, "source-label");
  assert.equal(
    publicManifest.capabilities.arbRecapture.integrationProfile.sourceCheckpointStatus,
    "clean-v61-source-checkpoint",
  );
  assert.equal(
    publicManifest.capabilities.arbRecapture.integrationProfile.sourceCheckpointSha,
    "5168888ed69cc738492368203197ee72a009a964",
  );
  assert.equal(
    keccak256(toBytes(publicManifest.capabilities.arbRecapture.integrationProfile.integrationIdPreimage)),
    publicManifest.capabilities.arbRecapture.integrationProfile.integrationId,
  );
  assert.equal(
    keccak256(toBytes(publicManifest.capabilities.arbRecapture.integrationProfile.feePolicyIdPreimage)),
    publicManifest.capabilities.arbRecapture.integrationProfile.feePolicyId,
  );
  assert.deepEqual(publicManifest.capabilities.arbRecapture.feePolicy, {
    basis: "gross-realized-quote-profit",
    generation: "v2",
    fixedProtocolShares: {
      wthBps: 1_000,
      hookrBps: 1_000,
    },
    configurablePoolShares: {
      sumBps: 8_000,
      abiStruct: "ProfitSplit",
      abiFields: [
        "creator",
        "traderBps",
        "creatorBps",
        "triggerPoolBps",
      ],
      bpsFields: ["traderBps", "creatorBps", "triggerPoolBps"],
      lockedAt: "pool-configuration",
      defaults: {
        traderBps: 2_000,
        creatorBps: 4_000,
        triggerPoolBps: 2_000,
      },
      semantics: {
        creator: "pool-configured-creator-or-authorized-attacher",
        traderBps: "authenticated-rebate-recipient-never-tx-origin",
        triggerPoolBps: "pool-id-scoped-lp-escrow-not-position-distribution",
      },
    },
    recipientIdentity: {
      hookr: "hookr.eth-resolved-address-pinned-at-release",
      wth: "whatthehook.eth-resolved-address-pinned-at-release",
    },
    externalRoundingAcceptance: "unverified",
    externalRecipientSemanticsAcceptance: "unverified-no-tx-origin",
  });
  const fixedShares = publicManifest.capabilities.arbRecapture.feePolicy.fixedProtocolShares;
  const configurableShares =
    publicManifest.capabilities.arbRecapture.feePolicy.configurablePoolShares;
  assert.equal(
    fixedShares.wthBps + fixedShares.hookrBps + configurableShares.sumBps,
    10_000,
  );
  assert.equal(
    Object.values(configurableShares.defaults).reduce((sum, value) => sum + value, 0),
    configurableShares.sumBps,
  );
  assert.deepEqual(publicManifest.capabilities.arbRecapture.existingTokenAttach.admission, {
    scope: "initial-pull-only",
    requiredDecimals: 18,
    initialFactoryBalanceDelta: "exact-requested-amount",
    laterMutableTransferSemantics: "unsupported",
    unsupportedLaterBehaviors: [
      "transfer-tax",
      "rebase",
      "pause-or-freeze",
      "blacklist",
      "callback-or-reentrancy",
      "code-loss",
    ],
  });
  assert.deepEqual(
    {
      status: publicManifest.capabilities.arbRecapture.triggerPoolLpDelivery.status,
      distributed: publicManifest.capabilities.arbRecapture.triggerPoolLpDelivery.distributed,
      claimableByLps: publicManifest.capabilities.arbRecapture.triggerPoolLpDelivery.claimableByLps,
      distributorStatus: publicManifest.capabilities.arbRecapture.triggerPoolLpDelivery.distributorStatus,
    },
    {
      status: "adapter-escrow",
      distributed: false,
      claimableByLps: false,
      distributorStatus: "absent",
    },
  );
  assert.equal(publicManifest.capabilities.arbRecapture.v6Sdk.transactionApi, false);
  assert.deepEqual(publicManifest.capabilities.arbRecapture.routingAndScanner, {
    canonicalRouter: "required-for-authenticated-gated-pot-and-wth-routes",
    genericEmptyData: {
      ungatedExactInputBuy: "candidate-source-supported",
      exactInputExit: "candidate-source-supported",
      gatedBuy: "unsupported",
      potQualifyingBuy: "unsupported",
      exactOutputExit: "conditional-unverified",
    },
    quoter: {
      simulationActor: "caller-supplied",
      executableOnlyWhenBoundToActiveWallet: true,
    },
    robinhoodUniversalRouter: {
      status: "unverified",
      officialSourceState: "conflicting-addresses",
      exactForkMatrix: false,
    },
    scannerEvidence: {
      authoritative: false,
      v5Token: "0x0093005884142Fb305A3991DCD24e55Bfebf1570",
      blockaidStatus: "warning-observed",
      successfulSellTransaction:
        "0xac74066b69caaf84df9a9f86a118bc09a977ae315e712047dcf895bb76dfcd9c",
      conclusion: "sellability-proved-for-one-route-not-scanner-clearance",
    },
  });
  assert.equal(
    publicManifest.capabilities.arbRecapture.boundaries.some((boundary) =>
      boundary.includes("tx.origin is prohibited"),
    ),
    true,
  );

  // V2 supersedes the WTH fee interface without rewriting the frozen V1 evidence record.
  assert.equal(frozenV1Manifest.schemaVersion, "hookr.integration-capabilities.v1");
  assert.equal(
    frozenV1Manifest.capabilities.arbRecapture.integrationProfile.integrationIdPreimage,
    "hookr.integration.wth-arb.v1",
  );
  assert.equal(
    frozenV1Manifest.capabilities.arbRecapture.integrationProfile.integrationId,
    "0x96b4bee6c464c61145bc4ddbff93ba0bc5e303003b633a6676dbe491acd3e651",
  );
  assert.equal(
    frozenV1Manifest.capabilities.arbRecapture.integrationProfile.feePolicyId,
    "0xe786145bacf8a9afb49db278f5c581557d335b51cebbed990a5c5e0871910499",
  );
  assert.deepEqual(frozenV1Manifest.capabilities.arbRecapture.feePolicy, {
    basis: "gross-realized-quote-profit",
    fixed: true,
    creatorBps: 4_000,
    authenticatedSwapRecipientBps: 2_000,
    triggerPoolLpsBps: 2_000,
    wthBps: 1_000,
    hookrBps: 1_000,
  });
  assert.equal(
    Object.keys(packageManifest.exports).some((entrypoint) => /(?:arb|v6)/i.test(entrypoint)),
    false,
  );
});
