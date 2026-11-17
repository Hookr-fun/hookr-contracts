#!/usr/bin/env node

// Writes the solc standard JSON input of one deployed contract, rebuilt from the files in this
// repository and the record in deployments/robinhood-4663.json. Compiling it with solc 0.8.37 gives the
// contract's verified bytecode, metadata hash included.
//
//   node hookr-1/standard-input.mjs --list
//   node hookr-1/standard-input.mjs <address> > input.json
//   solc-0.8.37 --standard-json input.json > output.json
//
// Lane v2 was built from a tree whose dependencies its metadata records by absolute path. The record writes that
// prefix as <build-root>; pass it as the second argument, read from the remappings of the contract's verified
// metadata on Sourcify, to rebuild it byte for byte:
//
//   node hookr-1/standard-input.mjs <address> <build root> > input.json
//
// Run `git submodule update --init --recursive` first: the dependency sources come from lib/.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");
const record = JSON.parse(readFileSync(join(here, "deployments", "robinhood-4663.json"), "utf8"));

const argument = process.argv[2];
if (!argument || argument === "--help") {
  console.error("usage: node hookr-1/standard-input.mjs <address> [build root] | --list");
  process.exit(2);
}

if (argument === "--list") {
  for (const c of record.contracts) {
    const where = c.block ? `${c.group}/${c.block}` : c.group;
    console.log(`${c.address}  ${where.padEnd(36)}  ${c.name}`);
  }
  process.exit(0);
}

const contract = record.contracts.find((c) => c.address.toLowerCase() === argument.toLowerCase());
if (!contract) {
  console.error(`no contract at ${argument} in the record; --list prints them`);
  process.exit(1);
}

const PLACEHOLDER = "<build-root>";
const buildRoot = process.argv[3];
const settings = JSON.stringify(record.settings[contract.settings]);
if ((settings.includes(PLACEHOLDER) || Object.keys(contract.sources).some((u) => u.includes(PLACEHOLDER))) && !buildRoot) {
  console.error(`${contract.name}'s metadata records its dependencies under an absolute path, written ${PLACEHOLDER} here;`);
  console.error("pass it as the second argument, as the remappings of its verified metadata on Sourcify give it");
  process.exit(1);
}
const named = (text) => (buildRoot ? text.split(PLACEHOLDER).join(buildRoot) : text);

const sources = {};
for (const [unit, path] of Object.entries(contract.sources)) {
  sources[named(unit)] = { content: readFileSync(join(root, path), "utf8") };
}

const input = {
  language: "Solidity",
  sources,
  settings: {
    ...JSON.parse(named(settings)),
    outputSelection: {
      "*": {
        "*": [
          "evm.bytecode.object",
          "evm.deployedBytecode.object",
          "evm.deployedBytecode.immutableReferences",
          "evm.deployedBytecode.linkReferences",
          "metadata",
        ],
      },
    },
  },
};

process.stdout.write(JSON.stringify(input) + "\n");
