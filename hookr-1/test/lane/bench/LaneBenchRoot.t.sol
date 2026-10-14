// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookrToken} from "../../../src/support/HookrToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {HookrTypes} from "../../../src/types/HookrTypes.sol";
import {IHookrLauncher} from "../../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../../src/interfaces/IHookrRouter.sol";
import {HookrRules} from "../../../src/core/HookrRules.sol";
import {IHookrLaneRoot} from "../../../src/interfaces/IHookrLaneRoot.sol";
import {LaneFixture} from "../LaneFixture.sol";
import {GasMeasure} from "../../utils/GasMeasure.sol";
import {TwoVenueExecutor} from "../mocks/TwoVenueExecutor.sol";
import {ScriptedExecutor} from "../mocks/ScriptedExecutor.sol";
import {Actor} from "../mocks/Actors.sol";

/// @notice Gas bench and behaviour of the recapture lane inside HookrRoot: the executor frozen per pool from the
///         registry lane, its switch read live, the split in HookrRules. The bench pool shape (base fee 1%,
///         L = 1e24 over +-60,000 at price 1, ETH quote, 0.3% hookless reference). Run with --isolate.
contract LaneBenchRoot is LaneFixture, GasMeasure {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    TwoVenueExecutor internal arb;
    PoolKey internal ref;
    PoolKey internal plainKey; // lane, plain rules (1% base, 25% share)
    PoolKey internal noLaneKey; // same rules, no lane (fee-only path)
    PoolKey internal guardKey; // lane + Anti-Snipe (50% decaying, per-block cap)
    PoolKey internal dynKey; // lane + Hookr dynamic fees
    PoolKey internal kothKey; // lane + King of the Pool
    bytes32 internal plainFamily;

    function setUp() public {
        _setUpLane();
        arb = new TwoVenueExecutor(manager, address(root), partner, PARTNER_BPS, 3000, 60, address(0), 1e22);
        bytes memory args = abi.encode(address(root), address(arb), address(arb).codehash, LANE_GAS, PARTNER_BPS);
        registry.queue(keccak256("OPEN_LANE"), args);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.openLaneOf(address(root), address(arb), address(arb).codehash, LANE_GAS, PARTNER_BPS);
        // Each pool gets its own subject so every pool has its own reference venue.
        (plainKey, plainFamily) = _launchLane(_benchSubject(), _rc(true, false), 0, false, false);
        (noLaneKey,) = _launchLane(_benchSubject(), _rc(false, false), 0, false, false);
        (guardKey,) = _launchLane(_benchSubject(), _rc(true, false), 0, true, false);
        (dynKey,) = _launchLane(_benchSubject(), _rc(true, false), 0, false, true);
        (kothKey,) = _launchLane(_benchSubject(), _rc(true, true), 3000, false, false);
    }

    function _benchSubject() internal returns (Currency) {
        return Currency.wrap(address(new HookrToken("S", "S", 1e30, address(this))));
    }

    function _rc(bool on, bool koth) internal pure returns (HookrTypes.RecaptureConfig memory c) {
        if (!on) return c;
        c.on = true;
        c.releaseBlocks = RELEASE;
        if (koth) {
            c.traderBps = 1000;
            c.lpBps = 6000;
            c.period = 1 days;
            c.maxPrizeBps = 50;
            c.potReleaseBps = 5000;
            c.minBuyQuote = 1e18;
        } else {
            c.traderBps = 2000;
            c.lpBps = 8000;
        }
    }

    function _launchLane(
        Currency subject,
        HookrTypes.RecaptureConfig memory rc,
        uint16 potBps,
        bool guarded,
        bool dynamic
    ) internal returns (PoolKey memory key, bytes32 family) {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        IHookrLauncher.Member memory m = members[0];
        m.quote = ETH;
        m.tickSpacing = 60;
        m.sqrtPriceX96 = SQRT_ONE;
        m.tickLower = -60_000;
        m.tickUpper = 60_000;
        m.liquidity = 1e24;
        m.amount0Max = 1e24;
        m.amount1Max = 1e24;
        m.config.rules = address(rules);
        m.config.baseLpFeePips = BASE_FEE;
        m.config.caps = HookrTypes.Caps(600_000, 200_000, 1000);
        m.config.rulesGasLimit = 2_000_000;
        m.config.policyId = keccak256("lane-bench");
        m.rules.maxFeePips = BASE_FEE;
        m.rules.protocolShareBps = 2500;
        m.rules.potBps = potBps;
        // A King of the Pool prize is capped by half the protocol's share of LP Rewards: 25% of 4%, halved, is 0.5%.
        if (potBps != 0) m.rules.lpBps = 400;
        if (guarded) {
            m.rules.guardEndBlock = uint40(vm.getBlockNumber() + 100_000);
            m.rules.snipeTaxPips = 500_000;
            m.rules.snipeFloorPips = 10_000;
            m.rules.snipeDecaySeconds = 3600;
            m.rules.maxBuyQuoteAmount = 1e22;
        }
        if (dynamic) {
            m.rules.maxFeePips = 50_000;
            m.rules.dynamicFeeSens = 5;
        }
        m.recapture = rc;
        address token = Currency.unwrap(subject);
        (bool ok,) =
            token.call(abi.encodeWithSignature("approve(address,uint256)", address(launcher), type(uint256).max));
        require(ok);
        (family,) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(token, "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
        // A hookless 0.3% reference venue of the same pair.
        (ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", address(seeder), type(uint256).max));
        require(ok);
        seeder.seed{value: 1e24}(_ref(key), SQRT_ONE, -60_000, 60_000, 1e24);
        _fund(token);
    }

    function _fund(address token) internal {
        address[3] memory people = [whale, minnow, attacker];
        for (uint256 i; i < people.length; ++i) {
            (bool ok,) = token.call(abi.encodeWithSignature("transfer(address,uint256)", people[i], 1e26));
            require(ok);
            vm.prank(people[i]);
            (ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", address(router), type(uint256).max));
            require(ok);
        }
        (bool ok2,) = token.call(abi.encodeWithSignature("transfer(address,uint256)", address(mover), 1e26));
        require(ok2);
    }

    function _warm(PoolKey memory key) internal {
        _buy(key, ETH, minnow, 1e18);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 12);
        _sell(key, ETH, minnow, 5e17);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 12);
    }

    function _count(Vm.Log[] memory logs) internal view returns (uint256 ok, uint256 failed, uint256 pushed) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(root)) continue;
            if (logs[i].topics[0] == SUCCEEDED) {
                ok++;
                (, uint256 p) = abi.decode(logs[i].data, (uint256, uint256));
                pushed += p;
            } else if (logs[i].topics[0] == FAILED) {
                failed++;
            }
        }
    }

    /// @dev Pushed by phase: the before-phase credits no trader, the after-phase the swap's authenticated payer.
    function _pushedByPhase(Vm.Log[] memory logs) internal view returns (uint256 beforePushed, uint256 afterPushed) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(root) || logs[i].topics[0] != SUCCEEDED) continue;
            (, uint256 p) = abi.decode(logs[i].data, (uint256, uint256));
            if (uint256(logs[i].topics[2]) == 1) beforePushed += p;
            else afterPushed += p;
        }
    }

    // ───────────── plain rules ─────────────

    function test_gas_root_noLane_buy() public {
        _warm(noLaneKey);
        _buy(noLaneKey, ETH, whale, 1e18);
        _measure("root.noLane.buy");
    }

    function test_gas_root_noLane_sell() public {
        _warm(noLaneKey);
        _sell(noLaneKey, ETH, whale, 1e18);
        _measure("root.noLane.sell");
    }

    function test_gas_root_laneIdle_buy() public {
        _warm(plainKey);
        vm.recordLogs();
        _buy(plainKey, ETH, whale, 1e18);
        _measure("root.laneIdle.buy");
        (uint256 ok, uint256 failed,) = _count(vm.getRecordedLogs());
        assertEq(ok, 0);
        assertEq(failed, 2);
    }

    function test_gas_root_laneIdle_sell() public {
        _warm(plainKey);
        _sell(plainKey, ETH, whale, 1e18);
        _measure("root.laneIdle.sell");
    }

    function test_gas_root_recapturing_buy() public {
        _warm(plainKey);
        _moveReference(plainKey, 1.03e18);
        uint256 protocolBefore = rules.claimable(ETH, protocol);
        uint256 whaleBefore = rules.claimable(ETH, whale);
        vm.recordLogs();
        _buy(plainKey, ETH, whale, 1e18);
        _measure("root.correcting.buy");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 ok,, uint256 pushed) = _count(logs);
        (uint256 beforePushed, uint256 afterPushed) = _pushedByPhase(logs);
        console2.log("  succeeded", ok);
        console2.log("  pushed", pushed);
        assertGt(ok, 0);
        assertGt(beforePushed, 0, "the before-phase closed the reference gap");
        assertGt(afterPushed, 0, "the after-phase closed the gap the buy opened");
        // Split: the protocol's 25% of each push's profit first, then 20% of the rest to the trader and 80% to the
        // pool's LP accrual. The trader leg comes only from the after-phase, and only on the part of its push the
        // whale's own 1e18 buy accounts for: most of it closes what the before-phase left of the reference gap, which
        // goes to the LP accrual.
        Outcome memory o = _outcome(logs);
        uint256 protocolLeg = _cut(o.profitBefore, beforePushed) + _cut(o.profitAfter, afterPushed);
        assertEq(rules.claimable(ETH, protocol) - protocolBefore, protocolLeg, "protocol leg (two arb recaptures)");
        uint256 afterRest = afterPushed - _cut(o.profitAfter, afterPushed);
        uint256 credit = rules.claimable(ETH, whale) - whaleBefore;
        console2.log("  trader leg, and uncapped", credit, afterRest * 2000 / 10_000);
        assertGt(credit, 0, "trader leg: after-phase only");
        assertLt(credit, afterRest * 2000 / 10_000, "bounded by the whale's own move");
        assertTrue(rules.accountingInvariant(ETH), "claims back every liability");
    }

    // ───────────── launch-time: Anti-Snipe guard ─────────────

    function test_gas_root_guardIdle_buy() public {
        _warm(guardKey);
        _buy(guardKey, ETH, whale, 1e18);
        _measure("root.guard.laneIdle.buy");
    }

    function test_gas_root_guardRecapturing_buy() public {
        _warm(guardKey);
        _moveReference(guardKey, 1.03e18);
        vm.recordLogs();
        _buy(guardKey, ETH, whale, 1e18);
        _measure("root.guard.correcting.buy");
        (uint256 ok,, uint256 pushed) = _count(vm.getRecordedLogs());
        console2.log("  succeeded", ok);
        console2.log("  pushed", pushed);
        assertGt(ok, 0);
    }

    // ───────────── dynamic fees ─────────────

    function test_gas_root_dynIdle_buy() public {
        _warm(dynKey);
        _buy(dynKey, ETH, whale, 1e18);
        _measure("root.dyn.laneIdle.buy");
    }

    function test_gas_root_dynRecapturing_buy() public {
        _warm(dynKey);
        _moveReference(dynKey, 1.03e18);
        vm.recordLogs();
        _buy(dynKey, ETH, whale, 1e18);
        _measure("root.dyn.correcting.buy");
        (uint256 ok,, uint256 pushed) = _count(vm.getRecordedLogs());
        console2.log("  succeeded", ok);
        console2.log("  pushed", pushed);
        assertGt(ok, 0);
    }

    // ───────────── King of the Pool ─────────────

    function test_gas_root_kothIdle_buy() public {
        _warm(kothKey);
        _buy(kothKey, ETH, whale, 2e18);
        _measure("root.koth.laneIdle.buy");
    }

    function test_gas_root_kothRecapturing_buy() public {
        _warm(kothKey);
        _moveReference(kothKey, 1.03e18);
        vm.recordLogs();
        _buy(kothKey, ETH, whale, 2e18);
        _measure("root.koth.correcting.buy");
        (uint256 ok,, uint256 pushed) = _count(vm.getRecordedLogs());
        console2.log("  succeeded", ok);
        console2.log("  pushed", pushed);
        (, address leader,, uint128 pot) = _hill(kothKey);
        assertEq(leader, whale, "the buy leads");
        assertGt(pot, 0, "the pot filled");
    }

    // ───────────── launch with a dev buy (a new token, guarded, capped) ─────────────

    function _devBuyLaunch(bool lane) internal {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        IHookrLauncher.Member memory m = members[0];
        m.quote = ETH;
        m.tickSpacing = 60;
        m.sqrtPriceX96 = SQRT_ONE;
        m.tickLower = -60_000;
        m.tickUpper = 0;
        uint160 lower = TickMath.getSqrtPriceAtTick(-60_000);
        m.liquidity = LiquidityAmounts.getLiquidityForAmount1(lower, SQRT_ONE, 1e27) / 1000 * 999;
        m.amount1Max = 1e27;
        m.config.rules = address(rules);
        m.config.baseLpFeePips = 3000;
        m.config.caps = HookrTypes.Caps(600_000, 200_000, 1000);
        m.config.rulesGasLimit = 2_000_000;
        m.config.policyId = keccak256("lane-bench-devbuy");
        m.rules.maxFeePips = 3000;
        m.rules.protocolShareBps = 2500;
        m.rules.guardEndBlock = uint40(vm.getBlockNumber() + 100_000);
        m.rules.snipeTaxPips = 500_000;
        m.rules.maxBuyQuoteAmount = 1e22;
        m.recapture = _rc(lane, false);
        launcher.launchWithBuy{value: 1e21}(
            IHookrLauncher.Token(address(0), "New", "NEW", 1e27, bytes32(uint256(lane ? 7 : 8))),
            address(root),
            members,
            new bytes[](1),
            IHookrLauncher.DevBuy(0, 1e21, 1, 0),
            vm.getBlockTimestamp()
        );
    }

    function test_gas_launch_devBuy_noLane() public {
        _devBuyLaunch(false);
        _measure("launch.devBuy.noLane");
    }

    function test_gas_launch_devBuy_lane() public {
        vm.recordLogs();
        _devBuyLaunch(true);
        _measure("launch.devBuy.lane");
        (uint256 ok, uint256 failed,) = _count(vm.getRecordedLogs());
        assertEq(ok, 0);
        assertEq(failed, 0, "no arb recapture runs in the transaction that creates the pool");
    }

    // ───────────── every launch rule at once: dynamic fees, Auto Burn, LP Rewards, royalty, guard ─────────────

    function _launchFull(bool lane) internal returns (PoolKey memory key) {
        HookrToken t = new HookrToken("F", "F", 1e30, address(this));
        t.approve(address(launcher), type(uint256).max);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        for (uint256 i; i < 2; ++i) {
            IHookrLauncher.Member memory m = members[i];
            m.quote = i == 0 ? ETH : Currency.wrap(address(tokenB));
            m.tickSpacing = 60;
            m.sqrtPriceX96 = SQRT_ONE;
            m.tickLower = -60_000;
            m.tickUpper = 60_000;
            m.liquidity = 1e24;
            m.amount0Max = 1e24;
            m.amount1Max = 1e24;
            m.config.rules = address(rules);
            m.config.baseLpFeePips = BASE_FEE;
            m.config.caps = HookrTypes.Caps(600_000, 200_000, 1000);
            m.config.rulesGasLimit = 2_000_000;
            m.config.policyId = keccak256("lane-bench-full");
            m.rules.maxFeePips = 50_000;
            m.rules.dynamicFeeSens = 5;
            m.rules.burnBps = 100;
            m.rules.lpBps = 200;
            m.rules.royaltyBps = 500;
            m.rules.royaltyTo = royalty;
            m.rules.protocolShareBps = 2500;
            m.rules.guardEndBlock = uint40(vm.getBlockNumber() + 100_000);
            m.rules.snipeTaxPips = 200_000;
            m.rules.snipeFloorPips = 10_000;
            m.rules.snipeDecaySeconds = 3600;
            m.rules.maxBuyQuoteAmount = 1e22;
            m.recapture = _rc(lane, false);
        }
        (bytes32 family,) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(t), "", "", 0, bytes32(0)), address(root), members, vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
        t.approve(address(seeder), type(uint256).max);
        seeder.seed{value: 1e24}(_ref(key), SQRT_ONE, -60_000, 60_000, 1e24);
        _fund(address(t));
    }

    function test_gas_root_fullRules_noLane_buy() public {
        PoolKey memory k = _launchFull(false);
        _warm(k);
        _buy(k, ETH, whale, 1e18);
        _measure("root.fullRules.noLane.buy");
    }

    function test_gas_root_fullRules_recapturing_buy() public {
        PoolKey memory k = _launchFull(true);
        _warm(k);
        _moveReference(k, 1.03e18);
        uint256 royaltyBefore = rules.claimable(ETH, royalty);
        uint256 deadBefore = IERC20(Currency.unwrap(k.currency1)).balanceOf(address(0xdead));
        vm.recordLogs();
        _buy(k, ETH, whale, 1e18);
        _measure("root.fullRules.correcting.buy");
        (uint256 ok,, uint256 pushed) = _count(vm.getRecordedLogs());
        console2.log("  succeeded", ok);
        console2.log("  pushed", pushed);
        assertGt(ok, 0);
        assertGt(rules.claimable(ETH, royalty), royaltyBefore, "royalty still paid");
        assertGt(IERC20(Currency.unwrap(k.currency1)).balanceOf(address(0xdead)), deadBefore, "Auto Burn still burns");
        assertTrue(rules.accountingInvariant(ETH));
    }

    function test_lane_quoterSeesTheArbRecapture() public {
        _warm(plainKey);
        _moveReference(plainKey, 1.03e18);
        IHookrRouter.Swap memory p = _swapParams(plainKey, ETH, true, true, 1e18, whale);
        uint256 quoted = quoter.quote(p, whale).outputAmount;
        uint256 snap = vm.snapshotState();
        (, uint256 out) = (0, _buy(plainKey, ETH, whale, 1e18));
        vm.revertToState(snap);
        assertEq(quoted, out, "the quote runs the same arb recaptures as the swap");
    }

    // ───────────── behaviour ─────────────

    function test_lane_frozenPerPool() public view {
        (address executor, bytes32 codeHash, uint16 partnerBps, bytes32 family, bool on, uint32 gasCap, uint256 floor) =
            IHookrLaneRoot(address(root)).laneOf(plainKey.toId());
        assertEq(executor, address(arb));
        assertEq(codeHash, address(arb).codehash);
        assertEq(partnerBps, PARTNER_BPS);
        assertEq(family, keccak256(abi.encode(address(launcher), plainFamily)), "the launcher's family, scoped to it");
        assertTrue(on);
        assertEq(gasCap, LANE_GAS);
        assertEq(floor, _entryFloor(LANE_GAS));
        (executor,,,,,,) = IHookrLaneRoot(address(root)).laneOf(noLaneKey.toId());
        assertEq(executor, address(0));
        assertEq(root.feeOnlyFrom(noLaneKey.toId()), 1, "the plain pool without a lane is fee-only");
        assertEq(root.feeOnlyFrom(plainKey.toId()), 0, "a lane pool is never fee-only");
    }

    function test_lane_closeDoesNotReachOpenPools() public {
        registry.closeLaneOf(address(root));
        (address executor,,,,,,) = IHookrLaneRoot(address(root)).laneOf(plainKey.toId());
        assertEq(executor, address(arb));
        _moveReference(plainKey, 1.03e18);
        vm.recordLogs();
        _buy(plainKey, ETH, whale, 1e18);
        (uint256 ok,,) = _count(vm.getRecordedLogs());
        assertGt(ok, 0, "the pool kept its frozen lane");
    }

    function test_lane_recaptureLaunchRefusedWithoutLane() public {
        registry.closeLaneOf(address(root));
        Currency s = _benchSubject();
        vm.expectRevert();
        this.launchExternal(s);
    }

    function launchExternal(Currency s) external {
        require(msg.sender == address(this));
        _launchLane(s, _rc(true, false), 0, false, false);
    }

    function test_lane_belowFloorReverts() public {
        _warm(plainKey);
        IHookrRouter.Swap memory p = _swapParams(plainKey, ETH, true, true, 1e18, whale);
        vm.prank(whale);
        vm.expectRevert();
        router.swap{value: 1e18, gas: 700_000}(p, address(0), new uint256[](0));
    }

    function swapWithGas(PoolKey memory k, uint256 g) external {
        require(msg.sender == address(this));
        IHookrRouter.Swap memory p = _swapParams(k, ETH, true, true, 1e18, whale);
        vm.prank(whale);
        router.swap{value: 1e18, gas: g}(p, address(0), new uint256[](0));
    }

    /// eth_estimateGas binary-searches the least gas at which the call succeeds. Below the lane floor the swap reverts,
    /// so the least succeeding gas funds both arb recaptures in full.
    function test_lane_estimateGasFundsTheArbRecapture() public {
        _warm(plainKey);
        _moveReference(plainKey, 1.03e18);
        uint256 lo = 100_000;
        uint256 hi = 5_000_000;
        while (hi - lo > 1_000) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            try this.swapWithGas(plainKey, mid) {
                hi = mid;
            } catch {
                lo = mid;
            }
            vm.revertToState(snap);
        }
        console2.log("least succeeding router gas", hi);
        vm.recordLogs();
        this.swapWithGas(plainKey, hi);
        (uint256 ok, uint256 failed, uint256 pushed) = _count(vm.getRecordedLogs());
        assertEq(ok, 2, "both arb recaptures ran at the estimated gas");
        assertEq(failed, 0);
        assertGt(pushed, 0);
        (,,,,,, uint256 floor) = IHookrLaneRoot(address(root)).laneOf(plainKey.toId());
        assertGt(hi, floor, "the estimate is above the lane floor");
    }

    /// A generous cap costs nothing in gas used: the same arb recapture at a 5,000,000 cap.
    function test_gas_root_recapturing_buy_cap5M() public {
        TwoVenueExecutor arb5 =
            new TwoVenueExecutor(manager, address(root), partner, PARTNER_BPS, 3000, 60, address(0), 1e22);
        bytes memory args =
            abi.encode(address(root), address(arb5), address(arb5).codehash, uint32(5_000_000), PARTNER_BPS);
        registry.queue(keccak256("OPEN_LANE"), args);
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.openLaneOf(address(root), address(arb5), address(arb5).codehash, 5_000_000, PARTNER_BPS);
        (PoolKey memory k,) = _launchLane(_benchSubject(), _rc(true, false), 0, false, false);
        _warm(k);
        _moveReference(k, 1.03e18);
        vm.recordLogs();
        _buy(k, ETH, whale, 1e18);
        _measure("root.correcting.buy.cap5M");
        (uint256 ok,,) = _count(vm.getRecordedLogs());
        assertEq(ok, 2);
        (,,,,,, uint256 floor) = IHookrLaneRoot(address(root)).laneOf(k.toId());
        console2.log("  floor per lane call at a 5M cap", floor);
    }

    function test_lane_lpAccrualClaim() public {
        _warm(plainKey);
        _moveReference(plainKey, 1.03e18);
        _buy(plainKey, ETH, whale, 1e18);
        // No in-range liquidity at the flush: the LP leg becomes the owner's accrual.
        _pendingToOwner(plainKey, plainFamily, 0, address(this));
        uint256 accrued = _ownerAccrued(plainKey);
        assertGt(accrued, 0);
        uint256 moved = launcher.claimRecapture(plainFamily, 0, address(this));
        assertEq(moved, 1);
        assertEq(rules.claimable(ETH, address(this)), accrued);
        assertTrue(rules.accountingInvariant(ETH));
    }
}
