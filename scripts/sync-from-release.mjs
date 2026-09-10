#!/usr/bin/env node
/**
 * sync-from-release.mjs
 *
 * Fills the placeholder addresses in this documentation package from a Hookr
 * release journal. It writes three things and nothing else:
 *
 *   1. docs/reference/deployments.md      -- the `pending deployment` cells
 *   2. deployments/robinhood-4663.v2.json -- addresses, hashes, identifiers
 *   3. hooklist/robinhood-4663.template.json -- hook.address only, when the file is present
 *
 * It never invents a value. A journal step that is missing leaves its
 * placeholder untouched and is listed in the report. An address already
 * present is left alone unless --force is passed, so a rerun after a partial
 * release cannot silently repoint a published address.
 *
 * The journal is the file the release sequencer writes as it goes, one entry
 * per plan step. Its shape is
 *
 *   { schema, chainId, createdAt, updatedAt,
 *     steps: { <stepKey>: { address?, txHash?, blockNumber?, gasUsed?,
 *                           salt?, value?, target?, updatedAt } } }
 *
 * `address` appears on create and create2 steps. `value` carries the decoded
 * return of a call step, which is where the kernel, module, integration and
 * profile identifiers come from.
 *
 * A create step that links a library it expected to reuse from a live address
 * checks that address's runtime code hash first. When the hash does not match
 * the local artifact the sequencer deploys the library fresh and journals it
 * under `<stepKey>_lib_<LibraryName>`. Those keys are not plan steps, and a
 * fresh deployment always supersedes the address the plan proposed reusing, so
 * this script rewrites the linked-library row whenever one is present.
 *
 * Usage:
 *   node scripts/sync-from-release.mjs --journal <path> [--root <path>]
 *                                      [--dry-run] [--force] [--help]
 *
 *   --journal   Path to the release journal JSON. Required.
 *   --root      Root of this documentation package. Defaults to the parent of
 *               this script's directory.
 *   --dry-run   Print what would change and write nothing.
 *   --force     Overwrite addresses that are already filled in.
 *
 * Exit codes: 0 on success, 1 on a usage or read error, 2 when the journal's
 * chainId does not match the package's.
 */

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const EXPECTED_CHAIN_ID = 4663;

/**
 * Journal step key -> the row label used in docs/reference/deployments.md and
 * the object key used in deployments/robinhood-4663.v2.json.
 *
 * `docLabel` must match the first table column exactly, including any
 * parenthetical, because the markdown rewrite anchors on it.
 */
const CONTRACTS = [
  { step: "moduleCatalog", json: "moduleCatalog", docLabel: "HookrModuleCatalogV1" },
  { step: "stackRegistry", json: "stackRegistry", docLabel: "HookrStackRegistryV2" },
  { step: "treasuryForwarder", json: "treasuryForwarder", docLabel: "HookrTreasuryForwarderV1" },
  { step: "nativeMechanicsCoordinatorLib", json: "nativeMechanicsCoordinatorLib", docLabel: "HookrNativeMechanicsCoordinatorLibV2" },
  { step: "initialBuyLib", json: "initialBuyLib", docLabel: "HookrMarketCoordinatorInitialBuyLibV4" },
  { step: "marketCoordinator", json: "marketCoordinator", docLabel: "HookrMarketCoordinatorV5" },
  { step: "swapAccountingKernel", json: "swapAccountingKernel", docLabel: "HookrSwapAccountingKernelV3" },
  { step: "kernelRouter", json: "kernelRouter", docLabel: "HookrKernelRouterV3" },
  { step: "kernelQuoter", json: "kernelQuoter", docLabel: "HookrKernelQuoterV1" },
  { step: "nativeMechanicsBlock", json: "nativeMechanicsBlock", docLabel: "HookrNativeMechanicsBlockV2" },
  { step: "rootHook", json: "rootHook", docLabel: "HookrModularHookV6" },
];

/** Journal step key -> identifier field in the deployments JSON. */
const IDENTIFIERS = [
  { step: "registerKernel", json: "kernelId" },
  { step: "registerModule", json: "moduleId" },
  { step: "registerIntegrationRouter", json: "routerIntegrationId" },
  { step: "registerIntegrationQuoter", json: "quoterIntegrationId" },
  { step: "sealRootProfile", json: "profileManifestHash" },
];

/**
 * Libraries a create step links by address. The plan proposes reusing each one
 * from a live deployment; when the codehash check fails the sequencer deploys
 * it fresh and journals it under `<step>_lib_<name>`. `json` is the key in
 * `reusedLibraries`, `docLabel` the first column of the linked-library table.
 */
