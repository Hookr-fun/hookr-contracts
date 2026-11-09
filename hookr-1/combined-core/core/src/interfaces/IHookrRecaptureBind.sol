// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookrTypes} from "../types/HookrTypes.sol";
/// @notice Internal core route; the core must refuse this selector from its public fallback.
interface IHookrRecaptureBind {
    function bindRecapture(PoolKey calldata key, HookrTypes.PoolConfig calldata pc,
        HookrTypes.RecaptureConfig calldata rc, uint16 potBps, uint32 prizeCapBps, bool funded)
        external returns (uint256 crown);
}
