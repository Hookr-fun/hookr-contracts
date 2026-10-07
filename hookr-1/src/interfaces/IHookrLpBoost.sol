// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookrRegistry} from "./IHookrRegistry.sol";
import {IHookrLauncherView} from "./IHookrLauncherView.sol";
import {IPositionManagerMinimal} from "./external/IPositionManagerMinimal.sol";
import {IHookrGoverned} from "./IHookrGoverned.sol";

/// @title IHookrLpBoost
/// @notice Interface for HookrLpBoost, LP time-lock boost rewards: an LP stakes a full-range Uniswap v4 position of a
///         Hookr pool, locks it for a number of weeks and earns rewards per second on its boosted liquidity from
///         tranches a creator, partner or the protocol funded. One gauge per pool, each with its own positions, budget
///         and accounting.
/// @dev Day-one consumer: creators and partners funding a pool's LP incentives and that pool's LPs, through the app's
///      LP boost panel, and an ops keeper calling `poke`. No Hookr core contract reads it.
///      Invariants: per gauge paid + owed + unassigned + scheduled <= funded, and the contract's balance of each
///      reward token covers every gauge's funded - paid; nothing accrues outside a tranche or with no weight; each
///      tranche emits its amount evenly from its start to its end and nothing changes it once started, so no notify
///      or fund can stretch, squeeze or block another; a gauge exists only with a minLiquidity that meets the sizing
///      rule and that some full-range position of its pool could hold, so while its currencies' supply bounds hold
///      nothing accrues while its positions are out of range (Range); a position is staked once, only full range,
///      only in its own pool's gauge and only with at least that gauge's minLiquidity, weighted by the liquidity read
///      at stake; a staked NFT leaves only through its staker's `withdraw` at or after maturity; owed rewards fall
///      only by their own claim; nothing works before the queued ACTIVATE executes; brakes never stop `withdraw` or
///      `collectFees`; the accrual reads no pool state.
///      Range: a full-range position is in range at every tick of the usable range, and on or past an edge of it owns
///      only one currency: for liquidity L, SqrtPriceMath's getAmount0Delta(sqrtPriceAtTick(minUsableTick),
///      sqrtPriceAtTick(maxUsableTick), L) of currency0 at the lower edge, getAmount1Delta of currency1 at the upper.
///      The sizing rule, which `createGauge` enforces: for L the gauge's minLiquidity, each of those amounts, rounded
///      down, is above that currency's supply bound (`supplyBound`: NATIVE_SUPPLY_BOUND for native ETH, a HookrToken's
///      fixed supply, or the bound the owner declared through SET_SUPPLY_BOUND). At the end of every transaction the
///      PoolManager is locked with every swap settled, so it holds all that every position owns, and no currency's
///      supply is past its bound (a flash mint is burned before its call returns): while anyone is staked, the price is
///      inside the usable range whenever a transaction ends. Time passes only between transactions, so every interval
///      with weight is in range; the accrual reads no pool state, and nothing done inside a transaction (a PoolManager
///      unlock, a flash mint, a round trip of settled swaps at any fee) changes what an interval pays.
///      A bound fails when an issuer mints past a declared one, or when a contract carries HookrToken's runtime code
///      but was deployed by other initcode, which can leave its totalSupply below what its holders hold (every
///      HookrToken HookrLauncher creates runs HookrToken's own constructor). Then a staked pool's price can leave the
///      usable range, and its stakes keep earning by weight: nothing is wiped and nothing moves but that gauge's own
///      emission, to its own stakes.
///      Rounding: every division rounds down, toward this contract.
interface IHookrLpBoost is IHookrGoverned {
    /// @notice A gauge's terms, fixed for good when it is created.
    struct Terms {
        /// @notice The ERC-20 the gauge pays; on the reward-token list when the gauge is created.
        address rewardToken;
        /// @notice The shortest lock a stake may pick, in weeks; at least 1.
        uint16 minLockWeeks;
        /// @notice The longest lock a stake may pick, in weeks; at most MAX_LOCK_WEEKS.
        uint16 maxLockWeeks;
        /// @notice The boost of a maxLockWeeks lock in basis points of 1x, from 10,000 to MAX_BOOST_BPS.
        uint16 maxBoostBps;
        /// @notice The least liquidity a staked position holds, at least MIN_LIQUIDITY and meeting the sizing rule
        ///         (Range), so while the pool's supply bounds hold its price never leaves the usable range while anyone
        ///         is staked, and at most what some full-range position of the pool could hold (MinLiquidityTooHigh):
        ///         in the pool's own units, the depth a full-range position adds, which the creator sizes as the
        ///         smallest depth worth paying for (a stake alone in the gauge earns its whole emission).
        uint128 minLiquidity;
    }

