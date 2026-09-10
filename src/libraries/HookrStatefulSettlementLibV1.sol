// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// @notice PoolManager settlement for validated stateful-module actions.
/// @dev External library calls execute in the hook's context. A donation may remain open across
///      the swap when a token-only launch band has no active liquidity at its opening boundary.
library HookrStatefulSettlementLibV1 {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    struct BeforeAction {
        bytes32 moduleId;
        bytes32 attributionKey;
        address module;
        uint128 quoteTake;
        uint128 quoteDonation;
        bool active;
    }

    struct AfterAction {
        bytes32 moduleId;
        bytes32 quoteAttributionKey;
        bytes32 subjectAttributionKey;
        address module;
        address subjectRecipient;
        uint128 quoteTake;
        uint128 subjectTake;
        bool active;
    }

    event StatefulModuleAction(
        PoolId indexed poolId,
        bytes32 indexed moduleId,
        bytes32 indexed attributionKey,
        address currency,
        address recipient,
        uint256 amount,
        bool donation,
        bool afterSwapPhase
    );

    error DeferredDonationUnavailable(PoolId poolId);

    function executeBefore(
        IPoolManager poolManager,
        PoolId poolId,
        PoolKey calldata key,
        address quote,
        BeforeAction[] memory actions,
        uint256 count
    ) external returns (bool quoteDonationDeferred) {
        Currency quoteCurrency = Currency.wrap(quote);
        bool hasActiveLiquidity = poolManager.getLiquidity(poolId) != 0;
        for (uint256 i; i < count; ++i) {
            BeforeAction memory action = actions[i];
            if (!action.active) continue;
            if (action.quoteDonation != 0) {
                if (hasActiveLiquidity) {
                    _donate(poolManager, key, quote, action.quoteDonation);
                } else {
                    quoteDonationDeferred = true;
                }
                emit StatefulModuleAction(
                    poolId,
                    action.moduleId,
                    action.attributionKey,
                    quote,
                    address(poolManager),
                    action.quoteDonation,
                    true,
                    false
                );
            }
            uint256 claimAmount = uint256(action.quoteTake) - action.quoteDonation;
            if (claimAmount != 0) {
                poolManager.mint(action.module, quoteCurrency.toId(), claimAmount);
                emit StatefulModuleAction(
                    poolId, action.moduleId, action.attributionKey, quote, action.module, claimAmount, false, false
                );
            }
        }
    }

    function settleDeferredQuoteDonation(
        IPoolManager poolManager,
        PoolId poolId,
        PoolKey calldata key,
        address quote,
        uint128 amount
    ) external {
        if (amount == 0 || poolManager.getLiquidity(poolId) == 0) {
            revert DeferredDonationUnavailable(poolId);
        }
        _donate(poolManager, key, quote, amount);
    }

    function executeAfter(
        IPoolManager poolManager,
        PoolId poolId,
        address quote,
        address subject,
        AfterAction[] memory actions,
        uint256 count
    ) external {
        Currency quoteCurrency = Currency.wrap(quote);
        Currency subjectCurrency = Currency.wrap(subject);
        for (uint256 i; i < count; ++i) {
            AfterAction memory action = actions[i];
            if (!action.active) continue;
            if (action.quoteTake != 0) {
                poolManager.mint(action.module, quoteCurrency.toId(), action.quoteTake);
                emit StatefulModuleAction(
                    poolId,
                    action.moduleId,
                    action.quoteAttributionKey,
                    quote,
                    action.module,
                    action.quoteTake,
                    false,
                    true
                );
            }
            if (action.subjectTake != 0) {
                poolManager.take(subjectCurrency, action.subjectRecipient, action.subjectTake);
                emit StatefulModuleAction(
                    poolId,
                    action.moduleId,
                    action.subjectAttributionKey,
                    subject,
                    action.subjectRecipient,
                    action.subjectTake,
                    false,
                    true
                );
            }
        }
    }

    function _donate(IPoolManager poolManager, PoolKey calldata key, address quote, uint128 amount) private {
        if (quote == Currency.unwrap(key.currency0)) {
            poolManager.donate(key, amount, 0, "");
        } else {
            poolManager.donate(key, 0, amount, "");
        }
    }
}
