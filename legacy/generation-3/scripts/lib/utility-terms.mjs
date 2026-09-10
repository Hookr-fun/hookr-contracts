import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { keccak256, toHex } from "viem";

export const UTILITY_TERMS_CANONICAL_PATH = "docs/HOOKR_UTILITY_TERMS_V2.md";
export const UTILITY_TERMS_PUBLIC_PATH = "/terms/HOOKR_UTILITY_TERMS_V2.md";
export const UTILITY_TERMS_PUBLIC_FILE = "public/terms/HOOKR_UTILITY_TERMS_V2.md";
export const UTILITY_TERMS_ARTIFACT_PATH = "src/lib/utility-terms.generated.json";

export const REPOSITORY_ROOT = fileURLToPath(new URL("../../", import.meta.url));

export function hashUtilityTerms(bytes) {
  return keccak256(toHex(bytes));
}

function readJson(path) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    throw new Error(`cannot read generated terms artifact: ${error.message}`);
  }
}

/**
 * Verify the exact release bytes shared by the app, public static asset, and promoter.
 *
 * This function intentionally does not regenerate anything. A terms edit must be followed by the
 * explicit generator and a review of the changed Markdown plus hash artifact; build/test may only
 * verify that checked-in state.
 */
export function verifyUtilityTerms(root = REPOSITORY_ROOT) {
  const canonicalPath = resolve(root, UTILITY_TERMS_CANONICAL_PATH);
  const publicFile = resolve(root, UTILITY_TERMS_PUBLIC_FILE);
  const artifactPath = resolve(root, UTILITY_TERMS_ARTIFACT_PATH);

  let canonicalBytes;
  let publicBytes;
  try {
    canonicalBytes = readFileSync(canonicalPath);
  } catch (error) {
    throw new Error(`cannot read ${UTILITY_TERMS_CANONICAL_PATH}: ${error.message}`);
  }
  try {
    publicBytes = readFileSync(publicFile);
  } catch (error) {
    throw new Error(`cannot read ${UTILITY_TERMS_PUBLIC_FILE}: ${error.message}`);
  }

  const artifact = readJson(artifactPath);
  if (
    artifact?.schema !== 1 ||
    artifact.canonicalPath !== UTILITY_TERMS_CANONICAL_PATH ||
    artifact.publicPath !== UTILITY_TERMS_PUBLIC_PATH ||
    artifact.byteLength !== canonicalBytes.byteLength ||
    typeof artifact.keccak256 !== "string" ||
    !/^0x[0-9a-f]{64}$/.test(artifact.keccak256) ||
    /^0x0+$/.test(artifact.keccak256)
  ) {
    throw new Error("generated utility terms artifact is malformed or describes different bytes");
  }

  const hash = hashUtilityTerms(canonicalBytes);
  if (hash !== artifact.keccak256) {
    throw new Error(
      `${UTILITY_TERMS_CANONICAL_PATH} does not match the checked-in expected Keccak-256 ${artifact.keccak256}`,
    );
  }
  if (!canonicalBytes.equals(publicBytes)) {
    throw new Error(
      `${UTILITY_TERMS_PUBLIC_FILE} is not byte-identical to ${UTILITY_TERMS_CANONICAL_PATH}`,
    );
  }

  return Object.freeze({
    canonicalPath: UTILITY_TERMS_CANONICAL_PATH,
    publicPath: UTILITY_TERMS_PUBLIC_PATH,
    publicFile: UTILITY_TERMS_PUBLIC_FILE,
    byteLength: canonicalBytes.byteLength,
    hash,
  });
}
