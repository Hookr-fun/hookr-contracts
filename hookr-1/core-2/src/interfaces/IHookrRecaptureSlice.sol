// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice HookrRecapture's integrator event. In its own file: HookrRules compiles IHookrRecaptureEvents, and the core's
///         creation code, metadata included, must stay what the live owned-root factory's code stores hold.
interface IHookrRecaptureSlice {
    /// @notice The pool's frozen integrator took `amount` of `currency` as a Rules claim: its listed rate of the
    ///         protocol's cut of one arb recapture's push. RecaptureSplit's `protocol` is what the protocol kept after it.
    event RecaptureIntegratorSlice(PoolId indexed id, Currency indexed currency, address indexed integrator, uint256 amount);
}
