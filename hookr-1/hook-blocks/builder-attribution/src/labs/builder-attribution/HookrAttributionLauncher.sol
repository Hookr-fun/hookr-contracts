// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {HookrTypes} from "../../types/HookrTypes.sol";
import {IHookrRegistry} from "../../interfaces/IHookrRegistry.sol";
import {IHookrRoot} from "../../interfaces/IHookrRoot.sol";
import {IHookrRules} from "../../interfaces/IHookrRules.sol";
import {HookrTokenDeployer} from "../../libraries/HookrTokenDeployer.sol";
import {HookrSettlement} from "../../libraries/HookrSettlement.sol";
import {HookrSessionTiers} from "../../libraries/HookrSessionTiers.sol";
import {HookrAttributionTypes as T} from "./types/HookrAttributionTypes.sol";
import {IHookrPartnerRegistry} from "./interfaces/IHookrPartnerRegistry.sol";
import {HookrPartnerRevenueVault} from "./HookrPartnerRevenueVault.sol";
import {HookrDirectionalTax} from "./HookrDirectionalTax.sol";
import {IHookrRecaptureAccrual} from "./interfaces/IHookrRecaptureAccrual.sol";

/// @title Hookr attribution launcher
/// @notice A later launcher, admitted through `HookrRegistry` SET_LAUNCHER, that adds the voucher step at creation:
///         in one transaction it verifies a partner's one-time voucher (or a direct market), deploys the pool's
///         revenue vault, records the attribution, initializes the pool with the directional-tax advisory paying
///         that vault, and seeds the caller's liquidity.
/// @dev HookrLauncher's family launch keeps `_launch` private, so it cannot take this voucher step by inheritance;
///      this launcher is a minimal single-pool variant instead: one pool per launch, new or existing subject, native or ERC20 quote,
///      one launcher-held position owned by the caller. It keeps phase one's safety properties that matter here:
///      it is the Rules `liquidityOwner`, so during an Anti-Snipe guard no one else can add liquidity; the owner
///      cannot withdraw principal before the position's lock ends, which is the guard end unless the creator
///      chose a longer `lockBlocks` (fees stay collectable); exits are paid by the
///      PoolManager straight to the chosen recipient; every call returns this contract's balances to where they
///      started, so it never holds assets between calls. It omits phase one's family transfer, claim-form exits,
///      redeem and sweep.
///
///      Voucher binding. The voucher names this launcher, the root, the caller, the exact PoolId and the stack
///      hash, so a copied voucher cannot be used by another account, on another pool, with other Rules, or at
///      another opening price, range or size. A new
///      token's address is salted with the caller, so a front-runner cannot occupy its PoolKey. An existing
///      token opens here only with a partner's voucher (Hookr's house partner included): a direct market
///      (partnerId zero) must launch a new token, so no one can take an existing token's PoolKey through this
///      launcher and be paid its tax (closed). An existing token's PoolKey can
///      still be taken by anyone initializing it first elsewhere, such as through the phase-one launcher,
///      which earns the squatter nothing; the voucher then cannot be used.
///
///      Recapture. A launch with `recapture.on` binds the pool to the root's open recapture lane (its RecaptureConfig
///      is the third part of the Rules data, exactly as HookrLauncher sends it). This contract holds the launch
///      position, so it is the pool's liquidity owner in its Rules: the LP share the Rules cannot donate (no in-range
///      liquidity, or a currency other than the pool's two) accrues to it. The launcher never keeps that accrual:
///      the position owner moves it with `claimRecapture`, and every `withdraw` (a fee collection included) moves it
///      to that call's recipient, also after all of the position's liquidity is gone. The launcher reports no
///      `poolFamily`, so a recapture pool opened here has no lane siblings.
///
///      Quotes. Only assets in the root registry's timelocked quote catalog (`isQuote`; native ETH always is)
///      can be the quote, because the vault must be able to realize and pay out its claim exactly.
///
///      New tokens. A new token is created and predicted by the package's linked library HookrTokenDeployer, the one
///      HookrLauncher links, which this launcher runs by DELEGATECALL: CREATE2 runs from this launcher's address with
///      salt keccak256(abi.encode(caller, salt)) and this launcher is the token's first holder, so a token keeps the
///      address and the first holder it had when the launcher created it itself, and HookrToken's creation code sits
///      in the library, not in this runtime. Linked to the release's library, the launcher creates exactly the tokens
///      HookrLauncher creates, whose runtime the release Rules recognise as a Hookr token.
contract HookrAttributionLauncher is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    /// @notice Launch parameters for one pool.
    /// @dev `config.subject`, `quote`, `liquidityOwner`, `advisory`, `advisoryGasLimit`, `advisoryPhases` and
    ///      `advisoryFailOpen` are overwritten by the launcher. `config.caps.maxQuoteTakePips` must leave room for
    ///      the tax above the Rules admission cap, or the advisory refuses to bind. `tiers` is the pool's optional
    ///      off-market surcharge on top of the tax (all zero for none); the voucher's stack hash commits it.
    ///      `lockBlocks` is how many blocks from launch the owner's principal stays locked: zero locks it until
    ///      `rules.guardEndBlock` (no lock without a guard); otherwise the lock ends at `block.number + lockBlocks`,
    ///      which must be at or after the guard end and at most `MAX_LOCK_BLOCKS`. The stack hash commits it.
    ///      `recapture` turns the recapture lane on for the pool (zeroed, or `on` false, for none: RECAPTURE_OFF); the
    ///      launch reverts while the root has no open lane. The stack hash commits it.
    struct Launch {
        address existing;
        string name;
        string symbol;
        uint256 supply;
        bytes32 salt;
        Currency quote;
        int24 tickSpacing;
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 amount0Max;
        uint128 amount1Max;
        HookrTypes.PoolConfig config;
        HookrTypes.RulesConfig rules;
        uint256 deadline;
        HookrSessionTiers.Tiers tiers;
        uint32 lockBlocks;
        HookrTypes.RecaptureConfig recapture;
    }

    /// @notice The launcher-held position of one attributed pool.
    struct Position {
        PoolKey key;
        address owner;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint64 lockedUntil;
        bool recapture;
    }

    struct Request {
        PoolId id;
        int256 liquidityDelta;
        uint256 bound0;
        uint256 bound1;
        address to;
    }

    uint8 private constant IDLE = 1;
    uint8 private constant BUSY = 2;
    uint8 private constant EXPECT = 3;
    uint8 private constant IN_CALLBACK = 4;
    uint8 private constant DONE = 5;
    /// @dev HookrRules' own bound on guardEndBlock - block.number.
    uint256 private constant MAX_GUARD_BLOCKS = 100_000;
    /// @notice Creator knob `Launch.lockBlocks`: zero (the default) locks principal until the Anti-Snipe guard ends;
    ///         a nonzero value must reach the guard end and be at most MAX_LOCK_BLOCKS (365 days of 12-second blocks).
    uint256 public constant DEFAULT_LOCK_BLOCKS = 0;
    uint256 public constant MAX_LOCK_BLOCKS = 2_628_000;
    /// @dev Matches HookrLauncher.DYNAMIC_FEE_LIQUIDITY_DIVISOR: a dynamic fee pool's minimum dynamic fee liquidity
    ///      is its launch liquidity divided by this, at least 1 and at most 2^96 - 1.
    uint256 private constant DYNAMIC_FEE_LIQUIDITY_DIVISOR = 100;

    /// @notice The Uniswap v4 PoolManager.
    IPoolManager public immutable poolManager;
    /// @notice The Hookr admission registry that admits this launcher.
    IHookrRegistry public immutable registry;
    /// @notice The attribution registry that verifies vouchers.
    IHookrPartnerRegistry public immutable partnerRegistry;
    /// @notice The directional-tax advisory every pool binds.
    HookrDirectionalTax public immutable taxAdvisory;
    /// @notice The only root this launcher opens pools on (the advisory's root).
    address public immutable root;

    uint8 private _lock = IDLE;
    bytes32 private _pending;
    mapping(PoolId => Position) private _positions;

    error InvalidLaunch();
    error InvalidFunding();
    error QuoteNotInCatalog(address quote);
    error PoolExists(PoolId id);
    error VoucherMismatch();
    error PartnerNotActive(bytes32 partnerId);
    error GuardTooLong(uint256 guardEndBlock);
    error LockOutOfRange(uint256 lockBlocks);
    error NotOwner();
    error PrincipalLocked(PoolId id, uint256 untilBlock);
    error InvalidRecipient(address recipient);
    error InvalidCallback();
    error Reentered();
    error Slippage();

    event AttributedLaunch(
        PoolId indexed id,
        bytes32 indexed partnerId,
        address indexed caller,
        address subject,
        address quote,
        address vault,
        uint128 liquidity
    );
    event LiquidityRemoved(
        PoolId indexed id, address indexed recipient, uint128 liquidity, uint256 amount0, uint256 amount1
    );
    event LPFeesCollected(PoolId indexed id, address indexed recipient, uint256 amount0, uint256 amount1);

    modifier idle() {
        if (_lock != IDLE) revert Reentered();
        _lock = BUSY;
        _;
        _lock = IDLE;
    }

    /// @dev Refuses a PoolManager, registry, partner registry or linked HookrTokenDeployer without code, so the
    ///      launcher cannot be deployed before the library it creates tokens with.
    /// @param manager The Uniswap v4 PoolManager
    /// @param registry_ The Hookr registry the root reads `isLauncher` from
    /// @param partnerRegistry_ The attribution registry that binds this launcher once
    /// @param taxAdvisory_ The directional-tax advisory; its root is this launcher's root
    constructor(
        IPoolManager manager,
        IHookrRegistry registry_,
        IHookrPartnerRegistry partnerRegistry_,
        HookrDirectionalTax taxAdvisory_
    ) {
        address root_ = taxAdvisory_.root();
        if (
            address(manager).code.length == 0 || address(registry_).code.length == 0
                || address(partnerRegistry_).code.length == 0 || address(HookrTokenDeployer).code.length == 0
                || address(taxAdvisory_.partnerRegistry()) != address(partnerRegistry_)
                || address(IHookrRoot(root_).poolManager()) != address(manager)
                || address(IHookrRoot(root_).registry()) != address(registry_)
        ) revert InvalidLaunch();
        poolManager = manager;
        registry = registry_;
        partnerRegistry = partnerRegistry_;
        taxAdvisory = taxAdvisory_;
        root = root_;
    }

    /// @notice The launcher-held position of a pool opened here; zero fields otherwise.
    function position(PoolId id) external view returns (Position memory) {
        return _positions[id];
    }

    /// @notice The commitment a voucher's `stackHash` must equal: the Rules module and everything the pool freezes
    ///         about it (base fee, caps, Rules gas limit, policy id, the exact Rules config) plus the market the
    ///         partner endorses (opening price, range, seeded liquidity and funding ceilings), the pool's session
    ///         tiers and the principal lock. The PoolId in the voucher already fixes subject, quote, tick spacing
    ///         and root. It also commits the pool's recapture config.
    function stackHash(Launch calldata l) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(
                    abi.encode(
                        l.config.rules,
                        l.config.baseLpFeePips,
                        l.config.caps,
                        l.config.rulesGasLimit,
                        l.config.policyId,
                        l.rules,
                        l.sqrtPriceX96,
                        l.tickLower,
                        l.tickUpper,
                        l.liquidity,
                        l.amount0Max,
                        l.amount1Max
                    )
                ),
                l.tiers,
                l.lockBlocks,
                l.recapture
            )
        );
    }

    /// @notice The address a new token launched by `caller` with these parameters will have
    ///         (HookrTokenDeployer.predict for this launcher).
    function predictToken(address caller, string calldata name, string calldata symbol, uint256 supply, bytes32 salt)
        public
        view
        returns (address)
    {
        return HookrTokenDeployer.predict(address(this), caller, salt, name, symbol, supply);
    }

    /// @notice The PoolKey and PoolId `caller` would open with `l`, so a partner can sign over the exact PoolId.
    function predictPool(address caller, Launch calldata l) external view returns (PoolKey memory key, PoolId id) {
        address subject =
            l.existing != address(0) ? l.existing : predictToken(caller, l.name, l.symbol, l.supply, l.salt);
        key = _key(subject, l.quote, l.tickSpacing);
        id = key.toId();
    }

    /// @notice Verifies the voucher, deploys the vault, records the attribution, opens the taxed pool and seeds the
    ///         caller's liquidity, atomically. Unused funding is refunded to the caller.
    /// @param l Launch parameters
    /// @param v The partner's voucher, or, for a new token only, a direct-market voucher (partnerId zero) with an
    ///        empty signature. The partner registry and the vault refuse a share that does not match the partner.
    /// @param signature EIP-712 (EOA) or ERC-1271 signature of the partner's signer over `v`
    /// @return id The new pool
    /// @return subject The subject token
    /// @return vault The pool's revenue vault
    function launch(Launch calldata l, T.Voucher calldata v, bytes calldata signature)
        external
        payable
        idle
        returns (PoolId id, address subject, address vault)
    {
        if (
            block.timestamp > l.deadline || !registry.rootOpen(root) || l.liquidity == 0
                || l.liquidity > uint128(type(int128).max) || l.tickLower >= l.tickUpper
                || Currency.unwrap(l.quote) == address(this)
        ) revert InvalidLaunch();
        // The vault can only realize a quote that delivers exactly and cannot be frozen or double-addressed.
        if (!registry.isQuote(Currency.unwrap(l.quote))) revert QuoteNotInCatalog(Currency.unwrap(l.quote));
        if (l.rules.guardEndBlock > block.number + MAX_GUARD_BLOCKS) revert GuardTooLong(l.rules.guardEndBlock);
        if (
            l.lockBlocks != 0 && (l.lockBlocks > MAX_LOCK_BLOCKS || block.number + l.lockBlocks < l.rules.guardEndBlock)
        ) revert LockOutOfRange(l.lockBlocks);
        subject = _subject(l);
        if (Currency.unwrap(l.quote) == subject) revert InvalidLaunch();
        PoolKey memory key = _key(subject, l.quote, l.tickSpacing);
        id = key.toId();
        {
            (uint160 price,,,) = poolManager.getSlot0(id);
            if (price != 0 || IHookrRoot(root).knownPool(id)) revert PoolExists(id);
        }
        if (
            v.caller != msg.sender || v.root != root || v.launcher != address(this) || v.poolId != PoolId.unwrap(id)
                || v.stackHash != stackHash(l) || v.creatorBeneficiary == address(0)
                || (v.partnerId == bytes32(0) && l.existing != address(0))
        ) revert VoucherMismatch();
        vault = _deployVault(id, l, v);
        partnerRegistry.consume(v, signature, msg.sender, vault);
        _open(key, l, subject, v, vault);
        _fundAndSeed(id, key, l, subject);
        emit AttributedLaunch(id, v.partnerId, msg.sender, subject, Currency.unwrap(l.quote), vault, l.liquidity);
    }

    /// @notice Removes liquidity, or collects fees with zero. Only the position owner. The PoolManager pays
    ///         `recipient` directly. Principal cannot leave before the position's lock ends (`lockedUntil`). On a
    ///         recapture pool the Rules' liquidity owner accrual, in every currency, goes with the fees into
    ///         `recipient`'s claims there; such a position stays collectable after all of its liquidity is gone: a
    ///         zero withdraw on the empty position calls no PoolManager and moves only the accrual.
    function withdraw(PoolId id, uint128 liquidity, uint256 min0, uint256 min1, address recipient, uint256 deadline)
        external
        idle
        returns (uint256 amount0, uint256 amount1)
    {
        Position storage p = _positions[id];
        if (p.owner != msg.sender || msg.sender == address(0)) revert NotOwner();
        if (recipient == address(0)) revert InvalidRecipient(recipient);
        _payee(recipient);
        if (block.timestamp > deadline || liquidity > p.liquidity) revert InvalidLaunch();
        if (liquidity != 0 && block.number < p.lockedUntil) revert PrincipalLocked(id, p.lockedUntil);
        if (p.liquidity != 0) {
            p.liquidity -= liquidity;
            uint256 before0 = HookrSettlement.balance(p.key.currency0, address(this));
            uint256 before1 = HookrSettlement.balance(p.key.currency1, address(this));
            (amount0, amount1) = _execute(Request(id, -int256(uint256(liquidity)), min0, min1, recipient));
            if (
                HookrSettlement.balance(p.key.currency0, address(this)) != before0
                    || HookrSettlement.balance(p.key.currency1, address(this)) != before1
            ) revert InvalidFunding();
        } else if (!p.recapture || (min0 | min1) != 0) {
            // An empty position pays nothing and calls no PoolManager, so only a recapture pool's accrual can move.
            revert InvalidLaunch();
        }
        if (p.recapture) _claimRecapture(id, recipient);
        if (liquidity != 0) emit LiquidityRemoved(id, recipient, liquidity, amount0, amount1);
    }

    /// @notice Moves a recapture pool's liquidity owner accrual in its Rules, in every currency, into `to`'s claims
    ///         there, payable with the Rules' `claim`, `claimTo` or `claimAsClaims`. Only the position owner; returns
    ///         how many currencies moved (zero when nothing did, as always on a pool without recapture). `to` may not
    ///         be this launcher or the PoolManager, which can never realize a Rules claim.
    function claimRecapture(PoolId id, address to) external idle returns (uint256 moved) {
        Position storage p = _positions[id];
        if (p.owner != msg.sender || msg.sender == address(0)) revert NotOwner();
        _payee(to);
        return _claimRecapture(id, to);
    }

    /// @notice Runs only the pending position change.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || _lock != EXPECT || keccak256(data) != _pending) {
            revert InvalidCallback();
        }
        _lock = IN_CALLBACK;
        delete _pending;
        Request memory r = abi.decode(data, (Request));
        (uint256 amount0, uint256 amount1) = _modify(r);
        _lock = DONE;
        return abi.encode(amount0, amount1);
    }

    /// @dev Refuses a payee that would strand what it is paid: this launcher and the PoolManager never call the Rules'
    ///      claim. The pool's vault realizes only its quote claim and is not refused here, for lack of bytecode room:
    ///      a position owner must not name it.
    function _payee(address to) private view {
        if (to == address(this) || to == address(poolManager)) revert InvalidRecipient(to);
    }

    /// @dev The Rules emit PoolClaimed for every currency moved.
    function _claimRecapture(PoolId id, address to) private returns (uint256) {
        return IHookrRecaptureAccrual(IHookrRoot(root).poolConfig(id).rules).claimPool(id, to);
    }

    function _subject(Launch calldata l) private returns (address subject) {
        if (l.existing == address(0)) {
            if (l.supply == 0) revert InvalidFunding();
            subject = HookrTokenDeployer.deploy(msg.sender, l.salt, l.name, l.symbol, l.supply);
        } else {
            if (l.supply != 0 || l.salt != bytes32(0) || l.existing.code.length == 0) revert InvalidFunding();
            subject = l.existing;
        }
    }

    /// @dev The registry re-checks everything in `consume`; the partner pre-check here only gives an unknown or
    ///      retired partner a clear error instead of the vault constructor's `InvalidTerms`.
    function _deployVault(PoolId id, Launch calldata l, T.Voucher calldata v) private returns (address) {
        address partnerBeneficiary;
        if (v.partnerId != bytes32(0)) {
            T.Partner memory p = partnerRegistry.partner(v.partnerId);
            if (!p.active) revert PartnerNotActive(v.partnerId);
            partnerBeneficiary = p.beneficiary;
        }
        return address(
            new HookrPartnerRevenueVault{salt: PoolId.unwrap(id)}(
                HookrPartnerRevenueVault.Terms({
                    poolId: PoolId.unwrap(id),
                    root: root,
                    rules: IHookrRules(l.config.rules),
                    quote: l.quote,
                    partnerId: v.partnerId,
                    partnerShareBps: v.partnerShareBps,
                    creatorBeneficiary: v.creatorBeneficiary,
                    partnerBeneficiary: partnerBeneficiary,
                    treasuryBeneficiary: partnerRegistry.treasuryBeneficiary(),
                    buyBurnBeneficiary: partnerRegistry.buyBurnBeneficiary()
                })
            )
        );
    }

    function _open(PoolKey memory key, Launch calldata l, address subject, T.Voucher calldata v, address vault)
        private
    {
        HookrTypes.PoolConfig memory c = l.config;
        c.subject = Currency.wrap(subject);
        c.quote = l.quote;
        c.liquidityOwner = address(this);
        c.advisory = address(taxAdvisory);
        c.advisoryGasLimit = registry.admission(root, address(taxAdvisory)).gasLimit;
        c.advisoryPhases = HookrTypes.BEFORE_SWAP;
        c.advisoryFailOpen = false;
        T.TaxConfig memory t = T.TaxConfig(v.buyTaxPips, v.sellTaxPips, vault);
        HookrSessionTiers.Tiers memory tiers = l.tiers;
        IHookrRoot(root)
            .initializePool(
                key,
                c,
                _rulesData(l),
                HookrSessionTiers.isEmpty(tiers) ? abi.encode(t) : abi.encode(t, tiers),
                l.sqrtPriceX96
            );
        uint256 lockedUntil = l.lockBlocks == 0 ? l.rules.guardEndBlock : block.number + l.lockBlocks;
        // Fits: at most a uint40 guard end or block.number + MAX_LOCK_BLOCKS.
        // forge-lint: disable-next-line(unsafe-typecast)
        _positions[key.toId()] =
            Position(key, msg.sender, l.tickLower, l.tickUpper, 0, uint64(lockedUntil), l.recapture.on);
    }

    /// @dev The pool's Rules bind data exactly as HookrLauncher._rulesData computes it for a launch without
    ///      launchFamily's member knobs: the config alone; for a dynamic fee pool (dynamicFeeSens != 0) the config and
    ///      its HookrTypes.RulesKnobs; for a recapture pool the config, its RulesKnobs and its RecaptureConfig. The knobs
    ///      are zero, their defaults, except a dynamic fee pool's minimum dynamic fee liquidity (its launch liquidity
    ///      divided by DYNAMIC_FEE_LIQUIDITY_DIVISOR, at least 1 and at most 2^96 - 1) and its tempo knobs, which take
    ///      the default tempo. The voucher's stack hash commits every input of these knobs.
    function _rulesData(Launch calldata l) private pure returns (bytes memory) {
        HookrTypes.RulesKnobs memory k;
        if (l.rules.dynamicFeeSens != 0) {
            uint256 minimum = uint256(l.liquidity) / DYNAMIC_FEE_LIQUIDITY_DIVISOR;
            if (minimum == 0) minimum = 1;
            if (minimum > type(uint96).max) minimum = type(uint96).max;
            // Fits: clamped to 2^96 - 1 just above.
            // forge-lint: disable-next-line(unsafe-typecast)
            k.minDynamicFeeLiquidity = uint96(minimum);
            k.windowSeconds = HookrTypes.DEFAULT_WINDOW_SECONDS;
            k.resetSeconds = HookrTypes.DEFAULT_RESET_SECONDS;
            k.carryBps = HookrTypes.DEFAULT_CARRY_BPS;
            k.moveTicks = HookrTypes.DEFAULT_MOVE_TICKS;
        }
        if (l.recapture.on) return abi.encode(l.rules, k, l.recapture);
        if (l.rules.dynamicFeeSens == 0) return abi.encode(l.rules);
        return abi.encode(l.rules, k);
    }

    /// @dev Pulls exact funding, seeds the position and refunds the rest. For a new token the whole supply was
    ///      minted here and everything the position did not use goes to the caller.
    function _fundAndSeed(PoolId id, PoolKey memory key, Launch calldata l, address subject) private {
        bool subjectFirst = Currency.unwrap(key.currency0) == subject;
        uint256 subjectBudget = subjectFirst ? l.amount0Max : l.amount1Max;
        uint256 quoteBudget = subjectFirst ? l.amount1Max : l.amount0Max;
        Currency s = Currency.wrap(subject);
        bool native = Currency.unwrap(l.quote) == address(0);
        uint256 subjectBefore;
        uint256 quoteBefore = HookrSettlement.balance(l.quote, address(this)) - (native ? msg.value : 0);
        if (l.existing == address(0)) {
            if (subjectBudget > l.supply) revert InvalidFunding();
        } else {
            subjectBefore = HookrSettlement.balance(s, address(this));
            _pull(s, subjectBudget);
        }
        if (native) {
            if (msg.value != quoteBudget) revert InvalidFunding();
        } else {
            if (msg.value != 0) revert InvalidFunding();
            _pull(l.quote, quoteBudget);
        }
        (uint256 paid0, uint256 paid1) =
            _execute(Request(id, int256(uint256(l.liquidity)), l.amount0Max, l.amount1Max, msg.sender));
        _positions[id].liquidity = l.liquidity;
        uint256 subjectPaid = subjectFirst ? paid0 : paid1;
        uint256 quotePaid = subjectFirst ? paid1 : paid0;
        uint256 subjectSupplied = l.existing == address(0) ? l.supply : subjectBudget;
        HookrSettlement.send(s, msg.sender, subjectSupplied - subjectPaid);
        HookrSettlement.send(l.quote, msg.sender, quoteBudget - quotePaid);
        if (
            HookrSettlement.balance(s, address(this)) != subjectBefore
                || HookrSettlement.balance(l.quote, address(this)) != quoteBefore
        ) revert InvalidFunding();
    }

    function _pull(Currency currency, uint256 amount) private {
        if (amount == 0) return;
        uint256 ours = HookrSettlement.balance(currency, address(this));
        uint256 theirs = HookrSettlement.balance(currency, msg.sender);
        IERC20(Currency.unwrap(currency)).safeTransferFrom(msg.sender, address(this), amount);
        if (
            HookrSettlement.balance(currency, address(this)) != ours + amount
                || HookrSettlement.balance(currency, msg.sender) != theirs - amount
        ) revert InvalidFunding();
    }

    function _execute(Request memory r) private returns (uint256 amount0, uint256 amount1) {
        bytes memory data = abi.encode(r);
        _pending = keccak256(data);
        _lock = EXPECT;
        (amount0, amount1) = abi.decode(poolManager.unlock(data), (uint256, uint256));
        if (_lock != DONE) revert InvalidCallback();
        _lock = BUSY;
    }

    function _modify(Request memory r) private returns (uint256 amount0, uint256 amount1) {
        Position storage p = _positions[r.id];
        (BalanceDelta delta, BalanceDelta fees) = poolManager.modifyLiquidity(
            p.key, ModifyLiquidityParams(p.tickLower, p.tickUpper, r.liquidityDelta, PoolId.unwrap(r.id)), ""
        );
        if (fees.amount0() < 0 || fees.amount1() < 0) revert InvalidFunding();
        if (fees.amount0() != 0 || fees.amount1() != 0) {
            emit LPFeesCollected(r.id, r.to, uint256(int256(fees.amount0())), uint256(int256(fees.amount1())));
        }
        if (r.liquidityDelta > 0) {
            if (delta.amount0() > 0 || delta.amount1() > 0) revert InvalidFunding();
            amount0 = uint256(-int256(delta.amount0()));
            amount1 = uint256(-int256(delta.amount1()));
            if ((amount0 == 0 && amount1 == 0) || amount0 > r.bound0 || amount1 > r.bound1) revert Slippage();
            HookrSettlement.pay(poolManager, p.key.currency0, address(this), amount0);
            HookrSettlement.pay(poolManager, p.key.currency1, address(this), amount1);
        } else {
            if (delta.amount0() < 0 || delta.amount1() < 0) revert InvalidFunding();
            amount0 = uint256(int256(delta.amount0()));
            amount1 = uint256(int256(delta.amount1()));
            if (amount0 < r.bound0 || amount1 < r.bound1) revert Slippage();
            HookrSettlement.takeTo(poolManager, p.key.currency0, r.to, amount0);
            HookrSettlement.takeTo(poolManager, p.key.currency1, r.to, amount1);
        }
    }

    function _key(address subject, Currency quote, int24 tickSpacing) private view returns (PoolKey memory) {
        bool subjectFirst = uint160(subject) < uint160(Currency.unwrap(quote));
        return PoolKey(
            subjectFirst ? Currency.wrap(subject) : quote,
            subjectFirst ? quote : Currency.wrap(subject),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing,
            IHooks(root)
        );
    }
}
