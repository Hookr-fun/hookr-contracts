import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const ROOT = resolve(import.meta.dirname, "..");

const EXPORTS = [
  {
    artifact: "contracts/out/HookrLockRewardsV2.sol/HookrLockRewardsV2.json",
    output: "src/lib/abi/HookrLockRewardsV2.json",
  },
  {
    artifact: "contracts/out/HookrLaunchBoostV2.sol/HookrLaunchBoostV2.json",
    output: "src/lib/abi/HookrLaunchBoostV2.json",
  },
  {
    artifact: "contracts/out/HookrLockRewardsV1.sol/HookrLockRewardsV1.json",
    output: "src/lib/abi/HookrLockRewardsV1.json",
  },
  {
    artifact: "contracts/out/HookrLaunchBoostV1.sol/HookrLaunchBoostV1.json",
    output: "src/lib/abi/HookrLaunchBoostV1.json",
  },
];

for (const entry of EXPORTS) {
  const artifactPath = resolve(ROOT, entry.artifact);
  const outputPath = resolve(ROOT, entry.output);
  const artifact = JSON.parse(await readFile(artifactPath, "utf8"));
  if (!Array.isArray(artifact.abi) || artifact.abi.length === 0) {
    throw new Error(`artifact has no ABI: ${entry.artifact}`);
  }
  await writeFile(outputPath, `${JSON.stringify(artifact.abi, null, 2)}\n`, "utf8");
  console.log(`${entry.artifact} -> ${entry.output}`);
}
