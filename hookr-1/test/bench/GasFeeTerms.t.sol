// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {HookrTreasury} from "../../src/support/HookrTreasury.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";
import {IHookrRouter} from "../../src/interfaces/IHookrRouter.sol";
import {HookrToken} from "../../src/support/HookrToken.sol";
import {GovernanceSecurityBase} from "../utils/GovernanceSecurityBase.sol";
import {GasMeasure} from "../utils/GasMeasure.sol";

/// @notice Gas of a launch and of a steady-state rule-fee buy on Rules that pay a HookrTreasury, as the release deploys
///         them, with and without an integrator. Run with --isolate so every measured call is its own transaction.
contract GasFeeTermsBench is GovernanceSecurityBase, GasMeasure {
    Currency internal constant NATIVE = Currency.wrap(address(0));
    address internal constant INTEGRATOR = address(0x1A7E);

    HookrTreasury internal treasury;
    HookrRules internal r2;
    HookrToken internal subject;

    function setUp() public {
        _setUpPeriphery();
        treasury = new HookrTreasury(address(this), address(0x7A7), manager);
        r2 = new HookrRules(manager, registry, address(treasury), address(root), 2_000);
        IHookrRegistry.Admission memory a = _rulesAdmission(address(r2), address(r2).codehash, r2.configSchemaHash());
        registry.queue(registry.ADMIT(), abi.encode(address(root), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(root), a);
        treasury.admitSource(address(r2));
        _listIntegrator();
        subject = new HookrToken("S", "S", 1e30, address(this));
        subject.approve(address(launcher), type(uint256).max);
        vm.deal(trader, 1e30);
    }

    function _members(bool integrated) internal view returns (IHookrLauncher.Member[] memory members) {
        members = new IHookrLauncher.Member[](1);
        members[0] = _member(NATIVE);
        members[0].config.rules = address(r2);
        members[0].rules.royaltyBps = 0;
        members[0].rules.royaltyTo = address(0);
        _name(members[0], integrated);
    }

    function _launchNative(IHookrLauncher.Member[] memory members) internal returns (PoolKey memory) {
        (bytes32 family,) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            vm.getBlockTimestamp()
        );
        return launcher.position(family, 0).key;
    }

    function _buy(PoolKey memory key) internal {
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 12);
        IHookrRouter.Swap memory p = _swap(key, true, true, 1 ether);
        vm.prank(trader);
        router.swap{value: 1 ether}(p, address(0), new uint256[](0));
    }

    function _launchOnly(IHookrLauncher.Member[] memory members) internal {
        launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            vm.getBlockTimestamp()
        );
    }

    function test_gas_terms_launch_1member() public {
        _launchOnly(_members(false));
        _measure("terms.launch.1member");
    }

    function test_gas_terms_ruleFeeBuy() public {
        PoolKey memory key = _launchNative(_members(false));
        _buy(key);
        _buy(key);
        _measure("terms.ruleFeeBuy");
    }

    // r23 only: the integrator cases.

    function test_gas_terms_launch_1member_integrator() public {
        _launchOnly(_members(true));
        _measure("terms.launch.1member.integrator");
    }

    function test_gas_terms_ruleFeeBuy_integrator() public {
        PoolKey memory key = _launchNative(_members(true));
        _buy(key);
        _buy(key);
        _measure("terms.ruleFeeBuy.integrator");
    }

    /// The worst case of an integrated buy: the integrator emptied its claim slot (here with claimAsClaims, which moves
    /// no token), so the next buy writes it from zero.
    function test_gas_terms_ruleFeeBuy_integratorDrained() public {
        PoolKey memory key = _launchNative(_members(true));
        _buy(key);
        vm.prank(INTEGRATOR);
        r2.claimAsClaims(NATIVE, INTEGRATOR);
        _buy(key);
        _measure("terms.ruleFeeBuy.integrator.drained");
    }

    function _listIntegrator() internal {
        treasury.proposeIntegrator(INTEGRATOR, 5_000);
        vm.warp(vm.getBlockTimestamp() + treasury.TERMS_DELAY());
        treasury.acceptIntegrator(INTEGRATOR);
    }

    function _name(IHookrLauncher.Member memory m, bool integrated) internal pure {
        if (integrated) m.rules.integrator = INTEGRATOR;
    }
}
