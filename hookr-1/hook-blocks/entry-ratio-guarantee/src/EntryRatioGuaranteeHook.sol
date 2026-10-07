// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Position as V4Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ErgTypes} from "./interfaces/ErgTypes.sol";
import {IEntryRatioGuarantee} from "./interfaces/IEntryRatioGuarantee.sol";
import {IErgPriceReference} from "./interfaces/IErgPriceReference.sol";
import {ErgExitMath} from "./libraries/ErgExitMath.sol";
import {ErgPositionMath} from "./libraries/ErgPositionMath.sol";
import {EntryRatioVault} from "./EntryRatioVault.sol";

/// @title EntryRatioGuaranteeHook
/// @notice Standalone Uniswap v4 custody hook: the Entry Ratio Guarantee. LPs deposit through
///         the `EntryRatioVault` this hook creates; the vault owns every enrolled PoolManager position (salt = the
///         position id). At exit the hook settles the vault's removal through `afterRemoveLiquidity` with a return
///         delta: accrued fees are forfeited into the pool's reserve, and when the LP asks for its entry ratio the
///         reserve pays the currency the position lost and takes the currency it gained, at the position's own
///         conversion rate, up to the pool's coverage and draw caps. An exit that asks for the entry ratio must
///         find the pool price inside the reference band, as a deposit must.
/// @dev Permission word 0x0301: beforeRemoveLiquidity (9) gates a vault removal (the lock, the option window,
///      full exits only); afterRemoveLiquidity (8) sees the removal's delta and fees; its return delta (0) moves
///      value between the LP and the reserve. There is no swap, donate, initialize or add bit, so swaps on any pool
///      never call this contract and cannot be stopped by it; removals by anyone but the vault are passed through
///      with a zero delta. The reserve is held as this hook's ERC-6909 claims in the PoolManager and accounted per
///      pool, so one pool's exits can never draw another pool's reserve. There is no owner, no pause and no
///      upgrade. A pool's creator registers it and chooses its terms inside the bounds `validateTerms` enforces;
///      the entry band is derived as half the pool fee less the reference's declared tolerance. The registrar only
///      allowlists price references per currency pair and can close a pool to new deposits; it is a contract (an
///      `EntryRatioRegistrar`, which puts allowlisting behind Hookr's governed timelock).
///      Protocol share. Every forfeited fee (the premium an LP pays for the guarantee) is split at exit: the pool's
///      `protocolShareBps`, frozen at registration and never below the release floor `minProtocolShareBps` (itself
///      at least 2,000), is credited to the immutable `protocolRecipient` as a claim backed by this hook's ERC-6909
///      balance; the rest funds the reserve. An exercising exit keeps only its leg's waiver out of the split:
///      `fee / (1 - fee)` of what the reserve takes, in that currency. The claim surface
///      (`protocolRecipient`, `poolManager`, `claimable`, `claimTo`, `claimAsClaims`) is the one the Hookr treasury
///      collects from.
contract EntryRatioGuaranteeHook is IHooks, IEntryRatioGuarantee, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using LPFeeLibrary for uint24;
    using SafeCast for int256;

    /// @notice Pool record: key, frozen terms, creator, status, reserve and draw window.
    /// @dev The draw window: the first paying exit after a window lapses opens a new one of
    ///      `DRAW_WINDOW_SECONDS` and sets its room to `maxDrawBps` of the reserve it sees; every exit in the window
    ///      draws from that room. Splitting a position into many no longer multiplies the draw cap.
    struct PoolRecord {
        PoolKey key;
        ErgTypes.PoolTerms terms;
        address creator;
        bool registered;
        bool closed;
        uint256 reserve0;
        uint256 reserve1;
        uint40 drawWindowStart;
        uint256 drawRoom0;
        uint256 drawRoom1;
    }

    /// @notice The only permission bits this hook's address carries: 9, 8 and 0.
    uint160 public constant HOOK_FLAGS = Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;
    /// @notice Shortest LOCK term a pool may offer.
    uint32 public constant MIN_LOCK_SECONDS = 1 days;
    /// @notice Shortest OPTION minimum hold a pool may offer; also the anti-JIT floor for OPTION exits.
    uint32 public constant MIN_OPTION_HOLD_SECONDS = 1 hours;
    /// @notice Shortest OPTION exercise window a pool may offer.
    uint32 public constant MIN_OPTION_WINDOW_SECONDS = 1 hours;
    /// @notice Longest lock, hold or window a pool may offer.
    uint32 public constant MAX_TERM_SECONDS = 730 days;
    /// @notice Smallest OPTION premium (share of fees forfeited without exercise) a pool may charge.
    uint16 public constant MIN_OPTION_PREMIUM_BPS = 1_000;
    /// @notice Largest OPTION premium, coverage or draw cap a pool may set: all of it.
    uint16 public constant MAX_BPS = 10_000;
    /// @notice Smallest coverage share a pool may set.
    uint16 public constant MIN_COVERAGE_BPS = 1;
    /// @notice Smallest draw cap a pool may set.
    uint16 public constant MIN_DRAW_BPS = 1;
    /// @notice Suggested LOCK term for a new pool.
    uint32 public constant DEFAULT_LOCK_SECONDS = 30 days;
    /// @notice Suggested OPTION minimum hold for a new pool.
    uint32 public constant DEFAULT_OPTION_HOLD_SECONDS = 1 days;
    /// @notice Suggested OPTION exercise window for a new pool.
    uint32 public constant DEFAULT_OPTION_WINDOW_SECONDS = 7 days;
    /// @notice Suggested OPTION premium for a new pool.
    uint16 public constant DEFAULT_OPTION_PREMIUM_BPS = 2_500;
    /// @notice Suggested coverage share for a new pool.
    uint16 public constant DEFAULT_COVERAGE_BPS = 10_000;
    /// @notice Suggested draw cap for a new pool: the exits of one draw window may take a tenth of the reserve.
    uint16 public constant DEFAULT_MAX_DRAW_BPS = 1_000;
    /// @notice Length of a pool's draw window. The draw cap applies to all exits in one window together, not to each
    ///         exit, so an LP cannot multiply it by splitting a position. Equal to the shortest OPTION
    ///         window, so every exercise window reaches the start of a fresh draw window.
    uint32 public constant DRAW_WINDOW_SECONDS = 1 hours;
    /// @notice Shortest LOCK coverage horizon a pool may set (seconds after the lock ends during which a LOCK exit
    ///         may still ask for the entry ratio). Zero is also accepted and means the right never lapses.
    uint32 public constant MIN_LOCK_COVERAGE_SECONDS = 1 days;
    /// @notice Longest LOCK coverage horizon a pool may set, other than zero (never lapses).
    uint32 public constant MAX_LOCK_COVERAGE_SECONDS = 730 days;
    /// @notice Suggested LOCK coverage horizon for a new pool: zero, the right never lapses.
    uint32 public constant DEFAULT_LOCK_COVERAGE_SECONDS = 0;
    /// @notice Lowest protocol share of forfeited fees any release of this hook may allow: Hookr's 2,000 bps floor.
    uint16 public constant MIN_PROTOCOL_SHARE_BPS = 2_000;
    /// @notice Highest protocol share of forfeited fees a pool may set (HookrRules' ceiling).
    uint16 public constant MAX_PROTOCOL_SHARE_BPS = 5_000;
    /// @notice Suggested protocol share for a new pool; `defaultCreatorTerms` lifts it to `minProtocolShareBps`.
    uint16 public constant DEFAULT_PROTOCOL_SHARE_BPS = 2_000;
    /// @notice Smallest static pool fee a registered pool may carry; fees are what fund the reserve.
    uint24 public constant MIN_POOL_FEE_PIPS = 100;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant PIPS = 1_000_000;

    /// @inheritdoc IEntryRatioGuarantee
    IPoolManager public immutable poolManager;
    /// @inheritdoc IEntryRatioGuarantee
    address public immutable vault;
    /// @inheritdoc IEntryRatioGuarantee
    address public immutable registrar;
    /// @inheritdoc IEntryRatioGuarantee
    address public immutable protocolRecipient;
    /// @notice The lowest protocol share any pool may register with, set once at deployment within
    ///         `[MIN_PROTOCOL_SHARE_BPS, MAX_PROTOCOL_SHARE_BPS]`.
    uint16 public immutable minProtocolShareBps;

    mapping(PoolId => PoolRecord) internal _pools;
    mapping(uint256 => ErgTypes.Position) internal _positions;
    /// @dev keccak256(currency0, currency1, reference) => allowed by the registrar.
    mapping(bytes32 => bool) internal _referenceAllowed;
    /// @dev Unpaid protocol claim per currency; only `protocolRecipient` ever holds one.
    mapping(Currency => uint256) internal _protocolClaims;

    /// @notice Thrown when the vault's hook data is not one ABI word holding 0 or 1.
    error InvalidHookData();
    /// @notice Thrown when a removal reports a negative principal (a PoolManager invariant; never expected).
    error UnexpectedDelta();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @notice Deploys the hook and its vault.
    /// @dev The address must carry exactly bits 9, 8 and 0 (a mined CREATE3 or CREATE2 salt). The vault is created
    ///      here so the pairing is immutable and verifiable from the hook alone. The registrar must be a contract
    ///      that is not an EIP-7702 delegated account. A contract's code cannot change, so the role can never later be
    ///      exercised through a delegation; an externally owned registrar could delegate after deployment and keep
    ///      the role. Hookr 1's registry applies the delegation rule to its owner and guardian. The protocol recipient
    ///      and the release's protocol share floor are fixed here, as in HookrRules.
    /// @param manager The Uniswap v4 PoolManager
    /// @param registrar_ The contract that may allowlist price references and close pools
    /// @param protocolRecipient_ The account credited with every pool's protocol share (the Hookr treasury)
    /// @param minProtocolShareBps_ The lowest protocol share a pool may register with, 2,000 to 5,000
    constructor(IPoolManager manager, address registrar_, address protocolRecipient_, uint16 minProtocolShareBps_) {
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
        if (uint160(address(this)) & Hooks.ALL_HOOK_MASK != HOOK_FLAGS) revert HookAddressMismatch();
        if (registrar_.code.length == 0 || _isDelegatedAccount(registrar_)) revert NotRegistrar();
        if (
            protocolRecipient_ == address(0) || protocolRecipient_ == address(manager)
                || minProtocolShareBps_ < MIN_PROTOCOL_SHARE_BPS || minProtocolShareBps_ > MAX_PROTOCOL_SHARE_BPS
        ) revert InvalidProtocolConfig();
        poolManager = manager;
        registrar = registrar_;
        protocolRecipient = protocolRecipient_;
        minProtocolShareBps = minProtocolShareBps_;
        vault = address(new EntryRatioVault(manager, IEntryRatioGuarantee(address(this))));
    }

    /// @notice The hook's permission struct: beforeRemoveLiquidity, afterRemoveLiquidity and its return delta.
    /// @return p The permissions validated in the constructor
    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeRemoveLiquidity = true;
        p.afterRemoveLiquidity = true;
        p.afterRemoveLiquidityReturnDelta = true;
    }

    /// @inheritdoc IEntryRatioGuarantee
    function setPriceReference(Currency currency0, Currency currency1, address priceReference, bool allowed) external {
        if (msg.sender != registrar) revert NotRegistrar();
        if (Currency.unwrap(currency0) >= Currency.unwrap(currency1)) revert InvalidReferencePair();
        if (allowed && (priceReference.code.length == 0 || _isDelegatedAccount(priceReference))) {
            revert InvalidTerms(0);
        }
        _referenceAllowed[_referenceSlot(currency0, currency1, priceReference)] = allowed;
        emit PriceReferenceSet(currency0, currency1, priceReference, allowed);
    }

    /// @inheritdoc IEntryRatioGuarantee
    function closePool(PoolId id) external {
        if (msg.sender != registrar) revert NotRegistrar();
        PoolRecord storage p = _pools[id];
        if (!p.registered) revert NotRegistered(id);
        if (!p.closed) {
            p.closed = true;
            emit PoolClosed(id);
        }
    }

    /// @inheritdoc IEntryRatioGuarantee
    function registerPool(PoolKey calldata key, ErgTypes.CreatorTerms calldata terms) external {
        if (address(key.hooks) != address(this)) revert WrongHook();
        if (key.fee.isDynamicFee() || key.fee < MIN_POOL_FEE_PIPS) revert UnsupportedFee(key.fee);
        PoolId id = key.toId();
        PoolRecord storage p = _pools[id];
        if (p.registered) revert AlreadyRegistered(id);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized(id);
        address ref = terms.priceReference;
        if (ref.code.length == 0 || _isDelegatedAccount(ref)) revert InvalidTerms(0);
        ErgTypes.PoolTerms memory t = ErgTypes.PoolTerms({
            priceReference: terms.priceReference,
            lockSeconds: terms.lockSeconds,
            optionHoldSeconds: terms.optionHoldSeconds,
            optionWindowSeconds: terms.optionWindowSeconds,
            optionPremiumBps: terms.optionPremiumBps,
            coverageBps: terms.coverageBps,
            maxDrawBps: terms.maxDrawBps,
            maxEntrySqrtDeviationPips: entryBandPips(key.fee, _declaredError(ref)),
            lockCoverageSeconds: terms.lockCoverageSeconds,
            protocolShareBps: terms.protocolShareBps
        });
        validateTerms(t, key.fee);
        if (!_referenceAllowed[_referenceSlot(key.currency0, key.currency1, ref)]) revert ReferenceNotAllowed(ref);
        p.key = key;
        p.terms = t;
        p.creator = msg.sender;
        p.registered = true;
        // The reference must answer now; a broken reference would otherwise register a pool nobody can enter.
        _reference(p);
        _entryReference(p);
        emit PoolRegistered(id, msg.sender, ref, t);
    }

    /// @notice Checks terms against the hook's immutable bounds. Reverts `InvalidTerms(field)` on the first failure.
    /// @dev The entry band may not exceed half the pool fee (`2 * band <= fee`). At exit the reserve buys the
    ///      position's surplus at the position's own average execution price. A position entered at the band edge
    ///      `sE = sF(1 + d)` whose range edge `sX` sits between the fair price `sF` and `sE` trades only between
    ///      `sX` and `sE`, so the reserve pays up to `sE * sX / sF^2 - 1 ~= 2d` above fair, while the fee that
    ///      position earns and forfeits is `phi / (1 - phi)` of its net input (also with a protocol fee on). The
    ///      round trip is unprofitable for every range only when `(1 + d)^2 <= 1 / (1 - phi)`, which `2d <= phi`
    ///      guarantees; the mirror case below fair needs `(1 - d)^2 >= 1 - phi`, which it also guarantees. A band
    ///      equal to the fee was safe only for a range edge exactly at the fair price (test/ErgReview.t.sol). The bound assumes the reference sits at the fair price; a reference that can sit
    ///      `e` away needs `e + band <= fee / 2`. `registerPool` therefore sets the band to `entryBandPips(fee, e)`,
    ///      half the fee less the reference's declared tolerance `e`, and field 7 refuses the pool when
    ///      nothing is left. The check stays so that any stored terms are provably inside the half-fee bound.
    ///      Field 9: the protocol share of forfeited fees runs from this release's `minProtocolShareBps` to
    ///      `MAX_PROTOCOL_SHARE_BPS`.
    /// @param t The terms
    /// @param fee The pool's static fee in pips
    function validateTerms(ErgTypes.PoolTerms memory t, uint24 fee) public view {
        if (t.priceReference == address(0)) revert InvalidTerms(0);
        if (t.lockSeconds < MIN_LOCK_SECONDS || t.lockSeconds > MAX_TERM_SECONDS) revert InvalidTerms(1);
        if (t.optionHoldSeconds < MIN_OPTION_HOLD_SECONDS || t.optionHoldSeconds > MAX_TERM_SECONDS) {
            revert InvalidTerms(2);
        }
        if (t.optionWindowSeconds < MIN_OPTION_WINDOW_SECONDS || t.optionWindowSeconds > MAX_TERM_SECONDS) {
            revert InvalidTerms(3);
        }
        if (t.optionPremiumBps < MIN_OPTION_PREMIUM_BPS || t.optionPremiumBps > MAX_BPS) revert InvalidTerms(4);
        if (t.coverageBps < MIN_COVERAGE_BPS || t.coverageBps > MAX_BPS) revert InvalidTerms(5);
        if (t.maxDrawBps < MIN_DRAW_BPS || t.maxDrawBps > MAX_BPS) revert InvalidTerms(6);
        if (t.maxEntrySqrtDeviationPips == 0 || uint256(t.maxEntrySqrtDeviationPips) * 2 > fee) revert InvalidTerms(7);
        if (
            t.lockCoverageSeconds != 0
                && (t.lockCoverageSeconds < MIN_LOCK_COVERAGE_SECONDS
                    || t.lockCoverageSeconds > MAX_LOCK_COVERAGE_SECONDS)
        ) revert InvalidTerms(8);
        if (t.protocolShareBps < minProtocolShareBps || t.protocolShareBps > MAX_PROTOCOL_SHARE_BPS) {
            revert InvalidTerms(9);
        }
    }

    /// @notice The widest entry band any pool with `fee` can get: half the fee, rounded down
    ///         (`2 * band <= fee`). A pool gets it only on a reference that declares zero tolerance.
    /// @param fee The pool's static fee in pips
    /// @return The ceiling, in pips of the reference sqrt price
    function maxEntryBandPips(uint24 fee) public pure returns (uint24) {
        return fee / 2;
    }

    /// @notice The entry band a pool with `fee` gets on a reference that declares `referenceErrorPips`: half the fee
    ///         less the declared tolerance, so that tolerance plus band never exceeds half the fee (review A1-R).
    ///         Zero when the tolerance takes the whole half fee; registration then refuses the pool (`InvalidTerms(7)`).
    /// @param fee The pool's static fee in pips
    /// @param referenceErrorPips The reference's `errorSqrtPips()`
    /// @return The largest distance, in pips of the reference sqrt price, a deposit's sqrt price may sit from it
    function entryBandPips(uint24 fee, uint24 referenceErrorPips) public pure returns (uint24) {
        uint24 ceiling = maxEntryBandPips(fee);
        return referenceErrorPips >= ceiling ? 0 : ceiling - referenceErrorPips;
    }

    /// @notice The suggested terms for a new pool on `priceReference`: a 30-day lock, a 1-day hold with a 7-day
    ///         window, a 25% premium, full coverage, a 10% draw cap per draw window, LOCK coverage that never lapses
    ///         and the protocol share at this release's floor (`DEFAULT_PROTOCOL_SHARE_BPS` or `minProtocolShareBps`,
    ///         whichever is higher).
    /// @param priceReference The reference the pool will name
    /// @return t The default creator terms
    function defaultCreatorTerms(address priceReference) external view returns (ErgTypes.CreatorTerms memory t) {
        t.priceReference = priceReference;
        t.lockSeconds = DEFAULT_LOCK_SECONDS;
        t.optionHoldSeconds = DEFAULT_OPTION_HOLD_SECONDS;
        t.optionWindowSeconds = DEFAULT_OPTION_WINDOW_SECONDS;
        t.optionPremiumBps = DEFAULT_OPTION_PREMIUM_BPS;
        t.coverageBps = DEFAULT_COVERAGE_BPS;
        t.maxDrawBps = DEFAULT_MAX_DRAW_BPS;
        t.lockCoverageSeconds = DEFAULT_LOCK_COVERAGE_SECONDS;
        t.protocolShareBps =
            minProtocolShareBps > DEFAULT_PROTOCOL_SHARE_BPS ? minProtocolShareBps : DEFAULT_PROTOCOL_SHARE_BPS;
    }

    /// @inheritdoc IEntryRatioGuarantee
    function enroll(
        uint256 positionId,
        address owner,
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint128 entry0,
        uint128 entry1,
        ErgTypes.Term term
    ) external {
        if (msg.sender != vault) revert NotVault();
        PoolId id = key.toId();
        PoolRecord storage p = _pools[id];
        if (!p.registered) revert NotRegistered(id);
        if (p.closed) revert PoolIsClosed(id);
        if (owner == address(0) || liquidity == 0 || _positions[positionId].owner != address(0)) {
            revert InvalidPosition(positionId);
        }
        (uint160 spot, int24 tick,,) = poolManager.getSlot0(id);
        // Independent of the vault: the PoolManager must hold exactly this liquidity for the vault under this
        // salt, and the entry amounts must be exactly what the PoolManager charges for it at this price.
        bytes32 key_ = V4Position.calculatePositionKey(vault, tickLower, tickUpper, bytes32(positionId));
        if (poolManager.getPositionLiquidity(id, key_) != liquidity) revert InvalidPosition(positionId);
        (uint256 expected0, uint256 expected1) =
            ErgPositionMath.amountsForAdd(tick, spot, tickLower, tickUpper, liquidity);
        if (expected0 != entry0 || expected1 != entry1) revert InvalidPosition(positionId);

        if (!_isAllowed(p)) revert ReferenceNotAllowed(p.terms.priceReference);
        uint160 ref = _reference(p);
        if (!_inBand(spot, ref, p.terms.maxEntrySqrtDeviationPips)) {
            revert EntryPriceOutOfBand(spot, ref, p.terms.maxEntrySqrtDeviationPips);
        }

        // The entry the cover cap reads is the reference's untrailing estimate, not its answer: an answer
        // still catching up to a genuine move would make its catch-up look like a deficit.
        uint160 entryRef = _entryReference(p);

        uint40 start = uint40(block.timestamp);
        uint40 unlockAt;
        uint40 expiry;
        if (term == ErgTypes.Term.LOCK) {
            unlockAt = start + p.terms.lockSeconds;
            if (p.terms.lockCoverageSeconds != 0) expiry = unlockAt + p.terms.lockCoverageSeconds;
        } else {
            unlockAt = start + p.terms.optionHoldSeconds;
            expiry = unlockAt + p.terms.optionWindowSeconds;
        }
        _positions[positionId] = ErgTypes.Position({
            owner: owner,
            start: start,
            unlockAt: unlockAt,
            expiry: expiry,
            term: term,
            open: true,
            poolId: id,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            entry0: entry0,
            entry1: entry1,
            entryReference: entryRef
        });
        emit PositionOpened(positionId, owner, id, term, liquidity, entry0, entry1, unlockAt, expiry, spot, ref);
    }

    /// @notice Gates a vault removal: the position must be open and removed whole, its lock or hold must have
    ///         ended, and the entry ratio can only be asked for until the position's expiry (an option's window, or
    ///         a LOCK's coverage horizon when the pool sets one). Other senders pass unchanged.
    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external view onlyPoolManager returns (bytes4) {
        if (sender == vault) {
            uint256 positionId = uint256(params.salt);
            ErgTypes.Position storage pos = _positions[positionId];
            _checkRemoval(positionId, pos, key, params);
            bool exercise = _decodeExercise(hookData);
            if (block.timestamp < pos.unlockAt) revert Locked(positionId, pos.unlockAt);
            if (exercise) {
                if (pos.expiry != 0 && block.timestamp > pos.expiry) {
                    revert ExerciseWindowClosed(positionId, pos.expiry);
                }
                _checkExercisePrice(_pools[pos.poolId]);
            }
        }
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @notice Settles a vault removal against the pool's reserve and returns the hook's delta.
    /// @dev The hook's delta per currency is the reserve change plus the protocol's share of the forfeits. Positive
    ///      components are minted to this hook as ERC-6909 claims (into the reserve and the protocol claim); negative
    ///      components are burned from its claims (out of the reserve). The LP's delta is the PoolManager's
    ///      `delta - (hookDelta + protocol)`. Other senders get a zero delta.
    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, BalanceDelta) {
        if (sender != vault) {
            return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        }
        uint256 positionId = uint256(params.salt);
        ErgTypes.Position storage pos = _positions[positionId];
        _checkRemoval(positionId, pos, key, params);
        bool exercise = _decodeExercise(hookData);
        PoolRecord storage p = _pools[pos.poolId];

        (uint256 principal0, uint256 fees0) = _split(delta.amount0(), feesAccrued.amount0());
        (uint256 principal1, uint256 fees1) = _split(delta.amount1(), feesAccrued.amount1());
        ErgTypes.ExitResult memory r =
            ErgExitMath.settle(_inputs(pos, p, principal0, principal1, fees0, fees1, exercise));

        pos.open = false;
        if (exercise) _recordDraw(p, r);
        p.reserve0 = _apply(p.reserve0, r.hookDelta0);
        p.reserve1 = _apply(p.reserve1, r.hookDelta1);
        int256 total0 = r.hookDelta0 + int256(r.protocol0);
        int256 total1 = r.hookDelta1 + int256(r.protocol1);
        _moveClaims(key.currency0, total0);
        _moveClaims(key.currency1, total1);

        emit PositionClosed(positionId, pos.owner, pos.poolId, exercise, r);
        emit ReserveUpdated(pos.poolId, p.reserve0, p.reserve1);
        if (r.protocol0 != 0 || r.protocol1 != 0) {
            _protocolClaims[key.currency0] += r.protocol0;
            _protocolClaims[key.currency1] += r.protocol1;
            emit ProtocolCredited(pos.poolId, r.protocol0, r.protocol1);
        }
        return (IHooks.afterRemoveLiquidity.selector, toBalanceDelta(total0.toInt128(), total1.toInt128()));
    }

    /// @inheritdoc IEntryRatioGuarantee
    function claimTo(Currency currency, address to) external returns (uint256 amount) {
        amount = _debit(currency, to);
        poolManager.unlock(abi.encode(currency, to, amount));
        emit Claimed(currency, msg.sender, to, amount);
    }

    /// @inheritdoc IEntryRatioGuarantee
    function claimAsClaims(Currency currency, address to) external returns (uint256 amount) {
        amount = _debit(currency, to);
        poolManager.transfer(to, currency.toId(), amount);
        emit Claimed(currency, msg.sender, to, amount);
    }

    /// @notice Pays a protocol claim during this hook's own unlock: burns the hook's ERC-6909 claims and takes the
    ///         tokens to the recipient. Only the PoolManager calls it, and only for an unlock this hook opened.
    /// @param data `abi.encode(currency, to, amount)`
    /// @return Empty bytes
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (Currency currency, address to, uint256 amount) = abi.decode(data, (Currency, address, uint256));
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, to, amount);
        return "";
    }

    /// @inheritdoc IEntryRatioGuarantee
    function claimable(Currency currency, address account) external view returns (uint256) {
        return account == protocolRecipient ? _protocolClaims[currency] : 0;
    }

    /// @inheritdoc IEntryRatioGuarantee
    function totalLiability(Currency currency) external view returns (uint256) {
        return _protocolClaims[currency];
    }

    /// @inheritdoc IEntryRatioGuarantee
    function isPriceReferenceAllowed(Currency currency0, Currency currency1, address priceReference)
        external
        view
        returns (bool)
    {
        return _referenceAllowed[_referenceSlot(currency0, currency1, priceReference)];
    }

    /// @inheritdoc IEntryRatioGuarantee
    function poolCreator(PoolId id) external view returns (address) {
        return _pools[id].creator;
    }

    /// @inheritdoc IEntryRatioGuarantee
    function isRegistered(PoolId id) external view returns (bool) {
        return _pools[id].registered;
    }

    /// @inheritdoc IEntryRatioGuarantee
    function isClosed(PoolId id) external view returns (bool) {
        return _pools[id].closed;
    }

    /// @inheritdoc IEntryRatioGuarantee
    function poolKey(PoolId id) external view returns (PoolKey memory) {
        if (!_pools[id].registered) revert NotRegistered(id);
        return _pools[id].key;
    }

    /// @inheritdoc IEntryRatioGuarantee
    function poolTerms(PoolId id) external view returns (ErgTypes.PoolTerms memory) {
        if (!_pools[id].registered) revert NotRegistered(id);
        return _pools[id].terms;
    }

    /// @inheritdoc IEntryRatioGuarantee
    function reserves(PoolId id) external view returns (uint256 reserve0, uint256 reserve1) {
        return (_pools[id].reserve0, _pools[id].reserve1);
    }

    /// @inheritdoc IEntryRatioGuarantee
    function position(uint256 positionId) external view returns (ErgTypes.Position memory) {
        return _positions[positionId];
    }

    /// @inheritdoc IEntryRatioGuarantee
    function previewExit(uint256 positionId, bool exercise) external view returns (ErgTypes.ExitResult memory) {
        ErgTypes.Position storage pos = _positions[positionId];
        if (!pos.open) revert RemovalMismatch(positionId);
        PoolRecord storage p = _pools[pos.poolId];
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(pos.poolId);
        (uint256 principal0, uint256 principal1) =
            ErgPositionMath.amountsForRemoval(tick, sqrtPriceX96, pos.tickLower, pos.tickUpper, pos.liquidity);
        (uint256 fees0, uint256 fees1) =
            ErgPositionMath.feesOwed(poolManager, pos.poolId, vault, pos.tickLower, pos.tickUpper, bytes32(positionId));
        return ErgExitMath.settle(_inputs(pos, p, principal0, principal1, fees0, fees1, exercise));
    }

    /// @inheritdoc IEntryRatioGuarantee
    function entryPriceCheck(PoolId id) external view returns (uint160 spot, uint160 reference_, bool ok) {
        PoolRecord storage p = _pools[id];
        if (!p.registered) revert NotRegistered(id);
        (spot,,,) = poolManager.getSlot0(id);
        reference_ = _reference(p);
        ok = !p.closed && _isAllowed(p) && _inBand(spot, reference_, p.terms.maxEntrySqrtDeviationPips);
    }

    /// @inheritdoc IHooks
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        pure
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function _checkRemoval(
        uint256 positionId,
        ErgTypes.Position storage pos,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params
    ) internal view {
        if (
            !pos.open || PoolId.unwrap(pos.poolId) != PoolId.unwrap(key.toId()) || pos.tickLower != params.tickLower
                || pos.tickUpper != params.tickUpper || params.liquidityDelta != -int256(uint256(pos.liquidity))
        ) revert RemovalMismatch(positionId);
    }

    function _decodeExercise(bytes calldata hookData) internal pure returns (bool) {
        if (hookData.length != 32) revert InvalidHookData();
        uint256 word = abi.decode(hookData, (uint256));
        if (word > 1) revert InvalidHookData();
        return word == 1;
    }

    function _inputs(
        ErgTypes.Position storage pos,
        PoolRecord storage p,
        uint256 principal0,
        uint256 principal1,
        uint256 fees0,
        uint256 fees1,
        bool exercise
    ) internal view returns (ErgExitMath.Inputs memory x) {
        x.principal0 = principal0;
        x.principal1 = principal1;
        x.fees0 = fees0;
        x.fees1 = fees1;
        x.entry0 = pos.entry0;
        x.entry1 = pos.entry1;
        x.reserve0 = p.reserve0;
        x.reserve1 = p.reserve1;
        // LOCK forfeits every fee on every exit; OPTION forfeits every fee only when it exercises.
        x.forfeitBps = (pos.term == ErgTypes.Term.LOCK || exercise) ? BPS : p.terms.optionPremiumBps;
        x.guarantee = exercise;
        x.coverageBps = p.terms.coverageBps;
        x.maxDrawBps = p.terms.maxDrawBps;
        x.protocolShareBps = p.terms.protocolShareBps;
        x.feePips = p.key.fee;
        if (exercise) {
            // The principal at the reference price floors a capped leg's rate.
            uint160 ref = _reference(p);
            (x.refPrincipal0, x.refPrincipal1) = ErgPositionMath.amountsForRemoval(
                TickMath.getTickAtSqrtPrice(ref), ref, pos.tickLower, pos.tickUpper, pos.liquidity
            );
            // What the deposit would have cost at its entry reference price (the reference's untrailing estimate
            // at deposit): the leg covers only the deficit the reference saw from there to here, never one a push
            // inside the band manufactures or the answer's own catch-up after a move.
            uint160 entryRef = pos.entryReference;
            (x.refEntry0, x.refEntry1) = ErgPositionMath.amountsForAdd(
                TickMath.getTickAtSqrtPrice(entryRef), entryRef, pos.tickLower, pos.tickUpper, pos.liquidity
            );
        }
        if (_drawWindowOpen(p)) {
            (x.drawRoom0, x.drawRoom1) = (p.drawRoom0, p.drawRoom1);
        } else {
            // A fresh window: its room is the draw cap of the reserve this exit sees, including what the reserve
            // keeps of its own forfeits in the paid currency, which is exactly the cap a lone exit has.
            x.drawRoom0 = FullMath.mulDiv(
                x.reserve0 + ErgExitMath.kept(ErgExitMath.forfeit(fees0, x.forfeitBps), x.protocolShareBps),
                x.maxDrawBps,
                BPS
            );
            x.drawRoom1 = FullMath.mulDiv(
                x.reserve1 + ErgExitMath.kept(ErgExitMath.forfeit(fees1, x.forfeitBps), x.protocolShareBps),
                x.maxDrawBps,
                BPS
            );
        }
    }

    function _drawWindowOpen(PoolRecord storage p) internal view returns (bool) {
        return p.drawWindowStart != 0 && block.timestamp < uint256(p.drawWindowStart) + DRAW_WINDOW_SECONDS;
    }

    /// @dev Charges an exercising exit's payment to the pool's draw window, opening a new window first when the last
    ///      one has lapsed. The room is read before the reserve changes, as `_inputs` read it.
    function _recordDraw(PoolRecord storage p, ErgTypes.ExitResult memory r) internal {
        if (r.paid0 == 0 && r.paid1 == 0) return;
        if (!_drawWindowOpen(p)) {
            uint256 f0 = ErgExitMath.kept(r.forfeited0 + r.protocol0, p.terms.protocolShareBps);
            uint256 f1 = ErgExitMath.kept(r.forfeited1 + r.protocol1, p.terms.protocolShareBps);
            p.drawWindowStart = uint40(block.timestamp);
            p.drawRoom0 = FullMath.mulDiv(p.reserve0 + f0, p.terms.maxDrawBps, BPS);
            p.drawRoom1 = FullMath.mulDiv(p.reserve1 + f1, p.terms.maxDrawBps, BPS);
        }
        p.drawRoom0 -= r.paid0;
        p.drawRoom1 -= r.paid1;
    }

    /// @dev An exit that asks for the entry ratio must see the market's price: the leg converts at the position's
    ///      own exit-time rate, so a price pushed in the exit's own transaction would set the rate the reserve is
    ///      charged. The spot must sit inside the pool's entry band around the reference, as at deposit.
    ///      The allowlist is not re-checked: delisting a reference closes it to new deposits, not to the exits of
    ///      positions that entered on it. A reference that refuses blocks exercise until it answers.
    function _checkExercisePrice(PoolRecord storage p) internal view {
        (uint160 spot,,,) = poolManager.getSlot0(p.key.toId());
        uint160 ref = _reference(p);
        if (!_inBand(spot, ref, p.terms.maxEntrySqrtDeviationPips)) {
            revert ExercisePriceOutOfBand(spot, ref, p.terms.maxEntrySqrtDeviationPips);
        }
    }

    function _split(int128 total, int128 fees) internal pure returns (uint256 principal, uint256 feesOut) {
        if (fees < 0 || total < fees) revert UnexpectedDelta();
        principal = uint256(int256(total) - int256(fees));
        feesOut = uint256(int256(fees));
    }

    /// @dev Zeroes the caller's claim before any external call; only the protocol recipient ever holds one.
    function _debit(Currency currency, address to) internal returns (uint256 amount) {
        if (to == address(0) || to == address(poolManager) || to == address(this)) revert InvalidRecipient();
        if (msg.sender != protocolRecipient) revert NothingToClaim();
        amount = _protocolClaims[currency];
        if (amount == 0) revert NothingToClaim();
        _protocolClaims[currency] = 0;
    }

    function _apply(uint256 reserve, int256 change) internal pure returns (uint256) {
        if (change >= 0) return reserve + uint256(change);
        // ErgExitMath caps every payment at the reserve plus what it keeps of the exit's own forfeits in the paid
        // currency (nothing is waived there), so this never underflows.
        return reserve - uint256(-change);
    }

    function _moveClaims(Currency currency, int256 change) internal {
        if (change > 0) poolManager.mint(address(this), currency.toId(), uint256(change));
        else if (change < 0) poolManager.burn(address(this), currency.toId(), uint256(-change));
    }

    function _referenceSlot(Currency currency0, Currency currency1, address priceReference)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(currency0, currency1, priceReference));
    }

    function _isAllowed(PoolRecord storage p) internal view returns (bool) {
        return _referenceAllowed[_referenceSlot(p.key.currency0, p.key.currency1, p.terms.priceReference)];
    }

    /// @dev The reference's declared tolerance; a reference that does not declare one cannot register a pool.
    function _declaredError(address priceReference) internal view returns (uint24 e) {
        try IErgPriceReference(priceReference).errorSqrtPips() returns (uint24 declared) {
            e = declared;
        } catch {
            revert InvalidTerms(0);
        }
    }

    function _reference(PoolRecord storage p) internal view returns (uint160 ref) {
        try IErgPriceReference(p.terms.priceReference).referenceSqrtPriceX96(p.key) returns (uint160 r) {
            ref = r;
        } catch {
            revert ReferenceUnavailable();
        }
        if (ref == 0) revert ReferenceUnavailable();
    }

    function _entryReference(PoolRecord storage p) internal view returns (uint160 entryRef) {
        try IErgPriceReference(p.terms.priceReference).entrySqrtPriceX96(p.key) returns (uint160 r) {
            entryRef = r;
        } catch {
            revert ReferenceUnavailable();
        }
        if (entryRef == 0) revert ReferenceUnavailable();
    }

    function _inBand(uint160 spot, uint160 ref, uint24 maxDeviationPips) internal pure returns (bool) {
        uint256 diff = spot > ref ? uint256(spot) - ref : uint256(ref) - spot;
        return diff * PIPS <= uint256(ref) * maxDeviationPips;
    }

    function _isDelegatedAccount(address account) internal view returns (bool) {
        if (account.code.length != 23) return false;
        return bytes3(account.code) == 0xef0100;
    }
}
