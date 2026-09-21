#!/usr/bin/env node

/**
 * Pins the storage layout of every contract under src/.
 *
 * `node check-storage-layout.mjs` runs `forge inspect <Contract> storage-layout`
 * for each contract STORAGE_LAYOUT.json lists and fails when a slot, offset,
 * label, type or struct member differs, when a contract gains or loses storage,
 * or when a source appears under src/ without an entry. `--write` regenerates
 * the file; review that diff the way a deployment is reviewed.
 *
 * HookrSwapKernelV3 and HookrSwapKernelV5Wth run HookrSwapAccountingKernelV3 by
 * DELEGATECALL, so the roots that inherit them execute the accounting kernel's
 * layout inside their own storage: slot 0 is `_inFlight`, slot 1 is
 * `_callbackState`, and the hosts declare nothing of their own. That is an
 * implicit contract between two compilation units. A later revision that adds a
 * variable to a host, or reorders the accounting kernel, would corrupt live swap
 * state without a compiler error; this check turns it into a failed build. The
 * keccak-namespaced correction slots the recapture kernel reads are constants in
 * source, invisible to `forge inspect`, and pinned by SOURCE_MANIFEST.json.
 *
 * AST ids are stripped from type names before comparison. They renumber whenever
 * a declaration is added anywhere in the unit and carry no layout meaning.
 */

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));
const goldenPath = join(root, "STORAGE_LAYOUT.json");
const write = process.argv.includes("--write");

/**
 * These host the accounting kernel's layout by DELEGATECALL and must own no storage. The default
 * root and its kernel base, and the recapture root and its kernel base.
 */
const delegatecallHosts = ["HookrModularHookV6", "HookrSwapKernelV3", "HookrModularHookV6WthV5", "HookrSwapKernelV5Wth"];

function fail(message) {
  console.error(message);
  process.exit(1);
}

function contractNames() {
  return readdirSync(join(root, "src"))
    .filter((name) => name.endsWith(".sol"))
    .map((name) => name.slice(0, -".sol".length))
    .sort();
}

const stripIds = (text) => text.replace(/\)\d+/g, ")");

function inspect(name) {
  const result = spawnSync("forge", ["inspect", name, "storage-layout", "--json"], {
    cwd: root,
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  if (result.status !== 0) fail(`forge inspect ${name} failed\n${(result.stderr ?? "").trim()}`);
  const parsed = JSON.parse(result.stdout);
  const storage = (parsed.storage ?? []).map((entry) => ({
    slot: entry.slot,
    offset: entry.offset,
    label: entry.label,
    type: stripIds(entry.type),
  }));
  const types = {};
  const entries = Object.entries(parsed.types ?? {}).sort(([a], [b]) => stripIds(a).localeCompare(stripIds(b)));
  for (const [key, value] of entries) {
    const type = { encoding: value.encoding, label: stripIds(value.label), numberOfBytes: value.numberOfBytes };
    if (value.key) type.key = stripIds(value.key);
    if (value.value) type.value = stripIds(value.value);
    if (value.base) type.base = stripIds(value.base);
    if (value.members) {
      type.members = value.members.map((member) => ({
        slot: member.slot,
        offset: member.offset,
        label: member.label,
        type: stripIds(member.type),
      }));
    }
    types[stripIds(key)] = type;
  }
  return { storage, types };
}

function describe(layout) {
  if (layout.storage.length === 0) return "    (no storage)";
  return layout.storage
    .map((entry) => `    slot ${entry.slot} offset ${entry.offset}  ${entry.label}: ${entry.type}`)
    .join("\n");
}

const names = contractNames();
const current = {};
for (const name of names) current[name] = inspect(name);

for (const host of delegatecallHosts) {
  if (!current[host]) fail(`${host} is listed as a delegatecall host but has no source under src/.`);
  if (current[host].storage.length > 0) {
    const labels = current[host].storage.map((entry) => entry.label).join(", ");
    fail(
      `${host} declares storage (${labels}) but hosts HookrSwapAccountingKernelV3's layout by DELEGATECALL. ` +
        "State belongs in the accounting kernel or in a namespaced slot.",
    );
  }
}

if (write) {
  const forge = spawnSync("forge", ["--version"], { cwd: root, encoding: "utf8" });
  const document = {
    comment:
      "Storage layout of every contract under src/, as forge inspect reports it with AST ids removed. " +
      "check-storage-layout.mjs fails the build when the current sources disagree with this file.",
    generatedWith: (forge.stdout ?? "").split("\n")[0].trim(),
    delegatecallHosts,
    contracts: current,
  };
  writeFileSync(goldenPath, `${JSON.stringify(document, null, 2)}\n`);
  console.log(`wrote ${names.length} layouts to STORAGE_LAYOUT.json`);
  process.exit(0);
}

if (!existsSync(goldenPath)) {
  fail("STORAGE_LAYOUT.json is missing. Run `node check-storage-layout.mjs --write` and review the result.");
}
const golden = JSON.parse(readFileSync(goldenPath, "utf8"));
const pinned = golden.contracts ?? {};
const problems = [];
for (const name of [...new Set([...Object.keys(pinned), ...names])].sort()) {
  if (!pinned[name]) {
    problems.push(`${name}: not pinned. Add it with --write and review its layout.`);
    continue;
  }
  if (!current[name]) {
    problems.push(`${name}: pinned but no longer under src/.`);
    continue;
  }
  if (JSON.stringify(pinned[name]) !== JSON.stringify(current[name])) {
    const slotsAgree = JSON.stringify(pinned[name].storage) === JSON.stringify(current[name].storage);
    problems.push(
      `${name}: storage layout changed${slotsAgree ? " inside a struct or type" : ""}.\n` +
        `  pinned:\n${describe(pinned[name])}\n  current:\n${describe(current[name])}`,
    );
  }
}
if (problems.length > 0) {
  fail(`${problems.join("\n\n")}\n\nIf the change is intended, run --write and review the diff as a storage migration.`);
}
console.log(
  `storage layout pinned for ${names.length} contracts; ${delegatecallHosts.length} delegatecall hosts declare no storage`,
);
