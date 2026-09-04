import type { PublicClient } from "viem";
import { verifyHookrRelease } from "../src/index.js";

export async function requireCurrentHookrRelease(publicClient: PublicClient) {
  const report = await verifyHookrRelease(publicClient);
  if (!report.ok) throw new Error(JSON.stringify(report.issues));
  return report;
}
