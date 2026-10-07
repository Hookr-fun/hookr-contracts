// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHookrReferralRegistry} from "./IHookrReferralRegistry.sol";
import {IHookrRegistry} from "./IHookrRegistry.sol";

/// @title IHookrReferralDistributor
/// @notice Interface for HookrReferralDistributor: fully funded, exact fee commissions.
interface IHookrReferralDistributor {
    /// @notice The fee stream a campaign commissions.
    enum FeeSource {
        Protocol,
        CreatorRoyalty
    }

    /// @notice A campaign's immutable terms: the fee stream it commissions, its window, rates, caps and review
    ///         authority.
    struct Terms {
        /// @notice The registered Hookr root the campaign's pool opened on.
        address root;
        /// @notice The pool's Rules, which must be the rules the root has for the pool.
        address rules;
        /// @notice The pool whose fees the campaign commissions.
        bytes32 poolId;
        /// @notice The pool's policy hash on the root, so the campaign names this exact configuration.
        bytes32 configHash;
        /// @notice The pool's quote currency, in which the campaign is funded and pays; address zero for native ETH.
        address currency;
        /// @notice The fee stream the commission is on.
        FeeSource feeSource;
        /// @notice The campaign's first timestamp, a whole UTC day in the future.
        uint64 start;
        /// @notice The campaign's end, a whole number of UTC days after `start` and at most 366.
        uint64 end;
        /// @notice The referrer's commission, in basis points of the payer's eligible fees; not zero.
        uint16 referrerBps;
        /// @notice The payer's cashback, in basis points of its eligible fees; with `referrerBps` below 10,000.
        uint16 cashbackBps;
        /// @notice The cash funded for each day, which no day's commissions and cashbacks exceed.
        uint128 dailyBudget;
        /// @notice The most eligible fees one payer can credit on one day.
        uint128 walletFeeCap;
        /// @notice The account that proposes each day's fee evidence; the distributor's pinned attestor.
        address attestor;
        /// @notice The account that can veto a proposal and approves an exact version; not the attestor.
        address reviewer;
        /// @notice The review window of each proposal, in seconds, between the distributor's minimum and maximum.
        uint64 reviewDelay;
        /// @notice The hash of the published policy for how collected fees are proven; not zero.
        bytes32 sourcePolicyHash;
    }

    /// @notice A campaign's terms with its creator and referral domain.
    struct Campaign {
        /// @notice The terms the creator fixed at creation.
        Terms terms;
        /// @notice The account that created and funded the campaign; unreleased cash returns to it.
        address creator;
        /// @notice The hash of the chain, this contract, the id, the creator and the terms.
        bytes32 termsHash;
        /// @notice The referral domain the campaign's referrals are registered under: a hash of the chain, this
        ///         contract, the id and the terms hash.
        bytes32 programKey;
    }

    /// @notice One day's fee proposal, its review state and its credit totals.
    /// @dev `challenged` is a sticky veto: it survives re-proposals and only reviewer approval of an exact
    ///      version lifts it. `released` means the day is closed and nothing more can be owed.
    struct Epoch {
        /// @notice The root of the day's fee claim tree.
        bytes32 merkleRoot;
        /// @notice The hash of the coverage the proposal claims, bound into every leaf.
        bytes32 coverageHash;
        /// @notice The hash of the fee collections the proposal's evidence covers, bound into every leaf.
        bytes32 collectionsHash;
        /// @notice The sum of every leaf's eligible fees.
        uint256 totalFees;
        /// @notice The eligible fees credited so far.
        uint256 claimedFees;
        /// @notice The commissions and cashbacks credited so far.
        uint256 allocated;
        /// @notice The timestamp from which an unchallenged proposal can be finalized and credits open.
        uint64 finalizeAfter;
        /// @notice The number of proposals made for the day; the reviewer approves one exact version.
        uint64 version;
        /// @notice Whether the reviewer vetoed the day; the veto survives re-proposals until the reviewer approves a
        ///         version.
        bool challenged;
        /// @notice Whether the day's allocation is final.
        bool finalized;
        /// @notice Whether the day is closed and nothing more can be owed.
        bool released;
    }

