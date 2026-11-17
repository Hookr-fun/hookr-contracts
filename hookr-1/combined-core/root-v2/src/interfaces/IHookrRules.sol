// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTypes} from "../types/HookrTypes.sol";

/// @title IHookrRules
/// @notice Interface for HookrRules, the native fee and settlement module a HookrRoot pool binds at launch.
interface IHookrRules {
    /// @notice Returns the identifier of the supported Hookr rules configuration.
    /// @return The schema hash of the configuration these Rules read.
    function configSchemaHash() external pure returns (bytes32);

    /// @notice Returns the immutable Uniswap v4 PoolManager.
    /// @return The PoolManager.
    function poolManager() external view returns (IPoolManager);

    /// @notice Returns the only root authorized to bind and settle these rules.
    /// @return The root.
    function trustedRoot() external view returns (address);

    /// @notice Freezes one pool configuration. Only the permanently trusted root can call.
    /// @param key The pool.
    /// @param config The pool's identity, trusted modules and execution limits.
    /// @param data The pool's ABI-encoded rules configuration.
    /// @return configHash The hash of the configuration frozen for the pool.
    function bind(PoolKey calldata key, HookrTypes.PoolConfig calldata config, bytes calldata data)
        external
        returns (bytes32 configHash);

    /// @notice Enforces the launch guard on liquidity additions.
    /// @param id The pool.
    /// @param sender The account adding liquidity.
    function beforeAddLiquidity(PoolId id, address sender) external view;

    /// @notice Returns the parent-clock block.number before which principal removal is refused, or zero.
    /// @param id The pool.
    /// @return untilBlock The parent-clock block before which removal is refused, or zero.
    function removalLockedUntil(PoolId id) external view returns (uint256 untilBlock);

    /// @notice Quotes the native rules from the authenticated context.
    /// @dev Not view: Rules may record per-swap state. Root calls it with CALL. HookrRules quote a pool with Hookr
    ///      dynamic fees through `IHookrDynamicFeeRules.quoteSimulatedSwap` instead.
    /// @param context The swap's authenticated context.
    /// @return The fees the Rules quote for the swap.
    function beforeSwap(HookrTypes.SwapContext calldata context) external returns (HookrTypes.FeeQuote memory);

    /// @notice Credits actual-fill fees and refunds as Rules liabilities and returns the credited quote amount.
    /// @dev credited = rulesFee + advisoryFee + refund. Nothing is donated.
    /// @param context The swap's authenticated context.
    /// @param settlement What the swap actually settled.
    /// @return credited The quote credited: the rules fee, the advisory fee and the refund.
    function settleSwap(HookrTypes.SwapContext calldata context, HookrTypes.Settlement calldata settlement)
        external
        returns (uint256 credited);

    /// @notice Protocol fee credited in this transaction by swaps whose authenticated payer is `payer`. Transient.
    /// @param payer The swap's authenticated payer.
    /// @param quote The quote currency.
    /// @return amount The protocol fee credited in this transaction.
    function protocolFeePaid(address payer, Currency quote) external view returns (uint256 amount);

    /// @notice Returns the beneficiary's backed claim in raw currency units.
    /// @param currency The currency.
    /// @param beneficiary The account.
    /// @return The account's backed claim in raw currency units.
    function claimable(Currency currency, address beneficiary) external view returns (uint256);

    /// @notice Pays the caller's claim to the caller, up to the PoolManager amount limit.
    /// @param currency The currency.
    /// @return The amount paid.
    function claim(Currency currency) external returns (uint256);

    /// @notice Pays only the caller's claim to the chosen recipient.
    /// @param currency The currency.
    /// @param to The recipient.
    /// @return The amount paid.
    function claimTo(Currency currency, address to) external returns (uint256);

    /// @notice Returns whether owned PoolManager claims cover the currency liabilities.
    /// @param currency The currency.
    /// @return True when the owned claims cover the liabilities.
    function accountingInvariant(Currency currency) external view returns (bool);
}
