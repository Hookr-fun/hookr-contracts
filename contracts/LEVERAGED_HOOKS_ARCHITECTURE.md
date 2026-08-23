# Leveraged Hooks — contract architecture

Verified against the vendored core before writing. Three facts changed the design and are load-bearing throughout:

- **`HookrLaunchpad` is at 24,280 / 24,576 bytes with 296 bytes of margin**, and already has a 12.5 KB library linked out. A credit engine cannot live in one contract here. Splitting is not defensive, it is arithmetic.
- **`HookrLaunchpadLib`'s convention is stateless-by-value** (`"This function reads and writes no launchpad storage; the caller keeps every state write"` — `HookrLaunchpadLib.sol:90`). I follow it: libraries compute and touch PoolManager under DELEGATECALL, they return effect structs, the market performs every SSTORE. That preserves the repo's stance that a delegate frame carries no authority over storage, and it gives property tests a pure seam.
- **`PoolManager.burn(from,…)` → `_burnFrom` requires `from == msg.sender` or operator approval** (`ERC6909Claims.sol:13-22`). Therefore all ERC-6909 custody must sit in **one** contract, and that contract must be the one that opens `unlock`. This forces per-pool custody into `LeverageMarket` and rules out spreading claims across hook/vault/manager.

---

## 0. The three v4 constraints that shape everything

**(a) A hook that calls `poolManager.swap` on its own pool is not hooked.** `Hooks.beforeSwap` line 253 and `Hooks.afterSwap` line 293 both begin `if (msg.sender == address(self)) return …`. If the credit engine and the hook were one contract, every leverage open and every liquidation would silently skip its own `beforeSwap`/`afterSwap` — no oracle observation written for the largest price moves in the system, and the cached dynamic fee applied instead of the override.

→ **The hook and the market are different addresses.** The market calls `poolManager.swap`, so `sender == address(market)` reaches the hook authentically and the oracle observes leverage-driven moves like any other. `sender` is not spoofable: it is the true `msg.sender` to `poolManager.swap`, unlike `hookData`, which the router chooses (`HookrSwapRouter.sol:182`) and which `HookrHook` already documents as unable to authenticate anyone.

**(b) Persistent debt cannot be a v4 balance.** Every delta nets to zero at unlock close or `CurrencyNotSettled` fires. So the ledger is the module's, and the *value* backing it is held as ERC-6909 claims — the exact convention `HookrHook` already uses (`nativeClaimBalance()` == sum of obligations). Extended: this market holds **native claims** (quote reserve, pull-payments) and **token claims** (trader collateral, fee dust), and the invariant becomes two-sided.

