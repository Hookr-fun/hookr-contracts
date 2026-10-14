// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookrLpBoost} from "../../src/periphery/HookrLpBoost.sol";
import {IHookrLpBoost} from "../../src/interfaces/IHookrLpBoost.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrLauncherView} from "../../src/interfaces/IHookrLauncherView.sol";
import {IPositionManagerMinimal} from "../../src/interfaces/external/IPositionManagerMinimal.sol";
import {MockFeeOnTransferToken} from "../mocks/MockFeeOnTransferToken.sol";
import {MockFlashMintToken} from "../mocks/MockFlashMintToken.sol";
import {MockHookToken} from "../mocks/MockHookToken.sol";
import {MockRebasingToken} from "../mocks/MockRebasingToken.sol";
import {Chain4663Code} from "../bench/Chain4663Code.sol";
import {LpBoostFixture, NoopSubscriber} from "./LpBoostFixture.sol";

/// @notice A contract that cannot take an ERC-721 (no onERC721Received) or ETH (no receive).
contract Inert {}

/// @notice An ERC-721 receiver and ETH receiver that calls back into a target and records the outcome.
contract Reenterer {
    address public target;
    bytes public data;
    uint256 public calls;
    bool public lastSucceeded;
    bytes public lastResult;

    function arm(address target_, bytes calldata data_) external {
        target = target_;
        data = data_;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        _reenter();
        return this.onERC721Received.selector;
    }

    receive() external payable {
        _reenter();
    }

    function _reenter() private {
        if (target == address(0)) return;
        ++calls;
        (lastSucceeded, lastResult) = target.call(data);
    }
}

/// @notice A PositionManager stand-in that answers whatever it is told and reports the real PoolManager.
contract FakePositionManager {
    IPoolManager public immutable poolManager;
    PoolKey internal _key;
    uint256 internal _info;
    address internal _owner;
    uint128 internal _liquidity;

    constructor(IPoolManager manager) {
        poolManager = manager;
    }

    function set(PoolKey calldata key_, uint256 info_, address owner_, uint128 liquidity_) external {
        _key = key_;
        _info = info_;
        _owner = owner_;
        _liquidity = liquidity_;
    }

    function ownerOf(uint256) external view returns (address) {
        return _owner;
    }

    function getPoolAndPositionInfo(uint256) external view returns (PoolKey memory, uint256) {
        return (_key, _info);
    }

    function getPositionLiquidity(uint256) external view returns (uint128) {
        return _liquidity;
    }

    function transferFrom(address, address, uint256) external {}
}

/// @notice Anyone's flash round trip past a pool's usable range (time-0-2's PoC): inside one PoolManager unlock it
///         swaps the price past the last usable tick, pokes the gauge if asked, swaps the price back to where it
///         started and settles the net, which is only the swap fees and rounding. It holds no position and only dust of
///         the pool's tokens, and records the tick inside the unlock.
contract FlashRangeWiper is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    HookrLpBoost public immutable boost;
    int24 public tickInside;

    constructor(IPoolManager manager_, HookrLpBoost boost_) {
        manager = manager_;
        boost = boost_;
    }

    function roundTrip(PoolKey calldata key, bool pokeInside) external {
        manager.unlock(abi.encode(key, pokeInside));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager");
        (PoolKey memory key, bool pokeInside) = abi.decode(data, (PoolKey, bool));
        PoolId id = key.toId();
        (uint160 start,,,) = manager.getSlot0(id);
        // Up past maxUsableTick, the gauge brought to now if asked, back down to the starting price.
        manager.swap(key, SwapParams(false, -int256(1e38), TickMath.MAX_SQRT_PRICE - 1), "");
        (, tickInside,,) = manager.getSlot0(id);
        if (pokeInside) boost.poke(id);
        manager.swap(key, SwapParams(true, -int256(1e38), start), "");
        _settle(key.currency0);
        _settle(key.currency1);
        return "";
    }

    function _settle(Currency currency) private {
        int256 delta = manager.currencyDelta(address(this), currency);
        if (delta < 0) {
            manager.sync(currency);
            IERC20(Currency.unwrap(currency)).transfer(address(manager), uint256(-delta));
            manager.settle();
        } else if (delta > 0) {
            manager.take(currency, address(this), uint256(delta));
        }
    }
}

