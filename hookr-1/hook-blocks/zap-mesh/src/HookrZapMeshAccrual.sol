// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTypes} from "hookr/types/HookrTypes.sol";
import {HookrReleased} from "hookr/base/HookrReleased.sol";
import {IHookrRoot} from "hookr/interfaces/IHookrRoot.sol";
import {IHookrRegistry} from "hookr/interfaces/IHookrRegistry.sol";
import {IHookrRootRoute} from "hookr/interfaces/IHookrRootRoute.sol";
import {HookrSessionTiers} from "hookr/libraries/HookrSessionTiers.sol";
import {IHookrAdvisory} from "hookr/interfaces/IHookrAdvisory.sol";
import {ZapRelayTypes} from "zap-relay/types/ZapRelayTypes.sol";
import {ZapSessionLens} from "zap-relay/ZapSessionLens.sol";
import {IHookrGatedRelay} from "zap-relay/interfaces/IHookrGatedRelay.sol";
import {IZapSessionTiered} from "zap-relay/interfaces/IZapSessionTiered.sol";
import {ZapMeshTypes} from "./types/ZapMeshTypes.sol";
import {IHookrZapMeshAccrual} from "./interfaces/IHookrZapMeshAccrual.sol";
import {IHookrZapMeshVault} from "./interfaces/IHookrZapMeshVault.sol";
import {ZapMeshDeployer, ZapMeshLegDeployer} from "./ZapMeshDeployer.sol";

