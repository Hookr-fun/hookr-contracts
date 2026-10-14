// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRules} from "../../src/interfaces/IHookrRules.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {IHookrRootEvents} from "../../src/interfaces/IHookrRootEvents.sol";
import {IHookrRulesEvents} from "../../src/interfaces/IHookrRulesEvents.sol";

/// @notice RL-02: bind refused an integrator that could never claim what settleSwap credits it (the Rules, their
///         trusted root, the PoolManager and their HookrRecapture module), but accepted any of them as royaltyTo, which
///         the same settleSwap credits on every swap. The config is frozen at bind, so every royalty the pool ever paid
///         became a Rules claim nobody could claim. Bind now refuses those four as the royalty recipient with
///         InvalidConfig, which a launch reports as the root's ModuleCallReverted.
contract HookrRulesRoyaltyToUnclaimableTest is PeripheryFixture {
    function setUp() public {
        _setUpPeriphery();
    }

    /// @dev PeripheryFixture's member (LP Rewards 200 bps, Auto Burn 100 bps, royalty 500 bps of LP Rewards) on a token
    ///      quote, with the royalty paid to `to`.
    function launchWithRoyaltyTo(address to) external returns (PoolKey memory key, Currency quote) {
        bool aFirst = address(tokenA) < address(tokenB);
        HookrToken subject = aFirst ? tokenA : tokenB;
        quote = Currency.wrap(aFirst ? address(tokenB) : address(tokenA));
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(quote);
        members[0].rules.royaltyTo = to;
        (bytes32 family,) = launcher.launch(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
    }

    /// @dev The accounts that can never claim a Rules claim: the Rules, their trusted root, the PoolManager and their
    ///      HookrRecapture module.
    function _cannotClaim() internal view returns (address[4] memory list) {
        (bool ok, bytes memory out) = address(rules).staticcall(abi.encodeWithSignature("recaptureModule()"));
        require(ok, "rules call");
        (address module,) = abi.decode(out, (address, bytes32));
        assertEq(rules.trustedRoot(), address(root), "the fixture root is the Rules' trusted root");
        list = [address(rules), address(root), address(manager), module];
    }

    /// The PoC: a launch naming any of them as the royalty recipient is refused at bind.
    function test_bindRefusesEveryAccountThatCanNeverClaimAsRoyaltyRecipient() public {
        address[4] memory cannotClaim = _cannotClaim();
        for (uint256 i; i < cannotClaim.length; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IHookrRootEvents.ModuleCallReverted.selector,
                    address(rules),
                    IHookrRules.bind.selector,
                    abi.encodeWithSelector(IHookrRulesEvents.InvalidConfig.selector)
                )
            );
            this.launchWithRoyaltyTo(cannotClaim[i]);
        }
    }

    /// Any other recipient still binds, and a buy credits it the royalty it can claim.
    function test_aRoyaltyRecipientThatCanClaimStillBindsAndIsCredited() public {
        address recipient = address(0x7A11);
        (PoolKey memory key, Currency quote) = this.launchWithRoyaltyTo(recipient);
        IHookrRouter.Swap memory p = _swap(key, true, true, 1e21);
        vm.prank(trader);
        router.swap(p, address(0), new uint256[](0));
        uint256 credited = rules.claimable(quote, recipient);
        assertGt(credited, 0, "the royalty is credited");
        vm.prank(recipient);
        rules.claim(quote);
        assertEq(rules.claimable(quote, recipient), 0, "and claimed");
    }
}
