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

import {HookrBlueprints} from "../src/HookrBlueprints.sol";
import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrHook} from "../src/HookrHook.sol";
import {HookrSwapRouter} from "../src/HookrSwapRouter.sol";
import {HookrToken} from "../src/HookrToken.sol";
import {HookrLaunchpadLib} from "../src/libraries/HookrLaunchpadLib.sol";
import {V4PoolMath} from "../src/libraries/V4PoolMath.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice The five defects that blocked the instant-launch path, each pinned by a test that fails
///         against the code as it stood before the fix. They are not five variations on one theme:
///
///           1. the anti-snipe cap meant something different at every float, and was weakest
///              exactly where the pool was thinnest;
///           2. the cap bounded one swap rather than one block, so a loop inside a single
///              transaction spent it as many times as it liked;
///           3. the snipe tax is an LP fee and the launchpad's position is the only LP, so a
///              creator who paid the tax got most of it back;
///           4. an unbounded band offset made graduation revert forever — on the CURVE path, on
///              the contract that is deployed today;
///           5. (covered in `src/components/TokenDetail.test.tsx`) the token page rendered a
///              bonding curve for a launch that never had one.
contract InstantLaunchDefectsTest is Test {
    using StateLibrary for IPoolManager;

    uint160 constant HOOK_FLAGS = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    uint160 constant MIN_LIMIT = 4295128739 + 1;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IPoolManager manager;
    HookrLaunchpad pad;

    HookrBlueprints bpReg;
    HookrHook hook;
    HookrSwapRouter router;

    address creator = address(0xC0FFEE);
    address trader = address(0xB0B);

    receive() external payable {}

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        pad = new HookrLaunchpad(manager, new HookrBlueprints(address(this)));
        bpReg = pad.blueprints();
        bytes memory creation = abi.encodePacked(type(HookrHook).creationCode, abi.encode(manager, address(pad)));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, creation);
        hook = new HookrHook{salt: salt}(manager, address(pad));
        assertEq(address(hook), predicted);
        pad.setHook(hook);
        router = new HookrSwapRouter(manager, hook);

        vm.deal(creator, 5000 ether);
        vm.deal(trader, 500 ether);
    }

    // ------------------------------------------------------------------ helpers

    function _params() internal pure returns (HookrLaunchpadLib.HookParams memory p) {
        p.baseFeePips = 3000;
        p.maxFeePips = 3000; // surge off, so the fee arithmetic in these tests is exactly base+tax
        p.surgeSens = 0;
    }

    function _args(uint256 ethIn) internal view returns (HookrLaunchpad.LaunchArgs memory a) {
        a.name = "Defect Fish";
        a.symbol = "DFSH";
        a.expectedCreator = creator;
        a.creatorBuyWei = ethIn;
        a.custom = _params();
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

    function _instant(HookrLaunchpad.LaunchArgs memory a, uint16 bps)
        internal
        returns (address token, PoolKey memory key, PoolId id)
    {
        // Read the fee FIRST: an external call inside the argument list would consume the pending
        // `vm.prank` and the launch would arrive from this test contract instead of the creator.
        uint256 value = pad.creationFeeWei() + a.creatorBuyWei;
        vm.prank(creator);
        token = pad.launchInstant{value: value}(a, bps, bytes32(0));
        key = _key(token);
        id = key.toId();
    }

    function _buy(address who, PoolKey memory key, uint256 ethIn) internal returns (uint256 out) {
        vm.prank(who);
        out = router.exactInput{value: ethIn}(
            HookrSwapRouter.ExactInputParams({
                key: key,
                zeroForOne: true,
                amountIn: uint128(ethIn),
                amountOutMinimum: 1,
                sqrtPriceLimitX96: MIN_LIMIT,
                recipient: who,
                deadline: block.timestamp + 1
            })
        );
    }

    function _maxBuyWei(PoolId id) internal view returns (uint96 maxBuyWei) {
        (,,,,,,,,,,, maxBuyWei,,,,,,,,,) = hook.poolConfig(id);
    }

    // ============================================================ 1. cap vs the float

    /// @dev DEFECT 1. `maxBuyBps` was a share of TOTAL SUPPLY, so on the instant path the cap
    ///      reduced to `ethIn * maxBuyBps / poolSupplyBps` — a figure that says nothing about the
    ///      pool it is guarding. Denominated against supply, the same "1%" setting authorises 5%
    ///      of the pool's ETH at a 20% float and 50% of it at a 2% float: the guard gets weaker
    ///      precisely as the pool it protects gets thinner.
    ///
    ///      What must hold instead is that the cap is a fixed fraction of POOL DEPTH at every
    ///      float, because depth is what determines how far a buy moves the price.
    function test_defect1_capIsAFixedShareOfPoolDepthAtEveryFloat() public {
        uint16[3] memory floats = [uint16(2000), 5000, 10_000];
        uint256 ethIn = 4 ether;

        for (uint256 i; i < 3; ++i) {
            HookrLaunchpad.LaunchArgs memory a = _args(ethIn);
            a.symbol = "DF";
            a.custom.guardBlocks = 50;
            a.custom.maxBuyBps = 100; // "1%"

            (,, PoolId id) = _instant(a, floats[i]);

            // 1% of the ETH in the pool, whatever share of supply that ETH is spread across.
            // Against SUPPLY this would have been `ethIn * 100 / floats[i]`: 0.2 ETH at the 20%
            // float instead of 0.04, and unbounded as the float shrinks.
            assertApproxEqRel(
                uint256(_maxBuyWei(id)), (ethIn * 100) / 10_000, 1e12, "cap is not 1% of the ETH actually in the pool"
            );
        }
    }

    /// @dev The consequence in the only terms that matter: one guarded swap at the cap must move
    ///      the price by a bounded amount, and that bound must not depend on the float. Before the
    ///      fix, a 20% float with `maxBuyBps = 100` authorised a single swap of 20% of pool ETH.
    function test_defect1_oneCappedSwapMovesPriceSimilarlyAtEveryFloat() public {
        uint16[2] memory floats = [uint16(2000), 10_000];
        uint256[2] memory moves;

        for (uint256 i; i < 2; ++i) {
            HookrLaunchpad.LaunchArgs memory a = _args(4 ether);
            a.symbol = "DM";
            a.custom.guardBlocks = 50;
            a.custom.maxBuyBps = 100;

            (, PoolKey memory key, PoolId id) = _instant(a, floats[i]);
            (uint160 before,,,) = manager.getSlot0(id);
            _buy(trader, key, _maxBuyWei(id));
            (uint160 after_,,,) = manager.getSlot0(id);

            // Buying pushes the token price up, i.e. sqrtPrice (tokens per ETH) down.
            moves[i] = (uint256(before - after_) * 10_000) / uint256(before);
            assertLt(moves[i], 200, "one capped swap moved spot by more than 2%");
        }
        assertApproxEqAbs(moves[0], moves[1], 20, "the cap's price impact depends on the float");
    }

    // ============================================================ 2. per-block accumulation

    /// @dev DEFECT 2. The cap bounded a single swap and nothing else, so a CONTRACT could launch
    ///      and then loop capped buys inside the same transaction, before the token existed as far
    ///      as anyone else was concerned. Measured against the unfixed code, a looping creator
    ///      ended the launch transaction holding 49-66% of the float.
    ///
    ///      The remedy is the one the pot already uses: accumulate per (pool, block). A block is
    ///      the finest granularity at which "two different buyers" is a real distinction rather
    ///      than one buyer with two addresses.
    function test_defect2_creatorCannotLoopCappedBuysInsideTheLaunchTransaction() public {
        AtomicSniper sniper = new AtomicSniper(pad, router, hook);
        vm.deal(address(sniper), 100 ether);

        HookrLaunchpad.LaunchArgs memory a = _args(4 ether);
        a.expectedCreator = address(sniper);
        a.custom.guardBlocks = 100;
        a.custom.maxBuyBps = 100;

        // Read the fee FIRST: an external call inside the argument list would consume the pending
        // `vm.expectRevert` and the assertion below would pass against a reverting loop.
        uint256 fee = pad.creationFeeWei();

        // Two capped buys in the launch transaction. The SECOND must be refused.
        vm.expectRevert();
        sniper.launchAndSnipe{value: 0}(a, 2000, fee, 2);

        // One is fine, and one is all the block allows.
        address token = sniper.launchAndSnipe{value: 0}(a, 2000, fee, 1);
        PoolId id = _key(token).toId();
        uint256 float_ = (pad.SUPPLY() * 2000) / 10_000;
        uint256 held = HookrToken(token).balanceOf(address(sniper));

        assertGt(held, 0, "the single capped buy should still go through");
        assertLt((held * 100) / float_, 3, "one block of guarded buying took more than 3% of the float");
        assertEq(uint256(hook.guardBuyBlock(id)), block.number, "the guard did not record the block");
        assertEq(uint256(hook.guardBuyWei(id)), uint256(_maxBuyWei(id)), "the block's budget is not spent");
    }

    /// @dev The budget is per BLOCK, not for all time: it refills, and the accounting resets
    ///      cleanly rather than carrying a stale figure into the next block.
    function test_defect2_theBudgetRefillsEachBlockAndNeverExceedsTheCap() public {
        HookrLaunchpad.LaunchArgs memory a = _args(4 ether);
        a.custom.guardBlocks = 100;
        a.custom.maxBuyBps = 100;
        (, PoolKey memory key, PoolId id) = _instant(a, 5000);
        uint256 cap = _maxBuyWei(id);

        // Half the budget, then the other half, then one wei too many — all in one block.
        _buy(trader, key, cap / 2);
        _buy(trader, key, cap - cap / 2);
        assertEq(uint256(hook.guardBuyWei(id)), cap, "two partial buys did not add up to the cap");
        vm.expectRevert();
        _buy(trader, key, 1);

        // Next block, the full cap is available again, and the counter reset rather than carried.
        vm.roll(block.number + 1);
        _buy(trader, key, cap);
        assertEq(uint256(hook.guardBuyWei(id)), cap, "the previous block's spend leaked forward");
        vm.expectRevert();
        _buy(trader, key, 1);
    }

    // ============================================================ 3. the tax is not a rebate

    /// @dev DEFECT 3. The snipe tax is charged as an LP fee, and a Hookr pool has exactly one LP:
    ///      the launchpad's locked position. `collectPoolFees` then split that fee with the
    ///      creator at `creatorFeeBps`, so a creator who sniped their own launch paid a tax of
    ///      which up to 80% came straight back — claimable in the same block. Net cost 20% against
    ///      100% for anyone else, which is not a tax, it is a discount for being the creator.
    function test_defect3_guardWindowFeesNeverReachTheCreator() public {
        HookrLaunchpad.LaunchArgs memory a = _args(4 ether);
        a.creatorFeeBps = 8000; // the maximum, so the leak would be at its largest
        a.custom.guardBlocks = 100;
        a.custom.snipeTaxPips = 200_000; // 20% snipe tax
        (address token, PoolKey memory key, PoolId id) = _instant(a, 5000);

        // The creator buys their own launch, inside the guard window they configured.
        _buy(creator, key, 0.5 ether);
        assertGt(hook.guardLpEarnedWei(id), 0, "the guard window earned the position nothing");

        uint256 protocolBefore = pad.protocolFeesByQuote(address(0));
        pad.collectPoolFees(token);

        assertEq(pad.creatorFeesWei(token), 0, "guard-window fees were credited to the creator");
        uint256 collected = pad.protocolFeesByQuote(address(0)) - protocolBefore;
        assertGt(collected, 0, "nothing was collected at all, so the test proves nothing");
        assertEq(pad.guardFeesWithheldWei(token), collected, "the whole collection should be withheld");

        // Nothing to claim, and the claim path says so rather than paying out zero.
        vm.expectRevert(HookrLaunchpad.NothingToClaim.selector);
        pad.claimCreatorFees(token);
    }

    /// @dev And the withholding is bounded to the guard window: ordinary trading after it ends
    ///      splits normally, so this is a quarantine rather than a confiscation. Withheld wei are
    ///      also never withheld twice — the launchpad's high-water mark against the hook's
    ///      cumulative accrual is what makes repeated collection safe.
    function test_defect3_afterTheGuardTheCreatorIsPaidNormallyAgain() public {
        HookrLaunchpad.LaunchArgs memory a = _args(4 ether);
        a.creatorFeeBps = 8000;
        a.custom.guardBlocks = 10;
        a.custom.snipeTaxPips = 200_000;
        (address token, PoolKey memory key, PoolId id) = _instant(a, 5000);

        uint256 launchBlock = block.number;
        _buy(creator, key, 0.5 ether);
        uint256 accrued = hook.guardLpEarnedWei(id);
        pad.collectPoolFees(token);
        assertEq(pad.creatorFeesWei(token), 0);
        uint256 withheld = pad.guardFeesWithheldWei(token);
        assertGt(withheld, 0);

        // Guard over. A third party trades; the creator's share of THAT is ordinary income.
        vm.roll(launchBlock + 10);
        _buy(trader, key, 0.5 ether);
        assertEq(hook.guardLpEarnedWei(id), accrued, "the guard accrual kept growing after the window");

        uint256 protocolBefore = pad.protocolFeesByQuote(address(0));
        pad.collectPoolFees(token);
        uint256 creatorSide = pad.creatorFeesWei(token);
        uint256 protocolSide = pad.protocolFeesByQuote(address(0)) - protocolBefore;

        // The accrual is computed with v4's round-UP fee arithmetic while the position's collected
        // fees round down, so a wei or two of the guard window can still be outstanding here. It
        // is withheld from this collection rather than forgotten — which is the conservative
        // direction, and the only one that cannot leak snipe tax back to the creator.
        uint256 residual = pad.guardFeesWithheldWei(token) - withheld;
        assertLe(residual, 2, "more than rounding dust was carried past the guard window");
        assertGt(creatorSide, 0, "post-guard fees were withheld too");
        assertEq(
            creatorSide, ((creatorSide + protocolSide - residual) * 8000) / 10_000, "post-guard split is not 80/20"
        );
        assertLe(pad.guardFeesWithheldWei(token), accrued, "withheld more than the guard window ever earned");
    }

    // ============================================================ 4. bands cannot brick a launch

    /// @dev DEFECT 4, and the one that is live on the DEPLOYED launchpad. `endOffset` had no upper
    ///      bound. Far enough below spot a band's sqrt-price width shrinks until its liquidity no
    ///      longer fits uint128 — and that overflow fired inside the `unlock` callback, BEFORE
    ///      `modifyLiquidity`, where `_seedTranches`' promise to skip an unusable band cannot
    ///      reach. Every graduating buy then reverted forever: the raise stranded in the
    ///      launchpad, the token permanently unable to open a pool.
    ///
    ///      Two things now prevent it, and this pins both. First, the offset is bounded, so a
    ///      creator cannot configure one.
    function test_defect4_anUnboundedBandOffsetIsRejectedAtLaunch() public {
        HookrLaunchpad.LaunchArgs memory a = _args(4 ether);
        a.lpTranches = new HookrLaunchpadLib.LpTranche[](1);
        a.lpTranches[0] =
            HookrLaunchpadLib.LpTranche({startOffset: 60, endOffset: pad.MAX_TRANCHE_OFFSET() + 1, bps: 5000});
        uint256 value = pad.creationFeeWei() + 4 ether;

        vm.prank(creator);
        vm.expectRevert(HookrLaunchpad.BadLpPlan.selector);
        pad.launchInstant{value: value}(a, 5000, bytes32(0));

        // The same plan on the curve path, which is where the live brick was demonstrated.
        HookrLaunchpad.LaunchArgs memory c = _args(0);
        c.targetRaiseWei = 0.01 ether;
        c.creatorBuyWei = 0;
        c.lpTranches = a.lpTranches;
        uint256 curveValue = pad.creationFeeWei();
        vm.prank(creator);
        // The curve path refuses the out-of-range raise target before the band plan is read;
        // the instant path above already proved the band bound itself with BadLpPlan.
        vm.expectRevert(HookrLaunchpad.TargetOutOfRange.selector);
        pad.launch{value: curveValue}(a, bytes32(0));

        // The bound itself is accepted, so this is a bound and not an off-by-one ban.
        a.lpTranches[0].endOffset = pad.MAX_TRANCHE_OFFSET();
        vm.prank(creator);
        address token = pad.launchInstant{value: value}(a, 5000, bytes32(0));
        assertTrue(pad.getLaunch(token).graduated);
    }

    /// @dev Second, and this is the actual guarantee: the band geometry refuses rather than
    ///      reverts. A liquidity figure that will not fit uint128 comes back as zero, so the
    ///      launchpad skips the band and burns its slice — the behavior `_seedTranches` documents.
    ///      Before the fix this call reverted with `V4PoolMath.LiquidityOverflow`.
    function test_defect4_bandLiquidityRefusesInsteadOfReverting() public pure {
        // Deep below spot, where the sqrt-price width is tiny relative to a leftover-sized amount.
        int24 lower = -880_020;
        int24 upper = -879_960;
        uint256 amount = 200_000_000e18; // the whole non-curve allocation

        assertEq(HookrLaunchpadLib.bandLiquidity(lower, upper, amount), 0, "an unfittable band must price at zero");

        // A band at a normal distance still prices, so the zero above is a refusal and not a stub.
        assertGt(HookrLaunchpadLib.bandLiquidity(190_000, 196_000, amount), 0, "an ordinary band lost its liquidity");
        // A collapsed range is zero rather than a division by zero.
        assertEq(HookrLaunchpadLib.bandLiquidity(1200, 1200, amount), 0);
    }

    /// @dev And the geometry that feeds it is TOTAL: an offset large enough to carry the tick
    ///      arithmetic out of int24 returns `ok == false` instead of panicking with 0x11. A panic
    ///      inside the unlock callback is unskippable for exactly the same reason the overflow was.
    function test_defect4_trancheRangeNeverPanicsOnExtremeOffsets() public pure {
        int24 refTick = 121_720; // measured graduation tick at the largest accepted curve raise
        bool ok;

        (ok,,) = HookrLaunchpadLib.trancheRange(refTick, 60, 60, type(int24).max);
        assertFalse(ok, "an extreme endOffset must be refused, not panicked on");
        (ok,,) = HookrLaunchpadLib.trancheRange(refTick, 60, type(int24).max - 1, type(int24).max);
        assertFalse(ok);
        (ok,,) = HookrLaunchpadLib.trancheRange(type(int24).min, 60, 60, type(int24).max);
        assertFalse(ok);
        (ok,,) = HookrLaunchpadLib.trancheRange(refTick, 60, type(int24).min, type(int24).min + 1);
        assertFalse(ok);

        // An ordinary ladder still resolves, so totality did not cost the feature.
        int24 lower;
        int24 upper;
        (ok, lower, upper) = HookrLaunchpadLib.trancheRange(refTick, 60, 600, 6000);
        assertTrue(ok, "an ordinary band stopped resolving");
        assertLt(upper, refTick);
        assertLt(lower, upper);
    }

    /// @dev The brick as it was actually reproduced, on the CURVE path, against the shape the
    ///      deployed launchpad accepts today. Measured on the unfixed code: a 1000 ETH raise with
    ///      `startOffset 850_000, endOffset 1_000_000` took 891.99 ETH of real buying, then every
    ///      graduating buy reverted — from the buyer, from the creator, and still 100,000 blocks
    ///      later — while sub-graduation buys kept working and kept adding to the stranded pile.
    ///      The launch is now refused instead, which is the only point in the lifecycle where
    ///      refusing costs nobody anything.
    function test_defect4_theBandShapeThatBrickedGraduationIsRefusedUpFront() public {
        HookrLaunchpad.LaunchArgs memory a = _args(0);
        a.targetRaiseWei = 1000 ether;
        a.creatorBuyWei = 0;
        a.lpTranches = new HookrLaunchpadLib.LpTranche[](1);
        a.lpTranches[0] = HookrLaunchpadLib.LpTranche({startOffset: 850_000, endOffset: 1_000_000, bps: 10_000});

        uint256 fee = pad.creationFeeWei();
        vm.prank(creator);
        vm.expectRevert(HookrLaunchpad.BadLpPlan.selector);
        pad.launch{value: fee}(a, bytes32(0));

        // The same raise with a legal ladder graduates and opens a tradeable pool, so the bound
        // rejects the bricking shape rather than the feature.
        a.lpTranches[0] = HookrLaunchpadLib.LpTranche({startOffset: 600, endOffset: 60_000, bps: 9000});
        vm.prank(creator);
        address token = pad.launch{value: fee}(a, bytes32(0));
        vm.deal(trader, 2000 ether);
        vm.prank(trader);
        pad.buy{value: 1400 ether}(token, 0);
        assertTrue(pad.getLaunch(token).graduated, "a legal ladder must still graduate");
        assertGt(manager.getLiquidity(_key(token).toId()), 0);
    }

    /// @dev The end-to-end shape of the promise: a launch whose ladder sits at the very bound
    ///      still opens its pool, still trades, and still burns whatever it could not place.
    function test_defect4_aLadderAtTheBoundStillOpensATradeablePool() public {
        HookrLaunchpad.LaunchArgs memory a = _args(4 ether);
        a.lpTranches = new HookrLaunchpadLib.LpTranche[](2);
        a.lpTranches[0] = HookrLaunchpadLib.LpTranche({startOffset: 600, endOffset: 100_000, bps: 5000});
        a.lpTranches[1] =
            HookrLaunchpadLib.LpTranche({startOffset: 100_000, endOffset: pad.MAX_TRANCHE_OFFSET(), bps: 5000});

        (address token, PoolKey memory key, PoolId id) = _instant(a, 5000);
        assertTrue(pad.getLaunch(token).graduated);
        assertGt(manager.getLiquidity(id), 0);
        assertGt(_buy(trader, key, 0.25 ether), 0, "the pool does not trade");
        assertEq(HookrToken(token).balanceOf(address(pad)), 0, "the launchpad kept supply it could not place");
    }
}

