// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHookrMilestoneNFT} from "./IHookrMilestoneNFT.sol";
import {IHookrReferralRegistry} from "./IHookrReferralRegistry.sol";
import {IHookrMilestoneNFTFactory} from "./IHookrMilestoneNFTFactory.sol";
import {IHookrProgramValidator} from "./IHookrProgramValidator.sol";
import {HookrProgramTypes} from "../types/HookrProgramTypes.sol";

/// @title IHookrPrograms
/// @notice Interface for HookrPrograms: creator programs and separately approved, capped Hookr Bux.
interface IHookrPrograms {
    /// @notice A program's immutable terms, creator and collection with its running issuance, cash and day accounting.
    /// @dev Cash ledger: cashPaid <= cashAllocated and cashAllocated + cashRefunded <= terms.cashBudget.
    ///      buxReleased is set once every day has closed, when the whole unused Bux allowance has returned.
    ///      immediateCashReleased is always false: Immediate programs hold no cash. It keeps the ABI stable.
    struct Program {
        /// @notice The terms the creator fixed at creation.
        HookrProgramTypes.Terms terms;
        /// @notice The account that created and funded the program; refunds go to it unless it names a recipient.
        address creator;
        /// @notice The hash of the chain, this contract, the id, the creator and every term, scope, milestone and
        ///         metadata record.
        bytes32 termsHash;
        /// @notice The milestone NFT collection deployed for the program, or zero when it has no milestones.
        IHookrMilestoneNFT collection;
        /// @notice The points credited to participants so far, never above the terms' point budget.
        uint256 pointsIssued;
        /// @notice The cash credited to participants so far, claimable through `claimCash`.
        uint256 cashAllocated;
        /// @notice The cash paid out to claimants so far.
        uint256 cashPaid;
        /// @notice The cash returned to the creator's refund recipient so far.
        uint256 cashRefunded;
        /// @notice The last milestone NFT token id reserved; the next reservation takes the one after it.
        uint256 nextTokenId;
        /// @notice The days not yet closed.
        uint32 openDays;
        /// @notice Whether the owner approved the program's Hookr Bux point budget.
        bool buxApproved;
        /// @notice Whether every day has closed and the whole unused Bux allowance has returned.
        bool buxReleased;
        /// @notice Whether `refundUnapprovedBux` cancelled the program, which then never releases a day.
        bool cancelled;
        /// @notice Always false: Immediate programs hold no cash. It keeps the ABI stable.
        bool immediateCashReleased;
    }

    /// @notice One day's allocation proposal, its review state and its claim totals.
    struct Epoch {
        /// @notice The root of the day's claim tree, or zero for a day with no activity.
        bytes32 merkleRoot;
        /// @notice The hash of the coverage the attestor's proposal claims for the day, bound into every leaf.
        bytes32 coverageHash;
        /// @notice The hash of the evidence the attestor published with the proposal.
        bytes32 evidenceHash;
        /// @notice The sum of every leaf's weight; each claim takes its share of the day's budgets.
        uint256 totalWeight;
        /// @notice The weight claimed so far.
        uint256 claimedWeight;
        /// @notice The points credited from the day so far.
        uint256 pointsAllocated;
        /// @notice The cash credited from the day so far.
        uint256 cashAllocated;
        /// @notice The timestamp from which an unchallenged proposal can be finalized.
        uint64 finalizeAfter;
        /// @notice The number of proposals made for the day; the reviewer approves one exact version.
        uint64 version;
        /// @notice Whether the reviewer vetoed the day; the veto survives re-proposals until the reviewer approves a
        ///         version.
        bool challenged;
        /// @notice Whether the day's allocation is final and claims are open.
        bool finalized;
        /// @notice Whether the day is closed: every unit of weight claimed, a zero day, or a lapse.
        bool closed;
        /// @notice Whether the closed day's unallocated cash has been returned through `releaseUnusedCash`.
        bool remainderReleased;
    }

    /// @notice The cash and Bux allowance a finalized day returned before it closed.
    struct Released {
        /// @notice The cash returned to the creator's refund recipient.
        uint256 cash;
        /// @notice The Bux allowance returned to the unreserved supply.
        uint256 bux;
    }

