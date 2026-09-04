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
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {HookrLaunchpadV5} from "../src/HookrLaunchpadV5.sol";
import {HookrHook} from "../src/HookrHook.sol";
import {HookrToken} from "../src/HookrToken.sol";
import {HookParams, FeeRecipient} from "../src/libraries/HookrLaunchTypes.sol";
import {IContinuousClearingAuctionFactory} from "../src/interfaces/IContinuousClearingAuction.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {MockAuctionFactory, MockAuction} from "./mocks/MockCCA.sol";

/// @notice A stand-in HOOKR, etched at the LIVE HOOKR address so the address-ordering property the
///         mining loop guarantees is exercised against production geometry.
contract MockHookr is ERC20 {
    constructor() ERC20("Mock HOOKR", "mHOOKR") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice The HOOKR-quoted generation-5 lanes: launches paired with HOOKR instead of ETH. These
///         pin the whole pairing contract: mined token addresses above HOOKR (HOOKR is always
///         currency0), the fixed 2,500,000 HOOKR instant open, the structural refusal of every
///         native-cut block, NO flywheel fee, 100%-to-creator fee routing in HOOKR, and the bonded
///         lane's HOOKR-denominated raise, migration, and proceeds.
contract HookrQuoteLanesV5Test is Test {
    uint160 constant HOOK_FLAGS = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant HOOKR_ADDR = 0x18E674231A58c239Dc7DaeDcffE15Ec3A24cff5c;
    address constant FLYWHEEL_RECIPIENT = address(0xF17);
    uint256 constant SUPPLY = 1_000_000_000e18;
    uint96 constant HOOKR_OPEN_FDV = 2_500_000e18;
    uint64 constant DURATION = 100_000;
    uint64 constant MIG_DELAY = 10;

    IPoolManager manager;
    HookrLaunchpadV5 pad;
    HookrHook hook;
    MockAuctionFactory factory;
    PoolSwapTest swapRouter;
    MockHookr hookr;
    uint160 minSqrtLimit;

    address creator = address(0xC0FFEE);
    address trader = address(0xB0B);

    receive() external payable {}

    function setUp() public {
        vm.etch(HOOKR_ADDR, address(new MockHookr()).code);
        hookr = MockHookr(HOOKR_ADDR);

        manager = IPoolManager(address(new PoolManager(address(this))));
        factory = new MockAuctionFactory();
        pad = new HookrLaunchpadV5(
            manager,
            IContinuousClearingAuctionFactory(address(factory)),
            DURATION,
            10,
            MIG_DELAY,
            2.5 ether,
            HOOKR_ADDR,
            HOOKR_OPEN_FDV
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
        vm.deal(trader, 100 ether);
        hookr.mint(trader, 100_000_000e18);
    }

    function _guardTwo() internal pure returns (HookParams memory p) {
        p = HookParams({
            guardBlocks: 10,
            maxBuyBps: 1000,
            snipeTaxPips: 200_000,
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

    function _args(HookParams memory stack) internal view returns (HookrLaunchpadV5.LaunchArgs memory a) {
        a.name = "Hookr Paired";
        a.symbol = "HPAIR";
        a.tagline = "quoted in HOOKR";
        a.logoURI = "";
        a.expectedCreator = creator;
        a.blueprintId = 0;
        a.custom = stack;
        a.creatorFeeBps = 0;
        a.feeRecipients = new FeeRecipient[](0);
    }

    function _key(address token) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(HOOKR_ADDR),
            currency1: Currency.wrap(token),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function _launchInstantHookr() internal returns (address token) {
        uint256 fee = pad.creationFeeWei();
        vm.prank(creator);
        token = pad.launchInstant{value: fee}(_args(_guardTwo()), HookrLaunchpadV5.Quote.Hookr, bytes32(0));
    }

    function _buyHookr(PoolKey memory key, uint256 amountIn) internal {
        vm.startPrank(trader);
        hookr.approve(address(swapRouter), amountIn);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: minSqrtLimit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ instant lane

    function test_instantOpensAtFixedHookrFdv_withHookrAsCurrency0() public {
        address token = _launchInstantHookr();
        assertGt(uint160(token), uint160(HOOKR_ADDR), "mined token address sits above HOOKR");

        HookrLaunchpadV5.Launch memory l = pad.getLaunch(token);
        assertEq(uint8(l.quote), uint8(HookrLaunchpadV5.Quote.Hookr), "quote recorded");
        assertEq(uint8(l.status), uint8(HookrLaunchpadV5.LaunchStatus.Live), "live at launch");
        assertEq(l.openFdvWei, HOOKR_OPEN_FDV, "fixed 2.5M HOOKR FDV");
        // price = FDV / supply = 2.5e24 / 1e9 tokens = 2.5e15 HOOKR-wei per whole token.
        assertEq(l.openPriceWei, uint96(uint256(HOOKR_OPEN_FDV) / (SUPPLY / 1e18)), "open price from FDV");
        assertEq(PoolId.unwrap(l.poolId), PoolId.unwrap(_key(token).toId()), "pool keyed on HOOKR currency0");
    }

    function test_hookrBuyWalksTheBand_andPaysNoFlywheelFee() public {
        address token = _launchInstantHookr();
        PoolKey memory key = _key(token);

        uint256 recipientBefore = hook.claimableWei(FLYWHEEL_RECIPIENT);
        _buyHookr(key, 200_000e18); // inside the 250k HOOKR guarded per-block cap

        assertGt(HookrToken(token).balanceOf(trader), 0, "buy delivered token for HOOKR");
        assertEq(hook.claimableWei(FLYWHEEL_RECIPIENT), recipientBefore, "no flywheel fee on a HOOKR pair");
        assertEq(hook.totalFlywheelWei(key.toId()), 0, "no flywheel accrual on a HOOKR pair");
    }

    function test_refusesEveryNativeCutBlock() public {
        uint256 fee = pad.creationFeeWei();
        HookParams memory withBurn = _guardTwo();
        withBurn.burnBps = 100;
        vm.prank(creator);
        vm.expectRevert(HookrLaunchpadV5.HookrPairRejectsNativeCutBlocks.selector);
        pad.launchInstant{value: fee}(_args(withBurn), HookrLaunchpadV5.Quote.Hookr, bytes32(0));

        HookParams memory withPot = _guardTwo();
        withPot.potBps = 50;
        withPot.potEveryNBuys = 2;
        withPot.potMinBuyWei = 0.001 ether;
        vm.prank(creator);
        vm.expectRevert(HookrLaunchpadV5.HookrPairRejectsNativeCutBlocks.selector);
        pad.launchInstant{value: fee}(_args(withPot), HookrLaunchpadV5.Quote.Hookr, bytes32(0));

        HookParams memory withLp = _guardTwo();
        withLp.lpBps = 25;
        vm.prank(creator);
        vm.expectRevert(HookrLaunchpadV5.HookrPairRejectsNativeCutBlocks.selector);
        pad.launchInstant{value: fee}(_args(withLp), HookrLaunchpadV5.Quote.Hookr, bytes32(0));

        // The bonded lane refuses identically — the check sits on the shared create path.
        vm.prank(creator);
        vm.expectRevert(HookrLaunchpadV5.HookrPairRejectsNativeCutBlocks.selector);
        pad.launchAuction{value: fee}(
            _args(withBurn), HookrLaunchpadV5.Quote.Hookr, 600_000e18, 3_000_000e18, 5000, bytes32(0)
        );
    }

    function test_blueprintCannotSmuggleNativeCutsOntoAHookrPair() public {
        // A blueprint carrying a pot block is fine on ETH pairs and refused on HOOKR pairs — the
        // check runs on RESOLVED params.
        HookParams memory potStack = _guardTwo();
        potStack.potBps = 50;
        potStack.potEveryNBuys = 2;
        potStack.potMinBuyWei = 0.001 ether;
        uint32 id = pad.saveBlueprint("Pot Stack", potStack, 0);

        uint256 fee = pad.creationFeeWei();
        HookrLaunchpadV5.LaunchArgs memory a = _args(_guardTwo());
        a.blueprintId = id;
        vm.prank(creator);
        vm.expectRevert(HookrLaunchpadV5.HookrPairRejectsNativeCutBlocks.selector);
        pad.launchInstant{value: fee}(a, HookrLaunchpadV5.Quote.Hookr, bytes32(0));
    }

    function test_collectPoolFeesRoutesEverythingToCreator_inHookr() public {
        address token = _launchInstantHookr();
        PoolKey memory key = _key(token);
        vm.roll(vm.getBlockNumber() + 12); // past the 10-block guard, so a deep fee-bearing buy fits
        _buyHookr(key, 5_000_000e18);

        uint256 protocolBefore = pad.protocolFeesWei();
        pad.collectPoolFees(token);
        assertEq(pad.protocolFeesWei(), protocolBefore, "protocol takes nothing from a HOOKR pair");
        uint256 credited = pad.creatorFeesWei(token);
        assertGt(credited, 0, "creator credited the whole quote-side collection");

        // The claim pays HOOKR, not ETH.
        uint256 creatorHookrBefore = hookr.balanceOf(creator);
        uint256 creatorEthBefore = creator.balance;
        pad.claimCreatorFees(token);
        assertEq(hookr.balanceOf(creator) - creatorHookrBefore, credited, "paid in HOOKR");
        assertEq(creator.balance, creatorEthBefore, "no ETH moved");
    }

    // ------------------------------------------------------------------ bonded lane

    function test_bondedHookrAuction_migratesAndPaysProceedsInHookr() public {
        uint256 fee = pad.creationFeeWei();
        uint16 reserveBps = 2000; // proceeds path
        vm.prank(creator);
        address token = pad.launchAuction{value: fee}(
            _args(_guardTwo()), HookrLaunchpadV5.Quote.Hookr, 600_000e18, 3_000_000e18, reserveBps, bytes32(0)
        );
        assertGt(uint160(token), uint160(HOOKR_ADDR), "bonded token also mined above HOOKR");
        MockAuction auction = MockAuction(payable(pad.getLaunch(token).auction));
        assertEq(auction.currency(), HOOKR_ADDR, "CCA created with the HOOKR currency");

        // A graduated auction that raised 3M HOOKR over the 800M auctioned tokens.
        uint256 raise = 3_000_000e18;
        uint256 auctionSupply = (SUPPLY * 8000) / 10_000;
        hookr.mint(address(auction), raise);
        auction.setOutcome(true, (raise << 96) / auctionSupply, raise, 0);

        vm.roll(uint256(pad.getLaunch(token).auctionEndBlock) + MIG_DELAY + 1);
        pad.migrateAuction(token);

        HookrLaunchpadV5.Launch memory l = pad.getLaunch(token);
        assertEq(uint8(l.status), uint8(HookrLaunchpadV5.LaunchStatus.Live), "live after migration");
        // The pool holds the locked share of the raise IN HOOKR.
        assertGt(hookr.balanceOf(address(manager)), 0, "raise locked into the pool in HOOKR");

        // 20% reserve cannot absorb the raise; ~3/4 of it is the creator's DISCLOSED proceeds,
        // credited and paid in HOOKR.
        uint256 proceeds = pad.creatorProceedsWei(token);
        assertApproxEqRel(proceeds, (raise * 3) / 4, 0.03e18, "~three quarters of the raise");
        uint256 before = hookr.balanceOf(creator);
        pad.claimAuctionProceeds(token);
        assertEq(hookr.balanceOf(creator) - before, proceeds, "proceeds paid in HOOKR");

        // And the migrated pool trades for HOOKR.
        _buyHookr(_key(token), 200_000e18); // inside the migrated pool's guarded cap
        assertGt(HookrToken(token).balanceOf(trader), 0, "migrated HOOKR pool delivers token");
    }

    function test_hookrTermRailsEnforced() public {
        uint256 fee = pad.creationFeeWei();
        HookrLaunchpadV5.LaunchArgs memory a = _args(_guardTwo());
        vm.prank(creator);
        vm.expectRevert(HookrLaunchpadV5.FloorFdvOutOfRange.selector);
        pad.launchAuction{value: fee}(a, HookrLaunchpadV5.Quote.Hookr, 9_999e18, 3_000_000e18, 5000, bytes32(0));
        vm.prank(creator);
        vm.expectRevert(HookrLaunchpadV5.RaiseFloorOutOfRange.selector);
        pad.launchAuction{value: fee}(a, HookrLaunchpadV5.Quote.Hookr, 600_000e18, 1_000_000_001e18, 5000, bytes32(0));
    }

    // ------------------------------------------------------------------ the HOOKR-side matrix

    /// @dev The HOOKR complement of test/HookBlockMatrixV5.t.sol: every combination of the two
    ///      HOOKR-legal blocks (guard, surge) through BOTH routes with real swaps and footprint
    ///      assertions, and every cut-bearing mask refused on both routes. Together the two files
    ///      cover the full quote x block-combination surface.
    function test_hookrMatrix_legalCombosBothRoutes() public {
        for (uint8 mask = 0; mask < 4; mask++) {
            HookParams memory p = _maskParams(mask);

            // Instant route.
            uint256 fee = pad.creationFeeWei();
            vm.prank(creator);
            address iToken = pad.launchInstant{value: fee}(_args(p), HookrLaunchpadV5.Quote.Hookr, bytes32(0));
            _exerciseHookr(iToken, mask);

            // Bonded route.
            fee = pad.creationFeeWei();
            vm.prank(creator);
            address bToken = pad.launchAuction{value: fee}(
                _args(p), HookrLaunchpadV5.Quote.Hookr, 600_000e18, 3_000_000e18, 5000, bytes32(0)
            );
            MockAuction auction = MockAuction(payable(pad.getLaunch(bToken).auction));
            uint256 raise = 3_000_000e18;
            hookr.mint(address(auction), raise);
            auction.setOutcome(true, (raise << 96) / ((SUPPLY * 5000) / 10_000), raise, 0);
            vm.roll(uint256(pad.getLaunch(bToken).auctionEndBlock) + MIG_DELAY + 1);
            pad.migrateAuction(bToken);
            _exerciseHookr(bToken, mask);
        }
    }

    function test_hookrMatrix_everyCutBearingMaskRefusedOnBothRoutes() public {
        // Masks carrying any of burn/lp/pot — all seven non-empty subsets, on both routes.
        for (uint8 cutMask = 1; cutMask < 8; cutMask++) {
            HookParams memory p = _guardTwo();
            if (cutMask & 1 != 0) p.burnBps = 100;
            if (cutMask & 2 != 0) p.lpBps = 25;
            if (cutMask & 4 != 0) {
                p.potBps = 50;
                p.potEveryNBuys = 2;
                p.potMinBuyWei = 0.001 ether;
            }
            uint256 fee = pad.creationFeeWei();
            vm.prank(creator);
            vm.expectRevert(HookrLaunchpadV5.HookrPairRejectsNativeCutBlocks.selector);
            pad.launchInstant{value: fee}(_args(p), HookrLaunchpadV5.Quote.Hookr, bytes32(0));
            vm.prank(creator);
            vm.expectRevert(HookrLaunchpadV5.HookrPairRejectsNativeCutBlocks.selector);
            pad.launchAuction{value: fee}(
                _args(p), HookrLaunchpadV5.Quote.Hookr, 600_000e18, 3_000_000e18, 5000, bytes32(0)
            );
        }
    }

    function _maskParams(uint8 mask) internal pure returns (HookParams memory p) {
        bool guard = mask & 1 != 0;
        bool surge = mask & 2 != 0;
        p = HookParams({
            guardBlocks: guard ? 10 : 0,
            maxBuyBps: guard ? 1000 : 0,
            snipeTaxPips: guard ? 200_000 : 0,
            baseFeePips: 3000,
            maxFeePips: surge ? 30_000 : 0,
            surgeSens: surge ? 5 : 0,
            burnBps: 0,
            burnTriggerWei: 0,
            lpBps: 0,
            potBps: 0,
            potEveryNBuys: 0,
            potMinBuyWei: 0
        });
    }

    function _exerciseHookr(address token, uint8 mask) internal {
        PoolKey memory key = _key(token);
        PoolId id = key.toId();
        string memory tag = string.concat("hookr mask ", vm.toString(mask), ": ");

        // A guarded over-cap probe must be refused, exactly like the ETH matrix.
        if (mask & 1 != 0) {
            vm.startPrank(trader);
            hookr.approve(address(swapRouter), 5_000_000e18);
            vm.expectRevert();
            swapRouter.swap(
                key,
                SwapParams({zeroForOne: true, amountSpecified: -int256(5_000_000e18), sqrtPriceLimitX96: minSqrtLimit}),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
            vm.stopPrank();
        }

        _buyHookr(key, 100_000e18);
        vm.roll(vm.getBlockNumber() + 12); // past any guard
        _buyHookr(key, 100_000e18);
        assertGt(HookrToken(token).balanceOf(trader), 0, string.concat(tag, "buys delivered token"));

        // No native machinery may leave a footprint on a HOOKR pair, whatever the mask.
        assertEq(hook.totalFlywheelWei(id), 0, string.concat(tag, "no flywheel"));
        assertEq(hook.totalBurnedTokens(id), 0, string.concat(tag, "no burn"));
        assertEq(hook.totalLpDonatedWei(id), 0, string.concat(tag, "no lp donation"));
        assertEq(hook.potBuyCount(id), 0, string.concat(tag, "no pot"));

        // And fee collection works, routing 100% to the creator.
        uint256 protocolBefore = pad.protocolFeesWei();
        pad.collectPoolFees(token);
        assertEq(pad.protocolFeesWei(), protocolBefore, string.concat(tag, "protocol took nothing"));
    }

    // ------------------------------------------------------------------ isolation

    function test_ethLaneStillPaysTheFlywheel_besideAHookrPair() public {
        // The two quotes coexist: an ETH launch right after a HOOKR launch still accrues 0.3%.
        _launchInstantHookr();
        uint256 fee = pad.creationFeeWei();
        vm.prank(creator);
        address ethToken = pad.launchInstant{value: fee}(_args(_guardTwo()), HookrLaunchpadV5.Quote.Eth, bytes32(0));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(ethToken),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        uint256 before = hook.claimableWei(FLYWHEEL_RECIPIENT);
        vm.prank(trader);
        swapRouter.swap{value: 0.1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(0.1 ether), sqrtPriceLimitX96: minSqrtLimit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertEq(
            hook.claimableWei(FLYWHEEL_RECIPIENT) - before,
            (0.1 ether * 3000) / 1e6,
            "0.3% of the ETH buy accrued to the flywheel"
        );
    }
}
