// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {HookrLaunchpadV5} from "../src/HookrLaunchpadV5.sol";
import {HookrHook} from "../src/HookrHook.sol";
import {HookrToken} from "../src/HookrToken.sol";
import {HookParams, FeeRecipient} from "../src/libraries/HookrLaunchTypes.sol";
import {IContinuousClearingAuctionFactory} from "../src/interfaces/IContinuousClearingAuction.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {MockAuctionFactory, MockAuction} from "./mocks/MockCCA.sol";

/// @notice The generation-5 bonded lane: a launch's raise is discovered by a Continuous Clearing
///         Auction (mocked here for the launchpad's orchestration; a fork test exercises the real
///         deployed factory). These tests pin the fund/arm handoff, the graduated migration into a
///         locked full-range pool, and the failed-auction burn.
contract AuctionLaunchV5Test is Test {
    /// @dev A stand-in HOOKR address for constructor plumbing; ETH-lane tests never touch it.
    address constant MOCK_HOOKR = address(0xB00C);
    /// @dev A stand-in flywheel burner. Generation-5 ETH-quoted pools configure the 0.3% flywheel
    ///      fee, and the hook refuses that config with no recipient — so v5 tests must wire one.
    address constant FLYWHEEL_RECIPIENT = address(0xF17);

    using StateLibrary for IPoolManager;

    uint160 constant HOOK_FLAGS = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant SUPPLY = 1_000_000_000e18;
    uint16 constant BPS = 10_000;
    /// Auction supply at the default 50/50 split (reserveBps = 5000).
    uint256 constant AUCTION_SUPPLY_50 = 500_000_000e18;
    uint64 constant DURATION = 100_000;
    uint64 constant MIG_DELAY = 10;

    IPoolManager manager;
    HookrLaunchpadV5 pad;
    HookrHook hook;
    MockAuctionFactory factory;
    PoolSwapTest swapRouter;

    address creator = address(0xC0FFEE);
    address trader = address(0xB0B);

    receive() external payable {}

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        factory = new MockAuctionFactory();
        pad = new HookrLaunchpadV5(
            manager,
            IContinuousClearingAuctionFactory(address(factory)),
            DURATION,
            10,
            MIG_DELAY,
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

        vm.deal(creator, 100 ether);
        vm.deal(trader, 5000 ether);
    }

    function _args() internal view returns (HookrLaunchpadV5.LaunchArgs memory a) {
        a.name = "Auction Coin";
        a.symbol = "AUC";
        a.tagline = "cleared by auction";
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

    uint96 constant FLOOR_FDV = 1 ether; // default starting valuation, below the graduation raise

    function _launchAuction(uint96 floor) internal returns (address token, MockAuction auction) {
        return _launchAuction(floor, 5000); // default: 50/50, zero proceeds
    }

    function _launchAuction(uint96 floor, uint16 reserveBps) internal returns (address token, MockAuction auction) {
        uint256 fee = pad.creationFeeWei();
        vm.prank(creator);
        token = pad.launchAuction{value: fee}(
            _args(), HookrLaunchpadV5.Quote.Eth, FLOOR_FDV, floor, reserveBps, bytes32(0)
        );
        auction = MockAuction(payable(pad.getLaunch(token).auction));
    }

    // ------------------------------------------------------------------ launch & arm

    function test_launchFundsAndArmsTheAuction() public {
        (address token, MockAuction auction) = _launchAuction(5 ether);

        HookrLaunchpadV5.Launch memory l = pad.getLaunch(token);
        assertEq(uint8(l.mode), uint8(HookrLaunchpadV5.LaunchMode.Bonded), "bonded");
        assertEq(uint8(l.status), uint8(HookrLaunchpadV5.LaunchStatus.Auctioning), "auctioning");
        assertEq(l.reserveBps, 5000, "reserve recorded");
        // At the 50/50 default: half auctioned, half reserved in the launchpad for migration.
        assertEq(HookrToken(token).balanceOf(address(auction)), AUCTION_SUPPLY_50, "auction holds auction supply");
        assertEq(HookrToken(token).balanceOf(address(pad)), SUPPLY - AUCTION_SUPPLY_50, "launchpad holds reserve");
        assertTrue(auction.armed(), "auction armed via onTokensReceived");
    }

    function test_cannotMigrateBeforeDelay() public {
        (address token, MockAuction auction) = _launchAuction(5 ether);
        auction.setOutcome(true, _clearingPriceX96(5 ether), 5 ether, 0);
        vm.expectRevert();
        pad.migrateAuction(token);
    }

    // ------------------------------------------------------------------ graduated migration

    function test_graduatedMigrationOpensLockedPool() public {
        (address token, MockAuction auction) = _launchAuction(5 ether);

        // A graduated auction: 5 ETH raised for all 500M auctioned -> clearing FDV 10 ETH.
        uint256 raise = 5 ether;
        vm.deal(address(auction), raise);
        auction.setOutcome(true, _clearingPriceX96(raise), raise, 0);

        vm.roll(block.number + DURATION + MIG_DELAY + 1);
        assertFalse(auction.isGraduated(), "CCA result is stale before final checkpoint");
        pad.migrateAuction(token);
        assertTrue(auction.checkpointed(), "launchpad finalized CCA before reading graduation");

        HookrLaunchpadV5.Launch memory l = pad.getLaunch(token);
        assertEq(uint8(l.status), uint8(HookrLaunchpadV5.LaunchStatus.Live), "live");
        // The pool now holds essentially the whole raise as locked liquidity.
        assertGt(address(manager).balance, 4.9 ether, "raise became pool ETH");
        assertApproxEqRel(uint256(l.openPriceWei) * (SUPPLY / 1e18), 10 ether, 0.02e18, "clearing FDV ~10 ETH");

        // The pool trades: a buy walks the price and delivers token.
        PoolKey memory key = _key(token);
        vm.prank(trader);
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertGt(HookrToken(token).balanceOf(trader), 0, "pool delivered token");
    }

    function test_migrationDepthBeatsTheOldCurve() public {
        (address token, MockAuction auction) = _launchAuction(5 ether);
        uint256 raise = 5 ether;
        vm.deal(address(auction), raise);
        auction.setOutcome(true, _clearingPriceX96(raise), raise, 0);
        vm.roll(block.number + DURATION + MIG_DELAY + 1);
        pad.migrateAuction(token);

        // 50/50 split => pool ETH ~ the whole raise, ~50% of FDV in depth. The stepped curve left
        // ~19% of a far larger FDV. Concretely: pool ETH / clearing FDV ~ 0.5.
        HookrLaunchpadV5.Launch memory l = pad.getLaunch(token);
        uint256 fdv = uint256(l.openPriceWei) * (SUPPLY / 1e18);
        assertApproxEqRel(address(manager).balance * 2, fdv, 0.05e18, "depth ~50% of FDV");
    }

    // ------------------------------------------------------------------ failed migration

    function test_failedAuctionBurnsAllSupply() public {
        (address token, MockAuction auction) = _launchAuction(5 ether);
        // Not graduated: sweep unsold auction supply back and burn everything.
        auction.setOutcome(false, 0, 0, AUCTION_SUPPLY_50);

        vm.roll(block.number + DURATION + MIG_DELAY + 1);
        pad.migrateAuction(token);

        HookrLaunchpadV5.Launch memory l = pad.getLaunch(token);
        assertEq(uint8(l.status), uint8(HookrLaunchpadV5.LaunchStatus.Failed), "failed");
        assertEq(HookrToken(token).balanceOf(DEAD), SUPPLY, "entire supply burned");
        assertEq(HookrToken(token).balanceOf(address(pad)), 0, "launchpad holds nothing");
        assertEq(address(manager).balance, 0, "no pool ever opened");
    }

    function test_cannotMigrateTwice() public {
        (address token, MockAuction auction) = _launchAuction(5 ether);
        auction.setOutcome(false, 0, 0, AUCTION_SUPPLY_50);
        vm.roll(block.number + DURATION + MIG_DELAY + 1);
        pad.migrateAuction(token);
        vm.expectRevert(HookrLaunchpadV5.NotAuctioning.selector);
        pad.migrateAuction(token);
    }

    function test_rejectsRaiseFloorOutOfRange() public {
        uint256 fee = pad.creationFeeWei();
        HookrLaunchpadV5.LaunchArgs memory a = _args();
        vm.prank(creator);
        vm.expectRevert(HookrLaunchpadV5.RaiseFloorOutOfRange.selector);
        pad.launchAuction{value: fee}(a, HookrLaunchpadV5.Quote.Eth, FLOOR_FDV, 0.005 ether, 5000, bytes32(0));
    }

    function test_rejectsFloorFdvOutOfRange() public {
        uint256 fee = pad.creationFeeWei();
        HookrLaunchpadV5.LaunchArgs memory a = _args();
        vm.prank(creator);
        vm.expectRevert(HookrLaunchpadV5.FloorFdvOutOfRange.selector);
        pad.launchAuction{value: fee}(a, HookrLaunchpadV5.Quote.Eth, 0.005 ether, 5 ether, 5000, bytes32(0)); // below MIN_FLOOR_FDV_WEI
        vm.prank(creator);
        vm.expectRevert(HookrLaunchpadV5.FloorFdvOutOfRange.selector);
        pad.launchAuction{value: fee}(a, HookrLaunchpadV5.Quote.Eth, 10_001 ether, 5 ether, 5000, bytes32(0)); // above MAX_FLOOR_FDV_WEI
    }

    function test_floorFdvDecouplesFromGraduationRaise() public {
        // pools.trade-style: the auction OPENS at the floor FDV but graduates only on the raise
        // floor — the two land in different AuctionParameters fields. The floor is the raw
        // FDV-over-total-supply price rounded DOWN to an exact tick boundary, because the CCA
        // initializes the floor as its first tick and refuses `TickPriceNotAtBoundary` otherwise.
        (, MockAuction auction) = _launchAuction(5 ether, 5000);
        uint256 rawFloor = (uint256(FLOOR_FDV) << 96) / SUPPLY;
        uint256 tick = rawFloor / 100;
        uint256 floor = auction.floorPriceQ96();
        assertEq(floor, (rawFloor / tick) * tick, "floor is the raw price rounded to a boundary");
        assertEq(floor % tick, 0, "floor sits exactly on a tick boundary");
        assertLe(rawFloor - floor, tick, "rounding concedes at most one tick");
        assertEq(auction.requiredCurrencyRaised(), 5 ether, "graduation threshold from raise floor");
    }

    /// @dev The live canary caught the deployed generation truncating the tick off the floor
    ///      (floor % tick = 51 wei -> the real CCA's `TickPriceNotAtBoundary`). Pin alignment for
    ///      every representable floor FDV, not just the happy value.
    function testFuzz_floorPriceAlwaysSitsOnATickBoundary(uint96 floorFdv) public {
        floorFdv = uint96(bound(floorFdv, 0.01 ether, 10_000 ether));
        uint256 fee = pad.creationFeeWei();
        vm.prank(creator);
        address token =
            pad.launchAuction{value: fee}(_args(), HookrLaunchpadV5.Quote.Eth, floorFdv, 5 ether, 5000, bytes32(0));
        MockAuction auction = MockAuction(payable(pad.getLaunch(token).auction));
        // The hardened mock already reverts misaligned floors at construction; assert the
        // properties explicitly so the invariant reads from the test, not the mock.
        uint256 raw = (uint256(floorFdv) << 96) / SUPPLY;
        uint256 tick = raw / 100 < 2 ? 2 : raw / 100;
        assertEq(auction.floorPriceQ96() % tick, 0, "aligned");
        assertLe(raw - auction.floorPriceQ96(), tick, "within one tick of the requested floor");
    }

    function test_ownerCanRetuneAuctionTimingForCanary() public {
        // A short window for a live canary, then flipped back — one contract, no redeploy.
        pad.setAuctionTiming(2500, 0, 1); // ~4 min at ~10 blocks/s (2500 divides 1e7)
        assertEq(pad.auctionDurationBlocks(), 2500, "duration retuned");
        (address token,) = _launchAuction(5 ether);
        // A launch started under the short window ends after 2500 blocks, not DURATION.
        assertEq(pad.getLaunch(token).auctionEndBlock, uint40(block.number + 2500), "short window applied");

        // Flipping the default back does NOT move the already-started auction's end block.
        pad.setAuctionTiming(DURATION, 10, MIG_DELAY);
        assertEq(pad.getLaunch(token).auctionEndBlock, uint40(block.number + 2500), "in-flight auction unaffected");
        // A non-divisor duration is refused.
        vm.expectRevert(HookrLaunchpadV5.AuctionScheduleInvalid.selector);
        pad.setAuctionTiming(144_000, 0, 1);
    }

    function test_rejectsReserveBpsOutOfRange() public {
        uint256 fee = pad.creationFeeWei();
        HookrLaunchpadV5.LaunchArgs memory a = _args();
        vm.prank(creator);
        vm.expectRevert(HookrLaunchpadV5.ReserveBpsOutOfRange.selector);
        pad.launchAuction{value: fee}(a, HookrLaunchpadV5.Quote.Eth, FLOOR_FDV, 5 ether, 1000, bytes32(0)); // below MIN_RESERVE_BPS
        vm.prank(creator);
        vm.expectRevert(HookrLaunchpadV5.ReserveBpsOutOfRange.selector);
        pad.launchAuction{value: fee}(a, HookrLaunchpadV5.Quote.Eth, FLOOR_FDV, 5 ether, 6000, bytes32(0)); // above MAX_RESERVE_BPS
    }

    // ------------------------------------------------------------------ configurable split / proceeds

    function test_configurableSplitPaysCreatorProceeds() public {
        // 20% reserved / 80% auctioned. At the clearing price the reserved tokens are worth a
        // quarter of the raise, so ~75% of the raise is the creator's disclosed proceeds.
        uint16 reserveBps = 2000;
        uint256 auctionSupply = (SUPPLY * (BPS - reserveBps)) / BPS; // 800M
        (address token, MockAuction auction) = _launchAuction(5 ether, reserveBps);
        assertEq(HookrToken(token).balanceOf(address(auction)), auctionSupply, "80% auctioned");

        uint256 raise = 5 ether;
        vm.deal(address(auction), raise);
        // clearing price for a full sale of the 800M auction supply
        auction.setOutcome(true, (raise << 96) / auctionSupply, raise, 0);

        vm.roll(block.number + DURATION + MIG_DELAY + 1);
        pad.migrateAuction(token);

        // ~1.25 ETH locks as liquidity; ~3.75 ETH is credited to the creator as proceeds.
        assertApproxEqRel(address(manager).balance, 1.25 ether, 0.03e18, "quarter of raise locked");
        assertApproxEqRel(pad.creatorProceedsWei(token), 3.75 ether, 0.03e18, "three quarters to creator");

        uint256 creatorBefore = creator.balance;
        pad.claimAuctionProceeds(token);
        assertApproxEqRel(creator.balance - creatorBefore, 3.75 ether, 0.03e18, "proceeds paid on claim");
        assertEq(pad.creatorProceedsWei(token), 0, "proceeds zeroed after claim");
    }

    function test_fiftyFiftyPaysNoProceeds() public {
        (address token, MockAuction auction) = _launchAuction(5 ether, 5000);
        uint256 raise = 5 ether;
        vm.deal(address(auction), raise);
        auction.setOutcome(true, _clearingPriceX96(raise), raise, 0);
        vm.roll(block.number + DURATION + MIG_DELAY + 1);
        pad.migrateAuction(token);
        // At MAX_RESERVE_BPS the reserved tokens balance the whole raise: zero (dust) proceeds.
        assertLt(pad.creatorProceedsWei(token), 0.01 ether, "no meaningful proceeds at 50/50");
    }

    // ------------------------------------------------------------------ auction clock

    /// @dev On Arbitrum/Orbit chains `block.number` is the PARENT chain's height while the CCA
    ///      lives on `ArbSys.arbBlockNumber()` — the live canary caught auctions being born
    ///      ~15.8M blocks in the past. With a mock ArbSys etched BEFORE deployment (the probe is
    ///      constructor-time), every auction-facing block must come from the precompile clock
    ///      while non-auction records stay on `block.number`.
    function test_auctionTimingRidesTheArbSysClockWhenPresent() public {
        uint256 rollupNow = 41_600_000;
        vm.etch(address(0x64), address(new MockArbSys()).code);
        MockArbSys(address(0x64)).setBlockNumber(rollupNow);

        HookrLaunchpadV5 clockPad = new HookrLaunchpadV5(
            manager,
            IContinuousClearingAuctionFactory(address(factory)),
            DURATION,
            10,
            MIG_DELAY,
            2.5 ether,
            MOCK_HOOKR,
            2_500_000e18
        );
        bytes memory creation =
            abi.encodePacked(type(HookrHook).creationCode, abi.encode(manager, address(clockPad), FLYWHEEL_RECIPIENT));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, creation);
        HookrHook clockHook = new HookrHook{salt: salt}(manager, address(clockPad), FLYWHEEL_RECIPIENT);
        assertEq(address(clockHook), predicted, "hook mine");
        clockPad.setHook(clockHook);

        uint256 fee = clockPad.creationFeeWei();
        vm.prank(creator);
        address token =
            clockPad.launchAuction{value: fee}(_args(), HookrLaunchpadV5.Quote.Eth, 1 ether, 5 ether, 5000, bytes32(0));
        HookrLaunchpadV5.Launch memory l = clockPad.getLaunch(token);

        // Auction timing on the precompile clock; the launch record on block.number.
        assertEq(uint256(l.auctionEndBlock), rollupNow + DURATION, "end block on the ArbSys clock");
        assertEq(uint256(l.launchBlock), block.number, "launch block stays on block.number");

        // Migration readiness compares against the SAME clock: rolling block.number far past the
        // end must NOT open migration while the auction clock still sits inside the window.
        MockAuction auction = MockAuction(payable(l.auction));
        vm.deal(address(auction), 5 ether);
        auction.setOutcome(true, _clearingPriceX96(5 ether), 5 ether, 0);
        vm.roll(block.number + DURATION + MIG_DELAY + 100);
        vm.expectRevert(
            abi.encodeWithSelector(
                HookrLaunchpadV5.MigrationNotReady.selector, rollupNow + DURATION + MIG_DELAY, rollupNow
            )
        );
        clockPad.migrateAuction(token);

        // Advance the AUCTION clock past readiness and it opens.
        MockArbSys(address(0x64)).setBlockNumber(rollupNow + DURATION + MIG_DELAY + 1);
        clockPad.migrateAuction(token);
        assertEq(uint8(clockPad.getLaunch(token).status), uint8(HookrLaunchpadV5.LaunchStatus.Live), "migrated");

        vm.etch(address(0x64), "");
    }

    // ------------------------------------------------------------------ helpers

    function _key(address token) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    /// @dev Clearing price Q96 (ETH-wei per token-wei) for `raise` ETH clearing all AUCTION_SUPPLY.
    function _clearingPriceX96(uint256 raise) internal pure returns (uint256) {
        return (raise << 96) / AUCTION_SUPPLY_50;
    }
}

/// @notice Minimal ArbSys stand-in: real selector, settable height, etched at address(0x64).
contract MockArbSys {
    uint256 internal stored;

    function setBlockNumber(uint256 value) external {
        stored = value;
    }

    function arbBlockNumber() external view returns (uint256) {
        return stored;
    }
}
