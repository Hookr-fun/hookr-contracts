// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ZapMeshTypes} from "../types/ZapMeshTypes.sol";

/// @title Zap mesh leg
/// @notice One route of a zap mesh: the feeder its target's gate lists. It buys the target's subject with quote its
///         mesh hands it, inside one impact window of its own, and gives every quote it holds back to the mesh.
/// @dev Answers the reads the deployed HookrGatedRelay makes of a feeder (`quote`, `windowScope`) and the read a
///      pool-wide zap vault makes of the other feeders of its target (`openAnchor`).
interface IZapMeshLeg {
    error OnlyMesh(address caller);
    error Reentered();
    error TargetNotGated(PoolId target);
    error AmountOutOfRange(uint256 amount);
    error BalanceMismatch();
    error InvalidCallback();
    error UnexpectedNative(address sender);
    /// @notice This window's buys already moved the subject price impactBps above the price its first buy found.
    error ImpactExhausted(uint160 referenceSqrtPriceX96, uint160 currentSqrtPriceX96);

    /// @notice The mesh this leg serves, which alone may hand it quote.
    function mesh() external view returns (address);
    /// @notice The route's position in its mesh, 0..3.
    function index() external view returns (uint8);
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
    function windowBlocks() external view returns (uint32);
    function windowScope() external view returns (uint8);
    /// @notice This leg's impact window, if open: the anchor sqrt price it measures from.
    function openAnchor() external view returns (bool open, uint160 sqrtPriceX96);
    /// @notice Whether the target exists on the root, runs this route's gate (strict, before-swap) with this route's
    ///         Rules and quote, and lists this leg as a feeder. Frozen once the target exists.
    function routeLive() external view returns (bool);
    /// @notice Whether a buy could still move the subject price now: the route is live and its window has room.
    function impactLeft() external view returns (bool);
    /// @notice Own partial-fill refunds credited in Rules since the last pull.
    function refundCredit() external view returns (uint256);
    /// @notice Liquidity of the leg's permanent full-range position in the target pool.
    function positionLiquidity() external view returns (uint128);
    /// @notice Pays the leg's whole Rules claim to the mesh. Only the mesh.
    /// @return amount What the claim paid.
    /// @return extra The part that was not this leg's own refunds (a credit someone else made to the leg).
    function pull() external returns (uint256 amount, uint256 extra);
    /// @notice Buys with `amount` quote the mesh hands it (as value for native, by transferFrom otherwise), adds or
    ///         sends to the sink by mode, and gives every quote it then holds back to the mesh. Only the mesh.
    function run(uint256 amount) external payable returns (ZapMeshTypes.LegResult memory result);
}
