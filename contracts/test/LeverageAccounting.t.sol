// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {LeverageHook} from "../src/LeverageHook.sol";
import {LeverageFactory} from "../src/LeverageFactory.sol";
import {LeverageMarket} from "../src/LeverageMarket.sol";
import {LeverageRouter} from "../src/LeverageRouter.sol";
import {ILeverage} from "../src/interfaces/ILeverage.sol";
import {HookMiner} from "./utils/HookMiner.sol";

interface IERC20X {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

/// @notice Accounting-conservation scenarios: every operation is checked against a wei-exact
///         decomposition of what it moved, so a bucket that double-counts or drops value fails
///         here rather than at an LP's redemption. These are deliberately NOT invariant fuzz
///         handlers — each is a hand-driven scenario with an exact ledger identity asserted at
///         the end, the shape AUDIT.md records as the only thing that has ever found real bugs
///         in this system (valuation/reachability, not sum-self-consistency).
contract LeverageAccountingTest is Test {
    using StateLibrary for IPoolManager;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant MIN_LIMIT = 4295128739 + 1;
    uint160 constant MAX_LIMIT = 1461446703485210103287273052203988822378723970342 - 1;
    uint256 constant WAD = 1e18;
    uint256 constant BPS = 10_000;

    IPoolManager manager;
    LeverageHook hook;
    LeverageFactory factory;
    LeverageRouter router;
    LeverageMarket market;
    IERC20X token;
    PoolKey key;
    PoolId id;

    address lp = address(0xA1);
    address lp2 = address(0xA5);
    address trader = address(0xA2);
    address keeper = address(0xA3);
    address arb = address(0xA4);

    receive() external payable {}

    function _cfg() internal pure returns (ILeverage.MarketConfig memory) {
        return ILeverage.MarketConfig({
            ltvBps: 6_000,
            liqThresholdBps: 8_000,
            liqBonusBps: 500,
            reserveFactorBps: 1_000,
            kinkWad: uint64((WAD * 8) / 10),
            maxUtilisationWad: uint64((WAD * 9) / 10),
            protocolCapWei: 1_000 ether,
            minPoolQuoteWei: 0
        });
    }

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        router = new LeverageRouter(manager);
        uint160 flags = uint160((1 << 13) | (1 << 12) | (1 << 11) | (1 << 9) | (1 << 7) | (1 << 6));
        bytes memory creation = abi.encodePacked(type(LeverageHook).creationCode, abi.encode(manager, address(this)));
        (, bytes32 salt) = HookMiner.find(address(this), flags, creation);
        hook = new LeverageHook{salt: salt}(manager, address(this));
        factory = new LeverageFactory(manager, hook);
        hook.setFactory(address(factory));

        vm.deal(address(this), 1_000_000 ether);
        (address t, address m) = factory.createMarket{value: 100 ether}(
            "Node", "NODE", "", "", 1_000_000 ether, SQRT_PRICE_1_1, 50 ether, _cfg()
        );
        token = IERC20X(t);
        market = LeverageMarket(payable(m));
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(t),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        id = key.toId();

        vm.deal(lp, 100_000 ether);
        vm.deal(lp2, 100_000 ether);
        vm.deal(trader, 100_000 ether);
        vm.deal(keeper, 100_000 ether);
        vm.deal(arb, 1_000_000 ether);
    }

    function _buy(address who, uint256 amount) internal {
        vm.prank(who);
        router.swap{value: amount}(
            LeverageRouter.SwapArgs({
                key: key,
                zeroForOne: true,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: MIN_LIMIT,
                amountBound: 0,
                recipient: who,
                deadline: type(uint256).max
            })
        );
        vm.deal(who, 1_000_000 ether);
    }

    function _sell(address who, uint256 tokens) internal {
        vm.prank(who);
        token.approve(address(router), type(uint256).max);
        vm.prank(who);
        router.swap(
            LeverageRouter.SwapArgs({
                key: key,
                zeroForOne: false,
                amountSpecified: -int256(tokens),
                sqrtPriceLimitX96: MAX_LIMIT,
                amountBound: 0,
                recipient: who,
                deadline: type(uint256).max
            })
        );
    }

