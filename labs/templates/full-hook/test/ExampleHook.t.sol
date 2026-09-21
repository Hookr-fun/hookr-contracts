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

import {ExampleHook} from "../src/ExampleHook.sol";
import {HookMiner} from "../src/HookMiner.sol";

/// @dev Deploys a PoolManager from lib/v4-core, mines a hook address that carries the two flags,
///      opens a dynamic-fee pool on it, adds liquidity and swaps through PoolSwapTest.
contract ExampleHookTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 internal constant FEE_PIPS = 3_000;

    PoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liquidityRouter;
    MockERC20 internal token0;
    MockERC20 internal token1;
    ExampleHook internal hook;
    PoolKey internal key;
    PoolId internal poolId;

    function setUp() public {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);

        MockERC20 a = new MockERC20("Token A", "A", 18);
        MockERC20 b = new MockERC20("Token B", "B", 18);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        token0.mint(address(this), 1_000_000 ether);
        token1.mint(address(this), 1_000_000 ether);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(liquidityRouter), type(uint256).max);
        token1.approve(address(liquidityRouter), type(uint256).max);

        // Mine a salt so the address carries exactly the two flags, then deploy with it. The
        // deployer is this test contract, which is what `find` is told.
        bytes memory constructorArgs = abi.encode(IPoolManager(address(manager)), FEE_PIPS);
        uint160 flags = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), flags, type(ExampleHook).creationCode, constructorArgs);
        hook = new ExampleHook{salt: salt}(IPoolManager(address(manager)), FEE_PIPS);
        assertEq(address(hook), expected, "mined address");
        assertEq(hook.REQUIRED_FLAGS(), flags, "the hook declares the flags it was mined for");

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);
        liquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1_000 ether, salt: 0}), ""
        );
    }

    function test_addressCarriesExactlyTheDeclaredFlags() public view {
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, hook.REQUIRED_FLAGS());
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
    }

    function test_swapCountsAndPaysTheOverriddenFee() public {
        assertEq(hook.swapCount(poolId), 0);
        uint256 balance1Before = token1.balanceOf(address(this));

        BalanceDelta delta = swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(hook.swapCount(poolId), 1, "one swap counted");
        assertEq(delta.amount0(), -1 ether, "exact input paid");
        assertGt(token1.balanceOf(address(this)), balance1Before, "output received");
        // 1 ether in at a 1:1 price on 1,000 ether of liquidity with a 0.30% fee comes out
        // below 0.9975 ether; without the override the dynamic-fee pool would charge nothing.
        assertLt(uint256(int256(delta.amount1())), 0.9975 ether, "fee was charged");
        assertGt(uint256(int256(delta.amount1())), 0.99 ether, "and not much more than 0.30% plus impact");
    }

    function test_secondSwapIncrementsAgain() public {
        for (uint256 i = 0; i < 3; i++) {
            swapRouter.swap(
                key,
                SwapParams({
                    zeroForOne: i % 2 == 0,
                    amountSpecified: -0.1 ether,
                    sqrtPriceLimitX96: i % 2 == 0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
        }
        assertEq(hook.swapCount(poolId), 3);
    }

    function test_callbacksRefuseAnyoneButThePoolManager() public {
        vm.expectRevert(ExampleHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, SwapParams(true, -1, 0), BalanceDelta.wrap(0), "");
    }

    function test_constructorRejectsAFeeAboveTheMaximum() public {
        vm.expectRevert(ExampleHook.FeeTooLarge.selector);
        new ExampleHook(IPoolManager(address(manager)), LPFeeLibrary.MAX_LP_FEE + 1);
    }
}
