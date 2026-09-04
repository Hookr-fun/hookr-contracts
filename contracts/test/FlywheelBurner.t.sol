// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {HookrFlywheelBurner} from "../src/HookrFlywheelBurner.sol";
import {HookrLaunchpadV5} from "../src/HookrLaunchpadV5.sol";
import {HookrHook} from "../src/HookrHook.sol";
import {HookrToken} from "../src/HookrToken.sol";
import {HookParams, FeeRecipient} from "../src/libraries/HookrLaunchTypes.sol";
import {IContinuousClearingAuctionFactory} from "../src/interfaces/IContinuousClearingAuction.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @dev Minimal mintable ERC20 standing in for HOOKR. Returns true from transfer/transferFrom
///      (the burner requires a true return on its burn transfer).
contract MockHookr {
    string public constant name = "Mock HOOKR";
    string public constant symbol = "mHOOKR";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev A payable contract target for migrateTo (which refuses EOAs).
contract EthSink {
    receive() external payable {}
}

/// @notice HookrFlywheelBurner against a REAL PoolManager pool: a hookless ETH/mock-HOOKR pool
///         with the canonical production shape (fee 2500, tick spacing 25) seeded with two-sided
///         liquidity, plus the full generation-5 stack (launchpad + hook with the burner as
///         flywheel recipient) so collect() is exercised end to end — launch, buy, collect,
///         buyback-and-burn in one loop.
contract FlywheelBurnerTest is Test {
    uint160 constant HOOK_FLAGS = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    address constant DUMMY_FACTORY = address(0xACC);
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant PIPS = 1e6;
    uint24 constant CANON_FEE = 2500;
    int24 constant CANON_SPACING = 25;
    /// @dev Full usable range at spacing 25: floor(887272 / 25) * 25.
    int24 constant FULL_LOWER = -887_250;
    int24 constant FULL_UPPER = 887_250;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 2^96

    IPoolManager manager;
    MockHookr mockHookr;
    PoolModifyLiquidityTest lpRouter;
    PoolSwapTest swapRouter;
    HookrFlywheelBurner burner;
    HookrLaunchpadV5 pad;
    HookrHook hook;
    PoolKey canonKey;

    address creator = address(0xC0FFEE);
    address trader = address(0xB0B);
    address stranger = address(0xBAD);

    /// @dev Cached in setUp: reading it inline as `hook.MIN_SQRT_PRICE_LIMIT()` inside a swap's
    ///      argument list is an external staticcall that CONSUMES a pending vm.prank/expectRevert.
    uint160 minSqrtLimit;

    receive() external payable {}

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        mockHookr = new MockHookr();
        lpRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);

        // The canonical hookless ETH/HOOKR venue, at the production key shape.
        canonKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(mockHookr)),
            fee: CANON_FEE,
            tickSpacing: CANON_SPACING,
            hooks: IHooks(address(0))
        });
        manager.initialize(canonKey, SQRT_PRICE_1_1);

        // Two-sided full-range depth at 1:1 — ~1000 ETH and ~1000 mHOOKR.
        mockHookr.mint(address(this), 1e27);
        mockHookr.approve(address(lpRouter), type(uint256).max);
        vm.deal(address(this), 10_000 ether);
        lpRouter.modifyLiquidity{value: 1_050 ether}(
            canonKey,
            ModifyLiquidityParams({
                tickLower: FULL_LOWER, tickUpper: FULL_UPPER, liquidityDelta: int256(1_000e18), salt: 0
            }),
            ""
        );

        // Burner first (the hook takes it as a constructor immutable), then the full v5 stack.
        burner = new HookrFlywheelBurner(manager, address(mockHookr), CANON_FEE, CANON_SPACING);
        pad = new HookrLaunchpadV5(
            manager,
            IContinuousClearingAuctionFactory(DUMMY_FACTORY),
            100_000,
            10,
            10,
            2.5 ether,
            address(mockHookr),
            2_500_000e18
        );
        bytes memory creation =
            abi.encodePacked(type(HookrHook).creationCode, abi.encode(manager, address(pad), address(burner)));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, creation);
        hook = new HookrHook{salt: salt}(manager, address(pad), address(burner));
        assertEq(address(hook), predicted, "hook mine");
        pad.setHook(hook);
        burner.setHook(address(hook));
        minSqrtLimit = hook.MIN_SQRT_PRICE_LIMIT();

        vm.deal(creator, 100 ether);
        vm.deal(trader, 100 ether);
    }

    // ------------------------------------------------------------------ 1. happy path

    function test_buybackAndBurn_happyPath() public {
        vm.deal(address(burner), 1 ether);
        uint256 deadBefore = mockHookr.balanceOf(DEAD);

        vm.expectEmit(true, false, false, false, address(burner));
        emit HookrFlywheelBurner.BuybackBurned(address(this), 0, 0); // caller topic only; amounts checked below

        uint256 burned = burner.buybackAndBurn(0.1 ether, 1);

        assertGt(burned, 0, "bought something");
        // At 1:1 with deep liquidity: ~0.1 out, less the 0.25% LP fee and slippage.
        assertApproxEqRel(burned, 0.09975 ether, 0.01e18, "roughly 0.1 less the 0.25% pool fee");
        assertEq(mockHookr.balanceOf(DEAD) - deadBefore, burned, "every token received went to 0xdEaD");
        assertEq(mockHookr.balanceOf(address(burner)), 0, "nothing stranded on the burner");
        assertEq(burner.totalEthSpent(), 0.1 ether, "lifetime spend updated");
        assertEq(burner.totalHookrBurned(), burned, "lifetime burn updated");
        assertEq(address(burner).balance, 0.9 ether, "balance dropped by exactly the buyback");
    }

    // ------------------------------------------------------------------ 2. bounds

    function test_buybackBounds_balanceCeilingAndThrottle() public {
        // More than the balance -> NothingToBuy (checked before the ceiling).
        vm.deal(address(burner), 0.05 ether);
        vm.expectRevert(HookrFlywheelBurner.NothingToBuy.selector);
        burner.buybackAndBurn(0.1 ether, 1);

        // Zero -> NothingToBuy.
        vm.expectRevert(HookrFlywheelBurner.NothingToBuy.selector);
        burner.buybackAndBurn(0, 1);

        // Over the per-call ceiling -> BuybackTooLarge.
        vm.deal(address(burner), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(HookrFlywheelBurner.BuybackTooLarge.selector, 0.5 ether, 0.25 ether));
        burner.buybackAndBurn(0.5 ether, 1);

        // One per block: the first call lands, the second in the same block is refused.
        burner.buybackAndBurn(0.1 ether, 1);
        vm.expectRevert(HookrFlywheelBurner.BuybackThisBlockAlready.selector);
        burner.buybackAndBurn(0.1 ether, 1);

        // The next block succeeds.
        vm.roll(vm.getBlockNumber() + 1);
        uint256 burned = burner.buybackAndBurn(0.1 ether, 1);
        assertGt(burned, 0, "next-block buyback went through");
    }

    // ------------------------------------------------------------------ 3. owner execution authority + bound

    function test_buybackAndBurn_onlyOwner_andNonzeroBound() public {
        vm.deal(address(burner), 1 ether);

        vm.prank(stranger);
        vm.expectRevert(HookrFlywheelBurner.NotOwner.selector);
        burner.buybackAndBurn(0.1 ether, 1);

        vm.expectRevert(HookrFlywheelBurner.ZeroMinimumOutput.selector);
        burner.buybackAndBurn(0.1 ether, 0);
    }

    function test_minHookrOutTooHigh_reverts() public {
        vm.deal(address(burner), 1 ether);
        vm.expectPartialRevert(HookrFlywheelBurner.TooLittleReceived.selector);
        burner.buybackAndBurn(0.1 ether, type(uint256).max);
    }

    // ------------------------------------------------------------------ 4. the whole loop

    function test_collectFromHook_thenBuybackAndBurn_fullLoop() public {
        // Launch an ETH-quoted instant token whose 0.3% flywheel fee accrues to the burner.
        uint256 fee = pad.creationFeeWei();
        vm.prank(creator);
        address token = pad.launchInstant{value: fee}(_args(), HookrLaunchpadV5.Quote.Eth, bytes32(0));
        PoolKey memory launchKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // One 1 ETH buy -> 0.003 ETH accrued to the burner's claim balance.
        vm.prank(trader);
        swapRouter.swap{value: 1 ether}(
            launchKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: minSqrtLimit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 accrued = hook.claimableWei(address(burner));
        assertEq(accrued, (1 ether * 3000) / PIPS, "0.3% of the buy accrued to the burner");

        // collect(): pull the claim out of the hook into the burner as real ETH.
        vm.expectEmit(false, false, false, true, address(burner));
        emit HookrFlywheelBurner.FlywheelCollected(accrued);
        burner.collect();
        assertEq(address(burner).balance, accrued, "collected ETH sits on the burner");
        assertEq(hook.claimableWei(address(burner)), 0, "hook claim zeroed");

        // buybackAndBurn(): the collected fee becomes burned HOOKR through the canonical pool.
        uint256 deadBefore = mockHookr.balanceOf(DEAD);
        uint256 burned = burner.buybackAndBurn(accrued, 1);
        assertGt(burned, 0, "the loop bought HOOKR");
        assertEq(mockHookr.balanceOf(DEAD) - deadBefore, burned, "and burned all of it");
        assertEq(address(burner).balance, 0, "the whole collection was spent");
        assertEq(burner.totalEthSpent(), accrued, "spend stat matches the collection");
        assertEq(burner.totalHookrBurned(), burned, "burn stat matches");
    }

    // ------------------------------------------------------------------ 5. admin surfaces

    function test_setMaxBuybackWei_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(HookrFlywheelBurner.NotOwner.selector);
        burner.setMaxBuybackWei(1 ether);

        vm.expectEmit(false, false, false, true, address(burner));
        emit HookrFlywheelBurner.MaxBuybackSet(1 ether);
        burner.setMaxBuybackWei(1 ether);
        assertEq(burner.maxBuybackWei(), 1 ether, "ceiling updated by the owner");
    }

    function test_setHook_onceOnly_andOnlyOwner() public {
        // setUp already wired the main burner; prove once-only there...
        vm.expectRevert(HookrFlywheelBurner.HookAlreadySet.selector);
        burner.setHook(address(this));

        // ...and the full surface on a fresh instance.
        HookrFlywheelBurner fresh = new HookrFlywheelBurner(manager, address(mockHookr), CANON_FEE, CANON_SPACING);
        vm.prank(stranger);
        vm.expectRevert(HookrFlywheelBurner.NotOwner.selector);
        fresh.setHook(address(hook));

        vm.expectRevert(HookrFlywheelBurner.ZeroAddress.selector);
        fresh.setHook(address(0));

        fresh.setHook(address(hook));
        assertEq(fresh.hook(), address(hook), "hook wired");

        vm.expectRevert(HookrFlywheelBurner.HookAlreadySet.selector);
        fresh.setHook(address(this));
    }

    function test_migrateTo_refusesEoas_movesBalanceToContract() public {
        vm.deal(address(burner), 1 ether);

        vm.prank(stranger);
        vm.expectRevert(HookrFlywheelBurner.NotOwner.selector);
        burner.migrateTo(payable(address(0xE0A)));

        vm.expectRevert(HookrFlywheelBurner.MigrateToEoa.selector);
        burner.migrateTo(payable(address(0xE0A)));

        EthSink sink = new EthSink();
        vm.expectEmit(true, false, false, true, address(burner));
        emit HookrFlywheelBurner.BalanceMigrated(address(sink), 1 ether);
        burner.migrateTo(payable(address(sink)));
        assertEq(address(sink).balance, 1 ether, "balance moved to the successor contract");
        assertEq(address(burner).balance, 0, "burner emptied");
    }

    // ------------------------------------------------------------------ launch helper

    function _args() internal view returns (HookrLaunchpadV5.LaunchArgs memory a) {
        a.name = "Loop Coin";
        a.symbol = "LOOP";
        a.tagline = "fees in, burn out";
        a.logoURI = "";
        a.expectedCreator = creator;
        a.blueprintId = 0;
        a.custom = HookParams({
            guardBlocks: 0,
            maxBuyBps: 0,
            snipeTaxPips: 0,
            baseFeePips: 3000,
            maxFeePips: 30_000,
            surgeSens: 5,
            burnBps: 0,
            burnTriggerWei: 0,
            lpBps: 0,
            potBps: 0,
            potEveryNBuys: 0,
            potMinBuyWei: 0
        });
        a.creatorFeeBps = 0;
        a.feeRecipients = new FeeRecipient[](0);
    }
}
