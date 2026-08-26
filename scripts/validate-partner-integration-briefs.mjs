#!/usr/bin/env node

import { readFile, readdir } from "node:fs/promises";
import { resolve } from "node:path";
import {
  assertPartnerIntegrationSchema,
  createPartnerIntegrationSchemaValidator,
} from "./lib/partner-integration-schema.mjs";

const root = process.cwd();
const examplesDirectory = resolve(root, "integrations", "partners", "examples");
const schema = JSON.parse(
  await readFile(resolve(root, "integrations", "partners", "schema.v1.json"), "utf8"),
);
const validate = createPartnerIntegrationSchemaValidator(schema);
const requested = process.argv.slice(2);
const files = requested.length
  ? requested.map((file) => resolve(root, file))
  : (await readdir(examplesDirectory))
      .filter((file) => file.endsWith(".json"))
      .sort()
      .map((file) => resolve(examplesDirectory, file));

if (files.length === 0) throw new Error("No partner integration briefs found");

const slugs = new Set();
for (const file of files) {
  const brief = JSON.parse(await readFile(file, "utf8"));
  assertPartnerIntegrationSchema(brief, validate, file);
  if (slugs.has(brief.slug)) throw new Error(`Duplicate partner integration slug: ${brief.slug}`);
  slugs.add(brief.slug);
  process.stdout.write(`valid ${brief.slug} (${brief.track})\n`);
}

process.stdout.write(`validated ${files.length} partner integration brief${files.length === 1 ? "" : "s"}\n`);
