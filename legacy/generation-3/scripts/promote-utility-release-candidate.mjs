#!/usr/bin/env node
/**
 * Historical V1 utility promotion is permanently retired. V1 never completed the fee/claim
 * canary and is exposed only through runtime-verified position recovery.
 */
console.error(
  "UTILITY V1 RELEASE CANDIDATE RETIRED: V1 is superseded and recovery-only; use promote-utility-v2-release-candidate.mjs after exact 3+2+2+1 V2 evidence.",
);
process.exitCode = 1;
