// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {FeeBuybackHook} from "../src/FeeBuybackHook.sol";
import {HookFeeSplit} from "../src/HookFeeSplit.sol";
import {HookMiner} from "../../../templates/full-hook/src/HookMiner.sol";

/// @dev Deploys a PoolManager from lib/v4-core, mines the hook address for the three flags it
///      needs, opens a dynamic-fee pool (the protected pool) and a second, ordinary pool the
///      buyback executes on, adds liquidity to both, and swaps through PoolSwapTest. Every
///      assertion is on state a reader can check: balances, deltas, position fee growth, events.
contract FeeBuybackHookTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 internal constant MIN_CRANK = 1e16;
    uint256 internal constant CONFIG_DELAY = 2 days;
    uint24 internal constant HOOK_FEE_PIPS = 3_000; // 0.30% of the specified amount
    uint24 internal constant LP_FEE_PIPS = 1_000; // 0.10%
    uint24 internal constant OWNER_BPS = 1_000; // 10% of the hook fee
    uint24 internal constant LP_BPS = 1_000; // 10% of the hook fee
    uint24 internal constant BUYBACK_BPS = 8_000; // 80% of the hook fee
    uint16 internal constant MAX_SLIPPAGE_BPS = 500; // 5% against the pre-swap spot
    int24 internal constant RANGE = 600;
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;
    int256 internal constant LIQUIDITY = 1_000 ether;

    PoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liquidityRouter;
    MockERC20 internal quoteToken;
    MockERC20 internal hookToken;
    FeeBuybackHook internal hook;
    PoolKey internal key;
    PoolKey internal buybackKey;
    PoolId internal poolId;
    Currency internal quote;
    address internal feeRecipient;

    function setUp() public {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);

        MockERC20 a = new MockERC20("Quote", "Q", 18);
        MockERC20 b = new MockERC20("Token", "T", 18);
        (quoteToken, hookToken) = address(a) < address(b) ? (a, b) : (b, a);
        quote = Currency.wrap(address(quoteToken));
        feeRecipient = makeAddr("feeRecipient");

        for (uint256 i; i < 2; ++i) {
            MockERC20 t = i == 0 ? quoteToken : hookToken;
            t.mint(address(this), 10_000_000 ether);
            t.approve(address(swapRouter), type(uint256).max);
            t.approve(address(liquidityRouter), type(uint256).max);
        }

        buybackKey = PoolKey({
            currency0: Currency.wrap(address(quoteToken)),
            currency1: Currency.wrap(address(hookToken)),
            fee: 500, // an ordinary static-fee pool: a separate buyback venue
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });
        manager.initialize(buybackKey, SQRT_PRICE_1_1);
        liquidityRouter.modifyLiquidity(
            buybackKey,
            ModifyLiquidityParams({
                tickLower: -6000, tickUpper: 6000, liquidityDelta: LIQUIDITY, salt: bytes32(uint256(1))
            }),
            ""
        );

        PoolKey memory base = PoolKey({
            currency0: Currency.wrap(address(quoteToken)),
            currency1: Currency.wrap(address(hookToken)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        FeeBuybackHook.Config memory cfg = _defaultConfig();
        bytes memory args = abi.encode(IPoolManager(address(manager)), base, quote, address(this), CONFIG_DELAY, cfg);
        uint160 flags = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        (address expected, bytes32 salt) = HookMiner.find(address(this), flags, type(FeeBuybackHook).creationCode, args);
        hook = new FeeBuybackHook{salt: salt}(
            IPoolManager(address(manager)), base, quote, address(this), CONFIG_DELAY, cfg
        );
        assertEq(address(hook), expected, "mined address");

        (Currency c0, Currency c1, uint24 poolFee, int24 spacing, IHooks hooks) = hook.poolKey();
        key = PoolKey({currency0: c0, currency1: c1, fee: poolFee, tickSpacing: spacing, hooks: hooks});
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);
        liquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -RANGE, tickUpper: RANGE, liquidityDelta: LIQUIDITY, salt: bytes32(0)}),
            ""
        );
    }

    function _defaultConfig() internal view returns (FeeBuybackHook.Config memory) {
        return FeeBuybackHook.Config({
            hookFeePips: HOOK_FEE_PIPS,
            lpFeePips: LP_FEE_PIPS,
            ownerBps: OWNER_BPS,
            lpBps: LP_BPS,
            buybackBps: BUYBACK_BPS,
            maxSlippageBps: MAX_SLIPPAGE_BPS,
            paused: false,
            ownerFeeRecipient: feeRecipient,
            hookToken: Currency.wrap(address(hookToken)),
            buybackKey: buybackKey,
            buybackSink: BURN,
            minCrankQuote: MIN_CRANK
        });
    }

    // ---------------------------------------------------------------- fee charging

    function test_addressCarriesExactlyTheDeclaredFlags() public view {
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, hook.REQUIRED_FLAGS());
        assertEq(
            uint160(address(hook)) & Hooks.ALL_HOOK_MASK,
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
    }

    /// @dev An exact-input buy pays the pool's LP fee to the pool and the hook fee to the hook: the
    ///      trader's specified amount is unchanged, and the hook's quote balance grows by exactly
    ///      the fee `HookFeeSplit.hookFee` computes.
    function test_exactInputBuyPaysTheHookFeeInQuote() public {
        uint256 amountIn = 20 ether;
        uint256 expectedFee = HookFeeSplit.hookFee(amountIn, HOOK_FEE_PIPS);
        assertGt(expectedFee, 0, "the configured fee must be non-trivial");

        BalanceDelta delta = _swap(true, -int256(amountIn));

        assertEq(uint256(uint128(-delta.amount0())), amountIn, "the trader pays exactly the specified amount");
        assertEq(quoteToken.balanceOf(address(hook)), expectedFee, "the hook holds the hook fee in quote");
    }

    /// @dev The two mirror quadrants (exact-input sell, exact-output buy) put the quote on the
    ///      unspecified leg. This hook does not charge there — the same quadrants the kernel's
    ///      specified-leg quote take covers — so a sell pays only the pool's LP fee.
    function test_exactInputSellPaysNoHookFee() public {
        _swap(true, -5 ether); // move the price off 1:1 so the sell has room
        uint256 hookBefore = quoteToken.balanceOf(address(hook));

        _swap(false, -10 ether); // subject in, quote out: quote is the unspecified leg

        assertEq(quoteToken.balanceOf(address(hook)), hookBefore, "no hook fee on the unspecified leg");
    }

    /// @dev An exact-output buy also has the quote on the unspecified leg, so it pays no hook fee.
    function test_exactOutputBuyPaysNoHookFee() public {
        uint256 hookBefore = quoteToken.balanceOf(address(hook));
        _swap(true, 1 ether); // exact output: the subject amount is specified
        assertEq(quoteToken.balanceOf(address(hook)), hookBefore, "no hook fee on the unspecified leg");
    }

    function test_pausedChargesNothingButSwapsStillWork() public {
        _proposeAndExecute(_withPaused(true));
        BalanceDelta delta = _swap(true, -20 ether);
        assertEq(quoteToken.balanceOf(address(hook)), 0, "paused collects nothing");
        assertEq(uint256(uint128(-delta.amount0())), 20 ether, "the swap still executes");
    }

    // ---------------------------------------------------------------- the crank

    /// @dev The split: 10% to the owner, 10% donated into the pool (which is what makes it accrue
    ///      to in-range liquidity pro rata), 80% swapped into the hook token on the buyback venue
    ///      and sent to the sink. Nothing is left in the hook.
    function test_crankSplitsDonatesAndBuysBack() public {
        _swap(true, -20 ether);
        uint256 collected = quoteToken.balanceOf(address(hook));
        assertGe(collected, MIN_CRANK, "enough to crank");

        (uint256 toOwner, uint256 toLp, uint256 toBuyback) = HookFeeSplit.split(collected, OWNER_BPS, LP_BPS);
        uint256 ownerBefore = quoteToken.balanceOf(feeRecipient);
        uint256 lpFeesBefore = _inRangeQuoteFees();

        hook.crank(0);

        assertEq(quoteToken.balanceOf(feeRecipient) - ownerBefore, toOwner, "the owner share is exact");
        // The donation shows up as claimable quote fees on the in-range position, within the
        // two floored divisions the PoolManager's fee growth uses.
        assertApproxEqAbs(_inRangeQuoteFees() - lpFeesBefore, toLp, 2, "the LP share was donated to the pool");
        assertGt(hookToken.balanceOf(BURN), 0, "the sink received the hook token");
        assertEq(quoteToken.balanceOf(address(hook)), 0, "nothing is stranded in the hook");
        assertEq(hookToken.balanceOf(address(hook)), 0, "the hook holds no hook token");
        assertGt(toBuyback, 0, "the buyback leg carries most of the fee");
    }

    /// @dev With a zero slippage allowance the floor is the pre-swap spot, which the buyback cannot
    ///      meet (the swap pays the venue's fee), so the crank reverts and the fee stays put.
    function test_crankRevertsWhenTheFloorCannotBeMet() public {
        FeeBuybackHook.Config memory next = _withPaused(false);
        next.maxSlippageBps = 0;
        _proposeAndExecute(next);

        _swap(true, -20 ether);
        uint256 held = quoteToken.balanceOf(address(hook));
        uint256 ownerBefore = quoteToken.balanceOf(feeRecipient);

        (bool ok, bytes memory data) = address(hook).call(abi.encodeCall(FeeBuybackHook.crank, (0)));
        assertFalse(ok, "the crank must revert rather than sell below the floor");
        assertEq(bytes4(data), FeeBuybackHook.SlippageExceeded.selector, "it must revert on slippage");

        assertEq(quoteToken.balanceOf(address(hook)), held, "a reverted crank leaves the fee in place");
        assertEq(quoteToken.balanceOf(feeRecipient), ownerBefore, "and pays nobody");
    }

    /// @dev The hook's own buyback swap is a self-call, which v4's hook dispatcher skips, so the
    ///      crank cannot compound its own fee.
    function test_buybackSwapDoesNotAccrueAHookFee() public {
        _swap(true, -20 ether);
        hook.crank(0);
        assertEq(quoteToken.balanceOf(address(hook)), 0, "the whole balance was distributed once");
        assertGt(hookToken.balanceOf(BURN), 0, "the sink received the hook token");
    }

    function test_crankBelowTheMinimumReverts() public {
        _swap(true, -1 ether); // a 0.003 ether fee, below MIN_CRANK
        assertLt(quoteToken.balanceOf(address(hook)), MIN_CRANK);
        vm.expectRevert(FeeBuybackHook.NothingToCrank.selector);
        hook.crank(0);
    }

    // ---------------------------------------------------------------- config

    function test_configCannotBeExecutedBeforeTheTimelock() public {
        FeeBuybackHook.Config memory next = _withPaused(true);
        hook.proposeConfig(next);
        vm.expectRevert(FeeBuybackHook.ConfigNotReady.selector);
        hook.executeConfig();
        vm.warp(block.timestamp + CONFIG_DELAY);
        hook.executeConfig();
        assertTrue(hook.hookConfig().paused, "the change took effect after the delay");
    }

    function test_configBoundsAreEnforced() public {
        FeeBuybackHook.Config memory next = _withPaused(false);
        next.ownerBps = uint24(HookFeeSplit.MAX_OWNER_BPS + 1);
        next.lpBps = uint24(HookFeeSplit.BPS - next.ownerBps - next.buybackBps);
        vm.expectRevert(abi.encodeWithSelector(HookFeeSplit.OwnerShareAboveCeiling.selector, next.ownerBps));
        hook.proposeConfig(next);

        next = _withPaused(false);
        next.hookFeePips = uint24(HookFeeSplit.MAX_HOOK_FEE_PIPS + 1);
        vm.expectRevert(abi.encodeWithSelector(HookFeeSplit.HookFeeAboveCeiling.selector, next.hookFeePips));
        hook.proposeConfig(next);

        next = _withPaused(false);
        next.maxSlippageBps = uint16(HookFeeSplit.MAX_SLIPPAGE_BPS + 1);
        vm.expectRevert(abi.encodeWithSelector(HookFeeSplit.SlippageAboveCeiling.selector, next.maxSlippageBps));
        hook.proposeConfig(next);

        next = _withPaused(false);
        next.lpBps = uint24(next.lpBps + 1);
        vm.expectRevert(abi.encodeWithSelector(HookFeeSplit.SharesNotNormalized.selector, HookFeeSplit.BPS + 1));
        hook.proposeConfig(next);

        next = _withPaused(false);
        next.hookToken = quote;
        vm.expectRevert(FeeBuybackHook.HookTokenIsQuote.selector);
        hook.proposeConfig(next);

        next = _withPaused(false);
        next.buybackKey = key; // does not contain the hook token? it does — but the hooks field is the hook
        next.buybackKey.tickSpacing = 60;
        hook.proposeConfig(next); // accepted: any key that contains quote and hookToken
    }

    function test_onlyOwnerMayProposeOrExecute() public {
        FeeBuybackHook.Config memory next = _withPaused(true);
        vm.startPrank(makeAddr("stranger"));
        vm.expectRevert(FeeBuybackHook.NotOwner.selector);
        hook.proposeConfig(next);
        vm.expectRevert(FeeBuybackHook.NotOwner.selector);
        hook.executeConfig();
        vm.expectRevert(FeeBuybackHook.NotOwner.selector);
        hook.cancelConfig();
        vm.stopPrank();
    }

    function test_callbacksRefuseAnyoneButThePoolManager() public {
        vm.expectRevert(FeeBuybackHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, SwapParams(true, -1, 0), "");
        vm.expectRevert(FeeBuybackHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, SwapParams(true, -1, 0), BalanceDelta.wrap(0), "");
        vm.expectRevert(FeeBuybackHook.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(uint256(0), uint256(0), uint256(0)));
    }

    function test_callbacksRejectAnUnknownPool() public {
        PoolKey memory other = key;
        other.tickSpacing = 10;
        other.hooks = IHooks(address(hook));
        vm.prank(address(manager));
        vm.expectRevert(FeeBuybackHook.UnknownPool.selector);
        hook.beforeSwap(address(this), other, SwapParams(true, -1, 0), "");
    }

    function test_constructorRejectsADelayBelowTheMinimum() public {
        FeeBuybackHook.Config memory cfg = _defaultConfig();
        vm.expectRevert(FeeBuybackHook.ConfigDelayTooShort.selector);
        new FeeBuybackHook(IPoolManager(address(manager)), key, quote, address(this), 1 hours, cfg);
    }

    // ---------------------------------------------------------------- helpers

    function _swap(bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        return swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev Quote fees the in-range position in the protected pool can claim right now. The
    ///      donation from a crank shows up here, which is what makes the LP leg verifiable.
    function _inRangeQuoteFees() internal view returns (uint256) {
        (uint128 liquidity, uint256 inside0Last,) =
            StateLibrary.getPositionInfo(manager, poolId, address(liquidityRouter), -RANGE, RANGE, bytes32(0));
        (uint256 inside0,) = StateLibrary.getFeeGrowthInside(manager, poolId, -RANGE, RANGE);
        return uint256(inside0 - inside0Last) * liquidity / (1 << 128);
    }

    function _withPaused(bool paused) internal view returns (FeeBuybackHook.Config memory next) {
        next = _defaultConfig();
        next.paused = paused;
    }

    function _proposeAndExecute(FeeBuybackHook.Config memory next) internal {
        hook.proposeConfig(next);
        vm.warp(block.timestamp + CONFIG_DELAY);
        hook.executeConfig();
    }
}
