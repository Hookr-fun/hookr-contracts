// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookrRevenueToken} from "../interfaces/IHookrRevenueToken.sol";

/// @title Hookr asset list, part of the HookRevenue Tokenizer
/// @notice A revenue token's asset list as immutables: what a door that forwards to the token (the family forwarder,
///         the Fee Beneficiary adapter) reads on every pull without a call or a storage read.
/// @dev The token fixes its assets in its own constructor and never changes them, so one read at construction is
///      exact for good. At most `IHookrRevenueToken.MAX_ASSETS` (4); the slots past `_assetCount` hold zero and are
///      never read.
abstract contract HookrAssetList {
    /// @notice The token has no code.
    error TokenHasNoCode(address token);

    /// @dev How many assets the token has.
    uint256 internal immutable _assetCount;
    Currency private immutable _asset0;
    Currency private immutable _asset1;
    Currency private immutable _asset2;
    Currency private immutable _asset3;

    /// @param token The revenue token; must have code.
    constructor(address token) {
        if (token.code.length == 0) revert TokenHasNoCode(token);
        IHookrRevenueToken t = IHookrRevenueToken(token);
        uint256 n = t.assetCount();
        _assetCount = n;
        _asset0 = t.assetAt(0).currency;
        _asset1 = n > 1 ? t.assetAt(1).currency : Currency.wrap(address(0));
        _asset2 = n > 2 ? t.assetAt(2).currency : Currency.wrap(address(0));
        _asset3 = n > 3 ? t.assetAt(3).currency : Currency.wrap(address(0));
    }

    /// @dev Asset `i` of the token, for `i` below `_assetCount`.
    function _assetAt(uint256 i) internal view returns (Currency) {
        if (i == 0) return _asset0;
        if (i == 1) return _asset1;
        if (i == 2) return _asset2;
        return _asset3;
    }
}
