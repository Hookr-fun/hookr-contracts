import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  REVIEWED_UTILITY_V2_NORMALIZED_RUNTIME_HASHES,
  REVIEWED_UTILITY_V2_RUNTIME_REFERENCE_LAYOUT_HASHES,
  UTILITY_V2_RUNTIME_ARTIFACTS,
  utilityV2AddressWord,
  utilityV2UintWord,
  validateReviewedUtilityV2Runtime,
} from "./lib/utility-v2-runtime-evidence.mjs";

const TOKEN = "0x1111111111111111111111111111111111111111";
const DEPLOYER = "0x2222222222222222222222222222222222222222";
const LAUNCHPAD = "0x3333333333333333333333333333333333333333";
const REWARDS = "0x4444444444444444444444444444444444444444";
const START = 1_800_000_000n;
const FEE = START + 7_200n;
const CLAIM = FEE + 7_200n;
const WEEKLY = 1_800_403_200n;

const load = (target) => JSON.parse(readFileSync(target.path, "utf8"));

function materialize(artifact, words) {
  const chars = artifact.deployedBytecode.object.replace(/^0x/, "").split("");
  const groups = Object.values(artifact.deployedBytecode.immutableReferences);
  assert.equal(groups.length, words.length);
  groups.forEach((references, index) => {
    const word = words[index].slice(2);
    for (const { start, length } of references) {
      assert.equal(length, 32);
      chars.splice(start * 2, length * 2, ...word);
    }
  });
  return `0x${chars.join("")}`;
}

test("pins V2 Rewards scalar and address immutable words", () => {
  const target = UTILITY_V2_RUNTIME_ARTIFACTS.lockRewards;
  const artifact = load(target);
  const words = [
    utilityV2AddressWord(TOKEN),
    utilityV2UintWord(START),
    utilityV2UintWord(FEE),
    utilityV2UintWord(CLAIM),
    utilityV2UintWord(WEEKLY),
  ];
  const proof = validateReviewedUtilityV2Runtime({
    artifact,
    liveCode: materialize(artifact, words),
    expectedTarget: target,
    expectedImmutableWords: words,
    expectedNormalizedTemplateHash: REVIEWED_UTILITY_V2_NORMALIZED_RUNTIME_HASHES.lockRewards,
    expectedReferenceLayoutHash: REVIEWED_UTILITY_V2_RUNTIME_REFERENCE_LAYOUT_HASHES.lockRewards,
  });
  assert.equal(proof.immutableWords.length, 5);
});

test("pins V2 Boost opening and linkage immutable words and rejects drift", () => {
  const target = UTILITY_V2_RUNTIME_ARTIFACTS.launchBoost;
  const artifact = load(target);
  const words = [
    utilityV2AddressWord(TOKEN),
    utilityV2AddressWord(LAUNCHPAD),
    utilityV2AddressWord(REWARDS),
    utilityV2UintWord(FEE),
  ];
  const liveCode = materialize(artifact, words);
  const input = {
    artifact,
    liveCode,
    expectedTarget: target,
    expectedImmutableWords: words,
    expectedNormalizedTemplateHash: REVIEWED_UTILITY_V2_NORMALIZED_RUNTIME_HASHES.launchBoost,
    expectedReferenceLayoutHash: REVIEWED_UTILITY_V2_RUNTIME_REFERENCE_LAYOUT_HASHES.launchBoost,
  };
  assert.doesNotThrow(() => validateReviewedUtilityV2Runtime(input));
  assert.throws(
    () => validateReviewedUtilityV2Runtime({
      ...input,
      expectedImmutableWords: [...words.slice(0, 3), utilityV2UintWord(FEE + 1n)],
    }),
    /immutable values differ/,
  );
  assert.notEqual(DEPLOYER, TOKEN);
});
