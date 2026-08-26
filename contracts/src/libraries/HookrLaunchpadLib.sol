// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {V4PoolMath} from "./V4PoolMath.sol";
import {HookrToken} from "../HookrToken.sol";
import {HookrHook} from "../HookrHook.sol";
import {IHookrLaunchHook} from "../interfaces/IHookrLaunchHook.sol";
import {HookrHookRegistry} from "../HookrHookRegistry.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

interface IHookrBlueprintFees {
    function feeSplitOf(uint32 blueprintId) external view returns (uint16 royaltyBps, address royaltyTo);
}

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
///      DELEGATECALL means these run in the launchpad's context. Stateful orchestration is limited
///      to token creation, the authenticated PoolManager unlock path, and calls to the immutable
///      blueprint registry, hook registry, and selected hook. The library does not address or
///      mutate launchpad storage directly.
library HookrLaunchpadLib {
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
        // ARB BUYBACK (v4 candidate): fees accrue a quote-asset reserve; a permissionless trigger
        // buys this pool's token when it trades drawdownBps below its running anchor and burns it.
        uint16 buybackBps; // 0 = block disabled
        uint16 buybackDrawdownBps; // 10..9900
        uint32 buybackCooldownBlocks; // 1..100_000
        uint96 buybackMinSpendWei; // >= hook's MIN_BUYBACK_SPEND_WEI
        uint96 buybackMaxSpendWei; // >= minSpend
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

    // Mirrors of HookrLaunchpad's validation bounds. The launchpad re-exports each of these
    // as a public constant and its regression suite pins the copies together, so a drift here
    // fails the suite rather than a creator.
    uint256 internal constant MAX_TOTAL_FEE_PIPS_MIRROR = 500_000;
    uint16 internal constant MAX_CREATOR_FEE_BPS_MIRROR = 8000;
    uint256 internal constant MAX_FEE_RECIPIENTS_MIRROR = 4;
    uint256 internal constant MAX_LP_TRANCHES_MIRROR = 4;
    int24 internal constant MIN_TRANCHE_OFFSET_MIRROR = 60;
    int24 internal constant MAX_TRANCHE_OFFSET_MIRROR = 200_000;
    uint96 internal constant MIN_POT_BUY_WEI_MIRROR = 0.001 ether;
    uint96 internal constant MIN_BUYBACK_SPEND_WEI_MIRROR = 0.001 ether;

    error BadHookParams();
    error BadFeeSplit();
    error BadLpPlan();
    error BadHookSelection();
    error BadCallback();

    /// @notice Rejection reasons for `instantPlan`, in the order the launchpad checks them.
    uint8 internal constant PLAN_OK = 0;
    uint8 internal constant PLAN_BAD_ETH = 1;
    uint8 internal constant PLAN_BAD_SHARE = 2;
    uint8 internal constant PLAN_BAD_PRICE = 3;

    /// @notice Rejection reasons for `attachPlan`, in the order the launchpad checks them.
    uint8 internal constant ATTACH_PLAN_OK = 0;
    uint8 internal constant ATTACH_BAD_SEED = 1;
    uint8 internal constant ATTACH_BAD_PRICE = 2;

    /// @dev Mirrors of `HookrLaunchpad`'s three unlock actions — the complete set. Both launch
    ///      paths seed their one position through `CB_GRADUATE`; `CB_TRANCHE` mints a token-only
    ///      band; `CB_COLLECT` passes a liquidity delta of exactly zero. There is no fourth, and
    ///      none of these can carry a negative liquidity delta, which is what makes the launchpad's
    ///      liquidity locked by construction rather than by policy.
    uint8 internal constant CB_GRADUATE = 1;
    uint8 internal constant CB_COLLECT = 2;
    uint8 internal constant CB_TRANCHE = 3;

    /// @notice Execute the launchpad's complete PoolManager unlock callback.
    /// @dev Runs by DELEGATECALL. The launchpad remains the callback target, settlement payer,
    ///      and position owner. The launchpad checks PoolManager identity before this call.
    function handleUnlock(IPoolManager pm, bytes calldata data) public returns (bytes memory) {
        uint8 action = abi.decode(data[:32], (uint8));
        if (action == CB_TRANCHE) {
            (, PoolKey memory trancheKey, int24 lower, int24 upper, uint256 amount) =
                abi.decode(data, (uint8, PoolKey, int24, int24, uint256));
            (uint256 tokenOwed, uint256 quoteOwed) = mintBand(pm, trancheKey, lower, upper, amount);
            if (quoteOwed > 0) revert BadLpPlan();
            return abi.encode(tokenOwed);
        }

        (, PoolKey memory key, uint160 sqrtPriceX96, uint256 amount0, uint256 amount1) =
            abi.decode(data, (uint8, PoolKey, uint160, uint256, uint256));
        if (action == CB_GRADUATE) {
            (uint256 owed0, uint256 owed1) = graduateFullRange(pm, key, sqrtPriceX96, amount0, amount1);
            return abi.encode(owed0, owed1);
        }
        if (action == CB_COLLECT) {
            (uint256 owed0, uint256 owed1) = collectPosition(pm, key, amount0, amount1);
            return abi.encode(owed0, owed1);
        }
        revert BadCallback();
    }

    // ------------------------------------------------------------------ pool opening

    event LpTrancheSeeded(
        address indexed token, uint256 indexed index, int24 tickLower, int24 tickUpper, uint256 tokensUsed
    );
    event Graduated(
        address indexed token,
        PoolId indexed poolId,
        uint160 sqrtPriceX96,
        uint256 quoteLiquidity,
        uint256 tokenLiquidity,
        uint256 tokensBurned
    );

    /// @notice `openPool` for paths that place EVERY pulled token into the full-range position
    ///         and configure no bands -- the existing-token attach path. No residue exists, so
    ///         nothing burns and no band loop is encoded at the call site.
    function openPoolSimple(
        IPoolManager pm,
        IHookrLaunchHook hookContract,
        PoolKey memory key,
        bytes memory hookConfig,
        uint160 sqrtPriceX96,
        address token,
        uint256 quoteForPool,
        uint256 tokensForPool
    ) public returns (uint256 quoteUsed, uint256 tokensUsed, PoolId poolId) {
        hookContract.configurePool(key, hookConfig);
        pm.initialize(key, sqrtPriceX96);
        hookContract.syncBaseFee(key);
        bytes memory result = pm.unlock(abi.encode(CB_GRADUATE, key, sqrtPriceX96, quoteForPool, tokensForPool));
        (quoteUsed, tokensUsed) = abi.decode(result, (uint256, uint256));
        poolId = key.toId();
        // Nothing is left over by construction: the caller placed exactly what it committed.
        emit Graduated(token, poolId, sqrtPriceX96, quoteUsed, tokensUsed, 0);
    }

    /// @notice Configure the hook, create the pool, seed the one position it will ever have,
    ///         place the optional token-only bands above spot, burn whatever remains, and emit
    ///         the graduation postcondition.
    /// @dev Runs by DELEGATECALL, so `address(this)` is still the launchpad. That is load-bearing
    ///      three times over: `configurePool` is gated on the launchpad address, `beforeInitialize`
    ///      checks the initializing sender is the launchpad, and `unlock` calls back into the
    ///      LAUNCHPAD's `unlockCallback` — which is where the position is minted, and therefore
    ///      who Uniswap records as its owner. Moving this sequence here changes which contract's
    ///      bytecode holds the instructions and nothing else. Events are emitted here for the
    ///      same reason: DELEGATECALL keeps each log's emitter as the launchpad, so indexers see
    ///      byte-identical topics while the encodes stay out of every caller's inline footprint.
    ///
    ///      This function reads and writes no launchpad storage; the caller keeps every state
    ///      write, hands in the config it built from storage itself, and receives back what it
    ///      must persist. Bands arrive as memory because reading them is the caller's storage
    ///      concern; everything below is pure mechanics over those values.
    /// @notice Buyback-block parameter rules mirrored from HookrHook.configurePool, so a bad
    ///         stack is rejected at launch time with BadHookParams instead of bricking graduation.
    /// @dev Lives here (DELEGATECALL) because the launchpad is at the EIP-170 size edge.
    function validateBuybackParams(
        uint16 buybackBps,
        uint16 drawdownBps,
        uint32 cooldownBlocks,
        uint96 minSpendWei,
        uint96 maxSpendWei
    ) external pure {
        if (buybackBps == 0) {
            if (minSpendWei != 0 || maxSpendWei != 0 || drawdownBps != 0 || cooldownBlocks != 0) {
                revert BadHookParams();
            }
            return;
        }
        if (minSpendWei < 0.001 ether || maxSpendWei < minSpendWei) revert BadHookParams();
        if (drawdownBps < 10 || drawdownBps > 9900) revert BadHookParams();
        if (cooldownBlocks < 1 || cooldownBlocks > 100_000) revert BadHookParams();
    }

    function openPool(
        IPoolManager pm,
        IHookrLaunchHook defaultHook,
        HookrHookRegistry hookRegistry,
        PoolKey memory key,
        HookrHook.PoolConfig memory defaultConfig,
        uint160 sqrtPriceX96,
        address token,
        uint256 quoteForPool,
        uint256 tokensForPool,
        uint256 tokensAvailable,
        LpTranche[] memory bands
    ) public returns (uint256 quoteUsed, uint256 tokensUsed, PoolId poolId) {
        IHookrLaunchHook hookContract = defaultHook;
        (uint32 hookId, IHookrLaunchHook selectedHook, bytes memory hookConfig) = hookRegistry.consumeForPool(token);
        if (hookId == 0) {
            hookConfig = abi.encode(defaultConfig);
        } else {
            hookContract = selectedHook;
            key.hooks = IHooks(address(hookContract));
        }
        // Configure behavior, then create the pool (beforeInitialize enforces this ordering).
        hookContract.configurePool(key, hookConfig);
        pm.initialize(key, sqrtPriceX96);
        hookContract.syncBaseFee(key);
        bytes memory result = pm.unlock(abi.encode(CB_GRADUATE, key, sqrtPriceX96, quoteForPool, tokensForPool));
        (quoteUsed, tokensUsed) = abi.decode(result, (uint256, uint256));
        poolId = key.toId();

        // Whatever the full-range position could not absorb funds the optional token-only
        // bands above spot; anything still unallocated burns exactly as it always has.
        uint256 tokensLeft = tokensAvailable - tokensUsed;
        uint256 tokensBurned;
        if (tokensLeft > 0 && bands.length > 0) {
            (, int24 currentTick,,) = StateLibrary.getSlot0(pm, poolId);
            uint256 seeded;
            for (uint256 i; i < bands.length; ++i) {
                uint256 amount = (tokensLeft * bands[i].bps) / BPS;
                if (amount == 0) continue;

                // Higher token price == lower tick, so the band is placed below spot. Alignment
                // can collapse a thin band, a far-out band can exceed the usable range, and only
                // a band strictly below spot is token-only — `ok` is false for each, and the
                // slice burns instead of reverting the graduation.
                (bool ok, int24 lower, int24 upper) =
                    trancheRange(currentTick, key.tickSpacing, bands[i].startOffset, bands[i].endOffset);
                if (!ok) continue;

                uint256 used = seedBand(pm, key, lower, upper, amount);
                if (used > 0) {
                    seeded += used;
                    emit LpTrancheSeeded(token, i, lower, upper, used);
                }
            }
            tokensBurned = tokensLeft - seeded;
        } else if (tokensLeft > 0) {
            tokensBurned = tokensLeft;
        }
        if (tokensBurned > 0) {
            HookrToken(token).transfer(DEAD, tokensBurned);
        }

        emit Graduated(token, poolId, sqrtPriceX96, quoteUsed, tokensUsed, tokensBurned);
    }

    /// @notice Mint one token-only band over `[lower, upper]`, funded with `amount` of token1.
    /// @dev Pure code motion of the launchpad's `CB_TRANCHE` unlock, linked out for EIP-170.
    function seedBand(IPoolManager pm, PoolKey memory key, int24 lower, int24 upper, uint256 amount)
        public
        returns (uint256 used)
    {
        return abi.decode(pm.unlock(abi.encode(CB_TRANCHE, key, lower, upper, amount)), (uint256));
    }

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @notice Mint the locked full-range position at `sqrtPriceX96`, funded with `amount0` of
    ///         currency0 and `amount1` of currency1, settling BOTH currencies from the caller's
    ///         own balances.
    /// @dev Pure code motion of the launchpad's `CB_GRADUATE` unlock branch, linked out for
    ///      EIP-170 exactly like everything else here. Runs by DELEGATECALL, so the position is
    ///      still minted by — and Uniswap records it as owned by — the launchpad, and settlement
    ///      pulls from the launchpad's own balances.
    function graduateFullRange(
        IPoolManager pm,
        PoolKey memory key,
        uint160 sqrtPriceX96,
        uint256 amount0,
        uint256 amount1
    ) public returns (uint256 oweCurrency0, uint256 oweCurrency1) {
        (int24 tickLower, int24 tickUpper) = usableTickRange(key.tickSpacing);
        uint128 liquidity = liquidityForAmountsInRange(tickLower, tickUpper, sqrtPriceX96, amount0, amount1);

        (BalanceDelta callerDelta,) = pm.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liquidity)), salt: bytes32(0)
            }),
            ""
        );

        oweCurrency0 = callerDelta.amount0() < 0 ? uint256(uint128(-callerDelta.amount0())) : 0;
        oweCurrency1 = callerDelta.amount1() < 0 ? uint256(uint128(-callerDelta.amount1())) : 0;

        if (oweCurrency0 > 0) {
            settleCallerSide(pm, key.currency0, oweCurrency0);
        }
        if (oweCurrency1 > 0) {
            settleCallerSide(pm, key.currency1, oweCurrency1);
        }
    }

    /// @notice Poke one position's accrued fees out of the pool with a zero liquidity delta.
    /// @dev Pure code motion of the launchpad's `CB_COLLECT` unlock branch: currency0 is taken to
    ///      the launchpad (the DELEGATECALL context), currency1 — the base token's fee side — is
    ///      burned straight to 0xdEaD, exactly as every deployed pool has always done.
    ///      `lowerSlot`/`upperSlot` ride in the two amount slots exactly as the callback expects:
    ///      zero for both means the full-range position, otherwise they are
    ///      `uint256(uint24(tick))` bit patterns the callback truncates back to `int24`.
    function collectPosition(IPoolManager pm, PoolKey memory key, uint256 lowerSlot, uint256 upperSlot)
        public
        returns (uint256 token0Owed, uint256 token1Owed)
    {
        int24 tickLower;
        int24 tickUpper;
        if (lowerSlot != 0 || upperSlot != 0) {
            // Collection over a tranche range: the bounds ride in the two amount slots.
            tickLower = int24(uint24(lowerSlot));
            tickUpper = int24(uint24(upperSlot));
        } else {
            (tickLower, tickUpper) = usableTickRange(key.tickSpacing);
        }

        (BalanceDelta callerDelta,) = pm.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 0, salt: bytes32(0)}),
            ""
        );
        token0Owed = callerDelta.amount0() > 0 ? uint256(uint128(callerDelta.amount0())) : 0;
        token1Owed = callerDelta.amount1() > 0 ? uint256(uint128(callerDelta.amount1())) : 0;
        if (token0Owed > 0) {
            pm.take(key.currency0, address(this), token0Owed);
        }
        if (token1Owed > 0) {
            // Burn the token side directly.
            pm.take(key.currency1, DEAD, token1Owed);
        }
    }

    /// @notice Collect the full-range position's accrued fees plus every seeded band's, poking
    ///         each range separately. Bands whose stored plan rounds to zero liquidity, or were
    ///         never seeded, are skipped exactly as `_seedTranches` -- now `openPool` -- skipped
    ///         them, so a dust band can never make an entire market's fee collection revert.
    /// @dev Code motion of the launchpad's collection loop. Runs by DELEGATECALL, so
    ///      `address(this)` is still the launchpad: the position-owner hash and the currency0
    ///      recipient both resolve to it, byte-identical to the original inline loop.
    function collectAllBands(
        IPoolManager pm,
        PoolKey memory key,
        PoolId poolId,
        LpTranche[] memory bands,
        uint160 sqrtPriceX96AtGraduation
    ) public returns (uint256 quoteAmount, uint256 tokenAmount) {
        (quoteAmount, tokenAmount) = collectRange(pm, key, 0, 0);

        // Each tranche is its own position, so its fees have to be poked separately -- collecting
        // only the full-range position would silently leave tranche fees in the pool forever.
        for (uint256 i; i < bands.length; ++i) {
            // Same geometry the seeding applied, against the graduation tick rather than spot.
            (bool ok, int24 lower, int24 upper) = trancheRangeAtSqrtPrice(
                sqrtPriceX96AtGraduation, key.tickSpacing, bands[i].startOffset, bands[i].endOffset
            );
            if (!ok) continue;
            // A valid stored plan can still seed zero liquidity: for example an instant launch
            // that places all supply in the full-range position may leave only rounding dust, and
            // a small tranche bps then rounds to zero. PoolManager rejects a zero-delta poke of a
            // position that was never minted, which used to make this token's *entire* fee
            // collection path revert forever. Read the launchpad-owned position first and skip
            // only truly absent bands; seeded positions are never removable by this contract.
            bytes32 positionId = keccak256(abi.encodePacked(address(this), lower, upper, bytes32(0)));
            if (StateLibrary.getPositionLiquidity(pm, poolId, positionId) == 0) continue;
            (uint256 bandQuote, uint256 bandTokens) =
                collectRange(pm, key, uint256(uint24(lower)), uint256(uint24(upper)));
            quoteAmount += bandQuote;
            tokenAmount += bandTokens;
        }
    }

    error TargetOutOfRange();

    /// @notice The entire curve-sold-out plan: final tranche price, its v4 sqrt price, and how
    ///         many of the remaining tokens the reserve can back at that price (clamped to the
    ///         tokens actually left after the curve).
    function graduatePlan(uint96 basePriceWei, uint256 reserveWei, uint256 tokensAvailable)
        public
        pure
        returns (uint256 pFinal, uint160 sqrtPriceX96, uint256 tokensForPool)
    {
        pFinal = tranchePrice(basePriceWei, TRANCHES - 1);
        // sqrt((1e18 << 192) / pFinal); the caller owns the named bound error on overflow.
        uint256 root = _sqrt((uint256(1e18) << 192) / pFinal);
        if (root > type(uint160).max) revert TargetOutOfRange();
        // casting to 'uint160' is safe: bounds-checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        sqrtPriceX96 = uint160(root);
        tokensForPool = (reserveWei * 1e18) / pFinal;
        if (tokensForPool > tokensAvailable) tokensForPool = tokensAvailable;
    }

    /// @notice Split one fee collection between the anti-snipe withhold, the creator side, and
    ///         the protocol remainder. Pure accounting over values the caller read from state.
    function splitCollectionFees(
        uint256 quoteAmount,
        uint256 guardOwedCumulative,
        uint256 alreadyWithheld,
        uint16 creatorFeeBps
    ) public pure returns (uint256 withheld, uint256 creatorSide) {
        // Fees earned inside the finite guard window are PROTOCOL-ONLY. The cumulative owed less
        // what previous collections took is high-water-marked, so the same wei is never withheld
        // twice and the snipe tax is never rebated to whoever paid it.
        withheld = guardOwedCumulative - alreadyWithheld;
        if (withheld > quoteAmount) withheld = quoteAmount;
        creatorSide = ((quoteAmount - withheld) * creatorFeeBps) / BPS;
    }

    /// @notice Settle a completed exact-input curve buy: pay the buyer their tokens, refund any
    ///         unused quote input, and emit the buy receipt.
    /// @dev Code motion of `_executeBuy`'s payout tail. Runs by DELEGATECALL, so tokens move
    ///      from the launchpad's own balance and the log carries the launchpad as emitter,
    ///      byte-identical topics to the original inline emit.
    function settleCurveBuy(
        address token,
        address buyer,
        address quoteToken,
        uint256 tokensOut,
        uint256 valueWei,
        uint256 ethUsed,
        uint256 fee,
        uint96 reserveWei,
        uint128 soldTokens
    ) public {
        HookrToken(token).transfer(buyer, tokensOut);
        uint256 refund = valueWei - ethUsed - fee;
        if (refund > 0) {
            if (quoteToken == address(0)) {
                (bool ok,) = buyer.call{value: refund}("");
                if (!ok) revert EthTransferFailed();
            } else {
                safeTransfer(quoteToken, buyer, refund);
            }
        }
        emit CurveBuy(token, buyer, ethUsed, tokensOut, reserveWei, soldTokens);
    }

    event CurveBuy(
        address indexed token,
        address indexed buyer,
        uint256 ethIn,
        uint256 tokensOut,
        uint96 reserveWei,
        uint128 soldTokens
    );

    /// @notice Refund an existing-token attach's sub-ppm rounding residue on BOTH sides and emit
    ///         the attach postcondition. The residue is the backer's own deposit, never anyone's
    ///         fee; this is what makes attach honest for tokens nobody else controls.
    function settleAttach(
        address token,
        address backer,
        address quoteToken,
        PoolId poolId,
        uint160 sqrtPriceX96,
        uint256 quoteSeedRaw,
        uint256 quoteUsed,
        uint256 tokenSeedRaw,
        uint256 tokensUsed
    ) public {
        if (quoteSeedRaw > quoteUsed) {
            if (quoteToken == address(0)) {
                (bool ok,) = backer.call{value: quoteSeedRaw - quoteUsed}("");
                if (!ok) revert EthTransferFailed();
            } else {
                safeTransfer(quoteToken, backer, quoteSeedRaw - quoteUsed);
            }
        }
        if (tokenSeedRaw > tokensUsed) {
            safeTransfer(token, backer, tokenSeedRaw - tokensUsed);
        }
        emit MarketAttached(token, backer, poolId, sqrtPriceX96, quoteUsed, tokensUsed);
    }

    event MarketAttached(
        address indexed token,
        address indexed creator,
        PoolId indexed poolId,
        uint160 sqrtPriceX96,
        uint256 quoteSeeded,
        uint256 tokensSeeded
    );

    error EthTransferFailed();

    /// @notice Settle `amount` of `currency` owed by the DELEGATECALL caller to the PoolManager.
    /// @dev Native comes from the caller's attached value; ERC-20s are pulled from the caller's
    ///     own balance. Code motion of the launchpad's `_settleLaunchpadSide`.
    function settleCallerSide(IPoolManager pm, Currency currency, uint256 amount) public {
        if (Currency.unwrap(currency) == address(0)) {
            pm.settle{value: amount}();
            return;
        }
        // The caller settles strictly from its OWN balance -- a plain transfer, never a
        // self-transferFrom (which would need a meaningless self-allowance).
        pm.sync(currency);
        safeTransfer(Currency.unwrap(currency), address(pm), amount);
        pm.settle();
    }

    /// @notice Best-effort-canonical ERC-20 transfer that fails closed on non-standard returns.
    function safeTransferFrom(address token, address from, address to, uint256 amount) public {
        (bool ok, bytes memory result) = token.call(abi.encodeWithSelector(bytes4(0x23b872dd), from, to, amount));
        if (!ok || (result.length != 0 && (result.length != 32 || !abi.decode(result, (bool))))) {
            revert TransferFailed();
        }
    }

    /// @notice Best-effort-canonical ERC-20 transfer that fails closed on non-standard returns.
    function safeTransfer(address token, address to, uint256 amount) public {
        (bool ok, bytes memory result) = token.call(abi.encodeWithSelector(bytes4(0xa9059cbb), to, amount));
        if (!ok || (result.length != 0 && (result.length != 32 || !abi.decode(result, (bool))))) {
            revert TransferFailed();
        }
    }

    error TransferFailed();

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

    /// @notice The entire opening plan of an EXISTING-token attach: the v4 sqrt price implied by
    ///         two funded seed amounts, and every reason to refuse it.
    ///
    /// @dev The price is DERIVED from what is actually being deposited — never typed in. The
    ///      raw pool price is `amount1Raw / amount0Raw`, so
    ///
    ///          sqrtPriceX96 = sqrt(amount1Raw / amount0Raw) * 2^96
    ///                       = sqrt(amount1Raw * 2^192 / amount0Raw)
    ///
    ///      which keeps the property every other launch path has: there is no way to express a
    ///      price that the contract is not simultaneously holding both sides of. Both amounts are
    ///      pulled from the backer in the same transaction, so an unfunded valuation is
    ///      unreachable rather than merely discouraged.
    ///
    ///      Unlike `instantPlan` there is no minimum-price quantization bound: the ratio IS the
    ///      price, exactly, for any decimal pairing of quote and token — the launchpad makes no
    ///      18-decimal assumption anywhere on this path. Degenerate seeds are caught by the same
    ///      usable-range check instantPlan applies: a root outside `(tickLower, tickUpper)` would
    ///      open a full-range position holding only one side, so refusing is the only safe answer.
    ///
    /// @return sqrtPriceX96 The funded opening price as a v4 sqrt price. Zero when unrepresentable.
    /// @return err          `ATTACH_PLAN_OK`, or which bound the inputs broke.
    function attachPlan(uint256 amount0Raw, uint256 amount1Raw, int24 tickSpacing)
        public
        pure
        returns (uint160 sqrtPriceX96, uint8 err)
    {
        if (amount0Raw == 0 || amount1Raw == 0) return (0, ATTACH_BAD_SEED);

        // mulDiv(a, 2^192, d) overflows when d <= a >> 64; past that the implied sqrt price
        // exceeds anything uint160 can represent -- refuse, never panic.
        if (amount0Raw <= (amount1Raw >> 64)) return (0, ATTACH_BAD_PRICE);

        uint256 root = _sqrt(V4PoolMath.mulDiv(amount1Raw, 1 << 192, amount0Raw));
        if (root > type(uint160).max) return (0, ATTACH_BAD_PRICE);
        // casting to 'uint160' is safe: bounds-checked on the line above.
        // forge-lint: disable-next-line(unsafe-typecast)
        sqrtPriceX96 = uint160(root);

        (int24 tickLower, int24 tickUpper) = V4PoolMath.usableTickRange(tickSpacing);
        if (
            sqrtPriceX96 <= V4PoolMath.getSqrtPriceAtTick(tickLower)
                || sqrtPriceX96 >= V4PoolMath.getSqrtPriceAtTick(tickUpper)
        ) {
            return (sqrtPriceX96, ATTACH_BAD_PRICE);
        }
    }

    // ------------------------------------------------------------------ validation (linked out for EIP-170)

    /// @notice `maxFeePips == 0` is the builder's "surge block not stacked" encoding, not a real
    ///         zero ceiling. Every read of the field goes through here.
    function normalizedMaxFeePips(HookParams memory p) public pure returns (uint24) {
        return p.maxFeePips == 0 ? p.baseFeePips : p.maxFeePips;
    }

    /// @notice Record a registered hook selection after the launchpad creates the token.
    /// @dev The selected hook owns `config`. Built-in block settings and blueprints are refused
    ///      because they would otherwise appear in launch calldata but have no effect.
    function selectRegisteredHook(
        HookrHookRegistry registry,
        address creator,
        address token,
        uint32 hookId,
        uint32 blueprintId,
        HookParams calldata p
    ) public {
        if (hookId == 0) return;
        if (blueprintId != 0 || _hasHookParams(p)) revert BadHookSelection();
        registry.bindStagedHook(creator, token, hookId);
    }

    function _hasHookParams(HookParams calldata p) private pure returns (bool) {
        return p.guardBlocks != 0 || p.maxBuyBps != 0 || p.snipeTaxPips != 0 || p.baseFeePips != 0 || p.maxFeePips != 0
            || p.surgeSens != 0 || p.burnBps != 0 || p.burnTriggerWei != 0 || p.lpBps != 0 || p.potBps != 0
            || p.potEveryNBuys != 0 || p.potMinBuyWei != 0 || p.buybackBps != 0 || p.buybackDrawdownBps != 0
            || p.buybackCooldownBlocks != 0 || p.buybackMinSpendWei != 0 || p.buybackMaxSpendWei != 0;
    }

    /// @notice The exact checks `HookrHook.configurePool` will apply, run at launch time so a
    ///         rejected stack reverts the launch instead of bricking graduation. Returns the
    ///         NORMALIZED max fee the config builder must use.
    function validateHookParams(HookParams memory p) public pure returns (uint24 maxFeePips) {
        maxFeePips = normalizedMaxFeePips(p);
        if (p.baseFeePips > MAX_TOTAL_FEE_PIPS_MIRROR || maxFeePips > MAX_TOTAL_FEE_PIPS_MIRROR) {
            revert BadHookParams();
        }
        if (maxFeePips < p.baseFeePips) revert BadHookParams();
        if (uint256(p.baseFeePips) + p.snipeTaxPips > MAX_TOTAL_FEE_PIPS_MIRROR) revert BadHookParams();
        if (uint256(p.burnBps) + p.lpBps + p.potBps + p.buybackBps > 1000) revert BadHookParams();
        if (p.burnTriggerWei != 0) revert BadHookParams();
        // Mirror the hook's own configurePool rules so launch-time rejection never becomes a
        // graduation-time brick. A disabled block must carry all-zero parameters.
        if (p.buybackBps == 0) {
            if (
                p.buybackMinSpendWei != 0 || p.buybackMaxSpendWei != 0 || p.buybackDrawdownBps != 0
                    || p.buybackCooldownBlocks != 0
            ) revert BadHookParams();
        } else {
            if (p.buybackMinSpendWei < MIN_BUYBACK_SPEND_WEI_MIRROR || p.buybackMaxSpendWei < p.buybackMinSpendWei) {
                revert BadHookParams();
            }
            if (p.buybackDrawdownBps < 10 || p.buybackDrawdownBps > 9900) revert BadHookParams();
            if (p.buybackCooldownBlocks < 1 || p.buybackCooldownBlocks > 100_000) revert BadHookParams();
        }
        if (p.potBps > 0 && (p.potEveryNBuys < 2 || p.potEveryNBuys > 100_000)) revert BadHookParams();
        if (p.surgeSens > 10) revert BadHookParams();
        if (p.guardBlocks > 100_000) revert BadHookParams();
        if (p.maxBuyBps > BPS) revert BadHookParams();
        if (p.potBps > 0 && p.potMinBuyWei < MIN_POT_BUY_WEI_MIRROR) revert BadHookParams();
    }

    /// @notice The creator-fee and fee-recipient checks every market path shares.
    function validateFeeSplit(uint16 creatorFeeBps, FeeRecipient[] calldata recipients) public pure {
        if (creatorFeeBps > MAX_CREATOR_FEE_BPS_MIRROR) revert BadFeeSplit();

        uint256 n = recipients.length;
        if (n > MAX_FEE_RECIPIENTS_MIRROR) revert BadFeeSplit();
        if (n > 0) {
            uint256 sum;
            for (uint256 i; i < n; ++i) {
                FeeRecipient calldata r = recipients[i];
                if (r.to == address(0) || r.bps == 0) revert BadFeeSplit();
                // Duplicates would still pay out correctly, but they make the split unreadable
                // on chain and hide a mistaken split from whoever reviews the launch.
                for (uint256 j; j < i; ++j) {
                    if (recipients[j].to == r.to) revert BadFeeSplit();
                }
                sum += r.bps;
            }
            // Exact, not "at most": anything else would silently strand fees in the contract.
            if (sum != BPS) revert BadFeeSplit();
        }
    }

    function validateDistribution(
        uint16 creatorFeeBps,
        FeeRecipient[] calldata recipients,
        LpTranche[] calldata tranches
    ) public pure {
        validateFeeSplit(creatorFeeBps, recipients);
        validateLpPlan(tranches);
    }

    /// @notice Rejects an LP-band plan the collection path could not honour exactly.
    function validateLpPlan(LpTranche[] calldata tranches) public pure {
        uint256 t = tranches.length;
        if (t > MAX_LP_TRANCHES_MIRROR) revert BadLpPlan();
        if (t == 0) return;

        uint256 sum;
        int24 previousUpper = 0;
        for (uint256 i; i < t; ++i) {
            LpTranche calldata b = tranches[i];
            if (b.bps == 0) revert BadLpPlan();
            // Strictly below the graduation tick keeps every band token-only: a band
            // straddling spot would need ETH the raise has already committed elsewhere.
            if (b.startOffset < MIN_TRANCHE_OFFSET_MIRROR) revert BadLpPlan();
            if (b.endOffset <= b.startOffset) revert BadLpPlan();
            // Bounded from above as well as below. Unbounded, a single band could be placed
            // where its liquidity no longer fits uint128 — which reverted inside the unlock
            // and so bricked graduation permanently instead of being skipped. `bandLiquidity`
            // is what makes that unreachable now; this is what stops a creator wandering into
            // the skip and silently burning the ladder they thought they had configured.
            if (b.endOffset > MAX_TRANCHE_OFFSET_MIRROR) revert BadLpPlan();
            // Ascending in price and non-overlapping, so the bands read as a ladder and a
            // mistake cannot quietly stack two positions on the same range.
            if (i > 0 && b.startOffset < previousUpper) revert BadLpPlan();
            previousUpper = b.endOffset;
            sum += b.bps;
        }
        // At most the whole leftover: any unallocated remainder still burns.
        if (sum > BPS) revert BadLpPlan();
    }

    /// @notice Build the exact per-pool hook config for these params. Royalty lookup is the
    ///         CALLER's job (it reads launchpad storage); everything else happens here so the
    ///         struct build stays out of the launchpad's EIP-170 budget.
    /// @notice The exact `PoolConfig` a CUSTOM-stack launch (blueprintId == 0) would hand the
    ///         hook for these params, so the UI and the regression suite can check up front that
    ///         anything `validateHookParams` accepts also configures cleanly.
    function previewPoolConfig(HookParams calldata p, uint256 pFinal, uint256 capTokens)
        external
        view
        returns (HookrHook.PoolConfig memory cfg)
    {
        return poolConfig(p, 0, address(0), pFinal, capTokens);
    }

    function poolConfig(HookParams memory p, uint16 royaltyBps, address royaltyTo, uint256 pFinal, uint256 capTokens)
        public
        view
        returns (HookrHook.PoolConfig memory cfg)
    {
        // The 1e18 division is the 18-decimal token assumption the two native launch paths make.
        uint256 maxBuyWei = 0;
        if (p.maxBuyBps != 0) {
            maxBuyWei = (((capTokens * p.maxBuyBps) / BPS) * pFinal) / 1e18;
            if (maxBuyWei > type(uint96).max) maxBuyWei = type(uint96).max;
        }
        return poolConfigWithGuardCap(p, royaltyBps, royaltyTo, uint96(maxBuyWei));
    }

    function poolConfigForLaunch(
        HookParams memory p,
        IHookrBlueprintFees blueprints,
        uint32 blueprintId,
        uint256 pFinal,
        uint256 capTokens
    ) public view returns (HookrHook.PoolConfig memory cfg) {
        (uint16 royaltyBps, address royaltyTo) = _royalty(blueprints, blueprintId);
        return poolConfig(p, royaltyBps, royaltyTo, pFinal, capTokens);
    }

    function poolConfigForGuardCap(
        HookParams memory p,
        IHookrBlueprintFees blueprints,
        uint32 blueprintId,
        uint96 maxBuyWei
    ) public view returns (HookrHook.PoolConfig memory cfg) {
        (uint16 royaltyBps, address royaltyTo) = _royalty(blueprints, blueprintId);
        return poolConfigWithGuardCap(p, royaltyBps, royaltyTo, maxBuyWei);
    }

    function poolConfigWithGuardCap(HookParams memory p, uint16 royaltyBps, address royaltyTo, uint96 maxBuyWei)
        public
        view
        returns (HookrHook.PoolConfig memory cfg)
    {
        cfg = HookrHook.PoolConfig({
            initialized: false, // hook sets this
            guardEndBlock: p.guardBlocks == 0 ? 0 : uint40(block.number + p.guardBlocks),
            baseFeePips: p.baseFeePips,
            // The builder emits maxFeePips == 0 whenever no surge block is stacked. The hook
            // reads that literally and rejects maxFee < baseFee, so it must be normalized HERE,
            // to the exact value validateHookParams already checked, or graduation bricks.
            maxFeePips: normalizedMaxFeePips(p),
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
            buybackBps: p.buybackBps,
            buybackDrawdownBps: p.buybackDrawdownBps,
            buybackCooldownBlocks: p.buybackCooldownBlocks,
            buybackMinSpendWei: p.buybackMinSpendWei,
            buybackMaxSpendWei: p.buybackMaxSpendWei,
            royaltyTo: royaltyTo,
            token: address(0) // hook sets this
        });
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

    function _royalty(IHookrBlueprintFees blueprints, uint32 blueprintId)
        private
        view
        returns (uint16 royaltyBps, address royaltyTo)
    {
        if (blueprintId != 0) return blueprints.feeSplitOf(blueprintId);
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
