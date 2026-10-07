// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookrGoverned} from "hookr/base/HookrGoverned.sol";
import {IHookrVestingMilestoneEscrow} from "./interfaces/IHookrVestingMilestoneEscrow.sol";

/// @title HookrVestingMilestoneEscrow
/// @notice A launch-time escrow for a creator or team allocation of one subject token. The owner funds the escrow
///         exactly once; from that block the allocation unlocks on a cliff-then-
///         linear time schedule, additionally gated by up to three on-chain milestones read from PoolManager state
///         through the pool's own Rules module's trusted views. Only the named beneficiary can ever receive
///         released tokens, and every owner action can only make the schedule slower, never faster.
/// @dev Composition:
///      - Dev buy / 5% hold cap: HookrLauncher's dev buy (MAX_DEV_BUY_BPS = 500) bounds only the launch-time swap
///        the creator receives; it says nothing about a separate team allocation escrowed here. `maxAllocationBps`
///        enforces an independent, owner-immutable ceiling against the subject's `totalSupply()` at fund time, so
///        the two allocations cannot be combined to exceed what governance intends. Where that ceiling sits is
///        the owner's choice.
///      - No hook wiring: this contract holds no PoolManager liquidity and is not itself a Rules or Advisory
///        module. It only reads pool state through StateLibrary views (liquidity, fee growth, slot0 tick), so it
///        composes with any pool configuration without occupying a Rules/Advisory admission slot.
///      - Milestones can only ever narrow `releasable()`; they are computed as `min(timeVested, milestoneGate)`, so
///        no milestone or owner action can push a release ahead of the time schedule, and `released` never
///        decreases. Nothing here can accelerate release; every owner setter only raises a threshold or extends a
///        duration, queued behind the fixed 30-minute HookrGoverned timelock.
///      - `feeGrowthGlobal` can be inflated by an actor donating to itself inside a single unlocked call
///        (documented on StateLibrary.getFeeGrowthGlobals), and by wash trading, since it is monotonic. That only
///        lets the volume milestone catch up to what the `timeVested` ceiling already allows; it can never release
///        a single unit ahead of the time schedule.
///      - Liquidity and time-in-range are sampled by permissionless checkpoints, never read as a single instant:
///        a sample can only be taken while the PoolManager is locked, an interval is credited only between two
///        qualifying samples, and no single interval credits more than MAX_CHECKPOINT_INTERVAL. Liquidity added
///        and removed inside one unlock is never sampled. A sample still sees the pool only at the instant it is
///        taken: an actor who places liquidity (or the price) at every sample instant, even for one transaction
///        each, and nobody samples in between, can build a held run without the liquidity ever resting in the
///        pool. Only an independent sampler closes that. The liquidity milestone also reads met
///        only while its last sample is fresh (no older than MAX_CHECKPOINT_GAP), so a run observed once in the
///        past never carries a later release.
///      - Pinning a sampled run: any one below-bar sample restarts the liquidity run, so an LP holding more than
///        (pool liquidity - bar) in range, the owner as launcher family owner included, can withdraw, sample and
///        re-add in one block once a day and keep the milestone unmet for good. Time in range breaks the same way:
///        any one out-of-band sample voids the next interval, and the family owner can withdraw, push the price
///        past the band (for one unit when its position was the pool's only liquidity), sample, push it back and
///        re-add after each keeper sample. HookrVestingMilestoneFactory therefore refuses all three milestones
///        until a hook-fed observation exists, and a raise can never switch one on (MilestoneStaysOff before
///        funding, the raise ceiling after). The constructor still accepts them, for an escrow deployed by hand,
///        which the factory does not list.
///      - Pool binding: this constructor accepts any `poolId` on `poolManager_`, because a PoolId alone cannot be
///        traced back to its currencies. HookrVestingMilestoneFactory is the binding point: it deploys (and lists
///        in `isEscrow`) only an escrow whose pool HookrLauncher launched and whose PoolKey holds `subject_`. An
///        escrow deployed by hand is not bound that way; check its `poolId` against the launcher before trusting
///        its milestones.
contract HookrVestingMilestoneEscrow is HookrGoverned, IHookrVestingMilestoneEscrow {
    using SafeERC20 for IERC20;

    uint40 public constant MIN_CLIFF = 0;
    uint40 public constant MAX_CLIFF = 365 days;
    uint40 public constant DEFAULT_CLIFF = 90 days;

    uint40 public constant MIN_VESTING = 30 days;
    uint40 public constant MAX_VESTING = 1460 days;
    uint40 public constant DEFAULT_VESTING = 365 days;

    uint32 public constant MIN_TIME_IN_RANGE = 0;
    uint32 public constant MAX_TIME_IN_RANGE = 365 days;
    uint32 public constant DEFAULT_TIME_IN_RANGE = 0;

    uint128 public constant MIN_LIQUIDITY_THRESHOLD = 0;
    uint128 public constant MAX_LIQUIDITY_THRESHOLD = type(uint128).max;
    uint128 public constant DEFAULT_LIQUIDITY_THRESHOLD = 0;

    uint256 public constant MIN_VOLUME_THRESHOLD = 0;
    uint256 public constant MAX_VOLUME_THRESHOLD = type(uint256).max;
    uint256 public constant DEFAULT_VOLUME_THRESHOLD = 0;

    uint16 public constant MIN_ALLOCATION_BPS = 0;
    uint16 public constant MAX_ALLOCATION_BPS = 5_000;
    uint16 public constant DEFAULT_ALLOCATION_BPS = 2_000;

    /// @notice The most one checkpoint interval can ever credit. A longer unobserved gap credits only this much
    ///         (time-in-range) or restarts the run (liquidity), so milestone time is always observed time.
    uint40 public constant MAX_CHECKPOINT_INTERVAL = 1 hours;
    /// @notice How long pool liquidity must stay at or above `liquidityThreshold`, across consecutive checkpoints
    ///         no more than MAX_CHECKPOINT_INTERVAL apart, before the liquidity milestone reads met.
    uint40 public constant LIQUIDITY_HOLD = 1 days;
    /// @notice Slack on top of MAX_CHECKPOINT_INTERVAL for a late keeper. A liquidity sample up to this long after
    ///         the previous one continues the held run (crediting at most MAX_CHECKPOINT_INTERVAL); a longer gap
    ///         restarts it. The liquidity milestone reads met only while its last sample is no older than this.
    uint40 public constant MAX_CHECKPOINT_GAP = MAX_CHECKPOINT_INTERVAL + 15 minutes;
    /// @notice After funding, a raise may take a milestone bar to at most this multiple of the bar in force at
    ///         funding, and may never switch on a milestone that was off at funding. Before funding, raises are
    ///         bounded only by the MIN/MAX constants above.
    uint256 public constant MAX_RAISE_FACTOR = 2;
    /// @notice The widest time-in-range band, in ticks, a switched-on time-in-range milestone accepts: 138,162 ticks
    ///         is a price ratio of about 1,000,000x from the band's bottom to its top. A band that covers every tick
    ///         a pool can reach (the shipped default [MIN_TICK, MAX_TICK], or anything close to it) would count
    ///         every sample as in range and meet the milestone for keeper gas alone, so it is refused.
    uint24 public constant MAX_RANGE_WIDTH = 138_162;

    uint256 private constant BPS = 10_000;

    bytes32 public constant EXTEND_CLIFF = keccak256("EXTEND_CLIFF");
    bytes32 public constant EXTEND_VESTING = keccak256("EXTEND_VESTING");
    bytes32 public constant RAISE_LIQUIDITY_THRESHOLD = keccak256("RAISE_LIQUIDITY_THRESHOLD");
    bytes32 public constant RAISE_VOLUME_THRESHOLD = keccak256("RAISE_VOLUME_THRESHOLD");
    bytes32 public constant RAISE_TIME_IN_RANGE_THRESHOLD = keccak256("RAISE_TIME_IN_RANGE_THRESHOLD");

    address public immutable beneficiary;
    address public immutable subject;
    IPoolManager public immutable poolManager;
    PoolId public immutable poolId;

    Config private _config;
    uint256 public total;
    uint256 public released;
    uint40 public fundedAt;

    uint40 private _lastCheckpoint;
    uint32 private _cumulativeInRangeSeconds;
    bool private _lastInRange;

    uint40 private _lastLiquidityCheckpoint;
    uint40 private _liquidityHeldSince;
    uint40 private _liquidityHeldSeconds;

    uint128 private _fundedLiquidityThreshold;
    uint256 private _fundedVolumeThreshold;
    uint32 private _fundedTimeInRangeSeconds;
    /// @dev Set by the one change of the liquidity bar allowed after funding. A change restarts the held run, so
    ///      a second one is refused: repeated small raises timed just before each run completes would otherwise
    ///      keep the milestone unmet for good while staying under the MAX_RAISE_FACTOR ceiling.
    bool private _liquidityBarChangedAfterFunding;

    /// @param owner_ The creator/family owner: can only extend the schedule or raise milestone bars, timelocked.
    /// @param beneficiary_ The only address that can ever receive released tokens. Immutable.
    /// @param subject_ The escrowed ERC-20.
    /// @param poolManager_ The Uniswap v4 PoolManager the milestones read.
    /// @param poolId_ The pool the milestones are measured against.
    /// @param config_ Bounded cliff/vesting/milestone configuration, validated against the MIN/MAX constants above.
    constructor(
        address owner_,
        address beneficiary_,
        address subject_,
        IPoolManager poolManager_,
        PoolId poolId_,
        Config memory config_
    ) HookrGoverned(owner_, MIN_DELAY) {
        if (beneficiary_ == address(0)) revert InvalidAddress(beneficiary_);
        if (subject_ == address(0)) revert InvalidAddress(subject_);
        if (address(poolManager_) == address(0)) revert InvalidAddress(address(poolManager_));
        _validateConfig(config_);

        beneficiary = beneficiary_;
        subject = subject_;
        poolManager = poolManager_;
        poolId = poolId_;
        _config = config_;
    }

    /// @notice Pulls `amount` of `subject` from the owner and starts the cliff clock. Owner only, callable once,
    ///         never again after. `total` records what actually arrived (the balance delta), not the figure asked
    ///         for, so a subject that takes a transfer fee can never promise more than the escrow holds.
    function fund(uint256 amount) external onlyOwner {
        if (fundedAt != 0) revert AlreadyFunded();
        if (amount == 0) revert ZeroTotal();
        uint256 supply = IERC20(subject).totalSupply();
        uint256 cap = (supply * _config.maxAllocationBps) / BPS;
        if (amount > cap) revert AllocationTooLarge(amount, cap);

        fundedAt = uint40(block.timestamp);
        _lastCheckpoint = uint40(block.timestamp);
        _fundedLiquidityThreshold = _config.liquidityThreshold;
        _fundedVolumeThreshold = _config.volumeThreshold;
        _fundedTimeInRangeSeconds = _config.timeInRangeSeconds;
        uint256 before = IERC20(subject).balanceOf(address(this));
        IERC20(subject).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(subject).balanceOf(address(this)) - before;
        if (received == 0) revert ZeroTotal();
        total = received;
        emit Funded(msg.sender, received, fundedAt);
    }

    /// @notice Releases everything currently unlocked to the beneficiary. Only the beneficiary may call.
    function release() external returns (uint256 amount) {
        if (msg.sender != beneficiary) revert OnlyBeneficiary(msg.sender);
        amount = releasable();
        if (amount == 0) revert NothingReleasable();
        released += amount;
        IERC20(subject).safeTransfer(beneficiary, amount);
        emit Released(beneficiary, amount, released);
    }

    /// @notice The amount `release()` would transfer right now.
    function releasable() public view returns (uint256) {
        if (fundedAt == 0) return 0;
        uint256 vested = timeVested();
        uint256 gate = milestoneGate();
        if (gate < vested) vested = gate;
        if (vested <= released) return 0;
        return vested - released;
    }

    /// @notice The cliff-then-linear time schedule's unlocked amount, ignoring milestones.
    function timeVested() public view returns (uint256) {
        if (fundedAt == 0) return 0;
        uint256 elapsed = block.timestamp - fundedAt;
        Config memory c = _config;
        if (elapsed < c.cliffSeconds) return 0;
        uint256 sinceCliff = elapsed - c.cliffSeconds;
        if (sinceCliff >= c.vestingSeconds) return total;
        return (total * sinceCliff) / c.vestingSeconds;
    }

    /// @notice The milestone-side ceiling: `total` when no milestone is enabled, otherwise `total` scaled by the
    ///         fraction of enabled milestones currently met (each enabled milestone worth an equal share).
    function milestoneGate() public view returns (uint256) {
        Config memory c = _config;
        uint256 enabledCount;
        uint256 metCount;
        if (c.liquidityThreshold != 0) {
            unchecked {
                ++enabledCount;
            }
            if (liquidityMilestoneMet()) {
                unchecked {
                    ++metCount;
                }
            }
        }
        if (c.volumeThreshold != 0) {
            unchecked {
                ++enabledCount;
            }
            if (volumeMilestoneMet()) {
                unchecked {
                    ++metCount;
                }
            }
        }
        if (c.timeInRangeSeconds != 0) {
            unchecked {
                ++enabledCount;
            }
            if (timeInRangeMilestoneMet()) {
                unchecked {
                    ++metCount;
                }
            }
        }
        if (enabledCount == 0 || metCount == enabledCount) return total;
        return (total * metCount) / enabledCount;
    }

    /// @notice Met once checkpoints have credited LIQUIDITY_HOLD of held liquidity (every sample at or above the
    ///         threshold, each interval credited at most MAX_CHECKPOINT_INTERVAL, no gap over MAX_CHECKPOINT_GAP),
    ///         the last sample is no older than MAX_CHECKPOINT_GAP, and the pool still holds the threshold now.
    ///         Never reads met while the PoolManager is unlocked, so liquidity added and removed inside one unlock
    ///         never counts. The live read can only turn a met milestone unmet; what makes it met is the stored,
    ///         fresh run.
    function liquidityMilestoneMet() public view returns (bool) {
        uint128 threshold = _config.liquidityThreshold;
        if (threshold == 0) return true;
        if (TransientStateLibrary.isUnlocked(poolManager)) return false;
        if (_liquidityHeldSince == 0 || _liquidityHeldSeconds < LIQUIDITY_HOLD) return false;
        if (block.timestamp - _lastLiquidityCheckpoint > MAX_CHECKPOINT_GAP) return false;
        return StateLibrary.getLiquidity(poolManager, poolId) >= threshold;
    }

    /// @notice Permissionless: samples pool liquidity against the threshold. A sample below the threshold, or one
    ///         taken more than MAX_CHECKPOINT_GAP after the previous sample, restarts the held run; otherwise the
    ///         interval since the previous sample is credited, capped at MAX_CHECKPOINT_INTERVAL.
    function checkpointLiquidity() external {
        if (fundedAt == 0) revert NotFunded();
        if (TransientStateLibrary.isUnlocked(poolManager)) revert ManagerUnlocked();
        uint128 threshold = _config.liquidityThreshold;
        uint128 liquidity = StateLibrary.getLiquidity(poolManager, poolId);
        uint40 nowTs = uint40(block.timestamp);
        if (threshold == 0 || liquidity < threshold) {
            _liquidityHeldSince = 0;
            _liquidityHeldSeconds = 0;
        } else if (_liquidityHeldSince == 0 || nowTs - _lastLiquidityCheckpoint > MAX_CHECKPOINT_GAP) {
            _liquidityHeldSince = nowTs;
            _liquidityHeldSeconds = 0;
        } else {
            uint40 elapsed = nowTs - _lastLiquidityCheckpoint;
            if (elapsed > MAX_CHECKPOINT_INTERVAL) elapsed = MAX_CHECKPOINT_INTERVAL;
            _liquidityHeldSeconds += elapsed;
        }
        _lastLiquidityCheckpoint = nowTs;
        emit LiquidityCheckpointed(liquidity, _liquidityHeldSince);
    }

    function liquidityHeldSince() external view returns (uint40) {
        return _liquidityHeldSince;
    }

    /// @notice Observed seconds credited to the current held-liquidity run.
    function liquidityHeldSeconds() external view returns (uint40) {
        return _liquidityHeldSeconds;
    }

    function lastLiquidityCheckpoint() external view returns (uint40) {
        return _lastLiquidityCheckpoint;
    }

    /// @notice True once the one post-funding change of the liquidity bar has been used.
    function liquidityBarChangedAfterFunding() external view returns (bool) {
        return _liquidityBarChangedAfterFunding;
    }

    function volumeMilestoneMet() public view returns (bool) {
        uint256 threshold = _config.volumeThreshold;
        if (threshold == 0) return true;
        (uint256 g0, uint256 g1) = StateLibrary.getFeeGrowthGlobals(poolManager, poolId);
        unchecked {
            return (g0 + g1) >= threshold;
        }
    }

    function timeInRangeMilestoneMet() public view returns (bool) {
        uint32 threshold = _config.timeInRangeSeconds;
        if (threshold == 0) return true;
        return _cumulativeInRangeSeconds >= threshold;
    }

    /// @notice Permissionless: samples the pool's tick against [rangeTickLower, rangeTickUpper]. The interval
    ///         since the previous sample is credited only when both that sample and this one were in the band, and
    ///         never more than MAX_CHECKPOINT_INTERVAL of it. The first call after funding only sets the baseline;
    ///         call at least every MAX_CHECKPOINT_INTERVAL (a keeper, or the beneficiary) to accrue in full.
    function checkpointTimeInRange() external {
        if (fundedAt == 0) revert NotFunded();
        if (TransientStateLibrary.isUnlocked(poolManager)) revert ManagerUnlocked();
        Config memory c = _config;
        (, int24 tick,,) = StateLibrary.getSlot0(poolManager, poolId);
        bool inRange = c.timeInRangeSeconds != 0 && tick >= c.rangeTickLower && tick <= c.rangeTickUpper;
        if (_lastInRange && inRange) {
            uint256 elapsed = block.timestamp - _lastCheckpoint;
            if (elapsed > MAX_CHECKPOINT_INTERVAL) elapsed = MAX_CHECKPOINT_INTERVAL;
            uint256 next = uint256(_cumulativeInRangeSeconds) + elapsed;
            _cumulativeInRangeSeconds = next > type(uint32).max ? type(uint32).max : uint32(next);
        }
        _lastInRange = inRange;
        _lastCheckpoint = uint40(block.timestamp);
        emit TimeInRangeCheckpointed(tick, inRange, _cumulativeInRangeSeconds);
    }

    function cumulativeInRangeSeconds() external view returns (uint32) {
        return _cumulativeInRangeSeconds;
    }

    // Owner: slower-only, timelocked

    /// @notice Executes a queued EXTEND_CLIFF(next): raises the cliff. Only ever later, never earlier.
    function extendCliff(uint40 next) external onlyOwner {
        _consume(EXTEND_CLIFF, abi.encode(next));
        uint40 previous = _config.cliffSeconds;
        if (next < previous) revert NotSlower(previous, next);
        if (next > MAX_CLIFF) revert OutOfBounds(next, MIN_CLIFF, MAX_CLIFF);
        _config.cliffSeconds = next;
        emit CliffExtended(previous, next);
    }

    /// @notice Executes a queued EXTEND_VESTING(next): lengthens the linear window. Only ever longer.
    function extendVesting(uint40 next) external onlyOwner {
        _consume(EXTEND_VESTING, abi.encode(next));
        uint40 previous = _config.vestingSeconds;
        if (next < previous) revert NotSlower(previous, next);
        if (next < MIN_VESTING || next > MAX_VESTING) revert OutOfBounds(next, MIN_VESTING, MAX_VESTING);
        _config.vestingSeconds = next;
        emit VestingExtended(previous, next);
    }

    /// @notice Executes a queued RAISE_LIQUIDITY_THRESHOLD(next): raises a liquidity bar that was on at
    ///         construction; a bar of 0 stays 0 (MilestoneStaysOff). A higher bar restarts the held run, so the
    ///         milestone reads met again only after checkpoints have held the new bar for LIQUIDITY_HOLD. After
    ///         funding the bar may change once: a second change reverts LiquidityBarAlreadyRaised, so the raise path
    ///         can delay the milestone by one run at most. It does not stop an LP from restarting the run with a
    ///         below-bar sample (see the contract notes); that is why the factory refuses this milestone.
    function raiseLiquidityThreshold(uint128 next) external onlyOwner {
        _consume(RAISE_LIQUIDITY_THRESHOLD, abi.encode(next));
        uint128 previous = _config.liquidityThreshold;
        if (next < previous) revert NotSlower(previous, next);
        if (next > MAX_LIQUIDITY_THRESHOLD) revert OutOfBounds(next, MIN_LIQUIDITY_THRESHOLD, MAX_LIQUIDITY_THRESHOLD);
        _checkRaiseCeiling(next, _fundedLiquidityThreshold);
        if (previous == 0 && next != 0) revert MilestoneStaysOff();
        if (fundedAt != 0 && next != previous) {
            if (_liquidityBarChangedAfterFunding) revert LiquidityBarAlreadyRaised();
            _liquidityBarChangedAfterFunding = true;
        }
        _config.liquidityThreshold = next;
        if (next != previous) {
            // A held run was credited against the old bar. No sample has seen the new one yet, so the run restarts
            // and only samples at or above the new bar count toward it.
            _liquidityHeldSince = 0;
            _liquidityHeldSeconds = 0;
        }
        emit LiquidityThresholdRaised(previous, next);
    }

    /// @notice Executes a queued RAISE_VOLUME_THRESHOLD(next): raises a volume bar that was on at construction; a
    ///         bar of 0 stays 0 (MilestoneStaysOff).
    function raiseVolumeThreshold(uint256 next) external onlyOwner {
        _consume(RAISE_VOLUME_THRESHOLD, abi.encode(next));
        uint256 previous = _config.volumeThreshold;
        if (next < previous) revert NotSlower(previous, next);
        _checkRaiseCeiling(next, _fundedVolumeThreshold);
        if (previous == 0 && next != 0) revert MilestoneStaysOff();
        _config.volumeThreshold = next;
        emit VolumeThresholdRaised(previous, next);
    }

    /// @notice Executes a queued RAISE_TIME_IN_RANGE_THRESHOLD(next): raises a time-in-range bar that was on at
    ///         construction; a bar of 0 stays 0 (MilestoneStaysOff). The band itself is fixed at construction, where
    ///         a switched-on bar validates it (widening it would let a wider band count as "in range", which is an
    ///         acceleration, not a slow-down, so it is never adjustable).
    function raiseTimeInRangeThreshold(uint32 next) external onlyOwner {
        _consume(RAISE_TIME_IN_RANGE_THRESHOLD, abi.encode(next));
        uint32 previous = _config.timeInRangeSeconds;
        if (next < previous) revert NotSlower(previous, next);
        if (next > MAX_TIME_IN_RANGE) revert OutOfBounds(next, MIN_TIME_IN_RANGE, MAX_TIME_IN_RANGE);
        _checkRaiseCeiling(next, _fundedTimeInRangeSeconds);
        if (previous == 0 && next != 0) revert MilestoneStaysOff();
        _config.timeInRangeSeconds = next;
        emit TimeInRangeThresholdRaised(previous, next);
    }

    /// @dev Once funded, a milestone bar may rise to at most MAX_RAISE_FACTOR times the bar in force at funding,
    ///      and a milestone that was off at funding (bar 0) stays off, so no owner action can pin the gate at zero
    ///      with a bar the beneficiary never agreed to. The liquidity bar, whose change restarts the held run, may
    ///      also change only once after funding (raiseLiquidityThreshold). Before funding there is nothing escrowed
    ///      to strand.
    function _checkRaiseCeiling(uint256 next, uint256 fundedValue) private view {
        if (fundedAt == 0) return;
        uint256 ceiling =
            fundedValue > type(uint256).max / MAX_RAISE_FACTOR ? type(uint256).max : fundedValue * MAX_RAISE_FACTOR;
        if (next > ceiling) revert OutOfBounds(next, fundedValue, ceiling);
    }

    /// @notice Sends `token` held here beyond what the escrow owes the beneficiary to the owner. For the subject
    ///         that is the balance above `total - released` (tokens that arrived outside fund()); any other token
    ///         is never owed, so all of it. Never touches the escrowed allocation, so it cannot slow or speed the
    ///         schedule.
    function recoverExcess(address token) external onlyOwner returns (uint256 amount) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (token == subject) {
            uint256 owed = total - released;
            amount = balance > owed ? balance - owed : 0;
        } else {
            amount = balance;
        }
        if (amount == 0) revert NothingToRecover();
        address to = owner();
        IERC20(token).safeTransfer(to, amount);
        emit ExcessRecovered(token, to, amount);
    }

    function _checkQueue(bytes32 kind, bytes calldata arguments) internal view override {
        if (
            kind == EXTEND_CLIFF || kind == EXTEND_VESTING || kind == RAISE_LIQUIDITY_THRESHOLD
                || kind == RAISE_VOLUME_THRESHOLD || kind == RAISE_TIME_IN_RANGE_THRESHOLD
        ) {
            return;
        }
        super._checkQueue(kind, arguments);
    }

    function config() external view returns (Config memory) {
        return _config;
    }

    function _validateConfig(Config memory c) private pure {
        if (c.cliffSeconds > MAX_CLIFF) revert OutOfBounds(c.cliffSeconds, MIN_CLIFF, MAX_CLIFF);
        if (c.vestingSeconds < MIN_VESTING || c.vestingSeconds > MAX_VESTING) {
            revert OutOfBounds(c.vestingSeconds, MIN_VESTING, MAX_VESTING);
        }
        if (c.timeInRangeSeconds > MAX_TIME_IN_RANGE) {
            revert OutOfBounds(c.timeInRangeSeconds, MIN_TIME_IN_RANGE, MAX_TIME_IN_RANGE);
        }
        if (c.timeInRangeSeconds != 0) _validateRange(c.rangeTickLower, c.rangeTickUpper);
        if (c.maxAllocationBps < MIN_ALLOCATION_BPS || c.maxAllocationBps > MAX_ALLOCATION_BPS) {
            revert OutOfBounds(c.maxAllocationBps, MIN_ALLOCATION_BPS, MAX_ALLOCATION_BPS);
        }
    }

    /// @dev A switched-on time-in-range band must be ordered, inside [MIN_TICK, MAX_TICK], and no wider than
    ///      MAX_RANGE_WIDTH ticks, so that a reachable tick can fall outside it.
    function _validateRange(int24 lower, int24 upper) private pure {
        if (
            lower >= upper || lower < TickMath.MIN_TICK || upper > TickMath.MAX_TICK
                || int256(upper) - int256(lower) > int256(uint256(MAX_RANGE_WIDTH))
        ) revert InvalidRange(lower, upper);
    }

    /// @notice A default, fully-bounded configuration with every milestone disabled (pure cliff + linear vesting).
    ///         Its band [MIN_TICK, MAX_TICK] is a placeholder: constructing an escrow with the time-in-range
    ///         milestone on over it reverts InvalidRange, so a hand-deployed escrow that enables that milestone has to
    ///         name a band around its pool (the factory refuses the milestone).
    function defaultConfig() external pure returns (Config memory c) {
        c.cliffSeconds = DEFAULT_CLIFF;
        c.vestingSeconds = DEFAULT_VESTING;
        c.liquidityThreshold = DEFAULT_LIQUIDITY_THRESHOLD;
        c.volumeThreshold = DEFAULT_VOLUME_THRESHOLD;
        c.timeInRangeSeconds = DEFAULT_TIME_IN_RANGE;
        c.rangeTickLower = TickMath.MIN_TICK;
        c.rangeTickUpper = TickMath.MAX_TICK;
        c.maxAllocationBps = DEFAULT_ALLOCATION_BPS;
    }
}
