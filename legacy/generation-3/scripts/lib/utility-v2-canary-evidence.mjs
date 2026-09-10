import { getAddress } from "viem";

import { assertStrictReceiptOrder } from "./instant-canary-evidence.mjs";

export const UTILITY_V2_CANARY_SPEC = Object.freeze({
  deployer: getAddress("0x5a52D4B820Ae7F02880d270562950918ACb14aA2"),
  hookrToken: getAddress("0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c"),
  hookrRuntimeCodehash:
    "0xd9346eaf1a9878650549765e1d4ce8b3d0516d93d3203e1c8b99e382428ebc8d",
  coreIntentId: "0xaeff879d7bb7c1ca78eba49ba3936b2845bb1d9bc90e44743b3c4ae5f1310e26",
  lockGross: 1_000_000_000_000_000_000n,
  boostGross: 100_000_000_000_000_000_000n,
  minGrossBoost: 100_000_000_000_000_000_000n,
  maxActiveBoosts: 512,
  fee: 1_000_000_000_000_000_000n,
  principal: 99_000_000_000_000_000_000n,
  tier: 0,
  multiplierBps: 10_000,
  lockDurationSeconds: 30 * 24 * 60 * 60,
  bootstrapEpochSeconds: 2 * 60 * 60,
  weeklyEpochSeconds: 7 * 24 * 60 * 60,
  mondayOffsetSeconds: 4 * 24 * 60 * 60,
  canaryDeadlineWindowSeconds: 10 * 60,
});

export const UTILITY_V2_REWARD_Q128 = 1n << 128n;

export const UTILITY_V2_RECEIPT_LABELS = Object.freeze([
  "lockRewardsDeploy",
  "launchBoostDeploy",
  "rewardSourceSet",
  "approveLock",
  "lock",
  "approveBoost",
  "boost",
  "claim",
]);

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const check = (condition, message) => {
  if (!condition) throw new Error(message);
};
const sameHex = (left, right) =>
  typeof left === "string" &&
  typeof right === "string" &&
  left.toLowerCase() === right.toLowerCase();
const asBigInt = (value, label) => {
  try {
    return BigInt(value);
  } catch {
    throw new Error(`${label} is not an integer`);
  }
};
const asNumber = (value, label) => {
  const number = Number(value);
  check(Number.isSafeInteger(number), `${label} is not a safe integer`);
  return number;
};

const firstMondayStrictlyAfter = (timestamp) => {
  const value = asNumber(timestamp, "claim epoch start");
  const offset = UTILITY_V2_CANARY_SPEC.mondayOffsetSeconds;
  const week = UTILITY_V2_CANARY_SPEC.weeklyEpochSeconds;
  const currentMonday = offset + Math.floor((value - offset) / week) * week;
  return currentMonday > value ? currentMonday : currentMonday + week;
};

export function validateUtilityV2BootstrapSchedule(schedule) {
  check(schedule && typeof schedule === "object", "V2 bootstrap schedule is missing");
  const bootstrapStartedAt = asNumber(schedule.bootstrapStartedAt, "bootstrap start");
  const feeEpochStartsAt = asNumber(schedule.feeEpochStartsAt, "fee epoch start");
  const claimEpochStartsAt = asNumber(schedule.claimEpochStartsAt, "claim epoch start");
  const weeklyEpochsStartAt = asNumber(schedule.weeklyEpochsStartAt, "weekly epoch start");
  check(bootstrapStartedAt > 0, "bootstrap start is zero");
  check(
    feeEpochStartsAt === bootstrapStartedAt + UTILITY_V2_CANARY_SPEC.bootstrapEpochSeconds,
    "fee epoch start is not bootstrap plus two hours",
  );
  check(
    claimEpochStartsAt === feeEpochStartsAt + UTILITY_V2_CANARY_SPEC.bootstrapEpochSeconds,
    "claim epoch start is not fee start plus two hours",
  );
  check(
    weeklyEpochsStartAt === firstMondayStrictlyAfter(claimEpochStartsAt),
    "weekly epoch start is not the first Monday strictly after claim start",
  );
  return Object.freeze({ bootstrapStartedAt, feeEpochStartsAt, claimEpochStartsAt, weeklyEpochsStartAt });
}

