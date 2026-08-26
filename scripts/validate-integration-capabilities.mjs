#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";

const root = process.cwd();
const schema = JSON.parse(
  await readFile(resolve(root, "integrations/capabilities/schema.v1.json"), "utf8"),
);
const manifest = JSON.parse(
  await readFile(resolve(root, "integrations/capabilities/current.v1.json"), "utf8"),
);
const ajv = new Ajv2020({ allErrors: true, strict: true });
addFormats(ajv);
const validate = ajv.compile(schema);
if (!validate(manifest)) {
  throw new Error(`Invalid integration capability manifest: ${ajv.errorsText(validate.errors)}`);
}

const arb = manifest.capabilities.arbRecapture;
const compatible = new Set(arb.compatibleHookBlocks);
const incompatible = new Set(arb.incompatibleHookBlocks);
for (const block of incompatible) {
  if (compatible.has(block)) throw new Error(`Arb block cannot be both compatible and incompatible: ${block}`);
}
if (!incompatible.has("lp-rewards")) throw new Error("Arb Recapture must retain the reviewed LP Rewards exclusion");
if (arb.production || arb.routeSigning) throw new Error("Arb Recapture cannot be marked live without a promoted V6 release");

process.stdout.write("valid integration capabilities (arb source-review, signing disabled)\n");
