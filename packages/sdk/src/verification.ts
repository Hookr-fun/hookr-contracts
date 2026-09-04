import { isAddressEqual, keccak256, type Address, type Hex, type PublicClient } from "viem";
import { hookrHookAbi, hookrLaunchpadV5Abi, hookrSwapRouterAbi } from "./abi.js";
import { HOOKR_CHAIN_ID } from "./chain.js";
import { HOOKR_V5_RELEASE } from "./release.js";

export type ReleaseVerificationIssue = Readonly<{
  code: string;
  contract?: "launchpad" | "hook" | "router" | "poolManager" | "flywheelBurner";
  message: string;
  expected?: string;
  observed?: string;
}>;

export type ReleaseVerificationReport = Readonly<{
  schemaVersion: "hookr.release-verification.v1";
  ok: boolean;
  chainId: number | null;
  blockNumber: bigint | null;
  blockHash: Hex | null;
  checkedAt: string;
  issues: readonly ReleaseVerificationIssue[];
}>;

type ContractLabel = NonNullable<ReleaseVerificationIssue["contract"]>;

function mismatch(
  issues: ReleaseVerificationIssue[],
  input: Omit<ReleaseVerificationIssue, "message"> & { label: string },
): void {
  issues.push({
    code: input.code,
    ...(input.contract ? { contract: input.contract } : {}),
    message: `${input.label} did not match the promoted V5 manifest.`,
    ...(input.expected ? { expected: input.expected } : {}),
    ...(input.observed ? { observed: input.observed } : {}),
  });
}

function compareText(
  issues: ReleaseVerificationIssue[],
  contract: ContractLabel,
  label: string,
  expected: string,
  observed: string,
): void {
  if (observed !== expected) mismatch(issues, { code: "IDENTITY_MISMATCH", contract, label, expected, observed });
}

function compareAddress(
  issues: ReleaseVerificationIssue[],
  contract: ContractLabel,
  label: string,
  expected: Address,
  observed: Address,
): void {
  if (!isAddressEqual(observed, expected)) mismatch(issues, { code: "WIRING_MISMATCH", contract, label, expected, observed });
}

/**
 * Verifies code hashes, stable identities, and immutable wiring at one block. It performs no write
 * and does not turn a passing source build into deployment evidence.
 */
