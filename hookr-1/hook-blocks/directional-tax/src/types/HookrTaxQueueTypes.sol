// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title Hookr tax queue types
library HookrTaxQueueTypes {
    /// @notice Frozen terms of one queue, carried as ERC-1167 immutable arguments (11 words, 352 bytes).
    /// @dev `routeId == 0` means the creator share is paid out as quote to `assetRecipient`, and `recoveryRecipient`
    ///      and `staleRecoveryDelay` are zero. Otherwise the creator share converts through the route to
    ///      `assetRecipient`, or is paid as quote to `recoveryRecipient` once the route is retired and the recovery
    ///      delay has passed, or once the booked share has waited `staleRecoveryDelay` seconds (the creator's choice
    ///      at launch, within the module's bounds) with no successful conversion.
    struct Terms {
        address root;
        address rules;
        PoolId poolId;
        Currency quote;
        bool isBuy;
        address protocolRecipient;
        uint16 protocolShareBps;
        bytes32 routeId;
        address assetRecipient;
        address recoveryRecipient;
        uint32 staleRecoveryDelay;
    }

    /// @notice Cumulative and outstanding quote accounting of one queue, in raw quote units.
    struct Ledger {
        uint256 protocolOwed;
        uint256 creatorOwed;
        uint256 income;
        uint256 protocolIncome;
        uint256 creatorIncome;
        uint256 protocolSwept;
        uint256 creatorConverted;
        uint256 creatorPaid;
        uint256 outputDelivered;
    }
}
