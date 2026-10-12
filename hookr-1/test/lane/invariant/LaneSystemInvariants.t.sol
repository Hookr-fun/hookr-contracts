// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {IHookrLauncher} from "../../../src/interfaces/IHookrLauncher.sol";
import {IHookrRecaptureRules} from "../../../src/interfaces/IHookrRecaptureRules.sol";
import {ArbSysKit} from "../../kit/ArbSysMock.sol";
import {KothInvariantBase} from "./KothInvariant.t.sol";

/// @notice System invariants for the recapture lane in HookrRoot and King of the Pool in HookrRules, over the King of
///         the Pool campaign (buys, sells, unauthenticated and JIT swaps,
///         washes, lane pushes of every executor mode, time, rollovers and claims): the PoolManager is settled after
///         every call; the root, Router, Quoter and launcher hold no tokens and no PoolManager claims; the Rules hold
///         claims only, exactly their liabilities; the launcher's position equals the PoolManager's. After every run
///         every party exits: the epoch settles, every claimant and the family owner are paid, what remains is exactly
///         the carried pot, and the owner withdraws the whole position.
contract LaneSystemInvariantsTest is KothInvariantBase {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    function _currencies() internal view returns (Currency[4] memory) {
        return [ETH, Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)), _subjectOf(key)];
    }

    function _bal(Currency c, address who) internal view returns (uint256) {
        return c.isAddressZero() ? who.balance : IERC20(Currency.unwrap(c)).balanceOf(who);
    }

    function _family() internal view returns (bytes32) {
        return launcher.poolFamily(key.toId());
    }

    /// The PoolManager is locked with no open delta after every call.
    function invariant_poolManagerSettled() public view {
        assertFalse(manager.isUnlocked(), "PoolManager left unlocked");
        assertEq(manager.getNonzeroDeltaCount(), 0, "nonzero delta count");
    }

    /// The root, Router, Quoter and launcher hold nothing; the Rules hold PoolManager claims only, exactly their
    /// liabilities.
    function invariant_nothingHeld() public view {
        address[4] memory holders = [address(root), address(router), address(quoter), address(launcher)];
        Currency[4] memory cs = _currencies();
        for (uint256 i; i < holders.length; ++i) {
            for (uint256 j; j < cs.length; ++j) {
                assertEq(_bal(cs[j], holders[i]), 0, "periphery or root holds tokens");
                assertEq(manager.balanceOf(holders[i], cs[j].toId()), 0, "periphery or root holds claims");
            }
        }
        for (uint256 j; j < cs.length; ++j) {
            assertEq(_bal(cs[j], address(rules)), 0, "the Rules hold tokens");
            assertEq(manager.balanceOf(address(rules), cs[j].toId()), rules.totalLiability(cs[j]), "Rules claims");
        }
    }

    /// The launcher's recorded position is the PoolManager's.
    function invariant_launcherCustody() public view {
        bytes32 family = _family();
        IHookrLauncher.Position memory p = launcher.position(family, 0);
        bytes32 pk = Position.calculatePositionKey(
            address(launcher), p.tickLower, p.tickUpper, keccak256(abi.encode(family, uint8(0)))
        );
        assertEq(manager.getPositionLiquidity(key.toId(), pk), p.liquidity, "launcher custody mismatch");
    }

    /// Every party exits: the open epoch settles and rolls, its leader (if any) is credited its prize and paid, the
    /// pending LP share is donated, every claimant, the protocol and the family owner are paid, the Rules then hold exactly the carried pot, and the
    /// owner's whole position leaves.
    function afterInvariant() public {
        PoolId id = key.toId();
        IHookrRecaptureRules r = _recap();
        (uint64 start0,,,) = _hill(key);
        (address leader, uint256 prize,) = r.pendingPrize(id);
        uint256 leaderOwed = leader == address(0) ? 0 : rules.claimable(ETH, leader);
        uint256 leaderBalance = leader.balance;
        // After a whole period the epoch is closed, so settleEpoch cannot revert with EpochOpen, its only refusal for a
        // bound King of the Pool pool.
        vm.warp(vm.getBlockTimestamp() + PERIOD + 1);
        r.settleEpoch(id);
        (uint64 start1,,,) = _hill(key);
        assertGt(start1, start0, "epoch did not roll");
        if (leader != address(0)) {
            assertEq(rules.claimable(ETH, leader), leaderOwed + prize, "leader not credited its prize");
        }
        // The pending LP share (the arb recaptures' and the released pot's) is released whole a full release period
        // later, at the first add.
        ArbSysKit.nextParent(vm, RELEASE_PARENTS);
        _newActor(key).modify(key, 800_040, 800_100, 1e18);
        (uint256 d0, uint256 d1, uint256 f0, uint256 f1,) = r.pendingDonation(id);
        assertEq(d0 + d1 + f0 + f1, 0, "nothing left pending after the flush");
        for (uint256 i; i < handler.actorCount(); ++i) {
            address a = handler.actorAt(i);
            if (rules.claimable(ETH, a) == 0) continue;
            vm.prank(a);
            rules.claim(ETH);
        }
        if (leader != address(0)) {
            assertEq(rules.claimable(ETH, leader), 0, "leader's claim left unpaid");
            assertEq(leader.balance, leaderBalance + leaderOwed + prize, "leader not paid its claim and prize");
        }
        if (rules.claimable(ETH, protocol) != 0) {
            vm.prank(protocol);
            rules.claim(ETH);
        }
        bytes32 family = _family();
        if (_accrued(key) != 0) {
            vm.prank(creator);
            launcher.claimRecapture(family, 0, creator);
        }
        if (rules.claimable(ETH, creator) != 0) {
            vm.prank(creator);
            rules.claim(ETH);
        }
        (,,, uint128 pot) = _hill(key);
        assertEq(rules.totalLiability(ETH), pot, "liabilities other than the carried pot left after every exit");
        assertEq(manager.balanceOf(address(rules), ETH.toId()), pot, "claims other than the carried pot");
        IHookrLauncher.Position memory p = launcher.position(family, 0);
        vm.prank(creator);
        launcher.withdraw(family, 0, p.liquidity, 0, 0, creator, vm.getBlockTimestamp());
        bytes32 pk = Position.calculatePositionKey(
            address(launcher), p.tickLower, p.tickUpper, keccak256(abi.encode(family, uint8(0)))
        );
        assertEq(manager.getPositionLiquidity(id, pk), 0, "position left after withdrawal");
        invariant_poolManagerSettled();
        invariant_nothingHeld();
    }

    function _crown() internal {
        handler.buy(0, 3e20);
        handler.buy(1, 2e20);
    }

    /// The exit settles the epoch, pays its leader the prize and leaves only the carried pot.
    function test_afterInvariant_settlesAndPaysTheLeader() public {
        _crown();
        (uint64 start0, address leader,,) = _hill(key);
        (, uint256 prize,) = _recap().pendingPrize(key.toId());
        assertTrue(leader != address(0) && prize != 0, "no crowned leader to settle");
        uint256 before = leader.balance;
        afterInvariant();
        (uint64 start1,,,) = _hill(key);
        assertGt(start1, start0);
        assertGe(leader.balance, before + prize);
    }

    /// The exit fails when the closed epoch cannot be settled.
    function test_afterInvariant_failsWhenSettleEpochReverts() public {
        _crown();
        vm.mockCallRevert(address(rules), abi.encodeWithSelector(IHookrRecaptureRules.settleEpoch.selector), "broken");
        vm.expectRevert(bytes("broken"));
        this.afterInvariant();
    }

    /// The exit fails when settleEpoch returns without rolling the epoch or paying the leader.
    function test_afterInvariant_failsWhenSettleEpochDoesNothing() public {
        _crown();
        (uint64 start,,,) = _hill(key);
        vm.mockCall(address(rules), abi.encodeWithSelector(IHookrRecaptureRules.settleEpoch.selector), "");
        string memory s = vm.toString(uint256(start));
        vm.expectRevert(bytes(string.concat("epoch did not roll: ", s, " <= ", s)));
        this.afterInvariant();
    }
}
