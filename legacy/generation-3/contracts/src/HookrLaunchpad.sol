// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {HookrToken} from "./HookrToken.sol";
import {HookrBlueprints} from "./HookrBlueprints.sol";
import {HookrHook} from "./HookrHook.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {V4PoolMath} from "./libraries/V4PoolMath.sol";
import {HookrLaunchpadLib} from "./libraries/HookrLaunchpadLib.sol";

/// @title HookrLaunchpad
/// @notice The Hookr.fun launchpad on Robinhood Chain: launch a fixed-supply token onto a stepped
///         bonding curve; when the curve sells out, the raise + reserved supply graduate atomically
///         into a native-ETH Uniswap v4 pool wearing the creator's configured HookrHook behavior.
///
///         Curve: 10 geometric price tranches (each step = +70%), 80% of supply on the curve,
///         buys and sells allowed pre-graduation with a 1% curve fee split creator/protocol.
///         Graduation: reserve ETH + remaining supply become full-range liquidity owned by this
///         contract forever (no removal function exists — the position is locked by construction).
///         LP fees on the locked position are collectable and split creator/protocol; the token
///         side of collected fees is burned.
///
///         Instant (`launchInstant`): no curve and no graduation step. The creator sends ETH and
///         picks what share of the fixed supply seeds the pool; the opening price is the ratio of
///         the two, so their real choice is an opening valuation. The pool is live in the launch
///         transaction and its liquidity is the same locked, launchpad-owned position graduation
///         produces. Supply not placed is burned or laddered into the token-only bands: neither
///         path hands the creator an allocation. Neither path stops them buying from the pool
///         once it is open, and on the instant path "once it is open" is the launch transaction
///         itself — the anti-snipe guard, not the absence of an allocation, is what constrains
///         and taxes that early buying on top of the AMM's reserve-based execution price.
///
///         Blueprints: reusable hook configurations saved by any author. Launching with a
///         blueprint routes a share of that pool's hook fees to the blueprint author (royalty).
contract HookrLaunchpad is IUnlockCallback {
    // ---------------------------------------------------------------- constants

    uint256 public constant SUPPLY = 1_000_000_000e18;
    uint256 public constant CURVE_SUPPLY = 800_000_000e18; // 80% sold along the curve
    uint256 public constant TRANCHE_TOKENS = 80_000_000e18; // 10 tranches
    uint256 public constant TRANCHES = 10;
    uint256 public constant PRICE_NUM = 17; // +70% per tranche
    uint256 public constant PRICE_DEN = 10;
    uint256 public constant CURVE_FEE_BPS = 100; // 1%
    uint256 internal constant BPS = 10_000;
    uint96 public constant MIN_TARGET = 0.0001 ether;
    uint96 public constant MAX_TARGET = 1000 ether;
    uint96 public constant MIN_POT_BUY_WEI = 0.001 ether;
    uint24 internal constant DYNAMIC_FEE_FLAG = 0x800000;
    int24 public constant TICK_SPACING = 60;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// Creator's share of collected pool fees. 0 in `LaunchArgs` means "use the default".
    uint16 public constant DEFAULT_CREATOR_FEE_BPS = 5000;
    /// The protocol keeps at least 20% of pool fees, so a creator can never take the whole cut.
    uint16 public constant MAX_CREATOR_FEE_BPS = 8000;
    /// Bounded so collection stays a fixed-cost loop no matter who configured the launch.
    uint256 public constant MAX_FEE_RECIPIENTS = 4;
    uint256 public constant MAX_LP_TRANCHES = 4;
    /// A tranche must sit at least this far from the graduation tick to be token-only.
    int24 public constant MIN_TRANCHE_OFFSET = 60;
    /// And no further than this, so a band cannot be placed where it bricks the launch.
    /// @dev A band is seeded from `HookrLaunchpadLib.bandLiquidity`, whose result must fit uint128. The
    ///      further below spot a band sits the smaller the sqrt-price width it spans, and past
    ///      roughly 560,000 ticks below spot the leftover supply no longer fits — which used to
    ///      revert INSIDE the unlock, before `_seedTranches` could skip it, stranding the raise and
    ///      leaving the token permanently unable to open a pool. Two things now stop that, and this
    ///      is only the first: 200,000 ticks is already a 4.85e8x price multiple, so nothing below
    ///      it is a ladder anyone meant to build, and it leaves ~8 orders of magnitude of headroom
    ///      against the uint128 bound at every price either launch path can reach. The guarantee is
    ///      `HookrLaunchpadLib.bandLiquidity` returning zero rather than reverting; this bound is
    ///      what stops a creator reaching that skip by accident and silently burning their ladder.
    int24 public constant MAX_TRANCHE_OFFSET = 200_000;

    /// Smallest share of the fixed supply an instant launch may place in its pool, in bps.
    /// @dev Two jobs, and the second is the reason it is not lower. It bounds the opening
    ///      valuation from above — opening FDV is `ethIn * BPS / poolSupplyBps`, so a 20% floor
    ///      caps it at 5x the ETH the creator actually committed. And it bounds how weak the
    ///      anti-snipe guard can get: the guard's cap is denominated in tokens, so at a 1% float
    ///      a `maxBuyBps` that authorises 1% of SUPPLY authorises 100% of the pool's ETH. Below
    ///      ~1900 bps an instant launch's guard is weaker than the same setting buys on any curve
    ///      launch, so the floor sits above that. A creator wanting a thinner float is asking for
    ///      a pool a single swap can move several-fold, which is not a launch, it is an exit.
    uint16 public constant MIN_POOL_SUPPLY_BPS = 2000;
    /// Coarsest opening price an instant launch may derive, in wei per whole token.
    /// @dev The derived price is an integer, so its relative quantization error is
    ///      `1 / openPriceWei`. Requiring 1e6 keeps the realized pool price within one part per
    ///      million of the `ethIn / tokensInPool` ratio the creator actually chose. It binds
    ///      exactly when a creator asks for a large share of supply against very little ETH; the
    ///      remedy is more ETH or a smaller share, and the error names the price, not the input,
    ///      because the constraint is genuinely on their ratio rather than on either one alone.
    uint96 public constant MIN_OPEN_PRICE_WEI = 1e6;

    IPoolManager public immutable poolManager;
    HookrBlueprints public immutable blueprints;
    address public owner;
    address public pendingOwner; // two-step handover; see proposeOwner/acceptOwnership
    HookrHook public hook; // set once by owner after CREATE2 mining
    uint96 public creationFeeWei = 0.0002 ether;

    // ---------------------------------------------------------------- types

    struct Launch {
        address token;
        address creator;
        address quoteToken; // address(0) means native ETH
        uint40 launchBlock;
        uint32 blueprintId; // 0 = custom stack
        bool graduated;
        bool attached; // true = an existing ERC-20 attached to a fresh hooked pool (no curve ever)
        uint96 basePriceWei; // p0: wei per whole token in tranche 0
        uint96 targetWei; // exact curve proceeds at full sale
        uint96 reserveWei; // ETH currently backing the curve
        uint128 soldTokens;
        uint40 graduatedAtBlock;
        uint160 sqrtPriceX96AtGraduation;
        PoolId poolId;
        HookrLaunchpadLib.HookParams hookParams;
    }

    mapping(address => Launch) internal launches;
    address[] public allTokens;

    /// @notice Successful intent-bound launches, namespaced by the transaction sender.
    /// @dev A nonzero token address is both the replay marker and the launch postcondition.
    mapping(address creator => mapping(bytes32 intentId => address token)) public launchedByIntent;

    // fee accruals (pull payments). Native fees are stored under the address(0) key so every
    // market path shares ONE accounting lane regardless of quote currency.
    mapping(address => uint256) public protocolFeesByQuote;
    mapping(address => uint256) public creatorFeesWei; // token => accrued creator fees
    /// token => creator's share of pool fees in bps. 0 means DEFAULT_CREATOR_FEE_BPS.
    mapping(address => uint16) public creatorFeeBpsOf;
    /// token => split of the creator side. Empty means the whole creator side goes to the creator.
    mapping(address => HookrLaunchpadLib.FeeRecipient[]) internal feeRecipientsOf;
    /// token => extra token-only bands seeded above the graduation price.
    mapping(address => HookrLaunchpadLib.LpTranche[]) internal lpTranchesOf;
    /// token => recipient => claimable wei from the split above.
    mapping(address => mapping(address => uint256)) public splitFeesWei;
    mapping(address => address) public creatorPayout; // token => payout address (0 = the creator)
    /// token => guard-window pool fees already routed past the creator's share, in wei. Monotone
    /// high-water mark against the hook's own cumulative `guardLpEarnedWei`; see collectPoolFees.
    mapping(address => uint256) public guardFeesWithheldWei;

    bool internal locked;
    uint8 internal constant CB_GRADUATE = 1;
    uint8 internal constant CB_COLLECT = 2;
    uint8 internal constant CB_TRANCHE = 3;

    // ---------------------------------------------------------------- events

    /// @notice Display metadata (tagline/logoURI) is deliberately NOT in this event: it is
    ///         permissionless, non-unique display data read from `getLaunch` by the UI. Identity
    ///         resolves by chain + token address, never by metadata.
    event TokenLaunched(
        address indexed token,
        address indexed creator,
        uint32 indexed blueprintId,
        string name,
        string symbol,
        uint96 targetWei,
        uint96 basePriceWei
    );
    event CurveBuy(
        address indexed token,
        address indexed buyer,
        uint256 ethIn,
        uint256 tokensOut,
        uint96 reserveWei,
        uint128 soldTokens
    );
    event CurveSell(
        address indexed token,
        address indexed seller,
        uint256 tokensIn,
        uint256 ethOut,
        uint96 reserveWei,
        uint128 soldTokens
    );
    event Graduated(
        address indexed token,
        PoolId indexed poolId,
        uint160 sqrtPriceX96,
        uint256 ethLiquidity,
        uint256 tokenLiquidity,
        uint256 tokensBurned
    );
    /// @notice A curve-free launch. `Graduated` is emitted alongside this in the same transaction,
    ///         so indexers that already follow the graduation path need no change; this event is
    ///         what tells them the pool was opened AT launch and no curve ever existed.
    event InstantLaunched(
        address indexed token, PoolId indexed poolId, uint16 poolSupplyBps, uint96 openPriceWei, uint256 ethInPool
    );
    event PoolFeesCollected(address indexed token, uint256 ethAmount, uint256 tokensBurned);
    event LpTrancheSeeded(
        address indexed token, uint256 indexed index, int24 tickLower, int24 tickUpper, uint256 tokensUsed
    );
    event FeeSplitCredited(address indexed token, address indexed to, uint256 amountWei);
    event CreatorFeesClaimed(address indexed token, address indexed payTo, uint256 amountWei);
    event CreatorPayoutSet(address indexed token, address indexed payTo);
    event ProtocolFeesWithdrawn(address indexed to, uint256 amountWei);
    event CreationFeeSet(uint96 feeWei);
    event HookSet(address hook);
    event OwnerProposed(address pendingOwner);
    event OwnerSet(address owner);
    event LaunchIntentConsumed(address indexed creator, bytes32 indexed intentId, address indexed token);

    /// @notice An existing ERC-20 was attached to a fresh hooked Uniswap v4 pool. `Graduated` is
    ///         emitted alongside it in the same transaction, so indexers that already follow the
    ///         graduation path need no change; this event is what tells them the base token was
    ///         NOT minted by this launchpad and no curve ever existed. Both seed amounts are the
    ///         amounts the locked position actually consumed.
    event MarketAttached(
        address indexed token,
        address indexed creator,
        PoolId indexed poolId,
        uint160 sqrtPriceX96,
        uint256 quoteSeeded,
        uint256 tokensSeeded
    );

    // ---------------------------------------------------------------- errors

    error NotOwner();
    error NotCreator();
    error ZeroAddress();
    error Reentrancy();
    error HookAlreadySet();
    error HookNotSet();
    error HookFlagsInvalid();
    error UnknownToken();
    error AlreadyGraduated();
    error NotGraduated();
    error BadLaunchArgs();
    error UnexpectedCreator(address expectedCreator, address actualCreator);
    error ZeroLaunchIntent();
    error LaunchIntentAlreadyUsed(address creator, bytes32 intentId, address token);
    error BadHookParams();
    error BadFeeSplit();
    error BadLpPlan();
    error TargetOutOfRange();
    error InstantEthOutOfRange();
    error PoolShareOutOfRange();
    error OpenPriceOutOfRange();
    error InsufficientPayment();
    error SlippageExceeded();
    error ZeroAmount();
    error CurveSoldOut();
    error EthTransferFailed();
    error UnexpectedNativeValue();
    error TransferFailed();
    error NotPoolManager();
    error BadCallback();
    error NothingToClaim();
    error FeeTooHigh();
    error BadAttachArgs();
    error AttachSeedOutOfRange();
    error AttachPriceUnrepresentable();
    error TokenAlreadyListed();

    modifier nonReentrant() {
        if (locked) revert Reentrancy();
        locked = true;
        _;
        locked = false;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(IPoolManager poolManager_, HookrBlueprints blueprintRegistry_) {
        poolManager = poolManager_;
        // The registry is a separate deployment for the launchpad's EIP-170 budget. It is
        // append-only and carries no authority over the launchpad; the launchpad only reads
        // resolved params + royalty routing from it at launch time.
        blueprints = blueprintRegistry_;
        owner = msg.sender;
    }

    /// @notice Stable deployment identity for post-deploy readbacks and agent health checks.
    function contractName() external pure returns (string memory) {
        return "HookrLaunchpad";
    }

    /// @notice Candidate generation. Runtime code hash remains the release authority.
    function contractVersion() external pure returns (string memory) {
        return "1.0.0";
    }

    receive() external payable {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }

    // ---------------------------------------------------------------- admin (deliberately tiny)

    /// @notice One-shot wiring of the CREATE2-mined hook.
    function setHook(HookrHook hook_) external onlyOwner {
        if (address(hook) != address(0)) revert HookAlreadySet();
        if (uint160(address(hook_)) & 0x3FFF != hook_.REQUIRED_FLAGS()) revert HookFlagsInvalid();
        if (hook_.launchpad() != address(this)) revert HookFlagsInvalid();
        if (address(hook_.poolManager()) != address(poolManager)) revert HookFlagsInvalid();
        hook = hook_;
        emit HookSet(address(hook_));
    }

    function setCreationFee(uint96 feeWei) external onlyOwner {
        if (feeWei > 0.05 ether) revert FeeTooHigh();
        creationFeeWei = feeWei;
        emit CreationFeeSet(feeWei);
    }

    /// @notice Step 1 of a two-step handover. Nominating address(0) is rejected, and the current
    ///         owner keeps every power until the nominee actually shows up.
    function proposeOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnerProposed(newOwner);
    }

    /// @notice Step 2: the nominee claims ownership, proving the address is live and controllable.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnerSet(msg.sender);
    }

    /// @notice Withdraw accrued protocol fees. `quoteToken == address(0)` selects the native
    ///         balance; anything else selects that ERC-20's accrued bucket. Owner-only.
    function withdrawProtocolFees(address to, address quoteToken) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = protocolFeesByQuote[quoteToken];
        if (amount == 0) revert NothingToClaim();
        delete protocolFeesByQuote[quoteToken];
        _sendQuote(quoteToken, to, amount);
        emit ProtocolFeesWithdrawn(to, amount);
    }

    // ---------------------------------------------------------------- launch

    struct LaunchArgs {
        string name;
        string symbol;
        string tagline;
        string logoURI;
        address expectedCreator; // binds approved calldata to the transaction sender
        address quoteToken; // optional; 0 means native ETH
        uint96 targetRaiseWei;
        uint32 blueprintId; // 0 = use `custom`
        HookrLaunchpadLib.HookParams custom;
        uint256 creatorBuyWei; // optional first buy, included in msg.value after the creation fee
        uint256 minTokensOut; // slippage guard for the creator buy
        uint16 creatorFeeBps; // 0 = DEFAULT_CREATOR_FEE_BPS; capped at MAX_CREATOR_FEE_BPS
        HookrLaunchpadLib.FeeRecipient[] feeRecipients; // empty = the whole creator side goes to the creator
        HookrLaunchpadLib.LpTranche[] lpTranches; // empty = full range only; leftover pool tokens burn as before
    }

    /// @notice Launches through the ordinary permissionless path.
    ///
    ///         Pass a nonzero `intentId` to launch EXACTLY ONCE for that creator-scoped
    ///         identifier: a successful launch records its token in `launchedByIntent`, and an
    ///         exact replay reverts before another token or fee can be created. Failed
    ///         transactions do not consume the intent. This is the door agent approval packets
    ///         use, so copied or repeated calldata cannot launch twice for one creator.
    ///
    ///         Pass `intentId == bytes32(0)` for an ordinary repeatable manual launch; identical
    ///         calls then remain intentionally repeatable by design.
    /// @dev The mapping stores the resulting token rather than a boolean so agents can reconcile
    ///      a mined receipt against an onchain postcondition. Every revert rolls the marker back.
    function launch(LaunchArgs calldata args, bytes32 intentId) external payable nonReentrant returns (address token) {
        if (intentId != 0) _checkIntent(intentId);
        token = _launch(args);
        if (intentId != 0) _recordIntent(intentId, token);
    }

    /// @notice Launch straight into a live Uniswap v4 pool. No bonding curve, no graduation step:
    ///         the pool exists and trades in this transaction, and its liquidity is the same
    ///         locked, launchpad-owned full-range position graduation would have produced.
    ///
    ///         The opening price is never typed in: the creator commits `creatorBuyWei` and picks
    ///         what share of supply seeds the pool, so the price falls out as their ratio and the
    ///         choice they are really making is an opening fully-diluted valuation bounded to
    ///         [1x, 5x] the committed ETH by MIN_POOL_SUPPLY_BPS. Supply not placed in the pool
    ///         burns or ladders into the configured token-only bands; the creator gets no
    ///         allocation, exactly as on the curve path.
    ///
    ///         Same `intentId` contract as `launch`: nonzero means exactly once per creator-scoped
    ///         identifier -- a re-broadcast instant launch would otherwise lock a second tranche
    ///         of ETH into a second pool, permanently, with no removal path by construction --
    ///         and zero means an ordinary repeatable manual launch.
    function launchInstant(LaunchArgs calldata args, uint16 poolSupplyBps, bytes32 intentId)
        external
        payable
        nonReentrant
        returns (address token)
    {
        if (intentId != 0) _checkIntent(intentId);
        token = _launchInstant(args, poolSupplyBps);
        if (intentId != 0) _recordIntent(intentId, token);
    }

    // ---------------------------------------------------------------- attach: existing-token markets

    /// @notice Attach an EXISTING ERC-20 to a fresh hooked Uniswap v4 pool — a programmable
    ///         market for a token this launchpad never minted.
    ///
    ///         A pool's hook is fixed at creation, so "attach" always means a NEW pool with new
    ///         liquidity, seeded here from the backer's own balances in the same transaction. It
    ///         never means editing some earlier pool, and it can never touch liquidity that any
    ///         other venue already holds.
    ///
    ///         The opening price is DERIVED, exactly as on every other launch path: the backer
    ///         commits both sides and the pool price is the funded ratio of the two raw amounts,
    ///         so ANY decimal pairing works — no 18-decimal assumption exists on this path.
    ///         There is no curve, no graduation step, and no leftover allocation to band or burn:
    ///         every pulled token goes into the one locked full-range position, and sub-ppm
    ///         rounding residue on EITHER side is refunded to the backer. The position is
    ///         launchpad-owned and locked by construction, identical to graduation, so fee
    ///         collection splits exactly as on native launches.
    ///
    ///         `quoteToken` may be address(0) (native ETH) or any ERC-20 with code; when it is an
    ///         ERC-20 both it and the base token must approve this contract before attaching.
    ///         Hook parameters that are denominated in quote units (`potMinBuyWei`, and the
    ///         quote-side cap a configured guard derives from `maxBuyBps`) are enforced against
    ///         RAW units of the chosen quote currency.
    struct AttachArgs {
        address token; // the existing ERC-20 (pool currency1); must have code
        address quoteToken; // pool currency0; address(0) = native ETH; an ERC-20 quote must sort BELOW `token`
        uint256 quoteSeedRaw; // raw quote units committed to the pool
        uint256 tokenSeedRaw; // raw base-token units committed to the pool
        address expectedCreator; // binds approved calldata to the transaction sender
        uint32 blueprintId; // 0 = use `custom`
        HookrLaunchpadLib.HookParams custom;
        uint16 creatorFeeBps; // 0 = DEFAULT_CREATOR_FEE_BPS; capped at MAX_CREATOR_FEE_BPS
        HookrLaunchpadLib.FeeRecipient[] feeRecipients; // empty = the whole creator side goes to the creator
    }

    function attachMarket(AttachArgs calldata args, bytes32 intentId)
        external
        payable
        nonReentrant
        returns (address token)
    {
        if (intentId != 0) _checkIntent(intentId);
        token = _attach(args);
        if (intentId != 0) _recordIntent(intentId, token);
    }

    function _attach(AttachArgs calldata args) internal returns (address token) {
        token = args.token;
        if (args.expectedCreator == address(0) || msg.sender != args.expectedCreator) {
            revert UnexpectedCreator(args.expectedCreator, msg.sender);
        }
        if (address(hook) == address(0)) revert HookNotSet();
        if (token == address(0) || token.code.length == 0) revert BadAttachArgs();
        if (token == args.quoteToken) revert BadAttachArgs();
        if (token == address(this) || token == address(hook) || token == address(poolManager)) {
            revert BadAttachArgs();
        }
        if (args.quoteToken != address(0) && args.quoteToken.code.length == 0) revert BadAttachArgs();
        // A pool's hook assumes quote == currency0 and base == currency1 (zeroForOne == buy).
        // Native ETH always sorts first; an ERC-20 quote must therefore sort BEFORE the base
        // token or the market's direction semantics invert. Refuse rather than silently flip.
        if (args.quoteToken != address(0) && args.quoteToken >= token) revert BadAttachArgs();
        if (args.tokenSeedRaw == 0 || args.quoteSeedRaw == 0) revert BadAttachArgs();
        // One token, one market record: a second attach of the same pair would collide with an
        // already-configured poolId anyway (`HookrHook.configurePool` reverts), but refusing HERE
        // keeps the ledger honest about why.
        if (launches[token].token != address(0)) revert TokenAlreadyListed();

        uint256 expectedNativePayment =
            uint256(creationFeeWei) + (args.quoteToken == address(0) ? args.quoteSeedRaw : 0);
        if (msg.value != expectedNativePayment) revert InsufficientPayment();
        _validateFeeSplit(args.creatorFeeBps, args.feeRecipients);

        HookrLaunchpadLib.HookParams memory params = _resolveParams(args.blueprintId, args.custom);

        (uint160 sqrtPriceX96, uint8 err) =
            HookrLaunchpadLib.attachPlan(args.quoteSeedRaw, args.tokenSeedRaw, TICK_SPACING);
        if (err == HookrLaunchpadLib.ATTACH_BAD_SEED) revert AttachSeedOutOfRange();
        if (err != HookrLaunchpadLib.ATTACH_PLAN_OK) revert AttachPriceUnrepresentable();

        Launch storage l = launches[token];
        l.token = token;
        l.creator = msg.sender;
        l.quoteToken = args.quoteToken;
        l.launchBlock = uint40(block.number);
        l.blueprintId = args.blueprintId;
        // Born graduated: there is no curve to run, and `soldTokens` is pinned at CURVE_SUPPLY so
        // the curve buy/sell entries fail closed forever even if some future refactor drops the
        // `graduated` check.
        l.graduated = true;
        l.attached = true;
        l.graduatedAtBlock = uint40(block.number);
        l.soldTokens = uint128(CURVE_SUPPLY);
        // reserveWei/basePriceWei/targetWei stay at their zero defaults: there is no curve, and
        // no 18-decimal assumption holds for an arbitrary existing token -- the pool's
        // `sqrtPriceX96AtGraduation` is the authoritative price and `MarketAttached` carries the
        // funded seed amounts.
        l.hookParams = params;
        l.sqrtPriceX96AtGraduation = sqrtPriceX96;
        if (args.creatorFeeBps != 0) creatorFeeBpsOf[token] = args.creatorFeeBps;
        for (uint256 i; i < args.feeRecipients.length; ++i) {
            feeRecipientsOf[token].push(args.feeRecipients[i]);
        }
        allTokens.push(token);

        protocolFeesByQuote[address(0)] += creationFeeWei;

        // Pull the market's liquidity from its backer before anything else moves. Any failure
        // here reverts the whole transaction, so nothing below can run against funds not held.
        _safeTransferFrom(token, msg.sender, address(this), args.tokenSeedRaw);
        if (args.quoteToken != address(0)) {
            _safeTransferFrom(args.quoteToken, msg.sender, address(this), args.quoteSeedRaw);
        }

        // The guard cap is denominated against what the pool ACTUALLY holds, in raw units:
        // a `maxBuyBps` share of the committed float at the committed backing ratio. Exactly the
        // semantics `_buildPoolConfig` gives the instant path ("the cap is a share of the float"),
        // reached without assuming either currency has 18 decimals.
        uint256 maxBuyWeiCap = 0;
        if (params.maxBuyBps != 0) {
            maxBuyWeiCap =
                V4PoolMath.mulDiv((args.tokenSeedRaw * params.maxBuyBps) / BPS, args.quoteSeedRaw, args.tokenSeedRaw);
            if (maxBuyWeiCap > type(uint96).max) maxBuyWeiCap = type(uint96).max;
        }

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(args.quoteToken),
            currency1: Currency.wrap(token),
            fee: DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        (uint256 quoteUsed, uint256 tokensUsed, PoolId poolId) = HookrLaunchpadLib.openPoolSimple(
            poolManager,
            hook,
            key,
            _poolConfigWithGuardCap(params, args.blueprintId, uint96(maxBuyWeiCap)),
            sqrtPriceX96,
            token,
            args.quoteSeedRaw,
            args.tokenSeedRaw
        );
        l.graduated = true;
        l.graduatedAtBlock = uint40(block.number);
        l.sqrtPriceX96AtGraduation = sqrtPriceX96;
        l.poolId = poolId;
        l.reserveWei = 0;

        // Residue refunds + receipt linked out for EIP-170; see HookrLaunchpadLib.settleAttach.
        HookrLaunchpadLib.settleAttach(
            token,
            msg.sender,
            args.quoteToken,
            l.poolId,
            sqrtPriceX96,
            args.quoteSeedRaw,
            quoteUsed,
            args.tokenSeedRaw,
            tokensUsed
        );
    }

    function _checkIntent(bytes32 intentId) internal view {
        if (intentId == bytes32(0)) revert ZeroLaunchIntent();
        address existingToken = launchedByIntent[msg.sender][intentId];
        if (existingToken != address(0)) {
            revert LaunchIntentAlreadyUsed(msg.sender, intentId, existingToken);
        }
    }

    function _recordIntent(bytes32 intentId, address token) internal {
        launchedByIntent[msg.sender][intentId] = token;
        emit LaunchIntentConsumed(msg.sender, intentId, token);
    }

    function _launch(LaunchArgs calldata args) internal returns (address token) {
        if (args.targetRaiseWei < MIN_TARGET || args.targetRaiseWei > MAX_TARGET) revert TargetOutOfRange();
        // p0 from the requested raise: target = 80e6 * sum_{k=0}^{9} p0 * 1.7^k
        (uint96 p0, uint96 exactTarget) = HookrLaunchpadLib.curveParams(args.targetRaiseWei);
        if (p0 == 0) revert TargetOutOfRange();

        Launch storage l;
        (token, l) = _create(args, p0, exactTarget);

        if (args.creatorBuyWei > 0) {
            _executeBuy(token, l, args.creatorBuyWei, args.minTokensOut);
        }
    }

    function _launchInstant(LaunchArgs calldata args, uint16 poolSupplyBps) internal returns (address token) {
        // Nothing about a curve applies here, so refuse to accept curve arguments rather than
        // ignore them: a creator who passes a raise target has misunderstood which path they are on.
        if (args.targetRaiseWei != 0 || args.minTokensOut != 0) revert BadLaunchArgs();

        uint256 quoteIn = args.creatorBuyWei;
        (uint256 tokensForPool, uint96 openPriceWei, uint160 sqrtPriceX96,, uint8 err) =
            HookrLaunchpadLib.instantPlan(quoteIn, poolSupplyBps, SUPPLY, TICK_SPACING);
        // One plan, three named refusals: a dust or absurd deposit, a share of supply outside the
        // band that keeps the opening valuation sane, and a price that is too coarse, not
        // representable, or outside what a full-range position can actually hold.
        if (err == HookrLaunchpadLib.PLAN_BAD_ETH) revert InstantEthOutOfRange();
        if (err == HookrLaunchpadLib.PLAN_BAD_SHARE) revert PoolShareOutOfRange();
        if (err != HookrLaunchpadLib.PLAN_OK) revert OpenPriceOutOfRange();

        Launch storage l;
        // `basePriceWei` is the opening price and `targetWei` the ETH raised — the same meanings
        // both fields carry on the curve path, reached without a curve.
        // casting to 'uint96' is safe: a plan with `err == PLAN_OK` has already bounded `quoteIn`
        // to MAX_TARGET, which is itself a uint96.
        // forge-lint: disable-next-line(unsafe-typecast)
        (token, l) = _create(args, openPriceWei, uint96(quoteIn));

        if (l.quoteToken != address(0) && quoteIn > 0) {
            _safeTransferFrom(l.quoteToken, msg.sender, address(this), quoteIn);
        }

        // The cap basis is `tokensForPool`, NOT `SUPPLY`: here the creator picks the float, so a
        // supply-denominated cap would silently mean something different at every float — and
        // weakest exactly where the pool is thinnest.
        (uint256 quoteUsed,) = _openPool(
            token,
            l,
            _buildPoolConfig(l.hookParams, l.blueprintId, openPriceWei, tokensForPool),
            sqrtPriceX96,
            quoteIn,
            tokensForPool,
            SUPPLY
        );
        // Sub-ppm rounding residue on the quote side. Unlike a graduation reserve this is the
        // creator's own deposit and was never anyone else's fee, so it goes back to them rather
        // than to protocol fees.
        if (quoteIn > quoteUsed) {
            _sendQuote(l.quoteToken, msg.sender, quoteIn - quoteUsed);
        }

        emit InstantLaunched(token, l.poolId, poolSupplyBps, openPriceWei, quoteUsed);
    }

    /// @dev Everything both launch paths do before their prices diverge: validate, mint the fixed
    ///      supply, and record the launch. Returns the storage pointer so the caller can drive the
    ///      curve or open the pool without a second lookup.
    function _create(LaunchArgs calldata args, uint96 basePriceWei, uint96 targetWei)
        internal
        returns (address token, Launch storage l)
    {
        if (args.expectedCreator == address(0) || msg.sender != args.expectedCreator) {
            revert UnexpectedCreator(args.expectedCreator, msg.sender);
        }
        if (address(hook) == address(0)) revert HookNotSet();
        if (bytes(args.name).length == 0 || bytes(args.name).length > 48) revert BadLaunchArgs();
        if (bytes(args.symbol).length == 0 || bytes(args.symbol).length > 12) revert BadLaunchArgs();
        if (bytes(args.tagline).length > 160) revert BadLaunchArgs();
        if (bytes(args.logoURI).length > 300) revert BadLaunchArgs();
        uint256 expectedNativePayment =
            uint256(creationFeeWei) + (args.quoteToken == address(0) ? args.creatorBuyWei : 0);
        if (msg.value != expectedNativePayment) revert InsufficientPayment();
        _validateDistribution(args);

        HookrLaunchpadLib.HookParams memory params = _resolveParams(args.blueprintId, args.custom);

        token = HookrLaunchpadLib.deployToken(args.name, args.symbol, args.tagline, args.logoURI, msg.sender, SUPPLY);
        if (args.quoteToken != address(0)) {
            if (args.quoteToken == token || args.quoteToken.code.length == 0) {
                revert BadLaunchArgs();
            }
        }

        l = launches[token];
        l.token = token;
        l.creator = msg.sender;
        l.quoteToken = args.quoteToken;
        l.launchBlock = uint40(block.number);
        l.blueprintId = args.blueprintId;
        l.basePriceWei = basePriceWei;
        l.targetWei = targetWei;
        l.hookParams = params;
        // Persisted before any buy can graduate the curve — or before the instant path opens its
        // pool — in this same transaction.
        if (args.creatorFeeBps != 0) creatorFeeBpsOf[token] = args.creatorFeeBps;
        for (uint256 i; i < args.feeRecipients.length; ++i) {
            feeRecipientsOf[token].push(args.feeRecipients[i]);
        }
        for (uint256 i; i < args.lpTranches.length; ++i) {
            lpTranchesOf[token].push(args.lpTranches[i]);
        }
        allTokens.push(token);

        protocolFeesByQuote[address(0)] += creationFeeWei;

        emit TokenLaunched(token, msg.sender, args.blueprintId, args.name, args.symbol, targetWei, basePriceWei);
    }

    /// @notice Exactly what `launchInstant` would do with these inputs, and `err == 0` iff it
    ///         would succeed. The creator is choosing an opening valuation, so `openFdvWei` — not
    ///         a tick, and not a sqrt price — is the number to put in front of them before they
    ///         sign. `err` is `HookrLaunchpadLib.PLAN_BAD_ETH` / `_SHARE` / `_PRICE`, which map
    ///         one-for-one onto this contract's `InstantEthOutOfRange`, `PoolShareOutOfRange` and
    ///         `OpenPriceOutOfRange`.
    function previewInstantLaunch(uint256 ethIn, uint16 poolSupplyBps)
        external
        pure
        returns (uint256 tokensInPool, uint96 openPriceWei, uint160 sqrtPriceX96, uint256 openFdvWei, uint8 err)
    {
        return HookrLaunchpadLib.instantPlan(ethIn, poolSupplyBps, SUPPLY, TICK_SPACING);
    }

    // ---------------------------------------------------------------- curve trading

    function buy(address token, uint256 minTokensOut) external payable nonReentrant {
        Launch storage l = _launchOf(token);
        if (l.graduated) revert AlreadyGraduated();
        if (l.quoteToken != address(0) && msg.value != 0) revert UnexpectedNativeValue();
        _executeBuy(token, l, msg.value, minTokensOut);
    }

    function sell(address token, uint256 tokenAmount, uint256 minEthOut) external nonReentrant {
        Launch storage l = _launchOf(token);
        if (l.graduated) revert AlreadyGraduated();
        if (tokenAmount == 0) revert ZeroAmount();

        (uint256 grossOut, uint128 newSold) = _walkDown(l, tokenAmount);
        uint256 fee = (grossOut * CURVE_FEE_BPS) / BPS;
        uint256 payout = grossOut - fee;
        if (payout == 0 || payout < minEthOut) revert SlippageExceeded();

        l.soldTokens = newSold;
        l.reserveWei = uint96(uint256(l.reserveWei) - grossOut);
        _splitCurveFee(token, fee);

        // Pull tokens back onto the curve, then pay out (state already updated).
        HookrToken(token).transferFrom(msg.sender, address(this), tokenAmount);
        _sendQuote(l.quoteToken, msg.sender, payout);

        emit CurveSell(token, msg.sender, tokenAmount, payout, l.reserveWei, l.soldTokens);
    }

    function _executeBuy(address token, Launch storage l, uint256 valueWei, uint256 minTokensOut) internal {
        if (l.soldTokens >= CURVE_SUPPLY) revert CurveSoldOut();

        if (l.quoteToken != address(0) && valueWei > 0) {
            _safeTransferFrom(l.quoteToken, msg.sender, address(this), valueWei);
        }

        // Reserve up to 1% for the curve fee; the walk decides how much ETH the curve can absorb.
        uint256 maxNet = (valueWei * (BPS - CURVE_FEE_BPS)) / BPS;
        (uint256 tokensOut, uint256 ethUsed, uint128 newSold) = _walkUp(l, maxNet);
        if (tokensOut == 0 || tokensOut < minTokensOut) revert SlippageExceeded();

        uint256 fee = (ethUsed * CURVE_FEE_BPS) / BPS;
        uint96 newReserveWei = uint96(uint256(l.reserveWei) + ethUsed);
        l.soldTokens = newSold;
        l.reserveWei = newReserveWei;
        _splitCurveFee(token, fee);

        // Payout + receipt linked out for EIP-170; see HookrLaunchpadLib.settleCurveBuy.
        HookrLaunchpadLib.settleCurveBuy(
            token, msg.sender, l.quoteToken, tokensOut, valueWei, ethUsed, fee, newReserveWei, newSold
        );

        if (newSold >= CURVE_SUPPLY) {
            _graduateAndOpen(token, l);
        }
    }

    function _splitCurveFee(address token, uint256 fee) internal {
        uint256 half = fee / 2;
        creatorFeesWei[token] += half;
        // Native fees are stored under the address(0) key like any other quote currency.
        protocolFeesByQuote[launches[token].quoteToken] += fee - half;
    }

    /// @dev Storage-reading shims over the linked curve math. The launch's `soldTokens` and
    ///      `basePriceWei` are the only state the walk ever consumed.
    function _walkUp(Launch storage l, uint256 maxNet)
        internal
        view
        returns (uint256 tokensOut, uint256 ethUsed, uint128 newSold)
    {
        return HookrLaunchpadLib.walkUp(l.soldTokens, l.basePriceWei, maxNet);
    }

    function _walkDown(Launch storage l, uint256 tokenAmount)
        internal
        view
        returns (uint256 grossOut, uint128 newSold)
    {
        // The bound check stays here so `SlippageExceeded` keeps being raised by this contract.
        if (tokenAmount > l.soldTokens) revert SlippageExceeded();
        return HookrLaunchpadLib.walkDown(l.soldTokens, l.basePriceWei, tokenAmount);
    }

    // ---------------------------------------------------------------- curve math

    // ---------------------------------------------------------------- graduation

    /// @notice Curve sold out: convert the reserve + remaining supply into the pool, continuing
    ///         exactly where the curve ended. Single caller: the sold-out branch of
    ///         `_executeBuy`. Kept as its own internal so the big open sequence exists once.
    function _graduateAndOpen(address token, Launch storage l) internal {
        // Price + float plan linked out for EIP-170; see HookrLaunchpadLib.graduatePlan. The pool
        // price continues exactly where the curve ended.
        (uint256 pFinal, uint160 sqrtPriceX96, uint256 tokensForPool) =
            HookrLaunchpadLib.graduatePlan(l.basePriceWei, l.reserveWei, SUPPLY - CURVE_SUPPLY);
        uint256 reserve = l.reserveWei;

        // `SUPPLY` as the cap basis is the live constant, deliberately unchanged: every deployed
        // pool was configured with it and graduation always places a near-fixed share of supply,
        // so the setting already means what a creator reads it to mean on this path.
        (uint256 ethUsed,) = _openPool(
            token,
            l,
            _buildPoolConfig(l.hookParams, l.blueprintId, pFinal, SUPPLY),
            sqrtPriceX96,
            reserve,
            tokensForPool,
            SUPPLY - CURVE_SUPPLY
        );
        if (reserve > ethUsed) {
            protocolFeesByQuote[l.quoteToken] += reserve - ethUsed;
        }
    }

    /// @notice Opens the pool a launch ends in, and seeds the ONE position it will ever have.
    /// @dev Shared verbatim by graduation, `launchInstant`, and existing-token attach; the three
    ///      paths differ only in how they arrive at a price, at the config, and at the amounts,
    ///      never in what happens to the liquidity.
    ///
    ///      LOCKED BY CONSTRUCTION. The only `modifyLiquidity` this contract can ever reach are
    ///      the three encoded here and in `collectPoolFees`: `CB_GRADUATE` and `CB_TRANCHE` mint
    ///      positive liquidity, `CB_COLLECT` passes a delta of exactly zero. There is no fourth,
    ///      and no function on this contract — owner-gated or otherwise — takes a negative
    ///      liquidity delta. Adding the instant and attach paths added no new PoolManager
    ///      interaction at all.
    ///
    /// @param cfg The exact pool behavior, already built by the caller: `_buildPoolConfig` on the
    ///        two native paths, `_poolConfigWithGuardCap` on attach (whose cap is decimals-free).
    /// @param tokensAvailable Every token this contract holds for the launch. Whatever the
    ///        position does not absorb funds the optional token-only bands, and the rest burns.
    ///        Attach always passes exactly what it placed, so nothing it pulled can ever burn.
    /// @return quoteUsed The quote currency the position actually took.
    /// @return tokensUsed The base token the position actually took.
    function _openPool(
        address token,
        Launch storage l,
        HookrHook.PoolConfig memory cfg,
        uint160 sqrtPriceX96,
        uint256 quoteForPool,
        uint256 tokensForPool,
        uint256 tokensAvailable
    ) internal returns (uint256 quoteUsed, uint256 tokensUsed) {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(l.quoteToken),
            currency1: Currency.wrap(token),
            fee: DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        // Configure, initialize, seed the locked full-range position, place the optional bands,
        // and burn the remainder. Linked out for EIP-170; it runs by DELEGATECALL, so the
        // launchpad is still the initializer, the callback target, and the position's owner --
        // and every event still carries the launchpad as its emitter.
        HookrLaunchpadLib.LpTranche[] memory bands = lpTranchesOf[token];
        PoolId poolId;
        (quoteUsed, tokensUsed, poolId) = HookrLaunchpadLib.openPool(
            poolManager, hook, key, cfg, sqrtPriceX96, token, quoteForPool, tokensForPool, tokensAvailable, bands
        );

        l.graduated = true;
        l.graduatedAtBlock = uint40(block.number);
        l.sqrtPriceX96AtGraduation = sqrtPriceX96;
        l.poolId = poolId;
        l.reserveWei = 0;
    }

    /// @notice The exact `PoolConfig` the two native launch paths hand the hook. The 1e18
    ///         division is their 18-decimal token assumption; attach derives its cap from raw
    ///         amounts instead and calls `_poolConfigWithGuardCap` directly.
    function _buildPoolConfig(
        HookrLaunchpadLib.HookParams memory p,
        uint32 blueprintId,
        uint256 pFinal,
        uint256 capTokens
    ) internal view returns (HookrHook.PoolConfig memory cfg) {
        uint256 maxBuyWei = 0;
        if (p.maxBuyBps != 0) {
            maxBuyWei = (((capTokens * p.maxBuyBps) / BPS) * pFinal) / 1e18;
            if (maxBuyWei > type(uint96).max) maxBuyWei = type(uint96).max;
        }
        // casting to 'uint96' is safe: clamped on the line above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return _poolConfigWithGuardCap(p, blueprintId, uint96(maxBuyWei));
    }

    /// @dev Everything `_buildPoolConfig` does except derive `maxBuyWei`, which arrives already
    ///      computed so attach can express the guard cap in raw quote units of ANY currency pair.
    ///      Royalty lookup is the only storage read; the struct build is linked out for EIP-170.
    function _poolConfigWithGuardCap(HookrLaunchpadLib.HookParams memory p, uint32 blueprintId, uint96 maxBuyWei)
        internal
        view
        returns (HookrHook.PoolConfig memory cfg)
    {
        uint16 royaltyBps;
        address royaltyTo;
        if (blueprintId != 0) {
            (royaltyBps, royaltyTo) = blueprints.feeSplitOf(blueprintId);
        }
        return HookrLaunchpadLib.poolConfigWithGuardCap(p, royaltyBps, royaltyTo, maxBuyWei);
    }

    // ---------------------------------------------------------------- locked-POL fee collection

    /// @notice Collect LP fees earned by the locked full-range position. ETH side splits
    ///         creator/protocol; the token side is burned. Callable by anyone.
    function collectPoolFees(address token) external nonReentrant {
        Launch storage l = _launchOf(token);
        if (!l.graduated) revert NotGraduated();

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(l.quoteToken),
            currency1: Currency.wrap(token),
            fee: DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        // Full-range position plus every seeded band, poked range by range. Linked out for
        // EIP-170; see HookrLaunchpadLib.collectAllBands for the skip rules.
        (uint256 quoteAmount, uint256 tokenAmount) = HookrLaunchpadLib.collectAllBands(
            poolManager, key, l.poolId, lpTranchesOf[token], l.sqrtPriceX96AtGraduation
        );

        if (quoteAmount > 0) {
            address quoteToken = l.quoteToken;
            // Fees the position earned while the anti-snipe guard was live are PROTOCOL-ONLY.
            // The snipe tax is charged as an LP fee, and the hook blocks outside LP additions for
            // the finite guard window so the launchpad's locked positions own that fee growth.
            // Without this withholding the tax flows back to the creator at `creatorFeeBps` — and
            // the creator is a party who can pay it, in the launch transaction on the instant path.
            // `guardFeesWithheldWei` is the high-water mark so the same wei is never withheld twice.
            (uint256 withheld, uint256 creatorSide) = HookrLaunchpadLib.splitCollectionFees(
                quoteAmount, hook.guardLpEarnedWei(l.poolId), guardFeesWithheldWei[token], _creatorFeeBps(token)
            );
            if (withheld > 0) guardFeesWithheldWei[token] += withheld;
            protocolFeesByQuote[quoteToken] += quoteAmount - creatorSide;
            _creditCreatorSide(token, creatorSide);
        }
        emit PoolFeesCollected(token, quoteAmount, tokenAmount);
    }

    /// @notice The creator's configured share of pool fees, in bps. Unset means the default.
    function _creatorFeeBps(address token) internal view returns (uint16) {
        uint16 configured = creatorFeeBpsOf[token];
        return configured == 0 ? DEFAULT_CREATOR_FEE_BPS : configured;
    }

    /// @notice Splits the creator side across configured recipients, or credits the creator.
    /// @dev The remainder from integer division goes to the last recipient so the sum of the
    ///      credited amounts equals `amount` exactly — fees can never be stranded by rounding.
    function _creditCreatorSide(address token, uint256 amount) internal {
        if (amount == 0) return;
        HookrLaunchpadLib.FeeRecipient[] storage recipients = feeRecipientsOf[token];
        uint256 n = recipients.length;
        if (n == 0) {
            creatorFeesWei[token] += amount;
            return;
        }
        uint256 distributed;
        for (uint256 i; i < n; ++i) {
            uint256 share = i + 1 == n ? amount - distributed : (amount * recipients[i].bps) / BPS;
            distributed += share;
            if (share == 0) continue;
            address to = recipients[i].to;
            splitFeesWei[token][to] += share;
            emit FeeSplitCredited(token, to, share);
        }
    }

    /// @notice Claim fees credited to a split recipient. Anyone may push a recipient's own
    ///         balance to them; the destination is always the recipient recorded at launch.
    function claimSplitFees(address token, address recipient) external nonReentrant {
        Launch storage l = _launchOf(token);
        uint256 amount = splitFeesWei[token][recipient];
        if (amount == 0) revert NothingToClaim();
        splitFeesWei[token][recipient] = 0;
        _sendQuote(l.quoteToken, recipient, amount);
        emit CreatorFeesClaimed(token, recipient, amount);
    }

    /// @notice Read the configured split for a launch.
    function getFeeRecipients(address token) external view returns (HookrLaunchpadLib.FeeRecipient[] memory) {
        return feeRecipientsOf[token];
    }

    /// @notice Read the configured LP bands for a launch.
    function getLpTranches(address token) external view returns (HookrLaunchpadLib.LpTranche[] memory) {
        return lpTranchesOf[token];
    }

    /// @notice Nominate where this token's creator fees are paid. Only the creator may set it;
    ///         ownership of the fees never moves, only the delivery address. Setting address(0)
    ///         restores the default (the creator). Exists so a creator whose address cannot
    ///         receive ETH — a contract with no payable fallback, a lost key — is not locked out.
    function setCreatorPayout(address token, address to) external {
        Launch storage l = _launchOf(token);
        if (msg.sender != l.creator) revert NotCreator();
        creatorPayout[token] = to;
        emit CreatorPayoutSet(token, to);
    }

    /// @notice Where `claimCreatorFees` will send this token's creator fees.
    function creatorPayoutOf(address token) public view returns (address) {
        address to = creatorPayout[token];
        return to == address(0) ? launches[token].creator : to;
    }

    /// @notice Claim accrued creator-side fees (curve fees + collected pool fees) for a token.
    function claimCreatorFees(address token) external nonReentrant {
        Launch storage l = _launchOf(token);
        uint256 amount = creatorFeesWei[token];
        if (amount == 0) revert NothingToClaim();
        creatorFeesWei[token] = 0;
        address to = creatorPayoutOf(token);
        _sendQuote(l.quoteToken, to, amount);
        emit CreatorFeesClaimed(token, to, amount);
    }

    // ---------------------------------------------------------------- unlock callback

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        // Each action carries its own payload shape; decode the selector first so a range-bearing
        // action cannot be misread as the full-range one.
        uint8 action = abi.decode(data[:32], (uint8));

        if (action == CB_TRANCHE) {
            (, PoolKey memory tKey, int24 tLower, int24 tUpper, uint256 tAmount) =
                abi.decode(data, (uint8, PoolKey, int24, int24, uint256));
            // Entirely above spot, so the band is funded with token1 alone. Minting and settling
            // are linked out for EIP-170 and run by DELEGATECALL, so the position is still the
            // launchpad's and the tokens still come from the launchpad's own balance.
            (uint256 oweT, uint256 oweE) = HookrLaunchpadLib.mintBand(poolManager, tKey, tLower, tUpper, tAmount);
            // A band above spot must never draw ETH; if it somehow would, that is a bug and the
            // graduation should revert rather than spend the raise. The check stays HERE so
            // `BadLpPlan` keeps being raised by this contract.
            if (oweE > 0) revert BadLpPlan();
            return abi.encode(oweT);
        }

        (, PoolKey memory key, uint160 sqrtPriceX96, uint256 amount0, uint256 amount1) =
            abi.decode(data, (uint8, PoolKey, uint160, uint256, uint256));

        // The mechanics of both remaining actions are linked out for EIP-170 and run by
        // DELEGATECALL; the launchpad stays the unlock callback target and the position owner.
        if (action == CB_GRADUATE) {
            (uint256 oweCurrency0, uint256 oweCurrency1) =
                HookrLaunchpadLib.graduateFullRange(poolManager, key, sqrtPriceX96, amount0, amount1);
            return abi.encode(oweCurrency0, oweCurrency1);
        }
        if (action == CB_COLLECT) {
            (uint256 token0Owed, uint256 token1Owed) =
                HookrLaunchpadLib.collectPosition(poolManager, key, amount0, amount1);
            return abi.encode(token0Owed, token1Owed);
        }

        revert BadCallback();
    }

    // ---------------------------------------------------------------- validation
    // The validator bodies are linked out for EIP-170 and run by DELEGATECALL; the launchpad
    // keeps only the call stubs. Custom-error selectors are name-derived, so reverts raised in
    // the library carry exactly the selectors these entrypoints have always surfaced.

    function _validateDistribution(LaunchArgs calldata args) internal pure {
        HookrLaunchpadLib.validateFeeSplit(args.creatorFeeBps, args.feeRecipients);
        HookrLaunchpadLib.validateLpPlan(args.lpTranches);
    }

    function _validateFeeSplit(uint16 creatorFeeBps, HookrLaunchpadLib.FeeRecipient[] calldata recipients)
        internal
        pure
    {
        HookrLaunchpadLib.validateFeeSplit(creatorFeeBps, recipients);
    }

    /// @notice Blueprint resolution for every market path. Id 0 means "use the caller's custom
    ///         stack" (validated here); anything else is validated at SAVE time by the registry,
    ///     which also bumps its use counter. Unknown ids revert inside the registry.
    function _resolveParams(uint32 blueprintId, HookrLaunchpadLib.HookParams calldata custom)
        internal
        returns (HookrLaunchpadLib.HookParams memory params)
    {
        if (blueprintId == 0) {
            params = custom;
            HookrLaunchpadLib.validateHookParams(params);
        } else {
            (,, params) = blueprints.resolveForLaunch(blueprintId);
        }
    }

    // ---------------------------------------------------------------- views

    function _launchOf(address token) internal view returns (Launch storage l) {
        l = launches[token];
        if (l.token == address(0)) revert UnknownToken();
    }

    function getLaunch(address token) external view returns (Launch memory) {
        return launches[token];
    }

    function tokensCount() external view returns (uint256) {
        return allTokens.length;
    }

    /// @notice Paginated newest-first token listing for the UI.
    function tokensPage(uint256 offset, uint256 limit) external view returns (address[] memory page) {
        uint256 n = allTokens.length;
        if (offset >= n) return new address[](0);
        uint256 count = n - offset < limit ? n - offset : limit;
        page = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            page[i] = allTokens[n - 1 - offset - i];
        }
    }

    /// @notice Current marginal curve price (wei per whole token); 0 once graduated.
    function currentCurvePrice(address token) external view returns (uint256) {
        Launch storage l = _launchOf(token);
        if (l.graduated || l.soldTokens >= CURVE_SUPPLY) return 0;
        return HookrLaunchpadLib.tranchePrice(l.basePriceWei, uint256(l.soldTokens) / TRANCHE_TOKENS);
    }

    /// @notice Quote a curve buy: tokens received and ETH actually consumed for `valueWei` sent.
    function quoteBuy(address token, uint256 valueWei) external view returns (uint256 tokensOut, uint256 totalCostWei) {
        Launch storage l = _launchOf(token);
        if (l.graduated || valueWei == 0) return (0, 0);
        uint256 maxNet = (valueWei * (BPS - CURVE_FEE_BPS)) / BPS;
        (uint256 out, uint256 ethUsed,) = _walkUp(l, maxNet);
        uint256 fee = (ethUsed * CURVE_FEE_BPS) / BPS;
        return (out, ethUsed + fee);
    }

    /// @notice Quote a curve sell: ETH received after the curve fee.
    function quoteSell(address token, uint256 tokenAmount) external view returns (uint256 ethOut) {
        Launch storage l = _launchOf(token);
        if (l.graduated || tokenAmount == 0 || tokenAmount > l.soldTokens) return 0;
        (uint256 gross,) = _walkDown(l, tokenAmount);
        return gross - (gross * CURVE_FEE_BPS) / BPS;
    }

    // ---------------------------------------------------------------- internal

    function _sendQuote(address quoteToken, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (quoteToken == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            HookrLaunchpadLib.safeTransfer(quoteToken, to, amount);
        }
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        HookrLaunchpadLib.safeTransferFrom(token, from, to, amount);
    }
}