const LINKED_LIBRARIES = [
  {
    step: "marketCoordinator",
    name: "HookrMarketCoordinatorTokenDeployerV3",
    json: "tokenDeployer",
    docLabel: "HookrMarketCoordinatorTokenDeployerV3",
  },
  {
    step: "marketCoordinator",
    name: "HookrMarketCoordinatorKernelReservationLibV1",
    json: "kernelReservationLib",
    docLabel: "HookrMarketCoordinatorKernelReservationLibV1",
  },
  {
    step: "swapAccountingKernel",
    name: "HookrStatefulSettlementLibV1",
    json: "statefulSettlementLib",
    docLabel: "HookrStatefulSettlementLibV1",
  },
  {
    step: "rootHook",
    name: "HookrModularCorrectionLibV2",
    json: "modularCorrectionLib",
    docLabel: "HookrModularCorrectionLibV2",
  },
];

const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const BYTES32_RE = /^0x[0-9a-fA-F]{64}$/;

function parseArgs(argv) {
  const args = { dryRun: false, force: false, help: false };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === "--help" || a === "-h") args.help = true;
    else if (a === "--dry-run") args.dryRun = true;
    else if (a === "--force") args.force = true;
    else if (a === "--journal") args.journal = argv[++i];
    else if (a === "--root") args.root = argv[++i];
    else throw new Error(`unknown argument: ${a}`);
  }
  return args;
}

function usage() {
  console.log(
    [
      "sync-from-release.mjs -- fill this package's placeholder addresses from a release journal",
      "",
      "  --journal <path>   release journal JSON (required)",
      "  --root <path>      documentation package root (default: this script's parent)",
      "  --dry-run          print the plan, write nothing",
      "  --force            overwrite addresses that are already filled in",
      "  --help             this message",
    ].join("\n"),
  );
}

