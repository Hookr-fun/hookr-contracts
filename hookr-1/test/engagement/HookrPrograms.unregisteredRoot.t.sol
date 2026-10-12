// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrReferralRegistry} from "../../src/engagement/HookrReferralRegistry.sol";
import {HookrPrograms} from "../../src/engagement/HookrPrograms.sol";
import {IHookrPrograms} from "../../src/interfaces/IHookrPrograms.sol";
import {HookrProgramTypes as P} from "../../src/types/HookrProgramTypes.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";

contract MimicRoot {
    address public poolManager;
    bytes32 public ph;
    address public quote;

    constructor(address pm, bytes32 h, address q) {
        poolManager = pm;
        ph = h;
        quote = q;
    }

    function knownPool(PoolId) external pure returns (bool) {
        return true;
    }

    function policyHash(PoolId) external view returns (bytes32) {
        return ph;
    }

    function poolConfig(PoolId) external view returns (HookrTypes.PoolConfig memory c) {
        c.quote = Currency.wrap(quote);
    }
}

/// I-13: program scopes could name any contract imitating the root interface; the scope was accepted but could never
/// be credited (the router trades only registered roots) and the service refused to allocate it.
///
/// Before the fix (base b7aeae64, B16Verify.testC1_MimicRootScopeAcceptedButNeverCreditable): an Immediate program
/// with a MimicRoot scope was created (10,000 of cash reserved against it) and every opted-in swap on the real pool
/// reverted InvalidScope.
/// Fix: the validator requires registry.isRoot(scope.root) through the pinned router's registry.
contract HookrProgramsUnregisteredRootTest is PeripheryFixture {
    using PoolIdLibrary for PoolKey;

    HookrPrograms programs;
    PoolKey key;

    function setUp() public {
        _setUpPeriphery();
        (, key,,) = _launch(true, false);
        programs =
            new HookrPrograms(manager, address(router), address(this), 10_000, address(new HookrReferralRegistry()));
    }

    function testMimicRootScopeIsRejected() public {
        MimicRoot fake = new MimicRoot(
            address(manager), root.policyHash(key.toId()), Currency.unwrap(root.poolConfig(key.toId()).quote)
        );
        assertFalse(registry.isRoot(address(fake)));
        P.Scope[] memory s = new P.Scope[](1);
        s[0] = P.Scope(address(fake), PoolId.unwrap(key.toId()), fake.ph(), fake.quote(), 1, 1e15, 0, 0);
        P.Terms memory t;
        t.mode = P.Mode.Immediate;
        t.start = uint64((vm.getBlockTimestamp() / 1 days + 1) * 1 days);
        t.end = t.start + 1 days;
        t.pointBudget = 1000;
        t.walletPointCap = 1000;
        t.pointNumerator = 1;
        t.pointDenominator = 1;
        t.sourcePolicyHash = keccak256("policy");
        t.name = "Program";
        t.pointDecimals = 18;
        P.NFTMetadata memory md;
        vm.expectRevert(IHookrPrograms.InvalidScope.selector);
        programs.createProgram(t, s, new P.Milestone[](0), md);
        s[0].root = address(root);
        programs.createProgram(t, s, new P.Milestone[](0), md); // the real root is still accepted
    }
}
