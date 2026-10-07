// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {IHookrRegistry} from "hookr/interfaces/IHookrRegistry.sol";
import {HookrReleased} from "hookr/base/HookrReleased.sol";
import {HookrTokenDeployer} from "hookr/libraries/HookrTokenDeployer.sol";
import {HookrSettlement} from "hookr/libraries/HookrSettlement.sol";
import {IHookrLaunchAdapter} from "./interfaces/IHookrLaunchAdapter.sol";
import {
    ExternalHookRecord,
    ExternalHookTypes,
    AdapterAdmission,
    IHookrExternalHookBook,
    IHookrLaunchAdapterBound,
    IHookrSeedHost,
    IHookrShareEscrow
} from "./interfaces/IHookrExternalHooks.sol";
import {IHookrRegistryPause} from "./interfaces/IHookrRegistryPause.sol";

/// @title HookrExternalLauncher
/// @notice The external-hook launcher beside the Hookr 1 `HookrLauncher`: opens one pool on a hook Hookr did not
///         write, through that hook's admitted `IHookrLaunchAdapter`, in one transaction that reverts as a unit, and
///         records it for discovery.
/// @dev The launch runs, in order: the six record checks (LAUNCHABLE; live code hash;
///      not UPGRADEABLE; adapter admitted for the record's protocol, unchanged, bound to this launcher; the owner of
///      record where OWNER_INIT is set; the intent against the capability bits, including IGNORES_HOOKDATA because
///      every call this contract makes passes empty hookData), the quote-catalog check against the
///      Hookr registry, exact funding, `prepare` (a STATICCALL) with the returned key checked field by field
///      against the intent, a refusal if the key is already initialized, `initialize` with the opening price read
///      back from the PoolManager, `seed` by the path the record names, an optional initial buy from the creator's
///      own quote on the fresh pool, exact refunds, and the check that neither this contract nor the adapter kept
///      anything. The swap path never touches this contract, the book or the adapter: an external pool runs only its
///      own hook, and no Hookr rule, share, cashback or recapture applies to it.
///      Custody after launch: a founding v4 position is owned by this contract (salt = launch id) and managed for
///      the launch owner: anyone may pay its fees to the recorded fee recipient, the owner may withdraw principal
///      after the creator-chosen lock. Escrowed hook-internal shares sit in the adapter's ledger under this
///      launcher and leave only through `withdraw`. This contract holds no asset between calls; `sweep` hands any
///      stray balance to whoever asks, as `HookrLauncher` does.
///      Protocol share: every fee a founding position pays out (by `collectFees` or inside `withdraw`) is split, and
///      `protocolShareBps` of it (rounded up, so never below the rate) is owed to `protocolRecipient`. The rate is
///      fixed for this deployment within [`MIN_PROTOCOL_SHARE_BPS`, `MAX_PROTOCOL_SHARE_BPS`] (the Hookr 1 release
///      floor and `HookrRules`' ceiling) and frozen into each launch's record. The owed share waits here as a claim per
///      currency and leaves only to the recipient through `payProtocol`, so a recipient that cannot take an asset
///      never blocks a creator's fees or principal. Escrowed shares carry their fees inside and pay no share.
///      New tokens: a `HookrToken` is created, and its address predicted, by the package's linked library
///      `HookrTokenDeployer`, run by DELEGATECALL as `HookrLauncher` runs it: CREATE2 from this contract at salt
///      keccak256(abi.encode(creator, salt)), this contract the first holder, so `HookrToken`'s creation code is not
///      in this contract's runtime. The library is deployed and linked before this contract, which refuses one
///      without code.
///      Clock: `lockBlocks` is a relative window on `block.number`. On Robinhood Chain that is the parent-chain
///      height (about 12 s per block); on an anvil fork it is the L2 height. Only the difference is used.
contract HookrExternalLauncher is HookrReleased, IUnlockCallback, IHookrSeedHost {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    /// @notice A new fixed-supply token, or an existing token when `existing` is non-zero (then the rest is empty)
    struct Token {
        address existing;
        string name;
        string symbol;
        uint256 supply;
        bytes32 salt;
    }

    /// @notice The creator's launch parameters
    /// @param quote The quote currency; native ETH is address zero
    /// @param fee The LP fee in pips as the key will carry it. A static fee is at most `MAX_FEE_PIPS`; the SDK
    ///        default is `DEFAULT_FEE_PIPS`. The dynamic-fee flag passes only for a hook whose record omits
    ///        `STATIC_FEE_ONLY`, and that hook then sets every swap's fee itself.
    /// @param tickSpacing The tick spacing
    /// @param sqrtPriceX96 The opening price
    /// @param subjectAmount The subject funded for seeding
    /// @param quoteAmount The quote funded for seeding (zero for a token-only band)
    /// @param feeRecipient Who collects the founding position's fees
    /// @param lockBlocks Principal lock, in blocks from launch, at most `MAX_LOCK_BLOCKS`
    /// @param buyQuoteAmount The creator's optional initial buy, exact quote in; zero skips it
    /// @param minBuySubjectOut The minimum subject the initial buy must return to the creator
    /// @param protocolData Opaque bytes for the adapter
    struct Params {
        Currency quote;
        uint24 fee;
        int24 tickSpacing;
        uint160 sqrtPriceX96;
        uint256 subjectAmount;
        uint256 quoteAmount;
        address feeRecipient;
        uint32 lockBlocks;
        uint256 buyQuoteAmount;
        uint256 minBuySubjectOut;
        bytes protocolData;
    }

    /// @notice What the launcher records for each launch
    struct Launch {
        address owner;
        address pendingOwner;
        address hook;
        address adapter;
        address subject;
        address feeRecipient;
        bytes32 initProtocolId;
        PoolKey key;
        uint8 kind;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 shares;
        uint64 lockedUntil;
        uint16 protocolShareBps;
    }

    /// @dev Working state of one launch, kept in memory to stay clear of the stack limit
    struct Ctx {
        bytes32 launchId;
        address subject;
        bool isNew;
        uint256 supply;
        Currency subjectC;
        Currency quoteC;
        uint256 subjectBase;
        uint256 quoteBase;
        uint256 adapterSubjectBefore;
        uint256 adapterQuoteBefore;
        uint256 subjectUsed;
        uint256 quoteUsed;
        uint256 buyPaid;
        uint256 buyOut;
        bytes32 receipt;
    }

    uint8 public constant POSITION = 1;
    uint8 public constant SHARES = 2;
    /// @notice The shortest principal lock a creator can choose: none
    uint32 public constant MIN_LOCK_BLOCKS = 0;
    /// @notice The longest principal lock a creator can choose: 365 days of 12-second parent blocks, the Hookr 1
    ///         launcher's dev-buy ceiling
    uint32 public constant MAX_LOCK_BLOCKS = 2_628_000;
    /// @notice The principal lock the SDK proposes when the creator sets none: none, as the Hookr 1 launcher's dev
    ///         buy. The app shows an unlocked founding position as unlocked.
    uint32 public constant DEFAULT_LOCK_BLOCKS = 0;
    /// @notice The lowest static LP fee a creator can choose, in pips
    uint24 public constant MIN_FEE_PIPS = 0;
    /// @notice The highest static LP fee a creator can choose, in pips: 100,000 pips is 10%
    uint24 public constant MAX_FEE_PIPS = 100_000;
    /// @notice The static LP fee the SDK proposes when the creator sets none, in pips: 3,000 pips is 0.3%
    uint24 public constant DEFAULT_FEE_PIPS = 3_000;
    /// @notice The finest tick spacing a creator can choose: v4's own floor
    int24 public constant MIN_TICK_SPACING = 1;
    /// @notice The coarsest tick spacing a creator can choose: v4's own ceiling
    int24 public constant MAX_TICK_SPACING = 32_767;
    /// @notice The tick spacing the SDK proposes when the creator sets none
    int24 public constant DEFAULT_TICK_SPACING = 60;
    /// @notice The lowest protocol share of a founding position's fees: the Hookr 1 release floor, 20%
    uint16 public constant MIN_PROTOCOL_SHARE_BPS = 2_000;
    /// @notice The highest protocol share of a founding position's fees: `HookrRules`' ceiling, 50%
    uint16 public constant MAX_PROTOCOL_SHARE_BPS = 5_000;
    /// @notice The protocol share the release proposes: the floor
    uint16 public constant DEFAULT_PROTOCOL_SHARE_BPS = 2_000;

    uint8 private constant IDLE = 1;
    uint8 private constant BUSY = 2;
    uint8 private constant SEEDING = 3;
    uint8 private constant EXPECT_CALLBACK = 4;
    uint8 private constant IN_CALLBACK = 5;
    uint8 private constant DONE = 6;

    uint8 private constant ACTION_ADD = 1;
    uint8 private constant ACTION_BUY = 2;
    uint8 private constant ACTION_REMOVE = 3;

    IPoolManager public immutable poolManager;
    /// @notice The Hookr registry: quote catalog and global brake
    IHookrRegistry public immutable hookrRegistry;
    /// @notice The external-hook launch records
    IHookrExternalHookBook public immutable book;
    /// @notice Who the protocol share is paid to
    address public immutable protocolRecipient;
    /// @notice This deployment's protocol share of a founding position's fees, in bps
    uint16 public immutable protocolShareBps;

    uint8 private _lock;
    bytes32 private _pending;
    uint256 public nonce;
    mapping(bytes32 launchId => Launch) private _launches;
    mapping(PoolId id => bytes32) public poolLaunch;
    /// @notice The protocol share accrued and not yet paid, per currency
    mapping(Currency currency => uint256) public protocolOwed;

    // The launch whose `seed` step is running. Transient: empty outside that call, empty again at transaction end.
    bytes32 private transient _tLaunchId;
    address private transient _tAdapter;
    bool private transient _tSeeded;
    uint256 private transient _tSubjectBudget;
    uint256 private transient _tQuoteBudget;
    uint256 private transient _tSubjectUsed;
    uint256 private transient _tQuoteUsed;

    error Reentered();
    error Expired();
    error LaunchesPaused();
    /// @param status The record's listing status
    error NotLaunchable(address hook, uint8 status);
    error HookCodeChanged(address hook);
    error HookUpgradeable(address hook);
    error AdapterNotAdmitted(address adapter);
    error OwnerOfRecordMismatch(address hook, address ownerOfRecord);
    /// @param reason A short code naming the capability or catalog rule the intent breaks
    error IntentRefused(bytes32 reason);
    error InvalidToken();
    error InvalidFunding();
    /// @param field The key field that differs from the intent
    error KeyMismatch(bytes32 field);
    error PoolExists(PoolId id);
    error InitializeMismatch();
    error SeedMismatch(bytes32 field);
    error AdapterKeptFunds(address adapter);
    error NotSeeding();
    error Slippage();
    error NotOwner();
    error NotPendingOwner();
    error UnknownLaunch();
    error PrincipalLocked(uint256 untilBlock);
    error InvalidRecipient(address recipient);
    error InvalidAmount();
    error NotApplicable();
    error InvalidCallback();
    error InvalidProtocolShare(uint16 bps);

    event ExternalLaunched(
        bytes32 indexed launchId,
        address indexed owner,
        address indexed hook,
        PoolId poolId,
        address subject,
        address quote,
        address adapter,
        bytes32 initProtocolId,
        uint8 kind,
        bytes32 receipt
    );
    /// @notice The discovery row: the full key of a pool opened on an external hook
    event ExternalPoolListed(PoolId indexed poolId, bytes32 indexed launchId, PoolKey key);
    event InitialBuy(bytes32 indexed launchId, address indexed buyer, uint256 quoteIn, uint256 subjectOut);
    event FeesCollected(bytes32 indexed launchId, address indexed recipient, uint256 amount0, uint256 amount1);
    event PrincipalWithdrawn(
        bytes32 indexed launchId, address indexed recipient, uint256 amount, uint256 amount0, uint256 amount1
    );
    event FeeRecipientSet(bytes32 indexed launchId, address indexed recipient);
    event LaunchTransferStarted(bytes32 indexed launchId, address indexed owner, address indexed pendingOwner);
    event LaunchTransferred(bytes32 indexed launchId, address indexed owner);
    /// @notice The protocol share of a collection, owed to `protocolRecipient`
    event ProtocolShareAccrued(bytes32 indexed launchId, uint256 amount0, uint256 amount1);
    event ProtocolPaid(Currency indexed currency, address indexed recipient, uint256 amount);
    event Swept(Currency indexed currency, address indexed to, uint256 amount);

    modifier idle() {
        if (_lock != IDLE) revert Reentered();
        _lock = BUSY;
        _;
        _lock = IDLE;
    }

    /// @param manager The Uniswap v4 PoolManager
    /// @param registry The Hookr registry
    /// @param _book The external-hook records
    /// @param _protocolRecipient Who the protocol share is paid to
    /// @param _protocolShareBps The protocol share of a founding position's fees, within the floor and the ceiling
    constructor(
        IPoolManager manager,
        IHookrRegistry registry,
        IHookrExternalHookBook _book,
        address _protocolRecipient,
        uint16 _protocolShareBps
    ) {
        if (
            address(manager).code.length == 0 || address(registry).code.length == 0 || address(_book).code.length == 0
                || address(HookrTokenDeployer).code.length == 0
        ) {
            revert InvalidFunding();
        }
        if (_protocolRecipient == address(0) || _protocolRecipient == address(manager)) {
            revert InvalidRecipient(_protocolRecipient);
        }
        if (_protocolShareBps < MIN_PROTOCOL_SHARE_BPS || _protocolShareBps > MAX_PROTOCOL_SHARE_BPS) {
            revert InvalidProtocolShare(_protocolShareBps);
        }
        poolManager = manager;
        hookrRegistry = registry;
        book = _book;
        protocolRecipient = _protocolRecipient;
        protocolShareBps = _protocolShareBps;
        _lock = IDLE;
    }

    /// @notice The record of a launch; an unknown id returns zero fields
    function launchOf(bytes32 launchId) external view returns (Launch memory) {
        return _launches[launchId];
    }

    /// @notice The key an adapter would open for `hook` and `intent`, through the same checks as a launch
    /// @dev Lets the app preview the key while every adapter step stays launcher-only.
    function previewKey(address hook, IHookrLaunchAdapter.LaunchIntent calldata intent)
        external
        view
        returns (PoolKey memory key, bool available)
    {
        ExternalHookRecord memory r = _admitted(hook);
        key = IHookrLaunchAdapter(r.launchAdapter).prepare(hook, intent);
        (uint160 price,,,) = poolManager.getSlot0(key.toId());
        available = price == 0;
    }

    /// @notice Stable address of a new token launched by `creator`; other creators cannot consume the salt
    function predictToken(address creator, Token calldata token) external view returns (address) {
        return HookrTokenDeployer.predict(address(this), creator, token.salt, token.name, token.symbol, token.supply);
    }

    /// @notice Opens one pool on an admitted external hook, seeds it, optionally buys, and records it
    /// @dev Any failure reverts everything: no pool, no token, no transfer survives a failed step.
    /// @param token A new token, or the existing subject
    /// @param hook The external hook; zero for a hookless pool
    /// @param p The launch parameters
    /// @param deadline The last timestamp the launch may execute at
    /// @return launchId The launch's id
    /// @return subject The subject token
    /// @return id The pool id
    function launchExternal(Token calldata token, address hook, Params calldata p, uint256 deadline)
        external
        payable
        idle
        returns (bytes32 launchId, address subject, PoolId id)
    {
        if (block.timestamp > deadline) revert Expired();
        if (book.launchesPaused() || IHookrRegistryPause(address(hookrRegistry)).newMarketsPaused()) {
            revert LaunchesPaused();
        }
        ExternalHookRecord memory r = _admitted(hook);
        Ctx memory c;
        c.quoteC = p.quote;
        c.quoteBase = HookrSettlement.balance(p.quote, address(this)) - (p.quote.isAddressZero() ? msg.value : 0);
        _subject(c, token);
        uint8 kind = _checkIntent(r, c, p);
        c.launchId = keccak256(abi.encode(block.chainid, address(this), msg.sender, ++nonce));
        launchId = c.launchId;
        subject = c.subject;
        _fund(c, p);

        IHookrLaunchAdapter adapter = IHookrLaunchAdapter(r.launchAdapter);
        IHookrLaunchAdapter.LaunchIntent memory intent = IHookrLaunchAdapter.LaunchIntent({
            subject: c.subjectC,
            quote: c.quoteC,
            fee: p.fee,
            tickSpacing: p.tickSpacing,
            sqrtPriceX96: p.sqrtPriceX96,
            subjectAmount: p.subjectAmount,
            quoteAmount: p.quoteAmount,
            feeRecipient: p.feeRecipient,
            protocolData: p.protocolData
        });
        PoolKey memory key = adapter.prepare(hook, intent);
        _checkKey(key, c, p, hook);
        id = key.toId();
        {
            (uint160 existing,,,) = poolManager.getSlot0(id);
            if (existing != 0) revert PoolExists(id);
        }
        c.adapterSubjectBefore = HookrSettlement.balance(c.subjectC, address(adapter));
        c.adapterQuoteBefore = HookrSettlement.balance(c.quoteC, address(adapter));

        Launch storage l = _launches[launchId];
        l.owner = msg.sender;
        l.hook = hook;
        l.adapter = address(adapter);
        l.subject = c.subject;
        l.feeRecipient = p.feeRecipient;
        l.initProtocolId = r.initProtocolId;
        l.key = key;
        l.kind = kind;
        l.lockedUntil = uint64(block.number + p.lockBlocks);
        l.protocolShareBps = protocolShareBps;
        poolLaunch[id] = launchId;

        // Step 2: initialize, and read the opening price back.
        if (PoolId.unwrap(adapter.initialize(key, intent)) != PoolId.unwrap(id)) revert InitializeMismatch();
        {
            (uint160 opened,,,) = poolManager.getSlot0(id);
            if (opened != p.sqrtPriceX96) revert InitializeMismatch();
        }
        // Step 3: seed by the record's path.
        if (kind == POSITION) _seedPosition(c, l, adapter, key, intent);
        else _seedShares(c, l, adapter, key, intent, id);
        if (
            HookrSettlement.balance(c.subjectC, address(adapter)) != c.adapterSubjectBefore
                || HookrSettlement.balance(c.quoteC, address(adapter)) != c.adapterQuoteBefore
        ) revert AdapterKeptFunds(address(adapter));
        // Optional initial buy on the fresh pool: the creator's price is the launch price.
        if (p.buyQuoteAmount != 0) _initialBuy(c, p);
        _refund(c, p);

        emit ExternalLaunched(
            launchId,
            msg.sender,
            hook,
            id,
            c.subject,
            Currency.unwrap(c.quoteC),
            address(adapter),
            r.initProtocolId,
            kind,
            c.receipt
        );
        emit ExternalPoolListed(id, launchId, key);
    }

    /// @inheritdoc IHookrSeedHost
    function seedPosition(int24 tickLower, int24 tickUpper, uint128 liquidity)
        external
        returns (uint256 subjectUsed, uint256 quoteUsed, bytes32 positionId)
    {
        if (_lock != SEEDING || msg.sender != _tAdapter || _tSeeded) revert NotSeeding();
        if (liquidity == 0 || liquidity > uint128(type(int128).max)) revert InvalidAmount();
        _tSeeded = true;
        bytes32 launchId = _tLaunchId;
        Launch storage l = _launches[launchId];
        l.tickLower = tickLower;
        l.tickUpper = tickUpper;
        l.liquidity = liquidity;
        (uint256 amount0, uint256 amount1) = abi.decode(
            _unlock(abi.encode(ACTION_ADD, launchId, int256(uint256(liquidity)), address(0)), SEEDING),
            (uint256, uint256)
        );
        bool subjectFirst = Currency.unwrap(l.key.currency0) == l.subject;
        subjectUsed = subjectFirst ? amount0 : amount1;
        quoteUsed = subjectFirst ? amount1 : amount0;
        if (subjectUsed > _tSubjectBudget || quoteUsed > _tQuoteBudget) revert SeedMismatch("BUDGET");
        _tSubjectUsed = subjectUsed;
        _tQuoteUsed = quoteUsed;
        positionId = Position.calculatePositionKey(address(this), tickLower, tickUpper, launchId);
    }

    /// @notice Pays a founding position's accrued fees to the launch's fee recipient, less the protocol share, which
    ///         is owed to `protocolRecipient`. Callable by anyone. Returns what the fee recipient received.
    /// @dev After a full exit there is no position left and nothing to pay (the exit paid the fees), so it returns
    ///      zeros instead of reverting inside the PoolManager; a keeper can sweep every launch without a filter.
    function collectFees(bytes32 launchId) external idle returns (uint256 amount0, uint256 amount1) {
        Launch storage l = _launches[launchId];
        if (l.owner == address(0)) revert UnknownLaunch();
        if (l.kind != POSITION) revert NotApplicable();
        if (l.liquidity == 0) return (0, 0);
        (amount0, amount1,,) = _remove(launchId, 0, address(0), l.feeRecipient);
    }

    /// @notice Withdraws principal after the lock: liquidity of a founding position, or escrowed shares
    /// @dev A position's accrued fees go to the fee recipient in the same call; shares carry their fees inside.
    ///      Every payout is measured by what arrives, so a transfer tax an existing subject or quote switches on after
    ///      the launch reduces what the recipient gets but never freezes the exit.
    /// @param launchId The launch
    /// @param amount Liquidity (position) or shares (escrow) to withdraw
    /// @param min0 The minimum currency0 principal the recipient receives
    /// @param min1 The minimum currency1 principal the recipient receives
    /// @param recipient Who receives the principal
    /// @param deadline The last timestamp the withdrawal may execute at
    function withdraw(bytes32 launchId, uint256 amount, uint256 min0, uint256 min1, address recipient, uint256 deadline)
        external
        idle
        returns (uint256 amount0, uint256 amount1)
    {
        Launch storage l = _launches[launchId];
        if (l.owner != msg.sender) revert NotOwner();
        if (block.timestamp > deadline) revert Expired();
        if (block.number < l.lockedUntil) revert PrincipalLocked(l.lockedUntil);
        if (recipient == address(0) || recipient == address(this) || recipient == address(poolManager)) {
            revert InvalidRecipient(recipient);
        }
        if (amount == 0) revert InvalidAmount();
        if (l.kind == POSITION) {
            if (amount > l.liquidity) revert InvalidAmount();
            l.liquidity -= uint128(amount);
            (,, amount0, amount1) = _remove(launchId, int256(amount), recipient, l.feeRecipient);
        } else {
            if (amount > l.shares) revert InvalidAmount();
            l.shares -= amount;
            (amount0, amount1) = IHookrShareEscrow(l.adapter).release(l.key, amount, 0, 0, recipient);
        }
        if (amount0 < min0 || amount1 < min1) revert Slippage();
        emit PrincipalWithdrawn(launchId, recipient, amount, amount0, amount1);
    }

    /// @notice Points a founding position's fees at a new recipient. Owner only; takes effect at the next collection,
    ///         and anyone may collect before then, so an owner re-pointing accrued fees collects first.
    /// @dev A SHARES launch has no founding position: its fees stay inside the shares and reach the principal
    ///      recipient on `withdraw`, so its recorded fee recipient is never paid and cannot be re-pointed.
    function setFeeRecipient(bytes32 launchId, address recipient) external idle {
        Launch storage l = _launches[launchId];
        if (l.owner != msg.sender) revert NotOwner();
        if (l.kind != POSITION) revert NotApplicable();
        if (recipient == address(0) || recipient == address(this) || recipient == address(poolManager)) {
            revert InvalidRecipient(recipient);
        }
        l.feeRecipient = recipient;
        emit FeeRecipientSet(launchId, recipient);
    }

    /// @notice Starts a two-step transfer of the launch. Zero cancels. The current owner keeps control until then.
    function transferLaunch(bytes32 launchId, address newOwner) external idle {
        Launch storage l = _launches[launchId];
        if (l.owner != msg.sender) revert NotOwner();
        if (newOwner == address(this) || newOwner == address(poolManager)) revert InvalidRecipient(newOwner);
        l.pendingOwner = newOwner;
        emit LaunchTransferStarted(launchId, msg.sender, newOwner);
    }

    /// @notice Completes a pending launch transfer
    function acceptLaunch(bytes32 launchId) external idle {
        Launch storage l = _launches[launchId];
        if (msg.sender != l.pendingOwner || msg.sender == address(0)) revert NotPendingOwner();
        l.owner = msg.sender;
        l.pendingOwner = address(0);
        emit LaunchTransferred(launchId, msg.sender);
    }

    /// @notice Pays the whole accrued protocol share of `currency` to `protocolRecipient`. Callable by anyone.
    function payProtocol(Currency currency) external idle returns (uint256 amount) {
        amount = protocolOwed[currency];
        if (amount == 0) revert InvalidAmount();
        protocolOwed[currency] = 0;
        HookrSettlement.send(currency, protocolRecipient, amount);
        emit ProtocolPaid(currency, protocolRecipient, amount);
    }

    /// @notice Sends this contract's idle balance of `currency` above the protocol share owed to `recipient`.
    ///         Callable by anyone.
    /// @dev Every call returns this contract's balances to where they started plus any protocol share it accrued, so
    ///      a balance above `protocolOwed` is a mistaken transfer or forced ETH. Positions live in the PoolManager and
    ///      shares in the adapter's ledger, never here.
    function sweep(Currency currency, address recipient) external idle returns (uint256 amount) {
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient(recipient);
        amount = HookrSettlement.balance(currency, address(this)) - protocolOwed[currency];
        if (amount == 0) revert InvalidAmount();
        HookrSettlement.send(currency, recipient, amount);
        emit Swept(currency, recipient, amount);
    }

    /// @notice Takes native ETH from the PoolManager only: the protocol share of a native fee
    receive() external payable {
        if (msg.sender != address(poolManager)) revert InvalidCallback();
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Runs only the pending action, only for the PoolManager.
    function unlockCallback(bytes calldata data) external returns (bytes memory result) {
        if (msg.sender != address(poolManager) || _lock != EXPECT_CALLBACK || keccak256(data) != _pending) {
            revert InvalidCallback();
        }
        _lock = IN_CALLBACK;
        delete _pending;
        (uint8 action, bytes32 launchId, int256 amount, address to) =
            abi.decode(data, (uint8, bytes32, int256, address));
        Launch storage l = _launches[launchId];
        if (action == ACTION_ADD) {
            result = _cbAdd(l, launchId, amount);
        } else if (action == ACTION_BUY) {
            result = _cbBuy(l, uint256(amount), to);
        } else {
            result = _cbRemove(l, launchId, amount, to);
        }
        _lock = DONE;
    }

    /// @dev Record checks 1 to 5, in order.
    function _admitted(address hook) private view returns (ExternalHookRecord memory r) {
        r = book.externalHook(hook);
        if (r.listingStatus != ExternalHookTypes.LAUNCHABLE || r.hook != hook) {
            revert NotLaunchable(hook, r.listingStatus);
        }
        if (hook == address(0) ? r.initProtocolId != ExternalHookTypes.HOOKLESS : hook.codehash != r.codeHash) {
            revert HookCodeChanged(hook);
        }
        if (r.capabilities & ExternalHookTypes.UPGRADEABLE != 0) revert HookUpgradeable(hook);
        AdapterAdmission memory a = book.adapterAdmission(r.launchAdapter);
        if (
            r.launchAdapter == address(0) || !a.active || a.initProtocolId != r.initProtocolId
                || r.launchAdapter.codehash != a.codeHash
                || IHookrLaunchAdapter(r.launchAdapter).initProtocolId() != r.initProtocolId
                || IHookrLaunchAdapterBound(r.launchAdapter).launcher() != address(this)
        ) revert AdapterNotAdmitted(r.launchAdapter);
        // Where the hook's entries are owner-only, the admitted adapter is the owner of record.
        if (r.capabilities & ExternalHookTypes.OWNER_INIT != 0 && r.ownerOfRecord != r.launchAdapter) {
            revert OwnerOfRecordMismatch(hook, r.ownerOfRecord);
        }
    }

    /// @dev Record check 6 plus the lane's own rules. Returns the seed path.
    function _checkIntent(ExternalHookRecord memory r, Ctx memory c, Params calldata p)
        private
        view
        returns (uint8 kind)
    {
        uint32 caps = r.capabilities;
        bool native = c.quoteC.isAddressZero();
        // Every add, buy, fee collection and exit this contract makes passes empty hookData.
        if (caps & ExternalHookTypes.IGNORES_HOOKDATA == 0) revert IntentRefused("HOOKDATA");
        if (LPFeeLibrary.isDynamicFee(p.fee)) {
            if (caps & ExternalHookTypes.STATIC_FEE_ONLY != 0) revert IntentRefused("DYNAMIC_FEE");
        } else if (p.fee > MAX_FEE_PIPS) {
            revert IntentRefused("FEE");
        }
        if (caps & ExternalHookTypes.REJECTS_NATIVE != 0 && native) revert IntentRefused("NATIVE");
        if (caps & ExternalHookTypes.ALLOWS_EXTERNAL_LP != 0) {
            kind = POSITION;
        } else if (caps & ExternalHookTypes.HOOK_OWNED_LP != 0) {
            // Shares are funded by an exact ERC-20 allowance; native value is never handed to an adapter.
            if (native) revert IntentRefused("NATIVE");
            kind = SHARES;
        } else {
            revert IntentRefused("NO_SEED_PATH");
        }
        if (!hookrRegistry.isQuote(Currency.unwrap(c.quoteC))) revert IntentRefused("QUOTE_CATALOG");
        if (Currency.unwrap(c.quoteC) == c.subject) revert IntentRefused("SAME_CURRENCY");
        if (p.subjectAmount == 0 || (!c.isNew && p.subjectAmount > type(uint128).max)) revert IntentRefused("AMOUNT");
        if (c.isNew && p.subjectAmount > c.supply) revert IntentRefused("AMOUNT");
        if (p.quoteAmount > type(uint128).max || p.buyQuoteAmount > type(uint128).max) revert IntentRefused("AMOUNT");
        if (p.lockBlocks > MAX_LOCK_BLOCKS) revert IntentRefused("LOCK");
        if (p.tickSpacing < MIN_TICK_SPACING || p.tickSpacing > MAX_TICK_SPACING) revert IntentRefused("TICK_SPACING");
        if (p.feeRecipient == address(0) || p.feeRecipient == address(this) || p.feeRecipient == address(poolManager)) {
            revert IntentRefused("FEE_RECIPIENT");
        }
        if (p.buyQuoteAmount != 0 && p.minBuySubjectOut == 0) revert IntentRefused("BUY_MIN");
    }

    /// @dev The key `prepare` returned must be exactly the intent's pool on the record's hook.
    function _checkKey(PoolKey memory key, Ctx memory c, Params calldata p, address hook) private pure {
        bool subjectFirst = uint160(c.subject) < uint160(Currency.unwrap(c.quoteC));
        Currency c0 = subjectFirst ? c.subjectC : c.quoteC;
        Currency c1 = subjectFirst ? c.quoteC : c.subjectC;
        if (
            Currency.unwrap(key.currency0) != Currency.unwrap(c0)
                || Currency.unwrap(key.currency1) != Currency.unwrap(c1)
        ) {
            revert KeyMismatch("CURRENCY");
        }
        if (key.fee != p.fee) revert KeyMismatch("FEE");
        if (key.tickSpacing != p.tickSpacing) revert KeyMismatch("TICK_SPACING");
        if (address(key.hooks) != hook) revert KeyMismatch("HOOKS");
    }

    function _subject(Ctx memory c, Token calldata token) private {
        c.isNew = token.existing == address(0);
        if (c.isNew) {
            if (token.supply == 0) revert InvalidToken();
            c.supply = token.supply;
            c.subject = HookrTokenDeployer.deploy(msg.sender, token.salt, token.name, token.symbol, token.supply);
            c.subjectBase = 0;
        } else {
            if (
                token.supply != 0 || token.salt != bytes32(0) || bytes(token.name).length != 0
                    || bytes(token.symbol).length != 0
            ) {
                revert InvalidToken();
            }
            c.subject = token.existing;
            _requireToken(c.subject);
            c.subjectBase = HookrSettlement.balance(Currency.wrap(c.subject), address(this));
        }
        c.subjectC = Currency.wrap(c.subject);
    }

    function _fund(Ctx memory c, Params calldata p) private {
        if (!c.isNew) _pull(c.subjectC, p.subjectAmount);
        uint256 quoteTotal = p.quoteAmount + p.buyQuoteAmount;
        if (c.quoteC.isAddressZero()) {
            if (msg.value != quoteTotal) revert InvalidFunding();
        } else {
            if (msg.value != 0) revert InvalidFunding();
            _pull(c.quoteC, quoteTotal);
        }
    }

    /// @dev Exact pull: this contract gains exactly `amount` and the payer loses exactly `amount`.
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

    function _refund(Ctx memory c, Params calldata p) private {
        uint256 subjectIn = c.isNew ? c.supply : p.subjectAmount;
        uint256 quoteIn = p.quoteAmount + p.buyQuoteAmount;
        uint256 subjectBack = subjectIn - c.subjectUsed;
        uint256 quoteBack = quoteIn - c.quoteUsed - c.buyPaid;
        if (HookrSettlement.balance(c.subjectC, address(this)) != c.subjectBase + subjectBack) revert InvalidFunding();
        if (HookrSettlement.balance(c.quoteC, address(this)) != c.quoteBase + quoteBack) revert InvalidFunding();
        HookrSettlement.send(c.subjectC, msg.sender, subjectBack);
        HookrSettlement.send(c.quoteC, msg.sender, quoteBack);
        if (
            HookrSettlement.balance(c.subjectC, address(this)) != c.subjectBase
                || HookrSettlement.balance(c.quoteC, address(this)) != c.quoteBase
        ) revert InvalidFunding();
    }

    /// @dev A subject must be a contract that is not an EIP-7702 delegated account.
    function _requireToken(address token) private view {
        uint256 size;
        bool delegated;
        assembly ("memory-safe") {
            size := extcodesize(token)
            if size {
                let free := mload(0x40)
                extcodecopy(token, free, 0, 1)
                delegated := eq(byte(0, mload(free)), 0xef)
            }
        }
        if (size == 0 || delegated) revert InvalidToken();
    }

    function _seedPosition(
        Ctx memory c,
        Launch storage l,
        IHookrLaunchAdapter adapter,
        PoolKey memory key,
        IHookrLaunchAdapter.LaunchIntent memory intent
    ) private {
        _tLaunchId = c.launchId;
        _tAdapter = address(adapter);
        _tSubjectBudget = intent.subjectAmount;
        _tQuoteBudget = intent.quoteAmount;
        _lock = SEEDING;
        IHookrLaunchAdapter.Seeded memory s = adapter.seed(key, intent);
        if (_lock != SEEDING) revert InvalidCallback();
        _lock = BUSY;
        if (!_tSeeded) revert SeedMismatch("NOT_SEEDED");
        if (s.subjectUsed != _tSubjectUsed || s.quoteUsed != _tQuoteUsed) revert SeedMismatch("AMOUNTS");
        if (s.subjectUsed == 0) revert SeedMismatch("EMPTY");
        bytes32 positionId = Position.calculatePositionKey(address(this), l.tickLower, l.tickUpper, c.launchId);
        if (s.receipt != positionId) revert SeedMismatch("RECEIPT");
        (uint128 onBook,,) = poolManager.getPositionInfo(key.toId(), positionId);
        if (onBook != l.liquidity) revert SeedMismatch("LIQUIDITY");
        _requireBandAtPrice(l, intent.sqrtPriceX96, Currency.unwrap(key.currency0) == c.subject);
        c.subjectUsed = s.subjectUsed;
        c.quoteUsed = s.quoteUsed;
        c.receipt = s.receipt;
        _tLaunchId = bytes32(0);
        _tAdapter = address(0);
        _tSeeded = false;
    }

    /// @dev The founding band must start at the opening price: no whole tick spacing may lie between the price and
    ///      the band's near edge, so the first trade in the subject's direction trades against it and the protocol
    ///      share applies to the fees it earns. A band parked away from the price, where it would never trade, is
    ///      refused (`IntentRefused("BAND")`); its far edge, and so its width, stays the creator's choice.
    function _requireBandAtPrice(Launch storage l, uint160 sqrtPriceX96, bool subjectFirst) private view {
        int24 spacing = l.key.tickSpacing;
        bool atPrice = subjectFirst
            ? l.tickLower - spacing < TickMath.MIN_TICK
                || TickMath.getSqrtPriceAtTick(l.tickLower - spacing) <= sqrtPriceX96
            : l.tickUpper + spacing > TickMath.MAX_TICK
                || TickMath.getSqrtPriceAtTick(l.tickUpper + spacing) > sqrtPriceX96;
        if (!atPrice) revert IntentRefused("BAND");
    }

    function _seedShares(
        Ctx memory c,
        Launch storage l,
        IHookrLaunchAdapter adapter,
        PoolKey memory key,
        IHookrLaunchAdapter.LaunchIntent memory intent,
        PoolId id
    ) private {
        IHookrShareEscrow escrow = IHookrShareEscrow(address(adapter));
        uint256 escrowBefore = escrow.escrowOf(id);
        uint256 subjectBefore = HookrSettlement.balance(c.subjectC, address(this));
        uint256 quoteBefore = HookrSettlement.balance(c.quoteC, address(this));
        // The only allowance an adapter ever gets: the launch amounts, cleared as soon as `seed` returns.
        IERC20(c.subject).forceApprove(address(adapter), intent.subjectAmount);
        IERC20(Currency.unwrap(c.quoteC)).forceApprove(address(adapter), intent.quoteAmount);
        IHookrLaunchAdapter.Seeded memory s = adapter.seed(key, intent);
        IERC20(c.subject).forceApprove(address(adapter), 0);
        IERC20(Currency.unwrap(c.quoteC)).forceApprove(address(adapter), 0);
        uint256 subjectSpent = subjectBefore - HookrSettlement.balance(c.subjectC, address(this));
        uint256 quoteSpent = quoteBefore - HookrSettlement.balance(c.quoteC, address(this));
        if (s.subjectUsed != subjectSpent || s.quoteUsed != quoteSpent) revert SeedMismatch("AMOUNTS");
        // A seed that moved no subject placed nothing; the pool would be an empty market with Hookr's name on it.
        if (subjectSpent == 0) revert SeedMismatch("EMPTY");
        uint256 shares = uint256(s.receipt);
        if (shares == 0 || escrow.escrowOf(id) != escrowBefore + shares) revert SeedMismatch("ESCROW");
        l.shares = shares;
        c.subjectUsed = subjectSpent;
        c.quoteUsed = quoteSpent;
        c.receipt = s.receipt;
    }

    /// @dev The pool key is read from the launch record inside the callback.
    function _initialBuy(Ctx memory c, Params calldata p) private {
        (uint256 paid, uint256 out) = abi.decode(
            _unlock(abi.encode(ACTION_BUY, c.launchId, int256(p.buyQuoteAmount), msg.sender), BUSY), (uint256, uint256)
        );
        if (paid > p.buyQuoteAmount || out < p.minBuySubjectOut) revert Slippage();
        c.buyPaid = paid;
        c.buyOut = out;
        emit InitialBuy(c.launchId, msg.sender, paid, out);
    }

    function _unlock(bytes memory data, uint8 resume) private returns (bytes memory result) {
        _pending = keccak256(data);
        _lock = EXPECT_CALLBACK;
        result = poolManager.unlock(data);
        if (_lock != DONE) revert InvalidCallback();
        _lock = resume;
    }

    function _remove(bytes32 launchId, int256 liquidity, address principalTo, address feeTo)
        private
        returns (uint256 fee0, uint256 fee1, uint256 amount0, uint256 amount1)
    {
        uint256 cut0;
        uint256 cut1;
        (fee0, fee1, amount0, amount1, cut0, cut1) = abi.decode(
            _unlock(
                abi.encode(ACTION_REMOVE, launchId, liquidity, principalTo == address(0) ? feeTo : principalTo), BUSY
            ),
            (uint256, uint256, uint256, uint256, uint256, uint256)
        );
        if (fee0 != 0 || fee1 != 0) emit FeesCollected(launchId, feeTo, fee0, fee1);
        if (cut0 != 0 || cut1 != 0) emit ProtocolShareAccrued(launchId, cut0, cut1);
    }

    function _cbAdd(Launch storage l, bytes32 launchId, int256 liquidity) private returns (bytes memory) {
        (BalanceDelta delta, BalanceDelta fees) =
            poolManager.modifyLiquidity(l.key, ModifyLiquidityParams(l.tickLower, l.tickUpper, liquidity, launchId), "");
        if (fees.amount0() != 0 || fees.amount1() != 0 || delta.amount0() > 0 || delta.amount1() > 0) {
            revert SeedMismatch("DELTA");
        }
        uint256 amount0 = uint256(-int256(delta.amount0()));
        uint256 amount1 = uint256(-int256(delta.amount1()));
        HookrSettlement.pay(poolManager, l.key.currency0, address(this), amount0);
        HookrSettlement.pay(poolManager, l.key.currency1, address(this), amount1);
        return abi.encode(amount0, amount1);
    }

    function _cbBuy(Launch storage l, uint256 amountIn, address buyer) private returns (bytes memory) {
        bool quoteIs0 = Currency.unwrap(l.key.currency0) != l.subject;
        BalanceDelta delta = poolManager.swap(
            l.key,
            SwapParams({
                zeroForOne: quoteIs0,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: quoteIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 quoteDelta = quoteIs0 ? delta.amount0() : delta.amount1();
        int128 subjectDelta = quoteIs0 ? delta.amount1() : delta.amount0();
        if (quoteDelta > 0 || subjectDelta < 0) revert Slippage();
        uint256 paid = uint256(-int256(quoteDelta));
        uint256 out = uint256(int256(subjectDelta));
        HookrSettlement.pay(poolManager, quoteIs0 ? l.key.currency0 : l.key.currency1, address(this), paid);
        HookrSettlement.takeTo(poolManager, Currency.wrap(l.subject), buyer, out);
        return abi.encode(paid, out);
    }

    /// @dev Liquidity zero collects fees only. Otherwise principal goes to `to`. Fees go to the fee recipient less the
    ///      launch's protocol share, which this contract takes and owes to `protocolRecipient`. Returns what each
    ///      party received, which is less than it was paid only when the token taxes the delivery.
    function _cbRemove(Launch storage l, bytes32 launchId, int256 liquidity, address to)
        private
        returns (bytes memory)
    {
        (BalanceDelta delta, BalanceDelta fees) = poolManager.modifyLiquidity(
            l.key, ModifyLiquidityParams(l.tickLower, l.tickUpper, -liquidity, launchId), ""
        );
        int256 d0 = delta.amount0();
        int256 d1 = delta.amount1();
        int256 f0 = fees.amount0();
        int256 f1 = fees.amount1();
        if (f0 < 0 || f1 < 0 || d0 < f0 || d1 < f1) revert SeedMismatch("DELTA");
        uint256 cut0 = _protocolCut(uint256(f0), l.protocolShareBps);
        uint256 cut1 = _protocolCut(uint256(f1), l.protocolShareBps);
        uint256 fee0 = uint256(f0) - cut0;
        uint256 fee1 = uint256(f1) - cut1;
        uint256 amount0 = uint256(d0 - f0);
        uint256 amount1 = uint256(d1 - f1);
        address feeTo = l.feeRecipient;
        // Every leg is paid by what arrives: a transfer tax an existing token switches on after the launch is the
        // token's own charge and must not freeze the position, its other currency or the protocol share.
        cut0 = _deliver(l.key.currency0, address(this), cut0);
        cut1 = _deliver(l.key.currency1, address(this), cut1);
        protocolOwed[l.key.currency0] += cut0;
        protocolOwed[l.key.currency1] += cut1;
        fee0 = _deliver(l.key.currency0, feeTo, fee0);
        fee1 = _deliver(l.key.currency1, feeTo, fee1);
        amount0 = _deliver(l.key.currency0, to, amount0);
        amount1 = _deliver(l.key.currency1, to, amount1);
        return abi.encode(fee0, fee1, amount0, amount1, cut0, cut1);
    }

    /// @dev Pays `amount` from the PoolManager to `to` and returns what `to` received. The PoolManager must lose
    ///      exactly `amount` (a token that charges the sender extra reverts, so no other pool's reserve pays for it);
    ///      an ERC-20 recipient may receive less, never more, when the token levies a transfer tax on delivery.
    function _deliver(Currency currency, address to, uint256 amount) private returns (uint256 received) {
        if (amount == 0) return 0;
        bool native = currency.isAddressZero();
        uint256 theirs = native ? 0 : HookrSettlement.balance(currency, to);
        uint256 managerBefore = HookrSettlement.balance(currency, address(poolManager));
        poolManager.take(currency, to, amount);
        if (HookrSettlement.balance(currency, address(poolManager)) != managerBefore - amount) {
            revert HookrSettlement.BalanceMismatch();
        }
        if (native) return amount;
        uint256 theirsAfter = HookrSettlement.balance(currency, to);
        if (theirsAfter < theirs || theirsAfter - theirs > amount) revert HookrSettlement.BalanceMismatch();
        received = theirsAfter - theirs;
    }

    /// @dev The protocol share of `fee`, rounded up so the share is never below the rate. A fee is at most int128.
    function _protocolCut(uint256 fee, uint16 bps) private pure returns (uint256) {
        return (fee * bps + 9_999) / 10_000;
    }
}
