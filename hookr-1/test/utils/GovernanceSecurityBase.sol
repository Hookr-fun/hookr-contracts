// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PeripheryFixture} from "../periphery/PeripheryFixture.sol";
import {HookrRoot} from "../../src/core/HookrRoot.sol";
import {HookrRules} from "../../src/core/HookrRules.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrLauncher} from "../../src/interfaces/IHookrLauncher.sol";

/// @notice Shared helpers for the governance-lane regression tests.
abstract contract GovernanceSecurityBase is PeripheryFixture {
    function _rulesAdmission(address impl, bytes32 codeHash, bytes32 schema)
        internal
        pure
        returns (IHookrRegistry.Admission memory)
    {
        return IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.RULES,
            implementation: impl,
            codeHash: codeHash,
            schemaHash: schema,
            caps: HookrTypes.Caps(600_000, 200_000, 1000),
            gasLimit: 2_000_000,
            phaseMask: 3,
            feeOnly: false,
            failOpen: false
        });
    }

    function _launchOn(address rootAddr, address rulesAddr, int24 spacing) internal returns (PoolKey memory key) {
        IHookrLauncher.Member[] memory members = new IHookrLauncher.Member[](1);
        members[0] = _member(Currency.wrap(address(tokenB)));
        members[0].tickSpacing = spacing;
        members[0].config.rules = rulesAddr;
        (bytes32 family,) = launcher.launch(
            IHookrLauncher.Token(address(tokenA), "", "", 0, bytes32(0)), rootAddr, members, vm.getBlockTimestamp()
        );
        key = launcher.position(family, 0).key;
    }

    /// @dev External wrapper so a reverting launch can be asserted with expectRevert.
    function launchExternal(address rootAddr, address rulesAddr, int24 spacing) external returns (PoolKey memory) {
        return _launchOn(rootAddr, rulesAddr, spacing);
    }

    /// @dev CREATE2 salt from this test contract that gives a root its PERMISSION_FLAGS bits.
    function _rootSalt(address routerAddr, address quoterAddr, address curated)
        internal
        view
        returns (bytes32 salt, address predicted)
    {
        bytes32 initHash = keccak256(
            abi.encodePacked(
                type(HookrRoot).creationCode, abi.encode(manager, registry, routerAddr, quoterAddr, curated)
            )
        );
        for (uint256 i = 1_000_000;; ++i) {
            predicted = vm.computeCreate2Address(bytes32(i), initHash, address(this));
            if (uint160(predicted) & 0x3fff == root.PERMISSION_FLAGS()) return (bytes32(i), predicted);
        }
    }

    function _secondRoot() internal returns (HookrRoot second) {
        (bytes32 salt,) = _rootSalt(address(router), address(quoter), address(0));
        second = new HookrRoot{salt: salt}(manager, registry, address(router), address(quoter), address(0));
    }
}
