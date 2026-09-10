// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {
    HookrMarketCoordinatorKernelReservationLibV1,
    HookrMarketCoordinatorTokenDeployerV3,
    IHookrStackRegistryV1CoordinatorV3
} from "./HookrMarketCoordinatorV3.sol";
import {HookrMarketCoordinatorInitialBuyLibV4} from "./libraries/HookrMarketCoordinatorInitialBuyLibV4.sol";
import {IHookrKernelRouterV2} from "./interfaces/IHookrKernelRouterV2.sol";
import {HookrModuleTypesV1} from "./libraries/HookrModuleTypesV1.sol";
import {IHookrNativeMechanicsCatalogReadV1} from "./libraries/HookrNativeMechanicsCoordinatorLibV1.sol";
import {HookrNativeMechanicsCoordinatorLibV2} from "./libraries/HookrNativeMechanicsCoordinatorLibV2.sol";

/// @title Hookr Market Coordinator V5
/// @notice Opens a modular pool for a newly deployed token or a fresh pool for an existing token.
/// @dev V5 removes the partner voucher, relayer, and per-pool revenue-vault machinery of V3/V4.
///      The creator is always `msg.sender`; fee distribution is defined entirely by calldata through
///      the native-mechanics module configuration (lpFeeRecipient, royaltyTo, flywheel fields). No
///      EIP-712 signature and no PartnerRegistry dependency remains. The coordinator itself exposes
///      `treasuryBeneficiary()` so the shared native-mechanics guard library keeps reading one
///      canonical treasury address.
///
///      Every market receives a sorted Uniswap v4 PoolKey and one immutable registered stack.
///      New-token markets preserve the generation-5 instant-launch geometry: a fixed one-billion
///      token supply is placed in one bounded, token-only sell band with no quote seed or creator
///      allocation. The coordinator owns that position and exposes no liquidity-removal function.
///      An optional creator buy, on any quote currency and capped at `MAX_INITIAL_BUY_SUBJECT`,
///      runs only after the band is seeded. Existing-token
///      markets initialize with zero liquidity; LPs add and remove their own positions through v4
///      periphery.
contract HookrMarketCoordinatorV5 is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    /// @notice Uniswap v4 dynamic-fee flag required by every coordinated pool.
    uint24 public constant DYNAMIC_FEE_FLAG = 0x800000;
    /// @notice Maximum module-data length accepted by an initial creator buy.
    uint256 public constant MAX_MODULE_DATA_LENGTH = 3_904;
    /// @notice Fixed supply minted by every new-token market.
    uint256 public constant SUPPLY = 1_000_000_000e18;
    /// @notice Width of the generation-5 sell band before alignment to the pool tick spacing.
    int24 public constant BAND_TICKS = 207_000;
    /// @notice Domain used to derive new-token CREATE2 salts.
    bytes32 public constant TOKEN_SALT_DOMAIN = keccak256("HOOKR_MARKET_COORDINATOR_TOKEN_CREATE2_V3");
    /// @notice Ceiling on any protocol share this coordinator may resolve, in bps (50%).
    /// @dev Mirrors `HookrNativeMechanicsBlockV2.MAX_PROTOCOL_SHARE_BPS`; the module rejects
    ///      anything above it structurally, so this bound only fails an owner mistake earlier and
    ///      louder. The share is carved out of a pool's opted-in add-ons; the base LP fee is never
    ///      touched at any value. See docs/FEE_MODEL_V2.md.
    uint24 public constant MAX_PROTOCOL_SHARE_BPS = 5_000;
    /// @notice Largest subject amount an initial creator buy may deliver: 5% of the fixed supply.
    /// @dev Enforced on the amount actually delivered to the creator, after any auto-burn, for
    ///      every quote currency.
    uint256 public constant MAX_INITIAL_BUY_SUBJECT = SUPPLY * 500 / 10_000;

    uint8 private constant CB_SEED_BAND = 1;
    uint8 private constant CB_COLLECT_BAND = 2;
    uint256 private constant TOKEN_QUERY_GAS = 50_000;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @notice Source of a market coordinated by this contract.
    enum MarketOrigin {
        /// @notice Zero value for an absent market record.
        UNSET,
        /// @notice Market whose subject token was deployed by this coordinator.
        NEW_TOKEN,
        /// @notice Fresh market for a subject token that was already deployed.
        EXISTING_TOKEN
    }

    /// @notice Pool, seed, founding-fee, and immutable-stack parameters for a market.
    struct MarketParams {
        /// @notice Quote token, or address(0) for native currency.
        address quote;
        /// @notice Subject amount placed in the new-token founding band.
        /// @dev Must equal `SUPPLY` for a new-token market and zero for an existing-token market.
        uint128 subjectAmount;
        /// @notice Quote amount placed in a founding position.
        /// @dev Must be zero for every market. An initial creator buy is funded separately.
        uint128 quoteAmount;
        /// @notice Recipient of fees earned by the new-token founding position.
        /// @dev Must be address(0) for an existing-token market, which has no founding position.
        address lpFeeRecipient;
        /// @notice Tick spacing encoded in the PoolKey.
        int24 tickSpacing;
        /// @notice Initial square-root pool price encoded as Q64.96.
        /// @dev A new-token market must place this value exactly on a usable tick. This preserves
        ///      per-market modular pricing while making the value the boundary of the token-only
        ///      founding band.
        uint160 sqrtPriceX96;
        /// @notice Registered root-hook identifier selected for the pool.
        bytes32 kernelId;
        /// @notice Ordered module selections frozen before pool initialization.
        HookrModuleTypesV1.ModuleSelection[] modules;
        /// @notice Immutable limits and integration bindings frozen with the stack.
        HookrModuleTypesV1.StackLimits limits;
    }

    /// @notice Optional exact-input creator buy executed immediately after founding liquidity.
    /// @dev Available on every quote currency. A zero `quoteAmountIn` requires every companion
    ///      field to be empty. For an ERC-20 quote the creator must approve the market's trusted
    ///      router for `quoteAmountIn` before the launch transaction; `msg.value` must be zero.
    struct InitialBuyParams {
        /// @notice Exact quote amount supplied to the buy, or zero to disable it.
        uint128 quoteAmountIn;
        /// @notice Minimum subject amount the creator must receive.
        uint128 subjectAmountOutMinimum;
        /// @notice Last block timestamp at which the buy may execute.
        uint256 deadline;
        /// @notice Encoded data forwarded to the market's immutable hook stack.
        bytes moduleData;
    }

    /// @notice Complete arguments for a new-token market.
    struct NewTokenArgs {
        /// @notice Token name.
        string name;
        /// @notice Token symbol.
        string symbol;
        /// @notice Token metadata tagline.
        string tagline;
        /// @notice Token metadata image URI.
        string logoURI;
        /// @notice Creator recorded by the token and receiving optional initial-buy output.
        /// @dev Must equal `msg.sender`. The field is retained so `previewNewTokenAddress` and
        ///      `computeNewTokenSalt` stay pure functions of the launch arguments and the CREATE2
        ///      address remains predictable from any caller before the launch transaction.
        address expectedCreator;
        /// @notice Token supply minted at deployment; must equal `SUPPLY`.
        uint256 totalSupply;
        /// @notice Caller-supplied entropy included in the CREATE2 salt.
        bytes32 deploymentSalt;
        /// @notice Pool, seed, founding-fee, and immutable-stack parameters.
        MarketParams market;
        /// @notice Optional native-quote initial creator buy.
        InitialBuyParams initialBuy;
    }

    /// @notice Complete arguments for a fresh pool using an existing subject token.
    struct ExistingTokenArgs {
        /// @notice Already deployed subject token.
        address subject;
        /// @notice Pool and immutable-stack parameters, with all founding-position fields zero.
        MarketParams market;
    }

    /// @notice Coordinator record for an initialized market.
    struct Market {
        /// @notice True after the coordinator records the initialized market.
        /// @dev This flag does not indicate release activation or production availability.
        bool live;
        /// @notice Whether the subject was newly deployed or already existed.
        MarketOrigin origin;
        /// @notice Subject token paired by the pool.
        address subject;
        /// @notice Quote token, or address(0) for native currency.
        address quote;
        /// @notice Creator permanently attributed to the market.
        address creator;
        /// @notice Root hook implementation bound to the PoolKey.
        address kernel;
        /// @notice Recipient of fees earned by the founding position, or zero when absent.
        address lpFeeRecipient;
        /// @notice Registered root-hook identifier.
        bytes32 kernelId;
        /// @notice Commitment to the immutable hook stack.
        bytes32 stackHash;
        /// @notice Uniswap v4 PoolId for the market.
        PoolId poolId;
        /// @notice Initial square-root pool price encoded as Q64.96.
        uint160 sqrtPriceX96;
        /// @notice Tick spacing encoded in the PoolKey.
        int24 tickSpacing;
        /// @notice Maximum subject amount offered to the founding position.
        uint256 subjectSupplied;
        /// @notice Maximum quote amount offered to the founding position.
        uint256 quoteSupplied;
        /// @notice Subject amount consumed by the founding position.
        uint256 subjectUsed;
        /// @notice Quote amount consumed by the founding position.
        uint256 quoteUsed;
        /// @notice Cumulative currency0 fees collected from the founding position.
        uint256 cumulativeFee0;
        /// @notice Cumulative currency1 fees collected from the founding position.
        uint256 cumulativeFee1;
        /// @notice Block number at which the market record was created.
        uint256 openedAtBlock;
        /// @notice Optional creator intent identifier used by the launch.
        bytes32 launchIntentId;
        /// @notice Router that executed the initial creator buy, or zero when no buy occurred.
        address initialBuyRouter;
        /// @notice Creator token allocation; always zero for fixed-supply band launches.
        uint256 creatorAllocation;
        /// @notice Native quote amount consumed by the initial creator buy.
        uint256 initialBuyQuoteIn;
        /// @notice Subject amount delivered by the initial creator buy.
        uint256 initialBuySubjectOut;
        /// @notice Minimum subject output required by the initial creator buy.
        uint256 initialBuySubjectOutMinimum;
        /// @notice Hash of module data supplied to the initial creator buy.
        bytes32 initialBuyModuleDataHash;
    }

    /// @notice An owner-set, unconditional protocol share for one launcher address.
    struct Tier {
        /// @notice True once the owner sets this tier; a cleared tier falls back to the default.
        bool set;
        /// @notice Protocol share in bps applied by this tier.
        uint24 shareBps;
    }

    struct FundingBaselines {
        uint256 subject;
        uint256 quote;
    }

    struct OpenResult {
        PoolId poolId;
        uint256 subjectRefund;
        uint256 quoteRefund;
    }

    struct SeedResult {
        uint256 subjectUsed;
        uint256 quoteUsed;
        uint256 subjectRefund;
        uint256 quoteRefund;
    }

    /// @notice Uniswap v4 PoolManager used for initialization and founding-position accounting.
    IPoolManager public immutable poolManager;
    /// @notice Registry used to record immutable hook stacks.
    IHookrStackRegistryV1CoordinatorV3 public immutable stackRegistry;

    /// @notice Account authorized to configure market-opening availability and protocol-fee tiers.
    address public owner;
    /// @notice Account eligible to accept the pending ownership transfer.
    address public pendingOwner;
    /// @notice Hookr treasury receiving every market's protocol share.
    /// @dev Constructor-only: there is no setter. This must equal the canonical native block's
    ///      immutable `protocolRecipient`; admission enforces equality per market, so rotating this
    ///      value would de-admit every future market built against the live block. Rotation of who
    ///      actually gets paid happens at `HookrTreasuryForwarderV1.target`, behind the pinned
    ///      forwarder address this is set to.
    address public treasury;
    /// @notice True while only the owner may open markets.
    bool public marketOpeningPaused = true;
    /// @notice Protocol share, in bps, applied to a market with no matching tier.
    uint24 public defaultProtocolShareBps = 2_000;
    uint256 private reentrancyState = 1;
    uint8 private activeCallbackAction;
    PoolId private activeCallbackPoolId;

    /// @notice Returns the subject deployed for a creator and optional intent identifier.
    mapping(address creator => mapping(bytes32 intentId => address subject)) public launchedByIntent;
    /// @notice Returns the subject deployed from a derived CREATE2 salt.
    mapping(bytes32 create2Salt => address subject) public tokenByCreate2Salt;
    /// @notice Unconditional protocol-share tier for one creator (launcher) address.
    mapping(address creator => Tier tier) public creatorTier;
    mapping(PoolId poolId => Market market) private _markets;
    PoolId[] private marketIds;

    event OwnerProposed(address indexed pendingOwner);
    event OwnerSet(address indexed owner);
    event MarketOpeningPauseSet(bool paused);
    event DefaultProtocolShareBpsSet(uint24 shareBps);
    event CreatorTierSet(address indexed creator, uint24 shareBps);
    event CreatorTierCleared(address indexed creator);
    /// @notice Emitted once per market with the protocol share frozen into its immutable config.
    /// @param poolId Uniswap v4 PoolId for the market.
    /// @param creator Creator whose tier resolved the share.
    /// @param shareBps Protocol share, in bps, this market carries for its whole life.
    event ProtocolShareResolved(PoolId indexed poolId, address indexed creator, uint24 shareBps);
    /// @notice Emitted after a market is initialized and recorded.
    /// @param poolId Uniswap v4 PoolId for the market.
    /// @param subject Subject token paired by the pool.
    /// @param creator Creator permanently attributed to the market.
    /// @param quote Quote token, or address(0) for native currency.
    /// @param origin Whether the subject was newly deployed or already existed.
    /// @param kernel Root hook implementation bound to the PoolKey.
    /// @param lpFeeRecipient Founding-position fee recipient, or zero when no founding position exists.
    /// @param kernelId Registered root-hook identifier.
    /// @param stackHash Commitment to the immutable hook stack.
    /// @param sqrtPriceX96 Initial square-root pool price encoded as Q64.96.
    /// @param tickSpacing Tick spacing encoded in the PoolKey.
    /// @param subjectUsed Subject amount consumed by the founding position.
    /// @param quoteUsed Quote amount consumed by the founding position.
    event MarketCreated(
        PoolId indexed poolId,
        address indexed subject,
        address indexed creator,
        address quote,
        MarketOrigin origin,
        address kernel,
        address lpFeeRecipient,
        bytes32 kernelId,
        bytes32 stackHash,
        uint160 sqrtPriceX96,
        int24 tickSpacing,
        uint256 subjectUsed,
        uint256 quoteUsed
    );
    /// @notice Emitted after an optional initial creator buy settles.
    /// @param poolId Pool that executed the buy.
    /// @param subject Subject token delivered by the buy.
    /// @param creator Creator receiving the subject output.
    /// @param intentId Optional creator intent identifier.
    /// @param stackHash Commitment to the immutable hook stack.
    /// @param router Router selected by the immutable stack.
    /// @param requestedQuoteIn Exact native quote amount requested.
    /// @param actualQuoteIn Native quote amount consumed.
    /// @param subjectOut Subject amount delivered to the creator.
    /// @param subjectOutMinimum Minimum subject output required by the creator.
    /// @param moduleDataHash Hash of module data forwarded to the hook stack.
    /// @param creatorAllocation Creator token allocation; always zero.
    /// @param subjectSeedResidue Subject seed residue; always zero after quantization dust is burned.
    /// @param quoteSeedResidue Quote seed residue; always zero because quote is not seeded.
    event CreatorBuyExecuted(
        PoolId indexed poolId,
        address indexed subject,
        address indexed creator,
        bytes32 intentId,
        bytes32 stackHash,
        address router,
        uint256 requestedQuoteIn,
        uint256 actualQuoteIn,
        uint256 subjectOut,
        uint256 subjectOutMinimum,
        bytes32 moduleDataHash,
        uint256 creatorAllocation,
        uint256 subjectSeedResidue,
        uint256 quoteSeedResidue
    );
    /// @notice Emitted after fees are collected from a new-token founding position.
    /// @param poolId Pool containing the founding position.
    /// @param recipient Account receiving both collected currencies.
    /// @param amount0 Currency0 amount collected.
    /// @param amount1 Currency1 amount collected.
    event LpFeesCollected(PoolId indexed poolId, address indexed recipient, uint256 amount0, uint256 amount1);

    error NotOwner();
    error NotPendingOwner();
    error MarketOpeningPaused(address caller);
    error MarketOpeningPauseUnchanged();
    error ZeroAddress();
    error InvalidWiring();
    error InvalidMarketArgs();
    error InvalidToken();
    error UnexpectedToken(address expected, address actual);
    error NotCreator(address expected, address caller);
    error ProtocolShareAboveCeiling(uint24 shareBps);
    error DefaultProtocolShareBpsUnchanged();
    error CreatorTierUnchanged(address creator);
    error TierNotSet(address account);
    error IntentAlreadyUsed(address creator, bytes32 intentId, address subject);
    error TokenSaltAlreadyUsed(bytes32 create2Salt, address subject);
    error InvalidPayment(uint256 expected, uint256 received);
    error InvalidInitialBuy();
    error InitialBuyInputMismatch(uint256 expected, uint256 actual);
    error InitialBuyAboveCap(uint256 subjectOut, uint256 cap);
    error InvalidStack();
    error NativeMechanicsModuleRequired();
    error DuplicateMarket(PoolId poolId);
    error NoFoundingPosition(PoolId poolId);
    error ZeroLiquidity();
    error ExcessiveSettlement();
    error TransferFailed();
    error TaxedTransfer();
    error NativeTransferFailed();
    error NotPoolManager();
    error BadCallback();
    error ReentrantCall();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (reentrancyState != 1) revert ReentrantCall();
        reentrancyState = 2;
        _;
        reentrancyState = 1;
    }

    modifier onlyWhenMarketOpeningAllowed() {
        if (marketOpeningPaused && msg.sender != owner) revert MarketOpeningPaused(msg.sender);
        _;
    }

    /// @notice Initializes coordinator governance and immutable registry wiring.
    /// @param owner_ Initial owner.
    /// @param poolManager_ Uniswap v4 PoolManager used by every market.
    /// @param stackRegistry_ Registry used to create immutable hook stacks.
    /// @param treasury_ Hookr treasury receiving every market's protocol share.
    constructor(
        address owner_,
        IPoolManager poolManager_,
        IHookrStackRegistryV1CoordinatorV3 stackRegistry_,
        address treasury_
    ) {
        if (
            owner_ == address(0) || address(poolManager_) == address(0) || address(poolManager_).code.length == 0
                || address(stackRegistry_) == address(0) || address(stackRegistry_).code.length == 0
                || treasury_ == address(0)
        ) revert ZeroAddress();
        if (address(stackRegistry_.poolManager()) != address(poolManager_)) revert InvalidWiring();
        owner = owner_;
        poolManager = poolManager_;
        stackRegistry = stackRegistry_;
        treasury = treasury_;
        emit OwnerSet(owner_);
    }

    /// @notice Accepts native currency only from the PoolManager during settlement.
    receive() external payable {
        if (msg.sender != address(poolManager)) revert NativeTransferFailed();
    }

    /// @notice Returns the release identity used by deployment and integration tooling.
    function contractName() external pure virtual returns (string memory) {
        return "HookrMarketCoordinatorV5";
    }

    /// @notice Returns the coordinator interface version.
    function contractVersion() external pure virtual returns (string memory) {
        return "5.1.0";
    }

    /// @notice Returns the treasury address read by the native-mechanics guard accounting library.
    /// @dev V5 owns this value directly; V3/V4 read it from the partner registry.
    function treasuryBeneficiary() external view returns (address) {
        return treasury;
    }

    // ---------------------------------------------------------------- ownership

    /// @notice Proposes a new owner.
    /// @param nextOwner Account that may accept ownership.
    function proposeOwner(address nextOwner) external onlyOwner {
        if (nextOwner == address(0) || nextOwner == owner) revert ZeroAddress();
        pendingOwner = nextOwner;
        emit OwnerProposed(nextOwner);
    }

    /// @notice Accepts ownership as the pending owner.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnerSet(msg.sender);
    }

    // ---------------------------------------------------------------- protocol-share tiers

    /// @notice Returns the protocol share, in bps, a market opened by this creator must carry in
    ///         its native-mechanics config.
    /// @dev Resolution is exactly two steps: `creatorTier[creator]` when the owner has set one,
    ///      otherwise `defaultProtocolShareBps`. Nothing about the market's own fee split can move
    ///      the share. The library admitting a market reads this and rejects any config carrying a
    ///      different share, so the value is frozen with the config at creation and later tier
    ///      changes never touch a live pool. The share is taken from inside the pool's opted-in
    ///      add-ons only; the base LP fee always stays whole with in-range LPs.
    /// @param creator Account opening the market.
    function protocolShareBps(address creator) public view returns (uint24 shareBps) {
        Tier memory tier = creatorTier[creator];
        if (tier.set) return tier.shareBps;
        return defaultProtocolShareBps;
    }

    /// @notice Sets the protocol share applied to markets whose creator has no tier.
    /// @dev Applies to FUTURE markets only. Every live pool keeps the share frozen into its own
    ///      immutable config at creation.
    /// @param shareBps New default share in bps, at most `MAX_PROTOCOL_SHARE_BPS`.
    function setDefaultProtocolShareBps(uint24 shareBps) external onlyOwner {
        if (shareBps > MAX_PROTOCOL_SHARE_BPS) revert ProtocolShareAboveCeiling(shareBps);
        if (shareBps == defaultProtocolShareBps) revert DefaultProtocolShareBpsUnchanged();
        defaultProtocolShareBps = shareBps;
        emit DefaultProtocolShareBpsSet(shareBps);
    }

    /// @notice Sets an unconditional protocol-share tier for one launcher address.
    /// @dev This is the integrator mechanism. `creator` is whatever address calls
    ///      `openNewTokenMarket`/`openExistingTokenMarket`, so granting a tier to a *contract*
    ///      launcher applies that share to every market that contract ever opens, for every one of
    ///      its end users, until the tier is cleared. Granting a tier to an EOA covers only that
    ///      EOA's own launches. Nothing else about a market can earn the share, and no tier change
    ///      ever reaches a market that already exists.
    /// @param creator Launcher address whose markets all carry `shareBps`.
    /// @param shareBps Tier share in bps, at most `MAX_PROTOCOL_SHARE_BPS`; zero is allowed.
    function setCreatorTier(address creator, uint24 shareBps) external onlyOwner {
        if (creator == address(0)) revert ZeroAddress();
        if (shareBps > MAX_PROTOCOL_SHARE_BPS) revert ProtocolShareAboveCeiling(shareBps);
        Tier memory tier = creatorTier[creator];
        if (tier.set && tier.shareBps == shareBps) revert CreatorTierUnchanged(creator);
        creatorTier[creator] = Tier({set: true, shareBps: shareBps});
        emit CreatorTierSet(creator, shareBps);
    }

    /// @notice Clears a creator tier, returning that launcher to the default rate.
    function clearCreatorTier(address creator) external onlyOwner {
        if (!creatorTier[creator].set) revert TierNotSet(creator);
        delete creatorTier[creator];
        emit CreatorTierCleared(creator);
    }

    // ---------------------------------------------------------------- market opening policy

    /// @notice Sets whether non-owner callers may open markets.
    /// @dev The owner may open markets while paused. Any operational review or authorization is
    ///      enforced offchain.
    /// @param paused_ True to restrict market opening to the owner.
    function setMarketOpeningPaused(bool paused_) external onlyOwner {
        if (paused_ == marketOpeningPaused) revert MarketOpeningPauseUnchanged();
        marketOpeningPaused = paused_;
        emit MarketOpeningPauseSet(paused_);
    }

    // ---------------------------------------------------------------- market opening

    /// @notice Deploys a HookrTokenV61, opens its modular pool, and optionally executes a native-quote
    ///         initial creator buy.
    /// @dev The caller is the creator. The complete fixed supply is placed in one coordinator-held
    ///      token-only band before the optional buy. No quote is seeded and no token allocation is
    ///      transferred to the creator. Any sub-unit band-quantization residue is burned. The
    ///      coordinator exposes no liquidity-removal path.
    /// @param args Token, seed, stack, fee-recipient, and optional initial-buy parameters.
    /// @param intentId Optional creator intent identifier.
    /// @param expectedToken Optional caller-supplied token-address assertion, or zero to skip it.
    /// @return subject Deployed HookrTokenV61 address.
    /// @return poolId Initialized Uniswap v4 PoolId.
    function openNewTokenMarket(NewTokenArgs calldata args, bytes32 intentId, address expectedToken)
        external
        payable
        onlyWhenMarketOpeningAllowed
        nonReentrant
        returns (address subject, PoolId poolId)
    {
        address creator = msg.sender;
        if (args.expectedCreator != creator) revert NotCreator(args.expectedCreator, creator);
        if (
            args.totalSupply != SUPPLY || args.market.subjectAmount != SUPPLY || args.market.quoteAmount != 0
                || args.market.lpFeeRecipient == address(0) || args.market.lpFeeRecipient == address(this)
        ) {
            revert InvalidMarketArgs();
        }
        _validateInitialBuy(args.market, args.initialBuy);
        if (intentId != bytes32(0)) {
            address prior = launchedByIntent[creator][intentId];
            if (prior != address(0)) revert IntentAlreadyUsed(creator, intentId, prior);
        }
        bytes32 create2Salt = _newTokenSalt(args, intentId);
        address priorAtSalt = tokenByCreate2Salt[create2Salt];
        if (priorAtSalt != address(0)) revert TokenSaltAlreadyUsed(create2Salt, priorAtSalt);
        _validatePayment(args.market, args.initialBuy.quoteAmountIn);

        subject = HookrMarketCoordinatorTokenDeployerV3.deploy(
            args.name, args.symbol, args.tagline, args.logoURI, creator, args.totalSupply, create2Salt
        );
        if (expectedToken != address(0) && subject != expectedToken) revert UnexpectedToken(expectedToken, subject);
        _validateMarketArgs(subject, args.market, true);

        if (_balanceOf(subject, address(this)) != args.totalSupply) revert TaxedTransfer();

        uint256 quoteBaseline = _fundQuote(args.market);
        // Only a native initial buy is held by this contract between funding and execution. An
        // ERC-20 quote never enters the coordinator at all: the router pulls it straight from the
        // creator's own approval, and `_validatePayment` has already required `msg.value == 0`.
        uint256 heldForInitialBuy = args.market.quote == address(0) ? uint256(args.initialBuy.quoteAmountIn) : 0;
        FundingBaselines memory baselines = FundingBaselines({subject: 0, quote: quoteBaseline + heldForInitialBuy});
        OpenResult memory opened = _openMarket(MarketOrigin.NEW_TOKEN, subject, creator, args.market, baselines);
        poolId = opened.poolId;

        Market storage market = _markets[poolId];
        market.launchIntentId = intentId;
        if (args.initialBuy.quoteAmountIn != 0) {
            PoolKey memory key = _poolKey(subject, args.market.quote, market.kernel, args.market.tickSpacing);
            IHookrKernelRouterV2.InitialBuyParams memory buyParams = IHookrKernelRouterV2.InitialBuyParams({
                key: key,
                creator: creator,
                quoteAmountIn: args.initialBuy.quoteAmountIn,
                subjectAmountOutMinimum: args.initialBuy.subjectAmountOutMinimum,
                deadline: args.initialBuy.deadline
            });
            (uint256 actualQuoteIn, uint256 subjectOut) = HookrMarketCoordinatorInitialBuyLibV4.executeAndEmit(
                HookrMarketCoordinatorInitialBuyLibV4.EmitContext({
                    poolId: poolId,
                    subject: subject,
                    intentId: intentId,
                    stackHash: market.stackHash,
                    quote: args.market.quote,
                    router: args.market.limits.trustedRouter,
                    subjectSeedResidue: opened.subjectRefund,
                    quoteSeedResidue: opened.quoteRefund
                }),
                buyParams,
                args.initialBuy.moduleData
            );
            // The delivered amount is what the creator ends up holding, net of any auto-burn, and
            // is capped identically on every quote currency.
            if (subjectOut > MAX_INITIAL_BUY_SUBJECT) revert InitialBuyAboveCap(subjectOut, MAX_INITIAL_BUY_SUBJECT);
            bytes32 moduleDataHash = keccak256(args.initialBuy.moduleData);
            market.initialBuyRouter = args.market.limits.trustedRouter;
            market.initialBuyQuoteIn = actualQuoteIn;
            market.initialBuySubjectOut = subjectOut;
            market.initialBuySubjectOutMinimum = args.initialBuy.subjectAmountOutMinimum;
            market.initialBuyModuleDataHash = moduleDataHash;
        }

        if (opened.subjectRefund != 0 || opened.quoteRefund != 0) revert ExcessiveSettlement();
        _assertHeld(subject, 0, 0);
        _assertHeld(args.market.quote, quoteBaseline, 0);
        tokenByCreate2Salt[create2Salt] = subject;
        if (intentId != bytes32(0)) launchedByIntent[creator][intentId] = subject;
    }

    /// @notice Initializes a fresh modular pool for an already deployed subject token without adding
    ///         liquidity.
    /// @dev The caller is the creator. `subjectAmount`, `quoteAmount`, and `lpFeeRecipient` must be
    ///      zero. This path has no initial creator buy. Liquidity is added and removed separately
    ///      through v4 periphery.
    /// @param args Existing subject and immutable pool-stack parameters.
    /// @return poolId Initialized zero-liquidity Uniswap v4 PoolId.
    function openExistingTokenMarket(ExistingTokenArgs calldata args)
        external
        payable
        onlyWhenMarketOpeningAllowed
        nonReentrant
        returns (PoolId poolId)
    {
        address creator = msg.sender;
        _validateExistingToken(args.subject);
        // Existing-token market creation is initialization only. Liquidity remains a separate
        // caller-owned periphery action subject to the frozen stack's add-liquidity policy; this
        // coordinator never escrows or locks a caller-supplied existing-token position.
        if (args.market.subjectAmount != 0 || args.market.quoteAmount != 0 || args.market.lpFeeRecipient != address(0)) revert InvalidMarketArgs();
        _validateMarketArgs(args.subject, args.market, true);
        _validatePayment(args.market, 0);

        OpenResult memory opened = _openMarket(
            MarketOrigin.EXISTING_TOKEN, args.subject, creator, args.market, FundingBaselines({subject: 0, quote: 0})
        );
        poolId = opened.poolId;
    }

    /// @notice Collects fees accrued to the coordinator-held founding position and routes 100% of
    ///         both currencies to the market's fee recipient.
    /// @dev Anyone may call this function. It does not collect fees owned by external LP positions.
    ///      Nothing is withheld: base fee earned during the guard window belongs to the founding
    ///      position like any other LP fee, and the protocol's revenue comes from its share inside
    ///      each opted-in add-on at swap time instead. Existing-token markets have no founding
    ///      position and revert.
    /// @param poolId New-token pool containing the founding position.
    /// @return amount0 Currency0 amount collected and forwarded.
    /// @return amount1 Currency1 amount collected and forwarded.
    function collectLpFees(PoolId poolId) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        Market storage market = _markets[poolId];
        if (!market.live) revert InvalidMarketArgs();
        if (market.origin != MarketOrigin.NEW_TOKEN || market.lpFeeRecipient == address(0) || market.subjectUsed == 0) {
            revert NoFoundingPosition(poolId);
        }

        PoolKey memory key = _poolKey(market.subject, market.quote, market.kernel, market.tickSpacing);
        (int24 tickLower, int24 tickUpper) = _foundingTickRange(market.subject, key, market.sqrtPriceX96);
        uint256 baseline0 = _balanceOf(Currency.unwrap(key.currency0), address(this));
        uint256 baseline1 = _balanceOf(Currency.unwrap(key.currency1), address(this));
        activeCallbackAction = CB_COLLECT_BAND;
        activeCallbackPoolId = poolId;
        (amount0, amount1) =
            abi.decode(poolManager.unlock(abi.encode(CB_COLLECT_BAND, key, tickLower, tickUpper)), (uint256, uint256));
        _clearActiveCallback();

        _assertHeld(Currency.unwrap(key.currency0), baseline0, amount0);
        _assertHeld(Currency.unwrap(key.currency1), baseline1, amount1);
        HookrNativeMechanicsCoordinatorLibV2.routeFoundingPositionFees(
            HookrNativeMechanicsCoordinatorLibV2.FeeRouteInput({
                poolId: PoolId.unwrap(poolId),
                currency0: Currency.unwrap(key.currency0),
                currency1: Currency.unwrap(key.currency1),
                lpFeeRecipient: market.lpFeeRecipient,
                amount0: amount0,
                amount1: amount1
            })
        );
        _assertHeld(Currency.unwrap(key.currency0), baseline0, 0);
        _assertHeld(Currency.unwrap(key.currency1), baseline1, 0);

        market.cumulativeFee0 += amount0;
        market.cumulativeFee1 += amount1;
    }

    /// @dev Shared immutable-stack and initialization pipeline. NEW_TOKEN continues into one
    ///      coordinator-held position with no removal path; EXISTING_TOKEN remains at zero liquidity.
    function _openMarket(
        MarketOrigin origin,
        address subject,
        address creator,
        MarketParams calldata params,
        FundingBaselines memory baselines
    ) internal returns (OpenResult memory opened) {
        IHookrStackRegistryV1CoordinatorV3.KernelSnapshot memory kernel = stackRegistry.activeKernel(params.kernelId);
        if (
            kernel.kernelId != params.kernelId || kernel.implementation == address(0)
                || kernel.implementation.code.length == 0
        ) revert InvalidStack();

        PoolKey memory key = _poolKey(subject, params.quote, kernel.implementation, params.tickSpacing);
        PoolId poolId = key.toId();
        if (_markets[poolId].live) revert DuplicateMarket(poolId);
        address nativeModule = HookrNativeMechanicsCoordinatorLibV2.validateAndRecordMarket(
            IHookrNativeMechanicsCatalogReadV1(address(stackRegistry)),
            uint8(origin),
            params.limits.baseLpFeePips,
            params.modules,
            PoolId.unwrap(poolId),
            address(this),
            creator
        );
        // Every V5 pool carries the enforced protocol flywheel fee, so the native block is mandatory.
        if (nativeModule == address(0)) revert NativeMechanicsModuleRequired();

        HookrMarketCoordinatorKernelReservationLibV1.consume(
            stackRegistry, params.kernelId, kernel.implementation, msg.sender
        );

        (PoolId registeredPoolId, bytes32 stackHash) =
            stackRegistry.createStack(key, subject, params.quote, params.kernelId, params.modules, params.limits);
        if (PoolId.unwrap(registeredPoolId) != PoolId.unwrap(poolId) || stackHash == bytes32(0)) {
            revert InvalidStack();
        }

        // `createStack` is the freeze boundary. Initialization may start only after the complete
        // stack exists, and the kernel must not have marked it initialized before its hook runs.
        HookrModuleTypesV1.StackCore memory frozen = stackRegistry.stack(poolId);
        if (!_matchesStack(frozen, subject, params.quote, kernel.implementation, params.kernelId, stackHash)) {
            revert InvalidStack();
        }
        if (frozen.initialized) revert InvalidStack();

        poolManager.initialize(key, params.sqrtPriceX96);
        HookrModuleTypesV1.StackCore memory initialized = stackRegistry.stack(poolId);
        if (
            !_matchesStack(initialized, subject, params.quote, kernel.implementation, params.kernelId, stackHash)
                || !initialized.initialized
        ) revert InvalidStack();

        SeedResult memory seed;
        if (origin == MarketOrigin.NEW_TOKEN) {
            if (
                params.subjectAmount != SUPPLY || params.quoteAmount != 0 || params.lpFeeRecipient == address(0)
                    || params.lpFeeRecipient == address(this)
            ) revert InvalidMarketArgs();
            seed = _seedLockedPosition(subject, key, poolId, params, baselines);
        } else if (
            origin != MarketOrigin.EXISTING_TOKEN || params.subjectAmount != 0 || params.quoteAmount != 0
                || params.lpFeeRecipient != address(0) || baselines.subject != 0 || baselines.quote != 0
        ) {
            revert InvalidMarketArgs();
        }

        Market storage market = _markets[poolId];
        market.live = true;
        market.origin = origin;
        market.subject = subject;
        market.quote = params.quote;
        market.creator = creator;
        market.kernel = kernel.implementation;
        market.lpFeeRecipient = params.lpFeeRecipient;
        market.kernelId = params.kernelId;
        market.stackHash = stackHash;
        market.poolId = poolId;
        market.sqrtPriceX96 = params.sqrtPriceX96;
        market.tickSpacing = params.tickSpacing;
        market.subjectSupplied = params.subjectAmount;
        market.quoteSupplied = params.quoteAmount;
        market.subjectUsed = seed.subjectUsed;
        market.quoteUsed = seed.quoteUsed;
        market.openedAtBlock = block.number;
        marketIds.push(poolId);
        emit MarketCreated(
            poolId,
            subject,
            creator,
            params.quote,
            origin,
            kernel.implementation,
            params.lpFeeRecipient,
            params.kernelId,
            stackHash,
            params.sqrtPriceX96,
            params.tickSpacing,
            seed.subjectUsed,
            seed.quoteUsed
        );
        // Admission already proved the frozen config carries exactly this share; recording it makes
        // the pool's permanent protocol share readable from logs without decoding the module config.
        emit ProtocolShareResolved(poolId, creator, protocolShareBps(creator));
        opened = OpenResult({poolId: poolId, subjectRefund: seed.subjectRefund, quoteRefund: seed.quoteRefund});
    }

    function _seedLockedPosition(
        address subject,
        PoolKey memory key,
        PoolId poolId,
        MarketParams calldata params,
        FundingBaselines memory baselines
    ) internal returns (SeedResult memory result) {
        _assertHeld(subject, baselines.subject, params.subjectAmount);
        _assertHeld(params.quote, baselines.quote, 0);

        (int24 tickLower, int24 tickUpper) = _foundingTickRange(subject, key, params.sqrtPriceX96);
        uint256 amount0 = Currency.unwrap(key.currency0) == subject ? params.subjectAmount : 0;
        uint256 amount1 = Currency.unwrap(key.currency1) == subject ? params.subjectAmount : 0;
        activeCallbackAction = CB_SEED_BAND;
        activeCallbackPoolId = poolId;
        (uint256 used0, uint256 used1) = abi.decode(
            poolManager.unlock(
                abi.encode(CB_SEED_BAND, key, params.sqrtPriceX96, tickLower, tickUpper, amount0, amount1)
            ),
            (uint256, uint256)
        );
        _clearActiveCallback();

        result.subjectUsed = amount0 == 0 ? used1 : used0;
        result.quoteUsed = amount0 == 0 ? used0 : used1;
        if (result.subjectUsed == 0 || result.subjectUsed > params.subjectAmount || result.quoteUsed != 0) {
            revert ExcessiveSettlement();
        }

        uint256 residue = uint256(params.subjectAmount) - result.subjectUsed;
        if (residue != 0) _transferExact(subject, DEAD, residue);
        _assertHeld(subject, baselines.subject, 0);
        _assertHeld(params.quote, baselines.quote, 0);
    }

    // ---------------------------------------------------------------- PoolManager callback

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        uint8 action = abi.decode(data[:32], (uint8));
        PoolKey memory key;
        if (action == CB_SEED_BAND) {
            (, key,,,,,) = abi.decode(data, (uint8, PoolKey, uint160, int24, int24, uint256, uint256));
        } else if (action == CB_COLLECT_BAND) {
            (, key,,) = abi.decode(data, (uint8, PoolKey, int24, int24));
        } else {
            revert BadCallback();
        }
        if (
            action != activeCallbackAction || PoolId.unwrap(activeCallbackPoolId) == bytes32(0)
                || PoolId.unwrap(key.toId()) != PoolId.unwrap(activeCallbackPoolId)
        ) revert BadCallback();

        int24 tickLower;
        int24 tickUpper;
        if (action == CB_COLLECT_BAND) {
            (,, tickLower, tickUpper) = abi.decode(data, (uint8, PoolKey, int24, int24));
            (bool collectionValid, uint256 amount0Collected, uint256 amount1Collected) =
                HookrMarketCoordinatorTokenDeployerV3.collectBand(poolManager, key, tickLower, tickUpper);
            if (!collectionValid) revert ExcessiveSettlement();
            return abi.encode(amount0Collected, amount1Collected);
        }

        uint160 sqrtPriceX96;
        uint256 amount0;
        uint256 amount1;
        (,, sqrtPriceX96, tickLower, tickUpper, amount0, amount1) =
            abi.decode(data, (uint8, PoolKey, uint160, int24, int24, uint256, uint256));
        (bool seedValid, uint256 used0, uint256 used1) = HookrMarketCoordinatorTokenDeployerV3.seedBand(
            poolManager, key, sqrtPriceX96, tickLower, tickUpper, amount0, amount1
        );
        if (!seedValid) revert ZeroLiquidity();

        if (used0 != 0) _settle(key.currency0, used0);
        if (used1 != 0) _settle(key.currency1, used1);
        return abi.encode(used0, used1);
    }

    function _foundingTickRange(address subject, PoolKey memory key, uint160 sqrtPriceX96)
        internal
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        bool valid;
        (valid, tickLower, tickUpper) =
            HookrMarketCoordinatorTokenDeployerV3.foundingTickRange(subject, key, sqrtPriceX96, BAND_TICKS);
        if (!valid) revert InvalidMarketArgs();
    }

    function _clearActiveCallback() internal {
        activeCallbackAction = 0;
        activeCallbackPoolId = PoolId.wrap(bytes32(0));
    }

    // ---------------------------------------------------------------- reads and validation

    /// @notice Returns the number of markets recorded by the coordinator.
    /// @return Number of initialized market records.
    function marketCount() external view returns (uint256) {
        return marketIds.length;
    }

    /// @notice Returns the coordinator record for a pool.
    /// @param poolId Pool to query.
    /// @return market Recorded market, or a zero-valued struct when absent.
    function getMarket(PoolId poolId) external view returns (Market memory market) {
        market = _markets[poolId];
    }

    /// @notice Returns the bound native module and its cumulative quote-denominated guard-window
    ///         LP earnings.
    /// @dev Informational. Nothing is withheld from a founding position, so there is no
    ///      quarantined or pending amount to report.
    function guardLpFeeAccounting(PoolId poolId) external view returns (address module, uint256 cumulativeEarned) {
        return HookrNativeMechanicsCoordinatorLibV2.guardAccounting(PoolId.unwrap(poolId));
    }

    /// @notice Largest subject amount an initial creator buy may deliver, for every quote currency.
    /// @dev Exposed so a launch wizard can solve for the largest quote amount that lands on it.
    function maxInitialBuySubject() external pure returns (uint256) {
        return MAX_INITIAL_BUY_SUBJECT;
    }

    /// @notice Deterministic HookrTokenV61 address available before pool-bound dependencies exist.
    /// @param args New-token constructor and salt inputs.
    /// @param intentId Optional creator intent identifier included in the salt.
    /// @return predicted Counterfactual token address.
    function previewNewTokenAddress(NewTokenArgs calldata args, bytes32 intentId)
        external
        view
        returns (address predicted)
    {
        predicted = _previewNewTokenAddress(args, intentId);
    }

    /// @notice Returns the CREATE2 salt derived for a new-token launch.
    /// @param args New-token constructor and salt inputs.
    /// @param intentId Optional creator intent identifier included in the salt.
    /// @return Derived CREATE2 salt.
    function computeNewTokenSalt(NewTokenArgs calldata args, bytes32 intentId) external view returns (bytes32) {
        return _newTokenSalt(args, intentId);
    }

    /// @notice Returns the PoolKey implied by a subject and market configuration.
    /// @dev This view accepts a counterfactual subject address. Mutating market paths additionally
    ///      require deployed subject code.
    /// @param subject Subject token or counterfactual new-token address.
    /// @param params Quote, price, tick-spacing, and kernel selection.
    /// @return key Sorted Uniswap v4 PoolKey.
    function poolKeyFor(address subject, MarketParams calldata params) external view returns (PoolKey memory key) {
        _validateMarketArgs(subject, params, false);
        IHookrStackRegistryV1CoordinatorV3.KernelSnapshot memory kernel = stackRegistry.activeKernel(params.kernelId);
        key = _poolKey(subject, params.quote, kernel.implementation, params.tickSpacing);
    }

    function _newTokenSalt(NewTokenArgs calldata args, bytes32 intentId) internal view returns (bytes32 create2Salt) {
        if (
            args.expectedCreator == address(0) || args.totalSupply == 0
                || (intentId == bytes32(0) && args.deploymentSalt == bytes32(0))
        ) revert InvalidMarketArgs();
        create2Salt = keccak256(
            abi.encode(
                TOKEN_SALT_DOMAIN,
                block.chainid,
                address(this),
                args.expectedCreator,
                intentId,
                args.deploymentSalt,
                keccak256(bytes(args.name)),
                keccak256(bytes(args.symbol)),
                keccak256(bytes(args.tagline)),
                keccak256(bytes(args.logoURI)),
                args.totalSupply
            )
        );
    }

    function _previewNewTokenAddress(NewTokenArgs calldata args, bytes32 intentId)
        internal
        view
        returns (address predicted)
    {
        bytes32 create2Salt = _newTokenSalt(args, intentId);
        bytes32 initCodeHash = HookrMarketCoordinatorTokenDeployerV3.initCodeHash(
            args.name, args.symbol, args.tagline, args.logoURI, args.expectedCreator, args.totalSupply
        );
        predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), create2Salt, initCodeHash))))
        );
    }

    function _validateExistingToken(address subject) internal view {
        if (subject == address(0) || subject.code.length == 0) revert InvalidToken();
    }

    function _validateMarketArgs(address subject, MarketParams calldata params, bool requireSubjectCode) internal view {
        if (
            subject == address(0) || (requireSubjectCode && subject.code.length == 0) || params.quote == subject
                || (params.quote != address(0) && params.quote.code.length == 0) || params.tickSpacing <= 0
                || params.tickSpacing > type(int16).max || params.sqrtPriceX96 == 0 || params.kernelId == bytes32(0)
        ) revert InvalidMarketArgs();
        int24 lower = TickMath.minUsableTick(params.tickSpacing);
        int24 upper = TickMath.maxUsableTick(params.tickSpacing);
        if (
            params.sqrtPriceX96 <= TickMath.getSqrtPriceAtTick(lower)
                || params.sqrtPriceX96 >= TickMath.getSqrtPriceAtTick(upper)
        ) revert InvalidMarketArgs();
        IHookrStackRegistryV1CoordinatorV3.KernelSnapshot memory kernel = stackRegistry.activeKernel(params.kernelId);
        if (
            kernel.kernelId != params.kernelId || kernel.implementation == address(0)
                || kernel.implementation.code.length == 0
        ) revert InvalidStack();
    }

    function _validateInitialBuy(MarketParams calldata market, InitialBuyParams calldata initialBuy) internal view {
        HookrMarketCoordinatorInitialBuyLibV4.validate(
            address(poolManager),
            address(stackRegistry),
            market.limits.trustedRouter,
            initialBuy.quoteAmountIn,
            initialBuy.subjectAmountOutMinimum,
            initialBuy.deadline,
            initialBuy.moduleData
        );
    }

    function _validatePayment(MarketParams calldata params, uint256 initialBuyQuoteAmount) internal view {
        uint256 expected = params.quote == address(0) ? uint256(params.quoteAmount) + initialBuyQuoteAmount : 0;
        if (msg.value != expected) revert InvalidPayment(expected, msg.value);
    }

    function _matchesStack(
        HookrModuleTypesV1.StackCore memory stack_,
        address subject,
        address quote,
        address kernel,
        bytes32 kernelId,
        bytes32 stackHash
    ) internal pure returns (bool) {
        return stack_.configured && stack_.kernel == kernel && stack_.kernelId == kernelId && stack_.subject == subject
            && stack_.quote == quote && stack_.stackHash == stackHash;
    }

    function _poolKey(address subject, address quote, address kernel, int24 tickSpacing)
        internal
        pure
        returns (PoolKey memory key)
    {
        (address currency0, address currency1) = subject < quote ? (subject, quote) : (quote, subject);
        key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(kernel)
        });
    }

    // ---------------------------------------------------------------- exact custody and settlement

    function _fundQuote(MarketParams calldata params) internal returns (uint256 baseline) {
        if (params.quote == address(0)) return address(this).balance - msg.value;
        if (params.quoteAmount == 0) return _balanceOf(params.quote, address(this));
        return _pullExact(params.quote, msg.sender, params.quoteAmount);
    }

    function _pullExact(address token, address from, uint256 amount) internal returns (uint256 baseline) {
        baseline = _balanceOf(token, address(this));
        uint256 fromBefore = _balanceOf(token, from);
        if (!_callExactBool(token, abi.encodeWithSelector(bytes4(0x23b872dd), from, address(this), amount))) {
            revert TransferFailed();
        }
        uint256 afterBalance = _balanceOf(token, address(this));
        uint256 fromAfter = _balanceOf(token, from);
        if (
            afterBalance < baseline || afterBalance - baseline != amount || fromAfter > fromBefore
                || fromBefore - fromAfter != amount
        ) {
            revert TaxedTransfer();
        }
    }

    function _transferExact(address token, address to, uint256 amount) internal {
        uint256 selfBefore = _balanceOf(token, address(this));
        uint256 toBefore = _balanceOf(token, to);
        if (!_callExactBool(token, abi.encodeWithSelector(bytes4(0xa9059cbb), to, amount))) {
            revert TransferFailed();
        }
        uint256 selfAfter = _balanceOf(token, address(this));
        uint256 toAfter = _balanceOf(token, to);
        if (
            selfAfter > selfBefore || selfBefore - selfAfter != amount || toAfter < toBefore
                || toAfter - toBefore != amount
        ) {
            revert TaxedTransfer();
        }
    }

    function _balanceOf(address token, address account) internal view returns (uint256 balance) {
        if (token == address(0)) return account.balance;
        (bool ok, uint256 result) =
            _staticcallWord(token, TOKEN_QUERY_GAS, abi.encodeWithSelector(bytes4(0x70a08231), account));
        if (!ok) revert TransferFailed();
        balance = result;
    }

    function _staticcallWord(address target, uint256 gasLimit, bytes memory input)
        internal
        view
        returns (bool ok, uint256 word)
    {
        assembly ("memory-safe") {
            mstore(0, 0)
            ok := staticcall(gasLimit, target, add(input, 0x20), mload(input), 0, 0x20)
            if iszero(eq(returndatasize(), 0x20)) { ok := 0 }
            word := mload(0)
        }
    }

    function _callExactBool(address target, bytes memory input) internal returns (bool valid) {
        bool ok;
        uint256 returnSize;
        uint256 word;
        assembly ("memory-safe") {
            mstore(0, 0)
            ok := call(gas(), target, 0, add(input, 0x20), mload(input), 0, 0x20)
            returnSize := returndatasize()
            word := mload(0)
        }
        return ok && returnSize == 32 && word == 1;
    }

    function _assertHeld(address token, uint256 baseline, uint256 amount) internal view {
        if (_balanceOf(token, address(this)) != baseline + amount) revert TaxedTransfer();
    }

    function _settle(Currency currency, uint256 amount) internal {
        address token = Currency.unwrap(currency);
        uint256 paid;
        if (token == address(0)) {
            paid = poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            _transferExact(token, address(poolManager), amount);
            paid = poolManager.settle();
        }
        if (paid != amount) revert TaxedTransfer();
    }

    function _refund(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            _transferExact(token, to, amount);
        }
    }
}
