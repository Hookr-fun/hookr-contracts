// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrRegistry} from "../interfaces/IHookrRegistry.sol";
import {IHookrRoot} from "../interfaces/IHookrRoot.sol";
import {IHookrRules} from "../interfaces/IHookrRules.sol";
import {IHookrLaneRules} from "../interfaces/IHookrLaneRules.sol";
import {HookrTypes} from "../types/HookrTypes.sol";
import {IHookrReferralRegistry} from "../interfaces/IHookrReferralRegistry.sol";
import {HookrReleased} from "../base/HookrReleased.sol";
import {IHookrReferralDistributor} from "../interfaces/IHookrReferralDistributor.sol";

/// @title HookrReferralDistributor
/// @notice Fully funded, exact fee commissions. No fees are intercepted in the root.
/// @dev The one attestor fixed at deployment (the operator whose ledger reserves each fee lot once) and each
///      campaign's own reviewer must establish collected fee provenance. Coverage and collection hashes commit
///      their evidence; they are not onchain historical proofs. Onchain bounds: only registered Hookr roots and
///      the pinned attestor, a sticky reviewer veto lifted only by version-bound approval, a review window
///      longer than the chain's forced-inclusion delay, credits that never open before a version's review
///      window ends, a 90-day proposal window after which unresolved days lapse, combined payouts below 100% of
///      the largest fee amount credited for one payer, pool, fee source and UTC day across every campaign in
///      this distributor (at most half of it on the Protocol fee of a pool whose King of the Pool is on), release
///      of cash that can never be owed, and owner-consented pro-rata settlement of an issuer shortfall instead of a
///      currency-wide freeze. Self-referral through a second wallet is NOT prevented: treat referrerBps +
///      cashbackBps as a rebate any bound trader can take, up to that cap.
contract HookrReferralDistributor is HookrReleased, ReentrancyGuard, IHookrReferralDistributor {
    using SafeERC20 for IERC20;

    uint256 public constant DAY = 1 days;
    /// @notice Shortest review window: six days. A veto the sequencer withholds can be forced in through the delayed
    ///         inbox once 28,800 parent blocks have passed since the one it reached the inbox in (chain 4663's
    ///         SequencerInbox delayBlocks at L1 block 26,063,772: four days at 12 s, more when parent slots are
    ///         missed). The window is counted in L2 timestamps, which the sequencer sets inside that inbox's bounds: up
    ///         to 3,600 s (futureSeconds) ahead of the parent chain's time and up to 345,600 s (delaySeconds) behind
    ///         it, so a block can carry finalizeAfter from finalizeAfter - 1 hour of parent-chain time. Assuming honest
    ///         timestamps (the proposal's timestamp not behind parent-chain time), a veto forced in as soon as it may
    ///         be lands before anyone can finalize or credit if that comes more than an hour before finalizeAfter: one
    ///         sent within about the first reviewDelay - 4 days - 1 hour (47 hours at this floor), less 12 s for each
    ///         parent slot missed while it waits. A proposal stamped behind parent-chain time shortens that window by
    ///         its lag, and at this floor a lag of 47 hours closes it; the lag shows on chain as L2 timestamps behind
    ///         the parent chain's.
    uint64 public constant MIN_REVIEW_DELAY = 6 days;
    /// @notice Longest review window.
    uint64 public constant MAX_REVIEW_DELAY = 30 days;
    /// @notice Time after finalizeAfter during which a veto still lands if nobody finalized first: five days, one
    ///         forced-inclusion delay (four days) and one more, so a veto sent at the review window's last second and
    ///         forced in four days later counts in an outage, where forced transactions keep their L1 order. A finalize
    ///         the sequencer includes first still wins. After the grace a mature day can no longer be voided.
    uint64 public constant VETO_GRACE = 5 days;
    /// @notice Time after a day ends during which its attestor may propose. After it, a day never proposed, or
    ///         one whose veto the reviewer never lifted, can be lapsed to zero by anyone and its budget returned.
    uint256 public constant PROPOSAL_WINDOW = 90 days;
    /// @notice Highest combined commission plus cashback, in bps of the largest fee amount any campaign here
    ///         credited for one payer, pool, fee source and UTC day, summed over every campaign in this
    ///         distributor. The Protocol fee of a pool whose King of the Pool is on has
    ///         MAX_KING_OF_THE_POOL_STACKED_BPS instead.
    uint256 public constant MAX_STACKED_BPS = 9_999;
    /// @notice Highest combined commission plus cashback on the Protocol fee of a pool whose King of the Pool is on,
    ///         in bps of the same largest fee amount, summed over every campaign in this distributor: half. A King of
    ///         the Pool prize is at most half the protocol fee its winning buy left with the protocol recipient, so a
    ///         rebate of more than the other half would let a washer who owns the pool's liquidity farm the crown at a
    ///         profit.
    uint256 public constant MAX_KING_OF_THE_POOL_STACKED_BPS = 5_000;
    /// @dev Gas for reading a pool's recapture mode from its Rules: what the root grants the same read when it
    ///      initializes the pool.
    uint256 private constant MODE_GAS = 50_000;
    /// @dev IHookrLaneRules.recaptureMode's answer for recapture with King of the Pool.
    uint256 private constant MODE_KING_OF_THE_POOL = 2;

    /// @dev Payouts already credited on one payer's fees for a pool, fee source and UTC day, and the largest
    ///      fee amount any campaign credited for them. Capacity is used only by cash actually credited.
    struct Stack {
        uint128 feeBasis;
        uint128 paid;
    }

    /// @inheritdoc IHookrReferralDistributor
    IHookrReferralRegistry public immutable referrals;
    /// @inheritdoc IHookrReferralDistributor
    IHookrRegistry public immutable registry;
    /// @inheritdoc IHookrReferralDistributor
    address public immutable attestor;
    /// @inheritdoc IHookrReferralDistributor
    uint256 public campaignCount;
    mapping(uint256 => Campaign) private _campaigns;
    mapping(uint256 => mapping(uint256 => Epoch)) private _epochs;
    /// @inheritdoc IHookrReferralDistributor
    mapping(uint256 => mapping(uint256 => mapping(address => bool))) public credited;
    /// @inheritdoc IHookrReferralDistributor
    mapping(address => mapping(address => uint256)) public claimable;
    /// @inheritdoc IHookrReferralDistributor
    mapping(address => uint256) public reservedCash;
    /// @inheritdoc IHookrReferralDistributor
    mapping(uint256 => mapping(uint256 => uint256)) public refunded;
    mapping(bytes32 => Stack) private _stacks;

    constructor(address referralRegistry, address hookrRegistry, address commissionAttestor) {
        if (referralRegistry.code.length == 0 || hookrRegistry.code.length == 0) revert InvalidCampaign();
        if (commissionAttestor == address(0)) revert InvalidAttestor(commissionAttestor);
        referrals = IHookrReferralRegistry(referralRegistry);
        registry = IHookrRegistry(hookrRegistry);
        attestor = commissionAttestor;
    }

    /// @inheritdoc IHookrReferralDistributor
    function createCampaign(Terms calldata t) external payable nonReentrant returns (uint256 id) {
        if (
            t.root.code.length == 0 || t.rules.code.length == 0 || t.start < block.timestamp || t.start % DAY != 0
                || t.end <= t.start || (t.end - t.start) % DAY != 0 || (t.end - t.start) / DAY > 366
                || t.dailyBudget == 0 || t.walletFeeCap == 0 || t.referrerBps == 0
                || uint256(t.referrerBps) + t.cashbackBps >= 10_000 || t.attestor == address(0)
                || t.reviewer == address(0) || t.attestor == t.reviewer || t.reviewDelay < MIN_REVIEW_DELAY
                || t.reviewDelay > MAX_REVIEW_DELAY || t.sourcePolicyHash == bytes32(0)
        ) revert InvalidCampaign();
        if (t.attestor != attestor) revert InvalidAttestor(t.attestor);
        if (!registry.isRoot(t.root)) revert UnregisteredRoot(t.root);
        IHookrRoot root = IHookrRoot(t.root);
        PoolId pool = PoolId.wrap(t.poolId);
        if (!root.knownPool(pool) || root.policyHash(pool) != t.configHash) revert InvalidCampaign();
        // One configuration read serves both fields it checks: the pool's Rules and its quote.
        HookrTypes.PoolConfig memory config = root.poolConfig(pool);
        if (
            config.rules != t.rules || Currency.unwrap(config.quote) != t.currency
                || IHookrRules(t.rules).trustedRoot() != t.root
        ) revert InvalidCampaign();
        uint256 budget = uint256(t.dailyBudget) * ((t.end - t.start) / DAY);
        _fund(t.currency, budget);
        id = ++campaignCount;
        Campaign storage c = _campaigns[id];
        c.terms = t;
        c.creator = msg.sender;
        c.termsHash = keccak256(abi.encode(block.chainid, address(this), id, msg.sender, t));
        c.programKey = keccak256(abi.encode(block.chainid, address(this), id, c.termsHash));
        emit CampaignCreated(id, msg.sender, c.programKey, c.termsHash, abi.encode(t));
    }

    /// @inheritdoc IHookrReferralDistributor
    function proposeDay(
        uint256 id,
        uint256 day,
        bytes32 root,
        uint256 totalFees,
        bytes32 coverageHash,
        bytes32 collectionsHash
    ) external {
        Campaign storage c = _campaign(id);
        Epoch storage e = _epochs[id][day];
        uint256 end = dayEnd(id, day);
        if (
            msg.sender != c.terms.attestor || block.timestamp < end || e.finalized || coverageHash == bytes32(0)
                || collectionsHash == bytes32(0) || ((root == bytes32(0)) != (totalFees == 0))
                || block.timestamp + c.terms.reviewDelay > type(uint64).max
        ) revert NotReady();
        if (block.timestamp >= end + PROPOSAL_WINDOW) revert ProposalWindowClosed(id, day, end + PROPOSAL_WINDOW);
        if (Math.mulDiv(totalFees, _rate(c.terms), 10_000) > c.terms.dailyBudget) revert BudgetExceeded();
        e.merkleRoot = root;
        e.totalFees = totalFees;
        e.coverageHash = coverageHash;
        e.collectionsHash = collectionsHash;
        e.finalizeAfter = uint64(block.timestamp + c.terms.reviewDelay);
        ++e.version;
        emit EpochProposed(id, day, e.version, root, totalFees, coverageHash, collectionsHash, e.finalizeAfter);
    }

    /// @inheritdoc IHookrReferralDistributor
    function challengeDay(uint256 id, uint256 day, bytes32 reasonHash) external {
        Campaign storage c = _campaign(id);
        Epoch storage e = _epochs[id][day];
        if (msg.sender != c.terms.reviewer || e.version == 0 || e.finalized || reasonHash == bytes32(0)) {
            revert NotReady();
        }
        uint256 closedAt = uint256(e.finalizeAfter) + VETO_GRACE;
        if (block.timestamp >= closedAt) revert VetoClosed(id, day, closedAt);
        e.challenged = true;
        emit EpochChallenged(id, day, reasonHash);
    }

    /// @inheritdoc IHookrReferralDistributor
    function approveDay(uint256 id, uint256 day, uint64 version) external {
        Campaign storage c = _campaign(id);
        Epoch storage e = _epochs[id][day];
        if (msg.sender != c.terms.reviewer) revert NotReviewer(msg.sender);
        if (e.finalized) revert DayFinalized(id, day);
        if (version == 0 || e.version != version) revert StaleVersion(id, day, e.version);
        e.challenged = false;
        e.finalized = true;
        emit DayApproved(id, day, version);
        emit EpochFinalized(id, day, version);
    }

    /// @inheritdoc IHookrReferralDistributor
    function finalizeDay(uint256 id, uint256 day) external {
        _campaign(id);
        Epoch storage e = _epochs[id][day];
        if (e.version == 0 || e.finalized || e.challenged || block.timestamp < e.finalizeAfter) revert NotReady();
        e.finalized = true;
        emit EpochFinalized(id, day, e.version);
    }

    /// @inheritdoc IHookrReferralDistributor
    function lapseDay(uint256 id, uint256 day) external {
        _campaign(id);
        Epoch storage e = _epochs[id][day];
        if (e.finalized) revert DayFinalized(id, day);
        uint256 opensAt = uint256(dayEnd(id, day)) + PROPOSAL_WINDOW;
        if (e.finalizeAfter > opensAt) opensAt = e.finalizeAfter;
        if (block.timestamp < opensAt) revert LapseNotOpen(id, day, opensAt);
        if (e.version != 0 && !e.challenged) revert PendingProposal(id, day, e.version);
        e.finalized = true;
        e.merkleRoot = bytes32(0);
        e.totalFees = 0;
        emit DayLapsed(id, day, e.version);
    }

    /// @inheritdoc IHookrReferralDistributor
    function creditDay(
        uint256 id,
        uint256 day,
        address payer,
        address referrer,
        uint64 firstActivityBlock,
        uint128 eligibleFees,
        bytes32[] calldata proof
    ) external nonReentrant {
        Campaign storage c = _campaign(id);
        Epoch storage e = _epochs[id][day];
        if (
            !e.finalized || payer == address(0) || eligibleFees == 0 || eligibleFees > c.terms.walletFeeCap
                || proof.length > 32
        ) {
            revert InvalidProof();
        }
        if (block.timestamp < e.finalizeAfter) revert CreditNotOpen(id, day, e.finalizeAfter);
        if (credited[id][day][payer]) revert AlreadyClaimed();
        if (
            !referrals.eligible(c.programKey, payer, referrer, firstActivityBlock)
                || !MerkleProof.verifyCalldata(
                    proof,
                    e.merkleRoot,
                    _feeLeaf(
                        id, day, e.coverageHash, e.collectionsHash, payer, referrer, firstActivityBlock, eligibleFees
                    )
                ) || eligibleFees > e.totalFees - e.claimedFees
        ) revert InvalidProof();
        (uint256 commission, uint256 cashback) = _stack(id, day, c.terms, payer, eligibleFees);
        if (commission + cashback > c.terms.dailyBudget - e.allocated - refunded[id][day]) revert BudgetExceeded();
        credited[id][day][payer] = true;
        e.claimedFees += eligibleFees;
        e.allocated += commission + cashback;
        claimable[c.terms.currency][referrer] += commission;
        claimable[c.terms.currency][payer] += cashback;
        emit CommissionCredited(id, day, payer, referrer, eligibleFees, commission, cashback);
    }

    /// @inheritdoc IHookrReferralDistributor
    function feeLeaf(
        uint256 id,
        uint256 day,
        address payer,
        address referrer,
        uint64 firstActivityBlock,
        uint128 eligibleFees
    ) external view returns (bytes32) {
        Epoch storage e = _epochs[id][day];
        if (e.version == 0) revert NoLiveProposal(id, day);
        return _feeLeaf(id, day, e.coverageHash, e.collectionsHash, payer, referrer, firstActivityBlock, eligibleFees);
    }

    /// @inheritdoc IHookrReferralDistributor
    function feeLeafFor(
        uint256 id,
        uint256 day,
        bytes32 coverageHash,
        bytes32 collectionsHash,
        address payer,
        address referrer,
        uint64 firstActivityBlock,
        uint128 eligibleFees
    ) external view returns (bytes32) {
        return _feeLeaf(id, day, coverageHash, collectionsHash, payer, referrer, firstActivityBlock, eligibleFees);
    }

    /// @inheritdoc IHookrReferralDistributor
    function claim(address currency, address beneficiary, address to, uint256 amount) external nonReentrant {
        if (
            beneficiary == address(0) || to == address(0) || to == address(this)
                || (to != beneficiary && msg.sender != beneficiary)
        ) {
            revert Unauthorized();
        }
        uint256 available = claimable[currency][beneficiary];
        if (amount == 0) amount = available;
        if (amount == 0 || amount > available) revert BudgetExceeded();
        claimable[currency][beneficiary] = available - amount;
        _pay(currency, to, amount, msg.sender == beneficiary);
        emit Claimed(currency, beneficiary, to, amount);
    }

    /// @inheritdoc IHookrReferralDistributor
    function releaseRemainder(uint256 id, uint256 day, address to) external nonReentrant returns (uint256 amount) {
        Campaign storage c = _campaign(id);
        if (to == address(0) || to == address(this)) revert Unauthorized();
        if (to != c.creator && msg.sender != c.creator) revert NotCreator(msg.sender);
        Epoch storage e = _epochs[id][day];
        if (!e.finalized || e.released) revert NotReady();
        uint256 done = refunded[id][day];
        uint256 owable = Math.mulDiv(e.totalFees - e.claimedFees, _rate(c.terms), 10_000);
        amount = c.terms.dailyBudget - e.allocated - owable - done;
        if (owable == 0) e.released = true;
        else if (amount == 0) revert NothingToRelease(id, day);
        refunded[id][day] = done + amount;
        if (amount != 0) _pay(c.terms.currency, to, amount, msg.sender == c.creator);
        emit RemainderReleased(id, day, to, amount, e.released);
    }

    /// @inheritdoc IHookrReferralDistributor
    function stackedRebate(bytes32 poolId, FeeSource feeSource, uint256 utcDay, address payer)
        external
        view
        returns (uint256 feeBasis, uint256 paid)
    {
        Stack storage s = _stacks[_stackKey(poolId, feeSource, utcDay, payer)];
        return (s.feeBasis, s.paid);
    }

    /// @inheritdoc IHookrReferralDistributor
    function dayEnd(uint256 id, uint256 day) public view returns (uint64) {
        Terms storage t = _campaign(id).terms;
        if (day >= (t.end - t.start) / DAY) revert InvalidCampaign();
        return uint64(uint256(t.start) + (day + 1) * DAY);
    }

    /// @inheritdoc IHookrReferralDistributor
    function campaign(uint256 id) external view returns (Campaign memory) {
        return _campaign(id);
    }

    /// @inheritdoc IHookrReferralDistributor
    function epoch(uint256 id, uint256 day) external view returns (Epoch memory) {
        return _epochs[id][day];
    }

    function _campaign(uint256 id) private view returns (Campaign storage c) {
        c = _campaigns[id];
        if (c.creator == address(0)) revert InvalidCampaign();
    }

    function _rate(Terms storage t) private view returns (uint256) {
        return uint256(t.referrerBps) + t.cashbackBps;
    }

    function _stackKey(bytes32 poolId, FeeSource feeSource, uint256 utcDay, address payer)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(poolId, feeSource, utcDay, payer));
    }

    /// @dev Credit the campaign's nominal commission and cashback on `fees`, cut to the payer's remaining
    ///      capacity: the key's cap (`_capBps`) of the largest fee amount credited for this key minus what is already
    ///      paid. Measuring against the largest single amount, never a sum, keeps the bound sound when two campaigns
    ///      attest the same fee lot; a credit that pays nothing uses no capacity.
    function _stack(uint256 id, uint256 day, Terms storage t, address payer, uint128 fees)
        private
        returns (uint256 commission, uint256 cashback)
    {
        commission = Math.mulDiv(fees, t.referrerBps, 10_000);
        cashback = Math.mulDiv(fees, t.cashbackBps, 10_000);
        Stack storage s = _stacks[_stackKey(t.poolId, t.feeSource, uint256(t.start) / DAY + day, payer)];
        uint256 basis = s.feeBasis > fees ? s.feeBasis : fees;
        uint256 paid = s.paid;
        uint256 limit = Math.mulDiv(basis, _capBps(t), 10_000);
        uint256 room = limit > paid ? limit - paid : 0;
        uint256 nominal = commission + cashback;
        if (nominal > room) {
            uint256 rate = _rate(t);
            commission = Math.mulDiv(room, t.referrerBps, rate);
            cashback = Math.mulDiv(room, t.cashbackBps, rate);
            emit StackingCapApplied(id, day, payer, nominal, commission + cashback);
        }
        s.feeBasis = uint128(basis);
        s.paid = uint128(paid + commission + cashback);
    }

    /// @dev The stacking cap of a campaign's key: MAX_KING_OF_THE_POOL_STACKED_BPS on the Protocol fee of a pool whose
    ///      Rules answer recaptureMode with King of the Pool, MAX_STACKED_BPS otherwise. The mode is read as the root
    ///      reads it when it initializes the pool, with MODE_GAS and one word, a failed or malformed answer meaning no
    ///      recapture; HookrRules freezes it at bind, so every campaign on a pool gets the same cap. A caller cannot
    ///      lift the cap by starving the read: the read runs out of gas only when the credit forwards it all but 1/64
    ///      of its remaining gas, and that 1/64 is far less than the writes the credit still has to make.
    function _capBps(Terms storage t) private view returns (uint256) {
        if (t.feeSource != FeeSource.Protocol) return MAX_STACKED_BPS;
        bytes memory input = abi.encodeCall(IHookrLaneRules.recaptureMode, (PoolId.wrap(t.poolId)));
        address rules = t.rules;
        bool crowned;
        assembly ("memory-safe") {
            let ok := staticcall(MODE_GAS, rules, add(input, 32), mload(input), 0, 32)
            crowned := and(and(ok, eq(returndatasize(), 32)), eq(mload(0), MODE_KING_OF_THE_POOL))
        }
        return crowned ? MAX_KING_OF_THE_POOL_STACKED_BPS : MAX_STACKED_BPS;
    }

    function _feeLeaf(
        uint256 id,
        uint256 day,
        bytes32 coverageHash,
        bytes32 collectionsHash,
        address payer,
        address referrer,
        uint64 firstActivityBlock,
        uint128 eligibleFees
    ) private view returns (bytes32) {
        Campaign storage c = _campaign(id);
        uint64 end = dayEnd(id, day);
        return keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(
                        block.chainid,
                        address(this),
                        id,
                        c.termsHash,
                        day,
                        uint64(end - DAY),
                        end,
                        coverageHash,
                        collectionsHash,
                        payer,
                        referrer,
                        firstActivityBlock,
                        eligibleFees
                    )
                )
            )
        );
    }

    function _fund(address token, uint256 amount) private {
        if (token == address(0)) {
            if (msg.value != amount) revert InexactTransfer();
        } else {
            if (msg.value != 0 || token.code.length == 0) revert InexactTransfer();
            IERC20 a = IERC20(token);
            uint256 beforeBalance = a.balanceOf(address(this));
            uint256 payer = a.balanceOf(msg.sender);
            // New cash never tops up an existing shortfall: a later creator must not absorb earlier losses.
            if (beforeBalance < reservedCash[token]) revert BudgetExceeded();
            a.safeTransferFrom(msg.sender, address(this), amount);
            if (a.balanceOf(address(this)) != beforeBalance + amount || a.balanceOf(msg.sender) != payer - amount) {
                revert InexactTransfer();
            }
        }
        reservedCash[token] += amount;
    }

    /// @dev An issuer burn, clawback or negative rebase can leave the pooled balance below what is owed. The loss is
    ///      shared pro rata instead of freezing every campaign: the party owed may exit (`consent`) at held/owed,
    ///      which leaves that ratio unchanged for everyone else. A third party cannot trigger a haircut on someone
    ///      else, and nobody can extinguish a claim for nothing.
    function _pay(address token, address to, uint256 owed, bool consent) private {
        uint256 liability = reservedCash[token];
        uint256 held = token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
        uint256 paid = owed;
        if (held < liability) {
            paid = Math.mulDiv(owed, held, liability);
            if (!consent || paid == 0) revert CashShortfall(token, liability, held);
            emit ShortfallShared(token, to, owed, paid);
        }
        reservedCash[token] = liability - owed;
        if (token == address(0)) {
            (bool ok,) = to.call{value: paid}("");
            if (!ok) revert InexactTransfer();
        } else {
            IERC20 a = IERC20(token);
            uint256 recipient = a.balanceOf(to);
            a.safeTransfer(to, paid);
            if (a.balanceOf(address(this)) != held - paid || a.balanceOf(to) != recipient + paid) {
                revert InexactTransfer();
            }
        }
    }
}
