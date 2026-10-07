// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHookrAdvisory} from "hookr/interfaces/IHookrAdvisory.sol";
import {IZapSessionTiered} from "./IZapSessionTiered.sol";

/// @title Gated relay advisory
/// @notice Target-pool advisory: a buy is accepted only when the root-authenticated payer is one of the pool's frozen
///         feeders. Sells are never rejected, and are charged only the pool's frozen session surcharge, if it bound
///         tiers. Liquidity may be added only by the pool's liquidity owner (the launcher) or a feeder, which closes
///         the range-order side door.
interface IHookrGatedRelay is IHookrAdvisory, IZapSessionTiered {
    error InvalidTerms(uint8 code);
    error InvalidPoolConfig(uint8 code);
    error AlreadyBound(address binder, PoolId id);

    event GateBound(
        address indexed binder, PoolId indexed id, address indexed factory, address[] feeders, address liquidityOwner
    );

    /// @notice Whether `account` is a frozen feeder of the pool a binder (the root) stored.
    function isFeeder(address binder, PoolId id, address account) external view returns (bool);

    /// @notice The frozen gate a binder stored for a pool.
    function gateOf(address binder, PoolId id)
        external
        view
        returns (bool bound, address liquidityOwner, address factory, address[] memory feeders);
}
