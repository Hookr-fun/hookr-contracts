#!/usr/bin/env node

import { readFile, readdir } from "node:fs/promises";
import { resolve } from "node:path";
import { assertExternalHookManifest } from "./lib/external-hook-standard.mjs";
import {
  assertExternalHookSchema,
  createExternalHookSchemaValidator,
} from "./lib/external-hook-schema.mjs";

const root = process.cwd();
const manifestsDir = resolve(root, "integrations/hooks/manifests");
const policy = JSON.parse(
  await readFile(resolve(root, "integrations/hooks/uniswap-policy.v1.json"), "utf8"),
);
const schema = JSON.parse(
  await readFile(resolve(root, "integrations/hooks/schema.v1.json"), "utf8"),
);
const validateSchema = createExternalHookSchemaValidator(schema);
const requested = process.argv.slice(2);
const files = requested.length
  ? requested.map((file) => resolve(root, file))
  : (await readdir(manifestsDir))
      .filter((file) => file.endsWith(".json"))
      .sort()
      .map((file) => resolve(manifestsDir, file));

if (files.length === 0) throw new Error("No external hook manifests found");

const slugs = new Set();
const deployedHooks = new Set();
for (const file of files) {
  const manifest = JSON.parse(await readFile(file, "utf8"));
  assertExternalHookSchema(manifest, validateSchema, file);
  assertExternalHookManifest(manifest, policy);
  if (slugs.has(manifest.slug)) throw new Error(`Duplicate manifest slug: ${manifest.slug}`);
  slugs.add(manifest.slug);
  for (const deployment of manifest.deployments) {
    const key = `${deployment.chain}:${deployment.hookAddress.toLowerCase()}`;
    if (deployedHooks.has(key)) throw new Error(`Duplicate deployed hook across manifests: ${key}`);
    deployedHooks.add(key);
  }
  process.stdout.write(`valid ${manifest.slug} (${manifest.status})\n`);
}

process.stdout.write(`validated ${files.length} external hook manifest${files.length === 1 ? "" : "s"}\n`);
