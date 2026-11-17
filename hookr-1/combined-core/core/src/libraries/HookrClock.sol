// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title HookrClock
/// @notice The arb recapture release clock, calibrated to ten ticks a second. On Robinhood Chain (4663), ArbSys
///         at 0x64 returns its own L2 height: the including block, equal to eth_blockNumber. block.number there is
///         the parent chain's height (about 12 s a step, about 120 L2 blocks). Every other chain uses
///         block.timestamp x 10 and reads no precompile, preserving the release bounds' wall-time meaning.
/// @dev The read forwards at most READ_GAS (20,000) gas. On Robinhood Chain it costs about 906 (the warm precompile);
///      a cold Solidity stand-in in a test costs about 5,000, which the cap leaves room for. The cap also bounds what
///      the read can burn where 0x64 holds the Nitro placeholder 0xfe (INVALID), as on a fork or a local node, which
///      would otherwise take 63/64 of the frame. Anything but a 32-byte answer between 1 and type(uint64).max reverts
///      ClockUnavailable (0x02ed49eb). The timestamp clock fits uint64 for timestamps below 1.8e18.
library HookrClock {
    /// @dev The most gas the ArbSys read forwards.
    uint256 internal constant READ_GAS = 20_000;
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4_663;
    uint256 internal constant TICKS_PER_SECOND = 10;

    error ClockUnavailable();

    /// @dev ArbSys only on 4663; timestamp ticks everywhere else (extensibility E6, decision D25).
    function l2Block() internal view returns (uint256 height) {
        if (block.chainid != ROBINHOOD_CHAIN_ID) return block.timestamp * TICKS_PER_SECOND;
        bool ok;
        assembly ("memory-safe") {
            mstore(0, shl(224, 0xa3b1b31d)) // arbBlockNumber()
            ok := staticcall(READ_GAS, 0x64, 0, 4, 0, 32)
            // A statement of its own: Yul evaluates arguments right to left, so returndatasize() inside the call's
            // own expression would be read before the call.
            ok := and(ok, eq(returndatasize(), 32))
            height := mload(0)
        }
        if (!ok || height == 0 || height > type(uint64).max) revert ClockUnavailable();
    }
}
