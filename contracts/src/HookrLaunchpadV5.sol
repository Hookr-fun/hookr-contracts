// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {HookrToken} from "./HookrToken.sol";
import {HookrHook} from "./HookrHook.sol";
import {HookrLaunchpadLibV5} from "./libraries/HookrLaunchpadLibV5.sol";
import {HookParams, FeeRecipient} from "./libraries/HookrLaunchTypes.sol";
import {
    IContinuousClearingAuctionFactory,
    IContinuousClearingAuction,
    AuctionParameters,
    LBPInitializationParams
} from "./interfaces/IContinuousClearingAuction.sol";

/// @title HookrLaunchpadV5
/// @notice The Hookr.fun generation-5 launchpad on Robinhood Chain 4663. Two native-ETH lanes,
///         both opening the same locked, launchpad-owned Uniswap v4 pool the earlier generations
///         did — and neither ever handing the creator a token allocation.
///
///         INSTANT (`launchInstant`): zero quote seed. The whole fixed supply is placed as ONE
///         token-only sell band whose upper edge is the opening tick, and the pool initializes
///         there at a creator-chosen opening FDV. Buyers deposit every wei of ETH by walking the
///         price down through the band — a bounded single-sided range, so it opens at a real
///         valuation and, unlike a full-range token-only position, is not drainable. Price walks a
///         closed-form square-root curve (ETH to reach multiple m over the open ~ FDV*(sqrt(m)-1)).
///
///         BONDED (`launchAuction` -> `migrateAuction`): the raise is discovered by a Continuous
///         Clearing Auction, run on Uniswap Labs' DEPLOYED, byte-verified, permissionless factory
///         (0x000000001F26a0044BaA66024e7b6599c61963F8). Every bid clears at ONE rising price; a
///         raise below the floor refunds in full. Half the supply is auctioned, half reserved; at
///         migration the pool opens AT the clearing price with the whole raise and the reserve as a
///         locked full-range position. 50/50 is the unique zero-skim split (raise == clearing price
///         x tokens auctioned), so the pool is two-sided at open and none of the raise is stranded.
///
///         The stepped bonding curve of generations 1-4 is retired here. Those generations remain
///         readable and tradable under their own contracts; this one carries no curve.
///
///         Blueprints, the anti-snipe/fee/burn/pot/LP hook stack, locked-by-construction liquidity,
///         creator fee splits and payout redirection are all unchanged from generation 4.
contract HookrLaunchpadV5 is IUnlockCallback {
    using StateLibrary for IPoolManager;

    // ---------------------------------------------------------------- constants

    uint256 public constant SUPPLY = 1_000_000_000e18;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant FIRST_PUBLIC_BLUEPRINT_ID = 6;
    uint24 internal constant DYNAMIC_FEE_FLAG = 0x800000;
    int24 public constant TICK_SPACING = 60;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint16 public constant DEFAULT_CREATOR_FEE_BPS = 5000;
    uint16 public constant MAX_CREATOR_FEE_BPS = 8000;
    uint256 public constant MAX_FEE_RECIPIENTS = 4;

    /// Width of the instant lane's single sell band, in ticks below the fixed open tick. ~1e9x price
    /// span: far more than any launch reaches, and `bandLiquidity` keeps it inside uint128 with
    /// orders of magnitude to spare.
    int24 public constant BAND_TICKS = 207_000;

    /// Bonded-lane term bounds, in wei. DELIBERATELY LOOSE — these are safety rails, not product
    /// policy. The product floors (pools.trade parity: ~$1k starting FDV, ~$5k graduation) are
    /// enforced by the wizard, exactly as generation 4 held the curve's UI floor at 5 ETH over a
    /// 0.0001 ETH contract bound. Keeping the contract bounds low is what lets a live canary run
    /// the full auction cycle with pennies instead of a production-sized raise.
    uint96 public constant MIN_RAISE_FLOOR_WEI = 0.01 ether;
    uint96 public constant MAX_RAISE_FLOOR_WEI = 1000 ether;
    /// The auction's STARTING valuation (its floor price expresses this FDV). Decoupled from the
    /// raise floor, pools.trade-style: an auction can open cheap and still demand a multiple of its
    /// floor in bids before it graduates.
    uint96 public constant MIN_FLOOR_FDV_WEI = 0.01 ether;
    uint96 public constant MAX_FLOOR_FDV_WEI = 10_000 ether;

    /// Bonded lane split bounds: the share of the fixed supply RESERVED to seed the pool at
    /// migration (the rest is auctioned). At the top of the range the reserved tokens exactly
    /// balance the raise at the clearing price, so 100% of it locks — the zero-skim point. Below it,
    /// the reserved tokens are worth less than the raise, and the balance is returned to the creator
    /// as disclosed proceeds (a real fundraise, pools.trade-style). The floor keeps meaningful
    /// locked depth: at 20% reserved a creator still locks a fifth of supply as liquidity.
    uint16 public constant MIN_RESERVE_BPS = 2000;
    uint16 public constant MAX_RESERVE_BPS = 5000;

    /// HOOKR-quoted bonded rails, in HOOKR wei. As deliberately loose as the ETH rails — product
    /// floors (value-matched to the ETH lane) are wizard policy. The ceiling is the entire HOOKR
    /// supply; beyond that a floor is not a price, it is a typo.
    uint96 public constant MIN_HOOKR_TERM = 10_000e18;
    uint96 public constant MAX_HOOKR_TERM = 1_000_000_000e18;

    /// The HOOKR-flywheel protocol fee on ETH-quoted pools: 0.3% of the ETH side of every swap
    /// (exact-output sells exempt — see the hook), accrued by the hook to the flywheel burner,
    /// which market-buys HOOKR and burns it. HOOKR-quoted pools pay NO protocol fee of any kind.
    uint24 public constant FLYWHEEL_FEE_PIPS = 3000;

    // ---------------------------------------------------------------- immutables

    IPoolManager public immutable poolManager;
    /// @notice Uniswap Labs' deployed Continuous Clearing Auction factory on 4663. Reused as-is.
    IContinuousClearingAuctionFactory public immutable auctionFactory;
    /// @notice Auction window and post-window delays, in blocks. Owner-settable (not immutable) so a
    ///         short window can be used for a live canary and then flipped to production — and so the
    ///         cadence can be retuned without a redeploy. Changing them is SAFE for launches already
    ///         under way: an auction's end block is baked into its CCA at creation, so a later change
    ///         only affects future auctions (and, for `migrationDelayBlocks`, when a pending
    ///         auction's migration unlocks — the owner can delay but never prevent it, as
    ///         `migrateAuction` stays permissionless). `auctionDurationBlocks` must divide 1e7
    ///         exactly (uniform issuance schedule); `setAuctionTiming` enforces it, as does the
    ///         constructor.
    uint64 public auctionDurationBlocks;
    uint64 public claimDelayBlocks;
    uint64 public migrationDelayBlocks;

    /// @notice The FIXED opening valuation of every instant launch, in wei. Set once at deploy and
    ///         platform-wide thereafter — no creator picks it, exactly like pools.trade's immutable
    ///         opening tick. The derived open price, sqrt price and band ticks are precomputed here
    ///         so a launch does no plan math.
    uint96 public immutable instantOpenFdvWei;

    /// @notice Whether this chain exposes the ArbSys precompile — probed once at deployment,
    ///         EXACTLY the way the CCA's BlockNumberish base probes it. The auction lives on
    ///         `ArbSys.arbBlockNumber()` (the rollup's own block height) on Arbitrum/Orbit chains,
    ///         while `block.number` there is the PARENT chain's height — two different clocks
    ///         (~10 blocks/s vs the parent's cadence). Every block the launchpad exchanges with
    ///         the auction (start, end, migration readiness) must be read from the auction's
    ///         clock, or an auction is born already expired. Elsewhere (plain EVM, unit tests,
    ///         forks without a native precompile) both contracts fall back to `block.number`
    ///         together, so the two clocks are equal by construction in every environment.
    bool internal immutable useArbSysClock;
    uint96 public immutable instantOpenPriceWei;
    uint160 public immutable instantSqrtPriceX96;
    int24 public immutable instantBandLower;
    int24 public immutable instantBandUpper;

    /// @notice The HOOKR token — the alternative quote currency. HOOKR-quoted launches mine their
    ///         token address ABOVE it so HOOKR is always currency0, pay no protocol fee anywhere,
    ///         and route 100% of collected fees to the creator. Their tradeoff: only the guard and
    ///         surge blocks (the native-cut blocks are ETH machinery; see the design doc).
    address public immutable hookrToken;
    /// @notice The FIXED opening valuation of a HOOKR-quoted instant launch, in HOOKR wei —
    ///         2,500,000 HOOKR at deploy. Fixed platform-wide exactly like the ETH lane's.
    uint96 public immutable hookrInstantOpenFdv;
    uint96 public immutable hookrInstantOpenPrice;
    uint160 public immutable hookrInstantSqrtPriceX96;
    int24 public immutable hookrBandLower;
    int24 public immutable hookrBandUpper;

    address public owner;
    address public pendingOwner;
    HookrHook public hook;
    uint96 public creationFeeWei = 0.0002 ether;

    // ---------------------------------------------------------------- types

    struct Blueprint {
        address author;
        uint16 royaltyBps;
        uint32 uses;
        uint40 savedAtBlock;
        string name;
        HookParams params;
    }

    enum LaunchMode {
        Instant,
        Bonded
    }

    /// @notice The pool's quote currency — what buyers pay with and what every price, floor, and
    ///         proceeds figure for the launch is denominated in.
    enum Quote {
        Eth,
        Hookr
    }

    enum LaunchStatus {
        Auctioning,
        Live,
        Failed
    }

    struct Launch {
        address token;
        address creator;
        uint40 launchBlock;
        uint32 blueprintId;
        LaunchMode mode;
        LaunchStatus status;
        uint96 openPriceWei; // instant: the fixed open price; bonded: clearing price at migration
        uint96 openFdvWei; // instant: the fixed FDV; bonded: raise floor until migration
        uint16 reserveBps; // bonded: share of supply reserved to seed the pool (rest is auctioned)
        address auction; // bonded only
        uint40 auctionEndBlock; // bonded only
        uint40 migratedAtBlock;
        uint160 sqrtPriceX96AtOpen;
        PoolId poolId;
        Quote quote;
        HookParams hookParams;
    }

    struct LaunchArgs {
        string name;
        string symbol;
        string tagline;
        string logoURI;
        address expectedCreator;
        uint32 blueprintId;
        HookParams custom;
        uint16 creatorFeeBps;
        FeeRecipient[] feeRecipients;
    }

    mapping(address => Launch) internal launches;
    address[] public allTokens;
    Blueprint[] internal blueprints;

    mapping(address creator => mapping(bytes32 intentId => address token)) public launchedByIntent;

    uint256 public protocolFeesWei;
    mapping(address => uint256) public creatorFeesWei;
    mapping(address => uint16) public creatorFeeBpsOf;
    mapping(address => FeeRecipient[]) internal feeRecipientsOf;
    mapping(address => mapping(address => uint256)) public splitFeesWei;
    mapping(address => address) public creatorPayout;
    mapping(address => uint256) public guardFeesWithheldWei;
    /// token => bonded-lane proceeds owed to the creator (the un-locked share of the raise).
    mapping(address => uint256) public creatorProceedsWei;

    bool internal locked;
    uint8 internal constant CB_GRADUATE = 1;
    uint8 internal constant CB_COLLECT = 2;
    uint8 internal constant CB_BAND = 3;

    // ---------------------------------------------------------------- events

    event TokenLaunched(
        address indexed token,
        address indexed creator,
        uint32 indexed blueprintId,
        LaunchMode mode,
        string name,
        string symbol,
        string tagline,
        string logoURI
    );
    event InstantLaunched(address indexed token, PoolId indexed poolId, uint96 openPriceWei);
    event AuctionStarted(
        address indexed token,
        address indexed auction,
        uint40 endBlock,
        uint96 floorFdvWei,
        uint96 raiseFloorWei,
        uint16 reserveBps
    );
    event AuctionProceeds(address indexed token, address indexed creator, uint256 amountWei);
    event Migrated(
        address indexed token,
        PoolId indexed poolId,
        uint160 sqrtPriceX96,
        uint256 ethLiquidity,
        uint256 tokenLiquidity,
        uint256 tokensBurned
    );
    event AuctionFailed(address indexed token, address indexed auction, uint256 tokensBurned);
    event BlueprintSaved(uint32 indexed id, address indexed author, string name, uint16 royaltyBps);
    event PoolFeesCollected(address indexed token, uint256 ethAmount, uint256 tokensBurned);
    event FeeSplitCredited(address indexed token, address indexed to, uint256 amountWei);
    event CreatorFeesClaimed(address indexed token, address indexed payTo, uint256 amountWei);
    event CreatorPayoutSet(address indexed token, address indexed payTo);
    event ProtocolFeesWithdrawn(address indexed to, uint256 amountWei);
    event CreationFeeSet(uint96 feeWei);
    event AuctionTimingSet(uint64 durationBlocks, uint64 claimDelay, uint64 migrationDelay);
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
    error BadLaunchArgs();
    error UnexpectedCreator(address expectedCreator, address actualCreator);
    error ZeroLaunchIntent();
    error LaunchIntentAlreadyUsed(address creator, bytes32 intentId, address token);
    error BadHookParams();
    error BadFeeSplit();
    error BadLpPlan();
    error OpenPriceOutOfRange();
    error RaiseFloorOutOfRange();
    error ReserveBpsOutOfRange();
    error InsufficientPayment();
    error FloorFdvOutOfRange();
    error InstantRejectsLpDonation();
    error HookrPairRejectsNativeCutBlocks();
    error NotAuctioning();
    error AlreadyResolved();
    error MigrationNotReady(uint256 readyBlock, uint256 nowBlock);
    error AuctionAmountMismatch(uint256 received, uint256 expected);
    error NotPoolManager();
    error BadCallback();
    error NothingToClaim();
    error FeeTooHigh();
    error RoyaltyTooHigh();
    error HouseBlueprintsPending();
    error AuctionScheduleInvalid();

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

    constructor(
        IPoolManager poolManager_,
        IContinuousClearingAuctionFactory auctionFactory_,
        uint64 auctionDurationBlocks_,
        uint64 claimDelayBlocks_,
        uint64 migrationDelayBlocks_,
        uint96 instantOpenFdvWei_,
        address hookrToken_,
        uint96 hookrInstantOpenFdv_
    ) {
        if (address(auctionFactory_) == address(0) || hookrToken_ == address(0)) {
            revert ZeroAddress();
        }
        if (!HookrLaunchpadLibV5.uniformStepsValid(auctionDurationBlocks_)) revert AuctionScheduleInvalid();
        poolManager = poolManager_;
        auctionFactory = auctionFactory_;
        auctionDurationBlocks = auctionDurationBlocks_;
        claimDelayBlocks = claimDelayBlocks_;
        migrationDelayBlocks = migrationDelayBlocks_;
        owner = msg.sender;
        blueprints.push(); // id 0 = custom sentinel

        // Probe the ArbSys precompile the way the CCA's BlockNumberish constructor does: only a
        // successful 32-byte `arbBlockNumber()` answer counts. A chain where address(0x64) holds
        // an inert stub (forge forks of Arbitrum chains) fails the probe, exactly as it does for
        // the CCA — keeping the two contracts on the same clock there too.
        bool probed;
        assembly ("memory-safe") {
            if extcodesize(0x64) {
                mstore(0x00, 0xa3b1b31d) // arbBlockNumber()
                let ok := staticcall(gas(), 0x64, 0x1c, 0x04, 0x00, 0x20)
                probed := and(ok, eq(returndatasize(), 0x20))
            }
        }
        useArbSysClock = probed;

        // Precompute the fixed instant open. Reverts the deployment if the chosen FDV does not
        // resolve to a placeable band — so a live launchpad's instant open is provably valid.
        (uint96 openPriceWei, uint160 sqrtPriceX96, int24 bandLower, int24 bandUpper, uint8 err) =
            HookrLaunchpadLibV5.zeroSeedPlan(instantOpenFdvWei_, SUPPLY, BAND_TICKS, TICK_SPACING, 1, type(uint96).max);
        if (err != 0) revert OpenPriceOutOfRange();
        instantOpenFdvWei = instantOpenFdvWei_;
        instantOpenPriceWei = openPriceWei;
        instantSqrtPriceX96 = sqrtPriceX96;
        instantBandLower = bandLower;
        instantBandUpper = bandUpper;

        // The HOOKR-quoted instant open, precomputed and constructor-validated the same way.
        hookrToken = hookrToken_;
        (openPriceWei, sqrtPriceX96, bandLower, bandUpper, err) = HookrLaunchpadLibV5.zeroSeedPlan(
            hookrInstantOpenFdv_, SUPPLY, BAND_TICKS, TICK_SPACING, 1, type(uint96).max
        );
        if (err != 0) revert OpenPriceOutOfRange();
        hookrInstantOpenFdv = hookrInstantOpenFdv_;
        hookrInstantOpenPrice = openPriceWei;
        hookrInstantSqrtPriceX96 = sqrtPriceX96;
        hookrBandLower = bandLower;
        hookrBandUpper = bandUpper;
    }

    function contractName() external pure returns (string memory) {
        return "HookrLaunchpadV5";
    }

    function contractVersion() external pure returns (string memory) {
        return "5.0.1";
    }

    /// @dev The receive() guard allows the pool manager always and an auction only while one is
    ///      mid-sweep. `_sweepingAuction` is set transiently around the sweep calls in `migrateAuction`.
    address internal _sweepingAuction;

    receive() external payable {
        // Native ETH arrives from the PoolManager (settlement) and the CCA (swept raise / refunds).
        if (msg.sender != address(poolManager) && msg.sender != _sweepingAuction) revert NotPoolManager();
    }

    // ---------------------------------------------------------------- admin

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

    /// @notice Retune the auction cadence — e.g. a short window for a live canary, then production.
    ///         Only affects auctions started after the change.
    function setAuctionTiming(uint64 durationBlocks, uint64 claimDelay, uint64 migrationDelay) external onlyOwner {
        if (!HookrLaunchpadLibV5.uniformStepsValid(durationBlocks)) revert AuctionScheduleInvalid();
        auctionDurationBlocks = durationBlocks;
        claimDelayBlocks = claimDelay;
        migrationDelayBlocks = migrationDelay;
        emit AuctionTimingSet(durationBlocks, claimDelay, migrationDelay);
    }

    function proposeOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnerProposed(newOwner);
    }

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
        if (blueprints.length < FIRST_PUBLIC_BLUEPRINT_ID && msg.sender != owner) {
            revert HouseBlueprintsPending();
        }
        if (bytes(name).length == 0 || bytes(name).length > 48) revert BadLaunchArgs();
        if (royaltyBps > 1000) revert RoyaltyTooHigh();
        _validateHookParams(params);
        if (royaltyBps > 0 && uint256(params.lpBps) + params.potBps == 0) revert BadHookParams();
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

    // ---------------------------------------------------------------- instant lane

    /// @notice Launch straight into a live, zero-seed, single-sided pool at the FIXED platform
    ///         opening valuation for the chosen quote (`instantOpenFdvWei` in ETH,
    ///         `hookrInstantOpenFdv` in HOOKR). No creator picks the price — like pools.trade's
    ///         immutable opening tick — so every instant launch on a given quote opens identically.
    /// @param quote The pool's quote currency. HOOKR-quoted launches pay no protocol fee anywhere
    ///        and route 100% of collected fees to the creator, but carry only the guard and surge
    ///        blocks (the native-cut blocks are ETH machinery end to end).
    /// @param intentId Optional replay guard, keyed by (creator, intentId). Pass `bytes32(0)` for
    ///        the ordinary permissionless path; a nonzero id launches exactly once per creator.
    function launchInstant(LaunchArgs calldata args, Quote quote, bytes32 intentId)
        external
        payable
        nonReentrant
        returns (address token)
    {
        if (intentId != bytes32(0)) _checkIntent(intentId);
        token = _launchInstant(args, quote);
        if (intentId != bytes32(0)) _recordIntent(intentId, token);
    }

    function _launchInstant(LaunchArgs calldata args, Quote quote) internal returns (address token) {
        bool eth = quote == Quote.Eth;
        Launch storage l;
        (token, l) = _create(
            args,
            LaunchMode.Instant,
            quote,
            eth ? instantOpenPriceWei : hookrInstantOpenPrice,
            eth ? instantOpenFdvWei : hookrInstantOpenFdv
        );
        // STRUCTURAL: a zero-seed pool opens with the tick OUTSIDE its band, so in-range liquidity
        // is zero until the first buy — and the hook fails closed on an LP-donation cut with no
        // in-range LP to receive it. Allowing lpBps here would brick the pool on its first buy.
        // The block stays available on the bonded lane, whose migrated pool has POL in range from
        // its first block. Checked on the RESOLVED params so blueprints cannot smuggle it in.
        if (l.hookParams.lpBps != 0) revert InstantRejectsLpDonation();

        _openInstant(token, l);

        l.status = LaunchStatus.Live;
        l.sqrtPriceX96AtOpen = eth ? instantSqrtPriceX96 : hookrInstantSqrtPriceX96;
        emit InstantLaunched(token, l.poolId, l.openPriceWei);
    }

    // ---------------------------------------------------------------- bonded lane

    /// @notice Launch through a Continuous Clearing Auction. `reserveBps` of the supply is reserved
    ///         to seed the pool at migration; the rest is auctioned over `auctionDurationBlocks`.
    /// @param floorFdvWei The auction's STARTING valuation: the floor price is the clearing price at
    ///        this FDV. Decoupled from the graduation floor, pools.trade-style, so an auction can
    ///        open cheap and still demand real bids before it graduates.
    /// @param raiseFloorWei The graduation floor. A total raise below this refunds every bid and
    ///        the launch fails.
    /// @param reserveBps Share of supply reserved to seed the pool, in [MIN_RESERVE_BPS, MAX_RESERVE_BPS].
    ///        At MAX_RESERVE_BPS the reserved tokens exactly balance the raise, so 100% of it locks
    ///        (zero creator proceeds). Below it, the balance is returned to the creator as disclosed
    ///        proceeds — a real fundraise. The chosen split is public before anyone bids.
    /// @param intentId Optional replay guard; see `launchInstant`.
    function launchAuction(
        LaunchArgs calldata args,
        Quote quote,
        uint96 floorFdvWei,
        uint96 raiseFloorWei,
        uint16 reserveBps,
        bytes32 intentId
    ) external payable nonReentrant returns (address token) {
        if (intentId != bytes32(0)) _checkIntent(intentId);
        token = _launchAuction(args, quote, floorFdvWei, raiseFloorWei, reserveBps);
        if (intentId != bytes32(0)) _recordIntent(intentId, token);
    }

    function _launchAuction(
        LaunchArgs calldata args,
        Quote quote,
        uint96 floorFdvWei,
        uint96 raiseFloorWei,
        uint16 reserveBps
    ) internal returns (address token) {
        if (quote == Quote.Eth) {
            if (raiseFloorWei < MIN_RAISE_FLOOR_WEI || raiseFloorWei > MAX_RAISE_FLOOR_WEI) {
                revert RaiseFloorOutOfRange();
            }
            if (floorFdvWei < MIN_FLOOR_FDV_WEI || floorFdvWei > MAX_FLOOR_FDV_WEI) revert FloorFdvOutOfRange();
        } else {
            if (raiseFloorWei < MIN_HOOKR_TERM || raiseFloorWei > MAX_HOOKR_TERM) revert RaiseFloorOutOfRange();
            if (floorFdvWei < MIN_HOOKR_TERM || floorFdvWei > MAX_HOOKR_TERM) revert FloorFdvOutOfRange();
        }
        if (reserveBps < MIN_RESERVE_BPS || reserveBps > MAX_RESERVE_BPS) revert ReserveBpsOutOfRange();

        Launch storage l;
        (token, l) = _create(args, LaunchMode.Bonded, quote, 0, raiseFloorWei);
        l.reserveBps = reserveBps;

        uint256 auctionSupply = (SUPPLY * (BPS - reserveBps)) / BPS;
        // Build the config, then create + fund + arm through the lib. The reserved supply stays in
        // the launchpad to seed the pool at migration.
        (bytes memory configData, uint64 endBlock) = _auctionConfig(quote, floorFdvWei, raiseFloorWei);
        address auction = HookrLaunchpadLibV5.createAndArmAuction(auctionFactory, token, auctionSupply, configData);

        l.status = LaunchStatus.Auctioning;
        l.auction = auction;
        l.auctionEndBlock = uint40(endBlock);
        emit AuctionStarted(token, auction, uint40(endBlock), floorFdvWei, raiseFloorWei, reserveBps);
    }

    /// @notice Settle a finished auction. Permissionless; a keeper or anyone may call it.
    ///         Graduated auctions open the pool at the clearing price; failed ones burn the supply.
    function migrateAuction(address token) external nonReentrant {
        Launch storage l = _launchOf(token);
        if (l.mode != LaunchMode.Bonded || l.status != LaunchStatus.Auctioning) revert NotAuctioning();
        uint256 readyBlock = uint256(l.auctionEndBlock) + migrationDelayBlocks;
        uint256 nowOnAuctionClock = _auctionClock();
        if (nowOnAuctionClock < readyBlock) revert MigrationNotReady(readyBlock, nowOnAuctionClock);

        IContinuousClearingAuction auction = IContinuousClearingAuction(l.auction);

        // The CCA checkpoints lazily. A bid near the start of the window can leave its stored
        // graduation accounting stale all the way through `endBlock`; reading `isGraduated()`
        // first would then misclassify a funded auction as failed. Finalize the checkpoint before
        // selecting either settlement path. This call is permissionless upstream and is safe to
        // repeat when the end block has already been checkpointed.
        auction.checkpoint();
        if (!auction.isGraduated()) {
            // Bids are refunded by bidders exiting the auction directly; the launchpad never
            // custodied a bid. It sweeps the unsold auction supply back and burns the whole supply.
            _sweepingAuction = l.auction;
            uint256 held = HookrLaunchpadLibV5.burnFailedAuction(l.auction, token);
            _sweepingAuction = address(0);
            l.status = LaunchStatus.Failed;
            emit AuctionFailed(token, l.auction, held);
            return;
        }

        // Graduated: pull the raise and the unsold auction tokens, then open the pool. The raise
        // is measured by BALANCE DELTA in the quote currency, so a factory protocol fee cannot
        // poison the accounting on either quote.
        LBPInitializationParams memory lbp = auction.lbpInitializationParams();
        bool eth = l.quote == Quote.Eth;
        uint256 quoteBefore = eth ? address(this).balance : HookrToken(hookrToken).balanceOf(address(this));
        _sweepingAuction = l.auction;
        HookrLaunchpadLibV5.sweepGraduated(l.auction);
        _sweepingAuction = address(0);
        uint256 raiseSwept =
            (eth ? address(this).balance : HookrToken(hookrToken).balanceOf(address(this))) - quoteBefore;

        (uint256 openPriceWei, uint160 sqrtPriceX96) = HookrLaunchpadLibV5.migrationSqrt(lbp.initialPriceX96);
        if (sqrtPriceX96 == 0) revert OpenPriceOutOfRange();

        // Only the RESERVED tokens seed the pool; unsold auction tokens (from a partial sale) are
        // burned. Capping the token offer at the reserve is what forces the pool to be token-limited
        // when `reserveBps < MAX_RESERVE_BPS` — the ETH it cannot absorb is the creator's proceeds.
        uint256 reservedTokens = (SUPPLY * l.reserveBps) / BPS;
        HookrLaunchpadLibV5.burnDownToReserve(token, reservedTokens);

        l.openPriceWei = uint96(openPriceWei > type(uint96).max ? type(uint96).max : openPriceWei);
        l.status = LaunchStatus.Live;
        l.migratedAtBlock = uint40(block.number);
        l.sqrtPriceX96AtOpen = sqrtPriceX96;

        _openPool(token, l, openPriceWei, sqrtPriceX96, raiseSwept, reservedTokens);
    }

    // ---------------------------------------------------------------- shared launch

    function _checkIntent(bytes32 intentId) internal view {
        if (intentId == bytes32(0)) revert ZeroLaunchIntent();
        address existingToken = launchedByIntent[msg.sender][intentId];
        if (existingToken != address(0)) revert LaunchIntentAlreadyUsed(msg.sender, intentId, existingToken);
    }

    function _recordIntent(bytes32 intentId, address token) internal {
        launchedByIntent[msg.sender][intentId] = token;
        emit LaunchIntentConsumed(msg.sender, intentId, token);
    }

    function _create(LaunchArgs calldata args, LaunchMode mode, Quote quote, uint96 openPriceWei, uint96 openFdvWei)
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
        if (msg.value != creationFeeWei) revert InsufficientPayment();
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
        // HOOKR pairs carry only the guard and surge blocks: the pot, auto-burn, and LP-donation
        // cuts are native-ETH machinery end to end (claims, payouts, buyback-burns), and the hook
        // enforces the same refusal at configuration. Checked on RESOLVED params — a blueprint
        // cannot smuggle a native-cut block onto a HOOKR pair.
        if (quote == Quote.Hookr && uint256(params.burnBps) + params.lpBps + params.potBps != 0) {
            revert HookrPairRejectsNativeCutBlocks();
        }

        token = quote == Quote.Eth
            ? HookrLaunchpadLibV5.deployToken(args.name, args.symbol, args.tagline, args.logoURI, msg.sender, SUPPLY)
            : HookrLaunchpadLibV5.deployTokenAbove(
                args.name, args.symbol, args.tagline, args.logoURI, msg.sender, SUPPLY, hookrToken
            );

        l = launches[token];
        l.token = token;
        l.creator = msg.sender;
        l.launchBlock = uint40(block.number);
        l.blueprintId = args.blueprintId;
        l.mode = mode;
        l.quote = quote;
        l.openPriceWei = openPriceWei;
        l.openFdvWei = openFdvWei;
        l.hookParams = params;
        if (args.creatorFeeBps != 0) creatorFeeBpsOf[token] = args.creatorFeeBps;
        for (uint256 i; i < args.feeRecipients.length; ++i) {
            feeRecipientsOf[token].push(args.feeRecipients[i]);
        }
        allTokens.push(token);

        protocolFeesWei += creationFeeWei;

        emit TokenLaunched(
            token, msg.sender, args.blueprintId, mode, args.name, args.symbol, args.tagline, args.logoURI
        );
    }

    // ---------------------------------------------------------------- opening

    /// @notice Configure the hook, open the pool at the band's upper edge, and seed the one
    ///         token-only sell band that holds the whole supply.
    function _openInstant(address token, Launch storage l) internal {
        bool eth = l.quote == Quote.Eth;
        uint160 openSqrt = eth ? instantSqrtPriceX96 : hookrInstantSqrtPriceX96;
        PoolKey memory key = _poolKey(token, l.quote);
        l.poolId = key.toId();

        // Guard begins here (guardEndBlock derives from block.number). capTokens = SUPPLY, so a
        // maxBuyBps cap means the same fraction of the opening valuation it means on any launch.
        (uint256 used, uint256 burned) = HookrLaunchpadLibV5.openInstantBand(
            poolManager,
            hook,
            key,
            _buildPoolConfig(l.hookParams, l.blueprintId, l.openPriceWei, SUPPLY, l.quote),
            openSqrt,
            eth ? instantBandLower : hookrBandLower,
            eth ? instantBandUpper : hookrBandUpper,
            SUPPLY
        );

        emit Migrated(token, l.poolId, openSqrt, 0, used, burned);
    }

    /// @notice Open the pool a bonded launch migrates into, and seed the ONE full-range position.
    /// @dev Shared graduation opening: the position takes whatever balances the swept ETH; leftover
    ///      tokens burn.
    function _openPool(
        address token,
        Launch storage l,
        uint256 openPriceWei,
        uint160 sqrtPriceX96,
        uint256 ethForPool,
        uint256 tokensAvailable
    ) internal {
        PoolKey memory key = _poolKey(token, l.quote);
        l.poolId = key.toId();

        (uint256 ethUsed, uint256 tokensUsed) = HookrLaunchpadLibV5.openPool(
            poolManager,
            hook,
            key,
            _buildPoolConfig(l.hookParams, l.blueprintId, openPriceWei, SUPPLY, l.quote),
            sqrtPriceX96,
            ethForPool,
            tokensAvailable
        );

        uint256 tokensBurned = tokensAvailable - tokensUsed;
        if (tokensBurned > 0) HookrToken(token).transfer(DEAD, tokensBurned);

        // The ETH the reserved position could not absorb is the creator's DISCLOSED PROCEEDS — the
        // fundraise the split bought them. Zero at MAX_RESERVE_BPS (the reserved tokens balance the
        // whole raise), growing as the reserve shrinks. Routed to the creator's payout address.
        uint256 proceeds = ethForPool - ethUsed;
        if (proceeds > 0) {
            creatorProceedsWei[token] += proceeds;
            emit AuctionProceeds(token, l.creator, proceeds);
        }

        emit Migrated(token, l.poolId, sqrtPriceX96, ethUsed, tokensUsed, tokensBurned);
    }

    function _buildPoolConfig(HookParams memory p, uint32 blueprintId, uint256 pFinal, uint256 capTokens, Quote quote)
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
        uint40 guardEndBlock = p.guardBlocks == 0 ? 0 : uint40(block.number + p.guardBlocks);
        cfg = HookrLaunchpadLibV5.buildPoolConfig(
            p, royaltyBps, royaltyTo, pFinal, capTokens, guardEndBlock, quote == Quote.Eth ? FLYWHEEL_FEE_PIPS : 0
        );
    }

    // ---------------------------------------------------------------- auction clock

    /// @notice The block number ON THE AUCTION'S CLOCK — `ArbSys.arbBlockNumber()` where the
    ///         probe found it, `block.number` everywhere else. Used for every auction-facing
    ///         block: config start/end and migration readiness. All other block math in this
    ///         contract (launch blocks, guard windows, intents) stays on `block.number`,
    ///         consistent with the hook and every prior generation on this chain.
    function _auctionClock() internal view returns (uint256 blockNumber) {
        if (!useArbSysClock) return block.number;
        assembly ("memory-safe") {
            mstore(0x00, 0xa3b1b31d) // arbBlockNumber()
            let ok := staticcall(gas(), 0x64, 0x1c, 0x04, 0x00, 0x20)
            if or(iszero(ok), iszero(eq(returndatasize(), 0x20))) { revert(0, 0) }
            blockNumber := mload(0x00)
        }
    }

    // ---------------------------------------------------------------- auction config

    /// @dev Builds the CCA's AuctionParameters. The floor PRICE comes from the floor FDV over the
    ///      TOTAL supply (pools.trade-style starting valuation); the raise FLOOR is the separate
    ///      graduation threshold (requiredCurrencyRaised). Decoupled: an auction can open at a low
    ///      valuation and still demand a real raise before it graduates. The launchpad is both
    ///      funds and tokens recipient.
    function _auctionConfig(Quote quote, uint96 floorFdvWei, uint96 raiseFloorWei)
        internal
        view
        returns (bytes memory configData, uint64 endBlock)
    {
        uint64 startBlock = uint64(_auctionClock());
        endBlock = startBlock + auctionDurationBlocks;
        (configData,) = HookrLaunchpadLibV5.encodeAuctionConfig(
            quote == Quote.Eth ? address(0) : hookrToken,
            address(this),
            startBlock,
            endBlock,
            endBlock + claimDelayBlocks,
            floorFdvWei,
            raiseFloorWei,
            SUPPLY,
            auctionDurationBlocks
        );
    }

    // ---------------------------------------------------------------- fee collection

    function collectPoolFees(address token) external nonReentrant {
        Launch storage l = _launchOf(token);
        if (l.status != LaunchStatus.Live) revert NotAuctioning();

        bool eth = l.quote == Quote.Eth;
        PoolKey memory key = _poolKey(token, l.quote);
        // Poke the position this launch actually holds: instant pools hold ONLY the band position
        // (poking full-range there would revert on a nonexistent position and strand the fees);
        // bonded pools hold only the full-range position, encoded as the (0,0) sentinel. For an
        // instant pool the band depends on the quote.
        (uint256 quoteAmount, uint256 tokenAmount) = l.mode == LaunchMode.Instant
            ? HookrLaunchpadLibV5.collectRange(
                poolManager,
                key,
                uint256(uint24(eth ? instantBandLower : hookrBandLower)),
                uint256(uint24(eth ? instantBandUpper : hookrBandUpper))
            )
            : HookrLaunchpadLibV5.collectRange(poolManager, key, 0, 0);

        if (quoteAmount > 0) {
            if (eth) {
                uint256 owed = hook.guardLpEarnedWei(l.poolId) - guardFeesWithheldWei[token];
                uint256 withheld = owed > quoteAmount ? quoteAmount : owed;
                if (withheld > 0) guardFeesWithheldWei[token] += withheld;
                uint256 creatorSide = ((quoteAmount - withheld) * _creatorFeeBps(token)) / BPS;
                protocolFeesWei += quoteAmount - creatorSide;
                _creditCreatorSide(token, creatorSide);
            } else {
                // The HOOKR-pair promise: no protocol take of any kind. 100% of the quote-side
                // collection is the creator's, in HOOKR. The guard withholding exists to keep the
                // snipe tax out of the PROTOCOL split's creator rebate — with no protocol split
                // there is nothing to withhold from; the tradeoff (a HOOKR-pair creator's own
                // guarded buys effectively rebate their snipe tax) is disclosed in the docs.
                _creditCreatorSide(token, quoteAmount);
            }
        }
        emit PoolFeesCollected(token, quoteAmount, tokenAmount);
    }

    function _creatorFeeBps(address token) internal view returns (uint16) {
        uint16 configured = creatorFeeBpsOf[token];
        return configured == 0 ? DEFAULT_CREATOR_FEE_BPS : configured;
    }

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

    function claimSplitFees(address token, address recipient) external nonReentrant {
        uint256 amount = splitFeesWei[token][recipient];
        if (amount == 0) revert NothingToClaim();
        splitFeesWei[token][recipient] = 0;
        _sendQuote(launches[token].quote, recipient, amount);
        emit CreatorFeesClaimed(token, recipient, amount);
    }

    function getFeeRecipients(address token) external view returns (FeeRecipient[] memory) {
        return feeRecipientsOf[token];
    }

    function setCreatorPayout(address token, address to) external {
        Launch storage l = _launchOf(token);
        if (msg.sender != l.creator) revert NotCreator();
        creatorPayout[token] = to;
        emit CreatorPayoutSet(token, to);
    }

    function creatorPayoutOf(address token) public view returns (address) {
        address to = creatorPayout[token];
        return to == address(0) ? launches[token].creator : to;
    }

    function claimCreatorFees(address token) external nonReentrant {
        _payClaim(token, creatorFeesWei);
    }

    /// @notice Claim a bonded launch's creator proceeds — the share of the raise not locked as LP.
    ///         Pull payment: credited at migration, sent to the creator's payout address on claim.
    function claimAuctionProceeds(address token) external nonReentrant {
        _payClaim(token, creatorProceedsWei);
    }

    /// @dev Zeroes and pays a token's balance in `ledger` to the creator's payout address, in the
    ///      token's QUOTE currency — every per-token ledger is denominated in it.
    function _payClaim(address token, mapping(address => uint256) storage ledger) internal {
        Launch storage l = _launchOf(token);
        uint256 amount = ledger[token];
        if (amount == 0) revert NothingToClaim();
        ledger[token] = 0;
        address to = creatorPayoutOf(token);
        _sendQuote(l.quote, to, amount);
        emit CreatorFeesClaimed(token, to, amount);
    }

    // ---------------------------------------------------------------- unlock callback

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (bool ok, bytes memory result) =
            HookrLaunchpadLibV5.unlockDispatch(poolManager, data, CB_BAND, CB_GRADUATE, CB_COLLECT);
        if (!ok) {
            if (result.length != 0) revert BadLpPlan();
            revert BadCallback();
        }
        return result;
    }

    // ---------------------------------------------------------------- validation

    function _validateDistribution(LaunchArgs calldata args) internal pure {
        if (
            HookrLaunchpadLibV5.validateDistribution(
                    args.creatorFeeBps, args.feeRecipients, MAX_CREATOR_FEE_BPS, MAX_FEE_RECIPIENTS
                ) != 0
        ) revert BadFeeSplit();
    }

    function _validateHookParams(HookParams memory p) internal pure {
        if (HookrLaunchpadLibV5.validateHookParams(p, 0.001 ether) != 0) revert BadHookParams();
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

    // ---------------------------------------------------------------- internal

    function _poolKey(address token, Quote quote) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(quote == Quote.Eth ? address(0) : hookrToken),
            currency1: Currency.wrap(token),
            fee: DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    /// @dev Pay out in a launch's quote currency: native ETH, or a HOOKR transfer.
    function _sendQuote(Quote quote, address to, uint256 amount) internal {
        if (quote == Quote.Eth) {
            _sendEth(to, amount);
        } else if (!HookrToken(hookrToken).transfer(to, amount)) {
            revert EthTransferFailed();
        }
    }

    error EthTransferFailed();
}
