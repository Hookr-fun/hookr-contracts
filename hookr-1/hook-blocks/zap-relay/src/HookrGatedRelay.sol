// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookrTypes} from "hookr/types/HookrTypes.sol";
import {HookrReleased} from "hookr/base/HookrReleased.sol";
import {IHookrRoot} from "hookr/interfaces/IHookrRoot.sol";
import {IHookrRegistry} from "hookr/interfaces/IHookrRegistry.sol";
import {HookrSessionTiers} from "hookr/libraries/HookrSessionTiers.sol";
import {IHookrAdvisory} from "hookr/interfaces/IHookrAdvisory.sol";
import {ZapRelayTypes} from "./types/ZapRelayTypes.sol";
import {IHookrGatedRelay} from "./interfaces/IHookrGatedRelay.sol";
import {IHookrZapAccrual} from "./interfaces/IHookrZapAccrual.sol";
import {IHookrZapVault} from "./interfaces/IHookrZapVault.sol";
import {ZapSessionFee} from "./libraries/ZapSessionFee.sol";
import {IZapSessionTiered} from "./interfaces/IZapSessionTiered.sol";

/// @title Hookr gated relay
/// @notice ADVISORY module for a target pool. A buy is accepted only when the root-authenticated payer is one of the
///         pool's frozen feeders: zap vaults created by an admitted HookrZapAccrual for exactly this pool and this gate.
///         The feeder buys through the pinned HookrRouter, which the root authenticates by code hash and whose hook data
///         names the router's own caller as payer; a HookrForwarder relay names the Permit2 signer, and a direct
///         PoolManager caller is its own payer. None of these can be made to name a vault by anyone but the vault.
///         Selling is never rejected, by any account, in any state, bound or not. A sell is charged only the pool's
///         frozen off-market session surcharge, if the pool bound session tiers, and never otherwise inspected.
///         Liquidity may be added only by the pool's liquidity owner (the launcher, i.e. the launch itself and the
///         family owner's adds to the family range) or a feeder. Otherwise an out-of-range position would be a
///         standing limit buy filled by sellers, a second buy path around the gate.
/// @dev Stateless on the swap path: every read is a static call over frozen storage keyed by the binder (the root).
///      Strict (never fail-open): the registry refuses a fail-open advisory that rejects, and the root ignores reject
///      from a fail-open one. The sell guarantee therefore rests on this module never reverting for a sell: the sell
///      branch reads one storage slot and, only for a pool with session tiers, the tiers slot and the shared calendar
///      through a bounded static call whose failure charges the highest tier. Nothing on that branch can revert. If
///      the gas the root grants were ever too low the root would revert the swap (strict), which is why bind requires
///      MIN_ADVISORY_GAS; a buy costs at most six cold storage reads plus, when tiered, one calendar read.
contract HookrGatedRelay is HookrReleased, IHookrGatedRelay {
    using PoolIdLibrary for PoolKey;

    /// @notice Fewest feeders one gated pool may freeze.
    uint256 public constant MIN_FEEDERS = 1;
    /// @notice Most feeders one gated pool may freeze.
    uint256 public constant MAX_FEEDERS = 4;
    /// @notice Smallest advisory gas limit a gated pool may bind with. Measured cold bind, four feeders: ~187k;
    ///         worst-case buy check: ~13.6k; sell: ~4.4k, ~11.1k with session tiers (ZapRelayGas.t.sol).
    uint32 public constant MIN_ADVISORY_GAS = 300_000;

    struct Bound {
        address liquidityOwner;
        uint8 count;
        bool bound;
        bool tiered;
        uint24 sessionLimit;
        address factory;
        address[4] feeders;
        HookrSessionTiers.Tiers tiers;
    }

    /// @custom:storage-location erc7201:hookr.gated-relay
    struct State {
        mapping(address binder => mapping(PoolId => Bound)) bound;
    }

    /// @dev cast index-erc7201 hookr.gated-relay
    bytes32 private constant STATE_SLOT = 0xa716f9c249dff64139c6b96470e7362722ed3014d422ef1d541ce69604c4ad00;
    /// @dev ABI size, before the feeder words, of `abi.encode(GateTerms)` and of `abi.encode(GateTerms, Tiers)`.
    uint256 private constant TERMS_BASE = 128;
    uint256 private constant TIERED_BASE = TERMS_BASE + HookrSessionTiers.ENCODED_SIZE;

    /// @inheritdoc IZapSessionTiered
    address public immutable calendar;

    /// @param calendar_ The shared session calendar (a HookrSessionAdvisory) every tiered pool reads.
    constructor(address calendar_) {
        if (calendar_.code.length == 0) revert InvalidTerms(6);
        calendar = calendar_;
    }

    /// @inheritdoc IHookrAdvisory
    function configSchemaHash() external pure returns (bytes32) {
        return ZapRelayTypes.GATE_SCHEMA;
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev Checks, in order: canonical terms with one to four distinct nonzero feeders, with or without session
    ///      tiers; not yet bound for this binder; a strict pool config with a before-swap phase, enough gas and a
    ///      liquidity owner; `factory` is admitted on the binding root as an ADVISORY with the accrual schema and its
    ///      current code hash; every feeder is a vault that factory created for this pool id and this gate, spending
    ///      this pool's quote, and all sharing one impact-window scope; non-empty session tiers pass HookrSessionTiers.check against this module's admitted
    ///      LP-fee cap, which the root reserves out of the pool cap. Empty tiers bind exactly like the plain terms.
    function bind(PoolKey calldata key, HookrTypes.PoolConfig calldata pc, bytes calldata data)
        external
        returns (bytes32 configHash)
    {
        ZapRelayTypes.GateTerms memory t;
        HookrSessionTiers.Tiers memory tiers;
        if (data.length >= TERMS_BASE + 32 && data.length <= TERMS_BASE + 32 * MAX_FEEDERS) {
            t = abi.decode(data, (ZapRelayTypes.GateTerms));
            if (keccak256(data) != keccak256(abi.encode(t))) revert InvalidTerms(0);
        } else if (data.length >= TIERED_BASE + 32 && data.length <= TIERED_BASE + 32 * MAX_FEEDERS) {
            (t, tiers) = abi.decode(data, (ZapRelayTypes.GateTerms, HookrSessionTiers.Tiers));
            if (keccak256(data) != keccak256(abi.encode(t, tiers))) revert InvalidTerms(0);
        } else {
            revert InvalidTerms(0);
        }
        uint256 n = t.feeders.length;
        if (n < MIN_FEEDERS || n > MAX_FEEDERS) revert InvalidTerms(1);
        PoolId id = key.toId();
        Bound storage b = _state().bound[msg.sender][id];
        if (b.bound) revert AlreadyBound(msg.sender, id);
        if (pc.advisoryFailOpen) revert InvalidPoolConfig(1);
        if (pc.advisoryPhases & HookrTypes.BEFORE_SWAP == 0) revert InvalidPoolConfig(2);
        if (pc.advisoryGasLimit < MIN_ADVISORY_GAS) revert InvalidPoolConfig(3);
        if (pc.liquidityOwner == address(0)) revert InvalidPoolConfig(4);
        IHookrRegistry registry = IHookrRoot(msg.sender).registry();
        IHookrRegistry.Admission memory fa = registry.admission(msg.sender, t.factory);
        if (
            t.factory == address(0) || fa.implementation != t.factory || fa.kind != IHookrRegistry.Kind.ADVISORY
                || t.factory.codehash != fa.codeHash || fa.schemaHash != ZapRelayTypes.ACCRUAL_SCHEMA
        ) revert InvalidTerms(2);
        for (uint256 i; i < n; ++i) {
            address f = t.feeders[i];
            if (f == address(0)) revert InvalidTerms(3);
            for (uint256 j; j < i; ++j) {
                if (t.feeders[j] == f) revert InvalidTerms(4);
            }
            (bool exists, PoolId target, address g) = IHookrZapAccrual(t.factory).vaultRecord(f);
            if (
                !exists || PoolId.unwrap(target) != PoolId.unwrap(id) || g != address(this)
                    || Currency.unwrap(IHookrZapVault(f).quote()) != Currency.unwrap(pc.quote)
            ) revert InvalidTerms(5);
            // One window scope per target, so pool-wide feeders never sit beside one that ignores them.
            if (i != 0 && IHookrZapVault(f).windowScope() != IHookrZapVault(t.feeders[0]).windowScope()) {
                revert InvalidTerms(7);
            }
            b.feeders[i] = f;
        }
        b.liquidityOwner = pc.liquidityOwner;
        // n <= MAX_FEEDERS (4), checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        b.count = uint8(n);
        b.factory = t.factory;
        b.bound = true;
        emit GateBound(msg.sender, id, t.factory, t.feeders, pc.liquidityOwner);
        if (!HookrSessionTiers.isEmpty(tiers)) {
            IHookrRegistry.Admission memory own = registry.admission(msg.sender, address(this));
            if (own.implementation != address(this)) revert InvalidPoolConfig(5);
            uint24 cap = own.caps.maxLpFeePips;
            HookrSessionTiers.check(tiers, cap);
            b.tiered = true;
            b.sessionLimit = cap;
            b.tiers = tiers;
            emit SessionTiersBound(msg.sender, id, tiers, cap);
        }
        return keccak256(data);
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev A sell is never rejected; it reads one slot and gets only the pool's session surcharge, if tiered. A buy
    ///      is rejected unless the pool is bound and the authenticated payer (the sender itself for unauthenticated
    ///      swaps) is a frozen feeder; an admitted buy gets the same session surcharge.
    function beforeSwap(HookrTypes.SwapContext calldata x) external view returns (HookrTypes.Advice memory advice) {
        Bound storage b = _state().bound[msg.sender][x.id];
        if (x.isBuy) {
            advice.reject = !_isFeeder(b, x.payer);
            if (advice.reject) return advice;
        }
        if (b.tiered) advice.lpFeeSurchargePips = ZapSessionFee.surcharge(b.tiers, calendar, b.sessionLimit);
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev Never rejects and never charges. Present only because IHookrAdvisory requires it.
    function afterSwap(HookrTypes.SwapContext calldata, int128, int128)
        external
        pure
        returns (HookrTypes.Advice memory advice)
    {
        return advice;
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev Removals and fee collection never reach this module (the root does not consult advisories on removal).
    function beforeAddLiquidity(PoolId id, address sender) external view returns (bool) {
        Bound storage b = _state().bound[msg.sender][id];
        return b.bound && (sender == b.liquidityOwner || _isFeeder(b, sender));
    }

    /// @inheritdoc IHookrGatedRelay
    function isFeeder(address binder, PoolId id, address account) external view returns (bool) {
        return _isFeeder(_state().bound[binder][id], account);
    }

    /// @inheritdoc IZapSessionTiered
    function sessionTiers(address binder, PoolId id)
        external
        view
        returns (bool tiered, uint24 limit, HookrSessionTiers.Tiers memory tiers)
    {
        Bound storage b = _state().bound[binder][id];
        return (b.tiered, b.sessionLimit, b.tiers);
    }

    /// @inheritdoc IHookrGatedRelay
    function gateOf(address binder, PoolId id)
        external
        view
        returns (bool bound, address liquidityOwner, address factory, address[] memory feeders)
    {
        Bound storage b = _state().bound[binder][id];
        feeders = new address[](b.count);
        for (uint256 i; i < b.count; ++i) {
            feeders[i] = b.feeders[i];
        }
        return (b.bound, b.liquidityOwner, b.factory, feeders);
    }

    function _isFeeder(Bound storage b, address account) private view returns (bool) {
        if (!b.bound || account == address(0)) return false;
        uint256 n = b.count;
        for (uint256 i; i < n; ++i) {
            if (b.feeders[i] == account) return true;
        }
        return false;
    }

    function _state() private pure returns (State storage s) {
        assembly ("memory-safe") {
            s.slot := STATE_SLOT
        }
    }
}
