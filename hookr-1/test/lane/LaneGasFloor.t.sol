// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {TwoVenueExecutor} from "./mocks/TwoVenueExecutor.sol";
import {ScriptedExecutor} from "./mocks/ScriptedExecutor.sol";
import {ScriptedLaneFixture} from "./utils/ScriptedLaneFixture.sol";

/// @notice Buys the subject on a native-quote pool with a chosen gas limit on the PoolManager's swap, then settles.
contract GasCappedSwapper is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager internal immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    function go(PoolKey calldata key, uint256 amountIn, uint256 gasCap) external {
        pm.unlock(abi.encode(key, amountIn, gasCap));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        (PoolKey memory key, uint256 amountIn, uint256 g) = abi.decode(raw, (PoolKey, uint256, uint256));
        BalanceDelta d = pm.swap{gas: g}(key, SwapParams(true, -int256(amountIn), 4295128741), "");
        pm.settle{value: uint256(uint128(-d.amount0()))}();
        pm.take(key.currency1, address(this), uint256(uint128(d.amount1())));
        return "";
    }

    receive() external payable {}
}

/// @notice An executor that records the gas it was called with and does nothing else.
contract GrantProbe {
    uint256 public seen;

    function executeArbitrage(PoolKey calldata, address) external returns (uint256) {
        seen = gasleft();
        return 0;
    }
}

/// @notice The gas floor of the lane switch (audit finding F-010): a caller that caps the swap's gas cannot land
///         between enough for the swap and enough for the lane, and the executor's grant is the switch's cap
///         whatever the settlement set.
contract LaneGasFloorTest is ScriptedLaneFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    /// F-010. A caller that caps the swap's gas can no longer land between "enough for the swap" and "enough for the
    /// lane": below the floor the swap reverts, above it both phases run with the full grant.
    function test_noStarveWindow() public {
        exec.set(ScriptedExecutor.Mode.PUSH, 9e18);
        GasCappedSwapper s = new GasCappedSwapper(manager);
        vm.deal(address(s), 1e24);
        uint256 passed;
        for (uint256 g = 150_000; g <= 3_000_000; g += 50_000) {
            uint256 snap = vm.snapshotState();
            vm.recordLogs();
            try s.go(key, 1e18, g) {
                Tally memory t = _tally(vm.getRecordedLogs());
                assertEq(t.succeeded, 2, "every completed swap funded both arb recaptures");
                assertEq(t.failed, 0);
                passed++;
            } catch {}
            vm.revertToState(snap);
        }
        assertGt(passed, 0, "a funded swap passes");
    }

    /// F-010. The floor of each lane call is the live cap, the 1/64 the call keeps back, the root's reserve and the
    /// margin; a swap must reach the before-phase with that floor, the before-phase's whole grant and the 600,000 the
    /// swap's own work may take until the after-phase.
    function test_floorAndRevert() public {
        (,,, uint256 floor) = _laneOf(key);
        assertEq(floor, (uint256(LANE_GAS) + LANE_GAS / 63 + 150_000 + 5_000) + LANE_GAS + 600_000);
        GasCappedSwapper s = new GasCappedSwapper(manager);
        vm.deal(address(s), 1e24);
        vm.expectRevert();
        s.go(key, 1e18, floor - 1);
    }

    /// F-010. The switch's cap is sized to the executor: the two-venue executor recaptures with half the fixture's cap,
    /// and a cap below its need fails open.
    function test_laneGasCapSizedToExecutor() public {
        assertTrue(_labRecaptures(LANE_GAS / 2), "half the cap still funds the two-venue executor");
        assertFalse(_labRecaptures(60_000), "a starved grant fails open");
    }

    /// F-010. The executor's grant does not depend on the registry's settlement set: the frame's claim snapshot, one
    /// read per accepted currency, is taken outside the grant, so filling the set to its 8 members (as a Robinhood
    /// Chain fork's genesis WETH and USDG partly do) leaves the executor exactly the gas it had, and the two-venue
    /// executor still recaptures with half the fixture's cap.
    function test_executorGrantIndependentOfTheSettlementSet() public {
        uint256 small = _grantSeen();
        for (uint256 n = registry.settlementCurrencies().length; n < 8; ++n) {
            _settlementCurrency(address(new HookrToken("X", "X", 1, address(this))));
        }
        assertEq(registry.settlementCurrencies().length, 8);
        assertEq(_grantSeen(), small, "the executor's grant is the same with a full settlement set");
        assertTrue(_labRecaptures(LANE_GAS / 2), "half the cap still funds the two-venue executor with a full set");
    }

    /// @dev The gas the executor is called with in the after-phase of a buy on a fresh ETH-quoted recapture pool.
    function _grantSeen() internal returns (uint256 seen) {
        uint256 snap = vm.snapshotState();
        GrantProbe probe = new GrantProbe();
        _openLane(address(probe), LANE_GAS);
        PoolKey memory k = _openRecapture(ETH);
        _buy(k, ETH, whale, 1e21);
        seen = probe.seen();
        assertGt(seen, 0, "the probe ran");
        vm.revertToState(snap);
    }

    function _labRecaptures(uint32 cap) internal returns (bool ok) {
        uint256 snap = vm.snapshotState();
        TwoVenueExecutor arb = _twoVenueExecutor(1e22);
        _openLane(address(arb), cap);
        PoolKey memory k = _openKoth(ETH);
        _seedReference(k);
        vm.recordLogs();
        _buy(k, ETH, whale, 2e22);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(root) && logs[i].topics[0] == SUCCEEDED) {
                (, uint256 pushed) = abi.decode(logs[i].data, (uint256, uint256));
                if (pushed != 0) ok = true;
            }
        }
        vm.revertToState(snap);
    }
}
