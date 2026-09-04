import type { Address, Hex } from "viem";
import { HOOKR_CHAIN_ID } from "./chain.js";

export type IntegrationAvailability =
  | "live"
  | "release-candidate"
  | "technical-review"
  | "new-release-required"
  | "source-review";

export const PARTNER_INTEGRATION_TRACKS = [
  "hook_publication",
  "hook_token_launch",
  "existing_token_pool",
  "launchpad_sdk",
  "hook_generator",
  "executor_adapter",
] as const;

export type PartnerIntegrationTrack = (typeof PARTNER_INTEGRATION_TRACKS)[number];

type RuntimeIdentity = Readonly<{
  address: Address;
  runtimeCodeHash: Hex;
  contractName?: string;
  contractVersion?: string;
}>;

/**
 * Promoted generation-5 write target. Runtime hashes and wiring remain the authority; consumers
 * should call `verifyHookrRelease` before enabling a long-lived integration.
 */
export const HOOKR_V5_RELEASE = Object.freeze({
  schemaVersion: "hookr.sdk-release.v1",
  chainId: HOOKR_CHAIN_ID,
  generation: 5,
  productionAllowed: true,
  deployBlock: 41_850_162n,
  launchModes: ["instant", "bonded"] as const,
  contracts: {
    launchpad: {
      address: "0xa043caBE645636899dDe91Cce4693C00a015e660",
      runtimeCodeHash: "0x26dd92acae56386f99dbc98ed2f53aa62ccff493bab27b6f1a26d84e23ed3a5d",
      contractName: "HookrLaunchpadV5",
      contractVersion: "5.0.1",
    } satisfies RuntimeIdentity,
    hook: {
      address: "0xe7c3461A4c762fF9dB4F91BeE3Cf8deAaFc2E8CC",
      runtimeCodeHash: "0x1d8e5b8f744d277779ddbeaed93e18afda4bfdfae74b4c8c5147601b8ee9f4ea",
      contractName: "HookrHook",
      contractVersion: "1.0.0",
    } satisfies RuntimeIdentity,
    router: {
      address: "0x644ac2e784059e1C01F24f99DF7795aE2be06ca0",
      runtimeCodeHash: "0xdfba091b062d784c6f06439d3a158d1ece3ca990f808b2aa474774893da27d61",
      contractName: "HookrSwapRouter",
      contractVersion: "1.0.0",
    } satisfies RuntimeIdentity,
    poolManager: {
      address: "0x8366a39CC670B4001A1121B8F6A443A643e40951",
      runtimeCodeHash: "0xbd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626",
    } satisfies RuntimeIdentity,
    quoteToken: {
      address: "0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c" as Address,
    },
    flywheelBurner: {
      address: "0x8Cee20FA000aF3266AC2cD2cBeEFbcD19D98FD89" as Address,
      runtimeCodeHash: "0xa75474371e64ed31e66ce6d1be687f00b87607ca7ca9818e15030d8b311cf84d" as Hex,
    },
  },
  releaseEvidence: {
    sourceCommit: "b1ccb017f86d9caffff8bf4277a735d714130972",
    fixedBlock: {
      number: 42_375_538n,
      hash: "0x15e3fcbd3b111e0cea82764777fa2f4d0da1e2216334095a01ab03f55767773d" as Hex,
    },
    publicSourceStatus: "current" as const,
  },
  lastLiveVerification: {
    number: 46_366_119n,
    hash: "0xcc3892177d686e6afda7f71e5cc37ce7fd8321512930dfbc6ea8ae3e7edcd482" as Hex,
    checkedAt: "2026-08-26T06:17:25.421Z",
  },
});