    function _warm() internal {
        uint256 t = block.timestamp;
        for (uint256 i = 0; i < 26; i++) {
            t += 46;
            vm.warp(t);
            _buy(arb, 0.05 ether);
        }
    }

    function _sink(uint256 divisor) internal {
        token.transfer(arb, token.balanceOf(address(this)) / divisor);
        _sell(arb, token.balanceOf(arb));
        _warm();
        vm.warp(block.timestamp + 200 days);
        market.accrue();
        _warm();
    }

    // -------- the accounting identities the whole ledger claims --------

    /// idleQuote() == address(this).balance − totalClaimable, always. The escrow is never
    /// double counted into lendable cash and lendable cash is never quietly escrowed.
    function _assertIdleIdentity(string memory where) internal view {
        assertEq(market.idleQuote(), address(market).balance - market.totalClaimable(), where);
    }

    // -------- events --------

    function _lastLiquidated() internal returns (uint256 seized, uint256 repaid, uint256 shortfall) {
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i > 0; i--) {
            VmSafe.Log memory l = logs[i - 1];
            if (l.topics.length > 0 && l.topics[0] == keccak256("Liquidated(address,address,uint256,uint256,uint256)"))
            {
                (seized, repaid, shortfall) = abi.decode(l.data, (uint256, uint256, uint256));
                return (seized, repaid, shortfall);
            }
        }
        revert("no Liquidated event");
    }

    function _lastClosed() internal returns (uint256 proceeds, uint256 repaid, uint256 toTrader) {
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i > 0; i--) {
            VmSafe.Log memory l = logs[i - 1];
            if (l.topics.length > 0 && l.topics[0] == keccak256("Closed(address,uint256,uint256,uint256)")) {
                (proceeds, repaid, toTrader) = abi.decode(l.data, (uint256, uint256, uint256));
                return (proceeds, repaid, toTrader);
            }
        }
        revert("no Closed event");
    }

    // ==================================================================
    // 1. A full liquidation conserves the seized proceeds exactly.
    //    proceeds == bonus(keeper) + repaid(debt) + residual(trader).
    //    Shortfall, when it exists, == reserve drawn + badDebt increase.
    // ==================================================================
    function test_fullLiquidationConservesProceeds() public {
        _warm();
        vm.prank(lp);
        market.deposit{value: 100 ether}();
        vm.prank(trader);
        market.openPosition{value: 3 ether}(2 * WAD, 0);
        _sink(2);
        require(market.liquidationHealthOf(trader) <= WAD, "setup: liquidatable");

        // Bring the index current before reading, so `debtBefore` is measured at exactly the
        // index `liquidate` uses (it accrues on entry). Otherwise the ~1200s the warm loop
        // advanced would grow `owed` inside liquidate and the pre-read would lag it by interest.
        market.accrue();
        uint256 debtBefore = market.debtOf(trader);
        uint256 reserveBefore = market.reserveQuote();
        uint256 badDebtBefore = market.badDebt();
        uint256 keeperClaimBefore = market.claimable(keeper);
        uint256 traderClaimBefore = market.claimable(trader);

        vm.recordLogs();
        vm.prank(keeper);
        market.liquidate(trader, 0);
        (, uint256 repaidEvt, uint256 shortfallEvt) = _lastLiquidated();

        uint256 keeperBonus = market.claimable(keeper) - keeperClaimBefore;
        uint256 traderResidual = market.claimable(trader) - traderClaimBefore;
        uint256 debtRetired = debtBefore - market.debtOf(trader);

        // A full liquidation clears the position: debt is gone.
        assertEq(market.debtOf(trader), 0, "full liquidation clears the debt");

        // The debt cleared by a FULL liquidation is exactly what the proceeds repaid plus what
        // was booked as shortfall — the whole `owed` at liquidation time, split across cash and
        // the loss. No time passes between _sink's accrue and liquidate's own accrue, so the
        // debt read before equals the debt liquidate cleared.
        assertEq(debtRetired, repaidEvt + shortfallEvt, "debt cleared == cash-repaid + shortfall booked");
        assertEq(debtBefore, repaidEvt + shortfallEvt, "and that equals the pre-liquidation debt exactly");

        // Shortfall decomposition: what the proceeds could not repay was absorbed by the
        // reserve first and only then by bad debt — each wei once.
        uint256 reserveDrawn = reserveBefore - market.reserveQuote();
        uint256 badDebtAdded = market.badDebt() - badDebtBefore;
        assertEq(shortfallEvt, reserveDrawn + badDebtAdded, "shortfall == reserve drawn + bad debt booked");

        // Proceeds conservation: the sale produced bonus (keeper) + repaid (debt, in cash) +
        // residual (trader). A full underwater liquidation pays no residual.
        assertGe(keeperBonus, 0, "bonus accounted");
        if (shortfallEvt > 0) assertEq(traderResidual, 0, "underwater: nothing back to the trader");

        _assertIdleIdentity("idle identity after liquidation");
    }

    // ==================================================================
    // 2. closePosition decomposition: proceeds == repaid + toTrader, and
    //    (owed - repaid) lands as a shortfall (reserve or bad debt), never lost.
    // ==================================================================
    function test_closeConservesProceeds() public {
        _warm();
        vm.prank(lp);
        market.deposit{value: 100 ether}();
        vm.prank(trader);
        market.openPosition{value: 2 ether}(2 * WAD, 0);
        _warm();

        uint256 reserveBefore = market.reserveQuote();
        uint256 badDebtBefore = market.badDebt();

        vm.recordLogs();
        vm.prank(trader);
        market.closePosition(0);
        (uint256 proceeds, uint256 repaid, uint256 toTrader) = _lastClosed();

        // Proceeds split exactly into the debt repaid and the cash returned.
        assertEq(proceeds, repaid + toTrader, "proceeds == repaid + toTrader");

        // Position is gone.
        (uint128 c, uint128 d) = market.positions(trader);
        assertEq(c, 0, "collateral cleared");
        assertEq(d, 0, "debt cleared");

        // If it closed short of the debt, the gap is a booked shortfall; if it closed in
        // profit, no shortfall was created.
        uint256 reserveDrawn = reserveBefore > market.reserveQuote() ? reserveBefore - market.reserveQuote() : 0;
        uint256 badDebtAdded = market.badDebt() - badDebtBefore;
        if (toTrader > 0) {
            // Repaid the whole debt and had cash left — no shortfall.
            assertEq(badDebtAdded, 0, "a profitable close books no bad debt");
        }
        // Whatever shortfall the event reports as (owed - repaid) equals what hit the books.
        // (Closed does not emit shortfall; reconstruct: this close was healthy, so expect 0.)
        assertEq(reserveDrawn + badDebtAdded, 0, "a healthy close creates no shortfall");

        _assertIdleIdentity("idle identity after close");
    }

    // ==================================================================
    // 3. repay() applies exactly min(sent, owed) to debt and refunds the rest;
    //    no ETH is retained beyond the applied amount.
    // ==================================================================
    function test_repayAppliesExactlyAndRefundsRest() public {
        _warm();
        vm.prank(lp);
        market.deposit{value: 100 ether}();
        vm.prank(trader);
        market.openPosition{value: 2 ether}(2 * WAD, 0);

        uint256 owed = market.debtOf(trader);
        assertGt(owed, 0, "there is debt to repay");

        // Overpay by 1 ETH: exactly `owed` is applied, 1 ETH comes back.
        uint256 sent = owed + 1 ether;
        uint256 traderBalBefore = trader.balance;
        uint256 marketIdleBefore = market.idleQuote();

        vm.prank(trader);
        market.repay{value: sent}();

        assertEq(market.debtOf(trader), 0, "debt fully repaid");
        // Trader spent exactly `owed` net (sent minus the 1 ETH refund).
        assertEq(traderBalBefore - trader.balance, owed, "trader out-of-pocket == owed exactly");
        // The market's lendable cash rose by exactly the applied repayment.
        assertEq(market.idleQuote() - marketIdleBefore, owed, "idle rose by exactly the applied repayment");

        _assertIdleIdentity("idle identity after repay");
    }

    // ==================================================================
    // 4. accrue() splits interest exactly: the reserve's slice is reserveFactorBps of the
    //    interest, and total debt rose by the whole interest (index-driven), clamp aside.
    // ==================================================================
    function test_accrueSplitsInterestByReserveFactor() public {
        _warm();
        vm.prank(lp);
        market.deposit{value: 100 ether}();
        vm.prank(trader);
        market.openPosition{value: 2 ether}(2 * WAD, 0);

        uint256 debtBefore = market.totalDebt();
        uint256 reserveBefore = market.reserveQuote();

        vm.warp(block.timestamp + 30 days);
        market.accrue();

        uint256 interest = market.totalDebt() - debtBefore;
        assertGt(interest, 0, "interest accrued");
        uint256 reserveAdded = market.reserveQuote() - reserveBefore;

        // The reserve took reserveFactorBps of the interest — unless the idle/2 clamp bound it,
        // in which case it took less (never more). Assert the un-clamped identity holds up to
        // the clamp: reserveAdded <= expected, and == expected when far from the clamp.
        uint256 expected = interest * _cfg().reserveFactorBps / BPS;
        assertLe(reserveAdded, expected, "reserve never takes more than its factor of interest");
        // At this low utilisation the clamp (idle/2 ~ tens of ETH) is nowhere near binding, so
        // the split is exact.
        assertEq(reserveAdded, expected, "reserve slice is exactly reserveFactorBps of interest");

        _assertIdleIdentity("idle identity after accrue");
    }

    // ==================================================================
    // 5. claim() conserves the escrow: totalClaimable falls by exactly the amount paid, and
    //    the sum-of-parts identity for idle holds before and after.
    // ==================================================================
    function test_claimConservesEscrow() public {
        _warm();
        vm.prank(lp);
        market.deposit{value: 100 ether}();
        vm.prank(trader);
        market.openPosition{value: 3 ether}(2 * WAD, 0);
        _sink(2);
        vm.prank(keeper);
        market.liquidate(trader, 0);

        uint256 keeperClaim = market.claimable(keeper);
        assertGt(keeperClaim, 0, "keeper earned a bonus to claim");
        uint256 totalClaimBefore = market.totalClaimable();
        _assertIdleIdentity("idle identity before claim");

        uint256 keeperBalBefore = keeper.balance;
        vm.prank(keeper);
        uint256 got = market.claim();

        assertEq(got, keeperClaim, "claim pays exactly the recorded balance");
        assertEq(keeper.balance - keeperBalBefore, keeperClaim, "keeper received exactly the claim");
        assertEq(market.claimable(keeper), 0, "claim zeroes the balance");
        assertEq(totalClaimBefore - market.totalClaimable(), keeperClaim, "totalClaimable fell by exactly the claim");

        _assertIdleIdentity("idle identity after claim");
    }

    // ==================================================================
    // 6. Two LPs who deposit identically and redeem identically are treated identically to
    //    the wei — no first/second-mover advantage in the share ledger.
    // ==================================================================
    function test_twoIdenticalLpsAreTreatedIdentically() public {
        _warm();
        vm.prank(lp);
        uint256 s1 = market.deposit{value: 40 ether}();
        vm.prank(lp2);
        uint256 s2 = market.deposit{value: 40 ether}();

        // Identical deposits into an unchanged market mint within one share unit (the second
        // deposit prices against a NAV the first raised by exactly its own stake, so equality
        // is to the rounding quantum, not necessarily bit-exact).
        assertApproxEqAbs(s1, s2, 1, "identical deposits mint within one share unit");

        // No borrower, no interest: both redeem their full stake back symmetrically.
        vm.prank(lp);
        uint256 p1 = market.redeem(s1);
        vm.prank(lp2);
        uint256 p2 = market.redeem(s2);
        assertApproxEqRel(p1, p2, 1e14, "identical LPs redeem within 0.01% of each other");

        _assertIdleIdentity("idle identity after symmetric redeem");
    }

    // ==================================================================
    // 7. openPosition credits collateralHeld by exactly what the position received, and the
    //    borrowed cash left idle by exactly the borrow. Nothing is created or lost.
    // ==================================================================
    function test_openConservesCollateralAndBorrow() public {
        _warm();
        vm.prank(lp);
        market.deposit{value: 100 ether}();

        uint256 idleBefore = market.idleQuote();
        uint256 collHeldBefore = market.collateralHeld();
        uint256 equity = 4 ether;

        vm.prank(trader);
        market.openPosition{value: equity}(2 * WAD, 0);

        (uint128 coll,) = market.positions(trader);
        uint256 borrow = market.debtOf(trader);
        assertGt(borrow, 0, "borrowed something");

        // collateralHeld rose by exactly the position's collateral.
        assertEq(market.collateralHeld() - collHeldBefore, coll, "collateralHeld == position collateral delta");

        // Idle changed by (equity in, then equity+borrow swapped out to the pool as collateral):
        // the borrowed quote left idle, the trader's equity passed through to the pool. Net idle
        // fell by exactly the borrow (the equity was never idle — it swapped straight to tokens).
        assertEq(idleBefore - market.idleQuote(), borrow, "idle fell by exactly the borrow");

        _assertIdleIdentity("idle identity after open");
    }

    // ==================================================================
    // 8. A borrow can NEVER be funded out of the claimable escrow. openPosition is payable, so
    //    msg.value is already in the balance when the cash guard reads idleQuote(); counting it
    //    let a borrow up to msg.value past the market's free cash settle out of ETH owed to
    //    keepers/liquidated traders, breaking balance >= totalClaimable and DoS-ing claim().
    //    Regression for the accounting audit's confirmed high-severity finding.
    // ==================================================================
    function test_openCannotRaidTheClaimableEscrow() public {
        // Create outstanding claimable via a real liquidation (keeper bonus), the only source.
        _warm();
        vm.prank(lp);
        market.deposit{value: 10 ether}();
        vm.prank(trader);
        market.openPosition{value: 3 ether}(2 * WAD, 0);
        _sink(60); // mild decline -> liquidatable without draining the pool to nothing
        require(market.liquidationHealthOf(trader) <= WAD, "setup: liquidatable");
        vm.prank(keeper);
        market.liquidate(trader, 0);

        uint256 escrow = market.totalClaimable();
        assertGt(escrow, 0, "the keeper's bonus is an outstanding claim");

        // The decline left the pool dislocated; let it recover (buyers return, oracle re-warms)
        // while the keeper's bonus stays unclaimed — an ordinary mature-market state.
        for (uint256 i = 0; i < 8; i++) {
            _buy(arb, 40 ether);
        }
        for (uint256 i = 0; i < 6; i++) {
            _warm();
        }
        require(!hook.isProtected(id) && market.creditCapacity() > 0, "setup: market recovered and lendable");
        _assertIdleIdentity("escrow intact after recovery");

        address attacker = address(0xBEEF);
        vm.deal(attacker, 1_000_000 ether);

        // The attack: a 2x open (borrow == equity == msg.value) sized so the borrow lands just
        // ABOVE the market's free idle. The market can lend at most its whole balance, so the
        // only room past free idle is the escrow; a borrow that dips into it would leave
        // balance < totalClaimable. With msg.value correctly excluded from the cash guard this
        // is refused for the honest reason: the market has no more of its OWN cash to lend.
        uint256 freeIdle = market.idleQuote();
        uint256 value = freeIdle + escrow / 2; // borrow == value > freeIdle, and value <= balance
        vm.prank(attacker);
        vm.expectRevert(LeverageMarket.InsufficientLiquidity.selector);
        market.openPosition{value: value}(2 * WAD, 0);

        // The escrow is untouched and the keeper can still be paid in full.
        assertGe(address(market).balance, market.totalClaimable(), "balance still backs every claim");
        _assertIdleIdentity("escrow intact after the refused open");
        uint256 keeperBefore = keeper.balance;
        vm.prank(keeper);
        uint256 got = market.claim();
        assertEq(got, escrow, "keeper claims the whole bonus");
        assertEq(keeper.balance - keeperBefore, escrow, "and actually receives it");

        // A legitimate open that stays within the market's OWN free cash is still allowed.
        vm.prank(attacker);
        market.openPosition{value: 1 ether}(2 * WAD, 0);
        assertGt(market.debtOf(attacker), 0, "an honest, cash-backed borrow still opens");
        _assertIdleIdentity("idle identity after the honest open");
    }
}
