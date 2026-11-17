#!/usr/bin/env node

// Checks owned-root factory v2's three code stores against the sources here. The factory builds every own hook's root
// from the root store and checks an own hook's core against what the two core stores hold. Each store's runtime is a
// STOP byte followed by its data. The record lists the three under the factory as dataContracts and root v2 as the
// factory's template, with root v2's sources and settings.
//
//   node hookr-1/combined-core/check-code-stores.mjs --input <build root> > root.json
//   solc-0.8.37 --standard-json root.json > root.out.json
//   node hookr-1/standard-input.mjs 0x8AD0aC66DbeBcc047e8d216666C925E797e5e52e > core.json
//   solc-0.8.37 --standard-json core.json > core.out.json
//   cast code 0xB41EB84679855602522ecd0093ff6343EB3ceEc4 > root.hex
//   cast code 0xd71167314A50589C7C8CD9Cc9C81939f5DDDb190 > core0.hex
//   cast code 0xe4731fFC8a0A0C10213C872F5c17b3f895A82a83 > core1.hex
//   node hookr-1/combined-core/check-code-stores.mjs root.out.json core.out.json root.hex core0.hex core1.hex
//
// `--input` writes root v2's solc standard JSON input from the files in this repository, as standard-input.mjs does
// for a contract in the record. Root v2 was built in lane v2's tree, whose metadata records the dependencies under an
// absolute path, written <build-root> in the record; pass it, as lane v2's verified metadata on Sourcify
// gives it. The check then needs three things to hold: the root store holds exactly root v2's
// creation code built here, whose metadata hash is the one the record names; the two core stores joined hold exactly
// the creation code of the core at 0x8AD0aC66DbeBcc047e8d216666C925E797e5e52e built here; and each store's data
// starts after a STOP byte.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..", "..");
const record = JSON.parse(readFileSync(join(here, "..", "deployments", "robinhood-4663.json"), "utf8"));

const ROOT = ["src/core/HookrRoot.sol", "HookrRoot"];
const CORE = "0x8AD0aC66DbeBcc047e8d216666C925E797e5e52e";

const factory = record.contracts.find((c) => c.group === "combined-core" && c.name === "HookrOwnedRootFactoryV2");
const template = (factory?.templates ?? []).find((t) => t.contract === ROOT.join(":"));
const stores = (factory?.dataContracts ?? []).filter((d) => d.name === "HookrCodeStore");
const core = record.contracts.find((c) => c.address.toLowerCase() === CORE.toLowerCase());
if (!template || stores.length !== 3 || !core) {
  console.error("the record lists no root v2 template, three HookrCodeStore stores and the core under owned-root factory v2");
  process.exit(1);
}

const argument = process.argv[2];
if (!argument || argument === "--help") {
  console.error("usage: node hookr-1/combined-core/check-code-stores.mjs --input <build root>");
  console.error(
    "       node hookr-1/combined-core/check-code-stores.mjs <root solc output.json> <core solc output.json> <root store hex> <core store 0 hex> <core store 1 hex>",
  );
  process.exit(2);
}

if (argument === "--input") {
  const buildRoot = process.argv[3];
  if (!buildRoot) {
    console.error("pass the build root, the absolute prefix of the remappings in lane v2's verified metadata on Sourcify");
    process.exit(2);
  }
  const named = (text) => text.split("<build-root>").join(buildRoot);
  const sources = {};
  for (const [unit, path] of Object.entries(template.sources)) {
    sources[named(unit)] = { content: readFileSync(join(root, path), "utf8") };
  }
  const input = {
    language: "Solidity",
    sources,
    settings: {
      ...JSON.parse(named(JSON.stringify(record.settings[template.settings]))),
      outputSelection: {
        "*": {
          "*": ["evm.bytecode.object", "evm.deployedBytecode.object", "metadata"],
        },
      },
    },
  };
  // No process.exit here: on a pipe it would cut the input short before stdout drains.
  process.stdout.write(JSON.stringify(input) + "\n");
} else {
  check(process.argv.slice(2));
}

