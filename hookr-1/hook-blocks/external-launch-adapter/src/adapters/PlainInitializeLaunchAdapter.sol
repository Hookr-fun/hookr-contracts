// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHookrLaunchAdapter} from "../interfaces/IHookrLaunchAdapter.sol";
import {ExternalHookTypes, IHookrExternalHookBook} from "../interfaces/IHookrExternalHooks.sol";
import {GenericLaunchAdapter} from "./GenericLaunchAdapter.sol";

/// @title PlainInitializeLaunchAdapter
/// @notice The generic adapter for protocol PLAIN_INITIALIZE: a hook that permits `PoolManager.initialize` and a
///         launcher-held v4 position
contract PlainInitializeLaunchAdapter is GenericLaunchAdapter {
    constructor(IPoolManager manager, IHookrExternalHookBook _book, address _launcher)
        GenericLaunchAdapter(manager, _book, _launcher)
    {}

    /// @inheritdoc IHookrLaunchAdapter
    function initProtocolId() external pure returns (bytes32) {
        return ExternalHookTypes.PLAIN_INITIALIZE;
    }

    function _checkProtocolHook(address hook) internal pure override {
        if (hook == address(0)) revert UnsupportedIntent("PROTOCOL_HOOK");
    }
}
