// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrLpBoost} from "../../src/interfaces/IHookrLpBoost.sol";
import {LpBoostFixture} from "./LpBoostFixture.sol";

/// @notice HookrLpBoost gas per entry on the etched 4663 runtimes, each the last call's total. Ceilings are the
///         measured figure plus about 5%; the accrual walk's worst case closes a drop at each of 104 weeks in one call.
contract HookrLpBoostGasTest is LpBoostFixture {
    using PoolIdLibrary for PoolKey;

    function _measure(string memory label, uint256 ceiling) internal view {
        Vm.Gas memory g = vm.lastCallGas();
        console2.log(string.concat("GAS ", label), g.gasTotalUsed);
        assertLe(g.gasTotalUsed, ceiling, label);
    }

    function test_gas_createGauge() public {
        (, PoolKey memory k2) = _launch(Currency.wrap(address(0)), 1e24);
        IHookrLpBoost.Terms memory t = _terms(4, 52, 30_000);
        boost.createGauge(k2, t);
        _measure("createGauge", 217_000);
    }

    function test_gas_notifyAndFund() public {
        _mintAndStake(alice, 1e18, 4);
        reward.approve(address(boost), 4e21);
        boost.notify(id, 4e21, 4);
        _measure("notify.first", 196_000);
        vm.warp(vm.getBlockTimestamp() + 1 weeks);
        reward.approve(address(boost), 1e21);
        boost.fund(id, 1e21, 3);
        _measure("fund", 113_000);
        // A notify beside the running tranches, ending at a later boundary.
        vm.warp(vm.getBlockTimestamp() + 1 weeks);
        reward.approve(address(boost), 1e22);
        boost.notify(id, 1e22, 4);
        _measure("notify.running", 119_000);
    }

    function test_gas_stake() public {
        uint256 a = _mintFullRange(alice, 1e18);
        uint256 b = _mintFullRange(bob, 1e18);
        vm.prank(alice);
        posm.approve(address(boost), a);
        vm.prank(bob);
        posm.approve(address(boost), b);
        vm.prank(alice);
        boost.stake(a, 52);
        _measure("stake.first", 229_000);
        _notify(4e21, 4);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(bob);
        boost.stake(b, 28);
        _measure("stake.boosted", 248_000);
    }

    /// @dev The gauge is kept current by a weekly poke (not measured), as the ops keeper does.
    function test_gas_claimExtendCollectWithdraw() public {
        uint256 a = _mintAndStake(alice, 1e21, 28);
        _mintAndStake(bob, 1e21, 52);
        _notify(52e21, 52);
        _swapToTick(key, 600);
        _swapToTick(key, -600);
        vm.warp(vm.getBlockTimestamp() + 2 weeks);
        uint256[] memory ids = new uint256[](1);
        ids[0] = a;
        vm.prank(alice);
        boost.claim(id, ids, alice);
        _measure("claim.one", 166_000);
        vm.prank(alice);
        boost.collectFees(a, alice);
        _measure("collectFees", 185_000);
        vm.prank(alice);
        boost.extend(a, 30);
        _measure("extend", 80_000);
        uint256 maturity = boost.stakeOf(a).maturity;
        while (vm.getBlockTimestamp() + 1 weeks < maturity) {
            vm.warp(vm.getBlockTimestamp() + 1 weeks);
            boost.poke(id);
        }
        vm.warp(maturity);
        vm.prank(alice);
        boost.withdraw(a, alice);
        _measure("withdraw.atMaturity", 168_000);
    }

    function test_gas_pokeWalks() public {
        uint256 a = _mintAndStake(alice, 1e18, 52);
        _notify(52e21, 52);
        vm.warp(vm.getBlockTimestamp() + 1 weeks);
        boost.poke(id);
        _measure("poke.oneWeek.noDrop", 79_000);
        // One boost ends 51 weeks later and nobody touches the gauge meanwhile: the walk reads every week.
        vm.warp(boost.stakeOf(a).maturity);
        boost.poke(id);
        _measure("poke.idle51Weeks.oneDrop", 324_000);
        // A drop at every one of 104 weeks, then nobody touches the gauge until all of them have passed.
        (, PoolKey memory k2) = _launch(Currency.wrap(address(0)), 1e24);
        boost.createGauge(k2, _terms(1, 104, 30_000));
        for (uint16 w = 1; w <= 104; ++w) {
            uint256 tokenId = _mint(alice, k2, -887_220, 887_220, 1e18);
            vm.startPrank(alice);
            posm.approve(address(boost), tokenId);
            boost.stake(tokenId, w);
            vm.stopPrank();
        }
        reward.approve(address(boost), 104e21);
        boost.notify(k2.toId(), 104e21, 52);
        vm.warp(vm.getBlockTimestamp() + 106 weeks);
        boost.poke(k2.toId());
        _measure("poke.104drops", 3_133_000);
        assertEq(boost.gauge(k2.toId()).totalWeight, 104e18);
    }
}
