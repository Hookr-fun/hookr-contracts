#!/usr/bin/env node
import { verifyUtilityTerms } from "./lib/utility-terms.mjs";

try {
  const verified = verifyUtilityTerms();
  console.log(
    `verified ${verified.canonicalPath}: ${verified.byteLength} bytes, keccak256 ${verified.hash}`,
  );
  console.log(`public bytes: ${verified.publicPath}`);
} catch (error) {
  console.error(`UTILITY TERMS VERIFICATION FAILED: ${error.message}`);
  process.exitCode = 1;
}
