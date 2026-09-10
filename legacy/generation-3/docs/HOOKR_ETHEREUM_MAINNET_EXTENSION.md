# Hookr on Ethereum mainnet — extension evidence packet

Prepared 2026-08-22 for the multi-chain expansion lane (Base / Unichain / Ethereum mainnet).
This file contains **verified onchain facts** and the exact integration points needed to add
Ethereum mainnet (chain id 1) alongside Base and Unichain. Nothing here opens writes: every
new chain ships `status: "target"` and stays fail-closed until a real deployment is broadcast,
canaried, verified, and promoted through the normal release-evidence path.

## 1. Verified PoolManager identities (live RPC, checked 2026-08-22)

| Chain | PoolManager | Runtime codehash (`keccak256(eth_getCode)`) |
|---|---|---|
| Robinhood 4663 | `0x8366a39CC670B4001A1121B8F6A443A643e40951` | `0xbd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626` |
| Base 8453 | `0x498581fF718922c3f8e6A244956aF099B2652b2b` | `0x83b2af6e9f3158defc2811cbcb0db71ecf8b2ba2abea39c39e370ac5c6f43eb6` |
| Ethereum 1 | `0x000000000004444c5dc75cB358380D2e3dE08A90` | `0x785f1014552b7ce7d5fb7d0c970ca60edee94fd00425d7ca21609acac7ce1293` |

Sources: official Uniswap v4 deployment list (`docs.uniswap.org/contracts/v4/deployments`),
cross-checked against live RPC (`cast codesize` / `cast keccak $(cast code …)`). Mainnet and
Base PoolManagers are both exactly 24,009 bytes of runtime code; the hashes differ across
chains because the owner immutable is baked into deployed bytecode. **Never reuse one chain's
codehash anchor for another.**

## 2. Integration points

### `src/lib/chains.ts`

Append one descriptor to `HOOKR_CHAINS` (and `ETHEREUM_CHAIN_ID = 1`, key `"ethereum"`):

```ts
{
  key: "ethereum",
  id: 1,
  name: "Ethereum",
  chain: mainnet as unknown as Chain, // viem/chains mainnet
  analyticsChain: "ethereum-1",
  explorerUrl: "https://etherscan.io",
  poolManager: "0x000000000004444c5dc75cB358380D2e3dE08A90",
  publicRpcUrl: process.env.NEXT_PUBLIC_ETHEREUM_RPC_URL || "https://ethereum-rpc.publicnode.com",
  serverRpcUrl: process.env.ETHEREUM_RPC_URL || process.env.NEXT_PUBLIC_ETHEREUM_RPC_URL || "https://ethereum-rpc.publicnode.com",
  status: "target",
}
```

Endpoint policy matches the existing registry rules: the public URL ships to wallets and
client bundles and must stay keyless; the server URL may point at a paid provider.

### `contracts/foundry.toml`

Already merged: `[rpc_endpoints] mainnet = "https://ethereum-rpc.publicnode.com"`. Override
per run with `--rpc-url` or `MAINNET_RPC_URL` when a keyed endpoint is preferred. For
verification use Etherscan V2:

```
forge verify-contract <addr> <Contract> --verifier etherscan \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --verifier-url https://api.etherscan.io/v2/api --chain-id 1
```

### Deployment + canary scripts (when ported multichain)

The chain-parameterized deploy/canary pattern was prototyped and compiles; reference copies
of that session live outside the repo. Load-bearing findings, all still applicable:

- Solidity has no struct constants — build the per-chain config in a pure selector function
  returning a `ChainConfig` struct from scalar constants (`ChainConfig constant X = …` fails
  to compile).
- The launchpad runtime embeds its PoolManager address as an immutable, so the *reviewed
  launchpad runtime hash is per-chain by construction*. A new chain starts with a zero
  anchor: dry-run first, log the candidate hash, pin it after human review, and let
  `run-canary.sh`'s grep-based anchor check refuse any canary while it is zero.
- Current source has the 17-field `HookParams` (five trailing buyback fields) and the wider
  `PoolConfig` return — blueprint seeding and `poolConfig` destructuring in any new script
  must match the current structs, not older script copies.
- The canary intent id `keccak256("hookr.v4.canary.instant.all-five.1")` may stay identical
  across chains: consumption is scoped to one launchpad contract + creator per chain, so
  `INSTANT_CANARY_SPEC` needs no per-chain fork.
- EIP-170 runtime-size assertions and the CREATE2 hook-mining loop are chain-agnostic.

### Release manifest + gates

Base/mainnet/Unichain enter as pending manifests with `productionAllowed: false` and empty
evidence, so `releaseGateBlockers()` keeps every browser write closed until promotion tooling
verifies receipts, pinned-block linkage, and the canary round trip against live RPC — same
gauntlet Robinhood went through.

### Promotion tooling

Parameterize by chain id: per-chain PoolManager identity constants, artifact default paths
(`broadcast/<Script>.s.sol/<chainId>/run-latest.json`), and the height policy. Robinhood's
non-standard header field drives a two-height distinction there; on Ethereum mainnet the
Solidity-visible block number equals the receipt height, so `contractBlockNumberForReceipt`
must fall back to `receipt.blockNumber` when no rollup height field exists.

## 3. Operator prerequisites observed 2026-08-22

Deployer `0x5a52D4B820Ae7F02880d270562950918ACb14aA2` balances were **insufficient** on both
target chains (Base ≈ 0.00082 ETH; mainnet ≈ 0.0045 ETH). Fund before scheduling broadcasts;
mainnet gas makes the ten-transaction deploy plus four-receipt canary materially more
expensive than Base. Broadcasts remain gated on the standard explicit-confirmation checklist;
a receipt proves inclusion, not success — verify each one plus its readbacks in order.

## 4. Status

- [x] PoolManager identities verified on live RPCs (all three chains)
- [x] foundry endpoints merged without disturbing the active migration lane
- [x] Duplicate prototype scripts withdrawn from `contracts/script/` (folded into the
      active session's naming plan; reference behavior documented above)
- [ ] `chains.ts` ethereum descriptor (apply after the active session lands)
- [ ] Multichain deploy/canary port incl. mainnet row (after contract migration settles)
- [ ] Dry-run simulations per chain → candidate addresses + per-chain reviewed hashes
- [ ] Funding, operator confirmation, broadcasts, canaries, promotion per chain