    /// @notice The program does not exist, or its terms or the call's arguments are invalid.
    error InvalidProgram();
    /// @notice The market is not one of the program's scopes, or a referral scope differs from its base program's.
    error InvalidScope();
    /// @notice The caller may not do this, or the program is a Bux program that is not approved or was cancelled.
    error Unauthorized();
    /// @notice The engagement receipt or its program list is invalid.
    error InvalidReceipt();
    /// @notice The execution, scope or claim was already recorded.
    error Duplicate();
    /// @notice The program, day or proposal is not in the state the call needs.
    error NotReady();
    /// @notice The claim's proof, weight or program mode does not match the finalized day.
    error InvalidProof();
    /// @notice There is nothing to claim or release.
    error NothingToClaim();
    /// @notice The amount exceeds the budget, supply or unreserved balance available.
    error BudgetExceeded();
    /// @notice A token transfer moved a different amount than requested.
    error InexactTransfer();
    /// @notice Ownership cannot be renounced.
    error RenounceDisabled();
    /// @notice The proposal window of day `day` of program `id` ended at `closedAt`.
    error ProposalWindowClosed(uint256 id, uint256 day, uint256 closedAt);
    /// @notice The reviewer approved a version other than day `day`'s current version `current`.
    error StaleVersion(uint256 id, uint256 day, uint64 current);
    /// @notice A payout of `amount` would pay out more than program `id` funded.
    error ProgramOverdrawn(uint256 id, uint256 amount);

    /// @notice The program has no Bux approval proposal ready: none was proposed, it was vetoed or executed, or its
    ///         wait has not passed (`readyAt` is zero or in the future).
    error BuxApprovalNotReady(uint256 id, uint256 readyAt);

    /// @notice The proposal's grace ended at `expiredAt`; approving needs a new proposal.
    error BuxApprovalExpired(uint256 id, uint256 expiredAt);

    /// @notice A proposal for the program is still pending or approvable until `readyAt + BUX_APPROVAL_GRACE`.
    error BuxApprovalPending(uint256 id, uint256 readyAt);

    /// @notice The pooled balance of `token` is below what is owed. Only the party owed may exit, at the pro-rata
    ///         recovery ratio held/owed; a third party cannot impose that haircut.
    error CashShortfall(address token, uint256 owed, uint256 held);

    /// @notice A program was created and funded.
    /// @param id The new program id.
    /// @param creator The account that created and funded the program.
    /// @param termsHash The hash of the program's terms, scopes, milestones and metadata.
    /// @param globalBux Whether the program earns Hookr Bux, which needs the owner's approval.
    /// @param termsData The ABI-encoded terms.
    /// @param scopesData The ABI-encoded scopes.
    /// @param milestonesData The ABI-encoded milestones.
    /// @param metadataData The ABI-encoded milestone collection metadata.
    event ProgramCreated(
        uint256 indexed id,
        address indexed creator,
        bytes32 indexed termsHash,
        bool globalBux,
        bytes termsData,
        bytes scopesData,
        bytes milestonesData,
        bytes metadataData
    );
    /// @notice The owner proposed reserving a Bux program's point budget.
    /// @param id The program.
    /// @param readyAt The timestamp from which the approval can execute.
    /// @param expiresAt The timestamp after which the proposal can no longer execute.
    event BuxProgramProposed(uint256 indexed id, uint256 readyAt, uint256 expiresAt);
    /// @notice A pending Bux approval proposal was voided.
    /// @param id The program.
    /// @param by The owner or guardian that vetoed it.
    event BuxProgramVetoed(uint256 indexed id, address indexed by);
    /// @notice A Bux program's point budget was reserved against the supply cap.
    /// @param id The program.
    /// @param reserved The point budget reserved.
    event BuxProgramApproved(uint256 indexed id, uint256 reserved);
    /// @notice A closed day returned its unissued Bux allowance to the unreserved supply.
    /// @param id The program.
    /// @param amount The allowance returned.
    event BuxAllowanceReleased(uint256 indexed id, uint256 amount);
    /// @notice The router submitted an engagement receipt that passed the receipt checks.
    /// @param executionId The receipt's execution id.
    /// @param participant The swap's authenticated payer.
    /// @param receiptData The ABI-encoded receipt.
    event ExecutionAccepted(bytes32 indexed executionId, address indexed participant, bytes receiptData);

