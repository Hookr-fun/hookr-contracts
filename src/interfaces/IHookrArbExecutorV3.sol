// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookrArbTypesV3} from "../libraries/HookrArbTypesV3.sol";

interface IHookrArbExecutorV3 {
    function routeAdmissionOpen() external view returns (bool);

    function executionBlockNumber() external view returns (uint64);

    function executeArbitrage(HookrArbTypesV3.ExecutionRequest calldata request)
        external
        returns (uint256 realizedProfitQuote, bytes32 planDigest);
}
