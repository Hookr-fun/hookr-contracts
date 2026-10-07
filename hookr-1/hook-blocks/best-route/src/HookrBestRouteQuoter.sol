// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHookrRegistry} from "hookr/interfaces/IHookrRegistry.sol";
import {IHookrRoot} from "hookr/interfaces/IHookrRoot.sol";
import {IHookrLaneRoot} from "hookr/interfaces/IHookrLaneRoot.sol";
import {HookrTypes} from "hookr/types/HookrTypes.sol";
import {IHookrRouter} from "hookr/interfaces/IHookrRouter.sol";
import {HookrQuoter} from "hookr/lens/HookrQuoter.sol";
import {BestRouteTypes} from "./HookrBestRouteTypes.sol";
import {HookrRoutePlanner} from "./HookrRoutePlanner.sol";
import {IHookrBestRoute} from "./interfaces/IHookrBestRoute.sol";
import {IPermit2Allowance} from "./interfaces/IPermit2Allowance.sol";
import {IUniswapV3PoolLike} from "./interfaces/IUniswapV3PoolLike.sol";
import {IUniswapV3SwapCallbackLike} from "./interfaces/IUniswapV3SwapCallbackLike.sol";
import {IHookrRootCurated} from "./interfaces/IHookrRootCurated.sol";
import {IHookrQuoteBrakes} from "./interfaces/IHookrQuoteBrakes.sol";

