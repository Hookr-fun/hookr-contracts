// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {HookrLaunchpad} from "./HookrLaunchpad.sol";
import {IHookrLockRewardsV1} from "./interfaces/IHookrLockRewardsV1.sol";
import {HookrTokenTransfer, IHookrUtilityToken} from "./libraries/HookrTokenTransfer.sol";

/// @title Hookr Launch Boost V1
/// @notice Creator-funded, non-slashable $HOOKR locks for a separately labelled Boosted rail.
/// @dev The contract never edits Hookr's organic Discover ordering. When a precommitted Lock
///      Rewards cohort exists, 1% of each deposit is forwarded atomically to that cohort's current
///      weekly fee ledger and the remaining 99% is refundable principal. Without eligible lockers,
///      the fee is waived rather than held for a future cohort.
contract HookrLaunchBoostV1 {
    using HookrTokenTransfer for IHookrUtilityToken;

    uint256 internal constant BPS = 10_000;
    uint32 internal constant MAX_REWARD_CHECKPOINT_EPOCHS = 64;

    uint16 public constant BOOST_FEE_BPS = 100; // 1%
    uint256 public constant MIN_GROSS_BOOST = 100 ether;
    /// @notice Maximum number of concurrently enumerated Boost positions.
    uint16 public constant MAX_ACTIVE_BOOSTS = 512;

    IHookrUtilityToken public immutable hookrToken;
    HookrLaunchpad public immutable launchpad;
    IHookrLockRewardsV1 public immutable lockRewards;

    struct BoostPosition {
        address creator;
        uint128 principal;
        uint40 startedAt;
        uint40 unlockAt;
        uint40 startedAtBlock;
        uint8 tier;
    }

    mapping(address token => BoostPosition position) internal boosts;
    /// @notice One-based active-registry index, or zero after pruning/withdrawal.
    mapping(address token => uint16 indexPlusOne) public boostedTokenIndexPlusOne;
    address[] internal boostedTokens;

    uint256 public totalBoostPrincipal;
    uint256 public cumulativeGrossBoosted;
    uint256 public cumulativePrincipalAdded;
    uint256 public cumulativeFeesForwarded;

    uint256 private reentrancyState = 1;

    event BoostDeposited(
        address indexed token,
        address indexed creator,
        uint256 grossAmount,
        uint256 principalAdded,
        uint256 rewardFee,
        bool feeApplied,
        uint256 totalPrincipal,
        uint8 tier,
        uint16 multiplierBps,
        uint40 unlockAt,
        uint256 score
    );
    event BoostExtended(
        address indexed token,
        address indexed creator,
        uint8 oldTier,
        uint8 newTier,
        uint40 oldUnlockAt,
        uint40 newUnlockAt,
        uint256 score
    );
    event BoostWithdrawn(address indexed token, address indexed creator, address indexed to, uint256 principal);
    event BoostPruned(
        address indexed token, address indexed creator, address indexed pruner, uint256 principal, uint40 unlockAt
    );

    error ZeroAddress();
    error ZeroAmount();
    error GrossAmountBelowMinimum(uint256 grossAmount, uint256 minimum);
    error CapacityFull(uint256 capacity);
    error DeadlineExpired();
    error UnknownLaunch();
    error NotLaunchCreator();
    error NoBoost();
    error BoostNotRegistered(address token);
    error BoostExpiredMustWithdraw();
    error BoostStillLocked(uint40 unlockAt);
    error TierCannotDecrease();
    error NoExtension();
    error UnlockAtAboveMaximum(uint40 unlockAt, uint40 maxUnlockAt);
    error VaultCheckpointRequired(uint32 checkpointEpoch, uint32 currentEpoch);
    error RewardFeeAboveMaximum(uint256 rewardFee, uint256 maxRewardFee);
    error PrincipalBelowMinimum(uint256 principalAdded, uint256 minPrincipalAdded);
    error AccountingInvariant();
    error ReentrantCall();

    modifier nonReentrant() {
        if (reentrancyState != 1) revert ReentrantCall();
        reentrancyState = 2;
        _;
        reentrancyState = 1;
    }

    constructor(IHookrUtilityToken hookrToken_, HookrLaunchpad launchpad_, IHookrLockRewardsV1 lockRewards_) {
        if (
            address(hookrToken_) == address(0) || address(hookrToken_).code.length == 0
                || address(launchpad_) == address(0) || address(launchpad_).code.length == 0
                || address(lockRewards_) == address(0) || address(lockRewards_).code.length == 0
        ) revert ZeroAddress();
        hookrToken = hookrToken_;
        launchpad = launchpad_;
        lockRewards = lockRewards_;
    }

    function contractName() external pure returns (string memory) {
        return "HookrLaunchBoost";
    }

    function contractVersion() external pure returns (string memory) {
        return "1";
    }

    function previewBoost(uint256 grossAmount, uint8 tier)
        external
        view
        returns (
            uint256 rewardFee,
            uint256 principalAdded,
            uint256 positionScore,
            uint40 durationSeconds,
            uint16 multiplierBps,
            bool feeWouldApply,
            bool rewardCheckpointCurrent
        )
    {
        (durationSeconds, multiplierBps) = lockRewards.tierConfig(tier);
        rewardCheckpointCurrent = lockRewards.checkpointEpoch() == lockRewards.currentEpoch();
        feeWouldApply = rewardCheckpointCurrent && lockRewards.currentEligibleWeight() != 0;
        if (feeWouldApply && grossAmount != 0) {
            rewardFee = FullMath.mulDivRoundingUp(grossAmount, BOOST_FEE_BPS, BPS);
        }
        principalAdded = grossAmount - rewardFee;
        positionScore = FullMath.mulDiv(principalAdded, multiplierBps, BPS);
    }

    function boost(
        address token,
        uint256 grossAmount,
        uint8 tier,
        uint256 maxRewardFee,
        uint256 minPrincipalAdded,
        uint256 deadline
    ) external nonReentrant returns (uint256 principalAdded, uint256 rewardFee) {
        return _boost(token, msg.sender, grossAmount, tier, maxRewardFee, minPrincipalAdded, deadline);
    }

    function boostWithPermit(
        address token,
        uint256 grossAmount,
        uint8 tier,
        uint256 maxRewardFee,
        uint256 minPrincipalAdded,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 principalAdded, uint256 rewardFee) {
        hookrToken.permitIfNeeded(msg.sender, address(this), grossAmount, deadline, v, r, s);
        return _boost(token, msg.sender, grossAmount, tier, maxRewardFee, minPrincipalAdded, deadline);
    }

    function boostByIntent(
        bytes32 intentId,
        uint256 grossAmount,
        uint8 tier,
        uint256 maxRewardFee,
        uint256 minPrincipalAdded,
        uint256 deadline
    ) external nonReentrant returns (address token, uint256 principalAdded, uint256 rewardFee) {
        token = launchpad.launchedByIntent(msg.sender, intentId);
        (principalAdded, rewardFee) =
            _boost(token, msg.sender, grossAmount, tier, maxRewardFee, minPrincipalAdded, deadline);
    }

    function boostByIntentWithPermit(
        bytes32 intentId,
        uint256 grossAmount,
        uint8 tier,
        uint256 maxRewardFee,
        uint256 minPrincipalAdded,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (address token, uint256 principalAdded, uint256 rewardFee) {
        hookrToken.permitIfNeeded(msg.sender, address(this), grossAmount, deadline, v, r, s);
        token = launchpad.launchedByIntent(msg.sender, intentId);
        (principalAdded, rewardFee) =
            _boost(token, msg.sender, grossAmount, tier, maxRewardFee, minPrincipalAdded, deadline);
    }

    function _boost(
        address token,
        address creator,
        uint256 grossAmount,
        uint8 tier,
        uint256 maxRewardFee,
        uint256 minPrincipalAdded,
        uint256 deadline
    ) internal returns (uint256 principalAdded, uint256 rewardFee) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (grossAmount < MIN_GROSS_BOOST) revert GrossAmountBelowMinimum(grossAmount, MIN_GROSS_BOOST);
        if (grossAmount > type(uint128).max) revert ZeroAmount();
        _validateCreator(token, creator);

        BoostPosition storage p = boosts[token];
        bool newPosition = p.principal == 0;
        if (newPosition) {
            if (boostedTokenIndexPlusOne[token] != 0) revert AccountingInvariant();
            if (boostedTokens.length >= MAX_ACTIVE_BOOSTS) revert CapacityFull(MAX_ACTIVE_BOOSTS);
        } else {
            if (p.creator != creator) revert NotLaunchCreator();
            if (boostedTokenIndexPlusOne[token] == 0 || block.timestamp >= p.unlockAt) {
                revert BoostExpiredMustWithdraw();
            }
            if (tier < p.tier) revert TierCannotDecrease();
        }

        lockRewards.checkpoint(MAX_REWARD_CHECKPOINT_EPOCHS);
        uint32 checkpointed = lockRewards.checkpointEpoch();
        uint32 current = lockRewards.currentEpoch();
        if (checkpointed != current) revert VaultCheckpointRequired(checkpointed, current);
        bool feeApplied = lockRewards.currentEligibleWeight() != 0;

        (uint40 duration, uint16 multiplierBps) = lockRewards.tierConfig(tier);

        if (feeApplied) {
            rewardFee = FullMath.mulDivRoundingUp(grossAmount, BOOST_FEE_BPS, BPS);
        }
        principalAdded = grossAmount - rewardFee;
        if (rewardFee > maxRewardFee) revert RewardFeeAboveMaximum(rewardFee, maxRewardFee);
        if (principalAdded < minPrincipalAdded) {
            revert PrincipalBelowMinimum(principalAdded, minPrincipalAdded);
        }
        if (principalAdded == 0) revert ZeroAmount();

        hookrToken.pullExact(creator, grossAmount);

        if (feeApplied) {
            hookrToken.safeTransfer(address(lockRewards), rewardFee);
            lockRewards.notifyBoostFee(rewardFee);
            cumulativeFeesForwarded += rewardFee;
        }

        uint256 newPrincipal = uint256(p.principal) + principalAdded;
        if (newPrincipal > type(uint128).max) revert AccountingInvariant();
        uint256 rawUnlock = block.timestamp + duration;
        if (rawUnlock > type(uint40).max) revert AccountingInvariant();
        // Safe after the explicit uint40 upper bound above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 candidateUnlock = uint40(rawUnlock);

        if (newPosition) {
            p.creator = creator;
            p.startedAt = uint40(block.timestamp);
            p.startedAtBlock = uint40(block.number);
            p.unlockAt = candidateUnlock;
            p.tier = tier;
            _registerBoostedToken(token);
        } else {
            if (candidateUnlock > p.unlockAt) p.unlockAt = candidateUnlock;
            p.tier = tier;
        }
        // Safe after the explicit uint128 upper bound above.
        // forge-lint: disable-next-line(unsafe-typecast)
        p.principal = uint128(newPrincipal);

        totalBoostPrincipal += principalAdded;
        cumulativeGrossBoosted += grossAmount;
        cumulativePrincipalAdded += principalAdded;

        uint256 score = FullMath.mulDiv(newPrincipal, multiplierBps, BPS);
        emit BoostDeposited(
            token,
            creator,
            grossAmount,
            principalAdded,
            rewardFee,
            feeApplied,
            newPrincipal,
            tier,
            multiplierBps,
            p.unlockAt,
            score
        );
    }

    function extend(address token, uint8 newTier, uint40 maxUnlockAt, uint256 deadline)
        external
        nonReentrant
        returns (uint40 unlockAt)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        _validateCreator(token, msg.sender);
        BoostPosition storage p = boosts[token];
        if (p.principal == 0) revert NoBoost();
        if (p.creator != msg.sender) revert NotLaunchCreator();
        if (block.timestamp >= p.unlockAt) revert BoostExpiredMustWithdraw();
        if (newTier < p.tier) revert TierCannotDecrease();

        (uint40 duration, uint16 multiplierBps) = lockRewards.tierConfig(newTier);
        uint256 rawUnlock = block.timestamp + duration;
        if (rawUnlock > type(uint40).max) revert AccountingInvariant();
        // Safe after the explicit uint40 upper bound above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 candidateUnlock = uint40(rawUnlock);
        if (candidateUnlock > maxUnlockAt) revert UnlockAtAboveMaximum(candidateUnlock, maxUnlockAt);
        if (candidateUnlock <= p.unlockAt && newTier == p.tier) revert NoExtension();

        uint8 oldTier = p.tier;
        uint40 oldUnlock = p.unlockAt;
        if (candidateUnlock > p.unlockAt) p.unlockAt = candidateUnlock;
        p.tier = newTier;
        unlockAt = p.unlockAt;

        uint256 score = FullMath.mulDiv(uint256(p.principal), multiplierBps, BPS);
        emit BoostExtended(token, msg.sender, oldTier, newTier, oldUnlock, unlockAt, score);
    }

    function withdraw(address token, address to) external nonReentrant returns (uint256 principal) {
        if (to == address(0)) revert ZeroAddress();
        BoostPosition storage p = boosts[token];
        if (p.principal == 0) revert NoBoost();
        if (p.creator != msg.sender) revert NotLaunchCreator();
        if (block.timestamp < p.unlockAt) revert BoostStillLocked(p.unlockAt);

        principal = p.principal;
        totalBoostPrincipal -= principal;
        _removeBoostedToken(token);
        delete boosts[token];
        hookrToken.safeTransfer(to, principal);
        emit BoostWithdrawn(token, msg.sender, to, principal);
    }

    /// @notice Remove an expired position from active enumeration without touching its custody state.
    /// @dev Principal, creator, tier, timestamps, liabilities and withdrawal rights are unchanged.
    function pruneExpired(address token) external nonReentrant returns (bool removed) {
        BoostPosition storage p = boosts[token];
        if (p.principal == 0) revert NoBoost();
        if (block.timestamp < p.unlockAt) revert BoostStillLocked(p.unlockAt);
        if (boostedTokenIndexPlusOne[token] == 0) revert BoostNotRegistered(token);

        removed = _removeBoostedToken(token);
        if (!removed) revert AccountingInvariant();
        emit BoostPruned(token, p.creator, msg.sender, p.principal, p.unlockAt);
    }

    function boostOf(address token) external view returns (BoostPosition memory) {
        return boosts[token];
    }

    function scoreOf(address token) public view returns (uint256 score) {
        BoostPosition storage p = boosts[token];
        if (p.principal == 0 || block.timestamp >= p.unlockAt) return 0;
        (, uint16 multiplierBps) = lockRewards.tierConfig(p.tier);
        score = FullMath.mulDiv(uint256(p.principal), multiplierBps, BPS);
    }

    function activePrincipalOf(address token) external view returns (uint256) {
        BoostPosition storage p = boosts[token];
        return p.principal != 0 && block.timestamp < p.unlockAt ? p.principal : 0;
    }

    function boostedTokensCount() external view returns (uint256) {
        return boostedTokens.length;
    }

    function isBoostRegistered(address token) external view returns (bool) {
        return boostedTokenIndexPlusOne[token] != 0;
    }

    /// @notice Page the bounded active registry; token address, not array index, is the stable identity.
    /// @dev Expired entries remain visible until pruned. Swap-removal can change ordering between reads.
    function boostedTokensPage(uint256 offset, uint256 limit) external view returns (address[] memory page) {
        uint256 n = boostedTokens.length;
        if (offset >= n || limit == 0) return new address[](0);
        uint256 count = n - offset < limit ? n - offset : limit;
        page = new address[](count);
        for (uint256 i; i < count; ++i) {
            page[i] = boostedTokens[offset + i];
        }
    }

    function _registerBoostedToken(address token) internal {
        if (boostedTokenIndexPlusOne[token] != 0 || boostedTokens.length >= MAX_ACTIVE_BOOSTS) {
            revert AccountingInvariant();
        }
        boostedTokens.push(token);
        // Safe because the array is capped at MAX_ACTIVE_BOOSTS, which fits uint16.
        // forge-lint: disable-next-line(unsafe-typecast)
        boostedTokenIndexPlusOne[token] = uint16(boostedTokens.length);
    }

    function _removeBoostedToken(address token) internal returns (bool removed) {
        uint256 indexPlusOne = boostedTokenIndexPlusOne[token];
        if (indexPlusOne == 0) return false;

        uint256 length = boostedTokens.length;
        uint256 index = indexPlusOne - 1;
        if (index >= length || boostedTokens[index] != token) revert AccountingInvariant();
        uint256 lastIndex = length - 1;
        if (index != lastIndex) {
            address movedToken = boostedTokens[lastIndex];
            if (boostedTokenIndexPlusOne[movedToken] != lastIndex + 1) revert AccountingInvariant();
            boostedTokens[index] = movedToken;
            // Safe because the array is capped at MAX_ACTIVE_BOOSTS, which fits uint16.
            // forge-lint: disable-next-line(unsafe-typecast)
            boostedTokenIndexPlusOne[movedToken] = uint16(index + 1);
        }

        boostedTokens.pop();
        delete boostedTokenIndexPlusOne[token];
        removed = true;
    }

    function _validateCreator(address token, address caller) internal view {
        if (token == address(0)) revert UnknownLaunch();
        HookrLaunchpad.Launch memory launch = launchpad.getLaunch(token);
        if (launch.token != token) revert UnknownLaunch();
        if (launch.creator != caller) revert NotLaunchCreator();
    }

    function solvency()
        external
        view
        returns (uint256 balance, uint256 principalLiability, uint256 surplus, bool solvent)
    {
        balance = hookrToken.balanceOf(address(this));
        principalLiability = totalBoostPrincipal;
        solvent = balance >= principalLiability;
        if (solvent) surplus = balance - principalLiability;
    }
}
