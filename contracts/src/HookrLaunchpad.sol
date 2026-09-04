// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {HookrToken} from "./HookrToken.sol";
import {HookrHook} from "./HookrHook.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
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
    /// @dev Blueprint id 0 is the custom sentinel. Deployment seeds reviewed house blueprints
    ///      1..5 in later transactions, so those ids stay owner-only until all five exist.
    uint256 internal constant FIRST_PUBLIC_BLUEPRINT_ID = 6;
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
    address public owner;
    address public pendingOwner; // two-step handover; see proposeOwner/acceptOwnership
    HookrHook public hook; // set once by owner after CREATE2 mining
    uint96 public creationFeeWei = 0.0002 ether;

    // ---------------------------------------------------------------- types

    /// @notice Creator-facing hook configuration — mirrors the builder blocks.
    struct HookParams {
        // ANTI-SNIPE
        uint32 guardBlocks; // 0 = block disabled
        uint16 maxBuyBps; // max buy per swap during guard, in bps of total supply (0 = uncapped)
        uint24 snipeTaxPips; // extra LP fee during guard
        // FEES (base always applies; maxFee > base enables surge)
        uint24 baseFeePips;
        uint24 maxFeePips; // 0 means "no surge block stacked" and normalizes to baseFeePips
        uint16 surgeSens; // 1-10
        // AUTO BURN (legacy field names retained in the ABI)
        uint16 burnBps;
        uint96 burnTriggerWei; // deprecated v2 field; custom configs MUST set this to zero
        // LP REWARDS
        uint16 lpBps;
        // JACKPOT
        uint16 potBps;
        uint32 potEveryNBuys; // every Nth qualifying buy wins the pot (deterministic, not random)
        uint96 potMinBuyWei;
    }

    struct Blueprint {
        address author;
        uint16 royaltyBps; // share of native LP/pot cuts routed to the author
        uint32 uses;
        uint40 savedAtBlock;
        string name;
        HookParams params;
    }

    /// @notice A share of the creator side of pool fees. `bps` values must sum to exactly BPS.
    /// @dev Splitting happens at collection, so a recipient's balance is credited even if the
    ///      creator never calls anything; nobody can redirect an already-credited balance.
    struct FeeRecipient {
        address to;
        uint16 bps;
    }

    /// @notice One token-only liquidity band sitting above the graduation *price*.
    /// @dev The pool is ETH/token with ETH as currency0, so its price is tokens-per-ETH: a
    ///      HIGHER token price is a LOWER tick. A band that only ever sells tokens therefore
    ///      lives strictly BELOW the graduation tick, and both offsets are expressed as ticks
    ///      below it — `startOffset` nearest the launch price, `endOffset` furthest above it.
    ///      Bands are funded from the pool tokens the full-range position could not absorb —
    ///      tokens that are otherwise burned — so tranching never touches the ETH raise or the
    ///      base position's economics.
    struct LpTranche {
        int24 startOffset; // ticks below the graduation tick where the band begins
        int24 endOffset; // ticks below the graduation tick where it ends; > startOffset
        uint16 bps; // share of the leftover token allocation
    }

    struct Launch {
        address token;
        address creator;
        uint40 launchBlock;
        uint32 blueprintId; // 0 = custom stack
        bool graduated;
        uint96 basePriceWei; // p0: wei per whole token in tranche 0
        uint96 targetWei; // exact curve proceeds at full sale
        uint96 reserveWei; // ETH currently backing the curve
        uint128 soldTokens;
        uint40 graduatedAtBlock;
        uint160 sqrtPriceX96AtGraduation;
        PoolId poolId;
        HookParams hookParams;
    }

    mapping(address => Launch) internal launches;
    address[] public allTokens;
    Blueprint[] internal blueprints;

    /// @notice Successful intent-bound launches, namespaced by the transaction sender.
    /// @dev A nonzero token address is both the replay marker and the launch postcondition.
    mapping(address creator => mapping(bytes32 intentId => address token)) public launchedByIntent;

    // fee accruals (pull payments)
    uint256 public protocolFeesWei;
    mapping(address => uint256) public creatorFeesWei; // token => accrued creator fees
    /// token => creator's share of pool fees in bps. 0 means DEFAULT_CREATOR_FEE_BPS.
    mapping(address => uint16) public creatorFeeBpsOf;
    /// token => split of the creator side. Empty means the whole creator side goes to the creator.
    mapping(address => FeeRecipient[]) internal feeRecipientsOf;
    /// token => extra token-only bands seeded above the graduation price.
    mapping(address => LpTranche[]) internal lpTranchesOf;
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

    event TokenLaunched(
        address indexed token,
        address indexed creator,
        uint32 indexed blueprintId,
        string name,
        string symbol,
        string tagline,
        string logoURI,
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
    event BlueprintSaved(uint32 indexed id, address indexed author, string name, uint16 royaltyBps);
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
    error NotPoolManager();
    error BadCallback();
    error NothingToClaim();
    error FeeTooHigh();
    error RoyaltyTooHigh();
    error HouseBlueprintsPending();

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

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
        owner = msg.sender;
        // Blueprint id 0 is the "custom stack" sentinel.
        blueprints.push();
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

    function withdrawProtocolFees(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = protocolFeesWei;
        if (amount == 0) revert NothingToClaim();
        protocolFeesWei = 0;
        _sendEth(to, amount);
        emit ProtocolFeesWithdrawn(to, amount);
    }

    // ---------------------------------------------------------------- blueprints

    function saveBlueprint(string calldata name, HookParams calldata params, uint16 royaltyBps)
        external
        returns (uint32 id)
    {
        // The launchpad CREATE and five blueprint saves cannot be one transaction in the release
        // script. Reserve the reviewed house ids so a public mempool transaction cannot take one
        // between deployment and seeding. Once ids 1..5 exist, blueprint authoring is permissionless.
        if (blueprints.length < FIRST_PUBLIC_BLUEPRINT_ID && msg.sender != owner) {
            revert HouseBlueprintsPending();
        }
        if (bytes(name).length == 0 || bytes(name).length > 48) revert BadLaunchArgs();
        if (royaltyBps > 1000) revert RoyaltyTooHigh();
        _validateHookParams(params);
        // Auto Burn, anti-snipe, and surge fees do not create a native hook cut. Reject a
        // royalty that could never accrue instead of letting a blueprint advertise phantom
        // economics. LP and pot cuts are the only revenue-bearing Hookr blocks in v3.
        if (royaltyBps > 0 && uint256(params.lpBps) + params.potBps == 0) {
            revert BadHookParams();
        }
        id = uint32(blueprints.length);
        blueprints.push(
            Blueprint({
                author: msg.sender,
                royaltyBps: royaltyBps,
                uses: 0,
                savedAtBlock: uint40(block.number),
                name: name,
                params: params
            })
        );
        emit BlueprintSaved(id, msg.sender, name, royaltyBps);
    }

    function blueprintsCount() external view returns (uint256) {
        return blueprints.length;
    }

    function getBlueprint(uint32 id) external view returns (Blueprint memory) {
        return blueprints[id];
    }

    // ---------------------------------------------------------------- launch

    struct LaunchArgs {
        string name;
        string symbol;
        string tagline;
        string logoURI;
        address expectedCreator; // binds approved calldata to the transaction sender
        uint96 targetRaiseWei;
        uint32 blueprintId; // 0 = use `custom`
        HookParams custom;
        uint256 creatorBuyWei; // optional first buy, included in msg.value after the creation fee
        uint256 minTokensOut; // slippage guard for the creator buy
        uint16 creatorFeeBps; // 0 = DEFAULT_CREATOR_FEE_BPS; capped at MAX_CREATOR_FEE_BPS
        FeeRecipient[] feeRecipients; // empty = the whole creator side goes to the creator
        LpTranche[] lpTranches; // empty = full range only; leftover pool tokens burn as before
    }

    /// @notice Launches through the ordinary permissionless path.
    /// @dev Identical calls remain repeatable by design; agent approval packets should use
    ///      `launchWithIntent` for contract-enforced replay protection.
    function launch(LaunchArgs calldata args) external payable nonReentrant returns (address token) {
        token = _launch(args);
    }

    /// @notice Launches exactly once for a creator-scoped, nonzero intent identifier.
    /// @dev The mapping stores the resulting token rather than a boolean so agents can reconcile
    ///      a mined receipt against an onchain postcondition. Every revert rolls the marker back.
    function launchWithIntent(LaunchArgs calldata args, bytes32 intentId)
        external
        payable
        nonReentrant
        returns (address token)
    {
        _checkIntent(intentId);
        token = _launch(args);
        _recordIntent(intentId, token);
    }

    /// @notice Launch straight into a live Uniswap v4 pool. No bonding curve, no graduation step:
    ///         the pool exists and trades in this transaction, and its liquidity is the same
    ///         locked, launchpad-owned full-range position graduation would have produced.
    ///
    /// @param args The same `LaunchArgs` the curve path takes. `creatorBuyWei` is the ETH that
    ///        seeds the pool. `targetRaiseWei` and `minTokensOut` describe a curve that does not
    ///        exist here and MUST be zero, so neither is silently ignored.
    /// @param poolSupplyBps The share of the fixed supply placed in the pool, in bps.
    ///
    /// @dev THIS IS THE PRICE CONTROL, and it is the whole design. The creator does not type a
    ///      price, a tick, or a sqrt price — they say how much ETH they are committing and how
    ///      much of the supply is tradeable, and the opening price falls out as
    ///      `creatorBuyWei / (SUPPLY * poolSupplyBps / BPS)`. Equivalently, and this is what the
    ///      creator is really choosing:
    ///
    ///          opening fully-diluted valuation = creatorBuyWei * BPS / poolSupplyBps
    ///
    ///      Two properties follow, and they are why this shape is hard to misuse:
    ///        - Every unit of price is backed by ETH the contract is holding right now. There is
    ///          no way to express a valuation and then not fund it, which is precisely the failure
    ///          a "creator types a price" parameterization invites — one misplaced zero there is a
    ///          10x mispricing seeded against real liquidity and arbitraged in the same block.
    ///        - `poolSupplyBps` is bounded to [MIN_POOL_SUPPLY_BPS, BPS], so the valuation is
    ///          bounded to [1x, 5x] the committed ETH. Both degenerate ends — a vanishing share
    ///          at an enormous price, and a price so low it stops being representable — are
    ///          unreachable rather than merely discouraged.
    ///
    ///      Supply not placed in the pool is burned to DEAD, or laddered into the configured
    ///      token-only bands. The launchpad hands the creator no ALLOCATION on this path, exactly
    ///      as on the curve path.
    ///
    ///      WHAT THAT DOES NOT MEAN. The pool is open in this same transaction, so the creator can
    ///      buy from it like anyone else, in the launch transaction, before anyone has seen the
    ///      token exists. That is not a bug to be apologised for, it is the shape of opening a
    ///      pool: whoever opens it trades first. The AMM reserves determine the execution price;
    ///      the anti-snipe guard is the launch-specific cap and tax on that first-block behavior.
    ///      On this path it is doing more work than on the curve path because there is no curve
    ///      phase in front of it. Configure it accordingly — a guard whose cap is a large share
    ///      of a thin float is decoration. See `HookrHook.beforeSwap`, where the
    ///      cap is accumulated per pool per block precisely so a loop of capped buys inside one
    ///      transaction cannot spend it repeatedly, and `collectPoolFees`, where fees earned
    ///      inside the guard window are withheld from the creator's share so the tax cannot be
    ///      rebated to the creator who paid it.
    function launchInstant(LaunchArgs calldata args, uint16 poolSupplyBps)
        external
        payable
        nonReentrant
        returns (address token)
    {
        token = _launchInstant(args, poolSupplyBps);
    }

    /// @notice `launchInstant`, launched exactly once per creator-scoped intent identifier.
    /// @dev An instant launch needs replay protection MORE than a curve launch, not less. A
    ///      re-broadcast curve launch mints a duplicate token whose ETH is still on a curve the
    ///      creator can sell back down; a re-broadcast instant launch also locks a second tranche
    ///      of their ETH into a second pool, permanently, with no removal path by construction.
    ///      It shares the curve path's `launchedByIntent` namespace deliberately: one intent
    ///      identifier means one token from this creator, whichever path consumed it.
    function launchInstantWithIntent(LaunchArgs calldata args, uint16 poolSupplyBps, bytes32 intentId)
        external
        payable
        nonReentrant
        returns (address token)
    {
        _checkIntent(intentId);
        token = _launchInstant(args, poolSupplyBps);
        _recordIntent(intentId, token);
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

        uint256 ethIn = args.creatorBuyWei;
        (uint256 tokensForPool, uint96 openPriceWei, uint160 sqrtPriceX96,, uint8 err) =
            HookrLaunchpadLib.instantPlan(ethIn, poolSupplyBps, SUPPLY, TICK_SPACING);
        // One plan, three named refusals: a dust or absurd deposit, a share of supply outside the
        // band that keeps the opening valuation sane, and a price that is too coarse, not
        // representable, or outside what a full-range position can actually hold.
        if (err == HookrLaunchpadLib.PLAN_BAD_ETH) revert InstantEthOutOfRange();
        if (err == HookrLaunchpadLib.PLAN_BAD_SHARE) revert PoolShareOutOfRange();
        if (err != HookrLaunchpadLib.PLAN_OK) revert OpenPriceOutOfRange();

        Launch storage l;
        // `basePriceWei` is the opening price and `targetWei` the ETH raised — the same meanings
        // both fields carry on the curve path, reached without a curve.
        // casting to 'uint96' is safe: a plan with `err == PLAN_OK` has already bounded `ethIn`
        // to MAX_TARGET, which is itself a uint96.
        // forge-lint: disable-next-line(unsafe-typecast)
        (token, l) = _create(args, openPriceWei, uint96(ethIn));

        // The cap basis is `tokensForPool`, NOT `SUPPLY`: here the creator picks the float, so a
        // supply-denominated cap would silently mean something different at every float — and
        // weakest exactly where the pool is thinnest.
        uint256 ethUsed = _openPool(token, l, openPriceWei, sqrtPriceX96, ethIn, tokensForPool, SUPPLY, tokensForPool);
        // Sub-ppm rounding residue on the ETH side. Unlike a graduation reserve this is the
        // creator's own deposit and was never anyone else's fee, so it goes back to them rather
        // than to `protocolFeesWei`.
        if (ethIn > ethUsed) _sendEth(msg.sender, ethIn - ethUsed);

        emit InstantLaunched(token, l.poolId, poolSupplyBps, openPriceWei, ethUsed);
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
        if (msg.value != uint256(creationFeeWei) + args.creatorBuyWei) revert InsufficientPayment();
        _validateDistribution(args);

        HookParams memory params;
        if (args.blueprintId == 0) {
            params = args.custom;
            _validateHookParams(params);
        } else {
            Blueprint storage bp = blueprints[args.blueprintId];
            if (bp.author == address(0)) revert BadLaunchArgs();
            params = bp.params;
            bp.uses += 1;
        }

        token = HookrLaunchpadLib.deployToken(args.name, args.symbol, args.tagline, args.logoURI, msg.sender, SUPPLY);

        l = launches[token];
        l.token = token;
        l.creator = msg.sender;
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

        protocolFeesWei += creationFeeWei;

        emit TokenLaunched(
            token,
            msg.sender,
            args.blueprintId,
            args.name,
            args.symbol,
            args.tagline,
            args.logoURI,
            targetWei,
            basePriceWei
        );
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
        if (msg.value == 0) revert ZeroAmount();
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
        _sendEth(msg.sender, payout);

        emit CurveSell(token, msg.sender, tokenAmount, payout, l.reserveWei, l.soldTokens);
    }

    function _executeBuy(address token, Launch storage l, uint256 valueWei, uint256 minTokensOut) internal {
        if (l.soldTokens >= CURVE_SUPPLY) revert CurveSoldOut();

        // Reserve up to 1% for the curve fee; the walk decides how much ETH the curve can absorb.
        uint256 maxNet = (valueWei * (BPS - CURVE_FEE_BPS)) / BPS;
        (uint256 tokensOut, uint256 ethUsed, uint128 newSold) = _walkUp(l, maxNet);
        if (tokensOut == 0 || tokensOut < minTokensOut) revert SlippageExceeded();

        uint256 fee = (ethUsed * CURVE_FEE_BPS) / BPS;
        l.soldTokens = newSold;
        l.reserveWei = uint96(uint256(l.reserveWei) + ethUsed);
        _splitCurveFee(token, fee);

        HookrToken(token).transfer(msg.sender, tokensOut);

        uint256 refund = valueWei - ethUsed - fee;
        if (refund > 0) _sendEth(msg.sender, refund);

        emit CurveBuy(token, msg.sender, ethUsed, tokensOut, l.reserveWei, l.soldTokens);

        if (newSold >= CURVE_SUPPLY) {
            _graduate(token, l);
        }
    }

    function _splitCurveFee(address token, uint256 fee) internal {
        uint256 half = fee / 2;
        creatorFeesWei[token] += half;
        protocolFeesWei += fee - half;
    }

    // ---------------------------------------------------------------- curve math

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

    // ---------------------------------------------------------------- graduation

    function _graduate(address token, Launch storage l) internal {
        uint256 pFinal = HookrLaunchpadLib.tranchePrice(l.basePriceWei, TRANCHES - 1);
        uint256 reserve = l.reserveWei;

        // Pool price continues exactly where the curve ended.
        uint160 sqrtPriceX96 = _sqrtPriceX96ForPrice(pFinal);

        uint256 available = SUPPLY - CURVE_SUPPLY;
        uint256 tokensForPool = (reserve * 1e18) / pFinal;
        if (tokensForPool > available) tokensForPool = available;

        // `SUPPLY` as the cap basis is the live constant, deliberately unchanged: every deployed
        // pool was configured with it and graduation always places a near-fixed share of supply,
        // so the setting already means what a creator reads it to mean on this path.
        uint256 ethUsed = _openPool(token, l, pFinal, sqrtPriceX96, reserve, tokensForPool, available, SUPPLY);
        if (reserve > ethUsed) {
            protocolFeesWei += reserve - ethUsed;
        }
    }

    /// @notice Opens the pool a launch ends in, and seeds the ONE position it will ever have.
    /// @dev Shared verbatim by graduation and by `launchInstant`; the two paths differ only in how
    ///      they arrive at a price and at the amounts, never in what happens to the liquidity.
    ///
    ///      LOCKED BY CONSTRUCTION. The only `modifyLiquidity` this contract can ever reach are
    ///      the three encoded here and in `collectPoolFees`: `CB_GRADUATE` and `CB_TRANCHE` mint
    ///      positive liquidity, `CB_COLLECT` passes a delta of exactly zero. There is no fourth,
    ///      and no function on this contract — owner-gated or otherwise — takes a negative
    ///      liquidity delta. Adding the instant path added no new PoolManager interaction at all.
    ///
    /// @param openPriceWei Wei per whole token at open; the hook's config is derived from it.
    /// @param tokensAvailable Every token this contract still holds for the launch. Whatever the
    ///        position does not absorb funds the optional token-only bands, and the rest burns.
    /// @param capTokens What the anti-snipe `maxBuyBps` is a share of. Graduation passes `SUPPLY`,
    ///        which is what it has always passed and what the live pools were configured with; the
    ///        instant path passes the tokens it is actually placing. See `_buildPoolConfig`.
    /// @return ethUsed The native currency the position actually took.
    function _openPool(
        address token,
        Launch storage l,
        uint256 openPriceWei,
        uint160 sqrtPriceX96,
        uint256 ethForPool,
        uint256 tokensForPool,
        uint256 tokensAvailable,
        uint256 capTokens
    ) internal returns (uint256 ethUsed) {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        PoolId poolId = key.toId();

        // Configure, initialize, and seed the locked full-range position. Linked out for EIP-170;
        // it runs by DELEGATECALL, so the launchpad is still the initializer, the callback target,
        // and the position's owner.
        uint256 tokensUsed;
        (ethUsed, tokensUsed) = HookrLaunchpadLib.openPool(
            poolManager,
            hook,
            key,
            _buildPoolConfig(l.hookParams, l.blueprintId, openPriceWei, capTokens),
            sqrtPriceX96,
            ethForPool,
            tokensForPool
        );

        // Whatever the full-range position could not absorb funds the optional token-only
        // bands above spot; anything still unallocated burns exactly as it always has.
        uint256 tokensLeft = tokensAvailable - tokensUsed;
        uint256 tokensBurned;
        if (tokensLeft > 0) {
            uint256 seeded = _seedTranches(token, key, tokensLeft);
            tokensBurned = tokensLeft - seeded;
            if (tokensBurned > 0) {
                HookrToken(token).transfer(DEAD, tokensBurned);
            }
        }

        l.graduated = true;
        l.graduatedAtBlock = uint40(block.number);
        l.sqrtPriceX96AtGraduation = sqrtPriceX96;
        l.poolId = poolId;
        l.reserveWei = 0;

        emit Graduated(token, poolId, sqrtPriceX96, ethUsed, tokensUsed, tokensBurned);
    }

    /// @notice Places each configured band as a token-only position above the graduation tick.
    /// @dev Returns the tokens actually consumed. A band that rounds to zero liquidity, or one
    ///      the pool rejects, is skipped rather than reverting the graduation: the launch has
    ///      already sold out, and stranding it over an optional band would be far worse than
    ///      burning that slice. Skipped tokens fall through to the burn.
    function _seedTranches(address token, PoolKey memory key, uint256 tokensLeft) internal returns (uint256 seeded) {
        LpTranche[] storage bands = lpTranchesOf[token];
        uint256 n = bands.length;
        if (n == 0) return 0;

        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, key.toId());

        for (uint256 i; i < n; ++i) {
            LpTranche storage b = bands[i];
            uint256 amount = (tokensLeft * b.bps) / BPS;
            if (amount == 0) continue;

            // Higher token price == lower tick, so the band is placed below spot. Alignment can
            // collapse a thin band, a far-out band can exceed the usable range, and only a band
            // strictly below spot is token-only — `ok` is false for each, and the slice burns
            // instead of reverting the graduation.
            (bool ok, int24 lower, int24 upper) =
                HookrLaunchpadLib.trancheRange(currentTick, key.tickSpacing, b.startOffset, b.endOffset);
            if (!ok) continue;

            uint256 used = HookrLaunchpadLib.seedBand(poolManager, key, lower, upper, amount);
            if (used > 0) {
                seeded += used;
                emit LpTrancheSeeded(token, i, lower, upper, used);
            }
        }
    }

    /// @notice The exact `PoolConfig` a launch will hand the hook for these params. Lets the UI
    ///         — and the regression suite — check up front that anything `_validateHookParams`
    ///         accepts is also something `HookrHook.configurePool` accepts.
    /// @param capTokens What `maxBuyBps` is a share OF. Pass `SUPPLY()` for the curve path and the
    ///        pool's token count for the instant path; see `_buildPoolConfig`.
    function previewPoolConfig(HookParams calldata p, uint32 blueprintId, uint256 pFinal, uint256 capTokens)
        external
        view
        returns (HookrHook.PoolConfig memory)
    {
        return _buildPoolConfig(p, blueprintId, pFinal, capTokens);
    }

    /// @param capTokens The token count `maxBuyBps` is denominated against.
    /// @dev WHY THIS IS A PARAMETER. What the guard is really bounding is how far one buy can move
    ///      the price, and that depends on the buy relative to the pool's DEPTH, not to the total
    ///      supply. On the curve path the two track each other: graduation always places roughly
    ///      the same ~19-20% of supply, so `SUPPLY` is a fixed multiple of the float and
    ///      `maxBuyBps = 100` reliably buys ~5% of the pool's ETH. That constant is live on chain
    ///      and stays exactly as it is.
    ///
    ///      The instant path breaks the coupling: the creator chooses the float. Denominated
    ///      against SUPPLY, the cap reduces to `ethIn * maxBuyBps / poolSupplyBps`, so the cap as a
    ///      fraction of pool depth scales as 1/float — at a 20% float `maxBuyBps = 100` authorises
    ///      5% of the pool's ETH, and at the 1% float the old floor allowed it authorised 100% of
    ///      it, a ~4x price move in a single swap, from a setting the creator was told meant "1%".
    ///      Passing the tokens ACTUALLY PLACED makes the setting mean the same thing on both paths.
    function _buildPoolConfig(HookParams memory p, uint32 blueprintId, uint256 pFinal, uint256 capTokens)
        internal
        view
        returns (HookrHook.PoolConfig memory cfg)
    {
        uint16 royaltyBps;
        address royaltyTo;
        if (blueprintId != 0) {
            Blueprint storage bp = blueprints[blueprintId];
            royaltyBps = bp.royaltyBps;
            royaltyTo = bp.author;
        }
        uint256 maxBuyWei = 0;
        if (p.maxBuyBps != 0) {
            maxBuyWei = (((capTokens * p.maxBuyBps) / BPS) * pFinal) / 1e18;
            if (maxBuyWei > type(uint96).max) maxBuyWei = type(uint96).max;
        }
        cfg = HookrHook.PoolConfig({
            initialized: false, // hook sets this
            guardEndBlock: p.guardBlocks == 0 ? 0 : uint40(block.number + p.guardBlocks),
            baseFeePips: p.baseFeePips,
            // The builder emits maxFeePips == 0 whenever no surge block is stacked. The hook
            // reads that literally and rejects maxFee < baseFee, so it must be normalized HERE,
            // to the exact value _validateHookParams already checked, or graduation bricks.
            maxFeePips: _normalizedMaxFeePips(p),
            snipeTaxPips: p.snipeTaxPips,
            surgeSens: p.surgeSens,
            burnBps: p.burnBps,
            lpBps: p.lpBps,
            potBps: p.potBps,
            royaltyBps: royaltyBps,
            potEveryNBuys: p.potEveryNBuys,
            maxBuyWei: uint96(maxBuyWei),
            potMinBuyWei: p.potMinBuyWei,
            burnTriggerWei: p.burnTriggerWei,
            royaltyTo: royaltyTo,
            token: address(0), // hook sets this
            flywheelFeePips: 0 // the flywheel begins at generation 5; v4 pools never pay it
        });
    }

    function _sqrtPriceX96ForPrice(uint256 pFinal) internal pure returns (uint160) {
        // sqrtPriceX96 = sqrt((1e18 << 192) / pFinal). The bound check stays here so
        // `TargetOutOfRange` keeps being raised by this contract.
        uint256 root = HookrLaunchpadLib.sqrtPriceX96ForPrice(pFinal);
        if (root > type(uint160).max) revert TargetOutOfRange();
        return uint160(root);
    }

    // ---------------------------------------------------------------- locked-POL fee collection

    /// @notice Collect LP fees earned by the locked full-range position. ETH side splits
    ///         creator/protocol; the token side is burned. Callable by anyone.
    function collectPoolFees(address token) external nonReentrant {
        Launch storage l = _launchOf(token);
        if (!l.graduated) revert NotGraduated();

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        (uint256 ethAmount, uint256 tokenAmount) = HookrLaunchpadLib.collectRange(poolManager, key, 0, 0);

        // Each tranche is its own position, so its fees have to be poked separately — collecting
        // only the full-range position would silently leave tranche fees in the pool forever.
        LpTranche[] storage bands = lpTranchesOf[token];
        for (uint256 i; i < bands.length; ++i) {
            (bool ok, int24 lower, int24 upper) = _seededTrancheRange(token, key, i);
            if (!ok) continue;
            // A valid stored plan can still seed zero liquidity: for example an instant launch
            // that places all supply in the full-range position may leave only rounding dust, and
            // a small tranche bps then rounds to zero. PoolManager rejects a zero-delta poke of a
            // position that was never minted, which used to make this token's *entire* fee
            // collection path revert forever. Read the launchpad-owned position first and skip
            // only truly absent bands; seeded positions are never removable by this contract.
            bytes32 positionId = keccak256(abi.encodePacked(address(this), lower, upper, bytes32(0)));
            if (StateLibrary.getPositionLiquidity(poolManager, l.poolId, positionId) == 0) continue;
            (uint256 bandEth, uint256 bandTokens) =
                HookrLaunchpadLib.collectRange(poolManager, key, uint256(uint24(lower)), uint256(uint24(upper)));
            ethAmount += bandEth;
            tokenAmount += bandTokens;
        }

        if (ethAmount > 0) {
            // Fees the position earned while the anti-snipe guard was live are PROTOCOL-ONLY.
            // The snipe tax is charged as an LP fee, and the hook blocks outside LP additions for
            // the finite guard window so the launchpad's locked positions own that fee growth.
            // Without this withholding the tax flows back to the creator at `creatorFeeBps` — and
            // the creator is a party who can pay it, in the launch transaction on the instant path.
            // `guardFeesWithheldWei` is the high-water mark so the same wei is never withheld twice.
            uint256 owed = hook.guardLpEarnedWei(l.poolId) - guardFeesWithheldWei[token];
            uint256 withheld = owed > ethAmount ? ethAmount : owed;
            if (withheld > 0) guardFeesWithheldWei[token] += withheld;
            uint256 creatorSide = ((ethAmount - withheld) * _creatorFeeBps(token)) / BPS;
            protocolFeesWei += ethAmount - creatorSide;
            _creditCreatorSide(token, creatorSide);
        }
        emit PoolFeesCollected(token, ethAmount, tokenAmount);
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
        FeeRecipient[] storage recipients = feeRecipientsOf[token];
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

    /// @notice The on-chain range of a seeded band, recomputed from the graduation tick.
    /// @dev Mirrors the alignment and skip rules `_seedTranches` applied, so collection pokes
    ///      exactly the ranges that were actually created and never an empty one.
    function _seededTrancheRange(address token, PoolKey memory key, uint256 index)
        internal
        view
        returns (bool ok, int24 lower, int24 upper)
    {
        LpTranche storage b = lpTranchesOf[token][index];
        // Same geometry `_seedTranches` applied, against the graduation tick rather than spot.
        return HookrLaunchpadLib.trancheRangeAtSqrtPrice(
            launches[token].sqrtPriceX96AtGraduation, key.tickSpacing, b.startOffset, b.endOffset
        );
    }

    /// @notice Claim fees credited to a split recipient. Anyone may push a recipient's own
    ///         balance to them; the destination is always the recipient recorded at launch.
    function claimSplitFees(address token, address recipient) external nonReentrant {
        uint256 amount = splitFeesWei[token][recipient];
        if (amount == 0) revert NothingToClaim();
        splitFeesWei[token][recipient] = 0;
        _sendEth(recipient, amount);
        emit CreatorFeesClaimed(token, recipient, amount);
    }

    /// @notice Read the configured split for a launch.
    function getFeeRecipients(address token) external view returns (FeeRecipient[] memory) {
        return feeRecipientsOf[token];
    }

    /// @notice Read the configured LP bands for a launch.
    function getLpTranches(address token) external view returns (LpTranche[] memory) {
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
        _launchOf(token);
        uint256 amount = creatorFeesWei[token];
        if (amount == 0) revert NothingToClaim();
        creatorFeesWei[token] = 0;
        address to = creatorPayoutOf(token);
        _sendEth(to, amount);
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

        (, PoolKey memory key, uint160 sqrtPriceX96, uint256 ethAmt, uint256 tokenAmt) =
            abi.decode(data, (uint8, PoolKey, uint160, uint256, uint256));

        (int24 tickLower, int24 tickUpper) = HookrLaunchpadLib.usableTickRange(key.tickSpacing);
        if (action == CB_COLLECT && (ethAmt != 0 || tokenAmt != 0)) {
            // Collection over a tranche range: the bounds ride in the two amount slots.
            tickLower = int24(uint24(ethAmt));
            tickUpper = int24(uint24(tokenAmt));
        }

        if (action == CB_GRADUATE) {
            uint128 liquidity =
                HookrLaunchpadLib.liquidityForAmountsInRange(tickLower, tickUpper, sqrtPriceX96, ethAmt, tokenAmt);

            (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: int256(uint256(liquidity)),
                    salt: bytes32(0)
                }),
                ""
            );

            uint256 oweEth = callerDelta.amount0() < 0 ? uint256(uint128(-callerDelta.amount0())) : 0;
            uint256 oweTokens = callerDelta.amount1() < 0 ? uint256(uint128(-callerDelta.amount1())) : 0;

            if (oweEth > 0) {
                poolManager.settle{value: oweEth}();
            }
            if (oweTokens > 0) {
                poolManager.sync(key.currency1);
                HookrToken(Currency.unwrap(key.currency1)).transfer(address(poolManager), oweTokens);
                poolManager.settle();
            }
            return abi.encode(oweEth, oweTokens);
        }

        if (action == CB_COLLECT) {
            // Zero-delta liquidity change surfaces the accrued fees as positive deltas.
            (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 0, salt: bytes32(0)
                }),
                ""
            );
            uint256 ethOwed = callerDelta.amount0() > 0 ? uint256(uint128(callerDelta.amount0())) : 0;
            uint256 tokensOwed = callerDelta.amount1() > 0 ? uint256(uint128(callerDelta.amount1())) : 0;
            if (ethOwed > 0) {
                poolManager.take(Currency.wrap(address(0)), address(this), ethOwed);
            }
            if (tokensOwed > 0) {
                // Burn the token side directly.
                poolManager.take(key.currency1, DEAD, tokensOwed);
            }
            return abi.encode(ethOwed, tokensOwed);
        }

        revert BadCallback();
        // silence unused-var warnings in the compiler for branches above
        // (sqrtPriceX96/ethAmt/tokenAmt are unused in CB_COLLECT)
    }

    // ---------------------------------------------------------------- validation

    /// @notice `maxFeePips == 0` is the builder's "surge block not stacked" encoding, not a real
    ///         zero ceiling. Every read of the field — validation and graduation alike — goes
    ///         through here so the launchpad can never accept a stack the hook would reject.
    function _normalizedMaxFeePips(HookParams memory p) internal pure returns (uint24) {
        return p.maxFeePips == 0 ? p.baseFeePips : p.maxFeePips;
    }

    /// @dev Mirrors HookrHook.configurePool's checks against the NORMALIZED params, so anything
    ///      accepted here is guaranteed to configure cleanly at graduation.
    /// @notice Rejects a fee split or LP plan the collection path could not honour exactly.
    /// @dev Runs before any state is written so a bad plan reverts the whole launch.
    function _validateDistribution(LaunchArgs calldata args) internal pure {
        if (args.creatorFeeBps > MAX_CREATOR_FEE_BPS) revert BadFeeSplit();

        uint256 n = args.feeRecipients.length;
        if (n > MAX_FEE_RECIPIENTS) revert BadFeeSplit();
        if (n > 0) {
            uint256 sum;
            for (uint256 i; i < n; ++i) {
                FeeRecipient calldata r = args.feeRecipients[i];
                if (r.to == address(0) || r.bps == 0) revert BadFeeSplit();
                // Duplicates would still pay out correctly, but they make the split unreadable
                // on chain and hide a mistaken split from whoever reviews the launch.
                for (uint256 j; j < i; ++j) {
                    if (args.feeRecipients[j].to == r.to) revert BadFeeSplit();
                }
                sum += r.bps;
            }
            // Exact, not "at most": anything else would silently strand fees in the contract.
            if (sum != BPS) revert BadFeeSplit();
        }

        uint256 t = args.lpTranches.length;
        if (t > MAX_LP_TRANCHES) revert BadLpPlan();
        if (t > 0) {
            uint256 sum;
            int24 previousUpper = 0;
            for (uint256 i; i < t; ++i) {
                LpTranche calldata b = args.lpTranches[i];
                if (b.bps == 0) revert BadLpPlan();
                // Strictly below the graduation tick keeps every band token-only: a band
                // straddling spot would need ETH the raise has already committed elsewhere.
                if (b.startOffset < MIN_TRANCHE_OFFSET) revert BadLpPlan();
                if (b.endOffset <= b.startOffset) revert BadLpPlan();
                // Bounded from above as well as below. Unbounded, a single band could be placed
                // where its liquidity no longer fits uint128 — which reverted inside the unlock
                // and so bricked graduation permanently instead of being skipped. `bandLiquidity`
                // is what makes that unreachable now; this is what stops a creator wandering into
                // the skip and silently burning the ladder they thought they had configured.
                if (b.endOffset > MAX_TRANCHE_OFFSET) revert BadLpPlan();
                // Ascending in price and non-overlapping, so the bands read as a ladder and a
                // mistake cannot quietly stack two positions on the same range.
                if (i > 0 && b.startOffset < previousUpper) revert BadLpPlan();
                previousUpper = b.endOffset;
                sum += b.bps;
            }
            // At most the whole leftover: any unallocated remainder still burns.
            if (sum > BPS) revert BadLpPlan();
        }
    }

    function _validateHookParams(HookParams memory p) internal pure {
        uint24 maxFeePips = _normalizedMaxFeePips(p);
        if (p.baseFeePips > 500_000 || maxFeePips > 500_000) revert BadHookParams();
        if (maxFeePips < p.baseFeePips) revert BadHookParams();
        if (uint256(p.baseFeePips) + p.snipeTaxPips > 500_000) revert BadHookParams();
        if (uint256(p.burnBps) + p.lpBps + p.potBps > 1000) revert BadHookParams();
        if (p.burnTriggerWei != 0) revert BadHookParams();
        if (p.potBps > 0 && (p.potEveryNBuys < 2 || p.potEveryNBuys > 100_000)) revert BadHookParams();
        if (p.surgeSens > 10) revert BadHookParams();
        if (p.guardBlocks > 100_000) revert BadHookParams();
        if (p.maxBuyBps > BPS) revert BadHookParams();
        if (p.potBps > 0 && p.potMinBuyWei < MIN_POT_BUY_WEI) revert BadHookParams();
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

    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }
}