function compiled(outputPath, [unit, name]) {
  const output = JSON.parse(readFileSync(outputPath, "utf8"));
  const errors = (output.errors ?? []).filter((e) => e.severity === "error");
  if (errors.length > 0) {
    console.error(errors.map((e) => e.formattedMessage).join("\n"));
    process.exit(1);
  }
  const evm = output.contracts?.[unit]?.[name]?.evm;
  if (!evm) {
    console.error(`${unit}:${name} is not in ${outputPath}`);
    process.exit(1);
  }
  return evm;
}

function data(path) {
  const runtime = Buffer.from(readFileSync(path, "utf8").trim().replace(/^0x/, ""), "hex");
  if (runtime.length === 0 || runtime[0] !== 0x00) {
    console.log(`MISMATCH ${path}: a store starts with a STOP byte`);
    process.exit(1);
  }
  return runtime.subarray(1);
}

function check([rootOutput, coreOutput, rootStore, ...coreStores]) {
  if (!rootOutput || !coreOutput || !rootStore || coreStores.length !== 2) {
    console.error(
      "usage: node hookr-1/combined-core/check-code-stores.mjs <root solc output.json> <core solc output.json> <root store hex> <core store 0 hex> <core store 1 hex>",
    );
    process.exit(2);
  }

  // Root v2: the root store holds its creation code, and the build carries the metadata hash the record names.
  const rootEvm = compiled(rootOutput, ROOT);
  const rootBuilt = Buffer.from(rootEvm.bytecode.object, "hex");
  const rootHeld = data(rootStore);
  if (!rootHeld.equals(rootBuilt)) {
    console.log(`MISMATCH root v2 creation code: ${rootBuilt.length} bytes built, ${rootHeld.length} bytes in the root store`);
    process.exit(1);
  }
  const cid = metadataHash(Buffer.from(rootEvm.deployedBytecode.object, "hex"));
  if (cid !== template.metadataIpfs) {
    console.log(`MISMATCH ${ROOT.join(":")} metadata ${cid}, the record names ${template.metadataIpfs}`);
    process.exit(1);
  }

  // The core: its library is set in the settings, so the creation code has no link references left.
  const [unit, name] = [core.contract.slice(0, core.contract.lastIndexOf(":")), core.contract.split(":").pop()];
  const coreEvm = compiled(coreOutput, [unit, name]);
  if (Object.keys(coreEvm.bytecode.linkReferences ?? {}).length > 0 || /__\$/.test(coreEvm.bytecode.object)) {
    console.log(`MISMATCH ${core.contract}: the build has unlinked libraries; write its input with standard-input.mjs ${CORE}`);
    process.exit(1);
  }
  const coreBuilt = Buffer.from(coreEvm.bytecode.object, "hex");
  const pieces = coreStores.map(data);
  const coreHeld = Buffer.concat(pieces);
  if (!coreHeld.equals(coreBuilt)) {
    console.log(`MISMATCH the core's creation code: ${coreBuilt.length} bytes built, ${coreHeld.length} bytes in the core stores`);
    process.exit(1);
  }

  console.log(
    `MATCH root v2 creation code: ${rootHeld.length} bytes in the root store, metadata ${cid}; ` +
      `the core's creation code: ${coreHeld.length} bytes in 2 stores (${pieces.map((p) => p.length).join(" + ")})`,
  );
}

// The metadata hash in the CBOR tail of a compiled runtime, as base58 (an IPFS CIDv0).
function metadataHash(runtime) {
  const cbor = runtime.subarray(runtime.length - 2 - runtime.readUInt16BE(runtime.length - 2), runtime.length - 2);
  const marker = Buffer.from("64697066735822", "hex"); // "ipfs" as a CBOR key, then a 34-byte string header
  const at = cbor.indexOf(marker);
  if (at === -1) return null;
  const multihash = cbor.subarray(at + marker.length, at + marker.length + 34);
  const alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
  let n = BigInt(`0x${multihash.toString("hex")}`);
  let out = "";
  while (n > 0n) {
    out = alphabet[Number(n % 58n)] + out;
    n /= 58n;
  }
  return out;
}
