// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {V4PoolMath} from "./V4PoolMath.sol";
import {HookrToken} from "../HookrToken.sol";
import {HookrHook} from "../HookrHook.sol";

/// @title HookrLaunchpadLib
/// @notice The code HookrLaunchpad deploys separately and links by DELEGATECALL: the token
///         factory, the bonding-curve arithmetic, and the pool/tranche geometry.
/// @dev This exists for EIP-170, not for abstraction. With the token's creation code, the curve
///      walk, the tranche geometry and the Uniswap tick/liquidity math all inlined into it,
///      HookrLaunchpad's deployed runtime is 28,134 bytes — 3,558 over the 24,576-byte limit, so
///      it simply cannot be deployed. Declaring these `public` makes solc link them by
///      DELEGATECALL: they are deployed once, separately, and the launchpad carries only the
///      call stubs. Measured: 28,134 -> 22,952 bytes.
///
///      ONE library, not several, is deliberate. Each linked library is an extra deploy
///      transaction, and the release pipeline verifies an exact ordered list of receipts. Two
///      tidier libraries would cost a second transaction in that list for no runtime benefit,
///      so the token factory and the math share a deployment unit even though they are
///      unrelated concerns.
///
///      The function boundary is drawn to minimise CROSSINGS, not to be pretty: each linked call
///      costs the launchpad roughly 200 bytes of encode/DELEGATECALL/decode stub, so a
///      fine-grained re-export of the same math gives most of the savings straight back (measured
///      at an intermediate step: 19 call sites recovered only 1,010 bytes). That is why several
///      functions bundle a whole call sequence (`liquidityForAmountsInRange`, `trancheRange`,
///      `curveParams`) instead of exposing their parts.
///
///      Semantics are preserved verbatim: every body below is the launchpad's or V4PoolMath's
///      former body with storage reads lifted into parameters. The only deliberate change is that
///      the two bound checks which used to revert inside the math (`SlippageExceeded` when a sell
///      exceeds the sold supply, `TargetOutOfRange` when the graduation sqrt price overflows
///      uint160) now happen at the launchpad call site, so those custom errors stay owned by the
///      contract that defines them and no error selector moves.
///
///      DELEGATECALL means these run in the launchpad's context. Every function except
///      `deployToken` is `pure`; `deployToken` only ever CREATEs. Nothing here reads or writes
///      launchpad storage, so the delegate frame carries no authority over it.
library HookrLaunchpadLib {
    // Mirrors of HookrLaunchpad's curve constants. `internal constant`, so they compile into this
    // library's own code rather than becoming linked reads.
    uint256 internal constant CURVE_SUPPLY = 800_000_000e18;
    uint256 internal constant TRANCHE_TOKENS = 80_000_000e18;
    uint256 internal constant TRANCHES = 10;
    uint256 internal constant PRICE_NUM = 17;
    uint256 internal constant PRICE_DEN = 10;
    uint256 internal constant BPS = 10_000;

    // Mirrors of HookrLaunchpad's instant-launch bounds. The launchpad re-exports each of these
    // as a public constant and `InstantLaunchTest.test_libraryBoundsMirrorTheLaunchpad` pins the
    // two copies together, so a drift here fails the suite rather than the creator.
    uint256 internal constant MIN_ETH_IN = 0.0001 ether;
    uint256 internal constant MAX_ETH_IN = 1000 ether;
    uint16 internal constant MIN_POOL_SUPPLY_BPS = 2000;
    uint96 internal constant MIN_OPEN_PRICE_WEI = 1e6;

    /// @notice Rejection reasons for `instantPlan`, in the order the launchpad checks them.
    uint8 internal constant PLAN_OK = 0;
    uint8 internal constant PLAN_BAD_ETH = 1;
    uint8 internal constant PLAN_BAD_SHARE = 2;
    uint8 internal constant PLAN_BAD_PRICE = 3;

    /// @dev Mirrors of `HookrLaunchpad`'s three unlock actions — the complete set. Both launch
    ///      paths seed their one position through `CB_GRADUATE`; `CB_TRANCHE` mints a token-only
    ///      band; `CB_COLLECT` passes a liquidity delta of exactly zero. There is no fourth, and
    ///      none of these can carry a negative liquidity delta, which is what makes the launchpad's
    ///      liquidity locked by construction rather than by policy.
    uint8 internal constant CB_GRADUATE = 1;
    uint8 internal constant CB_COLLECT = 2;
    uint8 internal constant CB_TRANCHE = 3;

    // ------------------------------------------------------------------ pool opening

    /// @notice Configure the hook, create the pool, and seed the one position it will ever have.
    /// @dev Runs by DELEGATECALL, so `address(this)` is still the launchpad. That is load-bearing
    ///      three times over: `configurePool` is gated on the launchpad address, `beforeInitialize`
    ///      checks the initializing sender is the launchpad, and `unlock` calls back into the
    ///      LAUNCHPAD's `unlockCallback` — which is where the position is minted, and therefore who
    ///      Uniswap records as its owner. Moving this sequence here changes which contract's
    ///      bytecode holds the instructions and nothing else.
    ///
    ///      This function reads and writes no launchpad storage; the caller keeps every state
    ///      write, and hands in the config it built from storage itself.
    function openPool(
        IPoolManager pm,
        HookrHook hookContract,
        PoolKey memory key,
        HookrHook.PoolConfig memory cfg,
        uint160 sqrtPriceX96,
        uint256 ethForPool,
        uint256 tokensForPool
    ) public returns (uint256 ethUsed, uint256 tokensUsed) {
        // Configure behavior, then create the pool (beforeInitialize enforces this ordering).
        hookContract.configurePool(key, cfg);
        pm.initialize(key, sqrtPriceX96);
        hookContract.syncBaseFee(key);
        bytes memory result = pm.unlock(abi.encode(CB_GRADUATE, key, sqrtPriceX96, ethForPool, tokensForPool));
        return abi.decode(result, (uint256, uint256));
    }

    /// @notice Mint one token-only band over `[lower, upper]`, funded with `amount` of token1.
    /// @dev Pure code motion of the launchpad's `CB_TRANCHE` unlock, linked out for EIP-170.
    function seedBand(IPoolManager pm, PoolKey memory key, int24 lower, int24 upper, uint256 amount)
        public
        returns (uint256 used)
    {
        return abi.decode(pm.unlock(abi.encode(CB_TRANCHE, key, lower, upper, amount)), (uint256));
    }

    /// @notice Mint one token-only band over `[lower, upper]` and settle what it consumed.
    /// @dev The inside of the launchpad's `CB_TRANCHE` callback, linked out for EIP-170. Runs by
    ///      DELEGATECALL, so the position Uniswap records belongs to the LAUNCHPAD and the tokens
    ///      settled are the launchpad's own — moving this changes which contract's bytecode holds
    ///      the instructions and nothing else.
    ///
    ///      A band whose liquidity `bandLiquidity` refuses to price mints nothing and reports zero
    ///      on both sides, so `_seedTranches` skips it and burns the slice.
    /// @return owedToken token1 the band consumed and this call has already settled.
    /// @return owedEth ETH the band would draw. A token-only band above spot must never draw any;
    ///         it is RETURNED rather than reverted on so the launchpad raises its own `BadLpPlan`.
    function mintBand(IPoolManager pm, PoolKey memory key, int24 lower, int24 upper, uint256 amount)
        public
        returns (uint256 owedToken, uint256 owedEth)
    {
        uint128 liquidity = bandLiquidity(lower, upper, amount);
        if (liquidity == 0) return (0, 0);

        (BalanceDelta delta,) = pm.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: lower, tickUpper: upper, liquidityDelta: int256(uint256(liquidity)), salt: bytes32(0)
            }),
            ""
        );
        if (delta.amount0() < 0) return (0, uint256(uint128(-delta.amount0())));
        owedToken = delta.amount1() < 0 ? uint256(uint128(-delta.amount1())) : 0;
        if (owedToken > 0) {
            pm.sync(key.currency1);
            HookrToken(Currency.unwrap(key.currency1)).transfer(address(pm), owedToken);
            pm.settle();
        }
    }

    /// @notice Poke one position's accrued fees out of the pool with a zero liquidity delta.
    /// @dev `lowerSlot`/`upperSlot` ride in the two amount slots exactly as the launchpad's
    ///      callback expects: zero for both means the full-range position, otherwise they are
    ///      `uint256(uint24(tick))` bit patterns the callback truncates back to `int24`. Pure code
    ///      motion of the launchpad's `CB_COLLECT` unlocks, linked out for EIP-170.
    function collectRange(IPoolManager pm, PoolKey memory key, uint256 lowerSlot, uint256 upperSlot)
        public
        returns (uint256 ethAmount, uint256 tokenAmount)
    {
        bytes memory out = pm.unlock(abi.encode(CB_COLLECT, key, uint160(0), lowerSlot, upperSlot));
        return abi.decode(out, (uint256, uint256));
    }

    // ------------------------------------------------------------------ token factory

    /// @notice Deploys the launch's ERC-20.
    /// @dev The single largest line item: an inline `new HookrToken(...)` embeds the token's
    ///      entire ~3.8KB creation code in the launchpad's own runtime. Here it is embedded in
    ///      the library instead. Because the library runs by DELEGATECALL, the CREATE is still
    ///      performed BY the launchpad — same deployer, same nonce sequence, therefore the same
    ///      token address — and inside the constructor `msg.sender` is still the launchpad, so
    ///      `HookrToken.launchpad` and the initial supply holder are unchanged.
    function deployToken(
        string calldata name,
        string calldata symbol,
        string calldata tagline,
        string calldata logoURI,
        address creator,
        uint256 supply
    ) public returns (address) {
        return address(new HookrToken(name, symbol, tagline, logoURI, creator, supply));
    }

    // ------------------------------------------------------------------ curve math

    /// @notice The curve's base price and the exact proceeds a full sale yields, together.
    /// @dev Returned as a pair because the launchpad always needs both. `p0 == 0` means the
    ///      requested target does not fit a uint96 base price; `target` is then meaningless.
    function curveParams(uint96 targetWei) public pure returns (uint96 p0, uint96 target) {
        p0 = _basePriceForTarget(targetWei);
        if (p0 != 0) target = _exactTarget(p0);
    }

    function tranchePrice(uint96 p0, uint256 k) public pure returns (uint256 p) {
        p = p0;
        for (uint256 i = 0; i < k; i++) {
            p = (p * PRICE_NUM) / PRICE_DEN;
        }
    }

    /// @notice Walks a buy up the stepped curve. `sold_`/`p0` are the launch's stored state.
    function walkUp(uint128 sold_, uint96 p0, uint256 maxNet)
        public
        pure
        returns (uint256 tokensOut, uint256 ethUsed, uint128 newSold)
    {
        uint256 sold = sold_;
        uint256 remaining = maxNet;
        while (remaining > 0 && sold < CURVE_SUPPLY) {
            uint256 k = sold / TRANCHE_TOKENS;
            uint256 pk = _tranchePrice(p0, k);
            uint256 trancheEnd = (k + 1) * TRANCHE_TOKENS;
            uint256 leftTokens = trancheEnd - sold;
            uint256 costLeft = _ceilDiv(leftTokens * pk, 1e18);
            if (remaining >= costLeft) {
                tokensOut += leftTokens;
                sold = trancheEnd;
                remaining -= costLeft;
            } else {
                uint256 chunk = (remaining * 1e18) / pk;
                if (chunk == 0) break;
                if (chunk > leftTokens) chunk = leftTokens;
                uint256 cost = _ceilDiv(chunk * pk, 1e18);
                tokensOut += chunk;
                sold += chunk;
                remaining -= cost;
                break;
            }
        }
        ethUsed = maxNet - remaining;
        newSold = uint128(sold);
    }

    /// @notice Walks a sell back down the curve. The caller must already have rejected
    ///         `tokenAmount > sold_` — this function assumes it holds.
    function walkDown(uint128 sold_, uint96 p0, uint256 tokenAmount)
        public
        pure
        returns (uint256 grossOut, uint128 newSold)
    {
        uint256 sold = sold_;
        uint256 remaining = tokenAmount;
        while (remaining > 0) {
            uint256 k = (sold - 1) / TRANCHE_TOKENS;
            uint256 pk = _tranchePrice(p0, k);
            uint256 trancheStart = k * TRANCHE_TOKENS;
            uint256 inTranche = sold - trancheStart;
            uint256 chunk = remaining < inTranche ? remaining : inTranche;
            grossOut += (chunk * pk) / 1e18; // floor: the reserve keeps the dust
            sold -= chunk;
            remaining -= chunk;
        }
        newSold = uint128(sold);
    }

    /// @notice `sqrt((1e18 << 192) / pFinal)` — the graduation sqrt price, unbounded.
    /// @dev Returns the raw root so the caller owns the `uint160` bound check (and its error).
    function sqrtPriceX96ForPrice(uint256 pFinal) public pure returns (uint256) {
        // v4 price = currency1/currency0 = tokenWei per ethWei = 1e18 / pFinal.
        return _sqrt((uint256(1e18) << 192) / pFinal);
    }

    /// @notice The entire opening plan of a curve-free launch, and every reason to refuse one.
    ///
    /// @dev The price is DERIVED, never supplied: it is exactly `ethIn / tokensInPool`, so a
    ///      caller cannot express a price that is not backed by ETH the launchpad is holding. The
    ///      creator's real choice is `openFdvWei == ethIn * BPS / poolSupplyBps`, and because
    ///      `poolSupplyBps` is clamped to [MIN_POOL_SUPPLY_BPS, BPS] that valuation is clamped to
    ///      [1x, 5x] the ETH committed. Both degenerate ends are unreachable, not merely rare.
    ///
    ///      Rounding is deliberately UP on the wei-per-token figure, which biases the sqrt price
    ///      DOWN, which makes the opening full-range position ETH-limited rather than
    ///      token-limited. The consequence is the one worth having: the depositor's ETH is
    ///      consumed essentially in full, and the rounding residue lands on the TOKEN side, where
    ///      an instant launch already has a defined destination for it (a band, or the burn).
    ///
    ///      The three `PLAN_BAD_PRICE` cases, in the order they can bite:
    ///        - QUANTIZATION. `openPriceWei` is an integer, so the realized price differs from the
    ///          requested ratio by at most one part in `openPriceWei`. Below `MIN_OPEN_PRICE_WEI`
    ///          that error stops being negligible, which is the "price so low the conversion loses
    ///          precision" end: a large share of supply asked for against very little ETH.
    ///        - REPRESENTABILITY. A root wider than uint160 is not a v4 price at all.
    ///        - USABLE RANGE. This is the quiet one. At or past either bound of the full-range
    ///          position, `getLiquidityForAmounts` reads only ONE of the two amounts, so the pool
    ///          would open holding the creator's ETH and none of the supply (or the reverse) with
    ///          no error anywhere. Refusing is the only safe answer.
    ///
    /// @return tokensInPool  `supply * poolSupplyBps / BPS` — the tradeable float at open.
    /// @return openPriceWei  Wei per whole token, `ceil(ethIn / tokensInPool)`.
    /// @return sqrtPriceX96  The same price as a v4 sqrt price. Zero when unrepresentable.
    /// @return openFdvWei    `supply * openPriceWei`, the number the creator is really choosing.
    /// @return err           `PLAN_OK`, or which bound the inputs broke. The launchpad maps this
    ///                       onto its own named errors; the UI shows it before anyone signs.
    function instantPlan(uint256 ethIn, uint16 poolSupplyBps, uint256 supply, int24 tickSpacing)
        public
        pure
        returns (uint256 tokensInPool, uint96 openPriceWei, uint160 sqrtPriceX96, uint256 openFdvWei, uint8 err)
    {
        if (ethIn < MIN_ETH_IN || ethIn > MAX_ETH_IN) return (0, 0, 0, 0, PLAN_BAD_ETH);
        if (poolSupplyBps < MIN_POOL_SUPPLY_BPS || poolSupplyBps > BPS) return (0, 0, 0, 0, PLAN_BAD_SHARE);

        tokensInPool = (supply * poolSupplyBps) / BPS;
        if (tokensInPool == 0) return (0, 0, 0, 0, PLAN_BAD_SHARE);

        uint256 p = _ceilDiv(ethIn * 1e18, tokensInPool);
        if (p < MIN_OPEN_PRICE_WEI || p > type(uint96).max) return (tokensInPool, 0, 0, 0, PLAN_BAD_PRICE);
        // casting to 'uint96' is safe: bounds-checked on the line above.
        // forge-lint: disable-next-line(unsafe-typecast)
        openPriceWei = uint96(p);
        openFdvWei = (supply * p) / 1e18;

        uint256 root = _sqrt((uint256(1e18) << 192) / p);
        if (root > type(uint160).max) return (tokensInPool, openPriceWei, 0, openFdvWei, PLAN_BAD_PRICE);
        // casting to 'uint160' is safe: bounds-checked on the line above.
        // forge-lint: disable-next-line(unsafe-typecast)
        sqrtPriceX96 = uint160(root);

        (int24 tickLower, int24 tickUpper) = V4PoolMath.usableTickRange(tickSpacing);
        if (
            sqrtPriceX96 <= V4PoolMath.getSqrtPriceAtTick(tickLower)
                || sqrtPriceX96 >= V4PoolMath.getSqrtPriceAtTick(tickUpper)
        ) {
            return (tokensInPool, openPriceWei, sqrtPriceX96, openFdvWei, PLAN_BAD_PRICE);
        }
    }

    function _basePriceForTarget(uint96 targetWei) private pure returns (uint96) {
        // target = (TRANCHE_TOKENS / 1e18) * sum p_k, with p_k = p0 * (17/10)^k (floored iteratively).
        // Solve p0 against the closed-form sum N/1e9 (N = sum 17^k * 10^(9-k)), then recompute the
        // exact floored target from p0 so charging and graduation share identical math.
        uint256 n = 0;
        uint256 num = 10 ** 9;
        for (uint256 k = 0; k < TRANCHES; k++) {
            n += num;
            num = (num * PRICE_NUM) / PRICE_DEN;
        }
        uint256 p0 = (uint256(targetWei) * 1e9) / ((TRANCHE_TOKENS / 1e18) * n);
        return p0 > type(uint96).max ? 0 : uint96(p0);
    }

    function _exactTarget(uint96 p0) private pure returns (uint96) {
        uint256 total = 0;
        uint256 p = p0;
        for (uint256 k = 0; k < TRANCHES; k++) {
            total += (TRANCHE_TOKENS * p) / 1e18;
            p = (p * PRICE_NUM) / PRICE_DEN;
        }
        return uint96(total);
    }

    function _tranchePrice(uint96 p0, uint256 k) private pure returns (uint256 p) {
        p = p0;
        for (uint256 i = 0; i < k; i++) {
            p = (p * PRICE_NUM) / PRICE_DEN;
        }
    }

    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    function _sqrt(uint256 x) private pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    // ------------------------------------------------------------------ v4 pool math

    /// @notice Largest full-range position expressible at `tickSpacing`.
    function usableTickRange(int24 tickSpacing) public pure returns (int24 tickLower, int24 tickUpper) {
        return V4PoolMath.usableTickRange(tickSpacing);
    }

    /// @notice Liquidity a token1-only band over `[tickLower, tickUpper]` can fund, or ZERO when
    ///         that band is not one this pool can hold.
    ///
    /// @dev The zero return is the whole point, and it is load-bearing. Liquidity is
    ///      `amount1 * Q96 / (sqrtUpper - sqrtLower)`, so it grows without bound as the band's
    ///      sqrt-price width shrinks — which is what happens far below spot. Past roughly 560,000
    ///      ticks down, a leftover-sized `amount1` no longer fits uint128.
    ///
    ///      `HookrLaunchpad._seedTranches` documents that an unusable band is SKIPPED and its
    ///      slice burned, never allowed to revert the launch. It could not keep that promise while
    ///      this reverted: the overflow fired inside the `unlock` callback, past the point where
    ///      the launchpad could catch it, so a single misconfigured band made every graduating buy
    ///      revert forever — the raise stranded in the launchpad and the token permanently unable
    ///      to open a pool. Refusing to price an unusable band is the one behavior that keeps the
    ///      failure proportional to the mistake.
    ///
    ///      A launch cannot normally reach this: `MAX_TRANCHE_OFFSET` bounds the offsets an order
    ///      of magnitude short of it. This is the floor under that bound, not a substitute for it.
    function bandLiquidity(int24 tickLower, int24 tickUpper, uint256 amount1) public pure returns (uint128) {
        uint160 lower = V4PoolMath.getSqrtPriceAtTick(tickLower);
        uint160 upper = V4PoolMath.getSqrtPriceAtTick(tickUpper);
        if (upper <= lower) return 0;
        uint256 liquidity = V4PoolMath.mulDiv(amount1, V4PoolMath.Q96, upper - lower);
        if (liquidity > type(uint128).max) return 0;
        // casting to 'uint128' is safe: bounds-checked on the line above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(liquidity);
    }

    /// @notice Liquidity both amounts jointly fund over `[tickLower, tickUpper]` at spot.
    function liquidityForAmountsInRange(
        int24 tickLower,
        int24 tickUpper,
        uint160 sqrtPriceX96,
        uint256 amount0,
        uint256 amount1
    ) public pure returns (uint128) {
        return V4PoolMath.getLiquidityForAmounts(
            sqrtPriceX96,
            V4PoolMath.getSqrtPriceAtTick(tickLower),
            V4PoolMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );
    }

    /// @notice The aligned, bounds-checked tick range of one token-only band below `refTick`.
    /// @dev Returns `ok == false` for exactly the cases the launchpad used to skip inline: a band
    ///      alignment collapsed, one outside the usable range, and one not strictly below the
    ///      reference tick. It is TOTAL — every input returns, none panics — because the launchpad
    ///      treats a false here as "skip this band and burn its slice", and a function that can
    ///      panic instead cannot be skipped.
    function trancheRange(int24 refTick, int24 tickSpacing, int24 startOffset, int24 endOffset)
        public
        pure
        returns (bool ok, int24 lower, int24 upper)
    {
        (int24 minTick, int24 maxTick) = V4PoolMath.usableTickRange(tickSpacing);
        // Widen before subtracting. `refTick - endOffset` is int24 arithmetic on an offset that is
        // only bounded by its own type, so it can leave int24 entirely, and `_alignTick`'s
        // round-toward-negative-infinity step can carry an already-extreme result over the edge.
        // Either way Solidity panics 0x11 — inside the unlock callback, where nothing can catch
        // it. A band this far out is one to refuse, and refusing has to be something this function
        // can actually do.
        int256 rawLower = int256(refTick) - int256(endOffset);
        int256 rawUpper = int256(refTick) - int256(startOffset);
        if (rawLower < minTick || rawLower > maxTick) return (false, 0, 0);
        if (rawUpper < minTick || rawUpper > maxTick) return (false, 0, 0);

        // casting to 'int24' is safe: both values are bounded by the usable tick range above.
        // forge-lint: disable-next-line(unsafe-typecast)
        lower = _alignTick(int24(rawLower), tickSpacing);
        // forge-lint: disable-next-line(unsafe-typecast)
        upper = _alignTick(int24(rawUpper), tickSpacing);
        if (upper <= lower) return (false, 0, 0);
        if (lower < minTick || upper > maxTick) return (false, 0, 0);
        if (upper > refTick) return (false, 0, 0);
        ok = true;
    }

    /// @notice `trancheRange` against the tick implied by a sqrt price — the graduation tick.
    function trancheRangeAtSqrtPrice(uint160 sqrtPriceX96, int24 tickSpacing, int24 startOffset, int24 endOffset)
        public
        pure
        returns (bool ok, int24 lower, int24 upper)
    {
        return trancheRange(V4PoolMath.getTickAtSqrtPrice(sqrtPriceX96), tickSpacing, startOffset, endOffset);
    }

    /// @dev Rounds toward negative infinity so alignment never widens a band past its bound.
    function _alignTick(int24 tick, int24 spacing) private pure returns (int24) {
        int24 aligned = (tick / spacing) * spacing;
        if (tick < 0 && aligned != tick) aligned -= spacing;
        return aligned;
    }
}
