// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {HookrGoverned} from "../base/HookrGoverned.sol";
import {HookrReleased} from "../base/HookrReleased.sol";
import {IHookrLpBoost} from "../interfaces/IHookrLpBoost.sol";
import {IHookrRegistry} from "../interfaces/IHookrRegistry.sol";
import {IHookrRoot} from "../interfaces/IHookrRoot.sol";
import {IHookrLauncherView} from "../interfaces/IHookrLauncherView.sol";
import {IPositionManagerMinimal} from "../interfaces/external/IPositionManagerMinimal.sol";
import {HookrToken} from "../support/HookrToken.sol";

/// @title HookrLpBoost
/// @notice LP time-lock boost rewards on full-range Uniswap v4 positions of Hookr pools, one gauge per pool.
/// @dev Custody: a staked position's NFT is held here; nothing changes its liquidity, and only its staker's
///      `withdraw`, from maturity on, sends it out. An NFT sent here by a plain `transferFrom` instead of `stake` is
///      not a stake and nothing can move it; a `safeTransferFrom` here reverts (no `onERC721Received`).
///      Only full-range positions are staked: Uniswap v4 keeps no time-in-range data, so no contract outside the hook
///      can know how long a concentrated position was out of range, while a full-range position is in range at every
///      tick of the usable range. The sizing rule `createGauge` enforces keeps the pool's price in that range at the
///      end of every transaction while anyone is staked and the pool's supply bounds hold (IHookrLpBoost Range), and
///      time passes only between transactions, so every interval with weight is in range: the accrual reads no pool
///      state, and nothing done inside a transaction (a PoolManager unlock, a flash mint, a round trip of settled
///      swaps) changes what an interval pays.
///      Accrual (per gauge): every notify and every fund is its own tranche, whose amount emits evenly from its start
///      to its end, a week boundary; nothing changes a tranche once it has started. The gauge's rate is the sum of its
///      running tranches' rates, and the budget left (`scheduled`) emits in proportion to what those rates still emit
///      (`emissionLeftX128`), so each tranche's amount has emitted by its end and the whole budget by the last end;
///      emitted rewards grow rewardPerWeightX128 by emitted x 2^128 / totalWeight. Maturities and tranche ends sit on
///      week boundaries; each update walks the boundaries up to the latest one holding a boost or a tranche that ends
///      there, at most 106 weeks past the previous update, and at each one records the accumulator and removes the
///      boosts and rates ending there.
contract HookrLpBoost is HookrReleased, HookrGoverned, IHookrLpBoost {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    /// @inheritdoc IHookrLpBoost
    uint256 public constant WEEK = 7 days;
    /// @inheritdoc IHookrLpBoost
    uint16 public constant MAX_LOCK_WEEKS = 104;
    /// @inheritdoc IHookrLpBoost
    uint16 public constant MAX_BOOST_BPS = 30_000;
    /// @inheritdoc IHookrLpBoost
    uint16 public constant MAX_PERIOD_WEEKS = 52;
    /// @inheritdoc IHookrLpBoost
    uint128 public constant MIN_LIQUIDITY = 1_000_000;
    /// @inheritdoc IHookrLpBoost
    uint256 public constant NATIVE_SUPPLY_BOUND = 2 ** 96;
    /// @inheritdoc IHookrLpBoost
    bytes32 public constant ACTIVATE = keccak256("ACTIVATE");
    /// @inheritdoc IHookrLpBoost
    bytes32 public constant ADD_REWARD_TOKEN = keccak256("ADD_REWARD_TOKEN");
    /// @inheritdoc IHookrLpBoost
    bytes32 public constant SET_SUPPLY_BOUND = keccak256("SET_SUPPLY_BOUND");
    /// @inheritdoc IHookrLpBoost
    bytes32 public constant CREATE_GAUGE = keccak256("CREATE_GAUGE");
    /// @inheritdoc IHookrLpBoost
    bytes32 public constant UNPAUSE = keccak256("UNPAUSE");
    /// @inheritdoc IHookrLpBoost
    bytes32 public constant UNPAUSE_ALL = keccak256("UNPAUSE_ALL");

    /// @dev 1x in basis points.
    uint16 private constant BPS = 10_000;
    /// @dev PositionManager action codes (v4-periphery Actions): DECREASE_LIQUIDITY and TAKE_PAIR.
    uint8 private constant DECREASE_LIQUIDITY = 0x01;
    uint8 private constant TAKE_PAIR = 0x11;
    /// @dev The PositionManager reads these recipients as its caller and as itself (ActionConstants).
    address private constant MSG_SENDER = address(1);
    address private constant ADDRESS_THIS = address(2);
    /// @dev keccak256("hookr.lpboost.transient.entered")
    bytes32 private constant ENTERED = 0xd6f48cfd815400adfb51e71a66b632643f404429e2dfccf64d53064548762f77;

    /// @inheritdoc IHookrLpBoost
    IPoolManager public immutable poolManager;
    /// @inheritdoc IHookrLpBoost
    IPositionManagerMinimal public immutable positionManager;
    /// @inheritdoc IHookrLpBoost
    bytes32 public immutable positionManagerCodeHash;
    /// @inheritdoc IHookrLpBoost
    IHookrRegistry public immutable registry;
    /// @inheritdoc IHookrLpBoost
    IHookrLauncherView public immutable launcher;
    /// @inheritdoc IHookrLpBoost
    bytes32 public immutable hookrTokenCodeHash;

    /// @inheritdoc IHookrLpBoost
    bool public active;
    /// @inheritdoc IHookrLpBoost
    bool public pausedAll;
    /// @inheritdoc IHookrLpBoost
    mapping(address token => bool) public rewardTokenListed;
    /// @inheritdoc IHookrLpBoost
    mapping(PoolId id => mapping(address account => uint256)) public owed;

    /// @dev The supply bounds the owner declared through SET_SUPPLY_BOUND; zero where none is declared.
    mapping(address currency => uint256) private _supplyBounds;
    mapping(PoolId id => Gauge) private _gauges;
    mapping(uint256 tokenId => Stake) private _stakes;
    mapping(PoolId id => mapping(uint256 week => uint256)) private _drops;
    mapping(PoolId id => mapping(uint256 week => uint256)) private _rateDrops;
    mapping(PoolId id => mapping(uint256 week => uint256)) private _rewardPerWeightAt;

    /// @param registry_ The Hookr registry: its roots make a pool a Hookr pool and its guardian may brake.
    /// @param launcher_ HookrLauncher, whose family owners may create their pools' gauges.
    /// @param positionManager_ The Uniswap v4 PositionManager; its runtime code hash is pinned here.
    /// @param owner_ The governance owner.
    /// @param delay_ The timelock delay.
    constructor(
        IHookrRegistry registry_,
        IHookrLauncherView launcher_,
        IPositionManagerMinimal positionManager_,
        address owner_,
        uint48 delay_
    ) HookrGoverned(owner_, delay_) {
        if (
            address(registry_).code.length == 0 || address(launcher_).code.length == 0
                || address(positionManager_).code.length == 0
        ) revert InvalidWiring();
        IPoolManager manager = positionManager_.poolManager();
        if (address(manager).code.length == 0 || address(registry_.poolManager()) != address(manager)) {
            revert InvalidWiring();
        }
        poolManager = manager;
        positionManager = positionManager_;
        positionManagerCodeHash = address(positionManager_).codehash;
        registry = registry_;
        launcher = launcher_;
        hookrTokenCodeHash = keccak256(type(HookrToken).runtimeCode);
    }

    modifier nonReentrant() {
        if (_entered()) revert Reentrancy();
        _enter(true);
        _;
        _enter(false);
    }

    modifier whenActive() {
        if (!active) revert Inactive();
        _;
    }

    /// @inheritdoc IHookrLpBoost
    function activate() external onlyOwner {
        if (active) revert AlreadyActive();
        _consume(ACTIVATE, "");
        active = true;
        emit Activated();
    }

    /// @inheritdoc IHookrLpBoost
    function addRewardToken(address token) external onlyOwner whenActive {
        _consume(ADD_REWARD_TOKEN, abi.encode(token));
        rewardTokenListed[token] = true;
        emit RewardTokenSet(token, true, msg.sender);
    }

    /// @inheritdoc IHookrLpBoost
    function removeRewardToken(address token) external whenActive {
        _onlyBrake();
        rewardTokenListed[token] = false;
        _invalidateQueued(_subjectKey(ADD_REWARD_TOKEN, abi.encode(token)));
        emit RewardTokenSet(token, false, msg.sender);
    }

    /// @inheritdoc IHookrLpBoost
    function setSupplyBound(address currency, uint256 bound) external onlyOwner whenActive {
        _consume(SET_SUPPLY_BOUND, abi.encode(currency, bound));
        _checkSupplyBound(currency, bound);
        _supplyBounds[currency] = bound;
        emit SupplyBoundSet(currency, bound, msg.sender);
    }

    /// @inheritdoc IHookrLpBoost
    function removeSupplyBound(address currency) external whenActive {
        _onlyBrake();
        if (currency == address(0) || currency.codehash == hookrTokenCodeHash) revert InvalidSupplyBound(currency, 0);
        delete _supplyBounds[currency];
        _invalidateQueued(_subjectKey(SET_SUPPLY_BOUND, abi.encode(currency)));
        emit SupplyBoundSet(currency, 0, msg.sender);
    }

    /// @inheritdoc IHookrLpBoost
    function createGauge(PoolKey calldata key, Terms calldata terms) external nonReentrant whenActive {
        if (pausedAll) revert AllPaused();
        PoolId id = key.toId();
        if (msg.sender == _owner()) {
            _consume(CREATE_GAUGE, abi.encode(key, terms));
        } else if (msg.sender != launcher.familyOwner(launcher.poolFamily(id))) {
            revert NotFamilyOwner(msg.sender);
        }
        _checkGauge(id, key, terms);
        Gauge storage g = _gauges[id];
        g.key = key;
        g.creator = msg.sender;
        g.terms = terms;
        g.lastUpdate = uint48(block.timestamp);
        emit GaugeCreated(id, msg.sender, terms.rewardToken, key, terms);
    }

    /// @inheritdoc IHookrLpBoost
    function pause(PoolId id) external whenActive {
        _onlyBrake();
        _gauge(id).paused = true;
        _invalidateQueued(_subjectKey(UNPAUSE, abi.encode(id)));
        emit GaugePauseSet(id, true, msg.sender);
    }

    /// @inheritdoc IHookrLpBoost
    function pauseAll() external whenActive {
        _onlyBrake();
        pausedAll = true;
        _invalidateQueued(UNPAUSE_ALL);
        emit AllPauseSet(true, msg.sender);
    }

    /// @inheritdoc IHookrLpBoost
    function unpause(PoolId id) external onlyOwner whenActive {
        _consume(UNPAUSE, abi.encode(id));
        _gauge(id).paused = false;
        emit GaugePauseSet(id, false, msg.sender);
    }

    /// @inheritdoc IHookrLpBoost
    function unpauseAll() external onlyOwner whenActive {
        _consume(UNPAUSE_ALL, "");
        pausedAll = false;
        emit AllPauseSet(false, msg.sender);
    }

    /// @inheritdoc IHookrLpBoost
    function notify(PoolId id, uint256 amount, uint16 durationWeeks) external nonReentrant whenActive {
        Gauge storage g = _open(id);
        if (msg.sender != g.creator && msg.sender != _owner()) revert NotGaugeCreator(msg.sender);
        _checkDuration(durationWeeks);
        _update(id, g);
        uint256 received = amount == 0 ? 0 : _pull(id, g, amount);
        uint256 tranche = received + g.unassigned;
        g.unassigned = 0;
        uint48 finish = _schedule(id, g, tranche, durationWeeks);
        emit Notified(id, msg.sender, received, tranche, finish);
    }

    /// @inheritdoc IHookrLpBoost
    function fund(PoolId id, uint256 amount, uint16 durationWeeks) external nonReentrant whenActive {
        Gauge storage g = _open(id);
        if (amount == 0) revert ZeroAmount();
        _checkDuration(durationWeeks);
        _update(id, g);
        uint256 received = _pull(id, g, amount);
        uint48 finish = _schedule(id, g, received, durationWeeks);
        emit Funded(id, msg.sender, received, finish);
    }

    /// @inheritdoc IHookrLpBoost
    function stake(uint256 tokenId, uint16 lockWeeks) external nonReentrant whenActive {
        if (address(positionManager).codehash != positionManagerCodeHash) revert PositionManagerChanged();
        (PoolKey memory key, uint256 info) = positionManager.getPoolAndPositionInfo(tokenId);
        PoolId id = key.toId();
        if (uint256(PoolId.unwrap(id)) >> 56 != info >> 56) revert PoolMismatch(tokenId);
        Gauge storage g = _open(id);
        (int24 tickLower, int24 tickUpper) = (int24(int256(info >> 8)), int24(int256(info >> 32)));
        if (
            tickLower != TickMath.minUsableTick(key.tickSpacing) || tickUpper != TickMath.maxUsableTick(key.tickSpacing)
        ) {
            revert NotFullRange(tickLower, tickUpper);
        }
        if (uint8(info) != 0) revert HasSubscriber(tokenId);
        if (_stakes[tokenId].owner != address(0)) revert AlreadyStaked(tokenId);
        if (positionManager.ownerOf(tokenId) != msg.sender) revert NotPositionOwner(tokenId, msg.sender);
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        uint128 actual = poolManager.getPositionLiquidity(
            id, Position.calculatePositionKey(address(positionManager), tickLower, tickUpper, bytes32(tokenId))
        );
        if (liquidity != actual) revert LiquidityMismatch(liquidity, actual);
        uint128 minLiquidity = g.terms.minLiquidity;
        if (liquidity < minLiquidity) revert LiquidityTooLow(liquidity, minLiquidity);
        _update(id, g);
        (uint48 maturity, uint16 boostBps) = _lock(g.terms, lockWeeks, g.lastUpdate);
        uint256 weight = _weight(liquidity, boostBps);
        g.totalWeight += weight;
        _addDrop(id, g, maturity, weight - liquidity);
        _stakes[tokenId] = Stake(msg.sender, maturity, boostBps, liquidity, id, g.rewardPerWeightX128);
        positionManager.transferFrom(msg.sender, address(this), tokenId);
        emit Staked(tokenId, id, msg.sender, liquidity, lockWeeks, maturity, boostBps);
    }

    /// @inheritdoc IHookrLpBoost
    function extend(uint256 tokenId, uint16 lockWeeks) external nonReentrant whenActive {
        Stake storage s = _staked(tokenId);
        PoolId id = s.poolId;
        Gauge storage g = _open(id);
        _update(id, g);
        (uint48 maturity, uint16 boostBps) = _lock(g.terms, lockWeeks, g.lastUpdate);
        uint48 current = s.maturity;
        if (maturity <= current) revert MaturityNotLater(maturity, current);
        _settle(id, g, s, tokenId);
        uint256 liquidity = s.liquidity;
        uint256 previous = _weight(liquidity, s.boostBps);
        // A boost still carried after the settlement ends at `current`, where its drop is pending.
        if (previous != liquidity) _drops[id][current] -= previous - liquidity;
        uint256 weight = _weight(liquidity, boostBps);
        g.totalWeight = g.totalWeight - previous + weight;
        _addDrop(id, g, maturity, weight - liquidity);
        s.maturity = maturity;
        s.boostBps = boostBps;
        emit Extended(tokenId, lockWeeks, maturity, boostBps);
    }

    /// @inheritdoc IHookrLpBoost
    function withdraw(uint256 tokenId, address recipient) external nonReentrant whenActive {
        Stake storage s = _staked(tokenId);
        _checkRecipient(recipient);
        PoolId id = s.poolId;
        Gauge storage g = _gauges[id];
        _update(id, g);
        if (g.lastUpdate < s.maturity) revert Locked(tokenId, s.maturity);
        _settle(id, g, s, tokenId);
        g.totalWeight -= s.liquidity;
        delete _stakes[tokenId];
        positionManager.safeTransferFrom(address(this), recipient, tokenId);
        emit Withdrawn(tokenId, msg.sender, recipient);
    }

    /// @inheritdoc IHookrLpBoost
    function claim(PoolId id, uint256[] calldata tokenIds, address recipient)
        external
        nonReentrant
        whenActive
        returns (uint256 amount)
    {
        Gauge storage g = _open(id);
        _checkRecipient(recipient);
        if (tokenIds.length != 0) {
            _update(id, g);
            for (uint256 i; i < tokenIds.length; ++i) {
                Stake storage s = _staked(tokenIds[i]);
                if (PoolId.unwrap(s.poolId) != PoolId.unwrap(id)) revert OtherGauge(tokenIds[i], id);
                _settle(id, g, s, tokenIds[i]);
            }
        }
        amount = owed[id][msg.sender];
        if (amount != 0) {
            owed[id][msg.sender] = 0;
            g.paid += uint128(amount);
            IERC20(g.terms.rewardToken).safeTransfer(recipient, amount);
            emit Claimed(id, msg.sender, recipient, amount);
        }
    }

    /// @inheritdoc IHookrLpBoost
    function collectFees(uint256 tokenId, address recipient) external nonReentrant whenActive {
        Stake storage s = _staked(tokenId);
        _checkRecipient(recipient);
        PoolKey storage key = _gauges[s.poolId].key;
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, recipient);
        positionManager.modifyLiquidities(
            abi.encode(abi.encodePacked(DECREASE_LIQUIDITY, TAKE_PAIR), params), block.timestamp
        );
        emit FeesCollected(tokenId, recipient);
    }

    /// @inheritdoc IHookrLpBoost
    function poke(PoolId id) external nonReentrant whenActive {
        _update(id, _gauge(id));
    }

    /// @inheritdoc IHookrLpBoost
    function gauge(PoolId id) external view returns (Gauge memory) {
        return _gauges[id];
    }

    /// @inheritdoc IHookrLpBoost
    function stakeOf(uint256 tokenId) external view returns (Stake memory) {
        return _stakes[tokenId];
    }

    /// @inheritdoc IHookrLpBoost
    function pendingRewards(uint256 tokenId) external view returns (uint256) {
        Stake memory s = _stakes[tokenId];
        if (s.owner == address(0)) return 0;
        PoolId id = s.poolId;
        Gauge storage g = _gauges[id];
        uint256 last = g.lastUpdate;
        uint256 acc = g.rewardPerWeightX128;
        uint256 atMaturity = s.maturity <= last ? _rewardPerWeightAt[id][s.maturity] : 0;
        if (block.timestamp > last) {
            uint256 scheduled = g.scheduled;
            uint256 left = g.emissionLeftX128;
            uint256 rate = g.rewardRateX128;
            uint256 weight = g.totalWeight;
            (uint256 lastDrop, uint256 lastEnd, uint256 end) = _walkBounds(g);
            for (uint256 week = (last / WEEK + 1) * WEEK; week <= end; week += WEEK) {
                (uint256 drop, uint256 rateDrop) = _weekDrops(id, week, lastDrop, lastEnd);
                if (drop != 0 || rateDrop != 0) {
                    (scheduled, left, acc) = _accrued(scheduled, left, acc, rate, weight, week - last);
                    if (week == s.maturity) atMaturity = acc;
                    weight -= drop;
                    rate -= rateDrop;
                    last = week;
                }
            }
            (,, acc) = _accrued(scheduled, left, acc, rate, weight, block.timestamp - last);
        }
        uint256 liquidity = s.liquidity;
        if (s.boostBps > BPS && s.maturity <= (block.timestamp > last ? block.timestamp : last)) {
            return FullMath.mulDiv(
                _weight(liquidity, s.boostBps), atMaturity - s.rewardPerWeightLastX128, FixedPoint128.Q128
            ) + FullMath.mulDiv(liquidity, acc - atMaturity, FixedPoint128.Q128);
        }
        return FullMath.mulDiv(_weight(liquidity, s.boostBps), acc - s.rewardPerWeightLastX128, FixedPoint128.Q128);
    }

    /// @inheritdoc IHookrLpBoost
    function weekState(PoolId id, uint256 week) external view returns (uint256 drop, uint256 rewardPerWeightX128) {
        return (_drops[id][week], _rewardPerWeightAt[id][week]);
    }

    /// @inheritdoc IHookrLpBoost
    function endingRate(PoolId id, uint256 week) external view returns (uint256) {
        return _rateDrops[id][week];
    }

    /// @inheritdoc IHookrLpBoost
    function supplyBound(address currency) external view returns (uint256) {
        return _supplyBound(currency);
    }

    /// @inheritdoc IHookrLpBoost
    function boostFor(PoolId id, uint16 lockWeeks) external view returns (uint16) {
        Terms storage terms = _gauge(id).terms;
        if (lockWeeks < terms.minLockWeeks || lockWeeks > terms.maxLockWeeks) revert InvalidLock(lockWeeks);
        return _boost(terms, lockWeeks);
    }

    /// @dev Queue-time admission: ACTIVATE once with no arguments; ADD_REWARD_TOKEN for an unlisted token holding its
    ///      own code; SET_SUPPLY_BOUND for a bound `setSupplyBound` would accept now; CREATE_GAUGE for a pool and terms
    ///      `createGauge` would accept now; UNPAUSE for a paused gauge and UNPAUSE_ALL while every gauge is paused;
    ///      TRANSFER_OWNER. Every other kind is refused, and every arguments encoding must be canonical.
    function _checkQueue(bytes32 kind, bytes calldata arguments) internal view override {
        if (kind == ACTIVATE) {
            if (active) revert AlreadyActive();
            _requireCanonical(kind, arguments, "");
        } else if (kind == ADD_REWARD_TOKEN) {
            address token = abi.decode(arguments, (address));
            _requireDeployedCode(token);
            if (token == address(positionManager) || token == address(poolManager) || token == address(this)) {
                revert InvalidRewardToken(token);
            }
            if (rewardTokenListed[token]) revert AlreadyListed(token);
            _requireCanonical(kind, arguments, abi.encode(token));
        } else if (kind == SET_SUPPLY_BOUND) {
            (address currency, uint256 bound) = abi.decode(arguments, (address, uint256));
            _checkSupplyBound(currency, bound);
            _requireCanonical(kind, arguments, abi.encode(currency, bound));
        } else if (kind == CREATE_GAUGE) {
            (PoolKey memory key, Terms memory terms) = abi.decode(arguments, (PoolKey, Terms));
            _checkGauge(key.toId(), key, terms);
            _requireCanonical(kind, arguments, abi.encode(key, terms));
        } else if (kind == UNPAUSE) {
            PoolId id = abi.decode(arguments, (PoolId));
            if (!_gauge(id).paused) revert GaugeNotPaused(id);
            _requireCanonical(kind, arguments, abi.encode(id));
        } else if (kind == UNPAUSE_ALL) {
            if (!pausedAll) revert NotAllPaused();
            _requireCanonical(kind, arguments, "");
        } else if (kind == TRANSFER_OWNER) {
            super._checkQueue(kind, arguments);
        } else {
            revert UnknownOperation(kind);
        }
    }

    /// @dev UNPAUSE and ADD_REWARD_TOKEN are keyed by their subject and SET_SUPPLY_BOUND by its currency alone, so a
    ///      brake voids only the operations that would undo it, whatever bound they name.
    function _epochKey(bytes32 kind, bytes memory arguments) internal pure override returns (bytes32) {
        if (kind == SET_SUPPLY_BOUND) return _subjectKey(kind, abi.encode(abi.decode(arguments, (address))));
        return kind == UNPAUSE || kind == ADD_REWARD_TOKEN ? _subjectKey(kind, arguments) : kind;
    }

    function _subjectKey(bytes32 kind, bytes memory arguments) private pure returns (bytes32) {
        return keccak256(abi.encode(kind, arguments));
    }

    /// @dev A new gauge: none yet for the pool, a listed token, terms within bounds, a Hookr pool (its hooks a
    ///      registered root that reports this PoolManager and initialized the pool), the sizing rule: a full-range
    ///      position of minLiquidity owns more currency0 on the usable range's lower edge, and more currency1 on its
    ///      upper edge, than that currency's supply bound (SqrtPriceMath's amounts, rounded down); and a minLiquidity
    ///      some full-range position of the pool could hold (`_checkCeiling`).
    function _checkGauge(PoolId id, PoolKey memory key, Terms memory terms) private view {
        if (_gauges[id].terms.rewardToken != address(0)) revert GaugeExists(id);
        if (!rewardTokenListed[terms.rewardToken]) revert RewardTokenNotListed(terms.rewardToken);
        if (
            terms.minLockWeeks == 0 || terms.minLockWeeks > terms.maxLockWeeks || terms.maxLockWeeks > MAX_LOCK_WEEKS
                || terms.maxBoostBps < BPS || terms.maxBoostBps > MAX_BOOST_BPS || terms.minLiquidity < MIN_LIQUIDITY
        ) revert InvalidTerms();
        address root = address(key.hooks);
        if (
            !registry.isRoot(root) || address(IHookrRoot(root).poolManager()) != address(poolManager)
                || !IHookrRoot(root).knownPool(id)
        ) revert InvalidPool(id);
        uint160 lower = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(key.tickSpacing));
        uint160 upper = TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(key.tickSpacing));
        uint256 b0 = _checkSized(key.currency0, SqrtPriceMath.getAmount0Delta(lower, upper, terms.minLiquidity, false));
        uint256 b1 = _checkSized(key.currency1, SqrtPriceMath.getAmount1Delta(lower, upper, terms.minLiquidity, false));
        _checkCeiling(terms.minLiquidity, key.tickSpacing, lower, upper, b0, b1);
    }

    /// @dev Reverts unless `atEdge`, what a full-range position of the terms' minLiquidity owns of `currency` on the
    ///      edge where it owns nothing else, is above the currency's supply bound; returns that bound.
    function _checkSized(Currency currency, uint256 atEdge) private view returns (uint256 bound) {
        address token = Currency.unwrap(currency);
        bound = _supplyBound(token);
        if (bound == 0) revert NoSupplyBound(token);
        if (atEdge <= bound) revert MinLiquidityTooLow(token, atEdge, bound);
    }

    /// @dev Reverts unless some full-range position of the pool could hold `minLiquidity`. Every full-range position
    ///      adds to the usable range's two ticks, so none holds more than v4's maximum liquidity per tick for the tick
    ///      spacing. And with a and b the usable range's edge prices (sqrt, Q96 removed), a position of L at a sqrt
    ///      price p between them holds L x (1/p - 1/b) of currency0 and L x (p - a) of currency1, so some price funds
    ///      it within the supply bounds b0 and b1 only while L x L x (b - a) <= L x (a x b x b0 + b1) + b0 x b1 x b,
    ///      which fails for every L > B + sqrt(C), B = (a x b x b0 + b1) / (b - a) and C = b0 x b1 x b / (b - a):
    ///      checked as (L - B) x (L - B) > C with B and C rounded up. Once b0 x b1 reaches 2^255, sqrt(C) is above
    ///      every maximum liquidity per tick, which then binds alone.
    function _checkCeiling(
        uint128 minLiquidity,
        int24 tickSpacing,
        uint160 lower,
        uint160 upper,
        uint256 b0,
        uint256 b1
    ) private pure {
        uint256 liquidity = minLiquidity;
        if (liquidity > Pool.tickSpacingToMaxLiquidityPerTick(tickSpacing)) revert MinLiquidityTooHigh(minLiquidity);
        if (b0 > type(uint256).max / b1) return;
        unchecked {
            uint256 product = b0 * b1;
            if (product >> 255 != 0) return;
            uint256 span = upper - lower;
            uint256 c = FullMath.mulDivRoundingUp(product, upper, span);
            uint256 b = FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(lower, upper, FixedPoint96.Q96), b0, span)
                + FullMath.mulDivRoundingUp(b1, FixedPoint96.Q96, span);
            if (liquidity > b && (liquidity - b) * (liquidity - b) > c) revert MinLiquidityTooHigh(minLiquidity);
        }
    }

    /// @dev A declarable bound: for an ERC-20 holding its own code that is not a HookrToken, nonzero and at least its
    ///      current totalSupply. Native ETH and a HookrToken have their bound built in.
    function _checkSupplyBound(address currency, uint256 bound) private view {
        _requireDeployedCode(currency);
        if (bound == 0 || currency.codehash == hookrTokenCodeHash || bound < IERC20(currency).totalSupply()) {
            revert InvalidSupplyBound(currency, bound);
        }
    }

    /// @dev NATIVE_SUPPLY_BOUND for native ETH, the fixed supply of a HookrToken (its runtime codehash), otherwise the
    ///      owner's declared bound; zero when there is none.
    function _supplyBound(address currency) private view returns (uint256) {
        if (currency == address(0)) return NATIVE_SUPPLY_BOUND;
        if (currency.codehash == hookrTokenCodeHash) return IERC20(currency).totalSupply();
        return _supplyBounds[currency];
    }

    /// @dev The owner, or the registry's guardian (IHookrRegistry.guardian, read live; zero is no guardian). The owner
    ///      is checked first, so its brakes never depend on the read.
    function _onlyBrake() private view {
        if (msg.sender != _owner() && msg.sender != registry.guardian()) revert Unauthorized(msg.sender);
    }

    /// @dev Brings the gauge to now. Each week boundary at which boosts or tranches end closes in order: accrual up to
    ///      it, its rewardPerWeightX128 recorded where boosts end, its drops removed.
    function _update(PoolId id, Gauge storage g) private {
        uint256 last = g.lastUpdate;
        if (block.timestamp <= last) return;
        (uint256 lastDrop, uint256 lastEnd, uint256 end) = _walkBounds(g);
        for (uint256 week = (last / WEEK + 1) * WEEK; week <= end; week += WEEK) {
            (uint256 drop, uint256 rateDrop) = _weekDrops(id, week, lastDrop, lastEnd);
            if (drop != 0 || rateDrop != 0) {
                _accrue(id, g, week);
                uint256 acc = g.rewardPerWeightX128;
                if (drop != 0) {
                    _rewardPerWeightAt[id][week] = acc;
                    g.totalWeight -= drop;
                    delete _drops[id][week];
                }
                if (rateDrop != 0) {
                    g.rewardRateX128 -= rateDrop;
                    delete _rateDrops[id][week];
                }
                emit WeekClosed(id, week, drop, rateDrop, acc);
            }
        }
        _accrue(id, g, block.timestamp);
    }

    /// @dev Emits from lastUpdate to `to`, where no boost or tranche ends in between, into rewardPerWeightX128, or into
    ///      the unassigned remainder when the gauge has no weight.
    function _accrue(PoolId id, Gauge storage g, uint256 to) private {
        uint256 rate = g.rewardRateX128;
        if (rate != 0) {
            uint256 scheduled = g.scheduled;
            uint256 weight = g.totalWeight;
            (uint256 rest, uint256 left, uint256 acc) =
                _accrued(scheduled, g.emissionLeftX128, g.rewardPerWeightX128, rate, weight, to - g.lastUpdate);
            g.emissionLeftX128 = left;
            if (rest != scheduled) {
                g.scheduled = uint128(rest);
                if (weight != 0) {
                    g.rewardPerWeightX128 = acc;
                } else {
                    g.unassigned += uint128(scheduled - rest);
                    emit Unassigned(id, scheduled - rest);
                }
            }
        }
        g.lastUpdate = uint48(to);
    }

    /// @dev The budget left, the emission left and the accumulator after `elapsed` seconds in which no boost or tranche
    ///      ends: the running tranches use rate x elapsed of the emission left, and the budget emits in that
    ///      proportion, scheduled x used / left rounded down, which is all of it once the last tranche ends (used =
    ///      left); it grows the accumulator by emitted x 2^128 / weight, rounded down, only when the weight is nonzero.
    function _accrued(uint256 scheduled, uint256 left, uint256 acc, uint256 rate, uint256 weight, uint256 elapsed)
        private
        pure
        returns (uint256, uint256, uint256)
    {
        if (rate == 0 || elapsed == 0) return (scheduled, left, acc);
        uint256 used = rate * elapsed;
        uint256 emitted = FullMath.mulDiv(scheduled, used, left);
        if (weight != 0) acc += FullMath.mulDiv(emitted, FixedPoint128.Q128, weight);
        return (scheduled - emitted, left - used, acc);
    }

    /// @dev The latest boost drop, the latest tranche end, and the last week boundary an update made now walks to.
    function _walkBounds(Gauge storage g) private view returns (uint256 lastDrop, uint256 lastEnd, uint256 end) {
        lastDrop = g.lastDropWeek;
        lastEnd = g.periodFinish;
        end = lastDrop > lastEnd ? lastDrop : lastEnd;
        if (block.timestamp < end) end = block.timestamp;
    }

    /// @dev The boost weight and the tranche rate ending at `week`, each read only within its own bound.
    function _weekDrops(PoolId id, uint256 week, uint256 lastDrop, uint256 lastEnd)
        private
        view
        returns (uint256 drop, uint256 rateDrop)
    {
        if (week <= lastDrop) drop = _drops[id][week];
        if (week <= lastEnd) rateDrop = _rateDrops[id][week];
    }

    /// @dev Starts a tranche of `amount` at the gauge's clock, ending at the first week boundary `durationWeeks`
    ///      weeks or more ahead: its rate, amount x 2^128 / its length in seconds rounded down, joins the gauge's rate
    ///      until that boundary, and what the rate emits by then joins the emission left.
    function _schedule(PoolId id, Gauge storage g, uint256 amount, uint16 durationWeeks)
        private
        returns (uint48 finish)
    {
        if (amount == 0) revert ZeroAmount();
        uint256 clock = g.lastUpdate;
        finish = _weekCeil(clock + uint256(durationWeeks) * WEEK);
        uint256 length = finish - clock;
        uint256 rate = FullMath.mulDiv(amount, FixedPoint128.Q128, length);
        g.scheduled += uint128(amount);
        g.rewardRateX128 += rate;
        g.emissionLeftX128 += rate * length;
        _rateDrops[id][finish] += rate;
        if (finish > g.periodFinish) g.periodFinish = finish;
    }

    /// @dev A tranche runs 1 to MAX_PERIOD_WEEKS weeks.
    function _checkDuration(uint16 durationWeeks) private pure {
        if (durationWeeks == 0 || durationWeeks > MAX_PERIOD_WEEKS) revert InvalidDuration(durationWeeks);
    }

    /// @dev Credits a stake's rewards since its checkpoint to its staker. A boosted stake whose maturity the accrual
    ///      has passed earns its boosted weight up to the maturity and its liquidity after it, and is 1x from then on.
    function _settle(PoolId id, Gauge storage g, Stake storage s, uint256 tokenId) private {
        uint256 acc = g.rewardPerWeightX128;
        uint256 last = s.rewardPerWeightLastX128;
        uint256 liquidity = s.liquidity;
        uint16 boostBps = s.boostBps;
        uint256 reward;
        if (boostBps > BPS && s.maturity <= g.lastUpdate) {
            uint256 atMaturity = _rewardPerWeightAt[id][s.maturity];
            reward = FullMath.mulDiv(_weight(liquidity, boostBps), atMaturity - last, FixedPoint128.Q128)
                + FullMath.mulDiv(liquidity, acc - atMaturity, FixedPoint128.Q128);
            s.boostBps = BPS;
        } else {
            reward = FullMath.mulDiv(_weight(liquidity, boostBps), acc - last, FixedPoint128.Q128);
        }
        s.rewardPerWeightLastX128 = acc;
        if (reward != 0) {
            address staker = s.owner;
            owed[id][staker] += reward;
            emit RewardsAccrued(tokenId, staker, reward);
        }
    }

    function _addDrop(PoolId id, Gauge storage g, uint48 week, uint256 drop) private {
        if (drop == 0) return;
        _drops[id][week] += drop;
        if (week > g.lastDropWeek) g.lastDropWeek = week;
    }

    /// @dev Pulls `amount` of the gauge's reward token from the caller and credits what arrived.
    function _pull(PoolId id, Gauge storage g, uint256 amount) private returns (uint256 received) {
        IERC20 token = IERC20(g.terms.rewardToken);
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        received = token.balanceOf(address(this)) - before;
        if (received == 0) revert NothingReceived();
        uint256 funded = g.funded + received;
        if (funded > type(uint128).max) revert FundingOverflow(id);
        g.funded = uint128(funded);
    }

    /// @dev The maturity (`clock` + lockWeeks weeks, rounded up to a week boundary) and boost of a lock within the
    ///      terms. `clock` is the gauge's lastUpdate after its update, never behind block.timestamp, so a maturity is
    ///      always ahead of the accrual walk.
    function _lock(Terms storage terms, uint16 lockWeeks, uint256 clock)
        private
        view
        returns (uint48 maturity, uint16 boostBps)
    {
        if (lockWeeks < terms.minLockWeeks || lockWeeks > terms.maxLockWeeks) revert InvalidLock(lockWeeks);
        maturity = _weekCeil(clock + uint256(lockWeeks) * WEEK);
        boostBps = _boost(terms, lockWeeks);
    }

    /// @dev `time` rounded up to a week boundary.
    function _weekCeil(uint256 time) private pure returns (uint48) {
        return uint48((time + WEEK - 1) / WEEK * WEEK);
    }

    /// @dev Linear from 1x at minLockWeeks to maxBoostBps at maxLockWeeks, rounded down.
    function _boost(Terms storage terms, uint16 lockWeeks) private view returns (uint16) {
        if (terms.maxLockWeeks == terms.minLockWeeks) return terms.maxBoostBps;
        return uint16(
            BPS + uint256(terms.maxBoostBps - BPS) * (lockWeeks - terms.minLockWeeks)
                / (terms.maxLockWeeks - terms.minLockWeeks)
        );
    }

    function _weight(uint256 liquidity, uint16 boostBps) private pure returns (uint256) {
        return liquidity * boostBps / BPS;
    }

    function _gauge(PoolId id) private view returns (Gauge storage g) {
        g = _gauges[id];
        if (g.terms.rewardToken == address(0)) revert UnknownGauge(id);
    }

    function _open(PoolId id) private view returns (Gauge storage g) {
        g = _gauge(id);
        if (pausedAll) revert AllPaused();
        if (g.paused) revert GaugeIsPaused(id);
    }

    function _staked(uint256 tokenId) private view returns (Stake storage s) {
        s = _stakes[tokenId];
        address staker = s.owner;
        if (staker == address(0)) revert NotStaked(tokenId);
        if (staker != msg.sender) revert NotStaker(tokenId, msg.sender);
    }

    function _checkRecipient(address recipient) private view {
        if (
            recipient == address(0) || recipient == MSG_SENDER || recipient == ADDRESS_THIS
                || recipient == address(this) || recipient == address(positionManager)
                || recipient == address(poolManager)
        ) revert InvalidRecipient(recipient);
    }

    function _entered() private view returns (bool entered) {
        bytes32 slot = ENTERED;
        assembly ("memory-safe") {
            entered := tload(slot)
        }
    }

    function _enter(bool entered) private {
        bytes32 slot = ENTERED;
        assembly ("memory-safe") {
            tstore(slot, entered)
        }
    }
}
