// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrTypes} from "../types/HookrTypes.sol";

/// @notice The combined core's pinned, delegated block protocol.
/// @dev Only blockMasks is directly callable. All hook entries reject direct calls on the module itself.
/// The core authenticates hook callers, appends the tails documented in HookrBlockCall, and preserves msg.sender.
interface IHookrBlock {
    /// @dev Eight uint32 lanes: bind, add, quoteBuy, quoteSell, settleBuy, settleSell, guardOnly, charging.
    /// cold: owned cold fields in bits0..127, cold-reader hot mask in bits128..159, zero above bit159.
    function blockMasks() external pure returns (uint256 hooks, uint256 cold);

    /// @dev Tail: context, cold, hot, protocolShareBps. Returns one packed HookrBlockBound word.
    function blockBind(PoolKey calldata key, HookrTypes.PoolConfig calldata pc) external returns (uint256 bound);

    /// @dev Tail: context, cold. Invoked in a static context; this entry writes nothing.
    function blockAddLiquidity(PoolId id, address sender) external;

    /// @dev Tail: context, cold, lp, take, burn, hookr. Returns all four running words after its additions.
    /// Static context must not write persistent or transient state. Simulation is zero outside the simulated path.
    function blockQuote(HookrTypes.SwapContext calldata x, HookrTypes.SwapSimulation calldata m)
        external returns (uint256 lp, uint256 take, uint256 burn, uint256 hookr);

    /// @dev Tail: context, cold, finalTake, protocol. Returns the protocol word after its creator carves.
    function blockSettle(HookrTypes.SwapContext calldata x, HookrTypes.Settlement calldata z)
        external returns (uint256 protocol);

    /// @dev Tail: context, cold. Reached only through locked/not-claiming core blockCall; no hook selector is exposed.
    function blockOut(bytes calldata data) external returns (bytes memory);
}
