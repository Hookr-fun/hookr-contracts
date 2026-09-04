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
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

import {HookrAttachHook} from "./HookrAttachHook.sol";
import {V4PoolMath} from "./libraries/V4PoolMath.sol";

/// @title HookrExistingTokenFactory
/// @notice Attaches Hookr hook behavior to a token that ALREADY exists: the caller brings the
///         token and the ETH, and the factory opens a native-ETH Uniswap v4 pool wearing the
///         caller's configured `HookrAttachHook` blocks, seeds the founding full-range position
///         and optional token-only bands, and locks that liquidity by construction — exactly the
///         position shape `HookrLaunchpad` graduation produces, reached without a launch. The
///         attach half of the launchpad, the way `LeverageExistingTokenFactory` is the BYO half
///         of `LeverageFactory` — see contracts/HOOKR_ATTACH_DESIGN.md for why both exist.
///
///         The token boundary is ported from `LeverageExistingTokenFactory` verbatim in
///         semantics: every inbound transfer is verified by balance delta (fee-on-transfer
///         refused outright), every token call requires a decodable `true`, and a creation-wide
///         reentrancy lock spans the whole attach because `transferFrom` on a foreign token is a
///         call into code nobody here reviewed.
///
///         What it deliberately does NOT try to verify: that `sqrtPriceX96` matches where the
///         token really trades. No contract can read an external venue's price. A price far from
///         the real market is arbitraged against the attacher's own seed liquidity; the UI states
///         this, the factory enforces what is enforceable.
///
///         Blueprints: v1 accepts raw `HookParams` only. A blueprint-id launch would have to read
///         `HookrLaunchpad.getBlueprint` cross-contract and could not bump the blueprint's `uses`
///         counter (that write is launchpad-internal), so blueprint attaches are out of v1 scope
///         rather than shipped half-working.
contract HookrExistingTokenFactory is IUnlockCallback {
    using StateLibrary for IPoolManager;

    // ---------------------------------------------------------------- constants

    uint256 internal constant BPS = 10_000;
    uint24 internal constant DYNAMIC_FEE_FLAG = 0x800000;
    int24 public constant TICK_SPACING = 60;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint96 public constant MIN_POT_BUY_WEI = 0.001 ether;

    /// Creator's share of collected pool fees. 0 in `AttachArgs` means "use the default".
    uint16 public constant DEFAULT_CREATOR_FEE_BPS = 5000;
    /// The protocol keeps at least 20% of pool fees, so a creator can never take the whole cut.
    uint16 public constant MAX_CREATOR_FEE_BPS = 8000;
    /// Bounded so collection stays a fixed-cost loop no matter who configured the attach.
    uint256 public constant MAX_LP_TRANCHES = 4;
    /// A band must sit at least this far below the opening tick to be token-only.
    int24 public constant MIN_TRANCHE_OFFSET = 60;
    /// And no further than this, so a band cannot be placed where its liquidity stops fitting
    /// uint128 — same bound, same rationale, as `HookrLaunchpad.MAX_TRANCHE_OFFSET`.
    int24 public constant MAX_TRANCHE_OFFSET = 200_000;

    IPoolManager public immutable poolManager;
    HookrAttachHook public immutable hook;

    address public owner;
    address public pendingOwner; // two-step handover; see proposeOwner/acceptOwnership
    uint96 public creationFeeWei = 0.0002 ether;

    // ---------------------------------------------------------------- types

    /// @notice Creator-facing hook configuration — field-for-field the launchpad's `HookParams`,
    ///         redeclared here so the attach ABI stands alone.
    struct HookParams {
        // ANTI-SNIPE
        uint32 guardBlocks; // 0 = block disabled
        uint16 maxBuyBps; // max buy during guard, in bps of the PLANNED token placement (0 = uncapped)
        uint24 snipeTaxPips; // extra LP fee during guard
        // FEES (base always applies; maxFee > base enables surge)
        uint24 baseFeePips;
        uint24 maxFeePips; // 0 means "no surge block stacked" and normalizes to baseFeePips
        uint16 surgeSens; // 1-10
        // AUTO BURN (legacy field names retained in the ABI)
        uint16 burnBps;
        uint96 burnTriggerWei; // deprecated v2 field; configs MUST set this to zero
        // LP REWARDS
        uint16 lpBps;
        // JACKPOT
        uint16 potBps;
        uint32 potEveryNBuys; // every Nth qualifying buy wins the pot (deterministic, not random)
        uint96 potMinBuyWei;
    }

    /// @notice One token-only liquidity band sitting above the opening *price*. Same geometry as
    ///         the launchpad's `LpTranche`: the pool's v4 price is tokens-per-ETH, so a HIGHER
    ///         token price is a LOWER tick and both offsets are expressed as ticks below the
    ///         opening tick. `bps` is the band's share of `bandTokenAmount`.
    struct LpTranche {
        int24 startOffset; // ticks below the opening tick where the band begins
        int24 endOffset; // ticks below the opening tick where it ends; > startOffset
        uint16 bps; // share of `bandTokenAmount`
    }

    struct AttachArgs {
        address token; // the pre-existing 18-decimals ERC20
        uint160 sqrtPriceX96; // opening price, caller-attested to match where the token trades
        uint256 tokenAmount; // token leg of the founding full-range position
        uint256 bandTokenAmount; // tokens funding the optional token-only bands
        LpTranche[] bands; // max 4, token-only, above the open price; empty = full range only
        uint16 creatorFeeBps; // 0 = DEFAULT_CREATOR_FEE_BPS; capped at MAX_CREATOR_FEE_BPS
        HookParams hookParams;
    }

    struct Attachment {
        address token;
        address creator;
        uint40 attachBlock;
        uint16 creatorFeeBps;
        uint160 sqrtPriceX96AtAttach;
        PoolId poolId;
    }

    /// @notice One band of the preview plan. `seeded == false` would mean the band is skipped
    ///         with its slice landing in `tokenRefund` — but `_validateBands` now refuses any
    ///         plan containing such a band, so every band a successful preview returns is
    ///         seeded. The flag stays for ABI stability and for symmetry with the seed path's
    ///         retained defense-in-depth skips.
    struct BandPlan {
        bool seeded;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 tokensUsed;
    }

    /// @notice Everything `attach` would do with these inputs, computed with the pool's own
    ///         rounding so execution matches wei-for-wei.
    struct AttachPlan {
        uint256 openPriceWei; // wei per whole token implied by the attested sqrt price
        uint256 capTokens; // what `maxBuyBps` is a share of: the PLANNED placement
        uint96 maxBuyWei;
        uint128 liquidity; // founding full-range position
        uint256 ethUsed;
        uint256 tokensUsed;
        uint256 bandTokensUsed;
        uint256 ethRefund;
        uint256 tokenRefund;
        BandPlan[] bands;
    }

    // ---------------------------------------------------------------- storage

    /// @dev DELIBERATELY no `mapping(token => pool)` uniqueness slot (the BYO leverage factory's
    ///      `marketOf` shape): attach is permissionless-many across tokens, and a factory-owned
    ///      uniqueness mapping is a squatting surface with its own semantics to defend. The pool
    ///      identity itself is the gate that matters — the PoolKey is fully determined by the
    ///      token address, so a second attach of the same token dies in the hook's one-shot
    ///      `configurePool` (`AlreadyConfigured`) and in v4's own initialize. `attachments` below
    ///      is bookkeeping for fee collection, not an authorization slot.
    mapping(address token => Attachment) internal attachments;
    address[] public allTokens;
    /// token => bands seeded above the opening price (geometry re-derived at collection).
    mapping(address token => LpTranche[]) internal bandsOf;

    // fee accruals (pull payments)
    uint256 public protocolFeesWei;
    mapping(address token => uint256) public creatorFeesWei;
    mapping(address token => address) public creatorPayout; // token => payout address (0 = the creator)
    /// token => guard-window pool fees already routed past the creator's share, in wei. Monotone
    /// high-water mark against the hook's own cumulative `guardLpEarnedWei`; see collectPoolFees.
    mapping(address token => uint256) public guardFeesWithheldWei;
    /// token => ERC-6909 claim tokens held in place of a token-side burn the token refused.
    /// See `unlockCallback` CB_COLLECT and `retryDeferredBurn`.
    mapping(address token => uint256) public deferredBurnClaims;

    /// @dev Foreign-token calls can reenter; a creation-wide lock spans every entrypoint that
    ///      calls into token code. 1 = unlocked, 2 = locked (non-zero base saves gas).
    uint256 private lock = 1;

    uint8 internal constant CB_SEED = 1;
    uint8 internal constant CB_COLLECT = 2;
    uint8 internal constant CB_BAND = 3;
    uint8 internal constant CB_RETRY_BURN = 4;

    // ---------------------------------------------------------------- events

    event PoolAttached(
        address indexed token,
        PoolId indexed poolId,
        address indexed creator,
        uint160 sqrtPriceX96,
        uint256 ethUsed,
        uint256 tokensUsed,
        uint256 bandTokensUsed
    );
    event BandSeeded(
        address indexed token, uint256 indexed index, int24 tickLower, int24 tickUpper, uint256 tokensUsed
    );
    event PoolFeesCollected(address indexed token, uint256 ethAmount, uint256 tokensBurned, uint256 tokensDeferred);
    event DeferredBurnCompleted(address indexed token, uint256 tokensBurned);
    event CreatorFeesClaimed(address indexed token, address indexed payTo, uint256 amountWei);
    event CreatorPayoutSet(address indexed token, address indexed payTo);
    event ProtocolFeesWithdrawn(address indexed to, uint256 amountWei);
    event CreationFeeSet(uint96 feeWei);
    event OwnerProposed(address pendingOwner);
    event OwnerSet(address owner);

    // ---------------------------------------------------------------- errors

    error NotOwner();
    error ZeroAddress();
    error Reentered();
    error HookFlagsInvalid();
    error UnknownToken();
    error BadSeed();
    error BadToken();
    /// @dev All price, tranche, and guard math in this generation assumes 18/18 decimals between
    ///      ETH and the token — the same assumption pools.trade enforces. A 6-decimals token at an
    ///      attested price would be off by twelve orders of magnitude in every derived figure, so
    ///      non-18-decimals tokens are refused outright rather than rescaled.
    error NonStandardDecimals();
    /// @dev The token kept a cut of the transfer (fee-on-transfer / tax). The pool's accounting
    ///      assumes amounts move whole, so such tokens are refused outright.
    error TaxedTransfer();
    error TokenCallFailed();
    error BadHookParams();
    error BadFeeSplit();
    error BadLpPlan();
    error OpenPriceOutOfRange();
    error InsufficientPayment();
    error EthTransferFailed();
    error NotPoolManager();
    error BadCallback();
    error NothingToClaim();
    error FeeTooHigh();

    modifier nonReentrant() {
        if (lock != 1) revert Reentered();
        lock = 2;
        _;
        lock = 1;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev The hook is immutable on BOTH sides: this factory never changes hooks, and the hook's
    ///      `factory` is a constructor immutable with no setter. The deploy script predicts this
    ///      factory's address, mines the hook's CREATE2 salt against it, deploys the hook, then
    ///      deploys the factory — and these checks (the same ones `HookrLaunchpad.setHook` runs)
    ///      fail the construction outright if any leg of that 1:1 binding is wrong.
    constructor(IPoolManager poolManager_, HookrAttachHook hook_) {
        if (uint160(address(hook_)) & 0x3FFF != hook_.REQUIRED_FLAGS()) revert HookFlagsInvalid();
        if (hook_.factory() != address(this)) revert HookFlagsInvalid();
        if (address(hook_.poolManager()) != address(poolManager_)) revert HookFlagsInvalid();
        poolManager = poolManager_;
        hook = hook_;
        owner = msg.sender;
    }

    /// @notice Stable deployment identity for post-deploy readbacks and agent health checks.
    function contractName() external pure returns (string memory) {
        return "HookrExistingTokenFactory";
    }

    /// @notice Candidate generation. Runtime code hash remains the release authority.
    function contractVersion() external pure returns (string memory) {
        return "1.0.0";
    }

    /// @dev ETH only ever arrives from the PoolManager (fee-collection `take`). There is no
    ///      market-contract refund hop here — attach refunds are paid from the factory's own
    ///      retained `msg.value` — so nothing else may deposit.
    receive() external payable {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }

    // ---------------------------------------------------------------- admin (deliberately tiny)

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

    // ---------------------------------------------------------------- attach

    /// @notice Open a hook-wearing pool for an existing token and seed its locked liquidity.
    ///         `msg.value` must be exactly `creationFeeWei` + the seed ETH; every wei above the
    ///         fee that the position does not consume refunds in the same transaction.
    /// @dev The pool-open ordering is the launchpad's `openPool` verbatim: configure the hook
    ///      (register-on-hook BEFORE initialize — `beforeInitialize` refuses an unconfigured
    ///      pool), initialize at the attested price, push the base fee, then seed inside one
    ///      unlock. The seed is one-shot by construction: a second attach of the same token dies
    ///      in the hook's write-once `configurePool`.
    function attach(AttachArgs calldata a) external payable nonReentrant returns (PoolId poolId) {
        if (msg.value <= creationFeeWei) revert InsufficientPayment();
        uint256 ethForPool = msg.value - creationFeeWei;
        _validateAttach(a, ethForPool);

        // Pull both token legs in one transfer and require they arrived whole. The balance
        // delta — not the transfer's return value — is the fact that matters: a fee-on-transfer
        // token "succeeds" while delivering less, and every downstream number would be wrong.
        uint256 totalPull = a.tokenAmount + a.bandTokenAmount;
        uint256 before = _balanceOf(a.token, address(this));
        _safeTransferFrom(a.token, msg.sender, address(this), totalPull);
        if (_balanceOf(a.token, address(this)) - before != totalPull) revert TaxedTransfer();

        PoolKey memory key = _poolKey(a.token);
        poolId = key.toId();

        // Bookkeeping before the pool opens so collection reads the same geometry that seeds.
        // If this token's pool already exists, `configurePool` below reverts and rolls all of
        // this back atomically.
        Attachment storage at = attachments[a.token];
        at.token = a.token;
        at.creator = msg.sender;
        at.attachBlock = uint40(block.number);
        at.creatorFeeBps = a.creatorFeeBps;
        at.sqrtPriceX96AtAttach = a.sqrtPriceX96;
        at.poolId = poolId;
        for (uint256 i; i < a.bands.length; ++i) {
            bandsOf[a.token].push(a.bands[i]);
        }
        allTokens.push(a.token);
        protocolFeesWei += creationFeeWei;

        // Configure behavior, then create the pool (beforeInitialize enforces this ordering),
        // then seed the locked full-range position.
        hook.configurePool(key, _buildPoolConfig(a.hookParams, _openPriceWei(a.sqrtPriceX96), _capTokens(a)));
        poolManager.initialize(key, a.sqrtPriceX96);
        hook.syncBaseFee(key);
        (uint256 ethUsed, uint256 tokensUsed) = abi.decode(
            poolManager.unlock(abi.encode(CB_SEED, key, a.sqrtPriceX96, ethForPool, a.tokenAmount)), (uint256, uint256)
        );

        uint256 bandTokensUsed = _seedBands(a.token, key, a.bandTokenAmount);

        // Leftovers REFUND to the caller, never burn. The launchpad burns unplaced supply because
        // it minted that supply and no one ever owned it; here every token is the caller's own
        // property, so tokens the position and bands could not absorb — including any skipped
        // band's slice — go back where they came from.
        uint256 tokenRefund = (a.tokenAmount - tokensUsed) + (a.bandTokenAmount - bandTokensUsed);
        if (tokenRefund > 0) _safeTransfer(a.token, msg.sender, tokenRefund);
        uint256 ethRefund = ethForPool - ethUsed;
        if (ethRefund > 0) _sendEth(msg.sender, ethRefund);

        emit PoolAttached(a.token, poolId, msg.sender, a.sqrtPriceX96, ethUsed, tokensUsed, bandTokensUsed);
    }

    /// @notice Exactly what `attach` would do with these inputs — every validation revert
    ///         included — with `ethForPool` standing in for `msg.value - creationFeeWei`.
    ///         Amounts are computed with the pool's own rounding (`SqrtPriceMath`, round-up on
    ///         deposits), so a successful preview matches execution wei-for-wei.
    function previewAttach(AttachArgs calldata a, uint256 ethForPool) external view returns (AttachPlan memory plan) {
        _validateAttach(a, ethForPool);

        (int24 tickLower, int24 tickUpper) = V4PoolMath.usableTickRange(TICK_SPACING);
        uint160 sqrtLower = V4PoolMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = V4PoolMath.getSqrtPriceAtTick(tickUpper);

        plan.openPriceWei = _openPriceWei(a.sqrtPriceX96);
        plan.capTokens = _capTokens(a);
        plan.maxBuyWei = _buildPoolConfig(a.hookParams, plan.openPriceWei, plan.capTokens).maxBuyWei;

        plan.liquidity =
            V4PoolMath.getLiquidityForAmounts(a.sqrtPriceX96, sqrtLower, sqrtUpper, ethForPool, a.tokenAmount);
        if (plan.liquidity > 0) {
            // The pool rounds deposit deltas UP (SqrtPriceMath, positive liquidity); mirror it.
            plan.ethUsed = SqrtPriceMath.getAmount0Delta(a.sqrtPriceX96, sqrtUpper, plan.liquidity, true);
            plan.tokensUsed = SqrtPriceMath.getAmount1Delta(sqrtLower, a.sqrtPriceX96, plan.liquidity, true);
        }

        int24 refTick = V4PoolMath.getTickAtSqrtPrice(a.sqrtPriceX96);
        plan.bands = new BandPlan[](a.bands.length);
        for (uint256 i; i < a.bands.length; ++i) {
            LpTranche calldata b = a.bands[i];
            // The three `continue`s mirror the seed path's skips and are equally unreachable
            // once `_validateAttach` above has passed; kept so preview and seed stay the same
            // code shape and can never disagree if validation drifts.
            uint256 amount = (a.bandTokenAmount * b.bps) / BPS;
            if (amount == 0) continue;
            (bool ok, int24 lower, int24 upper) = _trancheRange(refTick, b.startOffset, b.endOffset);
            if (!ok) continue;
            uint128 liquidity = _bandLiquidity(lower, upper, amount);
            if (liquidity == 0) continue;
            uint256 used = SqrtPriceMath.getAmount1Delta(
                V4PoolMath.getSqrtPriceAtTick(lower), V4PoolMath.getSqrtPriceAtTick(upper), liquidity, true
            );
            plan.bands[i] = BandPlan({
                seeded: used > 0, tickLower: lower, tickUpper: upper, liquidity: liquidity, tokensUsed: used
            });
            plan.bandTokensUsed += used;
        }

        plan.ethRefund = ethForPool - plan.ethUsed;
        plan.tokenRefund = (a.tokenAmount - plan.tokensUsed) + (a.bandTokenAmount - plan.bandTokensUsed);
    }

    // ---------------------------------------------------------------- locked-POL fee collection

    /// @notice Collect LP fees earned by the locked positions. ETH side splits creator/protocol;
    ///         the token side burns to DEAD, or falls back to factory-held ERC-6909 claims when
    ///         the token refuses the burn transfer. Callable by anyone.
    function collectPoolFees(address token) external nonReentrant {
        Attachment storage at = _attachmentOf(token);
        PoolKey memory key = _poolKey(token);

        (uint256 ethAmount, uint256 tokensBurned, uint256 tokensDeferred) = _collectRange(key, 0, 0);

        // Each band is its own position, so its fees have to be poked separately — collecting
        // only the full-range position would silently leave band fees in the pool forever.
        LpTranche[] storage bands = bandsOf[token];
        int24 refTick = V4PoolMath.getTickAtSqrtPrice(at.sqrtPriceX96AtAttach);
        for (uint256 i; i < bands.length; ++i) {
            (bool ok, int24 lower, int24 upper) = _trancheRange(refTick, bands[i].startOffset, bands[i].endOffset);
            if (!ok) continue;
            // Since `_validateBands` began pricing every band at the attested price, a stored
            // band that never seeded cannot exist: planned == placed, and this branch (like the
            // `!ok` continue above) is unreachable for any pool this factory attached. It stays
            // as anti-brick defense-in-depth because the failure it guards against is terminal:
            // PoolManager rejects a zero-delta poke of a position that was never minted, which
            // would make this token's ENTIRE fee collection — ETH side included — revert
            // forever. Read the factory-owned position and skip only truly absent bands; seeded
            // positions are never removable by this contract, so liquidity here is monotone.
            bytes32 positionId = keccak256(abi.encodePacked(address(this), lower, upper, bytes32(0)));
            if (poolManager.getPositionLiquidity(at.poolId, positionId) == 0) continue;
            (uint256 bandEth, uint256 bandBurned, uint256 bandDeferred) =
                _collectRange(key, uint256(uint24(lower)), uint256(uint24(upper)));
            ethAmount += bandEth;
            tokensBurned += bandBurned;
            tokensDeferred += bandDeferred;
        }

        if (tokensDeferred > 0) deferredBurnClaims[token] += tokensDeferred;

        if (ethAmount > 0) {
            // Fees the positions earned while the anti-snipe guard was live are PROTOCOL-ONLY.
            // The snipe tax is charged as an LP fee, and the hook blocks outside LP additions for
            // the finite guard window so the factory's locked positions own that fee growth.
            // Without this withholding the tax flows back to the creator at `creatorFeeBps` — and
            // the creator is a party who can pay it, in the attach transaction itself.
            // `guardFeesWithheldWei` is the high-water mark so the same wei is never withheld twice.
            uint256 owed = hook.guardLpEarnedWei(at.poolId) - guardFeesWithheldWei[token];
            uint256 withheld = owed > ethAmount ? ethAmount : owed;
            if (withheld > 0) guardFeesWithheldWei[token] += withheld;
            uint256 creatorSide = ((ethAmount - withheld) * _creatorFeeBps(token)) / BPS;
            protocolFeesWei += ethAmount - creatorSide;
            creatorFeesWei[token] += creatorSide;
        }
        emit PoolFeesCollected(token, ethAmount, tokensBurned, tokensDeferred);
    }

    /// @notice Retry the token-side burn a previous collection had to defer into ERC-6909 claims.
    ///         Permissionless: if the token starts accepting transfers to DEAD again (an unpause,
    ///         an unblock), anyone can complete the burn. Reverts wholesale — claims intact — if
    ///         the token still refuses.
    function retryDeferredBurn(address token) external nonReentrant {
        _attachmentOf(token);
        uint256 amount = deferredBurnClaims[token];
        if (amount == 0) revert NothingToClaim();
        deferredBurnClaims[token] = 0;
        poolManager.unlock(abi.encode(CB_RETRY_BURN, _poolKey(token), amount));
        emit DeferredBurnCompleted(token, amount);
    }

    /// @notice The creator's configured share of pool fees, in bps. Unset means the default.
    function _creatorFeeBps(address token) internal view returns (uint16) {
        uint16 configured = attachments[token].creatorFeeBps;
        return configured == 0 ? DEFAULT_CREATOR_FEE_BPS : configured;
    }

    /// @notice Nominate where this token's creator fees are paid. Only the creator may set it;
    ///         ownership of the fees never moves, only the delivery address. Setting address(0)
    ///         restores the default (the creator).
    function setCreatorPayout(address token, address to) external {
        Attachment storage at = _attachmentOf(token);
        if (msg.sender != at.creator) revert NotOwner();
        creatorPayout[token] = to;
        emit CreatorPayoutSet(token, to);
    }

    /// @notice Where `claimCreatorFees` will send this token's creator fees.
    function creatorPayoutOf(address token) public view returns (address) {
        address to = creatorPayout[token];
        return to == address(0) ? attachments[token].creator : to;
    }

    /// @notice Claim accrued creator-side pool fees for a token.
    function claimCreatorFees(address token) external nonReentrant {
        _attachmentOf(token);
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

        if (action == CB_BAND) {
            (, PoolKey memory bKey, int24 bLower, int24 bUpper, uint256 bAmount) =
                abi.decode(data, (uint8, PoolKey, int24, int24, uint256));
            return abi.encode(_mintBand(bKey, bLower, bUpper, bAmount));
        }

        if (action == CB_RETRY_BURN) {
            (, PoolKey memory rKey, uint256 rAmount) = abi.decode(data, (uint8, PoolKey, uint256));
            poolManager.burn(address(this), rKey.currency1.toId(), rAmount);
            // No try/catch here on purpose: this whole unlock IS the retry, so a refusal should
            // revert it and leave the claims exactly as they were.
            poolManager.take(rKey.currency1, DEAD, rAmount);
            return abi.encode(rAmount);
        }

        (, PoolKey memory key, uint160 sqrtPriceX96, uint256 ethAmt, uint256 tokenAmt) =
            abi.decode(data, (uint8, PoolKey, uint160, uint256, uint256));

        (int24 tickLower, int24 tickUpper) = V4PoolMath.usableTickRange(key.tickSpacing);
        if (action == CB_COLLECT && (ethAmt != 0 || tokenAmt != 0)) {
            // Collection over a band range: the bounds ride in the two amount slots.
            tickLower = int24(uint24(ethAmt));
            tickUpper = int24(uint24(tokenAmt));
        }

        if (action == CB_SEED) {
            uint128 liquidity = V4PoolMath.getLiquidityForAmounts(
                sqrtPriceX96,
                V4PoolMath.getSqrtPriceAtTick(tickLower),
                V4PoolMath.getSqrtPriceAtTick(tickUpper),
                ethAmt,
                tokenAmt
            );

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
                _safeTransfer(Currency.unwrap(key.currency1), address(poolManager), oweTokens);
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
            uint256 tokensBurned;
            uint256 tokensDeferred;
            if (tokensOwed > 0) {
                // Burn the token side directly — the launchpad's behavior — but this token is
                // foreign code that can refuse a transfer to DEAD (a blocklist, a pause). The
                // positive currency delta MUST still be resolved inside this unlock: a bare
                // try/catch alone would leave NonzeroDeltaCount set and brick the WHOLE unlock,
                // ETH side included. So on refusal, mint the amount to this factory as native
                // ERC-6909 claims — delta resolved, ETH fees flow, and `retryDeferredBurn` can
                // finish the burn whenever the token allows it.
                try poolManager.take(key.currency1, DEAD, tokensOwed) {
                    tokensBurned = tokensOwed;
                } catch {
                    poolManager.mint(address(this), key.currency1.toId(), tokensOwed);
                    tokensDeferred = tokensOwed;
                }
            }
            return abi.encode(ethOwed, tokensBurned, tokensDeferred);
        }

        revert BadCallback();
    }

    // ---------------------------------------------------------------- seeding internals

    /// @notice Places each configured band as a token-only position above the opening price.
    /// @dev Returns the tokens actually consumed. The skip branches below are UNREACHABLE for
    ///      any plan `_validateBands` accepted: validation already ran this exact math (slice,
    ///      `_trancheRange`, `_bandLiquidity`) at the attested price the pool was just
    ///      initialized to, and reverted `BadLpPlan` on anything that would skip here. They are
    ///      kept anyway — launchpad-style skip-don't-revert is the correct failure mode inside a
    ///      seed loop, and if validation and seeding ever drift, a skipped slice REFUNDS to the
    ///      caller (see `attach`) instead of bricking or burning.
    function _seedBands(address token, PoolKey memory key, uint256 bandTokenAmount) internal returns (uint256 seeded) {
        LpTranche[] storage bands = bandsOf[token];
        uint256 n = bands.length;
        if (n == 0) return 0;

        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());

        for (uint256 i; i < n; ++i) {
            LpTranche storage b = bands[i];
            uint256 amount = (bandTokenAmount * b.bps) / BPS;
            if (amount == 0) continue;

            // Higher token price == lower tick, so the band is placed below spot. Alignment can
            // collapse a thin band, a far-out band can exceed the usable range, and only a band
            // strictly below spot is token-only — `ok` is false for each, and the slice refunds
            // instead of reverting the attach. (Unreachable post-validation; see the fn note.)
            (bool ok, int24 lower, int24 upper) = _trancheRange(currentTick, b.startOffset, b.endOffset);
            if (!ok) continue;

            uint256 used = abi.decode(poolManager.unlock(abi.encode(CB_BAND, key, lower, upper, amount)), (uint256));
            if (used > 0) {
                seeded += used;
                emit BandSeeded(token, i, lower, upper, used);
            }
        }
    }

    /// @notice Mint one token-only band over `[lower, upper]` and settle what it consumed.
    /// @dev Runs inside the CB_BAND unlock. A band whose liquidity refuses to price mints nothing
    ///      and reports zero, so `_seedBands` skips it and the slice refunds. Like `_seedBands`'
    ///      skip branches, the zero return is unreachable for a validated plan (`_validateBands`
    ///      priced this exact band already) and is retained as defense-in-depth: a revert inside
    ///      an unlock callback cannot be skipped, so this path must stay total regardless.
    function _mintBand(PoolKey memory key, int24 lower, int24 upper, uint256 amount)
        internal
        returns (uint256 owedToken)
    {
        uint128 liquidity = _bandLiquidity(lower, upper, amount);
        if (liquidity == 0) return 0;

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: lower, tickUpper: upper, liquidityDelta: int256(uint256(liquidity)), salt: bytes32(0)
            }),
            ""
        );
        // A band above the open price must never draw ETH; if it somehow would, that is a bug
        // and the attach should revert rather than spend the caller's seed.
        if (delta.amount0() < 0) revert BadLpPlan();
        owedToken = delta.amount1() < 0 ? uint256(uint128(-delta.amount1())) : 0;
        if (owedToken > 0) {
            poolManager.sync(key.currency1);
            _safeTransfer(Currency.unwrap(key.currency1), address(poolManager), owedToken);
            poolManager.settle();
        }
    }

    /// @dev One position's accrued fees, poked with a zero liquidity delta. `lowerSlot`/
    ///      `upperSlot` ride in the two amount slots exactly as the callback expects: zero for
    ///      both means the full-range position, otherwise `uint256(uint24(tick))` bit patterns.
    function _collectRange(PoolKey memory key, uint256 lowerSlot, uint256 upperSlot)
        internal
        returns (uint256 ethAmount, uint256 tokensBurned, uint256 tokensDeferred)
    {
        bytes memory out = poolManager.unlock(abi.encode(CB_COLLECT, key, uint160(0), lowerSlot, upperSlot));
        return abi.decode(out, (uint256, uint256, uint256));
    }

    // ---------------------------------------------------------------- validation

    /// @dev Every refusal `attach` can raise before touching token code, shared verbatim with
    ///      `previewAttach` so the preview reverts exactly where execution would.
    function _validateAttach(AttachArgs calldata a, uint256 ethForPool) internal view {
        if (ethForPool == 0 || a.tokenAmount == 0) revert BadSeed();
        // Bands and their funding travel together: tokens with no plan (or a plan with no
        // tokens) is a mistake to surface, not to silently absorb.
        if ((a.bands.length == 0) != (a.bandTokenAmount == 0)) revert BadLpPlan();
        if (a.token.code.length == 0) revert BadToken();
        _requireStandardDecimals(a.token);
        if (a.creatorFeeBps > MAX_CREATOR_FEE_BPS) revert BadFeeSplit();

        // The attested price must sit STRICTLY inside the usable full-range band — a tighter
        // bound than v4's own MIN/MAX_SQRT_PRICE, and the one that matters: at or past either
        // bound the founding position would hold only one of the two currencies with no error
        // anywhere. Same check `instantPlan` runs on the launchpad's instant path.
        (int24 tickLower, int24 tickUpper) = V4PoolMath.usableTickRange(TICK_SPACING);
        if (
            a.sqrtPriceX96 <= V4PoolMath.getSqrtPriceAtTick(tickLower)
                || a.sqrtPriceX96 >= V4PoolMath.getSqrtPriceAtTick(tickUpper)
        ) revert OpenPriceOutOfRange();

        _validateHookParams(a.hookParams);
        _validateBands(a.bands, a.bandTokenAmount, a.sqrtPriceX96);
    }

    /// @dev Mirrors `HookrAttachHook.configurePool`'s checks against the NORMALIZED params, so
    ///      anything accepted here is guaranteed to configure cleanly. Ported verbatim from
    ///      `HookrLaunchpad._validateHookParams`.
    function _validateHookParams(HookParams calldata p) internal pure {
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

    /// @dev Ported from the band half of `HookrLaunchpad._validateDistribution`, then made
    ///      STRICTER. The launchpad must keep its bands skippable because price moves between
    ///      plan and graduation, so a band's fate is unknowable at launch. An attach has no such
    ///      gap: the seed executes in the SAME transaction at exactly the attested
    ///      `sqrtPriceX96`, which makes every band's aligned geometry, liquidity, and token
    ///      consumption fully computable right here. So a band that would collapse under
    ///      alignment, fail `_trancheRange`'s bounds, quantize its token slice to zero, or price
    ///      to zero liquidity is refused up front — the planned placement (`_capTokens`, the
    ///      anti-snipe cap basis) therefore always equals what actually seeds, and the seed
    ///      path's skip-refund branches become unreachable defense-in-depth.
    function _validateBands(LpTranche[] calldata bands, uint256 bandTokenAmount, uint160 sqrtPriceX96) internal pure {
        uint256 t = bands.length;
        if (t > MAX_LP_TRANCHES) revert BadLpPlan();
        if (t > 0) {
            int24 refTick = V4PoolMath.getTickAtSqrtPrice(sqrtPriceX96);
            uint256 sum;
            int24 previousUpper = 0;
            for (uint256 i; i < t; ++i) {
                LpTranche calldata b = bands[i];
                if (b.bps == 0) revert BadLpPlan();
                // Strictly below the opening tick keeps every band token-only: a band straddling
                // spot would need ETH the seed has already committed elsewhere.
                if (b.startOffset < MIN_TRANCHE_OFFSET) revert BadLpPlan();
                if (b.endOffset <= b.startOffset) revert BadLpPlan();
                if (b.endOffset > MAX_TRANCHE_OFFSET) revert BadLpPlan();
                // Ascending in price and non-overlapping, so the bands read as a ladder and a
                // mistake cannot quietly stack two positions on the same range.
                if (i > 0 && b.startOffset < previousUpper) revert BadLpPlan();
                previousUpper = b.endOffset;
                sum += b.bps;

                // The exact math the seed path runs, run now instead: the slice this band gets,
                // its aligned tick range at the attested price, and the liquidity that slice can
                // fund. Anything the seed would have skipped is refused while refusing is free.
                uint256 amount = (bandTokenAmount * b.bps) / BPS;
                if (amount == 0) revert BadLpPlan();
                (bool ok, int24 lower, int24 upper) = _trancheRange(refTick, b.startOffset, b.endOffset);
                if (!ok) revert BadLpPlan();
                if (_bandLiquidity(lower, upper, amount) == 0) revert BadLpPlan();
            }
            // At most the whole allocation: any unallocated remainder refunds.
            if (sum > BPS) revert BadLpPlan();
        }
    }

    /// @notice `maxFeePips == 0` is the builder's "surge block not stacked" encoding, not a real
    ///         zero ceiling; normalize exactly as the launchpad does.
    function _normalizedMaxFeePips(HookParams calldata p) internal pure returns (uint24) {
        return p.maxFeePips == 0 ? p.baseFeePips : p.maxFeePips;
    }

    /// @dev What the anti-snipe `maxBuyBps` is a share OF: the PLANNED placement, `tokenAmount +
    ///      bandTokenAmount` — the instant path's precedent, never `totalSupply()` of a foreign
    ///      token. A supply-denominated cap would mean something different at every float ratio,
    ///      weakest exactly where the pool is thinnest, and a foreign token's `totalSupply()` is
    ///      whatever its code says it is — an attacker-chosen number is no basis for a guard.
    function _capTokens(AttachArgs calldata a) internal pure returns (uint256) {
        return a.tokenAmount + a.bandTokenAmount;
    }

    /// @dev Ported from `HookrLaunchpad._buildPoolConfig` with the blueprint branch removed:
    ///      v1 attaches carry no royalty (see the contract notice on blueprints).
    function _buildPoolConfig(HookParams calldata p, uint256 openPriceWei, uint256 capTokens)
        internal
        view
        returns (HookrAttachHook.PoolConfig memory cfg)
    {
        uint256 maxBuyWei = 0;
        if (p.maxBuyBps != 0) {
            // Near the low tick edge `openPriceWei` reaches ~1e56, so `cappedTokens *
            // openPriceWei` can leave uint256 entirely — and a clamp that panics before it can
            // clamp is not a clamp. Saturate instead: when the 256-bit product would overflow,
            // the true quotient is ~1e59 wei at minimum, astronomically past the uint96 ceiling
            // the next line would apply anyway. (Any such placement is also refused downstream
            // by the uint128 liquidity bound, but this function must hold its own contract.)
            uint256 cappedTokens = V4PoolMath.mulDiv(capTokens, p.maxBuyBps, BPS);
            if (cappedTokens != 0 && openPriceWei > type(uint256).max / cappedTokens) {
                maxBuyWei = type(uint96).max;
            } else {
                maxBuyWei = V4PoolMath.mulDiv(cappedTokens, openPriceWei, 1e18);
                if (maxBuyWei > type(uint96).max) maxBuyWei = type(uint96).max;
            }
            // The hook reads maxBuyWei == 0 as "uncapped". A configured cap that quantizes to
            // zero (a microscopic placement at a microscopic price) would silently disable the
            // guard the creator asked for, so it fails closed here instead.
            if (maxBuyWei == 0) revert BadHookParams();
        }
        cfg = HookrAttachHook.PoolConfig({
            initialized: false, // hook sets this
            guardEndBlock: p.guardBlocks == 0 ? 0 : uint40(block.number + p.guardBlocks),
            baseFeePips: p.baseFeePips,
            maxFeePips: _normalizedMaxFeePips(p),
            snipeTaxPips: p.snipeTaxPips,
            surgeSens: p.surgeSens,
            burnBps: p.burnBps,
            lpBps: p.lpBps,
            potBps: p.potBps,
            royaltyBps: 0,
            potEveryNBuys: p.potEveryNBuys,
            maxBuyWei: uint96(maxBuyWei),
            potMinBuyWei: p.potMinBuyWei,
            burnTriggerWei: p.burnTriggerWei,
            royaltyTo: address(0),
            token: address(0) // hook sets this
        });
    }

    // ---------------------------------------------------------------- geometry internals

    /// @dev The pool every attach opens: hardcoded native-ETH / token, dynamic fee, spacing 60,
    ///      this generation's hook. Fully determined by the token address — which is what makes
    ///      the hook's one-shot `configurePool` the uniqueness gate.
    function _poolKey(address token) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    /// @dev Wei per whole token implied by the attested sqrt price: the v4 price is
    ///      tokens-per-wei, so this is `1e18 * 2^192 / sqrtPriceX96^2`, computed in two mulDivs
    ///      so the square never overflows.
    function _openPriceWei(uint160 sqrtPriceX96) internal pure returns (uint256) {
        return V4PoolMath.mulDiv(V4PoolMath.mulDiv(1e18, V4PoolMath.Q96, sqrtPriceX96), V4PoolMath.Q96, sqrtPriceX96);
    }

    /// @dev Ported verbatim from `HookrLaunchpadLib.trancheRange`: the aligned, bounds-checked
    ///      tick range of one token-only band below `refTick`, TOTAL over every input — a false
    ///      here means "skip this band", and a function that can panic cannot be skipped.
    function _trancheRange(int24 refTick, int24 startOffset, int24 endOffset)
        internal
        pure
        returns (bool ok, int24 lower, int24 upper)
    {
        (int24 minTick, int24 maxTick) = V4PoolMath.usableTickRange(TICK_SPACING);
        // Widen before subtracting: offset arithmetic can leave int24 entirely, and alignment's
        // round-toward-negative-infinity step can carry an extreme result over the edge.
        int256 rawLower = int256(refTick) - int256(endOffset);
        int256 rawUpper = int256(refTick) - int256(startOffset);
        if (rawLower < minTick || rawLower > maxTick) return (false, 0, 0);
        if (rawUpper < minTick || rawUpper > maxTick) return (false, 0, 0);

        // casting to 'int24' is safe: both values are bounded by the usable tick range above.
        // forge-lint: disable-next-line(unsafe-typecast)
        lower = _alignTick(int24(rawLower));
        // forge-lint: disable-next-line(unsafe-typecast)
        upper = _alignTick(int24(rawUpper));
        if (upper <= lower) return (false, 0, 0);
        if (lower < minTick || upper > maxTick) return (false, 0, 0);
        if (upper > refTick) return (false, 0, 0);
        ok = true;
    }

    /// @dev Rounds toward negative infinity so alignment never widens a band past its bound.
    function _alignTick(int24 tick) internal pure returns (int24) {
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 aligned = (tick / TICK_SPACING) * TICK_SPACING;
        if (tick < 0 && aligned != tick) aligned -= TICK_SPACING;
        return aligned;
    }

    /// @dev Ported verbatim from `HookrLaunchpadLib.bandLiquidity`: liquidity a token-only band
    ///      can fund, or ZERO when the band is not one this pool can hold. The zero return is
    ///      load-bearing — an unusable band must be skippable, and a revert inside the unlock
    ///      callback cannot be skipped.
    function _bandLiquidity(int24 tickLower, int24 tickUpper, uint256 amount1) internal pure returns (uint128) {
        uint160 lower = V4PoolMath.getSqrtPriceAtTick(tickLower);
        uint160 upper = V4PoolMath.getSqrtPriceAtTick(tickUpper);
        if (upper <= lower) return 0;
        uint256 liquidity = V4PoolMath.mulDiv(amount1, V4PoolMath.Q96, upper - lower);
        if (liquidity > type(uint128).max) return 0;
        // casting to 'uint128' is safe: bounds-checked on the line above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(liquidity);
    }

    // ---------------------------------------------------------------- views

    function _attachmentOf(address token) internal view returns (Attachment storage at) {
        at = attachments[token];
        if (at.token == address(0)) revert UnknownToken();
    }

    function getAttachment(address token) external view returns (Attachment memory) {
        return attachments[token];
    }

    /// @notice Read the configured LP bands for an attach.
    function getBands(address token) external view returns (LpTranche[] memory) {
        return bandsOf[token];
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

    // ---------------------------------------------------------------- token boundary

    /// @dev STRICTER than a SafeTransferLib on purpose, ported from
    ///      `LeverageExistingTokenFactory`: success requires call success AND at least 32 return
    ///      bytes AND a decodable `true`, so a USDT-style no-return token is refused at attach.
    ///      A token this generation cannot settle against must never get a pool, and attach is
    ///      the only gate that can hold that line.
    function _safeTransfer(address token, address to, uint256 amount) private {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        if (!ok || ret.length < 32 || !abi.decode(ret, (bool))) revert TokenCallFailed();
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) private {
        (bool ok, bytes memory ret) =
            token.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, amount));
        if (!ok || ret.length < 32 || !abi.decode(ret, (bool))) revert TokenCallFailed();
    }

    function _balanceOf(address token, address account) private view returns (uint256) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", account));
        if (!ok || ret.length < 32) revert TokenCallFailed();
        return abi.decode(ret, (uint256));
    }

    function _requireStandardDecimals(address token) private view {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || ret.length < 32) revert TokenCallFailed();
        if (abi.decode(ret, (uint256)) != 18) revert NonStandardDecimals();
    }

    // ---------------------------------------------------------------- internal

    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }
}
