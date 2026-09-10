# HOOKR Utility Terms V2

Applicability: **ONLY THE EXACT HASH-BOUND V2 RELEASE**

These terms define `HookrLockRewardsV2` and `HookrLaunchBoostV2`. They authorize neither deployment
nor wallet activity by themselves. They govern a release only if the exact UTF-8 bytes of this file
are hash-bound in a production-enabled utility release manifest that also contains finalized
deployment and canary receipts, runtime identities, immutable bootstrap timing, fixed-block linkage
and final readback evidence. Without that complete manifest, the Hookr interface must keep V2
utility reads and writes closed. A separately identified V1 recovery surface is not a V2 release and
must never expose a new V1 Lock, Boost, extension or approval flow.

## 1. Lock Rewards

- Any wallet may create a non-transferable HOOKR position for 30, 90 or 180 days only after the exact
  V2 release gate opens.
- Lock deposits are fee-free: they carry no protocol entry fee. Recorded principal is never slashed
  and becomes fully withdrawable after the position unlocks. There is no early exit.
- Effective reward weight is principal multiplied by 1.00x, 1.15x or 1.25x for the respective
  30-, 90- or 180-day term.
- A position always activates in the epoch after it is created. It can receive fees only while
  eligible and can claim only after a complete epoch has settled.
- Rewards consist solely of realized Launch Boost fees attributed by the contract. Boost activity,
  fees and claims may be zero. There is no APY, promised yield or guaranteed return.

## 2. Immutable bootstrap and weekly epochs

- Deployment fixes four public timestamps: bootstrap start, fee epoch start, claim epoch start and
  weekly epoch start. No owner or interface can change them.
- Epoch 0 begins at deployment and lasts exactly two hours. Locks created in epoch 0 activate in
  epoch 1. Launch Boost hard-reverts throughout epoch 0, before any token pull, fee routing,
  principal recording or active-registry use.
- Epoch 1 begins exactly two hours after epoch 0 and lasts exactly two hours. Launch Boost is then
  available. An eligible epoch-1 cohort receives the conditional fee described below.
- Epoch 2 begins when epoch 1 ends and bridges to the first Monday 00:00 UTC strictly after that
  boundary. Thereafter, epochs are consecutive Monday-to-Monday weeks.
- Bootstrap timing shortens only the initial release proof. The principal terms, proportional
  reward index, completed-epoch settlement and all later weekly accounting remain unchanged.

## 3. Launch Boost and paid placement

- Only the creator recorded for a token by the supported Hookr launchpad may fund that launch's
  Boost position.
- Each Boost deposit must be at least 100 HOOKR gross. This fixed onchain minimum limits negligible
  consumption of the bounded active registry; it is not a recommendation or a statement of
  economic value.
- An active Boost appears only in a clearly labelled paid, capital-weighted Boosted rail. Its score
  is net refundable principal multiplied by the same 1.00x, 1.15x or 1.25x term weight.
- Boost does not change organic Discover order. Payment or position size is not vetting,
  endorsement, identity verification, contract review, quality assurance or a safety signal.
- Availability and placement are best-effort. The contract permits at most 512 positions in its
  active Boost enumeration. If that enumeration is full, a new position reverts before any HOOKR
  token pull, while a still-registered active position may be topped up. Anyone may permissionlessly
  prune an expired position from enumeration to free capacity; pruning does not change its creator,
  principal, liability, tier, timestamps or withdrawal rights.
- If an already-eligible Lock Rewards cohort exists, the contract ceiling-rounds 1% of the gross
  Boost deposit and forwards that fee to the cohort's current epoch ledger. The remaining net
  principal becomes the creator's refundable position. After Boost opens, if no eligible cohort
  exists, the fee is waived rather than held for future lockers and the gross deposit becomes
  refundable principal.
- Adding principal or choosing a longer tier can recommit the position under the contract's term
  rules. Deposit fee/principal bounds and lock or extension timestamp bounds make reviewed execution
  limits part of calldata. A tier cannot be reduced while a position is active. Principal cannot be
  withdrawn before unlock, and an expired position must be withdrawn before a new one is opened.

## 4. Superseded V1 recovery

The V1 contracts were deployed and a single one-HOOKR V1 lock was created during release canary work,
but V1 was superseded before a production-enabled utility manifest was installed. V1 is not an open
utility release. Hookr may publish the exact receipt-backed V1 Lock Rewards identity solely so the
recorded owner can read that position, permissionlessly checkpoint its ledger, claim any actually
settled reward and withdraw matured principal. The interface must not offer new V1 locks, permits,
approvals, Boosts, extensions or paid placement. A recovery action still requires live runtime and
position verification, wallet confirmation, a successful receipt and an expected state readback.

## 5. Contract control and custody boundary

Hookr's interface and operator do not hold wallet keys or submit transactions on a user's behalf.
Every approval, lock, boost, claim, checkpoint and withdrawal requires the connected wallet to
review and sign the exact request. A submitted transaction is not confirmed until a successful
receipt and the expected onchain postcondition are independently read back.

Locking transfers HOOKR from the wallet to a smart contract and removes the wallet's ability to use
that principal until the withdrawal condition is satisfied. The V2 contracts have no ongoing owner,
slashing, pause, upgrade or sweep path after the reward source is wired once during deployment.
These constraints do not eliminate contract defects, token behavior, chain failure, reorganization,
transaction-ordering, wallet, RPC, market or other technical risks.

## 6. User responsibility and professional advice

Users are responsible for verifying the token, launchpad, utility contract addresses, amount, term,
bootstrap timing, conditional fee, score and wallet calldata before signing. HOOKR and any launched
token may lose all market value. A locked or boosted position is not insurance and does not make a
launch safe.

Paid placement, lockup, fee receipt, claims and withdrawals may have advertising, consumer-
protection, securities, commodities, sanctions, reporting or tax consequences depending on the
user and jurisdiction. Users are responsible for maintaining records and determining their legal
and tax obligations. Consult independent legal and tax counsel before participating. Hookr does
not provide financial, legal or tax advice.

## 7. Public records and privacy

Any executed utility transaction makes wallet addresses, principal, terms, weights, activation and
expiry epochs, boosted launches, scores, routed fees, claims, withdrawals and transaction timing
public blockchain records. They may be copied and associated with other public activity.
Disconnecting a wallet or deleting offchain profile data cannot erase them. Hookr must not attach raw
wallet addresses, balances, position amounts, calldata or signatures to product analytics.

## 8. Release acknowledgement

The production interface must present the material amount, term, bootstrap state, fee and placement
disclosures before requesting a signature. A release must hash this document and publish that hash
in the utility manifest. Any material change requires a new terms version and a new reviewed release;
a UI copy change cannot alter deployed contract behavior.
