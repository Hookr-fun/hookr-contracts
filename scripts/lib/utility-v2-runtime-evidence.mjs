import { getAddress, keccak256 } from "viem";

import {
  REVIEWED_COMPILER_SETTINGS,
  deriveRuntimeReferenceLayoutHash,
} from "./runtime-template-evidence.mjs";

/** Reviewed V2 utility runtime templates. This evidence is isolated from historical V1. */
export const UTILITY_V2_RUNTIME_ARTIFACTS = Object.freeze({
  lockRewards: Object.freeze({
    path: "contracts/out/HookrLockRewardsV2.sol/HookrLockRewardsV2.json",
    sourcePath: "src/HookrLockRewardsV2.sol",
    contractName: "HookrLockRewardsV2",
  }),
  launchBoost: Object.freeze({
    path: "contracts/out/HookrLaunchBoostV2.sol/HookrLaunchBoostV2.json",
    sourcePath: "src/HookrLaunchBoostV2.sol",
    contractName: "HookrLaunchBoostV2",
  }),
});

/**
 * Re-derived from source-matched Foundry artifacts on 2026-08-11. Any source, compiler,
 * optimizer, immutable layout, or bytecode change must stop release verification until reviewed.
 */
export const REVIEWED_UTILITY_V2_NORMALIZED_RUNTIME_HASHES = Object.freeze({
  lockRewards: "0xe1ba243b3e57b658acde08b28228b61e9dd10490d0f8873004e2524597634471",
  launchBoost: "0xb5a5de4ac75cafef0c5a8c44f78ee1a44d670ed429ea32d64ad65988d1a8a51f",
});

export const REVIEWED_UTILITY_V2_RUNTIME_REFERENCE_LAYOUT_HASHES = Object.freeze({
  lockRewards: "0xeab4af9818e84eb5280fe10b12187df301002856a7decb6d89ae37c4937cb903",
  launchBoost: "0x932e1c383e29de82a45cf6a5d8895f0c82d7103da612f97a9fe855bb6197aca1",
});

const check = (condition, message) => {
  if (!condition) throw new Error(message);
};
const strip0x = (value) => String(value ?? "").replace(/^0x/, "");
const sameHex = (left, right) =>
  typeof left === "string" &&
  typeof right === "string" &&
  left.toLowerCase() === right.toLowerCase();

export function utilityV2AddressWord(address) {
  return `0x${"0".repeat(24)}${getAddress(address).slice(2).toLowerCase()}`;
}

export function utilityV2UintWord(value) {
  const integer = BigInt(value);
  check(integer >= 0n && integer < (1n << 256n), "V2 immutable integer is out of uint256 range");
  return `0x${integer.toString(16).padStart(64, "0")}`;
}

function assertCompilerAndTarget(artifact, expectedTarget, label) {
  const metadata = artifact?.metadata;
  const settings = metadata?.settings;
  check(metadata?.compiler?.version === REVIEWED_COMPILER_SETTINGS.compilerVersion, `${label} compiler version is not reviewed`);
  check(settings?.optimizer?.enabled === true, `${label} optimizer is disabled`);
  check(settings?.optimizer?.runs === REVIEWED_COMPILER_SETTINGS.optimizerRuns, `${label} optimizer runs are not reviewed`);
  check(settings?.viaIR === true, `${label} was not compiled via IR`);
  check(settings?.evmVersion === REVIEWED_COMPILER_SETTINGS.evmVersion, `${label} EVM version is not reviewed`);
  check(settings?.metadata?.bytecodeHash === "none", `${label} embeds an unreviewed metadata hash`);
  check(settings?.libraries && Object.keys(settings.libraries).length === 0, `${label} metadata contains prelinked libraries`);
  const targets = Object.entries(settings?.compilationTarget ?? {});
  check(targets.length === 1, `${label} must contain exactly one compilation target`);
  check(
    targets[0]?.[0] === expectedTarget.sourcePath && targets[0]?.[1] === expectedTarget.contractName,
    `${label} compilation target is not reviewed`,
  );
}

