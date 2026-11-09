// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHookrSwapModule} from "rootv2/interfaces/IHookrSwapModule.sol";

/// @notice The slice of the Pons V2 launch factory this module reads: its record of a launch token (the factory and
///         the curve it deploys are verified on Sourcify for Robinhood Chain, `PonsV2LaunchFactory`).
interface IPonsLaunchFactoryLike {
    struct LaunchedToken {
        address token;
        address curve;
        address deployer;
        address creatorFeeRecipient;
        address pairToken;
        uint256 graduationThreshold;
        uint24 poolFee;
        int24 tickSpacing;
        uint16 creatorTaxBps;
        bool buybackEnabled;
        uint8 phase;
        uint256 sweptQuote;
        uint256 sweptTokens;
        uint256 sweptAt;
        bool exists;
    }

    function getLaunchedToken(address token) external view returns (LaunchedToken memory);
}

/// @notice The slice of a Pons V2 bonding curve (`PonsV2BondingCurve`) this module reads and trades: constant product
///         against its tracked reserves, every fee on the quote leg (on a buy the fee, the creator tax and the
///         launch-window snipe tax come off the quote paid in, on a sell the fee and the creator tax off the quote paid
///         out). A buy pays native ETH as `msg.value` or an ERC-20 the curve pulls; a sell has the curve pull the token.
interface IPonsCurveLike {
    function feeBps() external view returns (uint256);
    function creatorTaxBps() external view returns (uint256);
    function getReserves() external view returns (uint256 quoteReserve, uint256 tokenReserve);
    function sellableTokens() external view returns (uint256);
    function currentSnipeTaxBps(address recipient) external view returns (uint256);
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256);
    function sell(uint256 tokensIn, uint256 minQuoteOut, address recipient) external returns (uint256);
}

/// @notice The one view of a Pons V2 launch token this module asks: the curve it was minted to.
interface IPonsLaunchTokenLike {
    function curve() external view returns (address);
}

