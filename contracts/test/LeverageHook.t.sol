// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {LeverageHook} from "../src/LeverageHook.sol";
import {LeverageOracleLib} from "../src/libraries/LeverageOracleLib.sol";
import {ILeverage} from "../src/interfaces/ILeverage.sol";
import {HookrToken} from "../src/HookrToken.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice Minimal stand-in for LeverageMarket: opens its own unlock and calls the pool
///         manager directly, which is the only way the exclusivity gate can be satisfied —
///         v4 passes the immediate caller of `poolManager` as `sender`, so a shared router
///         can never be the market.
contract MarketStub is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    receive() external payable {}

    function addLiquidity(PoolKey calldata key, int256 liquidityDelta, int24 lower, int24 upper) external payable {
        manager.unlock(abi.encode(key, liquidityDelta, lower, upper));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (PoolKey memory key, int256 liquidityDelta, int24 lower, int24 upper) =
            abi.decode(data, (PoolKey, int256, int24, int24));

        (BalanceDelta delta,) = manager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: lower, tickUpper: upper, liquidityDelta: liquidityDelta, salt: bytes32(0)
            }),
            ""
        );

        if (delta.amount0() < 0) {
            manager.settle{value: uint256(int256(-delta.amount0()))}();
        }
        if (delta.amount1() < 0) {
            uint256 owed = uint256(int256(-delta.amount1()));
            manager.sync(key.currency1);
            IERC20Min(Currency.unwrap(key.currency1)).transfer(address(manager), owed);
            manager.settle();
        }
        return "";
    }
}

interface IERC20Min {
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice Pool-level invariants for the leverage hook, proven before any credit code exists.
///
///         The harness an earlier draft was credited with is the reason this file is explicit
///         about flags: that one mined 0x00CC — not the flags the design specifies — so it
///         proved none of the permissions it was cited for. This mines REQUIRED_FLAGS and
///         asserts the mined address actually carries them.
contract LeverageHookTest is Test {
    using StateLibrary for IPoolManager;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant MIN_LIMIT = 4295128739 + 1;
    uint24 constant DYNAMIC_FEE_FLAG = 0x800000;

    IPoolManager manager;
    LeverageHook hook;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    HookrToken token;
    PoolKey key;
    PoolId id;

    MarketStub marketStub;
    address market;
    address trader = address(0xB0B);

    receive() external payable {}

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);

