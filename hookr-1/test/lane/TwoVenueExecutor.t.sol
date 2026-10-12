// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LaneFixture} from "./LaneFixture.sol";
import {TwoVenueExecutor} from "./mocks/TwoVenueExecutor.sol";
import {Actor} from "./mocks/Actors.sol";

/// @notice The two-venue executor's reference venue is fixed at deployment, and its legs are priced with each venue's
///         LP fee and v4 protocol fee.
contract TwoVenueExecutorTest is LaneFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    /// @dev 0.1% in both directions, the v4 maximum.
    uint24 internal constant PROTOCOL_FEE = 1000 | (1000 << 12);
    /// @dev The subject is currency1 and the quote native currency0. The Hookr sell leg is oneForZero and pays
    ///      1,000 + 10,000 - 10 pips (a leg pays the base LP fee only, whatever the pool's LP Rewards); the reference
    ///      buy leg is zeroForOne and pays 1,000 + 3,000 - 3 pips.
    uint256 internal constant HOOKR_LEG_FEE = 10_990;
    uint256 internal constant REF_LEG_FEE = 3997;

    TwoVenueExecutor internal arb;
    PoolKey internal key;
    PoolKey internal ref;

    struct Phase {
        uint256 failed;
        uint256 succeeded;
        uint256 pushed;
        bytes4 reason;
    }

    function setUp() public {
        _setUpLane();
        arb = _twoVenueExecutor(1e22);
        _openLane(address(arb));
        key = _openKoth(ETH);
        ref = _seedReference(key);
    }

    function _protocolFees() internal {
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(key, PROTOCOL_FEE);
        manager.setProtocolFee(ref, PROTOCOL_FEE);
    }

    /// @dev Moves the reference venue to price `priceWad` (currency1 per currency0, 1e18 = 1) with an
    ///      unauthenticated swap that stops at the limit. A higher price makes the subject cheaper there.
    function _moveRef(uint256 priceWad) internal {
        uint160 target = uint160(Math.sqrt(priceWad * 1e18) * (1 << 96) / 1e18);
        mover.directSwap(ref, false, -int256(1e26), target);
        (uint160 now_,,,) = manager.getSlot0(ref.toId());
        assertEq(now_, target);
    }

    /// @dev A tiny authenticated buy on the Hookr pool; returns the before-phase outcome.
    function _trigger() internal returns (Phase memory p) {
        vm.recordLogs();
        _buy(key, ETH, whale, 1e15);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(root) || uint256(logs[i].topics[2]) != 1) continue;
            if (logs[i].topics[0] == FAILED) {
                p.failed++;
                p.reason = abi.decode(logs[i].data, (bytes4));
            } else if (logs[i].topics[0] == SUCCEEDED) {
                p.succeeded++;
                (, p.pushed) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
    }

    function test_venueIsFixedAtDeployment() public view {
        PoolKey memory v = arb.venue(key);
        assertEq(Currency.unwrap(v.currency0), Currency.unwrap(key.currency0));
        assertEq(Currency.unwrap(v.currency1), Currency.unwrap(key.currency1));
        assertEq(v.fee, 3000);
        assertEq(v.tickSpacing, 60);
        assertEq(address(v.hooks), address(0));
        assertEq(PoolId.unwrap(v.toId()), PoolId.unwrap(ref.toId()));
        assertEq(arb.root(), address(root));
    }

    function test_constructorRefusesBadVenues() public {
        address r = address(root);
        vm.expectRevert(TwoVenueExecutor.InvalidVenue.selector);
        new TwoVenueExecutor(manager, address(0), partner, PARTNER_BPS, 3000, 60, address(0), 1e22);
        vm.expectRevert(TwoVenueExecutor.InvalidVenue.selector);
        new TwoVenueExecutor(manager, r, partner, PARTNER_BPS, 3000, 60, r, 1e22);
        vm.expectRevert(TwoVenueExecutor.InvalidVenue.selector);
        new TwoVenueExecutor(manager, r, partner, PARTNER_BPS, 0x800000, 60, address(0), 1e22);
        vm.expectRevert(TwoVenueExecutor.InvalidVenue.selector);
        new TwoVenueExecutor(manager, r, partner, PARTNER_BPS, 3000, 0, address(0), 1e22);
        vm.expectRevert(TwoVenueExecutor.InvalidVenue.selector);
        new TwoVenueExecutor(manager, r, partner, PARTNER_BPS, 3000, 60, address(0), 0);
    }

    function test_onlyTheRootCallsTheExecutor() public {
        vm.prank(attacker);
        vm.expectRevert(TwoVenueExecutor.NotRoot.selector);
        arb.executeArbitrage(key, attacker);
    }

    /// A 1.42% gap covers the round trip's LP fees (1.31%), so without protocol fees the fee-priced legs recapture it
    /// at a profit; legs that ran to the midpoint of the two prices traded past break-even and lost.
    function test_gapAboveTheLpFeesIsRecaptured() public {
        _moveRef(1.0142e18);
        Phase memory p = _trigger();
        assertEq(p.succeeded, 1);
        assertGt(p.pushed, 0);
    }

    /// With the 0.1% protocol fee on both legs the same gap is inside the round trip's fees (1.49%): the executor
    /// finds no opportunity instead of trading at a loss.
    function test_protocolFeeOnBothLegsLeavesNoOpportunity() public {
        _protocolFees();
        _moveRef(1.0142e18);
        Phase memory p = _trigger();
        assertEq(p.succeeded, 0);
        assertEq(p.failed, 1);
        assertEq(p.reason, TwoVenueExecutor.NoOpportunity.selector);
    }

    /// With protocol fees on, a 10% gap is recaptured and both legs stop where the last unit breaks even: the subject's
    /// quote prices on the two venues stay at least the round trip's fee factor apart.
    function test_legsStopAtTheFeePricedBreakEven() public {
        _protocolFees();
        _moveRef(1.1e18);
        Phase memory p = _trigger();
        assertEq(p.succeeded, 1);
        assertGt(p.pushed, 0);
        (uint160 sHookr,,,) = manager.getSlot0(key.toId());
        (uint160 sRef,,,) = manager.getSlot0(ref.toId());
        // The subject is currency1, so its quote price is 1 / P. Cheap on the reference venue: P_ref > P_hookr.
        uint256 ratio = FullMath.mulDiv(uint256(sRef) * sRef, 1e18, uint256(sHookr) * sHookr);
        uint256 kept = (1e6 - HOOKR_LEG_FEE) * (1e6 - REF_LEG_FEE);
        // P_ref / P_hookr * R >= 1, to within rounding of the sqrt targets.
        assertGe(ratio * kept / 1e12, 1e18 - 1e9, "no leg traded past the fee-priced break-even");
        assertLt(ratio, 1.1e18, "the gap narrowed");
    }
}
