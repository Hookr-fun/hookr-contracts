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
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {HookrBlueprints} from "../src/HookrBlueprints.sol";
import {HookrLaunchpad} from "../src/HookrLaunchpad.sol";
import {HookrLaunchpadLib} from "../src/libraries/HookrLaunchpadLib.sol";
import {HookrHook} from "../src/HookrHook.sol";
import {HookrSwapRouter} from "../src/HookrSwapRouter.sol";
import {HookrToken} from "../src/HookrToken.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @notice Adversarial regression for guard-fee accounting when an exact-input buy is only
///         partially filled at its caller-selected price limit.
contract GuardPartialFillAuditTest is Test {
    using StateLibrary for IPoolManager;

    uint160 internal constant HOOK_FLAGS = uint160((1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2));
    uint160 internal constant MIN_LIMIT = 4295128740;
    uint160 internal constant MAX_LIMIT = 1461446703485210103287273052203988822378723970341;

    IPoolManager internal manager;
    HookrLaunchpad internal pad;

    HookrBlueprints bpReg;
    HookrHook internal hook;
    HookrSwapRouter internal router;
    PoolModifyLiquidityTest internal lpRouter;

    address internal creator = address(0xC0FFEE);
    address internal trader = address(0xB0B);
    address internal buyer = address(0xBEEF);

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
        lpRouter = new PoolModifyLiquidityTest(manager);
        vm.deal(creator, 10 ether);
        vm.deal(trader, 100 ether);
        vm.deal(buyer, 100 ether);
    }

    function _launch(uint16 maxBuyBps, uint16 lpBps) internal returns (address token, PoolKey memory key, PoolId id) {
        return _launchWithFees(maxBuyBps, lpBps, 3_000, 100_000);
    }

    function _launchWithFees(uint16 maxBuyBps, uint16 lpBps, uint24 baseFeePips, uint24 snipeTaxPips)
        internal
        returns (address token, PoolKey memory key, PoolId id)
    {
        HookrLaunchpadLib.HookParams memory params = HookrLaunchpadLib.HookParams({
            guardBlocks: 10,
            maxBuyBps: maxBuyBps,
            snipeTaxPips: snipeTaxPips,
            baseFeePips: baseFeePips,
            maxFeePips: baseFeePips,
            surgeSens: 0,
            burnBps: 0,
            burnTriggerWei: 0,
            lpBps: lpBps,
            potBps: 0,
            potEveryNBuys: 0,
            potMinBuyWei: 0,
            buybackBps: 0,
            buybackDrawdownBps: 0,
            buybackCooldownBlocks: 0,
            buybackMinSpendWei: 0,
            buybackMaxSpendWei: 0
        });
        HookrLaunchpad.LaunchArgs memory args;
        args.name = "Partial Guard";
        args.symbol = "PGUARD";
        args.expectedCreator = creator;
        args.creatorBuyWei = 1 ether;
        args.custom = params;

        uint256 value = pad.creationFeeWei() + args.creatorBuyWei;
        vm.prank(creator);
        token = pad.launchInstant{value: value}(args, 5000, bytes32(0));
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        id = key.toId();
    }

    function _buy(PoolKey memory key, uint128 requested, uint160 limit) internal returns (uint256 used) {
        return _buyAs(trader, key, requested, limit);
    }

    function _buyAs(address who, PoolKey memory key, uint128 requested, uint160 limit) internal returns (uint256 used) {
        HookrSwapRouter.ExactInputParams memory params = HookrSwapRouter.ExactInputParams({
            key: key,
            zeroForOne: true,
            amountIn: requested,
            amountOutMinimum: 1,
            sqrtPriceLimitX96: limit,
            recipient: who,
            deadline: block.timestamp + 1
        });
        uint256 beforeBalance = who.balance;
        vm.prank(who);
        router.exactInput{value: requested}(params);
        used = beforeBalance - who.balance;
    }

    function _sell(address token, PoolKey memory key, uint128 tokenIn) internal returns (uint256 received) {
        vm.startPrank(trader);
        HookrToken(token).approve(address(router), tokenIn);
        HookrSwapRouter.ExactInputParams memory params = HookrSwapRouter.ExactInputParams({
            key: key,
            zeroForOne: false,
            amountIn: tokenIn,
            amountOutMinimum: 1,
            sqrtPriceLimitX96: MAX_LIMIT,
            recipient: trader,
            deadline: block.timestamp + 1
        });
        uint256 beforeBalance = trader.balance;
        router.exactInput(params);
        vm.stopPrank();
        received = trader.balance - beforeBalance;
    }

    function test_guardLedgerMustUseActualPartialFill_notRequestedInput() public {
        (address token, PoolKey memory key, PoolId id) = _launch(0, 0);
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(id);

        uint256 requested = 10 ether;
        uint160 nearSpotLimit = sqrtPriceX96 - (sqrtPriceX96 / 1_000_000);
        uint256 used = _buy(key, uint128(requested), nearSpotLimit);
        assertGt(used, 0, "partial buy must trade");
        assertLt(used, requested / 1000, "test did not produce a sharply partial fill");

        uint256 recorded = hook.guardLpEarnedWei(id);
        assertLe(recorded, used, "guard ledger charged ETH the pool never consumed");

        // Collect the real guarded fee and advance past the guard. The attack must not leave a
        // phantom high-water mark capable of confiscating unrelated fees earned later.
        pad.collectPoolFees(token);
        uint256 withheldAfterGuard = pad.guardFeesWithheldWei(token);
        vm.roll(vm.getBlockNumber() + 10);

        _buy(key, 0.1 ether, MIN_LIMIT);
        uint256 creatorBefore = pad.creatorFeesWei(token);
        pad.collectPoolFees(token);
        assertGt(pad.creatorFeesWei(token) - creatorBefore, 0, "post-guard creator fees were confiscated");
        // v4 fee-growth division can leave one wei below the hook's deliberately rounded-up
        // accrual even when this is the only LP. That existing one-wei high-water behavior is not
        // the refunded-input defect; the attack must not leave more than that rounding bound.
        assertLe(
            pad.guardFeesWithheldWei(token) - withheldAfterGuard,
            1,
            "post-guard fees were applied to a phantom guard accrual"
        );
    }

    function test_guardBudgetMustUseActualPartialFill_notRequestedInput() public {
        (, PoolKey memory key, PoolId id) = _launch(100, 0); // 1% of the 50% float = 0.01 ETH at open
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(id);

        uint128 requested = 0.01 ether;
        uint160 nearSpotLimit = sqrtPriceX96 - (sqrtPriceX96 / 1_000_000);
        uint256 used = _buy(key, requested, nearSpotLimit);
        assertGt(used, 0, "partial buy must trade");
        assertLt(used, requested / 1000, "test did not produce a sharply partial fill");

        assertLe(hook.guardBuyWei(id), used, "partial buy consumed budget for refunded ETH");

        // A second buy whose actual/requested input remains below the cap must fit in this block.
        // Before the reconciliation fix, the first call reserves the full 0.01 ETH forever and
        // this otherwise-valid follow-up reverts MaxBuyExceeded.
        _buy(key, 0.009 ether, MIN_LIMIT);
        assertLe(hook.guardBuyWei(id), 0.01 ether, "same-block actual input exceeded the configured cap");
    }

    function test_fullFillsAndSellsPreserveExistingGuardAccountingAcrossSwaps() public {
        (address token, PoolKey memory key, PoolId id) = _launch(100, 0);

        uint256 first = 0.004 ether;
        uint256 second = 0.005 ether;
        _buy(key, uint128(first), MIN_LIMIT);
        _buy(key, uint128(second), MIN_LIMIT);

        uint256 requested = first + second;
        uint256 expectedFee = (requested * 103_000 + 1e6 - 1) / 1e6;
        assertEq(hook.guardBuyWei(id), requested, "full-fill cap accounting changed");
        assertEq(hook.guardLpEarnedWei(id), expectedFee, "paired callbacks leaked scratch state across buys");

        uint256 tokensToSell = HookrToken(token).balanceOf(trader) / 100;
        uint256 budgetBefore = hook.guardBuyWei(id);
        uint256 feesBefore = hook.guardLpEarnedWei(id);
        assertGt(_sell(token, key, uint128(tokensToSell)), 0, "guarded sell failed");
        assertEq(hook.guardBuyWei(id), budgetBefore, "sell mutated guarded buy budget");
        assertEq(hook.guardLpEarnedWei(id), feesBefore, "sell mutated guarded buy fees");
    }

    function test_nativeCutPathStillRejectsPartialFillAtomically() public {
        (, PoolKey memory key, PoolId id) = _launch(0, 100);
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(id);
        uint160 nearSpotLimit = sqrtPriceX96 - (sqrtPriceX96 / 1_000_000);

        uint256 feesBefore = hook.totalHookFeesWei(id);
        uint256 guardBefore = hook.guardLpEarnedWei(id);
        vm.expectRevert();
        _buy(key, 0.01 ether, nearSpotLimit);
        assertEq(hook.totalHookFeesWei(id), feesBefore, "reverted cut path accrued hook fees");
        assertEq(hook.guardLpEarnedWei(id), guardBefore, "reverted cut path accrued guarded fees");
    }

    function test_protocolFeeIsRemovedFromNoCutGuardAccrual() public {
        (, PoolKey memory key, PoolId id) = _launch(0, 0);
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(key, 1_000); // maximum 0->1 protocol fee: 0.1%

        uint256 requested = 0.1 ether;
        uint256 guardBefore = hook.guardLpEarnedWei(id);
        uint256 used = _buy(key, uint128(requested), MIN_LIMIT);
        assertEq(used, requested, "audit precondition: guarded buy did not fill");

        uint256 lpFeePips = 103_000; // 0.3% base + 10% snipe tax
        uint256 combinedFeePips = 1_000 + lpFeePips - ((1_000 * lpFeePips) / 1e6);
        uint256 totalSwapFee = (used * combinedFeePips + 1e6 - 1) / 1e6;
        uint256 protocolFee = (used * 1_000) / 1e6;
        assertEq(
            hook.guardLpEarnedWei(id) - guardBefore,
            totalSwapFee - protocolFee,
            "protocol fee was misclassified as launchpad LP income"
        );

        // Settling the guarded fees must not leave a high-water debt that can consume unrelated
        // creator fees after the guard. Fee-growth division can leave one wei uncollectable.
        address token = Currency.unwrap(key.currency1);
        pad.collectPoolFees(token);
        assertLe(hook.guardLpEarnedWei(id) - pad.guardFeesWithheldWei(token), 1);
        vm.roll(vm.getBlockNumber() + 10);
        _buy(key, 0.1 ether, MIN_LIMIT);
        uint256 creatorBefore = pad.creatorFeesWei(token);
        pad.collectPoolFees(token);
        assertGt(pad.creatorFeesWei(token) - creatorBefore, 0, "phantom debt consumed later fees");
    }

    function test_protocolFeeIsRemovedFromCutBearingGuardAccrual() public {
        (, PoolKey memory key, PoolId id) = _launch(0, 100); // 1% input cut, all donated to LPs
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(key, 1_000);

        uint256 requested = 0.1 ether;
        uint256 guardBefore = hook.guardLpEarnedWei(id);
        uint256 donatedBefore = hook.totalLpDonatedWei(id);
        uint256 used = _buy(key, uint128(requested), MIN_LIMIT);
        assertEq(used, requested, "audit precondition: cut-bearing buy did not fill");

        uint256 hookCut = (requested * 100) / 10_000;
        uint256 poolInput = requested - hookCut;
        uint256 lpFeePips = 103_000;
        uint256 combinedFeePips = 1_000 + lpFeePips - ((1_000 * lpFeePips) / 1e6);
        uint256 totalSwapFee = (poolInput * combinedFeePips + 1e6 - 1) / 1e6;
        uint256 protocolFee = (poolInput * 1_000) / 1e6;
        uint256 donated = hook.totalLpDonatedWei(id) - donatedBefore;
        assertEq(donated, hookCut, "audit precondition: LP cut was not fully donated");
        assertEq(
            hook.guardLpEarnedWei(id) - guardBefore,
            totalSwapFee - protocolFee + donated,
            "cut path misclassified protocol fee as launchpad LP income"
        );
    }

    function test_zeroLpFeeNeverBooksProtocolRoundingAsGuardIncome() public {
        (, PoolKey memory key, PoolId id) = _launchWithFees(0, 0, 0, 0);
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(key, 1_000);

        // Deliberately not divisible by the protocol-fee denominator. ceil(gross*p)-floor(gross*p)
        // is one, but v4's swapFee==protocolFee branch assigns the entire fee to the protocol.
        uint128 requested = 100_000_000_000_000_001;
        uint256 used = _buy(key, requested, MIN_LIMIT);
        assertEq(used, requested, "audit precondition: zero-LP-fee buy did not fill");
        assertEq(hook.guardLpEarnedWei(id), 0, "protocol rounding was booked as LP income");
    }

    function test_externalGuardLpMustNotCreatePhantomWithholdingDebt() public {
        (address token, PoolKey memory key, PoolId id) = _launch(0, 0);

        // Acquire inventory through the live pool, then settle every guard fee from that buy while
        // the launchpad is still the only LP. This isolates the next buy's accounting.
        _buy(key, 0.5 ether, MIN_LIMIT);
        pad.collectPoolFees(token);
        assertLe(hook.guardLpEarnedWei(id) - pad.guardFeesWithheldWei(token), 1, "initial guard fees unsettled");

        // Joining the same full-range position during the guard would split the guarded fee while
        // the launchpad ledger still records the whole amount. The before-add flag must stop that
        // position before any capital moves.
        uint128 externalLiquidity = manager.getLiquidity(id) / 4;
        vm.startPrank(trader);
        HookrToken(token).approve(address(lpRouter), type(uint256).max);
        vm.expectRevert();
        lpRouter.modifyLiquidity{value: 10 ether}(
            key,
            ModifyLiquidityParams({
                tickLower: -887220,
                tickUpper: 887220,
                liquidityDelta: int256(uint256(externalLiquidity)),
                salt: bytes32(0)
            }),
            ""
        );
        vm.stopPrank();

        // With no outside position, the launchpad can collect the guarded fee without phantom
        // high-water debt.
        _buyAs(buyer, key, 0.2 ether, MIN_LIMIT);
        pad.collectPoolFees(token);

        uint256 phantomDebt = hook.guardLpEarnedWei(id) - pad.guardFeesWithheldWei(token);
        assertLe(phantomDebt, 1, "external LP share became phantom launchpad withholding debt");

        // Permissionless LP resumes at the exact guard boundary, and later fees still use the
        // configured creator split.
        vm.roll(vm.getBlockNumber() + 10);
        vm.prank(trader);
        lpRouter.modifyLiquidity{value: 10 ether}(
            key,
            ModifyLiquidityParams({
                tickLower: -887220,
                tickUpper: 887220,
                liquidityDelta: int256(uint256(externalLiquidity)),
                salt: bytes32(0)
            }),
            ""
        );
        _buyAs(buyer, key, 0.1 ether, MIN_LIMIT);
        uint256 creatorBefore = pad.creatorFeesWei(token);
        pad.collectPoolFees(token);
        assertGt(pad.creatorFeesWei(token) - creatorBefore, 0, "external LP confiscated later creator fees");
    }
}
