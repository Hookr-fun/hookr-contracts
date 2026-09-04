import type { Address, PublicClient } from "viem";
import {
  composeHookParams,
  createLaunchIntent,
  prepareInstantLaunch,
  readLaunchConfiguration,
} from "../src/index.js";

export async function preparePartnerLaunch(publicClient: PublicClient, creator: Address) {
  const configuration = await readLaunchConfiguration(publicClient);
  const custom = composeHookParams({
    antiSnipe: { guardBlocks: 100, maxBuyBps: 50, snipeTaxPips: 40_000 },
    surgeFees: { baseFeePips: 3_000, maxFeePips: 30_000, sensitivity: 5 },
  });
  return prepareInstantLaunch({
    quote: "eth",
    intent: createLaunchIntent({ creator, lane: "instant" }),
    creationFeeWei: configuration.creationFeeWei,
    args: {
      name: "Partner Market",
      symbol: "PARTNER",
      tagline: "Prepared by a versioned Hookr adapter.",
      logoURI: "https://example.com/partner-market.png",
      expectedCreator: creator,
      blueprintId: 0,
      custom,
      creatorFeeBps: 5_000,
      feeRecipients: [],
    },
  });
}
