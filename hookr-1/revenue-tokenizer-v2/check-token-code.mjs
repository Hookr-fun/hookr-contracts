#!/usr/bin/env node

// Checks the two halves of the revenue token's creation code against the sources here. HookrRevenueTokenizer reads
// both at every mint and creates the revenue token from them. Each half's runtime is a STOP byte followed by its piece
// of HookrRevenueToken's creation code, linked to the token's three libraries. The record lists both under the
// tokenizer as dataContracts, with the sources and settings of their verified creation match.
//
//   node hookr-1/revenue-tokenizer-v2/check-token-code.mjs --input > input.json
//   solc-0.8.37 --standard-json input.json > output.json
//   cast code 0x99b498Aa5f073b70De35e317A8bFB1BB8386a78A > half0.hex
//   cast code 0xcccD15Ac6aA42d77874Af26b7b73DF634512d6e0 > half1.hex
//   node hookr-1/revenue-tokenizer-v2/check-token-code.mjs output.json half0.hex half1.hex
//
// The second tokenizer, 0x522723A7a09684515881568Ab8247f3846D66F43, has halves of its own, built from the same input and
// linked to its own libraries; name it after the hex files to check them:
//
//   node hookr-1/revenue-tokenizer-v2/check-token-code.mjs output.json half0.hex half1.hex 0x522723A7a09684515881568Ab8247f3846D66F43
//
// `--input` writes the halves' solc standard JSON input from the files in this repository, as standard-input.mjs does
// for a contract in the record. The check then needs three things to hold: the halves joined are HookrRevenueToken's
// creation code linked to the libraries the record names, the first half holds exactly SPLIT bytes of it, and the
// metadata hash of HookrRevenueTokenCode built here is the one the record names for both halves.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..", "..");
const record = JSON.parse(readFileSync(join(here, "..", "deployments", "robinhood-4663.json"), "utf8"));

const SPLIT = 14_000;
const TOKEN = ["src/HookrRevenueToken.sol", "HookrRevenueToken"];
const CODE = ["src/HookrRevenueTokenCode.sol", "HookrRevenueTokenCode"];

const tokenizers = record.contracts.filter((c) => c.group === "revenue-tokenizer-v2" && c.name === "HookrRevenueTokenizer");
const chosen = process.argv[5];
const tokenizer = chosen ? tokenizers.find((c) => c.address.toLowerCase() === chosen.toLowerCase()) : tokenizers[0];
if (!tokenizer) {
  console.error(`${chosen} is not a revenue-tokenizer-v2 tokenizer in the record`);
  process.exit(1);
}
const halves = (tokenizer.dataContracts ?? []).filter((d) => d.name === "HookrRevenueTokenCode");
if (halves.length !== 2) {
  console.error(`the record lists no two HookrRevenueTokenCode halves under the tokenizer ${tokenizer.address}`);
  process.exit(1);
}
for (const key of ["sources", "settings", "libraries", "metadataIpfs"]) {
  if (JSON.stringify(halves[0][key]) !== JSON.stringify(halves[1][key])) {
    console.error(`the two halves' ${key} differ in the record`);
    process.exit(1);
  }
}
const [half] = halves;

const argument = process.argv[2];
if (!argument || argument === "--help") {
  console.error("usage: node hookr-1/revenue-tokenizer-v2/check-token-code.mjs --input");
  console.error("       node hookr-1/revenue-tokenizer-v2/check-token-code.mjs <solc output.json> <half 0 hex file> <half 1 hex file> [tokenizer]");
  process.exit(2);
}

if (argument === "--input") {
  const sources = {};
  for (const [unit, path] of Object.entries(half.sources)) {
    sources[unit] = { content: readFileSync(join(root, path), "utf8") };
  }
  const input = {
    language: "Solidity",
    sources,
    settings: {
      ...record.settings[half.settings],
      outputSelection: {
        "*": {
          "*": ["evm.bytecode.object", "evm.bytecode.linkReferences", "evm.deployedBytecode.object", "metadata"],
        },
      },
    },
  };
  // No process.exit here: on a pipe it would cut the input short before stdout drains.
  process.stdout.write(JSON.stringify(input) + "\n");
} else {
  check(process.argv.slice(2, 5));
}

