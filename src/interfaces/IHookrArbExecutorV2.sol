// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookrArbTypesV2} from "../libraries/HookrArbTypesV2.sol";

interface IHookrArbExecutorV2 {
    /// @notice Whether new pools may select this executor-backed profile.
    /// @dev Existing pools remain fail-open when route admission is later paused: their ordinary
    ///      swaps continue, while unsigned/disabled correction attempts fail inside the isolated
    ///      executor call. The integration registry uses this only at immutable market admission.
    function routeAdmissionOpen() external view returns (bool);

    function executeArbitrage(HookrArbTypesV2.ExecutionRequest calldata request)
        external
        returns (uint256 realizedProfitQuote, bytes32 planDigest);
}
