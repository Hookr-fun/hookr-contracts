// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {ILeverage, ILeverageHook} from "./interfaces/ILeverage.sol";
import {LeverageOracleLib} from "./libraries/LeverageOracleLib.sol";

/// @title LeverageHook
/// @notice The v4 hook for a leverage-enabled Hookr market. It holds no value and moves no
///         balance: it observes price, prices the LP fee, keeps liquidity exclusive to the
///         market, and answers "is this market safe to lend against right now".
///
///         Deliberately SEPARATE from the market that lends. `Hooks.beforeSwap` and
///         `Hooks.afterSwap` both begin `if (msg.sender == address(self)) return` — a hook
///         that swapped its own pool would silently skip its own callbacks, so the largest
///         price moves in the system (opens and liquidations) would go unobserved and the
///         oracle would be blind exactly when it matters. The market is a different address,
///         so its swaps reach this hook like anyone else's.
///
///         No `*_RETURNS_DELTA` flags. This hook takes no swap-time cut, so ordinary traders
///         get an unmodified v4 pool and the whole class of partial-fill reconciliation bugs
///         that forces on `HookrHook` cannot arise here. Market revenue is origination fee,
///         interest, close fee and liquidation penalty — none of which touch a swap's delta.
contract LeverageHook is IHooks, ILeverageHook {
    using StateLibrary for IPoolManager;
    using LeverageOracleLib for LeverageOracleLib.Ring;

    // beforeInitialize | afterInitialize | beforeAddLiquidity | beforeRemoveLiquidity |
    // beforeSwap | afterSwap
    uint160 public constant REQUIRED_FLAGS =
        uint160((1 << 13) | (1 << 12) | (1 << 11) | (1 << 9) | (1 << 7) | (1 << 6));

    uint24 internal constant DYNAMIC_FEE_FLAG = 0x800000;
    uint24 internal constant FEE_OVERRIDE_FLAG = 0x400000;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    /// @dev Spot may sit this far from the average before the market stops trusting itself.
    uint256 public constant MAX_DEVIATION_BPS = 500;

    /// @dev A SECOND, much shorter window read from the SAME ring `MAX_DEVIATION_BPS` reads —
    ///      no separate accumulator, no separate storage. `_unwindForRedemption` needs a
    ///      reference the attacker cannot set in-transaction and that ALSO tracks close enough
    ///      to spot that it does not stay dislocated for long after a genuine price move.
    ///      900s failed the second half: a push that only walked spot down through headroom it
    ///      already had above the 900s average still paid, measured at +2.74 tokens with spot
    ///      30.27% above the mean. This window is short enough that an honest decline stops
    ///      disagreeing with it within its own duration, and — because the accumulator credits
    ///      every interval to the tick that actually stood over it — an attacker cannot shorten
    ///      that wait: a push read back in the SAME transaction shows the average essentially
    ///      unmoved from before the push, which is what makes the check fire at all.
    uint32 internal constant RECENT_WINDOW_SEC = 90;
    uint256 internal constant RECENT_MAX_WALK = RECENT_WINDOW_SEC / LeverageOracleLib.MIN_SPACING_SEC + 1;
    /// @dev Tighter than `MAX_DEVIATION_BPS`, deliberately: a 90s average sits close to spot in
    ///      ordinary trading, so a wide band here would let exactly the pushes it exists to
    ///      catch through. One-sided in `isRecentlyDislocated`, for the same reason the redeem
    ///      path is never gated on a rally — only a push BELOW the recent average can feed the
    ///      unwind's sale a manipulated price.
    uint256 public constant RECENT_DEVIATION_BPS = 150;
    /// @dev LP fee floor and ceiling, in pips (1e-6).
    uint24 public constant BASE_FEE_PIPS = 3000;
    uint24 public constant MAX_FEE_PIPS = 30_000;

    IPoolManager public immutable poolManager;

    /// @dev Set once, after deployment. The hook's address is mined against its own creation
    ///      code, so it cannot take the factory as a constructor argument without the factory
    ///      existing first — and the factory needs this address. One of the two links must be
    ///      late-bound; this is it, and it is one-shot.
    address public factory;

    mapping(PoolId => address) public marketOf;
    mapping(PoolId => LeverageOracleLib.Ring) internal rings;

    event PoolRegistered(PoolId indexed id, address indexed market);
    event FactorySet(address indexed factory);

    error NotPoolManager();
    error FactoryAlreadySet();
    error BadFee();
    error LiquidityIsExclusive();
    error BadFlags();

    address private immutable deployer;

    /// @param admin The address permitted to call `setFactory` once.
    /// @dev `admin` is explicit rather than `msg.sender` because this address must be MINED,
    ///      so the hook can only be created by CREATE2 — i.e. by a contract. Under
    ///      `forge script` that contract is the canonical deterministic deployer
    ///      0x4e59b448..., which would have become the deployer and left `setFactory`
    ///      unreachable by every address forever: `factory` stays zero, `registerPool` reverts
    ///      NotFactory, `beforeInitialize` reverts PoolNotRegistered, and `createMarket`
    ///      reverts for everyone. The product would have been dead on arrival.
    ///
    ///      Nothing caught it because every test deploys the hook FROM the test contract,
    ///      which is also the address that calls `setFactory`. The deploy script added
    ///      alongside this is the actual regression.
    ///
    ///      There is no circularity: the admin is known before the factory exists. It is part
    ///      of the creation code the salt is mined over, so it cannot be swapped after mining.
    constructor(IPoolManager manager, address admin) {
        if (admin == address(0)) revert ILeverage.BadConfig();
        poolManager = manager;
        deployer = admin;
        // The mined address is only meaningful if it carries the permissions this contract
        // claims. Nothing downstream re-checks it — the factory stores the hook as an
        // immutable and v4 short-circuits its own flag validation for a dynamic-fee pool — so
        // an unmined deployment would run with whatever bits its address happened to have.
        if (uint160(address(this)) & 0x3FFF != REQUIRED_FLAGS) revert BadFlags();
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @notice One-shot, and only by whoever deployed the hook.
    /// @dev Was callable by anyone. The hook's address is mined over its creation code, so the
    ///      factory link has to be late-bound — but "late-bound" was implemented as "open",
    ///      and a watcher could claim the hook between the two transactions and register pools
    ///      pointing at a market of their choosing.
    function setFactory(address factory_) external {
        if (msg.sender != deployer) revert ILeverage.NotFactory();
        if (factory_ == address(0)) revert ILeverage.BadConfig();
        if (factory != address(0)) revert FactoryAlreadySet();
        factory = factory_;
        emit FactorySet(factory_);
    }

    /// @inheritdoc ILeverageHook
    function registerPool(PoolKey calldata key, address market) external {
        if (msg.sender != factory) revert ILeverage.NotFactory();
        PoolId id = key.toId();
        if (marketOf[id] != address(0)) revert ILeverage.AlreadyRegistered();
        if (key.fee != DYNAMIC_FEE_FLAG) revert BadFee();
        marketOf[id] = market;
        emit PoolRegistered(id, market);
    }

    // ------------------------------------------------------------------ price

    /// @inheritdoc ILeverageHook
    function priceView(PoolId id) external view returns (ILeverage.PriceView memory view_) {
        (uint160 sqrtPriceX96, int24 spotTick,,) = poolManager.getSlot0(id);
        view_.spotWad = _priceWadFromSqrt(sqrtPriceX96);

        (int24 mean, bool covered) = rings[id].meanTick(uint32(block.timestamp), spotTick);
        view_.stale = !covered;
        view_.twapWad = covered ? _priceWadFromSqrt(TickMath.getSqrtPriceAtTick(mean)) : view_.spotWad;

        if (view_.twapWad != 0) {
            uint256 hi = view_.spotWad > view_.twapWad ? view_.spotWad : view_.twapWad;
            uint256 lo = view_.spotWad > view_.twapWad ? view_.twapWad : view_.spotWad;
            view_.deviated = (hi - lo) * BPS / hi > MAX_DEVIATION_BPS;
        }
    }

    /// @inheritdoc ILeverageHook
    function isProtected(PoolId id) external view returns (bool) {
        if (marketOf[id] == address(0)) return true;
        (uint160 sqrtPriceX96, int24 spotTick,,) = poolManager.getSlot0(id);
        (int24 mean, bool covered) = rings[id].meanTick(uint32(block.timestamp), spotTick);
        if (!covered) return true;
        uint256 spot = _priceWadFromSqrt(sqrtPriceX96);
        uint256 twap = _priceWadFromSqrt(TickMath.getSqrtPriceAtTick(mean));
        if (twap == 0 || spot == 0) return true;
        uint256 hi = spot > twap ? spot : twap;
        uint256 lo = spot > twap ? twap : spot;
        return (hi - lo) * BPS / hi > MAX_DEVIATION_BPS;
    }

    /// @notice Whether spot currently sits materially BELOW the market's own recent history.
    /// @dev Reads the SAME ring `priceView`/`isProtected` read, just over `RECENT_WINDOW_SEC`
    ///      instead of the full window — see `RECENT_WINDOW_SEC` for why 900s could not do
    ///      this job. Deliberately one-sided (only "spot below") and deliberately "false" on
    ///      an uncovered window: a young ring has no recent history to disagree with, and the
    ///      long-window `isProtected` already refuses lending on it for the reason that
    ///      matters — this check exists to catch a RECENT push, not general immaturity.
    function isRecentlyDislocated(PoolId id) external view returns (bool) {
        (uint160 sqrtPriceX96, int24 spotTick,,) = poolManager.getSlot0(id);
        (int24 mean, bool covered) =
            rings[id].meanTickOver(uint32(block.timestamp), spotTick, RECENT_WINDOW_SEC, RECENT_MAX_WALK);
        if (!covered) return false;
        uint256 spot = _priceWadFromSqrt(sqrtPriceX96);
        uint256 recent = _priceWadFromSqrt(TickMath.getSqrtPriceAtTick(mean));
        if (recent == 0 || spot >= recent) return false;
        return (recent - spot) * BPS / recent > RECENT_DEVIATION_BPS;
    }

    /// @dev Native ETH is currency0 in every Hookr pool, so sqrtPrice is sqrt(token/ETH) and
    ///      the quote-per-token price is its reciprocal. Getting this backwards inverts every
    ///      liquidation, so it is derived in exactly one place.
    function _priceWadFromSqrt(uint160 sqrtPriceX96) internal pure returns (uint256) {
        if (sqrtPriceX96 == 0) return 0;
        // priceToken1PerToken0 = (sqrtP/2^96)^2 ; we want token0 (ETH) per token1.
        uint256 p = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96);
        if (p == 0) return 0;
        return FullMath.mulDiv(WAD, 1 << 96, p);
    }

    // ------------------------------------------------------------------ hooks

    function beforeInitialize(address, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        if (marketOf[key.toId()] == address(0)) revert ILeverage.PoolNotRegistered();
        return IHooks.beforeInitialize.selector;
    }

    /// @dev Seeds the ring and pushes the opening fee in the same transaction the pool is
    ///      created, so there is no window where the pool is live with a zero dynamic fee and
    ///      an empty observation history.
    function afterInitialize(address, PoolKey calldata key, uint160, int24) external onlyPoolManager returns (bytes4) {
        rings[key.toId()].seed(uint32(block.timestamp));
        poolManager.updateDynamicLPFee(key, BASE_FEE_PIPS);
        return IHooks.afterInitialize.selector;
    }

    /// @dev Liquidity is exclusive to the market. An outside LP would hold a bare v4 position
    ///      with no claim on the credit ledger — and would be silently senior to the market's
    ///      own accounting. Enforced on both sides rather than inferred from one.
    function beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != marketOf[key.toId()]) revert LiquidityIsExclusive();
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != marketOf[key.toId()]) revert LiquidityIsExclusive();
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @dev Prices the LP fee. Surge scales with how much of in-range depth a trade consumes —
    ///      and is computed for EXACT-INPUT swaps only. `HookrHook`'s formula casts
    ///      `-amountSpecified`, which is negative on an exact-output swap; carrying the
    ///      formula without its guard would revert every exact-output trade in the pool.
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();

        // The observation is written BEFORE the swap, with the price that stood before this
        // trade — never the price this trade created.
        //
        // Writing the post-swap tick let one transaction choose what the window recorded and
        // then suppress every honest print for MIN_SPACING_SEC: dump (recorded at the
        // depressed tick), buy back in the same block (rate-limited away), repeat. Spot
        // returned to the wei while the average fell 45%, which was enough to liquidate
        // positions spot called healthy. A trade cannot pick the number that outlives it.
        (, int24 preTick,,) = poolManager.getSlot0(id);
        rings[id].write(preTick, uint32(block.timestamp));

        uint24 fee = BASE_FEE_PIPS;

        // The market's own execution pays the base fee: surging its liquidations would take
        // the recovery out of the LPs the liquidation exists to protect.
        if (sender != marketOf[id] && params.amountSpecified < 0) {
            uint128 liquidity = poolManager.getLiquidity(id);
            if (liquidity > 0) {
                uint256 amountIn = uint256(-params.amountSpecified);
                uint256 ratioBps = FullMath.mulDiv(amountIn, BPS, uint256(liquidity));
                uint256 extra = ratioBps * BASE_FEE_PIPS / BPS;
                uint256 total = uint256(BASE_FEE_PIPS) + extra;
                fee = total > MAX_FEE_PIPS ? MAX_FEE_PIPS : uint24(total);
            }
        }

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | FEE_OVERRIDE_FLAG);
    }

    /// @dev The observation write. Every swap that moves the pool — including the market's own
    ///      opens and liquidations — lands here, which is the whole reason the hook and the
    ///      market are different addresses.
    /// @dev Kept for the permission bit, but it writes nothing: the observation belongs in
    ///      beforeSwap, where the tick is still the one this trade inherited rather than the
    ///      one it produced.
    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, int128)
    {
        return (IHooks.afterSwap.selector, int128(0));
    }

    // ---------------------------------------------------------------- unused permissions

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IHooks.afterDonate.selector;
    }
}