    /// @notice The campaign does not exist, or its terms or the call's arguments are invalid.
    error InvalidCampaign();
    /// @notice The caller or recipient is not allowed to do this.
    error Unauthorized();
    /// @notice The credit's proof, fees, payer or referral do not match the finalized day.
    error InvalidProof();
    /// @notice The day or proposal is not in the state the call needs.
    error NotReady();
    /// @notice The payer's fees for the day were already credited.
    error AlreadyClaimed();
    /// @notice A transfer moved a different amount than requested, or native value was sent to a token campaign.
    error InexactTransfer();
    /// @notice The amount exceeds the day's budget or the claimable balance.
    error BudgetExceeded();
    /// @notice `root` is not a root in the Hookr registry.
    error UnregisteredRoot(address root);
    /// @notice The proposal window of day `day` of campaign `id` ended at `closedAt`.
    error ProposalWindowClosed(uint256 id, uint256 day, uint256 closedAt);
    /// @notice The reviewer approved a version other than day `day`'s current version `current`.
    error StaleVersion(uint256 id, uint256 day, uint64 current);
    /// @notice Day `day` of campaign `id` has no proposal.
    error NoLiveProposal(uint256 id, uint256 day);
    /// @notice Nothing of day `day` of campaign `id` can be released yet.
    error NothingToRelease(uint256 id, uint256 day);
    /// @notice The pooled balance of `token` is below the `owed` liabilities; only the beneficiary may exit, at the
    ///         pro-rata ratio held/owed.
    error CashShortfall(address token, uint256 owed, uint256 held);
    /// @notice `attestor` is zero or is not the distributor's pinned attestor.
    error InvalidAttestor(address attestor);
    /// @notice `caller` is not the campaign's reviewer.
    error NotReviewer(address caller);
    /// @notice `caller` is not the campaign's creator.
    error NotCreator(address caller);
    /// @notice Day `day` of campaign `id` is already finalized.
    error DayFinalized(uint256 id, uint256 day);
    /// @notice The veto window of day `day` of campaign `id` ended at `closedAt`.
    error VetoClosed(uint256 id, uint256 day, uint256 closedAt);
    /// @notice Credits for day `day` of campaign `id` open at `opensAt`.
    error CreditNotOpen(uint256 id, uint256 day, uint256 opensAt);
    /// @notice Day `day` of campaign `id` can lapse from `opensAt`.
    error LapseNotOpen(uint256 id, uint256 day, uint256 opensAt);
    /// @notice Day `day` of campaign `id` has a pending unchallenged proposal at `version`, which cannot lapse.
    error PendingProposal(uint256 id, uint256 day, uint64 version);

    /// @notice A campaign was created and funded.
    /// @param id The new campaign id.
    /// @param creator The account that created and funded the campaign.
    /// @param programKey The campaign's referral domain.
    /// @param termsHash The hash of the campaign's terms.
    /// @param termsData The ABI-encoded terms.
    event CampaignCreated(
        uint256 indexed id, address indexed creator, bytes32 indexed programKey, bytes32 termsHash, bytes termsData
    );

    /// @notice The attestor proposed a day's fees.
    /// @param id The campaign.
    /// @param day The zero-indexed campaign day.
    /// @param version The proposal's version.
    /// @param root The root of the day's fee claim tree.
    /// @param totalFees The sum of the leaves' eligible fees.
    /// @param coverageHash The coverage the proposal claims, bound into every leaf.
    /// @param collectionsHash The hash of the fee collections the evidence covers.
    /// @param finalizeAfter The timestamp from which the proposal can be finalized and credits open.
    event EpochProposed(
        uint256 indexed id,
        uint256 indexed day,
        uint64 version,
        bytes32 root,
        uint256 totalFees,
        bytes32 coverageHash,
        bytes32 collectionsHash,
        uint64 finalizeAfter
    );
    /// @notice The reviewer vetoed a day's proposal.
    /// @param id The campaign.
    /// @param day The zero-indexed campaign day.
    /// @param reasonHash The hash of the reviewer's published reason.
    event EpochChallenged(uint256 indexed id, uint256 indexed day, bytes32 reasonHash);
    /// @notice The reviewer approved one exact proposal version, which lifts any veto.
    /// @param id The campaign.
    /// @param day The zero-indexed campaign day.
    /// @param version The approved version.
    event DayApproved(uint256 indexed id, uint256 indexed day, uint64 version);
    /// @notice A day's allocation became final.
    /// @param id The campaign.
    /// @param day The zero-indexed campaign day.
    /// @param version The finalized version.
    event EpochFinalized(uint256 indexed id, uint256 indexed day, uint64 version);
    /// @notice A day never proposed, or still vetoed, closed as zero.
    /// @param id The campaign.
    /// @param day The zero-indexed campaign day.
    /// @param version The last proposed version, or zero.
    event DayLapsed(uint256 indexed id, uint256 indexed day, uint64 version);