export const HOOKR_INTEGRATION_CAPABILITIES = Object.freeze({
  schemaVersion: "hookr.integration-capabilities.v2",
  updatedAt: "2026-08-26",
  release: {
    chainId: HOOKR_CHAIN_ID,
    generation: 5,
    publicSourceStatus: "current" as const,
  },
  capabilities: {
    fiveBlockComposer: {
      availability: "live" as IntegrationAvailability,
      appliesTo: "New Hookr V5 launches",
      hookBlocks: ["anti-snipe", "surge-fees", "auto-burn", "lp-rewards", "nth-buy-pot"],
    },
    partnerSdk: {
      availability: "release-candidate" as IntegrationAvailability,
      package: "@hookr/sdk",
      version: "0.1.0-rc.1",
      generation: 5,
      tracks: ["launchpad_sdk", "hook_generator"] satisfies readonly PartnerIntegrationTrack[],
      note: "Source, tests, examples, and package smoke checks exist; npm publication is a separate release action.",
    },
    externalHooks: {
      availability: "technical-review" as IntegrationAvailability,
      tracks: ["hook_publication", "hook_token_launch"] satisfies readonly PartnerIntegrationTrack[],
      note: "A pinned public manifest can enter review. Source review is not deployment or routing approval.",
    },
    existingTokenPool: {
      availability: "new-release-required" as IntegrationAvailability,
      tracks: ["existing_token_pool"] satisfies readonly PartnerIntegrationTrack[],
      note: "A hook cannot be attached to an existing pool. The path creates a new reviewed PoolKey.",
    },
    v6IntegrationModel: {
      availability: "source-review" as IntegrationAvailability,
      production: false,
      sdkTransactionApi: false,
      poolKeyRoot: {
        rootHookSlots: 1,
        checkoutSelection: "one-root-profile" as const,
      },
      paths: {
        nativeRootBlocks: {
          requiresNewImmutableHookrGeneration: true,
          composition: "reviewed-schema-only" as const,
        },
        typedSubordinateExecutor: {
          optional: true,
          binding: "exact-versioned-profile" as const,
        },
        exclusiveExternalRoot: {
          composesWithNativeBlocks: false,
          requiredPolicyBindings: [
            "purpose-built-adapter",
            "router-policy",
            "quoter-policy",
          ] as const,
        },
        existingToken: {
          poolSemantics: "new-pool-key" as const,
          existingPoolsChanged: false,
        },
        launchpadAdapter: {
          binding: "atomic" as const,
          exactFields: [
            "profile",
            "config",
            "caller",
            "creator",
            "beneficiary",
            "funding",
            "deadline",
            "nonce",
          ] as const,
        },
      },
      existingDeployedHookAsNativeBlock: "unsupported" as const,
      monetization: {
        availability: "explicit-versioned-policy-only" as const,
        feePolicyIdentity: "versioned-feePolicyHash" as const,
        recipientAccounting: "explicit" as const,
      },
    },
    arbRecapture: {
      name: "WTH Arb Recapture",
      availability: "source-review" as IntegrationAvailability,
      tracks: ["executor_adapter", "hook_token_launch", "existing_token_pool"] satisfies readonly PartnerIntegrationTrack[],
      production: false,
      routeSigning: false,
      activationStatus: "inactive" as const,
      selection: "optional" as const,
      integrationProfile: {
        candidateGeneration: "v6.1" as const,
        sourceBoundary: "separate-versioned-release-required" as const,
        sourceCheckpointStatus: "clean-v61-source-checkpoint" as const,
        sourceCheckpointSha:
          "5168888ed69cc738492368203197ee72a009a964" as const,
        profileLabel: "WTH" as const,
        profileLabelStatus: "source-label" as const,
        serviceIdentity: {
          status: "unverified" as const,
          productionRecipient: null,
          externalAbiAcceptance: "unaccepted" as const,
        },
        integrationIdPreimage: "hookr.integration.wth-arb.v2",
        integrationId:
          "0xd49d445cfb1f944f40848794320f9ba89f9a8830fcbedf98c236f82476f7d680" as Hex,
        feePolicyIdPreimage:
          "hookr.fee-policy.wth-arb.v2:hookr=1000,wth=1000,configurable-creator-trader-trigger-pool-sum=8000",
        feePolicyId:
          "0x656d4d246973da37dc2020b1c4494018646a8033d212c09dc3bb82a4b0898ba7" as Hex,
        binding: "release-required" as const,
      },
      feePolicy: {
        basis: "gross-realized-quote-profit" as const,
        generation: "v2" as const,
        fixedProtocolShares: {
          wthBps: 1_000,
          hookrBps: 1_000,
        },
        configurablePoolShares: {
          sumBps: 8_000,
          abiStruct: "ProfitSplit" as const,
          abiFields: [
            "creator",
            "traderBps",
            "creatorBps",
            "triggerPoolBps",
          ] as const,
          bpsFields: ["traderBps", "creatorBps", "triggerPoolBps"] as const,
          lockedAt: "pool-configuration" as const,
          defaults: {
            traderBps: 2_000,
            creatorBps: 4_000,
            triggerPoolBps: 2_000,
          },
          semantics: {
            creator: "pool-configured-creator-or-authorized-attacher" as const,
            traderBps: "authenticated-rebate-recipient-never-tx-origin" as const,
            triggerPoolBps: "pool-id-scoped-lp-escrow-not-position-distribution" as const,
          },
        },
        recipientIdentity: {
          hookr: "hookr.eth-resolved-address-pinned-at-release" as const,
          wth: "whatthehook.eth-resolved-address-pinned-at-release" as const,
        },
        externalRoundingAcceptance: "unverified" as const,
        externalRecipientSemanticsAcceptance: "unverified-no-tx-origin" as const,
      },
      v6Sdk: {
        availability: "held" as const,
        transactionApi: false,
        reason: "No promoted V6 release manifest or canary readback",
      },
      existingTokenAttach: {
        poolSemantics: "new-pool-key" as const,
        existingPoolsChanged: false,
        creatorBeneficiary: "authorized-attacher" as const,
        admission: {
          scope: "initial-pull-only" as const,
          requiredDecimals: 18,
          initialFactoryBalanceDelta: "exact-requested-amount" as const,
          laterMutableTransferSemantics: "unsupported" as const,
          unsupportedLaterBehaviors: [
            "transfer-tax",
            "rebase",
            "pause-or-freeze",
            "blacklist",
            "callback-or-reentrancy",
            "code-loss",
          ] as const,
        },
      },
      triggerPoolLpDelivery: {
        status: "adapter-escrow" as const,
        distributed: false,
        claimableByLps: false,
        distributorStatus: "absent" as const,
        note: "Source reserves a PoolId-scoped amount for one adapter; adapter withdrawal is not LP distribution and does not prove delivery to eligible LP positions.",
      },
      routingAndScanner: {
        canonicalRouter: "required-for-authenticated-gated-pot-and-wth-routes" as const,
        genericEmptyData: {
          ungatedExactInputBuy: "candidate-source-supported" as const,
          exactInputExit: "candidate-source-supported" as const,
          gatedBuy: "unsupported" as const,
          potQualifyingBuy: "unsupported" as const,
          exactOutputExit: "conditional-unverified" as const,
        },
        quoter: {
          simulationActor: "caller-supplied" as const,
          executableOnlyWhenBoundToActiveWallet: true,
        },
        robinhoodUniversalRouter: {
          status: "unverified" as const,
          officialSourceState: "conflicting-addresses" as const,
          exactForkMatrix: false,
        },
        scannerEvidence: {
          authoritative: false,
          v5Token: "0x0093005884142Fb305A3991DCD24e55Bfebf1570" as Address,
          blockaidStatus: "warning-observed" as const,
          successfulSellTransaction:
            "0xac74066b69caaf84df9a9f86a118bc09a977ae315e712047dcf895bb76dfcd9c" as Hex,
          conclusion: "sellability-proved-for-one-route-not-scanner-clearance" as const,
        },
      },
      appliesTo:
        "Intended for eligible new V6.1 Hookr pools only after service verification, profile activation, and a supported second venue",
      behavior:
        "Source design for attempting one bounded, signer-approved post-swap correction. Hookr and WTH are fixed at 10% each; the pool locks creator, authenticated-swap-recipient, and trigger-pool shares that must total the remaining 80%, defaulting to 40/20/20. No WTH service is active.",
      compatibleHookBlocks: ["surge-fees", "auto-burn", "nth-buy-pot"],
      conditionalHookBlocks: [
        {
          block: "anti-snipe",
          duringGuard: {
            outerBuyCorrection: "supported" as const,
            outerSellCorrection: "fail-open" as const,
            outerSellRequirement: "exact-output-target-buy" as const,
          },
          afterGuard: "supported" as const,
          note: "During the Anti-Snipe guard, outer-buy Arb corrections can operate. Outer-sell corrections require an exact-output target buy and fail open until the guard ends.",
        },
      ],
      incompatibleHookBlocks: ["lp-rewards"],
      boundaries: [
        "Does not retrofit an existing V5 pool",
        "Does not apply to every external hook",
        "Does not guarantee that arbitrage is prevented or captured",
        "WTH is a source profile label; service identity and external ABI acceptance are unverified",
        "LP source allocation remains adapter escrow, is not distributed, and is not claimable by LPs",
        "Existing-token checks cover only 18 decimals and the exact initial factory balance delta; later mutable token behavior is unsupported",
        "A qualifying Nth-buy Pot buy requires the exact registry-bound Hookr router or simulation quoter plus an authenticated recipient; the official Universal Router is unsupported for that buy path",
        "Exact-output buys are blocked while Anti-Snipe is active; the guard does not block sells",
        "PoolManager emits Swap before Hookr afterSwap return deltas, so scanners and indexers must use final deltas and settlement transfers for realized amounts",
        "The public SDK remains V5-only and exposes no V6 transaction API",
        "The frozen V6/WTH-v1 reference uses a superseded fixed-share ABI and is not the V6.1 WTH-v2 interface",
        "WTH trader-share semantics are unaccepted: tx.origin is prohibited; the recipient must be authenticated and bound to the Hookr envelope or the share must remain disabled/escrowed",
        "Has no production deployment or route-signing manifest",
      ],
    },
  },
});
