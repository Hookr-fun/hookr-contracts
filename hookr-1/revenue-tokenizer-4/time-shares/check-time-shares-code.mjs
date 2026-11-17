#!/usr/bin/env node

// Checks the time shares factory's two data contracts against the time shares' creation code built from the sources
// here. HookrTimeSharesFactory writes the creation code of HookrTimeShares into two contracts at its own construction,
// the first half and the rest, and creates every time shares contract from them. Each one's runtime is its piece of the
// code, with no leading byte. The record lists both under the factory as dataContracts.
//
//   node hookr-1/standard-input.mjs 0x05fDb5654e1D52593Ee774cae964717d5834dF1B > input.json
//   solc-0.8.37 --standard-json input.json > output.json
//   cast code 0x2999D1E72bf3Cc2d6a4e76695c0Fd01d59dba0f3 > data0.hex
//   cast code 0x670636b2E5032146c5592399599fCd6B34038435 > data1.hex
//   node hookr-1/revenue-tokenizer-4/time-shares/check-time-shares-code.mjs output.json data0.hex data1.hex

import { readFileSync } from "node:fs";

const [outputPath, ...dataPaths] = process.argv.slice(2);
if (!outputPath || dataPaths.length !== 2) {
  console.error("usage: node hookr-1/revenue-tokenizer-4/time-shares/check-time-shares-code.mjs <solc output.json> <data 0 hex file> <data 1 hex file>");
  process.exit(2);
}

const output = JSON.parse(readFileSync(outputPath, "utf8"));
const built = output.contracts?.["src/HookrTimeShares.sol"]?.HookrTimeShares?.evm?.bytecode?.object;
if (!built) {
  console.error(`src/HookrTimeShares.sol:HookrTimeShares is not in ${outputPath}`);
  process.exit(1);
}

const pieces = dataPaths.map((path) => Buffer.from(readFileSync(path, "utf8").trim().replace(/^0x/, ""), "hex"));
const expected = Buffer.from(built, "hex");
const half = Math.floor(expected.length / 2);
if (pieces[0].length !== half) {
  console.log(`MISMATCH the first data contract holds ${pieces[0].length} bytes, not half the code (${half})`);
  process.exit(1);
}

const stored = Buffer.concat(pieces);
if (!stored.equals(expected)) {
  console.log(`MISMATCH HookrTimeShares creation code: ${expected.length} bytes built, ${stored.length} bytes in the data contracts`);
  process.exit(1);
}
console.log(`MATCH HookrTimeShares creation code: ${stored.length} bytes in 2 data contracts (${pieces.map((p) => p.length).join(" + ")})`);