    /// @notice One pool's gauge.
    struct Gauge {
        /// @notice The pool; its hooks are a registered Hookr root that initialized it.
        PoolKey key;
        /// @notice Who created the gauge: the pool's family owner, or the owner through the queue.
        address creator;
        /// @notice The gauge's terms.
        Terms terms;
        /// @notice Whether a brake paused the gauge.
        bool paused;
        /// @notice The time the accrual has been brought to.
        uint48 lastUpdate;
        /// @notice The end of the gauge's latest tranche, a week boundary: nothing emits after it; zero before the
        ///         first tranche.
        uint48 periodFinish;
        /// @notice The latest week boundary that ever held a maturity drop; with periodFinish, bounds the accrual walk.
        uint48 lastDropWeek;
        /// @notice The running tranches' amounts not yet emitted.
        uint128 scheduled;
        /// @notice Rewards emitted while nothing could earn them; only a later notify re-emits them.
        uint128 unassigned;
        /// @notice Every reward amount the gauge received, by balance delta.
        uint128 funded;
        /// @notice Every reward amount the gauge paid to stakers.
        uint128 paid;
        /// @notice The running tranches' rates summed, Q128 per second: each tranche's amount x 2^128 / its length in
        ///         seconds, rounded down.
        uint256 rewardRateX128;
        /// @notice What the running tranches' rates still emit, Q128: each rate x the seconds left to its tranche's
        ///         end, summed. An interval that uses `used` of it emits scheduled x used / emissionLeftX128, so the
        ///         budget left is all emitted when the last tranche ends.
        uint256 emissionLeftX128;
        /// @notice The sum of the live stakes' weights.
        uint256 totalWeight;
        /// @notice Rewards per unit of weight since the gauge was created, Q128.
        uint256 rewardPerWeightX128;
    }

    /// @notice One staked position.
    struct Stake {
        /// @notice The account that staked it: the only one that can extend, claim for, collect fees from or withdraw
        ///         it.
        address owner;
        /// @notice The week boundary from which it can be withdrawn and its boost ends.
        uint48 maturity;
        /// @notice Its boost in basis points of 1x; 10,000 once its maturity has been settled.
        uint16 boostBps;
        /// @notice Its liquidity, read from the PoolManager at stake.
        uint128 liquidity;
        /// @notice The pool, and so the gauge, it is staked in.
        PoolId poolId;
        /// @notice The gauge's rewardPerWeightX128 at its last settlement.
        uint256 rewardPerWeightLastX128;
    }

    /// @notice Emitted when the queued ACTIVATE executes.
    event Activated();

    /// @notice Emitted when a reward token joins or leaves the reward-token list.
    /// @param token The token.
    /// @param listed Whether it is now on the list.
    /// @param by The owner, or the guardian for a removal.
    event RewardTokenSet(address indexed token, bool listed, address indexed by);

    /// @notice Emitted when the owner declares a currency's supply bound, or a brake removes it.
    /// @param currency The ERC-20.
    /// @param bound The new bound; zero once removed.
    /// @param by The owner, or the guardian for a removal.
    event SupplyBoundSet(address indexed currency, uint256 bound, address indexed by);

    /// @notice Emitted when a pool's gauge is created.
    /// @param id The pool.
    /// @param creator The pool's family owner, or the owner.
    /// @param rewardToken The token the gauge pays.
    /// @param key The pool's key.
    /// @param terms The gauge's terms.
    event GaugeCreated(
        PoolId indexed id, address indexed creator, address indexed rewardToken, PoolKey key, Terms terms
    );

    /// @notice Emitted when the gauge's creator or the owner starts a tranche.
    /// @param id The pool.
    /// @param by The gauge's creator or the owner.
    /// @param received The amount that arrived with this notify.
    /// @param amount The tranche's amount: the amount received and the unassigned remainder.
    /// @param finish The tranche's end, a week boundary.
    event Notified(PoolId indexed id, address indexed by, uint256 received, uint256 amount, uint48 finish);

    /// @notice Emitted when anyone funds a tranche.
    /// @param id The pool.
    /// @param funder The account that paid.
    /// @param received The amount that arrived, the tranche's amount.
    /// @param finish The tranche's end, a week boundary.
    event Funded(PoolId indexed id, address indexed funder, uint256 received, uint48 finish);

