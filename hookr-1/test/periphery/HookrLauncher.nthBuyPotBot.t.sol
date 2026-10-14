// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

// M-05 old numbers: bot won 10/10 jackpots, +225.577e18, 9,869 bps of the honest pot, using a
// revert-unless-win loop on the deterministic Nth-buy counter. Fixed (OD-1): potBps != 0 is refused.

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {EconomicsSecurityBase} from "../utils/EconomicsSecurityBase.sol";

/// @notice Audit finding M-05.
contract HookrLauncherNthBuyPotBotTest is EconomicsSecurityBase {
    function testPocPotConfigRefusedAtLaunch() public {
        IHookrLauncher.Member memory m = _member(Currency.wrap(address(0)));
        m.rules.potBps = 200;
        m.rules.potEveryNBuys = 10;
        m.rules.potMinBuyQuote = 1e15;
        _expectLaunchRefused(m);
    }

    function testWithoutPotBotNeverGainsBeyondOwnRefunds() public {
        (PoolKey memory key,, Currency quote) = _launchMember(_member(Currency.wrap(address(0))), true);
        _buys(key);
        // Full fills produce no refund and there is no prize: the bot's claim never rises.
        assertEq(rules.claimable(quote, trader), 0);
        assertTrue(rules.accountingInvariant(quote));
    }

    function _buys(PoolKey memory key) internal {
        for (uint256 i; i < 100; ++i) {
            vm.roll(vm.getBlockNumber() + 1);
            _buyAs(trader, key, 1e18);
        }
    }
}
