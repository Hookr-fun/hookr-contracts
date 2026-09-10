# Audit scope

What an auditor is asked to review, what they may treat as a dependency, and the questions the system's own designers could not close from the inside.

## Status

Deployed on chain 4663. The evidence behind this scope is source review, a full run of the deployment and trading path against a fork of chain 4663, reads against the live contracts, and two canary pools the deployer opened and traded on the live deployment for a few thousandths of an ETH: a throwaway token against ETH (pool id `0xe375174c3e1a06b3150df6e27b7c409c06f259b9853d6287cd5262d2de26cc15`, seven transactions, every moved amount checked against the fee model) and HOOKR/ETH on the base fee alone (pool id `0x59fa67bc858058b4daad41ce138317c92e48fd9bccffdf2be646f18c2ec07720`, one position and one buy, every protocol counter unchanged). No independent audit has been completed. Every deployed contract's source is verified on Blockscout as a full match, and Sourcify holds each as an exact match. Addresses, runtime code hashes and the wiring read back from the chain are in [Deployments](../reference/deployments.md).

## In Scope

Six contracts and libraries carry the system, reviewed as a full diff rather than only against the invariants. Runtime sizes are from `forge build --sizes` at the pinned source commit, against the 24,576-byte EIP-170 limit, and each one equals the byte length of the deployed code at its address.

| Contract | Runtime | Role |
| --- | --- | --- |
| `HookrMarketCoordinatorV5` | 22,865 B | opens both lanes, resolves the protocol share, holds the founding position |
| `HookrNativeMechanicsBlockV2` | 16,889 B | the five rules and the per-quote claim ledger |
| `HookrKernelRouterV3` | 10,178 B | trusted router; the creator buy on every quote currency |
| `HookrNativeMechanicsCoordinatorLibV2` | 3,713 B | admission and founding-fee routing |
| `HookrTreasuryForwarderV1` | 3,272 B | rotatable payout indirection |
| `HookrMarketCoordinatorInitialBuyLibV4` | 2,209 B | validates and executes the creator buy |

The coordinator has 1,711 bytes of headroom. Any addition to it needs a size check.

[Fee model](../concepts/fee-model.md) is the specification these contracts implement and is part of the reading.

## Load-Bearing Dependencies, Out of Scope

Compiled from the same source tree, at an address of their own or linked from an address that already held the same code. Runtime sizes from the same build.

| Contract | Runtime | Where |
| --- | --- | --- |
| `HookrSwapAccountingKernelV3` | 23,965 B | at its own address |
| `HookrStackRegistryV2` | 23,307 B | at its own address |
| `HookrMarketCoordinatorTokenDeployerV3` | 10,541 B | at its own address |
| `HookrModularHookV6` | 8,474 B | at a CREATE2-mined address |
| `HookrModuleCatalogV1` | 6,448 B | at its own address |
| `HookrKernelQuoterV1` | 5,412 B | at its own address |
| `HookrModularCorrectionLibV2` | 3,063 B | linked where it stands |
| `HookrStatefulSettlementLibV1` | 2,715 B | linked where it stands |
| `HookrMarketCoordinatorKernelReservationLibV1` | 483 B | linked where it stands |

`HookrSwapKernelV3` is the base `HookrModularHookV6` extends and has no address of its own. `HookrStackRegistryV1` is the base `HookrStackRegistryV2` extends, in the same way. The `HookrMarketCoordinatorV3` contract compiles because two libraries the V5 coordinator links live in its file; it is not deployed by this release and is out of scope. The accounting kernel is the contract that recomputes every module's split; the native block's exact-input-buy split is computed to satisfy that recomputation byte for byte. It has 611 bytes of headroom, the tightest in the graph, and the registry 1,269.

## Non-Goals

Nothing converts or burns the protocol share. It accrues to a pull-claim ledger and the treasury forwarder pushes it to one address. Uniswap routing allowlisting for the root hook is a separate submission.

