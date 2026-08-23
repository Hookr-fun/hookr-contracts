# HOOKR Utility Terms V1

Applicability: **ONLY THE EXACT HASH-BOUND V1 RELEASE**

These terms define `HookrLockRewardsV1` and `HookrLaunchBoostV1`. They authorize neither deployment
nor wallet activity by themselves. They govern a release only if the exact
UTF-8 bytes of this file are hash-bound in a production-enabled utility release manifest that also
contains finalized deployment and canary receipts, runtime identities and fixed-block linkage
evidence. Without that complete manifest, the Hookr interface must keep utility reads and writes
closed; with it, the manifest identifies the exact contracts and terms to which this document applies.

## 1. Lock Rewards

- Any wallet may create a non-transferable HOOKR position for 30, 90 or 180 days.
- Lock deposits are fee-free: they carry no protocol entry fee. Recorded principal is never slashed and becomes fully
  withdrawable after the position unlocks. There is no early exit.
- Effective reward weight is principal multiplied by 1.00x, 1.15x or 1.25x for the respective
  30-, 90- or 180-day term.
- A position activates at the next Monday 00:00 UTC epoch boundary. It can receive fees only while
  eligible and can claim only after a complete weekly epoch has settled.
- Rewards consist solely of realized Launch Boost fees attributed by the contract. Boost activity,
  fees and claims may be zero. There is no APY, promised yield or guaranteed return.

## 2. Launch Boost and paid placement

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
  token pull, while a still-registered active position may be topped up. Anyone may permissionlessly prune an expired position from enumeration to free capacity; pruning does not change its creator, principal or liability, tier, timestamps, or the creator's withdrawal rights. The creator can
  withdraw after pruning, and can open a later position only after withdrawal and while capacity is
  available.
- If an already-eligible Lock Rewards cohort exists, the contract ceiling-rounds 1% of the gross
  Boost deposit and forwards that fee to the cohort's current weekly ledger. The remaining net
  principal becomes the creator's refundable position. If no eligible cohort exists, the fee is
  waived rather than held for future lockers, and the gross deposit becomes refundable principal.
- The standard planned 50/50 season utility split does not apply to Lock Rewards principal, Launch
  Boost principal or the conditional Boost fee.
- Adding principal or choosing a longer tier can recommit the position under the contract's term
  rules. Deposit fee/principal bounds and lock or extension timestamp bounds make reviewed execution
  limits part of calldata. A tier cannot be reduced while a position is active. Principal cannot be
  withdrawn before unlock, and an expired position must be withdrawn before a new one is opened.

## 3. Contract control and custody boundary

Hookr's interface and operator do not hold wallet keys or submit transactions on a user's behalf.
Every approval, lock, boost, claim and withdrawal requires the connected wallet to review and sign
the exact request. A submitted transaction is not confirmed until a successful receipt and the
expected onchain postcondition are independently read back.

Locking transfers HOOKR from the wallet to a smart contract and removes the wallet's ability to use
that principal until the withdrawal condition is satisfied. The V1 contracts have no
ongoing owner, slashing, pause, upgrade or sweep path after the reward source is wired once during
deployment. These constraints do not eliminate contract defects, token behavior, chain failure,
reorganization, transaction-ordering, wallet, RPC, market or other technical risks.

## 4. User responsibility and professional advice

Users are responsible for verifying the token, launchpad, utility contract addresses, amount,
term, conditional fee, score and wallet calldata before signing. HOOKR and any launched token may
lose all market value. A locked or boosted position is not insurance and does not make a launch
safe.

Paid placement, lockup, fee receipt, claims and withdrawals may have advertising, consumer-
protection, securities, commodities, sanctions, reporting or tax consequences depending on the
user and jurisdiction. Users are responsible for maintaining records and determining their legal
and tax obligations. Consult independent legal and tax counsel before participating. Hookr does
not provide financial, legal or tax advice.

## 5. Public records and privacy

Any executed V1 transaction makes wallet addresses, principal, terms, weights, activation and expiry epochs, boosted
launches, scores, routed fees, claims, withdrawals and transaction timing public blockchain
records. They may be copied and associated with other public activity. Disconnecting a wallet or
deleting offchain profile data cannot erase them. Hookr must not attach raw wallet addresses,
balances, position amounts, calldata or signatures to product analytics.

## 6. Release acknowledgement

The production interface must present the material amount, term, fee and placement disclosures
before requesting a signature. A release must hash this document and publish that hash in the
utility manifest. Any material change requires a new terms version and a new reviewed release; a UI
copy change cannot alter deployed contract behavior.
