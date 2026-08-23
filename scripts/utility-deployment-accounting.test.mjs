import assert from "node:assert/strict";
import test from "node:test";

import { validateAmbientUtilityDeploymentAccounting } from "./lib/utility-deployment-accounting.mjs";

function fixture(overrides = {}) {
  return {
    rewardReserve: 250n,
    cumulativeRewardsClaimed: 50n,
    cumulativeBoostFeesNotified: 300n,
    roundingCarry: 2n,
    cumulativeFeesForwarded: 300n,
    cumulativeGrossBoosted: 30_000n,
    cumulativePrincipalAdded: 29_700n,
    totalBoostPrincipal: 20_000n,
    boostedTokensCount: 200n,
    maxActiveBoosts: 512n,
    ...overrides,
  };
}

test("accepts nonzero ambient positions, fees, claims, withdrawals, and registry entries", () => {
  const result = validateAmbientUtilityDeploymentAccounting(fixture());
  assert.equal(result.grossBoosted, 30_000n);
  assert.equal(result.boostedTokensCount, 200n);
});

test("rejects broken cross-contract and cumulative identities", () => {
  assert.throws(
    () => validateAmbientUtilityDeploymentAccounting(fixture({ cumulativeBoostFeesNotified: 301n })),
    /reserve\/claim identity/,
  );
  assert.throws(
    () => validateAmbientUtilityDeploymentAccounting(fixture({ cumulativeFeesForwarded: 299n })),
    /forwarded fees/,
  );
  assert.throws(
    () => validateAmbientUtilityDeploymentAccounting(fixture({ cumulativeGrossBoosted: 29_999n })),
    /gross\/principal\/fee/,
  );
});

test("rejects impossible liability, rounding, or capacity state", () => {
  assert.throws(
    () => validateAmbientUtilityDeploymentAccounting(fixture({ roundingCarry: 251n })),
    /rounding reserve/,
  );
  assert.throws(
    () => validateAmbientUtilityDeploymentAccounting(fixture({ totalBoostPrincipal: 29_701n })),
    /current principal/,
  );
  assert.throws(
    () => validateAmbientUtilityDeploymentAccounting(fixture({ boostedTokensCount: 513n })),
    /registry exceeds capacity/,
  );
});
