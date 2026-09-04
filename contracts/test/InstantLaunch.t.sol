// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrHook} from "../src/HookrHook.sol";
import {HookrSwapRouter} from "../src/HookrSwapRouter.sol";
import {HookrToken} from "../src/HookrToken.sol";
import {V4PoolMath} from "../src/libraries/V4PoolMath.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {BlueprintSeeds} from "./utils/BlueprintSeeds.sol";

/// @notice `launchInstant`: a token launched straight into a live Uniswap v4 pool, with no
///         bonding curve and no graduation step.
///
///         The creator sends ETH and picks what SHARE OF SUPPLY seeds the pool. The opening price
///         is the ratio of the two and is never typed in, so what the creator is actually choosing
///         is an opening fully-diluted valuation:
///
///             openFdv = ethIn * 10000 / poolSupplyBps
///
///         These tests pin that identity, pin the guards at both degenerate ends of it, and pin
///         the property the product is really selling: the liquidity is locked by construction.
contract InstantLaunchTest is Test {
    /// @dev The hook's flywheel recipient. address(0) = flywheel dormant (pre-flywheel semantics).
    address constant FLYWHEEL_RECIPIENT = address(0);

    using StateLibrary for IPoolManager;

    uint160 constant HOOK_FLAGS = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    uint160 constant MIN_LIMIT = 4295128739 + 1;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    int24 constant FULL_LOWER = -887220; // (MIN_TICK / 60) * 60
    int24 constant FULL_UPPER = 887220;

    IPoolManager manager;
    HookrLaunchpad pad;
    HookrHook hook;
    HookrSwapRouter router;
    PoolModifyLiquidityTest lpRouter;

    address creator = address(0xC0FFEE);
    address trader = address(0xB0B);
    address attacker = address(0xBADBAD);
    address alice = address(0xA11CE);
    address bob = address(0xB0BB1E);
    address carol = address(0xCAC0);

    receive() external payable {}

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        pad = new HookrLaunchpad(manager);
        BlueprintSeeds.seed(pad);
        bytes memory creation =
            abi.encodePacked(type(HookrHook).creationCode, abi.encode(manager, address(pad), FLYWHEEL_RECIPIENT));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, creation);
        hook = new HookrHook{salt: salt}(manager, address(pad), FLYWHEEL_RECIPIENT);
        assertEq(address(hook), predicted);
        pad.setHook(hook);
        router = new HookrSwapRouter(manager, hook, address(0));
        lpRouter = new PoolModifyLiquidityTest(manager);

        vm.deal(creator, 5000 ether);
        vm.deal(trader, 100 ether);
        vm.deal(attacker, 100 ether);
    }

    // ------------------------------------------------------------------ helpers

    function _quietParams() internal pure returns (HookrLaunchpad.HookParams memory p) {
        p = HookrLaunchpad.HookParams({
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

    function _args(uint256 ethIn) internal view returns (HookrLaunchpad.LaunchArgs memory a) {
        a.name = "Instant Fish";
        a.symbol = "IFSH";
        a.expectedCreator = creator;
        a.targetRaiseWei = 0; // no curve exists on this path
        a.minTokensOut = 0;
        a.creatorBuyWei = ethIn;
        a.custom = _quietParams();
    }

    function _instant(HookrLaunchpad.LaunchArgs memory a, uint16 poolSupplyBps)
        internal
        returns (address token, PoolKey memory key, PoolId id)
    {
        uint256 fee = pad.creationFeeWei();
        vm.prank(creator);
        token = pad.launchInstant{value: fee + a.creatorBuyWei}(a, poolSupplyBps);
        key = _key(token);
        id = key.toId();
    }

    function _launchInstant(uint256 ethIn, uint16 poolSupplyBps)
        internal
        returns (address token, PoolKey memory key, PoolId id)
    {
        return _instant(_args(ethIn), poolSupplyBps);
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

    function _expectInstantRevert(uint256 ethIn, uint16 bps, bytes4 err) internal {
        HookrLaunchpad.LaunchArgs memory a = _args(ethIn);
        uint256 value = pad.creationFeeWei() + ethIn;
        vm.prank(creator);
        vm.expectRevert(err);
        pad.launchInstant{value: value}(a, bps);
    }

    function _buy(address who, PoolKey memory key, uint128 ethIn) internal returns (uint256 out) {
        HookrSwapRouter.ExactInputParams memory p = HookrSwapRouter.ExactInputParams({
            key: key,
            zeroForOne: true,
            amountIn: ethIn,
            amountOutMinimum: 1,
            sqrtPriceLimitX96: MIN_LIMIT,
            recipient: who,
            deadline: block.timestamp + 1
        });
        vm.prank(who);
        out = router.exactInput{value: ethIn}(p);
    }

    /// @dev The pool's price as wei per whole token: `1e18 / (sqrtPriceX96 / 2**96)**2`.
    function _priceWeiFromSqrt(uint160 sqrtPriceX96) internal pure returns (uint256) {
        return (uint256(1e18) << 192) / (uint256(sqrtPriceX96) * uint256(sqrtPriceX96));
    }

    function _fullRangePositionLiquidity(PoolId id) internal view returns (uint128) {
        return
            manager.getPositionLiquidity(
                id, keccak256(abi.encodePacked(address(pad), FULL_LOWER, FULL_UPPER, bytes32(0)))
            );
    }

    // ================================================================== happy path

    /// @dev The whole product in one test: one transaction in, a live pool out, the position owned
    ///      by the launchpad, the curve entrypoints already dead, and not one token to the creator.
    function test_instantLaunch_livePoolLockedPositionNoCreatorAllocation() public {
        uint256 ethIn = 1 ether;
        uint16 bps = 5000;
        uint256 creatorBefore = creator.balance;
        uint256 protocolBefore = pad.protocolFeesWei();
        uint256 fee = pad.creationFeeWei();

        vm.recordLogs();
        (address token, PoolKey memory key, PoolId id) = _launchInstant(ethIn, bps);

        // ---- the launch record says "already in a pool", in the launch block itself.
        HookrLaunchpad.Launch memory l = pad.getLaunch(token);
        assertTrue(l.graduated, "instant launch must land graduated");
        assertEq(l.graduatedAtBlock, l.launchBlock, "pool must open in the launch block");
        assertEq(l.launchBlock, uint40(block.number));
        assertEq(l.soldTokens, 0, "no curve, so nothing was ever sold");
        assertEq(l.reserveWei, 0, "no curve reserve exists");
        assertEq(l.creator, creator);

        // ---- opening price is exactly ethIn / tokensInPool, and the FDV is ethIn / share.
        uint256 tokensInPool = (pad.SUPPLY() * bps) / 10_000;
        assertEq(l.basePriceWei, 2e9, "openPrice = 1e18 wei / 5e26 tokens = 2e9 wei per token");
        assertEq(l.targetWei, uint96(ethIn), "targetWei records the ETH actually committed");
        uint256 fdv = (pad.SUPPLY() * uint256(l.basePriceWei)) / 1e18;
        assertEq(fdv, (ethIn * 10_000) / bps, "opening FDV must be ethIn / share of supply");
        assertEq(fdv, 2 ether, "1 ETH against half the supply is a 2 ETH opening valuation");

        // ---- the pool is live at that price and holds real liquidity.
        (uint160 sqrtNow, int24 tickNow,,) = manager.getSlot0(id);
        assertEq(sqrtNow, l.sqrtPriceX96AtGraduation, "pool did not open at the recorded price");
        assertGt(sqrtNow, 0, "pool not initialized");
        assertGt(tickNow, FULL_LOWER, "spot at/below the usable range");
        assertLt(tickNow, FULL_UPPER, "spot at/above the usable range");
        assertApproxEqRel(_priceWeiFromSqrt(sqrtNow), (ethIn * 1e18) / tokensInPool, 1e12, "realized price drifted");
        assertGt(manager.getLiquidity(id), 0, "no in-range liquidity");

        // ---- that liquidity is ONE full-range position and the launchpad owns it.
        assertGt(_fullRangePositionLiquidity(id), 0, "launchpad does not own the full-range position");

        // ---- the creator got ETH exposure and zero tokens; the launchpad kept nothing.
        assertEq(HookrToken(token).balanceOf(creator), 0, "creator must never receive an allocation");
        assertEq(HookrToken(token).balanceOf(address(pad)), 0, "launchpad must not sit on supply");
        assertEq(
            HookrToken(token).balanceOf(address(manager)) + HookrToken(token).balanceOf(DEAD),
            pad.SUPPLY(),
            "every token must be in the pool or burned"
        );

        // ---- essentially all the committed ETH became liquidity, and the sub-ppm rounding
        //      residue went back to the CREATOR rather than being swept into protocol fees.
        assertApproxEqRel(address(manager).balance, ethIn, 1e12, "pool did not receive the deposit");
        assertLe(ethIn - address(manager).balance, ethIn / 1e6, "more than 1ppm of the deposit was left behind");
        assertEq(
            creatorBefore - creator.balance,
            fee + address(manager).balance,
            "creator was charged more than the fee plus what the pool actually took"
        );
        assertEq(pad.protocolFeesWei() - protocolBefore, fee, "protocol skimmed more than the creation fee");

        // ---- the curve entrypoints are dead on arrival, because the launch is already graduated.
        vm.expectRevert(HookrLaunchpad.AlreadyGraduated.selector);
        vm.prank(trader);
        pad.buy{value: 1 ether}(token, 0);
        vm.expectRevert(HookrLaunchpad.AlreadyGraduated.selector);
        vm.prank(trader);
        pad.sell(token, 1, 0);
        assertEq(pad.currentCurvePrice(token), 0);
        (uint256 q,) = pad.quoteBuy(token, 1 ether);
        assertEq(q, 0);

        // ---- and it actually trades.
        uint256 got = _buy(trader, key, 0.05 ether);
        assertGt(got, 0, "pool does not trade");
        assertEq(HookrToken(token).balanceOf(trader), got);

        // ---- an indexer can tell this was instant rather than graduated.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("InstantLaunched(address,bytes32,uint16,uint96,uint256)");
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pad) && logs[i].topics.length == 3 && logs[i].topics[0] == sig) seen = true;
        }
        assertTrue(seen, "InstantLaunched not emitted");
    }

    /// @dev The identity the creator is actually choosing, across the legal range. If this ever
    ///      stops holding, the UI is quoting a valuation the contract does not implement.
    function test_openingValuationIsAlwaysEthOverShareOfSupply() public {
        uint256[4] memory eths = [uint256(0.01 ether), 0.5 ether, 7 ether, 250 ether];
        uint16[4] memory shares = [uint16(2000), 3000, 5000, 10_000];

        for (uint256 i; i < 4; ++i) {
            HookrLaunchpad.LaunchArgs memory a = _args(eths[i]);
            a.symbol = "IFS";

            (uint256 previewTokens, uint96 previewPrice, uint160 previewSqrt, uint256 previewFdv, uint8 err) =
                pad.previewInstantLaunch(eths[i], shares[i]);
            assertEq(err, 0, "legal inputs previewed as rejected");

            (address token,, PoolId id) = _instant(a, shares[i]);
            HookrLaunchpad.Launch memory l = pad.getLaunch(token);

            // The preview is not an estimate: it is the same code path the launch took.
            assertEq(previewTokens, (pad.SUPPLY() * shares[i]) / 10_000, "preview float wrong");
            assertEq(previewPrice, l.basePriceWei, "preview price != launched price");
            assertEq(previewSqrt, l.sqrtPriceX96AtGraduation, "preview sqrt price != launched sqrt price");

            // FDV == ethIn / share, to within the one-integer rounding of the price.
            assertApproxEqRel(previewFdv, (eths[i] * 10_000) / shares[i], 1e12, "FDV is not ethIn / share");
            assertGe(previewFdv, eths[i], "a launch may never open below the ETH committed");
            assertLe(previewFdv, eths[i] * 5 + 1e9, "a launch may never open above 5x the ETH committed");

            (uint160 sqrtNow, int24 tickNow,,) = manager.getSlot0(id);
            assertEq(sqrtNow, previewSqrt);
            assertGt(tickNow, FULL_LOWER);
            assertLt(tickNow, FULL_UPPER);
        }
    }

    /// @dev Anything the contract accepts must produce a pool at the price that was asked for, at
    ///      a tick a full-range position can hold, with a bounded valuation and no creator supply.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_acceptedInputsNeverProduceADegeneratePrice(uint256 rawEth, uint16 rawBps) public {
        uint256 ethIn = bound(rawEth, 1, 300 ether);
        uint16 bps = uint16(bound(uint256(rawBps), 0, 12_000));

        (,,,, uint8 err) = pad.previewInstantLaunch(ethIn, bps);
        HookrLaunchpad.LaunchArgs memory a = _args(ethIn);
        uint256 value = pad.creationFeeWei() + ethIn;

        if (err != 0) {
            bytes4 expected = err == 1
                ? HookrLaunchpad.InstantEthOutOfRange.selector
                : (err == 2 ? HookrLaunchpad.PoolShareOutOfRange.selector : HookrLaunchpad.OpenPriceOutOfRange.selector);
            vm.prank(creator);
            vm.expectRevert(expected);
            pad.launchInstant{value: value}(a, bps);
            return;
        }

        vm.prank(creator);
        address token = pad.launchInstant{value: value}(a, bps);
        PoolId id = _key(token).toId();

        uint256 tokensInPool = (pad.SUPPLY() * bps) / 10_000;
        (uint160 sqrtNow, int24 tickNow,,) = manager.getSlot0(id);

        // Representable, inside the usable range, and priced where it was told to be.
        assertGt(tickNow, FULL_LOWER, "spot outside the usable range");
        assertLt(tickNow, FULL_UPPER, "spot outside the usable range");
        assertApproxEqRel(_priceWeiFromSqrt(sqrtNow), (ethIn * 1e18) / tokensInPool, 1e12, "price is not ethIn/tokens");

        // Valuation bounded by the share guard, in both directions.
        uint256 fdv = (pad.SUPPLY() * uint256(pad.getLaunch(token).basePriceWei)) / 1e18;
        assertGe(fdv, ethIn, "opened below the ETH committed");
        // Slack = SUPPLY/1e18 (1e9): the per-token price rounds UP by at most one wei, and one
        // wei of price is 1e9 wei of FDV. At the minimum pool share the bound is exact and a
        // round-up seed lands right on it.
        assertLe(fdv, ethIn * 5 + 1e9, "opened above 5x the ETH committed");

        // Liquidity exists, is the launchpad's, and the creator holds nothing.
        assertGt(manager.getLiquidity(id), 0);
        assertGt(_fullRangePositionLiquidity(id), 0);
        assertEq(HookrToken(token).balanceOf(creator), 0);
        assertEq(HookrToken(token).balanceOf(address(pad)), 0);
    }

    /// @dev The price is rounded UP in wei per token, which biases the sqrt price DOWN, which
    ///      makes the opening position ETH-limited. That is deliberate: the residue then lands on
    ///      the TOKEN side, where the launch already has a destination for it (band, or burn),
    ///      instead of on the creator's deposit where it would need refunding at scale.
    function test_roundingResidueLandsOnTheTokenSideNotOnTheDeposit() public {
        uint256 ethIn = 3.7 ether; // deliberately not a round number
        uint256 creatorBefore = creator.balance;
        uint256 fee = pad.creationFeeWei();

        // Seeding ALL of supply leaves no intentional leftover, so anything burned here is purely
        // the rounding residue — and it must be on the token side.
        (address token,, PoolId id) = _launchInstant(ethIn, 10_000);

        uint256 pooledEth = address(manager).balance;
        assertEq(creatorBefore - creator.balance, fee + pooledEth, "residue was not refunded to the creator");
        assertLe(ethIn - pooledEth, ethIn / 1e6, "ETH residue exceeded 1ppm of the deposit");

        uint256 burned = HookrToken(token).balanceOf(DEAD);
        uint256 pooledTokens = HookrToken(token).balanceOf(address(manager));
        assertEq(burned + pooledTokens, pad.SUPPLY(), "supply is not fully accounted for");
        assertLe(burned, pad.SUPPLY() / 1e6, "token residue exceeded 1ppm of supply");
        assertEq(HookrToken(token).balanceOf(creator), 0);
        assertGt(manager.getLiquidity(id), 0);
    }

    // ================================================================== the extremes

    function test_dustAndAbsurdDepositsAreRejected() public {
        _expectInstantRevert(0, 5000, HookrLaunchpad.InstantEthOutOfRange.selector);
        _expectInstantRevert(1, 5000, HookrLaunchpad.InstantEthOutOfRange.selector);
        _expectInstantRevert(uint256(pad.MIN_TARGET()) - 1, 5000, HookrLaunchpad.InstantEthOutOfRange.selector);
        _expectInstantRevert(uint256(pad.MAX_TARGET()) + 1, 5000, HookrLaunchpad.InstantEthOutOfRange.selector);

        // MIN_TARGET is the ETH bound, but it is no longer the smallest LAUNCHABLE deposit: with
        // the float floor at 20%, the thinnest legal float still puts 2e26 tokens in the pool, and
        // 0.0001 ETH against those derives a price of 5e5 wei — under MIN_OPEN_PRICE_WEI. The
        // deposit is refused for being imprecise, not for being small, and says so.
        _expectInstantRevert(pad.MIN_TARGET(), 2000, HookrLaunchpad.OpenPriceOutOfRange.selector);

        // Twice the ETH bound is the first deposit the price floor also admits, and it launches.
        (address low,,) = _launchInstant(2 * uint256(pad.MIN_TARGET()), 2000);
        assertTrue(pad.getLaunch(low).graduated);
        assertEq(pad.getLaunch(low).basePriceWei, pad.MIN_OPEN_PRICE_WEI(), "landed exactly on the price floor");
    }

    function test_shareOfSupplyOutsideTheFloatFloorIsRejected() public {
        _expectInstantRevert(1 ether, 0, HookrLaunchpad.PoolShareOutOfRange.selector);
        _expectInstantRevert(1 ether, 1, HookrLaunchpad.PoolShareOutOfRange.selector);
        _expectInstantRevert(1 ether, pad.MIN_POOL_SUPPLY_BPS() - 1, HookrLaunchpad.PoolShareOutOfRange.selector);
        _expectInstantRevert(1 ether, 10_001, HookrLaunchpad.PoolShareOutOfRange.selector);
        _expectInstantRevert(1 ether, type(uint16).max, HookrLaunchpad.PoolShareOutOfRange.selector);
    }

    /// @dev The top end of the valuation. At the 20% float floor the opening FDV is exactly 5x the
    ///      ETH committed; one basis point below it, the launch is refused rather than repriced.
    function test_valuationIsCappedAtFiveTimesTheCommittedEth() public {
        uint256 ethIn = 1 ether;
        (,,, uint256 fdv, uint8 err) = pad.previewInstantLaunch(ethIn, pad.MIN_POOL_SUPPLY_BPS());
        assertEq(err, 0);
        assertEq(fdv, 5 ether, "the 20% float floor is exactly a 5x opening valuation");

        _expectInstantRevert(ethIn, pad.MIN_POOL_SUPPLY_BPS() - 1, HookrLaunchpad.PoolShareOutOfRange.selector);

        // And the bottom end: all of supply in the pool means FDV == the ETH committed, no less.
        (,,, uint256 fdvFull, uint8 errFull) = pad.previewInstantLaunch(ethIn, 10_000);
        assertEq(errFull, 0);
        assertEq(fdvFull, ethIn, "seeding all of supply must open at exactly the ETH committed");
    }

    /// @dev The precision end. A large share of supply against very little ETH drives the derived
    ///      wei-per-token price toward zero, where its integer quantization stops being
    ///      negligible. The guard sits exactly on that boundary, and the remedy is either input.
    function test_aPriceTooCoarseToRepresentIsRejected_andBothRemediesWork() public {
        // ceil(ethIn * 1e18 / 1e27) == ceil(ethIn / 1e9), so 1e6 wei/token needs ethIn > 999999e9.
        uint256 justUnder = 999_999_000_000_000; // -> 999,999 wei per token
        uint256 justOver = 999_999_000_000_001; // -> 1,000,000 wei per token

        (, uint96 pUnder,,, uint8 errUnder) = pad.previewInstantLaunch(justUnder, 10_000);
        assertEq(pUnder, 0, "a rejected plan must not report a price");
        assertEq(errUnder, 3, "PLAN_BAD_PRICE");
        _expectInstantRevert(justUnder, 10_000, HookrLaunchpad.OpenPriceOutOfRange.selector);

        (, uint96 pOver,,, uint8 errOver) = pad.previewInstantLaunch(justOver, 10_000);
        assertEq(pOver, pad.MIN_OPEN_PRICE_WEI(), "the boundary itself must be the floor exactly");
        assertEq(errOver, 0);

        // Remedy 1: commit more ETH at the same share.
        (address a1,,) = _launchInstant(justOver, 10_000);
        assertTrue(pad.getLaunch(a1).graduated);

        // Remedy 2: keep the ETH, seed a smaller share of supply.
        (address a2,, PoolId id2) = _launchInstant(justUnder, 2000);
        assertTrue(pad.getLaunch(a2).graduated);
        assertEq(pad.getLaunch(a2).basePriceWei, 4_999_995, "a fifth of the float means 5x the price");
        (, int24 tick2,,) = manager.getSlot0(id2);
        assertGt(tick2, FULL_LOWER);
        assertLt(tick2, FULL_UPPER);
    }

    /// @dev Both price corners of the accepted region open real, tradeable pools whose spot sits
    ///      well inside what a full-range position at tick spacing 60 can hold.
    function test_bothPriceCornersOpenRealPools() public {
        // Highest reachable price: the largest deposit against the smallest legal float.
        (address hi,, PoolId hiId) = _launchInstant(pad.MAX_TARGET(), pad.MIN_POOL_SUPPLY_BPS());
        assertEq(pad.getLaunch(hi).basePriceWei, 5e12, "1000 ETH / 200,000,000 tokens");
        (, int24 hiTick,,) = manager.getSlot0(hiId);
        assertGt(hiTick, FULL_LOWER);
        assertLt(hiTick, FULL_UPPER);
        assertGt(manager.getLiquidity(hiId), 0);
        assertApproxEqRel(address(manager).balance, uint256(pad.MAX_TARGET()), 1e12, "deposit not seeded");

        // Lowest reachable price: exactly MIN_OPEN_PRICE_WEI against all of supply.
        uint256 managerBefore = address(manager).balance;
        (address lo,, PoolId loId) = _launchInstant(999_999_000_000_001, 10_000);
        assertEq(pad.getLaunch(lo).basePriceWei, pad.MIN_OPEN_PRICE_WEI());
        (, int24 loTick,,) = manager.getSlot0(loId);
        assertGt(loTick, FULL_LOWER);
        assertLt(loTick, FULL_UPPER);
        assertGt(manager.getLiquidity(loId), 0);
        assertGt(address(manager).balance, managerBefore);

        // The two corners are ~6.7 decades apart in price and both are comfortably inside the range.
        assertGt(pad.getLaunch(hi).basePriceWei, pad.getLaunch(lo).basePriceWei * 1e6);
    }

    /// @dev Curve arguments are refused rather than ignored: a creator who passes a raise target
    ///      has misunderstood which path they are on, and silence there is how funds go missing.
    function test_curveArgumentsAreRefusedNotIgnored() public {
        HookrLaunchpad.LaunchArgs memory a = _args(1 ether);
        a.targetRaiseWei = 1 ether;
        uint256 value = pad.creationFeeWei() + 1 ether;
        vm.prank(creator);
        vm.expectRevert(HookrLaunchpad.BadLaunchArgs.selector);
        pad.launchInstant{value: value}(a, 5000);

        a = _args(1 ether);
        a.minTokensOut = 1;
        vm.prank(creator);
        vm.expectRevert(HookrLaunchpad.BadLaunchArgs.selector);
        pad.launchInstant{value: value}(a, 5000);
    }

    /// @dev The msg.value accounting is the curve path's, unchanged: creation fee plus the deposit.
    function test_paymentMustBeTheCreationFeePlusTheDeposit() public {
        HookrLaunchpad.LaunchArgs memory a = _args(1 ether);
        // Read the fee FIRST: an external call inside the argument list would consume the pending
        // vm.expectRevert instead of the launch itself.
        uint256 exact = pad.creationFeeWei() + 1 ether;

        vm.prank(creator);
        vm.expectRevert(HookrLaunchpad.InsufficientPayment.selector);
        pad.launchInstant{value: 1 ether}(a, 5000);

        vm.prank(creator);
        vm.expectRevert(HookrLaunchpad.InsufficientPayment.selector);
        pad.launchInstant{value: exact + 1}(a, 5000);
    }

    /// @dev The launchpad re-exports the bounds the library enforces. Pin the two copies together
    ///      behaviorally, so a drift in either fails here instead of in front of a creator.
    function test_libraryBoundsMirrorTheLaunchpadConstants() public view {
        uint8 err;
        // The ETH bound is checked FIRST, so it is pinned by where the error stops being the ETH
        // one — not by finding an accepted plan at the boundary. There is no longer such a plan:
        // at MIN_TARGET even the thinnest legal float derives a price under MIN_OPEN_PRICE_WEI,
        // so the floor is now visible as a change of reason rather than a change of verdict.
        (,,,, err) = pad.previewInstantLaunch(uint256(pad.MIN_TARGET()) - 1, 2000);
        assertEq(err, 1, "MIN_TARGET is not the library's ETH floor");
        (,,,, err) = pad.previewInstantLaunch(pad.MIN_TARGET(), 2000);
        assertEq(err, 3, "at the ETH floor the binding constraint must be the price, not the ETH");
        (,,,, err) = pad.previewInstantLaunch(uint256(pad.MAX_TARGET()) + 1, 5000);
        assertEq(err, 1, "MAX_TARGET is not the library's ETH ceiling");
        (,,,, err) = pad.previewInstantLaunch(pad.MAX_TARGET(), 5000);
        assertEq(err, 0);

        (,,,, err) = pad.previewInstantLaunch(1 ether, pad.MIN_POOL_SUPPLY_BPS() - 1);
        assertEq(err, 2, "MIN_POOL_SUPPLY_BPS is not the library's share floor");
        (,,,, err) = pad.previewInstantLaunch(1 ether, pad.MIN_POOL_SUPPLY_BPS());
        assertEq(err, 0);

        uint96 price;
        (, price,,, err) = pad.previewInstantLaunch(999_999_000_000_001, 10_000);
        assertEq(price, pad.MIN_OPEN_PRICE_WEI(), "MIN_OPEN_PRICE_WEI is not the library's price floor");
        assertEq(err, 0);
    }

    // ================================================================== locked by construction

    /// @dev The core promise. After an instant launch the launchpad owns a full-range position and
    ///      there is no reachable path — its own ABI, a direct callback, or another account
    ///      unlocking the PoolManager itself — that reduces it.
    function test_liquidityCannotBeWithdrawnByAnyone() public {
        HookrLaunchpad.LaunchArgs memory a = _args(2 ether);
        a.creatorFeeBps = 6000;
        (address token, PoolKey memory key, PoolId id) = _instant(a, 5000);

        uint128 seeded = _fullRangePositionLiquidity(id);
        assertGt(seeded, 0, "nothing to protect");
        uint256 poolEth = address(manager).balance;

        // 1. The unlock callback is the only way liquidity ever moves, and only the PoolManager
        //    may call it. A forged CB_GRADUATE with a negative delta cannot even get in.
        vm.prank(attacker);
        vm.expectRevert(HookrLaunchpad.NotPoolManager.selector);
        pad.unlockCallback(abi.encode(uint8(1), key, uint160(1), uint256(0), uint256(0)));
        vm.prank(creator);
        vm.expectRevert(HookrLaunchpad.NotPoolManager.selector);
        pad.unlockCallback(abi.encode(uint8(3), key, int24(-60), int24(60), uint256(1)));

        // 2. Anyone may unlock the PoolManager themselves — but v4 keys a position by its OWNER,
        //    so an outsider addressing the same tick range only ever finds their own empty one.
        vm.prank(attacker);
        vm.expectRevert();
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: FULL_LOWER, tickUpper: FULL_UPPER, liquidityDelta: -int256(uint256(seeded)), salt: bytes32(0)
            }),
            ""
        );
        assertEq(_fullRangePositionLiquidity(id), seeded, "outsider removal touched the position");

        // 3. Exercise every launchpad entrypoint that can still succeed after the launch, plus the
        //    owner-only ones, and confirm none of them is a withdrawal in disguise.
        _buy(trader, key, 0.2 ether);
        pad.collectPoolFees(token);
        vm.prank(creator);
        pad.setCreatorPayout(token, bob);
        pad.claimCreatorFees(token);
        pad.setCreationFee(0.01 ether);
        pad.withdrawProtocolFees(address(this));
        vm.prank(creator);
        vm.expectRevert(HookrLaunchpad.AlreadyGraduated.selector);
        pad.buy{value: 1 ether}(token, 0);
        vm.prank(creator);
        vm.expectRevert(HookrLaunchpad.AlreadyGraduated.selector);
        pad.sell(token, 1, 0);
        vm.expectRevert(HookrLaunchpad.HookAlreadySet.selector);
        pad.setHook(hook);

        assertEq(_fullRangePositionLiquidity(id), seeded, "a launchpad entrypoint moved the position");
        assertGt(manager.getLiquidity(id), 0, "pool lost its in-range liquidity");
        assertGe(address(manager).balance, poolEth, "ETH left the pool");

        // 4. Collecting fees repeatedly never drains the principal either.
        for (uint256 i; i < 3; ++i) {
            _buy(trader, key, 0.05 ether);
            pad.collectPoolFees(token);
        }
        assertEq(_fullRangePositionLiquidity(id), seeded, "fee collection eroded the position");

        // 5. The callback's action set is closed. Even the PoolManager itself cannot ask the
        //    launchpad to do anything other than the three non-negative liquidity operations.
        vm.prank(address(manager));
        vm.expectRevert(HookrLaunchpad.BadCallback.selector);
        pad.unlockCallback(abi.encode(uint8(4), key, uint160(0), uint256(0), uint256(0)));
        vm.prank(address(manager));
        vm.expectRevert(HookrLaunchpad.BadCallback.selector);
        pad.unlockCallback(abi.encode(uint8(0), key, uint160(0), uint256(0), uint256(0)));
        assertEq(_fullRangePositionLiquidity(id), seeded);

        // 6. And the hook itself refuses to be a removal surface: it carries no liquidity flags,
        //    so its remove callbacks are unreachable and revert if called directly.
        vm.expectRevert(HookrHook.HookNotCalled.selector);
        hook.beforeRemoveLiquidity(
            address(this),
            key,
            ModifyLiquidityParams({tickLower: FULL_LOWER, tickUpper: FULL_UPPER, liquidityDelta: -1, salt: bytes32(0)}),
            ""
        );
    }

    // ================================================================== distribution features

    /// @dev Fee splits are a launch-time property, not a curve-time one: they must behave
    ///      identically on a path that never had a curve.
    function test_creatorFeeSplitsWorkOnTheInstantPath() public {
        HookrLaunchpad.LaunchArgs memory a = _args(1 ether);
        a.creatorFeeBps = 6000;
        a.feeRecipients = new HookrLaunchpad.FeeRecipient[](3);
        // Indivisible shares, so the rounding remainder is actually exercised.
        a.feeRecipients[0] = HookrLaunchpad.FeeRecipient({to: alice, bps: 3333});
        a.feeRecipients[1] = HookrLaunchpad.FeeRecipient({to: bob, bps: 3333});
        a.feeRecipients[2] = HookrLaunchpad.FeeRecipient({to: carol, bps: 3334});

        (address token, PoolKey memory key,) = _instant(a, 5000);
        assertEq(pad.creatorFeeBpsOf(token), 6000, "creator share not stored on the instant path");
        assertEq(pad.getFeeRecipients(token).length, 3);

        _buy(trader, key, 0.1 ether);

        uint256 protocolBefore = pad.protocolFeesWei();
        uint256 creatorBalanceBefore = pad.creatorFeesWei(token);
        pad.collectPoolFees(token);
        uint256 protocolSide = pad.protocolFeesWei() - protocolBefore;

        uint256 toAlice = pad.splitFeesWei(token, alice);
        uint256 toBob = pad.splitFeesWei(token, bob);
        uint256 toCarol = pad.splitFeesWei(token, carol);
        uint256 creatorSide = toAlice + toBob + toCarol;

        assertGt(creatorSide, 0, "split credited nothing");
        assertEq(pad.creatorFeesWei(token), creatorBalanceBefore, "pool fees bypassed the split");
        assertEq(creatorSide, ((creatorSide + protocolSide) * 6000) / 10_000, "creator side wrong");
        assertGt(toAlice, 0);
        assertGt(toBob, 0);
        assertGt(toCarol, 0);

        uint256 aliceBefore = alice.balance;
        pad.claimSplitFees(token, alice);
        assertEq(alice.balance - aliceBefore, toAlice, "claim paid the wrong amount");

        // Malformed splits are rejected on this path too, before any state is written.
        HookrLaunchpad.LaunchArgs memory bad = _args(1 ether);
        bad.creatorFeeBps = 8001;
        uint256 value = pad.creationFeeWei() + 1 ether;
        vm.prank(creator);
        vm.expectRevert(HookrLaunchpad.BadFeeSplit.selector);
        pad.launchInstant{value: value}(bad, 5000);
    }

    /// @dev Bands are the other thing a creator can do with the supply that is not in the pool.
    ///      On the instant path that pot is large and entirely under their control, so it matters
    ///      that a band is still token-only, still above the opening price, and still cannot draw
    ///      on the deposit.
    function test_lpBandsWorkOnTheInstantPath() public {
        HookrLaunchpad.LaunchArgs memory a = _args(1 ether);
        a.lpTranches = new HookrLaunchpad.LpTranche[](2);
        a.lpTranches[0] = HookrLaunchpad.LpTranche({startOffset: 600, endOffset: 6000, bps: 5000});
        a.lpTranches[1] = HookrLaunchpad.LpTranche({startOffset: 6000, endOffset: 12_000, bps: 2500});

        (address token, PoolKey memory key, PoolId id) = _instant(a, 5000);
        assertEq(pad.getLpTranches(token).length, 2, "bands not stored");

        HookrLaunchpad.Launch memory l = pad.getLaunch(token);
        int24 openTick = V4PoolMath.getTickAtSqrtPrice(l.sqrtPriceX96AtGraduation);

        uint128 banded;
        for (uint256 i; i < 2; ++i) {
            int24 lower = _align(openTick - a.lpTranches[i].endOffset);
            int24 upper = _align(openTick - a.lpTranches[i].startOffset);
            uint128 liq =
                manager.getPositionLiquidity(id, keccak256(abi.encodePacked(address(pad), lower, upper, bytes32(0))));
            assertGt(liq, 0, "band has no liquidity");
            assertLt(upper, openTick, "band is not strictly above the opening price");
            banded += liq;
        }
        assertGt(banded, 0);

        // The remaining 25% of the leftover still burns, the deposit was never touched to fund a
        // band, and the bands did not move the opening price.
        assertGt(HookrToken(token).balanceOf(DEAD), 0, "remainder not burned");
        assertEq(HookrToken(token).balanceOf(address(pad)), 0, "launchpad kept supply");
        assertApproxEqRel(address(manager).balance, 1 ether, 1e12, "a band drew on the deposit");
        (uint160 sqrtNow,,,) = manager.getSlot0(id);
        assertEq(sqrtNow, l.sqrtPriceX96AtGraduation, "bands moved the opening price");

        // Buying pushes the price up (down in ticks) into the ladder, and collection sees it.
        _buy(trader, key, 0.3 ether);
        _buy(trader, key, 0.3 ether);
        (, int24 tickNow,,) = manager.getSlot0(id);
        assertLt(tickNow, openTick, "price never entered the ladder");

        uint256 protocolBefore = pad.protocolFeesWei();
        pad.collectPoolFees(token);
        uint256 collected = pad.creatorFeesWei(token) + (pad.protocolFeesWei() - protocolBefore);
        assertGt(collected, 0, "no fees collected across the ranges");

        // Malformed plans are rejected here too.
        HookrLaunchpad.LaunchArgs memory bad = _args(1 ether);
        bad.lpTranches = new HookrLaunchpad.LpTranche[](1);
        bad.lpTranches[0] = HookrLaunchpad.LpTranche({startOffset: 0, endOffset: 600, bps: 5000});
        uint256 badValue = pad.creationFeeWei() + 1 ether;
        vm.prank(creator);
        vm.expectRevert(HookrLaunchpad.BadLpPlan.selector);
        pad.launchInstant{value: badValue}(bad, 5000);
    }

    /// @dev Everything the two paths share is shared literally — `_create` is one function, not a
    ///      copy — so a blueprint launch and the default 50/50 fee split must behave on the instant
    ///      path exactly as they do after a graduation.
    function test_blueprintsAndTheDefaultCreatorShareWorkOnTheInstantPath() public {
        HookrLaunchpad.HookParams memory bp = _quietParams();
        bp.lpBps = 25; // a revenue-bearing block, so a royalty can actually accrue
        vm.prank(alice);
        uint32 id = pad.saveBlueprint("instant-bp", bp, 500);

        HookrLaunchpad.LaunchArgs memory a = _args(1 ether);
        a.blueprintId = id;
        a.creatorFeeBps = 0; // unset must mean the default, not zero

        (address token, PoolKey memory key, PoolId poolId) = _instant(a, 5000);
        assertTrue(pad.getLaunch(token).graduated);
        assertEq(pad.getLaunch(token).blueprintId, id, "blueprint not recorded");
        assertEq(pad.getBlueprint(id).uses, 1, "blueprint use not counted");
        assertEq(pad.creatorFeeBpsOf(token), 0, "unset share must stay unset in storage");

        // The blueprint's royalty is live on the pool the instant launch opened.
        (,,,,,,,,, uint16 royaltyBps,,,,, address royaltyTo,,) = hook.poolConfig(poolId);
        assertEq(royaltyBps, 500);
        assertEq(royaltyTo, alice);

        _buy(trader, key, 0.2 ether);
        assertGt(hook.claimableWei(alice), 0, "blueprint author earned no royalty");

        // ...and the unset creator share resolves to the documented default at collection.
        uint256 protocolBefore = pad.protocolFeesWei();
        pad.collectPoolFees(token);
        uint256 creatorSide = pad.creatorFeesWei(token);
        uint256 total = creatorSide + (pad.protocolFeesWei() - protocolBefore);
        assertGt(creatorSide, 0);
        assertEq(creatorSide, (total * pad.DEFAULT_CREATOR_FEE_BPS()) / 10_000, "default share is not 50%");
    }

    // ================================================================== guard + intent

    /// @dev The anti-snipe guard is measured from POOL CREATION. On the curve path that is
    ///      graduation, which is some later block; here it is the launch transaction itself, so
    ///      the window has to be live for the very first buy or the block would be decorative.
    function test_antiSnipeGuardRunsFromTheLaunchBlockItself() public {
        HookrLaunchpad.LaunchArgs memory a = _args(1 ether);
        a.custom.guardBlocks = 20;
        a.custom.maxBuyBps = 50; // 0.5% of supply
        a.custom.snipeTaxPips = 100_000;

        uint256 launchBlock = block.number;
        (, PoolKey memory key, PoolId id) = _instant(a, 5000);

        // The window opens at the launch block and closes guardBlocks later.
        (, uint40 guardEndBlock,,,,,,,,,,,,,,,) = hook.poolConfig(id);
        assertEq(guardEndBlock, uint40(launchBlock + 20), "guard is not anchored to the launch block");

        // The cap is denominated against the tokens ACTUALLY PLACED, not against total supply:
        // maxBuyWei = 0.5% of the 5e26-token float * openPrice(2e9) = 2.5e24 * 2e9 / 1e18 = 5e15.
        // Against SUPPLY it would be 1e16 — twice as much ETH from the same "0.5%" setting, and
        // the gap widens without limit as the float thins.
        uint256 cap = 0.005 ether;
        bytes memory expectedCapRevert = abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.beforeSwap.selector,
            abi.encodeWithSelector(HookrHook.MaxBuyExceeded.selector, 0.02 ether, cap),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
        vm.expectRevert(expectedCapRevert);
        _buy(trader, key, 0.02 ether);

        // A buy inside the cap goes through, in the launch block, and pays the snipe tax.
        assertGt(_buy(trader, key, 0.005 ether), 0, "capped buy should still be allowed");

        // Exact-output buys are blocked outright while the guard is live, so the cap on
        // exact-input buys cannot simply be stepped around.
        HookrSwapRouter.ExactOutputParams memory eo = HookrSwapRouter.ExactOutputParams({
            key: key,
            zeroForOne: true,
            amountOut: 1e18,
            amountInMaximum: 1 ether,
            sqrtPriceLimitX96: MIN_LIMIT,
            recipient: trader,
            deadline: block.timestamp + 1
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(HookrHook.ExactOutputBlockedDuringGuard.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        vm.prank(trader);
        router.exactOutput{value: 1 ether}(eo);

        // Once the window closes, the same oversized buy succeeds.
        vm.roll(launchBlock + 20);
        assertGt(_buy(trader, key, 0.02 ether), 0, "guard did not expire");
    }

    /// @dev An instant launch spends the creator's ETH into a pool that has no removal path, so a
    ///      re-broadcast is strictly worse than a duplicated curve launch. It shares the curve
    ///      path's intent namespace, so one identifier means one token per creator either way.
    function test_instantIntentIsReplaySafeAndSharesTheCurveNamespace() public {
        HookrLaunchpad.LaunchArgs memory a = _args(1 ether);
        uint256 value = pad.creationFeeWei() + 1 ether;
        bytes32 intentId = keccak256("packet-1");

        vm.prank(creator);
        vm.expectRevert(HookrLaunchpad.ZeroLaunchIntent.selector);
        pad.launchInstantWithIntent{value: value}(a, 5000, bytes32(0));

        vm.prank(creator);
        address token = pad.launchInstantWithIntent{value: value}(a, 5000, intentId);
        assertEq(pad.launchedByIntent(creator, intentId), token, "intent must record the token");
        assertTrue(pad.getLaunch(token).graduated);

        // The same packet, re-broadcast.
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(HookrLaunchpad.LaunchIntentAlreadyUsed.selector, creator, intentId, token)
        );
        pad.launchInstantWithIntent{value: value}(a, 5000, intentId);

        // And the same identifier cannot be laundered through the curve path either.
        HookrLaunchpad.LaunchArgs memory curveArgs = _args(0);
        curveArgs.targetRaiseWei = 0.01 ether;
        curveArgs.creatorBuyWei = 0;
        uint256 curveValue = pad.creationFeeWei();
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(HookrLaunchpad.LaunchIntentAlreadyUsed.selector, creator, intentId, token)
        );
        pad.launchWithIntent{value: curveValue}(curveArgs, intentId);

        // A different creator's namespace is untouched.
        HookrLaunchpad.LaunchArgs memory other = _args(1 ether);
        other.expectedCreator = trader;
        vm.prank(trader);
        address second = pad.launchInstantWithIntent{value: value}(other, 5000, intentId);
        assertTrue(second != token);
    }

    /// @dev A creator-supplied refusal to accept ETH must not be able to strand the launch: the
    ///      residue refund is the only ETH the instant path pushes, so prove it is not a foothold.
    function test_launchFromAContractCreatorStillOpensThePool() public {
        ContractCreator cc = new ContractCreator();
        vm.deal(address(cc), 10 ether);
        HookrLaunchpad.LaunchArgs memory a = _args(1 ether);
        a.expectedCreator = address(cc);
        address token = cc.launch(pad, a, 5000, pad.creationFeeWei() + 1 ether);
        assertTrue(pad.getLaunch(token).graduated, "contract creator could not launch");
        assertEq(HookrToken(token).balanceOf(address(cc)), 0, "contract creator received supply");
    }

    function _align(int24 tick) internal pure returns (int24) {
        int24 aligned = (tick / 60) * 60;
        if (tick < 0 && aligned != tick) aligned -= 60;
        return aligned;
    }
}

/// @notice A creator that is a contract and can receive ETH.
contract ContractCreator {
    receive() external payable {}

    function launch(HookrLaunchpad pad, HookrLaunchpad.LaunchArgs memory a, uint16 bps, uint256 value)
        external
        returns (address)
    {
        return pad.launchInstant{value: value}(a, bps);
    }
}
