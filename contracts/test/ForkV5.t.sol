// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {HookrLaunchpadV5} from "../src/HookrLaunchpadV5.sol";
import {HookrHook} from "../src/HookrHook.sol";
import {HookrToken} from "../src/HookrToken.sol";
import {HookParams, FeeRecipient} from "../src/libraries/HookrLaunchTypes.sol";
import {
    IContinuousClearingAuctionFactory,
    IContinuousClearingAuction
} from "../src/interfaces/IContinuousClearingAuction.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice Bidder-only surface used to exercise the deployed upstream CCA. The launchpad's
///         production interface intentionally omits this because it never submits bids itself.
interface IForkContinuousClearingAuction {
    function submitBid(uint256 maxPriceQ96, uint128 amount, address owner, bytes calldata hookData)
        external
        payable
        returns (uint256 bidId);
}

/// @notice Generation-5 integration against LIVE chain 4663 state. Unlike the unit suites (which
///         mock the auction), this proves the instant lane trades on the real PoolManager and that
///         `launchAuction` creates and arms a REAL Continuous Clearing Auction through Uniswap's
///         DEPLOYED, permissionless factory — the one integration the mock cannot cover.
/// @dev Requires the `robinhood` RPC. Run with: forge test --match-contract ForkV5Test --fork-url robinhood
contract ForkV5Test is Test {
    /// @dev The LIVE HOOKR token on 4663 — the fork carries it.
    address constant HOOKR_LIVE = 0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c;
    /// @dev A stand-in flywheel burner. Generation-5 ETH-quoted pools configure the 0.3% flywheel
    ///      fee, and the hook refuses that config with no recipient — so v5 tests must wire one.
    address constant FLYWHEEL_RECIPIENT = address(0xF17);

    using StateLibrary for IPoolManager;

    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IContinuousClearingAuctionFactory constant CCA_FACTORY =
        IContinuousClearingAuctionFactory(0x000000001F26a0044BaA66024e7b6599c61963F8);
    uint160 constant HOOK_FLAGS = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    uint64 constant DURATION = 125_000;
    uint256 constant AUCTION_SUPPLY = 500_000_000e18;

    HookrLaunchpadV5 pad;
    HookrHook hook;
    PoolSwapTest swapRouter;

    address creator = address(0xC0FFEE);
    address trader = address(0xB0B);

    receive() external payable {}

    function setUp() public {
        // Opt-in: the public Robinhood RPC anti-bot-challenges forge's parallel fork state fetches,
        // so this lands in the release fork-rehearsal (with the private ALCHEMY_RPC_URL), not the
        // default suite. Run with: RUN_FORK_V5=true forge test --match-contract ForkV5Test
        if (!vm.envOr("RUN_FORK_V5", false)) {
            vm.skip(true);
            return;
        }
        // FORK_RPC_URL lets the release rehearsal use the private provider; the public node
        // anti-bot-challenges forge's parallel state fetches.
        string memory rpc = vm.envOr("FORK_RPC_URL", string("robinhood"));
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 4663, "not on 4663");

        pad = new HookrLaunchpadV5(PM, CCA_FACTORY, DURATION, 0, 1, 2.5 ether, HOOKR_LIVE, 2_500_000e18);
        bytes memory creation =
            abi.encodePacked(type(HookrHook).creationCode, abi.encode(PM, address(pad), FLYWHEEL_RECIPIENT));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, creation);
        hook = new HookrHook{salt: salt}(PM, address(pad), FLYWHEEL_RECIPIENT);
        assertEq(address(hook), predicted, "hook mine");
        pad.setHook(hook);
        swapRouter = new PoolSwapTest(PM);

        vm.deal(creator, 100 ether);
        vm.deal(trader, 100 ether);
    }

    function _args() internal view returns (HookrLaunchpadV5.LaunchArgs memory a) {
        a.name = "Fork V5";
        a.symbol = "FV5";
        a.tagline = "";
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

    function test_fork_instantLaunchTradesOnRealPoolManager() public {
        uint256 fee = pad.creationFeeWei();
        vm.prank(creator);
        address token = pad.launchInstant{value: fee}(_args(), HookrLaunchpadV5.Quote.Eth, bytes32(0));

        HookrLaunchpadV5.Launch memory l = pad.getLaunch(token);
        assertEq(uint8(l.status), uint8(HookrLaunchpadV5.LaunchStatus.Live), "live");

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        vm.prank(trader);
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertGt(HookrToken(token).balanceOf(trader), 0, "real pool delivered token");
    }

    function test_fork_launchAuctionCreatesAndArmsRealCCA() public {
        uint256 fee = pad.creationFeeWei();
        vm.prank(creator);
        address token =
            pad.launchAuction{value: fee}(_args(), HookrLaunchpadV5.Quote.Eth, 1 ether, 5 ether, 5000, bytes32(0));

        HookrLaunchpadV5.Launch memory l = pad.getLaunch(token);
        assertEq(uint8(l.status), uint8(HookrLaunchpadV5.LaunchStatus.Auctioning), "auctioning");
        // A REAL auction contract now exists at the address the deployed factory returned.
        assertTrue(l.auction != address(0), "auction created");
        assertGt(l.auction.code.length, 0, "auction has code");
        // It holds the auction supply and its end block is the window we configured.
        assertEq(HookrToken(token).balanceOf(l.auction), AUCTION_SUPPLY, "auction funded");
        assertEq(IContinuousClearingAuction(l.auction).endBlock(), uint64(block.number) + DURATION, "end block");
        assertFalse(IContinuousClearingAuction(l.auction).isGraduated(), "not graduated with zero bids");
        assertEq(
            HookrToken(token).balanceOf(address(pad)), 1_000_000_000e18 - AUCTION_SUPPLY, "launchpad holds reserve"
        );
    }

    /// @dev Regression for upstream CCA's lazy final checkpoint. One funded bid submitted at the
    ///      start of the window leaves `isGraduated()` false even after the end block. V5 must call
    ///      the real auction's permissionless `checkpoint()` before selecting its migration branch;
    ///      otherwise this graduated auction would be burned as a failure.
    function test_fork_migrateCheckpointsStaleGraduationOnRealCCA() public {
        uint96 floorFdvWei = 0.02 ether;
        uint96 raiseFloorWei = 0.01 ether;
        uint128 bidWei = 0.0105 ether;
        uint256 fee = pad.creationFeeWei();

        vm.prank(creator);
        address token = pad.launchAuction{value: fee}(
            _args(), HookrLaunchpadV5.Quote.Eth, floorFdvWei, raiseFloorWei, 2000, bytes32(0)
        );
        HookrLaunchpadV5.Launch memory beforeMigration = pad.getLaunch(token);
        IContinuousClearingAuction auction = IContinuousClearingAuction(beforeMigration.auction);

        // The launchpad rounds its raw floor down to the upstream CCA's 1%-of-floor tick grid.
        // Bid at exactly two aligned floor ticks; a raw `floor * 2` can miss the boundary.
        uint256 rawFloorPriceQ96 = (uint256(floorFdvWei) << 96) / pad.SUPPLY();
        uint256 tickSpacingQ96 = rawFloorPriceQ96 / 100;
        if (tickSpacingQ96 < 2) tickSpacingQ96 = 2;
        uint256 alignedFloorPriceQ96 = (rawFloorPriceQ96 / tickSpacingQ96) * tickSpacingQ96;

        vm.prank(trader);
        uint256 bidId = IForkContinuousClearingAuction(beforeMigration.auction).submitBid{value: bidWei}(
            alignedFloorPriceQ96 * 2, bidWei, trader, ""
        );
        assertEq(bidId, 0, "first real CCA bid id");
        assertFalse(auction.isGraduated(), "early bid must begin with stale graduation state");

        // Advancing the fork through the auction window does not itself mutate the CCA's stored
        // checkpoint. This is the exact state that the pre-fix V5 migration misclassified.
        vm.roll(uint256(beforeMigration.auctionEndBlock) + 1);
        assertFalse(auction.isGraduated(), "graduation remains stale after end until checkpoint");

        // Migration is permissionless. Its internal checkpoint must make the real CCA graduate,
        // sweep the raise, and open the v4 pool instead of taking the failed-auction burn branch.
        vm.prank(address(0xBEEF));
        pad.migrateAuction(token);

        HookrLaunchpadV5.Launch memory afterMigration = pad.getLaunch(token);
        assertTrue(auction.isGraduated(), "migration finalized real CCA graduation");
        assertEq(uint8(afterMigration.status), uint8(HookrLaunchpadV5.LaunchStatus.Live), "migrated live");
        assertTrue(PoolId.unwrap(afterMigration.poolId) != bytes32(0), "real v4 pool opened");
        assertGt(afterMigration.openPriceWei, 0, "clearing price recorded");
    }
}
