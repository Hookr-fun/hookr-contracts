// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title HookrClock
/// @notice Robinhood Chain's own (L2) block number, as ArbSys.arbBlockNumber() at 0x64 returns it: the including
///         block, equal to eth_blockNumber. block.number there is the parent chain's height (about 12 s a step,
///         about 120 L2 blocks). No fallback: a pool's release stamps only ever hold L2 heights.
/// @dev The read forwards at most READ_GAS (20,000) gas. On Robinhood Chain it costs about 906 (the warm precompile);
///      a cold Solidity stand-in in a test costs about 5,000, which the cap leaves room for. The cap also bounds what
///      the read can burn where 0x64 holds the Nitro placeholder 0xfe (INVALID), as on a fork or a local node, which
///      would otherwise take 63/64 of the frame. Anything but a 32-byte answer between 1 and type(uint64).max reverts
///      ClockUnavailable (0x02ed49eb). There is no chain-id gate: Hookr 1 runs on Robinhood Chain only.
library HookrClock {
    /// @dev The most gas the ArbSys read forwards.
    uint256 internal constant READ_GAS = 20_000;

    error ClockUnavailable();

    /// @dev ArbSys.arbBlockNumber(): the L2 height of the block that includes the call.
    function l2Block() internal view returns (uint256 height) {
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
