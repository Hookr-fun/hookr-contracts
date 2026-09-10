# Native mechanics

`HookrNativeMechanicsBlockV2` holds all five rules in one module. They ship together because splitting them would change the fee rounding that the tests and the audit cover: one hook cut is computed across the LP reward and the pot, the royalty is removed once, and the protocol absorbs the shared rounding residue.

Each rule is switchable per pool by setting its rate to zero. A pool with every rate at zero still carries the module; it just does nothing.

## Surge Fee

The effective LP fee rises with trade size relative to in-range depth, between `baseFeePips` and `maxFeePips`.

```solidity
reserveIn = zeroForOne ? (uint256(liquidity) << 96) / sqrtPriceX96
                       : FullMath.mulDiv(uint256(liquidity), sqrtPriceX96, 1 << 96);
ratio     = min(amountIn * surgeSens * 1e6 / reserveIn, 1e6);
surge     = (maxFeePips - baseFeePips) * ratio / 1e6;
```

`surgeSens` scales how fast the fee climbs and is capped at 10. It must be zero exactly when `maxFeePips == baseFeePips`, which is how the config expresses "surge off".

An exact-output swap has no known input at `beforeSwap`, so it pays the full ceiling `maxFeePips - baseFeePips` rather than a size-scaled value. Price the difference before routing exact-output through a surge pool.

The surge applies to both directions. Sells surge too.

## Guard Window

A launch condition on the new-token lane only. It caps per-block quote spend on buys, adds a snipe tax to the LP fee, blocks exact-output buys, and blocks outside liquidity until `guardEndBlock`. See [Guard window](./guard-window.md).

## Auto Burn

On an exact-input buy, `burnBps` of the subject output is withheld. 80% of that at the deployed share (`1 - s` in general) goes to `0x000000000000000000000000000000000000dEaD` as an `afterSwap` delta. The protocol's 20% (`s`) is taken on the quote leg instead, so the module never holds subject tokens.

The burn runs on exact-input buys only. On an exact-output buy the subject is the specified currency and withholding part of it would break the exact output the trader asked for.

Two things to check before enabling it:

- The subject must permit a transfer to the dead address. A token with a blocklist, a pause, or a transfer hook that rejects it will make every buy revert, and the pool fails closed.
- Burning a tokenized stock destroys a claim on a real share. Burning a stablecoin destroys a dollar. Both are allowed by the contract and both are almost always the wrong choice.

## LP Reward

On an exact-input buy, `lpBps` of the gross quote input is taken. 80% of the remainder after royalty at the deployed share (`1 - s` in general) is donated to in-range liquidity in the same swap, through the PoolManager's donate path, so it lands as fee growth for whoever is in range at that moment.

## Nth-Buy Pot

On an exact-input buy that qualifies, `potBps` of the gross quote input is taken and 80% of the remainder after royalty at the deployed share (`1 - s` in general) is added to the pot. The pot pays out to the buyer whose buy makes the counter divisible by `potEveryNBuys`.

Two conditions gate qualification:

- The buy must be at least `potMinBuyWei`. That floor is 0.001 ETH for a native quote, and at least `10 ** (decimals - 3)` for an ERC-20 quote, checked at admission with a bounded `decimals()` read.
- The counter advances at most once per pool per block. A single block cannot be filled with qualifying buys to walk the counter to a win.

The pot leg needs an authenticated recipient. The module can only trust one carried in `hookData`, and the accounting kernel only decodes `hookData` from the pool's registered trusted router or quoter, at its registered code hash. A swap from any other caller runs with `activePotBps = 0`: it pays no pot cut and cannot win the pot. Every other rule still applies.

Payouts land in `claimable[quote][winner]` and the winner calls `claim(quote)` or `claimTo(quote, to)`.

## Royalty

`royaltyBps` is a share of the LP-reward and pot cuts, not of the swap, and it is computed on what is left after the protocol share. It accrues to `royaltyTo` in the claim ledger. If `royaltyBps` is zero then `royaltyTo` must be the zero address, and if it is non-zero then `royaltyTo` must be set and at least one of `lpBps` or `potBps` must be non-zero.

## Rounding and the Pooled Cut

The LP reward and the pot are one computation. A single cut `B` is taken off the gross quote input at `lpBps + potBps`, the royalty is removed once from it, and the donation and the pot are then split by their post-share weights. Splitting them into two independent streams gives the same totals and different rounding, which is why the module does not.

Every rate slice floors the protocol's rate, so the protocol's realised rate never exceeds the configured share. The residual inside the pooled cut lands on the protocol.

## The Claim Ledger

Every pull payment in the module goes through one pair of mappings:

```solidity
mapping(address quote => mapping(address account => uint256 amount)) public claimable;
mapping(address quote => uint256 amount) public totalClaimLiability;
```

Balances are held as ERC-6909 claims on the PoolManager, one currency id per quote. `accountingInvariant(quote)` returns whether the module's own ERC-6909 balance covers that quote's liability. Every quote currency is backed independently, so an ETH-quoted pool and a USDG-quoted pool can never draw on each other's balance.

A claim measures the recipient's balance before and after `take` and reverts `ClaimTransferFailed` unless the delta equals the debited amount. A fee-on-transfer or otherwise under-delivering quote fails the claim rather than silently paying less.

## Config Validation

`_decodeAndValidate` rejects a config that is not exactly 640 bytes, does not re-encode to itself canonically, or violates any bound. The full rule set is in [Config schema and limits](../reference/config-schema-and-limits.md).
