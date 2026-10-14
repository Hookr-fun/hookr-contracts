// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IHookrLpBoost} from "../../src/interfaces/IHookrLpBoost.sol";
import {LpBoostFixture} from "../periphery/LpBoostFixture.sol";
import {HookrLpBoostHandler} from "./HookrLpBoostHandler.sol";

interface IERC721Balance {
    function balanceOf(address owner) external view returns (uint256);
}

/// @notice HookrLpBoost invariants under a handler that stakes, stakes staked positions again, extends, withdraws,
///         notifies, funds, claims, collects fees, pauses, unpauses, moves the price and warps: per gauge paid + owed +
///         pending + unassigned + scheduled <= funded with only rounding dust between them, the reward balance covers
///         funded - paid, a position is staked once, NFTs held equal positions staked, the total weight and the drop
///         table match the live stakes, nothing accrues over an interval the pool spends outside the usable range or
///         after the last tranche's end, the pool's tick is outside the usable range only while nothing is staked (the
///         sizing rule), every tranche runs as it started (the gauge's rate and ending rates are its live tranches',
///         and what it has emitted is what they have emitted, to within rounding), nothing is scheduled once the last
///         tranche has ended, and no owed amount falls except by its own claim. The suites below run them on a deep
///         pool and on a thin one whose price the handler pushes at every tick.
abstract contract HookrLpBoostInvariantBase is LpBoostFixture {
    /// @dev The rounding every accrual step and settlement may leave behind, summed over a whole run, stays far below
    ///      this.
    uint256 internal constant DUST = 10_000;

    HookrLpBoostHandler internal handler;

    /// @dev Transfers `handlerAmount` of each pool token to `handler`, which gives each actor `perActor`, opens the run
    ///      with three locks (the shortest, a middle one and the longest) of the given liquidities and a funded
    ///      tranche, and targets every handler action.
    function _target(uint256 liquidity, uint256 handlerAmount, uint256 perActor) internal {
        PoolKey memory k = handler.key();
        IERC20(Currency.unwrap(k.currency0)).transfer(address(handler), handlerAmount);
        IERC20(Currency.unwrap(k.currency1)).transfer(address(handler), handlerAmount);
        handler.seed(perActor);
        handler.stake(0, liquidity, 4);
        handler.stake(1, liquidity * 3, 28);
        handler.stake(2, liquidity / 2, 52);
        handler.notify(52e21, 26);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = HookrLpBoostHandler.stake.selector;
        selectors[1] = HookrLpBoostHandler.stakeAgain.selector;
        selectors[2] = HookrLpBoostHandler.extend.selector;
        selectors[3] = HookrLpBoostHandler.withdraw.selector;
        selectors[4] = HookrLpBoostHandler.notify.selector;
        selectors[5] = HookrLpBoostHandler.fund.selector;
        selectors[6] = HookrLpBoostHandler.claim.selector;
        selectors[7] = HookrLpBoostHandler.collectFees.selector;
        selectors[8] = HookrLpBoostHandler.poke.selector;
        selectors[9] = HookrLpBoostHandler.warp.selector;
        selectors[10] = HookrLpBoostHandler.swap.selector;
        selectors[11] = HookrLpBoostHandler.pause.selector;
        selectors[12] = HookrLpBoostHandler.unpause.selector;
        targetSelector(StdInvariant.FuzzSelector(address(handler), selectors));
    }

    /// @dev After every run every staker exits and claims: every NFT is back with its staker and the gauge holds only
    ///      the unassigned remainder (waiting for a notify) and rounding dust. HOOKR_INVARIANT_COVERAGE=true prints
    ///      each run's action counts first.
    function afterInvariant() public {
        if (vm.envOr("HOOKR_INVARIANT_COVERAGE", false)) _printCoverage();
        handler.liveness();
        IHookrLpBoost.Gauge memory g = boost.gauge(handler.id());
        assertEq(IERC721Balance(address(posm)).balanceOf(address(boost)), 0, "every NFT back with its staker");
        assertEq(g.totalWeight, 0, "no weight left");
        assertEq(g.scheduled, 0, "every tranche has ended");
        assertEq(g.paid, handler.totalClaimed(), "paid equals what the claims paid");
        assertLe(uint256(g.funded) - g.paid - g.unassigned, DUST, "only dust stays besides the remainder");
        assertEq(
            IERC20(g.terms.rewardToken).balanceOf(address(boost)),
            uint256(g.funded) - g.paid,
            "the balance is the remainder and the dust"
        );
    }

    function _printCoverage() internal view {
        string[18] memory names = [
            "stake",
            "stakeAgain",
            "extend",
            "withdraw",
            "notify",
            "notifyEmpty",
            "fund",
            "claim",
            "collectFees",
            "poke",
            "warp",
            "swap",
            "swapOutOfRange",
            "intervalOutOfRange",
            "intervalAfterEnd",
            "pause",
            "unpause",
            "liveAtEnd"
        ];
        string memory line = "LPBOOST coverage";
        for (uint256 i; i < names.length - 1; ++i) {
            line = string.concat(line, " ", names[i], "=", vm.toString(handler.calls(bytes32(bytes(names[i])))));
        }
        line = string.concat(line, " ", names[names.length - 1], "=", vm.toString(handler.liveCount()));
        console2.log(line);
    }

    function invariant_solvency() public view {
        IHookrLpBoost.Gauge memory g = boost.gauge(handler.id());
        uint256 accounted = uint256(g.paid) + _owed() + _pending() + g.unassigned + g.scheduled;
        assertLe(accounted, g.funded, "paid + owed + pending + unassigned + scheduled <= funded");
        assertLe(g.funded - accounted, DUST, "only rounding dust is unaccounted");
        assertEq(g.paid, handler.totalClaimed(), "paid equals what the claims paid");
    }

    function invariant_balanceCoversFundedMinusPaid() public view {
        IHookrLpBoost.Gauge memory g = boost.gauge(handler.id());
        assertGe(IERC20(g.terms.rewardToken).balanceOf(address(boost)), uint256(g.funded) - g.paid);
    }

    function invariant_onePositionStakedOnce() public view {
        assertFalse(handler.duplicateAccepted(), "a staked position was staked again");
        uint256 live = handler.liveCount();
        for (uint256 i; i < live; ++i) {
            for (uint256 j = i + 1; j < live; ++j) {
                assertTrue(handler.live(i) != handler.live(j), "one position, one stake");
            }
        }
    }

    function invariant_custody() public view {
        uint256 live = handler.liveCount();
        assertEq(IERC721Balance(address(posm)).balanceOf(address(boost)), live, "NFTs held equal positions staked");
        for (uint256 i; i < live; ++i) {
            uint256 tokenId = handler.live(i);
            assertEq(posm.ownerOf(tokenId), address(boost));
            assertTrue(boost.stakeOf(tokenId).owner != address(0));
            assertEq(boost.stakeOf(tokenId).liquidity, posm.getPositionLiquidity(tokenId), "liquidity unchanged");
        }
        uint256 gone = handler.withdrawnCount();
        for (uint256 i; i < gone; ++i) {
            uint256 tokenId = handler.withdrawn(i);
            assertEq(posm.ownerOf(tokenId), handler.withdrawnTo(tokenId));
            assertEq(boost.stakeOf(tokenId).owner, address(0));
        }
    }

    function invariant_weightsAndDrops() public view {
        PoolId id_ = handler.id();
        IHookrLpBoost.Gauge memory g = boost.gauge(id_);
        uint256 live = handler.liveCount();
        uint256 total;
        for (uint256 i; i < live; ++i) {
            IHookrLpBoost.Stake memory s = boost.stakeOf(handler.live(i));
            uint256 boosted = uint256(s.liquidity) * s.boostBps / 10_000;
            total += s.maturity > g.lastUpdate ? boosted : s.liquidity;
            if (s.maturity > g.lastUpdate) {
                // Every boost part still ahead sits in its maturity's drop.
                uint256 due;
                for (uint256 j; j < live; ++j) {
                    IHookrLpBoost.Stake memory t = boost.stakeOf(handler.live(j));
                    if (t.maturity == s.maturity) due += uint256(t.liquidity) * t.boostBps / 10_000 - t.liquidity;
                }
                (uint256 drop,) = boost.weekState(id_, s.maturity);
                assertEq(drop, due, "drop table");
            } else {
                (uint256 drop,) = boost.weekState(id_, s.maturity);
                assertEq(drop, 0, "a passed drop is cleared");
            }
        }
        assertEq(g.totalWeight, total, "total weight");
        assertLe(g.lastDropWeek, g.lastUpdate + 106 weeks, "drops stay within the walk's reach");
    }

    function invariant_noAccrualOutOfRangeOrAfterTheEnd() public view {
        assertFalse(handler.accruedOutOfRange(), "an interval out of the usable range accrued");
        assertFalse(handler.accruedAfterEnd(), "an interval after the last tranche's end emitted");
        assertFalse(handler.emissionMisrouted(), "an interval's emission went to the wrong side");
    }

    /// @dev The sizing rule: a stake at the gauge's minLiquidity would own more of a pool token than exists on either
    ///      edge of the usable range, so the price is outside it only while nothing is staked.
    function invariant_outOfRangeOnlyWithNothingStaked() public view {
        if (!handler.inUsableRange()) assertEq(boost.gauge(handler.id()).totalWeight, 0, "staked out of range");
    }

    /// @dev Every tranche runs as it started, whatever was notified or funded after it: the gauge's rate is the sum of
    ///      its live tranches' rates, each boundary ahead removes exactly the rates of the tranches ending there, the
    ///      latest end is periodFinish, and what the gauge has emitted (every tranche's amount less what is scheduled)
    ///      is what each tranche emits evenly from its start to its end, to within rounding.
    function invariant_tranchesRunAsStarted() public view {
        IHookrLpBoost.Gauge memory g = boost.gauge(handler.id());
        uint256 n = handler.trancheCount();
        uint256 rate;
        uint256 latest;
        uint256 amounts;
        uint256 model;
        for (uint256 i; i < n; ++i) {
            uint256[4] memory t = handler.tranche(i);
            amounts += t[2];
            if (t[1] > latest) latest = t[1];
            uint256 end = g.lastUpdate < t[1] ? g.lastUpdate : t[1];
            model += FullMath.mulDiv(t[2], end - t[0], t[1] - t[0]);
            if (t[1] <= g.lastUpdate) continue;
            rate += t[3];
            uint256 ending;
            for (uint256 j; j < n; ++j) {
                uint256[4] memory u = handler.tranche(j);
                if (u[1] == t[1]) ending += u[3];
            }
            assertEq(boost.endingRate(handler.id(), t[1]), ending, "a boundary removes its tranches' rates");
        }
        assertEq(g.rewardRateX128, rate, "the rate is the live tranches'");
        assertEq(g.periodFinish, latest, "periodFinish is the latest end");
        uint256 emitted = amounts - g.scheduled;
        assertLe(emitted, model + n + 1, "never ahead of the tranches");
        assertLe(model, emitted + DUST, "behind them by rounding only");
    }

    function invariant_nothingScheduledAfterThePeriod() public view {
        IHookrLpBoost.Gauge memory g = boost.gauge(handler.id());
        if (g.lastUpdate >= g.periodFinish) assertEq(g.scheduled, 0);
    }

    function invariant_owedFallsOnlyByItsClaim() public view {
        assertFalse(handler.owedFell());
    }

    function _owed() internal view returns (uint256 sum) {
        PoolId id_ = handler.id();
        for (uint256 i; i < handler.actorCount(); ++i) {
            sum += boost.owed(id_, handler.actors(i));
        }
    }

    function _pending() internal view returns (uint256 sum) {
        for (uint256 i; i < handler.liveCount(); ++i) {
            sum += boost.pendingRewards(handler.live(i));
        }
    }
}

