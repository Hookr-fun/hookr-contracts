// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IHookrRevenueToken} from "tokenizer/interfaces/IHookrRevenueToken.sol";
import {IHookrDropBox} from "tokenizer/interfaces/IHookrDropBox.sol";
import {HookrCompoundShares} from "./base/HookrCompoundShares.sol";
import {HookrBandMath} from "./libraries/HookrBandMath.sol";
import {HookrShareMath} from "./libraries/HookrShareMath.sol";
import {IHookrRevenueCompounder} from "./interfaces/IHookrRevenueCompounder.sol";

/// @dev The pool's other currency, once the token has code and is one of the pool's two currencies. Evaluated before
///      the shares' constructor reads the token's assets.
function quoteOf(PoolKey memory key, IHookrRevenueToken token) view returns (Currency) {
    address t = address(token);
    if (t.code.length == 0) revert IHookrRevenueCompounder.InvalidTerms(0);
    if (Currency.unwrap(key.currency0) == t) return key.currency1;
    if (Currency.unwrap(key.currency1) == t) return key.currency0;
    revert IHookrRevenueCompounder.InvalidTerms(1);
}

/// @title Hookr revenue compounder
/// @notice The opt-in vault of one revenue token (IHookrRevenueCompounder): deposits stay in the vault and earn the
///         token's income, the income is placed in the token's pool as single-sided liquidity next to a price the
///         vault has not seen fall or rise away from it, the fees and the fills are placed the same way, drops to
///         the token's holders are claimed in and released over time like income, and shares redeem for a pro rata
///         share of everything.
/// @dev The vault modifies its bands itself, inside its own unlock callback, so the `sender` a Hookr root passes to
///      the pool's Rules and advisory is this contract. Every PoolManager step is settled before the callback ends;
///      no quote leaves the vault while the pool is unlocked (refunds, payouts and tips are paid after it), so a
///      recipient that runs code during a transfer cannot act on an unlocked pool. Rounding favours the vault.
///      Fee-on-transfer and rebasing quote tokens are refused. Every call that prices or moves shares first claims the
///      income the token owes the vault and the drops recorded for it, and refuses to run inside the token's own
///      payout (`TokenLocked`), where that claim cannot be made. The band math is HookrBandMath's, the share math
///      HookrShareMath's; the reads beyond `holdings` are HookrCompounderLens's.
contract HookrRevenueCompounder is IHookrRevenueCompounder, IUnlockCallback, HookrCompoundShares {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    /// @inheritdoc IHookrRevenueCompounder
    uint256 public constant MIN_SHARES = 1_000;
    /// @inheritdoc IHookrRevenueCompounder
    uint256 public constant MAX_BANDS = 3;
    /// @inheritdoc IHookrRevenueCompounder
    int24 public constant MAX_BAND_TICKS = 100_000;
    /// @inheritdoc IHookrRevenueCompounder
    uint16 public constant MAX_TIP_BPS = 100;
    /// @inheritdoc IHookrRevenueCompounder
    uint256 public constant CLAIM_GAS = 400_000;
    /// @inheritdoc IHookrRevenueCompounder
    uint256 public constant ADD_GAS_FLOOR = 500_000;
    /// @inheritdoc IHookrRevenueCompounder
    uint256 public constant ANCHOR_DRIFT = 100;
    /// @inheritdoc IHookrRevenueCompounder
    uint256 public constant ANCHOR_PERIOD = 1 hours;
    /// @inheritdoc IHookrRevenueCompounder
    uint256 public constant DROP_SCAN = 16;
    uint256 private constant BPS = 10_000;
    uint256 private constant NO_ASSET = type(uint256).max;
    uint8 private constant DEPOSIT = 0;
    uint8 private constant REDEEM = 1;
    uint8 private constant POKE = 2;
    /// @dev `Reentered()`, the error the revenue token's lock reverts with.
    bytes4 private constant TOKEN_REENTERED = bytes4(keccak256("Reentered()"));

    /// @inheritdoc IHookrRevenueCompounder
    IHookrRevenueToken public immutable token;
    /// @inheritdoc IHookrRevenueCompounder
    IPoolManager public immutable poolManager;
    /// @inheritdoc IHookrRevenueCompounder
    PoolId public immutable poolId;
    /// @inheritdoc IHookrRevenueCompounder
    bool public immutable tokenIsCurrency0;
    /// @inheritdoc IHookrRevenueCompounder
    int24 public immutable bandTicks;
    /// @inheritdoc IHookrRevenueCompounder
    uint16 public immutable tipBps;
    /// @inheritdoc IHookrRevenueCompounder
    uint128 public immutable tipCap;
    /// @inheritdoc IHookrRevenueCompounder
    int24 public immutable ANCHOR_TOLERANCE;
    Currency private immutable _currency0;
    Currency private immutable _currency1;
    uint24 private immutable _fee;
    int24 private immutable _spacing;
    IHooks private immutable _hooks;
    /// @dev The token's asset that is the quote, or `NO_ASSET` when the quote is not one of its assets.
    uint256 private immutable _quoteAsset;
    /// @dev The token's drop box.
    IHookrDropBox private immutable _box;
    /// @inheritdoc IHookrRevenueCompounder
    address public immutable creator;

    /// @inheritdoc IHookrRevenueCompounder
    uint256 public reserve;
    /// @inheritdoc IHookrRevenueCompounder
    uint256 public nextDrop;
    /// @dev The indexes of the bands the vault holds liquidity in (HookrBandMath.bandOf), at most `MAX_BANDS`.
    int256[] private _bands;
    Anchor private _anchor;
    /// @dev The quote that drops brought in and had not yet been released at `_droppedAt`; it releases linearly over
    ///      `dropStream` seconds and is left out of everything the shares are priced and paid on until it does.
    uint128 private _dropped;
    uint40 private _droppedAt;

    // What a call hands the unlock callback and what the callback hands back. They live in transient storage, for the
    // transaction only: the callback runs inside the PoolManager's unlock, within the call that opened it.
    address private transient _payer;
    uint256 private transient _tokensMax;
    uint256 private transient _quoteMax;
    uint256 private transient _supply;
    uint256 private transient _shares;
    bool private transient _leaveLocked;
    uint256 private transient _gathered;
    uint256 private transient _out0;
    uint256 private transient _out1;
    uint256 private transient _out2;
    /// @dev Whether a poke moved a band, placed anything or moved the anchor.
    bool private transient _active;

    /// @param manager The PoolManager.
    /// @param token_ The revenue token, sealed.
    /// @param key The pool, initialized, with the token as one of its currencies.
    /// @param bandTicks_ The band width in ticks: a multiple of the tick spacing, at most `MAX_BAND_TICKS`.
    /// @param tipBps_ The poker's tip, at most `MAX_TIP_BPS`.
    /// @param tipCap_ The most a poke tips, in quote units; zero for no tip.
    /// @param name_ ERC-20 name of the shares.
    /// @param symbol_ ERC-20 symbol of the shares.
    /// @param creator_ The token's creator, the only one who may list a side asset.
    constructor(
        IPoolManager manager,
        IHookrRevenueToken token_,
        PoolKey memory key,
        int24 bandTicks_,
        uint16 tipBps_,
        uint128 tipCap_,
        string memory name_,
        string memory symbol_,
        address creator_
    ) HookrCompoundShares(name_, symbol_, token_, quoteOf(key, token_), address(manager)) {
        if (!token_.live()) revert InvalidTerms(0);
        PoolId id = key.toId();
        (uint160 sqrtPriceX96, int24 tick,,) = manager.getSlot0(id);
        if (sqrtPriceX96 == 0) revert InvalidTerms(2);
        int24 spacing = key.tickSpacing;
        if (bandTicks_ < spacing || bandTicks_ > MAX_BAND_TICKS || bandTicks_ % spacing != 0) revert InvalidTerms(3);
        if (tipBps_ > MAX_TIP_BPS) revert InvalidTerms(4);
        token = token_;
        poolManager = manager;
        poolId = id;
        bool tokenIs0 = Currency.unwrap(key.currency0) == address(token_);
        tokenIsCurrency0 = tokenIs0;
        bandTicks = bandTicks_;
        tipBps = tipBps_;
        tipCap = tipCap_;
        ANCHOR_TOLERANCE = bandTicks_ / 4;
        (_currency0, _currency1, _fee, _spacing, _hooks) = (key.currency0, key.currency1, key.fee, spacing, key.hooks);
        Currency q = tokenIs0 ? key.currency1 : key.currency0;
        uint256 quoteAsset = NO_ASSET;
        uint256 n = token_.assetCount();
        for (uint256 i; i < n; ++i) {
            if (token_.assetAt(i).currency == q) quoteAsset = i;
        }
        _quoteAsset = quoteAsset;
        // The price at construction is the first anchor: the pool was initialized by someone else before this.
        _anchor = Anchor(tick, tick, uint40(block.timestamp));
        creator = creator_;
        // A drop recorded before the vault existed cannot have a share in it.
        IHookrDropBox box = IHookrDropBox(token_.dropBox());
        _box = box;
        nextDrop = box.dropCount();
    }

    /// @dev Native ETH arrives from the PoolManager (`take`), from the revenue token (a claim), from the token's drop
    ///      box and from anyone who wants to add to what the shareholders hold; it is placed by the next poke.
    receive() external payable {}

    // ------------------------------------------------------------------ actions

    /// @inheritdoc IHookrRevenueCompounder
    function deposit(uint256 tokensMax, uint256 quoteMax, address to, uint256 minShares, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 shares, uint256 tokens, uint256 quote_)
    {
        if (block.timestamp > deadline) revert Expired(deadline);
        _checkRecipient(to);
        Currency q = _quote();
        if (q.isAddressZero() ? msg.value != quoteMax : msg.value != 0) revert NativeMismatch();
        _catchUp(DROP_SCAN);
        _claimIncome(false);
        _recognizeSides();
        uint256 supply = totalSupply;
        (_payer, _tokensMax, _quoteMax, _supply) = (msg.sender, tokensMax, quoteMax, supply);
        poolManager.unlock(abi.encode(DEPOSIT));
        (shares, tokens, quote_) = (_out0, _out1, _out2);
        if (supply == 0) {
            if (shares <= MIN_SHARES) revert DepositTooSmall();
            _mint(DEAD, MIN_SHARES);
            shares -= MIN_SHARES;
        }
        if (shares < minShares) revert InsufficientShares(shares, minShares);
        _mint(to, shares);
        // The native excess is refunded after the unlock, so no ETH leaves the vault while the pool is unlocked.
        if (q.isAddressZero() && msg.value > quote_) q.transfer(msg.sender, msg.value - quote_);
        emit Deposit(msg.sender, to, shares, tokens, quote_);
    }

    /// @inheritdoc IHookrRevenueCompounder
    function redeem(uint256 shares, address to, uint256 minTokens, uint256 minQuote, uint256 deadline)
        external
        nonReentrant
        returns (uint256 tokens, uint256 quote_)
    {
        return _redeemShares(shares, to, minTokens, minQuote, deadline, false);
    }

    /// @inheritdoc IHookrRevenueCompounder
    function redeemUnlocked(uint256 shares, address to, uint256 minTokens, uint256 minQuote, uint256 deadline)
        external
        nonReentrant
        returns (uint256 tokens, uint256 quote_)
    {
        return _redeemShares(shares, to, minTokens, minQuote, deadline, true);
    }

    /// @inheritdoc IHookrRevenueCompounder
    function poke() external nonReentrant returns (uint256 tip) {
        return _compound(false);
    }

    /// @inheritdoc IHookrRevenueCompounder
    function claimDrops(uint256[] calldata dropIds) external nonReentrant returns (uint256 tip) {
        if (dropIds.length == 0) revert NoDrops();
        for (uint256 i; i < dropIds.length; ++i) {
            _takeDrop(dropIds[i]);
        }
        return _compound(true);
    }

    /// @inheritdoc IHookrRevenueCompounder
    function listSide(address asset) external returns (uint256 side) {
        if (msg.sender != creator) revert NotCreator(msg.sender);
        // The quote is placed, never split, and the revenue token is the deposits themselves.
        if (Currency.wrap(asset) == _quote() || asset == address(token)) revert InvalidSide(asset);
        return _addSide(Currency.wrap(asset));
    }

    /// @dev Claims drop `dropId` from the box and holds its proceeds back to release over `dropStream` seconds: the
    ///      quote into the quote stream, any other asset into its side's. An asset that is neither the quote nor a
    ///      listed side reverts `NotListed`, undoing the claim.
    function _takeDrop(uint256 dropId) private {
        IHookrDropBox box = _box;
        uint256[] memory ids = new uint256[](1);
        ids[0] = dropId;
        uint256 amount = box.claim(ids, address(this))[0];
        address asset = box.dropAt(dropId).asset;
        if (Currency.wrap(asset) == _quote()) {
            _dropped = uint128(_min(_quoteUnreleased() + amount, type(uint128).max));
            _droppedAt = uint40(block.timestamp);
        } else {
            (bool listed, uint256 side) = sideOf(Currency.wrap(asset));
            if (!listed) revert NotListed(asset);
            _streamSide(side, amount);
        }
        emit DropClaimed(dropId, asset, amount);
    }

    /// @dev Looks at up to `max` of the drops recorded since the last look and claims the ones the vault has a share
    ///      in and can account for (the quote or a listed side), so a drop is always in the vault, releasing, before
    ///      shares change hands. Returns whether every recorded drop has been looked at, and how many this call
    ///      looked at.
    function _catchUp(uint256 max) private returns (bool done, uint256 looked) {
        IHookrDropBox box = _box;
        uint256 count = box.dropCount();
        uint256 from = nextDrop;
        uint256 to = count - from > max ? from + max : count;
        nextDrop = to;
        Currency q = _quote();
        for (uint256 i = from; i < to; ++i) {
            if (box.claimable(i, address(this)) == 0) continue;
            Currency asset = Currency.wrap(box.dropAt(i).asset);
            (bool listed,) = sideOf(asset);
            if (asset == q || listed) _takeDrop(i);
        }
        return (to == count, to - from);
    }

    /// @dev `redeem` and `redeemUnlocked`: burns first, removes inside the unlock, pays after it.
    function _redeemShares(
        uint256 shares,
        address to,
        uint256 minTokens,
        uint256 minQuote,
        uint256 deadline,
        bool leaveLocked
    ) private returns (uint256 tokens, uint256 quote_) {
        if (block.timestamp > deadline) revert Expired(deadline);
        if (shares == 0) revert ZeroShares();
        _checkRecipient(to);
        _catchUp(DROP_SCAN);
        _claimIncome(false);
        _recognizeSides();
        uint256 supply = totalSupply;
        _burn(msg.sender, shares);
        (_shares, _supply, _leaveLocked) = (shares, supply, leaveLocked);
        poolManager.unlock(abi.encode(REDEEM));
        (tokens, quote_) = tokenIsCurrency0 ? (_out0, _out1) : (_out1, _out0);
        if (tokens < minTokens || quote_ < minQuote) revert InsufficientOutput(tokens, quote_);
        if (tokens != 0) IERC20(address(token)).safeTransfer(to, tokens);
        if (quote_ != 0) _send(_quote(), to, quote_);
        emit Redeem(msg.sender, to, shares, tokens, quote_);
    }

    /// @dev `poke`; `forced` when the caller brought something in, so the poke is never nothing.
    function _compound(bool forced) private returns (uint256 tip) {
        Currency q = _quote();
        (, uint256 looked) = _catchUp(DROP_SCAN);
        uint256 before = q.balanceOfSelf();
        bool claimed = _claimIncome(false);
        uint256 gathered = q.balanceOfSelf() - before;
        bool sides = _recognizeSides();
        _gathered = gathered;
        poolManager.unlock(abi.encode(POKE));
        (uint256 feeTokens, uint256 feeQuote) = (_out0, _out1);
        if (!forced && looked == 0 && !claimed && !sides && feeTokens == 0 && feeQuote == 0 && !_active) {
            revert NothingToPoke();
        }
        tip = _out2;
        // The tip is paid after the unlock, so no quote leaves the vault while the pool is unlocked.
        if (tip != 0) _send(q, msg.sender, tip);
        emit Poked(msg.sender, gathered + feeQuote, feeTokens, tip);
    }

    // ------------------------------------------------------------------ PoolManager callback

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        uint8 action = abi.decode(data, (uint8));
        if (action == DEPOSIT) _deposit();
        else if (action == REDEEM) _redeem();
        else _poke();
        return "";
    }

    /// @dev Realizes the fees, takes the vault's own mix from the payer and places the quote. The depositor's own
    ///      ETH (`quoteMax` of a native quote) is left out of the holdings it is measured against.
    function _deposit() private {
        (address payer, uint256 tokensMax, uint256 quoteMax, uint256 supply) = (_payer, _tokensMax, _quoteMax, _supply);
        _realize();
        _settleAll();
        Currency q = _quote();
        bool native = q.isAddressZero();
        (uint256 totalTokens, uint256 totalQuote) = _holdings(native ? quoteMax : 0);
        (uint256 shares, uint256 tokens, uint256 quote_) =
            HookrShareMath.sharesFor(supply, totalTokens, totalQuote, tokensMax, quoteMax);
        // A first deposit too small for the minimum shares is refused after the unlock, as DepositTooSmall.
        if (shares == 0 && supply != 0) revert ZeroShares();
        if (tokens != 0) {
            _pullExact(Currency.wrap(address(token)), payer, tokens);
            reserve += tokens;
        }
        if (quote_ != 0 && !native) _pullExact(q, payer, quote_);
        _place(native ? quoteMax - quote_ : 0);
        (_out0, _out1, _out2) = (shares, tokens, quote_);
    }

    /// @dev Removes `shares / supply` of every band and pays that principal plus the same share of what is loose, the
    ///      fees every band just realized included. The reserve gives up its share too. A band whose removal the hook
    ///      refuses reverts `RemovalLocked`, or, with `leaveLocked`, stays in place and out of the payout.
    function _redeem() private {
        (uint256 shares, uint256 supply, bool leaveLocked) = (_shares, _supply, _leaveLocked);
        // Fees first, as a deposit does: whatever a hook keeps of them is shared by every holder, and the removals
        // below realize none, so a removal's delta is its principal alone.
        _realize();
        _settleAll();
        uint256 removed0;
        uint256 removed1;
        for (uint256 i = _bands.length; i > 0;) {
            --i;
            (int24 lower, int24 upper,) = HookrBandMath.ticksOf(_bands[i], bandTicks, _spacing);
            uint128 liquidity = _liquidityAt(lower, upper);
            if (liquidity == 0) {
                _drop(i);
                continue;
            }
            uint256 part = FullMath.mulDiv(liquidity, shares, supply);
            (bool ok, BalanceDelta delta, BalanceDelta fees) = _tryModify(lower, upper, -int256(part));
            if (ok) {
                // The fees were realized above, so a removal carries principal alone; were any left, they are the
                // loose amounts' to share, not the redeemer's to take.
                removed0 += _positive(delta.amount0() - fees.amount0());
                removed1 += _positive(delta.amount1() - fees.amount1());
                if (part == liquidity) {
                    _drop(i);
                    emit BandRemoved(lower, upper, liquidity);
                }
            } else {
                if (!leaveLocked) revert RemovalLocked(lower, upper);
                emit BandLeft(lower, upper, liquidity);
            }
        }
        _settleAll();
        // The quote that drops brought in and has not released is not the shares' yet.
        uint256 held = _quoteUnreleased();
        (uint256 held0, uint256 held1) = tokenIsCurrency0 ? (uint256(0), held) : (held, uint256(0));
        uint256 amount0 = removed0 + FullMath.mulDiv(_currency0.balanceOfSelf() - removed0 - held0, shares, supply);
        uint256 amount1 = removed1 + FullMath.mulDiv(_currency1.balanceOfSelf() - removed1 - held1, shares, supply);
        reserve -= FullMath.mulDiv(reserve, shares, supply);
        (_out0, _out1) = (amount0, amount1);
    }

    /// @dev Realizes the fees, sets the tip aside, removes the bands the price moved away from and places everything
    ///      loose the anchor allows.
    function _poke() private {
        uint256 gathered = _gathered;
        (uint256 fees0, uint256 fees1) = _realize();
        _settleAll();
        (uint256 feeTokens, uint256 feeQuote) = tokenIsCurrency0 ? (fees0, fees1) : (fees1, fees0);
        uint256 tip = (gathered + feeQuote) * tipBps / BPS;
        if (tip > tipCap) tip = tipCap;
        _active = _place(tip);
        (_out0, _out1, _out2) = (feeTokens, feeQuote, tip);
    }

    // ------------------------------------------------------------------ band steps (inside the callback)

    /// @dev Realizes every band's fees into the vault's deltas. Returns them per currency. A band whose pool refuses
    ///      even this (a hook that locks every removal) is skipped: its fees stay in it.
    function _realize() private returns (uint256 fees0, uint256 fees1) {
        uint256 n = _bands.length;
        for (uint256 i; i < n; ++i) {
            (int24 lower, int24 upper,) = HookrBandMath.ticksOf(_bands[i], bandTicks, _spacing);
            if (_liquidityAt(lower, upper) == 0) continue;
            (bool ok,, BalanceDelta fees) = _tryModify(lower, upper, 0);
            if (!ok) continue;
            fees0 += uint128(fees.amount0());
            fees1 += uint128(fees.amount1());
        }
    }

    /// @dev Removes the bands the price left behind, then places what is loose and the anchor allows: currency0 in the
    ///      band above the price, currency1 in the band below it; the quote is what is loose of it less `reserveQuote`
    ///      (a refund or a tip paid after the unlock) and the drops' quote that has not released, the revenue tokens
    ///      what is loose above the reserve. Every delta is settled before this returns.
    function _place(uint256 reserveQuote) private returns (bool active) {
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        int256 k = HookrBandMath.bandOf(tick, bandTicks);
        (Anchor memory a, bool allow0, bool allow1, bool learnt) = _anchorFor(tick);
        bool moved = _consolidate(k, allow0, allow1);
        if (moved) _settleAll();
        uint256 looseTokens = IERC20(address(token)).balanceOf(address(this)) - reserve;
        uint256 looseQuote = _quote().balanceOfSelf() - reserveQuote - _quoteUnreleased();
        bool tokenIs0 = tokenIsCurrency0;
        (uint256 loose0, uint256 loose1) = tokenIs0 ? (looseTokens, looseQuote) : (looseQuote, looseTokens);
        uint128 placed0;
        uint128 placed1;
        if (allow0) placed0 = _add(k + 1, true, loose0);
        if (allow1) placed1 = _add(k - 1, false, loose1);
        if ((!allow0 && loose0 != 0) || (!allow1 && loose1 != 0)) {
            emit PlacementDeferred(tick, a.high, a.low, allow0 ? 0 : loose0, allow1 ? 0 : loose1);
        }
        if (placed0 != 0 || placed1 != 0) _settleAll();
        return learnt || moved || placed0 != 0 || placed1 != 0;
    }

    /// @dev Brings the anchor up to date with the price at `tick`. The anchor is the highest and the lowest price the
    ///      vault has seen recently: each closes in on the price by `ANCHOR_DRIFT` ticks for every `ANCHOR_PERIOD`
    ///      since the last look (at most one period's worth per look, so a vault nobody looked at does not forget), and
    ///      a price beyond either takes its place at once. A look can widen the anchor and a long enough wait narrows
    ///      it, but no sequence of prices pulls it toward a price the market is not at. Currency0 (placed above the
    ///      price) is allowed while the price is not below the recent high by more than the tolerance, currency1
    ///      (placed below it) while it is not above the recent low by more than that: a price pushed away from where
    ///      the market has been can only be placed next to by moving the placement further from the market, never
    ///      closer. Returns whether the anchor moved.
    function _anchorFor(int24 tick) private returns (Anchor memory a, bool allow0, bool allow1, bool learnt) {
        a = _anchor;
        uint256 elapsed = block.timestamp - a.lookedAt;
        if (elapsed > ANCHOR_PERIOD) elapsed = ANCHOR_PERIOD;
        int256 drift = int256(elapsed * ANCHOR_DRIFT / ANCHOR_PERIOD);
        int256 high = int256(a.high) - drift;
        int256 low = int256(a.low) + drift;
        if (high < tick) high = tick;
        if (low > tick) low = tick;
        learnt = high != a.high || low != a.low;
        a = Anchor(int24(high), int24(low), uint40(block.timestamp));
        _anchor = a;
        int256 tolerance = ANCHOR_TOLERANCE;
        allow0 = tick >= high - tolerance;
        allow1 = tick <= low + tolerance;
        if (learnt) emit AnchorMoved(a.high, a.low);
    }

    /// @dev Removes the whole of every band further than one band from `k`, the band holding the price, when what it
    ///      frees can be placed again: a band above the price holds currency0 (needs `allow0`), one below holds
    ///      currency1 (needs `allow1`). A band that cannot be replaced, or whose removal the pool's hook refuses,
    ///      stays where it is. Returns whether any liquidity moved.
    function _consolidate(int256 k, bool allow0, bool allow1) private returns (bool moved) {
        for (uint256 i = _bands.length; i > 0;) {
            --i;
            int256 band = _bands[i];
            if (band >= k - 1 && band <= k + 1) continue;
            if (band > k ? !allow0 : !allow1) continue;
            (int24 lower, int24 upper,) = HookrBandMath.ticksOf(band, bandTicks, _spacing);
            uint128 liquidity = _liquidityAt(lower, upper);
            if (liquidity != 0) {
                (bool ok,,) = _tryModify(lower, upper, -int256(uint256(liquidity)));
                if (!ok) {
                    emit BandLeft(lower, upper, liquidity);
                    continue;
                }
                emit BandRemoved(lower, upper, liquidity);
                moved = true;
            }
            _drop(i);
        }
    }

    /// @dev Places `amount` of one currency in band `k`, which lies entirely on that currency's side of the price:
    ///      currency0 above it when `isCurrency0`, currency1 below it otherwise. The liquidity is what the amount buys
    ///      there. A pool that refuses the add (its hook, or a tick at its liquidity limit), or a vault that already
    ///      holds `MAX_BANDS` other bands (some a hook will not let go of), leaves the amount loose.
    function _add(int256 k, bool isCurrency0, uint256 amount) private returns (uint128 liquidity) {
        if (amount == 0) return 0;
        (int24 lower, int24 upper, bool ok) = HookrBandMath.ticksOf(k, bandTicks, _spacing);
        if (!ok) return 0;
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(upper);
        liquidity = isCurrency0
            ? HookrBandMath.liquidityForAmount0(sqrtA, sqrtB, amount)
            : HookrBandMath.liquidityForAmount1(sqrtA, sqrtB, amount);
        if (liquidity == 0 || (_bands.length == MAX_BANDS && !_listed(k))) return 0;
        (ok,,) = _tryModify(lower, upper, int256(uint256(liquidity)));
        if (ok) {
            _track(k);
            emit BandAdded(lower, upper, liquidity);
        } else {
            emit AddRefused(lower, upper, liquidity);
            liquidity = 0;
        }
    }

    /// @dev Modifies the band by `delta`, or reports that the pool refused it (`ok` false). The caller must leave
    ///      `ADD_GAS_FLOOR`, so a starved call is never read as a refusal.
    function _tryModify(int24 lower, int24 upper, int256 delta)
        private
        returns (bool ok, BalanceDelta callerDelta, BalanceDelta fees)
    {
        if (gasleft() < ADD_GAS_FLOOR) revert Starved();
        try poolManager.modifyLiquidity(poolKey(), ModifyLiquidityParams(lower, upper, delta, bytes32(0)), "") returns (
            BalanceDelta d, BalanceDelta f
        ) {
            return (true, d, f);
        } catch {}
    }

    /// @dev Takes every credit into the vault and pays every debt from its balance.
    function _settleAll() private {
        _settle(_currency0);
        _settle(_currency1);
    }

    function _settle(Currency currency) private {
        int256 delta = poolManager.currencyDelta(address(this), currency);
        if (delta > 0) {
            poolManager.take(currency, address(this), uint256(delta));
        } else if (delta < 0) {
            uint256 amount = uint256(-delta);
            if (currency.isAddressZero()) {
                poolManager.settle{value: amount}();
            } else {
                poolManager.sync(currency);
                currency.transfer(address(poolManager), amount);
                poolManager.settle();
            }
        }
    }

    function _listed(int256 k) private view returns (bool) {
        uint256 n = _bands.length;
        for (uint256 i; i < n; ++i) {
            if (_bands[i] == k) return true;
        }
        return false;
    }

    /// @dev Lists band `k` unless it is listed.
    function _track(int256 k) private {
        uint256 n = _bands.length;
        for (uint256 i; i < n; ++i) {
            if (_bands[i] == k) return;
        }
        if (n == MAX_BANDS) revert TooManyBands();
        _bands.push(k);
    }

    /// @dev Unlists the `i`-th band.
    function _drop(uint256 i) private {
        uint256 last = _bands.length - 1;
        if (i != last) _bands[i] = _bands[last];
        _bands.pop();
    }

    // ------------------------------------------------------------------ income

    /// @dev Claims every asset the revenue token owes the vault (the side assets only with `sidesOnly`), each on its
    ///      own call with `CLAIM_GAS`, so one asset that cannot be paid stops neither the others nor the call.
    ///      Returns whether any claim paid.
    function _claimIncome(bool sidesOnly) private returns (bool any) {
        IHookrRevenueToken t = token;
        uint256 n = t.assetCount();
        uint256 skip = sidesOnly ? _quoteAsset : NO_ASSET;
        for (uint256 i; i < n; ++i) {
            if (i == skip) continue;
            if (t.claimable(address(this), i) == 0) continue;
            try t.claim{gas: CLAIM_GAS}(i, address(this)) returns (uint256 amount) {
                any = true;
                emit IncomeClaimed(i, amount);
            } catch (bytes memory reason) {
                // The token's lock is held: this call runs inside one of its payouts, where the claim cannot be made.
                // Pricing or moving shares without the income the token owes the vault would hand it to whoever joins.
                if (bytes4(reason) == TOKEN_REENTERED) revert TokenLocked();
            }
        }
    }

    /// @dev Before shares move: the side assets the token owes are claimed and everything held is recognized, so the
    ///      holder keeps what streamed while it held.
    function _syncSides() internal override {
        _catchUp(DROP_SCAN);
        _claimIncome(true);
        _recognizeSides();
    }

    /// @dev Pulls exactly `amount` of `currency` from `payer`; a transfer that lands short or long is refused.
    function _pullExact(Currency currency, address payer, uint256 amount) private {
        uint256 before = currency.balanceOfSelf();
        IERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(this), amount);
        if (currency.balanceOfSelf() - before != amount) revert InexactTransfer();
    }

    // ------------------------------------------------------------------ reads

    /// @inheritdoc IHookrRevenueCompounder
    function poolKey() public view returns (PoolKey memory) {
        return PoolKey(_currency0, _currency1, _fee, _spacing, _hooks);
    }

    /// @inheritdoc IHookrRevenueCompounder
    function quote() external view returns (Currency) {
        return _quote();
    }

    /// @inheritdoc IHookrRevenueCompounder
    function bands() external view returns (Band[] memory out) {
        uint256 n = _bands.length;
        out = new Band[](n);
        for (uint256 i; i < n; ++i) {
            (int24 lower, int24 upper,) = HookrBandMath.ticksOf(_bands[i], bandTicks, _spacing);
            out[i] = Band(lower, upper, _liquidityAt(lower, upper));
        }
    }

    /// @inheritdoc IHookrRevenueCompounder
    function anchor() external view returns (Anchor memory) {
        return _anchor;
    }

    /// @inheritdoc IHookrRevenueCompounder
    function holdings() public view returns (uint256 tokens, uint256 quote_) {
        return _holdings(0);
    }

    /// @dev The quote that drops brought in and has not released yet.
    function _quoteUnreleased() private view returns (uint256) {
        return _unreleased(_dropped, _droppedAt);
    }

    /// @dev `amount` as an unsigned number, zero when it is negative.
    function _positive(int128 amount) private pure returns (uint256) {
        return amount > 0 ? uint128(amount) : 0;
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @dev The loose amounts (a deposit's own ETH, `nativeExcluded`, left out) plus every band's amounts at the pool's
    ///      current price, as revenue tokens and quote.
    function _holdings(uint256 nativeExcluded) private view returns (uint256 tokens, uint256 quote_) {
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(poolId);
        uint256 amount0 = _currency0.balanceOfSelf() - (_currency0.isAddressZero() ? nativeExcluded : 0);
        uint256 amount1 = _currency1.balanceOfSelf();
        uint256 held = _quoteUnreleased();
        if (tokenIsCurrency0) amount1 -= _min(held, amount1);
        else amount0 -= _min(held, amount0);
        uint256 n = _bands.length;
        for (uint256 i; i < n; ++i) {
            (int24 lower, int24 upper,) = HookrBandMath.ticksOf(_bands[i], bandTicks, _spacing);
            (uint256 held0, uint256 held1) =
                HookrBandMath.amountsForLiquidity(sqrtPriceX96, tick, lower, upper, _liquidityAt(lower, upper), true);
            amount0 += held0;
            amount1 += held1;
        }
        return tokenIsCurrency0 ? (amount0, amount1) : (amount1, amount0);
    }

    function _liquidityAt(int24 lower, int24 upper) private view returns (uint128) {
        return poolManager.getPositionLiquidity(
            poolId, Position.calculatePositionKey(address(this), lower, upper, bytes32(0))
        );
    }

    function _quote() private view returns (Currency) {
        return tokenIsCurrency0 ? _currency1 : _currency0;
    }
}
