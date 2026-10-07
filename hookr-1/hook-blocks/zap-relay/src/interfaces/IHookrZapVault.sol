// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ZapRelayTypes} from "../types/ZapRelayTypes.sol";

/// @title Zap vault
/// @notice Holds one route's accrued quote as a HookrRules claim and spends it, permissionlessly, on the gated target.
interface IHookrZapVault {
    error Reentered();
    error InvalidRoute(uint8 code);
    error InvalidRewardRecipient(address rewardTo);
    error TargetNotGated(PoolId target);
    error BelowThreshold(uint256 available, uint256 threshold);
    error AmountOutOfRange(uint256 amount);
    error BalanceMismatch();
    error InvalidCallback();
    error UnexpectedNative(address sender);
    /// @notice This impact window's zaps already moved the subject price impactBps above the price its first zap found.
    error ImpactExhausted(uint160 referenceSqrtPriceX96, uint160 currentSqrtPriceX96);

    /// @notice One zap: who called, who got the reward, and every amount it moved.
    event Zapped(address indexed caller, address indexed rewardTo, ZapRelayTypes.ZapResult result);
    /// @notice Hookr's set-aside share of the source cuts was paid to the Rules' protocol recipient.
    event ProtocolPaid(address indexed recipient, uint256 amount);

    /// @notice The HookrZapAccrual this vault was created for (read from its deployer at construction).
    function factory() external view returns (address);
    function rules() external view returns (address);
    function router() external view returns (address);
    function root() external view returns (address);
    function gate() external view returns (address);
    function sink() external view returns (address);
    function quote() external view returns (Currency);
    function subject() external view returns (Currency);
    function targetId() external view returns (PoolId);
    function targetKey() external view returns (PoolKey memory);
    function mode() external view returns (uint8);
    function impactBps() external view returns (uint16);
    function rewardBps() external view returns (uint16);
    function threshold() external view returns (uint128);
    function maxPerZap() external view returns (uint128);
    function windowBlocks() external view returns (uint32);
    function windowScope() external view returns (uint8);
    /// @notice Hookr's share of each claimed source cut: max(accrual.protocolShareBps(), rules.minProtocolShareBps()).
    function protocolShareBps() external view returns (uint16);
    /// @notice The target Rules' protocolRecipient, read at construction.
    function protocolRecipient() external view returns (address);
    /// @notice Quote set aside for protocolRecipient and not yet paid. Never spent by a zap.
    function protocolOwed() external view returns (uint256);
    /// @notice Own partial-fill refunds credited back in Rules and not yet claimed; they carry no protocol share.
    function refundCredit() external view returns (uint256);
    /// @notice This vault's impact window, if open: the anchor sqrt price it measures from.
    function openAnchor() external view returns (bool open, uint160 sqrtPriceX96);

    /// @notice Pays protocolOwed to protocolRecipient. Anyone may call.
    function payProtocol() external returns (uint256 amount);

    /// @notice The route's claim in HookrRules and the quote and subject the vault holds idle (quote set aside for the
    ///         protocol excluded).
    function pending() external view returns (uint256 claimable, uint256 idleQuote, uint256 idleSubject);

    /// @notice Whether zap() would pass its target, threshold and impact-window checks now (it can still fail on the
    ///         buy itself).
    function ready() external view returns (bool);

    /// @notice Whether the route is live: the target pool exists on the route's root, its frozen advisory is the route's
    ///         gate (strict, before-swap), its Rules and quote are the route's, and the gate lists this vault. The
    ///         target's config and feeder list are frozen, so once the target exists this answer never changes.
    function routeLive() external view returns (bool);

    /// @notice Liquidity of the vault's permanent full-range position in the target pool.
    function positionLiquidity() external view returns (uint128);

    /// @notice Claims the route's accrual and spends it on the gated target. Anyone may call.
    /// @param rewardTo Receives the caller reward; must be nonzero when rewardBps is nonzero.
    function zap(address rewardTo) external returns (ZapRelayTypes.ZapResult memory result);
}
