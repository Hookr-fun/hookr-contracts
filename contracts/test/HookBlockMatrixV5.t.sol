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
import {MockAuctionFactory, MockAuction} from "./mocks/MockCCA.sol";

/// @notice EVERY hook-block combination through EVERY generation-5 launch route. The five
///         composable blocks — guard (cap + snipe tax), surge fees, auto-burn, LP donation, and
///         the deterministic pot — are toggled through all 32 subsets, each launched fresh through
///         the instant lane and the bonded (auction -> migrate) lane, then exercised with real
///         swaps: an over-cap probe during the guard, three qualifying buys across blocks (the pot
///         pays on the second), a sell, and a fee collection.
///
///         Per-combo assertions are within-pool markers, not cross-pool comparisons: each enabled
///         block must leave its own footprint (burned tokens, donated wei, a paid pot, a refused
///         over-cap buy) and each DISABLED block must leave none — so an interaction bug in either
///         direction (a block that stops working next to another, or one that fires when off)
///         fails the exact combo that exposes it. `collectPoolFees` runs on all 64 pools, matrixing
///         the instant-band collection fix across every configuration.
contract HookBlockMatrixV5Test is Test {
    /// @dev A stand-in HOOKR address for constructor plumbing; ETH-lane tests never touch it.
    address constant MOCK_HOOKR = address(0xB00C);
    /// @dev A stand-in flywheel burner. Generation-5 ETH-quoted pools configure the 0.3% flywheel
    ///      fee, and the hook refuses that config with no recipient — so v5 tests must wire one.
    address constant FLYWHEEL_RECIPIENT = address(0xF17);

    uint160 constant HOOK_FLAGS = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    uint256 constant SUPPLY = 1_000_000_000e18;
    uint16 constant BPS = 10_000;
    uint64 constant DURATION = 100_000;
    uint64 constant MIG_DELAY = 10;
    uint256 constant AUCTION_SUPPLY_50 = 500_000_000e18;

    uint8 constant B_GUARD = 1 << 0;
    uint8 constant B_SURGE = 1 << 1;
    uint8 constant B_BURN = 1 << 2;
    uint8 constant B_LP = 1 << 3;
    uint8 constant B_POT = 1 << 4;

    uint256 constant BUY_WEI = 0.05 ether;
    uint256 constant OVER_CAP_PROBE_WEI = 2 ether; // over the 10% cap on both routes (0.25 / ~1 ETH)

    IPoolManager manager;
    HookrLaunchpadV5 pad;
    HookrHook hook;
    MockAuctionFactory factory;
    PoolSwapTest swapRouter;

    address creator = address(0xC0FFEE);
    address trader = address(0xB0B);
    /// @dev Cached in setUp: reading it inline as `hook.MIN_SQRT_PRICE_LIMIT()` inside a swap's
    ///      argument list is an external staticcall that CONSUMES a pending vm.prank/expectRevert.
    uint160 minSqrtLimit;

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
        minSqrtLimit = hook.MIN_SQRT_PRICE_LIMIT();

        vm.deal(creator, 100 ether);
        vm.deal(trader, 5000 ether);
    }

    // ------------------------------------------------------------------ the matrix

    function test_allHookBlockCombos_instantRoute() public {
        for (uint8 mask = 0; mask < 32; mask++) {
            uint256 fee = pad.creationFeeWei();
            if (mask & B_LP != 0) {
                // STRUCTURAL: a zero-seed pool has no in-range LP until the first buy, so the
                // LP-donation block would brick the pool on that buy (the hook fails closed on a
                // donation with no recipient liquidity). The instant lane must refuse it — for
                // every combination it appears in.
                vm.prank(creator);
                vm.expectRevert(HookrLaunchpadV5.InstantRejectsLpDonation.selector);
                pad.launchInstant{value: fee}(_args(mask), HookrLaunchpadV5.Quote.Eth, bytes32(0));
                continue;
            }
            vm.prank(creator);
            address token = pad.launchInstant{value: fee}(_args(mask), HookrLaunchpadV5.Quote.Eth, bytes32(0));
            _exercise(token, mask, "instant");
        }
    }

    function test_allHookBlockCombos_bondedRoute() public {
        for (uint8 mask = 0; mask < 32; mask++) {
            uint256 fee = pad.creationFeeWei();
            vm.prank(creator);
            address token = pad.launchAuction{value: fee}(
                _args(mask), HookrLaunchpadV5.Quote.Eth, 1 ether, 5 ether, 5000, bytes32(0)
            );
            MockAuction auction = MockAuction(payable(pad.getLaunch(token).auction));

            uint256 raise = 5 ether;
            vm.deal(address(auction), raise);
            auction.setOutcome(true, (raise << 96) / AUCTION_SUPPLY_50, raise, 0);
            // Absolute roll target from contract state: solc legally CSEs `block.number` across
            // `vm.roll` within one function (it cannot change intra-tx on a real chain), so a
            // relative target computed here would reuse the loop's FIRST read and roll backward.
            vm.roll(uint256(pad.getLaunch(token).auctionEndBlock) + MIG_DELAY + 1);
            pad.migrateAuction(token);

            _exercise(token, mask, "bonded");
        }
    }

    // ------------------------------------------------------------------ shared exercise

    function _exercise(address token, uint8 mask, string memory route) internal {
        PoolKey memory key = _key(token);
        PoolId id = key.toId();
        string memory tag = string.concat(route, " mask ", vm.toString(mask), ": ");

        // Guard block: while the guard is live, an over-cap exact-input buy must be refused. The
        // hook's revert bubbles wrapped by the PoolManager, so match the wrapper selector.
        if (mask & B_GUARD != 0) {
            vm.prank(trader);
            vm.expectPartialRevert(CustomRevert.WrappedError.selector);
            swapRouter.swap{value: OVER_CAP_PROBE_WEI}(
                key,
                SwapParams({
                    zeroForOne: true, amountSpecified: -int256(OVER_CAP_PROBE_WEI), sqrtPriceLimitX96: minSqrtLimit
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                abi.encode(trader)
            );
        }

        // Three qualifying buys in three blocks: the first two inside the guard window (if any),
        // the pot paying on the second, the third after the guard ends.
        _buy(key);
        vm.roll(vm.getBlockNumber() + 1); // cheatcode read: immune to solc's block.number CSE
        _buy(key);
        vm.roll(vm.getBlockNumber() + 12); // past the 10-block guard
        _buy(key);

        uint256 traderTokens = HookrToken(token).balanceOf(trader);
        assertGt(traderTokens, 0, string.concat(tag, "buys delivered tokens"));

        // A sell back into the ETH the buys deposited.
        vm.startPrank(trader);
        HookrToken(token).approve(address(swapRouter), traderTokens / 10);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(traderTokens / 10),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        // Every enabled block left its footprint; every disabled block left none.
        if (mask & B_BURN != 0) {
            assertGt(hook.totalBurnedTokens(id) + hook.burnVaultWei(id), 0, string.concat(tag, "burn block accrued"));
        } else {
            assertEq(hook.totalBurnedTokens(id), 0, string.concat(tag, "no burn when off"));
            assertEq(hook.burnVaultWei(id), 0, string.concat(tag, "no burn vault when off"));
        }
        if (mask & B_LP != 0) {
            assertGt(hook.totalLpDonatedWei(id), 0, string.concat(tag, "lp donation flowed"));
        } else {
            assertEq(hook.totalLpDonatedWei(id), 0, string.concat(tag, "no lp donation when off"));
        }
        if (mask & B_POT != 0) {
            assertGe(hook.potBuyCount(id), 2, string.concat(tag, "pot counted the qualifying buys"));
            assertGt(hook.totalPotPaidWei(id), 0, string.concat(tag, "pot paid on the Nth buy"));
        } else {
            assertEq(hook.potBuyCount(id), 0, string.concat(tag, "no pot count when off"));
            assertEq(hook.totalPotPaidWei(id), 0, string.concat(tag, "no pot payout when off"));
        }

        // Fee collection must work under EVERY block combination on EVERY route — this matrixes
        // the instant-band collection fix (instant pools hold only the band position).
        uint256 protocolBefore = pad.protocolFeesWei();
        pad.collectPoolFees(token);
        assertGt(pad.protocolFeesWei(), protocolBefore, string.concat(tag, "pool fees collected"));
    }

    function _buy(PoolKey memory key) internal {
        vm.prank(trader);
        swapRouter.swap{value: BUY_WEI}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(BUY_WEI),
                sqrtPriceLimitX96: minSqrtLimit // canonical: required on cut-bearing buys
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(trader) // canonical pot recipient; ignored by pot-less configs
        );
    }

    // ------------------------------------------------------------------ combo args

    /// @dev Bit `i` of `mask` enables block `i`. Values mirror the five house blueprints, sized so
    ///      every combination passes `validateHookParams` (cuts sum to 175 <= 1000 bps; base fee
    ///      3000 + snipe tax 200_000 <= 500_000 pips).
    function _params(uint8 mask) internal pure returns (HookParams memory p) {
        bool guard = mask & B_GUARD != 0;
        bool surge = mask & B_SURGE != 0;
        p = HookParams({
            guardBlocks: guard ? 10 : 0,
            maxBuyBps: guard ? 1000 : 0, // 10% of supply at the open price, per block
            snipeTaxPips: guard ? 200_000 : 0, // +20% during the guard
            baseFeePips: 3000,
            maxFeePips: surge ? 30_000 : 0,
            surgeSens: surge ? 5 : 0,
            burnBps: mask & B_BURN != 0 ? 100 : 0, // 1%
            burnTriggerWei: 0,
            lpBps: mask & B_LP != 0 ? 25 : 0, // 0.25%
            potBps: mask & B_POT != 0 ? 50 : 0, // 0.5%
            potEveryNBuys: mask & B_POT != 0 ? 2 : 0,
            potMinBuyWei: mask & B_POT != 0 ? 0.001 ether : 0
        });
    }

    function _args(uint8 mask) internal view returns (HookrLaunchpadV5.LaunchArgs memory a) {
        a.name = "Matrix Coin";
        a.symbol = "MTRX";
        a.tagline = "every block, every route";
        a.logoURI = "";
        a.expectedCreator = creator;
        a.blueprintId = 0;
        a.custom = _params(mask);
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
}
