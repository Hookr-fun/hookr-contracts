// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {IHookrLpBoost} from "../../src/interfaces/IHookrLpBoost.sol";
import {Chain4663Code} from "../bench/Chain4663Code.sol";
import {LpBoostFixture} from "./LpBoostFixture.sol";

/// @notice HookrLpBoost against the live Robinhood Chain 4663 PoolManager and v4 PositionManager at L2 block
///         74,062,645: the Hookr stack deployed on the fork, a full-range position minted through the real
///         PositionManager into a Hookr pool, staked, rewarded, its fees collected through the real PositionManager
///         and Hookr root, claimed and withdrawn at maturity; and the gauge's reading of an existing live position.
///         Skipped unless ALCHEMY_RPC_URL is set; the fork URL is the `robinhood` alias in foundry.toml.
contract HookrLpBoostForkTest is LpBoostFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant FORK_BLOCK = 74_062_645;
    /// @dev eth_getBlockByNumber(74_062_645).l1BlockNumber: what `block.number` returns inside a contract on Nitro.
    uint256 internal constant FORK_L1_BLOCK = 26_069_826;
    /// @dev A live position at FORK_BLOCK: 74,857,445,855,060,173 liquidity over [300,000, 300,480] in a USDG pool
    ///      with tick spacing 80 and no hooks.
    uint256 internal constant LIVE_TOKEN = 3_357_027;
    bool internal live;

    function setUp() public override {
        if (bytes(vm.envOr("ALCHEMY_RPC_URL", string(""))).length == 0) return;
        vm.createSelectFork("robinhood", FORK_BLOCK);
        vm.roll(FORK_L1_BLOCK);
        _deployStack(IPoolManager(Chain4663Code.POOL_MANAGER_ADDRESS));
        (family, key) = _launch(Currency.wrap(address(quote)), 1e24);
        id = key.toId();
        boost = _deployBoost();
        _activate(boost);
        _listReward(boost, address(reward));
        boost.createGauge(key, _terms(4, 52, 30_000, FLOOR));
        vm.warp(_weekAfter(vm.getBlockTimestamp()));
        live = true;
    }

    function test_fork_pinsTheLivePositionManager() public view {
        if (!live) return;
        assertEq(address(boost.positionManager()), Chain4663Code.POSITION_MANAGER_ADDRESS);
        assertEq(boost.positionManagerCodeHash(), POSITION_MANAGER_CODE_HASH);
        assertEq(address(posm.poolManager()), Chain4663Code.POOL_MANAGER_ADDRESS);
    }

    function test_fork_readsALivePositionExactly() public {
        if (!live) return;
        (PoolKey memory liveKey, uint256 info) = posm.getPoolAndPositionInfo(LIVE_TOKEN);
        int24 lower = int24(int256(info >> 8));
        int24 upper = int24(int256(info >> 32));
        assertEq(lower, 300_000);
        assertEq(upper, 300_480);
        assertEq(uint256(PoolId.unwrap(liveKey.toId())) >> 56, info >> 56);
        uint128 actual = manager.getPositionLiquidity(
            liveKey.toId(), Position.calculatePositionKey(address(posm), lower, upper, bytes32(LIVE_TOKEN))
        );
        assertEq(actual, posm.getPositionLiquidity(LIVE_TOKEN));
        assertEq(actual, 74_857_445_855_060_173);
        // The gauge reads the same position and finds its pool, which has no gauge.
        address holder = posm.ownerOf(LIVE_TOKEN);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.UnknownGauge.selector, liveKey.toId()));
        boost.stake(LIVE_TOKEN, 4);
    }

    function test_fork_stakeEarnCollectClaimWithdraw() public {
        if (!live) return;
        uint256 a = _mintFullRange(alice, 1e21);
        uint256 b = _mintFullRange(bob, 1e21);
        _stake(alice, a, 52);
        _stake(bob, b, 4);
        assertEq(posm.ownerOf(a), address(boost));
        _notify(8e21, 8);
        // Trades on the Hookr pool earn the staked positions LP fees while the gauge pays rewards.
        _swapToTick(key, 1200);
        _swapToTick(key, -1200);
        _swapToTick(key, 0);
        vm.warp(vm.getBlockTimestamp() + 4 weeks);
        uint256 pa = boost.pendingRewards(a);
        uint256 pb = boost.pendingRewards(b);
        assertApproxEqAbs(pa, 3e21, 4);
        assertApproxEqAbs(pb, 1e21, 4);
        address token0 = Currency.unwrap(key.currency0);
        uint256 before0 = IERC20(token0).balanceOf(alice);
        vm.prank(alice);
        boost.collectFees(a, alice);
        assertGt(IERC20(token0).balanceOf(alice), before0);
        assertEq(posm.getPositionLiquidity(a), 1e21);
        assertEq(_claim(alice, a), pa);
        assertEq(reward.balanceOf(alice), pa);
        // Bob's four-week lock has matured: he withdraws his NFT; his rewards stay claimable.
        vm.prank(bob);
        boost.withdraw(b, bob);
        assertEq(posm.ownerOf(b), bob);
        assertEq(boost.owed(id, bob), pb);
        uint48 maturity = boost.stakeOf(a).maturity;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IHookrLpBoost.Locked.selector, a, maturity));
        boost.withdraw(a, alice);
        vm.warp(maturity);
        vm.prank(alice);
        boost.withdraw(a, alice);
        assertEq(posm.ownerOf(a), alice);
        assertLe(boost.gauge(id).paid + boost.owed(id, alice) + boost.owed(id, bob), 8e21);
    }
}
