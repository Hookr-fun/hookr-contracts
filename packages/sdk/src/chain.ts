import { defineChain, type Address } from "viem";

export const HOOKR_CHAIN_ID = 4663 as const;
export const HOOKR_PUBLIC_RPC_URL = "https://rpc.mainnet.chain.robinhood.com" as const;
export const HOOKR_EXPLORER_URL = "https://robinhoodchain.blockscout.com" as const;
export const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000" as const satisfies Address;

export const robinhoodChain = defineChain({
  id: HOOKR_CHAIN_ID,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: [HOOKR_PUBLIC_RPC_URL] },
  },
  blockExplorers: {
    default: { name: "Robinhood Blockscout", url: HOOKR_EXPLORER_URL },
  },
  contracts: {
    multicall3: {
      address: "0xcA11bde05977b3631167028862bE2a173976CA11",
    },
  },
});

export function hookrExplorerAddress(address: Address): string {
  return `${HOOKR_EXPLORER_URL}/address/${address}`;
}

export function hookrExplorerTransaction(hash: `0x${string}`): string {
  return `${HOOKR_EXPLORER_URL}/tx/${hash}`;
}