    /// @notice Emitted when emitted rewards could not be assigned: the gauge had no weight.
    /// @param id The pool.
    /// @param amount The amount added to the unassigned remainder.
    event Unassigned(PoolId indexed id, uint256 amount);

    /// @notice Emitted when the accrual crosses a week boundary at which boosts or tranches end.
    /// @param id The pool.
    /// @param week The boundary.
    /// @param drop The weight the ending boosts removed.
    /// @param rateDropX128 The rate the ending tranches removed, Q128 per second.
    /// @param rewardPerWeightX128 The gauge's rewardPerWeightX128 at the boundary.
    event WeekClosed(
        PoolId indexed id, uint256 indexed week, uint256 drop, uint256 rateDropX128, uint256 rewardPerWeightX128
    );

    /// @notice Emitted when a position is staked.
    /// @param tokenId The position.
    /// @param id The pool.
    /// @param owner The staker.
    /// @param liquidity The liquidity read at stake.
    /// @param lockWeeks The lock picked.
    /// @param maturity The week boundary at which it can be withdrawn.
    /// @param boostBps Its boost.
    event Staked(
        uint256 indexed tokenId,
        PoolId indexed id,
        address indexed owner,
        uint128 liquidity,
        uint16 lockWeeks,
        uint48 maturity,
        uint16 boostBps
    );

    /// @notice Emitted when a staker extends a lock.
    /// @param tokenId The position.
    /// @param lockWeeks The new lock, counted from the extension.
    /// @param maturity The new maturity.
    /// @param boostBps The new boost.
    event Extended(uint256 indexed tokenId, uint16 lockWeeks, uint48 maturity, uint16 boostBps);

    /// @notice Emitted when a settlement credits a stake's rewards to its staker.
    /// @param tokenId The position.
    /// @param owner The staker.
    /// @param amount The amount credited.
    event RewardsAccrued(uint256 indexed tokenId, address indexed owner, uint256 amount);

    /// @notice Emitted when a staker claims.
    /// @param id The pool.
    /// @param owner The staker.
    /// @param recipient The receiver of the rewards.
    /// @param amount The amount paid.
    event Claimed(PoolId indexed id, address indexed owner, address indexed recipient, uint256 amount);

    /// @notice Emitted when a staker collects a staked position's LP fees.
    /// @param tokenId The position.
    /// @param recipient The receiver of the fees.
    event FeesCollected(uint256 indexed tokenId, address indexed recipient);

    /// @notice Emitted when a staker withdraws a position.
    /// @param tokenId The position.
    /// @param owner The staker.
    /// @param recipient The receiver of the NFT.
    event Withdrawn(uint256 indexed tokenId, address indexed owner, address indexed recipient);

    /// @notice Emitted when a gauge is paused by a brake or unpaused by the queue.
    /// @param id The pool.
    /// @param paused Whether it is now paused.
    /// @param by The owner or the guardian.
    event GaugePauseSet(PoolId indexed id, bool paused, address indexed by);

    /// @notice Emitted when every gauge is paused by a brake or unpaused by the queue.
    /// @param paused Whether every gauge is now paused.
    /// @param by The owner or the guardian.
    event AllPauseSet(bool paused, address indexed by);

    /// @notice Thrown by every gauge entry before the queued ACTIVATE executes.
    error Inactive();

    /// @notice Thrown when ACTIVATE is queued or executed after it already executed.
    error AlreadyActive();

    /// @notice Thrown when the constructor's registry, launcher, PositionManager or their PoolManager do not fit
    ///         together.
    error InvalidWiring();

    /// @notice Thrown when a brake has paused every gauge.
    error AllPaused();

    /// @notice Thrown when a brake has paused the gauge.
    /// @param id The pool.
    error GaugeIsPaused(PoolId id);

    /// @notice Thrown when UNPAUSE is queued for a gauge that is not paused.
    /// @param id The pool.
    error GaugeNotPaused(PoolId id);

    /// @notice Thrown when UNPAUSE_ALL is queued while no brake has paused every gauge.
    error NotAllPaused();

    /// @notice Thrown when ADD_REWARD_TOKEN is queued for the PositionManager, the PoolManager or this contract (an
    ///         account without code or with an EIP-7702 delegation is refused by HookrGoverned's own checks).
    /// @param token The token.
    error InvalidRewardToken(address token);

    /// @notice Thrown when ADD_REWARD_TOKEN is queued for a listed token.
    /// @param token The token.
    error AlreadyListed(address token);

