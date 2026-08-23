import { isAddress } from "viem";

import { validateUtilityV2BootstrapSchedule } from "./utility-v2-canary-evidence.mjs";

const check = (condition, message) => {
  if (!condition) throw new Error(message);
};
const validHash = (value) =>
  typeof value === "string" && /^0x[0-9a-fA-F]{64}$/.test(value) && !/^0x0+$/.test(value);

/** Build the exact schema-3 application manifest from already verified 3+2+2+1 evidence. */
export function buildUtilityV2ReleaseCandidate(verified, verifiedTerms, rehearsal = false) {
  const schedule = validateUtilityV2BootstrapSchedule(verified?.bootstrap);
  const candidate = {
    schema: 3,
    version: 2,
    chainId: 4663,
    productionAllowed: !rehearsal,
    sourceCommit: verified.sourceCommit,
    deployBlock: verified.receiptOrder?.[0]?.blockNumber,
    token: {
      address: verified.identities?.hookrToken,
      runtimeHash: verified.runtimes?.hookrToken,
    },
    supportedCoreReleaseId: verified.core?.id,
    supportedCoreSourceCommit: String(verified.core?.sourceCommit ?? "").replace(/^0x/, "").toLowerCase(),
    contracts: {
      lockRewards: {
        address: verified.identities?.lockRewards,
        runtimeHash: verified.runtimes?.lockRewards,
      },
      launchBoost: {
        address: verified.identities?.launchBoost,
        runtimeHash: verified.runtimes?.launchBoost,
      },
      launchpad: {
        address: verified.identities?.launchpad,
        runtimeHash: verified.runtimes?.launchpad,
      },
    },
    policy: {
      boostFeeBps: 100,
      minGrossBoost: "100000000000000000000",
      maxActiveBoosts: 512,
      rewardEpochSeconds: 604800,
      tiers: [
        { id: 0, label: "30 days", durationDays: 30, multiplierBps: 10000 },
        { id: 1, label: "90 days", durationDays: 90, multiplierBps: 11500 },
        { id: 2, label: "180 days", durationDays: 180, multiplierBps: 12500 },
      ],
      paidRailOnly: true,
      creatorOnly: true,
      principalSlashable: false,
      upgradeable: false,
    },
    bootstrap: {
      epochLengthSeconds: 7200,
      ...schedule,
    },
    linkage: {
      blockNumber: verified.linkage?.blockNumber,
      blockHash: verified.linkage?.blockHash,
    },
    terms: {
      path: verifiedTerms.canonicalPath,
      hash: verifiedTerms.hash,
    },
    evidence: {
      deploymentReceipts: {
        lockRewards: verified.receipts?.deployment?.lockRewardsDeploy,
        launchBoost: verified.receipts?.deployment?.launchBoostDeploy,
        rewardSourceSet: verified.receipts?.deployment?.rewardSourceSet,
      },
      canaryReceipts: {
        lockApproval: verified.receipts?.canary?.approveLock,
        lock: verified.receipts?.canary?.lock,
        boostApproval: verified.receipts?.canary?.approveBoost,
        boost: verified.receipts?.canary?.boost,
        claim: verified.receipts?.canary?.claim,
      },
      canaryReadback: {
        blockNumber: verified.linkage?.blockNumber,
        blockHash: verified.linkage?.blockHash,
      },
    },
  };

  check(/^0x[0-9a-f]{40}$/.test(candidate.sourceCommit), "candidate source commit is malformed");
  check(/^[0-9a-f]{40}$/.test(candidate.supportedCoreSourceCommit), "candidate core source commit is malformed");
  check(candidate.supportedCoreReleaseId === "hookr-4663-v4", "candidate core release id is wrong");
  check(Number.isSafeInteger(candidate.deployBlock) && candidate.deployBlock > 0, "candidate deploy block is wrong");
  const identities = [candidate.token, ...Object.values(candidate.contracts)];
  for (const [index, identity] of identities.entries()) {
    check(isAddress(identity.address, { strict: true }), `candidate identity #${index} address is malformed`);
    check(validHash(identity.runtimeHash), `candidate identity #${index} runtime hash is malformed`);
  }
  const receipts = [
    ...Object.values(candidate.evidence.deploymentReceipts),
    ...Object.values(candidate.evidence.canaryReceipts),
  ];
  check(
    receipts.length === 8 &&
      receipts.every(validHash) &&
      new Set(receipts.map((hash) => hash.toLowerCase())).size === 8,
    "candidate receipt set is not exactly eight unique hashes",
  );
  check(
    Number.isSafeInteger(candidate.linkage.blockNumber) &&
      candidate.linkage.blockNumber >= verified.receiptOrder.at(-1).blockNumber &&
      validHash(candidate.linkage.blockHash),
    "candidate linkage block is malformed or predates the canary",
  );
  check(candidate.terms.path === "docs/HOOKR_UTILITY_TERMS_V2.md", "candidate terms path is not V2");
  check(validHash(candidate.terms.hash), "candidate terms hash is malformed");
  return candidate;
}
