// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {HookrTokenTransfer, IHookrUtilityToken} from "./libraries/HookrTokenTransfer.sol";

/// @title Hookr Lock Rewards V3
/// @notice Non-transferable, fixed-term $HOOKR locks that receive realized Launch Boost fees.
/// @dev The first two epochs are immutable two-hour bootstrap epochs. Epoch two bridges to the
///      first later Monday 00:00 UTC boundary, after which epochs are regular weeks. Positions
///      still activate only at the next boundary and earn only for complete epochs. The sole
///      reward source is wired once after deployment; there is no owner, pause, upgrade or sweep.
contract HookrLockRewardsV3 {
    using HookrTokenTransfer for IHookrUtilityToken;

    uint256 internal constant Q128 = 1 << 128;
    uint256 internal constant BPS = 10_000;

    uint40 public constant EPOCH_LENGTH = 7 days;
    uint40 public constant BOOTSTRAP_EPOCH_LENGTH = 2 hours;
    // 1970-01-05 00:00:00 UTC, the first Monday after the Unix epoch.
    uint40 public constant MONDAY_EPOCH_OFFSET = 4 days;
    uint32 public constant FIRST_WEEKLY_EPOCH = 3;
    uint32 public constant MAX_AUTO_CHECKPOINT_EPOCHS = 64;

    uint8 public constant TIER_30_DAYS = 0;
    uint8 public constant TIER_90_DAYS = 1;
    uint8 public constant TIER_180_DAYS = 2;

    IHookrUtilityToken public immutable hookrToken;
    uint40 public immutable bootstrapStartedAt;
    uint40 public immutable feeEpochStartsAt;
    uint40 public immutable claimEpochStartsAt;
    uint40 public immutable weeklyEpochsStartAt;

    /// @notice Temporary one-shot deployment authority; becomes zero after reward-source wiring.
    address public configurator;
    /// @notice The only contract allowed to report already-transferred Launch Boost fees.
    address public rewardSource;

    struct Position {
        address owner;
        uint128 principal;
        uint128 weight;
        uint40 unlockAt;
        uint32 activationEpoch;
        uint32 expiryEpoch;
        uint32 lastClaimEpoch;
        uint8 tier;
        bool withdrawn;
    }

    Position[] internal positions;
    mapping(address owner => uint256[] ids) internal ownerPositionIds;

    /// @notice The first not-yet-processed epoch. Eligible weight describes this epoch.
    uint32 public checkpointEpoch;
    uint256 public currentEligibleWeight;
    uint256 public cumulativeRewardPerWeightX128;
    uint256 public roundingCarry;

    mapping(uint32 epoch => uint256 amount) public boostFeesByEpoch;
    mapping(uint32 epoch => uint256 weight) public scheduledWeightAdds;
    mapping(uint32 epoch => uint256 weight) public scheduledWeightRemovals;
    /// @notice Cumulative reward index at the start of an epoch.
    mapping(uint32 epoch => uint256 index) public rewardIndexAtEpoch;

    uint256 public totalLockedPrincipal;
    uint256 public rewardReserve;
    uint256 public cumulativeBoostFeesNotified;
    uint256 public cumulativeRewardsClaimed;

    uint256 private reentrancyState = 1;

    event RewardSourceSet(address indexed source);
    event Locked(
        uint256 indexed positionId,
        address indexed owner,
        uint256 principal,
        uint8 tier,
        uint16 multiplierBps,
        uint32 activationEpoch,
        uint32 expiryEpoch,
        uint40 unlockAt,
        uint256 weight
    );
    event BoostFeeNotified(address indexed source, uint32 indexed epoch, uint256 amount);
    event EpochCheckpointed(
        uint32 indexed epoch, uint256 boostFees, uint256 eligibleWeight, uint256 indexDeltaX128, uint256 roundingCarry
    );
    event RewardsClaimed(uint256 indexed positionId, address indexed owner, address indexed to, uint256 amount);
    event Withdrawn(
        uint256 indexed positionId, address indexed owner, address indexed to, uint256 principal, uint256 reward
    );

    error ZeroAddress();
    error ZeroAmount();
    error InvalidTier();
    error DeadlineExpired();
    error ActivationEpochAboveMaximum(uint32 activationEpoch, uint32 maxActivationEpoch);
    error UnlockAtAboveMaximum(uint40 unlockAt, uint40 maxUnlockAt);
    error NotConfigurator();
    error RewardSourceAlreadySet();
    error NotRewardSource();
    error NoEligibleWeight();
    error CheckpointRequired(uint32 checkpointEpoch, uint32 currentEpoch);
    error UnknownPosition();
    error NotPositionOwner();
    error PositionWithdrawn();
    error PositionStillLocked(uint40 unlockAt);
    error NothingToClaim();
    error AccountingInvariant();
    error ReentrantCall();

    modifier nonReentrant() {
        if (reentrancyState != 1) revert ReentrantCall();
        reentrancyState = 2;
        _;
        reentrancyState = 1;
    }

    constructor(IHookrUtilityToken hookrToken_, address configurator_) {
        if (address(hookrToken_) == address(0) || address(hookrToken_).code.length == 0) revert ZeroAddress();
        if (configurator_ == address(0)) revert ZeroAddress();
        hookrToken = hookrToken_;
        configurator = configurator_;

        uint256 start = block.timestamp;
        uint256 feeStart = start + BOOTSTRAP_EPOCH_LENGTH;
        uint256 claimStart = feeStart + BOOTSTRAP_EPOCH_LENGTH;
        if (claimStart > type(uint40).max) revert AccountingInvariant();

        uint256 weeklyNumber = (claimStart - MONDAY_EPOCH_OFFSET) / EPOCH_LENGTH + 1;
        uint256 weeklyStart = uint256(MONDAY_EPOCH_OFFSET) + weeklyNumber * EPOCH_LENGTH;
        if (weeklyStart > type(uint40).max || weeklyStart <= claimStart) revert AccountingInvariant();

        // Safe after the explicit uint40 upper bounds above.
        // forge-lint: disable-next-line(unsafe-typecast)
        bootstrapStartedAt = uint40(start);
        // forge-lint: disable-next-line(unsafe-typecast)
        feeEpochStartsAt = uint40(feeStart);
        // forge-lint: disable-next-line(unsafe-typecast)
        claimEpochStartsAt = uint40(claimStart);
        // forge-lint: disable-next-line(unsafe-typecast)
        weeklyEpochsStartAt = uint40(weeklyStart);

        checkpointEpoch = 0;
        rewardIndexAtEpoch[0] = 0;

        // Position ids start at one so a zero id is never a valid postcondition.
        positions.push();
    }

    function contractName() external pure returns (string memory) {
        return "HookrLockRewards";
    }

    function contractVersion() external pure returns (string memory) {
        return "3";
    }

    function setRewardSourceOnce(address source) external {
        if (msg.sender != configurator) revert NotConfigurator();
        if (rewardSource != address(0)) revert RewardSourceAlreadySet();
        if (source == address(0) || source.code.length == 0) revert ZeroAddress();
        rewardSource = source;
        configurator = address(0);
        emit RewardSourceSet(source);
    }

    function tierConfig(uint8 tier) public pure returns (uint40 durationSeconds, uint16 multiplierBps) {
        if (tier == TIER_30_DAYS) return (30 days, 10_000);
        if (tier == TIER_90_DAYS) return (90 days, 11_500);
        if (tier == TIER_180_DAYS) return (180 days, 12_500);
        revert InvalidTier();
    }

    function currentEpoch() public view returns (uint32 epoch) {
        uint256 timestamp = block.timestamp;
        if (timestamp < feeEpochStartsAt) return 0;
        if (timestamp < claimEpochStartsAt) return 1;
        if (timestamp < weeklyEpochsStartAt) return 2;

        uint256 raw = FIRST_WEEKLY_EPOCH + (timestamp - weeklyEpochsStartAt) / EPOCH_LENGTH;
        if (raw > type(uint32).max) revert AccountingInvariant();
        // Safe after the explicit uint32 upper bound above.
        // forge-lint: disable-next-line(unsafe-typecast)
        epoch = uint32(raw);
    }

    function epochStart(uint32 epoch) public view returns (uint40 timestamp) {
        if (epoch == 0) return bootstrapStartedAt;
        if (epoch == 1) return feeEpochStartsAt;
        if (epoch == 2) return claimEpochStartsAt;

        uint256 raw = uint256(weeklyEpochsStartAt) + uint256(epoch - FIRST_WEEKLY_EPOCH) * EPOCH_LENGTH;
        if (raw > type(uint40).max) revert AccountingInvariant();
        // Safe after the explicit uint40 upper bound above.
        // forge-lint: disable-next-line(unsafe-typecast)
        timestamp = uint40(raw);
    }

    function epochAt(uint40 timestamp) public view returns (uint32 epoch) {
        if (timestamp < bootstrapStartedAt) revert AccountingInvariant();
        if (timestamp < feeEpochStartsAt) return 0;
        if (timestamp < claimEpochStartsAt) return 1;
        if (timestamp < weeklyEpochsStartAt) return 2;

        uint256 raw = FIRST_WEEKLY_EPOCH + (uint256(timestamp) - weeklyEpochsStartAt) / EPOCH_LENGTH;
        if (raw > type(uint32).max) revert AccountingInvariant();
        // Safe after the explicit uint32 upper bound above.
        // forge-lint: disable-next-line(unsafe-typecast)
        epoch = uint32(raw);
    }

    function checkpointCurrent() public view returns (bool) {
        return checkpointEpoch == currentEpoch();
    }

    /// @notice Permissionlessly settle at most maxEpochs completed epochs.
    /// @return processedThroughEpoch The first epoch not yet processed after this call.
    function checkpoint(uint32 maxEpochs) public returns (uint32 processedThroughEpoch) {
        uint32 target = currentEpoch();
        uint32 cursor = checkpointEpoch;
        uint32 processed;

        while (cursor < target && processed < maxEpochs) {
            uint256 fees = boostFeesByEpoch[cursor];
            delete boostFeesByEpoch[cursor];

            uint256 eligibleWeight = currentEligibleWeight;
            uint256 indexDelta;
            if (fees != 0 && eligibleWeight != 0) {
                indexDelta = FullMath.mulDiv(fees, Q128, eligibleWeight);
                uint256 globallyAllocated = FullMath.mulDiv(indexDelta, eligibleWeight, Q128);
                // Dust stays inside rewardReserve and is never indexed twice.
                roundingCarry += fees - globallyAllocated;
                cumulativeRewardPerWeightX128 += indexDelta;
            } else {
                // notifyBoostFee refuses a zero denominator. This branch is defensive for a
                // corrupted/migrated history and still refuses to allocate fees to future lockers.
                roundingCarry += fees;
            }

            uint32 completedEpoch = cursor;
            unchecked {
                cursor += 1;
                processed += 1;
            }
            rewardIndexAtEpoch[cursor] = cumulativeRewardPerWeightX128;

            uint256 removeWeight = scheduledWeightRemovals[cursor];
            uint256 addWeight = scheduledWeightAdds[cursor];
            delete scheduledWeightRemovals[cursor];
            delete scheduledWeightAdds[cursor];
            if (removeWeight > currentEligibleWeight) revert AccountingInvariant();
            currentEligibleWeight = currentEligibleWeight - removeWeight + addWeight;
            checkpointEpoch = cursor;

            emit EpochCheckpointed(completedEpoch, fees, eligibleWeight, indexDelta, roundingCarry);
        }

        processedThroughEpoch = checkpointEpoch;
    }

    function previewLock(uint256 amount, uint8 tier)
        external
        view
        returns (uint256 weight, uint32 activationEpoch, uint32 expiryEpoch, uint40 unlockAt, uint16 multiplierBps)
    {
        (uint40 duration, uint16 multiplier) = tierConfig(tier);
        uint256 rawUnlock = block.timestamp + duration;
        if (rawUnlock > type(uint40).max) revert AccountingInvariant();
        // Safe after the explicit uint40 upper bound above.
        // forge-lint: disable-next-line(unsafe-typecast)
        unlockAt = uint40(rawUnlock);
        activationEpoch = currentEpoch() + 1;
        expiryEpoch = epochAt(unlockAt);
        multiplierBps = multiplier;
        weight = FullMath.mulDiv(amount, multiplier, BPS);
    }

    function lock(uint256 amount, uint8 tier, uint32 maxActivationEpoch, uint40 maxUnlockAt, uint256 deadline)
        external
        nonReentrant
        returns (uint256 positionId)
    {
        positionId = _lock(msg.sender, amount, tier, maxActivationEpoch, maxUnlockAt, deadline);
    }

    function lockWithPermit(
        uint256 amount,
        uint8 tier,
        uint32 maxActivationEpoch,
        uint40 maxUnlockAt,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 positionId) {
        hookrToken.permitIfNeeded(msg.sender, address(this), amount, deadline, v, r, s);
        positionId = _lock(msg.sender, amount, tier, maxActivationEpoch, maxUnlockAt, deadline);
    }

    function _lock(
        address owner,
        uint256 amount,
        uint8 tier,
        uint32 maxActivationEpoch,
        uint40 maxUnlockAt,
        uint256 deadline
    ) internal returns (uint256 positionId) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (amount == 0 || amount > type(uint128).max) revert ZeroAmount();
        _requireCheckpointed();

        (uint40 duration, uint16 multiplierBps) = tierConfig(tier);
        uint256 rawUnlock = block.timestamp + duration;
        if (rawUnlock > type(uint40).max) revert AccountingInvariant();
        // Safe after the explicit uint40 upper bound above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 unlockAt = uint40(rawUnlock);
        uint32 activationEpoch = currentEpoch() + 1;
        uint32 expiryEpoch = epochAt(unlockAt);
        if (expiryEpoch <= activationEpoch) revert AccountingInvariant();
        if (activationEpoch > maxActivationEpoch) {
            revert ActivationEpochAboveMaximum(activationEpoch, maxActivationEpoch);
        }
        if (unlockAt > maxUnlockAt) revert UnlockAtAboveMaximum(unlockAt, maxUnlockAt);

        uint256 weight = FullMath.mulDiv(amount, multiplierBps, BPS);
        if (weight == 0 || weight > type(uint128).max) revert ZeroAmount();

        hookrToken.pullExact(owner, amount);

        scheduledWeightAdds[activationEpoch] += weight;
        scheduledWeightRemovals[expiryEpoch] += weight;
        totalLockedPrincipal += amount;

        positionId = positions.length;
        positions.push(
            Position({
                owner: owner,
                // Safe because amount was bounded to uint128 before the token pull.
                // forge-lint: disable-next-line(unsafe-typecast)
                principal: uint128(amount),
                // Safe because weight was bounded to uint128 before the token pull.
                // forge-lint: disable-next-line(unsafe-typecast)
                weight: uint128(weight),
                unlockAt: unlockAt,
                activationEpoch: activationEpoch,
                expiryEpoch: expiryEpoch,
                lastClaimEpoch: activationEpoch,
                tier: tier,
                withdrawn: false
            })
        );
        ownerPositionIds[owner].push(positionId);

        emit Locked(positionId, owner, amount, tier, multiplierBps, activationEpoch, expiryEpoch, unlockAt, weight);
    }

    /// @notice Record a fee already transferred by the one-shot configured Launch Boost source.
    function notifyBoostFee(uint256 amount) external {
        if (msg.sender != rewardSource) revert NotRewardSource();
        if (amount == 0) revert ZeroAmount();
        _requireCheckpointed();
        if (currentEligibleWeight == 0) revert NoEligibleWeight();

        uint256 requiredBalance = totalLockedPrincipal + rewardReserve + amount;
        if (hookrToken.balanceOf(address(this)) < requiredBalance) revert AccountingInvariant();

        uint32 epoch = currentEpoch();
        boostFeesByEpoch[epoch] += amount;
        rewardReserve += amount;
        cumulativeBoostFeesNotified += amount;
        emit BoostFeeNotified(msg.sender, epoch, amount);
    }

    function positionCount() external view returns (uint256) {
        return positions.length - 1;
    }

    function position(uint256 positionId) external view returns (Position memory) {
        return _position(positionId);
    }

    function positionsOfCount(address owner) external view returns (uint256) {
        return ownerPositionIds[owner].length;
    }

    function positionsOf(address owner, uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        uint256 n = ownerPositionIds[owner].length;
        if (offset >= n || limit == 0) return new uint256[](0);
        uint256 count = n - offset < limit ? n - offset : limit;
        ids = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            ids[i] = ownerPositionIds[owner][offset + i];
        }
    }

    function settledClaimable(uint256 positionId) public view returns (uint256 reward) {
        Position storage p = _positionStorage(positionId);
        if (p.withdrawn) return 0;
        uint32 endEpoch = checkpointEpoch < p.expiryEpoch ? checkpointEpoch : p.expiryEpoch;
        if (endEpoch <= p.lastClaimEpoch) return 0;
        uint256 indexDelta = rewardIndexAtEpoch[endEpoch] - rewardIndexAtEpoch[p.lastClaimEpoch];
        reward = FullMath.mulDiv(uint256(p.weight), indexDelta, Q128);
    }

    function claim(uint256 positionId, address to) external nonReentrant returns (uint256 reward) {
        if (to == address(0)) revert ZeroAddress();
        _requireCheckpointed();
        Position storage p = _positionStorage(positionId);
        if (p.owner != msg.sender) revert NotPositionOwner();
        if (p.withdrawn) revert PositionWithdrawn();

        reward = _consumeReward(p);
        if (reward == 0) revert NothingToClaim();
        hookrToken.safeTransfer(to, reward);
        emit RewardsClaimed(positionId, msg.sender, to, reward);
    }

    function withdraw(uint256 positionId, address to)
        external
        nonReentrant
        returns (uint256 principal, uint256 reward)
    {
        if (to == address(0)) revert ZeroAddress();
        _requireCheckpointed();
        Position storage p = _positionStorage(positionId);
        if (p.owner != msg.sender) revert NotPositionOwner();
        if (p.withdrawn) revert PositionWithdrawn();
        if (block.timestamp < p.unlockAt) revert PositionStillLocked(p.unlockAt);

        reward = _consumeReward(p);
        principal = p.principal;
        p.withdrawn = true;
        totalLockedPrincipal -= principal;

        hookrToken.safeTransfer(to, principal + reward);
        if (reward != 0) emit RewardsClaimed(positionId, msg.sender, to, reward);
        emit Withdrawn(positionId, msg.sender, to, principal, reward);
    }

    function _consumeReward(Position storage p) internal returns (uint256 reward) {
        uint32 endEpoch = checkpointEpoch < p.expiryEpoch ? checkpointEpoch : p.expiryEpoch;
        if (endEpoch > p.lastClaimEpoch) {
            uint256 indexDelta = rewardIndexAtEpoch[endEpoch] - rewardIndexAtEpoch[p.lastClaimEpoch];
            reward = FullMath.mulDiv(uint256(p.weight), indexDelta, Q128);
            p.lastClaimEpoch = endEpoch;
        }
        if (reward > rewardReserve) revert AccountingInvariant();
        rewardReserve -= reward;
        cumulativeRewardsClaimed += reward;
    }

    function _position(uint256 positionId) internal view returns (Position memory p) {
        if (positionId == 0 || positionId >= positions.length) revert UnknownPosition();
        p = positions[positionId];
    }

    function _positionStorage(uint256 positionId) internal view returns (Position storage p) {
        if (positionId == 0 || positionId >= positions.length) revert UnknownPosition();
        p = positions[positionId];
    }

    function _requireCheckpointed() internal {
        checkpoint(MAX_AUTO_CHECKPOINT_EPOCHS);
        uint32 target = currentEpoch();
        if (checkpointEpoch != target) revert CheckpointRequired(checkpointEpoch, target);
    }

    function solvency()
        external
        view
        returns (uint256 balance, uint256 principalLiability, uint256 rewardLiability, uint256 surplus, bool solvent)
    {
        balance = hookrToken.balanceOf(address(this));
        principalLiability = totalLockedPrincipal;
        rewardLiability = rewardReserve;
        uint256 liabilities = principalLiability + rewardLiability;
        solvent = balance >= liabilities;
        if (solvent) surplus = balance - liabilities;
    }
}