        bytes memory creation = abi.encodePacked(type(LeverageHook).creationCode, abi.encode(manager, address(this)));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), _flags(), creation);
        hook = new LeverageHook{salt: salt}(manager, address(this));
        assertEq(address(hook), predicted, "mined address mismatch");

        // This contract stands in for the factory.
        hook.setFactory(address(this));

        marketStub = new MarketStub(manager);
        market = address(marketStub);
        token = new HookrToken("Lev", "LEV", "", "", address(this), 1_000_000 ether);

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        id = key.toId();

        hook.registerPool(key, market);
        manager.initialize(key, SQRT_PRICE_1_1);

        // Only the market may add liquidity, and it does so by calling the manager itself.
        token.transfer(market, 500_000 ether);
        vm.deal(market, 500 ether);
        marketStub.addLiquidity{value: 0}(key, 50 ether, -60000, 60000);

        vm.deal(trader, 100 ether);
        vm.deal(address(this), 1_000 ether);
    }

    function _flags() internal pure returns (uint160) {
        return uint160((1 << 13) | (1 << 12) | (1 << 11) | (1 << 9) | (1 << 7) | (1 << 6));
    }

    // ------------------------------------------------------------------ flags

    function test_minedAddressCarriesExactlyTheDeclaredFlags() public view {
        assertEq(uint160(address(hook)) & 0x3FFF, hook.REQUIRED_FLAGS(), "flags on the address");
        assertEq(hook.REQUIRED_FLAGS(), _flags(), "declared flags");
        // No returns-delta bits: this hook takes no swap-time cut, which is what keeps
        // ordinary traders on an unmodified v4 pool.
        assertEq(uint160(address(hook)) & (1 << 3), 0, "beforeSwapReturnsDelta must be unset");
        assertEq(uint160(address(hook)) & (1 << 2), 0, "afterSwapReturnsDelta must be unset");
    }

    // ------------------------------------------------------------------ the F2 regression

    /// The three oracle constants are not independent, and an earlier draft got this wrong in
    /// a way that deadlocked every active pool. This fails if anyone edits one of them alone.
    function test_walkCoversWindow() public pure {
        uint256 slotsNeeded = LeverageOracleLib.WINDOW_SEC / LeverageOracleLib.MIN_SPACING_SEC;
        assertGe(LeverageOracleLib.MAX_WALK, slotsNeeded, "walk cannot reach the window");
        assertLe(LeverageOracleLib.MAX_WALK, LeverageOracleLib.CARDINALITY, "walk exceeds the ring");
    }

    // ------------------------------------------------------------------ exclusivity

    function test_outsideLiquidityIsRefused() public {
        address outsider = address(0xBAD);
        token.transfer(outsider, 1_000 ether);
        vm.deal(outsider, 10 ether);
        vm.startPrank(outsider);
        token.approve(address(lpRouter), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(LeverageHook.LiquidityIsExclusive.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        lpRouter.modifyLiquidity{value: 1 ether}(
            key,
            ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1 ether, salt: bytes32(0)}),
            ""
        );
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ swaps and fees

    function test_swapWorksAndHookTakesNothing() public {
        uint256 hookEthBefore = address(hook).balance;
        uint256 before = token.balanceOf(trader);

        vm.prank(trader);
        BalanceDelta d = swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: MIN_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(d.amount0(), -1 ether, "exact input spent");
        assertGt(d.amount1(), 0, "tokens received");
        assertGt(token.balanceOf(trader), before, "trader holds the output");
        // The hook custodies nothing: no ETH, no claims.
        assertEq(address(hook).balance, hookEthBefore, "hook took ETH");
        assertEq(manager.balanceOf(address(hook), Currency.wrap(address(0)).toId()), 0, "hook took claims");
    }

    /// Exact-output must work. The surge formula this borrows casts `-amountSpecified`, which
    /// is negative on an exact-output swap — carrying it without its guard would revert here.
    function test_exactOutputSwapDoesNotRevert() public {
        vm.prank(trader);
        BalanceDelta d = swapRouter.swap{value: 5 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: MIN_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertEq(d.amount1(), 1 ether, "exact output received");
        assertLt(d.amount0(), 0, "ETH paid");
    }

    // ------------------------------------------------------------------ the oracle

    function test_oracleSeedsAtInitializeAndIsProtectedUntilCovered() public view {
        // A fresh pool has one observation and cannot cover the window, so it is protected:
        // a young market is not a broken market, it is one that may not be lent against yet.
        assertTrue(hook.isProtected(id), "fresh pool must be protected");
        ILeverage.PriceView memory p = hook.priceView(id);
        assertTrue(p.stale, "fresh ring is stale");
        assertGt(p.spotWad, 0, "spot still readable");
    }

    function test_oracleCoversWindowAfterEnoughSpacedSwaps() public {
        // Walk the ring forward with spaced, tiny swaps until the window is covered.
        // Time is tracked in a local and warped to an absolute value: reading
        // `block.timestamp` as the base inside the loop does not advance under via_ir here.
        uint256 t = block.timestamp;
        for (uint256 i = 0; i < LeverageOracleLib.MAX_WALK * 2; i++) {
            t += LeverageOracleLib.MIN_SPACING_SEC + 1;
            vm.warp(t);
            vm.prank(trader);
            swapRouter.swap{value: 0.01 ether}(
                key,
                SwapParams({zeroForOne: true, amountSpecified: -0.01 ether, sqrtPriceLimitX96: MIN_LIMIT}),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
            vm.deal(address(this), 1_000 ether);
        }
        ILeverage.PriceView memory p = hook.priceView(id);
        assertFalse(p.stale, "ring should cover the window after enough spaced writes");
        assertGt(p.twapWad, 0, "twap readable");
    }

    function test_ringRateLimitsWithinASingleBlock() public {
        // First build REAL, covered history — the thing a single-block burst would try to
        // flush. The previous version skipped this and asserted `stale` on a ring that was
        // ALREADY stale before its loop ran, so it proved nothing about the rate limiter: it
        // would have passed just as well with the limiter deleted. Recorded as one of the three
        // still-weak tests in contracts/AUDIT.md.
        uint256 t = block.timestamp;
        for (uint256 i = 0; i < LeverageOracleLib.MAX_WALK * 2; i++) {
            t += LeverageOracleLib.MIN_SPACING_SEC + 1;
            vm.warp(t);
            _tinyBuy();
        }
        ILeverage.PriceView memory pre = hook.priceView(id);
        assertFalse(pre.stale, "precondition: the window is covered before the burst");

        // Now fire many swaps in ONE timestamp. Each moves spot, but `write` samples a ring
        // SLOT at most once per MIN_SPACING_SEC, so a burst cannot fill the ring. Fire MORE
        // than MAX_WALK of them: if the slot rate-limit were removed, that many same-block
        // writes would stamp every observation the walk can reach with the current timestamp,
        // the walk would exhaust its steps without ever finding older history, and the average
        // would collapse to spot while reporting itself stale.
        for (uint256 i = 0; i < LeverageOracleLib.MAX_WALK + 10; i++) {
            _tinyBuy(); // no warp: same block
        }
        ILeverage.PriceView memory post = hook.priceView(id);

        // The burst really did move the pool — otherwise the test proves nothing about a flush.
        assertTrue(post.spotWad != pre.spotWad, "the burst must actually move spot");
        // History survived: the ring is still covered, not falsely stale.
        assertFalse(post.stale, "one block of swaps must not flush the ring");
        // And no time passed during the burst, so with the slot rate-limited the average is
        // computed from the same stored history as before and does not move at all. Ablate the
        // `MIN_SPACING_SEC` guard in LeverageOracleLib.write and this equality breaks: the TWAP
        // jumps to spot.
        assertEq(post.twapWad, pre.twapWad, "a same-block burst must not drag the average");
    }

    /// A single tiny buy from the funded trader. Kept small so the burst moves spot only a
    /// little — the rate-limit property holds regardless of push size, and a small push keeps
    /// the pool well inside its range.
    function _tinyBuy() internal {
        vm.deal(trader, 100 ether);
        vm.prank(trader);
        swapRouter.swap{value: 0.01 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -0.01 ether, sqrtPriceLimitX96: MIN_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // ------------------------------------------------------------------ registration

    function test_registrationIsFactoryGatedAndOneShot() public {
        PoolKey memory other = key;
        other.tickSpacing = 30;

        vm.prank(address(0xDEAD));
        vm.expectRevert(ILeverage.NotFactory.selector);
        hook.registerPool(other, market);

        hook.registerPool(other, market);
        vm.expectRevert(ILeverage.AlreadyRegistered.selector);
        hook.registerPool(other, market);
    }

    function test_unregisteredPoolCannotInitialize() public {
        PoolKey memory rogue = key;
        rogue.tickSpacing = 10;
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(ILeverage.PoolNotRegistered.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(rogue, SQRT_PRICE_1_1);
    }

    function test_factoryIsOneShot() public {
        vm.expectRevert(LeverageHook.FactoryAlreadySet.selector);
        hook.setFactory(address(0xFEE));
    }
}