export async function verifyHookrRelease(client: PublicClient): Promise<ReleaseVerificationReport> {
  const issues: ReleaseVerificationIssue[] = [];
  let chainId: number | null = null;
  let blockNumber: bigint | null = null;
  let blockHash: Hex | null = null;
  try {
    chainId = await client.getChainId();
    if (chainId !== HOOKR_CHAIN_ID) {
      mismatch(issues, {
        code: "CHAIN_ID_MISMATCH",
        label: "Chain id",
        expected: String(HOOKR_CHAIN_ID),
        observed: String(chainId),
      });
    }
    const block = await client.getBlock({ blockTag: "latest" });
    blockNumber = block.number;
    blockHash = block.hash;

    const runtimeEntries = [
      ["launchpad", HOOKR_V5_RELEASE.contracts.launchpad],
      ["hook", HOOKR_V5_RELEASE.contracts.hook],
      ["router", HOOKR_V5_RELEASE.contracts.router],
      ["poolManager", HOOKR_V5_RELEASE.contracts.poolManager],
      ["flywheelBurner", HOOKR_V5_RELEASE.contracts.flywheelBurner],
    ] as const;
    const bytecodes = await Promise.all(
      runtimeEntries.map(([, identity]) =>
        client.getBytecode({ address: identity.address, blockNumber: block.number }),
      ),
    );
    for (const [index, [contract, identity]] of runtimeEntries.entries()) {
      const bytecode = bytecodes[index];
      const observed = bytecode && bytecode !== "0x" ? keccak256(bytecode) : null;
      if (observed !== identity.runtimeCodeHash) {
        mismatch(issues, {
          code: observed ? "RUNTIME_HASH_MISMATCH" : "RUNTIME_MISSING",
          contract,
          label: `${contract} runtime code hash`,
          expected: identity.runtimeCodeHash,
          observed: observed ?? "no code",
        });
      }
    }

    const launchpad = HOOKR_V5_RELEASE.contracts.launchpad.address;
    const hook = HOOKR_V5_RELEASE.contracts.hook.address;
    const router = HOOKR_V5_RELEASE.contracts.router.address;
    const [
      launchpadName,
      launchpadVersion,
      launchpadHook,
      launchpadPoolManager,
      launchpadQuoteToken,
      hookName,
      hookVersion,
      hookLaunchpad,
      hookPoolManager,
      routerName,
      routerVersion,
      routerHook,
      routerPoolManager,
      routerQuoteToken,
    ] = await Promise.all([
      client.readContract({ address: launchpad, abi: hookrLaunchpadV5Abi, functionName: "contractName", blockNumber: block.number }),
      client.readContract({ address: launchpad, abi: hookrLaunchpadV5Abi, functionName: "contractVersion", blockNumber: block.number }),
      client.readContract({ address: launchpad, abi: hookrLaunchpadV5Abi, functionName: "hook", blockNumber: block.number }),
      client.readContract({ address: launchpad, abi: hookrLaunchpadV5Abi, functionName: "poolManager", blockNumber: block.number }),
      client.readContract({ address: launchpad, abi: hookrLaunchpadV5Abi, functionName: "hookrToken", blockNumber: block.number }),
      client.readContract({ address: hook, abi: hookrHookAbi, functionName: "contractName", blockNumber: block.number }),
      client.readContract({ address: hook, abi: hookrHookAbi, functionName: "contractVersion", blockNumber: block.number }),
      client.readContract({ address: hook, abi: hookrHookAbi, functionName: "launchpad", blockNumber: block.number }),
      client.readContract({ address: hook, abi: hookrHookAbi, functionName: "poolManager", blockNumber: block.number }),
      client.readContract({ address: router, abi: hookrSwapRouterAbi, functionName: "contractName", blockNumber: block.number }),
      client.readContract({ address: router, abi: hookrSwapRouterAbi, functionName: "contractVersion", blockNumber: block.number }),
      client.readContract({ address: router, abi: hookrSwapRouterAbi, functionName: "hook", blockNumber: block.number }),
      client.readContract({ address: router, abi: hookrSwapRouterAbi, functionName: "poolManager", blockNumber: block.number }),
      client.readContract({ address: router, abi: hookrSwapRouterAbi, functionName: "quoteToken", blockNumber: block.number }),
    ]);

    compareText(issues, "launchpad", "Launchpad contract name", HOOKR_V5_RELEASE.contracts.launchpad.contractName, launchpadName);
    compareText(issues, "launchpad", "Launchpad contract version", HOOKR_V5_RELEASE.contracts.launchpad.contractVersion, launchpadVersion);
    compareAddress(issues, "launchpad", "Launchpad hook", hook, launchpadHook);
    compareAddress(issues, "launchpad", "Launchpad PoolManager", HOOKR_V5_RELEASE.contracts.poolManager.address, launchpadPoolManager);
    compareAddress(issues, "launchpad", "Launchpad quote token", HOOKR_V5_RELEASE.contracts.quoteToken.address, launchpadQuoteToken);
    compareText(issues, "hook", "Hook contract name", HOOKR_V5_RELEASE.contracts.hook.contractName, hookName);
    compareText(issues, "hook", "Hook contract version", HOOKR_V5_RELEASE.contracts.hook.contractVersion, hookVersion);
    compareAddress(issues, "hook", "Hook launchpad", launchpad, hookLaunchpad);
    compareAddress(issues, "hook", "Hook PoolManager", HOOKR_V5_RELEASE.contracts.poolManager.address, hookPoolManager);
    compareText(issues, "router", "Router contract name", HOOKR_V5_RELEASE.contracts.router.contractName, routerName);
    compareText(issues, "router", "Router contract version", HOOKR_V5_RELEASE.contracts.router.contractVersion, routerVersion);
    compareAddress(issues, "router", "Router hook", hook, routerHook);
    compareAddress(issues, "router", "Router PoolManager", HOOKR_V5_RELEASE.contracts.poolManager.address, routerPoolManager);
    compareAddress(issues, "router", "Router quote token", HOOKR_V5_RELEASE.contracts.quoteToken.address, routerQuoteToken);
  } catch (error) {
    issues.push({
      code: "RPC_VERIFICATION_FAILED",
      message: error instanceof Error ? error.message : "Release verification failed before readback completed.",
    });
  }

  return Object.freeze({
    schemaVersion: "hookr.release-verification.v1" as const,
    ok: issues.length === 0,
    chainId,
    blockNumber,
    blockHash,
    checkedAt: new Date().toISOString(),
    issues: Object.freeze(issues),
  });
}
