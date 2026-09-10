# Integrating as a launcher

## Introduction

A launcher is a contract that opens Hookr markets for its own users. This guide covers what changes when the creator is a contract rather than an EOA, and the two facts that most often surprise integrators.

## Your Contract Is the Creator

`openNewTokenMarket` requires `args.expectedCreator == msg.sender`, and `openExistingTokenMarket` records `msg.sender` as the creator. When your contract calls either one, your contract is the creator of every market it opens.

Three things follow.

**Your tier applies to every market you open.** `protocolShareBps(creator)` resolves on the calling address. A tier granted to your launcher applies to every market it ever opens, for every one of your users, until it is cleared. That is the intended integrator mechanism: one tier, granted once, applied to all your users.

**`lpFeeRecipient` is where the founding fees actually go.** The creator field records your contract; the fee recipient is a separate parameter. Set it to your user's address, or to a splitter you deploy per launch. It is frozen at creation and cannot be changed afterwards.

**`intentId` is scoped to the creator.** `launchedByIntent[creator][intentId]` guards against replay for one creator address. With a contract launcher that is a single namespace shared by all your users, so derive `intentId` from something user-specific.

## Getting a Tier

Tiers are owner-set on the coordinator and unconditional. There is no application flow in the contracts.

```solidity
uint24 mine = coordinator.protocolShareBps(address(myLauncher));
```

The default is 2,000 bps (20%) and the ceiling is 5,000 bps (50%). A tier can be zero. Read your own rate before quoting a fee to a user rather than assuming the default, and read it again in the same transaction you launch in, because the config you submit must match it exactly or admission reverts `ProtocolShareTierMismatch`.

## Predicting the Token Address

Your users will want to know the token address before they sign. Ask the coordinator:

```solidity
address subject = coordinator.previewNewTokenAddress(args, intentId);
```

It is a `view` function of the launch arguments and the `intentId`, so you can show it in a preview and assert it at launch time by passing the same address as `expectedToken`. A mismatch reverts `UnexpectedToken(expected, actual)`.

## Sizing a Creator Buy

The cap is on the subject the creator receives, not on the quote they spend:

```solidity
uint256 cap = coordinator.maxInitialBuySubject();  // 5% of supply
```

To land on it, compute the quote amount from your opening price and the founding band, quote it through the Hookr quoter, and adjust. Then check two other bounds before submitting:

- The buy must fit inside `maxBuyQuoteAmount` for its block, if the guard is on. It shares that budget with nobody else in the launch transaction, but the value is your own choice, so set it high enough.
- The buy must consume its whole input. A price limit that stops it short reverts.

A creator buy that clears the 5% cap but breaks either of these reverts the entire launch, token deployment included.

## Two Things That Surprise People

**Exact-output sells pay the protocol nothing.** The unspecified currency on that swap is the subject token and the protocol never holds subject tokens, so the whole surcharge stays with LPs. If you are modelling revenue, a market traded mostly through exact-output sells earns nothing.

**A base-fee-only pool earns nothing either.** The protocol's share is carved out of the opt-in add-ons. A pool with no surge, no guard, no burn, no LP reward and no pot produces zero protocol revenue, permanently. Tell a partner who expects a cut of every pool before they build on that expectation.

## Fail-Closed Behaviour to Handle

Your interface should surface these rather than retrying blindly.

| Revert | Meaning |
| --- | --- |
| `ProtocolShareTierMismatch(expected, actual)` | Your tier changed between reading it and launching. Re-read and rebuild the config |
| `MarketOpeningPaused(caller)` | Opening is owner-restricted right now |
| `IntentAlreadyUsed(creator, intentId, subject)` | Your intent namespace collided. Derive it per user |
| `TokenSaltAlreadyUsed(create2Salt, subject)` | Same launch arguments were already used. Vary `deploymentSalt` |
| `InvalidMarketArgs` | Usually the opening price is not exactly on a usable tick |
| `InitialBuyAboveCap(subjectOut, cap)` | The creator buy would deliver more than 5% of supply |
| `MaxBuyExceeded(attempted, max)` | The creator buy breaks the guard's per-block cap |
| `NativeMechanicsModuleRequired` | Your selections contain no native mechanics module |
| `TaxedTransfer` | A token moved by a different amount than the coordinator asked for: the new token's supply check after deployment, or a subject transfer. A fee-on-transfer ERC-20 quote fails in the router instead (`InputDebitMismatch`, `SettlementMismatch`) or at claim time (`ClaimTransferFailed`) |

## Checklist Before Mainnet

- Read your own `protocolShareBps` in the same transaction you launch in.
- Set `limits.baseLpFeePips` equal to the config's `baseFeePips`.
- Set `limits.trustedRouter` and `limits.trustedQuoter` to the registered Hookr router and quoter, or the registry rejects the stack (`IntegrationOutsideRootProfile`).
- Put the opening price exactly on a usable tick for your tick spacing.
- Approve the router for an ERC-20 quote if you are doing a creator buy. The coordinator never pulls the quote.
- Set `potMinBuyWei` to at least `10 ** (decimals - 3)` for an ERC-20 quote with a pot.
- Test one buy against a burn-enabled pool on a fork before launching, if the subject is not a token you deployed.

## Next Steps

Read [Config schema and limits](../reference/config-schema-and-limits.md) for every bound the validator enforces.
