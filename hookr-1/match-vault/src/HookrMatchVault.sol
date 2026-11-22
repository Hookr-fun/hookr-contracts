// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {HookrGoverned} from "hookr-1/base/HookrGoverned.sol";
import {IHookrRoot} from "hookr-1/interfaces/IHookrRoot.sol";
import {IHookrRegistry} from "hookr-1/interfaces/IHookrRegistry.sol";
import {HookrTypes} from "hookr-1/types/HookrTypes.sol";
import {IPositionManagerMinimal} from "hookr-1/interfaces/external/IPositionManagerMinimal.sol";
import {IHookrMatchVault} from "./interfaces/IHookrMatchVault.sol";
import {IHookrPriceLog} from "./interfaces/IHookrPriceLog.sol";
import {MatchMath} from "./libraries/MatchMath.sol";

/// @notice The Uniswap v4 PositionManager surface the vault uses: HookrLpBoost's, plus the next token id.
interface IMatchPositionManager is IPositionManagerMinimal {
    /// @notice The id the next minted position takes.
    function nextTokenId() external view returns (uint256);
}

/// @title HookrMatchVault
/// @notice Matches an approved asset with HOOKR. A wallet brings only the asset to the one approved ASSET/HOOKR pool of
///         that asset; the vault adds, from its own balance, the HOOKR the pool's price asks for, and mints the
///         full-range liquidity as two Uniswap v4 positions: the provider's (60% by default) and Hookr's. The vault
///         holds both until the match's unlock time (21 days by default), while the provider collects the fees. From
///         then the match's owner takes the provider's position and anyone sends Hookr's to the sink.
/// @dev Custody: a match's two PositionManager NFTs are held here. No function decreases, burns, approves or re-points
///      them; `withdraw` (the match's owner, from the unlock time) and `sweep` (anyone, from the unlock time, to the
///      sink) are the only calls that move one, each exactly once. Both are plain NFT transfers that touch no pool,
///      so no Hook Block, pause, keeper or list change can stop an unlock. Fee collection is a zero-liquidity
///      decrease, which the root never refuses.
///      Price: the HOOKR added is what a full-range mint at the pool's own price pulls, so the two sides are equal
///      in value at that price. A deposit is refused unless the price log's average over the pool's window is fresh,
///      the pool's tick and the log's newest record are within the pool's band of that average, tick and average are
///      inside the corridor the owner set and the pool holds its least liquidity. These bound the price of the add
///      against the average, not against any outside price: after a fast real move the average lags, and the limits
///      below are what bounds a loss. A record in the log weighs nothing when written, at most one is written per
///      interval and each moves at most the log's step, so no sequence of trades inside one block moves the average.
///      The mint carries the exact amounts computed from the checked price as its maxima, so a price moved between the
///      check and the mint reverts it.
///      Limits are counted in HOOKR, on live matches (a match is live until its first withdraw or sweep): per wallet,
///      per pool, in total and per UTC day. The vault's HOOKR balance is the budget: it can never add more than it
///      holds, and it holds nothing of a provider's between transactions.
///      Settings are stored, bounded by the constants below, and reach new matches only: a match keeps its unlock
///      time, its split (the two positions' liquidity) and its fee rule.
contract HookrMatchVault is HookrGoverned, IHookrMatchVault {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    /// @notice The safety range of the provider's share of the liquidity.
    uint16 public constant MIN_PROVIDER_SHARE_BPS = 5_000;
    uint16 public constant MAX_PROVIDER_SHARE_BPS = 7_500;
    /// @notice The safety range of the lock.
    uint32 public constant MIN_LOCK_SECONDS = 7 days;
    uint32 public constant MAX_LOCK_SECONDS = 26 weeks;
    /// @notice The safety range of a pool's band.
    uint24 public constant MIN_BAND_TICKS = 10;
    uint24 public constant MAX_BAND_TICKS = 500;
    /// @notice The widest corridor a pool may have, in ticks.
    uint24 public constant MAX_CORRIDOR_TICKS = 4_000;
    /// @notice The safety range of a pool's window, in intervals of its price log.
    uint32 public constant MIN_WINDOW_INTERVALS = 6;
    uint32 public constant MAX_WINDOW_INTERVALS = 48;
    /// @notice The longest a record may be allowed to stand, in intervals of the pool's price log.
    uint32 public constant MAX_STAND_INTERVALS = 4;
    /// @notice The largest step per record a pool's price log may have, in ticks.
    uint24 public constant MAX_LOG_STEP_TICKS = 500;

    /// @notice Queue kinds.
    bytes32 public constant APPROVE_POOL = keccak256("APPROVE_POOL");
    bytes32 public constant SET_POOL_SETTINGS = keccak256("SET_POOL_SETTINGS");
    bytes32 public constant SET_SETTINGS = keccak256("SET_SETTINGS");
    bytes32 public constant LIST_RULES = keccak256("LIST_RULES");
    bytes32 public constant UNPAUSE = keccak256("UNPAUSE");
    bytes32 public constant UNPAUSE_ALL = keccak256("UNPAUSE_ALL");

    uint256 private constant BPS = 10_000;
    /// @notice The gas the last fee collection inside `sweep` is given, whoever calls it. A collection that needs more
    ///         fails for every caller alike and the position still moves; a caller cannot pick a gas limit that starves
    ///         the collection while the sweep goes through.
    uint256 public constant SWEEP_FEES_GAS = 1_000_000;
    /// @dev What `sweep` needs besides the collection: the call itself, the counts, the event and the transfer.
    uint256 private constant SWEEP_TAIL_GAS = 150_000;
    /// @dev PositionManager action codes (v4-periphery Actions).
    uint8 private constant DECREASE_LIQUIDITY = 0x01;
    uint8 private constant MINT_POSITION = 0x02;
    uint8 private constant SETTLE = 0x0b;
    uint8 private constant TAKE_PAIR = 0x11;
    uint8 private constant SWEEP = 0x14;
    /// @dev keccak256("hookr.matchvault.transient.entered")
    bytes32 private constant ENTERED = 0xabfc422266f6855d18193ca93794df8807e5b6b74d61710edeaa8a998feb7789;

    /// @notice The Uniswap v4 PoolManager.
    IPoolManager public immutable poolManager;
    /// @notice The Uniswap v4 PositionManager whose NFTs the matches are.
    IMatchPositionManager public immutable positionManager;
    /// @notice The PositionManager's runtime code hash at construction; a deposit is refused if it differs.
    bytes32 public immutable positionManagerCodeHash;
    /// @notice HookrRoot: an approved pool's hook.
    IHookrRoot public immutable root;
    /// @notice The Hookr registry, whose guardian may pause new matches.
    IHookrRegistry public immutable registry;
    /// @notice HOOKR.
    IERC20 public immutable hookr;
    /// @notice The price log the approved pools' averages are read from.
    IHookrPriceLog public immutable priceLog;

    /// @inheritdoc IHookrMatchVault
    bool public allPaused;
    /// @inheritdoc IHookrMatchVault
    uint256 public matchCount;
    /// @inheritdoc IHookrMatchVault
    uint256 public globalLive;
    /// @inheritdoc IHookrMatchVault
    mapping(address rules => bool) public rulesListed;
    /// @inheritdoc IHookrMatchVault
    mapping(address owner => uint256) public liveOf;
    /// @inheritdoc IHookrMatchVault
    mapping(uint256 day => uint256) public matchedOn;
    /// @notice The approved pool of an asset; zero when it has none.
    mapping(address asset => PoolId) public poolOfAsset;

    Settings private _settings;
    PoolId[] private _approved;
    mapping(PoolId id => PoolInfo) private _pools;
    mapping(uint256 matchId => Match) private _matches;
    mapping(address owner => uint256[]) private _owned;

    /// @dev What a deposit of an amount would do now; `reason` is empty when it would go through.
    struct Plan {
        bytes32 reason;
        uint128 providerLiquidity;
        uint128 hookrLiquidity;
        // The provider's and Hookr's positions' exact mint amounts, per currency.
        uint256 p0;
        uint256 p1;
        uint256 h0;
        uint256 h1;
        uint256 asset;
        uint256 hookr;
        int24 poolTick;
        int24 averageTick;
        uint256 roomWallet;
        uint256 roomPool;
        uint256 roomDay;
        uint256 roomTotal;
    }

    /// @param positionManager_ The Uniswap v4 PositionManager; its runtime code hash is pinned here.
    /// @param root_ HookrRoot.
    /// @param hookr_ HOOKR.
    /// @param priceLog_ The price log, on the same PoolManager.
    /// @param owner_ The governance owner.
    /// @param delay_ The timelock delay.
    /// @param settings_ The first settings.
    constructor(
        IMatchPositionManager positionManager_,
        IHookrRoot root_,
        IERC20 hookr_,
        IHookrPriceLog priceLog_,
        address owner_,
        uint48 delay_,
        Settings memory settings_
    ) HookrGoverned(owner_, delay_) {
        if (
            address(positionManager_).code.length == 0 || address(root_).code.length == 0
                || address(hookr_).code.length == 0 || address(priceLog_).code.length == 0
        ) revert InvalidWiring();
        IPoolManager manager = positionManager_.poolManager();
        if (
            address(manager).code.length == 0 || address(root_.poolManager()) != address(manager)
                || address(priceLog_.manager()) != address(manager)
        ) revert InvalidWiring();
        IHookrRegistry registry_ = root_.registry();
        if (address(registry_).code.length == 0) revert InvalidWiring();
        poolManager = manager;
        positionManager = positionManager_;
        positionManagerCodeHash = address(positionManager_).codehash;
        root = root_;
        registry = registry_;
        hookr = hookr_;
        priceLog = priceLog_;
        _checkSettings(settings_);
        _settings = settings_;
        emit SettingsSet(settings_);
    }

    modifier nonReentrant() {
        if (_entered()) revert Reentrancy();
        _enter(true);
        _;
        _enter(false);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Any wallet
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IHookrMatchVault
    function deposit(DepositParams calldata p)
        external
        nonReentrant
        returns (uint256 matchId, uint256 assetUsed, uint256 hookrMatched, uint128 liquidity, uint48 unlockTime)
    {
        if (block.timestamp > p.deadline) revert DeadlinePassed();
        _checkRecipient(p.owner);
        if (address(positionManager).codehash != positionManagerCodeHash) revert PositionManagerChanged();
        // Inside an unlock a pushed price is free until the unlock settles; never match there.
        if (poolManager.isUnlocked()) revert ManagerUnlocked();
        PoolInfo storage info = _pools[p.poolId];
        if (!info.approved) revert PoolNotApproved(p.poolId);
        if (allPaused || info.paused) revert Paused();

        // The asset arrives before the price is read, so the pull itself cannot move a price already checked. The
        // asset token runs once more, when `_fill` sends it on to the PositionManager after the checks: a price it
        // moves there reverts the mint, whose maxima are the exact amounts the checked price asks for.
        IERC20 asset = IERC20(info.asset);
        uint256 assetBefore = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), p.assetAmount);
        {
            uint256 arrived = asset.balanceOf(address(this)) - assetBefore;
            if (arrived != p.assetAmount) revert AmountMismatch(p.assetAmount, arrived);
        }

        // A due record is written first. It weighs nothing in this block.
        try priceLog.record(info.settings.logId) {} catch {}

        Plan memory plan = _plan(info, p.poolId, p.owner, p.assetAmount);
        _refuse(plan);
        liquidity = plan.providerLiquidity + plan.hookrLiquidity;
        if (liquidity < p.minLiquidity) revert LiquidityTooLow(liquidity, p.minLiquidity);
        (assetUsed, hookrMatched) = (plan.asset, plan.hookr);

        uint256 firstId = positionManager.nextTokenId();
        (matchId, unlockTime) = _open(info, p.poolId, p.owner, plan, firstId);
        _fill(info.key, asset, plan, firstId);
        // What is left of the asset goes back. The mint's sweep also returns anything a third party left on the
        // PositionManager, so more may be left than computed, never less.
        uint256 unused = asset.balanceOf(address(this)) - assetBefore;
        if (unused < p.assetAmount - assetUsed) revert MintMismatch();
        if (unused != 0) asset.safeTransfer(msg.sender, unused);
    }

    /// @dev Writes the match and the live counts, before any token leaves.
    function _open(PoolInfo storage info, PoolId poolId, address owner_, Plan memory plan, uint256 firstId)
        private
        returns (uint256 matchId, uint48 unlockTime)
    {
        matchId = ++matchCount;
        unlockTime = uint48(block.timestamp + _settings.lockSeconds);
        Match storage m = _matches[matchId];
        m.owner = owner_;
        m.poolId = poolId;
        m.providerTokenId = firstId;
        m.hookrTokenId = firstId + 1;
        m.providerLiquidity = plan.providerLiquidity;
        m.hookrLiquidity = plan.hookrLiquidity;
        m.assetIn = _u128(plan.asset);
        m.hookrMatched = _u128(plan.hookr);
        m.start = uint48(block.timestamp);
        m.unlockTime = unlockTime;
        m.hookrFeesToProviderBps = _settings.hookrFeesToProviderBps;
        _owned[owner_].push(matchId);
        liveOf[owner_] += plan.hookr;
        info.live += uint128(plan.hookr);
        globalLive += plan.hookr;
        matchedOn[block.timestamp / 1 days] += plan.hookr;
        emit Matched(
            matchId,
            owner_,
            poolId,
            plan.asset,
            plan.hookr,
            plan.providerLiquidity,
            plan.hookrLiquidity,
            firstId,
            firstId + 1,
            unlockTime
        );
    }

    /// @dev Sends the two sides to the PositionManager, mints, and checks what was minted and what HOOKR left: the two
    ///      positions exactly, and no more HOOKR than computed. Less may have left, when the mint's sweep brought back
    ///      HOOKR a third party had left on the PositionManager; an exact check there would let one unit of dust
    ///      stop every deposit. Exactly two ids were taken since `firstId` was read: the asset's transfer runs the
    ///      asset's code between that read and the mint, and two positions it minted to the vault there would take
    ///      the match's ids and leave the real pair in no match.
    function _fill(PoolKey memory key, IERC20 asset, Plan memory plan, uint256 firstId) private {
        uint256 hookrBefore = hookr.balanceOf(address(this));
        asset.safeTransfer(address(positionManager), plan.asset);
        hookr.safeTransfer(address(positionManager), plan.hookr);
        _mint(key, plan);
        if (
            positionManager.nextTokenId() != firstId + 2 || positionManager.ownerOf(firstId) != address(this)
                || positionManager.ownerOf(firstId + 1) != address(this)
                || positionManager.getPositionLiquidity(firstId) != plan.providerLiquidity
                || positionManager.getPositionLiquidity(firstId + 1) != plan.hookrLiquidity
                || hookr.balanceOf(address(this)) + plan.hookr < hookrBefore
        ) revert MintMismatch();
    }

    /// @inheritdoc IHookrMatchVault
    function collectFees(uint256 matchId, address recipient)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        Match storage m = _match(matchId);
        if (msg.sender != m.owner) revert NotMatchOwner(msg.sender);
        _checkRecipient(recipient);
        (amount0, amount1) = _collect(m, recipient, !m.withdrawn, !m.swept);
        emit FeesCollected(matchId, recipient, amount0, amount1);
    }

    /// @inheritdoc IHookrMatchVault
    function withdraw(uint256 matchId, address recipient) external nonReentrant returns (uint256 providerTokenId) {
        Match storage m = _match(matchId);
        if (msg.sender != m.owner) revert NotMatchOwner(msg.sender);
        _checkRecipient(recipient);
        if (block.timestamp < m.unlockTime) revert StillLocked(m.unlockTime);
        if (m.withdrawn) revert AlreadyWithdrawn();
        if (!m.swept) _release(m);
        m.withdrawn = true;
        providerTokenId = m.providerTokenId;
        emit Withdrawn(matchId, recipient, providerTokenId);
        positionManager.safeTransferFrom(address(this), recipient, providerTokenId);
    }

    /// @inheritdoc IHookrMatchVault
    function sweep(uint256 matchId) external nonReentrant returns (uint256 hookrTokenId) {
        Match storage m = _match(matchId);
        if (block.timestamp < m.unlockTime) revert StillLocked(m.unlockTime);
        if (m.swept) revert AlreadySwept();
        // The last fees on Hookr's position go to the match's owner first. A failure there never holds the position.
        bool collected;
        if (gasleft() < SWEEP_FEES_GAS + SWEEP_FEES_GAS / 63 + SWEEP_TAIL_GAS) revert NotEnoughGas();
        try this.sweepFees{gas: SWEEP_FEES_GAS}(matchId) {
            collected = true;
        } catch {}
        if (!m.withdrawn) _release(m);
        m.swept = true;
        hookrTokenId = m.hookrTokenId;
        address sink = _settings.hookrSink;
        emit Swept(matchId, sink, hookrTokenId, collected);
        positionManager.transferFrom(address(this), sink, hookrTokenId);
    }

    /// @notice The fee collection inside `sweep`, as a call of its own so that `sweep` survives its failure.
    /// @dev Only the vault calls it, from inside `sweep`.
    function sweepFees(uint256 matchId) external {
        if (msg.sender != address(this)) revert OnlySelf();
        Match storage m = _matches[matchId];
        (uint256 amount0, uint256 amount1) = _collect(m, m.owner, false, true);
        emit FeesCollected(matchId, m.owner, amount0, amount1);
    }

    /// @inheritdoc IHookrMatchVault
    function record(PoolId poolId) external returns (bool written) {
        PoolInfo storage info = _pools[poolId];
        if (!info.approved) revert PoolNotApproved(poolId);
        return priceLog.record(info.settings.logId);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // The owner, through the queue
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Approves one pool for its asset. The pool is known to the root, its hook is the root, one side is HOOKR,
    ///         its Rules are listed, it has no advisory, it holds its least liquidity and its price log is open on it.
    function approvePool(PoolKey calldata key, PoolSettings calldata s) external onlyOwner {
        _consume(APPROVE_POOL, abi.encode(key, s));
        (PoolId id, address asset, bool hookrIs0) = _checkPool(key);
        _checkPoolSettings(key, id, s, true);
        PoolInfo storage info = _pools[id];
        info.key = key;
        info.asset = asset;
        info.hookrIs0 = hookrIs0;
        info.approved = true;
        info.settings = s;
        poolOfAsset[asset] = id;
        _approved.push(id);
        emit PoolApproved(id, asset, key, s);
    }

    /// @notice Replaces an approved pool's settings, for new matches.
    function setPoolSettings(PoolId id, PoolSettings calldata s) external onlyOwner {
        _consume(SET_POOL_SETTINGS, abi.encode(id, s));
        PoolInfo storage info = _pools[id];
        if (!info.approved) revert PoolNotApproved(id);
        _checkPoolSettings(info.key, id, s, false);
        info.settings = s;
        emit PoolSettingsSet(id, s);
    }

    /// @notice Replaces the settings, for new matches.
    function setSettings(Settings calldata s) external onlyOwner {
        _consume(SET_SETTINGS, abi.encode(s));
        _checkSettings(s);
        _settings = s;
        emit SettingsSet(s);
    }

    /// @notice Lists or delists a Rules contract whose pools may be approved.
    function listRules(address rules, bool listed) external onlyOwner {
        _consume(LIST_RULES, abi.encode(rules, listed));
        if (listed) _requireDeployedCode(rules);
        rulesListed[rules] = listed;
        emit RulesListed(rules, listed);
    }

    /// @notice Lifts a pool's pause.
    function unpause(PoolId id) external onlyOwner {
        PoolInfo storage info = _pools[id];
        if (!info.paused) revert NotPaused();
        _consume(UNPAUSE, abi.encode(id));
        info.paused = false;
        emit PoolPauseSet(id, false, msg.sender);
    }

    /// @notice Lifts the pause on everything.
    function unpauseAll() external onlyOwner {
        if (!allPaused) revert NotPaused();
        _consume(UNPAUSE_ALL, "");
        allPaused = false;
        emit AllPauseSet(false, msg.sender);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // At once
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Pauses new matches on a pool. The owner or the registry's guardian. Exits are never paused.
    function pause(PoolId id) external {
        _onlyBrake();
        PoolInfo storage info = _pools[id];
        if (!info.approved) revert PoolNotApproved(id);
        info.paused = true;
        _invalidateQueued(_subjectKey(UNPAUSE, abi.encode(id)));
        emit PoolPauseSet(id, true, msg.sender);
    }

    /// @notice Takes a pool off the list for good, at once: no new match on it, and its asset is free for another
    ///         pool. Its live matches keep everything: fees, withdraw and sweep read the pool's stored key. The owner.
    ///         A brake: every approval or settings change of this pool queued before it is void.
    function retirePool(PoolId id) external onlyOwner {
        PoolInfo storage info = _pools[id];
        if (!info.approved) revert PoolNotApproved(id);
        info.approved = false;
        _invalidateQueued(_poolEpochKey(id));
        poolOfAsset[info.asset] = PoolId.wrap(bytes32(0));
        uint256 n = _approved.length;
        for (uint256 i; i < n; ++i) {
            if (PoolId.unwrap(_approved[i]) == PoolId.unwrap(id)) {
                _approved[i] = _approved[n - 1];
                _approved.pop();
                break;
            }
        }
        emit PoolRetired(id, info.asset, msg.sender);
    }

    /// @notice Pauses new matches on every pool. The owner or the registry's guardian. Exits are never paused.
    function pauseAll() external {
        _onlyBrake();
        allPaused = true;
        _invalidateQueued(UNPAUSE_ALL);
        emit AllPauseSet(true, msg.sender);
    }

    /// @notice Takes back tokens the vault holds outside any match: its HOOKR budget, or Hookr's part of collected
    ///         fees. The vault holds nothing of a provider's between transactions; positions are not reachable here.
    function withdrawIdle(address token, uint256 amount, address to) external onlyOwner nonReentrant {
        _checkRecipient(to);
        if (token == address(positionManager) || token == address(poolManager)) revert InvalidRecipient(token);
        IERC20(token).safeTransfer(to, amount);
        emit IdleWithdrawn(token, to, amount);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IHookrMatchVault
    function approvedPools() external view returns (PoolId[] memory) {
        return _approved;
    }

    /// @inheritdoc IHookrMatchVault
    function pool(PoolId poolId) external view returns (PoolInfo memory) {
        return _pools[poolId];
    }

    /// @inheritdoc IHookrMatchVault
    function settings() external view returns (Settings memory) {
        return _settings;
    }

    /// @inheritdoc IHookrMatchVault
    function matchOf(uint256 matchId) external view returns (Match memory) {
        return _match(matchId);
    }

    /// @inheritdoc IHookrMatchVault
    function matchesOf(address owner_, uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        uint256[] storage all = _owned[owner_];
        uint256 n = all.length;
        if (offset >= n) return new uint256[](0);
        uint256 end = limit > n - offset ? n : offset + limit;
        ids = new uint256[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            ids[i - offset] = all[i];
        }
    }

    /// @inheritdoc IHookrMatchVault
    function quote(PoolId poolId, uint256 assetAmount, address owner_) external view returns (Quote memory q) {
        PoolInfo storage info = _pools[poolId];
        Plan memory plan = _plan(info, poolId, owner_, assetAmount);
        q.reason = plan.reason;
        q.ok = plan.reason == bytes32(0);
        (q.poolTick, q.averageTick) = (plan.poolTick, plan.averageTick);
        (q.roomWallet, q.roomPool, q.roomDay, q.roomTotal) =
            (plan.roomWallet, plan.roomPool, plan.roomDay, plan.roomTotal);
        if (q.ok) {
            (q.assetUsed, q.hookrMatched) = (plan.asset, plan.hookr);
            q.providerLiquidity = plan.providerLiquidity;
            q.liquidity = plan.providerLiquidity + plan.hookrLiquidity;
            q.unlockTime = uint48(block.timestamp + _settings.lockSeconds);
        }
    }

    /// @inheritdoc IHookrMatchVault
    function pendingFees(uint256 matchId) external view returns (uint256 amount0, uint256 amount1) {
        Match storage m = _match(matchId);
        PoolKey memory key = _pools[m.poolId].key;
        if (!m.withdrawn) (amount0, amount1) = _pending(key, m.poolId, m.providerTokenId);
        if (!m.swept) {
            (uint256 h0, uint256 h1) = _pending(key, m.poolId, m.hookrTokenId);
            amount0 += h0 * m.hookrFeesToProviderBps / BPS;
            amount1 += h1 * m.hookrFeesToProviderBps / BPS;
        }
    }

    /// @inheritdoc IHookrMatchVault
    function available() external view returns (uint256 balance, uint256 roomDay, uint256 roomTotal) {
        balance = hookr.balanceOf(address(this));
        roomDay = _room(_settings.dayCap, matchedOn[block.timestamp / 1 days]);
        roomTotal = _room(_settings.globalCap, globalLive);
        if (balance < roomTotal) roomTotal = balance;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev What a deposit of `assetAmount` for `owner_` would do now. Never reverts on a refusal: it names it.
    function _plan(PoolInfo storage info, PoolId id, address owner_, uint256 assetAmount)
        private
        view
        returns (Plan memory plan)
    {
        Settings memory s = _settings;
        plan.roomWallet = _room(s.maxHookrPerWallet, liveOf[owner_]);
        plan.roomPool = _room(info.settings.poolCap, info.live);
        plan.roomDay = _room(s.dayCap, matchedOn[block.timestamp / 1 days]);
        plan.roomTotal = _room(s.globalCap, globalLive);
        uint256 balance = hookr.balanceOf(address(this));
        if (balance < plan.roomTotal) plan.roomTotal = balance;
        if (!info.approved) {
            plan.reason = "NOT_APPROVED";
            return plan;
        }
        if (allPaused || info.paused) {
            plan.reason = "PAUSED";
            return plan;
        }

        PoolSettings memory ps = info.settings;
        (uint160 sqrtP, int24 tick,,) = poolManager.getSlot0(id);
        plan.poolTick = tick;
        (bool ok, int24 average) = priceLog.meanFresh(ps.logId, ps.window, ps.maxStand);
        if (!ok) {
            plan.reason = "NO_AVERAGE";
            return plan;
        }
        plan.averageTick = average;
        if (tick < ps.tickMin || tick > ps.tickMax || average < ps.tickMin || average > ps.tickMax) {
            plan.reason = "OUT_OF_CORRIDOR";
            return plan;
        }
        // The newest record must be within the band of the average too. After a real move the records step toward
        // the new price while the average lags an hour behind; the pool's tick can be pushed back to the average for
        // one transaction, the newest record cannot.
        if (
            MatchMath.tickDistance(tick, average) > ps.bandTicks
                || MatchMath.tickDistance(_newestPastRecord(ps.logId), average) > ps.bandTicks
        ) {
            plan.reason = "PRICE_MOVING";
            return plan;
        }
        if (poolManager.getLiquidity(id) < ps.minPoolLiquidity) {
            plan.reason = "POOL_TOO_THIN";
            return plan;
        }

        uint256 room = plan.roomWallet;
        if (plan.roomPool < room) room = plan.roomPool;
        if (plan.roomDay < room) room = plan.roomDay;
        if (plan.roomTotal < room) room = plan.roomTotal;
        if (room < s.minHookrPerMatch) {
            plan.reason = "VAULT_EMPTY";
            return plan;
        }

        // The corridor sits strictly inside the usable ticks (checked when set), so sqrtA < sqrtP < sqrtB here.
        // No match can use more asset than this, and the liquidity math below cannot overflow under it.
        if (assetAmount > type(uint128).max) assetAmount = type(uint128).max;
        int24 spacing = info.key.tickSpacing;
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(spacing));
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(spacing));
        bool hookrIs0 = info.hookrIs0;
        // Sized from one unit less of each side: two mints round up at most one unit more per currency than one
        // mint of the sum, so the first try fits whatever a raw unit is worth (an asset of 6 or 8 decimals included).
        uint256 l = hookrIs0
            ? MatchMath.liquidityForAmount1(sqrtA, sqrtP, assetAmount == 0 ? 0 : assetAmount - 1)
            : MatchMath.liquidityForAmount0(sqrtP, sqrtB, assetAmount == 0 ? 0 : assetAmount - 1);
        {
            uint256 lRoom = hookrIs0
                ? MatchMath.liquidityForAmount0(sqrtP, sqrtB, room - 1)
                : MatchMath.liquidityForAmount1(sqrtA, sqrtP, room - 1);
            if (lRoom < l) l = lRoom;
            if (l > type(uint128).max) l = type(uint128).max;
        }
        // Two mints round up twice per currency; step the liquidity down until both sides fit.
        for (uint256 i; i < 6 && l != 0; ++i) {
            plan.providerLiquidity = uint128(l * s.providerShareBps / BPS);
            plan.hookrLiquidity = uint128(l) - plan.providerLiquidity;
            (plan.p0, plan.p1) = MatchMath.amountsForLiquidity(sqrtP, sqrtA, sqrtB, plan.providerLiquidity);
            (plan.h0, plan.h1) = MatchMath.amountsForLiquidity(sqrtP, sqrtA, sqrtB, plan.hookrLiquidity);
            (plan.asset, plan.hookr) =
                hookrIs0 ? (plan.p1 + plan.h1, plan.p0 + plan.h0) : (plan.p0 + plan.h0, plan.p1 + plan.h1);
            if (plan.asset <= assetAmount && plan.hookr <= room) break;
            l = l - l / 1e15 - 1;
            plan.asset = type(uint256).max;
        }
        if (
            l == 0 || plan.asset > assetAmount || plan.hookr > room || plan.providerLiquidity == 0
                || plan.hookrLiquidity == 0 || plan.hookr < s.minHookrPerMatch
        ) {
            plan.reason = "BELOW_MINIMUM";
            return plan;
        }
        // Uniswap v4 caps the liquidity that may reference one tick. Every full-range position references the same two,
        // and filling one to the cap costs dust far from the price: then no full-range add lands. Name it.
        uint256 cap = Pool.tickSpacingToMaxLiquidityPerTick(spacing);
        uint256 total = uint256(plan.providerLiquidity) + plan.hookrLiquidity;
        (uint128 grossLow,) = poolManager.getTickLiquidity(id, TickMath.minUsableTick(spacing));
        (uint128 grossHigh,) = poolManager.getTickLiquidity(id, TickMath.maxUsableTick(spacing));
        if (grossLow + total > cap || grossHigh + total > cap) plan.reason = "RANGE_FULL";
    }

    /// @dev The tick of the newest record written before this block. A record written in this block (by this deposit,
    ///      or by anyone earlier in the transaction or the block) is at a price that block can set, so it never counts
    ///      here, as it never weighs in the average. The log holds at least the window's records whenever the average
    ///      is fresh, so the one before is there.
    function _newestPastRecord(bytes32 logId) private view returns (int24) {
        IHookrPriceLog.Record memory r = priceLog.latest(logId);
        if (r.time >= block.timestamp) r = priceLog.recordAt(logId, 1);
        return r.tick;
    }

    /// @dev Reverts with the error that names the plan's refusal.
    function _refuse(Plan memory plan) private view {
        bytes32 reason = plan.reason;
        if (reason == bytes32(0)) return;
        if (reason == "NO_AVERAGE") revert AverageUnavailable();
        if (reason == "OUT_OF_CORRIDOR") revert PriceOutOfCorridor(plan.poolTick, plan.averageTick);
        if (reason == "PRICE_MOVING") revert PriceOutOfBand(plan.poolTick, plan.averageTick);
        if (reason == "POOL_TOO_THIN") revert PoolTooThin();
        if (reason == "RANGE_FULL") revert RangeFull();
        if (reason == "VAULT_EMPTY") revert NothingAvailable();
        revert BelowMinimum(plan.hookr, _settings.minHookrPerMatch);
    }

    /// @dev One PositionManager call: mint the provider's position, mint Hookr's, settle both currencies from the
    ///      tokens just sent to the PositionManager, and sweep back whatever it still holds of either. The maxima are
    ///      the exact amounts computed from the checked price: a price that moved since reverts the mint.
    function _mint(PoolKey memory key, Plan memory plan) private {
        int24 lower = TickMath.minUsableTick(key.tickSpacing);
        int24 upper = TickMath.maxUsableTick(key.tickSpacing);
        bytes[] memory params = new bytes[](6);
        params[0] = abi.encode(
            key, lower, upper, uint256(plan.providerLiquidity), _u128(plan.p0), _u128(plan.p1), address(this), bytes("")
        );
        params[1] = abi.encode(
            key, lower, upper, uint256(plan.hookrLiquidity), _u128(plan.h0), _u128(plan.h1), address(this), bytes("")
        );
        params[2] = abi.encode(key.currency0, uint256(0), false);
        params[3] = abi.encode(key.currency1, uint256(0), false);
        params[4] = abi.encode(key.currency0, address(this));
        params[5] = abi.encode(key.currency1, address(this));
        positionManager.modifyLiquidities(
            abi.encode(abi.encodePacked(MINT_POSITION, MINT_POSITION, SETTLE, SETTLE, SWEEP, SWEEP), params),
            block.timestamp
        );
    }

    /// @dev Collects the fees of the provider's position (`provider`) and of Hookr's (`hookrSide`) and sends the
    ///      provider's part to `recipient`. Hookr's part of its own position's fees, if any, stays in the vault.
    function _collect(Match storage m, address recipient, bool provider, bool hookrSide)
        private
        returns (uint256 amount0, uint256 amount1)
    {
        PoolKey memory key = _pools[m.poolId].key;
        IERC20 t0 = IERC20(Currency.unwrap(key.currency0));
        IERC20 t1 = IERC20(Currency.unwrap(key.currency1));
        (uint256 r0, uint256 r1) = (t0.balanceOf(recipient), t1.balanceOf(recipient));
        uint256 share = m.hookrFeesToProviderBps;
        bool direct = hookrSide && share == BPS;
        if (provider || direct) {
            _take(key, provider ? m.providerTokenId : 0, direct ? m.hookrTokenId : 0, recipient);
        }
        if (hookrSide && !direct) {
            (uint256 v0, uint256 v1) = (t0.balanceOf(address(this)), t1.balanceOf(address(this)));
            _take(key, 0, m.hookrTokenId, address(this));
            if (share != 0) {
                uint256 d0 = (t0.balanceOf(address(this)) - v0) * share / BPS;
                uint256 d1 = (t1.balanceOf(address(this)) - v1) * share / BPS;
                if (d0 != 0) t0.safeTransfer(recipient, d0);
                if (d1 != 0) t1.safeTransfer(recipient, d1);
            }
        }
        amount0 = t0.balanceOf(recipient) - r0;
        amount1 = t1.balanceOf(recipient) - r1;
    }

    /// @dev A zero-liquidity decrease of one or two positions (a zero id is skipped), with what it frees sent to `to`.
    function _take(PoolKey memory key, uint256 firstId, uint256 secondId, address to) private {
        uint256 n = (firstId != 0 ? 1 : 0) + (secondId != 0 ? 1 : 0);
        bytes memory actions = n == 2
            ? abi.encodePacked(DECREASE_LIQUIDITY, DECREASE_LIQUIDITY, TAKE_PAIR)
            : abi.encodePacked(DECREASE_LIQUIDITY, TAKE_PAIR);
        bytes[] memory params = new bytes[](n + 1);
        uint256 i;
        if (firstId != 0) params[i++] = abi.encode(firstId, uint256(0), uint128(0), uint128(0), bytes(""));
        if (secondId != 0) params[i++] = abi.encode(secondId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[i] = abi.encode(key.currency0, key.currency1, to);
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    /// @dev A position's uncollected fees: its liquidity times the fee growth inside the full range since its last
    ///      touch, as the PoolManager computes them.
    function _pending(PoolKey memory key, PoolId id, uint256 tokenId) private view returns (uint256 f0, uint256 f1) {
        int24 lower = TickMath.minUsableTick(key.tickSpacing);
        int24 upper = TickMath.maxUsableTick(key.tickSpacing);
        (uint128 liquidity, uint256 last0, uint256 last1) = poolManager.getPositionInfo(
            id, Position.calculatePositionKey(address(positionManager), lower, upper, bytes32(tokenId))
        );
        (uint256 inside0, uint256 inside1) = poolManager.getFeeGrowthInside(id, lower, upper);
        unchecked {
            f0 = FullMath.mulDiv(inside0 - last0, liquidity, FixedPoint128.Q128);
            f1 = FullMath.mulDiv(inside1 - last1, liquidity, FixedPoint128.Q128);
        }
    }

    /// @dev A match leaves the live counts at its first withdraw or sweep.
    function _release(Match storage m) private {
        uint256 amount = m.hookrMatched;
        liveOf[m.owner] -= amount;
        _pools[m.poolId].live -= uint128(amount);
        globalLive -= amount;
    }

    function _match(uint256 matchId) private view returns (Match storage m) {
        m = _matches[matchId];
        if (m.owner == address(0)) revert UnknownMatch(matchId);
    }

    function _room(uint256 cap, uint256 used) private pure returns (uint256) {
        return used >= cap ? 0 : cap - used;
    }

    function _u128(uint256 x) private pure returns (uint128) {
        if (x > type(uint128).max) revert MintMismatch();
        return uint128(x);
    }

    function _checkRecipient(address recipient) private view {
        if (
            recipient == address(0) || recipient == address(this) || recipient == address(positionManager)
                || recipient == address(poolManager)
            // The PositionManager reads 1 as its caller (the vault) and 2 as itself.
            || recipient == address(1) || recipient == address(2)
        ) revert InvalidRecipient(recipient);
    }

    function _onlyBrake() private view {
        if (msg.sender != _owner() && msg.sender != registry.guardian()) revert Unauthorized(msg.sender);
    }

    /// @dev A pool that may be approved: not approved yet, its asset has no pool yet, its hook is the root, the root
    ///      opened it, one side is HOOKR and the other an ERC-20, its Rules are listed and it has no advisory.
    function _checkPool(PoolKey memory key) private view returns (PoolId id, address asset, bool hookrIs0) {
        id = key.toId();
        if (_pools[id].approved) revert PoolAlreadyApproved(id);
        if (address(key.hooks) != address(root)) revert InvalidPool("hooks");
        (address c0, address c1) = (Currency.unwrap(key.currency0), Currency.unwrap(key.currency1));
        if (c0 == address(hookr)) (asset, hookrIs0) = (c1, true);
        else if (c1 == address(hookr)) asset = c0;
        else revert InvalidPool("hookr");
        if (asset == address(0) || asset == address(hookr)) revert InvalidPool("asset");
        if (PoolId.unwrap(poolOfAsset[asset]) != bytes32(0)) revert AssetAlreadyApproved(asset);
        if (!root.knownPool(id)) revert InvalidPool("unknown");
        HookrTypes.PoolConfig memory config = root.poolConfig(id);
        if (!rulesListed[config.rules]) revert InvalidPool("rules");
        if (config.advisory != address(0)) revert InvalidPool("advisory");
    }

    /// @dev A pool's settings inside their ranges, and its price log open on it with a step no larger than the
    ///      widest band. `approving` also asks the pool to hold its least liquidity now.
    function _checkPoolSettings(PoolKey memory key, PoolId id, PoolSettings memory s, bool approving) private view {
        if (s.bandTicks < MIN_BAND_TICKS || s.bandTicks > MAX_BAND_TICKS) revert InvalidSettings("bandTicks");
        if (s.minPoolLiquidity == 0 || (approving && poolManager.getLiquidity(id) < s.minPoolLiquidity)) {
            revert InvalidSettings("minPoolLiquidity");
        }
        if (
            s.tickMin >= s.tickMax || uint256(int256(s.tickMax) - int256(s.tickMin)) > MAX_CORRIDOR_TICKS
                || s.tickMin <= TickMath.minUsableTick(key.tickSpacing)
                || s.tickMax >= TickMath.maxUsableTick(key.tickSpacing)
        ) revert InvalidSettings("corridor");
        if (s.poolCap > _settings.globalCap) revert InvalidSettings("poolCap");
        if (!priceLog.isOpen(s.logId) || PoolId.unwrap(priceLog.poolOf(s.logId)) != PoolId.unwrap(id)) {
            revert InvalidSettings("logId");
        }
        IHookrPriceLog.Params memory lp = priceLog.params(s.logId);
        if (lp.maxMoveTicks > MAX_LOG_STEP_TICKS) revert InvalidSettings("logStep");
        // The log marks a record thin at least whenever the pool is under its least liquidity, and its first record
        // is held to a seed price.
        if (lp.minLiquidity < s.minPoolLiquidity) revert InvalidSettings("logLiquidity");
        if (!lp.hasSeedTick) revert InvalidSettings("logSeed");
        uint256 interval = lp.interval;
        if (s.window < interval * MIN_WINDOW_INTERVALS || s.window > interval * MAX_WINDOW_INTERVALS) {
            revert InvalidSettings("window");
        }
        if (s.maxStand < interval || s.maxStand > interval * MAX_STAND_INTERVALS) revert InvalidSettings("maxStand");
    }

    function _checkSettings(Settings memory s) private view {
        if (s.providerShareBps < MIN_PROVIDER_SHARE_BPS || s.providerShareBps > MAX_PROVIDER_SHARE_BPS) {
            revert InvalidSettings("providerShareBps");
        }
        if (s.hookrFeesToProviderBps > BPS) revert InvalidSettings("hookrFeesToProviderBps");
        if (s.lockSeconds < MIN_LOCK_SECONDS || s.lockSeconds > MAX_LOCK_SECONDS) revert InvalidSettings("lockSeconds");
        if (s.minHookrPerMatch == 0) revert InvalidSettings("minHookrPerMatch");
        if (s.maxHookrPerWallet > s.globalCap) revert InvalidSettings("maxHookrPerWallet");
        if (s.dayCap > s.globalCap) revert InvalidSettings("dayCap");
        if (
            s.hookrSink == address(0) || s.hookrSink == address(this) || s.hookrSink == address(positionManager)
                || s.hookrSink == address(poolManager)
        ) revert InvalidSettings("hookrSink");
    }

    /// @dev Queue-time admission: only the kinds above, with canonical arguments that would pass now.
    function _checkQueue(bytes32 kind, bytes calldata arguments) internal view override {
        if (kind == APPROVE_POOL) {
            (PoolKey memory key, PoolSettings memory s) = abi.decode(arguments, (PoolKey, PoolSettings));
            (PoolId id,,) = _checkPool(key);
            _checkPoolSettings(key, id, s, true);
            _requireCanonical(kind, arguments, abi.encode(key, s));
        } else if (kind == SET_POOL_SETTINGS) {
            (PoolId id, PoolSettings memory s) = abi.decode(arguments, (PoolId, PoolSettings));
            if (!_pools[id].approved) revert PoolNotApproved(id);
            _checkPoolSettings(_pools[id].key, id, s, false);
            _requireCanonical(kind, arguments, abi.encode(id, s));
        } else if (kind == SET_SETTINGS) {
            Settings memory s = abi.decode(arguments, (Settings));
            _checkSettings(s);
            _requireCanonical(kind, arguments, abi.encode(s));
        } else if (kind == LIST_RULES) {
            (address rules, bool listed) = abi.decode(arguments, (address, bool));
            if (listed) _requireDeployedCode(rules);
            _requireCanonical(kind, arguments, abi.encode(rules, listed));
        } else if (kind == UNPAUSE) {
            PoolId id = abi.decode(arguments, (PoolId));
            if (!_pools[id].paused) revert NotPaused();
            _requireCanonical(kind, arguments, abi.encode(id));
        } else if (kind == UNPAUSE_ALL) {
            if (!allPaused) revert NotPaused();
            _requireCanonical(kind, arguments, "");
        } else if (kind == TRANSFER_OWNER) {
            super._checkQueue(kind, arguments);
        } else {
            revert UnknownOperation(kind);
        }
    }

    /// @dev A pool's unpause is keyed by the pool, so a pause voids only that pool's queued unpause. A pool's approval
    ///      and its settings changes share one key per pool, so `retirePool` voids both for that pool only.
    function _epochKey(bytes32 kind, bytes memory arguments) internal pure override returns (bytes32) {
        if (kind == UNPAUSE) return _subjectKey(kind, arguments);
        if (kind == APPROVE_POOL) {
            (PoolKey memory key,) = abi.decode(arguments, (PoolKey, PoolSettings));
            return _poolEpochKey(key.toId());
        }
        if (kind == SET_POOL_SETTINGS) {
            (PoolId id,) = abi.decode(arguments, (PoolId, PoolSettings));
            return _poolEpochKey(id);
        }
        return kind;
    }

    function _poolEpochKey(PoolId id) private pure returns (bytes32) {
        return keccak256(abi.encode(APPROVE_POOL, SET_POOL_SETTINGS, id));
    }

    function _subjectKey(bytes32 kind, bytes memory arguments) private pure returns (bytes32) {
        return keccak256(abi.encode(kind, arguments));
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
