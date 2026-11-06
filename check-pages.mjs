#!/usr/bin/env node

// Keeps every page on the contracts Hookr runs today. Earlier releases have one page,
// PREVIOUS_RELEASES.md, and no other page names them: not their words, not their addresses.
// A page is a Markdown file, an issue template or a workflow. lib/ is third-party code, and
// legacy/ keeps an earlier workspace whole, as published; PREVIOUS_RELEASES.md points to it.

import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));
const onePage = "PREVIOUS_RELEASES.md";
const skipped = new Set([".git", "cache", "dist", "legacy", "lib", "node_modules", "out"]);

const words = [
  ["Hookr 1", /\bHookr 1\b/i],
  ["a V2 or V6 label", /\bV[26]\b/],
  ["a V6 contract", /[A-Za-z]V6/],
  ["kernel", /kernel/i],
  ["generation", /generation/i],
  ["coordinator", /coordinator/i],
  ["the WTH adapter", /WTH adapter|WthExecutorAdapter/i],
  ["partner tax", /partner tax/i],
  ["bonding curve", /bonding[ -]curve/i],
  ["legacy", /\blegacy\b/i],
  ["release framing", /\b(?:current|earlier|previous) release\b/i],
];

// Another project's product name that happens to carry a version.
const allowedPhrases = [/\bPons V2\b/g];

// Addresses the earlier contracts share with today's: Uniswap's PoolManager and HOOKR.
const shared = new Set(["0x8366a39cc670b4001a1121b8f6a443a643e40951", "0x18e674231a58c239dc7daedcffe15ec3a24cff5c"]);

const earlier = new Set(
  (readFileSync(join(root, onePage), "utf8").match(/0x[0-9a-fA-F]{64}|0x[0-9a-fA-F]{40}/g) ?? [])
    .map((value) => value.toLowerCase())
    .filter((value) => !shared.has(value)),
);

const pages = [];
function visit(directory) {
  for (const name of readdirSync(directory).sort()) {
    if (skipped.has(name)) continue;
    const candidate = join(directory, name);
    const path = relative(root, candidate).split(sep).join("/");
    if (statSync(candidate).isDirectory()) visit(candidate);
    else if (path !== onePage && (/\.md$/i.test(path) || /^\.github\/.*\.ya?ml$/.test(path))) pages.push({ candidate, path });
  }
}
visit(root);

const failures = [];
for (const { candidate, path } of pages) {
  const lines = readFileSync(candidate, "utf8").split("\n");
  lines.forEach((original, index) => {
    let line = original;
    for (const phrase of allowedPhrases) line = line.replace(phrase, "");
    for (const [label, pattern] of words) {
      if (pattern.test(line)) failures.push(`${path}:${index + 1}: names ${label}`);
    }
    for (const value of line.match(/0x[0-9a-fA-F]{64}|0x[0-9a-fA-F]{40}/g) ?? []) {
      if (earlier.has(value.toLowerCase())) failures.push(`${path}:${index + 1}: names ${value}, which ${onePage} lists`);
    }
  });
}

if (failures.length > 0) {
  console.error(`Earlier releases belong on ${onePage} only:\n${failures.join("\n")}`);
  process.exit(1);
}
console.log(`pages verified (${pages.length} pages, ${earlier.size} earlier addresses and ids kept to ${onePage})`);
