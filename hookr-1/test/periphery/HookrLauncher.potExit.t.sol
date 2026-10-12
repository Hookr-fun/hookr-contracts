// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

// L-11 (pot half) old numbers: 42.75e15 pot stranded with no exit but the Nth buy. Fixed (OD-1): the pot
// is refused, so no pot liability can exist; every Rules liability is a claimable balance.
// The deferred-donation half is PART B's (Root keeps no ERC-6909 balance at rest).

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {EconomicsSecurityBase} from "../utils/EconomicsSecurityBase.sol";

/// @notice Audit finding L-11.
contract HookrLauncherPotExitTest is EconomicsSecurityBase {
    function testPotRefusedAndLiabilitiesAreAllClaims() public {
        IHookrLauncher.Member memory bad = _member(Currency.wrap(address(0)));
        bad.rules.potBps = 100;
        bad.rules.potEveryNBuys = 2;
        bad.rules.potMinBuyQuote = 1e15;
        _expectLaunchRefused(bad);
        (PoolKey memory key,, Currency quote) = _launchMember(_member(Currency.wrap(address(0))), true);
        _buys(key);
        _assertAllClaims(quote);
    }

    function _buys(PoolKey memory key) internal {
        for (uint256 i; i < 5; ++i) {
            vm.roll(vm.getBlockNumber() + 1);
            _buyAs(trader, key, 1e20);
        }
    }

    function _assertAllClaims(Currency quote) internal view {
        uint256 claims = rules.claimable(quote, protocol) + rules.claimable(quote, royalty);
        assertEq(rules.totalLiability(quote), claims + rules.claimable(quote, trader));
    }
}
