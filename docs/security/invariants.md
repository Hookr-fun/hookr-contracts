# Invariants

Properties the contracts hold. Each one names where it is enforced, so a reviewer can go straight to the check.

## Admission

**1. One canonical module version.** `MIN_MODULE_VERSION == MAX_MODULE_VERSION == 2` in the admission library. A module at any other version cannot admit through it.

**2. The protocol share is proved at admission, not declared.** `validateOrigin` requires the module's own `validateProtocolShare(config)` to return true before it records a market.

**3. The protocol recipient is pinned to the coordinator's treasury.** `validateOrigin` requires the module's immutable recipient to equal `coordinator.treasuryBeneficiary()`.

**3a. The pinned recipient never moves.** `coordinator.treasury` is constructor-only and the module's recipient is immutable, so neither side can drift from the forwarder address wired in at deploy time. The forwarder carries the mutable surface instead, and rotating its `target` does not touch the address invariant 3 checks.

**4. The same pair is re-checked on every swap and every liquidity add.** `_authorize` reverts `ProtocolShareNotEnforced` when the config's share exceeds the ceiling or names a foreign recipient. It runs from `beforeAddLiquidity`, `beforeSwapStateful` and `afterSwapStateful`.

**5. No pool without a native module.** `_openMarket` reverts `NativeMechanicsModuleRequired` when `validateAndRecordMarket` returns the zero address.

**6. The share is capped structurally and resolved by the coordinator.** The module rejects any share above `MAX_PROTOCOL_SHARE_BPS` in both `_decodeAndValidate` and `validateProtocolShare`. The module never fixes an exact rate; the coordinator's tier resolution does, and the library proves the two agree.

**7. The ERC-20 pot floor is decimals-aware.** `validateProtocolShare` requires `potMinBuyWei >= 10 ** (decimals - 3)` through a gas-bounded `decimals()` read, and rejects a token reporting fewer than 3 or more than `MAX_QUOTE_DECIMALS` decimals. Native quotes use the fixed `MIN_POT_BUY_WEI` structurally.

**8. Every admission read fails closed.** Every bounded-word read in the library is a `staticcall` under `QUERY_GAS` (`TOKEN_QUERY_GAS` for the balance reads in fee routing) that requires a full 32-byte return word; the module-snapshot and treasury-beneficiary reads are ordinary calls that revert on failure. Either way a target that fails does not read as absent. A target that reverts, runs long, or returns short fails admission rather than being treated as absent.

**9. A guard window implies a locked founding position.** `requiresLockedFoundingPosition` is true exactly when `guardEndBlock` is non-zero, and admission reverts `GuardRequiresLockedFoundingPosition` on any origin other than the new-token lane.

## Configuration

**10. The config is byte-exact.** `_decodeAndValidate` requires exactly 640 bytes and requires the payload to re-encode to itself, so no non-canonical encoding or dirty high bits reach the rules.

**11. The frozen config hash is re-derived on every callback.** `_authorize` compares `keccak256(config)` against `stackRegistry.frozenModuleConfigHash(poolId, address(this))` and reverts `NotKernel` on a mismatch. Nothing can substitute a different config for a pool.

**12. Per-pool caps sit inside the catalog registration.** The registry derives each pool's caps from `validateStack` and reverts `ModuleConfigCapsExceedSnapshot` if any exceeds the module's one-shot registration ceiling.

**13. The base fee agrees across both structures.** Admission requires the config's `baseFeePips` to equal `limits.baseLpFeePips`.

## Runtime

**14. Only the pool's own kernel may call the module.** `_authorize` requires `core.kernel == msg.sender == cfg.kernel`, and the runtime subject and quote to match both the stack and the config.

**15. A stateful module never runs as a stateless one.** The module's `beforeSwap` and `afterSwap` revert `StatefulKernelRequired`.

**16. Partial fills are incompatible with input cuts.** Any non-zero input cut on an exact-input buy requires the canonical full-fill square-root price limit before the swap, and requires the pool input to equal the requested amount minus the aggregate take after it. Either check failing reverts `PartialFillUnsupportedWithInputCuts`.

**17. The pot needs the authenticated router path.** `activePotBps` is non-zero only when `trustedCaller` is true. An untrusted caller must send empty `hookData` or the kernel reverts `UntrustedHookData`, and its swap keeps every other rule while omitting the pot leg.

**18. A trusted integration's code cannot change under a pool.** The kernel compares `sender.codehash` against the pool's registered router or quoter code hash and reverts `TrustedIntegrationCodeChanged` on drift. The same pattern protects module implementations and the accounting kernel itself.

**19. The pot counter advances at most once per pool per block.** `_tickJackpot` returns early when `potLastQualifyingBlock[poolId] == block.number`. A single block cannot be filled with qualifying buys to walk the counter to a payout.

**20. The protocol never holds subject tokens.** The burn's protocol slice is taken on the quote leg. Exact-output sells, whose unspecified currency is the subject, carry no protocol take at all.

**21. The base LP fee carries no protocol share.** The LP-fee override is `baseFeePips + (surcharge * (1 - s))`. The base term is never reduced.

## Accounting

**22. Claims are quote-isolated and independently solvent.** `claimable` is keyed `[quote][account]` and `totalClaimLiability` by quote. `accountingInvariant(quote)` requires the module's own ERC-6909 balance to cover that quote's liability. No quote can draw on another's balance.

**23. A claim pays exactly what the pool delivers.** `unlockCallback` returns the measured recipient balance delta and `_claimTo` reverts `ClaimTransferFailed` unless it equals the debited amount. A short-paying quote fails the claim rather than under-paying silently.

**24. ERC-20 movements are balance-checked on both sides.** The coordinator and the admission library compare sender and recipient balances before and after every transfer and revert `TaxedTransfer` on any mismatch.

**25. The trader pays exactly the configured amount.** Every protocol share is carved out of an amount the trader already agreed to. Nothing is added on top of the effective LP fee and the configured cuts.

## Lifecycle

**26. A pool is initialized once, by the coordinator, against a stack that already exists.** `beforeInitialize` requires `sender == coordinator`, an uninitialized stack, and a `PoolKey` matching the frozen record.

**27. Creator identity is the caller.** `openNewTokenMarket` requires `args.expectedCreator == msg.sender`.

**28. `openExistingTokenMarket` grants no privilege.** `creator` records `msg.sender` and `_validateExistingToken` only requires the subject to have code. There is no ownership check, and none is implied.

**29. The founding position cannot be removed.** The coordinator holds it and exposes no removal path.

**30. Owner changes never reach an open pool.** Tier changes, default-share changes and the opening pause all affect only markets opened after the call. There is no per-pool admin function anywhere in the system.

**31. One-shot binds stay burned.** `setCoordinatorOnce` and `setCanonicalStatefulModuleOnce` each succeed once, `sealRootProfile` succeeds once per kernel, and none can be reversed.

**32. Removing liquidity is never hooked.** The permission bits are not set, so no Hookr rule can block or tax a withdrawal.
