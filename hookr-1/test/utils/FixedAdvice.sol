// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrAdvisory} from "../../src/interfaces/IHookrAdvisory.sol";

contract FixedAdvice is IHookrAdvisory {
    HookrTypes.Advice private _before;
    HookrTypes.Advice private _after;
    bool private immutable _fail;
    bool private immutable _dirty;

    constructor(HookrTypes.Advice memory before_, HookrTypes.Advice memory after_, bool fail_, bool dirty_) {
        _before = before_;
        _after = after_;
        _fail = fail_;
        _dirty = dirty_;
    }

    function configSchemaHash() external pure returns (bytes32) {
        return keccak256("test.advice");
    }

    function bind(PoolKey calldata, HookrTypes.PoolConfig calldata, bytes calldata data)
        external
        pure
        returns (bytes32)
    {
        return keccak256(data);
    }

    function beforeAddLiquidity(PoolId, address) external pure returns (bool) {
        return true;
    }

    function beforeSwap(HookrTypes.SwapContext calldata) external view returns (HookrTypes.Advice memory) {
        if (_fail) revert();
        if (_dirty) {
            assembly ("memory-safe") {
                mstore(0, shl(255, 1))
                mstore(32, 0)
                mstore(64, 0)
                mstore(96, 0)
                return(0, 128)
            }
        }
        return _before;
    }

    function afterSwap(HookrTypes.SwapContext calldata, int128, int128)
        external
        view
        returns (HookrTypes.Advice memory)
    {
        return _after;
    }
}
