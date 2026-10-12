// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Gas measurement for the benches. `_measure` snapshots the gas of the last top-level call under a plain
///         English label, into `snapshots/<test contract>.json`. The default profile sets `gas_snapshot_emit = false`,
///         so a plain `forge test` writes nothing and checks nothing; the bench step of CI runs with `--isolate` (every
///         measured call is its own transaction: intrinsic gas, cold access and refunds included) and
///         `FORGE_SNAPSHOT_CHECK=true`, which fails the run when a number differs from the committed file. Refresh the
///         files with `FORGE_SNAPSHOT_EMIT=true forge test --isolate --match-path '<bench paths>'`.
/// @dev Abstract and `is Test` only, so a bench adds it beside whatever fixture it already extends. `snapshotGasLastCall`
///      is the cheatcode Foundry 1.7.1 (the pinned CI version) offers; its result equals `vm.lastCallGas().gasTotalUsed`.
abstract contract GasMeasure is Test {
    /// @dev Records the last call's gas under `label`, logs it, and returns it.
    function _measure(string memory label) internal returns (uint256 gasUsed) {
        gasUsed = vm.snapshotGasLastCall(label);
        console2.log(string.concat("GAS ", label), gasUsed);
    }

    /// @dev Records a derived figure (a difference of two measured calls, a size) under `label`, and logs it.
    function _record(string memory label, uint256 value) internal {
        vm.snapshotValue(label, value);
        console2.log(string.concat("GAS ", label), value);
    }
}
