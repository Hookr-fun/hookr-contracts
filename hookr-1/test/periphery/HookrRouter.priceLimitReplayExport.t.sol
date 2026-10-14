// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {ServiceEventExport} from "../utils/ServiceEventExport.sol";

/// @notice M-09 regression, chain half. Any swap that stops at its sqrtPriceLimitX96 used to make the operator
///         service's LP replay throw "Swap replay mismatch" for every later day, which
///         stopped DailyLPFees and LP-based DailyReferral allocation for the whole program.
/// @dev Original numbers (unfixed service): the app's 5% bound buy consumed 29,043,030,286,051,101,276,492 of
///      1e23 quote and ended exactly at 81,262,209,211,001,084,758,817,408,984; the 2-wei grief sold 2 wei of subject
///      for 0 quote and ended at price - 1. Both histories threw in 6 of 6 later replay windows. This test proves the
///      exploit still works on chain (swaps end exactly at their limits) and exports the histories; the operator
///      service replays them and must match PoolManager storage.
contract HookrRouterPriceLimitReplayExportTest is ServiceEventExport {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    bytes32 private family;
    PoolKey private key;
    HookrToken private subject;
    address private attacker = address(0xBAD);

    function setUp() public {
        _setUpPeriphery();
    }

    /// @dev Control: the same history with limits that never bind.
    function testExportControl() public {
        _launchPool();
        _routerTrade(true, 1e21, 0);
        uint256 tMid = _nextDay();
        _routerTrade(false, 5e20, 0);
        uint256 tLater = _nextDay();
        _routerTrade(true, 2e21, 0);
        _routerTrade(false, 1e21, 0);
        emit log_named_string("M09_VECTOR_CONTROL", _export(tMid, tLater));
    }

    /// @dev The app path: HookrRouter exact-input buy with the app's default 5% bound. The router accepts the fill.
    function testExportAppLimitedBuy() public {
        _launchPool();
        _routerTrade(true, 1e21, 0);
        uint256 tMid = _nextDay();
        (uint160 before,,,) = manager.getSlot0(key.toId());
        bool zeroForOne = Currency.unwrap(key.currency0) != address(subject);
        uint160 limit = _appPriceLimit(before, zeroForOne, 500);
        (uint256 amountIn,) = _routerTrade(true, 1e23, limit);
        (uint160 afterSqrt,,,) = manager.getSlot0(key.toId());
        assertLt(amountIn, 1e23, "partial fill");
        assertEq(afterSqrt, limit, "swap ended exactly at the price limit");
        uint256 tLater = _nextDay();
        _routerTrade(true, 2e21, 0);
        _routerTrade(false, 1e21, 0);
        emit log_named_string("M09_VECTOR_APP_LIMITED_BUY", _export(tMid, tLater));
    }

    /// @dev The grief: an unauthenticated generic caller sells dust with a limit one unit past the price.
    function testExportDustGrief() public {
        _launchPool();
        _routerTrade(true, 1e21, 0);
        uint256 tMid = _nextDay();
        PoolSwapTest swapper = new PoolSwapTest(manager);
        subject.transfer(attacker, 1e6);
        vm.prank(attacker);
        subject.approve(address(swapper), type(uint256).max);
        bool zeroForOne = Currency.unwrap(key.currency0) == address(subject);
        (uint160 before,,,) = manager.getSlot0(key.toId());
        uint160 limit = zeroForOne ? before - 1 : before + 1;
        uint256 s0 = subject.balanceOf(attacker);
        _begin();
        vm.prank(attacker, attacker);
        swapper.swap(key, SwapParams(zeroForOne, -1e6, limit), PoolSwapTest.TestSettings(false, false), "");
        _capture(attacker);
        (uint160 afterSqrt,,,) = manager.getSlot0(key.toId());
        assertEq(afterSqrt, limit, "grief swap ended at its limit");
        assertLe(s0 - subject.balanceOf(attacker), 2, "attack cost <= 2 wei");
        uint256 tLater = _nextDay();
        _routerTrade(true, 2e21, 0);
        _routerTrade(false, 1e21, 0);
        emit log_named_string("M09_VECTOR_DUST_GRIEF", _export(tMid, tLater));
    }

    /// @dev Exact-output variant: a generic caller asks for more quote than the limit allows and is partially filled.
    function testExportExactOutputLimited() public {
        _launchPool();
        _routerTrade(true, 1e21, 0);
        uint256 tMid = _nextDay();
        PoolSwapTest swapper = new PoolSwapTest(manager);
        subject.transfer(attacker, 1e24);
        vm.prank(attacker);
        subject.approve(address(swapper), type(uint256).max);
        bool zeroForOne = Currency.unwrap(key.currency0) == address(subject);
        (uint160 before,,,) = manager.getSlot0(key.toId());
        uint160 limit = _appPriceLimit(before, zeroForOne, 300);
        _begin();
        vm.prank(attacker, attacker);
        swapper.swap(key, SwapParams(zeroForOne, 1e23, limit), PoolSwapTest.TestSettings(false, false), "");
        _capture(attacker);
        (uint160 afterSqrt,,,) = manager.getSlot0(key.toId());
        assertEq(afterSqrt, limit, "exact-output swap ended at its limit");
        uint256 tLater = _nextDay();
        _routerTrade(true, 2e21, 0);
        emit log_named_string("M09_VECTOR_EXACT_OUTPUT_LIMITED", _export(tMid, tLater));
    }

    function _launchPool() private {
        _begin();
        Currency q;
        (family, key, subject, q) = _launch(true, false);
        _capture(address(this));
    }

    function _appPriceLimit(uint160 sqrtP, bool zeroForOne, uint256 bps) private pure returns (uint160) {
        uint256 s = uint256(sqrtP);
        return uint160(Math.sqrt(s * s * (zeroForOne ? 10_000 - bps : 10_000 + bps) / 10_000));
    }

    function _routerTrade(bool buy, uint128 amount, uint160 limit)
        private
        returns (uint256 amountIn, uint256 amountOut)
    {
        _begin();
        IHookrRouter.Swap memory p = _swap(key, buy, true, amount);
        if (limit != 0) p.sqrtPriceLimitX96 = limit;
        vm.prank(trader, trader);
        (amountIn, amountOut) = router.swap(p, address(0), new uint256[](0));
        _capture(trader);
    }

    function _nextDay() private returns (uint256 t) {
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.roll(vm.getBlockNumber() + 7200);
        t = vm.getBlockTimestamp() + 12;
    }

    function _export(uint256 tMid, uint256 tLater) private returns (string memory) {
        int24[] memory ticks = new int24[](2);
        ticks[0] = -60_000;
        ticks[1] = 60_000;
        bytes32[] memory positions = new bytes32[](1);
        positions[0] = _familyPosition(family, -60_000, 60_000);
        _exportPool(key, ticks, positions);
        return _vector(
            string.concat(
                '"familyId":"',
                vm.toString(family),
                '","poolId":"',
                vm.toString(PoolId.unwrap(key.toId())),
                '","owner":"',
                vm.toString(address(this)),
                '","tMid":',
                vm.toString(tMid),
                ',"tLater":',
                vm.toString(tLater),
                ","
            )
        );
    }
}
