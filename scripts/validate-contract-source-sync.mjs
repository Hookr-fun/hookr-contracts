#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

const ROOT = resolve(import.meta.dirname, "..");
const manifest = JSON.parse(
  await readFile(resolve(ROOT, "contracts/source-sync.v1.json"), "utf8"),
);

if (manifest.schemaVersion !== "hookr.contract-source-sync.v1") {
  throw new Error("unsupported contract source-sync manifest");
}
if (!/^[0-9a-f]{40}$/.test(manifest.upstreamCommit)) {
  throw new Error("source-sync upstreamCommit must be a full Git SHA");
}

for (const [path, expectedTree] of Object.entries(manifest.gitTrees ?? {})) {
  if (!/^contracts\/(src|script|test)$/.test(path)) {
    throw new Error(`unsupported source-sync path: ${path}`);
  }
  if (!/^[0-9a-f]{40}$/.test(String(expectedTree))) {
    throw new Error(`invalid source-sync tree for ${path}`);
  }

  const actualTree = execFileSync("git", ["rev-parse", `HEAD:${path}`], {
    cwd: ROOT,
    encoding: "utf8",
  }).trim();
  if (actualTree !== expectedTree) {
    throw new Error(
      `${path} differs from upstream ${manifest.upstreamCommit}: expected ${expectedTree}, received ${actualTree}`,
    );
  }
  console.log(`${path} matches ${expectedTree}`);
}
