import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import test from "node:test";

test("legacy V1 promoter cannot emit an open release candidate", () => {
  const result = spawnSync(process.execPath, ["scripts/promote-utility-release-candidate.mjs"], {
    encoding: "utf8",
  });
  assert.equal(result.status, 1);
  assert.equal(result.stdout, "");
  assert.match(result.stderr, /V1.*RETIRED.*recovery-only/i);
});
