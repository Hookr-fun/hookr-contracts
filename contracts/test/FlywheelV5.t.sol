// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {HookrLaunchpadV5} from "../src/HookrLaunchpadV5.sol";
import {HookrHook} from "../src/HookrHook.sol";
import {HookrToken} from "../src/HookrToken.sol";
import {HookParams, FeeRecipient} from "../src/libraries/HookrLaunchTypes.sol";
import {IContinuousClearingAuctionFactory} from "../src/interfaces/IContinuousClearingAuction.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice The HOOKR flywheel protocol fee on an ETH-quoted generation-5 instant launch: 0.3%
///         (FLYWHEEL_FEE_PIPS = 3000) of the ETH side of every swap, accrued by the hook to the
///         flywheel recipient as native ERC-6909-backed claims. Quadrant coverage:
///
///           buy  exact-in  -> beforeSwap specified delta, 0.3% of the full requested input
///           buy  exact-out -> afterSwap unspecified delta, 0.3% of the ACTUAL pool charge, on top
///           sell exact-in  -> afterSwap unspecified delta, 0.3% of the ETH output, netted
///           sell exact-out -> EXEMPT (shaving ETH would break the exact requested output)
///
///         Plus: composition with the pot cut machinery, the canonical-limit requirement on
///         cut-bearing exact-in buys, the recipient's claim path, and the launchpad-set config.
contract FlywheelV5Test is Test {
    /// @dev A stand-in HOOKR address for constructor plumbing; ETH-lane tests never touch it.
    address constant MOCK_HOOKR = address(0xB00C);
    /// @dev Dedicated flywheel recipient (the burner's role, played by a plain address so the fee
    ///      arithmetic is observable in isolation; the real burner is exercised in FlywheelBurner.t).
    address constant FLYWHEEL = address(0xF1F);

    uint160 constant HOOK_FLAGS = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    address constant DUMMY_FACTORY = address(0xACC);
    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant PIPS = 1e6;
    uint256 constant BPS = 10_000;
    uint24 constant FLYWHEEL_PIPS = 3000; // 0.3%, set by the launchpad on ETH quotes

    IPoolManager manager;
    HookrLaunchpadV5 pad;
    HookrHook hook;
    PoolSwapTest swapRouter;

    address creator = address(0xC0FFEE);
    address trader = address(0xB0B);

    /// @dev Cached in setUp: reading it inline as `hook.MIN_SQRT_PRICE_LIMIT()` inside a swap's
    ///      argument list is an external staticcall that CONSUMES a pending vm.prank/expectRevert.
    uint160 minSqrtLimit;

    receive() external payable {}

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        pad = new HookrLaunchpadV5(
            manager,
            IContinuousClearingAuctionFactory(DUMMY_FACTORY),
            100_000,
            10,
            10,
            2.5 ether,
            MOCK_HOOKR,
            2_500_000e18
        );
        bytes memory creation =
            abi.encodePacked(type(HookrHook).creationCode, abi.encode(manager, address(pad), FLYWHEEL));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, creation);
        hook = new HookrHook{salt: salt}(manager, address(pad), FLYWHEEL);
        assertEq(address(hook), predicted, "hook mine");
        pad.setHook(hook);
        swapRouter = new PoolSwapTest(manager);
        minSqrtLimit = hook.MIN_SQRT_PRICE_LIMIT();

        vm.deal(creator, 100 ether);
        vm.deal(trader, 5000 ether);
    }

    // ------------------------------------------------------------------ helpers

    function _quiet() internal pure returns (HookParams memory p) {
        p = HookParams({
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
    }

    /// @dev Quiet plus the deterministic-pot block: the one ETH-denominated cut the instant lane
    ///      accepts (LP donation is structurally refused on zero-seed pools).
    function _potArmed() internal pure returns (HookParams memory p) {
        p = _quiet();
        p.potBps = 50; // 0.5% of the buy
        p.potEveryNBuys = 2;
        p.potMinBuyWei = 0.001 ether;
    }

    function _args(HookParams memory params) internal view returns (HookrLaunchpadV5.LaunchArgs memory a) {
        a.name = "Flywheel Coin";
        a.symbol = "FLY";
        a.tagline = "0.3% feeds the burn";
        a.logoURI = "";
        a.expectedCreator = creator;
        a.blueprintId = 0;
        a.custom = params;
        a.creatorFeeBps = 0;
        a.feeRecipients = new FeeRecipient[](0);
    }

    function _key(address token) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function _launch(HookParams memory params) internal returns (address token) {
        uint256 fee = pad.creationFeeWei();
        vm.prank(creator);
        token = pad.launchInstant{value: fee}(_args(params), HookrLaunchpadV5.Quote.Eth, bytes32(0));
    }

    function _buyExactIn(PoolKey memory key, uint256 ethIn, bytes memory hookData) internal {
        vm.prank(trader);
        swapRouter.swap{value: ethIn}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: minSqrtLimit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    // ------------------------------------------------------------------ 1. buy exact-in

    function test_buyExactIn_accruesExactFlywheelFee() public {
        address token = _launch(_quiet());
        PoolKey memory key = _key(token);
        PoolId id = pad.getLaunch(token).poolId;

        uint256 ethIn = 1 ether;
        uint256 expectedFee = (ethIn * FLYWHEEL_PIPS) / PIPS; // 0.003 ether

        vm.expectEmit(true, false, false, true, address(hook));
        emit HookrHook.FlywheelFeeAccrued(id, expectedFee);
        _buyExactIn(key, ethIn, "");

        assertEq(hook.claimableWei(FLYWHEEL), expectedFee, "claimable grew by exactly 0.3% of input");
        assertEq(hook.totalFlywheelWei(id), expectedFee, "pool lifetime stat matches");
        assertEq(hook.nativeClaimBalance(), expectedFee, "fee is 1:1 native-6909 backed");
        assertGt(HookrToken(token).balanceOf(trader), 0, "swap still delivered tokens");
    }

    // ------------------------------------------------------------------ 2. buy exact-in + cut blocks

    function test_buyExactIn_potBlockAndFlywheelCompose() public {
        address token = _launch(_potArmed());
        PoolKey memory key = _key(token);
        PoolId id = pad.getLaunch(token).poolId;

        uint256 ethIn = 1 ether;
        uint256 expectedFlywheel = (ethIn * FLYWHEEL_PIPS) / PIPS; // 0.003 ether of the FULL input
        uint256 expectedPotCut = (ethIn * 50) / BPS; // 0.005 ether

        _buyExactIn(key, ethIn, abi.encode(trader)); // pot buys must bind a recipient

        // Both machines took their exact share of the full input, independently.
        assertEq(hook.claimableWei(FLYWHEEL), expectedFlywheel, "flywheel = 0.3% of full input");
        assertEq(hook.totalFlywheelWei(id), expectedFlywheel, "flywheel stat");
        assertEq(hook.potWei(id), expectedPotCut, "pot cut = 0.5% of full input");
        assertEq(hook.totalHookFeesWei(id), expectedPotCut, "cut machinery accounted");
        assertEq(hook.potBuyCount(id), 1, "qualifying buy counted");

        // The swapper paid the full input; the PoolManager physically holds all of it; the hook's
        // minted claims carve out both takes, so the pool itself received input - cuts - flywheel.
        // (afterSwap independently enforces actualPoolIn == requested - cuts - flywheel, so the
        // swap succeeding is itself proof of that arithmetic.)
        assertEq(address(manager).balance, ethIn, "manager holds the full deposit");
        assertEq(hook.nativeClaimBalance(), expectedFlywheel + expectedPotCut, "claims back both takes");
        assertEq(
            address(manager).balance - hook.nativeClaimBalance(),
            ethIn - expectedFlywheel - expectedPotCut,
            "pool received input minus cuts minus flywheel"
        );
        assertGt(HookrToken(token).balanceOf(trader), 0, "swap succeeded");
    }

    // ------------------------------------------------------------------ 3. buy exact-out

    function test_buyExactOut_feeOnActualPoolCharge_onTop() public {
        address token = _launch(_quiet());
        PoolKey memory key = _key(token);
        PoolId id = pad.getLaunch(token).poolId;

        uint256 tokensOut = 1_000_000e18;
        uint256 ethBefore = trader.balance;

        vm.prank(trader);
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: int256(tokensOut), sqrtPriceLimitX96: minSqrtLimit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 fee = hook.claimableWei(FLYWHEEL);
        uint256 totalPaid = ethBefore - trader.balance; // router refunds the unused value
        uint256 poolCharged = totalPaid - fee; // = |delta.amount0| the pool actually charged

        assertGt(fee, 0, "flywheel accrued on the exact-out buy");
        assertEq(fee, (poolCharged * FLYWHEEL_PIPS) / PIPS, "fee = 0.3% of the ACTUAL pool charge");
        assertEq(hook.totalFlywheelWei(id), fee, "pool stat matches");
        assertEq(HookrToken(token).balanceOf(trader), tokensOut, "exact output delivered in full");
    }

    // ------------------------------------------------------------------ 4. sell exact-in

    function test_sellExactIn_feeNettedFromEthOutput() public {
        address token = _launch(_quiet());
        PoolKey memory key = _key(token);
        PoolId id = pad.getLaunch(token).poolId;

        _buyExactIn(key, 1 ether, "");
        uint256 feeAfterBuy = hook.claimableWei(FLYWHEEL);
        uint256 sellTokens = HookrToken(token).balanceOf(trader) / 2;
        uint256 ethBefore = trader.balance;

        vm.startPrank(trader);
        HookrToken(token).approve(address(swapRouter), sellTokens);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(sellTokens), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        uint256 fee = hook.claimableWei(FLYWHEEL) - feeAfterBuy;
        uint256 received = trader.balance - ethBefore;
        uint256 poolOutput = received + fee; // the ETH the pool paid out before the hook's take

        assertGt(fee, 0, "flywheel accrued on the sell");
        assertEq(fee, (poolOutput * FLYWHEEL_PIPS) / PIPS, "fee = 0.3% of the ETH output");
        assertEq(hook.totalFlywheelWei(id), feeAfterBuy + fee, "pool stat matches");
        assertGt(received, 0, "seller still received the netted ETH");
    }

    // ------------------------------------------------------------------ 5. sell exact-out: exempt

    function test_sellExactOut_isExempt_deliversExactEth() public {
        address token = _launch(_quiet());
        PoolKey memory key = _key(token);
        PoolId id = pad.getLaunch(token).poolId;

        _buyExactIn(key, 2 ether, "");
        uint256 feeAfterBuy = hook.claimableWei(FLYWHEEL);
        uint256 statAfterBuy = hook.totalFlywheelWei(id);

        uint256 wantEthOut = 0.05 ether;
        uint256 ethBefore = trader.balance;

        vm.startPrank(trader);
        HookrToken(token).approve(address(swapRouter), HookrToken(token).balanceOf(trader));
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: int256(wantEthOut), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        assertEq(trader.balance - ethBefore, wantEthOut, "the EXACT requested ETH arrived, unshaved");
        assertEq(hook.claimableWei(FLYWHEEL), feeAfterBuy, "no flywheel fee accrued");
        assertEq(hook.totalFlywheelWei(id), statAfterBuy, "pool stat untouched");
    }

    // ------------------------------------------------------------------ 6. wrong-limit buy refused

    function test_buyExactIn_nonCanonicalLimitReverts() public {
        address token = _launch(_quiet());
        PoolKey memory key = _key(token);

        // Any exact-in buy on a flywheel pool must carry the canonical full-fill limit: the fee is
        // priced from the requested input before v4 knows the fill, so a partial fill would
        // overcharge. The hook's revert bubbles wrapped by the PoolManager.
        vm.prank(trader);
        vm.expectPartialRevert(CustomRevert.WrappedError.selector);
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: minSqrtLimit + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // ------------------------------------------------------------------ 7. claim

    function test_claim_paysTheRecipientAndZeroes() public {
        address token = _launch(_quiet());
        _buyExactIn(_key(token), 1 ether, "");

        uint256 claimable = hook.claimableWei(FLYWHEEL);
        assertEq(claimable, (1 ether * uint256(FLYWHEEL_PIPS)) / PIPS, "known accrual to claim");
        uint256 balBefore = FLYWHEEL.balance;

        vm.prank(FLYWHEEL);
        hook.claim();

        assertEq(FLYWHEEL.balance - balBefore, claimable, "the ETH arrived");
        assertEq(hook.claimableWei(FLYWHEEL), 0, "claim zeroed");
        assertEq(hook.nativeClaimBalance(), 0, "backing claims burned with the payout");
    }

    // ------------------------------------------------------------------ 8. launchpad-set config

    function test_ethQuoteLaunchConfiguresFlywheelPips() public {
        address token = _launch(_quiet());
        PoolId id = pad.getLaunch(token).poolId;

        // PoolConfig has 17 fields; flywheelFeePips is appended last so prior slots are preserved.
        (bool initialized,,,,,,,,,,,,,,,, uint24 flywheelFeePips) = hook.poolConfig(id);
        assertTrue(initialized, "pool configured");
        assertEq(flywheelFeePips, FLYWHEEL_PIPS, "ETH-quote launch carries the 0.3% flywheel fee");
    }
}
