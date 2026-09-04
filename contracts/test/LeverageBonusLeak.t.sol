// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

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

/// @notice Quantifies the accepted "underwater-liquidation bonus is LP-borne" caveat recorded in
///         AUDIT.md item 4. NOT a bug this test expects to fail — it PINS the magnitude, so a
///         future change that widens the leak (or a fix that closes it) shows up here as a number.
///
///         The claim under measurement: on an underwater liquidation (`proceeds < owed`), the 5%
///         bonus is carved from `net` before repayment, so the bad debt booked to LPs is larger by
///         exactly the bonus than it would be at `liqBonusBps = 0`. Proven by A/B: two identical
///         markets that differ only in `liqBonusBps`, driven through the same decline and the same
///         liquidation.
contract LeverageBonusLeakTest is Test {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant MIN_LIMIT = 4295128739 + 1;
    uint160 constant MAX_LIMIT = 1461446703485210103287273052203988822378723970342 - 1;
    uint256 constant WAD = 1e18;

    IPoolManager manager;
    LeverageHook hook;
    LeverageFactory factory;
    LeverageRouter router;

    address lp = address(0xA1);
    address trader = address(0xA2);
    address keeper = address(0xA3);
    address arb = address(0xA4);

    receive() external payable {}

    function _cfg(uint16 bonusBps) internal pure returns (ILeverage.MarketConfig memory) {
        return ILeverage.MarketConfig({
            ltvBps: 6_000,
            liqThresholdBps: 8_000,
            liqBonusBps: bonusBps,
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
        vm.deal(lp, 100_000 ether);
        vm.deal(trader, 100_000 ether);
        vm.deal(keeper, 100_000 ether);
        vm.deal(arb, 1_000_000 ether);
    }

    struct Run {
        LeverageMarket market;
        IERC20X token;
        PoolKey key;
        PoolId id;
        uint256 badDebt;
        uint256 keeperBonus;
        uint256 lpRedeem;
    }

    function _buy(Run memory r, uint256 amount) internal {
        vm.prank(arb);
        router.swap{value: amount}(
            LeverageRouter.SwapArgs({
                key: r.key,
                zeroForOne: true,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: MIN_LIMIT,
                amountBound: 0,
                recipient: arb,
                deadline: type(uint256).max
            })
        );
        vm.deal(arb, 1_000_000 ether);
    }

    function _sell(Run memory r, address who, uint256 tokens) internal {
        vm.prank(who);
        r.token.approve(address(router), type(uint256).max);
        vm.prank(who);
        router.swap(
            LeverageRouter.SwapArgs({
                key: r.key,
                zeroForOne: false,
                amountSpecified: -int256(tokens),
                sqrtPriceLimitX96: MAX_LIMIT,
                amountBound: 0,
                recipient: who,
                deadline: type(uint256).max
            })
        );
    }

    function _warm(Run memory r) internal {
        uint256 t = block.timestamp;
        for (uint256 i = 0; i < 26; i++) {
            t += 46;
            vm.warp(t);
            _buy(r, 0.05 ether);
        }
    }

    /// Build one market with the given bonus, drive the SAME decline and liquidation, and record
    /// the bad debt booked, the keeper's bonus, and what the LP can redeem afterwards.
    function _driveUnderwater(uint16 bonusBps) internal returns (Run memory r) {
        (address t, address m) = factory.createMarket{value: 100 ether}(
            "Node", "NODE", "", "", 1_000_000 ether, SQRT_PRICE_1_1, 50 ether, _cfg(bonusBps)
        );
        r.token = IERC20X(t);
        r.market = LeverageMarket(payable(m));
        r.key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(t),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        r.id = r.key.toId();

        _warm(r);
        vm.prank(lp);
        r.market.deposit{value: 100 ether}();
        vm.prank(trader);
        r.market.openPosition{value: 1 ether}(2 * WAD, 0);

        // Drive the position underwater with the SAME calibrated decline the proven exploit
        // fixture uses (LeverageExploits._sinkTheTrader): dump a fixed fraction of the creator's
        // unsold supply, sell it in, re-warm, let interest accrue, re-warm. A fixed absolute slug
        // instead overflowed accrue's index after 200 days at pinned utilisation — an artifact of
        // an unrealistically large single dump, not a contract path.
        r.token.transfer(arb, r.token.balanceOf(address(this)) / 2);
        _sell(r, arb, r.token.balanceOf(arb));
        _warm(r);
        vm.warp(block.timestamp + 200 days);
        r.market.accrue();
        _warm(r);
        require(r.market.liquidationHealthOf(trader) <= WAD, "setup: not liquidatable");

        uint256 keeperBefore = r.market.claimable(keeper);
        vm.prank(keeper);
        r.market.liquidate(trader, 0);

        r.badDebt = r.market.badDebt();
        r.keeperBonus = r.market.claimable(keeper) - keeperBefore;

        uint256 shares = r.market.balanceOf(lp);
        vm.prank(lp);
        r.lpRedeem = r.market.redeem(shares);
    }

    function test_underwaterBonusIsBorneByLps_quantified() public {
        // Snapshot so the two runs start from BYTE-IDENTICAL state and clock — running them back
        // to back accumulates warped time, and the second market's accrue then underflows `dt`.
        // The A/B only means anything if the only difference is liqBonusBps.
        uint256 snap = vm.snapshotState();
        Run memory withBonus = _driveUnderwater(500); // 5%, the shipped default
        vm.revertToState(snap);
        Run memory noBonus = _driveUnderwater(0); // counterfactual, same decline, same clock

        emit log_named_uint("withBonus.badDebt", withBonus.badDebt);
        emit log_named_uint("withBonus.keeperBonus", withBonus.keeperBonus);
        emit log_named_uint("withBonus.lpRedeem", withBonus.lpRedeem);
        emit log_named_uint("noBonus.badDebt", noBonus.badDebt);
        emit log_named_uint("noBonus.keeperBonus", noBonus.keeperBonus);
        emit log_named_uint("noBonus.lpRedeem", noBonus.lpRedeem);

        // The decline drove real bad debt in both markets (the liquidation was underwater).
        assertGt(withBonus.badDebt, 0, "with-bonus run must actually go underwater");

        // The bonus is only paid when there is a bonus to pay.
        assertGt(withBonus.keeperBonus, 0, "keeper earns the bonus");
        assertEq(noBonus.keeperBonus, 0, "no bonus configured, none paid");

        // The core claim: the 5% market books MORE bad debt than the 0% market, and the gap is
        // the bonus that was carved out of proceeds that would otherwise have reduced the
        // shortfall. Same decline, same liquidation, only liqBonusBps differs.
        assertGt(withBonus.badDebt, noBonus.badDebt, "the bonus enlarges the LP shortfall");
        uint256 extraBadDebt = withBonus.badDebt - noBonus.badDebt;

        // And the LP in the bonus market recovers strictly less on redemption.
        assertLt(withBonus.lpRedeem, noBonus.lpRedeem, "the LP bears the bonus on an underwater liquidation");

        // Bound the magnitude: the extra shortfall is on the order of the bonus (a few percent of
        // the seized proceeds), never a runaway. Emit both so the number is visible in -vv.
        emit log_named_uint("extra bad debt from the 5% bonus (wei)", extraBadDebt);
        emit log_named_uint("keeper bonus (wei)", withBonus.keeperBonus);
        emit log_named_uint("LP redeem WITH bonus (wei)", withBonus.lpRedeem);
        emit log_named_uint("LP redeem WITHOUT bonus (wei)", noBonus.lpRedeem);
        // The identity, exact to the wei: the extra bad debt the LP eats equals the bonus the
        // keeper was paid. `shortfall = owed - (proceeds - bonus)`, so a market that pays the
        // bonus books precisely `bonus` more bad debt than one that does not, same decline.
        assertEq(extraBadDebt, withBonus.keeperBonus, "the bonus enlarges the LP shortfall by exactly itself");
    }
}