export function utilityV2EpochAt(schedule, timestamp) {
  const exact = validateUtilityV2BootstrapSchedule(schedule);
  const value = asNumber(timestamp, "epoch timestamp");
  check(value >= exact.bootstrapStartedAt, "epoch timestamp predates bootstrap");
  if (value < exact.feeEpochStartsAt) return 0;
  if (value < exact.claimEpochStartsAt) return 1;
  if (value < exact.weeklyEpochsStartAt) return 2;
  return 3 + Math.floor(
    (value - exact.weeklyEpochsStartAt) / UTILITY_V2_CANARY_SPEC.weeklyEpochSeconds,
  );
}

export function utilityV2ProRataReward(weight, startIndex, endIndex) {
  const w = asBigInt(weight, "claim weight");
  const start = asBigInt(startIndex, "claim start index");
  const end = asBigInt(endIndex, "claim end index");
  check(end >= start, "claim reward index regressed");
  return (w * (end - start)) / UTILITY_V2_REWARD_Q128;
}

const checkAddress = (actual, expected, label) => {
  check(sameHex(actual, expected), `${label} is wrong`);
};
const checkAmount = (actual, expected, label) => {
  check(asBigInt(actual, label) === asBigInt(expected, `expected ${label}`), `${label} is wrong`);
};
const checkAtLeast = (actual, minimum, label) => {
  check(asBigInt(actual, label) >= asBigInt(minimum, `minimum ${label}`), `${label} is below the canary proof`);
};
const checkDeadline = (deadline, timestamp, label) => {
  const d = asBigInt(deadline, `${label} deadline`);
  const t = asBigInt(timestamp, `${label} timestamp`);
  check(d > t, `${label} deadline was expired when mined`);
  check(d <= t + 15n * 60n, `${label} deadline exceeds the bounded window`);
};
const hasExactKeys = (value, expected) => {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const actual = Object.keys(value).sort();
  const expectedSorted = [...expected].sort();
  return actual.length === expectedSorted.length && actual.every((key, index) => key === expectedSorted[index]);
};

const checkTransaction = (record, expectedTarget, label) => {
  const tx = record?.transaction;
  check(tx && typeof tx === "object", `${label} transaction is missing`);
  checkAddress(tx.from, UTILITY_V2_CANARY_SPEC.deployer, `${label} sender`);
  checkAddress(tx.to, expectedTarget, `${label} target`);
  checkAmount(tx.value, 0n, `${label} native value`);
};

const checkApproval = (record, spender, expectedAmount, label) => {
  checkTransaction(record, UTILITY_V2_CANARY_SPEC.hookrToken, label);
  checkAddress(record.calldata.spender, spender, `${label} calldata spender`);
  checkAmount(record.calldata.amount, expectedAmount, `${label} calldata amount`);
  checkAddress(record.event.owner, UTILITY_V2_CANARY_SPEC.deployer, `${label} event owner`);
  checkAddress(record.event.spender, spender, `${label} event spender`);
  checkAmount(record.event.amount, expectedAmount, `${label} event amount`);
};

/**
 * Pure validation for the exact three-deploy-plus-five-canary evidence assembled by the live
 * verifier. Keeping this seam RPC-free makes malformed receipt/event/linkage fixtures testable.
 */