    /// @notice A swap was recorded as activity on a daily swap program's day.
    /// @param id The program.
    /// @param day The zero-indexed program day the swap fell on.
    /// @param executionId The receipt's execution id.
    /// @param participant The swap's authenticated payer.
    event DailyActivityAccepted(
        uint256 indexed id, uint256 indexed day, bytes32 indexed executionId, address participant
    );

    /// @notice An Immediate program credited points for a swap.
    /// @param id The program.
    /// @param participant The account credited.
    /// @param weight The swap's quote volume in the program's common weight units.
    /// @param pointsAward The points credited, after the budget and wallet caps.
    /// @param cashAward The cash credited, zero for an Immediate program.
    event ActivityCredited(
        uint256 indexed id, address indexed participant, uint256 weight, uint256 pointsAward, uint256 cashAward
    );

    /// @notice The attestor proposed a day's allocation.
    /// @param id The program.
    /// @param day The zero-indexed program day.
    /// @param version The proposal's version.
    /// @param merkleRoot The root of the day's claim tree.
    /// @param totalWeight The sum of the leaves' weights.
    /// @param coverageHash The coverage the proposal claims, bound into every leaf.
    /// @param evidenceHash The hash of the evidence published with the proposal.
    /// @param finalizeAfter The timestamp from which the proposal can be finalized if unchallenged.
    event EpochProposed(
        uint256 indexed id,
        uint256 indexed day,
        uint64 version,
        bytes32 merkleRoot,
        uint256 totalWeight,
        bytes32 coverageHash,
        bytes32 evidenceHash,
        uint64 finalizeAfter
    );
    /// @notice The reviewer vetoed a day's proposal.
    /// @param id The program.
    /// @param day The zero-indexed program day.
    /// @param reasonHash The hash of the reviewer's published reason.
    event EpochChallenged(uint256 indexed id, uint256 indexed day, bytes32 reasonHash);
    /// @notice A day's allocation became final.
    /// @param id The program.
    /// @param day The zero-indexed program day.
    /// @param version The finalized version.
    event EpochFinalized(uint256 indexed id, uint256 indexed day, uint64 version);
    /// @notice The reviewer approved one exact proposal version, which lifts any veto.
    /// @param id The program.
    /// @param day The zero-indexed program day.
    /// @param version The approved version.
    event DayApproved(uint256 indexed id, uint256 indexed day, uint64 version);
    /// @notice A day never proposed, or still vetoed, closed as zero once its proposal window ended.
    /// @param id The program.
    /// @param day The zero-indexed program day.
    /// @param version The last proposed version, or zero.
    event DayLapsed(uint256 indexed id, uint256 indexed day, uint64 version);
    /// @notice A payout was cut to the pro-rata recovery ratio because the pooled balance of `token` is below what is
    ///         owed.
    /// @param token The reward token.
    /// @param to The recipient.
    /// @param owed The amount owed.
    /// @param paid The amount paid.
    event ShortfallShared(address indexed token, address indexed to, uint256 owed, uint256 paid);

    /// @notice A beneficiary claimed its share of a finalized day.
    /// @param id The program.
    /// @param day The zero-indexed program day.
    /// @param beneficiary The account credited.
    /// @param weight The weight the proof established.
    /// @param pointsAward The points credited, after the budget and wallet caps.
    /// @param cashAward The cash credited, after the budget and wallet caps.
    event DayClaimed(
        uint256 indexed id,
        uint256 indexed day,
        address indexed beneficiary,
        uint128 weight,
        uint256 pointsAward,
        uint256 cashAward
    );

