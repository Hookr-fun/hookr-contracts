# Config schema and limits

One `HookrNativeMechanicsBlockV2.Config` is frozen per pool. This page is the full field list, every bound the validator enforces, and the combinations the contract accepts or rejects.

## The Config Struct

```solidity
struct Config {
    bytes32 poolId;
    address kernel;
    address subject;
    address quote;
    address lockedLiquidityProvider;
    uint40  guardEndBlock;
    uint24  baseFeePips;
    uint24  maxFeePips;
    uint24  snipeTaxPips;
    uint16  surgeSens;
    uint16  burnBps;
    uint16  lpBps;
    uint16  potBps;
    uint16  royaltyBps;
    uint32  potEveryNBuys;
    uint96  maxBuyQuoteAmount;
    uint96  potMinBuyWei;
    address royaltyTo;
    address protocolRecipient;
    uint24  protocolShareBps;
}
```

ABI-encoded it is exactly 640 bytes. The validator rejects any other length, and rejects a payload that does not re-encode to itself byte for byte, so no dirty high bits or non-canonical encoding can reach the rules.

## Fields

| Name | Type | Description |
| --- | --- | --- |
| `poolId` | `bytes32` | The pool this config belongs to. Must match the runtime `PoolId` on every callback |
| `kernel` | `address` | The root hook. Must be the caller on every module callback |
| `subject` | `address` | The token the rules act on |
| `quote` | `address` | What the pool is priced in; `address(0)` is native |
| `lockedLiquidityProvider` | `address` | The only address allowed to add liquidity while the guard window is open. Must be the coordinator |
| `guardEndBlock` | `uint40` | Block at which the guard window closes; zero disables it |
| `baseFeePips` | `uint24` | Base LP fee in pips. Must equal `limits.baseLpFeePips` |
| `maxFeePips` | `uint24` | Ceiling of the surge fee in pips |
| `snipeTaxPips` | `uint24` | Guard-window surcharge on buys, in pips |
| `surgeSens` | `uint16` | How fast the surge climbs with trade size |
| `burnBps` | `uint16` | Share of subject output withheld on an exact-input buy |
| `lpBps` | `uint16` | Share of gross quote input donated to in-range LPs |
| `potBps` | `uint16` | Share of gross quote input added to the pot |
| `royaltyBps` | `uint16` | Share of the LP-reward and pot cuts paid to `royaltyTo` |
| `potEveryNBuys` | `uint32` | How many qualifying buys between pot payouts |
| `maxBuyQuoteAmount` | `uint96` | Per-block quote buy cap while the guard window is open; zero disables the cap |
| `potMinBuyWei` | `uint96` | Smallest buy that advances the pot counter, in quote units |
| `royaltyTo` | `address` | Royalty recipient |
| `protocolRecipient` | `address` | Must equal the module's own immutable recipient |
| `protocolShareBps` | `uint24` | The pool's protocol share |

## Structural Bounds

Enforced by `_decodeAndValidate`, which every entry point calls.

| Rule | Reverts |
| --- | --- |
| `config.length == 640` and re-encodes canonically | `InvalidConfig` |
| `poolId != 0`, `kernel != 0`, `subject != 0` | `InvalidConfig` |
| `subject != quote` | `InvalidConfig` |
| `baseFeePips <= MAX_TOTAL_FEE_PIPS` | `InvalidConfig` |
| `baseFeePips <= maxFeePips <= MAX_TOTAL_FEE_PIPS` | `InvalidConfig` |
| `baseFeePips + snipeTaxPips <= MAX_TOTAL_FEE_PIPS` | `InvalidConfig` |
| `surgeSens <= 10` | `InvalidConfig` |
| `surgeSens == 0` exactly when `maxFeePips == baseFeePips` | `InvalidConfig` |
| `burnBps + lpBps + potBps <= 1_000` | `InvalidConfig` |
| `royaltyBps <= 1_000` | `InvalidConfig` |
| `royaltyBps != 0` requires `royaltyTo != 0` and `lpBps + potBps != 0` | `InvalidConfig` |
| `royaltyBps == 0` requires `royaltyTo == 0` | `InvalidConfig` |
| `guardEndBlock == 0` requires `lockedLiquidityProvider`, `snipeTaxPips` and `maxBuyQuoteAmount` all zero | `InvalidConfig` |
| `guardEndBlock != 0` requires `lockedLiquidityProvider != 0` | `InvalidConfig` |
| `potBps != 0` requires `2 <= potEveryNBuys <= 100_000` | `InvalidConfig` |
| `potBps != 0` requires `potMinBuyWei >= MIN_POT_BUY_WEI` for a native quote, or `potMinBuyWei != 0` for an ERC-20 quote | `InvalidConfig` |
| `potBps == 0` requires `potEveryNBuys == 0` and `potMinBuyWei == 0` | `InvalidConfig` |
| `protocolShareBps <= MAX_PROTOCOL_SHARE_BPS` and `protocolRecipient != 0` | `InvalidConfig` |

