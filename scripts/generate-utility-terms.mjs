#!/usr/bin/env node
/**
 * Explicitly regenerate the reviewed utility terms hash and byte-identical public Markdown.
 *
 * This is never a prebuild step: builds verify checked-in truth and must not silently bless edits.
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import {
  REPOSITORY_ROOT,
  UTILITY_TERMS_ARTIFACT_PATH,
  UTILITY_TERMS_CANONICAL_PATH,
  UTILITY_TERMS_PUBLIC_FILE,
  UTILITY_TERMS_PUBLIC_PATH,
  hashUtilityTerms,
} from "./lib/utility-terms.mjs";

const canonicalBytes = readFileSync(resolve(REPOSITORY_ROOT, UTILITY_TERMS_CANONICAL_PATH));
const hash = hashUtilityTerms(canonicalBytes);
const artifact = {
  schema: 1,
  canonicalPath: UTILITY_TERMS_CANONICAL_PATH,
  publicPath: UTILITY_TERMS_PUBLIC_PATH,
  byteLength: canonicalBytes.byteLength,
  keccak256: hash,
};
const publicFile = resolve(REPOSITORY_ROOT, UTILITY_TERMS_PUBLIC_FILE);
const artifactFile = resolve(REPOSITORY_ROOT, UTILITY_TERMS_ARTIFACT_PATH);

mkdirSync(dirname(publicFile), { recursive: true });
writeFileSync(publicFile, canonicalBytes);
writeFileSync(artifactFile, `${JSON.stringify(artifact, null, 2)}\n`, "utf8");

console.log(`${UTILITY_TERMS_CANONICAL_PATH}: ${canonicalBytes.byteLength} bytes`);
console.log(`keccak256: ${hash}`);
console.log(`public copy: ${UTILITY_TERMS_PUBLIC_FILE}`);
console.log(`hash artifact: ${UTILITY_TERMS_ARTIFACT_PATH}`);