    /// @notice A referral claim credited a referrer with points for its payer's activity on a finalized day.
    /// @param id The program.
    /// @param day The zero-indexed program day.
    /// @param payer The referred account whose activity the leaf proves.
    /// @param referrer The account credited.
    /// @param weight The weight the proof established.
    /// @param pointsAward The points credited, after the budget and wallet caps.
    event ReferralDayClaimed(
        uint256 indexed id,
        uint256 indexed day,
        address indexed payer,
        address referrer,
        uint128 weight,
        uint256 pointsAward
    );
    /// @notice A beneficiary withdrew earned cash.
    /// @param id The program.
    /// @param beneficiary The account whose earned cash was claimed.
    /// @param to The recipient.
    /// @param amount The cash claimed, before any shortfall cut.
    event CashClaimed(uint256 indexed id, address indexed beneficiary, address indexed to, uint256 amount);
    /// @notice Unallocated cash was returned to the creator's refund recipient.
    /// @param id The program.
    /// @param day The zero-indexed program day, or zero for a refund of an unapproved Bux program.
    /// @param amount The cash returned.
    event UnusedCashReleased(uint256 indexed id, uint256 indexed day, uint256 amount);
    /// @notice A finalized, still-open day returned the part of its budgets no unclaimed leaf can still earn.
    /// @param id The program.
    /// @param day The zero-indexed program day.
    /// @param cash The cash returned.
    /// @param bux The Bux allowance returned.
    event RemainderReleased(uint256 indexed id, uint256 indexed day, uint256 cash, uint256 bux);
    /// @notice The creator named where the program's refunds go.
    /// @param id The program.
    /// @param to The refund recipient, or zero for the creator.
    event RefundRecipientSet(uint256 indexed id, address indexed to);

    /// @notice A participant's points reached a milestone and an NFT was reserved for it.
    /// @param id The program.
    /// @param beneficiary The participant.
    /// @param milestone The milestone index.
    /// @param tokenId The reserved token id.
    event MilestoneReserved(
        uint256 indexed id, address indexed beneficiary, uint256 indexed milestone, uint256 tokenId
    );
    /// @notice A reserved milestone NFT was minted.
    /// @param id The program.
    /// @param beneficiary The participant who earned it.
    /// @param milestone The milestone index.
    /// @param to The NFT's recipient.
    event NFTDelivered(uint256 indexed id, address indexed beneficiary, uint256 indexed milestone, address to);

    /// @notice Returns the most Hookr Bux that can exist at once.
    /// @return The most Hookr Bux that can be issued and reserved together, fixed at deployment.
    function buxSupplyCap() external view returns (uint256);

    /// @notice Returns the referral registry that authorizes DailyReferral claims.
    /// @return The referral registry the DailyReferral programs read.
    function referrals() external view returns (IHookrReferralRegistry);

    /// @notice Returns the factory that deploys each program's milestone collection.
    /// @return The milestone NFT factory.
    function nftFactory() external view returns (IHookrMilestoneNFTFactory);

    /// @notice Returns the stateless validator that checks every new program's terms.
    /// @return The program validator.
    function validator() external view returns (IHookrProgramValidator);

    /// @notice Issued Bux plus unused allowances still reserved for approved programs.
    /// @return The Bux issued plus the unused allowances still reserved.
    function buxReserved() external view returns (uint256);

    /// @notice Lifetime Bux issued across all approved programs.
    /// @return The Bux issued across all approved programs.
    function buxIssued() external view returns (uint256);

    /// @notice Returns the number of programs created; the next program takes the id after it.
    /// @return The program count, which is also the newest program id.
    function programCount() external view returns (uint256);

    /// @notice Returns the points a participant earned in a program.
    /// @param id The program.
    /// @param participant The participant.
    /// @return The participant's points in the program.
    function points(uint256 id, address participant) external view returns (uint256);

    /// @notice Returns the cash a participant has been credited in a program, claimed or not.
    /// @param id The program.
    /// @param participant The participant.
    /// @return The participant's lifetime cash allocation, which the program's wallet cash cap bounds.
    function cashAllocated(uint256 id, address participant) external view returns (uint256);

    /// @notice Returns the cash a participant can withdraw from a program now.
    /// @param id The program.
    /// @param participant The participant.
    /// @return The allocated cash not yet claimed.
    function claimableCash(uint256 id, address participant) external view returns (uint256);

    /// @notice Returns whether a router execution was already recorded for a program.
    /// @param id The program.
    /// @param executionId The receipt's execution id.
    /// @return True once the execution was recorded, so it cannot be recorded again.
    function recorded(uint256 id, bytes32 executionId) external view returns (bool);

    /// @notice Returns whether a daily claim was made for an account on a day.
    /// @param id The program.
    /// @param day The zero-indexed program day.
    /// @param claimant The beneficiary of a daily claim, or the payer of a referral claim.
    /// @return True once the account's leaf was claimed.
    function dayClaimed(uint256 id, uint256 day, address claimant) external view returns (bool);

