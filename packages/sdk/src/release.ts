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
  schemaVersion: "hookr.integration-capabilities.v1",
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
        profileLabel: "WTH" as const,
        profileLabelStatus: "source-label" as const,
        serviceIdentity: {
          status: "unverified" as const,
          productionRecipient: null,
          externalAbiAcceptance: "unaccepted" as const,
        },
        integrationIdPreimage: "hookr.integration.wth-arb.v1",
        integrationId:
          "0x96b4bee6c464c61145bc4ddbff93ba0bc5e303003b633a6676dbe491acd3e651" as Hex,
        feePolicyIdPreimage:
          "hookr.fee-policy.wth-arb.v1:creator=4000,trader=2000,trigger-pool-lp=2000,wth=1000,hookr=1000",
        feePolicyId:
          "0xe786145bacf8a9afb49db278f5c581557d335b51cebbed990a5c5e0871910499" as Hex,
        binding: "release-required" as const,
      },
      feePolicy: {
        basis: "gross-realized-quote-profit" as const,
        fixed: true,
        creatorBps: 4_000,
        authenticatedSwapRecipientBps: 2_000,
        triggerPoolLpsBps: 2_000,
        wthBps: 1_000,
        hookrBps: 1_000,
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
      appliesTo:
        "Intended for eligible new V6 Hookr pools only after service verification, profile activation, and a supported second venue",
      behavior:
        "Source design for attempting one bounded, signer-approved post-swap correction and applying the fixed 40/20/20/10/10 realized-profit waterfall; no WTH service is active.",
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
        "The public SDK remains V5-only and exposes no V6 transaction API",
        "Has no production deployment or route-signing manifest",
      ],
    },
  },
});
