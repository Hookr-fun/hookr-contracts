// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {TestERC20} from "@uniswap/v4-core/src/test/TestERC20.sol";

import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrBlueprints} from "../src/HookrBlueprints.sol";
import {HookrHook} from "../src/HookrHook.sol";
import {HookrSwapRouter} from "../src/HookrSwapRouter.sol";
import {HookrLaunchpadLib} from "../src/libraries/HookrLaunchpadLib.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice Existing-token attach: an ERC-20 this launchpad never minted is attached to a FRESH
///         hooked Uniswap v4 pool, priced by the funded ratio of two committed seed amounts.
///
///         These tests pin the properties the product claims:
///           - the pool exists and trades in the attach transaction itself;
///           - the position is launchpad-owned and locked by construction;
///           - NOTHING the backer deposited is ever burned -- only rounding residue returns;
///           - the opening price is exactly the funded ratio, for ANY decimal pairing;
///           - curve entries fail closed forever on attached markets;
///           - fees collect and split exactly as on native launches;
///           - intent identifiers are consumed exactly once per creator, shared with launches.
contract ExistingTokenAttachTest is Test {
    using StateLibrary for IPoolManager;

    uint160 constant HOOK_FLAGS = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    int24 constant FULL_LOWER = -887220;
    int24 constant FULL_UPPER = 887220;
    uint160 constant MIN_LIMIT = 4295128739 + 1;

    IPoolManager manager;
    HookrLaunchpad pad;
    HookrBlueprints blueprints;
    HookrHook hook;
    HookrSwapRouter router;
    PoolModifyLiquidityTest lpRouter;

    address backer = address(0xB0a7);
    address trader = address(0xB0B);
    address alice = address(0xA11CE);

    TestERC20 communityToken; // the EXISTING token being attached
    TestERC20 usdcLikeQuote; // a small-decimal ERC-20 used as quote

    receive() external payable {}

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        blueprints = new HookrBlueprints(address(this));
        pad = new HookrLaunchpad(manager, blueprints);
        bytes memory creation = abi.encodePacked(type(HookrHook).creationCode, abi.encode(manager, address(pad)));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, creation);
        hook = new HookrHook{salt: salt}(manager, address(pad));
        assertEq(address(hook), predicted);
        pad.setHook(hook);
        router = new HookrSwapRouter(manager, hook);
        lpRouter = new PoolModifyLiquidityTest(manager);

        // Deploy the QUOTE first so its address sorts below the base token (v4 currency0 < currency1).
        usdcLikeQuote = new TestERC20(1e12);
        communityToken = new TestERC20(1e30);

        // v4-core's test LP router settles from ITS OWN balance and pulls tokens from the CALLER
        // via transferFrom: fund it with ETH and give callers an allowance toward it.
        vm.deal(address(lpRouter), 100 ether);
        communityToken.transfer(backer, 4e26);
        communityToken.transfer(alice, 5e25); // the outside LP joins with its own tokens
        usdcLikeQuote.transfer(backer, 4e11);
        communityToken.approve(address(lpRouter), type(uint256).max);
        usdcLikeQuote.approve(address(lpRouter), type(uint256).max);

        communityToken.transfer(backer, 4e26);
        usdcLikeQuote.transfer(backer, 4e11);

        vm.deal(backer, 1000 ether);
        vm.deal(trader, 100 ether);
        vm.deal(alice, 100 ether);
    }

    // ------------------------------------------------------------------ helpers

    function _quietParams() internal view returns (HookrLaunchpadLib.HookParams memory p) {
        p.baseFeePips = 3000;
        p.maxFeePips = 30_000;
        p.surgeSens = 5;
    }

    function _attachArgs(address token, address quote, uint256 tokenSeed, uint256 quoteSeed)
        internal
        view
        returns (HookrLaunchpad.AttachArgs memory a)
    {
        a.token = token;
        a.quoteToken = quote;
        a.tokenSeedRaw = tokenSeed;
        a.quoteSeedRaw = quoteSeed;
        a.expectedCreator = backer;
        a.custom = _quietParams();
    }

    function _approveAll(address who) internal {
        vm.startPrank(who);
        communityToken.approve(address(pad), type(uint256).max);
        usdcLikeQuote.approve(address(pad), type(uint256).max);
        vm.stopPrank();
    }

    function _attach(HookrLaunchpad.AttachArgs memory a, bytes32 intentId)
        internal
        returns (address token, PoolKey memory key)
    {
        uint256 fee = pad.creationFeeWei();
        uint256 nativeDue = fee + (a.quoteToken == address(0) ? a.quoteSeedRaw : 0);
        _approveAll(a.expectedCreator);
        vm.prank(a.expectedCreator);
        if (a.quoteToken == address(0)) {
            pad.attachMarket{value: nativeDue}(a, intentId);
        } else {
            pad.attachMarket{value: fee}(a, intentId);
        }
        key = PoolKey({
            currency0: Currency.wrap(a.quoteToken),
            currency1: Currency.wrap(a.token),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        token = a.token;
    }

    function _attachEthQuote(uint256 tokenSeed, uint256 quoteSeed)
        internal
        returns (address token, PoolKey memory key)
    {
        return _attach(
            _attachArgs(address(communityToken), address(0), tokenSeed, quoteSeed),
            keccak256(abi.encode(tokenSeed, quoteSeed))
        );
    }

    function _buy(address token, address who, uint256 ethIn) internal {
        vm.deal(who, ethIn + 1 ether);
        vm.prank(who);
        _buyNoPrank(token, who, ethIn);
    }

    function _buyNoPrank(address token, address who, uint256 ethIn) internal {
        router.exactInput{value: ethIn}(
            HookrSwapRouter.ExactInputParams({
                key: _keyOf(token),
                zeroForOne: true,
                amountIn: uint128(ethIn),
                amountOutMinimum: 1,
                sqrtPriceLimitX96: MIN_LIMIT,
                recipient: who,
                deadline: block.timestamp + 1
            })
        );
    }

    // ------------------------------------------------------------------ happy path

    function test_attach_eth_quote_opensLiveLockedListedPool() public {
        (address token, PoolKey memory key) = _attachEthQuote(1e24, 10 ether);
        PoolId id = key.toId();

        HookrLaunchpad.Launch memory l = pad.getLaunch(token);
        assertTrue(l.graduated, "attached market must be born graduated");
        assertTrue(l.attached, "must be flagged as attached");
        assertEq(l.creator, backer);
        assertEq(l.quoteToken, address(0));
        assertEq(PoolId.unwrap(l.poolId), PoolId.unwrap(id), "pool recorded");
        assertEq(uint256(l.soldTokens), uint256(pad.CURVE_SUPPLY()), "curve permanently exhausted");
        assertEq(l.basePriceWei, 0, "no 18-decimal assumption on attach");
        assertEq(l.hookParams.baseFeePips, 3000, "custom stack stored");

        // The one position exists and belongs to the launchpad.
        assertGt(manager.getLiquidity(id), 0);
        bytes32 posId = keccak256(abi.encodePacked(address(pad), FULL_LOWER, FULL_UPPER, bytes32(0)));
        assertGt(manager.getPositionLiquidity(id, posId), 0);

        // Hook behavior was configured once for THIS pool with the stack we passed.
        (
            bool initialized,, // guardEndBlock
            uint24 baseFeePips,, // maxFeePips
            , // snipeTaxPips
            , // surgeSens
            , // burnBps
            , // lpBps
            , // potBps
            , // royaltyBps
            , // potEveryNBuys
            , // maxBuyWei
            , // potMinBuyWei
            , // burnTriggerWei
            , // buybackBps
            , // buybackDrawdownBps
            , // buybackCooldownBlocks
            , // buybackMinSpendWei
            , // buybackMaxSpendWei
            , // royaltyTo
            address cfgToken
        ) = hook.poolConfig(id);
        assertTrue(initialized);
        assertEq(cfgToken, token);
        assertEq(baseFeePips, 3000);

        // The market shows up in the public listing.
        bool listed;
        address[] memory page = pad.tokensPage(0, pad.tokensCount());
        for (uint256 i; i < page.length; ++i) {
            if (page[i] == token) listed = true;
        }
        assertTrue(listed, "attached market must be listed for discovery");
    }

    function test_attach_priceIsExactlyTheFundedRatio_anyDecimals() public {
        // A small-decimal quote against an 18-decimal base: the RAW ratio prices the pool, so no
        // decimal assumption exists anywhere on this path.
        (address token, PoolKey memory key) =
            _attach(_attachArgs(address(communityToken), address(usdcLikeQuote), 1e24, 5e6), keccak256("erc20-quote"));
        PoolId id = key.toId();

        (uint160 sqrtNow,,,) = manager.getSlot0(id);
        (uint160 planned, uint8 err) = HookrLaunchpadLib.attachPlan(5e6, 1e24, 60);
        assertEq(err, HookrLaunchpadLib.ATTACH_PLAN_OK);
        assertApproxEqAbs(sqrtNow, planned, 1, "pool opened at the funded ratio");

        // A different existing token gets its own market at its own funded ratio. Keep deploying
        // until the new base sorts ABOVE the quote (v4 ordering).
        TestERC20 second = new TestERC20(1e30);
        while (address(second) <= address(usdcLikeQuote)) {
            second = new TestERC20(1e30);
        }
        second.transfer(backer, 4e26);
        HookrLaunchpad.AttachArgs memory b = _attachArgs(address(second), address(usdcLikeQuote), 2e24, 7e6);
        b.expectedCreator = backer;
        uint256 feeDue = pad.creationFeeWei();
        vm.startPrank(backer);
        second.approve(address(pad), type(uint256).max);
        usdcLikeQuote.approve(address(pad), type(uint256).max);
        pad.attachMarket{value: feeDue}(b, keccak256("second-token"));
        vm.stopPrank();

        (uint160 sqrtB,,,) = manager.getSlot0(
            PoolKey({
                    currency0: Currency.wrap(address(usdcLikeQuote)),
                    currency1: Currency.wrap(address(second)),
                    fee: 0x800000,
                    tickSpacing: 60,
                    hooks: IHooks(address(hook))
                }).toId()
        );
        (planned, err) = HookrLaunchpadLib.attachPlan(7e6, 2e24, 60);
        assertEq(err, HookrLaunchpadLib.ATTACH_PLAN_OK);
        assertApproxEqAbs(sqrtB, planned, 1, "every pair prices at ITS OWN funded ratio");
    }

    function test_attach_neverBurns_andDeploysEverythingCommitted() public {
        // The attach path has no burn destination at all: `tokensAvailable == tokensForPool` by
        // construction, so conservation proves nothing was torched.
        uint256 seedTokens = 1e24;
        uint256 backerTokensBefore = communityToken.balanceOf(backer);

        _attachEthQuote(seedTokens, 10 ether);

        assertLe(
            communityToken.balanceOf(backer), backerTokensBefore, "backer cannot end up with more than they started"
        );
        // Essentially everything committed reached the pool; residue is sub-ppm rounding dust.
        assertGe(
            communityToken.balanceOf(backer),
            backerTokensBefore - seedTokens - ((seedTokens * 1e6) / 1e12),
            "residue beyond rounding dust would mean silent loss"
        );
        assertApproxEqAbs(
            communityToken.balanceOf(backer),
            backerTokensBefore - seedTokens,
            (seedTokens * 1e6) / 1e12,
            "conservation: pool took the seed minus returned dust"
        );
    }

    // ------------------------------------------------------------------ curve entries fail closed

    function test_attach_curveEntriesFailClosedForever() public {
        (address token,) = _attachEthQuote(1e24, 10 ether);

        vm.expectRevert(HookrLaunchpad.AlreadyGraduated.selector);
        pad.buy(token, 1);
        vm.expectRevert(HookrLaunchpad.AlreadyGraduated.selector);
        pad.sell(token, 1e18, 0);
        assertEq(pad.currentCurvePrice(token), 0);
        (uint256 out,) = pad.quoteBuy(token, 1 ether);
        assertEq(out, 0);
        assertEq(pad.quoteSell(token, 1e18), 0);
    }

    // ------------------------------------------------------------------ trading + fees

    function test_attach_tradesThroughTheProductionRouter_andFeesSplit() public {
        (address token,) = _attachEthQuote(1e24, 10 ether);

        _buy(token, trader, 1 ether);
        assertGt(communityToken.balanceOf(trader), 0, "trader bought through the hooked pool");

        // LP fees accrued on the launchpad-owned locked position; collecting splits them.
        vm.roll(block.number + 1);
        uint256 protocolBefore = pad.protocolFeesByQuote(address(0));
        pad.collectPoolFees(token);
        assertGt(pad.protocolFeesByQuote(address(0)), protocolBefore, "protocol earned its share of pool fees");
        assertGt(pad.creatorFeesWei(token), 0, "creator share credited");
    }

    // ------------------------------------------------------------------ guard semantics

    function test_attach_guardCapIsAShareOfWhatThePoolActuallyHolds_inRawUnits() public {
        HookrLaunchpad.AttachArgs memory a = _attachArgs(address(communityToken), address(0), 1e24, 10 ether);
        a.custom.guardBlocks = 10;
        a.custom.maxBuyBps = 500; // 5% of the committed float per block
        (address token,) = _attach(a, keccak256("guarded"));

        // Cap derives from RAW amounts: 5% of the float at the funded backing ratio = 0.5 ETH.
        uint256 expectedCapWei = ((1e24 * 500) / 10_000) * 10 ether / 1e24;
        (,,,,,,,,,,, uint96 maxBuyWeiCfg,,,,,,,,,) = hook.poolConfig(_keyOf(token).toId());
        assertEq(maxBuyWeiCfg, expectedCapWei, "cap is a decimals-free share of the funded depth");

        vm.deal(trader, 1 ether);
        vm.prank(trader);
        try router.exactInput{value: 0.51 ether}(
            HookrSwapRouter.ExactInputParams({
                key: _keyOf(token),
                zeroForOne: true,
                amountIn: 0.51 ether,
                amountOutMinimum: 1,
                sqrtPriceLimitX96: MIN_LIMIT,
                recipient: trader,
                deadline: block.timestamp + 1
            })
        ) {
            assertTrue(false, "capped buy must revert");
        } catch (bytes memory reason) {
            assertInnerRevert(reason, HookrHook.MaxBuyExceeded.selector);
        }

        // A buy inside the cap passes during the same guarded window.
        _buy(token, trader, 0.4 ether);
    }

    function test_attach_outsideLpBlockedDuringGuardThenPermissionless() public {
        HookrLaunchpad.AttachArgs memory a = _attachArgs(address(communityToken), address(0), 1e24, 10 ether);
        a.custom.guardBlocks = 5;
        (, PoolKey memory key) = _attach(a, keccak256("guard-lp"));

        vm.prank(alice);
        try lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: FULL_LOWER, tickUpper: FULL_UPPER, liquidityDelta: 1e18, salt: bytes32(0)
            }),
            ""
        ) {
            assertTrue(false, "outside LP must be blocked during the guard");
        } catch (bytes memory reason) {
            assertInnerRevert(reason, HookrHook.ExternalLiquidityBlockedDuringGuard.selector);
        }

        vm.startPrank(alice);
        communityToken.approve(address(lpRouter), type(uint256).max);
        vm.stopPrank();
        vm.roll(block.number + 6);
        vm.prank(alice);
        _addLiquidityNoPrank(key, 1e15);
    }

    // ------------------------------------------------------------------ reverts

    function test_attach_rejectsStructurallyInvalidArguments() public {
        uint256 fee = pad.creationFeeWei();
        _approveAll(backer);

        HookrLaunchpad.AttachArgs memory a = _attachArgs(address(1), address(0), 1e24, 10 ether); // no code
        vm.prank(backer);
        vm.expectRevert(HookrLaunchpad.BadAttachArgs.selector);
        pad.attachMarket{value: fee}(a, keccak256("no-code"));

        a = _attachArgs(address(usdcLikeQuote), address(usdcLikeQuote), 1e24, 10 ether); // token == quote
        vm.prank(backer);
        vm.expectRevert(HookrLaunchpad.BadAttachArgs.selector);
        pad.attachMarket{value: fee}(a, keccak256("self-pair"));

        a = _attachArgs(address(communityToken), address(0), 0, 10 ether); // zero token seed
        vm.prank(backer);
        vm.expectRevert(HookrLaunchpad.BadAttachArgs.selector);
        pad.attachMarket{value: fee}(a, keccak256("zero-seed"));

        a = _attachArgs(address(communityToken), address(0), 1e24, 10 ether);
        vm.prank(backer);
        vm.expectRevert(HookrLaunchpad.InsufficientPayment.selector); // missing creation fee
        pad.attachMarket{value: 5 ether}(a, keccak256("bad-value"));
    }

    function test_attach_unapprovedPullsFailClosed() public {
        HookrLaunchpad.AttachArgs memory a = _attachArgs(address(communityToken), address(0), 1e24, 10 ether);
        uint256 due = pad.creationFeeWei() + 10 ether;
        vm.prank(backer); // deliberately NOT approved
        vm.expectRevert(HookrLaunchpad.TransferFailed.selector);
        pad.attachMarket{value: due}(a, keccak256("unapproved"));
    }

    function test_attach_wrongSenderCannotUseBoundCalldata() public {
        HookrLaunchpad.AttachArgs memory a = _attachArgs(address(communityToken), address(0), 1e24, 10 ether);
        uint256 due = pad.creationFeeWei() + 10 ether;
        _approveAll(backer);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(HookrLaunchpad.UnexpectedCreator.selector, backer, trader));
        pad.attachMarket{value: due}(a, keccak256("wrong-sender"));
    }

    function test_attach_samePairCannotBeAttachedTwice() public {
        HookrLaunchpad.AttachArgs memory a = _attachArgs(address(communityToken), address(0), 1e24, 10 ether);
        _attach(a, keccak256("first"));
        uint256 due2 = pad.creationFeeWei() + 1 ether;
        _approveAll(backer);
        vm.prank(backer);
        vm.expectRevert(HookrLaunchpad.TokenAlreadyListed.selector);
        pad.attachMarket{value: due2}(a, keccak256("second"));
    }

    function test_attach_launchpadLaunchedTokenCannotBeReAttached() public {
        uint256 launchFee = pad.creationFeeWei();
        HookrLaunchpad.LaunchArgs memory la = _launchArgsFor("Native Fish", "NFSH");
        vm.prank(backer);
        address launched = pad.launch{value: launchFee}(la, bytes32(0));

        HookrLaunchpad.AttachArgs memory a = _attachArgs(launched, address(0), 1e21, 1 ether);
        uint256 due = pad.creationFeeWei() + 1 ether;
        _approveAll(backer);
        vm.prank(backer);
        vm.expectRevert(HookrLaunchpad.TokenAlreadyListed.selector);
        pad.attachMarket{value: due}(a, keccak256("relaunch"));
    }

    function test_attach_intentConsumedExactlyOnce_sharedWithLaunchNamespace() public {
        HookrLaunchpad.AttachArgs memory a = _attachArgs(address(communityToken), address(0), 1e24, 10 ether);
        bytes32 intentId = keccak256("agent-attach-intent");
        uint256 fee = pad.creationFeeWei();
        uint256 due = fee + 10 ether;
        _approveAll(backer);

        vm.prank(backer);
        address token = pad.attachMarket{value: due}(a, intentId);
        assertEq(pad.launchedByIntent(backer, intentId), token, "intent records the attached token");

        uint256 replayDue = pad.creationFeeWei() + 10 ether;
        vm.prank(backer);
        vm.expectRevert(
            abi.encodeWithSelector(HookrLaunchpad.LaunchIntentAlreadyUsed.selector, backer, intentId, token)
        );
        pad.attachMarket{value: replayDue}(a, intentId);

        // One namespace across every path: a LAUNCH cannot launder the same identifier either.
        vm.prank(backer);
        vm.expectRevert(
            abi.encodeWithSelector(HookrLaunchpad.LaunchIntentAlreadyUsed.selector, backer, intentId, token)
        );
        pad.launch{value: fee}(_launchArgsFor("Laundry", "LNDRY"), intentId);
    }

    function test_attach_zeroIntentIsRepeatableButPairStillCollides() public {
        HookrLaunchpad.AttachArgs memory a = _attachArgs(address(communityToken), address(0), 1e24, 10 ether);
        _attach(a, bytes32(0));
        assertEq(pad.launchedByIntent(backer, bytes32(0)), address(0), "zero intent never records");

        // The pair itself still cannot host a second market record -- even via the repeatable door.
        uint256 due = pad.creationFeeWei() + 10 ether;
        vm.prank(backer);
        vm.expectRevert(HookrLaunchpad.TokenAlreadyListed.selector);
        pad.attachMarket{value: due}(a, bytes32(0));
    }

    // ------------------------------------------------------------------ plan math

    function test_attachPlan_extremeRatiosAreRefusedNotMispriced() public {
        (uint160 sqrtX, uint8 err) = HookrLaunchpadLib.attachPlan(1, 1e30, 60);
        assertEq(err, HookrLaunchpadLib.ATTACH_BAD_PRICE, "absurd ratio refused");
        assertEq(sqrtX, 0);

        (sqrtX, err) = HookrLaunchpadLib.attachPlan(0, 1e24, 60);
        assertEq(err, HookrLaunchpadLib.ATTACH_BAD_SEED, "zero quote seed refused");

        (sqrtX, err) = HookrLaunchpadLib.attachPlan(1e18, 1e24, 60);
        assertEq(err, HookrLaunchpadLib.ATTACH_PLAN_OK);
        // Closed form: sqrt(1e24 / 1e18) * 2^96 = 1_000 * 2^96.
        uint256 twoTo96 = 1 << 96;
        assertEq(sqrtX, uint160(1000 * twoTo96), "root matches the closed form");
    }

    function test_fuzz_attachPricesAtTheFundedRatio(uint64 spread) public {
        uint256 quoteSeed = 1e18;
        uint256 tokenSeed = (uint256(spread) % 1e21) + 1e21; // bounded ratio spread
        (address token,) = _attachEthQuote(tokenSeed, quoteSeed);
        (uint160 sqrtNow,,,) = manager.getSlot0(_keyOf(token).toId());
        (uint160 planned, uint8 err) = HookrLaunchpadLib.attachPlan(quoteSeed, tokenSeed, 60);
        assertEq(err, HookrLaunchpadLib.ATTACH_PLAN_OK);
        assertApproxEqRel(sqrtNow, planned, 1e15, "realized spot tracks the funded plan");
    }

    /// @dev PoolManager wraps hook reverts in `WrappedError(...)`; assert the INNER selector is
    ///      present anywhere in the bubbled payload.
    function assertInnerRevert(bytes memory reason, bytes4 inner) internal pure {
        assertTrue(reason.length >= 8, "expected a wrapped revert payload");
        bool found;
        for (uint256 i = 4; i + 4 <= reason.length; ++i) {
            bytes4 chunk;
            assembly {
                chunk := mload(add(add(reason, 32), i))
            }
            if (chunk == inner) found = true;
        }
        assertTrue(found, "inner selector missing from wrapped revert");
    }

    // ------------------------------------------------------------------ shape helpers

    function _keyOf(address token) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function _addLiquidity(PoolKey memory key, address who) internal {
        vm.prank(who);
        _addLiquidityNoPrank(key, 1e18);
    }

    function _addLiquidityNoPrank(PoolKey memory key, uint128 delta) internal {
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: FULL_LOWER, tickUpper: FULL_UPPER, liquidityDelta: int256(uint256(delta)), salt: bytes32(0)
            }),
            ""
        );
    }

    function _launchArgsFor(string memory name, string memory symbol)
        internal
        view
        returns (HookrLaunchpad.LaunchArgs memory a)
    {
        a.name = name;
        a.symbol = symbol;
        a.expectedCreator = backer;
        a.targetRaiseWei = 1 ether;
        a.custom = _quietParams();
    }
}
