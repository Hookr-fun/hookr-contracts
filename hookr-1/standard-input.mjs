#!/usr/bin/env node

// Writes the solc standard JSON input of one deployed Hookr 1 contract, rebuilt from the files in this
// repository and the record in deployments/robinhood-4663.json. Compiling it with solc 0.8.37 gives the
// contract's verified bytecode, metadata hash included.
//
//   node hookr-1/standard-input.mjs --list
//   node hookr-1/standard-input.mjs <address> > input.json
//   solc-0.8.37 --standard-json input.json > output.json
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
  console.error("usage: node hookr-1/standard-input.mjs <address> | --list");
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

const sources = {};
for (const [unit, path] of Object.entries(contract.sources)) {
  sources[unit] = { content: readFileSync(join(root, path), "utf8") };
}

const input = {
  language: "Solidity",
  sources,
  settings: {
    ...record.settings[contract.settings],
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
