// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";

/// @title ArbSysMock
/// @notice A stand-in for Nitro's ArbSys precompile at 0x64 that answers only arbBlockNumber(), modelling Robinhood
///         Chain's two clocks: every parent block (block.number, about 12 s) is 120 L2 blocks (about 100 ms each).
///         It answers l2Base + 120 x (block.number - l1Base) + extra, so a plain vm.roll moves both clocks at the
///         Nitro ratio and `extra` moves the L2 clock alone, inside one parent block.
/// @dev Slot 0: l2Base (uint128) | l1Base (uint64) << 128 | extra (uint64) << 192. No fallback: any other selector
///      reverts. Below l1Base the answer stays at l2Base + extra; a test that rolls backwards installs again.
contract ArbSysMock {
    function arbBlockNumber() external view returns (uint256) {
        uint256 w;
        assembly {
            w := sload(0)
        }
        uint256 l1Base = uint64(w >> 128);
        return uint128(w) + (block.number > l1Base ? (block.number - l1Base) * 120 : 0) + uint64(w >> 192);
    }
}

/// @notice Installs and drives ArbSysMock at 0x64. Never stub 0x64 with a NUMBER echo in a test: it makes the L2 clock
///         equal the parent clock and cannot catch a contract that mixes the two.
library ArbSysKit {
    address internal constant ARB_SYS = address(100);
    /// @dev L2 blocks per parent block in the model (measured on Robinhood Chain: 119.65 over three days, 120.0 over
    ///      one).
    uint256 internal constant L2_PER_PARENT = 120;
    /// @dev The default L2 height a test starts at: the fork block the repo pins (foundry.toml fork_block_number), far
    ///      from every parent height a test rolls to.
    uint256 internal constant L2_BASE = 74_062_645;
    /// @dev The parent height of L2_BASE on Robinhood Chain (its header's l1BlockNumber): what block.number returns
    ///      inside a contract there.
    uint256 internal constant PARENT_BASE = 26_069_826;

    /// @dev Puts the mock at 0x64 answering `l2Base` at parent block `l1Base`, with no extra L2 steps.
    function install(Vm vm, uint256 l2Base, uint256 l1Base) internal {
        require(l2Base <= type(uint128).max && l1Base <= type(uint64).max, "ArbSysKit: base out of range");
        vm.etch(ARB_SYS, type(ArbSysMock).runtimeCode);
        vm.store(ARB_SYS, bytes32(0), bytes32(l2Base | (l1Base << 128)));
    }

    /// @dev L2 blocks per second of sequencer-paced blocks (100 ms each), as HookrRecapture's release assumes.
    uint256 internal constant L2_PER_SECOND = 10;

    /// @dev Moves the L2 clock `k` sequencer blocks inside the current parent block, and the time with them at 10 a
    ///      second: every tenth L2-only step is a second later. No roll.
    function stepL2(Vm vm, uint256 k) internal {
        uint256 before = _extra(vm);
        _setExtra(vm, before + k);
        uint256 secs = (before + k) / L2_PER_SECOND - before / L2_PER_SECOND;
        if (secs != 0) vm.warp(vm.getBlockTimestamp() + secs);
    }

    /// @dev Moves the L2 clock `k` blocks that share the current timestamp, as a burst of parent-chain inbox
    ///      (delayed) messages does: each message is its own L2 block. No roll, no warp.
    function inboxBurst(Vm vm, uint256 k) internal {
        _setExtra(vm, _extra(vm) + k);
    }

    function _extra(Vm vm) private view returns (uint256) {
        return uint64(uint256(vm.load(ARB_SYS, bytes32(0))) >> 192);
    }

    function _setExtra(Vm vm, uint256 extra) private {
        require(extra <= type(uint64).max, "ArbSysKit: extra out of range");
        uint256 w = uint256(vm.load(ARB_SYS, bytes32(0)));
        vm.store(ARB_SYS, bytes32(0), bytes32((w & ((1 << 192) - 1)) | (extra << 192)));
    }

    /// @dev Moves `k` parent blocks (and 12k seconds): 120k L2 blocks.
    function nextParent(Vm vm, uint256 k) internal {
        vm.roll(vm.getBlockNumber() + k);
        vm.warp(vm.getBlockTimestamp() + 12 * k);
    }

    /// @dev The L2 height the mock answers now.
    function l2() internal view returns (uint256) {
        return ArbSysMock(ARB_SYS).arbBlockNumber();
    }
}
