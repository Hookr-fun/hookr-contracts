// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {Fork} from "./Fork.sol";

/// @title Figures
/// @notice Records each measured figure: one line in the test log and one JSON file under figures/, which
///         gas-figures.mjs merges into gas-figures.json. A figure's gas is the difference of two whole transactions,
///         or one whole transaction when its baseline is "absolute".
abstract contract Figures is Fork {
    /// @dev A row of gas-figures.json (README.md). `gas` is signed so that a difference is never clamped.
    struct Figure {
        string id;
        string piece;
        string label;
        string action;
        int256 gas;
        string baseline;
        string router;
        string test;
    }

    /// @dev The values of a figure's `baseline`.
    string internal constant HOOKLESS_POOL = "hookless-pool";
    string internal constant SAME_POOL_WITHOUT_PIECE = "same-pool-without-piece";
    string internal constant ABSOLUTE = "absolute";

    /// @dev The values of a figure's `router`.
    string internal constant UR_CURATED = "Universal Router 2.1.1 (curated by the root)";
    string internal constant UR_NOT_CURATED = "Universal Router (not curated by the root)";
    string internal constant DIRECT = "direct call";

    /// @dev Logs the figure and writes it to figures/<id>.json.
    function _record(Figure memory f) internal {
        console2.log(string.concat("FIGURE ", f.id), f.gas);
        string memory key = string.concat("figure.", f.id);
        vm.serializeString(key, "id", f.id);
        vm.serializeString(key, "piece", f.piece);
        vm.serializeString(key, "label", f.label);
        vm.serializeString(key, "action", f.action);
        vm.serializeInt(key, "gas", f.gas);
        vm.serializeString(key, "baseline", f.baseline);
        vm.serializeString(key, "router", f.router);
        vm.serializeString(key, "test", f.test);
        vm.serializeUint(key, "chainId", block.chainid);
        string memory json = vm.serializeUint(key, "forkBlock", FORK_BLOCK);
        vm.writeJson(json, string.concat("figures/", f.id, ".json"));
    }

    /// @dev `on` minus `off`: the extra gas of a piece.
    function _extra(uint256 on, uint256 off) internal pure returns (int256) {
        return int256(on) - int256(off);
    }

    /// @dev The whole gas of the last call the test made, as a figure's gas.
    function _lastCallGas() internal view returns (int256) {
        return int256(uint256(vm.lastCallGas().gasTotalUsed));
    }
}
