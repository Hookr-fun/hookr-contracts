# Threat model

Who can do what, what they cannot do, and where the system relies on something outside itself.

## Trust Assumptions

**The Uniswap v4 PoolManager.** Every settlement, every claim, and every fee-growth accrual goes through it. Hookr assumes it behaves as deployed.

**The quote token.** A Hookr pool prices in whatever the creator picks. A quote that is fee-on-transfer, rebasing, pausable, or upgradeable brings those properties into every pool that uses it. The coordinator and the admission library reject fee-on-transfer and rebasing behaviour with balance checks, but they cannot reject a token that acquires the behaviour later through an upgrade.

**The subject token.** Same, plus the burn rule depends on the token permitting a transfer to `0x…dEaD`.

**The Hookr owner.** Trusted to set tiers and the default share sensibly, and to keep the treasury forwarder's target under control. Not trusted with any open pool; see [Immutability and ownership](../concepts/immutability-and-ownership.md) for the exhaustive list of what the owner can reach.

**The deployer's release sequence.** The one-shot binds must run in the right order against the right addresses. A wrong bind is unrecoverable within this release.

## Actors

### A trader

Can trade any Hookr pool through any v4 caller. Cannot exceed the guard's per-block cap, cannot execute an exact-output buy during the guard, cannot claim someone else's balance, and cannot win the pot without routing through the pool's registered router or quoter.

Can win the pot by timing a qualifying buy. The counter advances at most once per pool per block and the payout interval is fixed at creation, so the attack is to watch the counter and buy at `n − 1`. That is not prevented and does not need to be: the pot is funded by the buys that fill it, and a sniper who wins it paid the same cut everyone else did.

### A pool creator

Chooses every rule, every rate and every recipient, once. Cannot change any of them afterwards, cannot remove the founding position, and cannot take a share of the base LP fee beyond what an LP would earn.

On the new-token lane the creator holds the only liquidity during the guard window, so they receive the LP part of every guard-window fee including the snipe tax. A creator who buys their own launch through the guard therefore recovers `1 − s` of the tax they paid. This is a known and accepted property; the 5% dev-buy cap is what bounds it. See [Known limitations](./known-limitations.md).

On the existing-asset lane anyone can open a pool for anyone's token while market opening is not paused (the owner can pause it; the deployed coordinator is unpaused). `market.creator` records who opened it, nothing more.

### A launcher contract

Opens markets for its users and carries its own tier to all of them. It chooses `lpFeeRecipient` per launch, so it can route founding fees to a user, to itself, or to a splitter. Its users should be shown who receives them.

### The Hookr owner

Sets the default share and per-creator tiers within a ceiling with no setter, pauses market opening, registers and retires modules, integrations and kernels for future stacks, seals a root profile once, and rotates the treasury forwarder's payout target.

Cannot reach a pool that is already open by any path.

### The treasury forwarder's owner

Rotates where collected protocol shares land, and points the forwarder at a module that already names it. Cannot claim anything an account other than the forwarder is owed, cannot set the target to the forwarder, the module, or a PoolManager, and cannot affect admission.

## Attacks the Design Addresses

**Launch sniping.** The guard window caps per-block quote spend on buys, taxes them, blocks exact-output buys, and blocks outside liquidity. All four are bounded and all four expire at a block fixed at creation.

**Crediting a router instead of a wallet.** The pot needs a recipient. If the hook trusted any caller's `hookData`, a router could name itself and the pot would be unwinnable. The kernel decodes `hookData` only from the pool's registered router or quoter at its registered code hash, and requires empty `hookData` from everyone else.

**Swapping a trusted integration's code.** Every trusted address is pinned by runtime code hash. A `SELFDESTRUCT`-and-redeploy or a proxy upgrade at a registered address makes the pool revert `TrustedIntegrationCodeChanged` rather than trusting new code.

**Substituting a module config.** The frozen config hash is re-derived on every callback from the registry's own record.

**Bricking a pool by moving the treasury.** The coordinator's treasury and the module's recipient are both fixed at construction, and admission requires them to be equal. The mutable surface is the forwarder's target, which no pool reads.

**Stranding an accrual by a bad payout target.** `collect` claims out of the module before forwarding, so a target that refuses the payment leaves the funds on the forwarder rather than trapped in the module. `ForwardDeferred` says so and `sweep` delivers them after a rotation.

**Front-running a treasury rotation.** `setTargetAndCollect` rotates and drains atomically, so a compromised outgoing target gets no block boundary in which to be paid. Send it through a private relay when that matters.

**A partial fill after an input cut.** A cut taken off the input before the swap would otherwise let a price limit strand the trader's cut on quote that never reached the pool. Both a pre-swap price-limit check and a post-swap amount check reject it.

**Under-delivering quote on a claim.** The claim path measures the recipient's balance delta and reverts unless it equals the debit.

## Attacks the Design Does Not Address

**A malicious subject or quote token.** A pool inherits whatever its tokens do. A token that pauses, blocklists, or admin-burns can halt or distort a pool, and Hookr fails closed rather than trying to route around it.

**Ordinary MEV.** Sandwiching, backrunning and priority ordering behave as on any v4 pool. The surge fee raises the cost of large sandwiches but is not an anti-MEV mechanism.

**A creator choosing bad parameters.** Every value inside the caps is permitted. A 50% total fee, a 10% cut, a 100,000-block guard window and a burn on a stock token are all legal. The interface's warnings are the mitigation, and they are advisory.

**Value at the payout target.** Once `collect` or `sweep` delivers to `target`, the funds are wherever the owner pointed them.

**Governance capture of the owner keys.** There is no timelock and no multisig requirement in the contracts. The bound on the damage is that no owner function reaches an open pool.

## Failure Modes and Their Direction

Every one of these fails closed, meaning the transaction reverts rather than settling on a guess.

| Condition | Result |
| --- | --- |
| A subject or quote token is paused or blocks a party | Swaps revert |
| A burn destination transfer is rejected | Every exact-input buy on that pool reverts |
| A trusted router or quoter's code changes | Swaps through it revert |
| A module implementation's code changes | Every callback reverts |
| An admission read reverts or returns short | Market opening reverts |
| A claim's measured delta is short | The claim reverts and the balance stays owed |
| A quote token is fee-on-transfer | A creator buy, fee routing and swaps revert; a market that moves no quote at opening admits and fails on first use |
| A pool's aggregate takes exceed its frozen caps | The swap reverts |

There is no path that settles a swap at a fee the hook could not compute, and no path that pays a claim from another quote's balance.
