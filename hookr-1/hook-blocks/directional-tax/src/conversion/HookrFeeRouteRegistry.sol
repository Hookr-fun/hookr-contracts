// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {HookrGoverned} from "hookr/base/HookrGoverned.sol";
import {HookrFeeConversionTypes} from "../types/HookrFeeConversionTypes.sol";
import {IHookrFeeRouteRegistry} from "../interfaces/IHookrFeeRouteRegistry.sol";
import {IHookrStraySweep} from "../interfaces/IHookrStraySweep.sol";

/// @title HookrFeeRouteRegistry
/// @notice Owner-curated conversion routes for tax queues, a Hookr 1 port of the V2-lineage `HookrFeeRouteRegistryV1`,
///         governed like every Hookr 1 contract: adding a route waits the owner timelock, retiring one is immediate.
/// @dev A route is registered once, after a queued REGISTER_ROUTE that discloses every term including the adapter's
///      code hash, and can only be retired afterwards. The owner cannot edit a route, redirect a queue's output or
///      touch any balance: registering adds a choice for future pools; retiring stops conversions on that route and
///      starts each bound queue's recovery clock. Neither power reaches a swap. The owner, a nominee and an adapter
///      are never an EIP-7702 delegated account.
///
///      Stray assets: the owner may also send on an asset that was sent by mistake to the tax module, a tax queue or
///      the executor, but only through a queued SWEEP_STRAY that discloses the target, asset, amount and destination
///      and waits the timelock. The target must name this registry, and it refuses anything that is tax: a queue
///      never releases its quote asset this way, so accrued tax, booked shares and Rules claims are out of reach.
contract HookrFeeRouteRegistry is HookrGoverned, IHookrFeeRouteRegistry {
    /// @notice Kind for adding a route. Arguments:
    ///         `abi.encode(routeId, tokenIn, tokenOut, adapter, adapterCodeHash, routeDataHash)`.
    bytes32 public constant REGISTER_ROUTE = keccak256("REGISTER_ROUTE");
    /// @notice Kind for sending a stray asset on. Arguments: `abi.encode(target, asset, amount, to)`.
    bytes32 public constant SWEEP_STRAY = keccak256("SWEEP_STRAY");

    mapping(bytes32 routeId => HookrFeeConversionTypes.Route) private _routes;

    error InvalidRoute(bytes32 routeId);
    error RouteExists(bytes32 routeId);
    error RouteNotActive(bytes32 routeId);
    error InvalidStraySweep(address target, address to);

    event RouteRegistered(
        bytes32 indexed routeId,
        address indexed tokenIn,
        address indexed tokenOut,
        address adapter,
        bytes32 adapterCodeHash,
        bytes32 routeDataHash
    );
    event RouteRetired(bytes32 indexed routeId, uint40 retiredAt);
    event StraySweepExecuted(address indexed target, address indexed asset, uint256 amount, address to);

    /// @param owner_ The route curator (not an EIP-7702 delegated account).
    /// @param delay_ The owner timelock, within `HookrGoverned`'s bounds.
    constructor(address owner_, uint48 delay_) HookrGoverned(owner_, delay_) {}

    /// @notice Registers an immutable conversion route. Consumes a queued REGISTER_ROUTE with the same terms and the
    ///         adapter's current code hash.
    /// @param routeId Non-zero identifier chosen by the owner; never reusable.
    /// @param tokenIn Asset the route spends (the pool quote for tax queues); zero is native ETH.
    /// @param tokenOut Asset the route delivers; must differ from `tokenIn`; zero is native ETH.
    /// @param adapter Venue adapter; its runtime code hash is pinned now and re-checked on every use.
    /// @param routeDataHash keccak256 of the exact adapter bytes every conversion on this route must pass.
    function registerRoute(bytes32 routeId, address tokenIn, address tokenOut, address adapter, bytes32 routeDataHash)
        external
        onlyOwner
    {
        bytes32 codeHash = adapter.codehash;
        _consume(REGISTER_ROUTE, abi.encode(routeId, tokenIn, tokenOut, adapter, codeHash, routeDataHash));
        _checkRoute(routeId, tokenIn, tokenOut, adapter, routeDataHash);
        _routes[routeId] = HookrFeeConversionTypes.Route({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            adapter: adapter,
            adapterCodeHash: codeHash,
            routeDataHash: routeDataHash,
            status: HookrFeeConversionTypes.RouteStatus.ACTIVE,
            retiredAt: 0
        });
        emit RouteRegistered(routeId, tokenIn, tokenOut, adapter, codeHash, routeDataHash);
    }

    /// @notice Retires an active route at once. Conversions stop; bound queues may recover after their delay.
    function retireRoute(bytes32 routeId) external onlyOwner {
        HookrFeeConversionTypes.Route storage r = _routes[routeId];
        if (r.status != HookrFeeConversionTypes.RouteStatus.ACTIVE) revert RouteNotActive(routeId);
        r.status = HookrFeeConversionTypes.RouteStatus.RETIRED;
        r.retiredAt = uint40(block.timestamp);
        emit RouteRetired(routeId, r.retiredAt);
    }

    /// @notice Sends `amount` of stray `asset` held by `target` to `to`. Consumes a queued SWEEP_STRAY with the same
    ///         arguments. The target decides what is stray and reverts on anything else.
    /// @param target The tax module, a tax queue or the executor; it must name this registry.
    /// @param asset The stray asset, zero for native ETH.
    /// @param amount Exact amount to send, at most the target's balance.
    /// @param to Destination, normally the donor.
    function sweepStray(address target, address asset, uint256 amount, address to) external onlyOwner {
        _consume(SWEEP_STRAY, abi.encode(target, asset, amount, to));
        IHookrStraySweep(target).sweepStray(asset, amount, to);
        emit StraySweepExecuted(target, asset, amount, to);
    }

    /// @inheritdoc IHookrFeeRouteRegistry
    function route(bytes32 routeId) external view returns (HookrFeeConversionTypes.Route memory) {
        return _routes[routeId];
    }

    /// @inheritdoc IHookrFeeRouteRegistry
    function isActive(bytes32 routeId, address tokenIn, address tokenOut) external view returns (bool) {
        HookrFeeConversionTypes.Route storage r = _routes[routeId];
        return r.status == HookrFeeConversionTypes.RouteStatus.ACTIVE && r.tokenIn == tokenIn && r.tokenOut == tokenOut
            && r.adapter.codehash == r.adapterCodeHash;
    }

    /// @dev Only REGISTER_ROUTE, SWEEP_STRAY and TRANSFER_OWNER may be queued, with canonical arguments. A route is checked when it
    ///      is queued and again when it executes, and the queued code hash must be the adapter's code hash.
    function _checkQueue(bytes32 kind, bytes calldata arguments) internal view override {
        if (kind == REGISTER_ROUTE) {
            (
                bytes32 routeId,
                address tokenIn,
                address tokenOut,
                address adapter,
                bytes32 adapterCodeHash,
                bytes32 routeDataHash
            ) = abi.decode(arguments, (bytes32, address, address, address, bytes32, bytes32));
            _requireCanonical(
                kind, arguments, abi.encode(routeId, tokenIn, tokenOut, adapter, adapterCodeHash, routeDataHash)
            );
            _checkRoute(routeId, tokenIn, tokenOut, adapter, routeDataHash);
            if (adapterCodeHash != adapter.codehash) revert InvalidRoute(routeId);
        } else if (kind == SWEEP_STRAY) {
            (address target, address asset, uint256 amount, address to) =
                abi.decode(arguments, (address, address, uint256, address));
            _requireCanonical(kind, arguments, abi.encode(target, asset, amount, to));
            _checkSweep(target, amount, to);
        } else if (kind == TRANSFER_OWNER) {
            super._checkQueue(kind, arguments);
        } else {
            revert UnknownOperation(kind);
        }
    }

    /// @dev A sweep names a deployed target that answers to this registry, a non-zero amount and a destination other
    ///      than the target.
    function _checkSweep(address target, uint256 amount, address to) private view {
        _requireDeployedCode(target);
        if (amount == 0 || to == address(0) || to == target) revert InvalidStraySweep(target, to);
        try IHookrStraySweep(target).routeRegistry() returns (IHookrFeeRouteRegistry named) {
            if (address(named) != address(this)) revert InvalidStraySweep(target, to);
        } catch {
            revert InvalidStraySweep(target, to);
        }
    }

    function _checkRoute(bytes32 routeId, address tokenIn, address tokenOut, address adapter, bytes32 routeDataHash)
        private
        view
    {
        if (routeId == bytes32(0) || tokenIn == tokenOut || routeDataHash == bytes32(0)) revert InvalidRoute(routeId);
        if (_routes[routeId].status != HookrFeeConversionTypes.RouteStatus.NONE) revert RouteExists(routeId);
        _requireDeployedCode(adapter);
        if (tokenIn != address(0)) _requireDeployedCode(tokenIn);
        if (tokenOut != address(0)) _requireDeployedCode(tokenOut);
    }
}
