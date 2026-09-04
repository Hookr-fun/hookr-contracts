import { access, readFile } from "node:fs/promises";

const root = new URL("../", import.meta.url);
const required = [
  "dist/esm/index.js",
  "dist/cjs/index.js",
  "dist/cjs/package.json",
  "dist/types/index.d.ts",
  "README.md",
  "LICENSE",
];

await Promise.all(required.map((path) => access(new URL(path, root))));

const packageJson = JSON.parse(await readFile(new URL("package.json", root), "utf8"));
if (packageJson.private === true) throw new Error("The SDK package is unexpectedly private");
if (packageJson.name !== "@hookr/sdk") throw new Error("Unexpected SDK package name");
if (!packageJson.exports?.["./verification"]) {
  throw new Error("The verification entry point is missing from package exports");
}