    /// @notice A payer's fees were credited: the referrer's commission and the payer's cashback.
    /// @param id The campaign.
    /// @param day The zero-indexed campaign day.
    /// @param payer The referred account whose fees the leaf proves, and who earns the cashback.
    /// @param referrer The account credited the commission.
    /// @param eligibleFees The fees the leaf proves.
    /// @param commission The commission credited, after the stacking cap.
    /// @param cashback The cashback credited, after the stacking cap.
    event CommissionCredited(
        uint256 indexed id,
        uint256 indexed day,
        address indexed payer,
        address referrer,
        uint128 eligibleFees,
        uint256 commission,
        uint256 cashback
    );

    /// @notice A credit was cut to the payer's remaining shared capacity; `paid` of `nominal` was credited.
    /// @param id The campaign.
    /// @param day The zero-indexed campaign day.
    /// @param payer The payer whose shared capacity cut the credit.
    /// @param nominal The credit before the cut.
    /// @param paid The credit after the cut.
    event StackingCapApplied(
        uint256 indexed id, uint256 indexed day, address indexed payer, uint256 nominal, uint256 paid
    );
    /// @notice A beneficiary withdrew credited cash.
    /// @param currency The currency claimed.
    /// @param beneficiary The account whose credit was claimed.
    /// @param to The recipient.
    /// @param amount The credit claimed, before any shortfall cut.
    event Claimed(address indexed currency, address indexed beneficiary, address indexed to, uint256 amount);
    /// @notice A finalized day returned the cash that can never be owed to its creator, or to the address it named.
    /// @param id The campaign.
    /// @param day The zero-indexed campaign day.
    /// @param to The recipient.
    /// @param amount The cash returned.
    /// @param closed Whether the day closed with this release.
    event RemainderReleased(uint256 indexed id, uint256 indexed day, address indexed to, uint256 amount, bool closed);
    /// @notice A claim was cut to the pro-rata recovery ratio because the pooled balance of `token` is below what is
    ///         owed.
    /// @param token The currency.
    /// @param to The recipient.
    /// @param owed The amount the recipient was owed.
    /// @param paid The amount paid.
    event ShortfallShared(address indexed token, address indexed to, uint256 owed, uint256 paid);

    /// @notice Returns the referral registry that proves a payer was referred.
    /// @return The referral registry.
    function referrals() external view returns (IHookrReferralRegistry);

    /// @notice Hookr registry; campaigns may only name a registered root.
    /// @return The Hookr registry.
    function registry() external view returns (IHookrRegistry);

    /// @notice The only attestor a campaign may name: the operator whose ledger reserves each fee lot once
    ///         across every campaign, so no second attestor can make up fees to use a payer's shared capacity.
    ///         Fixed at deployment; it gains no power over funds, since each campaign's own reviewer can veto
    ///         any proposal and an unresolved day lapses back to its creator.
    /// @return The pinned attestor every campaign names.
    function attestor() external view returns (address);

    /// @notice Returns the number of campaigns created; the next takes the id after it.
    /// @return The campaign count, which is also the newest campaign id.
    function campaignCount() external view returns (uint256);

    /// @notice Returns whether a payer's fees were credited on a day.
    /// @param id The campaign.
    /// @param day The zero-indexed campaign day.
    /// @param payer The referred account.
    /// @return True once the payer's leaf was credited.
    function credited(uint256 id, uint256 day, address payer) external view returns (bool);

    /// @notice Returns the credited cash a beneficiary can claim in a currency.
    /// @param currency The currency.
    /// @param beneficiary The account credited.
    /// @return The credited cash not yet claimed.
    function claimable(address currency, address beneficiary) external view returns (uint256);

    /// @notice Funded daily budgets plus credited unpaid commissions, grouped by currency.
    /// @param currency The currency.
    /// @return The cash of `currency` the campaigns owe.
    function reservedCash(address currency) external view returns (uint256);

    /// @notice Cash already returned to the creator for a campaign day.
    /// @param id The campaign.
    /// @param day The zero-indexed campaign day.
    /// @return The cash returned to the creator for the day.
    function refunded(uint256 id, uint256 day) external view returns (uint256);

    /// @notice Create immutable fee commission terms and fund every daily budget in full.
    /// @dev The root must be registered in the Hookr registry (retired roots included) so a campaign cannot
    ///      borrow a real PoolId behind an imitation root, and the attestor must be the pinned `attestor`.
    /// @param t The campaign's terms.
    /// @return id The new campaign's id.
    function createCampaign(Terms calldata t) external payable returns (uint256 id);