export function validateUtilityV2CanaryEvidence(evidence) {
  const spec = UTILITY_V2_CANARY_SPEC;
  check(evidence && typeof evidence === "object", "utility canary evidence is missing");
  check(evidence.chainId === 4663, "utility evidence chain is wrong");
  check(/^0x[0-9a-f]{40}$/.test(evidence.sourceCommit), "utility source commit is malformed");
  const bootstrap = validateUtilityV2BootstrapSchedule(evidence.bootstrap);

  check(evidence.core?.version === 4, "supported core release is not generation 4");
  check(evidence.core?.productionAllowed === true, "supported core release is not production-enabled");
  check(evidence.core?.id === "hookr-4663-v4", "supported core release id is wrong");
  check(/^0x[0-9a-fA-F]{40}$/.test(evidence.core?.sourceCommit), "supported core source commit is malformed");
  checkAddress(evidence.core.launchpad.address, evidence.identities.launchpad, "core launchpad address");
  check(
    sameHex(evidence.core.launchpad.runtimeCodehash, evidence.runtimes.launchpad),
    "core launchpad runtime hash is wrong",
  );

  checkAddress(evidence.identities.deployer, spec.deployer, "utility deployer");
  checkAddress(evidence.identities.hookrToken, spec.hookrToken, "HOOKR token");
  for (const [label, address] of Object.entries({
    lockRewards: evidence.identities.lockRewards,
    launchBoost: evidence.identities.launchBoost,
    launchpad: evidence.identities.launchpad,
    launchToken: evidence.identities.launchToken,
  })) {
    check(!sameHex(address, ZERO_ADDRESS), `${label} address is zero`);
  }
  check(sameHex(evidence.runtimes.hookrToken, spec.hookrRuntimeCodehash), "HOOKR runtime hash is wrong");
  for (const label of ["lockRewards", "launchBoost", "launchpad"]) {
    check(/^0x[0-9a-fA-F]{64}$/.test(evidence.runtimes[label]), `${label} runtime hash is malformed`);
  }

  check(Array.isArray(evidence.receiptOrder), "receipt order is missing");
  check(evidence.receiptOrder.length === UTILITY_V2_RECEIPT_LABELS.length, "receipt order is not exactly 8 records");
  for (let index = 0; index < UTILITY_V2_RECEIPT_LABELS.length; index += 1) {
    check(evidence.receiptOrder[index]?.label === UTILITY_V2_RECEIPT_LABELS[index], `receipt #${index} label is wrong`);
  }
  assertStrictReceiptOrder(evidence.receiptOrder);

  const deployReceipts = evidence.receipts?.deployment;
  const canaryReceipts = evidence.receipts?.canary;
  check(
    hasExactKeys(deployReceipts, ["lockRewardsDeploy", "launchBoostDeploy", "rewardSourceSet"]),
    "deployment receipt set is not exactly three labeled records",
  );
  check(
    hasExactKeys(canaryReceipts, ["approveLock", "lock", "approveBoost", "boost", "claim"]),
    "canary receipt set is not exactly five labeled records",
  );
  for (const label of UTILITY_V2_RECEIPT_LABELS) {
    const expected = evidence.receiptOrder.find((record) => record.label === label)?.hash;
    const actual = deployReceipts?.[label] ?? canaryReceipts?.[label];
    check(sameHex(actual, expected), `${label} labeled receipt hash is wrong`);
  }

  checkApproval(evidence.stages.approveLock, evidence.identities.lockRewards, spec.lockGross, "lock approval");
  const lock = evidence.stages.lock;
  checkTransaction(lock, evidence.identities.lockRewards, "lock");
  checkAmount(lock.calldata.amount, spec.lockGross, "lock calldata amount");
  check(asNumber(lock.calldata.tier, "lock calldata tier") === spec.tier, "lock calldata tier is wrong");
  checkDeadline(lock.calldata.deadline, lock.transaction.timestamp, "lock");
  checkAddress(lock.transfer.from, spec.deployer, "lock transfer sender");
  checkAddress(lock.transfer.to, evidence.identities.lockRewards, "lock transfer recipient");
  checkAmount(lock.transfer.amount, spec.lockGross, "lock transfer amount");
  const canaryPositionId = asBigInt(lock.event.positionId, "Locked position id");
  check(canaryPositionId > 0n, "Locked position id is zero");
  checkAddress(lock.event.owner, spec.deployer, "Locked owner");
  checkAmount(lock.event.principal, spec.lockGross, "Locked principal");
  check(asNumber(lock.event.tier, "Locked tier") === spec.tier, "Locked tier is wrong");
  check(
    asNumber(lock.event.multiplierBps, "Locked multiplier") === spec.multiplierBps,
    "Locked multiplier is wrong",
  );
  checkAmount(lock.event.weight, spec.lockGross, "Locked weight");
  const depositEpoch = utilityV2EpochAt(bootstrap, lock.transaction.timestamp);
  check(depositEpoch === 0, "lock was not mined in bootstrap epoch 0");
  check(asNumber(lock.event.activationEpoch, "activation epoch") === depositEpoch + 1, "activation epoch is wrong");
  check(
    asNumber(lock.calldata.maxActivationEpoch, "lock maximum activation epoch") ===
      asNumber(lock.event.activationEpoch, "Locked activation epoch"),
    "lock activation bound is not exact",
  );
  check(
    asNumber(lock.event.expiryEpoch, "expiry epoch") === utilityV2EpochAt(bootstrap, lock.event.unlockAt),
    "expiry epoch is wrong",
  );
  checkAmount(
    lock.event.unlockAt,
    asBigInt(lock.transaction.timestamp, "lock timestamp") + BigInt(spec.lockDurationSeconds),
    "lock unlock timestamp",
  );
  const unlockTolerance =
    asBigInt(lock.calldata.maxUnlockAt, "lock maximum unlock timestamp") -
    asBigInt(lock.event.unlockAt, "Locked unlock timestamp");
  check(unlockTolerance >= 0n, "lock maximum unlock timestamp was exceeded");
  check(
    unlockTolerance <= BigInt(spec.canaryDeadlineWindowSeconds),
    "lock maximum unlock tolerance exceeds the canary window",
  );

  checkApproval(evidence.stages.approveBoost, evidence.identities.launchBoost, spec.boostGross, "boost approval");
  const boost = evidence.stages.boost;
  checkTransaction(boost, evidence.identities.launchBoost, "boost");
  check(sameHex(boost.calldata.intentId, spec.coreIntentId), "boost intent id is wrong");
  checkAmount(boost.calldata.grossAmount, spec.boostGross, "boost calldata gross");
  check(asNumber(boost.calldata.tier, "boost calldata tier") === spec.tier, "boost calldata tier is wrong");
  checkAmount(boost.calldata.maxRewardFee, spec.fee, "boost calldata maximum fee");
  checkAmount(boost.calldata.minPrincipalAdded, spec.principal, "boost calldata minimum principal");
  checkDeadline(boost.calldata.deadline, boost.transaction.timestamp, "boost");
  check(utilityV2EpochAt(bootstrap, boost.transaction.timestamp) === 1, "boost was not mined in fee epoch 1");
  checkAddress(boost.grossTransfer.from, spec.deployer, "boost gross transfer sender");
  checkAddress(boost.grossTransfer.to, evidence.identities.launchBoost, "boost gross transfer recipient");
  checkAmount(boost.grossTransfer.amount, spec.boostGross, "boost gross transfer amount");
  checkAddress(boost.feeTransfer.from, evidence.identities.launchBoost, "boost fee transfer sender");
  checkAddress(boost.feeTransfer.to, evidence.identities.lockRewards, "boost fee transfer recipient");
  checkAmount(boost.feeTransfer.amount, spec.fee, "boost fee transfer amount");
  checkAddress(boost.feeEvent.source, evidence.identities.launchBoost, "BoostFeeNotified source");
  check(asNumber(boost.feeEvent.epoch, "boost fee epoch") === depositEpoch + 1, "boost fee epoch is wrong");
  checkAmount(boost.feeEvent.amount, spec.fee, "BoostFeeNotified amount");
  checkAddress(boost.event.token, evidence.identities.launchToken, "BoostDeposited token");
  checkAddress(boost.event.creator, spec.deployer, "BoostDeposited creator");
  checkAmount(boost.event.grossAmount, spec.boostGross, "BoostDeposited gross");
  checkAmount(boost.event.principalAdded, spec.principal, "BoostDeposited principal");
  checkAmount(boost.event.rewardFee, spec.fee, "BoostDeposited fee");
  check(boost.event.feeApplied === true, "BoostDeposited fee was waived");
  checkAmount(boost.event.totalPrincipal, spec.principal, "BoostDeposited total principal");
  check(asNumber(boost.event.tier, "BoostDeposited tier") === spec.tier, "BoostDeposited tier is wrong");
  check(
    asNumber(boost.event.multiplierBps, "BoostDeposited multiplier") === spec.multiplierBps,
    "BoostDeposited multiplier is wrong",
  );
  checkAmount(boost.event.score, spec.principal, "BoostDeposited score");
  checkAmount(
    boost.event.unlockAt,
    asBigInt(boost.transaction.timestamp, "boost timestamp") + BigInt(spec.lockDurationSeconds),
    "boost unlock timestamp",
  );

  const claim = evidence.stages.claim;
  checkTransaction(claim, evidence.identities.lockRewards, "claim");
  checkAmount(claim.calldata.positionId, canaryPositionId, "claim position id");
  checkAddress(claim.calldata.to, spec.deployer, "claim recipient");
  check(utilityV2EpochAt(bootstrap, claim.transaction.timestamp) === 2, "claim was not mined in bridge epoch 2");
  checkAmount(claim.event.positionId, canaryPositionId, "RewardsClaimed position id");
  checkAddress(claim.event.owner, spec.deployer, "RewardsClaimed owner");
  checkAddress(claim.event.to, spec.deployer, "RewardsClaimed recipient");
  const claimedReward = asBigInt(claim.event.amount, "RewardsClaimed amount");
  check(claimedReward > 0n, "RewardsClaimed amount is zero");
  checkAddress(claim.transfer.from, evidence.identities.lockRewards, "claim transfer sender");
  checkAddress(claim.transfer.to, spec.deployer, "claim transfer recipient");
  checkAmount(claim.transfer.amount, claimedReward, "claim transfer amount");

  checkAddress(evidence.canonicalLaunch.token, evidence.identities.launchToken, "canonical launch token");
  checkAddress(evidence.canonicalLaunch.creator, spec.deployer, "canonical launch creator");
  check(sameHex(evidence.canonicalLaunch.intentId, spec.coreIntentId), "canonical launch intent is wrong");

  const post = evidence.postconditions;
  checkAmount(post.lockPosition.positionId, canaryPositionId, "postcondition position id");
  checkAddress(post.lockPosition.owner, spec.deployer, "postcondition lock owner");
  checkAmount(post.lockPosition.principal, spec.lockGross, "postcondition lock principal");
  checkAmount(post.lockPosition.weight, spec.lockGross, "postcondition lock weight");
  check(asNumber(post.lockPosition.activationEpoch, "post activation epoch") === depositEpoch + 1, "post activation wrong");
  check(
    asNumber(post.lockPosition.expiryEpoch, "post expiry epoch") === utilityV2EpochAt(bootstrap, lock.event.unlockAt),
    "post expiry epoch wrong",
  );
  checkAmount(post.lockPosition.unlockAt, lock.event.unlockAt, "post lock unlockAt");
  check(asNumber(post.lockPosition.lastClaimEpoch, "post claim epoch") === depositEpoch + 2, "post claim cursor wrong");
  check(asNumber(post.lockPosition.tier, "post lock tier") === spec.tier, "post lock tier wrong");
  check(post.lockPosition.withdrawn === false, "postcondition lock was withdrawn");
  check(
    asNumber(post.claimProof.startEpoch, "claim proof start epoch") === depositEpoch + 1,
    "claim proof start epoch is wrong",
  );
  check(
    asNumber(post.claimProof.endEpoch, "claim proof end epoch") === depositEpoch + 2,
    "claim proof end epoch is wrong",
  );
  const expectedReward = utilityV2ProRataReward(
    post.lockPosition.weight,
    post.claimProof.startIndex,
    post.claimProof.endIndex,
  );
  check(expectedReward > 0n, "claim proof reward is zero");
  checkAmount(claimedReward, expectedReward, "pro-rata claimed reward");
  checkAddress(post.boostPosition.creator, spec.deployer, "postcondition boost creator");
  checkAmount(post.boostPosition.principal, spec.principal, "postcondition boost principal");
  checkAmount(post.boostPosition.startedAtBlock, boost.transaction.contractBlockNumber, "boost L1 block clock");
  checkAmount(post.boostPosition.startedAt, boost.transaction.timestamp, "boost startedAt");
  checkAmount(post.boostPosition.unlockAt, boost.event.unlockAt, "boost postcondition unlockAt");
  check(asNumber(post.boostPosition.tier, "post boost tier") === spec.tier, "post boost tier wrong");
  checkAmount(post.allowances.lockRewards, 0n, "post lock allowance");
  checkAmount(post.allowances.launchBoost, 0n, "post boost allowance");
  checkAtLeast(post.lockAccounting.positionCount, canaryPositionId, "lock position count");
  checkAmount(post.lockAccounting.ownerPositionCount, 1n, "lock owner position count");
  checkAtLeast(post.lockAccounting.totalPrincipal, spec.lockGross, "lock liability");
  checkAtLeast(post.lockAccounting.rewardReserve, 0n, "reward reserve");
  checkAtLeast(post.lockAccounting.roundingCarry, 0n, "rounding carry");
  checkAtLeast(post.lockAccounting.feesNotified, spec.fee, "fees notified");
  checkAtLeast(post.lockAccounting.rewardsClaimed, claimedReward, "rewards claimed");
  check(post.lockAccounting.checkpointCurrent === true, "lock checkpoint is stale");
  checkAtLeast(post.boostAccounting.totalPrincipal, spec.principal, "boost liability");
  checkAmount(post.boostAccounting.maxActiveBoosts, spec.maxActiveBoosts, "maximum active boosts");
  checkAtLeast(post.boostAccounting.boostedTokensCount, 1n, "boosted token count");
  checkAtLeast(post.boostAccounting.tokenIndexPlusOne, 1n, "boosted token reverse index");
  check(
    asBigInt(post.boostAccounting.tokenIndexPlusOne, "boosted token reverse index") <=
      asBigInt(post.boostAccounting.boostedTokensCount, "boosted token count"),
    "boosted token reverse index exceeds the registry",
  );
  check(post.boostAccounting.registered === true, "canonical boost is not registered");
  checkAtLeast(post.boostAccounting.grossBoosted, spec.boostGross, "gross boosted ledger");
  checkAtLeast(post.boostAccounting.principalAdded, spec.principal, "principal added ledger");
  checkAtLeast(post.boostAccounting.feesForwarded, spec.fee, "fees forwarded ledger");
  checkAmount(post.boostAccounting.score, spec.principal, "boost score");
  checkAmount(post.boostAccounting.activePrincipal, spec.principal, "active boost principal");
  check(post.lockSolvency.solvent === true, "LockRewards is insolvent");
  checkAmount(post.lockSolvency.principal, post.lockAccounting.totalPrincipal, "LockRewards solvency principal");
  checkAmount(post.lockSolvency.rewards, post.lockAccounting.rewardReserve, "LockRewards solvency rewards");
  checkAmount(
    post.lockSolvency.balance,
    asBigInt(post.lockSolvency.principal, "lock solvency principal") +
      asBigInt(post.lockSolvency.rewards, "lock solvency rewards") +
      asBigInt(post.lockSolvency.surplus, "lock solvency surplus"),
    "LockRewards solvency identity",
  );
  check(post.boostSolvency.solvent === true, "LaunchBoost is insolvent");
  checkAmount(post.boostSolvency.principal, post.boostAccounting.totalPrincipal, "LaunchBoost solvency principal");
  checkAmount(
    post.boostSolvency.balance,
    asBigInt(post.boostSolvency.principal, "boost solvency principal") +
      asBigInt(post.boostSolvency.surplus, "boost solvency surplus"),
    "LaunchBoost solvency identity",
  );

  check(
    asBigInt(evidence.linkage?.blockNumber, "linkage block") >=
      asBigInt(claim.transaction.blockNumber, "claim block"),
    "linkage block predates canary",
  );
  check(/^0x[0-9a-fA-F]{64}$/.test(evidence.linkage?.blockHash), "linkage block hash is malformed");
  return evidence;
}