    /// @notice Thrown when a gauge would pay a token that is not on the reward-token list.
    /// @param token The token.
    error RewardTokenNotListed(address token);

    /// @notice Thrown when SET_SUPPLY_BOUND names a HookrToken (its bound is its fixed supply), a zero bound, or a
    ///         bound below the currency's current totalSupply (native ETH, an account without code and an EIP-7702
    ///         delegation are refused by HookrGoverned's own checks), and when removeSupplyBound names native ETH or a
    ///         HookrToken, whose bounds are built in (`bound` zero).
    /// @param currency The currency.
    /// @param bound The bound asked; zero for a removal.
    error InvalidSupplyBound(address currency, uint256 bound);

    /// @notice Thrown when a gauge's pool holds a currency with no supply bound: not native ETH, not a HookrToken and
    ///         none declared.
    /// @param currency The currency.
    error NoSupplyBound(address currency);

    /// @notice Thrown when a gauge's minLiquidity breaks the sizing rule: on the edge of the usable range where a
    ///         full-range position of it owns only `currency`, it owns no more than that currency's supply bound.
    /// @param currency The currency.
    /// @param atEdge What the position owns there, rounded down.
    /// @param supplyBound The currency's supply bound.
    error MinLiquidityTooLow(address currency, uint256 atEdge, uint256 supplyBound);

    /// @notice Thrown when no full-range position of a gauge's pool could hold its minLiquidity: it is above v4's
    ///         maximum liquidity per tick for the pool's tick spacing (every full-range position adds to the same two
    ///         ticks), or no price funds a full-range position of it within the two currencies' supply bounds. Such a
    ///         gauge would take funding no stake could ever earn.
    /// @param minLiquidity The minLiquidity asked.
    error MinLiquidityTooHigh(uint128 minLiquidity);

    /// @notice Thrown when a pool is not a Hookr pool: its hooks are not a registered root, or the root reports
    ///         another PoolManager or did not initialize the pool.
    /// @param id The pool.
    error InvalidPool(PoolId id);

    /// @notice Thrown when a gauge already exists for the pool.
    /// @param id The pool.
    error GaugeExists(PoolId id);

    /// @notice Thrown when no gauge exists for the pool.
    /// @param id The pool.
    error UnknownGauge(PoolId id);

    /// @notice Thrown when terms break their bounds: 1 <= minLockWeeks <= maxLockWeeks <= MAX_LOCK_WEEKS,
    ///         10,000 <= maxBoostBps <= MAX_BOOST_BPS and minLiquidity >= MIN_LIQUIDITY.
    error InvalidTerms();

    /// @notice Thrown when someone other than the pool's family owner creates a gauge outside the queue.
    /// @param caller The caller.
    error NotFamilyOwner(address caller);

    /// @notice Thrown when someone other than the gauge's creator or the owner notifies.
    /// @param caller The caller.
    error NotGaugeCreator(address caller);

    /// @notice Thrown when a tranche is not 1 to MAX_PERIOD_WEEKS weeks.
    /// @param durationWeeks The duration asked.
    error InvalidDuration(uint16 durationWeeks);

    /// @notice Thrown when a tranche would hold nothing: `fund` with a zero amount, or a notify that brings nothing
    ///         while the unassigned remainder is empty.
    error ZeroAmount();

    /// @notice Thrown when a reward transfer leaves this contract's balance unchanged.
    error NothingReceived();

    /// @notice Thrown when a gauge's funding would pass 2^128 - 1.
    /// @param id The pool.
    error FundingOverflow(PoolId id);

    /// @notice Thrown when the PositionManager's runtime code is no longer the code pinned at construction.
    error PositionManagerChanged();

    /// @notice Thrown when a position's info and its pool key name different pools, or the token does not exist.
    /// @param tokenId The position.
    error PoolMismatch(uint256 tokenId);

    /// @notice Thrown when a position is not full range: its ticks are not the key's minUsableTick and maxUsableTick.
    /// @param tickLower The position's lower tick.
    /// @param tickUpper The position's upper tick.
    error NotFullRange(int24 tickLower, int24 tickUpper);

    /// @notice Thrown when a position has a subscriber.
    /// @param tokenId The position.
    error HasSubscriber(uint256 tokenId);

    /// @notice Thrown when the position is already staked.
    /// @param tokenId The position.
    error AlreadyStaked(uint256 tokenId);

    /// @notice Thrown when the caller does not own the position.
    /// @param tokenId The position.
    /// @param caller The caller.
    error NotPositionOwner(uint256 tokenId, address caller);