    /// @notice Commit collected-fee evidence for a completed day, within its proposal window, and start a fresh
    ///         review delay.
    /// @dev Replacing a pending proposal restarts its delay. A veto is sticky: a re-proposal stays challenged, so
    ///      it can only finalize through reviewer approval of that exact version.
    /// @param id The campaign.
    /// @param day The zero-indexed campaign day, which must have ended.
    /// @param root The root of the day's fee claim tree.
    /// @param totalFees The sum of the leaves' eligible fees, whose commission the daily budget must cover.
    /// @param coverageHash The coverage the proposal claims, bound into every leaf.
    /// @param collectionsHash The hash of the fee collections the evidence covers, bound into every leaf.
    function proposeDay(
        uint256 id,
        uint256 day,
        bytes32 root,
        uint256 totalFees,
        bytes32 coverageHash,
        bytes32 collectionsHash
    ) external;

    /// @notice Veto the day. The veto survives re-proposals; only reviewer approval of an exact version lifts it.
    /// @dev Open until finalizeAfter + VETO_GRACE unless someone finalized first, so a veto sent inside the review
    ///      window but held back for one forced-inclusion delay still lands, while a mature day cannot be voided
    ///      later.
    /// @param id The campaign.
    /// @param day The zero-indexed campaign day.
    /// @param reasonHash The hash of the reviewer's published reason.
    function challengeDay(uint256 id, uint256 day, bytes32 reasonHash) external;

    /// @notice Reviewer approval of one exact proposal version: lifts any veto and finalizes it at once.
    /// @dev Bound to the version so a replacement proposal can never ride on an approval meant for another.
    ///      Credits still open only at that version's finalizeAfter, so an early approval never decides who
    ///      reaches a payer's shared capacity first; never-owed cash can be released at once.
    /// @param id The campaign.
    /// @param day The zero-indexed campaign day.
    /// @param version The proposal version the reviewer approves; a newer proposal makes it stale.
    function approveDay(uint256 id, uint256 day, uint64 version) external;

    /// @notice Finalize an unchallenged proposal after its review delay.
    /// @param id The campaign.
    /// @param day The zero-indexed campaign day.
    function finalizeDay(uint256 id, uint256 day) external;

    /// @notice Close as zero a day never proposed, or still vetoed, once its proposal window and the latest
    ///         proposal's review window have both ended; its whole budget then returns through releaseRemainder.
    /// @dev A pending unchallenged proposal cannot lapse; it becomes finalizable within reviewDelay. Waiting for
    ///      the latest finalizeAfter gives the reviewer a full review window to approve a late correction.
    /// @param id The campaign.
    /// @param day The zero-indexed campaign day.
    function lapseDay(uint256 id, uint256 day) external;

    /// @notice Credit funded commission and cashback for a proven, prospectively referred payer, once the
    ///         finalized version's review window has ended.
    /// @dev Combined payouts on one payer's fees for one pool, fee source and UTC day are capped at
    ///      MAX_STACKED_BPS of the largest fee amount credited for them, across every campaign here, and at
    ///      MAX_KING_OF_THE_POOL_STACKED_BPS (half) on the Protocol fee of a pool whose Rules answer recaptureMode
    ///      with King of the Pool, read at credit. Capacity is used only by cash actually credited; a credit above
    ///      the remaining capacity pays only that capacity, split in its campaign's referrer:cashback proportion,
    ///      and its unpaid share returns to its creator.
    /// @param id The campaign.
    /// @param day The zero-indexed campaign day.
    /// @param payer The referred account whose fees the leaf proves, and who earns the cashback.
    /// @param referrer The account credited the commission.
    /// @param firstActivityBlock The block of the payer's first activity, which the referral registry checks against
    ///         its authorization.
    /// @param eligibleFees The fees the leaf proves, at most the campaign's wallet cap.
    /// @param proof The Merkle proof of the leaf under the day's root.
    function creditDay(
        uint256 id,
        uint256 day,
        address payer,
        address referrer,
        uint64 firstActivityBlock,
        uint128 eligibleFees,
        bytes32[] calldata proof
    ) external;