**(c) `unlock` cannot nest.** The market opens `unlock` for every state-changing flow; the hook never calls `unlock` at all (it only runs inside someone else's). No `AlreadyUnlocked` path exists.

---

## 1. File set

Nine files. Each one justified by a limit, a callback boundary, or a custody boundary — not by taste.

| # | File | Responsibility (one line) |
|---|---|---|
| 1 | `src/LeverageHook.sol` | Mined-address v4 hook: pool registry, observation ring, dynamic LP fee, exclusive-liquidity gate, protected-state evaluation. Holds no value. |
| 2 | `src/LeverageMarket.sol` | Per-pool custody + ledger + ERC-20 LP share + `unlockCallback` dispatch; the only holder of ERC-6909 claims and the v4 position. |
| 3 | `src/LeverageFactory.sol` | Deploys token + market, registers the pool with the hook, initializes it, seeds the first liquidity, mints founding shares. |
| 4 | `src/HookrCreditBond.sol` | Shared $HOOKR bond registry read as one term of every market's credit capacity; pays bonders a share of origination fees. |
| 5 | `src/libraries/LeverageMath.sol` | `internal pure` — prices from sqrt, interest index, HF, liquidation price, rate curve, capacity terms, share exchange rate. Inlines. |
| 6 | `src/libraries/LeverageOracleLib.sol` | `internal` — observation ring write, bounded backward walk, TWAP, quality score. Inlines into the hook. |
| 7 | `src/libraries/LeveragePositionLib.sol` | `public`, linked — the OPEN / CLOSE / REPAY / LIQUIDATE unlock bodies, swap-and-reconcile, bad-debt waterfall. |
| 8 | `src/libraries/LeverageVaultLib.sol` | `public`, linked — NAV, deposit / redeem / queue service / in-kind strip / harvest unlock bodies. |
| 9 | `src/interfaces/ILeverage.sol` | Shared structs, errors, and the `ILeverageHook` / `ILeverageMarket` interfaces that break the hook↔market import cycle. |

**Why not fewer.**
- 1 and 2 must split: constraint (a).
- 2 and {7, 8} must split: 24 KB. `LeverageMarket` alone is storage + ERC-20 (~700 B) + entrypoint validation + dispatch + views. The flow bodies go out.
- 7 and 8 split by *what they can corrupt*: 7 touches the credit book and can create bad debt; 8 touches the share supply and can mint. Merging them means one linked-library address whose compromise is total. Split, and open/close/liquidate stay merged because they share the swap-and-reconcile helper — splitting them would duplicate the most safety-critical routine in the system.
- 3 exists because `HookrLaunchpad.setHook` is one-shot (`HookAlreadySet`) and every `PoolKey` it builds hardcodes `IHooks(address(hook))`. There is no per-launch hook parameter. A leverage pool needs its own opener.
- 4 is shared, not per-market: $HOOKR is a protocol-level asset, and per-market copies of ERC-20 custody logic is how you get eleven bugs instead of one.
- 5 and 6 are `internal` so they cost bytecode where they inline, not a link step — matching `V4PoolMath` (all `internal`) versus `HookrLaunchpadLib` (`public`, linked).

**Contingency, stated up front.** If `LeverageMarket` still exceeds 24,576 B after 7 and 8 are extracted, move every non-essential view to a standalone `src/LeverageLens.sol` with no storage and no privileges, reading the market's public getters. Do *not* solve it by shrinking the invariant checks.

**Explicitly not created:** no second launchpad, no router. `HookrSwapRouter._validate` hard-pins `address(key.hooks) != address(hook)` against its constructor immutable, so it will reject this pool; spot swappers use `PoolSwapTest`-shaped generic routing or a later `HookrSwapRouterV2` generalized over hooks. That is a UI problem, not a protocol problem, and pretending otherwise would add a tenth file for nothing.

---

## 2. Per-file specification

### 2.1 `LeverageHook.sol`

**Flags.** `beforeInitialize | afterInitialize | beforeAddLiquidity | beforeRemoveLiquidity | beforeSwap | afterSwap`

```solidity
uint160 public constant REQUIRED_FLAGS =
    uint160((1 << 13) | (1 << 12) | (1 << 11) | (1 << 9) | (1 << 7) | (1 << 6)); // 0x3AC0 == 15040
```

**No `*_RETURNS_DELTA` bits.** This is deliberate and it deletes a whole bug class. `HookrHook` needs them for its input-side cuts, which is why it must force `sqrtPriceLimitX96 == MIN_SQRT_PRICE_LIMIT` and reconcile `expectedPoolIn` in `afterSwap` or revert `PartialFillUnsupportedWithInputCuts()`. This hook takes no swap-time cut — market revenue is origination fee, interest, close fee, liquidation penalty, and the LP fee the market-owned position already earns through v4. So ordinary swappers get an unmodified v4 pool and `Hooks.isValidHookAddress`'s returns-delta dependency rules are trivially satisfied.

`afterInitialize` is worth its bit: it pushes the initial dynamic LP fee (a dynamic-fee pool initializes at lpFee 0 via `LPFeeLibrary.getInitialLPFee`) and seeds observation[0] at the true init tick and timestamp, in the same transaction. No separate `syncBaseFee` call, no window where the pool is live with a zero fee and an empty ring.

`beforeRemoveLiquidity` is set even though nobody but the market can have liquidity to remove. It costs one bit and makes the exclusive-liquidity invariant enforced on both sides rather than inferred from the add-side gate — `beforeAddLiquidity`'s `sender` is the original `msg.sender` to `modifyLiquidity`, and if a future periphery contract ever fronts an add, a one-sided gate becomes an extraction path.

**Storage**

```solidity
struct PoolCfg {
    bool     registered;
    address  market;              // the only address that may hold liquidity here
    address  token;               // currency1
    uint24   baseFeePips;
    uint24   maxFeePips;          // == baseFeePips disables surge
    uint16   surgeSens;           // 1..10, same shape as HookrHook.cfg.surgeSens
    uint24   utilFeePips;         // added at uMax, scaled linearly from uKink
    uint32   twapShortSec;        // 900
    uint32   twapLongSec;         // 7200
    uint32   minObsSpacingSec;    // 45  -> 256 slots ~= 3.2h of history
    uint32   maxStalenessSec;     // 3600
    uint32   protectCooldownSec;  // 300
    int24    maxDevTicks;         // 500  (~5%) spot vs short TWAP
    int24    maxJumpTicks;        // 1000 (~10.5%) single swap
    int24    maxVolTicks;         // EWMA ceiling
    int24    volRefTicks;         // EWMA reference for the quality score
    uint128  minLiquidity;        // depth-collapse floor
    uint16   minQualityBps;
}
mapping(PoolId => PoolCfg) public poolCfg;

uint256 internal constant CARDINALITY = 256;
struct Observation { uint32 blockTimestamp; int56 tickCumulative; uint64 volEwmaX32; } // one slot
mapping(PoolId => Observation[256]) internal obs;

struct OracleMeta {
    uint16 index;          // ring head
    uint16 filled;         // observations written, saturating at 256
    int24  lastTick;       // tick as of the last afterSwap
    uint32 lastObsAt;      // timestamp of obs[index]
    uint40 protectedUntil; // hysteresis floor
    uint16 utilBps;        // PUSHED by the market; the hook never calls the market
}
mapping(PoolId => OracleMeta) public oracleMeta;

IPoolManager public immutable poolManager;
address      public immutable factory;
```

**External surface**

```solidity
function registerPool(PoolKey calldata key, PoolCfg calldata c) external;      // onlyFactory, one-shot
function updateRisk(PoolId id, uint16 utilBps) external;                       // onlyMarket(id)

function riskState(PoolId id) external view returns (RiskState memory);
function consult(PoolId id, uint32 window) external view returns (int24 meanTick, bool ok);
function isProtected(PoolId id) external view returns (bool, uint8 reasonMask);
function contractName() external pure returns (string memory);                 // "LeverageHook"
function contractVersion() external pure returns (string memory);
uint160 public constant REQUIRED_FLAGS;

// IHooks — implemented
function beforeInitialize(address sender, PoolKey calldata key, uint160) external view returns (bytes4);
function afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick) external returns (bytes4);
function beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata) external view returns (bytes4);
function beforeRemoveLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata) external view returns (bytes4);
function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata p, bytes calldata) external returns (bytes4, BeforeSwapDelta, uint24);
function afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata) external returns (bytes4, int128);
// the remaining four IHooks methods are `external pure` and revert HookNotCalled(), as in HookrHook
```

```solidity
struct RiskState {
    uint160 sqrtPriceX96;
    int24   tick;
    uint256 spotPq;          // quote wei per 1e18 token
    uint256 twapShortPq;
    uint256 twapLongPq;
    uint128 liquidity;
    uint16  qualityBps;      // min(oracle, vol, util)
    bool    protected_;
    uint8   reasonMask;
    uint32  lastObsAt;
}
```

**Errors / modifiers**

```solidity
error NotPoolManager(); error NotFactory(); error NotMarket();
error AlreadyRegistered(); error NotRegistered(); error BadConfig();
error ExclusiveLiquidity();   // any non-market modifyLiquidity
error HookNotCalled();
modifier onlyPoolManager();
```

**Events:** `PoolRegistered`, `ObservationWritten`, `ProtectedEntered(PoolId,uint8 reasonMask)`, `ProtectedCleared`, `RiskPushed(PoolId,uint16 utilBps)`.

**`beforeSwap` body — the whole thing**

```
1. cfg = poolCfg[id]; if (!cfg.registered) revert NotRegistered();
2. (, int24 tick,,) = poolManager.getSlot0(id);
3. LeverageOracleLib.write(obs[id], oracleMeta[id], tick, uint32(block.timestamp), cfg.minObsSpacingSec);
      // no-op unless minObsSpacingSec has elapsed. Most swaps write nothing.
      // the accumulator adds tick * dt using the tick that PREVAILED over the interval,
      // i.e. the pre-swap tick — which is exactly what v3's observation.write does.
4. feePips = cfg.baseFeePips
         + (sender == cfg.market ? 0 : surge(id, cfg, p))
         + utilSurcharge(cfg, meta.utilBps);
   clamp to MAX_TOTAL_FEE_PIPS (500_000, repo-local)
5. return (selector, ZERO_DELTA, uint24(feePips) | OVERRIDE_FEE_FLAG);
```

`surge` is `HookrHook._surgeComponent` verbatim — the virtual-reserve expression at `HookrHook.sol:393-413` is the only depth signal in this codebase and it is already reviewed:

```solidity
reserveIn = zeroForOne ? (uint256(liquidity) << 96) / sqrtPriceX96      // quote side
                       : (uint256(liquidity) * sqrtPriceX96) >> 96;    // token side
```

**Why `sender == market ⇒ no surge, and the abuse it opens, and how it is closed.** Liquidations must not pay a surge fee in the exact moment recovery matters. That waiver would otherwise let a trader wrap a spot buy as a 1.0001× "leverage open" to dodge the surge. It is closed in the market, not the hook: `cfg.minCreditBps` (default 2000) requires every open to borrow ≥20% of notional, so a fee-dodging "open" is a real interest-bearing loan, plus `originationBps` on full notional. One rule in the hook, one rule in the market, no `hookData` trust anywhere.

**`afterSwap` body**

```
1. (, int24 tickAfter,,) = poolManager.getSlot0(id);
2. jump = tickAfter - meta.lastTick;
3. meta.volEwmaX32 = ewma(meta.volEwmaX32, abs(jump), alpha)
4. reasons = 0
   if (abs(jump) > cfg.maxJumpTicks)                      reasons |= JUMP
   (int24 twapShortTick, bool ok) = boundedWalk(id, cfg.twapShortSec, 8)
   if (!ok)                                               reasons |= ORACLE_THIN
   else if (abs(tickAfter - twapShortTick) > cfg.maxDevTicks) reasons |= DEVIATION
   if (volEwmaTicks > cfg.maxVolTicks)                    reasons |= VOLATILITY
   if (poolManager.getLiquidity(id) < cfg.minLiquidity)   reasons |= DEPTH
5. if (reasons != 0) meta.protectedUntil = uint40(block.timestamp + cfg.protectCooldownSec);
6. meta.lastTick = tickAfter;
7. return (IHooks.afterSwap.selector, int128(0));
```

`boundedWalk` steps back at most 8 ring slots and returns `ok=false` rather than reverting if the window is not covered — the launchpad's own lesson that a revert on a path that must not fail is worse than a degraded answer (`bandLiquidity` returns 0 = "skip", `mintBand` never reverts on an unusable band). Failing to `ok=false` degrades `qualityBps`, which tightens credit; it never bricks a swap.

Returndata note: with `AFTER_SWAP_RETURNS_DELTA` unset, `Hooks.callHookWithReturnDelta` short-circuits at `if (!parseReturn) return 0;` **before** the 64-byte length check (`Hooks.sol:163-167`). Only `callHook`'s `result.length >= 32 && selector match` applies. Returning `(selector, int128(0))` is correct and the zero is discarded by core.

**`beforeAddLiquidity` / `beforeRemoveLiquidity`**

```solidity
if (sender != poolCfg[key.toId()].market) revert ExclusiveLiquidity();
```

**This is the single most consequential decision in the design and it is not optional.** The credit cap is the minimum of terms including *executable liquidation depth*, computed from `getLiquidity(id)`. If outside LPs could add bare v4 positions, they would earn fees while carrying none of the credit risk, they would inflate the depth number the credit engine trusts, and they could withdraw that depth in the block before a liquidation. `HookrHook` makes exactly this argument for its guard window (`HookrHook.sol:577-586`: an outside position while an accrual ledger runs "would send part of that fee to the outside position while the ledger still records 100%, leaving a phantom debt"). Here the ledger runs forever, so the exclusion is permanent. The payoff: the market's position is full-range, so **in-range liquidity == all liquidity**, and `getLiquidity` is an honest, stable depth number rather than a lower bound of unknown tightness.

### 2.2 `LeverageMarket.sol`

One per pool. Holds everything of value. Is the ERC-20 LP share (per-pool market ⇒ one share class ⇒ folding the token in saves a contract *and* a trust edge, and puts `totalSupply` in the same storage as NAV so the exchange rate cannot desync).

**Immutables**

```solidity
IPoolManager     public immutable poolManager;
ILeverageHook    public immutable hook;
IHookrCreditBond public immutable bond;
address          public immutable token;      // currency1
address          public immutable factory;
PoolId           public immutable poolId;
int24 internal constant TICK_LOWER = -887220; // V4PoolMath.usableTickRange(60)
int24 internal constant TICK_UPPER =  887220;
uint24 internal constant DYNAMIC_FEE_FLAG = 0x800000;
int24  internal constant TICK_SPACING = 60;
uint160 internal constant MIN_SQRT_PRICE_LIMIT = 4295128740;
uint160 internal constant MAX_SQRT_PRICE_LIMIT = 1461446703485210103287273052203988822378723970341;
uint256 internal constant RAY = 1e27; uint256 internal constant WAD = 1e18; uint256 internal constant BPS = 1e4;
uint256 internal constant NATIVE_ID = 0;      // Currency.wrap(address(0)).toId()
uint256 internal immutable TOKEN_ID;          // Currency.wrap(token).toId()
uint256 internal constant DEAD_SHARES = 1e3;
```

The `PoolKey` is rebuilt on demand from `(token, hook)` plus the constants — never stored, exactly as `HookrLaunchpad` rebuilds it identically in three places.

**Risk config** — set once by the factory, then immutable. No owner, no setter, matching `HookrHook.configurePool`'s one-shot `AlreadyConfigured` stance.

```solidity
struct RiskConfig {
    // solvency geometry
    uint16 maxLtvBps;           // 6000  -> 2.5x max
    uint16 liqThresholdBps;     // 7500
    uint16 openBufferBps;       // 1500  -> must open at HF >= 1.15
    // the liquidation buffer, itemised (see §3.3)
    uint16 liqBonusBps;         // 200   liquidator, relative
    uint96 maxLiqBonusWei;      //       liquidator, absolute
    uint16 liqPenaltyBps;       // 300   -> insurance
    uint16 maxLiqSlippageBps;   // 500
    uint16 interestLagBps;      // 200
    uint16 oracleLagBps;        // 300
    uint16 closeFactorBps;      // 5000
    uint16 fullLiqHfBps;        // 9500  below this HF, close factor = 100%
    // revenue
    uint16 originationBps;      // 30
    uint16 closeFeeBps;         // 10
    uint16 reserveFactorBps;    // 1000  of interest -> insurance
    uint16 bondFeeBps;          // 2000  of origination -> HookrCreditBond
    uint16 minCreditBps;        // 2000  minimum borrow fraction of notional
    uint96 minEquityWei;
    // rate curve, stored per-second to keep division out of the hot path
    uint16 uKinkBps; uint16 uMaxBps;
    uint96 baseRatePerSecRay; uint96 slope1PerSecRay; uint96 slope2PerSecRay;
    // capacity
    uint16 maxBookToDepthBps;   // 2500
    uint96 maxBookQuoteWei;
    uint96 maxNewCreditPerBlockWei;
    uint96 creditPerBondedWad;  // governance parameter, NOT an oracle
    uint16 minQualityBps;
    // redemption
    uint16 minReserveRatioBps;  // 2000  freeQuote floor as a fraction of totalDebt
    uint16 exitFeeMinBps;       // 5
    uint16 exitFeeMaxBps;       // 300
    uint96 maxRedeemPerBlockWei;
    uint32 minHoldBlocks;       // 5
}
RiskConfig public cfg;
```

**Storage**

```solidity
// --- credit book
uint128 public borrowIndexRay;         // starts 1e27
uint40  public lastAccrualAt;
uint128 public totalDebtScaled;
uint128 public totalCollateralTokens;
uint128 public badDebtQuote;           // lifetime realised
uint128 public insuranceQuote;

struct Position {                      // 2 slots
    address owner;      uint96 debtScaled;
    uint128 collateral; uint40 openedAt; uint40 lastTouchedAt;
}
mapping(uint256 => Position) public positions;
uint256 public nextPositionId;         // starts at 1

// --- ERC-6909 custody, internally booked (never read balanceOf for accounting)
uint128 public quoteClaimsBooked;      // native claims this market owns
uint128 public tokenClaimsBooked;      // token claims this market owns
uint128 public tokenTreasury;          // market-owned tokens (fee dust) — an ASSET
mapping(address => uint256) public claimableQuote;
mapping(address => uint256) public claimableToken;
uint128 public claimableQuoteTotal;
uint128 public claimableTokenTotal;

// --- ERC-20 shares
string  public name; string public symbol; uint8 public constant decimals = 18;
uint256 public totalSupply;
mapping(address => uint256) public balanceOf;
mapping(address => mapping(address => uint256)) public allowance;
mapping(address => uint40) public lastMintBlock;

// --- redemption queue, denominated in SHARES (see §6)
struct Ticket { address owner; uint128 sharesEscrowed; uint40 createdAt; }
mapping(uint256 => Ticket) public tickets;
uint256 public queueHead; uint256 public queueTail;
uint128 public sharesEscrowedTotal;    // held at balanceOf[address(this)], still in totalSupply

// --- receivable strips (the in-kind exit)
uint128 public stripLiabilityQuote;
uint256 public totalStripShares;
uint256 public stripCashPerShareWad;
mapping(address => uint256) public stripShares;
mapping(address => uint256) public stripSnapshotWad;

// --- per-block budgets (per-block, never per-swap — HookrHook.sol:281-289)
uint40 public creditBlock; uint96 public creditOpenedInBlock;
uint40 public redeemBlock; uint96 public redeemedInBlock;

uint8 internal unlockDepth;            // reentrancy
```

**External surface**

```solidity
// --- trader
function open(OpenParams calldata p) external payable returns (uint256 positionId);
function increase(uint256 id, uint128 addEquityWei, uint128 addCreditWei, uint128 minTokensOut, uint256 deadline) external payable;
function reduce(uint256 id, uint128 collateralToSell, uint128 minQuoteOut, uint256 deadline) external;
function close(uint256 id, uint128 minQuoteOut, uint256 deadline) external;
function repay(uint256 id) external payable;                       // allowed while protected
function addCollateral(uint256 id, uint128 amount) external;       // allowed while protected
function withdrawCollateral(uint256 id, uint128 amount) external;  // BLOCKED while protected
function liquidate(uint256 id, uint128 collateralToSeize, uint128 minQuoteOut) external;

// --- LP
function deposit(uint256 minShares) external payable returns (uint256 shares);
function requestRedeem(uint256 shares, uint256 minQuoteNow) external returns (uint256 paidNow, uint256 ticketId);
function cancelTicket(uint256 ticketId) external;
function serviceQueue(uint256 maxTickets) external returns (uint256 served);
function redeemInKind(uint256 shares) external returns (uint256 quoteOut, uint256 tokenOut, uint256 stripIssued);
function claimStrip() external returns (uint256 amount);
function harvest() external;                                        // poke fees, compound what pairs

// --- pull payments (the only path that moves real value out)
function claim(address payable to) external returns (uint256 quote, uint256 tokens);

// --- views
function debtOf(uint256 id) public view returns (uint256);
function healthFactor(uint256 id) external view returns (uint256 hfWad);
function liquidationPrice(uint256 id) external view returns (uint256 pqWei);
function liquidationTick(uint256 id) external view returns (int24);   // view-only; binary search
function nav() public view returns (uint256 navWei, NavParts memory parts);
function sharePriceWad() external view returns (uint256);
function utilisationBps() public view returns (uint16);
function borrowRatePerSecRay() public view returns (uint256);
function creditCapacity() public view returns (CapacityTerms memory t, uint256 availableWei);
function instantRedeemAllowance() public view returns (uint256);
function exitFeeBps() public view returns (uint16);
function maxDepositable() external view returns (uint256);
function totalDebt() public view returns (uint256);
function positionValue() public view returns (uint256 quoteLeg, uint256 tokenLeg, uint256 fees0, uint256 fees1);
function contractName() external pure returns (string memory);  // "LeverageMarket"
function contractVersion() external pure returns (string memory);

// --- ERC-20: transfer, transferFrom, approve (no permit in v1)
// --- v4
function unlockCallback(bytes calldata data) external returns (bytes memory);   // onlyPoolManager
```

```solidity
struct OpenParams { uint128 equityWei; uint128 creditWei; uint128 minTokensOut; uint16 maxLtvBps; uint256 deadline; }
struct NavParts {
    uint256 freeQuote; uint256 positionQuote; uint256 tokenTreasuryQuote;
    uint256 performingDebt; uint256 impairment;
    uint256 queuedLiability; uint256 stripLiability; uint256 insurance; uint256 claimables;
}
struct CapacityTerms { uint256 capLiquidity; uint256 capDepth; uint256 capBond; uint256 capProtocol; uint256 capReserve; uint16 qualityBps; }
```

**Errors**

```solidity
error NotPoolManager(); error NotFactory(); error NotOwner(); error Reentrant();
error Expired(); error BadValue(); error BadConfig();
error Protected();               // credit op attempted while the pool is protected
error OracleUnusable();          // quality below floor, or stale
error CapacityExceeded(uint256 requested, uint256 available);
error BlockCreditBudget(); error BlockRedeemBudget();
error MinCreditFraction();       // open borrows < minCreditBps of notional
error LtvBreach(uint256 debt, uint256 collateralValue);
error OpenBufferBreach(uint256 hfWad);
error PartialFill(uint256 requested, uint256 actual);
error Slippage(uint256 got, uint256 min);
error NotLiquidatable(uint256 hfWad);
error CloseFactorExceeded();
error LiquidationTooDeep(uint256 got, uint256 floor);
error InsufficientShares(); error ShareHoldPeriod(); error DepositCapped();
error NothingToClaim(); error TransferFailed();
error CustodyMismatch();         // the two-sided claim invariant broke
```

**Modifiers:** `onlyPoolManager`, `onlyFactory`, `nonReentrant` (`unlockDepth`), `accrues` (calls `_accrue()` first — applied to *every* state-changing entrypoint without exception; see §3.1 for why this deletes the JIT-deposit attack).

**Events:** `PositionOpened/Increased/Reduced/Closed/Liquidated`, `BadDebtRealised(uint256 id, uint256 shortfall, uint256 absorbedByInsurance)`, `Deposited`, `RedeemRequested`, `TicketServed`, `TicketCancelled`, `InKindRedeemed`, `StripIssued/StripPaid/StripWrittenDown`, `Accrued(uint128 newIndexRay, uint256 interest, uint256 toInsurance)`, `Harvested`, `RiskPushed`.

**Unlock action tags** — one dispatcher, tag-prefixed payload, exactly `HookrLaunchpad.unlockCallback`'s shape:

```
1 OPEN   2 CLOSE   3 REPAY   4 ADD_COLLATERAL   5 WITHDRAW_COLLATERAL
6 LIQUIDATE   7 DEPOSIT   8 REDEEM   9 SERVICE_QUEUE   10 REDEEM_IN_KIND
11 HARVEST   12 CLAIM
```

### 2.3 `LeverageFactory.sol`

```solidity
function create(CreateParams calldata p) external payable returns (address token, address market);
function predictHookFlags() external pure returns (uint160);
function marketOf(address token) external view returns (address);
function previewSeed(uint256 ethIn, uint16 poolSupplyBps) external pure
    returns (uint256 tokensInPool, uint96 openPriceWei, uint160 sqrtPriceX96, uint256 openFdvWei, uint8 err);
```

Ordering, mirroring `HookrLaunchpadLib.openPool` because `beforeInitialize` enforces it:

```
1. token  = new HookrToken(name, symbol, tagline, logoURI, creator, SUPPLY)
2. market = new LeverageMarket(poolManager, hook, bond, token, riskConfig, shareName, shareSymbol)
3. hook.registerPool(key, poolCfg with market = address(market))     // one-shot, onlyFactory
4. poolManager.initialize(key, sqrtPriceX96)                          // beforeInitialize checks (3);
                                                                      // afterInitialize pushes the LP fee + seeds obs[0]
5. token.transfer(address(market), tokensForPool)
6. market.seed{value: ethForPool}(tokensForPool, reserveWei, creator) // onlyFactory, one-shot:
                                                                      // unlock -> settle both legs -> modifyLiquidity(+L)
                                                                      // -> mint reserve claims -> mint founding shares
```

Price is derived, never supplied — reuse `HookrLaunchpadLib.instantPlan(ethIn, poolSupplyBps, SUPPLY, 60)` verbatim (it is already deployed and linked, and it already returns the `PLAN_*` error codes). Do not reimplement `sqrtPriceX96ForPrice`.

`seed` mints `DEAD_SHARES = 1e3` to `address(0)` on the first deposit path. Standard inflation-attack defence, and it is not sufficient on its own — see the booked-claims rule in §6.

### 2.4 `HookrCreditBond.sol`

```solidity
function bond(address market, uint256 amount) external;
function requestUnbond(address market, uint256 amount) external returns (uint256 unlockAt);
function withdraw(address market, uint256 requestId, address to) external returns (uint256);
function bondedFor(address market) external view returns (uint256);
function notifyFee(address market) external payable;                 // called by the market on origination
function claim(address market, address payable to) external returns (uint256);

uint32 public constant UNBOND_COOLDOWN = 7 days;
```

`UNBOND_COOLDOWN` must exceed the longest plausible time-to-liquidate so a bonder cannot exit ahead of the risk their bond was underwriting. Fee accrual is the standard cumulative-index-per-bonded-token pattern.

**Honest statement about this term.** `creditPerBondedWad` is a governance constant, not a price oracle — there is no reliable on-chain $HOOKR price here. That is fine, because `capBond` only ever enters a `min()`. It can never *raise* capacity above what liquidity supports; that property is structural, not a clamp someone has to remember to write. If the bond is zero, capacity is zero: bonding is a **required** term, which is the actual utility.

### 2.5 `LeverageMath.sol` (`internal pure`)

```solidity
function pqFromSqrt(uint160 sqrtPriceX96) internal pure returns (uint256 pqWei);
function pqFromTick(int24 tick) internal pure returns (uint256 pqWei);
function riskPrice(uint256 spot, uint256 twapShort, uint256 twapLong) internal pure returns (uint256);
function accrueIndex(uint128 idxRay, uint256 ratePerSecRay, uint256 dt) internal pure returns (uint128);
function debtFromScaled(uint256 scaled, uint128 idxRay) internal pure returns (uint256);   // rounds UP
function scaledFromDebt(uint256 debt, uint128 idxRay) internal pure returns (uint256);     // rounds UP on borrow
function healthFactorWad(uint256 collateral, uint256 pq, uint16 liqThresholdBps, uint256 debt) internal pure returns (uint256);
function liqPriceWei(uint256 debt, uint256 collateral, uint16 liqThresholdBps) internal pure returns (uint256);
function borrowRatePerSecRay(uint16 uBps, RiskConfig memory c) internal pure returns (uint256);
function capacityTerms(...) internal pure returns (CapacityTerms memory);
function exitFeeBps(uint16 uBps, uint16 minBps, uint16 maxBps) internal pure returns (uint16);
function sharesForQuote(uint256 quote, uint256 supply, uint256 nav) internal pure returns (uint256);
function quoteForShares(uint256 shares, uint256 supply, uint256 nav) internal pure returns (uint256);
```

Reuse `V4PoolMath.mulDiv` (reverts `MulDivOverflow` rather than returning garbage) and `V4PoolMath.getSqrtPriceAtTick`. **Never call `V4PoolMath.getTickAtSqrtPrice` inside `beforeSwap`/`afterSwap`** — its own header says so; it is an ~18-iteration binary search. It appears exactly once in this design, in the view-only `liquidationTick()`.

### 2.6 `LeverageOracleLib.sol` (`internal`)

```solidity
function write(Observation[256] storage ring, OracleMeta storage m, int24 tick, uint32 nowSec, uint32 minSpacing) internal;
function observeAt(Observation[256] storage ring, OracleMeta storage m, uint32 target) internal view returns (int56 tickCumulative, bool ok);
function meanTick(Observation[256] storage ring, OracleMeta storage m, uint32 window, uint32 nowSec) internal view returns (int24, bool ok);
function boundedWalk(Observation[256] storage ring, OracleMeta storage m, uint32 window, uint8 maxSteps) internal view returns (int24, bool ok);
function oracleQualityBps(OracleMeta memory m, uint32 twapLongSec, uint32 maxStalenessSec, uint32 nowSec) internal pure returns (uint16);
function volQualityBps(uint64 volEwmaX32, int24 refTicks, uint16 floorBps) internal pure returns (uint16);
function utilQualityBps(uint16 uBps, uint16 uKinkBps, uint16 uMaxBps) internal pure returns (uint16);
```

### 2.7 / 2.8 The linked libraries

`LeveragePositionLib` and `LeverageVaultLib` are `library` with `public` functions, DELEGATECALLed so `address(this)` remains the market. They take memory structs, call PoolManager, and **return effect structs**; the market applies every SSTORE:

```solidity
struct OpenEffects   { uint128 tokensOut; uint128 originationWei; uint128 debtScaled; uint256 hfWad; }
struct CloseEffects  { uint128 quoteOut; uint128 repaid; uint128 residual; uint128 fee; uint128 shortfall; uint128 scaledBurned; }
struct LiqEffects    { uint128 quoteOut; uint128 bonus; uint128 penalty; uint128 repaid; uint128 residual; uint128 shortfall; uint128 scaledBurned; }
```

This keeps the repo's stated security property (`HookrLaunchpadLib.sol:46`: "the delegate frame carries no authority over it"), keeps the market's write blocks compact, and makes every flow a pure function of `(inputs, pool state)` for property testing.

---

## 3. The math

Units: quote = wei of ETH (currency0). Token = 18-decimal currency1. `RAY = 1e27` (index), `WAD = 1e18` (HF, prices, share price), `BPS = 1e4`.

### 3.0 The price inversion — read this before writing any tick comparison

`currency0` is native ETH in every Hookr pool, so `sqrtPriceX96` encodes **price of currency0 in currency1 = tokens per ETH**. A more valuable token means *fewer tokens per ETH* means **lower sqrtPrice** means **lower tick**.

```
Pq  =  quote wei per 1e18 token  =  1e18 * 2^192 / sqrtPriceX96^2
```

Computed without overflow as two `mulDiv`s (never square a uint160):

```solidity
uint256 h = V4PoolMath.mulDiv(1e18, Q96, sqrtPriceX96);   // <= ~2^124
pqWei     = V4PoolMath.mulDiv(h,    Q96, sqrtPriceX96);
```

Sanity: `sqrtPriceX96 == 2^96` → `Pq == 1e18` (1 ETH per token). Token doubles → `sqrtPrice = 2^96/√2` → `Pq = 2e18`, and the tick *fell*.

Therefore: **a long-token position becomes liquidatable when the tick RISES.** `liquidationTick()` returns `t` such that the position is liquidatable when `currentTick >= t`. This is inverted from every mental model imported from a token/USDC pool, and it is why the on-chain health check operates on `Pq` and never on ticks. Ticks appear only in the oracle (where the direction cancels out of a difference) and in the view-only `liquidationTick`.

### 3.1 Interest accrual — index based

```
dt = block.timestamp - lastAccrualAt
if (dt == 0 || totalDebtScaled == 0) { lastAccrualAt = now; return; }

r          = borrowRatePerSecRay(utilisationBps())               // RAY per second
newIndex   = borrowIndexRay * (RAY + r*dt) / RAY                 // simple within, compounding across
interest   = totalDebtScaled * (newIndex - borrowIndexRay) / RAY
toInsurance = interest * cfg.reserveFactorBps / BPS
insuranceQuote += toInsurance
borrowIndexRay  = newIndex
lastAccrualAt   = now
```

Per position, rounding **always against the borrower**:

```
debtOf(id)   = ceil(p.debtScaled * borrowIndexRay / RAY)
totalDebt()  = floor(totalDebtScaled * borrowIndexRay / RAY)
```

so `Σ debtOf ≥ totalDebt`. The residue is unattributed surplus, which is conservative. The inverse rounding would manufacture a phantom shortfall — the same failure mode `HookrHook` guards against with its `lpFeePips == 0` early return, where a naive `ceil − floor` "invents one LP wei."

**Interest is accrued, not received.** It raises `totalDebt()`, which is an *asset* in NAV, so the LP share price rises the moment it accrues — before any cash arrives. That is standard, it is exactly the "performing debt + accrued interest" in the published claim, and it is precisely why withdrawal has to be solvency-aware rather than a simple `burn → transfer`.

**`_accrue()` runs at the top of every state-changing entrypoint, no exceptions.** Combined with valuing uncollected v4 fees continuously through `getFeeGrowthInside` (rather than only at harvest), this removes both discontinuities a JIT depositor could straddle: the index never jumps at a call boundary, and `harvest()` becomes NAV-neutral. The remaining upward jump is a liquidation penalty; `cfg.minHoldBlocks` covers it.

### 3.2 Utilisation and the borrow rate

```
freeQuote = quoteClaimsBooked - claimableQuoteTotal - insuranceQuote
U         = totalDebt * BPS / (totalDebt + freeQuote)            // 0 if both are 0
```

The denominator is the **credit book's own funding base**, not the whole balance sheet. The ETH sitting inside the AMM curve is not lendable — it is the depth that secures the loans. Including it would understate utilisation and is the sort of flattering denominator this repo's fail-closed conventions exist to prevent.

Two-slope kink:

```
U <= uKink:  r = base + slope1 * U / uKink
U >  uKink:  r = base + slope1 + slope2 * (U - uKink) / (BPS - uKink)
```

Defaults: base 2% APR, slope1 8%, slope2 200%, `uKink = 8000`, `uMax = 9000`. Stored per-second (`aprRay / 365 days`) so the hot path has no division; `uint96` because slope2 at 200% APR is ~6.3e19, over `uint64`.

**Past `uMax`, new leverage is refused** — not by the rate, by `utilQualityBps` hitting 0, which zeroes capacity. Reduce, repay, close, add-collateral, and liquidate all remain open.

### 3.3 Health factor and the liquidation buffer

Risk price — the most conservative of the three, so collateral can never be valued off a spike:

```
Prisk = min(spotPq, twapShortPq, twapLongPq)
```

```
collateralValue = collateral * Prisk / 1e18                       // rounds DOWN
debt            = debtOf(id)                                      // rounds UP
HF_wad          = collateralValue * liqThresholdBps * 1e18 / (debt * BPS)
liquidatable    <=>  HF_wad < 1e18
```

At `liqThresholdBps = 7500`, liquidation opens while collateral is still **1.333× debt** — the requirement that "liquidation begins before collateral merely equals debt." The buffer is **derived, not guessed**, and the constructor asserts the identity:

```
BPS - liqThresholdBps  ==  liqBonusBps + liqPenaltyBps + maxLiqSlippageBps + interestLagBps + oracleLagBps + closeFeeBps
   2500                ==   200        + 300           + 500               + 200           + 300         + 10   (+ 990 headroom)
```

Every basis point of the buffer is attributable to a named hazard, and `require(sum <= BPS - liqThresholdBps)` in the constructor makes a mis-set config uncompilable-in-practice rather than quietly under-collateralised.

Opening is strictly tighter: `maxLtvBps = 6000` (2.5×) against `liqThresholdBps = 7500`, and additionally `HF_open >= 1e18 + openBufferBps` (1.15). A position is never liquidatable in the block it opens.

### 3.4 Liquidation price

Solve `HF = 1`:

```
Pliq = debt * BPS * 1e18 / (collateral * liqThresholdBps)          // quote wei per 1e18 token
```

`liquidationTick()` = `V4PoolMath.getTickAtSqrtPrice(sqrtFromPq(Pliq))`, **view only**, and the position is liquidatable when `currentTick >= liquidationTick()`.

### 3.5 Credit capacity — a minimum of terms

```
reserveQuote = (uint256(L) << 96) / sqrtPriceX96      // quote-side virtual reserve, in-range
reserveToken = (uint256(L) * sqrtPriceX96) >> 96      // token-side
```

Both verbatim from `HookrHook.sol:399-403`. With exclusive liquidity and a full-range position, in-range == all.

**1. capLiquidity** — the book must stay small relative to the market securing it:

```
capLiquidity = reserveQuote * cfg.maxBookToDepthBps / BPS          // default 25%
```

**2. capDepth — executable liquidation depth.** If the entire book had to be liquidated, the forced sale must clear inside `maxLiqSlippageBps`. Under the constant-product view of in-range depth, selling `T` tokens into `reserveToken` incurs average slippage `T / (reserveToken + T)`. Bound it at `s`:

```
maxSellTokens = reserveToken * s / (BPS - s)
capDepth      = maxSellTokens * Prisk / 1e18 * cfg.maxLtvBps / BPS
```

This is the term that makes "credit is extended out of the pool's own liquidity" a solvency statement rather than a slogan: the market will not lend more than it can unwind into its own book at a price it has already committed to accept.

**3. capBond** — `bond.bondedFor(market) * cfg.creditPerBondedWad / 1e18`.

**4. capProtocol** — `cfg.maxBookQuoteWei`.

**5. capReserve** — `freeQuote > totalDebt * minReserveRatioBps / BPS ? freeQuote - that : 0`. You cannot lend the redemption buffer.

Then the tighteners, none of which can ever loosen anything:

```
qualityBps    = min(oracleQualityBps, volQualityBps, utilQualityBps)
ceiling       = min(capLiquidity, capDepth, capBond, capProtocol) * qualityBps / BPS
availableWei  = min(ceiling, capReserve) - totalDebt        (floored at 0)
```

```
volQuality    = clamp(BPS * volRefTicks / max(volRefTicks, volEwmaTicks), minQualityBps, BPS)
oracleQuality = 0 if stale; BPS * spannedSec / twapLongSec while the ring is warming; else BPS
utilQuality   = BPS below uKink; linear to 0 at uMax; 0 at/above uMax
```

And the same quality tightens per-position leverage, so a scary tape shrinks both the book and each borrower:

```
effectiveMaxLtvBps = cfg.maxLtvBps * qualityBps / BPS
```

Finally, **per block, never per swap**: `creditOpenedInBlock <= cfg.maxNewCreditPerBlockWei`, reset on `creditBlock != block.number`. `HookrHook.sol:281-289` already states the reason — "a contract can loop capped buys inside a single transaction… a block is the finest granularity at which 'different callers' is a real distinction rather than one caller with more addresses." A per-transaction credit cap is decorative.

### 3.6 NAV and the LP exchange rate — where the double-count is avoided

```
ASSETS
  A1  freeQuote            = quoteClaimsBooked - claimableQuoteTotal - insuranceQuote
  A2  positionQuote        = amount0 + amount1 * Prisk / 1e18 + fees0 + fees1 * Prisk / 1e18
  A3  tokenTreasuryQuote   = tokenTreasury * Prisk / 1e18
  A4  performingDebt       = totalDebt()

LIABILITIES
  L1  queuedLiability      = 0        (see below — the queue is denominated in shares)
  L2  stripLiabilityQuote
  L3  insuranceQuote
  L4  impairment           = max(0, totalDebt - totalCollateralTokens * Prisk / 1e18
                                    * (BPS - liqPenaltyBps - maxLiqSlippageBps) / BPS)

CUSTODIAL — NOT AN ASSET
  totalCollateralTokens

NAV            = A1 + A2 + A3 + A4 - L2 - L3 - L4
sharePriceWad  = totalSupply == 0 ? 1e18 : NAV * 1e18 / totalSupply
```

**The double count, named.** Trader collateral physically sits in this contract as ERC-6909 token claims. It is not in `A1` (native only), not in `A2` (the v4 position is a separate object), and not in `A3` (`tokenTreasury` is market-owned fee dust, tracked separately). **It appears nowhere in NAV.** The market's entire exposure to those tokens runs through `A4` net of `L4`. Counting the collateral as an asset *and* keeping the receivable would book the same economic value twice — every levered token would appear on the balance sheet as both the loan and the thing the loan bought.

The enforceable form of that statement, checked after every action:

```
tokenClaimsBooked == totalCollateralTokens + tokenTreasury + claimableTokenTotal
```

`A2` uses `V4PoolMath.getAmountsForLiquidity(sqrtRisk, sqrtLower, sqrtUpper, L)` — which **rounds down**, correct for valuation (its header flags it as unsafe for sizing debt, which is not what it is doing here) — plus uncollected fees from `StateLibrary.getFeeGrowthInside` differenced against the position's `feeGrowthInside*Last`. Valuing fees continuously rather than at harvest is what makes `harvest()` NAV-neutral and removes it as a front-runnable event. v4 warns that `feesAccrued` can be inflated by self-donation; with exclusive liquidity the only possible donor is this market, so it is not an attack surface here — but the sole reason it isn't is the exclusivity gate, so the two decisions must live or die together.

**`L4` is a lower bound on true impairment and I am saying so.** Aggregating collateral against debt nets a healthy position's surplus against an unhealthy one's deficit, so this understates. The honest per-position answer is a tick-bucketed liquidation ledger (`debtInBucket[tick]`, `collateralInBucket[tick]`, summed over buckets at or beyond the current tick), and it is a real O(buckets) loop. **It is not in v1 (§8).** The reason that is acceptable is structural: the protection against redeeming at par into a bad book is not the marking, it is the redemption model in §6 — an LP who redeems while the book is impaired receives a strip of the impaired book, not cash, regardless of how precisely the book is marked. `L4` is a monotone early-warning signal that goes positive exactly when the book as a whole is underwater, which is the case a bank run cares about.

**The queue is not a liability** (`L1 = 0`) because tickets escrow *shares*, not quote. The escrowed shares stay in `totalSupply`, held at `balanceOf[address(this)]`, and keep floating with NAV. This is the entire point (§6).

---

## 4. Flows — step by step, marking what happens inside `unlock()`

### 4.1 OPEN

**Outside `unlock` — `open(OpenParams p)`, `msg.value == p.equityWei`**

1. `nonReentrant`; `block.timestamp <= p.deadline` or `Expired()`.
2. `_accrue()`.
3. `RiskState s = hook.riskState(poolId)`. Require `!s.protected_` or `Protected()`; `s.qualityBps >= cfg.minQualityBps` or `OracleUnusable()`.
4. `Prisk = min(s.spotPq, s.twapShortPq, s.twapLongPq)`.
5. `notional = equityWei + creditWei`. Require `equityWei >= cfg.minEquityWei`; `creditWei * BPS >= notional * cfg.minCreditBps` or `MinCreditFraction()`.
6. `(terms, available) = creditCapacity()`. Require `creditWei <= available` or `CapacityExceeded`.
7. Per-block budget: roll `creditBlock`, require `creditOpenedInBlock + creditWei <= cfg.maxNewCreditPerBlockWei`.
8. Pre-check LTV against `Prisk` (an estimate — step 15 is the one that binds).
9. `poolManager.unlock(abi.encode(uint8(1), trader, p))`.

**Inside `unlockCallback` — ACTION_OPEN, delegated to `LeveragePositionLib.open`**

10. `poolManager.settle{value: equityWei}()` → `delta0 += equityWei`. Native settle, **no `sync`** — the repo idiom (`HookrLaunchpad.sol:1152`, `HookrSwapRouter.sol:235`).
11. `originationWei = notional * cfg.originationBps / BPS`; `notionalIn = notional - originationWei`.
12. **`poolManager.burn(address(this), NATIVE_ID, creditWei)` → `delta0 += creditWei`.** *This single line is where credit is extended out of the pool's own reserve.* No lending vault, no second depositor class — the quote came from the same managed share the LPs hold. `quoteClaimsBooked -= creditWei`.
13. ```solidity
    BalanceDelta d = poolManager.swap(
        key,
        SwapParams({zeroForOne: true, amountSpecified: -int256(uint256(notionalIn)), sqrtPriceLimitX96: MIN_SQRT_PRICE_LIMIT}),
        ""
    );
    ```
    The hook's `beforeSwap` and `afterSwap` **do** run here (`sender == address(market) != address(hook)`), so an observation is written and the fee override applies at base (no surge on market-originated swaps). No returns-delta flags, so no hook delta perturbs `d`.
14. **Reconcile against the actual fill — atomic or revert:**
    ```solidity
    uint256 spent = uint256(-int256(d.amount0()));
    if (spent != notionalIn) revert PartialFill(notionalIn, spent);
    uint256 tokensOut = uint256(int256(d.amount1()));
    if (tokensOut < p.minTokensOut) revert Slippage(tokensOut, p.minTokensOut);
    ```
    `MIN_SQRT_PRICE_LIMIT` (= `TickMath.MIN_SQRT_PRICE + 1`, the lowest legal `zeroForOne` limit — `Pool.swap` reverts `PriceLimitOutOfBounds` at or below `MIN_SQRT_PRICE`) makes a partial fill possible only if the book is exhausted entirely, and the equality check catches that case. Same structure as `HookrHook.sol:636-643`, minus the cut arithmetic, because reverting "atomically unwinds… instead of overcharging."
15. **Re-derive LTV from the fill, not the quote.** Read `getSlot0` *again*, post-swap:
    ```
    PriskAfter      = min(spotAfterPq, s.twapShortPq, s.twapLongPq)
    collateralValue = tokensOut * PriskAfter / 1e18
    if (creditWei * BPS > collateralValue * effectiveMaxLtvBps) revert LtvBreach(...);
    if (HF(tokensOut, creditWei) < 1e18 + openBuffer)           revert OpenBufferBreach(...);
    ```
    Our own buy pushed spot *up* in token terms. The `min()` with the two TWAPs is what excludes that self-inflicted improvement — the trader cannot borrow against the price impact of their own open. This is the difference between quoting and reconciling, and it is the step that most implementations skip.
16. `poolManager.mint(address(this), TOKEN_ID, tokensOut)` → `delta1 -= tokensOut`. Collateral is now a token claim. `tokenClaimsBooked += tokensOut`.
17. `poolManager.mint(address(this), NATIVE_ID, originationWei)` → `delta0 -= originationWei`. `quoteClaimsBooked += originationWei`; split `bondFeeBps` to `HookrCreditBond`, remainder stays in `freeQuote` and lifts the share price.
18. **Deltas net:** `delta0 = equity + credit − notionalIn − origination = 0`; `delta1 = tokensOut − tokensOut = 0`. `NonzeroDeltaCount` is 0 at close.

**Back outside**

19. Write the `Position`; `debtScaled = ceil(creditWei * RAY / borrowIndexRay)`; bump `totalDebtScaled`, `totalCollateralTokens`, `creditOpenedInBlock`.
20. `hook.updateRisk(poolId, utilisationBps())` — one push, so the hook never has to call back into a mid-flight market.
21. Emit `PositionOpened`. Assert the custody invariants (§7 I1/I2).

`increase` is the same body with an existing `positionId`.

### 4.2 CLOSE / REDUCE

**Outside:** `nonReentrant`, `_accrue()`, `p.owner == msg.sender`, deadline. **Not** blocked while protected. Oracle freshness is *not* required — closing must always be possible.

**Inside — ACTION_CLOSE**

1. `poolManager.burn(address(this), TOKEN_ID, collateralToSell)` → `delta1 += collateralToSell`.
2. `d = poolManager.swap(key, {zeroForOne: false, amountSpecified: -int256(collateralToSell), sqrtPriceLimitX96: MAX_SQRT_PRICE_LIMIT}, "")`.
3. Reconcile: `sold = uint256(-int256(d.amount1()))` must equal `collateralToSell`; `quoteOut = uint256(int256(d.amount0()))` must be `>= minQuoteOut`.
4. Waterfall:
   ```
   fee      = quoteOut * cfg.closeFeeBps / BPS          -> market revenue
   avail    = quoteOut - fee
   repay    = min(avail, debtOf(id))
   scaledΔ  = floor(repay * RAY / borrowIndexRay)        // rounds DOWN: the borrower is never over-credited
   residual = avail - repay                              -> claimableQuote[owner]
   ```
5. `poolManager.mint(address(this), NATIVE_ID, quoteOut)` → `delta0 -= quoteOut`, consuming the swap's positive `amount0`. `quoteClaimsBooked += quoteOut`; `claimableQuoteTotal += residual`.
6. If the position is fully closed and `repay < debt`: `shortfall = debt - repay` → **explicit bad debt**, absorbed by `insuranceQuote` first, then by NAV. `badDebtQuote += shortfall`. Emit `BadDebtRealised`.
7. Route the debt-book inflow through the strip splitter (§6).
8. Deltas net: `delta1 = collateralToSell − collateralToSell = 0`; `delta0 = quoteOut − quoteOut = 0`.

**Every trader-facing payout is a pull payment** (`claimableQuote` / `claimableToken`), never a `take` to the trader inside the callback. Two reasons, both already learned in this repo: `take` to a payable address is an external call to arbitrary code inside an open unlock, and — decisively — **a revert inside an `unlock` callback is uncatchable**, which is why `mintBand`/`bandLiquidity` return skip signals instead of reverting and why graduation cannot be bricked by one bad band. A trader with a reverting `receive()` must not be able to brick their own liquidation.

`claim(address payable to)` mirrors `HookrHook._claimTo` exactly: zero the balance **before** `unlock` (checks-effects-interactions), then `unlock` → `burn` claims → `take` wrapped in `try/catch` → `TransferFailed()`.

`repay` (settle ETH, mint claims, reduce debt) and `addCollateral` (`sync` → `transferFrom` → `settle` → `mint` token claims) are allowed while protected. `withdrawCollateral` is blocked while protected and requires `HF >= 1e18 + openBuffer` after.

### 4.3 LIQUIDATE

**Outside — `liquidate(id, collateralToSeize, minQuoteOut)`, permissionless**

1. `nonReentrant`, `_accrue()`.
2. `s = hook.riskState(poolId)`. Require `now - s.lastObsAt <= cfg.maxStalenessSec` or `OracleUnusable()`. **A stale oracle must never authorize a liquidation.**
3. **Trigger on `twapShortPq` alone — not `min(spot, twap)`.** If spot could trigger liquidations, dumping spot to force liquidations and buying back is a one-transaction attack. TWAP as the trigger makes it cost real time-weighted capital.
4. `HF < 1e18` or `NotLiquidatable(hf)`.
5. Close factor: `maxSeize = HF < cfg.fullLiqHfBps*1e14 ? collateral : collateral * cfg.closeFactorBps / BPS`. Require `collateralToSeize <= maxSeize`.
6. `poolManager.unlock(ACTION_LIQUIDATE)`.

**Inside — ACTION_LIQUIDATE**

7. `burn(self, TOKEN_ID, seize)`; `swap(oneForZero, exact-in seize, MAX_SQRT_PRICE_LIMIT)`. The hook sees `sender == market` and charges **base fee only** — no surge in the moment recovery matters. The LP fee that is charged accrues to the market's own position, so it is a transfer between two LP-owned pockets, not a leak.
8. Reconcile the fill exactly as in 4.2 step 3.
9. **Execution bound — the other half of the manipulation defence:**
   ```
   floor = seize * s.twapShortPq / 1e18 * (BPS - cfg.maxLiqSlippageBps) / BPS
   if (quoteOut < floor) revert LiquidationTooDeep(quoteOut, floor);
   ```
   A liquidation may not be used to dump the book. If the seize is too large for current depth, it reverts and must be re-attempted smaller — which is exactly the behaviour `capDepth` sized the book to guarantee is possible.
10. Waterfall:
    ```
    bonus    = min(quoteOut * cfg.liqBonusBps / BPS, cfg.maxLiqBonusWei)   -> claimableQuote[msg.sender]
    penalty  = quoteOut * cfg.liqPenaltyBps / BPS                          -> insuranceQuote
    avail    = quoteOut - bonus - penalty
    repay    = min(avail, debt)                                            -> debt book (strip splitter)
    residual = avail - repay                                               -> claimableQuote[position.owner]
    shortfall (if fully seized and repay < debt) -> insuranceQuote, then NAV; badDebtQuote += shortfall
    ```
    The incentive is **bounded twice** — relative (`liqBonusBps`) and absolute (`maxLiqBonusWei`) — so a single whale liquidation cannot pay out an unbounded bounty. **Residual goes back to the trader.** Shortfall is **explicit**, emitted, and counted; it is never silently netted into the share price without an event.
11. `mint(self, NATIVE_ID, quoteOut)`; update aggregates; `hook.updateRisk`.

**The liquidator needs no capital.** The market sells the collateral itself and pays a bounded quote bonus, so the liquidator pays gas only. This deletes the flash-loan dependency, deletes the "keeper front-runs with a worse execution because they profit from the spread" vector, and puts execution quality under the market's own slippage bound rather than the liquidator's discretion. It is a deliberate trade: liquidations are capped in size per call, so a cascade needs several transactions. That is the correct direction — several bounded sales beat one unbounded dump.

### 4.4 Reentrancy and ordering, stated

- The market opens `unlock` for every state-changing flow; **the hook never calls `unlock`**. No `AlreadyUnlocked` path exists anywhere.
- `unlockCallback` is `onlyPoolManager` and guarded by `unlockDepth`; every external entrypoint asserts `unlockDepth == 0`.
- **No untrusted external call occurs inside `unlockCallback`.** The only callees are `poolManager` and `hook` (trusted, and pushed-to rather than called-back). All trader/liquidator outflows are pull payments. This is the precondition that makes the transient-scratch pattern safe here, and it is the same argument `HookrHook` makes for `guardFeePipsInFlight` — "there is no untrusted external call between the write and delete."
- The hook holds no value, so a hook bug cannot move funds — only mis-price a fee or mis-report risk, both of which fail toward *less* credit.
- Dependency direction is one-way: market → hook (view reads + `updateRisk` push). The hook never calls the market. That is why `updateRisk` is a push and not a pull: a pull would have the hook reading a market mid-unlock, with state that is momentarily inconsistent by construction.

---

## 5. The oracle

**v4 gives you nothing.** `getSlot0` is spot; core ships no observation array. The ring is ours, and it lives in the hook because only the hook receives swap callbacks.

**What is observed**

| signal | source | where |
|---|---|---|
| spot | `getSlot0().sqrtPriceX96` → `Pq` | live, any call |
| short TWAP (900 s) | ring `tickCumulative` difference | `consult` |
| long TWAP (7200 s) | same | `consult` |
| depth | `getLiquidity(id)` → virtual reserves | live |
| volatility | EWMA of `|Δtick|` per swap | `afterSwap` |
| spot/TWAP deviation | `|tickAfter − twapShortTick|` | `afterSwap` |
| trade size vs active liquidity | `amountIn / reserveIn`, the `HookrHook` expression | `beforeSwap` |

**How the TWAP is maintained.** `beforeSwap` reads the pre-swap tick and calls `write`. The accumulator adds `tick * dt` using the tick that *prevailed over the interval* — which is precisely the pre-swap tick, and precisely what v3's `observation.write` does. Writing from `beforeSwap` is therefore not a convenience, it is the only correct placement.

Cardinality is **fixed at 256** with a **minimum spacing of 45 s**, giving ~3.2 h of history — enough for a 2 h long TWAP with margin. Fixed cardinality avoids the growable-ring bookkeeping; minimum spacing means most swaps write nothing (a `dt < minSpacing` early return, one `SLOAD`), and it makes single-block manipulation of the accumulator impossible: you cannot add observations faster than wall-clock.

`consult(id, window)` binary-searches for the observation at or before `now − window`, synthesizes the current cumulative as `obs[index].tickCumulative + lastTick * (now − lastObsAt)`, and returns `meanTick = Δcumulative / Δt` with `ok = false` if the ring does not span the window. `ok = false` degrades `qualityBps`; it never reverts.

`afterSwap` uses `boundedWalk(…, maxSteps = 8)` instead of the full binary search, so the per-swap cost is bounded and a thin ring degrades quality rather than reverting a stranger's swap.

**Protected state — entry**

Written in `afterSwap` when any of: single-swap `|Δtick| > maxJumpTicks`; `|spot − shortTWAP| > maxDevTicks`; `volEwma > maxVolTicks`; ring cannot cover the short window; `getLiquidity < minLiquidity`. Sets `protectedUntil = now + protectCooldownSec` and emits `ProtectedEntered(reasonMask)`.

**Protected state — exit**

`isProtected()` is a **view that recomputes the live conditions and ORs them with `protectedUntil`**. So protection is entered by a swap and leaves by time plus calm, with no keeper poke and no way to flicker inside a block. Staleness alone (`now − lastObsAt > maxStalenessSec`) also reads as protected, so a pool that simply stops trading closes for new credit automatically.

**What protection gates**

- **Blocked:** `open`, `increase`, `withdrawCollateral`.
- **Allowed:** `repay`, `reduce`, `close`, `addCollateral`, `liquidate`, `deposit`, `redeemInKind`, `serviceQueue`, `claim`.
- **Never blocked:** ordinary third-party swaps. Protection is a credit gate, not a trading halt. A hook that halts its own pool in a crash is a hook that guarantees the crash cannot be arbitraged out — and it would make this pool strictly worse than a plain v4 pool for everyone who never touched leverage.

---

## 6. The LP share and withdrawal

**One share class over the whole market**, exactly as published: a claim on pool liquidity + uncollected fees + performing debt + accrued interest + liquidation proceeds + reserves + realised bad debt. There is no second depositor class; the quote that funds credit is the same quote that funds the AMM leg, held by the same shares.

**Deposit.** `deposit(minShares)` payable, ETH only.

```
shares = totalSupply == 0 ? msg.value - DEAD_SHARES : msg.value * totalSupply / NAV
```

Inside unlock: `settle{value:}` → `mint(self, NATIVE_ID, msg.value)`. Deposits go **entirely to the quote reserve**, never to the AMM leg — adding to a full-range position requires both currencies at the current ratio, and swapping half in on every deposit would move the price on every deposit. So new capital arrives as credit capacity, which is what a leveraged market wants.

The honest consequence: depth (and therefore `capLiquidity`/`capDepth`) does not grow with deposits. `maxDepositable()` therefore caps deposits at the point where additional quote could never be deployed, and `deposit` reverts `DepositCapped()` past it. Refusing capital you cannot deploy is better than accepting it and diluting yield — and it is the same fail-closed instinct as `previewInstantLaunch` returning `PLAN_BAD_*` instead of clamping.

**Inflation-attack defence, two layers.** `DEAD_SHARES = 1e3` minted to `address(0)` on the first deposit, **and** — more importantly — NAV reads `quoteClaimsBooked`, an internal counter, never `poolManager.balanceOf`. Anyone can `mint` claims to this market inside their own unlock; if NAV read the live balance, that would be a share-price lever. Reading the booked counter makes donations invisible, and `balanceOf >= booked` becomes an invariant with the surplus sweepable to `insuranceQuote`. This is `HookrHook`'s `nativeClaimBalance() == Σ obligations` invariant, run in the other direction.

**Redemption is part of solvency.** Four paths, and they are a set — remove any one and you either trap LPs or let them run.

**(1) Instant tier, capped by a solvency floor**

```
floor     = totalDebt * cfg.minReserveRatioBps / BPS
allowance = freeQuote > floor ? freeQuote - floor : 0
allowance = min(allowance, cfg.maxRedeemPerBlockWei - redeemedInBlock)
```

As the book levers up, the instant tier shrinks toward zero **automatically**. This is the mechanism that satisfies "must never let early LPs take all liquid quote asset while remaining LPs carry every loan" — the early LPs are structurally unable to take the cash, because the floor is a function of the debt that would be left behind. It does not depend on marking the book correctly.

**(2) Utilisation-sensitive exit fee**

```
exitFeeBps = min(exitFeeMinBps + (exitFeeMaxBps - exitFeeMinBps) * U² / BPS², exitFeeMaxBps)
```

Convex in utilisation. The fee **stays in the market**, so it lifts the share price for everyone who did not leave — it is compensation to the remaining LPs for the liquidity the exit consumed, not protocol revenue.

**(3) Queue — denominated in SHARES, and this is the whole point**

```solidity
struct Ticket { address owner; uint128 sharesEscrowed; uint40 createdAt; }
```

`requestRedeem(shares, minQuoteNow)`:
- compute the entitlement, apply the exit fee, pay `payNow = min(net, allowance)`, and burn **only the shares that payment corresponds to**;
- transfer the remaining shares to `address(this)` and record a FIFO ticket.

**Escrowed shares remain in `totalSupply` and keep floating with NAV** — up with interest, down with bad debt. A queued LP is therefore *not* a senior creditor. Had the ticket been a fixed quote claim, the queue would have converted exiting LPs into a senior tranche that eats none of the losses, and the remaining LPs would absorb everything — the exact unfairness the requirement forbids, reintroduced by a data-type choice. `serviceQueue(maxTickets)` is permissionless, prices each ticket at *current* NAV with the *current* exit fee, and burns shares as it pays. `cancelTicket` returns the shares; there is nothing to front-run, because the ticket never had a price.

**(4) In-kind exit — the uncapped door**

`redeemInKind(shares)`: burn the shares, and receive a pro-rata slice of **everything**:
- `shares/total` of `freeQuote` (as claimable native),
- `shares/total` of the v4 position, removed via a negative `liquidityDelta` inside unlock, paid out as claimable ETH **and** claimable token,
- a **receivable strip**: `shares/total × (totalDebt − impairment)`.

No cap, no queue, no exit fee, never blocked — not even while protected. Because it takes exactly its share of the risk, there is nothing to protect anyone from.

Strip accounting is one aggregate and one index:

```
issue:      newStripShares = stripLiabilityQuote == 0 ? amt : amt * totalStripShares / stripLiabilityQuote
            stripLiabilityQuote += amt
cash in X:  toStrip = X * stripLiabilityQuote / (stripLiabilityQuote + lpOwnedDebt)
            stripCashPerShareWad += toStrip * 1e18 / totalStripShares
            stripLiabilityQuote  -= toStrip
bad debt B: toStrip = B * stripLiabilityQuote / (stripLiabilityQuote + lpOwnedDebt)
            stripLiabilityQuote  -= toStrip           // no cash, no index move — the claim simply shrinks
claim:      owed = stripShares[u] * (stripCashPerShareWad - stripSnapshotWad[u]) / 1e18
```

where `lpOwnedDebt = totalDebt − stripLiabilityQuote`. Strip holders take their pro-rata share of repayments, interest, liquidation recoveries **and** write-offs. Non-transferable in v1.

**Why this door matters more than it costs.** It removes the incentive to run: running gets you a strip, waiting gets you cash. Withdrawing in-kind also removes pro-rata depth, which lowers `capDepth`, which lowers capacity — the market shrinks its credit book as its LP base shrinks, automatically. And note what the safety property actually rests on: **the queue-in-shares alone already satisfies the stated invariant.** The strip is the *convenience* door, not the *safety* door. If v1 scope has to be cut under schedule pressure, this is the one piece that can go without breaking the invariant — and knowing which piece that is, in advance, is the point of writing it down.

**`minHoldBlocks`.** Shares are non-redeemable for `cfg.minHoldBlocks` after minting (`lastMintBlock`). With `_accrue()` on every entrypoint and continuous fee valuation, the only remaining upward NAV jump is a liquidation penalty; this covers it.

---

## 7. Invariants — the property-test list

Modelled on `AdversarialAudit.t.sol:243-250`'s `_assertHookSolvent`, which asserts total claim units equal the sum of every named obligation after **every single action**. Same discipline, two currencies. Every one of these is asserted in a shared `_assertSolvent(string tag)` helper called after every action in every test.

**Custody**

- **I1** `poolManager.balanceOf(market, NATIVE_ID) >= quoteClaimsBooked` — surplus is donation, never counted.
- **I2** `poolManager.balanceOf(market, TOKEN_ID) >= tokenClaimsBooked`.
- **I3** `tokenClaimsBooked == totalCollateralTokens + tokenTreasury + claimableTokenTotal` — **the no-double-count invariant.** Trader collateral is fully accounted and appears nowhere in NAV.
- **I4** `quoteClaimsBooked >= claimableQuoteTotal + insuranceQuote` — pull payments and the reserve are always fully backed.
- **I5** `address(market).balance == 0` and `market` has no `receive()`/`fallback()`, outside a transient in-flight `settle`.
- **I6** `poolManager.getPositionLiquidity(poolId, keccak256(abi.encodePacked(market, TICK_LOWER, TICK_UPPER, bytes32(0))))` is the pool's **entire** liquidity — no other position exists, ever.

**Balance sheet**

- **I7** `NAV == freeQuote + positionQuote + tokenTreasuryQuote + totalDebt − stripLiability − insurance − impairment`, recomputed from primitives and compared to the incremental value. Fuzzed over action sequences — the repo's `assertEq(address(pad).balance, reserve + protocolFees + creatorFees, "every wei accounted")` shape.
- **I8** `Σ debtOf(id) >= totalDebt()` — rounding is always against the borrower, never in a direction that manufactures a shortfall.
- **I9** `totalDebtScaled == Σ positions[i].debtScaled`, `totalCollateralTokens == Σ positions[i].collateral`.
- **I10** Bad debt is conserved: every `BadDebtRealised` event's shortfall equals the drop in `(NAV + insuranceQuote)` attributable to that action, to the wei.
- **I11** `sharePriceWad` is non-decreasing across `deposit`, `requestRedeem`, `serviceQueue`, `redeemInKind`, `harvest`, `claim` — every share-count-changing operation must be non-dilutive. It may only fall on `_accrue` impairment or realised bad debt.

**Credit**

- **I12** `totalDebt() <= min(capLiquidity, capDepth, capBond, capProtocol) * qualityBps / BPS` holds immediately after every `open`/`increase`. (It may be breached later by price movement — that is what liquidation is for. Assert only at origination.)
- **I13** Every position satisfies `HF >= 1e18 + openBuffer` immediately after `open`/`increase`/`withdrawCollateral`.
- **I14** No `open` succeeds while `hook.isProtected(poolId)`; every `repay`/`reduce`/`close`/`addCollateral`/`liquidate` succeeds while protected, given otherwise-valid inputs. Fuzz protection on/off across every action.
- **I15** `creditOpenedInBlock <= maxNewCreditPerBlockWei` — proven with an adversarial contract that loops opens inside a single transaction (the `HookrHook.sol:281-289` attack, replayed).
- **I16** After a full close or full liquidation, `positions[id].debtScaled == 0 && collateral == 0`, and either debt was fully repaid or a `BadDebtRealised` event was emitted. Never both, never neither.

**Liquidation**

- **I17** Liquidator payout `<= min(quoteOut * liqBonusBps / BPS, maxLiqBonusWei)`. Fuzzed over sizes and prices; no input produces an unbounded bounty.
- **I18** Residual after repayment always reaches `claimableQuote[position.owner]`; a trader with a reverting `receive()` cannot brick their own liquidation (deploy one and liquidate it).
- **I19** `liquidate` reverts when `now − lastObsAt > maxStalenessSec`.
- **I20** A spot-manipulation sandwich (dump → liquidate → buy back, one transaction) is unprofitable or reverts: the TWAP trigger refuses, or the `LiquidationTooDeep` floor refuses. Both branches tested.

**Withdrawal — the headline property**

- **I21** **The run test.** Fuzz an LP set, open a book to utilisation `U`, then have every LP redeem in a fuzzed order. Assert: no ordering leaves any LP with a strictly larger fraction of `freeQuote` than their share fraction, and `freeQuote >= totalDebt * minReserveRatioBps / BPS` holds after every instant redemption.
- **I22** Escrowed shares stay in `totalSupply` and absorb bad debt: realise bad debt with tickets queued, then service them, and assert the ticket holder received strictly less than their pre-loss entitlement, in exact proportion.
- **I23** `redeemInKind` never reverts for a solvent holder — not while protected, not at `U = uMax`, not with the queue full.
- **I24** Strip conservation: `Σ strip claims paid + stripLiabilityQuote_final == stripLiabilityQuote_issued + Σ interest allocated to strips`, and strip write-downs sum exactly to the strip's pro-rata share of realised bad debt.
- **I25** JIT round-trip is unprofitable: `deposit` → any single action → `requestRedeem` in the same block reverts (`ShareHoldPeriod`), and across `minHoldBlocks` yields strictly less than the exit fee.

**Oracle / hook**

- **I26** Any non-market `modifyLiquidity` reverts `ExclusiveLiquidity` — via `PoolModifyLiquidityTest`, via a direct call, and via a contract impersonating a router.
- **I27** Ordinary swaps never revert due to protection, staleness, or utilisation. Fuzz swaps across every protected state.
- **I28** `consult` is monotone and manipulation-bounded: a single-block swap sequence of arbitrary size moves the 900 s TWAP by at most `spacing/window` of the spot move.
- **I29** Hook flag word: `uint160(address(hook)) & 0x3FFF == REQUIRED_FLAGS == 0x3AC0`, and the hook's four unflagged IHooks methods revert `HookNotCalled()`.
- **I30** The hook holds no value in any currency, ever: `balance == 0`, `poolManager.balanceOf(hook, *) == 0`.

---

## 8. Not in v1 — and why

1. **Short leverage** (borrowing the token against quote collateral). The pool holds token inventory, so it is mechanically possible — but the loss is unbounded above and liquidation runs *into* the illiquid direction, exactly where `capDepth` is weakest. Longs first, and only longs, until the liquidation engine has real history.
2. **Cross-margin / netting.** One position, one collateral, one debt. Cross-margin makes health a set-valued function and makes partial liquidation a search problem.
3. **Per-position mark-to-market impairment.** `L4` is the aggregate floor, and it understates true impairment because netting cancels a healthy surplus against an unhealthy deficit. The correct fix is a tick-bucketed liquidation ledger (`debtInBucket` / `collateralInBucket`, summed from the current tick outward — the same shape as v4's own tick ledger). It is a real loop and it deserves its own review. Deferred because the redemption model, not the marking, is what protects LPs from redeeming at par.
4. **Price-moving `rebalance()`.** `harvest()` compounds fees back into the position without a swap. Deploying idle quote into the AMM leg requires buying the token, which moves the price on a schedule an attacker can read. Until that is designed properly, `maxDepositable()` refuses capital that cannot be deployed — an honest cap beats a dangerous deployment.
5. **$HOOKR bond slashing.** The bond is a capacity term plus a fee share. Slashing needs a loss-attribution rule that survives adversarial construction; a bond that can be slashed by a griefer is worse than no bond.
6. **Any external oracle.** The pool is its own oracle, exactly as published. No Chainlink, no Pyth, no fallback feed. The whole `qualityBps` apparatus exists because that choice has costs and they are being priced rather than hidden.
7. **Auto-deleveraging / socialised loss on winners.** Bad debt hits LPs and is emitted. It is never clawed back from profitable traders.
8. **Transferable positions (NFT) and transferable strips.** Positions are owner-keyed structs; strips are non-transferable. Both become tradeable only once the liquidation engine has history.
9. **Fixed-rate or term loans, interest paid in token.** Floating rate, quote-denominated, open-term.
10. **Governance and upgradeability.** No proxy, no owner on the market, no setter after `create`. Matching the repo: `HookrHook`'s config is one-shot, `HookrSwapRouter` has no owner at all, and `HookrLaunchpad`'s admin surface cannot touch a live pool. A leverage market with a config setter is a leverage market with a rug.
11. **A generalized swap router.** `HookrSwapRouter._validate` pins its immutable hook and will reject this pool. Spot swappers use generic v4 routing until a `HookrSwapRouterV2` is generalized over hooks. A UI problem, not a protocol problem.
12. **Multiple pools per market, multi-hop, or a shared cross-pool market.** One market, one pool, one token. Shared custody across pools means one pool's bad debt can reach another pool's claims.

---

## 9. Implementation order

1. `ILeverage.sol`, `LeverageMath.sol`, `LeverageOracleLib.sol` — pure, unit-testable with no PoolManager. Get the `Pq` inversion (§3.0) and the TWAP accumulator right here or nothing downstream is trustworthy.
2. `LeverageHook.sol` + `HookMiner.find(address(this), 0x3AC0, creation)` — stand up a pool with a scratch harness (`ScratchLeverageHarness.t.sol`, already passing). Prove I26–I30 before any credit code exists.
3. `LeverageMarket.sol` custody skeleton + `LeverageVaultLib` deposit/NAV — prove I1–I7, I11 with zero debt.
4. `LeveragePositionLib` open/close — prove I8–I9, I12–I13, I16, and the fill reconciliation (step 15 of §4.1) with a fuzzed book.
5. Liquidation + bad debt — I10, I17–I20.
6. Queue, strip, exit fee — I21–I25.
7. `LeverageFactory`, `HookrCreditBond`, `script/DeployLeverage.s.sol` with its own `HOOK_FLAGS = 0x3AC0` literal and the `_mine` loop from `DeployRobinhood.s.sol:150-165` (including the `code.length == 0` EIP-684 check, which `HookMiner` deliberately omits).

Two things to watch during 3–6: run `forge build --sizes` after every step — `LeverageMarket` is the contract that will hit 24,576 B, and the fix is `LeverageLens.sol`, not thinner invariant checks. And add each new invariant to the shared `_assertSolvent(tag)` helper as it is proven, so every later test inherits every earlier property.