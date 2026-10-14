// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {PeripheryFixture} from "./PeripheryFixture.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";

/// @notice G-02 (phase-one review, Appendix A, Low): HookrLauncher.withdraw compared `min0`/`min1` with what the
///         PoolManager paid, the principal plus every fee the position accrued since it was last touched, while the
///         app builds and shows them as principal floors.
/// @dev Regression for the fix: `_modify` compares the principal, the removal's delta less the fees `modifyLiquidity`
///      reports, with the bounds, and still pays both. The review's scenario: a family owner sets 1% floors on the
///      principal at the price it saw, a sell lands first and cuts the quote principal by about 2%, and the quote
///      fees the position had accrued used to fill the gap, so the withdrawal cleared below the owner's floor. It now
///      reverts `Slippage`. Fees are read from the PoolManager's own position and fee growth state before each call.
contract HookrLauncherWithdrawMinimumsTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    bytes32 private family;
    PoolKey private key;

    function setUp() public {
        _setUpPeriphery();
        // The subject sorts first: currency1 is the quote, which buys pay and which carries LP Rewards.
        (family, key,,) = _launch(true, false);
        // Ordinary trading accrues fees to the family position in both currencies.
        for (uint256 i; i < 20; ++i) {
            _trade(true, 1e23);
            _trade(false, 1e23);
        }
    }

    /// @dev The review's front-run, now refused on both withdraw entry points: the fees no longer fill a principal
    ///      shortfall below the owner's floor, though principal plus fees still clears it.
    function testFeesNoLongerFillAShortfallBelowTheFloor() public {
        IHookrLauncher.Position memory pos = launcher.position(family, 0);
        (uint256 seen0, uint256 seen1) = _principal(pos, pos.liquidity);
        // The owner's floors: 99% of the principal the position holds at the price it saw.
        uint256 min0 = seen0 * 99 / 100;
        uint256 min1 = seen1 * 99 / 100;

        // A sell lands first and cuts the quote principal.
        _trade(false, 2e22);
        (uint256 principal0, uint256 principal1) = _principal(pos, pos.liquidity);
        (, uint256 fee1) = _fees(pos);
        assertLt(principal1, min1, "the quote principal fell below the owner's floor");
        assertGe(principal1 + fee1, min1, "the accrued quote fees cover the shortfall, as the old check counted them");
        assertGe(principal0, min0, "the subject side rose, as a sell moves it");

        vm.expectRevert(IHookrLauncher.Slippage.selector);
        launcher.withdraw(family, 0, pos.liquidity, min0, min1, address(this), vm.getBlockTimestamp());
        vm.expectRevert(IHookrLauncher.Slippage.selector);
        launcher.withdrawWithClaims(family, 0, pos.liquidity, min0, min1, address(this), 3, vm.getBlockTimestamp());
        assertEq(launcher.position(family, 0).liquidity, pos.liquidity, "the position is whole");
    }

    /// @dev The bounds compare with the principal exactly: one unit above it on either side refuses the removal,
    ///      however large the fees, and the principal itself passes. The call pays the principal and every fee the
    ///      position accrued, as LPFeesCollected reports, and returns both.
    function testBoundsAreThePrincipalAndFeesArePaidOnTop() public {
        IHookrLauncher.Position memory pos = launcher.position(family, 0);
        uint128 half = pos.liquidity / 2;
        (uint256 principal0, uint256 principal1) = _principal(pos, half);
        (uint256 fee0, uint256 fee1) = _fees(pos);
        assertGt(fee0, 0, "accrued subject fees");
        assertGt(fee1, 0, "accrued quote fees");

        vm.expectRevert(IHookrLauncher.Slippage.selector);
        launcher.withdraw(family, 0, half, principal0 + 1, 0, address(this), vm.getBlockTimestamp());
        vm.expectRevert(IHookrLauncher.Slippage.selector);
        launcher.withdraw(family, 0, half, 0, principal1 + 1, address(this), vm.getBlockTimestamp());

        address recipient = address(0xBEEF);
        vm.recordLogs();
        (uint256 amount0, uint256 amount1) =
            launcher.withdraw(family, 0, half, principal0, principal1, recipient, vm.getBlockTimestamp());
        (uint256 paid0, uint256 paid1) = _feesCollected(vm.getRecordedLogs());
        assertEq(paid0, fee0, "LPFeesCollected reports the subject fees");
        assertEq(paid1, fee1, "and the quote fees");
        assertEq(amount0, principal0 + fee0, "currency0: principal plus fees");
        assertEq(amount1, principal1 + fee1, "currency1: principal plus fees");
        assertEq(key.currency0.balanceOf(recipient), amount0, "the recipient received currency0");
        assertEq(key.currency1.balanceOf(recipient), amount1, "and currency1");
        assertEq(launcher.position(family, 0).liquidity, pos.liquidity - half, "half the liquidity left");
    }

    /// @dev A fee collection removes no liquidity and pays no principal: a nonzero bound refuses it whatever fees are
    ///      due, and zero bounds collect them all.
    function testFeeCollectionPassesZeroBounds() public {
        IHookrLauncher.Position memory pos = launcher.position(family, 0);
        (uint256 fee0, uint256 fee1) = _fees(pos);
        assertGt(fee0, 0, "accrued subject fees");
        assertGt(fee1, 0, "accrued quote fees");

        vm.expectRevert(IHookrLauncher.Slippage.selector);
        launcher.withdraw(family, 0, 0, 1, 0, address(this), vm.getBlockTimestamp());
        vm.expectRevert(IHookrLauncher.Slippage.selector);
        launcher.withdraw(family, 0, 0, 0, 1, address(this), vm.getBlockTimestamp());

        (uint256 amount0, uint256 amount1) =
            launcher.withdraw(family, 0, 0, 0, 0, address(this), vm.getBlockTimestamp());
        assertEq(amount0, fee0, "the collection pays the subject fees");
        assertEq(amount1, fee1, "and the quote fees");
        assertEq(launcher.position(family, 0).liquidity, pos.liquidity, "and leaves the liquidity");
    }

    /// @dev What removing `liquidity` of the position pays at the current price, fees excluded: the PoolManager's own
    ///      rounding for a removal (down).
    function _principal(IHookrLauncher.Position memory pos, uint128 liquidity)
        private
        view
        returns (uint256 amount0, uint256 amount1)
    {
        uint160 lower = TickMath.getSqrtPriceAtTick(pos.tickLower);
        uint160 upper = TickMath.getSqrtPriceAtTick(pos.tickUpper);
        (uint160 price, int24 tick,,) = manager.getSlot0(key.toId());
        assertTrue(tick >= pos.tickLower && tick < pos.tickUpper, "the position is in range");
        amount0 = SqrtPriceMath.getAmount0Delta(price, upper, liquidity, false);
        amount1 = SqrtPriceMath.getAmount1Delta(lower, price, liquidity, false);
    }

    /// @dev The fees the position accrued since it was last touched, as the PoolManager computes them on the next
    ///      modifyLiquidity (Position.update): the fee growth inside the range since the position's snapshot times its
    ///      liquidity.
    function _fees(IHookrLauncher.Position memory pos) private view returns (uint256 fee0, uint256 fee1) {
        bytes32 salt = keccak256(abi.encode(family, uint8(0)));
        (uint128 liquidity, uint256 last0, uint256 last1) =
            manager.getPositionInfo(key.toId(), address(launcher), pos.tickLower, pos.tickUpper, salt);
        assertEq(liquidity, pos.liquidity, "the launcher's position in the PoolManager");
        (uint256 inside0, uint256 inside1) = manager.getFeeGrowthInside(key.toId(), pos.tickLower, pos.tickUpper);
        unchecked {
            fee0 = FullMath.mulDiv(inside0 - last0, liquidity, FixedPoint128.Q128);
            fee1 = FullMath.mulDiv(inside1 - last1, liquidity, FixedPoint128.Q128);
        }
    }

    function _trade(bool buy, uint128 amount) private {
        IHookrRouter.Swap memory p = _swap(key, buy, true, amount);
        vm.prank(trader);
        router.swap(p, address(0), new uint256[](0));
    }

    function _feesCollected(Vm.Log[] memory logs) private view returns (uint256 fee0, uint256 fee1) {
        bytes32 topic = IHookrLauncher.LPFeesCollected.selector;
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(launcher) && logs[i].topics[0] == topic) {
                (,, fee0, fee1) = abi.decode(logs[i].data, (uint8, address, uint256, uint256));
                ++n;
            }
        }
        assertEq(n, 1, "one LPFeesCollected");
    }
}
