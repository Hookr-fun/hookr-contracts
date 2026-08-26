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
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {HookrLaunchpadV5} from "../src/HookrLaunchpadV5.sol";
import {HookrHook} from "../src/HookrHook.sol";
import {HookrToken} from "../src/HookrToken.sol";
import {HookParams, FeeRecipient} from "../src/libraries/HookrLaunchTypes.sol";
import {HookrLaunchpadLibV5} from "../src/libraries/HookrLaunchpadLibV5.sol";
import {IContinuousClearingAuctionFactory} from "../src/interfaces/IContinuousClearingAuction.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice The generation-5 zero-seed instant lane: the whole supply becomes one token-only sell
///         band, the pool opens at a creator-chosen FDV with NO quote seeded, and buyers deposit
///         all the ETH. These tests pin the opening geometry, prove the band is not drainable (the
///         inverse of HookrPairBoundaryAttack), and pin the locked-by-construction property.
contract InstantLaunchV5Test is Test {
    /// @dev A stand-in HOOKR address for constructor plumbing; ETH-lane tests never touch it.
    address constant MOCK_HOOKR = address(0xB00C);
    /// @dev A stand-in flywheel burner. Generation-5 ETH-quoted pools configure the 0.3% flywheel
    ///      fee, and the hook refuses that config with no recipient — so v5 tests must wire one.
    address constant FLYWHEEL_RECIPIENT = address(0xF17);

    using StateLibrary for IPoolManager;

    uint160 constant HOOK_FLAGS = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant DUMMY_FACTORY = address(0xACC);
    uint256 constant SUPPLY = 1_000_000_000e18;

    IPoolManager manager;
    HookrLaunchpadV5 pad;
    HookrHook hook;
    PoolSwapTest swapRouter;

    address creator = address(0xC0FFEE);
    address trader = address(0xB0B);

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
            abi.encodePacked(type(HookrHook).creationCode, abi.encode(manager, address(pad), FLYWHEEL_RECIPIENT));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, creation);
        hook = new HookrHook{salt: salt}(manager, address(pad), FLYWHEEL_RECIPIENT);
        assertEq(address(hook), predicted, "hook mine");
        pad.setHook(hook);
        swapRouter = new PoolSwapTest(manager);

        vm.deal(creator, 5000 ether);
        vm.deal(trader, 5000 ether);
    }

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

    function _args() internal view returns (HookrLaunchpadV5.LaunchArgs memory a) {
        a.name = "Zero Seed";
        a.symbol = "ZERO";
        a.tagline = "opens with no quote";
        a.logoURI = "";
        a.expectedCreator = creator;
        a.blueprintId = 0;
        a.custom = _quiet();
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

    function _launch() internal returns (address token) {
        uint256 fee = pad.creationFeeWei();
        vm.prank(creator);
        token = pad.launchInstant{value: fee}(_args(), HookrLaunchpadV5.Quote.Eth, bytes32(0));
    }

    // ------------------------------------------------------------------ opening

    function test_opensAtFixedPlatformFdv_withNoQuoteSeed() public {
        address token = _launch();

        HookrLaunchpadV5.Launch memory l = pad.getLaunch(token);
        assertEq(uint8(l.mode), uint8(HookrLaunchpadV5.LaunchMode.Instant), "mode");
        assertEq(uint8(l.status), uint8(HookrLaunchpadV5.LaunchStatus.Live), "live");

        // No ETH is seeded: the pool holds zero native currency at open.
        assertEq(address(manager).balance, 0, "pool holds no ETH at open");
        // The whole supply is in the band; the launchpad keeps none.
        assertEq(HookrToken(token).balanceOf(address(pad)), 0, "launchpad holds no token");

        // Every instant launch opens at the SAME fixed platform FDV (2.5 ETH, set at deploy).
        (uint160 sqrtP,,,) = manager.getSlot0(l.poolId);
        assertEq(sqrtP, l.sqrtPriceX96AtOpen, "pool opened at the fixed price");
        assertEq(l.openPriceWei, pad.instantOpenPriceWei(), "open price is the immutable");
        uint256 openFdv = uint256(l.openPriceWei) * (SUPPLY / 1e18);
        assertApproxEqRel(openFdv, 2.5 ether, 0.01e18, "open FDV ~2.5 ETH");
    }

    function test_twoLaunchesOpenIdentically() public {
        address a = _launch();
        uint256 fee = pad.creationFeeWei();
        vm.prank(creator);
        address b = pad.launchInstant{value: fee}(_args(), HookrLaunchpadV5.Quote.Eth, bytes32(0));
        assertEq(pad.getLaunch(a).openPriceWei, pad.getLaunch(b).openPriceWei, "same fixed open");
        assertEq(pad.getLaunch(a).sqrtPriceX96AtOpen, pad.getLaunch(b).sqrtPriceX96AtOpen, "same tick");
    }

    function test_firstBuyIsNotADrain_inverseOfBoundaryAttack() public {
        address token = _launch();
        PoolKey memory key = _key(token);

        // One raw wei of ETH must NOT drain a meaningful fraction of supply — the whole point of a
        // bounded interior-tick band versus a terminal-tick full-range position.
        vm.prank(trader);
        swapRouter.swap{value: 1}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(1), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertLt(HookrToken(token).balanceOf(trader), SUPPLY / 100_000, "1 wei took under 0.001% of supply");
    }

    function test_buyWalksPriceUp_andDeliversToken() public {
        address token = _launch();
        PoolKey memory key = _key(token);
        (uint160 sqrtBefore,,,) = manager.getSlot0(pad.getLaunch(token).poolId);

        vm.prank(trader);
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        (uint160 sqrtAfter,,,) = manager.getSlot0(pad.getLaunch(token).poolId);
        // Buying token pushes the pool price (token/ETH) DOWN, so sqrtPrice decreases and the
        // token's ETH-denominated price rises.
        assertLt(sqrtAfter, sqrtBefore, "price walked");
        assertGt(HookrToken(token).balanceOf(trader), 0, "trader received token");
        assertGt(address(manager).balance, 0.9 ether, "pool now holds the deposited ETH");
    }

    function test_cannotSellBeforeAnyBuy() public {
        address token = _launch();
        PoolKey memory key = _key(token);
        // No liquidity sits above the open tick, so a sell (oneForZero) fills nothing: the trader,
        // who holds no token to sell, extracts no ETH. Cannot dump what was never bought.
        uint256 ethBefore = trader.balance;
        vm.prank(trader);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertEq(trader.balance, ethBefore, "sell extracted no ETH from an all-token pool");
        assertEq(address(manager).balance, 0, "pool still holds no ETH");
    }

    // ------------------------------------------------------------------ refusals

    function test_rejectsLpDonationBlock_structurallyUnavailableOnZeroSeed() public {
        // A zero-seed pool opens with the tick outside its band: in-range liquidity is zero until
        // the first buy, and the hook fails closed on an LP-donation cut with nobody in range —
        // that first buy would revert forever. The lane must refuse lpBps up front.
        uint256 fee = pad.creationFeeWei();
        HookrLaunchpadV5.LaunchArgs memory a = _args();
        a.custom.lpBps = 25;
        vm.prank(creator);
        vm.expectRevert(HookrLaunchpadV5.InstantRejectsLpDonation.selector);
        pad.launchInstant{value: fee}(a, HookrLaunchpadV5.Quote.Eth, bytes32(0));
    }

    function test_deployRejectsAnUnplaceableFixedFdv() public {
        // The constructor precomputes the fixed instant band and reverts a launchpad whose fixed
        // FDV cannot resolve to a placeable open — proving a live launchpad's instant open is valid.
        vm.expectRevert(HookrLaunchpadV5.OpenPriceOutOfRange.selector);
        new HookrLaunchpadV5(
            manager, IContinuousClearingAuctionFactory(DUMMY_FACTORY), 100_000, 10, 10, 0, MOCK_HOOKR, 2_500_000e18
        );
    }

    // ------------------------------------------------------------------ fee collection

    function test_collectPoolFeesCollectsTheInstantBand() public {
        // REGRESSION: an instant pool holds ONLY the band position. A full-range poke (the bonded
        // path) targets a position this pool never minted, reverts on the zero-liquidity update,
        // and would permanently strand the fees. Collection must poke the band itself.
        address token = _launch();
        PoolKey memory key = _key(token);

        vm.prank(trader);
        swapRouter.swap{value: 5 ether}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(5 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 protocolBefore = pad.protocolFeesWei();
        pad.collectPoolFees(token);
        assertGt(pad.protocolFeesWei(), protocolBefore, "band swap fees actually collected");
    }

    // ------------------------------------------------------------------ intent replay

    function test_intentBlocksReplay() public {
        bytes32 id = keccak256("hookr.v5.instant.1");
        uint256 fee = pad.creationFeeWei();
        vm.prank(creator);
        address token = pad.launchInstant{value: fee}(_args(), HookrLaunchpadV5.Quote.Eth, id);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(HookrLaunchpadV5.LaunchIntentAlreadyUsed.selector, creator, id, token));
        pad.launchInstant{value: fee}(_args(), HookrLaunchpadV5.Quote.Eth, id);
    }

    // ------------------------------------------------------------------ fixed-FDV sweep

    function test_deploysAndOpensAcrossTheFixedFdvBand() public {
        uint96[3] memory fdvs = [uint96(0.5 ether), uint96(2.5 ether), uint96(100 ether)];
        for (uint256 i; i < fdvs.length; i++) {
            HookrLaunchpadV5 pad2 = new HookrLaunchpadV5(
                manager,
                IContinuousClearingAuctionFactory(DUMMY_FACTORY),
                100_000,
                10,
                10,
                fdvs[i],
                MOCK_HOOKR,
                2_500_000e18
            );
            bytes memory creation =
                abi.encodePacked(type(HookrHook).creationCode, abi.encode(manager, address(pad2), FLYWHEEL_RECIPIENT));
            (address predicted, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, creation);
            HookrHook hook2 = new HookrHook{salt: salt}(manager, address(pad2), FLYWHEEL_RECIPIENT);
            assertEq(address(hook2), predicted, "mine");
            pad2.setHook(hook2);

            uint256 fee = pad2.creationFeeWei();
            vm.prank(creator);
            address token = pad2.launchInstant{value: fee}(_args(), HookrLaunchpadV5.Quote.Eth, bytes32(0));
            HookrLaunchpadV5.Launch memory l = pad2.getLaunch(token);
            assertEq(uint8(l.status), uint8(HookrLaunchpadV5.LaunchStatus.Live), "live");
            assertEq(HookrToken(token).balanceOf(address(pad2)), 0, "no token stranded at any fixed FDV");
        }
    }
}
