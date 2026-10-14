#!/usr/bin/env node
// Runs the gas bench and writes gas-figures.json, or checks a committed gas-figures.json.
//
//   node bench/gas-figures.mjs            run `forge test --isolate` in bench/, merge what the tests wrote, write the file
//   node bench/gas-figures.mjs --check    check bench/gas-figures.json against the schema, with no fork and no RPC
//   node bench/gas-figures.mjs --table    print the README's table of figures from bench/gas-figures.json
//
// The tests fork through the rpc alias `robinhood` in the reader's own Foundry config (bench/README.md). This script
// never reads or prints a URL: it masks every URL forge prints, and the value of any environment variable that is one.

import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const bench = dirname(fileURLToPath(import.meta.url));
const root = dirname(bench);
const figuresDir = join(bench, "figures");
const outputPath = join(bench, "gas-figures.json");
const readmePath = join(bench, "README.md");

const CHAIN_ID = 4663;
const REPOSITORY = "Hookr-fun/hookr-contracts";
const METHOD =
  "Whole isolated transactions (forge test --isolate) on a fork of Robinhood Chain 4663 against Hookr's live " +
  "contracts, after warm-up swaps: a piece's extra gas is the same action on the same pool shape with the piece on " +
  "minus off, the base is measured over a hookless pool of that shape, and launches, limit orders, the family " +
  "lock's collect and the ETH claim are whole transactions.";

// What the figures are measured with: the bench itself, the Hookr sources it compiles and the libraries it links.
const MEASURED_PATHS = [
  "bench/foundry.toml",
  "bench/gas-figures.mjs",
  "bench/src",
  "bench/test",
  "hookr-1/src/interfaces",
  "hookr-1/src/types",
  "hookr-1/hook-blocks/limit-orders/src",
  "hookr-1/hook-blocks/market-guard/src",
  "lib",
];

// The Hook Block pages on hookr.fun/hooks/<slug>, plus the three pieces that have no page.
const PIECES = [
  "base",
  "lp-rewards",
  "creator-royalty",
  "auto-burn",
  "anti-snipe",
  "wallet-cap",
  "dynamic-fees",
  "king-of-the-pool",
  "arb-recapture",
  "limit-orders",
  "liquidity-lock",
  "market-guard",
  "buy-sell-block",
  "launch",
  "claim",
];
const ACTIONS = [
  "buy",
  "first-buy",
  "repeat-buy",
  "sell",
  "after-window",
  "launch",
  "place",
  "cancel",
  "fill",
  "collect",
  "per-swap",
  "claim",
];
const BASELINES = ["hookless-pool", "same-pool-without-piece", "absolute"];
const KEYS = ["id", "piece", "label", "action", "gas", "baseline", "router", "test"];

function fail(message) {
  console.error(`gas-figures: ${message}`);
  process.exit(1);
}

