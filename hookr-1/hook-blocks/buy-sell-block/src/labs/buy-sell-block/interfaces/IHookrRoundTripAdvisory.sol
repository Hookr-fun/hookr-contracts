// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Round-trip advisory marker
/// @notice An advisory that answers `ROUND_TRIP_ADVISORY()` with `ROUND_TRIP_MAGIC` asks a round-trip Rules module
///         to record the pools it is bound to.
interface IHookrRoundTripAdvisory {
    /// @notice Returns ROUND_TRIP_MAGIC.
    function ROUND_TRIP_ADVISORY() external view returns (bytes32);
}
