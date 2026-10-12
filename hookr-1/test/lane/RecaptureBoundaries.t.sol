// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {ScriptedExecutor} from "./mocks/ScriptedExecutor.sol";
import {ScriptedLaneFixture} from "./utils/ScriptedLaneFixture.sol";

/// @notice The recapture split's rounding and King of the Pool's edges, each with a mutation-gate id: the trader's part is
///         floored twice, as its model says, on amounts the other suites keep round (RC-2); a buy that only ties the
///         leader does not take the crown (RC-7); and an idle pot fully released at the 256th closed epoch carries
///         nothing even when it is enormous and releases a quarter at a time (RC-11).
contract RecaptureBoundariesTest is ScriptedLaneFixture {
    /// @dev A quarter of the pot per closed epoch, the slowest release the knob admits, so that a very large pot would
    ///      still be nonzero after 255 epochs: 0.75^255 is about 1.5e-32.
    function _potReleaseBps() internal pure override returns (uint16) {
        return 2_500;
    }

    /// RC-2: on a push whose amount, trader basis and profit are odd, the trader's claim is
    /// floor(floor(min(basis, amount) x rest / amount) x traderBps / 10,000) with rest the push less the protocol's 25% of
    /// the profit, floored: never a unit more.
    function testFuzz_theTraderPartIsFlooredTwice(uint64 amountSeed, uint64 basisSeed) public {
        uint256 amount = 9e18 + (uint256(amountSeed) | 1);
        uint256 basis = 3e18 + (uint256(basisSeed) | 1);
        uint256 protocolPart = amount * PROTOCOL_BPS / 10_000;
        uint256 rest = amount - protocolPart;
        uint256 part = basis < amount ? basis : amount;
        uint256 expected = FullMath.mulDiv(part, rest, amount) * _kothRc().traderBps / 10_000;
        vm.prank(address(root));
        _recap().settleRecapture(key, ETH, whale, amount, basis, amount);
        assertEq(rules.claimable(ETH, whale), expected, "the trader's part, floored twice");
    }

    /// RC-7: a buy of exactly the leader's amount does not take the crown; one unit more does.
    function test_aTieDoesNotTakeTheCrown() public {
        _buy(key, ETH, minnow, 5e20);
        _nextBlock();
        _buy(key, ETH, whale, 5e20);
        (, address leader,,) = _hill(key);
        assertEq(leader, minnow, "the first buy of that size keeps the crown");
        _nextBlock();
        _buy(key, ETH, whale, 5e20 + 1);
        (, leader,,) = _hill(key);
        assertEq(leader, whale, "a larger buy takes it");
    }

    /// RC-11: nothing of an idle pot carries past the 256th closed epoch, however large the pot: it is all released to
    /// the LP accrual, the pot is zero and the Rules stay backed.
    function test_aHugePotIsFullyReleasedAtTheLastEpoch() public {
        vm.deal(address(exec), 1e38);
        exec.set(ScriptedExecutor.Mode.PUSH, 5e37);
        _newActor(key).directSwap(key, true, -1e18, MIN_PRICE);
        (uint64 start,,, uint128 pot) = _hill(key);
        assertGt(pot, 1e37, "an enormous pot");
        vm.warp(uint256(start) + 256 * PERIOD);
        _recap().settleEpoch(id);
        (,,, uint128 carried) = _hill(key);
        assertEq(carried, 0, "256 closed epochs release everything");
        assertTrue(rules.accountingInvariant(ETH));
    }

    /// RC-12: behind an integrator the protocol keeps protocolShareBps x (10,000 - rate) / 10,000 rounded down, and the
    /// prize bound is read on that: at a 25% share and a 3 bps rate the kept share is 2,499, not 2,500, and 10% LP
    /// Rewards leave a bound of 124, not 125.
    function test_theKeptShareBehindAnIntegratorIsFloored() public view {
        assertEq(_recap().prizeBoundFor(1_000, 0, 2_500, 3), 124);
        assertEq(_recap().prizeBoundFor(1_000, 0, 2_500, 0), 125, "no integrator: the whole share");
    }
}