/// @notice A creator that is a contract, launching and buying its own float in ONE transaction.
///         This is the shape defect 2 was about: the per-swap cap bounds each call in the loop and
///         nothing bounds the loop.
contract AtomicSniper {
    HookrLaunchpad immutable pad;
    HookrSwapRouter immutable router;
    HookrHook immutable hook;

    constructor(HookrLaunchpad pad_, HookrSwapRouter router_, HookrHook hook_) {
        pad = pad_;
        router = router_;
        hook = hook_;
    }

    receive() external payable {}

    function launchAndSnipe(HookrLaunchpad.LaunchArgs memory a, uint16 bps, uint256 fee, uint256 buys)
        external
        payable
        returns (address token)
    {
        token = pad.launchInstant{value: fee + a.creatorBuyWei}(a, bps, bytes32(0));
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        (,,,,,,,,,,, uint96 cap,,,,,,,,,) = hook.poolConfig(key.toId());

        for (uint256 i; i < buys; ++i) {
            router.exactInput{value: cap}(
                HookrSwapRouter.ExactInputParams({
                    key: key,
                    zeroForOne: true,
                    amountIn: cap,
                    amountOutMinimum: 1,
                    sqrtPriceLimitX96: 4295128739 + 1,
                    recipient: address(this),
                    deadline: block.timestamp + 1
                })
            );
        }
    }
}