function readJson(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

/** A step's address, only when it is a well-formed address. */
function stepAddress(steps, key) {
  const v = steps?.[key]?.address;
  return typeof v === "string" && ADDRESS_RE.test(v) ? v : undefined;
}

/** A call step's decoded return value, only when it is a well-formed bytes32. */
function stepValue(steps, key) {
  const v = steps?.[key]?.value;
  return typeof v === "string" && BYTES32_RE.test(v) ? v : undefined;
}

/**
 * Rewrite the `pending deployment` cell of every markdown table row whose first
 * column is this label.
 *
 * Rows look like: `| HookrModuleCatalogV1 | `pending deployment` |`
 * and become:     `| HookrModuleCatalogV1 | [`0x…`](explorer/address/0x…) |`
 *
 * The address is always the last cell, so this works for the two-column
 * deployment table and the three-column linked-library table alike. Anchored on
 * the first column, so a label appearing in prose is never touched. A contract
 * that is both a deployment and a linked library has a row in both tables and
 * one address, so both rows are written.
 */
function fillDocRow(markdown, label, address, explorer, force) {
  const cell = `[\`${address}\`](${explorer}/address/${address})`;
  let found = false;
  let wrote = false;
  const lines = markdown.split("\n").map((line) => {
    if (!line.startsWith("|")) return line;
    // `| a | b |` splits into ["", " a ", " b ", ""].
    const cells = line.split("|");
    if (cells.length < 4 || cells[1].trim() !== label) return line;
    found = true;
    const last = cells.length - 2;
    if (cells[last].trim() !== "`pending deployment`" && !force) return line;
    wrote = true;
    cells[last] = ` ${cell} `;
    return cells.join("|");
  });
  if (!found) return { markdown, status: "row-not-found" };
  if (!wrote) return { markdown, status: "already-filled" };
  return { markdown: lines.join("\n"), status: "filled" };
}

function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (err) {
    console.error(`error: ${err.message}`);
    usage();
    process.exit(1);
  }
  if (args.help) return usage();
  if (!args.journal) {
    console.error("error: --journal is required");
    usage();
    process.exit(1);
  }

  const root = resolve(args.root ?? join(dirname(fileURLToPath(import.meta.url)), ".."));
  const journalPath = resolve(args.journal);

  let journal;
  try {
    journal = readJson(journalPath);
  } catch (err) {
    console.error(`error: cannot read journal at ${journalPath}: ${err.message}`);
    process.exit(1);
  }

  if (journal.chainId !== EXPECTED_CHAIN_ID) {
    console.error(
      `error: journal chainId ${journal.chainId} does not match this package's ${EXPECTED_CHAIN_ID}`,
    );
    process.exit(2);
  }

  const steps = journal.steps ?? {};
  const deploymentsPath = join(root, "deployments", "robinhood-4663.v2.json");
  const docPath = join(root, "docs", "reference", "deployments.md");
  const hooklistPath = join(root, "hooklist", "robinhood-4663.template.json");

  const deployments = readJson(deploymentsPath);
  // The hooklist entry is optional: the published package carries the docs and the
  // deployments record, and the entry itself lives in Uniswap's hooklist once listed.
  const hooklist = existsSync(hooklistPath) ? readJson(hooklistPath) : null;
  let markdown = readFileSync(docPath, "utf8");
  const explorer = deployments.explorer;

  const report = { filled: [], missing: [], skipped: [] };

  for (const c of CONTRACTS) {
    const address = stepAddress(steps, c.step);
    if (!address) {
      report.missing.push(`${c.step} (no address in journal)`);
      continue;
    }
    const entry = deployments.contracts[c.json];
    if (!entry) {
      report.missing.push(`${c.json} (no entry in deployments JSON)`);
      continue;
    }
    if (entry.address && !args.force) {
      report.skipped.push(`${c.json} (already ${entry.address}; pass --force to overwrite)`);
    } else {
      entry.address = address;
      entry.txHash = steps[c.step].txHash ?? "";
      entry.blockNumber = String(steps[c.step].blockNumber ?? "");
      if (steps[c.step].salt) entry.salt = steps[c.step].salt;
      report.filled.push(`${c.json} = ${address}`);
    }

    const res = fillDocRow(markdown, c.docLabel, address, explorer, args.force);
    markdown = res.markdown;
    if (res.status === "row-not-found") report.missing.push(`${c.docLabel} (no table row in deployments.md)`);
    if (res.status === "already-filled") report.skipped.push(`${c.docLabel} (markdown row already filled)`);
  }

  for (const lib of LINKED_LIBRARIES) {
    const key = `${lib.step}_lib_${lib.name}`;
    const address = stepAddress(steps, key);
    const entry = deployments.reusedLibraries?.[lib.json];
    if (!address) {
      // No fallback entry: the codehash matched and the planned address was linked as is.
      report.skipped.push(`${lib.json} (reused at ${entry?.address ?? "the planned address"})`);
      continue;
    }
    if (!entry) {
      report.missing.push(`${lib.json} (no entry in deployments JSON)`);
      continue;
    }
    if (entry.address === address && !args.force) {
      report.skipped.push(`${lib.json} (already ${address}, deployed fresh in this release)`);
      continue;
    }
    entry.address = address;
    entry.txHash = steps[key].txHash ?? "";
    entry.blockNumber = String(steps[key].blockNumber ?? "");
    entry.reused = false;
    delete entry.verifyBeforeLinking;
    report.filled.push(`${lib.json} = ${address} (deployed fresh, codehash mismatch)`);

    // A fresh deployment supersedes whatever address the row proposed, so this
    // row is rewritten whether or not it was still a placeholder.
    const res = fillDocRow(markdown, lib.docLabel, address, explorer, true);
    markdown = res.markdown;
    if (res.status === "row-not-found") {
      report.missing.push(`${lib.docLabel} (no table row in deployments.md)`);
    }
  }

  for (const id of IDENTIFIERS) {
    const value = stepValue(steps, id.step);
    if (!value) {
      report.missing.push(`${id.step} (no bytes32 return value in journal)`);
      continue;
    }
    if (deployments.identifiers[id.json] && !args.force) {
      report.skipped.push(`identifiers.${id.json} (already set)`);
      continue;
    }
    deployments.identifiers[id.json] = value;
    report.filled.push(`identifiers.${id.json} = ${value}`);
  }

  const rootHookAddress = stepAddress(steps, "rootHook");
  if (rootHookAddress && hooklist) {
    const current = hooklist.hook.address;
    if (current && !current.startsWith("<") && !args.force) {
      report.skipped.push(`hooklist hook.address (already ${current})`);
    } else {
      hooklist.hook.address = rootHookAddress;
      report.filled.push(`hooklist hook.address = ${rootHookAddress}`);
    }
  }

  if (deployments.status === "pending-deployment" && report.filled.length > 0) {
    deployments.status = "deployed";
  }

  if (args.dryRun) {
    console.log("dry run, nothing written\n");
  } else {
    writeFileSync(deploymentsPath, `${JSON.stringify(deployments, null, 2)}\n`);
    if (hooklist) writeFileSync(hooklistPath, `${JSON.stringify(hooklist, null, 2)}\n`);
    writeFileSync(docPath, markdown);
  }

  console.log(`filled (${report.filled.length}):`);
  for (const line of report.filled) console.log(`  ${line}`);
  console.log(`skipped (${report.skipped.length}):`);
  for (const line of report.skipped) console.log(`  ${line}`);
  console.log(`missing (${report.missing.length}):`);
  for (const line of report.missing) console.log(`  ${line}`);

  if (report.missing.length > 0) {
    console.log(
      "\nMissing entries kept their placeholders. Nothing was guessed.\n" +
        "Three things this script deliberately does not do:\n" +
        "  - it never fills auditUrl in the hooklist entry; that is a human decision;\n" +
        "  - it never picks a Universal Router address, because chain 4663 has two\n" +
        "    conflicting official sources and the choice needs fork evidence;\n" +
        "  - it never fills runtimeCodeHash, because a hash copied from a journal\n" +
        "    proves nothing. Read it from the chain and paste it in.",
    );
  }
}

main();
