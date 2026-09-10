import assert from "node:assert/strict";
import test from "node:test";

import {
  UTILITY_CANARY_SPEC as spec,
  UTILITY_RECEIPT_LABELS,
  UTILITY_REWARD_Q128,
  utilityEpochAt,
  utilityProRataReward,
  validateUtilityCanaryEvidence,
} from "./lib/utility-canary-evidence.mjs";

const address = (value) => `0x${value.toString(16).padStart(40, "0")}`;
const hash = (value) => `0x${value.toString(16).padStart(64, "0")}`;
const rewards = address(0x1001);
const boost = address(0x1002);
const launchpad = address(0x1003);
const launchToken = address(0x1004);

function fixture() {
  const canaryPositionId = 7n;
  const claimStartIndex = 3n * UTILITY_REWARD_Q128;
  const claimEndIndex = claimStartIndex + UTILITY_REWARD_Q128 / 4n;
  const claimedReward = utilityProRataReward(spec.lockGross, claimStartIndex, claimEndIndex);
  const depositTimestamp = 1_800_000_000;
  const depositEpoch = utilityEpochAt(depositTimestamp);
  const boostTimestamp = spec.epochOffsetSeconds + (depositEpoch + 1) * spec.epochSeconds;
  const claimTimestamp = boostTimestamp + spec.epochSeconds;
  const receiptOrder = UTILITY_RECEIPT_LABELS.map((label, index) => ({
    label,
    hash: hash(index + 1),
    blockNumber: 100 + index,
    transactionIndex: 0,
  }));
  const tx = (to, timestamp, blockNumber, contractBlockNumber = blockNumber) => ({
    from: spec.deployer,
    to,
    value: 0n,
    timestamp,
    blockNumber,
    contractBlockNumber,
  });
  return {
    chainId: 4663,
    sourceCommit: `0x${"a".repeat(40)}`,
    core: {
      id: "hookr-4663-v4",
      version: 4,
      productionAllowed: true,
      sourceCommit: `0x${"b".repeat(40)}`,
      launchpad: { address: launchpad, runtimeCodehash: hash(33) },
    },
    identities: {
      deployer: spec.deployer,
      hookrToken: spec.hookrToken,
      lockRewards: rewards,
      launchBoost: boost,
      launchpad,
      launchToken,
    },
    runtimes: {
      hookrToken: spec.hookrRuntimeCodehash,
      lockRewards: hash(31),
      launchBoost: hash(32),
      launchpad: hash(33),
    },
    receiptOrder,
    receipts: {
      deployment: {
        lockRewardsDeploy: receiptOrder[0].hash,
        launchBoostDeploy: receiptOrder[1].hash,
        rewardSourceSet: receiptOrder[2].hash,
      },
      canary: {
        approveLock: receiptOrder[3].hash,
        lock: receiptOrder[4].hash,
        approveBoost: receiptOrder[5].hash,
        boost: receiptOrder[6].hash,
        claim: receiptOrder[7].hash,
      },
    },
    stages: {
      approveLock: {
        transaction: tx(spec.hookrToken),
        calldata: { spender: rewards, amount: spec.lockGross },
        event: { owner: spec.deployer, spender: rewards, amount: spec.lockGross },
      },
      lock: {
        transaction: tx(rewards, depositTimestamp, 104),
        calldata: {
          amount: spec.lockGross,
          tier: spec.tier,
          maxActivationEpoch: depositEpoch + 1,
          maxUnlockAt:
            depositTimestamp + spec.lockDurationSeconds + spec.canaryDeadlineWindowSeconds,
          deadline: depositTimestamp + 600,
        },
        transfer: { from: spec.deployer, to: rewards, amount: spec.lockGross },
        event: {
          positionId: canaryPositionId,
          owner: spec.deployer,
          principal: spec.lockGross,
          tier: spec.tier,
          multiplierBps: spec.multiplierBps,
          activationEpoch: depositEpoch + 1,
          expiryEpoch: utilityEpochAt(depositTimestamp + spec.lockDurationSeconds),
          unlockAt: depositTimestamp + spec.lockDurationSeconds,
          weight: spec.lockGross,
        },
      },
      approveBoost: {
        transaction: tx(spec.hookrToken),
        calldata: { spender: boost, amount: spec.boostGross },
        event: { owner: spec.deployer, spender: boost, amount: spec.boostGross },
      },
      boost: {
        transaction: tx(boost, boostTimestamp, 106, 5_006),
        calldata: {
          intentId: spec.coreIntentId,
          grossAmount: spec.boostGross,
          tier: spec.tier,
          maxRewardFee: spec.fee,
          minPrincipalAdded: spec.principal,
          deadline: boostTimestamp + 600,
        },
        grossTransfer: { from: spec.deployer, to: boost, amount: spec.boostGross },
        feeTransfer: { from: boost, to: rewards, amount: spec.fee },
        feeEvent: { source: boost, epoch: depositEpoch + 1, amount: spec.fee },
        event: {
          token: launchToken,
          creator: spec.deployer,
          grossAmount: spec.boostGross,
          principalAdded: spec.principal,
          rewardFee: spec.fee,
          feeApplied: true,
          totalPrincipal: spec.principal,
          tier: spec.tier,
          multiplierBps: spec.multiplierBps,
          unlockAt: boostTimestamp + spec.lockDurationSeconds,
          score: spec.principal,
        },
      },
      claim: {
        transaction: tx(rewards, claimTimestamp, 107),
        calldata: { positionId: canaryPositionId, to: spec.deployer },
        event: { positionId: canaryPositionId, owner: spec.deployer, to: spec.deployer, amount: claimedReward },
        transfer: { from: rewards, to: spec.deployer, amount: claimedReward },
      },
    },
    canonicalLaunch: { intentId: spec.coreIntentId, token: launchToken, creator: spec.deployer },
    postconditions: {
      lockPosition: {
        positionId: canaryPositionId,
        owner: spec.deployer,
        principal: spec.lockGross,
        weight: spec.lockGross,
        unlockAt: depositTimestamp + spec.lockDurationSeconds,
        activationEpoch: depositEpoch + 1,
        expiryEpoch: utilityEpochAt(depositTimestamp + spec.lockDurationSeconds),
        lastClaimEpoch: depositEpoch + 2,
        tier: spec.tier,
        withdrawn: false,
      },
      claimProof: {
        startEpoch: depositEpoch + 1,
        endEpoch: depositEpoch + 2,
        startIndex: claimStartIndex,
        endIndex: claimEndIndex,
      },
      boostPosition: {
        creator: spec.deployer,
        principal: spec.principal,
        startedAt: boostTimestamp,
        unlockAt: boostTimestamp + spec.lockDurationSeconds,
        startedAtBlock: 5_006,
        tier: spec.tier,
      },
      allowances: { lockRewards: 0n, launchBoost: 0n },
      lockAccounting: {
        positionCount: 9n,
        ownerPositionCount: 1n,
        totalPrincipal: 11n * spec.lockGross,
        rewardReserve: 3n * spec.fee,
        roundingCarry: 123n,
        feesNotified: 4n * spec.fee,
        rewardsClaimed: spec.fee,
        checkpointCurrent: true,
      },
      boostAccounting: {
        maxActiveBoosts: spec.maxActiveBoosts,
        boostedTokensCount: 4n,
        tokenIndexPlusOne: 3n,
        registered: true,
        totalPrincipal: 4n * spec.principal,
        grossBoosted: 4n * spec.boostGross,
        principalAdded: 4n * spec.principal,
        feesForwarded: 4n * spec.fee,
        score: spec.principal,
        activePrincipal: spec.principal,
      },
      lockSolvency: {
        balance: 14n * spec.lockGross,
        principal: 11n * spec.lockGross,
        rewards: 3n * spec.fee,
        surplus: 0n,
        solvent: true,
      },
      boostSolvency: {
        balance: 4n * spec.principal,
        principal: 4n * spec.principal,
        surplus: 0n,
        solvent: true,
      },
    },
    linkage: { blockNumber: 107, blockHash: hash(99) },
  };
}

