// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title Round-trip record storage
/// @notice Where HookrRulesRoundTrip keeps its round-trip record, apart from HookrRules' own namespace: the one
///         definition of the layout, shared by the Rules (which read it) and HookrRoundTripRecords (which writes it in
///         the Rules' storage).
library HookrRoundTripStorage {
    /// @dev erc7201("hookr.rules.roundtrip").
    bytes32 internal constant SLOT = 0xb7f7ab9efddac12b1fc2a389eae72bda4bc5f1c17b3d9e2ef4a87270114ec600;

    /// @custom:storage-location erc7201:hookr.rules.roundtrip
    struct RoundTrips {
        mapping(PoolId => bool) recording;
        /// @dev blockNumber << 2 | sold << 1 | bought, per pool and trader key.
        mapping(PoolId => mapping(bytes32 => uint256)) words;
    }

    function load() internal pure returns (RoundTrips storage t) {
        assembly ("memory-safe") {
            t.slot := SLOT
        }
    }
}
