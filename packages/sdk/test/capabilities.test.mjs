import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  HOOKR_INTEGRATION_CAPABILITIES,
  HOOKR_V5_RELEASE,
} from "../dist/esm/release.js";

test("keeps public capability JSON aligned with the SDK", async () => {
  const publicManifest = JSON.parse(
    await readFile(new URL("../../../integrations/capabilities/current.v1.json", import.meta.url)),
  );
  const arb = HOOKR_INTEGRATION_CAPABILITIES.capabilities.arbRecapture;
  const packageManifest = JSON.parse(
    await readFile(new URL("../package.json", import.meta.url)),
  );
  assert.equal(publicManifest.release.publicSourceStatus, "current");
  assert.equal(HOOKR_V5_RELEASE.releaseEvidence.publicSourceStatus, "current");
  assert.equal(
    publicManifest.capabilities.partnerSdk.version,
    packageManifest.version,
  );
  assert.equal(publicManifest.capabilities.arbRecapture.availability, arb.availability);
  assert.deepEqual(publicManifest.capabilities.arbRecapture.compatibleHookBlocks, arb.compatibleHookBlocks);
  assert.deepEqual(publicManifest.capabilities.arbRecapture.incompatibleHookBlocks, arb.incompatibleHookBlocks);
  assert.equal(publicManifest.capabilities.arbRecapture.production, false);
  assert.equal(publicManifest.capabilities.arbRecapture.routeSigning, false);
});
