// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookrTypes} from "../../types/HookrTypes.sol";
import {IHookrAdvisory} from "../../interfaces/IHookrAdvisory.sol";
import {IHookrRegistry} from "../../interfaces/IHookrRegistry.sol";
import {IHookrRoot} from "../../interfaces/IHookrRoot.sol";
import {HookrSessionTiers} from "../../libraries/HookrSessionTiers.sol";
import {HookrAttributionTypes as T} from "./types/HookrAttributionTypes.sol";
import {IHookrPartnerRegistry} from "./interfaces/IHookrPartnerRegistry.sol";

/// @title Hookr partner tax
/// @notice Strict, before-phase phase-one advisory that charges a frozen buy tax and a frozen sell tax as a quote
///         take, credited by the root as HookrRules claims to the pool's attributed revenue vault.
/// @dev Phase one admits only RULES and ADVISORY kinds, so this is the smallest faithful take: an ADVISORY with
///      phaseMask BEFORE_SWAP, no LP surcharge, no subject take, not fail-open (a take may not be fail-open).
///
///      Swap path. `beforeSwap` reads one storage slot the pool froze at bind and makes no external call. It
///      cannot see the partner registry, the vault or any mutable state, so partner retirement, payee rotation,
///      registry ownership or a vault that cannot receive can never stop a swap.
///
///      Coverage. Every buy (exact input and exact output) pays `buyTaxPips` of the gross buyer spend; every
///      exact-input sell pays `sellTaxPips` of the quote it releases. The phase-one root cannot take quote from an
///      exact-output sell in either phase (HookrRoot.beforeSwap / afterSwap), so while the sell tax is nonzero an
///      exact-output sell is REJECTED rather than let through untaxed. Exact-output sells of a pool with a zero
///      sell tax pass.
///
///      Recapture legs. On a recapture pool the root asks this advisory about every arb recapture leg of the pool's
///      frozen lane executor as an unauthenticated swap of that executor, and charges the leg the take it answers,
///      credited to the vault as any outside swap's (HookrRoot `FRAME_LEG`, HookrRecapture `settleLeg`). So a leg in
///      a taxed direction pays the tax, and an exact-output sell leg is rejected while the sell tax is nonzero, as any
///      exact-output sell is. The advisory needs no state for it and does not know whether a swap is a leg.
///
///      Hookr dynamic fees (closed by Hookr 1). On a pool whose Rules enable dynamic fees, the root asks
///      this advisory first, simulates the swap net of Rules' own take and this advisory's quote take, and Rules
///      price the dynamic fee on that simulated movement. The tax therefore never raises the dynamic fee: a taxed
///      exact-input buy pays the same dynamic fee as an untaxed buy that reaches the pool with the same input.
///
///      Bind. Only the one root this advisory serves may bind, only for the pool it is initializing, once. The
///      config must name the vault the partner registry recorded for that pool with the same taxes, so this take
///      can only ever pay an attributed split vault: a pool opened through any other launcher cannot bind it. The
///      bind also refuses caps that could later make a swap revert `AggregateCapExceeded`: the tax must fit the
///      advisory's admission cap, and tax + the Rules admission's quote-take cap must fit the pool's cap.
///
///      Session tiers (optional off-market surcharge). The bind data is either `abi.encode(TaxConfig)` (96 bytes)
///      or `abi.encode(TaxConfig, HookrSessionTiers.Tiers)` (352 bytes). Non-empty tiers are checked against
///      MAX_TAX_PIPS and frozen with the tax. On each swap the tier of the current US equity session, read from the
///      shared calendar fixed at construction, is added to the direction's tax, and the sum is clamped to the
///      pool's `limit`: the smallest of MAX_TAX_PIPS, the advisory's admission cap and the pool cap left above the
///      Rules' worst case, the same bounds the tax itself must fit at bind. A calendar read that fails charges the
///      highest of the five tiers (`HookrSessionTiers.highest`) and never reverts the swap. Empty tiers, or the
///      96-byte encoding, cost one branch.
contract HookrDirectionalTax is IHookrAdvisory {
    using PoolIdLibrary for PoolKey;

    /// @notice Creator knobs, fixed per pool at launch and signed by the partner's voucher: the buy tax and the sell
    ///         tax, each in pips of the taxed quote amount, within [MIN_TAX_PIPS, MAX_TAX_PIPS] and not both zero.
    ///         The defaults are what a launch form pre-fills; nothing enforces them.
    uint24 public constant MIN_TAX_PIPS = 0;
    uint24 public constant MAX_TAX_PIPS = T.MAX_TAX_PIPS;
    uint24 public constant DEFAULT_BUY_TAX_PIPS = 30_000;
    uint24 public constant DEFAULT_SELL_TAX_PIPS = 30_000;
    /// @notice Optional session tiers (default: none): each of the five tiers within [0, MAX_TAX_PIPS] and each ramp
    ///         within [0, MAX_RAMP_SECONDS]; tax plus tier is clamped to the pool's limit on every swap.
    uint256 public constant MAX_RAMP_SECONDS = HookrSessionTiers.MAX_RAMP_SECONDS;

    /// @notice The only root this advisory serves.
    address public immutable root;
    /// @notice The root's admission registry.
    IHookrRegistry public immutable registry;
    /// @notice Where the launcher records attributions.
    IHookrPartnerRegistry public immutable partnerRegistry;
    /// @notice The shared US equity calendar (a HookrSessionAdvisory) session tiers read `sessionAt` from.
    address public immutable calendar;

    /// @notice Frozen per-pool state. One storage slot.
    /// @param buyTaxPips Tax on every buy
    /// @param sellTaxPips Tax on exact-input sells
    /// @param vault The attributed revenue vault the take is credited to
    /// @param limit Largest take any swap of the pool is charged, session tier included
    /// @param tiered True when the pool bound non-empty session tiers
    struct Bound {
        uint24 buyTaxPips;
        uint24 sellTaxPips;
        address vault;
        uint24 limit;
        bool tiered;
    }

    mapping(PoolId => Bound) private _bound;
    mapping(PoolId => HookrSessionTiers.Tiers) private _tiers;

    error Unauthorized();
    error AlreadyBound();
    error InvalidConfig();
    error NotAttributed(PoolId id);
    error CapsTooLow(uint256 tax, uint256 available);
    error UnknownPool(PoolId id);

    event TaxBound(PoolId indexed id, address indexed vault, uint24 buyTaxPips, uint24 sellTaxPips);
    event SessionTiersBound(PoolId indexed id, HookrSessionTiers.Tiers tiers, uint24 limit);

    /// @param root_ The one root this advisory serves; its registry is read from it
    /// @param partnerRegistry_ The attribution record bind checks
    /// @param calendar_ The shared session calendar (a HookrSessionAdvisory)
    constructor(address root_, IHookrPartnerRegistry partnerRegistry_, address calendar_) {
        if (root_.code.length == 0 || address(partnerRegistry_).code.length == 0 || calendar_.code.length == 0) {
            revert InvalidConfig();
        }
        root = root_;
        registry = IHookrRoot(root_).registry();
        partnerRegistry = partnerRegistry_;
        calendar = calendar_;
    }

    /// @inheritdoc IHookrAdvisory
    function configSchemaHash() external pure returns (bytes32) {
        return keccak256(
            "hookr.partner-tax.v2(uint24 buyTaxPips,uint24 sellTaxPips,address vault)[SessionTiers(uint24 regularPips,uint24 preMarketPips,uint24 afterHoursPips,uint24 overnightPips,uint24 closedPips,uint16 openRampSeconds,uint16 closeRampSeconds,uint8 flags)]"
        );
    }

    /// @notice The frozen tax of a pool; zero fields for an unbound pool.
    function taxOf(PoolId id) external view returns (T.TaxConfig memory) {
        Bound memory b = _bound[id];
        return T.TaxConfig(b.buyTaxPips, b.sellTaxPips, b.vault);
    }

    /// @notice The frozen state of a pool: taxes, vault, take limit and whether it has session tiers.
    function boundOf(PoolId id) external view returns (Bound memory) {
        return _bound[id];
    }

    /// @notice The frozen session tiers of a pool; zero fields when it has none.
    function tiersOf(PoolId id) external view returns (HookrSessionTiers.Tiers memory) {
        return _tiers[id];
    }

    /// @notice The take a swap of pool `id` in direction `isBuy` would be charged at `timestamp`, session tier
    ///         included and clamped to the pool's limit. Zero for an unbound pool.
    function takeAt(PoolId id, bool isBuy, uint256 timestamp) external view returns (uint24) {
        return _take(_bound[id], id, isBuy, timestamp);
    }

    /// @inheritdoc IHookrAdvisory
    function bind(PoolKey calldata key, HookrTypes.PoolConfig calldata pc, bytes calldata data)
        external
        returns (bytes32)
    {
        PoolId id = key.toId();
        if (
            msg.sender != root || address(key.hooks) != root
                || PoolId.unwrap(IHookrRoot(root).bindingPool()) != PoolId.unwrap(id)
        ) revert Unauthorized();
        if (_bound[id].vault != address(0)) revert AlreadyBound();
        T.TaxConfig memory t;
        HookrSessionTiers.Tiers memory tiers;
        if (data.length == 96) {
            t = abi.decode(data, (T.TaxConfig));
            if (keccak256(data) != keccak256(abi.encode(t))) revert InvalidConfig();
        } else if (data.length == 96 + HookrSessionTiers.ENCODED_SIZE) {
            (t, tiers) = abi.decode(data, (T.TaxConfig, HookrSessionTiers.Tiers));
            if (keccak256(data) != keccak256(abi.encode(t, tiers))) revert InvalidConfig();
            HookrSessionTiers.check(tiers, T.MAX_TAX_PIPS);
        } else {
            revert InvalidConfig();
        }
        if (
            t.vault == address(0) || pc.advisory != address(this) || pc.advisoryFailOpen
                || pc.advisoryPhases != HookrTypes.BEFORE_SWAP || t.buyTaxPips > T.MAX_TAX_PIPS
                || t.sellTaxPips > T.MAX_TAX_PIPS
        ) revert InvalidConfig();
        T.Attribution memory a = partnerRegistry.attribution(PoolId.unwrap(id));
        if (
            !a.recorded || a.root != root || a.vault != t.vault || a.buyTaxPips != t.buyTaxPips
                || a.sellTaxPips != t.sellTaxPips
        ) revert NotAttributed(id);
        uint256 tax = t.buyTaxPips > t.sellTaxPips ? t.buyTaxPips : t.sellTaxPips;
        uint256 own = registry.admission(root, address(this)).caps.maxQuoteTakePips;
        if (tax > own) revert CapsTooLow(tax, own);
        uint256 poolCap = pc.caps.maxQuoteTakePips;
        uint256 rulesCap = registry.admission(root, pc.rules).caps.maxQuoteTakePips;
        uint256 rulesWorst = rulesCap < poolCap ? rulesCap : poolCap;
        if (tax + rulesWorst > poolCap) revert CapsTooLow(tax, poolCap - rulesWorst);
        uint256 limit = poolCap - rulesWorst;
        if (own < limit) limit = own;
        if (T.MAX_TAX_PIPS < limit) limit = T.MAX_TAX_PIPS;
        bool tiered = !HookrSessionTiers.isEmpty(tiers);
        _bound[id] = Bound(t.buyTaxPips, t.sellTaxPips, t.vault, uint24(limit), tiered);
        emit TaxBound(id, t.vault, t.buyTaxPips, t.sellTaxPips);
        if (tiered) {
            _tiers[id] = tiers;
            emit SessionTiersBound(id, tiers, uint24(limit));
        }
        return keccak256(data);
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev Liquidity is never gated by the tax. Rules keep their own Anti-Snipe liquidity guard.
    function beforeAddLiquidity(PoolId, address) external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev Without session tiers: one SLOAD and no external call. With them: one more SLOAD and one bounded
    ///      static call to the calendar, whose failure charges the highest tier. Reverts only for a pool this advisory
    ///      never bound. An exact-output sell is rejected whenever its take at this moment would be nonzero.
    function beforeSwap(HookrTypes.SwapContext calldata x) external view returns (HookrTypes.Advice memory advice) {
        Bound memory b = _bound[x.id];
        if (b.vault == address(0)) revert UnknownPool(x.id);
        advice.recipient = b.vault;
        uint24 take = _take(b, x.id, x.isBuy, block.timestamp);
        if (x.isBuy || x.exactInput) {
            advice.quoteTakePips = take;
        } else if (take != 0) {
            advice.reject = true;
        }
    }

    /// @dev The direction's tax plus, for a tiered pool, the session tier at `timestamp`, clamped to `limit`.
    function _take(Bound memory b, PoolId id, bool isBuy, uint256 timestamp) private view returns (uint24) {
        uint256 take = isBuy ? b.buyTaxPips : b.sellTaxPips;
        if (b.tiered) {
            take += HookrSessionTiers.valueAt(_tiers[id], calendar, timestamp);
            if (take > b.limit) take = b.limit;
        }
        return uint24(take);
    }

    /// @inheritdoc IHookrAdvisory
    /// @dev Never called: pools bind this advisory with the before phase only. Returns no advice.
    function afterSwap(HookrTypes.SwapContext calldata, int128, int128)
        external
        pure
        returns (HookrTypes.Advice memory advice)
    {
        return advice;
    }
}
