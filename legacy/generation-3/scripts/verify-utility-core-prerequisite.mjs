#!/usr/bin/env node
/** Read-only generation-4 prerequisite. It never signs, broadcasts, or writes. */
import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { createPublicClient, http } from "viem";

import { verifyUtilityCorePrerequisite } from "./lib/utility-core-prerequisite.mjs";

const argv = process.argv.slice(2);
const flag = (name, fallback = "") => {
  const index = argv.indexOf(`--${name}`);
  return index >= 0 && argv[index + 1] ? argv[index + 1] : fallback;
};
const rehearsal = argv.includes("--rehearsal");
const rpc = flag("rpc", "https://rpc.mainnet.chain.robinhood.com");
const coreReleasePath = flag("core-release");
const launchpad = flag("launchpad", process.env.HOOKR_UTILITY_LAUNCHPAD_ADDRESS ?? "");
const launchpadCodehash = flag(
  "launchpad-codehash",
  process.env.HOOKR_UTILITY_LAUNCHPAD_RUNTIME_CODEHASH ?? "",
);

const fail = (message) => {
  console.error(`\nUTILITY CORE PREREQUISITE BLOCKED: ${message}`);
  process.exit(1);
};
const load = (path) => {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    fail(`cannot read ${path}: ${error.message}`);
  }
};

let rpcUrl;
try {
  rpcUrl = new URL(rpc);
} catch {
  fail(`--rpc is not a valid URL: ${rpc}`);
}
const loopback = rpcUrl.hostname === "localhost" ||
  rpcUrl.hostname === "::1" ||
  rpcUrl.hostname === "[::1]" ||
  /^127\./.test(rpcUrl.hostname);
if (rehearsal && !loopback) fail("--rehearsal is only allowed against a loopback RPC");
if (!rehearsal && loopback) fail("a loopback prerequisite requires --rehearsal");
if (!rehearsal && rpcUrl.protocol !== "https:") fail("production prerequisite requires an https RPC");
if (coreReleasePath && !rehearsal) fail("--core-release override is rehearsal-only");
if (!rehearsal) {
  const provenancePaths = [
    "src/lib/release-manifest.ts",
    "scripts/lib/utility-core-prerequisite.mjs",
    "scripts/verify-utility-core-prerequisite.mjs",
    "contracts/script/DeployHookrUtilities.s.sol",
    "contracts/src",
  ];
  const dirty = execFileSync("git", ["status", "--porcelain", "--", ...provenancePaths], {
    encoding: "utf8",
  }).trim();
  if (dirty) fail("core manifest or prerequisite/deploy inputs are dirty; production provenance is not attributable");
}

let helpers;
try {
  helpers = await import("../src/lib/release-manifest.ts");
} catch (error) {
  fail(`cannot load core release helpers: ${error.message}`);
}
const manifest = coreReleasePath ? load(coreReleasePath) : helpers.CURRENT_RELEASE_MANIFEST;
const client = createPublicClient({ transport: http(rpc) });
try {
  const proof = await verifyUtilityCorePrerequisite({
    client,
    manifest,
    releaseGateBlockers: helpers.releaseGateBlockers,
    releaseIdOf: helpers.releaseIdOf,
    expectedLaunchpadAddress: launchpad,
    expectedLaunchpadRuntimeHash: launchpadCodehash,
    blockTag: rehearsal ? "latest" : "safe",
  });
  console.log("UTILITY CORE PREREQUISITE OK (read-only)");
  console.log(`  release   ${proof.releaseId}`);
  console.log(`  launchpad ${proof.launchpad} ${proof.liveRuntimeHash}`);
  console.log(`  block     #${proof.blockNumber} ${proof.blockHash}`);
  console.log(`  canary    ${proof.canaryToken} ${proof.canaryIntent}`);
} catch (error) {
  fail(error instanceof Error ? error.message : String(error));
}