/// @title Hookr zap mesh accrual
/// @notice ADVISORY module for a source pool whose buy cut feeds a zap mesh. Every buy pays a frozen quote cut of up to
///         10% of the gross buyer spend, credited by the root to the pool's mesh as a HookrRules claim; sells are never
///         charged. It binds HookrZapAccrual's terms (ZapRelayTypes.ACCRUAL_SCHEMA): `abi.encode(AccrualTerms)` naming
///         a mesh instead of a vault, with the same optional off-market session tiers.
///         It is also the only factory of meshes and their legs, and records every leg with its target and gate, so the
///         deployed HookrGatedRelay admits a leg as a feeder of its target once this contract is admitted on the root
///         as an ADVISORY with the accrual schema: the gate checks the factory's admission, schema and code hash, then
///         `vaultRecord(leg)`, then the leg's quote and window scope. No target needs a new block.
/// @dev Stateless on the swap path, like HookrZapAccrual: beforeSwap is a view over the binder's frozen record. Storage
///      is keyed by the binder (the root). Strict (never fail-open). Its admitted runtime code hash pins the addresses
///      of the two deployers and the session lens it creates, whose code comes from this contract's creation code.
contract HookrZapMeshAccrual is HookrReleased, IHookrZapMeshAccrual {
    using PoolIdLibrary for PoolKey;

    /// @notice Same cut bounds as HookrZapAccrual.
    uint24 public constant MIN_TAKE_PIPS = 1;
    uint24 public constant MAX_TAKE_PIPS = 100_000;
    uint24 public constant DEFAULT_TAKE_PIPS = 10_000;
    /// @notice Least advisory gas a source may bind with: covers the heaviest bind measured, a source with session tiers
    ///         on a mesh of four live targets with every account cold (145,585 as the root calls it, 169,590 with even
    ///         the registry admissions cold). The zap accrual's floor is 150,000; the mesh is admitted with its 200,000.
    uint32 public constant MIN_ADVISORY_GAS = 175_000;
    uint16 public constant MIN_PROTOCOL_SHARE_BPS = 2_000;
    uint16 public constant MAX_PROTOCOL_SHARE_BPS = 5_000;
    uint16 public constant DEFAULT_PROTOCOL_SHARE_BPS = 2_000;

    struct Bound {
        address mesh;
        uint24 takePips;
        bool bound;
        bool tiered;
        uint24 sessionLimit;
    }

    struct LegRecord {
        PoolId target;
        address gate;
        bool exists;
    }

    /// @custom:storage-location erc7201:hookr.zap-mesh-accrual
    struct State {
        mapping(address binder => mapping(PoolId => Bound)) bound;
        mapping(address mesh => bool) meshes;
        mapping(address leg => LegRecord) legs;
        mapping(address binder => mapping(PoolId => HookrSessionTiers.Tiers)) tiers;
    }

    /// @dev cast index-erc7201 hookr.zap-mesh-accrual
    bytes32 private constant STATE_SLOT = 0x53c08f94702cc7435052994659ac95fab06c6f8775db7989d50e89b0a0ab0d00;
    uint256 private constant TERMS_SIZE = 64;
    uint256 private constant TIERED_SIZE = TERMS_SIZE + HookrSessionTiers.ENCODED_SIZE;

    /// @inheritdoc IZapSessionTiered
    address public immutable calendar;
    /// @notice The session lens this contract deployed.
    ZapSessionLens public immutable lens;
    /// @notice The mesh deployer this contract deployed.
    ZapMeshDeployer public immutable meshDeployer;
    /// @notice The leg deployer this contract deployed.
    ZapMeshLegDeployer public immutable legDeployer;
    /// @inheritdoc IHookrZapMeshAccrual
    uint16 public immutable protocolShareBps;

    /// @param calendar_ The shared session calendar (a HookrSessionAdvisory) every tiered pool reads.
    /// @param protocolShareBps_ Hookr's share of every source cut, MIN_PROTOCOL_SHARE_BPS..MAX_PROTOCOL_SHARE_BPS.
    constructor(address calendar_, uint16 protocolShareBps_) {
        if (calendar_.code.length == 0) revert InvalidTerms(6);
        if (protocolShareBps_ < MIN_PROTOCOL_SHARE_BPS || protocolShareBps_ > MAX_PROTOCOL_SHARE_BPS) {
            revert InvalidTerms(7);
        }
        calendar = calendar_;
        protocolShareBps = protocolShareBps_;
        lens = new ZapSessionLens(calendar_);
        legDeployer = new ZapMeshLegDeployer();
        meshDeployer = new ZapMeshDeployer(address(legDeployer));
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev The zap accrual's schema: the gated relay admits only a factory admitted with it, and the terms are the same.
    function configSchemaHash() external pure returns (bytes32) {
        return ZapRelayTypes.ACCRUAL_SCHEMA;
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev Checks, in order: canonical terms; not yet bound for this binder; 0 < take <= 10%; the mesh was created here,
    ///      targets other pools, spends this pool's quote, claims from this pool's Rules and lives on this root; every
    ///      target the root already opened has its route live (its feeder list is frozen, so a dead route never comes
    ///      alive); a strict before-swap pool config with enough gas; the take fits this module's admission cap and,
    ///      with the Rules' admitted quote ceiling, the frozen pool cap; non-empty session tiers pass
    ///      HookrSessionTiers.check against this module's admitted LP-fee cap. The route checks read each target from
    ///      this contract's own leg record and check liveness here, not through the leg, so a tiered source binds a
    ///      mesh of four live targets well inside the admitted gas (see _checkRoutes and MIN_ADVISORY_GAS).
    function bind(PoolKey calldata key, HookrTypes.PoolConfig calldata pc, bytes calldata data)
        external
        returns (bytes32 configHash)
    {
        ZapRelayTypes.AccrualTerms memory t;
        HookrSessionTiers.Tiers memory tiers;
        if (data.length == TERMS_SIZE) {
            t = abi.decode(data, (ZapRelayTypes.AccrualTerms));
            if (keccak256(data) != keccak256(abi.encode(t))) revert InvalidTerms(0);
        } else if (data.length == TIERED_SIZE) {
            (t, tiers) = abi.decode(data, (ZapRelayTypes.AccrualTerms, HookrSessionTiers.Tiers));
        } else {
            revert InvalidTerms(0);
        }
        PoolId id = key.toId();
        State storage s = _state();
        Bound storage b = s.bound[msg.sender][id];
        if (b.bound) revert AlreadyBound(msg.sender, id);
        if (t.takePips < MIN_TAKE_PIPS || t.takePips > MAX_TAKE_PIPS) revert InvalidTerms(1);
        if (!s.meshes[t.vault]) revert InvalidTerms(2);
        IHookrZapMeshVault mesh = IHookrZapMeshVault(t.vault);
        if (
            Currency.unwrap(mesh.quote()) != Currency.unwrap(pc.quote) || mesh.rules() != pc.rules
                || mesh.root() != address(key.hooks)
        ) revert InvalidTerms(4);
        _checkRoutes(s, mesh, IHookrRoot(address(key.hooks)), id, pc);
        if (pc.advisoryFailOpen) revert InvalidPoolConfig(1);
        if (pc.advisoryPhases & HookrTypes.BEFORE_SWAP == 0) revert InvalidPoolConfig(2);
        if (pc.advisoryGasLimit < MIN_ADVISORY_GAS) revert InvalidPoolConfig(3);
        IHookrRegistry registry = IHookrRoot(msg.sender).registry();
        IHookrRegistry.Admission memory own = registry.admission(msg.sender, address(this));
        if (own.implementation != address(this) || t.takePips > own.caps.maxQuoteTakePips) revert InvalidPoolConfig(4);
        IHookrRegistry.Admission memory ra = registry.admission(msg.sender, pc.rules);
        if (uint256(ra.caps.maxQuoteTakePips) + t.takePips > pc.caps.maxQuoteTakePips) revert InvalidPoolConfig(5);
        b.mesh = t.vault;
        b.takePips = t.takePips;
        b.bound = true;
        emit AccrualBound(msg.sender, id, t.vault, t.takePips);
        if (!HookrSessionTiers.isEmpty(tiers)) {
            uint24 cap = own.caps.maxLpFeePips;
            HookrSessionTiers.check(tiers, cap);
            b.tiered = true;
            b.sessionLimit = cap;
            s.tiers[msg.sender][id] = tiers;
            emit SessionTiersBound(msg.sender, id, tiers, cap);
        }
        return keccak256(data);
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev The quote take is buys only, credited to the mesh in Rules. A tiered pool also gets its session surcharge
    ///      on every swap; a failed lens call charges the highest tier and never reverts.
    function beforeSwap(HookrTypes.SwapContext calldata x) external view returns (HookrTypes.Advice memory advice) {
        State storage s = _state();
        Bound memory b = s.bound[msg.sender][x.id];
        if (b.tiered) {
            HookrSessionTiers.Tiers memory tiers = s.tiers[msg.sender][x.id];
            try lens.surcharge(tiers, b.sessionLimit) returns (uint24 pips) {
                advice.lpFeeSurchargePips = pips;
            } catch {
                uint256 top = HookrSessionTiers.highest(tiers);
                // top <= sessionLimit (a uint24) after the clamp.
                // forge-lint: disable-next-line(unsafe-typecast)
                advice.lpFeeSurchargePips = uint24(top < b.sessionLimit ? top : b.sessionLimit);
            }
        }
        if (!x.isBuy || !b.bound) return advice;
        advice.quoteTakePips = b.takePips;
        advice.recipient = b.mesh;
    }

    /// @inheritdoc IHookrAdvisory
    function afterSwap(HookrTypes.SwapContext calldata, int128, int128)
        external
        pure
        returns (HookrTypes.Advice memory advice)
    {
        return advice;
    }

    /// @inheritdoc IHookrAdvisory
    function beforeAddLiquidity(PoolId, address) external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IHookrZapMeshAccrual
    function createMesh(ZapMeshTypes.Mesh calldata m, bytes32 salt)
        external
        returns (address vault, address[] memory legs)
    {
        vault = meshDeployer.deploy(m, _salt(msg.sender, salt));
        State storage s = _state();
        s.meshes[vault] = true;
        emit MeshCreated(vault, msg.sender, m.gate, m.mode, m.split, m.sink);
        uint256 n = m.targets.length;
        legs = new address[](n);
        for (uint256 i; i < n; ++i) {
            (address predicted, uint16 weight, PoolId target,) = IHookrZapMeshVault(vault).route(i);
            // i < 4, checked by the mesh.
            // forge-lint: disable-next-line(unsafe-typecast)
            address leg = legDeployer.deploy(vault, uint8(i));
            if (leg != predicted) revert LegMismatch(i, leg, predicted);
            s.legs[leg] = LegRecord(target, m.gate, true);
            legs[i] = leg;
            // forge-lint: disable-next-line(unsafe-typecast)
            emit LegCreated(vault, leg, target, uint8(i), weight);
        }
    }

    /// @inheritdoc IHookrZapMeshAccrual
    function predictMesh(address creator, ZapMeshTypes.Mesh calldata m, bytes32 salt)
        external
        view
        returns (address vault, address[] memory legs)
    {
        vault = meshDeployer.predict(m, _salt(creator, salt));
        uint256 n = m.targets.length;
        legs = new address[](n);
        for (uint256 i; i < n; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            legs[i] = legDeployer.predict(vault, uint8(i));
        }
    }

    /// @inheritdoc IHookrZapMeshAccrual
    function meshRecord(address mesh) external view returns (bool) {
        return _state().meshes[mesh];
    }

    /// @inheritdoc IHookrZapMeshAccrual
    function vaultRecord(address leg) external view returns (bool exists, PoolId target, address gate) {
        LegRecord storage l = _state().legs[leg];
        return (l.exists, l.target, l.gate);
    }

    /// @inheritdoc IZapSessionTiered
    function sessionTiers(address binder, PoolId id)
        external
        view
        returns (bool tiered, uint24 limit, HookrSessionTiers.Tiers memory tiers)
    {
        State storage s = _state();
        Bound storage b = s.bound[binder][id];
        return (b.tiered, b.sessionLimit, s.tiers[binder][id]);
    }

    /// @inheritdoc IHookrZapMeshAccrual
    function terms(address binder, PoolId id) external view returns (uint24 takePips, address mesh, bool bound) {
        Bound storage b = _state().bound[binder][id];
        return (b.takePips, b.mesh, b.bound);
    }

    /// @dev For every route of `mesh`: its target, read from this contract's leg record, is not the source `id`; and if
    ///      the root already opened it, its frozen advisory is the mesh's gate, its quote is the mesh's, and the gate
    ///      lists the leg. That is the leg's own routeLive() check, read with the root's two-slot poolRoute instead of
    ///      the seven-slot PoolConfig: a pool whose advisory is the admitted gate is strict and before-swap and its
    ///      feeders trade its quote, because the gate's bind refuses anything else. The one part not re-checked here is
    ///      that the target binds the mesh's Rules; the leg checks it at every zap, so such a route is simply not live,
    ///      and the cut strands only if no route is.
    function _checkRoutes(
        State storage s,
        IHookrZapMeshVault mesh,
        IHookrRoot root,
        PoolId id,
        HookrTypes.PoolConfig calldata pc
    ) private view {
        address[] memory list = mesh.legs();
        address gate = mesh.gate();
        for (uint256 i; i < list.length; ++i) {
            PoolId target = s.legs[list[i]].target;
            if (PoolId.unwrap(target) == PoolId.unwrap(id)) revert InvalidTerms(3);
            if (!root.knownPool(target)) continue;
            (Currency quote, address advisory) = IHookrRootRoute(address(root)).poolRoute(target);
            if (
                advisory != gate || Currency.unwrap(quote) != Currency.unwrap(pc.quote)
                    || !IHookrGatedRelay(gate).isFeeder(address(root), target, list[i])
            ) revert InvalidTerms(5);
        }
    }

    function _salt(address creator, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(creator, salt));
    }

    function _state() private pure returns (State storage s) {
        assembly ("memory-safe") {
            s.slot := STATE_SLOT
        }
    }
}
