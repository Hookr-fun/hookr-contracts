/**
 * Pinned utility-only candidate runtime anchors. These are intentionally separate from generation 4's
 * core runtime anchors so changing or releasing the optional utility rail cannot alter the core
 * ten-receipt deployment verifier.
 *
 * Re-derived twice from the Foundry artifacts on 2026-08-11. They make the verifier fail closed,
 * but are not deployment approval. A reviewer must approve these initial values before production;
 * any later contract-source, compiler, optimizer, via-IR, EVM, immutable-layout, or link-layout
 * change must stop preflight until replacement values are reproduced and reviewed.
 */
export const UTILITY_RUNTIME_ARTIFACTS = Object.freeze({
  lockRewards: Object.freeze({
    path: "contracts/out/HookrLockRewardsV1.sol/HookrLockRewardsV1.json",
    sourcePath: "src/HookrLockRewardsV1.sol",
    contractName: "HookrLockRewardsV1",
  }),
  launchBoost: Object.freeze({
    path: "contracts/out/HookrLaunchBoostV1.sol/HookrLaunchBoostV1.json",
    sourcePath: "src/HookrLaunchBoostV1.sol",
    contractName: "HookrLaunchBoostV1",
  }),
});

export const REVIEWED_UTILITY_NORMALIZED_RUNTIME_HASHES = Object.freeze({
  lockRewards: "0xeb9f5ba2af2968436aa17f5fa5730e4536d82db6550b1a4003c10ab789c69a3d",
  launchBoost: "0x0219dc68d4feb8c9daa3dae925d03f1a25c31db54f29280150db64535cbd13ba",
});

export const REVIEWED_UTILITY_RUNTIME_REFERENCE_LAYOUT_HASHES = Object.freeze({
  lockRewards: "0xd26de9d715a17cbc674c27f30ce7eee9cb3cfcae3efbb05e52594dc4bcea3a70",
  launchBoost: "0x86b161c8c80f1cdda580d0bcb162c6247ab4bca0448e29159ddb4d4dd153b2c6",
});