    /// @notice Returns the milestone NFT reserved for a participant.
    /// @param id The program.
    /// @param beneficiary The participant.
    /// @param milestone The milestone index.
    /// @return The reserved token id, or zero when none is reserved.
    function reservedNFT(uint256 id, address beneficiary, uint256 milestone) external view returns (uint256);

    /// @notice Returns which of a participant's reserved milestone NFTs were delivered.
    /// @param id The program.
    /// @param beneficiary The participant.
    /// @return A bitmap with bit `milestone` set once that milestone's NFT was minted.
    function deliveredNFT(uint256 id, address beneficiary) external view returns (uint256);

    /// @notice Returns how many NFTs of a milestone were reserved so far.
    /// @param id The program.
    /// @param milestone The milestone index.
    /// @return The reservations made, never above the milestone's `maxAwards`.
    function milestoneAwards(uint256 id, uint256 milestone) external view returns (uint256);

    /// @notice Nontransferable global Hookr Bux earned by each participant.
    /// @param participant The participant.
    /// @return The participant's Hookr Bux.
    function buxBalance(address participant) external view returns (uint256);

    /// @notice Unallocated funded budgets plus earned unpaid cash, grouped by reward asset. Each program's share is
    ///         its own ledger (cashBudget - cashPaid - cashRefunded).
    /// @param token The reward token.
    /// @return The cash of `token` the programs owe.
    function reservedCash(address token) external view returns (uint256);

    /// @notice Where a program's refunds go, set by its creator; zero means the creator.
    /// @param id The program.
    /// @return The refund recipient the creator named, or zero for the creator.
    function refundRecipient(uint256 id) external view returns (address);

    /// @notice Cash and Bux allowance a finalized day returned before it closed.
    /// @param id The program.
    /// @param day The zero-indexed program day.
    /// @return cash The cash the day returned before it closed.
    /// @return bux The Bux allowance the day returned before it closed.
    function released(uint256 id, uint256 day) external view returns (uint256 cash, uint256 bux);

    /// @notice When each program's proposed Bux approval becomes executable; zero when none is pending. A proposal
    ///         still pending when its program starts can no longer execute.
    /// @param id The program.
    /// @return The timestamp from which the proposal can execute, or zero when none is pending.
    function buxApprovalReadyAt(uint256 id) external view returns (uint256);

    /// @notice Create immutable terms, scopes and milestones; fund the full cash budget.
    /// @param t The program's terms: mode, window, budgets, caps, rates, attestor, reviewer and review delay.
    /// @param sources The markets whose swaps or fees earn points, each with its conversion rates.
    /// @param milestoneRules The point thresholds and the number of NFTs each awards.
    /// @param metadata The name, symbol, base URI and transferability of the milestone collection.
    /// @return id The new program's id.
    function createProgram(
        HookrProgramTypes.Terms calldata t,
        HookrProgramTypes.Scope[] calldata sources,
        HookrProgramTypes.Milestone[] calldata milestoneRules,
        HookrProgramTypes.NFTMetadata calldata metadata
    ) external returns (uint256 id);

    /// @notice Propose reserving a pending Hookr Bux program's complete point budget. `approveBuxProgram` can execute
    ///         it from BUX_APPROVAL_DELAY after this call until BUX_APPROVAL_GRACE after that, and only before the
    ///         program starts; `vetoBuxProgram` voids it. An expired proposal may be proposed again.
    /// @dev The checks and the proposal record run in the linked library HookrProgramsAdmin.
    /// @param id The program.
    function proposeBuxProgram(uint256 id) external;

    /// @notice Void a program's pending Bux approval proposal. Approving it then needs a new proposal and a new wait.
    /// @dev The owner, or the Hookr registry's guardian (`IHookrRouter(trustedRouter).registry().guardian()`, read
    ///      live in the linked library HookrProgramsAdmin), so a watcher of `BuxProgramProposed` can brake a proposal
    ///      before it executes; any other caller is refused as by `onlyOwner`.
    /// @param id The program.
    function vetoBuxProgram(uint256 id) external;

    /// @notice Reserve the complete point budget of a pending Hookr Bux program: executes its proposal from readyAt
    ///         to readyAt + BUX_APPROVAL_GRACE, before the program starts.
    /// @dev The checks, the proposal's consumption and the approval mark run in the linked library HookrProgramsAdmin,
    ///      which returns the budget reserved here.
    /// @param id The program.
    function approveBuxProgram(uint256 id) external;

