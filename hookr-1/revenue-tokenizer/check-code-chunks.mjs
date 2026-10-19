#!/usr/bin/env node

// Checks the compounder factory's two code chunks against the compounder's creation code built from the sources here.
// The factory writes the creation code of HookrRevenueCompounder into HookrCodeChunk contracts at its own construction
// and deploys every compounder from them. Each chunk's runtime is a STOP byte followed by its piece of the code.
//
//   node hookr-1/standard-input.mjs 0xF32205941a11Ac428Be079773B3Ea583E55BC764 > input.json
//   solc-0.8.37 --standard-json input.json > output.json
//   cast code 0x2e9e3e42E0351563e7206FE505140ec777bca386 > chunk0.hex
//   cast code 0xcc879898625b089bE1249b19E8085d7fE28f15eC > chunk1.hex
//   node hookr-1/revenue-tokenizer/check-code-chunks.mjs output.json chunk0.hex chunk1.hex

import { readFileSync } from "node:fs";

const [outputPath, ...chunkPaths] = process.argv.slice(2);
if (!outputPath || chunkPaths.length === 0) {
  console.error("usage: node hookr-1/revenue-tokenizer/check-code-chunks.mjs <solc output.json> <chunk hex file>...");
  process.exit(2);
}

const output = JSON.parse(readFileSync(outputPath, "utf8"));
const built = output.contracts?.["src/HookrRevenueCompounder.sol"]?.HookrRevenueCompounder?.evm?.bytecode?.object;
if (!built) {
  console.error(`src/HookrRevenueCompounder.sol:HookrRevenueCompounder is not in ${outputPath}`);
  process.exit(1);
}

const pieces = [];
for (const path of chunkPaths) {
  const code = Buffer.from(readFileSync(path, "utf8").trim().replace(/^0x/, ""), "hex");
  if (code.length === 0 || code[0] !== 0x00) {
    console.log(`MISMATCH ${path}: a chunk starts with a STOP byte`);
    process.exit(1);
  }
  pieces.push(code.subarray(1));
}

const stored = Buffer.concat(pieces);
const expected = Buffer.from(built, "hex");
if (!stored.equals(expected)) {
  console.log(`MISMATCH HookrRevenueCompounder creation code: ${expected.length} bytes built, ${stored.length} bytes in the chunks`);
  process.exit(1);
}
console.log(`MATCH HookrRevenueCompounder creation code: ${stored.length} bytes in ${pieces.length} chunks (${pieces.map((p) => p.length).join(" + ")})`);
