// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {HookrTypes} from "../../src/types/HookrTypes.sol";
import {IHookrRoot} from "../../src/interfaces/IHookrRoot.sol";
import {IHookrLaneRoot} from "../../src/interfaces/IHookrLaneRoot.sol";

/// @title CyclingExecutor
/// @notice Test and rehearsal stand-in for a partner recapture executor of the shape the lane is sized for: in one
///         `executeArbitrage` call it runs several arbitrages (the triggering pool against outside venues of its
///         pair) and cycles through the triggering pool's family (the subject bought on one member and sold on
///         another, the two quotes joined by a connector pool), round-robin, one chunk per route per round, until no
///         route has a gap above its threshold or its gas budget runs low. It keeps a partner share fixed in its code
///         (25%, WTH's production share) and pushes the rest to the root; it exposes no `partnerBps()`.
///         Not a partner's code.
/// @dev Every chunk runs in its own self-call and reverts unless it returns more of the triggering pool's quote than
///      it spent and leaves no other delta, so a refused leg (a second direction on a pool of the frame) or an
///      unprofitable chunk unwinds alone. A route's direction is fixed by its first profitable chunk. Gaps are read
///      from slot0 before each chunk, so an arb recapture with nothing to do costs a few storage reads per route. A
///      chunk is sized from the gap above the route's fees and the route's shallowest pool, capped by the route's
///      chunk, which halves on a refused chunk.
contract CyclingExecutor {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    uint160 internal constant MIN_PRICE = 4295128740;
    uint160 internal constant MAX_PRICE = 1461446703485210103287273052203988822378723970341;
    uint256 internal constant WAD = 1e18;
    /// @dev The partner's share of each arb recapture's profit, fixed in code: WTH's production share, 25%, the share
    ///      the lane opens at (the registry's cap, MAX_LANE_PARTNER_BPS).
    uint256 internal constant KEEP_BPS = 2_500;
    /// @dev Gas kept for the payout (take, mint, settleRecapture) and the call's records after the last chunk.
    uint256 internal constant PAYOUT_GAS = 200_000;
    /// @dev Gas one chunk may need: two legs for an arbitrage, three for a cycle, with the self-call around them.
    uint256 internal constant PAIR_CHUNK_GAS = 260_000;
    uint256 internal constant CYCLE_CHUNK_GAS = 380_000;
    /// @dev A route stops after this many halvings of its first chunk.
    uint256 internal constant MAX_HALVINGS = 6;

    struct Trigger {
        Currency quote;
        Currency subject;
        uint128 firstChunk;
    }

    /// @dev An arbitrage against `venue` (same pair as the trigger) when `cycle` is false; otherwise a cycle through
    ///      `venue`, a member of the trigger's family on another quote, and `connector`, the pool of the two quotes.
    ///      `minGapBps` is the least price gap worth a chunk: the sum of the route's fees.
    struct Route {
        PoolKey venue;
        PoolKey connector;
        bool cycle;
        uint16 minGapBps;
    }

    IPoolManager public immutable manager;
    address public immutable root;
    address public immutable partner;
    address public immutable operator;
    mapping(PoolId => Trigger) internal _triggers;
    mapping(PoolId => Route[]) internal _routes;

    uint256 public calls;
    /// @notice Chunks of the last call that closed part of a gap: arbitrages and cycles.
    uint256 public lastArbs;
    uint256 public lastCycles;
    uint256 public lastProfit;
    uint256 public lastKeep;
    /// @notice Gas the last call spent before its payout.
    uint256 public lastGas;
    /// @notice Chunks of every call so far.
    uint256 public totalArbs;
    uint256 public totalCycles;

    error NotRoot();
    error NotOperator();
    error NotSelf();
    error Unprofitable(uint256 spent, uint256 got);
    error LeftDelta(address currency);

    constructor(IPoolManager _manager, address _root, address _partner) {
        manager = _manager;
        root = _root;
        partner = _partner;
        operator = msg.sender;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    /// @notice Lets `trigger` start arb recaptures, with the first chunk in its quote.
    function setTrigger(PoolKey calldata trigger, uint128 firstChunk) external onlyOperator {
        HookrTypes.PoolConfig memory pc = IHookrRoot(root).poolConfig(trigger.toId());
        _triggers[trigger.toId()] = Trigger(pc.quote, pc.subject, firstChunk);
    }

    /// @notice An outside venue of `trigger`'s pair.
    function addVenue(PoolKey calldata trigger, PoolKey calldata venue, uint16 minGapBps) external onlyOperator {
        PoolKey memory none;
        _routes[trigger.toId()].push(Route(venue, none, false, minGapBps));
    }

    /// @notice A cycle through `sibling` (the trigger's subject on another quote) and `connector` (the two quotes).
    function addCycle(PoolKey calldata trigger, PoolKey calldata sibling, PoolKey calldata connector, uint16 minGapBps)
        external
        onlyOperator
    {
        _routes[trigger.toId()].push(Route(sibling, connector, true, minGapBps));
    }

    function routeCount(PoolKey calldata trigger) external view returns (uint256) {
        return _routes[trigger.toId()].length;
    }

    /// @notice The one call the root makes. Returns the profit in the triggering pool's quote; pushes 75% of it.
    function executeArbitrage(PoolKey calldata key, address) external returns (uint256 profit) {
        if (msg.sender != root) revert NotRoot();
        uint256 g0 = gasleft();
        calls++;
        PoolId id = key.toId();
        Trigger memory t = _triggers[id];
        Route[] storage routes = _routes[id];
        uint256 n = routes.length;
        (lastArbs, lastCycles, lastProfit, lastKeep, lastGas) = (0, 0, 0, 0, 0);
        if (n == 0 || t.firstChunk == 0) return 0;
        int256 start = manager.currencyDelta(address(this), t.quote);
        uint256[] memory size = new uint256[](n);
        uint8[] memory dir = new uint8[](n);
        uint256 minChunk = uint256(t.firstChunk) >> MAX_HALVINGS;
        for (uint256 r; r < n; ++r) {
            size[r] = t.firstChunk;
        }
        (uint256 arbs, uint256 cycles) = _rounds(key, t, routes, size, dir, minChunk);
        (lastArbs, lastCycles) = (arbs, cycles);
        (totalArbs, totalCycles) = (totalArbs + arbs, totalCycles + cycles);
        lastGas = g0 - gasleft();
        int256 end = manager.currencyDelta(address(this), t.quote);
        if (end <= start) return 0;
        profit = uint256(end - start);
        uint256 keep = profit * KEEP_BPS / 10_000;
        uint256 pushed = profit - keep;
        if (keep != 0) manager.take(t.quote, partner, keep);
        manager.mint(root, t.quote.toId(), pushed);
        IHookrLaneRoot(root).settleRecapture(key, t.quote, pushed);
        (lastProfit, lastKeep) = (profit, keep);
    }

    function _rounds(
        PoolKey calldata key,
        Trigger memory t,
        Route[] storage routes,
        uint256[] memory size,
        uint8[] memory dir,
        uint256 minChunk
    ) internal returns (uint256 arbs, uint256 cycles) {
        uint256 n = size.length;
        bool active = true;
        while (active) {
            active = false;
            for (uint256 r; r < n; ++r) {
                if (size[r] < minChunk || size[r] == 0) continue;
                Route memory route = routes[r];
                if (gasleft() < PAYOUT_GAS + (route.cycle ? CYCLE_CHUNK_GAS : PAIR_CHUNK_GAS)) return (arbs, cycles);
                uint256 done = _chunk(key, t, route, size, dir, r);
                if (done != 0) active = true;
                if (done == 2) {
                    if (route.cycle) ++cycles;
                    else ++arbs;
                }
            }
        }
    }

    /// @dev One chunk on route `r`: 0 when the route is done (no gap above its fees, or the gap turned), 1 when the
    ///      chunk was refused (the route's chunk halves), 2 when it closed part of the gap.
    function _chunk(
        PoolKey calldata key,
        Trigger memory t,
        Route memory route,
        uint256[] memory size,
        uint8[] memory dir,
        uint256 r
    ) internal returns (uint256) {
        // The gap: the subject's price in the trigger's quote on the trigger against the route.
        uint256 here = _price(key, t.subject);
        uint256 there = route.cycle
            ? FullMath.mulDiv(
                _price(route.venue, t.subject), _price(route.connector, _other(route.venue, t.subject)), WAD
            )
            : _price(route.venue, t.subject);
        bool cheapHere = here < there;
        (uint256 lo, uint256 hi) = cheapHere ? (here, there) : (there, here);
        uint8 want = cheapHere ? 1 : 2;
        if (hi * 10_000 <= lo * (10_000 + uint256(route.minGapBps)) || (dir[r] != 0 && dir[r] != want)) {
            size[r] = 0;
            return 0;
        }
        // Sized from the gap above the route's fees and the shallowest pool on the route: about what moves each pool
        // its share of the way, capped by the route's current chunk.
        uint256 amount =
            _depth(key, route, t) * ((hi - lo) * 10_000 / lo - route.minGapBps) / (route.cycle ? 60_000 : 40_000);
        if (amount > size[r]) amount = size[r];
        if (amount == 0) {
            size[r] = 0;
            return 0;
        }
        try this.step(key, route, t.quote, t.subject, amount, cheapHere) {
            dir[r] = want;
            return 2;
        } catch {
            size[r] = amount / 2;
            return 1;
        }
    }

    /// @notice One chunk of a route, reverting unless it gains the trigger's quote and leaves every other delta as it
    ///         found it. Only this contract.
    function step(PoolKey calldata trigger, Route calldata route, Currency q, Currency s, uint256 amount, bool buyHere)
        external
    {
        if (msg.sender != address(this)) revert NotSelf();
        int256 q0 = manager.currencyDelta(address(this), q);
        int256 s0 = manager.currencyDelta(address(this), s);
        if (!route.cycle) {
            (PoolKey memory buyAt, PoolKey memory sellAt) = buyHere ? (trigger, route.venue) : (route.venue, trigger);
            _swapIn(sellAt, s, _swapIn(buyAt, q, amount));
        } else {
            Currency x = _other(route.venue, s);
            int256 x0 = manager.currencyDelta(address(this), x);
            if (buyHere) {
                _swapIn(route.connector, x, _swapIn(route.venue, s, _swapIn(trigger, q, amount)));
            } else {
                _swapIn(trigger, s, _swapIn(route.venue, x, _swapIn(route.connector, q, amount)));
            }
            if (manager.currencyDelta(address(this), x) != x0) revert LeftDelta(Currency.unwrap(x));
        }
        if (manager.currencyDelta(address(this), s) != s0) revert LeftDelta(Currency.unwrap(s));
        int256 q1 = manager.currencyDelta(address(this), q);
        if (q1 <= q0) revert Unprofitable(amount, uint256(q1 - q0 + int256(amount)));
    }

    /// @dev Exact input `amount` of `input` on `key`; returns the output. The deltas stay open until the payout.
    function _swapIn(PoolKey memory key, Currency input, uint256 amount) internal returns (uint256) {
        bool zeroForOne = input == key.currency0;
        BalanceDelta d =
            manager.swap(key, SwapParams(zeroForOne, -int256(amount), zeroForOne ? MIN_PRICE + 1 : MAX_PRICE - 1), "");
        return uint256(uint128(zeroForOne ? d.amount1() : d.amount0()));
    }

    /// @dev The shallowest virtual reserve on the route, in the trigger's quote.
    function _depth(PoolKey calldata key, Route memory route, Trigger memory t) internal view returns (uint256 d) {
        d = _reserve(key, t.quote);
        uint256 e;
        if (route.cycle) {
            Currency x = _other(route.venue, t.subject);
            e = FullMath.mulDiv(_reserve(route.venue, x), _price(route.connector, x), WAD);
            uint256 c = _reserve(route.connector, t.quote);
            if (c < e) e = c;
        } else {
            e = _reserve(route.venue, t.quote);
        }
        if (e < d) d = e;
    }

    /// @dev The virtual reserve of `c` at the pool's current price and in-range liquidity.
    function _reserve(PoolKey memory key, Currency c) internal view returns (uint256) {
        PoolId id = key.toId();
        (uint160 sqrtPrice,,,) = manager.getSlot0(id);
        uint256 liquidity = manager.getLiquidity(id);
        return c == key.currency1
            ? FullMath.mulDiv(liquidity, sqrtPrice, 1 << 96)
            : FullMath.mulDiv(liquidity, 1 << 96, sqrtPrice);
    }

    /// @dev The price of `base` in the pool's other currency, in WAD.
    function _price(PoolKey memory key, Currency base) internal view returns (uint256) {
        (uint160 sqrtPrice,,,) = manager.getSlot0(key.toId());
        uint256 p = FullMath.mulDiv(sqrtPrice, sqrtPrice, 1 << 96);
        return base == key.currency0 ? FullMath.mulDiv(p, WAD, 1 << 96) : FullMath.mulDiv(1 << 96, WAD, p);
    }

    function _other(PoolKey memory key, Currency c) internal pure returns (Currency) {
        return key.currency0 == c ? key.currency1 : key.currency0;
    }

    receive() external payable {}
}

/// @title HooklessVenue
/// @notice Test and rehearsal utility: initializes hookless v4 pools, adds liquidity to them from the caller, and makes
///         unauthenticated exact-input swaps on any pool for the caller. Positions stay with this contract.
contract HooklessVenue is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    uint160 internal constant MIN_PRICE = 4295128740;
    uint160 internal constant MAX_PRICE = 1461446703485210103287273052203988822378723970341;
    IPoolManager public immutable manager;
    address private _payer;

    error Hooked();
    error InvalidCallback();

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    /// @notice Initializes `key` at `sqrtPriceX96` if needed and adds `liquidity` over the range, paid by the caller.
    function seed(PoolKey calldata key, uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint128 liquidity)
        external
        payable
    {
        if (address(key.hooks) != address(0)) revert Hooked();
        (uint160 price,,,) = manager.getSlot0(key.toId());
        if (price == 0) manager.initialize(key, sqrtPriceX96);
        _unlock(abi.encode(key, true, false, int256(uint256(liquidity)), tickLower, tickUpper, uint160(0)));
    }

    /// @notice Exact-input swap of `amountIn` for the caller, stopping at `limit` (zero: no limit). Returns the output.
    function swap(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint160 limit)
        external
        payable
        returns (uint256 out)
    {
        if (limit == 0) limit = zeroForOne ? MIN_PRICE + 1 : MAX_PRICE - 1;
        out = abi.decode(
            _unlock(abi.encode(key, false, zeroForOne, -int256(amountIn), int24(0), int24(0), limit)), (uint256)
        );
    }

    function _unlock(bytes memory data) private returns (bytes memory result) {
        _payer = msg.sender;
        result = manager.unlock(data);
        _payer = address(0);
        if (address(this).balance != 0) {
            (bool ok,) = msg.sender.call{value: address(this).balance}("");
            require(ok, "refund");
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager) || _payer == address(0)) revert InvalidCallback();
        (PoolKey memory key, bool add, bool zeroForOne, int256 amount, int24 lower, int24 upper, uint160 limit) =
            abi.decode(data, (PoolKey, bool, bool, int256, int24, int24, uint160));
        uint256 out;
        if (add) {
            manager.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, amount, 0), "");
        } else {
            BalanceDelta d = manager.swap(key, SwapParams(zeroForOne, amount, limit), "");
            int128 o = zeroForOne ? d.amount1() : d.amount0();
            out = o > 0 ? uint256(uint128(o)) : 0;
        }
        _close(key.currency0);
        _close(key.currency1);
        return abi.encode(out);
    }

    function _close(Currency c) private {
        int256 d = manager.currencyDelta(address(this), c);
        if (d > 0) {
            manager.take(c, _payer, uint256(d));
        } else if (d < 0) {
            uint256 owed = uint256(-d);
            if (c.isAddressZero()) {
                manager.settle{value: owed}();
            } else {
                manager.sync(c);
                IERC20(Currency.unwrap(c)).transferFrom(_payer, address(manager), owed);
                manager.settle();
            }
        }
    }

    receive() external payable {}
}
