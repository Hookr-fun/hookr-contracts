// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

// L-08 old numbers: after a bot bought the per-block cap and sold it back, every honest buy reverted for
// the whole parent block. Fixed: sells net the same-block guard counter.

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {EconomicsSecurityBase} from "../utils/EconomicsSecurityBase.sol";

/// @notice Audit finding L-08.
contract HookrLauncherGuardCapGriefTest is EconomicsSecurityBase {
    address internal honest = address(0x2002);
    uint128 internal constant CAP = 1e21;

    function _guarded() internal returns (PoolKey memory key, HookrToken subject, Currency quote) {
        IHookrLauncher.Member memory m = _member(Currency.wrap(address(0)));
        m.rules.guardEndBlock = uint40(block.number + 100);
        m.rules.maxBuyQuoteAmount = CAP;
        (key, subject, quote) = _launchMember(m, true);
        HookrToken(Currency.unwrap(quote)).transfer(honest, 1e24);
        vm.prank(honest);
        HookrToken(Currency.unwrap(quote)).approve(address(router), type(uint256).max);
    }

    function testBuyThenSellDoesNotBlockHonestBuy() public {
        (PoolKey memory key,,) = _guarded();
        (, uint256 bought) = _buyAs(trader, key, CAP);
        // Build the sell before the prank: _swap makes external calls (root.poolConfig) that would consume a prank
        // placed in front of router.swap(_swap(...)), making the test contract the seller.
        IHookrRouter.Swap memory sell = _swap(key, false, true, uint128(bought));
        vm.prank(trader);
        router.swap(sell, address(0), new uint256[](0));
        _buyAs(honest, key, 1e18);
    }

    function testHeldCapBlocksOnlyThisParentBlock() public {
        (PoolKey memory key,,) = _guarded();
        _buyAs(trader, key, CAP);
        IHookrRouter.Swap memory p = _swap(key, true, true, 1e18);
        p.recipient = honest;
        vm.prank(honest);
        vm.expectRevert();
        router.swap(p, address(0), new uint256[](0));
        vm.roll(vm.getBlockNumber() + 1);
        _buyAs(honest, key, 1e18);
    }
}