## Admission Bounds

Enforced on top of the structural rules when a market is opened. See [Pool lifecycle](../concepts/pool-lifecycle.md).

| Rule | Reverts |
| --- | --- |
| `protocolRecipient` equals the module's own immutable recipient | `validateProtocolShare` returns false, then `InvalidNativeMechanicsModule` |
| The module's immutable recipient equals `coordinator.treasuryBeneficiary()` | `InvalidNativeMechanicsModule` |
| `protocolShareBps` equals `coordinator.protocolShareBps(creator)` | `ProtocolShareTierMismatch(expected, actual)` |
| `baseFeePips` equals `limits.baseLpFeePips` | `InvalidNativeMechanicsModule` |
| A guard window is requested only on the new-token lane | `GuardRequiresLockedFoundingPosition` |
| `block.number < guardEndBlock <= block.number + MAX_GUARD_BLOCKS` | `InvalidNativeMechanicsModule` or `InvalidConfig` |
| For an ERC-20 quote with `potBps != 0`: `3 <= decimals <= MAX_QUOTE_DECIMALS` and `potMinBuyWei >= 10 ** (decimals - 3)` | `validateProtocolShare` returns false, then `InvalidNativeMechanicsModule` |
| `lockedLiquidityProvider` equals the kernel's `coordinator()` when the guard is on | `InvalidConfig` |
| The per-pool caps derived by `validateStack` fit inside the catalog registration | `ModuleConfigCapsExceedSnapshot` |

## Constants

| Constant | Value | Where |
| --- | --- | --- |
| `MAX_TOTAL_FEE_PIPS` | 500,000 (50%) | `HookrNativeMechanicsBlockV2` |
| `MAX_PROTOCOL_SHARE_BPS` | 5,000 (50%) | `HookrNativeMechanicsBlockV2` as `uint16`, mirrored on the coordinator as `uint24` |
| `MIN_POT_BUY_WEI` | 0.001 ether | `HookrNativeMechanicsBlockV2` |
| `MAX_QUOTE_DECIMALS` | 36 | `HookrNativeMechanicsBlockV2` |
| `MAX_GUARD_BLOCKS` | 100,000 | `HookrNativeMechanicsBlockV2` and the admission library |
| `MIN_SQRT_PRICE_LIMIT` | 4295128740 | canonical full-fill limit for `zeroForOne` |
| `MAX_SQRT_PRICE_LIMIT` | 1461446703485210103287273052203988822378723970341 | canonical full-fill limit for one-for-zero |
| `DEAD` | `0x000000000000000000000000000000000000dEaD` | burn destination |
| `SUPPLY` | 1,000,000,000e18 | fixed supply of a new-token market |
| `MAX_INITIAL_BUY_SUBJECT` | `SUPPLY * 500 / 10_000` (5e25) | ceiling on the creator's same-transaction buy |
| `DYNAMIC_FEE_FLAG` | `0x800000` | required `PoolKey.fee` |
| `MAX_MODULE_DATA_LENGTH` | 3,904 | longest module data a swap or a creator buy may carry |
| (inline bound in `HookrMarketCoordinatorV5._validateMarketArgs`) | `type(int16).max` | `tickSpacing` must be positive and no larger; there is no named constant |

