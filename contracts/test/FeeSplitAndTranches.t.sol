// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {HookrBlueprints} from "../src/HookrBlueprints.sol";
import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrLaunchpadLib} from "../src/libraries/HookrLaunchpadLib.sol";
import {HookrHook} from "../src/HookrHook.sol";
import {HookrSwapRouter} from "../src/HookrSwapRouter.sol";
import {HookrToken} from "../src/HookrToken.sol";
import {V4PoolMath} from "../src/libraries/V4PoolMath.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice Creator fee splits and tranched LP distribution.
///
/// Two independent knobs a creator sets at launch:
///  - what share of collected pool fees is theirs, and how that share is divided; and
///  - whether the pool tokens the full-range position could not absorb are burned (the default)
///    or placed as token-only bands above the graduation price.
contract FeeSplitAndTranchesTest is Test {
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
    address alice = address(0xA11CE);
    address bob = address(0xB0BB1E);

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
        vm.deal(creator, 100 ether);
        vm.deal(trader, 100 ether);
    }

    function _baseArgs() internal view returns (HookrLaunchpad.LaunchArgs memory a) {
        a.name = "Split Test";
        a.symbol = "SPLIT";
        a.expectedCreator = creator;
        a.targetRaiseWei = 0.01 ether;
        a.custom = HookrLaunchpadLib.HookParams({
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
            potMinBuyWei: 0,
            buybackBps: 0,
            buybackDrawdownBps: 0,
            buybackCooldownBlocks: 0,
            buybackMinSpendWei: 0,
            buybackMaxSpendWei: 0
        });
    }

    function _launchAndGraduate(HookrLaunchpad.LaunchArgs memory a)
        internal
        returns (address token, PoolKey memory key, PoolId id)
    {
        uint256 fee = pad.creationFeeWei();
        vm.prank(creator);
        token = pad.launch{value: fee}(a, bytes32(0));
        vm.prank(creator);
        pad.buy{value: 0.02 ether}(token, 0);
        assertTrue(pad.getLaunch(token).graduated, "did not graduate");

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        id = key.toId();
    }

    /// Trades both ways so the pool accrues LP fees for the collector to split.
    function _churn(PoolKey memory key) internal {
        HookrSwapRouter.ExactInputParams memory p = HookrSwapRouter.ExactInputParams({
            key: key,
            zeroForOne: true,
            amountIn: 0.01 ether,
            amountOutMinimum: 1,
            sqrtPriceLimitX96: MIN_LIMIT,
            recipient: trader,
            deadline: block.timestamp + 1
        });
        vm.prank(trader);
        router.exactInput{value: 0.01 ether}(p);
    }

    // ------------------------------------------------------------------ fee splits

    function test_defaultSplitIsUnchangedFiftyFifty() public {
        HookrLaunchpad.LaunchArgs memory a = _baseArgs();
        (address token, PoolKey memory key,) = _launchAndGraduate(a);
        _churn(key);

        uint256 protocolBefore = pad.protocolFeesByQuote(address(0));
        uint256 creatorBefore = pad.creatorFeesWei(token);
        pad.collectPoolFees(token);
        uint256 creatorSide = pad.creatorFeesWei(token) - creatorBefore;
        uint256 protocolSide = pad.protocolFeesByQuote(address(0)) - protocolBefore;

        assertGt(creatorSide, 0, "no creator fees accrued");
        // Halves, with the odd wei going to the protocol exactly as before this feature.
        assertEq(creatorSide, (creatorSide + protocolSide) / 2, "default split moved");
        assertEq(pad.creatorFeeBpsOf(token), 0, "default should stay unset");
    }

    function test_customCreatorShareIsHonoured() public {
        HookrLaunchpad.LaunchArgs memory a = _baseArgs();
        a.creatorFeeBps = 8000; // the cap
        (address token, PoolKey memory key,) = _launchAndGraduate(a);
        _churn(key);

        uint256 protocolBefore = pad.protocolFeesByQuote(address(0));
        uint256 creatorBefore = pad.creatorFeesWei(token);
        pad.collectPoolFees(token);
        uint256 creatorSide = pad.creatorFeesWei(token) - creatorBefore;
        uint256 total = creatorSide + (pad.protocolFeesByQuote(address(0)) - protocolBefore);

        assertEq(creatorSide, (total * 8000) / 10_000, "creator share wrong");
    }

    function test_splitCreditsEveryRecipientAndConservesTheWholeSide() public {
        HookrLaunchpad.LaunchArgs memory a = _baseArgs();
        a.creatorFeeBps = 6000;
        a.feeRecipients = new HookrLaunchpadLib.FeeRecipient[](3);
        // Deliberately indivisible shares so the rounding remainder is exercised.
        a.feeRecipients[0] = HookrLaunchpadLib.FeeRecipient({to: alice, bps: 3333});
        a.feeRecipients[1] = HookrLaunchpadLib.FeeRecipient({to: bob, bps: 3333});
        a.feeRecipients[2] = HookrLaunchpadLib.FeeRecipient({to: creator, bps: 3334});

        (address token, PoolKey memory key,) = _launchAndGraduate(a);
        _churn(key);

        uint256 protocolBefore = pad.protocolFeesByQuote(address(0));
        uint256 creatorBalanceBefore = pad.creatorFeesWei(token);
        pad.collectPoolFees(token);
        uint256 protocolSide = pad.protocolFeesByQuote(address(0)) - protocolBefore;

        uint256 toAlice = pad.splitFeesWei(token, alice);
        uint256 toBob = pad.splitFeesWei(token, bob);
        uint256 toCreator = pad.splitFeesWei(token, creator);
        uint256 creatorSide = toAlice + toBob + toCreator;

        assertGt(creatorSide, 0, "split credited nothing");
        // With recipients configured, pool fees must not touch the single-balance path (the
        // pre-graduation curve fee already sits there and must be left exactly as it was).
        assertEq(pad.creatorFeesWei(token), creatorBalanceBefore, "pool fees bypassed the split");
        // Not one wei may be stranded by integer division.
        assertEq(creatorSide, ((creatorSide + protocolSide) * 6000) / 10_000, "creator side wrong");
        assertGt(toAlice, 0);
        assertGt(toBob, 0);

        uint256 aliceBefore = alice.balance;
        pad.claimSplitFees(token, alice);
        assertEq(alice.balance - aliceBefore, toAlice, "claim paid the wrong amount");
        assertEq(pad.splitFeesWei(token, alice), 0, "balance not cleared");
        vm.expectRevert(HookrLaunchpad.NothingToClaim.selector);
        pad.claimSplitFees(token, alice);
    }

    function test_rejectsMalformedSplits() public {
        HookrLaunchpad.LaunchArgs memory a = _baseArgs();
        uint256 fee = pad.creationFeeWei();

        a.creatorFeeBps = 8001; // over the cap
        vm.prank(creator);
        vm.expectRevert(HookrLaunchpad.BadFeeSplit.selector);
        pad.launch{value: fee}(a, bytes32(0));

        a.creatorFeeBps = 5000;
        a.feeRecipients = new HookrLaunchpadLib.FeeRecipient[](2);
        a.feeRecipients[0] = HookrLaunchpadLib.FeeRecipient({to: alice, bps: 5000});
        a.feeRecipients[1] = HookrLaunchpadLib.FeeRecipient({to: bob, bps: 4000}); // sums to 9000
        vm.prank(creator);
        vm.expectRevert(HookrLaunchpad.BadFeeSplit.selector);
        pad.launch{value: fee}(a, bytes32(0));

        a.feeRecipients[1] = HookrLaunchpadLib.FeeRecipient({to: alice, bps: 5000}); // duplicate
        vm.prank(creator);
        vm.expectRevert(HookrLaunchpad.BadFeeSplit.selector);
        pad.launch{value: fee}(a, bytes32(0));

        a.feeRecipients[1] = HookrLaunchpadLib.FeeRecipient({to: address(0), bps: 5000});
        vm.prank(creator);
        vm.expectRevert(HookrLaunchpad.BadFeeSplit.selector);
        pad.launch{value: fee}(a, bytes32(0));
    }

    // ------------------------------------------------------------------ LP tranches

    function test_defaultBurnsLeftoverExactlyAsBefore() public {
        HookrLaunchpad.LaunchArgs memory a = _baseArgs();
        (address token,,) = _launchAndGraduate(a);
        // No bands configured: the leftover is burned, so the dead address holds it.
        assertEq(pad.getLpTranches(token).length, 0, "unexpected bands");
        assertGt(HookrToken(token).balanceOf(DEAD), 0, "leftover was not burned");
    }

    function test_tranchesSeedTokenOnlyBandsAboveSpotAndBurnTheRemainder() public {
        HookrLaunchpad.LaunchArgs memory a = _baseArgs();
        a.lpTranches = new HookrLaunchpadLib.LpTranche[](2);
        // Two ascending, non-overlapping ladders above the graduation tick.
        a.lpTranches[0] = HookrLaunchpadLib.LpTranche({startOffset: 600, endOffset: 6000, bps: 5000});
        a.lpTranches[1] = HookrLaunchpadLib.LpTranche({startOffset: 6000, endOffset: 12_000, bps: 2500});

        uint256 padEthBefore = address(pad).balance;
        (address token,, PoolId id) = _launchAndGraduate(a);

        assertEq(pad.getLpTranches(token).length, 2, "bands not stored");

        // Each configured band exists as its own position with real liquidity.
        (, int24 gradTick,,) = manager.getSlot0(id);
        uint128 seeded;
        for (uint256 i; i < 2; ++i) {
            (int24 lower, int24 upper) = _bandRange(gradTick, a.lpTranches[i]);
            uint128 liq = manager.getPositionLiquidity(id, _positionKey(lower, upper));
            assertGt(liq, 0, "band has no liquidity");
            seeded += liq;
            assertLt(upper, gradTick, "band is not below spot in tick terms");
        }
        assertGt(seeded, 0);

        // The unallocated 25% still burns, and the raise was never touched to fund a band.
        assertGt(HookrToken(token).balanceOf(DEAD), 0, "remainder not burned");
        assertGe(address(pad).balance, padEthBefore, "ETH left the launchpad for a band");
        assertGt(manager.getLiquidity(id), 0, "base position missing");
        // The pool still prices at graduation: token-only bands sit entirely above spot.
        (uint160 sqrtNow,,,) = manager.getSlot0(id);
        assertEq(sqrtNow, pad.getLaunch(token).sqrtPriceX96AtGraduation, "bands moved the price");
    }

    function test_curveGraduatedEventReconcilesBaseBandsAndActualBurn() public {
        HookrLaunchpad.LaunchArgs memory a = _baseArgs();
        a.lpTranches = new HookrLaunchpadLib.LpTranche[](2);
        a.lpTranches[0] = HookrLaunchpadLib.LpTranche({startOffset: 600, endOffset: 6000, bps: 5000});
        a.lpTranches[1] = HookrLaunchpadLib.LpTranche({startOffset: 6000, endOffset: 12_000, bps: 2500});

        vm.recordLogs();
        (address token,,) = _launchAndGraduate(a);
        _assertGraduationSupplyAccounting(vm.getRecordedLogs(), token, pad.SUPPLY() - pad.CURVE_SUPPLY());
    }

    function test_instantGraduatedEventReconcilesBaseBandsAndActualBurn() public {
        HookrLaunchpad.LaunchArgs memory a = _baseArgs();
        a.targetRaiseWei = 0;
        a.creatorBuyWei = 1 ether;
        a.lpTranches = new HookrLaunchpadLib.LpTranche[](2);
        a.lpTranches[0] = HookrLaunchpadLib.LpTranche({startOffset: 600, endOffset: 6000, bps: 5000});
        a.lpTranches[1] = HookrLaunchpadLib.LpTranche({startOffset: 6000, endOffset: 12_000, bps: 2500});

        uint256 value = pad.creationFeeWei() + a.creatorBuyWei;
        vm.recordLogs();
        vm.prank(creator);
        address token = pad.launchInstant{value: value}(a, 5000, bytes32(0));
        _assertGraduationSupplyAccounting(vm.getRecordedLogs(), token, pad.SUPPLY());
    }

    function test_collectionIncludesTrancheFeesNotJustTheFullRangePosition() public {
        HookrLaunchpad.LaunchArgs memory a = _baseArgs();
        a.lpTranches = new HookrLaunchpadLib.LpTranche[](1);
        // A band starting just above spot, so an ordinary buy trades through it.
        a.lpTranches[0] = HookrLaunchpadLib.LpTranche({startOffset: 60, endOffset: 60_000, bps: 9000});
        (address token, PoolKey memory key, PoolId id) = _launchAndGraduate(a);

        // Buying is zeroForOne (ETH in, token out), which raises the token's price and so
        // LOWERS the tick — straight into the band, which sits below the graduation tick.
        _churn(key);
        _churn(key);
        (, int24 tickNow,,) = manager.getSlot0(id);
        int24 gradTick = V4PoolMath.getTickAtSqrtPrice(pad.getLaunch(token).sqrtPriceX96AtGraduation);
        assertLt(tickNow, gradTick, "price did not move into the band");

        uint256 protocolBefore = pad.protocolFeesByQuote(address(0));
        pad.collectPoolFees(token);
        uint256 collected = pad.creatorFeesWei(token) + (pad.protocolFeesByQuote(address(0)) - protocolBefore);
        assertGt(collected, 0, "no fees collected across the ranges");
    }

    function test_rejectsMalformedLpPlans() public {
        HookrLaunchpad.LaunchArgs memory a = _baseArgs();
        uint256 fee = pad.creationFeeWei();

        a.lpTranches = new HookrLaunchpadLib.LpTranche[](1);
        // Straddling spot would need ETH the raise has already committed.
        a.lpTranches[0] = HookrLaunchpadLib.LpTranche({startOffset: 0, endOffset: 600, bps: 5000});
        vm.prank(creator);
        vm.expectRevert(HookrLaunchpad.BadLpPlan.selector);
        pad.launch{value: fee}(a, bytes32(0));

        a.lpTranches[0] = HookrLaunchpadLib.LpTranche({startOffset: 600, endOffset: 600, bps: 5000}); // empty band
        vm.prank(creator);
        vm.expectRevert(HookrLaunchpad.BadLpPlan.selector);
        pad.launch{value: fee}(a, bytes32(0));

        a.lpTranches[0] = HookrLaunchpadLib.LpTranche({startOffset: 600, endOffset: 1200, bps: 10_001}); // over 100%
        vm.prank(creator);
        vm.expectRevert(HookrLaunchpad.BadLpPlan.selector);
        pad.launch{value: fee}(a, bytes32(0));

        HookrLaunchpad.LaunchArgs memory b = _baseArgs();
        b.lpTranches = new HookrLaunchpadLib.LpTranche[](2);
        b.lpTranches[0] = HookrLaunchpadLib.LpTranche({startOffset: 600, endOffset: 6000, bps: 4000});
        b.lpTranches[1] = HookrLaunchpadLib.LpTranche({startOffset: 3000, endOffset: 9000, bps: 4000}); // overlaps
        vm.prank(creator);
        vm.expectRevert(HookrLaunchpad.BadLpPlan.selector);
        pad.launch{value: fee}(a, bytes32(0));
    }

    // ------------------------------------------------------------------ helpers

    function _bandRange(int24 gradTick, HookrLaunchpadLib.LpTranche memory b)
        internal
        pure
        returns (int24 lower, int24 upper)
    {
        lower = _align(gradTick - b.endOffset);
        upper = _align(gradTick - b.startOffset);
    }

    function _align(int24 tick) internal pure returns (int24) {
        int24 aligned = (tick / 60) * 60;
        if (tick < 0 && aligned != tick) aligned -= 60;
        return aligned;
    }

    function _positionKey(int24 lower, int24 upper) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(address(pad), lower, upper, bytes32(0)));
    }

    function _assertGraduationSupplyAccounting(Vm.Log[] memory logs, address token, uint256 available) internal view {
        bytes32 graduatedSig = keccak256("Graduated(address,bytes32,uint160,uint256,uint256,uint256)");
        bytes32 trancheSig = keccak256("LpTrancheSeeded(address,uint256,int24,int24,uint256)");
        bytes32 tokenTopic = bytes32(uint256(uint160(token)));
        uint256 baseTokens;
        uint256 seededTokens;
        uint256 burnedTokens;
        bool sawGraduated;

        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter != address(pad) || entry.topics.length != 3 || entry.topics[1] != tokenTopic) continue;
            if (entry.topics[0] == graduatedSig) {
                (,, baseTokens, burnedTokens) = abi.decode(entry.data, (uint160, uint256, uint256, uint256));
                sawGraduated = true;
            } else if (entry.topics[0] == trancheSig) {
                (,, uint256 used) = abi.decode(entry.data, (int24, int24, uint256));
                seededTokens += used;
            }
        }

        assertTrue(sawGraduated, "missing Graduated event");
        assertGt(seededTokens, 0, "audit precondition: no tranche was seeded");
        assertEq(burnedTokens, HookrToken(token).balanceOf(DEAD), "event did not report the actual burn");
        assertEq(baseTokens + seededTokens + burnedTokens, available, "launch supply did not reconcile");
    }
}
