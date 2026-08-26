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
    await readFile(new URL("../../../integrations/capabilities/current.v1.json", import.meta.url)),
  );
  const arb = HOOKR_INTEGRATION_CAPABILITIES.capabilities.arbRecapture;
  const v6Model = HOOKR_INTEGRATION_CAPABILITIES.capabilities.v6IntegrationModel;
  const packageManifest = JSON.parse(
    await readFile(new URL("../package.json", import.meta.url)),
  );
  assert.deepEqual(publicManifest, HOOKR_INTEGRATION_CAPABILITIES);
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
  assert.equal(publicManifest.capabilities.arbRecapture.integrationProfile.profileLabel, "WTH");
  assert.equal(publicManifest.capabilities.arbRecapture.integrationProfile.profileLabelStatus, "source-label");
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
    fixed: true,
    creatorBps: 4_000,
    authenticatedSwapRecipientBps: 2_000,
    triggerPoolLpsBps: 2_000,
    wthBps: 1_000,
    hookrBps: 1_000,
  });
  assert.equal(
    Object.entries(publicManifest.capabilities.arbRecapture.feePolicy)
      .filter(([key]) => key.endsWith("Bps"))
      .reduce((sum, [, value]) => sum + value, 0),
    10_000,
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
  assert.equal(
    Object.keys(packageManifest.exports).some((entrypoint) => /(?:arb|v6)/i.test(entrypoint)),
    false,
  );
});
