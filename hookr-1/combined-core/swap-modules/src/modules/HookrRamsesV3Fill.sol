// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {CurrencyReserves} from "@uniswap/v4-core/src/libraries/CurrencyReserves.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHookrSwapModule} from "rootv2/interfaces/IHookrSwapModule.sol";

/// @notice The slice of a Ramses V3 pool this module uses: Uniswap V3's `swap`, paid in `uniswapV3SwapCallback`, with
///         a dynamic `fee()` and `slot0()` led by the price.
interface IRamsesV3PoolLike {
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata)
        external
        returns (int256 amount0, int256 amount1);
}

/// @notice The slice of WETH this module uses. Robinhood Chain's WETH is Arbitrum's aeWETH, whose `depositTo` mints
///         straight to the venue, so an ETH payment never passes through a WETH balance of this module.
interface IWETHLike {
    function depositTo(address account) external payable;
    function withdraw(uint256 amount) external;
}

/// @title HookrRamsesV3Fill
/// @notice Outside fill from one tickSpacing of Ramses V3: for a Hookr pool of the same two tokens, native ETH standing
///         for WETH, it trades the Ramses pool of that tickSpacing while the venue, after its fee, beats the Hookr
///         pool's own price after its LP fee, and stops at that price, so the pool's own liquidity fills the rest. An
///         ETH-in swap pays the venue in WETH minted from the swap's ETH input; an ETH-out swap unwraps the venue's
///         WETH and settles it to the root as ETH.
/// @dev No owner, no setter, no storage: every call reads the venue fresh. The venue of a pair is its CREATE2 address
///      under Ramses V3's pool deployer (salt `keccak256(abi.encode(token0, token1, tickSpacing))`, the deployer's
///      fixed 55-byte init code), so the module never asks the factory and a pool from any other deployer is never a
///      venue. Every venue call is caught: a venue that is missing, reverts, is paused, runs out of gas or answers
///      malformed fills nothing and never stops the Hookr pool. The venue's callback refuses a fill below the price
///      floor HookrFill applies, on the same count HookrFill reads (what the PoolManager will count arriving, so a
///      token that delivers less than the venue sends fills nothing), so the root never has to refuse one. One
///      instance per tickSpacing.
contract HookrRamsesV3Fill is IHookrSwapModule {
    IPoolManager public immutable poolManager;
    IWETHLike public immutable weth;
    /// @notice Ramses V3's pool deployer, and the hash of the init code it creates every pool with.
    address public immutable poolDeployer;
    bytes32 public immutable poolInitCodeHash;
    int24 public immutable venueTickSpacing;

    /// @dev The venue whose callback may pay itself, transiently, while `fill` calls it.
    bytes32 private constant CALLING = keccak256("hookr.fill.transient.calling");
    uint256 private constant PIPS = 1_000_000;
    uint160 private constant MIN_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 private constant MAX_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
    /// @dev Gas kept back from the venue call to unwrap, settle, mint back and return: the costliest finish (an ETH
    ///      output, a partial fill, every slot cold) measures about 53,300 on the 4663 fork, the rest is margin for the
    ///      upgradeable WETH and token implementations it calls.
    uint256 private constant FINISH_GAS = 80_000;
    /// @dev The most gas a venue's `fee()` or `slot0()` read gets (Ramses V3: at most 5,117 cold, measured).
    uint256 private constant READ_GAS = 30_000;

    error BelowPoolPrice();
    error InvalidWiring();
    error Reentrancy();
    error UnexpectedCallback();

    constructor(IPoolManager manager, IWETHLike weth_, address deployer, bytes32 initCodeHash, int24 tickSpacing) {
        if (
            address(manager).code.length == 0 || address(weth_).code.length == 0 || deployer.code.length == 0
                || initCodeHash == bytes32(0) || tickSpacing <= 0
        ) revert InvalidWiring();
        poolManager = manager;
        weth = weth_;
        poolDeployer = deployer;
        poolInitCodeHash = initCodeHash;
        venueTickSpacing = tickSpacing;
    }

    /// @notice Takes ETH only from the PoolManager (the venue's payment) and WETH (the venue's output, unwrapped).
    receive() external payable {
        if (msg.sender != address(poolManager) && msg.sender != address(weth)) revert UnexpectedCallback();
    }

    /// @inheritdoc IHookrSwapModule
    function venueOf(Currency currency0, Currency currency1) external view returns (address venue) {
        (address a, address b) = (_asVenueToken(currency0), _asVenueToken(currency1));
        if (a != b) venue = a < b ? _venue(a, b) : _venue(b, a);
    }

    /// @inheritdoc IHookrSwapModule
    /// @dev The venue and its price against the Hookr pool's, as `fill` reads them: no venue for the pair, or one
    ///      already at or past the pool's price after both fees, answers false.
    function wouldFill(Currency input, Currency output, uint160 sqrtPriceX96, uint24 lpFeePips)
        external
        view
        returns (bool)
    {
        (,, uint160 limit) = _quote(input, output, sqrtPriceX96, lpFeePips);
        return limit != 0;
    }

    /// @inheritdoc IHookrSwapModule
    function fill(Currency input, Currency output, uint256 budget, uint160 sqrtPriceX96, uint24 lpFeePips)
        external
        returns (uint256 amountIn, uint256 amountOut)
    {
        if (_tget() != address(0)) revert Reentrancy();
        // The caller's claims become this module's credit; whatever the venue does not use goes back as claims.
        poolManager.burn(address(this), input.toId(), budget);
        (address venue, bool zeroForOne, uint160 limit) = _quote(input, output, sqrtPriceX96, lpFeePips);
        if (limit != 0) {
            bool ethOut = Currency.unwrap(output) == address(0);
            // An ERC-20 output is paid by the venue into the PoolManager; WETH for an ETH output comes here. The sync
            // runs for both: for ETH it clears any ERC-20 sync an earlier caller left pending, which would otherwise
            // make the PoolManager refuse the ETH settle below (`NonzeroNativeValue`) and revert the whole swap.
            poolManager.sync(output);
            uint256 got;
            (amountIn, got) = _swap(
                venue,
                ethOut ? address(this) : address(poolManager),
                zeroForOne,
                budget,
                limit,
                abi.encode(
                    input,
                    output,
                    uint256(sqrtPriceX96) | uint256(lpFeePips) << 160
                        | (Currency.unwrap(input) < Currency.unwrap(output) ? 1 << 184 : 0)
                )
            );
            if (!ethOut) {
                // Always settle after a sync, even nothing: no synced currency is left for the next payer. The output
                // is what the PoolManager counted arriving, never what the venue said.
                amountOut = poolManager.settleFor(msg.sender);
            } else if (got != 0) {
                weth.withdraw(got);
                amountOut = poolManager.settleFor{value: got}(msg.sender);
            }
        }
        uint256 unused = budget - amountIn;
        if (unused != 0) poolManager.mint(msg.sender, input.toId(), unused);
    }

    /// @notice The venue's swap callback: refuses a fill below the Hookr pool's price net of its LP fee (the floor
    ///         HookrFill applies, so the venue's trade reverts and fills nothing instead of the root refusing the
    ///         swap), then pays the venue what it is owed from this module's credit, minting WETH from ETH for an ETH
    ///         input.
    /// @dev A Uniswap V3 pool pays its output before it calls back. An ERC-20 output went to the PoolManager, so the
    ///      floor is checked on what the PoolManager holds above the reserve `fill`'s sync recorded, the amount its
    ///      `settleFor` will count and HookrFill will check, not on what the venue says it sent. WETH for an ETH output
    ///      came here and is settled whole.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        if (msg.sender != _tget()) revert UnexpectedCallback();
        (int256 owedSigned, int256 gotSigned) =
            amount0Delta > 0 ? (amount0Delta, amount1Delta) : (amount1Delta, amount0Delta);
        (address input, address output, uint256 terms) = abi.decode(data, (address, address, uint256));
        if (owedSigned <= 0 || gotSigned >= 0) revert UnexpectedCallback();
        uint256 owed = uint256(owedSigned);
        uint256 got = output == address(0)
            ? uint256(-gotSigned)
            : IERC20Minimal(output).balanceOf(address(poolManager))
                - uint256(poolManager.exttload(CurrencyReserves.RESERVES_OF_SLOT));
        // HookrFill's floor, word for word: the pool's own rate for `owed` at its spot price, less its LP fee.
        uint256 sqrtP = uint160(terms);
        uint256 priceX128 = FullMath.mulDiv(sqrtP, sqrtP, 1 << 64);
        (uint256 n, uint256 d) =
            (terms >> 184) & 1 != 0 ? (priceX128, uint256(1) << 128) : (uint256(1) << 128, priceX128);
        if (got < FullMath.mulDiv(FullMath.mulDiv(owed, n, d), PIPS - uint24(terms >> 160), PIPS)) {
            revert BelowPoolPrice();
        }
        if (input == address(0)) {
            poolManager.take(Currency.wrap(address(0)), address(this), owed);
            weth.depositTo{value: owed}(msg.sender);
        } else {
            poolManager.take(Currency.wrap(input), msg.sender, owed);
        }
    }

    /// @dev The venue for a swap of `input` for `output`, its direction, and the venue price at which it stops
    ///      beating the Hookr pool (zero when it has no venue for the pair or already does not beat the pool). On
    ///      the venue's own order, selling its token0 (price falls) it fills down to P (1 - f_pool) / (1 - f_venue);
    ///      buying it (price rises) up to P (1 - f_venue) / (1 - f_pool), in sqrt terms, rounded toward the pool's
    ///      side. P is the Hookr pool's price in the venue's order: inverted when native ETH, the Hookr pool's
    ///      currency0, maps to WETH above the other token.
    function _quote(Currency input, Currency output, uint160 sqrtPriceX96, uint24 lpFeePips)
        private
        view
        returns (address venue, bool zeroForOne, uint160 limit)
    {
        (address a, address b) = (_asVenueToken(input), _asVenueToken(output));
        if (a == b || lpFeePips >= PIPS) return (address(0), false, 0);
        zeroForOne = a < b;
        venue = zeroForOne ? _venue(a, b) : _venue(b, a);
        if (venue == address(0)) return (address(0), zeroForOne, 0);
        (bool ok, uint256 venueFee) = _read(venue, 0xddca3f43); // fee()
        if (!ok || venueFee >= PIPS) return (venue, zeroForOne, 0);
        uint256 venuePrice;
        (ok, venuePrice) = _read(venue, 0x3850c7bd); // slot0(), led by sqrtPriceX96
        if (!ok) return (venue, zeroForOne, 0);
        bool inverted = zeroForOne != (Currency.unwrap(input) < Currency.unwrap(output));
        uint256 l;
        if (zeroForOne) {
            uint256 factorX96 =
                Math.sqrt(FullMath.mulDivRoundingUp(PIPS - lpFeePips, 1 << 192, PIPS - venueFee), Math.Rounding.Ceil);
            l = inverted
                ? FullMath.mulDivRoundingUp(factorX96, 1 << 96, sqrtPriceX96)
                : FullMath.mulDivRoundingUp(sqrtPriceX96, factorX96, 1 << 96);
            if (l < MIN_LIMIT) l = MIN_LIMIT;
            if (venuePrice <= l) return (venue, zeroForOne, 0);
        } else {
            uint256 factorX96 = Math.sqrt(FullMath.mulDiv(PIPS - venueFee, 1 << 192, PIPS - lpFeePips));
            l = inverted
                ? FullMath.mulDiv(factorX96, 1 << 96, sqrtPriceX96)
                : FullMath.mulDiv(sqrtPriceX96, factorX96, 1 << 96);
            if (l > MAX_LIMIT) l = MAX_LIMIT;
            if (venuePrice >= l) return (venue, zeroForOne, 0);
        }
        limit = uint160(l);
    }

    /// @dev Calls the venue with all but FINISH_GAS, so one that reverts or runs out of gas fills nothing, and reads
    ///      its answer without copying more than two words. Returns the input it was paid and the output it sent.
    function _swap(address venue, address recipient, bool zeroForOne, uint256 budget, uint160 limit, bytes memory data)
        private
        returns (uint256 amountIn, uint256 got)
    {
        bytes memory call_ =
            abi.encodeCall(IRamsesV3PoolLike.swap, (recipient, zeroForOne, int256(budget), limit, data));
        _tput(venue);
        uint256 g = gasleft();
        g = g > FINISH_GAS ? g - FINISH_GAS : 0;
        bool ok;
        int256 amount0;
        int256 amount1;
        assembly ("memory-safe") {
            ok := call(g, venue, 0, add(call_, 32), mload(call_), 0, 64)
            if and(ok, gt(returndatasize(), 63)) {
                amount0 := mload(0)
                amount1 := mload(32)
            }
        }
        _tput(address(0));
        (int256 paid, int256 sent) = zeroForOne ? (amount0, amount1) : (amount1, amount0);
        if (paid > 0 && sent < 0) (amountIn, got) = (uint256(paid), uint256(-sent));
        if (amountIn > budget) revert UnexpectedCallback();
    }

    /// @dev One word from a venue view, bounded to READ_GAS; false when the venue does not answer it.
    function _read(address venue, bytes4 selector) private view returns (bool ok, uint256 word) {
        assembly ("memory-safe") {
            mstore(0, selector)
            ok := staticcall(READ_GAS, venue, 0, 4, 0, 32)
            ok := and(ok, gt(returndatasize(), 31))
            word := mload(0)
        }
    }

    /// @dev The Ramses V3 pool of (token0, token1) at this module's tickSpacing, or zero when none was created.
    function _venue(address token0, address token1) private view returns (address venue) {
        venue = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            poolDeployer,
                            keccak256(abi.encode(token0, token1, venueTickSpacing)),
                            poolInitCodeHash
                        )
                    )
                )
            )
        );
        if (venue.code.length == 0) venue = address(0);
    }

    /// @dev Native ETH trades as WETH on the venue.
    function _asVenueToken(Currency currency) private view returns (address token) {
        token = Currency.unwrap(currency);
        if (token == address(0)) token = address(weth);
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