function check([outputPath, ...halfPaths]) {
  if (halfPaths.length !== 2) {
    console.error("usage: node hookr-1/revenue-tokenizer-v2/check-token-code.mjs <solc output.json> <half 0 hex file> <half 1 hex file> [tokenizer]");
    process.exit(2);
  }

  const output = JSON.parse(readFileSync(outputPath, "utf8"));
  const errors = (output.errors ?? []).filter((e) => e.severity === "error");
  if (errors.length > 0) {
    console.error(errors.map((e) => e.formattedMessage).join("\n"));
    process.exit(1);
  }
  const token = output.contracts?.[TOKEN[0]]?.[TOKEN[1]]?.evm?.bytecode;
  const code = output.contracts?.[CODE[0]]?.[CODE[1]]?.evm?.deployedBytecode;
  if (!token?.linkReferences || !code) {
    console.error(`${TOKEN.join(":")} or ${CODE.join(":")} is not in ${outputPath}; write the input with --input`);
    process.exit(1);
  }

  // The token's creation code, linked to the libraries the record names.
  const libraries = Object.fromEntries(Object.entries(half.libraries).map(([k, v]) => [k.toLowerCase(), v]));
  const hex = token.object.split("");
  let links = 0;
  for (const [file, libs] of Object.entries(token.linkReferences)) {
    for (const [lib, refs] of Object.entries(libs)) {
      const linked = libraries[`${file}:${lib}`.toLowerCase()];
      if (!linked) {
        console.error(`the record names no address for library ${file}:${lib}`);
        process.exit(1);
      }
      for (const { start } of refs) hex.splice(start * 2, 40, ...linked.slice(2).toLowerCase());
      links += 1;
    }
  }
  const expected = Buffer.from(hex.join(""), "hex");

  const pieces = [];
  for (const path of halfPaths) {
    const runtime = Buffer.from(readFileSync(path, "utf8").trim().replace(/^0x/, ""), "hex");
    if (runtime.length === 0 || runtime[0] !== 0x00) {
      console.log(`MISMATCH ${path}: a half starts with a STOP byte`);
      process.exit(1);
    }
    pieces.push(runtime.subarray(1));
  }
  if (pieces[0].length !== SPLIT) {
    console.log(`MISMATCH the first half holds ${pieces[0].length} bytes, not SPLIT (${SPLIT})`);
    process.exit(1);
  }
  const stored = Buffer.concat(pieces);
  if (!stored.equals(expected)) {
    console.log(`MISMATCH HookrRevenueToken creation code: ${expected.length} bytes built, ${stored.length} bytes in the halves`);
    process.exit(1);
  }

  // The metadata hash in the CBOR tail of HookrRevenueTokenCode's compiled runtime, as base58 (an IPFS CIDv0).
  const runtime = Buffer.from(code.object, "hex");
  const cbor = runtime.subarray(runtime.length - 2 - runtime.readUInt16BE(runtime.length - 2), runtime.length - 2);
  const marker = Buffer.from("64697066735822", "hex"); // "ipfs" as a CBOR key, then a 34-byte string header
  const at = cbor.indexOf(marker);
  if (at === -1) {
    console.log(`MISMATCH ${CODE.join(":")} carries no IPFS metadata hash`);
    process.exit(1);
  }
  const multihash = cbor.subarray(at + marker.length, at + marker.length + 34);
  const alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
  let n = BigInt(`0x${multihash.toString("hex")}`);
  let cid = "";
  while (n > 0n) {
    cid = alphabet[Number(n % 58n)] + cid;
    n /= 58n;
  }
  if (cid !== half.metadataIpfs) {
    console.log(`MISMATCH ${CODE.join(":")} metadata ${cid}, the record names ${half.metadataIpfs}`);
    process.exit(1);
  }

  console.log(
    `MATCH HookrRevenueToken creation code: ${stored.length} bytes in 2 halves (${pieces.map((p) => p.length).join(" + ")}), ` +
      `${links} libraries linked; HookrRevenueTokenCode metadata ${cid}; tokenizer ${tokenizer.address}`,
  );
}
