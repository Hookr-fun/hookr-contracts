// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IHookrRegistry} from "hookr/interfaces/IHookrRegistry.sol";
import {HookrReleased} from "hookr/base/HookrReleased.sol";
import {IHookrModuleMarket} from "./interfaces/IHookrModuleMarket.sol";
import {IHookrBondVault} from "./interfaces/IHookrBondVault.sol";
import {IHookrUsageFeeRouter} from "./interfaces/IHookrUsageFeeRouter.sol";
import {TransientReentrancyGuard} from "./libraries/TransientReentrancyGuard.sol";

/// @title HookrBondVault
/// @notice Holds the $HOOKR bonded behind each module version and streams the backers' share of that
///         version's usage fees to everyone whose $HOOKR is posted behind it (developer and backers alike).
///
///      Bonds. Per version, stakes are shares of that version's assets. Assets are tracked internally, never
///      read from `balanceOf`, so a donation changes nobody's claim. A slash reduces assets and leaves shares
///      alone, so it lands pro rata on developer and backers. Every stake is locked until the market releases
///      the version (exit notice, drained installs, cooldown) or a full slash terminates it; there is no early
///      exit, which is what makes "publish, win adoption, pull the bond, vanish" impossible.
///
///      Backer rewards. Each collected backers' share is streamed per currency, merged with what is still
///      streaming, over at most REWARD_WINDOW (7 days). So a stake placed just before a large collection earns
///      only for the time it is actually posted: capturing a fee stream needs the capital to sit there, and the
///      capital cannot leave before release. Rounding is always down, so payouts can never exceed what was
///      funded; emissions that fall while nobody is staked, or after a full slash has emptied the bond (shares
///      with no assets earn nothing), are recorded as stranded and swept to the version's reserve.
///
///      Reward currencies. A version starts streaming a currency only while it is reviewed: native ETH or an asset
///      in the registry's timelocked quote catalog (`canNotify`); once listed, it streams for good. The router keeps
///      the backers' share in any other quote for the version's reserve. Nobody can therefore pick the currencies a
///      version earns in, and those that stake, withdraw and a full slash settle grow only with the catalog (a
///      first-come cap would let anyone fill every slot with dust quotes).
///
///      Units: shares and assets are raw token units; the accumulator is scaled by 1e36 per share, which keeps
///      a 6-decimal quote meaningful against a 250,000-token bond.
contract HookrBondVault is HookrReleased, TransientReentrancyGuard, IHookrBondVault {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    /// @notice A notification's amount streams over this window; merged with what is still streaming, the merged
    ///         stream ends between the running stream's own end and this window from now, weighted by amount.
    uint64 public constant REWARD_WINDOW = 7 days;
    uint256 private constant RATE_SCALE = 1e18;
    uint256 private constant ACC_SCALE = 1e36;
    uint256 private constant BPS = 10_000;

    /// @inheritdoc IHookrBondVault
    address public immutable market;
    /// @notice The bond token.
    IERC20 public immutable hookr;
    /// @notice Smallest stake: one whole bond token. Keeps every holder's shares at or above 1e18-scale.
    uint256 public immutable minStake;
    /// @notice The Hookr registry whose reviewed quote catalog decides, besides native ETH, the currencies a version
    ///         can start streaming in.
    IHookrRegistry public immutable registry;

    struct Bond {
        uint256 totalAssets;
        uint256 totalShares;
        Currency[] currencies;
    }

    struct Stream {
        uint256 rateX; // token units * RATE_SCALE per second
        uint256 accX; // token units * ACC_SCALE per share
        uint64 finish;
        uint64 last;
        bool listed;
    }

    struct Checkpoint {
        uint256 accX;
        uint256 owed;
    }

    mapping(uint256 versionId => Bond) private _bonds;
    /// @notice A holder's shares of a version's bond.
    mapping(uint256 versionId => mapping(address holder => uint256)) public sharesOf;
    mapping(uint256 versionId => mapping(Currency => Stream)) private _streams;
    mapping(uint256 versionId => mapping(address holder => mapping(Currency => Checkpoint))) private _checkpoints;
    /// @notice Emissions that fell while the version had no stake; swept to the version's reserve.
    mapping(uint256 versionId => mapping(Currency => uint256)) public stranded;
    /// @notice Funded rewards not yet paid or swept, per currency (includes rounding dust).
    mapping(Currency => uint256) public rewardHeld;
    /// @notice Sum of every version's bonded assets.
    uint256 public totalBonded;

    error Unauthorized(address caller);
    error BondsClosed(uint256 versionId);
    error BondLocked(uint256 versionId);
    error StakeTooSmall(uint256 amount, uint256 minimum);
    error ZeroShares();
    error InexactTransfer(uint256 expected, uint256 received);
    error NothingToWithdraw();
    error NothingToClaim();
    error InvalidRecipient(address to);
    error CannotNotify(uint256 versionId, Currency currency);
    error InvalidFunding(uint256 expected, uint256 actual);
    error InvalidSlash(uint16 bps);

    event Staked(uint256 indexed versionId, address indexed holder, uint256 assets, uint256 shares);
    event Withdrawn(uint256 indexed versionId, address indexed holder, address to, uint256 assets, uint256 shares);
    event Slashed(uint256 indexed versionId, address indexed recipient, uint256 amount, uint256 remaining);
    event RewardNotified(
        uint256 indexed versionId, Currency indexed currency, uint256 amount, uint256 rateX, uint64 finish
    );
    event RewardClaimed(
        uint256 indexed versionId, address indexed holder, Currency indexed currency, address to, uint256 amount
    );
    event StrandedSwept(uint256 indexed versionId, Currency indexed currency, uint256 amount);

    /// @param market_ The marketplace; its bond token, unit and registry are read here.
    constructor(address market_) {
        if (market_.code.length == 0) revert Unauthorized(market_);
        market = market_;
        hookr = IHookrModuleMarket(market_).hookr();
        minStake = IHookrModuleMarket(market_).bondUnit();
        registry = IHookrModuleMarket(market_).registry();
    }

    /// @notice Locks `amount` $HOOKR behind a listed version. Developer bond and backing are the same act.
    /// @dev Locked until the version is released or terminated. Refuses fee-on-transfer receipts.
    function stake(uint256 versionId, uint256 amount) external nonReentrant returns (uint256 shares) {
        if (!IHookrModuleMarket(market).acceptsBond(versionId)) revert BondsClosed(versionId);
        if (amount < minStake) revert StakeTooSmall(amount, minStake);
        Bond storage b = _bonds[versionId];
        _settleAll(versionId, msg.sender);
        // A listed version always has totalAssets > 0 once it has shares: only a full slash empties it, and a
        // full slash terminates the version.
        shares = b.totalShares == 0 ? amount : FullMath.mulDiv(amount, b.totalShares, b.totalAssets);
        if (shares == 0) revert ZeroShares();
        uint256 before = hookr.balanceOf(address(this));
        hookr.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = hookr.balanceOf(address(this)) - before;
        if (received != amount) revert InexactTransfer(amount, received);
        b.totalAssets += amount;
        b.totalShares += shares;
        sharesOf[versionId][msg.sender] += shares;
        totalBonded += amount;
        emit Staked(versionId, msg.sender, amount, shares);
    }

    /// @notice Withdraws all of the caller's bond once the version is released (or what is left after a full slash).
    /// @dev Earned rewards are settled first and stay claimable after the shares are burned.
    function withdraw(uint256 versionId, address to) external nonReentrant returns (uint256 assets) {
        if (!IHookrModuleMarket(market).bondReleased(versionId)) revert BondLocked(versionId);
        if (to == address(0)) revert InvalidRecipient(to);
        uint256 shares = sharesOf[versionId][msg.sender];
        if (shares == 0) revert NothingToWithdraw();
        _settleAll(versionId, msg.sender);
        Bond storage b = _bonds[versionId];
        assets = shares == b.totalShares ? b.totalAssets : FullMath.mulDiv(shares, b.totalAssets, b.totalShares);
        sharesOf[versionId][msg.sender] = 0;
        b.totalShares -= shares;
        b.totalAssets -= assets;
        totalBonded -= assets;
        if (assets != 0) hookr.safeTransfer(to, assets);
        emit Withdrawn(versionId, msg.sender, to, assets, shares);
    }

    /// @inheritdoc IHookrBondVault
    /// @dev Only the market calls this, after a published, delayed, unvetoed proposal on a listed ground.
    function slash(uint256 versionId, uint16 bps, address recipient) external nonReentrant returns (uint256 amount) {
        if (msg.sender != market) revert Unauthorized(msg.sender);
        if (bps == 0 || bps > BPS) revert InvalidSlash(bps);
        Bond storage b = _bonds[versionId];
        amount = bps == BPS ? b.totalAssets : FullMath.mulDiv(b.totalAssets, bps, BPS);
        // A slash that empties the bond ends every stream's accrual to its shares: checkpoint what
        // fell while the bond was posted; from here on emissions are stranded for the version's reserve.
        if (amount == b.totalAssets) _updateStreams(versionId);
        b.totalAssets -= amount;
        totalBonded -= amount;
        if (amount != 0) hookr.safeTransfer(recipient, amount);
        emit Slashed(versionId, recipient, amount, b.totalAssets);
    }

    /// @inheritdoc IHookrBondVault
    /// @dev False once a full slash has emptied the bond: shares with no assets behind them earn
    ///      nothing, so the router keeps the backers' share for the version's reserve instead. Otherwise true for a
    ///      currency the version already streams in, and for a new one only while it is reviewed: native ETH or a
    ///      `CATALOG` asset by the registry's `badgeForQuote`. A class member or an
    ///      unreviewed quote never starts a stream: a class admits every token of one code hash and any-quote mode
    ///      every token, so either would let anyone lengthen the list every stake settles with dust fees.
    function canNotify(uint256 versionId, Currency currency) public view returns (bool) {
        Bond storage b = _bonds[versionId];
        return b.totalShares != 0 && b.totalAssets != 0
            && (_streams[versionId][currency].listed
                || currency.isAddressZero()
                || registry.badgeForQuote(Currency.unwrap(currency)) == IHookrRegistry.QuoteBadge.CATALOG);
    }

    /// @inheritdoc IHookrBondVault
    /// @dev Merges `amount` with whatever is still streaming. The merged stream ends at the amount-weighted average
    ///      of the running stream's own end and a full REWARD_WINDOW from now, so it ends no earlier than the running
    ///      stream would have and no later than a full window from now. A dust notification barely moves the end
    ///      (a fresh full window on every notify would let dust trades plus permissionless collects keep pushing
    ///      payouts back), and a large one gets close to a full window. At the merge, the merged rate is
    ///      never above the running stream's rate plus the new amount spread over a full window.
    function notifyReward(uint256 versionId, Currency currency, uint256 amount) external payable nonReentrant {
        if (msg.sender != address(IHookrModuleMarket(market).router())) revert Unauthorized(msg.sender);
        if (!canNotify(versionId, currency)) revert CannotNotify(versionId, currency);
        if (currency.isAddressZero()) {
            if (msg.value != amount) revert InvalidFunding(amount, msg.value);
        } else {
            if (msg.value != 0) revert InvalidFunding(0, msg.value);
            uint256 backing = rewardHeld[currency] + amount;
            if (Currency.unwrap(currency) == address(hookr)) backing += totalBonded;
            uint256 balance = currency.balanceOfSelf();
            if (balance < backing) revert InvalidFunding(backing, balance);
        }
        Stream storage s = _streams[versionId][currency];
        if (!s.listed) {
            s.listed = true;
            _bonds[versionId].currencies.push(currency);
        }
        _updateStream(versionId, currency);
        uint256 remaining = block.timestamp < s.finish ? s.finish - block.timestamp : 0;
        uint256 leftover = remaining * s.rateX;
        uint256 added = amount * RATE_SCALE;
        uint256 total = leftover + added;
        // Rounded up, so the merged rate never exceeds the bound in the NatSpec; still at most REWARD_WINDOW.
        uint256 duration =
            total == 0 ? REWARD_WINDOW : (remaining * leftover + REWARD_WINDOW * added + total - 1) / total;
        s.rateX = total / duration;
        s.finish = uint64(block.timestamp + duration);
        s.last = uint64(block.timestamp);
        rewardHeld[currency] += amount;
        emit RewardNotified(versionId, currency, amount, s.rateX, s.finish);
    }

    /// @notice Pays the caller's earned rewards in one currency.
    function claimReward(uint256 versionId, Currency currency, address to)
        external
        nonReentrant
        returns (uint256 amount)
    {
        if (to == address(0)) revert InvalidRecipient(to);
        _settle(versionId, msg.sender, currency);
        Checkpoint storage cp = _checkpoints[versionId][msg.sender][currency];
        amount = cp.owed;
        if (amount == 0) revert NothingToClaim();
        cp.owed = 0;
        rewardHeld[currency] -= amount;
        currency.transfer(to, amount);
        emit RewardClaimed(versionId, msg.sender, currency, to, amount);
    }

    /// @notice Sends emissions that fell while nobody was staked to the version's reserve. Anyone may call.
    function sweepStranded(uint256 versionId, Currency currency) external nonReentrant returns (uint256 amount) {
        _updateStream(versionId, currency);
        amount = stranded[versionId][currency];
        if (amount == 0) revert NothingToClaim();
        stranded[versionId][currency] = 0;
        rewardHeld[currency] -= amount;
        IHookrUsageFeeRouter r = IHookrModuleMarket(market).router();
        if (currency.isAddressZero()) {
            r.receiveStranded{value: amount}(versionId, currency, amount);
        } else {
            currency.transfer(address(r), amount);
            r.receiveStranded(versionId, currency, amount);
        }
        emit StrandedSwept(versionId, currency, amount);
    }

    /// @inheritdoc IHookrBondVault
    function totalAssets(uint256 versionId) external view returns (uint256) {
        return _bonds[versionId].totalAssets;
    }

    /// @inheritdoc IHookrBondVault
    function totalShares(uint256 versionId) external view returns (uint256) {
        return _bonds[versionId].totalShares;
    }

    /// @notice The $HOOKR a holder would withdraw for a version today (rounded down).
    function assetsOf(uint256 versionId, address holder) external view returns (uint256) {
        Bond storage b = _bonds[versionId];
        uint256 shares = sharesOf[versionId][holder];
        if (shares == 0) return 0;
        return shares == b.totalShares ? b.totalAssets : FullMath.mulDiv(shares, b.totalAssets, b.totalShares);
    }

    /// @notice Currencies a version has received rewards in.
    function rewardCurrencies(uint256 versionId) external view returns (Currency[] memory) {
        return _bonds[versionId].currencies;
    }

    /// @notice A version's stream in one currency.
    function stream(uint256 versionId, Currency currency)
        external
        view
        returns (uint256 rateX, uint256 accX, uint64 finish, uint64 last)
    {
        Stream storage s = _streams[versionId][currency];
        return (s.rateX, _currentAcc(versionId, s), s.finish, s.last);
    }

    /// @notice What a holder has earned and not claimed, including what has streamed since the last update.
    function earned(uint256 versionId, address holder, Currency currency) external view returns (uint256) {
        Stream storage s = _streams[versionId][currency];
        Checkpoint storage cp = _checkpoints[versionId][holder][currency];
        uint256 acc = _currentAcc(versionId, s);
        return cp.owed + FullMath.mulDiv(sharesOf[versionId][holder], acc - cp.accX, ACC_SCALE);
    }

    /// @dev Emissions accrue to shares only while the bond has assets behind them; otherwise (nobody staked, or a
    ///      full slash emptied the bond) they are stranded for the version's reserve.
    function _currentAcc(uint256 versionId, Stream storage s) private view returns (uint256 acc) {
        acc = s.accX;
        uint256 end = block.timestamp < s.finish ? block.timestamp : s.finish;
        Bond storage b = _bonds[versionId];
        uint256 ts = b.totalShares;
        if (end > s.last && ts != 0 && b.totalAssets != 0) {
            acc += FullMath.mulDiv((end - s.last) * s.rateX, ACC_SCALE / RATE_SCALE, ts);
        }
    }

    function _updateStream(uint256 versionId, Currency currency) private {
        Stream storage s = _streams[versionId][currency];
        uint256 end = block.timestamp < s.finish ? block.timestamp : s.finish;
        if (end <= s.last) return;
        uint256 emitted = (end - s.last) * s.rateX;
        Bond storage b = _bonds[versionId];
        uint256 ts = b.totalShares;
        if (ts == 0 || b.totalAssets == 0) stranded[versionId][currency] += emitted / RATE_SCALE;
        else s.accX += FullMath.mulDiv(emitted, ACC_SCALE / RATE_SCALE, ts);
        s.last = uint64(end);
    }

    function _updateStreams(uint256 versionId) private {
        Currency[] storage cs = _bonds[versionId].currencies;
        for (uint256 i; i < cs.length; ++i) {
            _updateStream(versionId, cs[i]);
        }
    }

    function _settle(uint256 versionId, address holder, Currency currency) private {
        _updateStream(versionId, currency);
        Stream storage s = _streams[versionId][currency];
        Checkpoint storage cp = _checkpoints[versionId][holder][currency];
        uint256 shares = sharesOf[versionId][holder];
        if (shares != 0) cp.owed += FullMath.mulDiv(shares, s.accX - cp.accX, ACC_SCALE);
        cp.accX = s.accX;
    }

    function _settleAll(uint256 versionId, address holder) private {
        Currency[] storage cs = _bonds[versionId].currencies;
        for (uint256 i; i < cs.length; ++i) {
            _settle(versionId, holder, cs[i]);
        }
    }
}
