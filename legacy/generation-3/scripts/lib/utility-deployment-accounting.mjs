function asUnsigned(value, label) {
  if (typeof value !== "bigint" || value < 0n) throw new Error(`${label} is not an unsigned bigint`);
  return value;
}

/**
 * Validate identities that remain exact even after unrelated users interact permissionlessly.
 * Constructor/initcode evidence proves initialization; this function deliberately never requires
 * a later global count or ledger to remain zero.
 */
export function validateAmbientUtilityDeploymentAccounting(input) {
  const rewardReserve = asUnsigned(input.rewardReserve, "rewardReserve");
  const rewardsClaimed = asUnsigned(input.cumulativeRewardsClaimed, "cumulativeRewardsClaimed");
  const feesNotified = asUnsigned(input.cumulativeBoostFeesNotified, "cumulativeBoostFeesNotified");
  const roundingCarry = asUnsigned(input.roundingCarry, "roundingCarry");
  const feesForwarded = asUnsigned(input.cumulativeFeesForwarded, "cumulativeFeesForwarded");
  const grossBoosted = asUnsigned(input.cumulativeGrossBoosted, "cumulativeGrossBoosted");
  const principalAdded = asUnsigned(input.cumulativePrincipalAdded, "cumulativePrincipalAdded");
  const boostPrincipal = asUnsigned(input.totalBoostPrincipal, "totalBoostPrincipal");
  const boostedTokensCount = asUnsigned(input.boostedTokensCount, "boostedTokensCount");
  const maxActiveBoosts = asUnsigned(input.maxActiveBoosts, "maxActiveBoosts");

  if (rewardReserve + rewardsClaimed !== feesNotified) {
    throw new Error("LockRewards notified-fee reserve/claim identity failed");
  }
  if (roundingCarry > rewardReserve) {
    throw new Error("LockRewards rounding reserve exceeds reward liability");
  }
  if (feesForwarded !== feesNotified) {
    throw new Error("LaunchBoost forwarded fees do not equal LockRewards notified fees");
  }
  if (grossBoosted !== principalAdded + feesForwarded) {
    throw new Error("LaunchBoost gross/principal/fee identity failed");
  }
  if (boostPrincipal > principalAdded) {
    throw new Error("LaunchBoost current principal exceeds cumulative principal additions");
  }
  if (boostedTokensCount > maxActiveBoosts) {
    throw new Error("LaunchBoost active registry exceeds capacity");
  }
  return Object.freeze({
    rewardReserve,
    rewardsClaimed,
    feesNotified,
    roundingCarry,
    feesForwarded,
    grossBoosted,
    principalAdded,
    boostPrincipal,
    boostedTokensCount,
    maxActiveBoosts,
  });
}
