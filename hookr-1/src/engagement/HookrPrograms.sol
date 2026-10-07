// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {HookrProgramValidator} from "./HookrProgramValidator.sol";
import {IHookrProgramValidator} from "../interfaces/IHookrProgramValidator.sol";
import {IHookrReferralRegistry} from "../interfaces/IHookrReferralRegistry.sol";
import {HookrProgramTypes as P} from "../types/HookrProgramTypes.sol";
import {IHookrEngagementReceiptSink} from "../interfaces/IHookrEngagementReceiptSink.sol";
import {HookrMilestoneNFTFactory} from "./HookrMilestoneNFTFactory.sol";
import {IHookrMilestoneNFTFactory} from "../interfaces/IHookrMilestoneNFTFactory.sol";
import {HookrProgramsAdmin} from "../libraries/HookrProgramsAdmin.sol";
import {HookrReleased} from "../base/HookrReleased.sol";
import {IHookrPrograms} from "../interfaces/IHookrPrograms.sol";

/// @title HookrPrograms
/// @notice Creator programs and separately approved, capped Hookr Bux. No root bookkeeping.
/// @dev Daily allocations trust the named attestor/reviewer; proofs do not establish historical truth.
///      Immediate programs credit creator points only; cash, Bux and milestone NFTs need a reviewed daily
///      allocation. Every program's cash is its own ledger: no program can pay out more than it funded.
contract HookrPrograms is HookrReleased, IHookrEngagementReceiptSink, Ownable2Step, ReentrancyGuard, IHookrPrograms {
    using SafeERC20 for IERC20;
    using TransientStateLibrary for IPoolManager;

    uint256 public constant DAY = P.DAY;
    uint256 public constant MAX_DAYS = P.MAX_DAYS;
    uint256 public constant MAX_SCOPES = P.MAX_SCOPES;
    uint256 public constant MAX_MILESTONES = P.MAX_MILESTONES;
    uint256 public constant MAX_RATE = P.MAX_RATE;
    /// @notice Time after a day ends during which its attestor may propose. After it, an unproposed day, or one
    ///         whose veto the reviewer never lifted, can be lapsed to zero by anyone (a vetoed version only once its
    ///         own review delay has passed).
    uint256 public constant PROPOSAL_WINDOW = 90 days;
    /// @notice Wait between a Bux program's proposal and its approval: thirty minutes, the registry's delay, so a
    ///         watcher of `BuxProgramProposed` can act before any Bux are reserved.
    uint256 public constant BUX_APPROVAL_DELAY = 30 minutes;
    /// @notice How long a ready proposal stays approvable; after it the program needs a new proposal.
    uint256 public constant BUX_APPROVAL_GRACE = 14 days;
    /// @inheritdoc IHookrEngagementReceiptSink
    address public immutable override poolManager;
    /// @inheritdoc IHookrEngagementReceiptSink
    address public immutable override trustedRouter;
    /// @inheritdoc IHookrPrograms
    uint256 public immutable buxSupplyCap;
    /// @inheritdoc IHookrPrograms
    IHookrReferralRegistry public immutable referrals;
    /// @inheritdoc IHookrPrograms
    IHookrMilestoneNFTFactory public immutable nftFactory;
    /// @inheritdoc IHookrPrograms
    IHookrProgramValidator public immutable validator;
    /// @inheritdoc IHookrPrograms
    uint256 public buxReserved;
    /// @inheritdoc IHookrPrograms
    uint256 public buxIssued;
    /// @inheritdoc IHookrPrograms
    uint256 public programCount;

    mapping(uint256 => Program) private _programs;
    mapping(uint256 => P.Scope[]) private _scopes;
    mapping(uint256 => P.Milestone[]) private _milestones;
    mapping(uint256 => mapping(bytes32 => uint256)) private _scopeIndex;
    /// @inheritdoc IHookrPrograms
    mapping(uint256 => mapping(address => uint256)) public points;
    /// @inheritdoc IHookrPrograms
    mapping(uint256 => mapping(address => uint256)) public cashAllocated;
    /// @inheritdoc IHookrPrograms
    mapping(uint256 => mapping(address => uint256)) public claimableCash;
    mapping(uint256 => mapping(address => uint256)) private _pointCarry;
    mapping(uint256 => mapping(address => mapping(uint256 => uint256))) private _scopeCarry;
    /// @inheritdoc IHookrPrograms
    mapping(uint256 => mapping(bytes32 => bool)) public recorded;
    mapping(uint256 => mapping(uint256 => Epoch)) private _epochs;
    /// @inheritdoc IHookrPrograms
    mapping(uint256 => mapping(uint256 => mapping(address => bool))) public dayClaimed;
    /// @inheritdoc IHookrPrograms
    mapping(uint256 => mapping(address => mapping(uint256 => uint256))) public reservedNFT;
    /// @inheritdoc IHookrPrograms
    mapping(uint256 => mapping(address => uint256)) public deliveredNFT;
    /// @inheritdoc IHookrPrograms
    mapping(uint256 => mapping(uint256 => uint256)) public milestoneAwards;
    /// @inheritdoc IHookrPrograms
    mapping(address => uint256) public buxBalance;
    /// @inheritdoc IHookrPrograms
    mapping(address => uint256) public reservedCash;
    /// @inheritdoc IHookrPrograms
    mapping(uint256 => address) public refundRecipient;
    /// @inheritdoc IHookrPrograms
    mapping(uint256 => mapping(uint256 => Released)) public released;
    /// @inheritdoc IHookrPrograms
    mapping(uint256 => uint256) public buxApprovalReadyAt;

    constructor(IPoolManager manager, address router, address buxOwner, uint256 supplyCap, address referralRegistry)
        Ownable(buxOwner)
    {
        if (
            address(manager).code.length == 0 || router.code.length == 0 || supplyCap == 0
                || referralRegistry.code.length == 0
        ) revert InvalidProgram();
        poolManager = address(manager);
        trustedRouter = router;
        buxSupplyCap = supplyCap;
        referrals = IHookrReferralRegistry(referralRegistry);
        nftFactory = new HookrMilestoneNFTFactory();
        validator = new HookrProgramValidator();
    }

    /// @inheritdoc IHookrPrograms
    function createProgram(
        P.Terms calldata t,
        P.Scope[] calldata sources,
        P.Milestone[] calldata milestoneRules,
        P.NFTMetadata calldata metadata
    ) external nonReentrant returns (uint256 id) {
        _validate(t);
        validator.validate(
            t,
            sources,
            milestoneRules,
            metadata,
            poolManager,
            trustedRouter,
            t.mode == P.Mode.DailyLPFees
                || (t.mode == P.Mode.DailyReferral && _programs[t.baseProgramId].terms.mode == P.Mode.DailyLPFees)
        );
        id = ++programCount;
        Program storage p = _programs[id];
        p.terms = t;
        p.creator = msg.sender;
        p.termsHash =
            keccak256(abi.encode(block.chainid, address(this), id, msg.sender, t, sources, milestoneRules, metadata));
        if (t.mode != P.Mode.Immediate) p.openDays = uint32((t.end - t.start) / DAY);
        for (uint256 i; i < sources.length; ++i) {
            P.Scope calldata s = sources[i];
            bytes32 key = _scopeKey(s.root, s.poolId, s.configHash, s.quoteAsset);
            if (t.mode == P.Mode.DailyReferral) {
                uint256 baseIndex = _scopeIndex[t.baseProgramId][key];
                if (
                    baseIndex == 0
                        || keccak256(abi.encode(_scopes[t.baseProgramId][baseIndex - 1])) != keccak256(abi.encode(s))
                ) revert InvalidScope();
            }
            if (_scopeIndex[id][key] != 0) revert Duplicate();
            _scopeIndex[id][key] = i + 1;
            _scopes[id].push(s);
        }
        uint256 supply;
        for (uint256 i; i < milestoneRules.length; ++i) {
            P.Milestone calldata m = milestoneRules[i];
            supply += m.maxAwards;
            _milestones[id].push(m);
        }
        if (supply != 0) {
            p.collection =
                nftFactory.create(supply, metadata.name, metadata.symbol, metadata.baseURI, metadata.transferable);
        }
        if (t.cashBudget != 0) _fund(t.rewardToken, msg.sender, t.cashBudget);
        emit ProgramCreated(
            id,
            msg.sender,
            p.termsHash,
            t.globalBux,
            abi.encode(t),
            abi.encode(sources),
            abi.encode(milestoneRules),
            abi.encode(metadata)
        );
    }

    /// @inheritdoc IHookrPrograms
    function proposeBuxProgram(uint256 id) external onlyOwner {
        HookrProgramsAdmin.proposeBux(_program(id), buxApprovalReadyAt, id);
    }

    /// @inheritdoc IHookrPrograms
    function vetoBuxProgram(uint256 id) external {
        HookrProgramsAdmin.vetoBux(buxApprovalReadyAt, id);
    }

    /// @inheritdoc IHookrPrograms
    function approveBuxProgram(uint256 id) external onlyOwner {
        uint256 reserved = buxReserved;
        buxReserved =
            reserved + HookrProgramsAdmin.approveBux(_program(id), buxApprovalReadyAt, id, buxSupplyCap - reserved);
    }

    /// @inheritdoc Ownable
    /// @notice Ownership can move (two-step) but never be renounced: Bux approval would be lost for good.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @inheritdoc IHookrEngagementReceiptSink
    /// @notice Credit selected programs from an authenticated swap after PoolManager relocks.
    function recordExecution(EngagementReceipt calldata r, uint256[] calldata ids) external nonReentrant {
        if (msg.sender != trustedRouter || IPoolManager(poolManager).isUnlocked()) revert Unauthorized();
        if (
            r.chainId != block.chainid || r.participant == address(0) || r.executionId == bytes32(0)
                || r.quoteVolume == 0 || r.quoteVolume > type(uint128).max || r.executedAt != block.timestamp
                || r.flowType != 0 || ids.length == 0 || ids.length > 8
        ) revert InvalidReceipt();
        emit ExecutionAccepted(r.executionId, r.participant, abi.encode(r));
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            Program storage p = _program(id);
            _enabled(p);
            if (
                (p.terms.mode != P.Mode.Immediate && p.terms.mode != P.Mode.DailySwap)
                    || block.timestamp < p.terms.start || block.timestamp >= p.terms.end
            ) revert NotReady();
            if (recorded[id][r.executionId]) revert Duplicate();
            uint256 index = _scopeIndex[id][_scopeKey(r.root, r.poolId, r.configHash, r.quoteAsset)];
            if (index == 0) revert InvalidScope();
            recorded[id][r.executionId] = true;
            if (p.terms.mode == P.Mode.DailySwap) {
                emit DailyActivityAccepted(id, (block.timestamp - p.terms.start) / DAY, r.executionId, r.participant);
                continue;
            }
            // Immediate programs hold no cash, Bux or milestones (validator), so a raw fill only moves points: the
            // points-only credit skips the cash ledger, Bux and milestone reads a general credit would make.
            P.Scope storage s = _scopes[id][--index];
            (uint256 weight, uint256 remainder) =
                _accrue(r.quoteVolume, s.numerator, s.denominator, _scopeCarry[id][r.participant][index]);
            _scopeCarry[id][r.participant][index] = remainder;
            (uint256 pointAward, uint256 pointCarry) =
                _accrue(weight, p.terms.pointNumerator, p.terms.pointDenominator, _pointCarry[id][r.participant]);
            _pointCarry[id][r.participant] = pointCarry;
            pointAward = _creditPoints(id, p, r.participant, pointAward);
            emit ActivityCredited(id, r.participant, weight, pointAward, 0);
        }
    }

    /// @inheritdoc IHookrPrograms
    function proposeDay(
        uint256 id,
        uint256 day,
        bytes32 root,
        uint256 totalWeight,
        bytes32 coverageHash,
        bytes32 evidenceHash
    ) external {
        Program storage p = _program(id);
        _enabled(p);
        uint256 end = dayEnd(id, day);
        if (
            msg.sender != p.terms.attestor || block.timestamp < end || coverageHash == bytes32(0)
                || evidenceHash == bytes32(0) || ((root == bytes32(0)) != (totalWeight == 0))
        ) revert NotReady();
        if (block.timestamp >= end + PROPOSAL_WINDOW) revert ProposalWindowClosed(id, day, end + PROPOSAL_WINDOW);
        Epoch storage e = _epochs[id][day];
        if (e.finalized || block.timestamp + p.terms.reviewDelay > type(uint64).max) revert NotReady();
        e.merkleRoot = root;
        e.totalWeight = totalWeight;
        e.coverageHash = coverageHash;
        e.evidenceHash = evidenceHash;
        e.finalizeAfter = uint64(block.timestamp + p.terms.reviewDelay);
        ++e.version;
        emit EpochProposed(id, day, e.version, root, totalWeight, coverageHash, evidenceHash, e.finalizeAfter);
    }

    /// @inheritdoc IHookrPrograms
    function challengeDay(uint256 id, uint256 day, bytes32 reasonHash) external {
        Program storage p = _program(id);
        Epoch storage e = _epochs[id][day];
        if (msg.sender != p.terms.reviewer || e.version == 0 || e.finalized || reasonHash == bytes32(0)) {
            revert NotReady();
        }
        e.challenged = true;
        emit EpochChallenged(id, day, reasonHash);
    }

    /// @inheritdoc IHookrPrograms
    function approveDay(uint256 id, uint256 day, uint64 version) external {
        Program storage p = _program(id);
        Epoch storage e = _epochs[id][day];
        if (msg.sender != p.terms.reviewer || e.finalized) revert NotReady();
        if (version == 0 || e.version != version) revert StaleVersion(id, day, e.version);
        e.challenged = false;
        emit DayApproved(id, day, version);
        _finalize(id, day, p, e);
    }

    /// @inheritdoc IHookrPrograms
    function finalizeDay(uint256 id, uint256 day) external {
        Program storage p = _program(id);
        Epoch storage e = _epochs[id][day];
        if (e.version == 0 || e.finalized || e.challenged || block.timestamp < e.finalizeAfter) revert NotReady();
        _finalize(id, day, p, e);
    }

    /// @inheritdoc IHookrPrograms
    function lapseDay(uint256 id, uint256 day) external {
        Program storage p = _program(id);
        _enabled(p);
        uint256 end = dayEnd(id, day);
        Epoch storage e = _epochs[id][day];
        if (
            e.finalized || block.timestamp < end + PROPOSAL_WINDOW
                || (e.version != 0 && (!e.challenged || block.timestamp < e.finalizeAfter))
        ) revert NotReady();
        e.finalized = true;
        e.merkleRoot = bytes32(0);
        e.totalWeight = 0;
        _closeDay(id, day, p, e);
        emit DayLapsed(id, day, e.version);
    }

    /// @inheritdoc IHookrPrograms
    function claimDay(uint256 id, uint256 day, address beneficiary, uint128 weight, bytes32[] calldata proof)
        external
        nonReentrant
    {
        Program storage p = _program(id);
        _enabled(p);
        Epoch storage e = _epochs[id][day];
        if (
            p.terms.mode == P.Mode.DailyReferral || !e.finalized || e.totalWeight == 0 || beneficiary == address(0)
                || weight == 0 || proof.length > 32
        ) revert InvalidProof();
        if (dayClaimed[id][day][beneficiary]) revert Duplicate();
        if (
            !MerkleProof.verifyCalldata(proof, e.merkleRoot, dayLeaf(id, day, beneficiary, weight))
                || weight > e.totalWeight - e.claimedWeight
        ) revert InvalidProof();
        dayClaimed[id][day][beneficiary] = true;
        e.claimedWeight += weight;
        uint256 pointAward = Math.mulDiv(p.terms.dailyPointBudget, weight, e.totalWeight);
        uint256 cashAward = Math.mulDiv(p.terms.dailyCashBudget, weight, e.totalWeight);
        (pointAward, cashAward) = _credit(id, beneficiary, pointAward, cashAward);
        e.pointsAllocated += pointAward;
        e.cashAllocated += cashAward;
        if (e.claimedWeight == e.totalWeight) _closeDay(id, day, p, e);
        emit DayClaimed(id, day, beneficiary, weight, pointAward, cashAward);
    }

    /// @inheritdoc IHookrPrograms
    function claimReferralDay(
        uint256 id,
        uint256 day,
        address payer,
        address referrer,
        uint64 firstActivityBlock,
        uint128 weight,
        bytes32[] calldata proof
    ) external nonReentrant {
        Program storage p = _program(id);
        _enabled(p);
        Epoch storage e = _epochs[id][day];
        if (
            p.terms.mode != P.Mode.DailyReferral || !e.finalized || e.totalWeight == 0 || weight == 0
                || proof.length > 32 || !referrals.eligible(referralProgramKey(id), payer, referrer, firstActivityBlock)
        ) revert InvalidProof();
        if (dayClaimed[id][day][payer]) revert Duplicate();
        if (
            !MerkleProof.verifyCalldata(
                    proof, e.merkleRoot, referralDayLeaf(id, day, payer, referrer, firstActivityBlock, weight)
                ) || weight > e.totalWeight - e.claimedWeight
        ) revert InvalidProof();
        dayClaimed[id][day][payer] = true;
        e.claimedWeight += weight;
        (uint256 pointAward,) = _credit(id, referrer, Math.mulDiv(p.terms.dailyPointBudget, weight, e.totalWeight), 0);
        e.pointsAllocated += pointAward;
        if (e.claimedWeight == e.totalWeight) _closeDay(id, day, p, e);
        emit ReferralDayClaimed(id, day, payer, referrer, weight, pointAward);
    }

    /// @inheritdoc IHookrPrograms
    function referralProgramKey(uint256 id) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), id, _program(id).termsHash));
    }

    /// @inheritdoc IHookrPrograms
    function referralDayLeaf(
        uint256 id,
        uint256 day,
        address payer,
        address referrer,
        uint64 firstActivityBlock,
        uint128 weight
    ) public view returns (bytes32) {
        Program storage p = _program(id);
        uint64 end = dayEnd(id, day);
        return keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(
                        block.chainid,
                        address(this),
                        id,
                        p.termsHash,
                        day,
                        uint64(end - DAY),
                        end,
                        _epochs[id][day].coverageHash,
                        payer,
                        referrer,
                        firstActivityBlock,
                        weight
                    )
                )
            )
        );
    }

    /// @inheritdoc IHookrPrograms
    function dayLeaf(uint256 id, uint256 day, address beneficiary, uint128 weight) public view returns (bytes32) {
        Program storage p = _program(id);
        uint64 end = dayEnd(id, day);
        return keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(
                        block.chainid,
                        address(this),
                        id,
                        p.termsHash,
                        day,
                        uint64(end - DAY),
                        end,
                        _epochs[id][day].coverageHash,
                        beneficiary,
                        weight
                    )
                )
            )
        );
    }

    /// @inheritdoc IHookrPrograms
    function dayEnd(uint256 id, uint256 day) public view returns (uint64) {
        P.Terms storage t = _program(id).terms;
        if (t.mode == P.Mode.Immediate || day >= (t.end - t.start) / DAY) revert InvalidProgram();
        return uint64(uint256(t.start) + (day + 1) * DAY);
    }

    /// @inheritdoc IHookrPrograms
    function claimCash(uint256 id, address beneficiary, address to, uint256 amount) external nonReentrant {
        _recipient(beneficiary, to);
        Program storage p = _program(id);
        uint256 available = claimableCash[id][beneficiary];
        if (amount == 0) amount = available;
        if (amount == 0 || amount > available) revert NothingToClaim();
        claimableCash[id][beneficiary] = available - amount;
        p.cashPaid += amount;
        _payout(id, p, to, amount, msg.sender == beneficiary);
        emit CashClaimed(id, beneficiary, to, amount);
    }

    /// @inheritdoc IHookrPrograms
    function claimNFT(uint256 id, address beneficiary, uint256 milestone, address to)
        external
        nonReentrant
        returns (bool)
    {
        _recipient(beneficiary, to);
        Program storage p = _program(id);
        return
            HookrProgramsAdmin.deliverMilestone(
                p, _milestones, reservedNFT, deliveredNFT, id, beneficiary, milestone, to
            );
    }

    /// @inheritdoc IHookrPrograms
    function releaseUnusedCash(uint256 id, uint256 day) external nonReentrant returns (uint256 amount) {
        Program storage p = _program(id);
        _enabled(p);
        dayEnd(id, day);
        Epoch storage e = _epochs[id][day];
        if (!e.closed || e.remainderReleased) revert NotReady();
        e.remainderReleased = true;
        amount = p.terms.dailyCashBudget - e.cashAllocated - released[id][day].cash;
        _refund(id, p, amount);
        emit UnusedCashReleased(id, day, amount);
    }

    /// @inheritdoc IHookrPrograms
    function releaseRemainder(uint256 id, uint256 day) external nonReentrant returns (uint256 cash, uint256 bux) {
        Program storage p = _program(id);
        _enabled(p);
        dayEnd(id, day);
        Epoch storage e = _epochs[id][day];
        if (!e.finalized || e.closed) revert NotReady();
        uint256 open = e.totalWeight - e.claimedWeight;
        Released storage r = released[id][day];
        cash = _unowed(p.terms.dailyCashBudget, e.cashAllocated + r.cash, open, e.totalWeight);
        if (p.buxApproved) bux = _unowed(p.terms.dailyPointBudget, e.pointsAllocated + r.bux, open, e.totalWeight);
        if (cash == 0 && bux == 0) revert NothingToClaim();
        r.cash += cash;
        r.bux += bux;
        buxReserved -= bux;
        _refund(id, p, cash);
        emit RemainderReleased(id, day, cash, bux);
    }

    /// @inheritdoc IHookrPrograms
    function setRefundRecipient(uint256 id, address to) external {
        if (msg.sender != _program(id).creator || to == address(this)) revert Unauthorized();
        refundRecipient[id] = to;
        emit RefundRecipientSet(id, to);
    }

    /// @inheritdoc IHookrPrograms
    function refundUnapprovedBux(uint256 id) external nonReentrant {
        Program storage p = _program(id);
        if (!p.terms.globalBux || p.buxApproved || p.cancelled || block.timestamp < p.terms.start) revert NotReady();
        p.cancelled = true;
        _refund(id, p, p.terms.cashBudget);
        emit UnusedCashReleased(id, 0, p.terms.cashBudget);
    }

    /// @inheritdoc IHookrPrograms
    function program(uint256 id) external view returns (Program memory) {
        return _program(id);
    }

    /// @inheritdoc IHookrPrograms
    function scopes(uint256 id) external view returns (P.Scope[] memory) {
        return _scopes[id];
    }

    /// @inheritdoc IHookrPrograms
    function milestones(uint256 id) external view returns (P.Milestone[] memory) {
        return _milestones[id];
    }

    /// @inheritdoc IHookrPrograms
    function epoch(uint256 id, uint256 day) external view returns (Epoch memory) {
        return _epochs[id][day];
    }

    /// @dev Credits `award` points, cut to the program's unissued point budget and the wallet's remaining cap. This is
    ///      an Immediate program's whole credit: the validator admits no cash, global Bux or milestones there.
    function _creditPoints(uint256 id, Program storage p, address user, uint256 award) private returns (uint256) {
        uint256 held = points[id][user];
        award = Math.min(award, Math.min(p.terms.pointBudget - p.pointsIssued, p.terms.walletPointCap - held));
        points[id][user] = held + award;
        p.pointsIssued += award;
        return award;
    }

    function _credit(uint256 id, address user, uint256 pointAward, uint256 cashAward)
        private
        returns (uint256, uint256)
    {
        Program storage p = _programs[id];
        pointAward = _creditPoints(id, p, user, pointAward);
        cashAward = Math.min(
            cashAward,
            Math.min(
                p.terms.cashBudget - p.cashAllocated - p.cashRefunded, p.terms.walletCashCap - cashAllocated[id][user]
            )
        );
        cashAllocated[id][user] += cashAward;
        claimableCash[id][user] += cashAward;
        p.cashAllocated += cashAward;
        if (p.terms.globalBux) {
            buxBalance[user] += pointAward;
            buxIssued += pointAward;
        }
        P.Milestone[] storage ms = _milestones[id];
        for (uint256 i; i < ms.length; ++i) {
            if (points[id][user] < ms[i].pointsRequired) break;
            if (reservedNFT[id][user][i] != 0 || milestoneAwards[id][i] >= ms[i].maxAwards) continue;
            ++milestoneAwards[id][i];
            uint256 tokenId = ++p.nextTokenId;
            reservedNFT[id][user][i] = tokenId;
            emit MilestoneReserved(id, user, i, tokenId);
        }
        return (pointAward, cashAward);
    }

    function _finalize(uint256 id, uint256 day, Program storage p, Epoch storage e) private {
        e.finalized = true;
        if (e.totalWeight == 0) _closeDay(id, day, p, e);
        emit EpochFinalized(id, day, e.version);
    }

    /// @dev Closing a day returns its unissued Bux allowance at once, so one open day pins only its own share.
    function _closeDay(uint256 id, uint256 day, Program storage p, Epoch storage e) private {
        e.closed = true;
        uint32 open = --p.openDays;
        if (p.buxApproved) {
            uint256 unused = p.terms.dailyPointBudget - e.pointsAllocated - released[id][day].bux;
            buxReserved -= unused;
            if (open == 0) p.buxReleased = true;
            emit BuxAllowanceReleased(id, unused);
        }
    }

    /// @dev Refunds come only from unallocated budget, once, and go to the creator's refund recipient.
    function _refund(uint256 id, Program storage p, uint256 amount) private {
        if (amount == 0) return;
        p.cashRefunded += amount;
        address to = refundRecipient[id];
        _payout(id, p, to == address(0) ? p.creator : to, amount, msg.sender == p.creator);
    }

    /// @dev budget - spent - the most `open` of `total` weight can still earn (floor, as each claim rounds down).
    function _unowed(uint256 budget, uint256 spent, uint256 open, uint256 total) private pure returns (uint256) {
        return budget - spent - Math.mulDiv(budget, open, total);
    }

    /// @dev Every cash outflow re-checks the program's own ledger, so an accounting error in one program can never
    ///      spend another program's reserved cash.
    function _payout(uint256 id, Program storage p, address to, uint256 amount, bool consent) private {
        if (p.cashPaid > p.cashAllocated || p.cashAllocated + p.cashRefunded > p.terms.cashBudget) {
            revert ProgramOverdrawn(id, amount);
        }
        _pay(p.terms.rewardToken, to, amount, consent);
    }

    function _validate(P.Terms calldata t) private view {
        if (t.mode == P.Mode.DailyReferral) {
            Program storage base = _program(t.baseProgramId);
            if (
                t.referralRegistry != address(referrals) || base.creator != msg.sender || base.cancelled
                    || base.terms.mode == P.Mode.DailyReferral || t.start < base.terms.start || t.end > base.terms.end
                    || t.cashBudget != 0
            ) revert InvalidProgram();
        } else if (t.referralRegistry != address(0) || t.baseProgramId != 0) {
            revert InvalidProgram();
        }
    }

    /// @dev Every created program has `end > start` (validator), so a zero `end` marks an id never created. The check
    ///      reads the first terms word, which most callers read next, rather than `creator`.
    function _program(uint256 id) private view returns (Program storage p) {
        p = _programs[id];
        if (p.terms.end == 0) revert InvalidProgram();
    }

    /// @dev Only a Bux program can be disabled: before its approval, or once its refund cancelled it. `cancelled` is
    ///      set only by refundUnapprovedBux, on a Bux program, so a program without Bux never reads its approval word.
    function _enabled(Program storage p) private view {
        if (p.terms.globalBux && (p.cancelled || !p.buxApproved)) revert Unauthorized();
    }

    function _scopeKey(address root, bytes32 poolId, bytes32 configHash, address quote) private pure returns (bytes32) {
        return keccak256(abi.encode(root, poolId, configHash, quote));
    }

    function _accrue(uint256 value, uint128 numerator, uint128 denominator, uint256 previous)
        private
        pure
        returns (uint256 whole, uint256 carry)
    {
        whole = Math.mulDiv(value, numerator, denominator);
        carry = mulmod(value, numerator, denominator) + previous;
        whole += carry / denominator;
        carry %= denominator;
    }

    function _recipient(address beneficiary, address to) private view {
        if (
            beneficiary == address(0) || to == address(0) || to == address(this)
                || (to != beneficiary && msg.sender != beneficiary)
        ) {
            revert Unauthorized();
        }
    }

    function _fund(address token, address from, uint256 amount) private {
        IERC20 a = IERC20(token);
        uint256 beforeBalance = a.balanceOf(address(this));
        uint256 payer = a.balanceOf(from);
        if (beforeBalance < reservedCash[token]) revert BudgetExceeded();
        a.safeTransferFrom(from, address(this), amount);
        if (a.balanceOf(address(this)) != beforeBalance + amount || a.balanceOf(from) != payer - amount) {
            revert InexactTransfer();
        }
        reservedCash[token] += amount;
    }

    /// @dev An issuer burn, clawback or negative rebase can leave the pooled balance below what is owed. The loss is
    ///      shared pro rata instead of freezing every program: the party owed may exit (`consent`) at held/owed, which
    ///      leaves that ratio unchanged for everyone else. A third party cannot trigger a haircut on someone else.
    function _pay(address token, address to, uint256 amount, bool consent) private {
        IERC20 a = IERC20(token);
        uint256 held = a.balanceOf(address(this));
        uint256 liability = reservedCash[token];
        uint256 paid = amount;
        if (held < liability) {
            paid = Math.mulDiv(amount, held, liability);
            if (!consent || paid == 0) revert CashShortfall(token, liability, held);
            emit ShortfallShared(token, to, amount, paid);
        }
        reservedCash[token] = liability - amount;
        uint256 recipient = a.balanceOf(to);
        a.safeTransfer(to, paid);
        if (a.balanceOf(address(this)) != held - paid || a.balanceOf(to) != recipient + paid) {
            revert InexactTransfer();
        }
    }
}
