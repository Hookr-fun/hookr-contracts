// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {console2} from "forge-std/console2.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookrPairRoot} from "../../src/interfaces/IHookrPairRoot.sol";
import {IHookrRegistry} from "../../src/interfaces/IHookrRegistry.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {HookrFeeAdvisory} from "../../src/extensions/HookrFeeAdvisory.sol";
import {IHookrFeeAdvisory} from "../../src/interfaces/IHookrFeeAdvisory.sol";
import {HookrSessionAdvisory} from "../../src/extensions/HookrSessionAdvisory.sol";
import {HookrSessionTiers} from "../../src/libraries/HookrSessionTiers.sol";
import {PairRootFixture} from "./PairRootFixture.sol";

/// @dev Gas of `HookrRootFactory.deploy` for a fixed-fee pair root, for one with an advisory, and for one bound in
///      HookrFeeAdvisory with and without session tiers under the fork rehearsal's factory admission (cap 2,000,
///      advisory gas 60,000). `-vvvv` shows the `bindPair` frame. Run with
///      `forge test --isolate --match-path test/factory/PairRootDeployGas.t.sol -vv`.
contract PairRootDeployGasTest is PairRootFixture {
    HookrFeeAdvisory internal fee;

    /// @dev The release's registry delay.
    function _registryDelay() internal pure override returns (uint48) {
        return 30 minutes;
    }

    function setUp() public {
        _setUpFactory();
        HookrSessionAdvisory session = new HookrSessionAdvisory(address(this), 30 minutes);
        fee = new HookrFeeAdvisory(address(this), 30 minutes, IHookrRegistry(address(registry)), address(session));
        IHookrRegistry.Admission memory a = IHookrRegistry.Admission({
            kind: IHookrRegistry.Kind.ADVISORY,
            implementation: address(fee),
            codeHash: address(fee).codehash,
            schemaHash: fee.configSchemaHash(),
            caps: HookrTypes.Caps(2_000, 0, 0),
            gasLimit: 60_000,
            phaseMask: HookrTypes.BEFORE_SWAP,
            feeOnly: true,
            failOpen: false
        });
        registry.queue(registry.ADMIT(), abi.encode(address(factory), a));
        vm.warp(vm.getBlockTimestamp() + registry.delay());
        registry.admit(address(factory), a);
    }

    function _measure(string memory label, IHookrPairRoot.Params memory p) internal {
        _measure(label, p, "");
    }

    function _measure(string memory label, IHookrPairRoot.Params memory p, bytes memory data)
        internal
        returns (PoolId id)
    {
        bytes32 salt = _mine(deployer, p);
        vm.prank(deployer);
        uint256 before = gasleft();
        (, id) = factory.deploy(salt, p, SQRT_ONE, data);
        console2.log(label, before - gasleft());
    }

    function _feeParams() internal view returns (IHookrPairRoot.Params memory p) {
        (Currency c0, Currency c1) = _eth();
        p = _advised(c0, c1, 3_000, 2_000, false);
        p.advisory = address(fee);
        p.advisoryGasLimit = fee.MIN_TIERED_GAS();
    }

    function _feeConfig() internal pure returns (IHookrFeeAdvisory.Config memory) {
        return IHookrFeeAdvisory.Config(2_000, 500, 0, 0, 1_000, 60, 1 hours);
    }

    function test_gas_deployPlain() public {
        (Currency c0, Currency c1) = _eth();
        _measure("GAS deploy pair root, no advisory", _plain(c0, c1, 3_000));
    }

    function test_gas_deployAdvised() public {
        (Currency c0, Currency c1) = _eth();
        _measure("GAS deploy pair root, advisory", _advised(c0, c1, 3_000, 2_000, false));
    }

    function test_gas_deployFeeAdvisory() public {
        _measure("GAS deploy pair root, HookrFeeAdvisory", _feeParams(), abi.encode(_feeConfig()));
    }

    /// The tiered bind stores a second slot. The rehearsal's admission gas, 60,000, is MIN_TIERED_GAS, so it admits a
    /// tiered pair root at exactly the floor; bindPair itself runs with all remaining gas.
    function test_gas_deployFeeAdvisoryTiered() public {
        PoolId id = _measure(
            "GAS deploy pair root, HookrFeeAdvisory + tiers",
            _feeParams(),
            abi.encode(_feeConfig(), HookrSessionTiers.Tiers(300, 600, 600, 800, 1_000, 1_800, 1_800, 1))
        );
        assertEq(fee.sessionTiers(id).cap, 2_000);
    }
}