## Regression Tests Behind Closed Findings

The test suites cover six findings, each with a named regression test: a fee bypass through an empty module selection, a pot floor that was not decimals-aware, a rate check that ran only at swap time, a recipient and treasury that could decouple, admission of a wrong module version, and a dead equality check in the claim path. One product-level finding is accepted rather than fixed: `openExistingTokenMarket` is permissionless while market opening is not paused and `market.creator` records only who opened the pool.

## Questions for the Auditor

1. Does admission-time proof plus the runtime re-check fully close the rate and recipient bricking risk, or is there a path where a config passes admission and a later read of the recipient or the share diverges, through a proxy-upgradeable quote token or reentrancy across `unlock`?
2. `_decodeAndValidate` is `pure`, so recipient identity is unverifiable there by construction. Does the structural and admission split have a gap across a reorg or a registry upgrade?
3. Is `setNativeBlock`'s owner-gated but mutable design the right trade against a one-shot bind, given the mis-bind guard at the call site?
4. The guard-accounting storage slot is a fixed slot in the coordinator's storage. Does the code-hash pin on the module also need to protect against a re-sealed root profile pointing a different kernel at the same per-pool record?
5. The one-shot module-admission caps are `maxLpFeeSurchargePips = 500,000`, `maxSpecifiedQuoteTakeBps = 4,000`, `maxUnspecifiedQuoteTakeBps = 2,500` and `maxSubjectTakeBps = 1,000`. They can never be raised again for this module. Is that headroom right for every pool configuration this release is expected to open? See [Config schema and limits](../reference/config-schema-and-limits.md).
6. The block's exact-input-buy split is computed to satisfy the accounting kernel's own recomputation exactly: LP donation by weight, pot by weight, royalty on the post-protocol remainder, protocol as the residual. Is the ordering underflow-free for every input, and is the wei-level residue accruing to the protocol acceptable?
7. The burn slice is charged in quote on the gross input rather than revalued against the realised subject output. Is this the right trade against the alternative, which would require a second `afterSwap` quote take the kernel does not permit and would make the take depend on the trade's own slippage?
8. Exact-input sells carry the deferred surcharge rate in transient storage. Can any path read a stale value across two swaps in one transaction, given the kernel's callback-state reentrancy guard and the clear-on-read accessor?

## Reproducing the Build

```sh
git submodule update --init --recursive
forge build --sizes
```

Solidity `v0.8.26+commit.8a97fa7a`, via-IR, optimizer at 200 runs, `evm_version = cancun`, `bytecode_hash = ipfs`. The v4-core and forge-std submodules must be initialized. The test suites live in the source repository at the commit recorded in `SOURCE_MANIFEST.json`.

Every runtime size in the tables above came out of this build, and each matches the byte length of the code at that contract's address on chain 4663. A contract that links libraries is compiled without them: the library addresses are written into the placeholders afterwards, which is how the deployed code carries the metadata of a library-free compilation. [Deployments](../reference/deployments.md) records that comparison address by address.

## Deployment Sequence

Twelve deployments in an enforced order, interleaved with the binds and ending with the sealing of the root profile: catalog, registry, treasury forwarder, admission library, initial-buy library, token-deployer library, coordinator, `setCoordinatorOnce`, accounting kernel, router, quoter, native block, `setNativeBlock`, `setCanonicalStatefulModuleOnce`, `registerModule`, the CREATE2-mined root hook, `registerIntegration` for the router and the quoter, `registerKernel`, `sealRootProfile`. That is the order on chain, and every step's address, transaction and block is in [Deployments](../reference/deployments.md).

`setCoordinatorOnce`, `setCanonicalStatefulModuleOnce` and `sealRootProfile` are each one-shot and have all been spent on this graph. Nothing in it can admit a second coordinator, a second canonical stateful module, or a second root implementation under the sealed profile.
