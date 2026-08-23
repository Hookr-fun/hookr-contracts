import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

/**
 * Foundry artifact -> committed ABI JSON, the same one-way pipeline the utility ABIs use.
 * There is no codegen at build time: the app imports checked-in JSON, so a contract change
 * that nobody re-exported cannot silently reach the UI.
 */
const ROOT = resolve(import.meta.dirname, "..");

const EXPORTS = [
  { artifact: "contracts/out/LeverageMarket.sol/LeverageMarket.json", output: "src/lib/abi/LeverageMarket.json" },
  { artifact: "contracts/out/LeverageFactory.sol/LeverageFactory.json", output: "src/lib/abi/LeverageFactory.json" },
  { artifact: "contracts/out/LeverageHook.sol/LeverageHook.json", output: "src/lib/abi/LeverageHook.json" },
  { artifact: "contracts/out/LeverageRouter.sol/LeverageRouter.json", output: "src/lib/abi/LeverageRouter.json" },
];

for (const entry of EXPORTS) {
  const artifact = JSON.parse(await readFile(resolve(ROOT, entry.artifact), "utf8"));
  if (!Array.isArray(artifact.abi) || artifact.abi.length === 0) {
    throw new Error(`artifact has no ABI: ${entry.artifact}`);
  }
  await writeFile(resolve(ROOT, entry.output), `${JSON.stringify(artifact.abi, null, 2)}\n`);
  console.log(`${entry.output}  (${artifact.abi.length} entries)`);
}