## Catalog Registration Ceiling

`registerModule` fixes a structural ceiling for the module across every pool it will ever serve, permanently. There is no updater.

| Field | Value |
| --- | --- |
| `requiredHookFlags` | 10444 (`0x28cc`) |
| `phaseMask` | all phases |
| `executionMode` | `STATEFUL_V1` |
| `maxLpFeeSurchargePips` | 500,000 |
| `maxSpecifiedQuoteTakeBps` | 4,000 |
| `maxUnspecifiedQuoteTakeBps` | 2,500 |
| `maxSubjectTakeBps` | 1,000 |
| `callbackGasLimit` | 2,000,000 |

Every pool's own `validateStack` output must fit inside these. Treat the registration values as part of the reviewed configuration, not as incidental deployment parameters.

`validateStack` derives a pool's two quote-take caps from its surcharge ceiling:

```solidity
(surgeMax, snipeMax) = _surchargeCeiling(cfg);
surchargeSlicePips   = ((surgeMax + snipeMax) * share) / BPS;
specifiedPips        = surchargeSlicePips + ((burnBps * share) / BPS) * 100;
specifiedCap         = lpBps + potBps + ceilDiv(specifiedPips, 100);
unspecifiedCap       = ceilDiv(surchargeSlicePips, 100);
```

Worked against the example pool in [Open a new-token market](../guides/open-a-new-token-market.md), with `baseFeePips = 3000`, `maxFeePips = 10000`, `snipeTaxPips = 250000`, `burnBps = 200`, `lpBps = 50`, `potBps = 50` and `share = 2000`: the surcharge ceiling is 257,000 pips, the slice is 51,400 pips, `specifiedCap` comes out at 654 bps and `unspecifiedCap` at 514 bps. Both fit inside the registration.

The registration is sized against the module's structural maxima rather than any one pool. The specified cap peaks at 3,500 bps, reached with `lpBps + potBps = 1,000`, `baseFeePips = 0`, the full 500,000-pip surcharge ceiling and a 5,000 bps share; the unspecified cap peaks at 2,500 bps under the same ceiling and share. The registered 4,000 and 2,500 cover both, and `maxSubjectTakeBps = 1,000` equals the structural burn ceiling. `registerModule` is one-shot and generation-wide, and there is no updater, so these four numbers are part of the reviewed configuration.

## Combination Matrix, per Lane

| Rule | New-token lane | Existing-asset lane |
| --- | --- | --- |
| Native mechanics module | required | required |
| Base LP fee | required, must equal `limits.baseLpFeePips` | same |
| Surge | allowed | allowed |
| Guard window | allowed, up to 100,000 blocks | rejected, `GuardRequiresLockedFoundingPosition` |
| Auto burn | allowed | allowed |
| LP reward | allowed | allowed |
| Pot | allowed, subject to the floor | allowed, subject to the floor |
| Royalty | allowed, at most 10% of the cuts | same |
| Founding position | created and never removable | none; `lpFeeRecipient` must be zero |
| Creator buy | allowed, at most 5% of supply | rejected |

## Combination Matrix, per Asset

`OK` is allowed and coherent. `WARN` is allowed by the contract and needs a warning in any interface. `BLOCK` is rejected by the contract.

| Subject \ Quote | ETH | HOOKR | USDG | Tokenized stock | Other ERC-20 |
| --- | --- | --- | --- | --- | --- |
| New Hookr token | OK | OK | OK | OK, WARN pause registry | OK |
| Existing ERC-20 | OK, WARN burn if the token is not yours | same | same | same, plus WARN pause registry | same |
| HOOKR | OK, burn deflates HOOKR | BLOCK, subject equals quote | OK | OK, WARN pause registry | OK |
| Tokenized stock | OK, WARN burn destroys shares, WARN pause registry | same | same | OK, both warnings | same |
| USDG or another stablecoin | OK, WARN burn destroys dollars | same | BLOCK, subject equals quote | OK, WARN pause registry | same |

The reasons behind each `WARN` are in [RWA and ERC-20 quotes](../concepts/rwa-and-erc20-quotes.md).