/// @title HookrBestRouteQuoter
/// @notice Off-pool sidecar that compares one exact-input trade on a Hookr pool with Uniswap v3 fee tiers,
///         hookless Uniswap v4 pools and one-hop paths through ETH or USDG, and offers the best one only when it
///         beats the Hookr pool by more than an offer margin: half the trader's slippage unless the request sets
///         its own. The offer is the calldata of one Universal Router `execute` call that the trader sends to the
///         pinned router.
/// @dev Holds no funds, keeps no persistent state and touches no Hookr contract's state: every venue quote is a
///      real swap simulated inside a call that reverts, so pools, hooks and Rules are left as they were.
///      Venues are canonical by construction: a v3 pool is the CREATE2 address of the pinned factory and fee
///      tier (the same address the router computes and trusts), a v4 venue must be hookless on the pinned
///      PoolManager, and a Hookr pool must belong to a registered root and quote through its pinned
///      HookrQuoter. A pool with any other hook is never quoted: a hook can make a simulation and an execution
///      disagree. Each simulation runs under a gas budget and a bounded return-data copy, so one expensive or
///      hostile venue marks its own route and cannot fail the rest. Quotes are for `eth_call`; the offered
///      plan's minimum output, not the quote, is what protects the trader at execution.
///      On the Hookr 1 registry: an asset braked as a quote (`quoteIsBraked`) is never routed through, into or out
///      of; the Hookr pool's quote carries its registry badge (reviewed, or UNREVIEWED under any-quote mode); and a
///      Hookr pool whose recapture lane is on is quoted with a budget that carries the lane's entry floor, and every
///      plan through such a pool names the gas limit that funds it.
contract HookrBestRouteQuoter is IHookrBestRoute, IUnlockCallback, IUniswapV3SwapCallbackLike {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice Largest slippage tolerance accepted, in basis points.
    uint16 public constant MAX_SLIPPAGE_BPS = 5_000;
    /// @notice Gas budget per route step when a request passes zero.
    uint32 public constant DEFAULT_ROUTE_GAS = 3_000_000;
    /// @notice Gas budget for the Hookr pool's quote when a request passes zero.
    uint32 public constant DEFAULT_HOOKR_GAS = 6_000_000;
    /// @notice Smallest and largest per-step budget a request may set.
    uint32 public constant MIN_GAS_BUDGET = 150_000;
    uint32 public constant MAX_GAS_BUDGET = 30_000_000;
    /// @notice The offer margin a request passes for the default rule: gain above half the slippage.
    uint16 public constant DEFAULT_OFFER_MARGIN_BPS = 0;
    /// @notice Smallest and largest explicit offer margin a request may set, in basis points of the Hookr quote.
    uint16 public constant MIN_OFFER_MARGIN_BPS = 1;
    uint16 public constant MAX_OFFER_MARGIN_BPS = 10_000;
    /// @notice Number of v3 fee tiers and hookless v4 shapes tried per leg; see `v3FeeTier` and `v4Shape`.
    uint256 public constant V3_TIERS = 4;
    uint256 public constant V4_SHAPES = 6;

    /// @notice What a Hookr quote of a lane pool needs on top of the lane's entry floor: the HookrQuoter's frames, the
    ///         PoolManager unlock and swap and the root's work up to the lane check, with the 1/64 each call keeps
    ///         back (`laneQuoteGas`).
    uint256 public constant LANE_QUOTE_BASE = 400_000;
    /// @notice What a Universal Router transaction through lane pools needs on top of their summed entry floors: the
    ///         intrinsic gas, the router's commands, the PoolManager unlock and swap and the root's work up to the
    ///         lane check, with the 1/64 each call keeps back (`laneRouteGas`).
    uint256 public constant LANE_ROUTE_BASE = 400_000;
    /// @notice The share of the floor added for the 1/64 rule, as its divisor: floor / 8.
    uint256 public constant LANE_FLOOR_DIVISOR = 8;

    uint256 private constant LEGS = V3_TIERS + V4_SHAPES;
    uint256 private constant LANE_READ_GAS = 60_000;
    uint256 private constant GAS_RESERVE = 40_000;
    uint256 private constant MAX_RETURN = 512;
    uint160 private constant MIN_PRICE_LIMIT = 4295128740;
    uint160 private constant MAX_PRICE_LIMIT = 1461446703485210103287273052203988822378723970341;
    bytes32 private constant ENTERED = keccak256("hookr.bestroute.transient.entered");
    bytes32 private constant PENDING = keccak256("hookr.bestroute.transient.pending");

    /// @notice The pinned Uniswap v4 PoolManager.
    IPoolManager public immutable poolManager;
    /// @notice The Hookr registry that says which roots are Hookr roots.
    IHookrRegistry public immutable registry;
    /// @notice The pinned HookrQuoter every quoted Hookr pool's root names.
    address public immutable hookrQuoter;
    /// @notice The pinned Universal Router plans are built for.
    address public immutable universalRouter;
    /// @notice The router's runtime code hash; plans are refused if the code at `universalRouter` differs.
    bytes32 public immutable universalRouterCodeHash;
    /// @notice Permit2, through which the router pulls an ERC-20 input.
    address public immutable permit2;
    /// @notice The wrapped native token every v3 ETH pool is keyed by.
    address public immutable weth;
    /// @notice The second one-hop intermediate after ETH.
    address public immutable usdg;
    /// @notice The canonical Uniswap v3 factory and its pool init code hash.
    address public immutable v3Factory;
    bytes32 public immutable v3PoolInitCodeHash;

    error Reentered();
    error NotSimulating();
    error InvalidWiring();
    error InvalidRequest();
    error InvalidCallback();
    error RouterNotPinned(address router, bytes32 codeHash);
    error UnsupportedVenue(uint256 index);
    /// @notice A step of the route touches an asset the registry brakes as a quote.
    error BrakedQuote(address asset);
    /// @notice Carries a v3 simulation's pool deltas out of the reverted swap.
    error V3Quote(int256 amount0, int256 amount1);
    /// @notice Carries a v4 simulation's caller deltas out of the reverted unlock.
    error V4Quote(int128 amount0, int128 amount1);

    struct Wiring {
        IPoolManager poolManager;
        IHookrRegistry registry;
        address hookrQuoter;
        address universalRouter;
        bytes32 universalRouterCodeHash;
        address permit2;
        address weth;
        address usdg;
        address v3Factory;
        bytes32 v3PoolInitCodeHash;
    }

    constructor(Wiring memory w) {
        if (
            address(w.poolManager).code.length == 0 || address(w.registry).code.length == 0
                || w.hookrQuoter.code.length == 0 || w.universalRouter.code.length == 0
                || w.universalRouter.codehash != w.universalRouterCodeHash || w.permit2.code.length == 0
                || w.weth.code.length == 0 || w.usdg.code.length == 0 || w.weth == w.usdg || w.v3Factory == address(0)
                || w.v3PoolInitCodeHash == bytes32(0)
                || address(HookrQuoter(w.hookrQuoter).poolManager()) != address(w.poolManager)
                || !_answersBrakes(address(w.registry))
        ) revert InvalidWiring();
        poolManager = w.poolManager;
        registry = w.registry;
        hookrQuoter = w.hookrQuoter;
        universalRouter = w.universalRouter;
        universalRouterCodeHash = w.universalRouterCodeHash;
        permit2 = w.permit2;
        weth = w.weth;
        usdg = w.usdg;
        v3Factory = w.v3Factory;
        v3PoolInitCodeHash = w.v3PoolInitCodeHash;
    }

    /// @inheritdoc IHookrBestRoute
    /// @dev Order: the Hookr pool through the pinned HookrQuoter; every v3 tier and hookless v4 shape for the
    ///      pair; then, for ETH and USDG unless either is the input or output asset, every first leg, the best
    ///      first leg's output through every second leg. Only OK routes compete; ties keep the earlier route.
    ///      The default offer rule is PR #201's, `(best - hookr) * 20000 > hookr * slippageBps`; a request may
    ///      set its own margin instead (`offerableWithMargin`). There is no offer when the Hookr pool itself has
    ///      no OK quote.
    function quote(BestRouteTypes.Request calldata r) external returns (BestRouteTypes.Result memory res) {
        _enter();
        PoolKey memory key = r.hookrKey;
        // forge-lint: disable-next-line(block-timestamp) -- a plan deadline, enforced again by the router.
        bool expired = r.deadline < block.timestamp;
        if (
            r.amountIn == 0 || r.amountIn > uint128(type(int128).max) || r.slippageBps > MAX_SLIPPAGE_BPS || expired
                || r.offerMarginBps > MAX_OFFER_MARGIN_BPS || !_isHookrPool(key)
        ) revert InvalidRequest();
        address cin = r.zeroForOne ? _addr(key, true) : _addr(key, false);
        address cout = r.zeroForOne ? _addr(key, false) : _addr(key, true);
        res.currencyIn = cin;
        res.currencyOut = cout;
        {
            PoolId id = key.toId();
            res.quoteBadge =
                registry.badgeForQuote(Currency.unwrap(IHookrRoot(address(key.hooks)).poolConfig(id).quote));
            res.laneGasFloor = _laneFloor(address(key.hooks), id);
        }
        res.quoteBraked = _braked(cin) || _braked(cout);
        address payer = r.payer == address(0) ? address(this) : r.payer;
        uint256 routeGas = _budget(r.routeGas, DEFAULT_ROUTE_GAS);
        {
            BestRouteTypes.Step[] memory hs = new BestRouteTypes.Step[](1);
            hs[0] = BestRouteTypes.Step(
                BestRouteTypes.Venue.HOOKR, cin, cout, key.fee, key.tickSpacing, address(key.hooks)
            );
            // The trader's own pool is quoted even when one of its currencies is braked: that is the pool on screen.
            res.hookr = _quoteRoute(hs, r.amountIn, payer, _budget(r.hookrGas, DEFAULT_HOOKR_GAS), false);
        }
        BestRouteTypes.RouteQuote[] memory routes = new BestRouteTypes.RouteQuote[](3 * LEGS);
        uint256 n;
        // A pool of ETH against WETH has no alternative this planner can encode: every route would visit one
        // asset twice (HookrRoutePlanner.RepeatedAsset). Quote none, so the answer is the Hookr quote and no offer.
        // A braked currency on either end: quote no alternative, so nothing routes into or out of it.
        if (!res.quoteBraked && _asset(cin) != _asset(cout)) {
            BestRouteTypes.Step[] memory legs = _legs(cin, cout);
            for (uint256 i; i < legs.length; ++i) {
                routes[n++] = _quoteRoute(_one(legs[i]), r.amountIn, payer, routeGas, true);
            }
            address[2] memory mids = [address(0), usdg];
            for (uint256 m; m < 2; ++m) {
                address mid = mids[m];
                if (_asset(mid) == _asset(cin) || _asset(mid) == _asset(cout)) continue;
                n = _oneHop(routes, n, cin, mid, cout, r.amountIn, payer, routeGas);
            }
        }
        assembly ("memory-safe") {
            mstore(routes, n)
        }
        res.routes = routes;
        res.best = BestRouteTypes.NONE;
        uint256 bestOut;
        for (uint256 i; i < n; ++i) {
            if (routes[i].status == BestRouteTypes.Status.OK && routes[i].amountOut > bestOut) {
                bestOut = routes[i].amountOut;
                res.best = i;
            }
        }
        if (res.best != BestRouteTypes.NONE && res.hookr.status == BestRouteTypes.Status.OK) {
            uint256 hookrOut = res.hookr.amountOut;
            res.gainBps = gainBps(bestOut, hookrOut);
            if (offerableWithMargin(bestOut, hookrOut, r.slippageBps, r.offerMarginBps) && routerPinned()) {
                uint256 minOut = FullMath.mulDiv(bestOut, 10_000 - r.slippageBps, 10_000);
                if (minOut != 0 && minOut <= type(uint128).max) {
                    res.executable = true;
                    res.minAmountOut = minOut;
                    res.plan = _plan(routes[res.best].steps, cin, cout, r.amountIn, minOut, r.deadline);
                }
            }
        }
        _exit();
    }

    /// @inheritdoc IHookrBestRoute
    /// @dev A Hookr step quotes through the pinned HookrQuoter for `payer` (zero quotes for this contract).
    ///      `gasBudget` applies to each step; zero means DEFAULT_ROUTE_GAS. A Hookr step on a pool whose recapture
    ///      lane is on gets at least `laneQuoteGas` of its entry floor. A step touching a braked quote is BRAKED.
    function quoteRoute(BestRouteTypes.Step[] calldata steps, uint128 amountIn, address payer, uint32 gasBudget)
        external
        returns (BestRouteTypes.RouteQuote memory route)
    {
        _enter();
        if (
            steps.length == 0 || steps.length > HookrRoutePlanner.MAX_STEPS || amountIn == 0
                || amountIn > uint128(type(int128).max)
        ) revert InvalidRequest();
        for (uint256 i = 1; i < steps.length; ++i) {
            if (!_chains(steps[i - 1], steps[i])) revert InvalidRequest();
        }
        // Each step is simulated from the state before the quote, which is exact only if no pool repeats; a route
        // that visits no asset twice cannot repeat a pool (the rule planRoute enforces too).
        for (uint256 i = 1; i <= steps.length; ++i) {
            address x = _asset(i == steps.length ? steps[i - 1].currencyOut : steps[i].currencyIn);
            for (uint256 j; j < i; ++j) {
                if (_asset(steps[j].currencyIn) == x) revert InvalidRequest();
            }
        }
        route = _quoteRoute(
            steps, amountIn, payer == address(0) ? address(this) : payer, _budget(gasBudget, DEFAULT_ROUTE_GAS), true
        );
        _exit();
    }

    /// @inheritdoc IHookrBestRoute
    /// @dev Refuses unless the router's code hash is the pinned one, every v3 pool has code, every v4 step is an
    ///      initialized hookless pool, and every Hookr step is a known pool of a registered root that trusts this
    ///      router's `msgSender()` (its `curatedRouter`), so the trader is the authenticated payer. Refuses a route
    ///      through, into or out of an asset braked as a quote. A route through lane pools carries their summed entry
    ///      floor and the gas limit that funds it (`Plan.laneGasFloor`, `Plan.gasLimit`).
    function planRoute(
        BestRouteTypes.Step[] calldata steps,
        address currencyIn,
        address currencyOut,
        uint128 amountIn,
        uint128 minAmountOut,
        uint64 deadline
    ) external view returns (BestRouteTypes.Plan memory) {
        if (!routerPinned()) revert RouterNotPinned(universalRouter, universalRouter.codehash);
        // forge-lint: disable-next-line(block-timestamp) -- a plan deadline, enforced again by the router.
        if (deadline < block.timestamp) revert InvalidRequest();
        BestRouteTypes.Step[] memory s = steps;
        for (uint256 i; i < s.length; ++i) {
            if (!_venueExists(s[i], true)) revert UnsupportedVenue(i);
            if (_braked(s[i].currencyIn)) revert BrakedQuote(s[i].currencyIn);
            if (_braked(s[i].currencyOut)) revert BrakedQuote(s[i].currencyOut);
        }
        return _plan(s, currencyIn, currencyOut, amountIn, minAmountOut, deadline);
    }

    /// @inheritdoc IHookrBestRoute
    function approvalNeed(address owner, address token, uint256 amount, uint64 deadline)
        external
        view
        returns (BestRouteTypes.ApprovalNeed)
    {
        if (token == address(0)) return BestRouteTypes.ApprovalNeed.NONE;
        if (IERC20(token).allowance(owner, permit2) < amount) return BestRouteTypes.ApprovalNeed.ERC20_TO_PERMIT2;
        (uint160 allowed, uint48 expiration,) = IPermit2Allowance(permit2).allowance(owner, token, universalRouter);
        if (allowed < amount || expiration < deadline) return BestRouteTypes.ApprovalNeed.PERMIT2_TO_ROUTER;
        return BestRouteTypes.ApprovalNeed.NONE;
    }

    /// @notice The recapture-lane entry floor of a Hookr pool while its lane is on (`IHookrLaneRoot.laneOf`), else
    ///         zero, and zero for any pool that is not a Hookr venue here.
    function laneGasFloor(PoolKey calldata key) external view returns (uint256) {
        if (!_isHookrPool(key)) return 0;
        return _laneFloor(address(key.hooks), key.toId());
    }

    /// @notice The least simulation budget for a Hookr quote of a pool with lane entry floor `floor`: the floor, an
    ///         eighth of it for the 1/64 each call keeps back, and LANE_QUOTE_BASE. Zero for a zero floor.
    function laneQuoteGas(uint256 floor) public pure returns (uint256) {
        return floor == 0 ? 0 : floor + floor / LANE_FLOOR_DIVISOR + LANE_QUOTE_BASE;
    }

    /// @notice The least transaction gas limit for a Universal Router plan whose lane pools' entry floors sum to
    ///         `floorSum`: the sum, an eighth of it for the 1/64 rule, and LANE_ROUTE_BASE. Zero for a zero sum.
    function laneRouteGas(uint256 floorSum) public pure returns (uint256) {
        return floorSum == 0 ? 0 : floorSum + floorSum / LANE_FLOOR_DIVISOR + LANE_ROUTE_BASE;
    }

    /// @notice Whether the registry brakes `currency` as a quote. Native ETH is never braked.
    function quoteBraked(address currency) external view returns (bool) {
        return _braked(currency);
    }

    /// @notice Whether the code at `universalRouter` is still the pinned build.
    function routerPinned() public view returns (bool) {
        return universalRouter.codehash == universalRouterCodeHash;
    }

    /// @notice The default offer rule: the best route beats the Hookr pool by more than half the slippage.
    /// @dev Integer form of `(best - hookr) * 20000 > hookr * slippageBps`, overflow-free: best - hookr must exceed
    ///      floor(hookr * slippageBps / 20000). False when the Hookr pool quoted nothing.
    function offerable(uint256 best, uint256 hookr, uint256 slippageBps) public pure returns (bool) {
        if (hookr == 0 || best <= hookr) return false;
        return best - hookr > FullMath.mulDiv(hookr, slippageBps, 20_000);
    }

    /// @notice The offer rule a request selects: with a zero margin the default rule (`offerable`), otherwise the
    ///         best route must beat the Hookr pool by more than `offerMarginBps` of the Hookr quote.
    /// @dev Integer form of `(best - hookr) * 10000 > hookr * offerMarginBps`, overflow-free. Whatever the margin,
    ///      an offered plan's minimum `best * (1 - s)` is above the Hookr pool's own `hookr * (1 - s)`.
    function offerableWithMargin(uint256 best, uint256 hookr, uint256 slippageBps, uint256 offerMarginBps)
        public
        pure
        returns (bool)
    {
        if (offerMarginBps == DEFAULT_OFFER_MARGIN_BPS) return offerable(best, hookr, slippageBps);
        if (hookr == 0 || best <= hookr) return false;
        return best - hookr > FullMath.mulDiv(hookr, offerMarginBps, 10_000);
    }

    /// @notice `(out - hookr) * 10000 / hookr`, rounded toward zero and clamped to +/-1,000,000.
    function gainBps(uint256 out, uint256 hookr) public pure returns (int256) {
        if (hookr == 0) return 0;
        if (out >= hookr) {
            uint256 diff = out - hookr;
            if (diff / 100 >= hookr) return int256(1_000_000);
            uint256 up = FullMath.mulDiv(diff, 10_000, hookr);
            // forge-lint: disable-next-line(unsafe-typecast) -- up <= 1e6 on the branch that casts it.
            return up > 1_000_000 ? int256(1_000_000) : int256(up);
        }
        uint256 down = FullMath.mulDiv(hookr - out, 10_000, hookr);
        // forge-lint: disable-next-line(unsafe-typecast) -- down <= 1e6 on the branch that casts it.
        return down > 1_000_000 ? -int256(1_000_000) : -int256(down);
    }

    /// @notice The canonical v3 pool for two tokens and a fee tier, whether or not it exists.
    function v3Pool(address tokenA, address tokenB, uint24 fee) public view returns (address) {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(hex"ff", v3Factory, keccak256(abi.encode(t0, t1, fee)), v3PoolInitCodeHash)
                    )
                )
            )
        );
    }

    /// @notice The v3 fee tiers tried on every leg: 0.01%, 0.05%, 0.3%, 1%.
    function v3FeeTier(uint256 i) public pure returns (uint24) {
        if (i == 0) return 100;
        if (i == 1) return 500;
        if (i == 2) return 3000;
        if (i == 3) return 10_000;
        revert InvalidRequest();
    }

    /// @notice The hookless v4 shapes tried on every leg, as (fee, tick spacing): Uniswap's four interface
    ///         defaults, the canonical HOOKR/ETH shape (0.25%, 25) and (1%, 100), where hookless HOOKR/ETH and
    ///         HOOKR/USDG pools exist on Robinhood Chain.
    function v4Shape(uint256 i) public pure returns (uint24 fee, int24 tickSpacing) {
        if (i == 0) return (100, 1);
        if (i == 1) return (500, 10);
        if (i == 2) return (3000, 60);
        if (i == 3) return (10_000, 200);
        if (i == 4) return (2500, 25);
        if (i == 5) return (10_000, 100);
        revert InvalidRequest();
    }

    /// @notice ERC-165: this quote surface and ERC-165 itself.
    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IHookrBestRoute).interfaceId || id == 0x01ffc9a7;
    }

    /// @notice v3 simulation callback. Always reverts with the pool's deltas; nothing is ever paid.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external view {
        if (_get(ENTERED) == 0) revert NotSimulating();
        revert V3Quote(amount0Delta, amount1Delta);
    }

    /// @notice v4 simulation callback. Runs only the committed swap and reverts with its deltas.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || _get(PENDING) != uint256(keccak256(data))) revert InvalidCallback();
        (PoolKey memory key, bool zeroForOne, uint256 amountIn) = abi.decode(data, (PoolKey, bool, uint256));
        BalanceDelta delta = poolManager.swap(
            key,
            // forge-lint: disable-next-line(unsafe-typecast) -- amountIn <= type(int128).max, checked before unlock.
            SwapParams(zeroForOne, -int256(amountIn), zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            bytes("")
        );
        revert V4Quote(delta.amount0(), delta.amount1());
    }

    function _oneHop(
        BestRouteTypes.RouteQuote[] memory routes,
        uint256 n,
        address cin,
        address mid,
        address cout,
        uint256 amountIn,
        address payer,
        uint256 routeGas
    ) private returns (uint256) {
        BestRouteTypes.Step[] memory firsts = _legs(cin, mid);
        BestRouteTypes.RouteQuote memory bestFirst;
        bool found;
        for (uint256 i; i < firsts.length; ++i) {
            BestRouteTypes.RouteQuote memory q = _quoteRoute(_one(firsts[i]), amountIn, payer, routeGas, true);
            if (q.status == BestRouteTypes.Status.OK && (!found || q.amountOut > bestFirst.amountOut)) {
                bestFirst = q;
                found = true;
            }
        }
        if (!found) return n;
        BestRouteTypes.Step[] memory seconds_ = _legs(mid, cout);
        for (uint256 i; i < seconds_.length; ++i) {
            BestRouteTypes.RouteQuote memory q =
                _quoteRoute(_one(seconds_[i]), bestFirst.amountOut, payer, routeGas, true);
            BestRouteTypes.Step[] memory both = new BestRouteTypes.Step[](2);
            both[0] = bestFirst.steps[0];
            both[1] = seconds_[i];
            q.steps = both;
            q.amountInUsed = bestFirst.amountInUsed;
            q.gasUsed += bestFirst.gasUsed;
            routes[n++] = q;
        }
        return n;
    }

    /// @dev Simulates `steps` in order, each from the state before this quote (every simulation reverts), which is
    ///      exact because a route never visits the same pool twice. Stops at the first step that is not OK. With
    ///      `brakes`, a step touching a braked quote stops the route as BRAKED before it is simulated.
    function _quoteRoute(
        BestRouteTypes.Step[] memory steps,
        uint256 amountIn,
        address payer,
        uint256 budget,
        bool brakes
    ) private returns (BestRouteTypes.RouteQuote memory q) {
        q.steps = steps;
        uint256 amount = amountIn;
        for (uint256 i; i < steps.length; ++i) {
            (BestRouteTypes.Status status, uint256 out, uint256 used, uint256 spent) = brakes
                && (_braked(steps[i].currencyIn) || _braked(steps[i].currencyOut))
                ? (BestRouteTypes.Status.BRAKED, 0, 0, 0)
                : _simStep(steps[i], amount, payer, budget);
            q.gasUsed += spent;
            if (i == 0) q.amountInUsed = used;
            q.status = status;
            if (status == BestRouteTypes.Status.OK || status == BestRouteTypes.Status.PARTIAL_FILL) q.amountOut = out;
            if (status != BestRouteTypes.Status.OK) {
                if (status != BestRouteTypes.Status.PARTIAL_FILL) q.amountOut = 0;
                return q;
            }
            amount = out;
        }
    }

    function _simStep(BestRouteTypes.Step memory s, uint256 amountIn, address payer, uint256 budget)
        private
        returns (BestRouteTypes.Status, uint256 out, uint256 used, uint256 spent)
    {
        if (!_venueExists(s, false)) return (BestRouteTypes.Status.NO_POOL, 0, 0, 0);
        if (s.venue == BestRouteTypes.Venue.HOOKR) {
            // A lane pool's swap reverts below its entry floor, so its quote gets at least what carries the floor.
            (PoolKey memory k,) = HookrRoutePlanner.poolKey(s);
            uint256 laneBudget = laneQuoteGas(_laneFloor(s.hooks, k.toId()));
            if (laneBudget > budget) budget = laneBudget;
        }
        if (gasleft() < budget + budget / 63 + GAS_RESERVE) return (BestRouteTypes.Status.SKIPPED, 0, 0, 0);
        uint256 before = gasleft();
        bool ok;
        bytes memory ret;
        uint256 size;
        if (s.venue == BestRouteTypes.Venue.V3) {
            if (amountIn > uint256(type(int256).max)) return (BestRouteTypes.Status.FAILED, 0, 0, 0);
            bool zeroForOne = s.currencyIn < s.currencyOut;
            // forge-lint: disable-next-line(unsafe-typecast) -- amountIn <= type(int256).max, checked above.
            int256 specified = int256(amountIn);
            (ok, ret, size) = _call(
                v3Pool(s.currencyIn, s.currencyOut, s.fee),
                budget,
                abi.encodeCall(
                    IUniswapV3PoolLike.swap,
                    (address(this), zeroForOne, specified, zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT, bytes(""))
                )
            );
            spent = before - gasleft();
            // forge-lint: disable-next-line(unsafe-typecast) -- ret holds 68 bytes here; bytes4 reads the selector.
            if (!ok && size == 68 && bytes4(ret) == V3Quote.selector) {
                (int256 a0, int256 a1) = abi.decode(_strip(ret), (int256, int256));
                (int256 paid, int256 got) = zeroForOne ? (a0, a1) : (a1, a0);
                if (paid < 0 || got > 0 || got == type(int256).min) return (BestRouteTypes.Status.FAILED, 0, 0, spent);
                // forge-lint: disable-next-line(unsafe-typecast) -- paid >= 0 and got in (int256.min, 0], checked above.
                return _classify(amountIn, uint256(-got), uint256(paid), spent);
            }
        } else if (s.venue == BestRouteTypes.Venue.V4) {
            if (amountIn > uint128(type(int128).max)) return (BestRouteTypes.Status.FAILED, 0, 0, 0);
            (PoolKey memory key, bool zeroForOne) = HookrRoutePlanner.poolKey(s);
            bytes memory data = abi.encode(key, zeroForOne, amountIn);
            _put(PENDING, uint256(keccak256(data)));
            (ok, ret, size) = _call(address(poolManager), budget, abi.encodeCall(IPoolManager.unlock, (data)));
            _put(PENDING, 0);
            spent = before - gasleft();
            // forge-lint: disable-next-line(unsafe-typecast) -- ret holds 68 bytes here; bytes4 reads the selector.
            if (!ok && size == 68 && bytes4(ret) == V4Quote.selector) {
                (int128 a0, int128 a1) = abi.decode(_strip(ret), (int128, int128));
                (int128 paid, int128 got) = zeroForOne ? (a0, a1) : (a1, a0);
                if (paid > 0 || got < 0) return (BestRouteTypes.Status.FAILED, 0, 0, spent);
                // forge-lint: disable-next-line(unsafe-typecast) -- got >= 0 and paid <= 0, checked above.
                return _classify(amountIn, uint256(int256(got)), uint256(-int256(paid)), spent);
            }
        } else {
            if (amountIn > uint128(type(int128).max)) return (BestRouteTypes.Status.FAILED, 0, 0, 0);
            (PoolKey memory key, bool zeroForOne) = HookrRoutePlanner.poolKey(s);
            IHookrRouter.Swap memory swap = IHookrRouter.Swap(
                key,
                zeroForOne,
                // forge-lint: disable-next-line(unsafe-typecast) -- amountIn <= type(int128).max, checked above.
                -int128(uint128(amountIn)),
                1,
                zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT,
                payer,
                block.timestamp
            );
            (ok, ret, size) = _call(hookrQuoter, budget, abi.encodeCall(HookrQuoter.quote, (swap, payer)));
            spent = before - gasleft();
            if (ok && size == 13 * 32) {
                HookrTypes.ExecutionReceipt memory receipt = abi.decode(ret, (HookrTypes.ExecutionReceipt));
                if (receipt.quoteRefund != 0) {
                    return (BestRouteTypes.Status.PARTIAL_FILL, receipt.outputAmount, receipt.inputAmount, spent);
                }
                return _classify(amountIn, receipt.outputAmount, receipt.inputAmount, spent);
            }
        }
        // A call that burned (nearly) its whole budget and returned nothing ran out of gas. Out-of-gas deep inside
        // the venue (PoolManager.unlock -> callback -> swap) leaves 1/64 at each frame, so allow 1/16 of slack.
        if (!ok && size == 0 && spent >= budget - budget / 16) {
            return (BestRouteTypes.Status.OVER_BUDGET, 0, 0, spent);
        }
        return (BestRouteTypes.Status.FAILED, 0, 0, spent);
    }

    function _classify(uint256 amountIn, uint256 out, uint256 used, uint256 spent)
        private
        pure
        returns (BestRouteTypes.Status, uint256, uint256, uint256)
    {
        if (used > amountIn) return (BestRouteTypes.Status.FAILED, 0, 0, spent);
        if (out == 0) return (BestRouteTypes.Status.NO_LIQUIDITY, 0, used, spent);
        if (used < amountIn) return (BestRouteTypes.Status.PARTIAL_FILL, out, used, spent);
        return (BestRouteTypes.Status.OK, out, used, spent);
    }

    /// @dev Whether a step names a venue this contract quotes (and, for plans, executes through the router).
    function _venueExists(BestRouteTypes.Step memory s, bool forPlan) private view returns (bool) {
        if (s.currencyIn == s.currencyOut) return false;
        if (s.venue == BestRouteTypes.Venue.V3) {
            if (s.currencyIn == address(0) || s.currencyOut == address(0) || s.hooks != address(0)) return false;
            return v3Pool(s.currencyIn, s.currencyOut, s.fee).code.length != 0;
        }
        if (s.tickSpacing <= 0) return false;
        (PoolKey memory key,) = HookrRoutePlanner.poolKey(s);
        if (s.venue == BestRouteTypes.Venue.V4) {
            if (s.hooks != address(0)) return false;
            (uint160 price,,,) = poolManager.getSlot0(key.toId());
            return price != 0;
        }
        if (!_isHookrPool(key)) return false;
        if (!forPlan) return true;
        return IHookrRoot(s.hooks).curatedRouter() == universalRouter
            && IHookrRootCurated(s.hooks).curatedRouterCodeHash() == universalRouterCodeHash;
    }

    /// @dev A known pool of a registered root on this PoolManager that quotes through the pinned HookrQuoter.
    ///      A pair root (a `HookrPairRoot`, registered through `registerFactoryRoot`, so `rootFactoryOf` names its
    ///      factory) has no HookrQuoter and is never a Hookr venue here. An owned root (registered through
    ///      `registerOwnedRoot`) has no root factory of record and reports its template's HookrQuoter and curated
    ///      router, so its pools are Hookr venues as the template's are.
    function _isHookrPool(PoolKey memory key) private view returns (bool) {
        address root = address(key.hooks);
        if (root == address(0) || !registry.isRoot(root) || registry.rootFactoryOf(root) != address(0)) return false;
        IHookrRoot r = IHookrRoot(root);
        return address(r.poolManager()) == address(poolManager) && r.quoter() == hookrQuoter && r.knownPool(key.toId());
    }

    function _plan(
        BestRouteTypes.Step[] memory steps,
        address cin,
        address cout,
        uint256 amountIn,
        uint256 minOut,
        uint256 deadline
    ) private view returns (BestRouteTypes.Plan memory p) {
        (bytes memory commands, bytes[] memory inputs, uint256 value) =
            HookrRoutePlanner.build(steps, cin, cout, amountIn, minOut, weth);
        p.target = universalRouter;
        p.value = value;
        p.commands = commands;
        p.inputs = inputs;
        p.deadline = deadline;
        p.amountIn = amountIn;
        p.minAmountOut = minOut;
        p.data = HookrRoutePlanner.executeCalldata(commands, inputs, deadline);
        for (uint256 i; i < steps.length; ++i) {
            if (steps[i].venue != BestRouteTypes.Venue.HOOKR) continue;
            (PoolKey memory k,) = HookrRoutePlanner.poolKey(steps[i]);
            p.laneGasFloor += _laneFloor(steps[i].hooks, k.toId());
        }
        p.gasLimit = laneRouteGas(p.laneGasFloor);
    }

    /// @dev A Hookr pool's lane entry floor from `IHookrLaneRoot.laneOf`, read under LANE_READ_GAS; zero when the lane
    ///      is off, the pool has none, or the root does not answer in the expected shape.
    function _laneFloor(address root, PoolId id) private view returns (uint256 floor) {
        (bool ok, bytes memory ret) = root.staticcall{gas: LANE_READ_GAS}(abi.encodeCall(IHookrLaneRoot.laneOf, (id)));
        if (!ok || ret.length != 7 * 32) return 0;
        assembly ("memory-safe") {
            floor := mload(add(ret, 224))
        }
    }

    /// @dev Whether the registry brakes `currency` as a quote. Native ETH (zero) is never braked.
    function _braked(address currency) private view returns (bool braked) {
        if (currency == address(0)) return false;
        (braked,) = IHookrQuoteBrakes(address(registry)).quoteIsBraked(currency);
    }

    /// @dev Whether `reg` answers the Hookr 1 per-asset brake read, so a registry without it is refused at wiring.
    function _answersBrakes(address reg) private view returns (bool) {
        (bool ok, bytes memory ret) = reg.staticcall(abi.encodeCall(IHookrQuoteBrakes.quoteIsBraked, (address(1))));
        return ok && ret.length == 64;
    }

    /// @dev Every direct leg between two v4-form currencies: the four v3 tiers (ETH as WETH), then the six
    ///      hookless v4 shapes. A v3 leg whose two tokens coincide (ETH and WETH) is left out.
    function _legs(address from, address to) private view returns (BestRouteTypes.Step[] memory legs) {
        legs = new BestRouteTypes.Step[](LEGS);
        uint256 k;
        address a = from == address(0) ? weth : from;
        address b = to == address(0) ? weth : to;
        if (a != b) {
            for (uint256 i; i < V3_TIERS; ++i) {
                legs[k++] = BestRouteTypes.Step(BestRouteTypes.Venue.V3, a, b, v3FeeTier(i), 0, address(0));
            }
        }
        for (uint256 i; i < V4_SHAPES; ++i) {
            (uint24 fee, int24 spacing) = v4Shape(i);
            legs[k++] = BestRouteTypes.Step(BestRouteTypes.Venue.V4, from, to, fee, spacing, address(0));
        }
        assembly ("memory-safe") {
            mstore(legs, k)
        }
    }

    function _chains(BestRouteTypes.Step calldata p, BestRouteTypes.Step calldata s) private view returns (bool) {
        if (p.currencyOut == s.currencyIn) return true;
        bool pV3 = p.venue == BestRouteTypes.Venue.V3;
        bool sV3 = s.venue == BestRouteTypes.Venue.V3;
        return (pV3 && !sV3 && p.currencyOut == weth && s.currencyIn == address(0))
            || (!pV3 && sV3 && p.currencyOut == address(0) && s.currencyIn == weth);
    }

    /// @dev CALL with a gas budget, copying at most MAX_RETURN bytes of return data; also returns the full size.
    function _call(address target, uint256 gasBudget, bytes memory data)
        private
        returns (bool ok, bytes memory ret, uint256 size)
    {
        assembly ("memory-safe") {
            ok := call(gasBudget, target, 0, add(data, 32), mload(data), 0, 0)
            size := returndatasize()
            let copy := size
            if gt(copy, MAX_RETURN) { copy := MAX_RETURN }
            ret := mload(0x40)
            mstore(ret, copy)
            returndatacopy(add(ret, 32), 0, copy)
            mstore(0x40, add(add(ret, 32), and(add(copy, 31), not(31))))
        }
    }

    /// @dev The ABI payload of a custom error: its bytes after the 4-byte selector.
    function _strip(bytes memory ret) private pure returns (bytes memory out) {
        out = new bytes(ret.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = ret[i + 4];
        }
    }

    function _one(BestRouteTypes.Step memory s) private pure returns (BestRouteTypes.Step[] memory steps) {
        steps = new BestRouteTypes.Step[](1);
        steps[0] = s;
    }

    function _budget(uint32 requested, uint32 fallback_) private pure returns (uint256) {
        if (requested == 0) return fallback_;
        if (requested < MIN_GAS_BUDGET || requested > MAX_GAS_BUDGET) revert InvalidRequest();
        return requested;
    }

    function _addr(PoolKey memory key, bool zero) private pure returns (address) {
        return Currency.unwrap(zero ? key.currency0 : key.currency1);
    }

    function _asset(address currency) private view returns (address) {
        return currency == weth ? address(0) : currency;
    }

    function _enter() private {
        if (_get(ENTERED) != 0) revert Reentered();
        _put(ENTERED, 1);
    }

    function _exit() private {
        _put(ENTERED, 0);
    }

    function _get(bytes32 slot) private view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    function _put(bytes32 slot, uint256 value) private {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }
}
