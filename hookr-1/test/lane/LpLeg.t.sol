// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {PartnerShapedFixture} from "./utils/PartnerShapedFixture.sol";
import {Actor} from "./mocks/Actors.sol";

/// @notice RCM-3, fixed: the LP leg follows the pool's in-range liquidity, not the launch position's owner. A family
///         owner that withdraws its whole launch position no longer keeps the LP leg of later arb recaptures; the
///         third-party LP whose liquidity the arb recapture legs trade against collects it as LP fees.
contract MoneyLpLegAttackTest is PartnerShapedFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    HookrToken internal subject;
    PoolKey internal a;
    PoolKey internal refA;
    bytes32 internal family;

    function setUp() public {
        _setUpPartnerShaped();
        subject = _newSubject();
        subject.approve(address(venue), type(uint256).max);
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _laneMemberAt(ETH);
        PoolKey[] memory keys;
        (family, keys) = _launch(subject, members);
        a = keys[0];
        refA = _hookless(a.currency0, a.currency1);
        ex.setTrigger(a, 1e22);
        ex.addVenue(a, refA, PAIR_GAP);
        _nextBlock();
    }

    /// Formerly pinned as a known limit (the LP leg followed the family owner, not liquidity: an owner that had
    /// withdrawn its whole launch position kept every arb recapture's LP leg, 183.83 ETH on a 3e22 buy). The LP leg is
    /// now donated to the pool's in-range liquidity from the next block, so the third party that holds all of it
    /// collects it as LP fees and the empty launch position gets nothing.
    function test_regression_theLpLegFollowsTheLiquidityNotTheEmptyOwner() public {
        Actor lp3 = _newActor(a);
        lp3.modify(a, -60_000, 60_000, int256(1e24));
        launcher.withdraw(family, 0, 1e24, 0, 0, address(this), vm.getBlockTimestamp());
        assertEq(launcher.position(family, 0).liquidity, 0, "launch position is empty");
        _nextBlock();
        vm.recordLogs();
        _buy(a, ETH, whale, 3e22);
        Splits memory sp = _splits(vm.getRecordedLogs());
        assertGt(sp.lp, 1e18, "an LP leg");
        assertEq(_accrued(a), sp.lp, "pending, nothing to the owner");
        // The third party's swap fees of this block.
        lp3.modify(a, -60_000, 60_000, 0);
        _nextBlock();
        // The next block's first add flushes one block of release before landing (out of range, so it shares
        // nothing).
        lp3.modify(a, 60_000, 60_060, 1e18);
        // Then the rest, released whole a full release period later.
        _flushAll(a);
        uint256 before = address(lp3).balance;
        lp3.modify(a, -60_000, 60_000, 0);
        uint256 fees = address(lp3).balance - before;
        console2.log("LP leg collected by the third party holding all liquidity (wei ETH)", fees);
        assertApproxEqAbs(fees, sp.lp, 2, "the whole LP leg");
        assertEq(_accrued(a), 0);
        assertEq(launcher.claimRecapture(family, 0, address(this)), 0, "the empty owner has nothing");
        assertTrue(rules.accountingInvariant(ETH));
    }
}