    /// @notice Hash a fee claim with the latest proposal's coverage and collection hashes.
    /// @dev Reverts until the day has been proposed; before proposing, use feeLeafFor with the exact hashes
    ///      you will propose.
    /// @param id The campaign.
    /// @param day The zero-indexed campaign day.
    /// @param payer The referred account whose fees the leaf proves.
    /// @param referrer The account credited the commission.
    /// @param firstActivityBlock The block of the payer's first activity.
    /// @param eligibleFees The fees the leaf proves.
    /// @return The leaf the day's fee claim tree holds for the claim.
    function feeLeaf(
        uint256 id,
        uint256 day,
        address payer,
        address referrer,
        uint64 firstActivityBlock,
        uint128 eligibleFees
    ) external view returns (bytes32);

    /// @notice Hash a fee claim with explicit coverage and collection hashes, for building a root to propose.
    /// @param id The campaign.
    /// @param day The zero-indexed campaign day.
    /// @param coverageHash The coverage hash to bind into the leaf.
    /// @param collectionsHash The collections hash to bind into the leaf.
    /// @param payer The referred account whose fees the leaf proves.
    /// @param referrer The account credited the commission.
    /// @param firstActivityBlock The block of the payer's first activity.
    /// @param eligibleFees The fees the leaf proves.
    /// @return The leaf the day's fee claim tree would hold for the claim.
    function feeLeafFor(
        uint256 id,
        uint256 day,
        bytes32 coverageHash,
        bytes32 collectionsHash,
        address payer,
        address referrer,
        uint64 firstActivityBlock,
        uint128 eligibleFees
    ) external view returns (bytes32);

    /// @notice Pay credited cash; only the beneficiary may redirect it. Zero amount claims all.
    /// @dev If an issuer action left the currency's balance below its liabilities, a claim sent by the
    ///      beneficiary settles pro rata (held / owed) and emits ShortfallShared; a claim sent by anyone else
    ///      reverts CashShortfall so no third party can force a haircut. The redirect is the beneficiary's own
    ///      right: the contract keeps no sanctions list, so an issuer blocking the beneficiary does not block it.
    /// @param currency The currency to claim.
    /// @param beneficiary The account whose credit is claimed.
    /// @param to The recipient; not the beneficiary only when the beneficiary calls.
    /// @param amount The cash to claim, or zero for all of it.
    function claim(address currency, address beneficiary, address to, uint256 amount) external;

    /// @notice Return a finalized day's cash that can never be owed. Anyone may pay it to the creator; only the
    ///         creator may redirect it.
    /// @dev Releases dailyBudget - allocated - maxOwable, where maxOwable bounds the commission and cashback every
    ///      uncredited fee could still earn, so one uncreditable leaf holds back only its own maximum. Callable
    ///      again as credits land; the day closes once nothing more can be owed. A lapsed day returns in full.
    /// @param id The campaign.
    /// @param day The zero-indexed campaign day, which must be finalized and not closed.
    /// @param to The recipient; not the creator only when the creator calls.
    /// @return amount The cash returned.
    function releaseRemainder(uint256 id, uint256 day, address to) external returns (uint256 amount);

    /// @notice Return the largest fee amount credited and the combined commission plus cashback already credited
    ///         on a payer's fees for a pool, fee source and UTC day (day number = timestamp / 1 days), across
    ///         every campaign in this distributor. Remaining capacity is feeBasis * MAX_STACKED_BPS / 1e4 - paid,
    ///         or feeBasis * MAX_KING_OF_THE_POOL_STACKED_BPS / 1e4 - paid on the Protocol fee of a pool whose King
    ///         of the Pool is on.
    /// @param poolId The pool.
    /// @param feeSource The fee stream.
    /// @param utcDay The UTC day number, the timestamp divided by one day.
    /// @param payer The payer.
    /// @return feeBasis The largest fee amount any campaign credited for the payer, pool, fee source and day.
    /// @return paid The combined commission and cashback already credited on them.
    function stackedRebate(bytes32 poolId, FeeSource feeSource, uint256 utcDay, address payer)
        external
        view
        returns (uint256 feeBasis, uint256 paid);

    /// @notice Return the exclusive end of a valid zero-indexed UTC day.
    /// @param id The campaign.
    /// @param day The zero-indexed campaign day.
    /// @return The timestamp at which the day ends.
    function dayEnd(uint256 id, uint256 day) external view returns (uint64);

    /// @notice Return immutable fee commission terms and their referral domain.
    /// @param id The campaign.
    /// @return The campaign's terms, creator and referral domain.
    function campaign(uint256 id) external view returns (Campaign memory);

    /// @notice Return the collected-fee proposal and allocation state for a day.
    /// @param id The campaign.
    /// @param day The zero-indexed campaign day.
    /// @return The day's proposal, review state and credit totals.
    function epoch(uint256 id, uint256 day) external view returns (Epoch memory);
}
