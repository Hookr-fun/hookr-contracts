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
import {IHookrZapAccrual} from "./interfaces/IHookrZapAccrual.sol";
import {IHookrZapVault} from "./interfaces/IHookrZapVault.sol";
import {ZapSessionLens} from "./ZapSessionLens.sol";
import {ZapVaultDeployer} from "./ZapVaultDeployer.sol";
import {IZapSessionTiered} from "./interfaces/IZapSessionTiered.sol";

/// @title Hookr zap accrual
/// @notice ADVISORY module for a source pool. Every buy (exact input or exact output, authenticated or not) pays a
///         frozen quote cut of up to 10% of the gross buyer spend. The root credits the cut to the pool's zap vault as
///         a HookrRules claim; nothing is held here and nothing is donated. Sells are never charged. The vault sets
///         aside Hookr's share of every cut it claims (protocolShareBps, never below the 2,000 bps release floor) for
///         the Rules' protocol recipient before it spends the rest.
///         The same contract is the only factory of HookrZapVault, through the ZapVaultDeployer it creates in its
///         constructor. Its admitted runtime code hash pins the addresses of that deployer and of the session lens;
///         their code comes from this contract's creation code, which the release checks by reading both code hashes
///         back before admission. A source pool may also bind off-market session tiers: an LP-fee surcharge on every
///         swap that follows the US equity session, read from the shared calendar fixed at construction.
/// @dev Stateless on the swap path: beforeSwap is a view over the binder's frozen record. Storage is keyed by the binder
///      (the root), so a third-party bind writes only its own namespace. Strict (never fail-open): a skipped quote take
///      would be a leak, and the registry refuses fail-open admissions with a quote take anyway.
///      Why a quote take and not an LP surcharge: a take is credited per swap to a fixed recipient, so just-in-time
///      liquidity on the source pool cannot capture it (LP fees can be captured that way).
contract HookrZapAccrual is HookrReleased, IHookrZapAccrual {
    using PoolIdLibrary for PoolKey;

    /// @notice Smallest cut a source pool may bind: one pip of the gross buyer spend.
    uint24 public constant MIN_TAKE_PIPS = 1;
    /// @notice Largest cut a source pool may bind: 10% of the gross buyer spend. The admission's quote-take cap and the
    ///         pool's frozen quote cap (less the Rules ceiling) can lower it for a given pool.
    uint24 public constant MAX_TAKE_PIPS = 100_000;
    /// @notice Suggested cut for a new source pool: 1% of the gross buyer spend. The app's default; not enforced.
    uint24 public constant DEFAULT_TAKE_PIPS = 10_000;
    /// @notice Smallest advisory gas limit a source pool may bind with. Measured cold bind: ~66k; buy advice: ~4.4k.
    uint32 public constant MIN_ADVISORY_GAS = 150_000;
    /// @notice Smallest share of every source cut Hookr takes: the Hookr 1 release protocol floor (20%).
    uint16 public constant MIN_PROTOCOL_SHARE_BPS = 2_000;
    /// @notice Largest share of a source cut Hookr may take: the HookrRules protocol-share ceiling (50%).
    uint16 public constant MAX_PROTOCOL_SHARE_BPS = 5_000;
    /// @notice Hookr's share of a source cut unless the owner picks a higher one at deployment: the floor.
    uint16 public constant DEFAULT_PROTOCOL_SHARE_BPS = 2_000;

    struct Bound {
        address vault;
        uint24 takePips;
        bool bound;
        bool tiered;
        uint24 sessionLimit;
    }

    struct VaultRecord {
        PoolId target;
        address gate;
        bool exists;
    }

    /// @custom:storage-location erc7201:hookr.zap-accrual
    struct State {
        mapping(address binder => mapping(PoolId => Bound)) bound;
        mapping(address vault => VaultRecord) vaults;
        mapping(address binder => mapping(PoolId => HookrSessionTiers.Tiers)) tiers;
    }

    /// @dev cast index-erc7201 hookr.zap-accrual
    bytes32 private constant STATE_SLOT = 0x1225651bfdceee733812b2abe9a0ef551b56d18ca1db8b50ad5787f319f07800;
    /// @dev ABI size of `abi.encode(AccrualTerms)` and of `abi.encode(AccrualTerms, HookrSessionTiers.Tiers)`.
    uint256 private constant TERMS_SIZE = 64;
    uint256 private constant TIERED_SIZE = TERMS_SIZE + HookrSessionTiers.ENCODED_SIZE;

    /// @inheritdoc IZapSessionTiered
    address public immutable calendar;
    /// @notice The session lens this contract deployed; it computes a tiered pool's surcharge.
    ZapSessionLens public immutable lens;
    /// @notice The vault deployer this contract deployed; it holds the vault's creation code and deploys only for this
    ///         contract.
    ZapVaultDeployer public immutable vaultDeployer;
    /// @inheritdoc IHookrZapAccrual
    uint16 public immutable protocolShareBps;

    /// @param calendar_ The shared session calendar (a HookrSessionAdvisory) every tiered pool reads.
    /// @param protocolShareBps_ Hookr's share of every source cut, MIN_PROTOCOL_SHARE_BPS..MAX_PROTOCOL_SHARE_BPS. Each
    ///        vault takes at least this and at least its Rules' minProtocolShareBps.
    constructor(address calendar_, uint16 protocolShareBps_) {
        if (calendar_.code.length == 0) revert InvalidTerms(6);
        if (protocolShareBps_ < MIN_PROTOCOL_SHARE_BPS || protocolShareBps_ > MAX_PROTOCOL_SHARE_BPS) {
            revert InvalidTerms(7);
        }
        calendar = calendar_;
        protocolShareBps = protocolShareBps_;
        lens = new ZapSessionLens(calendar_);
        vaultDeployer = new ZapVaultDeployer();
    }

    /// @inheritdoc IHookrAdvisory
    function configSchemaHash() external pure returns (bytes32) {
        return ZapRelayTypes.ACCRUAL_SCHEMA;
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev Checks, in order: canonical terms (two words, or two words plus session tiers); not yet bound for this
    ///      binder; 0 < take <= 10%; the vault was created here, targets another pool, spends this pool's quote,
    ///      claims from this pool's Rules and lives on this root; if its target pool already exists, the vault's route
    ///      is live there (the target gates it and lists it); the pool config is strict with a before-swap phase
    ///      and enough gas; the take fits this module's own admission cap; the Rules' admitted quote ceiling plus the
    ///      take fits the frozen pool cap, so the cut can never push a buy into AggregateCapExceeded; and non-empty
    ///      session tiers pass HookrSessionTiers.check against this module's admitted LP-fee cap, which the root
    ///      reserves out of the pool cap before binding the Rules, so the surcharge can never push a swap into
    ///      AggregateCapExceeded either. Empty tiers bind exactly like the two-word encoding.
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
            // Every field is static, so at this exact length the checked decode admits only the canonical encoding.
            (t, tiers) = abi.decode(data, (ZapRelayTypes.AccrualTerms, HookrSessionTiers.Tiers));
        } else {
            revert InvalidTerms(0);
        }
        PoolId id = key.toId();
        State storage s = _state();
        Bound storage b = s.bound[msg.sender][id];
        if (b.bound) revert AlreadyBound(msg.sender, id);
        if (t.takePips < MIN_TAKE_PIPS || t.takePips > MAX_TAKE_PIPS) revert InvalidTerms(1);
        VaultRecord memory v = s.vaults[t.vault];
        if (!v.exists) revert InvalidTerms(2);
        if (PoolId.unwrap(v.target) == PoolId.unwrap(id)) revert InvalidTerms(3);
        IHookrZapVault vault = IHookrZapVault(t.vault);
        if (
            Currency.unwrap(vault.quote()) != Currency.unwrap(pc.quote) || vault.rules() != pc.rules
                || vault.root() != address(key.hooks)
        ) revert InvalidTerms(4);
        // A target the root already opened has frozen its advisory and feeder list, so if its route is not
        // live now it never will be and the cut would be stranded. A target not opened yet may still list the vault.
        if (IHookrRoot(address(key.hooks)).knownPool(v.target) && !vault.routeLive()) revert InvalidTerms(5);
        if (pc.advisoryFailOpen) revert InvalidPoolConfig(1);
        if (pc.advisoryPhases & HookrTypes.BEFORE_SWAP == 0) revert InvalidPoolConfig(2);
        if (pc.advisoryGasLimit < MIN_ADVISORY_GAS) revert InvalidPoolConfig(3);
        IHookrRegistry registry = IHookrRoot(msg.sender).registry();
        IHookrRegistry.Admission memory own = registry.admission(msg.sender, address(this));
        if (own.implementation != address(this) || t.takePips > own.caps.maxQuoteTakePips) revert InvalidPoolConfig(4);
        IHookrRegistry.Admission memory ra = registry.admission(msg.sender, pc.rules);
        if (uint256(ra.caps.maxQuoteTakePips) + t.takePips > pc.caps.maxQuoteTakePips) revert InvalidPoolConfig(5);
        b.vault = t.vault;
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
    /// @dev The quote take is buys only: the root sizes it on the gross buyer spend and credits it to `recipient` in
    ///      Rules. A pool with session tiers also gets their LP-fee surcharge on every swap, buy or sell, from the lens;
    ///      a failed or malformed calendar read, or a failed lens call, charges the highest tier and never reverts.
    function beforeSwap(HookrTypes.SwapContext calldata x) external view returns (HookrTypes.Advice memory advice) {
        State storage s = _state();
        Bound memory b = s.bound[msg.sender][x.id];
        if (b.tiered) {
            HookrSessionTiers.Tiers memory tiers = s.tiers[msg.sender][x.id];
            try lens.surcharge(tiers, b.sessionLimit) returns (uint24 pips) {
                advice.lpFeeSurchargePips = pips;
            } catch {
                uint256 top = HookrSessionTiers.highest(tiers);
                // top <= sessionLimit (a uint24) after the clamp; check() bound highest(tiers) <= sessionLimit anyway.
                // forge-lint: disable-next-line(unsafe-typecast)
                advice.lpFeeSurchargePips = uint24(top < b.sessionLimit ? top : b.sessionLimit);
            }
        }
        if (!x.isBuy || !b.bound) return advice;
        advice.quoteTakePips = b.takePips;
        advice.recipient = b.vault;
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev Never used (bind requires only the before phase to be meaningful); returns no advice.
    function afterSwap(HookrTypes.SwapContext calldata, int128, int128)
        external
        pure
        returns (HookrTypes.Advice memory advice)
    {
        return advice;
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev A source pool's liquidity is not restricted by this module.
    function beforeAddLiquidity(PoolId, address) external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IHookrZapAccrual
    function createVault(ZapRelayTypes.Route calldata route, bytes32 salt) external returns (address vault) {
        vault = vaultDeployer.deploy(route, _salt(msg.sender, salt));
        PoolId target = route.target.toId();
        _state().vaults[vault] = VaultRecord(target, route.gate, true);
        emit VaultCreated(vault, msg.sender, target, route.gate, route.mode, route.sink);
    }

    /// @inheritdoc IHookrZapAccrual
    function predictVault(address creator, ZapRelayTypes.Route calldata route, bytes32 salt)
        external
        view
        returns (address)
    {
        return vaultDeployer.predict(route, _salt(creator, salt));
    }

    /// @inheritdoc IHookrZapAccrual
    function vaultRecord(address vault) external view returns (bool exists, PoolId target, address gate) {
        VaultRecord storage v = _state().vaults[vault];
        return (v.exists, v.target, v.gate);
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

    /// @inheritdoc IHookrZapAccrual
    function terms(address binder, PoolId id) external view returns (uint24 takePips, address vault, bool bound) {
        Bound storage b = _state().bound[binder][id];
        return (b.takePips, b.vault, b.bound);
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
