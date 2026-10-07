// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {HookrReleased} from "hookr/base/HookrReleased.sol";
import {IHookrLaunchAdapter} from "../interfaces/IHookrLaunchAdapter.sol";
import {
    ExternalHookRecord,
    ExternalHookTypes,
    IHookrExternalHookBook,
    IHookrLaunchAdapterBound,
    IHookrSeedHost
} from "../interfaces/IHookrExternalHooks.sol";

/// @title GenericLaunchAdapter
/// @notice The generic adapter for pools with no hook, or with a hook that permits
///         direct initialization and external liquidity: `prepare` checks the record and the intent, `initialize`
///         calls `PoolManager.initialize`, `seed` places a launcher-owned token-only founding band.
/// @dev Shared code for the HOOKLESS and PLAIN_INITIALIZE protocols. `initProtocolId()` is `pure` in the draft ABI,
///      so one deployment cannot answer two ids; each protocol is a thin subclass admitted by its own code hash.
///      The band holds only the subject at the opening price: above it when the subject is currency0, below it when
///      the subject is currency1. `protocolData` is empty for the widest such band (from the first tick past the
///      price to the usable edge) or `abi.encode(int24 tickLower, int24 tickUpper)`; the launcher refuses a band whose
///      near edge is a whole tick spacing or more away from the opening price. The adapter never holds a
///      token: `seed` asks the launcher, through `IHookrSeedHost.seedPosition`, to add the band under its own
///      unlock from the launch's funds. Refusals beyond the design's list, each named in `UnsupportedIntent`:
///      `LP_RETURN_DELTA` for a hook whose liquidity callbacks return deltas (the band's cost or its exit would be
///      set by the hook, not by the plan), `QUOTE_UNUSED` for quote funding a token-only band cannot use.
abstract contract GenericLaunchAdapter is HookrReleased, IHookrLaunchAdapter, IHookrLaunchAdapterBound {
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable poolManager;
    IHookrExternalHookBook public immutable book;
    /// @inheritdoc IHookrLaunchAdapterBound
    address public immutable launcher;

    /// @param manager The Uniswap v4 PoolManager
    /// @param _book The external-hook records
    /// @param _launcher The only launcher this adapter serves
    constructor(IPoolManager manager, IHookrExternalHookBook _book, address _launcher) {
        if (address(manager).code.length == 0 || address(_book).code.length == 0 || _launcher.code.length == 0) {
            revert UnsupportedIntent("CONSTRUCTOR");
        }
        poolManager = manager;
        book = _book;
        launcher = _launcher;
    }

    modifier onlyLauncher() {
        if (msg.sender != launcher) revert NotLauncher();
        _;
    }

    /// @inheritdoc IHookrLaunchAdapter
    function prepare(address hook, LaunchIntent calldata intent)
        external
        view
        onlyLauncher
        returns (PoolKey memory key)
    {
        key = _prepare(hook, intent);
    }

    /// @inheritdoc IHookrLaunchAdapter
    function initialize(PoolKey calldata key, LaunchIntent calldata intent) external onlyLauncher returns (PoolId id) {
        _requirePrepared(key, intent);
        poolManager.initialize(key, intent.sqrtPriceX96);
        id = key.toId();
    }

    /// @inheritdoc IHookrLaunchAdapter
    function seed(PoolKey calldata key, LaunchIntent calldata intent)
        external
        payable
        onlyLauncher
        returns (Seeded memory seeded)
    {
        if (msg.value != 0) revert UnsupportedIntent("VALUE");
        _requirePrepared(key, intent);
        bool subjectFirst = Currency.unwrap(key.currency0) == Currency.unwrap(intent.subject);
        (int24 tickLower, int24 tickUpper) = _band(intent, subjectFirst);
        uint128 liquidity = _liquidity(intent.subjectAmount, subjectFirst, tickLower, tickUpper);
        (seeded.subjectUsed, seeded.quoteUsed, seeded.receipt) =
            IHookrSeedHost(launcher).seedPosition(tickLower, tickUpper, liquidity);
    }

    /// @notice The band `seed` would place for `intent`, and its liquidity
    function bandOf(LaunchIntent calldata intent)
        external
        pure
        returns (int24 tickLower, int24 tickUpper, uint128 liquidity)
    {
        bool subjectFirst = uint160(Currency.unwrap(intent.subject)) < uint160(Currency.unwrap(intent.quote));
        (tickLower, tickUpper) = _band(intent, subjectFirst);
        liquidity = _liquidity(intent.subjectAmount, subjectFirst, tickLower, tickUpper);
    }

    /// @dev HOOKLESS requires `hook == 0`; PLAIN_INITIALIZE requires a hook.
    function _checkProtocolHook(address hook) internal pure virtual;

    function _requirePrepared(PoolKey calldata key, LaunchIntent calldata intent) private view {
        PoolKey memory expected = _prepare(address(key.hooks), intent);
        if (keccak256(abi.encode(key)) != keccak256(abi.encode(expected))) revert UnsupportedIntent("KEY");
    }

    function _prepare(address hook, LaunchIntent calldata intent) private view returns (PoolKey memory key) {
        _checkProtocolHook(hook);
        ExternalHookRecord memory r = book.externalHook(hook);
        if (r.listingStatus != ExternalHookTypes.LAUNCHABLE || r.hook != hook) {
            revert UnsupportedIntent("NOT_LAUNCHABLE");
        }
        if (r.launchAdapter != address(this) || r.initProtocolId != this.initProtocolId()) {
            revert UnsupportedIntent("WRONG_ADAPTER");
        }
        if (hook != address(0) && hook.codehash != r.codeHash) revert UnsupportedIntent("CODE_CHANGED");
        uint32 caps = r.capabilities;
        if (caps & ExternalHookTypes.ALLOWS_EXTERNAL_LP == 0) revert UnsupportedIntent("NO_EXTERNAL_LP");
        if (caps & ExternalHookTypes.UPGRADEABLE != 0) revert UnsupportedIntent("UPGRADEABLE");
        if (
            uint160(hook)
                    & (Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG)
                != 0
        ) revert UnsupportedIntent("LP_RETURN_DELTA");
        address subject = Currency.unwrap(intent.subject);
        address quote = Currency.unwrap(intent.quote);
        if (subject == address(0) || subject == quote) revert UnsupportedIntent("SUBJECT");
        if (quote == address(0) && caps & ExternalHookTypes.REJECTS_NATIVE != 0) revert UnsupportedIntent("NATIVE");
        if (LPFeeLibrary.isDynamicFee(intent.fee)) {
            if (hook == address(0) || caps & ExternalHookTypes.STATIC_FEE_ONLY != 0) {
                revert UnsupportedIntent("DYNAMIC_FEE");
            }
        } else if (intent.fee > LPFeeLibrary.MAX_LP_FEE) {
            revert UnsupportedIntent("FEE");
        }
        if (intent.tickSpacing < TickMath.MIN_TICK_SPACING || intent.tickSpacing > TickMath.MAX_TICK_SPACING) {
            revert UnsupportedIntent("TICK_SPACING");
        }
        if (intent.sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || intent.sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            revert UnsupportedIntent("PRICE");
        }
        if (intent.subjectAmount == 0 || intent.subjectAmount > type(uint128).max) revert UnsupportedIntent("AMOUNT");
        if (intent.quoteAmount != 0) revert UnsupportedIntent("QUOTE_UNUSED");
        bool subjectFirst = uint160(subject) < uint160(quote);
        key = PoolKey({
            currency0: subjectFirst ? intent.subject : intent.quote,
            currency1: subjectFirst ? intent.quote : intent.subject,
            fee: intent.fee,
            tickSpacing: intent.tickSpacing,
            hooks: IHooks(hook)
        });
        (int24 tickLower, int24 tickUpper) = _band(intent, subjectFirst);
        if (_liquidity(intent.subjectAmount, subjectFirst, tickLower, tickUpper) == 0) {
            revert UnsupportedIntent("DUST");
        }
    }

    /// @dev The token-only band. Reverts `BAND` when it would hold any quote at the opening price or is empty.
    function _band(LaunchIntent calldata intent, bool subjectFirst)
        private
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        int24 spacing = intent.tickSpacing;
        int24 minTick = TickMath.minUsableTick(spacing);
        int24 maxTick = TickMath.maxUsableTick(spacing);
        if (intent.protocolData.length == 0) {
            int24 floor = _floor(TickMath.getTickAtSqrtPrice(intent.sqrtPriceX96), spacing);
            if (subjectFirst) {
                tickLower = floor + spacing;
                tickUpper = maxTick;
            } else {
                tickLower = minTick;
                tickUpper = floor;
            }
        } else {
            if (intent.protocolData.length != 64) revert UnsupportedIntent("BAND");
            (tickLower, tickUpper) = abi.decode(intent.protocolData, (int24, int24));
            if (tickLower % spacing != 0 || tickUpper % spacing != 0) revert UnsupportedIntent("BAND");
        }
        if (tickLower >= tickUpper || tickLower < minTick || tickUpper > maxTick) revert UnsupportedIntent("BAND");
        if (subjectFirst
                ? intent.sqrtPriceX96 > TickMath.getSqrtPriceAtTick(tickLower)
                : intent.sqrtPriceX96 < TickMath.getSqrtPriceAtTick(tickUpper)) {
            revert UnsupportedIntent("BAND");
        }
    }

    /// @dev Largest liquidity whose rounded-up cost fits in `amount`.
    function _liquidity(uint256 amount, bool subjectFirst, int24 tickLower, int24 tickUpper)
        private
        pure
        returns (uint128 liquidity)
    {
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);
        uint256 l = subjectFirst
            ? FullMath.mulDiv(amount, FullMath.mulDiv(sqrtA, sqrtB, FixedPoint96.Q96), sqrtB - sqrtA)
            : FullMath.mulDiv(amount, FixedPoint96.Q96, sqrtB - sqrtA);
        if (l > uint128(type(int128).max)) l = uint128(type(int128).max);
        liquidity = uint128(l);
        while (liquidity != 0) {
            uint256 cost = subjectFirst
                ? SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liquidity, true)
                : SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liquidity, true);
            if (cost <= amount) break;
            // Rounding up can exceed the budget by a unit; step down by the smallest amount that clears it.
            liquidity -= liquidity > 1_000 ? liquidity / 1_000_000_000 + 1 : 1;
        }
    }

    function _floor(int24 tick, int24 spacing) private pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;
        return compressed * spacing;
    }
}
