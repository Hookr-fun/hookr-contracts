#!/usr/bin/env node

import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));
const ignored = new Set([".git", "cache", "dist", "legacy", "lib", "node_modules", "out"]);

// The one file allowed under scripts/. It reads a release journal and rewrites
// the addresses in docs/reference/deployments.md, deployments/robinhood-4663.v2.json
// and the hooklist entry. It signs nothing, sends nothing and holds no key.
const allowedPaths = new Set(["scripts/sync-from-release.mjs"]);

const forbiddenPaths = [
  /^app(?:\/|$)/,
  /^contracts(?:\/|$)/,
  /^script(?:\/|$)/,
  /^scripts(?:\/|$)/,
  /^broadcast(?:\/|$)/,
  /^release-evidence(?:\/|$)/,
  /^supabase(?:\/|$)/,
  /(?:^|\/)\.env(?:\.|$)/,
  /(?:^|\/)run-latest\.json$/,
];
const forbiddenSourcePatterns = [
  ["broadcast cheatcode", /\b(?:startBroadcast|broadcast)\s*\(/],
  ["RPC endpoint configuration", /\[rpc_endpoints\]/],
  ["secret environment input", /\benv(?:Uint|Bytes32|Address|String|Bytes)\s*\(/],
  ["private-key label", /\b(?:PRIVATE_KEY|MNEMONIC|SEED_PHRASE)\b/],
  ["PEM private key", /-----BEGIN [A-Z ]*PRIVATE KEY-----/],
  ["GitHub access token", /\bgh[pousr]_[A-Za-z0-9]{20,}\b/],
  ["OpenAI-style secret key", /\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b/],
  ["AWS access key", /\bAKIA[A-Z0-9]{16}\b/],
  ["credential-bearing URL", /https?:\/\/[^\s/:]+:[^\s/@]+@/],
];

const files = [];
function visit(directory) {
  for (const name of readdirSync(directory).sort()) {
    if (ignored.has(name) || name.startsWith("out-")) continue;
    const candidate = join(directory, name);
    const path = relative(root, candidate).split(sep).join("/");
    if (statSync(candidate).isDirectory()) visit(candidate);
    else files.push({ candidate, path });
  }
}
visit(root);

const failures = [];
for (const { candidate, path } of files) {
  if (!allowedPaths.has(path)) {
    for (const pattern of forbiddenPaths) {
      if (pattern.test(path)) failures.push(`${path}: forbidden review-package path`);
    }
  }
  if (!/\.(?:sol|toml|ya?ml)$/.test(path)) continue;
  const contents = readFileSync(candidate, "utf8");
  for (const [label, pattern] of forbiddenSourcePatterns) {
    if (pattern.test(contents)) failures.push(`${path}: contains ${label}`);
  }
}

if (failures.length > 0) {
  console.error(failures.join("\n"));
  process.exitCode = 1;
} else {
  console.log(`review boundary verified (${files.length} files scanned)`);
}