/// @title HookrPonsCurveFill
/// @notice Outside fill from Pons V2 bonding curves: for a Hookr pool of a Pons launch token and the token's own pair
///         token (native ETH, USDG, a stock token, …), it buys or sells on the token's curve while the curve, after its
///         fee, creator tax and snipe tax, beats the Hookr pool's own price after its LP fee, and stops where it no
///         longer does, so the pool's own liquidity fills the rest. A curve that has graduated, or whose sellable
///         allocation is gone (ready to graduate), is no venue; the module never buys a curve's last token, so a Hookr
///         swap never triggers a graduation.
/// @dev No owner, no setter, no storage. The curve of a pair comes from the Pons factory's own record of the launch
///      token (read whenever the curve would fill, nothing cached): the token must name the curve, the factory must
///      have launched the token against exactly the pool's other currency, and the launch must still trade on its
///      curve. A curve that does not beat the pool is turned down on its own views, before the record. The quote
///      mirrors the curve's integer math word for word (`PonsV2BondingCurve.buy`/`sell`, `PonsV2BondingCurveMath`),
///      so the module knows the curve's answer before it trades and sends no trade that would fill a dust amount below
///      the pool's price or partly fill. The trade runs as a call to this module, so a curve that refuses or a token
///      transfer that fails unwinds everything, the PoolManager calls included, and the pool serves the swap. Every
///      read is a bounded static call: a missing or malformed answer is no venue, never a revert. A sell pays the
///      curve with an approval of exactly the trade's amount, which the curve's pull spends to zero.
contract HookrPonsCurveFill is IHookrSwapModule {
    IPoolManager public immutable poolManager;
    /// @notice The Pons V2 launch factory whose launches this module trades.
    address public immutable ponsFactory;

    /// @dev The curve `fill` is trading, transiently: the only sender besides the PoolManager whose ETH `receive`
    ///      takes, and the reentrancy guard.
    bytes32 private constant CALLING = keccak256("hookr.ponsfill.transient.calling");
    uint256 private constant PIPS = 1_000_000;
    uint256 private constant BPS = 10_000;
    uint256 private constant Q96 = 1 << 96;
    /// @dev Reserves above 2^112 are no venue, so every product in the quote and in the curve's own math fits.
    uint256 private constant MAX_RESERVE = 1 << 112;
    /// @dev Gas kept back from the trade call to mint the unused input back and return.
    uint256 private constant FINISH_GAS = 60_000;
    /// @dev The most gas a token's `curve()` or one of the curve's views gets.
    uint256 private constant READ_GAS = 30_000;
    /// @dev The most gas the factory's record read gets (eleven storage words).
    uint256 private constant RECORD_GAS = 60_000;

    error BelowPoolPrice();
    error InvalidWiring();
    error Reentrancy();
    error UnexpectedCallback();

    /// @dev One curve's terms for one swap, as `_quote` read them.
    struct Venue {
        address curve;
        bool buy; // input is the pair token, output the launch token
        bool in0; // input is the Hookr pool's currency0
        uint256 feeBps;
        uint256 taxBps;
        uint256 snipeBps; // a buy's snipe tax, capped as the curve caps it; zero on a sell
        uint256 quoteReserve;
        uint256 tokenReserve;
        uint256 maxIn; // the most input that still beats the pool; zero when the curve would fill nothing
    }

    constructor(IPoolManager manager, address factory) {
        if (address(manager).code.length == 0 || factory.code.length == 0) revert InvalidWiring();
        poolManager = manager;
        ponsFactory = factory;
    }

    /// @notice Takes ETH only from the PoolManager (a native buy's input) and from the curve being traded (a native
    ///         sell's output).
    receive() external payable {
        if (msg.sender != address(poolManager) && msg.sender != _tget()) revert UnexpectedCallback();
    }

    /// @inheritdoc IHookrSwapModule
    /// @dev The launch token's curve when the factory launched one of the two currencies against the other and its
    ///      curve still has tokens for sale; zero for a pair the factory does not know, a graduated curve, or one
    ///      ready to graduate.
    function venueOf(Currency currency0, Currency currency1) external view returns (address venue) {
        address curve = _resolve(Currency.unwrap(currency0), Currency.unwrap(currency1));
        if (curve != address(0)) {
            (bool ok, uint256 sellable) = _read(curve, IPonsCurveLike.sellableTokens.selector);
            if (ok && sellable != 0) venue = curve;
        }
    }

    /// @inheritdoc IHookrSwapModule
    /// @dev The curve's terms read as `fill` reads them: yes only when some input beats the pool after both sides'
    ///      fees and the curve's exact answer for it clears HookrFill's floor.
    function wouldFill(Currency input, Currency output, uint160 sqrtPriceX96, uint24 lpFeePips)
        external
        view
        returns (bool)
    {
        return _quote(input, output, sqrtPriceX96, lpFeePips).maxIn != 0;
    }

    /// @inheritdoc IHookrSwapModule
    function fill(Currency input, Currency output, uint256 budget, uint160 sqrtPriceX96, uint24 lpFeePips)
        external
        returns (uint256 amountIn, uint256 amountOut)
    {
        if (_tget() != address(0)) revert Reentrancy();
        // The caller's claims become this module's credit; whatever the curve does not use goes back as claims.
        poolManager.burn(address(this), input.toId(), budget);
        Venue memory v = _quote(input, output, sqrtPriceX96, lpFeePips);
        uint256 x = v.maxIn < budget ? v.maxIn : budget;
        if (x != 0) {
            // HookrFill's floor for this amount, and the curve's own answer for it: a dust trade that rounds below the
            // floor is never sent.
            uint256 minOut = _floor(x, sqrtPriceX96, lpFeePips, v.in0);
            uint256 out = _out(v, x);
            if (out != 0 && out >= minOut) {
                bytes memory call_ = abi.encodeCall(this.trade, (input, output, v.curve, v.buy, x, minOut, msg.sender));
                _tput(v.curve);
                uint256 g = gasleft();
                g = g > FINISH_GAS ? g - FINISH_GAS : 0;
                bool ok;
                uint256 got;
                assembly ("memory-safe") {
                    ok := call(g, address(), 0, add(call_, 32), mload(call_), 0, 32)
                    if ok { got := mload(0) }
                }
                _tput(address(0));
                // A trade that returned took the input and credited the output; one that failed left no trace.
                if (ok) (amountIn, amountOut) = (x, got);
            }
        }
        uint256 unused = budget - amountIn;
        if (unused != 0) poolManager.mint(msg.sender, input.toId(), unused);
    }

    /// @notice The trade itself, which only `fill` may call (as a call to this module, so anything that fails in it
    ///         unwinds all of it): takes the input from this module's credit, pays the curve, has the curve's output
    ///         paid into the PoolManager after `sync` (an ERC-20) or here (ETH) and credits it to `root`, and refuses
    ///         an output the PoolManager counted below `minOut`, HookrFill's floor.
    /// @dev The curve gets `minOut` as its own slippage bound too. An ERC-20 input is approved to the curve for exactly
    ///      `amountIn`, which the curve's pull spends to zero; a failed trade reverts the approval with everything else.
    function trade(
        Currency input,
        Currency output,
        address curve,
        bool buy,
        uint256 amountIn,
        uint256 minOut,
        address root
    ) external returns (uint256 amountOut) {
        if (msg.sender != address(this)) revert UnexpectedCallback();
        bool ethOut = output.isAddressZero();
        // An ERC-20 output is paid by the curve into the PoolManager; ETH for a native sell comes here. The sync runs
        // for both: for ETH it clears any ERC-20 sync an earlier caller left pending, which would otherwise make the
        // PoolManager refuse the ETH settle below (`NonzeroNativeValue`) and drop the fill.
        poolManager.sync(output);
        poolManager.take(input, address(this), amountIn);
        uint256 value;
        if (input.isAddressZero()) value = amountIn;
        else _approve(Currency.unwrap(input), curve, amountIn);
        address to = ethOut ? address(this) : address(poolManager);
        uint256 got = buy
            ? IPonsCurveLike(curve).buy{value: value}(amountIn, minOut, to)
            : IPonsCurveLike(curve).sell(amountIn, minOut, to);
        // The output is what the PoolManager counted arriving, never what the curve said; a sync always ends in a
        // settle here, so no synced currency is left for the next payer.
        amountOut = ethOut ? poolManager.settleFor{value: got}(root) : poolManager.settleFor(root);
        if (amountOut == 0 || amountOut < minOut) revert BelowPoolPrice();
    }

    /// @dev The curve for a swap of `input` for `output`, its terms, and the most input it fills while it beats the
    ///      Hookr pool (zero when it has no curve for the pair, the curve trades nothing, or nothing beats the pool).
    ///      The launch token is the output on a buy and the input on a sell; a currency that names no curve (a pair
    ///      token, or any other token) costs one failed view.
    function _quote(Currency input, Currency output, uint160 sqrtPriceX96, uint24 lpFeePips)
        private
        view
        returns (Venue memory v)
    {
        (address i, address o) = (Currency.unwrap(input), Currency.unwrap(output));
        if (i == o || lpFeePips >= PIPS) return v;
        v = _quoteOn(o, i, true, sqrtPriceX96, lpFeePips);
        if (v.maxIn == 0) v = _quoteOn(i, o, false, sqrtPriceX96, lpFeePips);
    }

    /// @dev The fill on launch token `token`'s curve against `pair` (`buy` when the pair is the input). The curve is
    ///      priced first and the factory's record read only when it would fill: a curve that does not beat the pool
    ///      costs its own views, never the record. Nothing fills on a curve the record does not vouch for.
    function _quoteOn(address token, address pair, bool buy, uint160 sqrtPriceX96, uint24 lpFeePips)
        private
        view
        returns (Venue memory v)
    {
        address curve = _named(token);
        if (curve == address(0)) return v;
        v = _price(curve, buy, buy ? pair < token : token < pair, sqrtPriceX96, lpFeePips);
        if (v.maxIn != 0 && !_launched(token, pair, curve)) v.maxIn = 0;
    }

    /// @dev `curve`'s terms and the most input it fills while it beats the pool. On a buy (pair token in) the curve's
    ///      quote reserve grows: it fills while its marginal rate, (1 - c) T / Q with c the fee, creator tax and snipe
    ///      tax, beats the pool's net rate R, so up to Q' with Q'^2 = (1 - c) Q T / R, and never past one token short
    ///      of its sellable allocation. On a sell (launch token in) the token reserve grows to T' with
    ///      T'^2 = (1 - c) Q T / R, c the fee and creator tax. With the pool's price P (currency1 per currency0) R is
    ///      P (1 - f) for a currency0 input and (1 - f) / P otherwise, so the grown reserve is
    ///      sqrt((1 - c) Q T / (1 - f)) times 2^96 / sqrtP or sqrtP / 2^96. Everything rounds toward the pool's side.
    ///      The price is checked before the snipe tax is read: a curve that loses without it loses with it.
    function _price(address curve, bool buy, bool in0, uint160 sqrtPriceX96, uint24 lpFeePips)
        private
        view
        returns (Venue memory v)
    {
        (bool ok, uint256 fee) = _read(curve, IPonsCurveLike.feeBps.selector);
        if (!ok) return v;
        uint256 tax;
        (ok, tax) = _read(curve, IPonsCurveLike.creatorTaxBps.selector);
        // Bounded before any sum: a curve may answer any word, and a revert here would refuse the whole swap.
        if (!ok || fee >= BPS || tax >= BPS || fee + tax >= BPS - 100) return v;
        (bool okR, uint256 q, uint256 t) = _readReserves(curve);
        if (!okR || q == 0 || t == 0 || q >= MAX_RESERVE || t >= MAX_RESERVE) return v;
        uint256 cut = fee + tax;
        uint256 grown = _grown(q * t, cut, in0, sqrtPriceX96, lpFeePips);
        if (grown <= (buy ? q : t)) return v;
        uint256 sellable;
        (ok, sellable) = _read(curve, IPonsCurveLike.sellableTokens.selector);
        // Ready to graduate: the curve refuses both sides. A real curve's sellable tokens are its token reserve less a
        // reserved allocation of at least one token; any other answer is no venue (the buy cap below divides by the
        // difference).
        if (!ok || sellable == 0 || sellable >= t) return v;
        uint256 snipe;
        uint256 maxIn;
        if (buy) {
            // The curve charges the snipe tax of the buy's recipient, the PoolManager, bounded to leave 1% to buy.
            (ok, snipe) = _readFor(curve, IPonsCurveLike.currentSnipeTaxBps.selector, address(poolManager));
            if (!ok) return v;
            if (snipe != 0) {
                if (snipe > BPS - cut - 100) snipe = BPS - cut - 100;
                cut += snipe;
                grown = _grown(q * t, cut, in0, sqrtPriceX96, lpFeePips);
            }
            uint256 net = grown > q ? grown - q : 0;
            // The most quote that buys at most sellable - 1 tokens: n T / (Q + n) <= S - 1 exactly when
            // n <= (S - 1) Q / (T - S + 1), and T - S is the reserved allocation, never zero.
            uint256 cap = FullMath.mulDiv(sellable - 1, q, t - (sellable - 1));
            if (net > cap) net = cap;
            // The curve floors each fee, so the quote it credits for x is below x (1 - c) + 3: 3 less keeps it at or
            // under `net`.
            if (net > 3) maxIn = (net - 3) * BPS / (BPS - cut);
        } else {
            maxIn = grown - t;
        }
        if (maxIn > type(uint128).max) maxIn = type(uint128).max;
        v = Venue(curve, buy, in0, fee, tax, snipe, q, t, maxIn);
        if (maxIn != 0) {
            uint256 out = _out(v, maxIn);
            if (out == 0 || out < _floor(maxIn, sqrtPriceX96, lpFeePips, in0)) v.maxIn = 0;
        }
    }

    /// @dev The input reserve at which the curve's marginal rate after a cut of `cut` bps meets the pool's after its
    ///      LP fee: sqrt(k (1 - c) / (1 - f)), times 2^96 / sqrtP for a currency0 input, sqrtP / 2^96 otherwise.
    function _grown(uint256 k, uint256 cut, bool in0, uint160 sqrtPriceX96, uint24 lpFeePips)
        private
        pure
        returns (uint256)
    {
        uint256 root = Math.sqrt(FullMath.mulDiv(k, (BPS - cut) * PIPS, BPS * (PIPS - lpFeePips)));
        return in0 ? FullMath.mulDiv(root, Q96, sqrtPriceX96) : FullMath.mulDiv(root, sqrtPriceX96, Q96);
    }

    /// @dev The curve's own answer for `x` of input, as its integer math computes it: a buy floors each fee off the
    ///      quote and prices the rest at constant product, a sell prices the tokens at constant product and floors
    ///      each fee off the quote paid out.
    function _out(Venue memory v, uint256 x) private pure returns (uint256 out) {
        if (v.buy) {
            uint256 n = x - x * v.feeBps / BPS - x * v.taxBps / BPS - x * v.snipeBps / BPS;
            if (n != 0) out = n * v.tokenReserve / (v.quoteReserve + n);
        } else {
            uint256 gross = x * v.quoteReserve / (v.tokenReserve + x);
            if (gross != 0) out = gross - gross * v.feeBps / BPS - gross * v.taxBps / BPS;
        }
    }

    /// @dev HookrFill's floor, word for word: the pool's own rate for `x` at its spot price, less its LP fee.
    function _floor(uint256 x, uint160 sqrtPriceX96, uint24 lpFeePips, bool in0) private pure returns (uint256) {
        uint256 priceX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
        (uint256 n, uint256 d) = in0 ? (priceX128, uint256(1) << 128) : (uint256(1) << 128, priceX128);
        return FullMath.mulDiv(FullMath.mulDiv(x, n, d), PIPS - lpFeePips, PIPS);
    }

    /// @dev The curve of a pool of `a` and `b`, vouched for by the factory's record: `b` is tried as the launch token
    ///      first, then `a`.
    function _resolve(address a, address b) private view returns (address curve) {
        curve = _named(b);
        if (curve == address(0) || !_launched(b, a, curve)) {
            curve = _named(a);
            if (curve != address(0) && !_launched(a, b, curve)) curve = address(0);
        }
    }

    /// @dev The curve `token` names (a Pons launch token's `curve()`), or zero when it names none: a pair token or any
    ///      other token fails the view at once.
    function _named(address token) private view returns (address curve) {
        if (token == address(0)) return address(0);
        (bool ok, uint256 named) = _read(token, IPonsLaunchTokenLike.curve.selector);
        if (ok && named >> 160 == 0) curve = address(uint160(named));
    }

    /// @dev Whether the factory's record of `token` says it launched `token` against `pair` on `curve` and the launch
    ///      has not graduated (phase 0, still trading on its curve).
    function _launched(address token, address pair, address curve) private view returns (bool) {
        address factory = ponsFactory;
        bytes4 selector = IPonsLaunchFactoryLike.getLaunchedToken.selector;
        bool ok;
        uint256 recorded;
        uint256 recordedPair;
        uint256 phase;
        uint256 exists;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, selector)
            mstore(add(p, 4), token)
            ok := staticcall(RECORD_GAS, factory, p, 36, p, 480)
            ok := and(ok, eq(returndatasize(), 480))
            recorded := mload(add(p, 32))
            recordedPair := mload(add(p, 128))
            phase := mload(add(p, 320))
            exists := mload(add(p, 448))
        }
        return ok && exists == 1 && phase == 0 && recordedPair == uint256(uint160(pair))
            && recorded == uint256(uint160(curve));
    }

    /// @dev One word from a view with no argument, bounded to READ_GAS; false when the target does not answer it.
    function _read(address target, bytes4 selector) private view returns (bool ok, uint256 word) {
        assembly ("memory-safe") {
            mstore(0, selector)
            ok := staticcall(READ_GAS, target, 0, 4, 0, 32)
            ok := and(ok, gt(returndatasize(), 31))
            word := mload(0)
        }
    }

    /// @dev One word from a view of one address, bounded to READ_GAS.
    function _readFor(address target, bytes4 selector, address arg) private view returns (bool ok, uint256 word) {
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, selector)
            mstore(add(p, 4), arg)
            ok := staticcall(READ_GAS, target, p, 36, 0, 32)
            ok := and(ok, gt(returndatasize(), 31))
            word := mload(0)
        }
    }

    /// @dev The curve's tradeable reserves (quote, token), bounded to READ_GAS.
    function _readReserves(address curve) private view returns (bool ok, uint256 q, uint256 t) {
        bytes4 selector = IPonsCurveLike.getReserves.selector;
        assembly ("memory-safe") {
            mstore(0, selector)
            ok := staticcall(READ_GAS, curve, 0, 4, 0, 64)
            ok := and(ok, gt(returndatasize(), 63))
            q := mload(0)
            t := mload(32)
        }
    }

    /// @dev Approves exactly `amount` of `token` to `spender`, for a token that returns true or nothing.
    function _approve(address token, address spender, uint256 amount) private {
        (bool ok, bytes memory r) = token.call(abi.encodeWithSelector(0x095ea7b3, spender, amount));
        if (!ok || (r.length != 0 && (r.length < 32 || abi.decode(r, (uint256)) != 1))) revert UnexpectedCallback();
    }

    function _tget() private view returns (address a) {
        bytes32 slot = CALLING;
        assembly ("memory-safe") {
            a := tload(slot)
        }
    }

    function _tput(address a) private {
        bytes32 slot = CALLING;
        assembly ("memory-safe") {
            tstore(slot, a)
        }
    }
}
