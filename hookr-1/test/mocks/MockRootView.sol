// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

/// @notice Stands in for HookrRoot: only `curatedRouter()` is read by the guard (core delta C5).
contract MockRootView {
    address public curatedRouter;

    constructor(address curated) {
        curatedRouter = curated;
    }
}
