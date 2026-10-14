// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookrLpBoost} from "../../src/periphery/HookrLpBoost.sol";
import {IHookrLpBoost} from "../../src/interfaces/IHookrLpBoost.sol";
import {IPositionManagerTest, IPermit2Approve} from "../periphery/LpBoostFixture.sol";

/// @notice Drives one HookrLpBoost gauge through stakes, repeated stakes of staked positions, extensions, withdrawals,
///         notifies, fundings, claims, fee collections, brakes, price moves and time, and keeps the ghost state the
///         invariants read, every tranche started included. Every action checks its own preconditions, so any revert it
///         meets is a finding; each ends with a poke, so the invariants read a gauge brought to now. Time only moves in
///         `_advance`, which checks the update it causes: an interval accrues to the stakes only while the pool's tick
///         is in the usable range and the gauge has weight, and nothing at all once the last tranche has ended. A wide
///         handler aims the price at any tick of the whole tick range, past the usable range too, with everything it
///         holds of the paying token. Pool tokens only ever move by transfer from the supply the suite seeded, never by
///         `deal`: a dealt balance is supply that does not exist, which the sizing rule rests on.
contract HookrLpBoostHandler is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant WEEK = 7 days;
    uint256 internal constant Q128 = 1 << 128;
    uint256 internal constant MAX_LIVE = 24;
    uint8 internal constant MINT_POSITION = 0x02;
    uint8 internal constant SETTLE_PAIR = 0x0d;

    HookrLpBoost public immutable boost;
    IPositionManagerTest public immutable posm;
    PoolSwapTest public immutable swapper;
    IERC20 public immutable reward;
    address public immutable gov;
    address public immutable guardian;
    PoolId public immutable id;
    uint128 public immutable minLiquidity;
    uint128 public immutable maxLiquidity;
    bool public immutable wide;
    PoolKey internal _key;

    address[4] public actors;
    uint256[] public live;
    mapping(uint256 tokenId => address) public withdrawnTo;
    uint256[] public withdrawn;
    mapping(address actor => uint256) public lastOwed;
    mapping(address actor => uint256) public claimedBy;
    bool public owedFell;
    bool public duplicateAccepted;
    bool public accruedOutOfRange;
    bool public emissionMisrouted;
    bool public accruedAfterEnd;
    uint256 public totalClaimed;
    /// @dev Every tranche a notify or a fund started: its start, its end, its amount and the rate it was given.
    uint256[4][] internal _tranches;
    mapping(bytes32 action => uint256) public calls;

    constructor(
        HookrLpBoost boost_,
        IPositionManagerTest posm_,
        PoolSwapTest swapper_,
        PoolKey memory key_,
        address permit2,
        address gov_,
        address guardian_,
        uint128 maxLiquidity_,
        bool wide_
    ) {
        boost = boost_;
        posm = posm_;
        swapper = swapper_;
        _key = key_;
        id = key_.toId();
        reward = IERC20(boost_.gauge(id).terms.rewardToken);
        minLiquidity = boost_.gauge(id).terms.minLiquidity;
        gov = gov_;
        guardian = guardian_;
        maxLiquidity = maxLiquidity_;
        wide = wide_;
        actors = [makeAddr("lp0"), makeAddr("lp1"), makeAddr("lp2"), makeAddr("lp3")];
        address token0 = Currency.unwrap(key_.currency0);
        address token1 = Currency.unwrap(key_.currency1);
        for (uint256 i; i < actors.length; ++i) {
            vm.startPrank(actors[i]);
            IERC20(token0).approve(permit2, type(uint256).max);
            IERC20(token1).approve(permit2, type(uint256).max);
            IPermit2Approve(permit2).approve(token0, address(posm_), type(uint160).max, type(uint48).max);
            IPermit2Approve(permit2).approve(token1, address(posm_), type(uint160).max, type(uint48).max);
            vm.stopPrank();
        }
    }

    /// @dev Gives every actor `perActor` of each pool token from what the suite transferred here; called once after
    ///      deployment by the suite, which holds the supplies.
    function seed(uint256 perActor) external {
        address token0 = Currency.unwrap(_key.currency0);
        address token1 = Currency.unwrap(_key.currency1);
        for (uint256 i; i < actors.length; ++i) {
            IERC20(token0).transfer(actors[i], perActor);
            IERC20(token1).transfer(actors[i], perActor);
        }
        IERC20(token0).approve(address(swapper), type(uint256).max);
        IERC20(token1).approve(address(swapper), type(uint256).max);
    }

    modifier settles() {
        _;
        boost.poke(id);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Actions
    // ------------------------------------------------------------------------------------------------------------

    function stake(uint256 actorSeed, uint256 liquiditySeed, uint256 lockSeed) external settles {
        if (live.length >= MAX_LIVE || _paused()) return;
        address actor = actors[actorSeed % actors.length];
        uint128 liquidity = uint128(bound(liquiditySeed, minLiquidity, maxLiquidity));
        uint16 lockWeeks = uint16(bound(lockSeed, 4, 52));
        if (!_cover(actor, liquidity)) return;
        uint256 tokenId = posm.nextTokenId();
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            _key,
            TickMath.minUsableTick(_key.tickSpacing),
            TickMath.maxUsableTick(_key.tickSpacing),
            uint256(liquidity),
            type(uint128).max,
            type(uint128).max,
            actor,
            bytes("")
        );
        params[1] = abi.encode(_key.currency0, _key.currency1);
        uint256 deadline = vm.getBlockTimestamp();
        vm.prank(actor);
        posm.modifyLiquidities(abi.encode(abi.encodePacked(MINT_POSITION, SETTLE_PAIR), params), deadline);
        _before();
        vm.startPrank(actor);
        posm.approve(address(boost), tokenId);
        boost.stake(tokenId, lockWeeks);
        vm.stopPrank();
        live.push(tokenId);
        _after(address(0));
        ++calls["stake"];
    }

    /// @dev Stakes a staked position again, as its staker and as the gauge itself (the one caller custody alone would
    ///      let through): both must be refused, AlreadyStaked once the position's pool and gauge checks pass.
    function stakeAgain(uint256 indexSeed, uint256 lockSeed) external settles {
        if (live.length == 0) return;
        uint256 tokenId = live[indexSeed % live.length];
        uint16 lockWeeks = uint16(bound(lockSeed, 4, 52));
        address[2] memory callers = [boost.stakeOf(tokenId).owner, address(boost)];
        bytes4 expected = boost.pausedAll()
            ? IHookrLpBoost.AllPaused.selector
            : boost.gauge(id).paused ? IHookrLpBoost.GaugeIsPaused.selector : IHookrLpBoost.AlreadyStaked.selector;
        _before();
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            try boost.stake(tokenId, lockWeeks) {
                duplicateAccepted = true;
            } catch (bytes memory err) {
                if (bytes4(err) != expected) duplicateAccepted = true;
            }
        }
        _after(address(0));
        ++calls["stakeAgain"];
    }

    function extend(uint256 indexSeed, uint256 lockSeed) external settles {
        if (live.length == 0 || _paused()) return;
        uint256 tokenId = live[indexSeed % live.length];
        IHookrLpBoost.Stake memory s = boost.stakeOf(tokenId);
        uint16 lockWeeks = uint16(bound(lockSeed, 4, 52));
        uint256 clock = _clock();
        uint256 maturity = (clock + uint256(lockWeeks) * WEEK + WEEK - 1) / WEEK * WEEK;
        if (maturity <= s.maturity) return;
        _before();
        vm.prank(s.owner);
        boost.extend(tokenId, lockWeeks);
        _after(address(0));
        ++calls["extend"];
    }

    /// @dev Withdraws the first matured stake from a random start.
    function withdraw(uint256 indexSeed) external settles {
        uint256 n = live.length;
        uint256 index = type(uint256).max;
        for (uint256 k; k < n; ++k) {
            uint256 candidate = (indexSeed % n + k) % n;
            if (_clock() >= boost.stakeOf(live[candidate]).maturity) {
                index = candidate;
                break;
            }
        }
        if (index == type(uint256).max) return;
        uint256 tokenId = live[index];
        IHookrLpBoost.Stake memory s = boost.stakeOf(tokenId);
        _before();
        vm.prank(s.owner);
        boost.withdraw(tokenId, s.owner);
        live[index] = live[live.length - 1];
        live.pop();
        withdrawnTo[tokenId] = s.owner;
        withdrawn.push(tokenId);
        _after(address(0));
        ++calls["withdraw"];
    }

    /// @dev A notify of any amount, the unassigned remainder rolled in, over any length: it starts a tranche beside the
    ///      running ones and nothing refuses it but a tranche of nothing.
    function notify(uint256 amountSeed, uint256 weeksSeed) external settles {
        if (_paused()) return;
        uint256 amount = bound(amountSeed, 0, 1e24);
        uint16 weeks_ = uint16(bound(weeksSeed, 1, 52));
        uint256 budget = amount + boost.gauge(id).unassigned;
        deal(address(reward), gov, amount);
        _before();
        vm.startPrank(gov);
        reward.approve(address(boost), amount);
        if (budget == 0) {
            vm.expectRevert(IHookrLpBoost.ZeroAmount.selector);
            boost.notify(id, amount, weeks_);
            ++calls["notifyEmpty"];
        } else {
            boost.notify(id, amount, weeks_);
            _record(budget, weeks_);
            ++calls["notify"];
        }
        vm.stopPrank();
        _after(address(0));
    }

    /// @dev Anyone funds a tranche of any amount over any length.
    function fund(uint256 amountSeed, uint256 weeksSeed) external settles {
        if (_paused()) return;
        uint256 amount = bound(amountSeed, 1, 1e24);
        uint16 weeks_ = uint16(bound(weeksSeed, 1, 52));
        address funder = actors[amountSeed % actors.length];
        deal(address(reward), funder, reward.balanceOf(funder) + amount);
        _before();
        vm.startPrank(funder);
        reward.approve(address(boost), amount);
        boost.fund(id, amount, weeks_);
        vm.stopPrank();
        _record(amount, weeks_);
        _after(address(0));
        ++calls["fund"];
    }

    function claim(uint256 actorSeed) external settles {
        if (_paused()) return;
        address actor = actors[actorSeed % actors.length];
        uint256 n;
        for (uint256 i; i < live.length; ++i) {
            if (boost.stakeOf(live[i]).owner == actor) ++n;
        }
        uint256[] memory ids = new uint256[](n);
        uint256 j;
        uint256 pending;
        for (uint256 i; i < live.length; ++i) {
            if (boost.stakeOf(live[i]).owner == actor) {
                ids[j++] = live[i];
                pending += boost.pendingRewards(live[i]);
            }
        }
        uint256 expected = boost.owed(id, actor) + pending;
        _before();
        vm.prank(actor);
        uint256 paid = boost.claim(id, ids, actor);
        assertEq(paid, expected, "claim pays owed plus pending");
        claimedBy[actor] += paid;
        totalClaimed += paid;
        _after(actor);
        ++calls["claim"];
    }

    function collectFees(uint256 indexSeed) external settles {
        if (live.length == 0) return;
        uint256 tokenId = live[indexSeed % live.length];
        address owner = boost.stakeOf(tokenId).owner;
        _before();
        vm.prank(owner);
        boost.collectFees(tokenId, owner);
        _after(address(0));
        ++calls["collectFees"];
    }

    function poke() external {
        _before();
        boost.poke(id);
        _after(address(0));
        ++calls["poke"];
    }

    /// @dev Moves time by up to two weeks, or every other call by up to 40 weeks, so runs cross maturities inside one
    ///      update and spend time past the period's end.
    function warp(uint256 secondsSeed) external {
        _advance(bound(secondsSeed / 2, 0, secondsSeed % 2 == 0 ? 40 weeks : 2 weeks));
        ++calls["warp"];
    }

    /// @dev Moves the price to a random tick within [-50,000, 50,000]. A wide handler aims a third of its moves below
    ///      the usable range, a third above it and a third anywhere inside it, paying in all it holds of the token it
    ///      sells: with a stake at the gauge's minLiquidity in the pool, the sizing rule stops it inside the band.
    function swap(uint256 tickSeed) external settles {
        int24 tick;
        if (wide) {
            int256 lower = TickMath.minUsableTick(_key.tickSpacing);
            int256 upper = TickMath.maxUsableTick(_key.tickSpacing);
            int256 r = int256(tickSeed / 3);
            uint256 region = tickSeed % 3;
            if (region == 0) tick = int24(bound(r, TickMath.MIN_TICK + 1, lower - 1));
            else if (region == 1) tick = int24(bound(r, upper, TickMath.MAX_TICK - 1));
            else tick = int24(bound(r, lower, upper - 1));
        } else {
            tick = int24(int256(bound(tickSeed, 0, 100_000))) - 50_000;
        }
        uint160 target = TickMath.getSqrtPriceAtTick(tick);
        (uint160 price,,,) = boost.poolManager().getSlot0(id);
        if (target == price) return;
        bool zeroForOne = target < price;
        uint256 amountIn = 1e26;
        if (wide) {
            amountIn = IERC20(Currency.unwrap(zeroForOne ? _key.currency0 : _key.currency1)).balanceOf(address(this));
            if (amountIn == 0) return;
        }
        swapper.swap(
            _key, SwapParams(zeroForOne, -int256(amountIn), target), PoolSwapTest.TestSettings(false, false), ""
        );
        ++calls["swap"];
        if (!_inRange()) ++calls["swapOutOfRange"];
    }

    /// @dev Brakes one call in eight, so most of a run trades with the gauge open.
    function pause(uint256 seed_) external settles {
        if (seed_ % 8 != 0 || boost.gauge(id).paused) return;
        vm.prank(guardian);
        boost.pause(id);
        ++calls["pause"];
    }

    function unpause() external settles {
        if (!boost.gauge(id).paused) return;
        bytes32 kind = boost.UNPAUSE();
        vm.prank(gov);
        boost.queue(kind, abi.encode(id));
        _advance(boost.delay());
        vm.prank(gov);
        boost.unpause(id);
        ++calls["unpause"];
    }

    /// @dev After a run: lifts a pause, waits out every maturity and tranche, then every staker withdraws and
    ///      claims. Called by the suite's afterInvariant, never by the fuzzer.
    function liveness() external {
        if (boost.gauge(id).paused) {
            bytes32 kind = boost.UNPAUSE();
            uint256 delay = boost.delay();
            vm.prank(gov);
            boost.queue(kind, abi.encode(id));
            vm.warp(vm.getBlockTimestamp() + delay);
            vm.prank(gov);
            boost.unpause(id);
        }
        uint256 end = boost.gauge(id).periodFinish;
        for (uint256 i; i < live.length; ++i) {
            uint256 maturity = boost.stakeOf(live[i]).maturity;
            if (maturity > end) end = maturity;
        }
        if (end > vm.getBlockTimestamp()) vm.warp(end);
        boost.poke(id);
        while (live.length != 0) {
            uint256 tokenId = live[live.length - 1];
            address owner = boost.stakeOf(tokenId).owner;
            vm.prank(owner);
            boost.withdraw(tokenId, owner);
            live.pop();
            withdrawnTo[tokenId] = owner;
            withdrawn.push(tokenId);
        }
        uint256[] memory none = new uint256[](0);
        for (uint256 i; i < actors.length; ++i) {
            uint256 owed = boost.owed(id, actors[i]);
            vm.prank(actors[i]);
            uint256 paid = boost.claim(id, none, actors[i]);
            assertEq(paid, owed, "liveness claim");
            totalClaimed += paid;
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // Views for the invariants
    // ------------------------------------------------------------------------------------------------------------

    function liveCount() external view returns (uint256) {
        return live.length;
    }

    function withdrawnCount() external view returns (uint256) {
        return withdrawn.length;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function key() external view returns (PoolKey memory) {
        return _key;
    }

    function inUsableRange() external view returns (bool) {
        return _inRange();
    }

    function trancheCount() external view returns (uint256) {
        return _tranches.length;
    }

    /// @dev The `index`th tranche started: its start, its end, its amount and its rate.
    function tranche(uint256 index) external view returns (uint256[4] memory) {
        return _tranches[index];
    }

    // ------------------------------------------------------------------------------------------------------------
    // Time and ghost bookkeeping
    // ------------------------------------------------------------------------------------------------------------

    /// @dev Moves time by `elapsed` and brings the gauge to it, then checks that update. Nothing else moves while time
    ///      does, so the tick read now is the pool's tick for the whole interval: out of the usable range, or with no
    ///      weight, the interval's emission goes wholly to the unassigned remainder and the accumulator stands still;
    ///      in range with weight, the remainder stands still; from the last tranche's end on nothing emits.
    function _advance(uint256 elapsed) internal {
        IHookrLpBoost.Gauge memory g0 = boost.gauge(id);
        bool inRange = _inRange();
        _before();
        vm.warp(vm.getBlockTimestamp() + elapsed);
        boost.poke(id);
        _after(address(0));
        IHookrLpBoost.Gauge memory g1 = boost.gauge(id);
        uint256 emitted = g0.scheduled - g1.scheduled;
        bool accrued = g1.rewardPerWeightX128 != g0.rewardPerWeightX128;
        if (!inRange) {
            if (accrued || g1.unassigned != g0.unassigned + emitted) accruedOutOfRange = true;
            if (emitted != 0) ++calls["intervalOutOfRange"];
        } else if (g0.totalWeight == 0) {
            if (accrued || g1.unassigned != g0.unassigned + emitted) emissionMisrouted = true;
        } else if (g1.unassigned != g0.unassigned) {
            emissionMisrouted = true;
        }
        if (g0.lastUpdate >= g0.periodFinish) {
            if (emitted != 0 || accrued || g1.unassigned != g0.unassigned) accruedAfterEnd = true;
            if (elapsed != 0) ++calls["intervalAfterEnd"];
        }
    }

    /// @dev Records the tranche of `amount` the gauge just started at its clock, `weeks_` weeks rounded up to a week
    ///      boundary, with the rate the gauge gives it: amount x 2^128 / its length, rounded down.
    function _record(uint256 amount, uint16 weeks_) internal {
        uint256 start = boost.gauge(id).lastUpdate;
        uint256 finish = (start + uint256(weeks_) * WEEK + WEEK - 1) / WEEK * WEEK;
        _tranches.push([start, finish, amount, FullMath.mulDiv(amount, Q128, finish - start)]);
    }

    function _before() internal {
        for (uint256 i; i < actors.length; ++i) {
            lastOwed[actors[i]] = boost.owed(id, actors[i]);
        }
    }

    /// @dev Owed amounts may only fall through their owner's claim.
    function _after(address claimant) internal {
        for (uint256 i; i < actors.length; ++i) {
            address a = actors[i];
            if (a != claimant && boost.owed(id, a) < lastOwed[a]) owedFell = true;
        }
    }

    /// @dev Transfers `actor`, from this handler's own balances, what a full-range mint of `liquidity` at the current
    ///      price costs beyond what it holds (the PoolManager's amounts, rounded up); false, moving nothing more, once
    ///      this handler holds less than that.
    function _cover(address actor, uint128 liquidity) internal returns (bool) {
        (uint160 price,,,) = boost.poolManager().getSlot0(id);
        uint160 lower = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(_key.tickSpacing));
        uint160 upper = TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(_key.tickSpacing));
        uint160 inside = price < lower ? lower : price > upper ? upper : price;
        uint256[2] memory cost = [
            SqrtPriceMath.getAmount0Delta(inside, upper, liquidity, true),
            SqrtPriceMath.getAmount1Delta(lower, inside, liquidity, true)
        ];
        IERC20[2] memory tokens = [IERC20(Currency.unwrap(_key.currency0)), IERC20(Currency.unwrap(_key.currency1))];
        for (uint256 i; i < 2; ++i) {
            uint256 held = tokens[i].balanceOf(actor);
            if (held >= cost[i]) continue;
            if (tokens[i].balanceOf(address(this)) < cost[i] - held) return false;
            tokens[i].transfer(actor, cost[i] - held);
        }
        return true;
    }

    function _inRange() internal view returns (bool) {
        (, int24 tick,,) = boost.poolManager().getSlot0(id);
        return tick >= TickMath.minUsableTick(_key.tickSpacing) && tick < TickMath.maxUsableTick(_key.tickSpacing);
    }

    function _paused() internal view returns (bool) {
        return boost.pausedAll() || boost.gauge(id).paused;
    }

    function _clock() internal view returns (uint256) {
        uint256 last = boost.gauge(id).lastUpdate;
        return vm.getBlockTimestamp() > last ? vm.getBlockTimestamp() : last;
    }
}