    /// @notice Thrown when the PositionManager's liquidity for a position differs from the PoolManager's.
    /// @param reported The PositionManager's answer.
    /// @param actual The PoolManager's position liquidity.
    error LiquidityMismatch(uint128 reported, uint128 actual);

    /// @notice Thrown when a position holds less than its gauge's minLiquidity.
    /// @param liquidity The position's liquidity.
    /// @param minLiquidity The gauge's minLiquidity.
    error LiquidityTooLow(uint128 liquidity, uint128 minLiquidity);

    /// @notice Thrown when a lock is outside the gauge's minLockWeeks to maxLockWeeks.
    /// @param lockWeeks The lock asked.
    error InvalidLock(uint16 lockWeeks);

    /// @notice Thrown when an extension would not move the maturity later.
    /// @param maturity The maturity the extension gives.
    /// @param current The current maturity.
    error MaturityNotLater(uint48 maturity, uint48 current);

    /// @notice Thrown when a position is not staked.
    /// @param tokenId The position.
    error NotStaked(uint256 tokenId);

    /// @notice Thrown when the caller is not the position's staker.
    /// @param tokenId The position.
    /// @param caller The caller.
    error NotStaker(uint256 tokenId, address caller);

    /// @notice Thrown when a position is withdrawn before its maturity.
    /// @param tokenId The position.
    /// @param maturity Its maturity.
    error Locked(uint256 tokenId, uint48 maturity);

    /// @notice Thrown when a claim names a position staked in another pool's gauge.
    /// @param tokenId The position.
    /// @param id The pool claimed.
    error OtherGauge(uint256 tokenId, PoolId id);

    /// @notice Thrown when a recipient is zero, a PositionManager recipient sentinel (1 or 2), this contract, the
    ///         PositionManager or the PoolManager.
    /// @param recipient The recipient.
    error InvalidRecipient(address recipient);

    /// @notice Thrown when an entry is reentered.
    error Reentrancy();

    /// @notice Executes the queued ACTIVATE. Owner only, once.
    /// @dev Before it executes every gauge entry reverts `Inactive`.
    function activate() external;

    /// @notice Executes a queued ADD_REWARD_TOKEN(token), putting the token on the reward-token list. Owner only.
    /// @dev The list is for plain ERC-20s with no fee on transfer, no rebase and no transfer hooks, so a gauge's
    ///      token can never short another gauge holding the same token.
    /// @param token The token.
    function addRewardToken(address token) external;

    /// @notice Brake: takes a token off the reward-token list at once, for new gauges only; gauges that pay it keep
    ///         paying it. Owner or the registry's guardian.
    /// @dev Voids every ADD_REWARD_TOKEN(token) queued before it.
    /// @param token The token.
    function removeRewardToken(address token) external;

    /// @notice Executes a queued SET_SUPPLY_BOUND(currency, bound): the most of `currency` the sizing rule takes as
    ///         ever existing at once. Owner only.
    /// @dev For an ERC-20 holding its own code that is not a HookrToken; native ETH's bound is NATIVE_SUPPLY_BOUND and
    ///      a HookrToken's its fixed supply. Checked when queued and again here: nonzero and at least the currency's
    ///      totalSupply (InvalidSupplyBound). Declare one only for a currency whose supply at the end of a transaction
    ///      can never pass it, an issuer's mints included (a flash mint, burned before its call returns, never does): a
    ///      gauge sized against a bound that fails can see its pool leave the usable range while staked and keep paying
    ///      those stakes. Gauges already created keep their minLiquidity.
    /// @param currency The ERC-20.
    /// @param bound The bound, in the currency's raw units.
    function setSupplyBound(address currency, uint256 bound) external;

    /// @notice Brake: removes a currency's declared supply bound at once, so no new gauge can be created on a pool
    ///         that holds it. Owner or the registry's guardian.
    /// @dev Gauges already created keep running. Voids every SET_SUPPLY_BOUND(currency, any bound) queued before it.
    ///      Native ETH's bound and a HookrToken's are built in and cannot be removed (InvalidSupplyBound).
    /// @param currency The ERC-20.
    function removeSupplyBound(address currency) external;