/**
 * V2 adds uint40 timing immutables, so V1's address-only runtime masker is not sufficient. This
 * validator pins the exact compiler reference layout and normalized bytes, then checks the
 * multiset of every live 32-byte immutable word against constructor and schedule evidence.
 */
export function validateReviewedUtilityV2Runtime({
  artifact,
  liveCode,
  expectedTarget,
  expectedImmutableWords,
  expectedNormalizedTemplateHash,
  expectedReferenceLayoutHash,
  label = expectedTarget.contractName,
}) {
  assertCompilerAndTarget(artifact, expectedTarget, label);
  const links = artifact?.deployedBytecode?.linkReferences ?? {};
  check(Object.keys(links).length === 0, `${label} contains unexpected runtime links`);
  const template = strip0x(artifact?.deployedBytecode?.object);
  const live = strip0x(liveCode);
  check(/^([0-9a-fA-F]{2})+$/.test(template), `${label} runtime template is malformed`);
  check(/^([0-9a-fA-F]{2})+$/.test(live), `${label} live runtime is malformed`);
  check(live.length === template.length, `${label} live runtime length differs from the reviewed template`);
  const layoutHash = deriveRuntimeReferenceLayoutHash(artifact);
  check(
    sameHex(layoutHash, expectedReferenceLayoutHash),
    `${label} compiler reference layout is not the reviewed anchor (candidate ${layoutHash}, reviewed ${expectedReferenceLayoutHash})`,
  );

  const templateChars = template.toLowerCase().split("");
  const liveChars = live.toLowerCase().split("");
  const byteLength = template.length / 2;
  const masked = new Uint8Array(byteLength);
  const actualWords = [];
  const groups = Object.values(artifact?.deployedBytecode?.immutableReferences ?? {});
  check(groups.length === expectedImmutableWords.length, `${label} immutable group count changed`);
  for (const references of groups) {
    check(Array.isArray(references) && references.length > 0, `${label} immutable group is empty`);
    let groupWord = null;
    for (const reference of references) {
      const { start, length } = reference ?? {};
      check(Number.isInteger(start) && Number.isInteger(length) && start >= 0 && length === 32, `${label} immutable reference is malformed`);
      check(start + length <= byteLength, `${label} immutable reference is out of bounds`);
      for (let offset = start; offset < start + length; offset += 1) {
        check(masked[offset] === 0, `${label} immutable ranges overlap at byte ${offset}`);
        masked[offset] = 1;
      }
      const templateWord = template.slice(start * 2, (start + length) * 2);
      const liveWord = live.slice(start * 2, (start + length) * 2).toLowerCase();
      check(/^0+$/.test(templateWord), `${label} immutable template word is not zero-filled`);
      if (groupWord === null) groupWord = liveWord;
      check(liveWord === groupWord, `${label} immutable group has inconsistent live values`);
      templateChars.splice(start * 2, length * 2, ..."0".repeat(length * 2));
      liveChars.splice(start * 2, length * 2, ..."0".repeat(length * 2));
    }
    actualWords.push(`0x${groupWord}`);
  }

  const canonicalWords = (words) => words.map((word) => String(word).toLowerCase()).sort();
  check(
    JSON.stringify(canonicalWords(actualWords)) === JSON.stringify(canonicalWords(expectedImmutableWords)),
    `${label} immutable values differ from constructor and schedule evidence`,
  );
  const normalizedTemplate = `0x${templateChars.join("")}`;
  const normalizedLive = `0x${liveChars.join("")}`;
  const normalizedTemplateHash = keccak256(normalizedTemplate);
  check(
    sameHex(normalizedTemplateHash, expectedNormalizedTemplateHash),
    `${label} normalized template hash is not the reviewed anchor (candidate ${normalizedTemplateHash}, reviewed ${expectedNormalizedTemplateHash})`,
  );
  check(normalizedTemplate === normalizedLive, `${label} live runtime differs outside reviewed immutable ranges`);
  return Object.freeze({
    runtimeHash: keccak256(`0x${live}`),
    normalizedTemplateHash,
    referenceLayoutHash: layoutHash,
    immutableWords: Object.freeze(canonicalWords(actualWords)),
  });
}