const URL_PATTERN = /(?:https?|wss?):\/\/[^\s"'<>)\]]+/gi;

// Every secret an environment variable could carry: the URLs in it, and the parts of a URL that identify the account.
function urlSecrets() {
  const secrets = new Set();
  for (const value of Object.values(process.env)) {
    for (const found of value?.match(URL_PATTERN) ?? []) {
      secrets.add(found);
      try {
        const url = new URL(found);
        for (const part of [url.username, url.password, ...url.pathname.split("/"), ...url.searchParams.values()]) {
          if (part.length >= 8) secrets.add(part);
        }
      } catch {
        // not a URL after all; the whole match is still masked
      }
    }
  }
  return [...secrets].sort((a, b) => b.length - a.length);
}

const SECRETS = urlSecrets();

function mask(text) {
  let masked = text.replace(URL_PATTERN, "<url>");
  for (const secret of SECRETS) masked = masked.replaceAll(secret, "<url>");
  return masked;
}

// Masks line by line, so a URL that arrives in two reads is never printed in halves.
function maskedWriter(stream) {
  let pending = "";
  return {
    write(chunk) {
      pending += chunk;
      const lines = pending.split("\n");
      pending = lines.pop();
      for (const line of lines) stream.write(`${mask(line)}\n`);
    },
    end() {
      if (pending !== "") stream.write(`${mask(pending)}\n`);
      pending = "";
    },
  };
}

function runBench() {
  return new Promise((resolve) => {
    const out = maskedWriter(process.stdout);
    const err = maskedWriter(process.stderr);
    const child = spawn("forge", ["test", "--isolate", "-vv"], { cwd: bench, stdio: ["inherit", "pipe", "pipe"] });
    child.stdout.on("data", (chunk) => out.write(chunk.toString()));
    child.stderr.on("data", (chunk) => err.write(chunk.toString()));
    child.on("error", (error) => fail(`cannot run forge: ${mask(error.message)}`));
    child.on("close", (code) => {
      out.end();
      err.end();
      resolve(code);
    });
  });
}

function readFragments() {
  if (!existsSync(figuresDir)) fail("bench/figures is missing; run the bench first");
  const names = readdirSync(figuresDir).filter((name) => name.endsWith(".json"));
  if (names.length === 0) fail("bench/figures holds no figure; run the bench first");
  const fragments = names.map((name) => JSON.parse(readFileSync(join(figuresDir, name), "utf8")));
  const forkBlocks = new Set(fragments.map((fragment) => fragment.forkBlock));
  if (forkBlocks.size !== 1) fail(`the figures come from more than one fork block: ${[...forkBlocks].join(", ")}`);
  for (const fragment of fragments) {
    if (fragment.chainId !== CHAIN_ID) fail(`${fragment.id}: measured on chain ${fragment.chainId}, not ${CHAIN_ID}`);
  }
  const figures = fragments.map((fragment) => Object.fromEntries(KEYS.map((key) => [key, fragment[key]])));
  return { forkBlock: [...forkBlocks][0], figures };
}

function order(a, b) {
  return (
    PIECES.indexOf(a.piece) - PIECES.indexOf(b.piece) ||
    ACTIONS.indexOf(a.action) - ACTIONS.indexOf(b.action) ||
    (a.id < b.id ? -1 : a.id > b.id ? 1 : 0)
  );
}

function git(...args) {
  return execFileSync("git", args, { cwd: root, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
}

// The commit of the last change to what the figures are measured with, so adding the JSON changes nothing here. It is
// read before the run, so `source` names what was measured, and the run refuses a tree that differs from it.
function sourceCommit() {
  try {
    if (git("status", "--porcelain", "--ignore-submodules=dirty", "--", ...MEASURED_PATHS) !== "") {
      fail("what the bench measures with has uncommitted changes; commit them first, so `source` names what was measured");
    }
    return git("log", "-1", "--format=%H", "--", ...MEASURED_PATHS);
  } catch (error) {
    fail(`cannot read the commit of the bench sources: ${mask(String(error.message))}`);
  }
}

// Whether the tree differs from `commit` in what the figures are measured with, files not yet committed included.
function differsFrom(commit) {
  try {
    git("diff", "--quiet", "--ignore-submodules=dirty", commit, "--", ...MEASURED_PATHS);
  } catch (error) {
    if (error.status === 1) return true;
    throw error;
  }
  return git("ls-files", "--others", "--exclude-standard", "--", ...MEASURED_PATHS) !== "";
}

// `source` has to name the state the figures were measured with. A squash merge or a shallow clone leaves the commit out
// of the history, and then there is nothing to compare with: the check says so and passes.
function checkFreshness(file) {
  const stamped = /^[^@]+@([0-9a-f]{40}) bench$/.exec(file.source ?? "")?.[1];
  if (stamped === undefined) return [];
  try {
    git("cat-file", "-e", `${stamped}^{commit}`);
  } catch {
    console.warn(`gas-figures: ${stamped} is not in this clone's history, so the figures' freshness is not checked`);
    return [];
  }
  try {
    if (!differsFrom(stamped)) return [];
  } catch (error) {
    fail(`cannot compare the bench sources with ${stamped}: ${mask(String(error.message))}`);
  }
  return [`what the bench measures with has changed since ${stamped}, the commit \`source\` names: run node bench/gas-figures.mjs again`];
}

// The README's table is the expected output of the command, so it has to say what the file says.
function checkReadme(file) {
  const rows = new Map();
  for (const line of readFileSync(readmePath, "utf8").split("\n")) {
    const match = line.match(/^\| `([a-z0-9.-]+)` \| (-?[\d,]+) \| (.+) \|$/);
    if (match) rows.set(match[1], { gas: Number(match[2].replaceAll(",", "")), label: match[3] });
  }
  const problems = [];
  for (const figure of file.figures) {
    const row = rows.get(figure.id);
    if (row === undefined) problems.push(`README.md has no row for ${figure.id}`);
    else if (row.gas !== figure.gas || row.label !== figure.label) problems.push(`README.md disagrees with gas-figures.json on ${figure.id}`);
    rows.delete(figure.id);
  }
  for (const id of rows.keys()) problems.push(`README.md has a row for ${id}, which gas-figures.json does not have`);
  return problems;
}

function checkFigures(file) {
  const problems = [];
  const problem = (message) => problems.push(message);
  if (file.schema !== 1) problem("schema must be 1");
  if (file.chainId !== CHAIN_ID) problem(`chainId must be ${CHAIN_ID}`);
  if (!Number.isInteger(file.forkBlock) || file.forkBlock <= 0) problem("forkBlock must be a positive integer");
  if (!new RegExp(`^${REPOSITORY}@[0-9a-f]{40} bench$`).test(file.source ?? "")) problem("source must be <repository>@<commit> bench");
  if (!/^\d{4}-\d{2}-\d{2}$/.test(file.measuredAt ?? "")) problem("measuredAt must be YYYY-MM-DD");
  if (typeof file.method !== "string" || file.method === "") problem("method must be a sentence");
  if (!Array.isArray(file.figures) || file.figures.length === 0) {
    problem("figures must be a list");
    return problems;
  }
  const ids = new Set();
  for (const figure of file.figures) {
    const where = figure.id ?? "(no id)";
    if (JSON.stringify(Object.keys(figure)) !== JSON.stringify(KEYS)) problem(`${where}: keys must be ${KEYS.join(", ")}`);
    if (!/^[a-z0-9.-]+$/.test(figure.id ?? "")) problem(`${where}: id must be lower case letters, digits, dots and dashes`);
    if (ids.has(figure.id)) problem(`${where}: id is used twice`);
    ids.add(figure.id);
    if (!PIECES.includes(figure.piece)) problem(`${where}: unknown piece ${figure.piece}`);
    if (!ACTIONS.includes(figure.action)) problem(`${where}: unknown action ${figure.action}`);
    if (!BASELINES.includes(figure.baseline)) problem(`${where}: unknown baseline ${figure.baseline}`);
    if (!Number.isInteger(figure.gas)) problem(`${where}: gas must be an integer`);
    for (const key of ["label", "router"]) if (typeof figure[key] !== "string" || figure[key] === "") problem(`${where}: ${key} is empty`);
    const [path, name] = String(figure.test).split(":");
    if (!path?.startsWith("bench/test/") || !existsSync(join(root, path))) problem(`${where}: ${figure.test} names no test file`);
    else if (!new RegExp(`function ${name}\\(`).test(readFileSync(join(root, path), "utf8"))) problem(`${where}: ${figure.test} names no test`);
  }
  const sorted = [...file.figures].sort(order);
  if (JSON.stringify(sorted) !== JSON.stringify(file.figures)) problem("figures are not in the canonical order");
  return problems;
}

const mode = process.argv[2] ?? "";
if (!["", "--check", "--table"].includes(mode)) fail(`unknown argument ${mode}`);

if (mode === "--table") {
  const { figures } = JSON.parse(readFileSync(outputPath, "utf8"));
  console.log("| Figure | Gas | What it measures |\n| --- | ---: | --- |");
  for (const figure of figures) console.log(`| \`${figure.id}\` | ${figure.gas.toLocaleString("en-US")} | ${figure.label} |`);
} else if (mode === "--check") {
  if (!existsSync(outputPath)) fail("bench/gas-figures.json does not exist");
  const file = JSON.parse(readFileSync(outputPath, "utf8"));
  const problems = [...checkFigures(file), ...checkReadme(file), ...checkFreshness(file)];
  if (problems.length > 0) fail(problems.join("\n"));
  console.log(`gas figures verified (${file.figures.length} figures)`);
} else {
  const source = `${REPOSITORY}@${sourceCommit()} bench`;
  const measuredAt = new Date().toISOString().slice(0, 10);
  rmSync(figuresDir, { recursive: true, force: true });
  mkdirSync(figuresDir);
  writeFileSync(join(figuresDir, ".gitkeep"), "");
  const code = await runBench();
  if (code !== 0) fail(`forge test exited with ${code}`);
  const { forkBlock, figures } = readFragments();
  const file = { schema: 1, chainId: CHAIN_ID, forkBlock, source, measuredAt, method: METHOD, figures: figures.sort(order) };
  const problems = checkFigures(file);
  if (problems.length > 0) fail(problems.join("\n"));
  writeFileSync(outputPath, `${JSON.stringify(file, null, 2)}\n`);
  console.log(`wrote bench/gas-figures.json: ${file.figures.length} figures at block ${forkBlock}`);
  const stale = checkReadme(file);
  if (stale.length > 0) console.warn(`gas-figures: bench/README.md no longer matches:\n${stale.join("\n")}`);
}