    /// @notice Propose a completed day within its proposal window; replacing a pending proposal restarts its review
    ///         delay. A veto is sticky: a re-proposal stays challenged until the reviewer approves an exact version.
    /// @param id The program.
    /// @param day The zero-indexed program day, which must have ended.
    /// @param root The root of the day's claim tree, zero only when `totalWeight` is zero.
    /// @param totalWeight The sum of the leaves' weights.
    /// @param coverageHash The coverage the proposal claims, bound into every leaf; not zero.
    /// @param evidenceHash The hash of the evidence published with the proposal; not zero.
    function proposeDay(
        uint256 id,
        uint256 day,
        bytes32 root,
        uint256 totalWeight,
        bytes32 coverageHash,
        bytes32 evidenceHash
    ) external;

    /// @notice Veto the day until it is finalized. The veto survives re-proposals; only the reviewer lifts it.
    /// @dev Open until finalization, not only until finalizeAfter, so a veto delayed by an outage still lands
    ///      unless someone finalized first.
    /// @param id The program.
    /// @param day The zero-indexed program day.
    /// @param reasonHash The hash of the reviewer's published reason; not zero.
    function challengeDay(uint256 id, uint256 day, bytes32 reasonHash) external;

    /// @notice Reviewer approval of one exact proposal version: lifts any veto and finalizes it at once.
    /// @param id The program.
    /// @param day The zero-indexed program day.
    /// @param version The proposal version the reviewer approves; a newer proposal makes it stale.
    function approveDay(uint256 id, uint256 day, uint64 version) external;

    /// @notice Finalize an unchallenged proposal after its review delay.
    /// @param id The program.
    /// @param day The zero-indexed program day.
    function finalizeDay(uint256 id, uint256 day) external;

    /// @notice Close as zero a day never proposed, or still vetoed, once its proposal window has ended.
    /// @dev A pending unchallenged proposal cannot lapse; it becomes finalizable within reviewDelay. A vetoed version
    ///      cannot lapse before its own finalizeAfter either, so the reviewer always keeps the full review delay after
    ///      the latest proposal to approve it. Proposals stop at the window end, so every day can be closed by
    ///      end + PROPOSAL_WINDOW + reviewDelay.
    /// @param id The program.
    /// @param day The zero-indexed program day.
    function lapseDay(uint256 id, uint256 day) external;

    /// @notice Credit the proven beneficiary from a finalized daily point and cash budget.
    /// @param id The program.
    /// @param day The zero-indexed program day.
    /// @param beneficiary The account credited.
    /// @param weight The leaf's weight.
    /// @param proof The Merkle proof of the leaf under the day's root.
    function claimDay(uint256 id, uint256 day, address beneficiary, uint128 weight, bytes32[] calldata proof) external;

    /// @notice Additive referral points use their own budget. The attestation proves eligible base activity;
    /// registry authorization is also checked onchain and cannot be backdated into the activity block.
    /// @param id The program.
    /// @param day The zero-indexed program day.
    /// @param payer The referred account whose activity the leaf proves.
    /// @param referrer The account credited.
    /// @param firstActivityBlock The block of the payer's first activity, which the referral registry checks against
    ///         its authorization.
    /// @param weight The leaf's weight.
    /// @param proof The Merkle proof of the leaf under the day's root.
    function claimReferralDay(
        uint256 id,
        uint256 day,
        address payer,
        address referrer,
        uint64 firstActivityBlock,
        uint128 weight,
        bytes32[] calldata proof
    ) external;

    /// @notice Return the chain-bound referral domain for immutable program terms.
    /// @param id The program.
    /// @return The hash of the chain, this contract, the program id and its terms hash.
    function referralProgramKey(uint256 id) external view returns (bytes32);

    /// @notice Hash a daily referral claim with its coverage, payer, referrer and activity clock.
    /// @param id The program.
    /// @param day The zero-indexed program day.
    /// @param payer The referred account whose activity the leaf proves.
    /// @param referrer The account credited.
    /// @param firstActivityBlock The block of the payer's first activity.
    /// @param weight The leaf's weight.
    /// @return The leaf the day's claim tree holds for the claim.
    function referralDayLeaf(
        uint256 id,
        uint256 day,
        address payer,
        address referrer,
        uint64 firstActivityBlock,
        uint128 weight
    ) external view returns (bytes32);

