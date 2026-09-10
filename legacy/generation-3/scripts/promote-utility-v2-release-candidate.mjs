#!/usr/bin/env node
/**
 * Read-only utility release candidate promoter.
 *
 * It delegates all chain/artifact verification to the exact 3+2+2+1 receipt verifier, requires the
 * checked-in V2 terms bytes to match the reviewed hash and public copy, validates the exact
 * application-facing field shape, and emits one deterministic JSON candidate to stdout. It never
 * signs, broadcasts, or edits CURRENT.
 */
import { execFileSync } from "node:child_process";
import { verifyUtilityTerms } from "./lib/utility-terms.mjs";
import { buildUtilityV2ReleaseCandidate } from "./lib/utility-v2-release-candidate.mjs";

const argv = process.argv.slice(2);
const flag = (name, fallback) => {
  const index = argv.indexOf(`--${name}`);
  return index >= 0 && argv[index + 1] ? argv[index + 1] : fallback;
};
const REHEARSAL = argv.includes("--rehearsal");
const paths = {
  deploy: flag("deploy", "contracts/broadcast/DeployHookrUtilitiesV2.s.sol/4663/run-latest.json"),
  lock: flag("lock", "contracts/broadcast/CanaryHookrUtilitiesV2Lock.s.sol/4663/run-latest.json"),
  boost: flag("boost", "contracts/broadcast/CanaryHookrUtilitiesV2Boost.s.sol/4663/run-latest.json"),
  claim: flag("claim", "contracts/broadcast/CanaryHookrUtilitiesV2Claim.s.sol/4663/run-latest.json"),
};
const rpc = flag("rpc", "https://rpc.mainnet.chain.robinhood.com");
const coreRelease = flag("core-release", "");
const finalityTimeout = flag("finality-timeout-seconds", "300");

const fail = (message) => {
  console.error(`\nUTILITY V2 RELEASE CANDIDATE BLOCKED: ${message}`);
  process.exit(1);
};

let verifiedTerms;
try {
  verifiedTerms = verifyUtilityTerms();
} catch (error) {
  fail(`canonical utility terms verification failed: ${error.message}`);
}

const verifierArgs = [
  "scripts/verify-utility-v2-canary-evidence.mjs",
  "--deploy",
  paths.deploy,
  "--lock",
  paths.lock,
  "--boost",
  paths.boost,
  "--claim",
  paths.claim,
  "--rpc",
  rpc,
  "--finality-timeout-seconds",
  finalityTimeout,
  "--json",
];
if (REHEARSAL) verifierArgs.push("--rehearsal");
if (coreRelease) verifierArgs.push("--core-release", coreRelease);

let verified;
try {
  const stdout = execFileSync(process.execPath, verifierArgs, {
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
    stdio: ["ignore", "pipe", "pipe"],
  });
  verified = JSON.parse(stdout);
} catch (error) {
  const detail = String(error.stderr ?? "")
    .split("\n")
    .map((line) => line.trim())
    .find(Boolean);
  fail(`exact 3+2+2+1 receipt verifier failed${detail ? `: ${detail}` : ""}`);
}

let candidate;
try {
  candidate = buildUtilityV2ReleaseCandidate(verified, verifiedTerms, REHEARSAL);
} catch (error) {
  fail(error.message);
}

process.stdout.write(`${JSON.stringify(candidate, null, 2)}\n`);