/// @notice The invariants on the fixture's deep pool, its gauge's minLiquidity FLOOR: stakes of 10^15 to 10^22
///         liquidity, the price within ticks -50,000 to 50,000.
contract HookrLpBoostInvariantTest is HookrLpBoostInvariantBase {
    function setUp() public override {
        super.setUp();
        _appointGuardian();
        handler = new HookrLpBoostHandler(boost, posm, swapper, key, permit2, gov, guardian, 1e22, false);
        _target(1e18, 1e28, 1e26);
    }
}

/// @notice The invariants on a thin pool of the small tokens (10^25 supplies, tick spacing 200, a 10^9 launch
///         position, a gauge whose minLiquidity is MIN_LIQUIDITY, stakes of 10^6 to 10^8 liquidity) whose price the
///         handler aims at every tick from MIN_TICK + 1 to MAX_TICK - 1 with all it holds of the paying token, most of
///         the supply: the run opens with stakes in the pool, and their positions stay in it after withdrawal, so the
///         sizing rule keeps the tick inside the usable range throughout.
contract HookrLpBoostThinPoolInvariantTest is HookrLpBoostInvariantBase {
    function setUp() public override {
        super.setUp();
        _appointGuardian();
        (, PoolKey memory thin) = _launchSmall(1e9, 200, 3000);
        boost.createGauge(thin, _terms(4, 52, 30_000, LEAST_LIQUIDITY));
        handler = new HookrLpBoostHandler(boost, posm, swapper, thin, permit2, gov, guardian, 1e8, true);
        _target(1e7, 9e24, 1e24);
    }
}