/// @notice Anyone's settled round trip toward the edge of a pool's usable range with no PoolManager unlock open at the
///         poke (time-1-2's PoC): one ordinary settled swap of everything it holds of currency1 toward
///         MAX_SQRT_PRICE, `poke` while the PoolManager is locked, and one settled swap back to the exact starting
///         price. It needs the input only for the length of one transaction; in a pool that charges nothing per swap
///         the round trip nets to rounding. It records the tick its poke saw.
contract SettledRangeWiper {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    PoolSwapTest public immutable swapper;
    HookrLpBoost public immutable boost;
    bool public pokedWhileLocked;
    int24 public tickAtPoke;

    constructor(IPoolManager manager_, PoolSwapTest swapper_, HookrLpBoost boost_) {
        manager = manager_;
        swapper = swapper_;
        boost = boost_;
    }

    function wipe(PoolKey calldata key) external {
        PoolId id = key.toId();
        IERC20 t0 = IERC20(Currency.unwrap(key.currency0));
        IERC20 t1 = IERC20(Currency.unwrap(key.currency1));
        t0.approve(address(swapper), type(uint256).max);
        t1.approve(address(swapper), type(uint256).max);
        (uint160 start,,,) = manager.getSlot0(id);
        swapper.swap(
            key,
            SwapParams(false, -int256(t1.balanceOf(address(this))), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        pokedWhileLocked = !manager.isUnlocked();
        (, tickAtPoke,,) = manager.getSlot0(id);
        boost.poke(id);
        swapper.swap(
            key,
            SwapParams(true, -int256(t0.balanceOf(address(this))), start),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }
}

/// @notice An outsider holding dust (time-1-1's PoC): it flash-mints the pool's flash-mintable currency, no PoolManager
///         unlock open, swaps it in past the usable range with an ordinary settled swap, pokes the gauge while the
///         PoolManager is locked, swaps back with everything the first swap paid out, and burns the mint back before
///         the call returns. It records the tick its poke saw.
contract FlashMintRangeWiper is IERC3156FlashBorrower {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    PoolSwapTest public immutable swapper;
    HookrLpBoost public immutable boost;
    bool public pokedWhileLocked;
    int24 public tickAtPoke;

    constructor(IPoolManager manager_, PoolSwapTest swapper_, HookrLpBoost boost_) {
        manager = manager_;
        swapper = swapper_;
        boost = boost_;
    }

    function wipe(PoolKey calldata key, MockFlashMintToken token, uint256 amount) external {
        token.flashLoan(this, address(token), amount, abi.encode(key));
    }

    function onFlashLoan(address, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        returns (bytes32)
    {
        require(msg.sender == token, "token");
        PoolKey memory key = abi.decode(data, (PoolKey));
        PoolId id = key.toId();
        IERC20 t0 = IERC20(Currency.unwrap(key.currency0));
        IERC20 t1 = IERC20(Currency.unwrap(key.currency1));
        t0.approve(address(swapper), type(uint256).max);
        t1.approve(address(swapper), type(uint256).max);
        (uint160 start,,,) = manager.getSlot0(id);
        bool flashIsZero = address(t0) == token;
        swapper.swap(
            key,
            SwapParams(
                flashIsZero, -int256(amount), flashIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        pokedWhileLocked = !manager.isUnlocked();
        (, tickAtPoke,,) = manager.getSlot0(id);
        boost.poke(id);
        IERC20 other = flashIsZero ? t1 : t0;
        swapper.swap(
            key,
            SwapParams(!flashIsZero, -int256(other.balanceOf(address(this))), start),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        IERC20(token).approve(token, amount + fee);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}

/// @notice HookrToken's runtime code deployed by other initcode: this constructor writes `reportedSupply` as the
///         totalSupply and `held` as `holder`'s balance, which HookrToken's own constructor never would, and returns
///         HookrToken's runtime. The contract has every HookrToken's codehash, yet its totalSupply is not what its
///         holders hold.
contract HookrTokenCodeWithOtherStorage {
    constructor(bytes memory runtime, uint256 reportedSupply, address holder, uint256 held) {
        assembly ("memory-safe") {
            // HookrToken's storage: _balances at slot 0, _totalSupply at slot 2.
            sstore(2, reportedSupply)
            mstore(0x00, holder)
            mstore(0x20, 0)
            sstore(keccak256(0x00, 0x40), held)
            return(add(runtime, 0x20), mload(runtime))
        }
    }
}

/// @notice Attacks on HookrLpBoost: time manipulation, flash stakes and withdrawals, duplicate and unsolicited
///         deposits, range and the sizing rule, a pool currency minted for the length of one call, a supply bound that
///         fails, updates inside a PoolManager unlock, failed withdrawals, position verification, reentrancy through
///         the position NFT and the reward token, fee-on-transfer and rebasing reward tokens, donations to the
///         accumulator and the pool, dust stakes below a gauge's minLiquidity, and a position's liquidity changing
///         while staked.
contract HookrLpBoostAttacksTest is LpBoostFixture, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    uint256 internal constant Q128 = 1 << 128;

    // ------------------------------------------------------------------------------------------------------------
    // Time manipulation
    // ------------------------------------------------------------------------------------------------------------

    function test_time_warpFarPastThePeriodEndEmitsExactlyTheBudget() public {
        uint256 a = _mintAndStake(alice, 1e18, 4);
        uint256 b = _mintAndStake(bob, 5e17, 52);
        _notify(4e21, 4);
        vm.warp(vm.getBlockTimestamp() + 100 * 365 days);
        uint256 pa = boost.pendingRewards(a);
        uint256 pb = boost.pendingRewards(b);
        assertLe(pa + pb, 4e21);
        assertGe(pa + pb + 2, 4e21);
        assertEq(_claim(alice, a), pa);
        assertEq(_claim(bob, b), pb);
        IHookrLpBoost.Gauge memory g = boost.gauge(id);
        assertEq(g.scheduled, 0);
        assertEq(g.unassigned, 0);
        assertEq(g.paid, pa + pb);
        assertGe(reward.balanceOf(address(boost)), g.funded - g.paid);
    }

    function test_time_backwardTimestampIsNoElapsedTime() public {
        uint256 a = _mintAndStake(alice, 1e18, 4);
        _notify(4e21, 4);
        uint256 t1 = vm.getBlockTimestamp() + 1 weeks;
        vm.warp(t1);
        boost.poke(id);
        IHookrLpBoost.Gauge memory before = boost.gauge(id);
        uint256 pending = boost.pendingRewards(a);
        // A timestamp behind the gauge's clock accrues nothing and moves nothing back.
        vm.warp(t1 - 3 days);
        boost.poke(id);
        IHookrLpBoost.Gauge memory after_ = boost.gauge(id);
        assertEq(after_.lastUpdate, before.lastUpdate);
        assertEq(after_.rewardPerWeightX128, before.rewardPerWeightX128);
        assertEq(after_.scheduled, before.scheduled);
        assertEq(boost.pendingRewards(a), pending);
        // A lock taken then still counts from the gauge's clock, so its maturity stays ahead of the accrual walk.
        uint256 c = _mintAndStake(carol, 1e18, 4);
        assertGe(boost.stakeOf(c).maturity, t1 + 4 weeks);
        // Withdrawal follows the gauge's clock too: still locked.
        uint48 maturity = boost.stakeOf(c).maturity;
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.Locked.selector, c, maturity));
        boost.withdraw(c, carol);
        vm.warp(boost.stakeOf(c).maturity);
        vm.prank(carol);
        boost.withdraw(c, carol);
    }

    function test_time_maturitiesAcrossManyWeeksLandExactly() public {
        uint256 s4 = _mintAndStake(alice, 1e18, 4);
        uint256 s10 = _mintAndStake(bob, 1e18, 10);
        uint256 s28 = _mintAndStake(carol, 1e18, 28);
        uint256 s52 = _mintAndStake(mallory, 1e18, 52);
        assertEq(boost.stakeOf(s10).boostBps, 12_500);
        _notify(52e21, 52);
        // Nobody touches the gauge for 60 weeks: three boosts end inside the walk.
        vm.warp(vm.getBlockTimestamp() + 60 weeks);
        // Weights 1 + 1.25 + 2 + 3 = 7.25 for 10 weeks, 7 for 18 weeks, 6 for 24 weeks; 1e21 a week.
        uint256 e = 1e21;
        uint256[4] memory expected = [
            uint256(10 * e * 100 / 725 + 18 * e / 7 + 24 * e / 6),
            10 * e * 125 / 725 + 18 * e / 7 + 24 * e / 6,
            10 * e * 200 / 725 + 18 * e * 2 / 7 + 24 * e / 6,
            10 * e * 300 / 725 + 18 * e * 3 / 7 + 24 * e * 3 / 6
        ];
        uint256[4] memory ids = [s4, s10, s28, s52];
        address[4] memory owners = [alice, bob, carol, mallory];
        uint256 total;
        for (uint256 i; i < 4; ++i) {
            uint256 paid = _claim(owners[i], ids[i]);
            assertApproxEqAbs(paid, expected[i], 10, "stake");
            total += paid;
        }
        assertLe(total, 52e21);
        assertGe(total + 10, 52e21);
    }

    function testFuzz_time_emissionNeverAboveFunded(uint32[6] memory gaps, uint96[3] memory budgets, uint8 locks)
        public
    {
        uint256 a = _mintAndStake(alice, 1e18, uint16(4 + locks % 49));
        _notify(uint256(budgets[0]) + 1, 1 + uint16(budgets[0] % 52));
        uint256 b;
        for (uint256 i; i < gaps.length; ++i) {
            vm.warp(vm.getBlockTimestamp() + gaps[i] % 30 days);
            if (i == 1) b = _mintAndStake(bob, 3e18, uint16(4 + (locks >> 2) % 49));
            if (i == 2) _fund(sponsor, uint256(budgets[1]) + 1, 1 + uint16(budgets[1] % 52));
            if (i == 3) {
                // Nothing funded before refuses a notify: it goes through unless its tranche would hold nothing.
                boost.poke(id);
                bool empty = budgets[2] == 0 && boost.gauge(id).unassigned == 0;
                reward.approve(address(boost), budgets[2]);
                if (empty) vm.expectRevert(IHookrLpBoost.ZeroAmount.selector);
                boost.notify(id, budgets[2], 1 + uint16(budgets[2] % 52));
            }
            if (i == 4) _claim(alice, a);
            _checkSolvency(a, b);
        }
    }

    /// Small time frames: updating the gauge every second, before the period starts, across a maturity boundary and up
    /// to the period's end, pays what one update over the same span pays, to within rounding. Every update rounds its
    /// emission down and leaves the rest scheduled, so part way through a period a faster cadence never pays more than
    /// one update beyond that update's own rounding, and loses at most a unit per update; by the period's end the whole
    /// budget has emitted either way. Nothing accrues before the period starts, and the boost ends exactly at its week
    /// boundary whatever the cadence.
    function test_time_secondBySecondUpdatesPayWhatOneUpdatePays() public {
        uint256 a = _mintAndStake(alice, 1e18, 8);
        uint256 b = _mintAndStake(bob, 3e18, 52);
        uint48 maturity = boost.stakeOf(a).maturity;
        assertEq(maturity, vm.getBlockTimestamp() + 8 weeks, "staked on a week boundary: exactly eight weeks");
        uint256 boostedA = uint256(1e18) * boost.stakeOf(a).boostBps / 10_000;
        assertGt(boostedA, 1e18);
        // A poke every second for a minute before any period: nothing accrues and nothing is set aside.
        uint256 start = vm.getBlockTimestamp();
        for (uint256 t = start + 1; t <= start + 60; ++t) {
            vm.warp(t);
            boost.poke(id);
        }
        assertEq(boost.gauge(id).rewardPerWeightX128, 0);
        assertEq(boost.gauge(id).unassigned, 0);
        _notify(12e21, 12);
        uint256 finish = boost.gauge(id).periodFinish;
        uint256 snap = vm.snapshotState();

        // One update: the pending rewards ten minutes past the maturity, then the claims at the period's end.
        vm.warp(maturity + 600);
        uint256[2] memory midOne = [boost.pendingRewards(a), boost.pendingRewards(b)];
        vm.warp(finish);
        uint256[2] memory endOne = [_claim(alice, a), _claim(bob, b)];
        vm.revertToState(snap);

        // A poke every second for ten minutes on each side of the maturity boundary.
        uint256 pokes;
        uint256 weight = boost.gauge(id).totalWeight;
        for (uint256 t = maturity - 600; t <= maturity + 600; ++t) {
            vm.warp(t);
            boost.poke(id);
            ++pokes;
            (uint256 drop,) = boost.weekState(id, maturity);
            if (t < maturity) {
                assertEq(drop, boostedA - 1e18, "the drop waits for its boundary");
                assertEq(boost.gauge(id).totalWeight, weight);
            } else {
                assertEq(drop, 0, "the drop closed at the boundary");
                assertEq(boost.gauge(id).totalWeight, weight - (boostedA - 1e18), "exactly the boost left");
            }
        }
        // Part way through the period the cadence pays no more in all than one update beyond that update's rounding
        // (its two steps, split at the maturity, and the two stakes' shares), and each stake is within a unit per
        // update.
        uint256[2] memory midFine = [boost.pendingRewards(a), boost.pendingRewards(b)];
        assertLe(midFine[0] + midFine[1], midOne[0] + midOne[1] + 4, "never more in all");
        for (uint256 i; i < 2; ++i) {
            assertApproxEqAbs(midFine[i], midOne[i], pokes + 2, "within a unit per update");
        }
        // A poke every second for the period's last ten minutes, then the claims at its end.
        for (uint256 t = finish - 600; t <= finish; ++t) {
            vm.warp(t);
            boost.poke(id);
            ++pokes;
        }
        uint256[2] memory endFine = [_claim(alice, a), _claim(bob, b)];
        assertEq(boost.stakeOf(a).boostBps, 10_000, "the boost ended at the maturity");
        assertLe(endOne[0] + endOne[1], 12e21, "never above the budget");
        assertLe(endFine[0] + endFine[1], 12e21, "never above the budget");
        assertApproxEqAbs(endFine[0] + endFine[1], endOne[0] + endOne[1], 4, "the whole budget either way");
        for (uint256 i; i < 2; ++i) {
            assertApproxEqAbs(endFine[i], endOne[i], pokes + 2, "each stake's share to within rounding");
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // Flash stake and withdraw
    // ------------------------------------------------------------------------------------------------------------

    function test_flash_stakeAndWithdrawInOneBlockIsRefused() public {
        _notify(4e21, 4);
        uint256 a = _mintAndStake(alice, 1e24, 4);
        uint48 maturity = boost.stakeOf(a).maturity;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.Locked.selector, a, maturity));
        boost.withdraw(a, alice);
        // A claim in the same block pays nothing.
        assertEq(_claim(alice, a), 0);
    }

    function test_flash_lateStakeCapturesNoPastEmission() public {
        uint256 a = _mintAndStake(alice, 1e18, 4);
        _notify(4e21, 4);
        vm.warp(vm.getBlockTimestamp() + 2 weeks);
        // A huge stake in the middle earns only from now on.
        uint256 b = _mintAndStake(bob, 1e24, 4);
        assertEq(boost.pendingRewards(b), 0);
        assertApproxEqAbs(boost.pendingRewards(a), 2e21, 1);
        vm.warp(vm.getBlockTimestamp() + 2 weeks);
        assertApproxEqAbs(boost.pendingRewards(a), 2e21 + uint256(2e21) / 1_000_001, 2);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Schedule
    // ------------------------------------------------------------------------------------------------------------

    /// @dev The squeeze the second pass refused with an end floor: were the creator able to squeeze the rest of a
    ///      52-week budget into one week, a large position of its own staked for the shortest lock would take most of
    ///      it back from an LP locked for the whole period. A notify now starts a tranche beside the running one and
    ///      never touches it: the creator's position shares only the weeks it is staked, its one-week tranche of new
    ///      money included, and the 52-week tranche keeps emitting 1e21 a week to whoever is staked.
    function test_schedule_aCreatorCannotSqueezeTheBudgetUnderALockedLp() public {
        uint256 a = _mintAndStake(alice, 1e18, 52);
        _notify(52e21, 52);
        uint256 rate = boost.gauge(id).rewardRateX128;
        vm.warp(vm.getBlockTimestamp() + 1 weeks);
        // An account of the creator's stakes 99 times alice's 3x weight for the shortest lock (1x).
        uint256 c = _mintAndStake(mallory, 297e18, 4);
        vm.expectRevert(IHookrLpBoost.ZeroAmount.selector);
        boost.notify(id, 0, 1);
        _notify(1e21, 1);
        assertEq(boost.gauge(id).rewardRateX128, rate + FullMath.mulDiv(1e21, Q128, 1 weeks), "beside, not instead");
        // A week later that position holds 99% of that week's two tranches, not of the remaining 51 weeks.
        vm.warp(vm.getBlockTimestamp() + 1 weeks);
        assertApproxEqAbs(boost.pendingRewards(c), 198e19, 2);
        assertApproxEqAbs(boost.pendingRewards(a), 1e21 + 2e19, 2);
        // It leaves at its maturity, five weeks in; alice takes every week after that.
        vm.warp(boost.stakeOf(c).maturity);
        vm.prank(mallory);
        boost.withdraw(c, mallory);
        vm.warp(boost.gauge(id).periodFinish);
        uint256[] memory none = new uint256[](0);
        vm.prank(mallory);
        assertApproxEqAbs(boost.claim(id, none, mallory), 495e19, 4);
        assertApproxEqAbs(_claim(alice, a), 1e21 + 5e19 + 47e21, 4);
    }

    /// @dev ECON-2-1's first PoC: a creator extended its running period at the running rate with the least amount the
    ///      rate floor took, and a stranger's one-wei funding, landed first, raised that floor by 1 / (time left), so
    ///      the rate floor refused the notify. Each notify is now a tranche of its own: the same notify goes
    ///      through after the wei, its tranche is exactly what it is without the wei, and by its end alice has every
    ///      tranche whole.
    function test_schedule_aStrangersWeiCannotBlockACreatorsNotify() public {
        uint256 a = _mintAndStake(alice, 1e22, 4);
        _notify(4e21, 4);
        vm.warp(vm.getBlockTimestamp() + 2 weeks);
        boost.poke(id);
        uint256 amount = _leastToKeepTheRate(6);
        assertEq(amount, 4e21);
        uint256 end = vm.getBlockTimestamp() + 6 weeks;
        uint256 snap = vm.snapshotState();
        reward.approve(address(boost), amount);
        boost.notify(id, amount, 6);
        uint256 alone = boost.endingRate(id, end);
        vm.revertToState(snap);
        _fund(mallory, 1);
        reward.approve(address(boost), amount);
        boost.notify(id, amount, 6);
        assertEq(boost.gauge(id).periodFinish, end);
        assertEq(boost.endingRate(id, end), alone, "the creator's tranche is what it is alone");
        vm.warp(end);
        assertApproxEqAbs(boost.pendingRewards(a), 4e21 + 1 + amount, 2);
    }

    /// @dev ECON-2-1's second PoC: an extension carrying a 1% margin over the least the rate floor took was refused
    ///      after a stranger funded 1e19 + 1 first, under a tenth of that margin; to extend at all the creator had to
    ///      pay x (new length / time left - 1) more. The same notify now goes through: the creator pays its own amount
    ///      and nothing more, and its tranche is exactly that amount over its own length.
    function test_schedule_aStrangersFundingCannotMakeACreatorPayMore() public {
        _mintAndStake(alice, 1e22, 4);
        _notify(4e21, 4);
        vm.warp(vm.getBlockTimestamp() + 3 weeks);
        boost.poke(id);
        uint256 least = _leastToKeepTheRate(13);
        uint256 amount = least + least / 100;
        assertEq(amount, 12_120e18);
        _fund(mallory, 1e19 + 1);
        uint256 before = reward.balanceOf(address(this));
        reward.approve(address(boost), amount);
        boost.notify(id, amount, 13);
        assertEq(before - reward.balanceOf(address(this)), amount, "the creator pays its own amount");
        uint256 end = vm.getBlockTimestamp() + 13 weeks;
        assertEq(boost.endingRate(id, end), FullMath.mulDiv(amount, Q128, 13 weeks), "that amount over its length");
    }

    /// @dev ECON-2-1's third PoC: a notify of nothing made an empty 52-week period, and a stranger's one-wei funding
    ///      turned it into a running period no shorter one could replace, so a four-week campaign was refused as a
    ///      shortening for up to 52 weeks. A notify of nothing is now refused, so no empty period exists; a
    ///      stranger's 52-week tranche of one wei runs beside the creator's four-week campaign, which emits its whole
    ///      amount by its own end.
    function test_schedule_aStrangersTrancheCannotHoldBackACreatorsCampaign() public {
        uint256 a = _mintAndStake(alice, 1e22, 4);
        vm.expectRevert(IHookrLpBoost.ZeroAmount.selector);
        boost.notify(id, 0, 52);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _fund(mallory, 1, 52);
        _notify(4e21, 4);
        uint256 time = vm.getBlockTimestamp();
        assertEq(boost.gauge(id).periodFinish, _weekAfter(time + 52 weeks), "the wei keeps its own end");
        vm.warp(_weekAfter(time + 4 weeks));
        assertApproxEqAbs(boost.pendingRewards(a), 4e21, 2, "the whole campaign by its own end");
    }

    // ------------------------------------------------------------------------------------------------------------
    // Duplicate and unsolicited deposits
    // ------------------------------------------------------------------------------------------------------------

    function test_duplicate_aStakedPositionCannotBeStakedAgain() public {
        uint256 a = _mintAndStake(alice, 1e18, 4);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.AlreadyStaked.selector, a));
        boost.stake(a, 4);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.AlreadyStaked.selector, a));
        boost.stake(a, 4);
        // Even the custodian itself, the one caller custody alone would let through, finds it staked.
        vm.prank(address(boost));
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.AlreadyStaked.selector, a));
        boost.stake(a, 4);
        assertEq(boost.gauge(id).totalWeight, 1e18);
    }

    function test_unsolicited_safeTransferIsRefusedAndAPlainTransferIsNoStake() public {
        uint256 a = _mintFullRange(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert();
        posm.safeTransferFrom(alice, address(boost), a);
        assertEq(posm.ownerOf(a), alice);
        // A plain transfer cannot be refused by any contract; it makes no stake and nobody can stake or withdraw it.
        vm.prank(alice);
        posm.transferFrom(alice, address(boost), a);
        assertEq(boost.stakeOf(a).owner, address(0));
        assertEq(boost.gauge(id).totalWeight, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.NotPositionOwner.selector, a, alice));
        boost.stake(a, 4);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.NotStaked.selector, a));
        boost.withdraw(a, alice);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Range
    // ------------------------------------------------------------------------------------------------------------

    /// @dev The PoC for refusing concentrated positions: the gauge cannot observe a range exit, so it takes none.
    function test_range_aConcentratedPositionIsRefused() public {
        uint256 a = _mint(alice, key, -60, 60, 1e18);
        vm.startPrank(alice);
        posm.approve(address(boost), a);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.NotFullRange.selector, int24(-60), int24(60)));
        boost.stake(a, 4);
        vm.stopPrank();
    }

    function test_range_fullRangeAccruesAcrossLargePriceMoves() public {
        uint256 a = _mintAndStake(alice, 1e18, 4);
        _notify(4e21, 4);
        int24[4] memory ticks = [int24(59_000), -59_000, 30_000, 0];
        for (uint256 i; i < ticks.length; ++i) {
            vm.warp(vm.getBlockTimestamp() + 1 weeks);
            _swapToTick(key, ticks[i]);
            boost.poke(id);
        }
        assertEq(boost.gauge(id).unassigned, 0);
        assertApproxEqAbs(_claim(alice, a), 4e21, 4);
    }

    /// @dev Under the sizing rule a pool leaves the usable range only while nobody is staked. The small tokens' thin
    ///      pool goes past it for the price of its launch position, and that week, with no weight, goes to the
    ///      remainder; a position of the gauge's minLiquidity out there would own more than the supply. Back inside, a
    ///      stake holds the price in the band against this suite's whole balance of either token, and every week it
    ///      is staked is paid.
    function test_range_onlyAPoolWithNoStakeLeavesTheBand() public {
        (, PoolKey memory thin) = _launchSmall(1e9, 200, 3000);
        PoolId thinId = thin.toId();
        boost.createGauge(thin, _terms(4, 52, 30_000, LEAST_LIQUIDITY));
        IERC20 t0 = IERC20(Currency.unwrap(thin.currency0));
        IERC20 t1 = IERC20(Currency.unwrap(thin.currency1));
        (int24 lower, int24 upper) = (TickMath.minUsableTick(200), TickMath.maxUsableTick(200));
        reward.approve(address(boost), 5e21);
        boost.notify(thinId, 5e21, 5);
        _swapToPrice(thin, TickMath.MAX_SQRT_PRICE - 1, t1.balanceOf(address(this)));
        assertGe(_tick(thinId), upper, "out of range, nobody staked");
        vm.warp(vm.getBlockTimestamp() + 1 weeks);
        boost.poke(thinId);
        assertApproxEqAbs(boost.gauge(thinId).unassigned, 1e21, 1, "the unstaked week waits in the remainder");
        uint256 needed = SqrtPriceMath.getAmount1Delta(
            TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), LEAST_LIQUIDITY, true
        );
        assertGt(needed, t1.totalSupply(), "no position of the gauge's minLiquidity fits out there");
        _swapToTick(thin, 0);
        uint256 a = _mint(alice, thin, lower, upper, LEAST_LIQUIDITY);
        _stake(alice, a, 8);
        _swapToPrice(thin, TickMath.MAX_SQRT_PRICE - 1, t1.balanceOf(address(this)));
        assertLt(_tick(thinId), upper, "the band's upper edge is out of reach");
        vm.warp(vm.getBlockTimestamp() + 2 weeks);
        boost.poke(thinId);
        _swapToPrice(thin, TickMath.MIN_SQRT_PRICE + 1, t0.balanceOf(address(this)));
        assertGe(_tick(thinId), lower, "the band's lower edge is out of reach");
        vm.warp(vm.getBlockTimestamp() + 2 weeks);
        boost.poke(thinId);
        assertApproxEqAbs(boost.gauge(thinId).unassigned, 1e21, 1, "only the unstaked week");
        assertApproxEqAbs(boost.pendingRewards(a), 4e21, 4, "every staked week is paid");
    }

    /// @dev The sizing rule against the out-of-range PoC's push: on or past an edge of the usable range a full-range
    ///      position of the gauge's floor would own more of the paying token than its 10^30 supply, so with a stake at
    ///      the floor the price never gets there. Pushed toward each edge with all this suite holds of the paying
    ///      token, it stops inside the band, and every week is in range and paid.
    function test_range_aStakeAtTheSizingFloorKeepsThePriceInTheBand() public {
        (, PoolKey memory thin) = _launch(Currency.wrap(address(quote)), 1e9, 200);
        PoolId thinId = thin.toId();
        IERC20 t0 = IERC20(Currency.unwrap(thin.currency0));
        IERC20 t1 = IERC20(Currency.unwrap(thin.currency1));
        uint128 floor = _sizingFloor(thin);
        boost.createGauge(thin, _terms(4, 52, 30_000, floor));
        uint256 a = _mint(alice, thin, TickMath.minUsableTick(200), TickMath.maxUsableTick(200), floor);
        _stake(alice, a, 8);
        reward.approve(address(boost), 4e21);
        boost.notify(thinId, 4e21, 4);
        vm.warp(vm.getBlockTimestamp() + 1 weeks);
        boost.poke(thinId);
        _swapToPrice(thin, TickMath.MAX_SQRT_PRICE - 1, t1.balanceOf(address(this)));
        assertLt(_tick(thinId), TickMath.maxUsableTick(200), "the band's upper edge is out of reach");
        vm.warp(vm.getBlockTimestamp() + 2 weeks);
        boost.poke(thinId);
        _swapToPrice(thin, TickMath.MIN_SQRT_PRICE + 1, t0.balanceOf(address(this)));
        assertGe(_tick(thinId), TickMath.minUsableTick(200), "the band's lower edge is out of reach");
        vm.warp(vm.getBlockTimestamp() + 1 weeks);
        boost.poke(thinId);
        assertEq(boost.gauge(thinId).unassigned, 0, "no interval was out of range");
        assertApproxEqAbs(boost.pendingRewards(a), 4e21, 4);
    }

    /// @dev The rule's other half: a full-range position minted while the price is outside the band holds all its
    ///      value in one token. With the pool pushed past the band before anyone staked, a position at the gauge's
    ///      sizing floor would hold more than that token's whole supply, so none can be minted there, let alone
    ///      staked.
    function test_range_noPositionAtTheSizingFloorCanBeMintedOutsideTheBand() public {
        (, PoolKey memory thin) = _launch(Currency.wrap(address(quote)), 1e9, 200);
        PoolId thinId = thin.toId();
        IERC20 t1 = IERC20(Currency.unwrap(thin.currency1));
        uint128 floor = _sizingFloor(thin);
        boost.createGauge(thin, _terms(4, 52, 30_000, floor));
        // Nobody is staked, so only the launch's concentrated position stands in the way.
        _swapToPrice(thin, TickMath.MAX_SQRT_PRICE - 1, 1e29);
        assertGe(_tick(thinId), TickMath.maxUsableTick(200), "out of range");
        (int24 lower, int24 upper) = (TickMath.minUsableTick(200), TickMath.maxUsableTick(200));
        uint256 needed = SqrtPriceMath.getAmount1Delta(
            TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), floor, true
        );
        assertGt(needed, t1.totalSupply(), "more than the whole supply");
        // Holding all of it but dust, alice cannot settle the mint: Permit2's transfer of the token fails.
        _fundLp(alice, thin);
        t1.transfer(alice, t1.balanceOf(address(this)));
        bytes[] memory params = new bytes[](2);
        params[0] =
            abi.encode(thin, lower, upper, uint256(floor), type(uint128).max, type(uint128).max, alice, bytes(""));
        params[1] = abi.encode(thin.currency0, thin.currency1);
        uint256 deadline = vm.getBlockTimestamp();
        vm.prank(alice);
        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));
        posm.modifyLiquidities(abi.encode(abi.encodePacked(MINT_POSITION, SETTLE_PAIR), params), deadline);
    }

    /// @dev time-0-1's out-of-range PoC ran on a gauge below the sizing rule, MIN_LIQUIDITY on a thin pool of two 10^30
    ///      supplies, where about 1.8e25 of the paying token pushed the price past the band and an update made on its
    ///      edge paid two weeks spent outside. `createGauge` refuses that gauge now, directly and when queued, naming
    ///      the currency whose edge binds, what a full-range position of MIN_LIQUIDITY owns there and the 10^30 bound.
    function test_range_aGaugeBelowTheSizingRuleIsRefused() public {
        (, PoolKey memory thin) = _launch(Currency.wrap(address(quote)), 1e9, 200);
        bytes memory refusal = _sizingRefusal(thin, LEAST_LIQUIDITY);
        (, uint256 atEdge, uint256 bound) = _decodeTooLow(refusal);
        assertGt(atEdge, 1.8e25);
        assertLt(atEdge, 1.9e25);
        assertEq(bound, 1e30);
        vm.expectRevert(refusal);
        boost.createGauge(thin, _terms(4, 52, 30_000, LEAST_LIQUIDITY));
        bytes32 kind = boost.CREATE_GAUGE();
        vm.prank(gov);
        vm.expectRevert(refusal);
        boost.queue(kind, abi.encode(thin, _terms(4, 52, 30_000, LEAST_LIQUIDITY)));
    }

    /// @dev time-1-2's PoC, a settled round trip outside an unlock: in a pool that charges nothing per swap, an
    ///      outsider holding the swap input for one transaction swaps it in, pokes with no unlock open and swaps back,
    ///      for rounding. On a gauge at MIN_LIQUIDITY, which `createGauge` used to take on any pool, the first swap
    ///      went past the usable range and the poke sent four in-range weeks to the remainder. That gauge is refused
    ///      now; at the least minLiquidity the sizing rule takes, the same round trip with 10^26 of each token stops
    ///      inside the band and alice keeps her four weeks.
    function test_sizing_aSettledRoundTripCannotWipeInRangeWeeks() public {
        (PoolKey memory zk, PoolId zid, uint128 least) = _zeroFeeGaugeAtTheSizingFloor();
        uint256 a = _mint(alice, zk, TickMath.minUsableTick(120), TickMath.maxUsableTick(120), least);
        _stake(alice, a, 52);
        reward.approve(address(boost), 52e21);
        boost.notify(zid, 52e21, 52);
        (uint160 priceBefore,,,) = manager.getSlot0(zid);
        vm.warp(vm.getBlockTimestamp() + 4 weeks);
        uint256 earned = boost.pendingRewards(a);
        assertApproxEqAbs(earned, 4e21, 2);
        SettledRangeWiper wiper = new SettledRangeWiper(manager, swapper, boost);
        IERC20 t0 = IERC20(Currency.unwrap(zk.currency0));
        IERC20 t1 = IERC20(Currency.unwrap(zk.currency1));
        t0.transfer(address(wiper), 1e26);
        t1.transfer(address(wiper), 1e26);
        wiper.wipe(zk);
        assertTrue(wiper.pokedWhileLocked(), "the poke ran with no unlock open");
        assertLt(wiper.tickAtPoke(), TickMath.maxUsableTick(120), "the push stopped inside the band");
        (uint160 priceAfter,,,) = manager.getSlot0(zid);
        assertEq(priceAfter, priceBefore, "the price is back where it was");
        assertLe(2e26 - t0.balanceOf(address(wiper)) - t1.balanceOf(address(wiper)), 1000, "rounding only");
        assertEq(boost.gauge(zid).unassigned, 0);
        assertApproxEqAbs(boost.pendingRewards(a), earned, 2, "four in-range weeks kept");
    }

    /// @dev time-1-2's creator PoC: a second before a 52-week period ended, the creator's settled round trip around a
    ///      poke wiped alice's whole period on a gauge at MIN_LIQUIDITY, and its account, staked for the shortest
    ///      lock, then took the re-emitted budget over one week. On the gauge at the sizing floor the round trip stays
    ///      inside the band: alice, locked 52 weeks at 3x and the only stake, takes the whole budget and nothing is
    ///      left to re-emit.
    function test_sizing_aCreatorCannotTakeBackALockedLpsBudgetWithSettledSwaps() public {
        (PoolKey memory zk, PoolId zid, uint128 least) = _zeroFeeGaugeAtTheSizingFloor();
        (int24 lower, int24 upper) = (TickMath.minUsableTick(120), TickMath.maxUsableTick(120));
        uint256 a = _mint(alice, zk, lower, upper, least);
        _stake(alice, a, 52);
        reward.approve(address(boost), 52e21);
        boost.notify(zid, 52e21, 52);
        uint48 finish = boost.gauge(zid).periodFinish;
        assertEq(boost.stakeOf(a).maturity, finish, "alice is locked for exactly the period");
        SettledRangeWiper wiper = new SettledRangeWiper(manager, swapper, boost);
        IERC20(Currency.unwrap(zk.currency0)).transfer(address(wiper), 1e26);
        IERC20(Currency.unwrap(zk.currency1)).transfer(address(wiper), 1e26);
        vm.warp(finish - 1);
        wiper.wipe(zk);
        assertLt(wiper.tickAtPoke(), upper, "the push stopped inside the band");
        vm.warp(finish);
        vm.prank(alice);
        boost.withdraw(a, alice);
        uint256[] memory none = new uint256[](0);
        vm.prank(alice);
        uint256 aliceTotal = boost.claim(zid, none, alice);
        // The creator's account (mallory here) stakes for the shortest lock; the creator re-emits over one week.
        uint256 c = _mint(mallory, zk, lower, upper, least);
        _stake(mallory, c, 4);
        vm.expectRevert(IHookrLpBoost.ZeroAmount.selector);
        boost.notify(zid, 0, 1);
        vm.warp(vm.getBlockTimestamp() + 1 weeks);
        assertEq(boost.pendingRewards(c), 0, "nothing is left to re-emit");
        assertApproxEqAbs(aliceTotal, 52e21, 4, "the locked LP keeps the budget");
    }

    // ------------------------------------------------------------------------------------------------------------
    // A pool currency minted for the length of one call
    // ------------------------------------------------------------------------------------------------------------

    /// @dev time-1-1's PoC: the sizing rule rested on a currency's supply, which a flash mint passes for the length of
    ///      one call. An existing-token subject with an ERC-3156 flash mint, its gauge sized by the rule against its
    ///      totalSupply, let an outsider holding dust flash-mint 100 times the supply, take the price past the usable
    ///      range with a settled swap, poke with no unlock open, swap back and burn the mint: four in-range weeks went
    ///      to the remainder. Such a subject gets no gauge without a declared bound; with one declared (its supply, as
    ///      an owner might), the same round trip still takes the price past the band, and alice keeps her four weeks.
    function test_flashMint_aRoundTripPastTheBandCannotWipeInRangeWeeks() public {
        (PoolKey memory fk, PoolId fid, MockFlashMintToken flash, uint128 least) = _flashMintGauge();
        uint256 a = _mint(alice, fk, TickMath.minUsableTick(120), TickMath.maxUsableTick(120), least);
        _stake(alice, a, 52);
        reward.approve(address(boost), 52e21);
        boost.notify(fid, 52e21, 52);
        vm.warp(vm.getBlockTimestamp() + 4 weeks);
        uint256 earned = boost.pendingRewards(a);
        assertApproxEqAbs(earned, 4e21, 2);
        FlashMintRangeWiper wiper = new FlashMintRangeWiper(manager, swapper, boost);
        IERC20(Currency.unwrap(fk.currency0)).transfer(address(wiper), 1000);
        IERC20(Currency.unwrap(fk.currency1)).transfer(address(wiper), 1000);
        uint256 supply = flash.totalSupply();
        wiper.wipe(fk, flash, 100 * supply);
        assertTrue(wiper.pokedWhileLocked(), "the poke ran with no unlock open");
        assertFalse(_inUsableRange(wiper.tickAtPoke(), 120), "the poke saw the price past the band");
        assertEq(flash.totalSupply(), supply, "the mint was burned back");
        assertEq(boost.gauge(fid).unassigned, 0);
        assertApproxEqAbs(boost.pendingRewards(a), earned, 2, "four in-range weeks kept");
    }

    /// @dev time-1-1's creator PoC: the family owner of the flash-mintable subject wiped alice's whole 52-week period a
    ///      second before it ended and re-emitted it over one week to its own fresh stake. With the bound declared and
    ///      the gauge at the sizing floor, the round trip still takes the price past the band: alice, locked 52 weeks
    ///      at 3x and the only stake, takes the whole budget and nothing is left to re-emit.
    function test_flashMint_aCreatorCannotTakeBackALockedLpsBudget() public {
        (PoolKey memory fk, PoolId fid, MockFlashMintToken flash, uint128 least) = _flashMintGauge();
        (int24 lower, int24 upper) = (TickMath.minUsableTick(120), TickMath.maxUsableTick(120));
        uint256 a = _mint(alice, fk, lower, upper, least);
        _stake(alice, a, 52);
        reward.approve(address(boost), 52e21);
        boost.notify(fid, 52e21, 52);
        uint48 finish = boost.gauge(fid).periodFinish;
        assertEq(boost.stakeOf(a).maturity, finish, "alice is locked for exactly the period");
        FlashMintRangeWiper wiper = new FlashMintRangeWiper(manager, swapper, boost);
        IERC20(Currency.unwrap(fk.currency0)).transfer(address(wiper), 1000);
        IERC20(Currency.unwrap(fk.currency1)).transfer(address(wiper), 1000);
        vm.warp(finish - 1);
        wiper.wipe(fk, flash, 100 * flash.totalSupply());
        assertFalse(_inUsableRange(wiper.tickAtPoke(), 120), "the poke saw the price past the band");
        vm.warp(finish);
        vm.prank(alice);
        boost.withdraw(a, alice);
        uint256[] memory none = new uint256[](0);
        vm.prank(alice);
        uint256 aliceTotal = boost.claim(fid, none, alice);
        uint256 c = _mint(mallory, fk, lower, upper, least);
        _stake(mallory, c, 4);
        vm.expectRevert(IHookrLpBoost.ZeroAmount.selector);
        boost.notify(fid, 0, 1);
        vm.warp(vm.getBlockTimestamp() + 1 weeks);
        assertEq(boost.pendingRewards(c), 0, "nothing is left to re-emit");
        assertApproxEqAbs(aliceTotal, 52e21, 4, "the locked LP keeps the budget");
    }

    // ------------------------------------------------------------------------------------------------------------
    // A supply bound that fails
    // ------------------------------------------------------------------------------------------------------------

    /// @dev What a supply bound that fails does (IHookrLpBoost Range): the owner declared a mintable ERC-20's 10^24
    ///      supply as its bound, and its issuer later mints past it and sells the excess into the staked pool, which
    ///      then ends a transaction past the usable range. The accrual reads no pool state, so nothing is wiped:
    ///      alice, the only stake, keeps the week she spent in range and earns the week the pool spends outside by
    ///      weight.
    function test_failedBound_mintsPastADeclaredBoundKeepPayingTheStakes() public {
        MockERC20 plain = new MockERC20("Plain", "PLN", 18);
        plain.mint(address(this), 1e24);
        plain.approve(address(launcher), type(uint256).max);
        plain.approve(address(swapper), type(uint256).max);
        (, PoolKey memory k) = _launchOf(address(plain), Currency.wrap(address(quote)), 1e18, SPACING, 3000, 1e23);
        _declareBound(boost, address(plain), 1e24);
        (PoolId kid, uint256 a) = _stakedGaugeAWeekIn(k);
        plain.mint(address(this), 1e36);
        assertGt(plain.totalSupply(), boost.supplyBound(address(plain)), "minted past the declared bound");
        _keepsPayingPastTheBand(k, kid, a, address(plain), 1e36);
    }

    /// @dev The other way a bound fails: HookrToken's runtime code deployed by other initcode, which reports a
    ///      totalSupply of 10^6 while this suite holds 10^45 of it. It has every HookrToken's codehash, so its bound is
    ///      built in at 10^6 and its family owner opens a gauge with no declaration; selling what the totalSupply does
    ///      not show ends a transaction past the usable range. Nothing is wiped: alice, the only stake, keeps the week
    ///      she spent in range and earns the week outside by weight.
    function test_failedBound_hookrTokenCodeWithOtherStorageKeepsPayingTheStakes() public {
        bytes memory runtime = vm.getDeployedCode("HookrToken.sol:HookrToken");
        address fake = address(new HookrTokenCodeWithOtherStorage(runtime, 1e6, address(this), 1e45));
        assertEq(fake.codehash, boost.hookrTokenCodeHash(), "every HookrToken's codehash");
        assertEq(boost.supplyBound(fake), 1e6, "its bound is the totalSupply it reports");
        assertEq(IERC20(fake).balanceOf(address(this)), 1e45, "far past it");
        IERC20(fake).approve(address(launcher), type(uint256).max);
        IERC20(fake).approve(address(swapper), type(uint256).max);
        IERC20(fake).transfer(alice, 1e27);
        (, PoolKey memory k) = _launchOf(fake, Currency.wrap(address(quote)), 1e18, SPACING, 3000, 1e23);
        (PoolId kid, uint256 a) = _stakedGaugeAWeekIn(k);
        _keepsPayingPastTheBand(k, kid, a, fake, 1e36);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Updates inside a PoolManager unlock
    // ------------------------------------------------------------------------------------------------------------

    /// @dev time-0-2's PoC: in a pool that charges nothing per swap, one unlock that swaps past the last usable tick,
    ///      pokes and swaps back to the exact starting price settles for rounding dust, and the poke read "out of
    ///      range" for four weeks that were in range throughout, sending them to the remainder. The round trip still
    ///      works for dust and the price is past the band at the poke, but the accrual reads no pool state: the four
    ///      weeks stay alice's.
    function test_unlocked_aFreeFlashRoundTripCannotWipeAnInterval() public {
        (PoolKey memory zk, PoolId zid) = _zeroFeeGauge();
        uint256 a = _mint(alice, zk, TickMath.minUsableTick(120), TickMath.maxUsableTick(120), 1e18);
        _stake(alice, a, 52);
        reward.approve(address(boost), 52e21);
        boost.notify(zid, 52e21, 52);
        (uint160 priceBefore,,,) = manager.getSlot0(zid);
        vm.warp(vm.getBlockTimestamp() + 4 weeks);
        uint256 earned = boost.pendingRewards(a);
        assertApproxEqAbs(earned, 4e21, 2);
        FlashRangeWiper wiper = _wiper(zk);
        wiper.roundTrip(zk, true);
        assertGe(wiper.tickInside(), TickMath.maxUsableTick(120), "past the band inside the unlock");
        (uint160 priceAfter,,,) = manager.getSlot0(zid);
        assertEq(priceAfter, priceBefore, "the price is back where it was");
        assertLe(2000 - _held(zk, address(wiper)), 1000, "the round trip costs only rounding dust");
        assertEq(boost.gauge(zid).lastUpdate, vm.getBlockTimestamp(), "the poke inside brought the gauge to now");
        assertEq(boost.gauge(zid).unassigned, 0);
        assertApproxEqAbs(boost.pendingRewards(a), earned, 2, "four in-range weeks kept");
    }

    /// @dev The PoC's second half: the remainder a wipe filled went, at the creator's next notify, to whoever was
    ///      staked then, never to the LP staked through the wiped weeks. With the round trip made at alice's maturity,
    ///      she keeps her four weeks and bob, staked after, earns only the four after.
    function test_unlocked_theLpStakedThroughTheWeeksKeepsThem() public {
        (PoolKey memory zk, PoolId zid) = _zeroFeeGauge();
        (int24 lower, int24 upper) = (TickMath.minUsableTick(120), TickMath.maxUsableTick(120));
        uint256 a = _mint(alice, zk, lower, upper, 1e18);
        _stake(alice, a, 4);
        reward.approve(address(boost), 8e21);
        boost.notify(zid, 8e21, 8);
        vm.warp(boost.stakeOf(a).maturity);
        FlashRangeWiper wiper = _wiper(zk);
        wiper.roundTrip(zk, true);
        vm.prank(alice);
        boost.withdraw(a, alice);
        uint256[] memory none = new uint256[](0);
        vm.prank(alice);
        assertApproxEqAbs(boost.claim(zid, none, alice), 4e21, 4);
        uint256 b = _mint(bob, zk, lower, upper, 1e18);
        _stake(bob, b, 4);
        vm.warp(vm.getBlockTimestamp() + 4 weeks);
        assertApproxEqAbs(boost.pendingRewards(b), 4e21, 4);
        assertEq(boost.gauge(zid).unassigned, 0);
    }

    /// @dev The PoC's creator use, the squeeze done with a wipe: a wipe a second before a 52-week period ended sent
    ///      the period to the remainder, and the creator re-emitted the whole remainder over one week to a fresh stake
    ///      of its own. The round trip leaves the budget where it was, so alice, locked 52 weeks at 3x and the only
    ///      stake, takes it whole and nothing is left to re-emit.
    function test_unlocked_aCreatorCannotWipeALockedLpsBudget() public {
        (PoolKey memory zk, PoolId zid) = _zeroFeeGauge();
        uint256 a = _mint(alice, zk, TickMath.minUsableTick(120), TickMath.maxUsableTick(120), 1e18);
        _stake(alice, a, 52);
        reward.approve(address(boost), 52e21);
        boost.notify(zid, 52e21, 52);
        uint48 finish = boost.gauge(zid).periodFinish;
        assertEq(boost.stakeOf(a).maturity, finish, "alice is locked for exactly the period");
        FlashRangeWiper wiper = _wiper(zk);
        vm.warp(finish - 1);
        wiper.roundTrip(zk, true);
        vm.warp(finish);
        vm.prank(alice);
        boost.withdraw(a, alice);
        uint256[] memory none = new uint256[](0);
        vm.prank(alice);
        assertApproxEqAbs(boost.claim(zid, none, alice), 52e21, 4);
        IHookrLpBoost.Gauge memory g = boost.gauge(zid);
        assertEq(g.unassigned, 0);
        assertEq(g.scheduled, 0);
    }

    /// @dev The accrual reads no pool state, so notify, fund, poke, extend, claim and pendingRewards work inside a
    ///      PoolManager unlock as outside one, and an update made there pays what one made after it would. The
    ///      PositionManager itself refuses what would move its NFT or open a second unlock there: stake and withdraw
    ///      meet its PoolManagerMustBeLocked, collectFees its AlreadyUnlocked. This suite is the gauge's creator and
    ///      the position's staker, and makes each call from inside its own unlock (`unlockCallback`).
    function test_unlocked_theGaugesEntriesWorkInsideAnUnlockAsOutside() public {
        address gauge = address(boost);
        bytes4 mustBeLocked = bytes4(keccak256("PoolManagerMustBeLocked()"));
        uint256 mine = _mintFullRange(address(this), 1e18);
        posm.approve(gauge, mine);
        _expectRevertInsideUnlock(gauge, abi.encodeCall(HookrLpBoost.stake, (mine, 4)), mustBeLocked);
        boost.stake(mine, 4);
        reward.approve(gauge, 4e21);
        _insideUnlock(gauge, abi.encodeCall(HookrLpBoost.notify, (id, 4e21, 4)));
        assertEq(boost.gauge(id).scheduled, 4e21);
        vm.warp(vm.getBlockTimestamp() + 1 weeks);
        uint256 pending =
            abi.decode(_insideUnlock(gauge, abi.encodeCall(HookrLpBoost.pendingRewards, (mine))), (uint256));
        assertEq(pending, boost.pendingRewards(mine));
        assertApproxEqAbs(pending, 1e21, 1);
        reward.approve(gauge, 1e21);
        _insideUnlock(gauge, abi.encodeCall(HookrLpBoost.fund, (id, 1e21, 3)));
        _insideUnlock(gauge, abi.encodeCall(HookrLpBoost.poke, (id)));
        _insideUnlock(gauge, abi.encodeCall(HookrLpBoost.extend, (mine, 8)));
        assertEq(boost.owed(id, address(this)), pending, "the extension settled the week");
        uint256[] memory ids = new uint256[](1);
        ids[0] = mine;
        vm.warp(vm.getBlockTimestamp() + 1 weeks);
        uint256 week = boost.pendingRewards(mine);
        bytes memory claimed = _insideUnlock(gauge, abi.encodeCall(HookrLpBoost.claim, (id, ids, alice)));
        assertEq(abi.decode(claimed, (uint256)), pending + week);
        assertEq(reward.balanceOf(alice), pending + week);
        _expectRevertInsideUnlock(
            gauge, abi.encodeCall(HookrLpBoost.collectFees, (mine, alice)), IPoolManager.AlreadyUnlocked.selector
        );
        vm.warp(boost.stakeOf(mine).maturity);
        _expectRevertInsideUnlock(gauge, abi.encodeCall(HookrLpBoost.withdraw, (mine, alice)), mustBeLocked);
        boost.withdraw(mine, alice);
        assertEq(posm.ownerOf(mine), alice);
    }

    /// @dev Outside an unlock every move settles on its own, so leaving the usable range takes paying in about
    ///      1.8e19 x the full-range liquidity of one currency: about 1.8e37 raw units through alice's 10^18 here, far
    ///      past either token's 10^30 supply. Pushed with this suite's whole balance either way, the price stays inside
    ///      the band and every week is paid.
    function test_unlocked_outsideAnUnlockTheWholeSupplyCannotLeaveTheBand() public {
        (PoolKey memory zk, PoolId zid) = _zeroFeeGauge();
        uint256 a = _mint(alice, zk, TickMath.minUsableTick(120), TickMath.maxUsableTick(120), 1e18);
        _stake(alice, a, 52);
        reward.approve(address(boost), 52e21);
        boost.notify(zid, 52e21, 52);
        vm.warp(vm.getBlockTimestamp() + 4 weeks);
        IERC20 t0 = IERC20(Currency.unwrap(zk.currency0));
        IERC20 t1 = IERC20(Currency.unwrap(zk.currency1));
        _swapToPrice(zk, TickMath.MAX_SQRT_PRICE - 1, t1.balanceOf(address(this)));
        assertLt(_tick(zid), TickMath.maxUsableTick(120), "below the band's upper edge");
        boost.poke(zid);
        _swapToPrice(zk, TickMath.MIN_SQRT_PRICE + 1, t0.balanceOf(address(this)));
        assertGe(_tick(zid), TickMath.minUsableTick(120), "at or above the band's lower edge");
        boost.poke(zid);
        assertEq(boost.gauge(zid).unassigned, 0);
        assertApproxEqAbs(boost.pendingRewards(a), 4e21, 2);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Failed withdrawals
    // ------------------------------------------------------------------------------------------------------------

    function test_failedWithdrawal_toAReceiverRejectingErc721LeavesTheStakeIntact() public {
        uint256 a = _mintAndStake(alice, 1e18, 4);
        _notify(4e21, 4);
        vm.warp(boost.stakeOf(a).maturity);
        address inert = address(new Inert());
        vm.prank(alice);
        vm.expectRevert();
        boost.withdraw(a, inert);
        assertEq(boost.stakeOf(a).owner, alice);
        assertEq(posm.ownerOf(a), address(boost));
        assertEq(boost.gauge(id).totalWeight, 1e18);
        vm.prank(alice);
        boost.withdraw(a, alice);
        assertEq(posm.ownerOf(a), alice);
    }

    function test_failedWithdrawal_aRevertingRewardTokenNeverBlocksIt() public {
        MockHookToken token = new MockHookToken(1e30);
        (PoolKey memory k2, PoolId id2) = _secondGauge(address(token));
        uint256 a = _mintFullRangeIn(alice, k2, 1e18);
        _stake(alice, a, 4);
        token.approve(address(boost), 4e21);
        boost.notify(id2, 4e21, 4);
        vm.warp(boost.stakeOf(a).maturity);
        token.setFrozen(true);
        uint256[] memory ids = new uint256[](0);
        vm.prank(alice);
        boost.withdraw(a, alice);
        assertEq(posm.ownerOf(a), alice);
        uint256 owed = boost.owed(id2, alice);
        assertApproxEqAbs(owed, 4e21, 1);
        vm.prank(alice);
        vm.expectRevert(MockHookToken.Frozen.selector);
        boost.claim(id2, ids, alice);
        assertEq(boost.owed(id2, alice), owed);
        token.setFrozen(false);
        vm.prank(alice);
        assertEq(boost.claim(id2, ids, alice), owed);
    }

    function test_failedWithdrawal_feeCollectionToARecipientRejectingEthLeavesTheStakeIntact() public {
        (PoolKey memory k2,) = _secondGauge(address(reward));
        assertTrue(k2.currency0.isAddressZero());
        uint256 a = _mintFullRangeIn(alice, k2, 1e21);
        _stake(alice, a, 4);
        _swapToTick(k2, 600);
        _swapToTick(k2, -600);
        address inert = address(new Inert());
        vm.prank(alice);
        vm.expectRevert();
        boost.collectFees(a, inert);
        assertEq(boost.stakeOf(a).owner, alice);
        assertEq(posm.ownerOf(a), address(boost));
        uint256 before = alice.balance;
        vm.prank(alice);
        boost.collectFees(a, alice);
        assertGt(alice.balance, before);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Position verification
    // ------------------------------------------------------------------------------------------------------------

    function test_verification_anAnswerThatDisagreesWithThePoolManagerIsRefused() public {
        FakePositionManager fake = new FakePositionManager(manager);
        HookrLpBoost other = new HookrLpBoost(
            IHookrRegistry(address(registry)),
            IHookrLauncherView(address(launcher)),
            IPositionManagerMinimal(address(fake)),
            gov,
            DELAY
        );
        _activate(other);
        _listReward(other, address(reward));
        other.createGauge(key, _terms(4, 52, 30_000));
        (int24 lower, int24 upper) = _fullRange();
        uint256 info =
            (uint256(PoolId.unwrap(id)) >> 56 << 56) | (uint256(uint24(upper)) << 32) | (uint256(uint24(lower)) << 8);
        // The fake claims a full-range position with liquidity the PoolManager does not hold for it.
        fake.set(key, info, alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.LiquidityMismatch.selector, uint128(1e18), uint128(0)));
        other.stake(7, 4);
        // A wrong pool id in the info is refused before anything else.
        fake.set(key, info ^ (1 << 100), alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.PoolMismatch.selector, uint256(7)));
        other.stake(7, 4);
    }

    function test_verification_aChangedPositionManagerIsRefused() public {
        uint256 a = _mintFullRange(alice, 1e18);
        vm.prank(alice);
        posm.approve(address(boost), a);
        vm.etch(Chain4663Code.POSITION_MANAGER_ADDRESS, address(new Inert()).code);
        vm.prank(alice);
        vm.expectRevert(IHookrLpBoost.PositionManagerChanged.selector);
        boost.stake(a, 4);
    }

    function test_verification_aPositionInAPoolWithoutAGaugeIsRefused() public {
        (, PoolKey memory k2) = _launch(Currency.wrap(address(0)), 1e24);
        uint256 a = _mintFullRangeIn(alice, k2, 1e18);
        vm.startPrank(alice);
        posm.approve(address(boost), a);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.UnknownGauge.selector, k2.toId()));
        boost.stake(a, 4);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------------------------
    // Reentrancy
    // ------------------------------------------------------------------------------------------------------------

    function test_reentrancy_throughAHostileRewardToken() public {
        MockHookToken token = new MockHookToken(1e30);
        (PoolKey memory k2, PoolId id2) = _secondGauge(address(token));
        uint256 a = _mintFullRangeIn(alice, k2, 1e18);
        _stake(alice, a, 4);
        token.approve(address(boost), 4e21);
        boost.notify(id2, 4e21, 4);
        vm.warp(vm.getBlockTimestamp() + 2 weeks);
        uint256[] memory ids = new uint256[](1);
        ids[0] = a;
        // On the claim's transfer out the token calls the gauge again: every entry is locked.
        token.arm(address(boost), address(boost), abi.encodeCall(HookrLpBoost.claim, (id2, ids, alice)));
        vm.prank(alice);
        uint256 paid = boost.claim(id2, ids, alice);
        assertEq(token.hookCalls(), 1);
        assertFalse(token.lastHookSucceeded());
        assertEq(bytes4(token.lastHookResult()), IHookrLpBoost.Reentrancy.selector);
        assertApproxEqAbs(paid, 2e21, 1);
        token.arm(address(boost), address(boost), abi.encodeCall(HookrLpBoost.poke, (id2)));
        vm.warp(vm.getBlockTimestamp() + 1 weeks);
        vm.prank(alice);
        boost.claim(id2, ids, alice);
        assertEq(bytes4(token.lastHookResult()), IHookrLpBoost.Reentrancy.selector);
    }

    function test_reentrancy_throughTheReceiverOfAWithdrawnPosition() public {
        uint256 a = _mintAndStake(alice, 1e18, 4);
        uint256 b = _mintAndStake(alice, 1e18, 4);
        vm.warp(boost.stakeOf(a).maturity);
        Reenterer receiver = new Reenterer();
        receiver.arm(address(boost), abi.encodeCall(HookrLpBoost.withdraw, (b, address(receiver))));
        vm.prank(alice);
        boost.withdraw(a, address(receiver));
        assertEq(receiver.calls(), 1);
        assertFalse(receiver.lastSucceeded());
        assertEq(bytes4(receiver.lastResult()), IHookrLpBoost.Reentrancy.selector);
        assertEq(posm.ownerOf(a), address(receiver));
        assertEq(posm.ownerOf(b), address(boost));
        assertEq(boost.stakeOf(b).owner, alice);
    }

    function test_reentrancy_throughTheEthRecipientOfFees() public {
        (PoolKey memory k2, PoolId id2) = _secondGauge(address(reward));
        uint256 a = _mintFullRangeIn(alice, k2, 1e21);
        _stake(alice, a, 4);
        _swapToTick(k2, 600);
        _swapToTick(k2, -600);
        Reenterer receiver = new Reenterer();
        receiver.arm(address(boost), abi.encodeCall(HookrLpBoost.poke, (id2)));
        vm.prank(alice);
        boost.collectFees(a, address(receiver));
        assertEq(receiver.calls(), 1);
        assertFalse(receiver.lastSucceeded());
        assertEq(bytes4(receiver.lastResult()), IHookrLpBoost.Reentrancy.selector);
        assertGt(address(receiver).balance, 0);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Reward tokens off the list
    // ------------------------------------------------------------------------------------------------------------

    function test_rewardTokens_feeOnTransferAndRebasingAreRefusedUnlessListed() public {
        MockFeeOnTransferToken fot = new MockFeeOnTransferToken("Fee", "FEE", 1e30, 100, address(0));
        MockRebasingToken reb = new MockRebasingToken(1e30);
        (, PoolKey memory k2) = _launch(Currency.wrap(address(0)), 1e24);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.RewardTokenNotListed.selector, address(fot)));
        boost.createGauge(k2, IHookrLpBoost.Terms(address(fot), 4, 52, 30_000, FLOOR));
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.RewardTokenNotListed.selector, address(reb)));
        boost.createGauge(k2, IHookrLpBoost.Terms(address(reb), 4, 52, 30_000, FLOOR));
    }

    /// @dev Were a fee-on-transfer token listed by mistake, the gauge credits only what arrives and still never
    ///      promises more than it holds.
    function test_rewardTokens_aFeeOnTransferTokenIsCreditedByBalanceDelta() public {
        MockFeeOnTransferToken fot = new MockFeeOnTransferToken("Fee", "FEE", 1e30, 100, address(0));
        (PoolKey memory k2, PoolId id2) = _secondGauge(address(fot));
        uint256 a = _mintFullRangeIn(alice, k2, 1e18);
        _stake(alice, a, 4);
        fot.approve(address(boost), 1e21);
        boost.notify(id2, 1e21, 1);
        IHookrLpBoost.Gauge memory g = boost.gauge(id2);
        assertEq(g.funded, 1e21 - 1e19);
        assertEq(g.scheduled, 1e21 - 1e19);
        assertEq(fot.balanceOf(address(boost)), g.funded);
        vm.warp(vm.getBlockTimestamp() + 1 weeks);
        uint256[] memory ids = new uint256[](1);
        ids[0] = a;
        vm.prank(alice);
        uint256 paid = boost.claim(id2, ids, alice);
        assertLe(paid, g.funded);
        assertGe(fot.balanceOf(address(boost)), boost.gauge(id2).funded - boost.gauge(id2).paid);
    }

    /// @dev Were a rebasing token listed by mistake: a positive rebase is surplus nobody can take, and a negative one
    ///      can leave the last claim unpaid while the earlier ones were paid in full. The list keeps such tokens out.
    function test_rewardTokens_aRebasingTokenShowsWhyTheListExists() public {
        MockRebasingToken reb = new MockRebasingToken(1e30);
        (PoolKey memory k2, PoolId id2) = _secondGauge(address(reb));
        uint256 a = _mintFullRangeIn(alice, k2, 1e18);
        uint256 b = _mintFullRangeIn(bob, k2, 1e18);
        _stake(alice, a, 4);
        _stake(bob, b, 4);
        reb.approve(address(boost), 2e21);
        boost.notify(id2, 2e21, 1);
        vm.warp(vm.getBlockTimestamp() + 1 weeks);
        reb.rebase(address(boost), 3e21);
        uint256[] memory ids = new uint256[](1);
        ids[0] = a;
        vm.prank(alice);
        assertEq(boost.claim(id2, ids, alice), 1e21);
        assertEq(reb.balanceOf(address(boost)), 2e21);
        reb.rebase(address(boost), 5e20);
        ids[0] = b;
        vm.prank(bob);
        vm.expectRevert();
        boost.claim(id2, ids, bob);
        assertEq(boost.owed(id2, bob), 0);
        assertEq(boost.pendingRewards(b), 1e21);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Donation and inflation
    // ------------------------------------------------------------------------------------------------------------

    function test_donation_directRewardTransfersChangeNothing() public {
        uint256 a = _mintAndStake(alice, 1e18, 4);
        _notify(4e21, 4);
        vm.warp(vm.getBlockTimestamp() + 1 weeks);
        boost.poke(id);
        uint256 pending = boost.pendingRewards(a);
        IHookrLpBoost.Gauge memory before = boost.gauge(id);
        reward.transfer(address(boost), 1e24);
        boost.poke(id);
        IHookrLpBoost.Gauge memory after_ = boost.gauge(id);
        assertEq(after_.funded, before.funded);
        assertEq(after_.scheduled, before.scheduled);
        assertEq(after_.unassigned, before.unassigned);
        assertEq(after_.rewardPerWeightX128, before.rewardPerWeightX128);
        assertEq(boost.pendingRewards(a), pending);
        vm.warp(vm.getBlockTimestamp() + 3 weeks);
        assertApproxEqAbs(_claim(alice, a), 4e21, 1);
    }

    function test_donation_toThePoolIsTheLpsFeeNotAReward() public {
        uint256 a = _mintAndStake(alice, 1e21, 4);
        _notify(4e21, 4);
        PoolDonateTest donor = new PoolDonateTest(manager);
        IERC20(Currency.unwrap(key.currency0)).approve(address(donor), type(uint256).max);
        IERC20(Currency.unwrap(key.currency1)).approve(address(donor), type(uint256).max);
        vm.warp(vm.getBlockTimestamp() + 1 weeks);
        uint256 pending = boost.pendingRewards(a);
        donor.donate(key, 1e22, 1e22, "");
        assertEq(boost.pendingRewards(a), pending);
        uint256 before0 = IERC20(Currency.unwrap(key.currency0)).balanceOf(alice);
        vm.prank(alice);
        boost.collectFees(a, alice);
        assertGt(IERC20(Currency.unwrap(key.currency0)).balanceOf(alice), before0);
    }

    function test_inflation_aFirstStakeCannotCaptureEarlierEmission() public {
        _notify(4e21, 4);
        vm.warp(vm.getBlockTimestamp() + 2 weeks);
        // The least stake the gauge takes arrives first, two weeks into the period.
        uint256 least = _mintAndStake(mallory, FLOOR, 4);
        // The first two weeks went unassigned, not to the first staker.
        boost.poke(id);
        assertApproxEqAbs(boost.gauge(id).unassigned, 2e21, 1);
        assertEq(boost.pendingRewards(least), 0);
        uint256 a = _mintAndStake(alice, 1e18, 4);
        vm.warp(vm.getBlockTimestamp() + 2 weeks);
        uint256 pl = boost.pendingRewards(least);
        uint256 pa = boost.pendingRewards(a);
        assertApproxEqAbs(pl + pa, 2e21, 2);
        // From then on it earns its weight's share: FLOOR of FLOOR + 10^18.
        assertApproxEqAbs(pl, uint256(2e21) * FLOOR / (FLOOR + 1e18), 2);
    }

    // ------------------------------------------------------------------------------------------------------------
    // The gauge's minLiquidity
    // ------------------------------------------------------------------------------------------------------------

    /// @dev The PoC for the per-gauge minLiquidity: with only a global floor of MIN_LIQUIDITY raw liquidity, 10^-12 of
    ///      a token in this pool, a stake made as soon as the gauge existed took the week before the first real LP
    ///      whole, at no cost. A position below the gauge's minLiquidity is refused, so that week waits in the
    ///      remainder and the real LP earns the three weeks it was staked.
    function test_minLiquidity_aDustStakeCannotTakeTheEmissionBeforeTheFirstRealLp() public {
        uint128 dust = LEAST_LIQUIDITY;
        _expectTooLow(mallory, _mintFullRange(mallory, dust), dust);
        _notify(4e21, 4);
        vm.warp(vm.getBlockTimestamp() + 1 weeks);
        uint256 real = _mintAndStake(alice, 1e22, 4);
        vm.warp(vm.getBlockTimestamp() + 3 weeks);
        assertApproxEqAbs(boost.pendingRewards(real), 3e21, 1);
        boost.poke(id);
        assertApproxEqAbs(boost.gauge(id).unassigned, 1e21, 1);
    }

    /// @dev The PoC's second gap: a period ran with nothing staked, so its whole budget waited in the remainder, and
    ///      the creator re-emitted it for the LPs it expected; a dust stake made first took the two weeks before the
    ///      real LP arrived. It is refused, so those two weeks wait in the remainder again.
    function test_minLiquidity_aDustStakeCannotTakeTheReEmittedRemainder() public {
        _notify(4e21, 4);
        vm.warp(boost.gauge(id).periodFinish);
        boost.poke(id);
        assertEq(boost.gauge(id).unassigned, 4e21, "the unstaked period waits in the remainder");
        uint128 dust = LEAST_LIQUIDITY;
        _expectTooLow(mallory, _mintFullRange(mallory, dust), dust);
        boost.notify(id, 0, 4);
        vm.warp(vm.getBlockTimestamp() + 2 weeks);
        uint256 real = _mintAndStake(alice, 1e22, 4);
        vm.warp(boost.gauge(id).periodFinish);
        assertApproxEqAbs(boost.pendingRewards(real), 2e21, 1);
        boost.poke(id);
        assertApproxEqAbs(boost.gauge(id).unassigned, 2e21, 1);
    }

    /// @dev The PoC's third gap: a dust stake locked beside a real LP stayed on after its maturity, at 1x and free to
    ///      leave at any time, and took every week after the real LP withdrew. It is refused, so once the real LP
    ///      withdraws the rest of the period waits in the remainder.
    function test_minLiquidity_aDustStakeCannotTakeTheEmissionAfterTheRealLpLeaves() public {
        uint128 dust = LEAST_LIQUIDITY;
        _expectTooLow(mallory, _mintFullRange(mallory, dust), dust);
        uint256 real = _mintAndStake(alice, 1e22, 4);
        _notify(8e21, 8);
        vm.warp(boost.stakeOf(real).maturity);
        vm.prank(alice);
        boost.withdraw(real, alice);
        assertApproxEqAbs(boost.owed(id, alice), 4e21, 1);
        vm.warp(boost.gauge(id).periodFinish);
        boost.poke(id);
        assertEq(boost.gauge(id).totalWeight, 0);
        assertApproxEqAbs(boost.gauge(id).unassigned, 4e21, 1);
    }

    /// @dev ECON-2-2's PoC: createGauge took a minLiquidity of the pool's maximum liquidity per tick plus one, which no
    ///      position can hold (every full-range position adds to the same two ticks, and the PoolManager refuses the
    ///      mint with TickLiquidityOverflow); notify took its budget, which stayed unassigned for good, and the pool's
    ///      one gauge slot was taken for good. Such terms are refused now, directly and when queued, so nothing can be
    ///      funded into such a gauge and the slot stays free for a gauge at the pool's sizing floor.
    function test_minLiquidity_aGaugeNoPositionCanHoldIsRefused() public {
        (, PoolKey memory k2) = _launch(Currency.wrap(address(0)), 1e24);
        PoolId id2 = k2.toId();
        uint128 unreachable = Pool.tickSpacingToMaxLiquidityPerTick(k2.tickSpacing) + 1;
        // No position can hold it: the PoolManager refuses the mint at the shared lower tick.
        (int24 lower, int24 upper) = (TickMath.minUsableTick(k2.tickSpacing), TickMath.maxUsableTick(k2.tickSpacing));
        _fundLp(alice, k2);
        bytes memory actions = abi.encodePacked(MINT_POSITION, SETTLE_PAIR, SWEEP);
        bytes[] memory params = new bytes[](3);
        params[0] =
            abi.encode(k2, lower, upper, uint256(unreachable), type(uint128).max, type(uint128).max, alice, bytes(""));
        params[1] = abi.encode(k2.currency0, k2.currency1);
        params[2] = abi.encode(k2.currency0, alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("TickLiquidityOverflow(int24)")), lower));
        posm.modifyLiquidities{value: 1e27}(abi.encode(actions, params), vm.getBlockTimestamp());
        // The gauge is refused, directly and when queued.
        bytes memory refusal = abi.encodeWithSelector(IHookrLpBoost.MinLiquidityTooHigh.selector, unreachable);
        vm.expectRevert(refusal);
        boost.createGauge(k2, _terms(4, 52, 30_000, unreachable));
        bytes32 kind = boost.CREATE_GAUGE();
        vm.prank(gov);
        vm.expectRevert(refusal);
        boost.queue(kind, abi.encode(k2, _terms(4, 52, 30_000, unreachable)));
        // The slot is still free: a gauge at the pool's sizing floor is created.
        uint128 least = _sizingFloor(k2);
        boost.createGauge(k2, _terms(4, 52, 30_000, least));
        assertEq(boost.gauge(id2).terms.minLiquidity, least);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Liquidity changes while staked
    // ------------------------------------------------------------------------------------------------------------

    /// @dev The gauge holds the NFT and never approves anyone, so no account (its staker, an operator the staker had
    ///      approved, a stranger) can add to, take from or burn a staked position, subscribe it, approve itself for it
    ///      or get an approval by permit (the gauge signs nothing): its liquidity stays the liquidity read at stake.
    function test_liquidity_nobodyCanChangeAStakedPosition() public {
        uint256 a = _mintFullRange(alice, 1e18);
        // Alice approved an operator before staking; the approval does not follow the NFT.
        vm.prank(alice);
        posm.setApprovalForAll(carol, true);
        _stake(alice, a, 4);
        assertEq(posm.getApproved(a), address(0));
        assertFalse(posm.isApprovedForAll(address(boost), carol));
        address subscriber = address(new NoopSubscriber());
        address[3] memory actors = [alice, carol, mallory];
        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[i];
            bytes memory notApproved = abi.encodeWithSelector(NOT_APPROVED, actor);
            _fundLp(actor, key);
            bytes[] memory params = new bytes[](2);
            params[0] = abi.encode(a, uint256(1e18), type(uint128).max, type(uint128).max, bytes(""));
            params[1] = abi.encode(key.currency0, key.currency1);
            _expectPositionCallReverts(actor, abi.encodePacked(INCREASE_LIQUIDITY, SETTLE_PAIR), params, notApproved);
            params[0] = abi.encode(a, type(uint128).max, type(uint128).max, bytes(""));
            _expectPositionCallReverts(
                actor, abi.encodePacked(INCREASE_LIQUIDITY_FROM_DELTAS, SETTLE_PAIR), params, notApproved
            );
            params[0] = abi.encode(a, uint256(5e17), uint128(0), uint128(0), bytes(""));
            params[1] = abi.encode(key.currency0, key.currency1, actor);
            _expectPositionCallReverts(actor, abi.encodePacked(DECREASE_LIQUIDITY, TAKE_PAIR), params, notApproved);
            params[0] = abi.encode(a, uint128(0), uint128(0), bytes(""));
            _expectPositionCallReverts(actor, abi.encodePacked(BURN_POSITION, TAKE_PAIR), params, notApproved);
            vm.prank(actor);
            vm.expectRevert(notApproved);
            posm.subscribe(a, subscriber, "");
            vm.prank(actor);
            vm.expectRevert(POSM_UNAUTHORIZED);
            posm.approve(actor, a);
            uint256 deadline = vm.getBlockTimestamp();
            vm.prank(actor);
            vm.expectRevert();
            posm.permit(actor, a, deadline, i, new bytes(65));
            vm.prank(actor);
            vm.expectRevert();
            posm.permitForAll(address(boost), actor, true, deadline, i, new bytes(65));
        }
        assertEq(posm.getPositionLiquidity(a), 1e18);
        assertEq(posm.getApproved(a), address(0));
        assertEq(posm.positionInfo(a) & 0xff, 0);
        assertEq(boost.stakeOf(a).liquidity, 1e18);
        // Fee collection through the gauge leaves the liquidity as it was.
        _swapToTick(key, 600);
        vm.prank(alice);
        boost.collectFees(a, alice);
        assertEq(posm.getPositionLiquidity(a), 1e18);
        assertEq(boost.gauge(id).totalWeight, 1e18);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------------------

    /// @dev What ECON-2-1's PoCs computed as the least amount a notify of `durationWeeks` had to bring for the running
    ///      rate not to fall, under the rate floor the tranches replaced: (scheduled + amount + unassigned) x (time
    ///      left) >= scheduled x (new length).
    function _leastToKeepTheRate(uint16 durationWeeks) internal view returns (uint256) {
        IHookrLpBoost.Gauge memory g = boost.gauge(id);
        uint256 left = g.periodFinish - vm.getBlockTimestamp();
        uint256 needed = (uint256(g.scheduled) * durationWeeks * WEEK + left - 1) / left;
        return needed - g.scheduled - g.unassigned;
    }

    /// @dev A native-quote pool family launched by this contract with a gauge paying `token`, listed first, the clock
    ///      then on a week boundary.
    function _secondGauge(address token) internal returns (PoolKey memory k2, PoolId id2) {
        (, k2) = _launch(Currency.wrap(address(0)), 1e24);
        id2 = k2.toId();
        if (!boost.rewardTokenListed(token)) _listReward(boost, token);
        boost.createGauge(k2, IHookrLpBoost.Terms(token, 4, 52, 30_000, FLOOR));
        _onAWeekBoundary();
    }

    function _mintFullRangeIn(address lp, PoolKey memory k, uint128 liquidity) internal returns (uint256) {
        return _mint(lp, k, TickMath.minUsableTick(k.tickSpacing), TickMath.maxUsableTick(k.tickSpacing), liquidity);
    }

    /// @dev time-1-2's pool, `subject` against `quote` charging nothing per swap (tick spacing 120, a 10^24 launch
    ///      position): its PoC's gauge at MIN_LIQUIDITY breaks the sizing rule and is refused, and the gauge is created
    ///      at the least minLiquidity the rule takes.
    function _zeroFeeGaugeAtTheSizingFloor() internal returns (PoolKey memory zk, PoolId zid, uint128 least) {
        (, zk) = _launch(Currency.wrap(address(quote)), 1e24, 120, 0);
        zid = zk.toId();
        vm.expectRevert(_sizingRefusal(zk, LEAST_LIQUIDITY));
        boost.createGauge(zk, _terms(4, 52, 30_000, LEAST_LIQUIDITY));
        least = _sizingFloor(zk);
        boost.createGauge(zk, _terms(4, 52, 30_000, least));
    }

    /// @dev A pool of `subject` against `quote` that charges nothing per swap (tick spacing 120, a 10^24 launch
    ///      position), with a gauge whose minLiquidity is FLOOR.
    function _zeroFeeGauge() internal returns (PoolKey memory zk, PoolId zid) {
        (, zk) = _launch(Currency.wrap(address(quote)), 1e24, 120, 0);
        zid = zk.toId();
        boost.createGauge(zk, _terms(4, 52, 30_000, FLOOR));
    }

    /// @dev time-1-1's pool: an existing-token family whose subject is a MockFlashMintToken of 10^30 against `quote`,
    ///      charging nothing per swap (tick spacing 120, a 10^24 launch position over [-60,000, 60,000] at price 1).
    ///      Without a declared bound its gauge is refused; the owner declares the subject's supply as its bound, and
    ///      the gauge is created at the sizing floor, the clock back on a week boundary.
    function _flashMintGauge()
        internal
        returns (PoolKey memory fk, PoolId fid, MockFlashMintToken flash, uint128 least)
    {
        flash = new MockFlashMintToken(1e30);
        flash.approve(address(launcher), type(uint256).max);
        (, fk) = _launchOf(address(flash), Currency.wrap(address(quote)), 1e24, 120, 0, 1e27);
        fid = fk.toId();
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.NoSupplyBound.selector, address(flash)));
        boost.createGauge(fk, _terms(4, 52, 30_000));
        _declareBound(boost, address(flash), flash.totalSupply());
        least = _sizingFloor(fk);
        boost.createGauge(fk, _terms(4, 52, 30_000, least));
        vm.warp(_weekAfter(vm.getBlockTimestamp()));
    }

    /// @dev Creates `k`'s gauge at the sizing floor (this suite its family owner), stakes alice there for 52 weeks on
    ///      a week boundary, notifies 52e21 over 52 weeks and brings the gauge through one week in range: alice has
    ///      earned 1e21.
    function _stakedGaugeAWeekIn(PoolKey memory k) internal returns (PoolId kid, uint256 a) {
        kid = k.toId();
        uint128 least = _sizingFloor(k);
        boost.createGauge(k, _terms(4, 52, 30_000, least));
        _onAWeekBoundary();
        a = _mintFullRangeIn(alice, k, least);
        _stake(alice, a, 52);
        reward.approve(address(boost), 52e21);
        boost.notify(kid, 52e21, 52);
        vm.warp(vm.getBlockTimestamp() + 1 weeks);
        boost.poke(kid);
        assertTrue(_inUsableRange(_tick(kid), k.tickSpacing), "a week in range");
        assertApproxEqAbs(boost.pendingRewards(a), 1e21, 1);
    }

    /// @dev This suite sells up to `amount` of `token`, which it holds past the token's bound, into `k` toward the
    ///      token's own edge in one ordinary settled swap, and the transaction ends with the staked pool past the
    ///      usable range; a week passes there and an update closes it. Alice keeps the week in range, her stake earns
    ///      the week outside by weight, and nothing goes to the remainder.
    function _keepsPayingPastTheBand(PoolKey memory k, PoolId kid, uint256 a, address token, uint256 amount) internal {
        bool tokenIsZero = Currency.unwrap(k.currency0) == token;
        _swapToPrice(k, tokenIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1, amount);
        assertFalse(_inUsableRange(_tick(kid), k.tickSpacing), "the staked pool ends a transaction past the band");
        vm.warp(vm.getBlockTimestamp() + 1 weeks);
        boost.poke(kid);
        assertFalse(_inUsableRange(_tick(kid), k.tickSpacing), "past the band for the whole week");
        assertEq(boost.gauge(kid).unassigned, 0, "nothing is wiped");
        assertApproxEqAbs(boost.pendingRewards(a), 2e21, 2, "the stake keeps earning by weight");
    }

    function _inUsableRange(int24 tick, int24 spacing) internal pure returns (bool) {
        return tick >= TickMath.minUsableTick(spacing) && tick < TickMath.maxUsableTick(spacing);
    }

    /// @dev An outsider's FlashRangeWiper holding 1,000 raw units of each of the pool's tokens.
    function _wiper(PoolKey memory k) internal returns (FlashRangeWiper wiper) {
        wiper = new FlashRangeWiper(manager, boost);
        IERC20(Currency.unwrap(k.currency0)).transfer(address(wiper), 1000);
        IERC20(Currency.unwrap(k.currency1)).transfer(address(wiper), 1000);
    }

    /// @dev What `who` holds of the pool's two tokens together.
    function _held(PoolKey memory k, address who) internal view returns (uint256) {
        IERC20 t0 = IERC20(Currency.unwrap(k.currency0));
        IERC20 t1 = IERC20(Currency.unwrap(k.currency1));
        return t0.balanceOf(who) + t1.balanceOf(who);
    }

    /// @dev Makes `call` to `target` from this suite inside a PoolManager unlock.
    function _insideUnlock(address target, bytes memory call) internal returns (bytes memory) {
        return manager.unlock(abi.encode(target, call));
    }

    function _expectRevertInsideUnlock(address target, bytes memory call, bytes4 reason) internal {
        vm.expectRevert(reason);
        _insideUnlock(target, call);
    }

    /// @dev The PoolManager's callback for `_insideUnlock`: makes the call it carries, from this suite, and bubbles up
    ///      its revert.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager");
        (address target, bytes memory call) = abi.decode(data, (address, bytes));
        (bool ok, bytes memory result) = target.call(call);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
        return result;
    }

    /// @dev `lp` stakes `tokenId`, a position of `liquidity` below the fixture gauge's FLOOR, and is refused.
    function _expectTooLow(address lp, uint256 tokenId, uint128 liquidity) internal {
        vm.startPrank(lp);
        posm.approve(address(boost), tokenId);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.LiquidityTooLow.selector, liquidity, FLOOR));
        boost.stake(tokenId, 4);
        vm.stopPrank();
    }

    /// @dev `actor` runs `actions` on the PositionManager and expects `reason`.
    function _expectPositionCallReverts(address actor, bytes memory actions, bytes[] memory params, bytes memory reason)
        internal
    {
        uint256 deadline = vm.getBlockTimestamp();
        vm.prank(actor);
        vm.expectRevert(reason);
        posm.modifyLiquidities(abi.encode(actions, params), deadline);
    }

    /// @dev paid + owed + pending + unassigned + scheduled <= funded, and the balance covers funded - paid, on the
    ///      gauge brought to now (pendingRewards counts the emission since lastUpdate, which scheduled still holds).
    function _checkSolvency(uint256 a, uint256 b) internal {
        boost.poke(id);
        IHookrLpBoost.Gauge memory g = boost.gauge(id);
        uint256 owed = boost.owed(id, alice) + boost.owed(id, bob);
        uint256 pending = boost.pendingRewards(a) + (b == 0 ? 0 : boost.pendingRewards(b));
        assertLe(uint256(g.paid) + owed + pending + g.unassigned + g.scheduled, g.funded, "solvency");
        assertGe(reward.balanceOf(address(boost)), uint256(g.funded) - g.paid, "balance");
    }
}
