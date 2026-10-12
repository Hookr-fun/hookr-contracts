// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ZapMeshTypes} from "../types/ZapMeshTypes.sol";

/// @title Zap mesh vault
/// @notice Holds the quote that source pools credit to it in HookrRules and spends it, permissionlessly, on buys of up
///         to four gated target pools, through one leg per target.
interface IHookrZapMeshVault {
    error Reentered();
    error InvalidMesh(uint8 code);
    error InvalidRewardRecipient(address rewardTo);
    error NoLiveRoute();
    error BelowThreshold(uint256 available, uint256 threshold);
    error NoRouteCanBuy();
    error NothingDeployed();
    error BalanceMismatch();
    /// @notice Too little gas was left to give the next leg run LEG_GAS; the zap reverts instead of skipping the route.
    error GasTooLow(uint256 needed, uint256 left);

    /// @notice One zap: who called, who got the reward, and every amount it moved.
    event MeshZapped(address indexed caller, address indexed rewardTo, ZapMeshTypes.ZapResult result);
    /// @notice A route was offered quote and its leg failed; the quote stays idle for a later zap (under SPLIT_FILL_GAP
    ///         it goes to the other open routes in the same zap).
    event RouteSkipped(uint8 indexed index, bytes reason);
    /// @notice The quote depth of every route, recorded for SPLIT_FILL_GAP choices in later blocks.
    event DepthsRecorded(uint64 blockNumber, uint256[4] depths);
    /// @notice Hookr's set-aside share was paid to the Rules' protocol recipient.
    event ProtocolPaid(address indexed recipient, uint256 amount);

    /// @notice The HookrZapMeshAccrual this mesh was created for.
    function factory() external view returns (address);
    function rules() external view returns (address);
    function router() external view returns (address);
    function root() external view returns (address);
    function gate() external view returns (address);
    function sink() external view returns (address);
    function quote() external view returns (Currency);
    function mode() external view returns (uint8);
    function split() external view returns (uint8);
    function impactBps() external view returns (uint16);
    function rewardBps() external view returns (uint16);
    function threshold() external view returns (uint128);
    function maxPerZap() external view returns (uint128);
    function windowBlocks() external view returns (uint32);
    function windowScope() external view returns (uint8);
    /// @notice Hookr's share of each claimed source cut: max(accrual.protocolShareBps(), rules.minProtocolShareBps()).
    function protocolShareBps() external view returns (uint16);
    /// @notice The Rules' protocolRecipient, read at construction.
    function protocolRecipient() external view returns (address);
    /// @notice Quote set aside for protocolRecipient and not yet paid. Never spent by a zap.
    function protocolOwed() external view returns (uint256);

    /// @notice How many routes the mesh carries, 1..4.
    function routeCount() external view returns (uint256);
    /// @notice Route `i`: its leg, weight, target and target key.
    function route(uint256 i) external view returns (address leg, uint16 weight, PoolId target, PoolKey memory key);
    /// @notice Every route's leg, in route order.
    function legs() external view returns (address[] memory);
    /// @notice What route `i`'s leg reads when it is made.
    function legSpec(uint256 i) external view returns (ZapMeshTypes.LegSpec memory);
    /// @notice The quote depth snapshot a SPLIT_FILL_GAP zap in this block chooses from (with each route's depth now):
    ///         the newest one taken in an earlier block, and that block (zero when there is none). A record made in this
    ///         block never replaces it.
    function depthSnapshot() external view returns (uint64 blockNumber, uint256[4] memory depths);
    /// @notice Every route's quote depth now: the quote side of its in-range liquidity at its current price.
    function depths() external view returns (uint256[4] memory);

    /// @notice The mesh's own Rules claim, its legs' Rules claims, and the quote it holds idle (set-aside excluded).
    function pending() external view returns (uint256 claimable, uint256 legClaims, uint256 idleQuote);
    /// @notice Whether zap() would pass its route, threshold and impact checks now (a leg can still fail its buy).
    ///         Under SPLIT_FILL_GAP a route also needs quote depth.
    function ready() external view returns (bool);
    /// @notice Whether at least one route is live.
    function routeLive() external view returns (bool);

    /// @notice Records every route's quote depth now, for SPLIT_FILL_GAP zaps in later blocks. Once per block. Anyone.
    ///         It never replaces the snapshot a zap in this block decides on.
    function recordDepths() external returns (bool recorded);
    /// @notice Pays protocolOwed to protocolRecipient. Anyone may call.
    function payProtocol() external returns (uint256 amount);
    /// @notice Claims the mesh's accrual and its legs' refunds and spends them on the live routes. Anyone may call.
    ///         Needs enough gas to give every leg run LEG_GAS, or it reverts GasTooLow.
    /// @param rewardTo Receives the caller reward; must be nonzero when rewardBps is nonzero.
    function zap(address rewardTo) external returns (ZapMeshTypes.ZapResult memory result);
}
