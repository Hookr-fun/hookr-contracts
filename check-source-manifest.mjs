#!/usr/bin/env node

/**
 * Verifies that every Solidity file under src/ is a byte-for-byte copy of the
 * Hookr source repository at one pinned commit.
 *
 * `node check-source-manifest.mjs` compares SOURCE_MANIFEST.json against the
 * files on disk: the inventory must match exactly and every sha256 must agree.
 * `--write` regenerates the manifest. `--source-git <path>` additionally reads
 * each file out of a local clone at the pinned commit and requires the bytes to
 * be identical, which is the check that proves provenance rather than
 * self-consistency.
 */

import { createHash } from "node:crypto";
import { existsSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, relative, resolve, sep } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const repositoryRoot = dirname(fileURLToPath(import.meta.url));
const manifestPath = join(repositoryRoot, "SOURCE_MANIFEST.json");
const sourceRepository = "https://github.com/Hookr-fun/hookr.git";
const sourceCommit = "5baea2799015ff7c46ff69fcc08e7d0ba1d4223e";
const exportRoots = ["src"];

/** Deployed at its own address by this release, or linked from one it already had. */
const deployed = new Set([
  "src/HookrKernelQuoterV1.sol",
  "src/HookrKernelRouterV3.sol",
  "src/HookrMarketCoordinatorV5.sol",
  "src/HookrModularHookV6.sol",
  "src/HookrModularHookV6WthV5.sol",
  "src/HookrModuleCatalogV1.sol",
  "src/HookrNativeMechanicsBlockV2.sol",
  "src/HookrReleaseCreate2FactoryV1.sol",
  "src/HookrStackRegistryV2.sol",
  "src/HookrSwapAccountingKernelV3.sol",
  "src/HookrTreasuryForwarderV1.sol",
  "src/HookrWthExecutorAdapterV1.sol",
  "src/libraries/HookrMarketCoordinatorInitialBuyLibV4.sol",
  "src/libraries/HookrModularCorrectionLibV2.sol",
  "src/libraries/HookrModularCorrectionLibV3.sol",
  "src/libraries/HookrNativeMechanicsCoordinatorLibV2.sol",
  "src/libraries/HookrStatefulSettlementLibV1.sol",
]);

/** Compiled into a deployed contract rather than deployed on its own: a base
 *  contract, the compilation unit of a linked library, or the token the
 *  coordinator deploys per market. */
const compiledInto = new Set([
  "src/HookrMarketCoordinatorV3.sol",
  "src/HookrStackRegistryV1.sol",
  "src/HookrSwapKernelV3.sol",
  "src/HookrSwapKernelV5Wth.sol",
  "src/HookrTokenV61.sol",
]);

function toPosix(path) {
  return path.split(sep).join("/");
}

function exportedFiles() {
  const files = [];
  const visit = (absolutePath) => {
    for (const name of readdirSync(absolutePath).sort()) {
      const candidate = join(absolutePath, name);
      if (statSync(candidate).isDirectory()) visit(candidate);
      else {
        const path = toPosix(relative(repositoryRoot, candidate));
        if (path.endsWith(".sol")) files.push(path);
      }
    }
  };
  for (const root of exportRoots) visit(join(repositoryRoot, root));
  return files.sort();
}

function sha256(contents) {
  return createHash("sha256").update(contents).digest("hex");
}

function roleFor(path) {
  if (deployed.has(path)) return "deployed";
  if (compiledInto.has(path)) return "compiled-into-a-deployed-contract";
  if (path.startsWith("src/interfaces/")) return "interface";
  return "library";
}

function entryFor(path) {
  return {
    path,
    role: roleFor(path),
    source_repository: sourceRepository,
    source_path: `contracts/${path}`,
    source_commit: sourceCommit,
    sha256: sha256(readFileSync(join(repositoryRoot, path))),
  };
}

function sourceGitArgument(args) {
  const index = args.indexOf("--source-git");
  if (index === -1) return undefined;
  if (!args[index + 1]) throw new Error("--source-git requires a repository path");
  return resolve(args[index + 1]);
}

function readSourceBlob(sourceGit, entry) {
  const result = spawnSync("git", ["-C", sourceGit, "show", `${entry.source_commit}:${entry.source_path}`], {
    encoding: null,
    maxBuffer: 32 * 1024 * 1024,
  });
  if (result.status !== 0) {
    throw new Error(`cannot read ${entry.source_path} at ${entry.source_commit}: ${result.stderr.toString().trim()}`);
  }
  return result.stdout;
}

function verifySourceGit(sourceGit, entries) {
  for (const entry of entries) {
    const sourceBlob = readSourceBlob(sourceGit, entry);
    const exportedBlob = readFileSync(join(repositoryRoot, entry.path));
    if (!sourceBlob.equals(exportedBlob)) {
      throw new Error(`${entry.path} differs byte-for-byte from ${entry.source_path} at ${entry.source_commit}`);
    }
  }
}

function writeManifest(sourceGit) {
  const files = exportedFiles().map(entryFor);
  if (sourceGit) verifySourceGit(sourceGit, files);
  const manifest = {
    schema_version: 1,
    scope:
      "Byte-for-byte export of the Solidity sources behind the Hookr contracts on chain 4663: " +
      "every deployed contract, plus the interfaces, types and libraries they import transitively.",
    source_repository: sourceRepository,
    source_commit: sourceCommit,
    hash_algorithm: "sha256",
    generated_by: "node check-source-manifest.mjs --write",
    files,
  };
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  console.log(`wrote ${relative(repositoryRoot, manifestPath)} (${files.length} files)`);
}

function checkManifest(sourceGit) {
  if (!existsSync(manifestPath)) throw new Error("SOURCE_MANIFEST.json is missing");
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  if (manifest.source_repository !== sourceRepository || manifest.source_commit !== sourceCommit) {
    throw new Error("manifest source identity does not match the review export identity");
  }
  const actualPaths = exportedFiles();
  const manifestPaths = manifest.files.map((entry) => entry.path);
  if (JSON.stringify(manifestPaths) !== JSON.stringify(actualPaths)) {
    throw new Error("manifest file inventory is stale; run with --write after intentional scope review");
  }
  for (const entry of manifest.files) {
    const expected = entryFor(entry.path);
    if (JSON.stringify(entry) !== JSON.stringify(expected)) {
      throw new Error(`manifest entry is stale or malformed: ${entry.path}`);
    }
  }
  if (sourceGit) verifySourceGit(sourceGit, manifest.files);
  console.log(`SOURCE_MANIFEST.json verified (${manifest.files.length} files)`);
}

try {
  const args = process.argv.slice(2);
  const sourceGit = sourceGitArgument(args);
  if (args.includes("--write")) writeManifest(sourceGit);
  else checkManifest(sourceGit);
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
}
