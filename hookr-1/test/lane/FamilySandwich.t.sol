// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {console2} from "forge-std/console2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {PartnerShapedFixture} from "./utils/PartnerShapedFixture.sol";

/// @notice Sandwich of a victim's buy on a dynamic fee member, directly on that member and through a cheap static
///         sibling whose family legs carry the move into the victim's member at base fee (and earn the attacker the
///         arb recapture's trader leg). Values are in ETH with tokenB at its connector price (1:1). Held: the outside
///         sandwicher loses both ways at every size.
contract FamilySandwichTest is PartnerShapedFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    HookrToken internal subject;
    Currency internal s;
    Currency internal qb;
    PoolKey internal a;
    PoolKey internal b;
    PoolKey internal refA;
    PoolKey internal refB;
    PoolKey internal conn;

    function setUp() public {
        _setUpPartnerShaped();
        subject = _newSubject();
        subject.approve(address(venue), type(uint256).max);
        s = Currency.wrap(address(subject));
        qb = Currency.wrap(address(tokenB));
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](2);
        members[0] = _laneMemberAt(ETH);
        members[0].rules.maxFeePips = 50_000;
        members[0].rules.dynamicFeeSens = 5;
        members[1] = _laneMemberAt(qb);
        members[1].rules.lpBps = 0;
        (, PoolKey[] memory keys) = _launch(subject, members);
        (a, b) = (keys[0], keys[1]);
        refA = _hookless(a.currency0, a.currency1);
        refB = _hookless(b.currency0, b.currency1);
        conn = _hookless(ETH, qb);
        ex.setTrigger(a, 1e22);
        ex.addVenue(a, refA, PAIR_GAP);
        ex.addCycle(a, b, conn, CYCLE_GAP);
        ex.setTrigger(b, 1e22);
        ex.addVenue(b, refB, PAIR_GAP);
        ex.addCycle(b, a, conn, CYCLE_GAP);
        _nextBlock();
        _buy(a, ETH, minnow, 1e18);
        _nextBlock();
    }

    /// @dev The attacker's value in ETH (tokenB 1:1): ETH + tokenB + both Rules claims + subject at A's price.
    function _value() internal view returns (int256) {
        uint256 v = attacker.balance + tokenB.balanceOf(attacker) + rules.claimable(ETH, attacker)
            + rules.claimable(qb, attacker);
        return int256(v);
    }

    function _subjectBal() internal view returns (uint256) {
        return subject.balanceOf(attacker);
    }

    function _run(bool viaSibling, uint256 x, uint256 victim) internal returns (int256 pnl, uint256 victimOut) {
        int256 v0 = _value();
        uint256 s0 = _subjectBal();
        if (viaSibling) _buy(b, qb, attacker, x);
        else _buy(a, ETH, attacker, x);
        _nextBlock();
        victimOut = _buy(a, ETH, whale, victim);
        _nextBlock();
        uint256 got = _subjectBal() - s0;
        if (viaSibling) _sell(b, qb, attacker, got);
        else _sell(a, ETH, attacker, got);
        pnl = _value() - v0;
    }

    function test_held_sandwichLosesDirectAndThroughTheCheapSibling() public {
        uint256 victim = 3e22;
        uint256 snap = vm.snapshotState();
        uint256 clean = _buy(a, ETH, whale, victim);
        vm.revertToState(snap);
        uint256[3] memory xs = [uint256(1e22), 3e22, 6e22];
        for (uint256 i; i < xs.length; ++i) {
            snap = vm.snapshotState();
            (int256 pDirect, uint256 outDirect) = _run(false, xs[i], victim);
            vm.revertToState(snap);
            (int256 pSib, uint256 outSib) = _run(true, xs[i], victim);
            vm.revertToState(snap);
            console2.log("front-run size", xs[i]);
            console2.log("  attacker P&L direct on the dynamic fee member (wei)");
            console2.logInt(pDirect);
            console2.log("  attacker P&L through the static sibling (wei)");
            console2.logInt(pSib);
            console2.log("  victim subject out: clean / direct / sibling", clean, outDirect, outSib);
            assertLt(pDirect, 0, "the direct sandwich loses");
            assertLt(pSib, 0, "the sandwich through the sibling loses");
        }
    }
}