    /// @notice Creates a pool's gauge with terms fixed for good. Called by the pool's family owner on the pinned
    ///         HookrLauncher, or by the owner executing a queued CREATE_GAUGE(key, terms).
    /// @dev The pool's hooks must be a registered Hookr root that reports this contract's PoolManager and initialized
    ///      the pool; the reward token must be listed; the terms within their bounds (InvalidTerms); minLiquidity must
    ///      meet the sizing rule (Range) against each currency's supply bound (NoSupplyBound, MinLiquidityTooLow) and
    ///      be one some full-range position of the pool could hold (MinLiquidityTooHigh); one gauge per pool, never
    ///      removed, its terms fixed for good. Refused while every gauge is paused.
    /// @param key The pool.
    /// @param terms The gauge's terms.
    function createGauge(PoolKey calldata key, Terms calldata terms) external;

    /// @notice Brake: pauses one gauge at once. Owner or the registry's guardian.
    /// @dev Stops stake, extend, notify, fund and claim on it; never withdraw, collectFees or poke. Voids every
    ///      UNPAUSE(id) queued before it.
    /// @param id The pool.
    function pause(PoolId id) external;

    /// @notice Brake: pauses every gauge at once. Owner or the registry's guardian.
    /// @dev Stops createGauge, stake, extend, notify, fund and claim everywhere; never withdraw, collectFees or poke.
    ///      Voids every UNPAUSE_ALL queued before it.
    function pauseAll() external;

    /// @notice Executes a queued UNPAUSE(id), queued while the gauge was paused. Owner only.
    /// @param id The pool.
    function unpause(PoolId id) external;

    /// @notice Executes a queued UNPAUSE_ALL, queued while every gauge was paused. Owner only.
    function unpauseAll() external;

    /// @notice Starts a tranche of `amount` plus the unassigned remainder, emitted evenly from now to the first week
    ///         boundary `durationWeeks` weeks or more ahead. The gauge's creator or the owner.
    /// @dev The caller approves `amount` first; what arrives is credited. A tranche runs beside the gauge's other
    ///      tranches and nothing changes it once started: no notify can stretch or squeeze a schedule LPs locked for,
    ///      and nothing anyone else does changes what a notify does or costs. Refused when the tranche would hold
    ///      nothing (ZeroAmount). Funding is irrevocable and only ever paid to this gauge's stakers.
    /// @param id The pool.
    /// @param amount The reward amount to pull from the caller; zero re-emits only the unassigned remainder.
    /// @param durationWeeks The tranche's length, 1 to MAX_PERIOD_WEEKS weeks, its end rounded up to a week boundary.
    function notify(PoolId id, uint256 amount, uint16 durationWeeks) external;

    /// @notice Starts a tranche of `amount`, emitted evenly from now to the first week boundary `durationWeeks` weeks
    ///         or more ahead. Anyone.
    /// @dev The caller approves `amount` first; what arrives is credited. A tranche runs beside the gauge's other
    ///      tranches and nothing changes it once started, so the tranche a funder pays for emits to the end it chose.
    ///      Funding is irrevocable and only ever paid to this gauge's stakers.
    /// @param id The pool.
    /// @param amount The reward amount to pull from the caller; nonzero.
    /// @param durationWeeks The tranche's length, 1 to MAX_PERIOD_WEEKS weeks, its end rounded up to a week boundary.
    function fund(PoolId id, uint256 amount, uint16 durationWeeks) external;

    /// @notice Stakes a full-range PositionManager position of a pool with a gauge, locked for `lockWeeks` weeks.
    /// @dev The caller owns the NFT and approved this contract for it. Verified on chain: the PositionManager's code
    ///      is the code pinned at construction; the position's info and key name the same pool, which has an unpaused
    ///      gauge; the ticks are the key's minUsableTick and maxUsableTick; no subscriber; not staked already; the
    ///      PositionManager's liquidity equals the PoolManager's own and is at least the gauge's minLiquidity.
    ///      Maturity is now + lockWeeks weeks rounded up to a week boundary. Boost: 10,000 + (maxBoostBps - 10,000) x
    ///      (lockWeeks - minLockWeeks) / (maxLockWeeks - minLockWeeks), rounded down (maxBoostBps when the bounds are
    ///      equal); weight = liquidity x boost / 10,000 until maturity, liquidity after it.
    /// @param tokenId The position.
    /// @param lockWeeks The lock, minLockWeeks to maxLockWeeks.
    function stake(uint256 tokenId, uint16 lockWeeks) external;

    /// @notice Re-locks a staked position for `lockWeeks` weeks from now and re-prices its boost. Its staker.
    /// @dev Settles the position's rewards first. The new maturity, now + lockWeeks weeks rounded up to a week
    ///      boundary, must be later than the current one; the boost follows lockWeeks and can go down.
    /// @param tokenId The position.
    /// @param lockWeeks The new lock, minLockWeeks to maxLockWeeks.
    function extend(uint256 tokenId, uint16 lockWeeks) external;

