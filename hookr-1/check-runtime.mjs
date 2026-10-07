#!/usr/bin/env node

// Compares one contract's solc output with the code at its address on chain 4663, byte for byte.
// The linked libraries come from the record. The immutables are the only bytes taken from the chain
// code, at the offsets solc reports for them; every other byte, the metadata hash included, must match.
//
//   node hookr-1/standard-input.mjs <address> > input.json
//   solc-0.8.37 --standard-json input.json > output.json
//   cast code <address> > chain.hex
//   node hookr-1/check-runtime.mjs <address> output.json chain.hex

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const record = JSON.parse(readFileSync(join(here, "deployments", "robinhood-4663.json"), "utf8"));

const [address, outputPath, chainPath] = process.argv.slice(2);
if (!address || !outputPath || !chainPath) {
  console.error("usage: node hookr-1/check-runtime.mjs <address> <solc output.json> <chain code hex file>");
  process.exit(2);
}

const contract = record.contracts.find((c) => c.address.toLowerCase() === address.toLowerCase());
if (!contract) {
  console.error(`no contract at ${address} in the record; node hookr-1/standard-input.mjs --list prints them`);
  process.exit(1);
}

const [unit, name] = [contract.contract.slice(0, contract.contract.lastIndexOf(":")), contract.contract.split(":").pop()];
const output = JSON.parse(readFileSync(outputPath, "utf8"));
const errors = (output.errors ?? []).filter((e) => e.severity === "error");
if (errors.length > 0) {
  console.error(errors.map((e) => e.formattedMessage).join("\n"));
  process.exit(1);
}
const deployed = output.contracts?.[unit]?.[name]?.evm?.deployedBytecode;
if (!deployed) {
  console.error(`${contract.contract} is not in ${outputPath}`);
  process.exit(1);
}

const libraries = Object.fromEntries(Object.entries(contract.libraries).map(([k, v]) => [k.toLowerCase(), v]));
const hex = deployed.object.split("");
for (const [file, libs] of Object.entries(deployed.linkReferences ?? {})) {
  for (const [lib, refs] of Object.entries(libs)) {
    const linked = libraries[`${file}:${lib}`.toLowerCase()];
    if (!linked) {
      console.error(`the record names no address for library ${file}:${lib}`);
      process.exit(1);
    }
    for (const { start } of refs) hex.splice(start * 2, 40, ...linked.slice(2).toLowerCase());
  }
}

const built = Buffer.from(hex.join(""), "hex");
const chain = Buffer.from(readFileSync(chainPath, "utf8").trim().replace(/^0x/, ""), "hex");
if (built.length !== chain.length) {
  console.log(`MISMATCH ${contract.name} ${contract.address}: ${built.length} bytes built, ${chain.length} on chain`);
  process.exit(1);
}

let immutables = 0;
for (const refs of Object.values(deployed.immutableReferences ?? {})) {
  for (const { start, length } of refs) {
    chain.copy(built, start, start, start + length);
    immutables += 1;
  }
}

if (!built.equals(chain)) {
  let first = 0;
  while (built[first] === chain[first]) first += 1;
  console.log(`MISMATCH ${contract.name} ${contract.address}: first differing byte at ${first}`);
  process.exit(1);
}
console.log(`MATCH ${contract.name} ${contract.address}: ${chain.length} bytes, ${immutables} immutable slots`);