test("accepts exact canary receipts and pro-rata proof amid unrelated ambient state", () => {
  assert.equal(validateUtilityCanaryEvidence(fixture()).chainId, 4663);
});

test("rejects a non-exact 1% fee transfer", () => {
  const evidence = fixture();
  evidence.stages.boost.feeTransfer.amount -= 1n;
  assert.throws(() => validateUtilityCanaryEvidence(evidence), /boost fee transfer amount is wrong/);
});

test("rejects a claim for any position other than the lock receipt position", () => {
  const evidence = fixture();
  evidence.stages.claim.calldata.positionId += 1n;
  assert.throws(() => validateUtilityCanaryEvidence(evidence), /claim position id is wrong/);
});

test("rejects a claim amount not proven by the immutable epoch-index delta", () => {
  const evidence = fixture();
  evidence.postconditions.claimProof.endIndex += 1n << 128n;
  assert.throws(() => validateUtilityCanaryEvidence(evidence), /pro-rata claimed reward is wrong/);
});

test("rejects ambient ledgers below the canary's receipt-scoped contribution", () => {
  const evidence = fixture();
  evidence.postconditions.boostAccounting.feesForwarded = spec.fee - 1n;
  assert.throws(() => validateUtilityCanaryEvidence(evidence), /fees forwarded ledger is below the canary proof/);
});

test("rejects legacy one-HOOKR Boost canary evidence", () => {
  const evidence = fixture();
  evidence.stages.boost.calldata.grossAmount = spec.lockGross;
  assert.throws(() => validateUtilityCanaryEvidence(evidence), /boost calldata gross is wrong/);
});

test("rejects a changed active-capacity policy or missing canonical membership", () => {
  const wrongCapacity = fixture();
  wrongCapacity.postconditions.boostAccounting.maxActiveBoosts = 513;
  assert.throws(() => validateUtilityCanaryEvidence(wrongCapacity), /maximum active boosts is wrong/);

  const prunedCanary = fixture();
  prunedCanary.postconditions.boostAccounting.registered = false;
  assert.throws(() => validateUtilityCanaryEvidence(prunedCanary), /canonical boost is not registered/);
});

test("rejects duplicate receipts and the wrong Robinhood L1 contract clock", () => {
  const duplicate = fixture();
  duplicate.receiptOrder[7].hash = duplicate.receiptOrder[6].hash;
  assert.throws(() => validateUtilityCanaryEvidence(duplicate), /duplicate hash/);

  const wrongClock = fixture();
  wrongClock.postconditions.boostPosition.startedAtBlock = 106;
  assert.throws(() => validateUtilityCanaryEvidence(wrongClock), /boost L1 block clock is wrong/);
});
