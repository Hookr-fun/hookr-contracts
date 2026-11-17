// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @title HookrTime
/// @notice Hookr 1's two clocks, chosen by chain id, so every block-count bound keeps its wall-time meaning on each
///         chain the release runs on.
///         - The parent clock (`parentBlock`) counts the launch guard, the liquidity and principal locks and every
///           other bound written in "parent blocks" of about 12 seconds (HookrTypes.PARENT_BLOCK_SECONDS):
///           - Robinhood Chain (4663): block.number, which there is the parent chain's (Ethereum's) height.
///           - Ethereum (1): block.number, its own 12-second slots.
///           - Monad (143): block.timestamp / 12. Monad's own blocks are about 0.3 s, so its block.number would run
///             every bound about 40 times short; a twelfth of the timestamp keeps them at their 12-second pace, and
///             every block within one 12-second window reads the same parent block, as on Robinhood Chain.
///           - The local test chain (31337) and any other chain: block.number, as on Robinhood Chain. A release
///             never runs on another chain: HookrRoot's and HookrRules' constructors call `checkChain`, which reverts
///             UnsupportedChain on any chain but these four, so nothing that reads the parent clock can be deployed
///             where its pace is unknown. The check sits in the constructors, not in every read, because a read
///             inlines into HookrLane, whose runtime is within a hundred bytes of EIP-170's limit.
///         - The release tick (`releaseTick`) paces the arb recapture release at about ten ticks a second:
///           - Ethereum and Monad: block.timestamp x 10. Every call in one second reads the same tick.
///           - Robinhood Chain and every other chain: ArbSys.arbBlockNumber() at 0x64, the L2 height of the including
///             block. No fallback: a pool's release stamps only ever hold one kind of reading. Where 0x64 does not
///             answer as Nitro's ArbSys does, it reverts ClockUnavailable.
/// @dev The ArbSys read forwards at most READ_GAS (20,000) gas. On Robinhood Chain it costs about 906 (the warm
///      precompile); a cold Solidity stand-in in a test costs about 5,000, which the cap leaves room for. The cap also
///      bounds what the read can burn where 0x64 holds the Nitro placeholder 0xfe (INVALID), as on a fork or a local
///      node, which would otherwise take 63/64 of the frame. Anything but a 32-byte answer between 1 and
///      type(uint64).max reverts ClockUnavailable (0x02ed49eb). The tick stays below type(uint64).max, as every release
///      stamp must, for any timestamp below 1.8e18, and the parent block below type(uint40).max, as every guard and
///      lock end must, for any timestamp below 1.3e13.
library HookrTime {
    /// @dev The most gas the ArbSys read forwards.
    uint256 internal constant READ_GAS = 20_000;
    /// @dev Robinhood Chain's chain id: block.number is the parent chain's height, and ArbSys answers at 0x64.
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    /// @dev Ethereum's chain id: block.number is a 12-second slot, and the release tick is the timestamp's.
    uint256 internal constant ETHEREUM_CHAIN_ID = 1;
    /// @dev Monad's chain id: the parent clock and the release tick both come from the timestamp.
    uint256 internal constant MONAD_CHAIN_ID = 143;
    /// @dev The local test chain's id (forge and anvil): block.number, as on Robinhood Chain.
    uint256 internal constant LOCAL_CHAIN_ID = 31_337;
    /// @dev The parent block's length in seconds on Monad, HookrTypes.PARENT_BLOCK_SECONDS.
    uint256 internal constant PARENT_SECONDS = 12;
    /// @dev The release tick's steps a second: Robinhood Chain's L2 blocks a second while traffic fills every 100 ms
    ///      block, the pace of HookrRecapture's release bounds and wall-time cap.
    uint256 internal constant TICKS_PER_SECOND = 10;

    error ClockUnavailable();
    error UnsupportedChain();

    /// @dev The parent block: block.timestamp / 12 on Monad, block.number everywhere else (checkChain keeps a release
    ///      off any chain but Robinhood Chain, Ethereum, Monad and the local test chain).
    function parentBlock() internal view returns (uint256) {
        return block.chainid == MONAD_CHAIN_ID ? block.timestamp / PARENT_SECONDS : block.number;
    }

    /// @dev Reverts UnsupportedChain unless this is Robinhood Chain, Ethereum, Monad or the local test chain: the
    ///      chains whose parent clock and release tick this library knows.
    function checkChain() internal view {
        uint256 id = block.chainid;
        if (id != ROBINHOOD_CHAIN_ID && id != ETHEREUM_CHAIN_ID && id != MONAD_CHAIN_ID && id != LOCAL_CHAIN_ID) {
            revert UnsupportedChain();
        }
    }

    /// @dev The release tick: block.timestamp x 10 on Ethereum and Monad; elsewhere ArbSys.arbBlockNumber(), the L2
    ///      height of the block that includes the call.
    function releaseTick() internal view returns (uint256 height) {
        if (block.chainid == ETHEREUM_CHAIN_ID || block.chainid == MONAD_CHAIN_ID) {
            return block.timestamp * TICKS_PER_SECOND;
        }
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