    /// @notice Hash a daily claim with its coverage, interval, beneficiary and weight.
    /// @param id The program.
    /// @param day The zero-indexed program day.
    /// @param beneficiary The account credited.
    /// @param weight The leaf's weight.
    /// @return The leaf the day's claim tree holds for the claim.
    function dayLeaf(uint256 id, uint256 day, address beneficiary, uint128 weight) external view returns (bytes32);

    /// @notice Return the exclusive end of a valid zero-indexed UTC day.
    /// @param id The program.
    /// @param day The zero-indexed program day.
    /// @return The timestamp at which the day ends.
    function dayEnd(uint256 id, uint256 day) external view returns (uint64);

    /// @notice Pay earned cash; only the beneficiary may redirect it. Zero amount claims all.
    /// @param id The program.
    /// @param beneficiary The account whose earned cash is claimed.
    /// @param to The recipient; not the beneficiary only when the beneficiary calls.
    /// @param amount The cash to claim, or zero for all of it.
    function claimCash(uint256 id, address beneficiary, address to, uint256 amount) external;

    /// @notice Deliver a reserved milestone; a rejected safe mint returns false and remains retryable.
    /// @dev The delivery runs in the linked library HookrProgramsAdmin.
    /// @param id The program.
    /// @param beneficiary The account that earned the milestone.
    /// @param milestone The milestone index.
    /// @param to The NFT's recipient; not the beneficiary only when the beneficiary calls.
    /// @return True when the NFT was minted, false when the collection refused it.
    function claimNFT(uint256 id, address beneficiary, uint256 milestone, address to) external returns (bool);

    /// @notice Return a closed day's unallocated cash to the creator. Only enabled (approved or non-Bux) daily
    ///         programs can close days, so this never overlaps refundUnapprovedBux.
    /// @param id The program.
    /// @param day The zero-indexed program day, which must be closed.
    /// @return amount The cash returned.
    function releaseUnusedCash(uint256 id, uint256 day) external returns (uint256 amount);

    /// @notice Return the part of a finalized, still-open day's cash and Bux allowance that no unclaimed leaf can
    ///         still earn, so one unclaimable leaf holds back only its own maximum. Callable again as claims land;
    ///         the rest returns through releaseUnusedCash once the day closes.
    /// @param id The program.
    /// @param day The zero-indexed program day, which must be finalized and open.
    /// @return cash The cash returned.
    /// @return bux The Bux allowance returned.
    function releaseRemainder(uint256 id, uint256 day) external returns (uint256 cash, uint256 bux);

    /// @notice Direct this program's refunds to `to` (zero restores the creator). Creator only.
    /// @param id The program.
    /// @param to The refund recipient, or zero for the creator.
    function setRefundRecipient(uint256 id, address to) external;

    /// @notice Cancel and refund a Bux program that reached its start without approval. Such a program was never
    ///         enabled, so nothing was allocated or released before.
    /// @dev The refund logs UnusedCashReleased(id, 0, cashBudget), the event a release of day 0 logs too.
    ///      `program(id).cancelled` tells them apart: true only after this refund, and a cancelled program never
    ///      releases a day.
    /// @param id The program.
    function refundUnapprovedBux(uint256 id) external;

    /// @notice Return immutable program terms and current issuance and cash accounting.
    /// @param id The program.
    /// @return The program's terms and accounting.
    function program(uint256 id) external view returns (Program memory);

    /// @notice Return the program's ordered markets and fixed normalization rates.
    /// @param id The program.
    /// @return The program's scopes in order.
    function scopes(uint256 id) external view returns (HookrProgramTypes.Scope[] memory);

    /// @notice Return the program's ordered point thresholds and award limits.
    /// @param id The program.
    /// @return The program's milestones in order.
    function milestones(uint256 id) external view returns (HookrProgramTypes.Milestone[] memory);

    /// @notice Return the proposal, review state and allocation totals for a day.
    /// @param id The program.
    /// @param day The zero-indexed program day.
    /// @return The day's proposal, review state and allocation totals.
    function epoch(uint256 id, uint256 day) external view returns (Epoch memory);
}
