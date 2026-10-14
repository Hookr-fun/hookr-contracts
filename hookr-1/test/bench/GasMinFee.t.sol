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

/// @notice Gas of swaps and a launch on a Hookr token's pool whose Rules pay a HookrTreasury, as the release deploys
///         them: a pool without rules (fee-only before r25, the minimum's full path after it) and a pool with 2% LP
///         Rewards at an 80/20 split (which binds no minimum from r31: its LP Rewards earn Hookr a share). Run with
///         --isolate so every measured call is its own transaction.
contract GasMinFeeBench is GovernanceSecurityBase, GasMeasure {
    Currency internal constant NATIVE = Currency.wrap(address(0));

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
        subject = new HookrToken("S", "S", 1e30, address(this));
        subject.approve(address(launcher), type(uint256).max);
        subject.transfer(trader, 1e27);
        vm.prank(trader);
        subject.approve(address(router), type(uint256).max);
        vm.deal(trader, 1e30);
    }

    /// @dev No rules: no dynamic fee, Snipe, LP Rewards, Auto Burn or royalty; the base fee alone.
    function _plain() internal view returns (IHookrLauncher.Member[] memory members) {
        members = new IHookrLauncher.Member[](1);
        members[0] = _member(NATIVE);
        members[0].config.rules = address(r2);
        members[0].rules.burnBps = 0;
        members[0].rules.lpBps = 0;
        members[0].rules.royaltyBps = 0;
        members[0].rules.royaltyTo = address(0);
        members[0].rules.protocolShareBps = 2_000;
    }

    /// @dev LP Rewards 2% at an 80/20 split.
    function _rewards() internal view returns (IHookrLauncher.Member[] memory members) {
        members = _plain();
        members[0].rules.lpBps = 200;
    }

    function _launch(IHookrLauncher.Member[] memory members) internal returns (PoolKey memory) {
        (bytes32 family,) = launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            members,
            vm.getBlockTimestamp()
        );
        return launcher.position(family, 0).key;
    }

    function _next() internal {
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 12);
    }

    function _buy(PoolKey memory key) internal {
        _next();
        IHookrRouter.Swap memory p = _swap(key, true, true, 1 ether);
        vm.prank(trader);
        router.swap{value: 1 ether}(p, address(0), new uint256[](0));
    }

    function _sell(PoolKey memory key) internal {
        _next();
        IHookrRouter.Swap memory p = _swap(key, false, true, 1 ether);
        vm.prank(trader);
        router.swap(p, address(0), new uint256[](0));
    }

    function test_gas_minFee_launch_plain() public {
        launcher.launch{value: 1e24}(
            IHookrLauncher.Token(address(subject), "", "", 0, bytes32(0)),
            address(root),
            _plain(),
            vm.getBlockTimestamp()
        );
        _measure("minfee.launch.plain");
    }

    function test_gas_minFee_plainBuy() public {
        PoolKey memory key = _launch(_plain());
        _buy(key);
        _buy(key);
        _measure("minfee.plain.buy");
    }

    function test_gas_minFee_plainSell() public {
        PoolKey memory key = _launch(_plain());
        _sell(key);
        _sell(key);
        _measure("minfee.plain.sell");
    }

    function test_gas_minFee_rewardsBuy() public {
        PoolKey memory key = _launch(_rewards());
        _buy(key);
        _buy(key);
        _measure("minfee.rewards.buy");
    }
}