    /// @notice Returns a matured position's NFT, with its uncollected LP fees, to `recipient`. Its staker, from
    ///         maturity on, also while paused.
    /// @dev Settles the position's rewards, which stay claimable. Sends with `safeTransferFrom`: a recipient that
    ///      cannot take an ERC-721 reverts the withdrawal and the stake stays as it was.
    /// @param tokenId The position.
    /// @param recipient The receiver of the NFT.
    function withdraw(uint256 tokenId, address recipient) external;

    /// @notice Settles the caller's positions `tokenIds` in the pool's gauge and pays the caller everything the gauge
    ///         owes it.
    /// @dev `tokenIds` may be empty, to claim what was settled before, such as at a withdrawal. A reward token that
    ///      reverts reverts the claim and leaves the owed amount intact.
    /// @param id The pool.
    /// @param tokenIds The caller's positions staked in this gauge to settle first.
    /// @param recipient The receiver of the rewards.
    /// @return amount The amount paid.
    function claim(PoolId id, uint256[] calldata tokenIds, address recipient) external returns (uint256 amount);

    /// @notice Sends a staked position's LP fees straight from the PoolManager to `recipient`. Its staker, at any
    ///         time, also while locked or paused.
    /// @dev A zero-liquidity DECREASE_LIQUIDITY and a TAKE_PAIR through the PositionManager; the position's
    ///      liquidity does not change and the fees never pass through this contract.
    /// @param tokenId The position.
    /// @param recipient The receiver of the fees.
    function collectFees(uint256 tokenId, address recipient) external;

    /// @notice Brings a gauge's accrual to now: emits and applies the boosts that ended. Anyone, also while paused.
    /// @param id The pool.
    function poke(PoolId id) external;

    /// @notice Returns the week length every lock and maturity counts in, in seconds.
    /// @return 604,800.
    function WEEK() external view returns (uint256);

    /// @notice Returns the longest lock a gauge may allow, in weeks.
    /// @return 104.
    function MAX_LOCK_WEEKS() external view returns (uint16);

    /// @notice Returns the highest boost a gauge may give, in basis points of 1x.
    /// @return 30,000.
    function MAX_BOOST_BPS() external view returns (uint16);

    /// @notice Returns the longest tranche, in weeks.
    /// @return 52.
    function MAX_PERIOD_WEEKS() external view returns (uint16);

    /// @notice Returns the least minLiquidity a gauge's terms may set: no stake is ever smaller, which bounds the
    ///         reward accumulator. The sizing rule can ask for more.
    /// @return 1,000,000.
    function MIN_LIQUIDITY() external view returns (uint128);

    /// @notice Returns native ETH's supply bound in the sizing rule: more wei than can ever exist on the chain.
    /// @return 2^96, about 7.9e28 wei (79 billion ETH, over 600 times Ethereum's whole supply).
    function NATIVE_SUPPLY_BOUND() external view returns (uint256);

    /// @notice Returns the queue kind of the one-time activation (no arguments).
    /// @return keccak256("ACTIVATE").
    function ACTIVATE() external view returns (bytes32);

    /// @notice Returns the queue kind of a reward-token listing, arguments abi.encode(address token).
    /// @return keccak256("ADD_REWARD_TOKEN").
    function ADD_REWARD_TOKEN() external view returns (bytes32);

    /// @notice Returns the queue kind of a supply bound, arguments abi.encode(address currency, uint256 bound).
    /// @dev Keyed by currency alone: a removeSupplyBound(currency) voids it whatever bound it names.
    /// @return keccak256("SET_SUPPLY_BOUND").
    function SET_SUPPLY_BOUND() external view returns (bytes32);

    /// @notice Returns the queue kind of an owner-created gauge, arguments abi.encode(PoolKey key, Terms terms).
    /// @return keccak256("CREATE_GAUGE").
    function CREATE_GAUGE() external view returns (bytes32);

    /// @notice Returns the queue kind of a gauge's unpause, arguments abi.encode(PoolId id).
    /// @return keccak256("UNPAUSE").
    function UNPAUSE() external view returns (bytes32);

    /// @notice Returns the queue kind of the global unpause (no arguments).
    /// @return keccak256("UNPAUSE_ALL").
    function UNPAUSE_ALL() external view returns (bytes32);

    /// @notice Returns the PoolManager every position and pool lives in.
    /// @return The PoolManager, read from the PositionManager at construction.
    function poolManager() external view returns (IPoolManager);

    /// @notice Returns the PositionManager whose positions can be staked.
    /// @return The PositionManager pinned at construction.
    function positionManager() external view returns (IPositionManagerMinimal);

    /// @notice Returns the PositionManager's runtime code hash pinned at construction.
    /// @return The code hash every stake checks.
    function positionManagerCodeHash() external view returns (bytes32);

    /// @notice Returns the registry whose roots make a pool a Hookr pool and whose guardian may brake.
    /// @return The registry pinned at construction.
    function registry() external view returns (IHookrRegistry);

    /// @notice Returns the launcher whose family owners may create their pools' gauges.
    /// @return The HookrLauncher pinned at construction.
    function launcher() external view returns (IHookrLauncherView);

    /// @notice Returns the runtime codehash every HookrToken shares (it has no immutables): a currency with it has its
    ///         fixed supply as its supply bound.
    /// @dev The codehash fixes the code, not how the storage was written: a contract with this runtime code deployed
    ///      by other initcode can report a totalSupply below what its holders hold, a bound that fails (Range). Every
    ///      HookrToken HookrLauncher creates runs HookrToken's own constructor.
    /// @return keccak256 of HookrToken's runtime code, computed at construction.
    function hookrTokenCodeHash() external view returns (bytes32);

    /// @notice Returns whether the queued ACTIVATE has executed.
    /// @return Whether the gauges are live.
    function active() external view returns (bool);

    /// @notice Returns whether a brake has paused every gauge.
    /// @return Whether every gauge is paused.
    function pausedAll() external view returns (bool);

    /// @notice Returns whether a token is on the reward-token list.
    /// @param token The token.
    /// @return Whether new gauges may pay it.
    function rewardTokenListed(address token) external view returns (bool);

    /// @notice Returns the most of a currency the sizing rule takes as ever existing at once.
    /// @param currency The currency; zero for native ETH.
    /// @return NATIVE_SUPPLY_BOUND for native ETH, a HookrToken's fixed supply, otherwise the bound the owner declared,
    ///         and zero for a currency with none: no new gauge can be created on a pool that holds it.
    function supplyBound(address currency) external view returns (uint256);

    /// @notice Returns a pool's gauge; an unknown pool reads all zero.
    /// @param id The pool.
    /// @return The gauge, accrued only up to its lastUpdate.
    function gauge(PoolId id) external view returns (Gauge memory);

    /// @notice Returns a staked position; an unstaked one reads all zero.
    /// @param tokenId The position.
    /// @return The stake.
    function stakeOf(uint256 tokenId) external view returns (Stake memory);

    /// @notice Returns the rewards a gauge has settled for an account and not yet paid.
    /// @param id The pool.
    /// @param account The staker.
    /// @return The amount `claim` pays now without settling any position.
    function owed(PoolId id, address account) external view returns (uint256);

    /// @notice Returns what settling a staked position now would credit.
    /// @param tokenId The position.
    /// @return The rewards accrued since its last settlement.
    function pendingRewards(uint256 tokenId) external view returns (uint256);

    /// @notice Returns a gauge's maturity drop at a week boundary and its rewardPerWeightX128 there.
    /// @param id The pool.
    /// @param week The week boundary.
    /// @return drop The weight the boosts ending at `week` remove, while that boundary is ahead of the accrual.
    /// @return rewardPerWeightX128 The gauge's rewardPerWeightX128 at `week`, once the accrual has applied a maturity
    ///         drop there; zero otherwise.
    function weekState(PoolId id, uint256 week) external view returns (uint256 drop, uint256 rewardPerWeightX128);

    /// @notice Returns the rate a gauge's tranches ending at a week boundary remove from its rewardRateX128.
    /// @param id The pool.
    /// @param week The week boundary.
    /// @return The summed rate of the tranches ending at `week`, Q128 per second, while that boundary is ahead of the
    ///         accrual; zero once the accrual has applied it.
    function endingRate(PoolId id, uint256 week) external view returns (uint256);

    /// @notice Returns the boost a lock of `lockWeeks` weeks gets in a pool's gauge.
    /// @param id The pool.
    /// @param lockWeeks The lock, minLockWeeks to maxLockWeeks.
    /// @return The boost in basis points of 1x.
    function boostFor(PoolId id, uint16 lockWeeks) external view returns (uint16);
}
