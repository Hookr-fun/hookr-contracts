// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {HookrTypes} from "../types/HookrTypes.sol";
import {HookrDynamicFee} from "../libraries/HookrDynamicFee.sol";
import {IHookrLaneRoot} from "../interfaces/IHookrLaneRoot.sol";
import {IHookrAdvisoryFeeCounter} from "../interfaces/IHookrAdvisoryFeeCounter.sol";
import {IHookrRulesKnobs} from "../interfaces/IHookrRulesKnobs.sol";
import {HookrRules} from "./HookrRules.sol";
import {HookrClock} from "../libraries/HookrClock.sol";
import {IHookrTreasury} from "../interfaces/IHookrTreasury.sol";
import {IHookrRecaptureEvents} from "../interfaces/IHookrRecaptureEvents.sol";
import {IHookrRulesEvents} from "../interfaces/IHookrRulesEvents.sol";

/// @title HookrRecapture
/// @notice HookrRules' recapture split and King of the Pool, as a module HookrRules deploys from its own constructor
///         and reaches only by DELEGATECALL, so it runs in the Rules' context (storage, claims, events, address) while
///         its code stays out of the Rules' runtime. A pool without recapture never reaches it.
/// @dev What a recapture pool gets, frozen at bind (HookrTypes.RecaptureConfig, the third part of its Rules data):
///      - The split. The root's lane executor keeps its pinned partner share of the realized profit and pushes the
///        rest in any of the accepted currencies, several if it likes: the pool's quote or subject, or a member of the
///        registry's settlement set (native ETH, WETH, USDG at genesis). For each currency pushed the root moves the
///        push to the Rules as claims of that currency and asks for the split, passing the profit that push reports
///        (push x 10,000 / (10,000 - partnerBps), rounded down: Hookr never sees the arbitrage's real profit, so this
///        is the executor's figure, not a measurement). The protocol takes RECAPTURE_PROTOCOL_BPS (25%) of that profit
///        first, in that currency, at most the whole push: the same on every pool, whatever its protocolShareBps (the
///        share of its rule fees), and never split with an integrator. On a push in the quote, RulesConfig.potBps of
///        the remainder goes to the King of the Pool pot, `traderBps` of the remainder's part the trader's own swap
///        accounts for (the root's `traderBasis`: only on the after-phase, only when the arb recapture undid the
///        trader's move, at most its quote times its price move) to the trader the root names, and the rest (`lpBps`,
///        the rounding dust and whatever trader share the basis does not cover) is the LP share. The basis and the pot
///        are quote units, so on a push in any other currency the trader and pot shares join the LP share. A family arb
///        recapture that legs through the pool's siblings is split once, under the pool that triggered it. With a
///        partner share of 2,500 and the default traderBps of 2,500, a profit P splits 25% to the partner, 25% to the
///        protocol, 12.5% to the trader (when its basis covers the push) and 37.5% to the LPs.
///      - The LP share goes to all of the pool's in-range liquidity in proportion to the L2 blocks it stayed in range,
///        JIT-safe. In one of the pool's two currencies it becomes a pending donation, released gradually over the
///        pool's `releaseBlocks` (R) and donated with PoolManager.donate (settled by burning the Rules' own claims)
///        only outside any lane frame, before every liquidity add and removal lands and at the start of every outer
///        swap on the pool (`flushRecapture`, which the root calls). Each flush releases pending x min(L2 blocks since
///        the last flush, R) / R, rounded up, a share from the L2 block after it accrued, so liquidity added and
///        removed within one L2 block gets none of it and liquidity held across k L2 block boundaries gets at most
///        ceil(pending x k / R) of it, whatever its width. The blocks a release counts are also capped by wall time,
///        10 a second (L2_PER_SECOND) plus one second's worth, so liquidity held from second t to second t' gets at
///        most ceil(pending x 10 x (t' - t + 1) / R) of it however many L2 blocks share those seconds (a burst of
///        parent-chain inbox messages, each its own L2 block, adds none). The release clock is Robinhood Chain's own
///        block number (ArbSys.arbBlockNumber(), HookrClock), read only here; block.number there is the parent chain's
///        height and stays the clock of the launch guard. The part a flush releases while no liquidity is in range, and an LP
///        share in any currency other than the pool's two or accrued with no in-range liquidity, is the liquidity
///        owner's accrual in that currency instead (the launch position, through HookrLauncher). Released pot follows
///        the same path in the quote.
///      - King of the Pool, off by default: a nonzero RulesConfig.potBps turns it on. Epochs of `period` seconds
///        from the bind; the leader is the payer of the largest authenticated buy of at least `minBuyQuote` gross
///        quote spend; the first swap after an epoch, or anyone through `settleEpoch`, closes it and credits the
///        leader min(pot, spend * maxPrizeBps / 10,000). Each closed epoch then releases `potReleaseBps` of the pot
///        it carries to the LP accrual.
///      - Wash resistance. `maxPrizeBps` is at most half of what the protocol keeps of the pool's LP Rewards and Auto
///        Burn in basis points of a buy, after the pool's integrator rate (`prizeBound` on the kept share), so every
///        prize is at most half the protocol fee its own winning buy left with the protocol recipient, which never
///        returns to the buyer, the pool's liquidity or its integrator: a round trip that buys the crown and exits
///        on another venue (the pool's own family siblings included), or on the pool itself in a later transaction,
///        loses at least half that fee, even for a creator who owns all the liquidity. A sell on the pool
///        voids a lead taken earlier in the same transaction; a buy in a transaction that already sold on the pool,
///        or whose path crosses liquidity added to the pool in the same transaction above the root's tolerance,
///        cannot lead; the executor's legs never lead.
contract HookrRecapture is IHookrAdvisoryFeeCounter, IHookrRulesKnobs, IHookrRecaptureEvents, IHookrRulesEvents {
    using PoolIdLibrary for PoolKey;

    /// @dev HookrRules' storage root (erc7201:hookr.rules): this module runs only in the Rules' context.
    bytes32 private constant SLOT = 0x762913e4bc0f59f7b08c82f07586fa48932548ab5fab99e6db0b09765b4ff900;
    uint256 private constant BPS = 10_000;
    /// @dev Length of `abi.encode(RulesConfig, RulesKnobs)`: the head of a recapture pool's Rules data.
    uint256 private constant RULES_HEAD = 22 * 32;
    bytes32 private constant T_SOLD = keccak256("hookr.rules.transient.koth.sold");
    bytes32 private constant T_PREV = keccak256("hookr.rules.transient.koth.prev");
    bytes32 private constant T_PREV_AMOUNT = keccak256("hookr.rules.transient.koth.prevAmount");

    /// @notice Least share of an arb recapture's post-protocol remainder a pool may credit the trader.
    uint16 public constant MIN_TRADER_BPS = 0;
    /// @notice Most share of an arb recapture's post-protocol remainder a pool may credit the trader.
    uint16 public constant MAX_TRADER_BPS = 5_000;
    /// @notice The trader share the launch wizard and SDK pre-fill.
    uint16 public constant DEFAULT_TRADER_BPS = 2_500;
    /// @notice The LP share the launch wizard and SDK pre-fill with King of the Pool off: the rest.
    uint16 public constant DEFAULT_LP_BPS = 7_500;
    /// @notice Most share of the remainder a King of the Pool pool may put in its pot (RulesConfig.potBps).
    uint16 public constant MAX_POT_BPS = 5_000;
    /// @notice The pot share the wizard pre-fills when the creator turns King of the Pool on. Off by default.
    uint16 public constant DEFAULT_POT_BPS = 2_500;
    /// @notice Shortest King of the Pool epoch.
    uint32 public constant MIN_PERIOD = 1 hours;
    /// @notice Longest King of the Pool epoch.
    uint32 public constant MAX_PERIOD = 30 days;
    /// @notice The epoch the wizard pre-fills.
    uint32 public constant DEFAULT_PERIOD = 1 days;
    /// @notice Least share of the carried pot a closed epoch releases to the LP accrual.
    uint16 public constant MIN_POT_RELEASE_BPS = 2_500;
    /// @notice Most share of the carried pot a closed epoch releases: all of it.
    uint16 public constant MAX_POT_RELEASE_BPS = 10_000;
    /// @notice The release the wizard pre-fills: half the carried pot per closed epoch.
    uint16 public constant DEFAULT_POT_RELEASE_BPS = 5_000;
    /// @notice Least prize ceiling of a King of the Pool pool; the most is the pool's `prizeBound`.
    uint16 public constant MIN_PRIZE_BPS = 1;
    /// @notice The share of the protocol fee a winning buy paid that its prize may reach: half, so taking the crown
    ///         always costs at least the other half.
    uint16 public constant PRIZE_SHARE_OF_FEE_BPS = 5_000;
    /// @notice The protocol's cut of every arb recapture, in basis points of the profit its push reports (the push at
    ///         the pool's frozen partner share, `reportedProfit`): 25%, the same on every pool and independent of its
    ///         protocolShareBps.
    uint16 public constant RECAPTURE_PROTOCOL_BPS = 2_500;
    /// @notice Bounds and default of a recapture pool's releaseBlocks, in L2 blocks (ArbSys.arbBlockNumber(), about 10
    ///         a second on Robinhood Chain while traffic fills every 100 ms block; slower when it does not, which only
    ///         slows the release): about 2 minutes, 24 hours and, by default, an hour.
    uint32 public constant MIN_RELEASE_BLOCKS = 1_200;
    uint32 public constant MAX_RELEASE_BLOCKS = 864_000;
    uint32 public constant DEFAULT_RELEASE_BLOCKS = 36_000;
    /// @dev The L2 blocks a second of wall time (block.timestamp) may add to a release: Robinhood Chain's pace while
    ///      traffic fills every 100 ms block (120 to a 12-second parent block, measured). A flush counts no more L2
    ///      blocks than this pace allows, so blocks that share a timestamp beyond it (a burst of parent-chain inbox
    ///      messages, each its own L2 block) release nothing extra; a chain that runs faster only slows the release.
    uint256 private constant L2_PER_SECOND = 10;
    /// @notice From this many closed epochs in one rollover on, the whole carried pot is released.
    uint256 public constant FULL_RELEASE_EPOCHS = 256;

    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    /// @notice The PoolManager the Rules hold their claims on.
    IPoolManager public immutable poolManager;
    /// @notice Receives the protocol leg of every split.
    address public immutable protocolRecipient;
    /// @notice The one root whose pools the Rules bind; the only caller of `settleRecapture`.
    address public immutable trustedRoot;
    address private immutable self;

    constructor(IPoolManager _manager, address _protocolRecipient, address _trustedRoot) {
        poolManager = _manager;
        protocolRecipient = _protocolRecipient;
        trustedRoot = _trustedRoot;
        self = address(this);
    }

    /// @dev Every entry that touches state runs only as the Rules' DELEGATECALL, never on the module's own address.
    modifier delegated() {
        if (address(this) == self) revert Unauthorized();
        _;
    }

    /// @notice HookrRules.bind forwarded for a recapture pool (Rules data of `abi.encode(RulesConfig, RulesKnobs,
    ///         RecaptureConfig)`), after the Rules checked the caller and the head of `data`: checks the recapture
    ///         config and freezes it. Reachable only through the Rules' own bind, whose selector this shares.
    function bind(PoolKey calldata key, HookrTypes.PoolConfig calldata pc, bytes calldata data) external delegated {
        (HookrTypes.RulesConfig memory c,, HookrTypes.RecaptureConfig memory rc) =
            abi.decode(data, (HookrTypes.RulesConfig, HookrTypes.RulesKnobs, HookrTypes.RecaptureConfig));
        if (keccak256(data[RULES_HEAD:]) != keccak256(abi.encode(rc))) revert InvalidConfig();
        PoolId id = key.toId();
        HookrRules.State storage s = _state();
        // The Rules froze the pool's integrator before forwarding the bind.
        _validate(c, rc, s.integrations[id].bps);
        s.recapture[id] = HookrRules.Recapture(
            pc.quote,
            true,
            rc.traderBps,
            rc.lpBps,
            rc.period,
            rc.maxPrizeBps,
            rc.potReleaseBps,
            rc.minBuyQuote,
            rc.releaseBlocks
        );
        if (c.potBps != 0) s.hills[id].epochStart = uint64(block.timestamp);
    }

    /// @notice HookrRules.settleSwap forwarded on a King of the Pool pool, after the Rules checked the context:
    ///         closes an elapsed epoch and tracks the leader. Reachable only through the Rules' own settleSwap.
    function settleSwap(HookrTypes.SwapContext calldata x, HookrTypes.Settlement calldata z) external delegated {
        HookrRules.State storage s = _state();
        HookrRules.Recapture storage rc = s.recapture[x.id];
        _roll(s, x.id, rc);
        _track(s, x, z, rc);
    }

    /// @notice IHookrLaneRules.settleRecapture: splits `amount` of `currency` claims the root moved to the Rules for
    ///         one arb recapture on pool `key` (see the contract notes). The protocol takes RECAPTURE_PROTOCOL_BPS of
    ///         `reportedProfit` (the profit the push reports at the pool's frozen partner share, as the root read it
    ///         back), at most `amount`; the trader leg is paid on the remainder's part of min(amount, traderBasis) of a
    ///         push in the quote. Root only. Returns `amount`.
    function settleRecapture(
        PoolKey calldata key,
        Currency currency,
        address trader,
        uint256 amount,
        uint256 traderBasis,
        uint256 reportedProfit
    ) external delegated returns (uint256) {
        PoolId id = key.toId();
        HookrRules.State storage s = _state();
        HookrRules.Bound storage b = s.pools[id];
        if (!b.bound) revert UnknownPool();
        if (msg.sender != trustedRoot) revert Unauthorized();
        HookrRules.Recapture storage rc = s.recapture[id];
        if (!rc.on || amount == 0) revert InvalidSettlement();
        uint256 potBps = b.config.potBps;
        if (potBps != 0) _roll(s, id, rc);
        // Both in `currency` (the root takes the profit from the push itself); never above the push.
        uint256 protocol = FullMath.mulDiv(reportedProfit, RECAPTURE_PROTOCOL_BPS, BPS);
        if (protocol > amount) protocol = amount;
        uint256 rest = amount - protocol;
        uint256 toTrader;
        uint256 toPot;
        if (currency == rc.quote) {
            if (trader != address(0) && traderBasis != 0) {
                // The trader's part of the rest: the push it accounts for, net of the protocol cut as the push is
                // (part x rest / amount, at most the rest).
                uint256 part = traderBasis < amount ? traderBasis : amount;
                toTrader = FullMath.mulDiv(part, rest, amount) * rc.traderBps / BPS;
            }
            toPot = rest * potBps / BPS;
        }
        uint256 toLp = rest - toTrader - toPot;
        if (toTrader != 0) s.claims[currency][trader] += toTrader;
        if (protocol != 0) s.claims[currency][protocolRecipient] += protocol;
        if (toPot != 0) {
            HookrRules.Hill storage h = s.hills[id];
            uint256 pot = uint256(h.pot) + toPot;
            if (pot > type(uint128).max) revert InvalidSettlement();
            h.pot = uint128(pot);
        }
        s.liabilities[currency] += amount;
        if (toLp != 0) {
            bool is0 = currency == key.currency0;
            _lpShare(s, id, currency, toLp, is0 || currency == key.currency1, is0);
        }
        emit RecaptureSplit(id, trader, toTrader, toLp, toPot, protocol, currency, reportedProfit);
        return amount;
    }

    /// @notice IHookrLaneRules.flushRecapture: releases the pool's pending LP share accrued before this L2 block,
    ///         each part x min(its age, releaseBlocks) / releaseBlocks, and donates it to the pool's in-range liquidity,
    ///         or moves it to the liquidity owner's accrual when there is none. A part's age is the L2 blocks since its
    ///         release block, capped at L2_PER_SECOND a second of wall time since then plus one second's worth, less
    ///         what earlier flushes in that time already released (`_age`). A flush in a second whose allowance is
    ///         spent releases nothing and moves the release block to its own, so the L2 blocks past the allowance
    ///         are dropped, not deferred. A second flush in one L2 block releases nothing. Root only. Returns whether
    ///         any share is still pending.
    function flushRecapture(PoolKey calldata key) external delegated returns (bool) {
        PoolId id = key.toId();
        HookrRules.State storage s = _state();
        if (!s.pools[id].bound) revert UnknownPool();
        if (msg.sender != trustedRoot) revert Unauthorized();
        HookrRules.Pending storage p = s.pending[id];
        uint256 n = s.recapture[id].releaseBlocks;
        uint256 due0 = p.due0;
        uint256 due1 = p.due1;
        uint256 fresh0 = p.fresh0;
        uint256 fresh1 = p.fresh1;
        if (due0 | due1 | fresh0 | fresh1 == 0) return false;
        // The one clock of every release stamp. A clock that went backwards reverts here, and the root's call fails
        // open with the share still pending.
        uint256 now_ = HookrClock.l2Block();
        // Wall time in L2 blocks: the furthest mark a release may reach by now.
        uint256 pace = block.timestamp * L2_PER_SECOND + L2_PER_SECOND;
        uint256 mark = p.dueMark;
        uint256 age = _age(now_ - p.releasedAt, pace, mark);
        uint256 out0 = _released(due0, age, n);
        uint256 out1 = _released(due1, age, n);
        if (due0 | due1 != 0) mark += age;
        uint256 freshBlock = p.freshBlock;
        if (fresh0 | fresh1 != 0 && freshBlock < now_) {
            // A share is released from the L2 block after the one it accrued in, its wall-time allowance counted from
            // that block's second. Each sum stays within int128 (`_lpShare`).
            uint256 freshMark = uint256(p.freshTime) * L2_PER_SECOND;
            age = _age(now_ - freshBlock, pace, freshMark);
            if (age != 0) {
                out0 += _released(fresh0, age, n);
                out1 += _released(fresh1, age, n);
                (due0, due1, fresh0, fresh1) = (due0 + fresh0, due1 + fresh1, 0, 0);
                (p.fresh0, p.fresh1) = (0, 0);
                if (freshMark + age > mark) mark = freshMark + age;
            }
        }
        if (out0 | out1 != 0) {
            (due0, due1) = (due0 - out0, due1 - out1);
            // Unused wall time is not carried: the mark is at least this second's.
            if (mark < pace - L2_PER_SECOND) mark = pace - L2_PER_SECOND;
            (p.due0, p.due1, p.releasedAt, p.dueMark) = (uint128(due0), uint128(due1), uint64(now_), uint64(mark));
            if (poolManager.getLiquidity(id) == 0) {
                if (out0 != 0) _accrue(s, id, key.currency0, out0);
                if (out1 != 0) _accrue(s, id, key.currency1, out1);
            } else {
                poolManager.donate(key, out0, out1, "");
                if (out0 != 0) {
                    poolManager.burn(address(this), key.currency0.toId(), out0);
                    s.liabilities[key.currency0] -= out0;
                }
                if (out1 != 0) {
                    poolManager.burn(address(this), key.currency1.toId(), out1);
                    s.liabilities[key.currency1] -= out1;
                }
                emit LpShareDonated(id, out0, out1);
            }
        } else if (due0 | due1 != 0 && now_ > p.releasedAt) {
            // The second's allowance is spent (a due share and a later L2 block release something otherwise): the L2
            // blocks past the pace are dropped, not paid in one lump at the next second. The mark is at the pace.
            p.releasedAt = uint64(now_);
        }
        return due0 | due1 | fresh0 | fresh1 != 0;
    }

    /// @dev A part's age for a flush: the `blocks` L2 blocks since its release block, at most the wall-time allowance
    ///      `pace` - `mark` (zero when the mark has reached it). `pace` is L2_PER_SECOND x (block.timestamp + 1) and
    ///      `mark` is L2_PER_SECOND x the second the part's allowance counts from, plus what flushes since then
    ///      released, so the ages all flushes credit from a mark at second t to second t' add up to at most
    ///      L2_PER_SECOND x (t' - t + 1). Parent-chain inbox messages each become an L2 block, and a burst of them
    ///      shares one timestamp: a burst adds at most one second's worth, however many blocks it holds and however
    ///      many flushes run inside it.
    function _age(uint256 blocks, uint256 pace, uint256 mark) private pure returns (uint256) {
        uint256 allowed = pace > mark ? pace - mark : 0;
        return blocks < allowed ? blocks : allowed;
    }

    /// @dev The part of `amount` a flush releases `age` L2 blocks after its release block, over `n` L2 blocks: all of
    ///      it from `n` blocks on, else amount x age / n rounded up, so a remainder under n units drains one unit per
    ///      flush instead of going whole to one L2 block's liquidity. It is above zero whenever `amount` and `age`
    ///      are, which the flush relies on: a merged fresh share is written back to `due` only when something is
    ///      released, and it merges only at a nonzero age. amount < 2^128 and n <= MAX_RELEASE_BLOCKS, so nothing
    ///      overflows.
    function _released(uint256 amount, uint256 age, uint256 n) private pure returns (uint256 out) {
        if (age == 0) return 0;
        if (age >= n) return amount;
        out = (amount * age + n - 1) / n;
    }

    /// @notice IHookrLaneRules.creditSweep: credits `amount` of `currency` claims the root just moved here to the
    ///         protocol recipient. Root only; the Rules' claims must back every liability after it.
    function creditSweep(Currency currency, uint256 amount) external delegated {
        if (msg.sender != trustedRoot) revert Unauthorized();
        HookrRules.State storage s = _state();
        s.claims[currency][protocolRecipient] += amount;
        uint256 liabilities = s.liabilities[currency] + amount;
        s.liabilities[currency] = liabilities;
        if (poolManager.balanceOf(address(this), currency.toId()) < liabilities) revert InvalidSettlement();
        emit ClaimsSwept(currency, amount);
    }

    /// @notice IHookrLaneRules.settleLeg: credits `amount` of the pool's quote, which the root mints to the Rules right
    ///         after, to `recipient`: the advisory take of one executor leg, which runs no rule. It touches no protocol
    ///         share, King of the Pool, guard, anchor, pending share, clock or advisory fee counter. Root only, for a
    ///         bound pool with recapture on. Returns `amount`.
    function settleLeg(PoolId id, address recipient, uint256 amount) external delegated returns (uint256) {
        HookrRules.State storage s = _state();
        if (msg.sender != trustedRoot) revert Unauthorized();
        if (!s.pools[id].bound) revert UnknownPool();
        HookrRules.Recapture storage rc = s.recapture[id];
        if (!rc.on || recipient == address(0) || amount == 0) revert InvalidSettlement();
        Currency quote = rc.quote;
        s.claims[quote][recipient] += amount;
        s.liabilities[quote] += amount;
        emit FeesAllocated(id, quote, 0, 0, 0, recipient, amount);
        return amount;
    }

    /// @inheritdoc IHookrAdvisoryFeeCounter
    /// @dev Served from the Rules' fallback for every pool, with recapture or not; HookrRules.settleSwap writes it.
    function advisoryFeeCredited(PoolId id) external view delegated returns (uint256) {
        return _state().advisoryFees[id];
    }

    /// @inheritdoc IHookrRulesKnobs
    /// @dev Served from the Rules' fallback for every pool. A pool has dynamic fees when its maxFeePips is above its
    ///      base fee, as HookrRules' poolHasDynamicFee reads it.
    function dynamicFeeParameters(PoolId id)
        external
        view
        delegated
        returns (uint256 window, uint256 reset, uint256 carryBps, uint256 moveTicks)
    {
        HookrRules.State storage s = _state();
        HookrRules.Bound storage b = s.pools[id];
        if (b.config.maxFeePips > b.baseFeePips) return _tempo(s.knobs[id]);
    }

    /// @inheritdoc IHookrRulesKnobs
    /// @dev Served from the Rules' fallback for every pool. The stored Knobs are nonzero exactly when the pool bound a
    ///      knob off its default (HookrRules.Knobs).
    function rulesKnobs(PoolId id) external view delegated returns (HookrTypes.RulesKnobs memory knobs) {
        HookrRules.State storage s = _state();
        HookrRules.Bound storage b = s.pools[id];
        HookrRules.Knobs storage stored = s.knobs[id];
        knobs.snipeCurve = stored.snipeCurve;
        if (b.config.maxFeePips > b.baseFeePips) {
            knobs.minDynamicFeeLiquidity = s.dynamicFee[id].minLiquidity;
            (knobs.windowSeconds, knobs.resetSeconds, knobs.carryBps, knobs.moveTicks) = _tempo(stored);
        }
    }

    /// @inheritdoc IHookrRulesKnobs
    function dynamicFeeReachBound()
        external
        view
        delegated
        returns (uint256 maxReach, uint256 maxReserve, uint256 reserveScale)
    {
        return (HookrDynamicFee.MAX_REACH, HookrDynamicFee.MAX_RESERVE, HookrDynamicFee.RESERVE_SCALE);
    }

    /// @dev A dynamic fee pool's tempo: its stored Knobs, or the defaults when it stored none (a dynamic fee pool's
    ///      stored window is never zero).
    function _tempo(HookrRules.Knobs storage k)
        private
        view
        returns (uint16 window, uint16 reset, uint16 carryBps, uint24 moveTicks)
    {
        if (k.windowSeconds == 0) {
            return (
                HookrTypes.DEFAULT_WINDOW_SECONDS,
                HookrTypes.DEFAULT_RESET_SECONDS,
                HookrTypes.DEFAULT_CARRY_BPS,
                HookrTypes.DEFAULT_MOVE_TICKS
            );
        }
        return (k.windowSeconds, k.resetSeconds, k.carryBps, k.moveTicks);
    }

    /// @notice The Hookr minimum pool `id` froze at bind, in pips of a swap: zero for a pool without one, which every
    ///         pool with arb recapture is (HookrRules.bind).
    function minimumFee(PoolId id) external view delegated returns (uint16) {
        return _state().integrations[id].minFeePips;
    }

    /// @notice Closes an elapsed King of the Pool epoch. Permissionless.
    function settleEpoch(PoolId id) external delegated {
        HookrRules.State storage s = _state();
        if (!s.pools[id].bound) revert UnknownPool();
        HookrRules.Recapture storage rc = s.recapture[id];
        if (s.pools[id].config.potBps == 0) revert NotKoth();
        if (block.timestamp < uint256(s.hills[id].epochStart) + rc.period) revert EpochOpen();
        _roll(s, id, rc);
    }

    /// @notice Moves the pool's liquidity owner accrual, in every currency it holds, into `to`'s claims, payable with
    ///         claim, claimTo or claimAsClaims. Only the pool's liquidity owner can call: for a launched pool,
    ///         HookrLauncher, through claimRecapture on the family owner's behalf and with every withdraw or fee
    ///         collection of the member. Returns how many currencies moved; zero when there was nothing.
    /// @dev `to` is never zero, the Rules, their trusted root, the PoolManager or this module: none of them ever calls
    ///      claim, claimTo or claimAsClaims, so a claim credited to one could never be paid.
    function claimPool(PoolId id, address to) external delegated returns (uint256 moved) {
        HookrRules.State storage s = _state();
        HookrRules.Bound storage b = s.pools[id];
        if (!b.bound) revert UnknownPool();
        if (
            msg.sender != b.liquidityOwner || to == address(0) || to == address(this) || to == trustedRoot
                || to == address(poolManager) || to == self
        ) revert Unauthorized();
        Currency[] storage list = s.accruedCurrencies[id];
        mapping(Currency => uint256) storage accrued = s.poolAccrued[id];
        for (uint256 i; i < list.length; ++i) {
            Currency currency = list[i];
            uint256 amount = accrued[currency];
            if (amount == 0) continue;
            accrued[currency] = 0;
            s.claims[currency][to] += amount;
            ++moved;
            emit PoolClaimed(id, to, currency, amount);
        }
    }

    /// @notice IHookrLaneRules.recaptureMode: 0 no recapture, 1 recapture, 2 recapture with King of the Pool.
    function recaptureMode(PoolId id) external view delegated returns (uint256) {
        HookrRules.State storage s = _state();
        if (!s.recapture[id].on) return 0;
        return s.pools[id].config.potBps != 0 ? 2 : 1;
    }

    /// @notice The pool's frozen recapture config and pot share. Zeros for a pool without recapture.
    /// @dev `protocolShareBps` is the pool's whole rule-fee share. The bind checked `maxPrizeBps` against the share Hookr
    ///      keeps after the pool's integrator: to rebuild that ceiling, read the rate with `integration(id)` and call
    ///      `prizeBoundFor(lpBps, burnBps, protocolShareBps, rate)`, not `prizeBound` on this share.
    function recaptureConfig(PoolId id)
        external
        view
        delegated
        returns (HookrTypes.RecaptureConfig memory rc, uint16 potBps, uint16 protocolShareBps)
    {
        HookrRules.State storage s = _state();
        HookrRules.Recapture storage r = s.recapture[id];
        if (!r.on) return (rc, 0, 0);
        rc = HookrTypes.RecaptureConfig(
            true, r.traderBps, r.lpBps, r.period, r.maxPrizeBps, r.potReleaseBps, r.minBuyQuote, r.releaseBlocks
        );
        potBps = s.pools[id].config.potBps;
        protocolShareBps = s.pools[id].config.protocolShareBps;
    }

    /// @notice The pool's King of the Pool epoch: its start and end, the leader, the leading spend and the pot. A
    ///         rollover is due from block.timestamp >= epochEnd.
    function hill(PoolId id)
        external
        view
        delegated
        returns (uint64 epochStart, uint64 epochEnd, address leader, uint128 leaderAmount, uint128 pot)
    {
        HookrRules.State storage s = _state();
        HookrRules.Hill storage h = s.hills[id];
        epochStart = h.epochStart;
        epochEnd = epochStart + s.recapture[id].period;
        (leader, leaderAmount, pot) = (h.leader, h.leaderAmount, h.pot);
    }

    /// @notice The prize the current leader would receive if the epoch closed now, and the pot one closure would
    ///         carry after its release.
    function pendingPrize(PoolId id) external view delegated returns (address leader, uint256 prize, uint256 carried) {
        HookrRules.State storage s = _state();
        HookrRules.Hill storage h = s.hills[id];
        HookrRules.Recapture storage rc = s.recapture[id];
        leader = h.leader;
        carried = h.pot;
        if (leader != address(0)) {
            prize = uint256(h.leaderAmount) * rc.maxPrizeBps / BPS;
            if (prize > carried) prize = carried;
            carried -= prize;
        }
        carried = _carried(carried, rc.potReleaseBps, 1);
    }

    /// @notice The pool's unclaimed liquidity owner accrual in `currency`.
    function poolAccrued(PoolId id, Currency currency) external view delegated returns (uint256) {
        return _state().poolAccrued[id][currency];
    }

    /// @notice Every currency the pool's liquidity owner accrual has held.
    function poolAccruedCurrencies(PoolId id) external view delegated returns (Currency[] memory) {
        return _state().accruedCurrencies[id];
    }

    /// @notice The pool's pending LP donation in its two currencies: `due` is released from the L2 block of the last
    ///         flush, `fresh` accrued in `freshBlock` and is released from the L2 block after it (see flushRecapture).
    ///         `freshBlock` is an L2 height (ArbSys.arbBlockNumber(), equal to eth_blockNumber and a receipt's
    ///         blockNumber), not block.number.
    function pendingDonation(PoolId id)
        external
        view
        delegated
        returns (uint256 due0, uint256 due1, uint256 fresh0, uint256 fresh1, uint256 freshBlock)
    {
        HookrRules.Pending storage p = _state().pending[id];
        return (p.due0, p.due1, p.fresh0, p.fresh1, p.freshBlock);
    }

    /// @notice The recapture config the launch wizard and SDK pre-fill: arb recaptures on, the trader share and the
    ///         rest to the LP accrual, King of the Pool off (a zero RulesConfig.potBps). A creator opts out with
    ///         `on` false.
    function recaptureDefaults() external pure returns (HookrTypes.RecaptureConfig memory rc, uint16 potBps) {
        rc.on = true;
        rc.traderBps = DEFAULT_TRADER_BPS;
        rc.lpBps = DEFAULT_LP_BPS;
        rc.releaseBlocks = DEFAULT_RELEASE_BLOCKS;
        potBps = 0;
    }

    /// @notice The largest maxPrizeBps a King of the Pool pool may freeze with these native rules: half
    ///         (PRIZE_SHARE_OF_FEE_BPS) of the protocol's share of LP Rewards plus its share of Auto Burn, in basis
    ///         points of a buy's gross quote spend, each rounded down to whole basis points, so never more than the
    ///         Rules take: they round the protocol's share up, in pips. Zero means the rules leave no room for a prize.
    ///         A pool with an integrator is bound on the share the protocol keeps after the integrator's rate,
    ///         protocolShareBps x (10,000 - rate) / 10,000 rounded down, which is never more than it keeps: the
    ///         integrator's part is rounded down. The bind checks the pool's maxPrizeBps against that kept share, so a
    ///         tool that pre-fills a pool naming an integrator passes the kept share here, or calls `prizeBoundFor`
    ///         with the rate; this bound on the pool's whole share is refused for it.
    function prizeBound(uint16 lpBps, uint16 burnBps, uint16 protocolShareBps) public pure returns (uint256) {
        return (uint256(lpBps) * protocolShareBps / BPS + uint256(burnBps) * protocolShareBps / BPS)
            * PRIZE_SHARE_OF_FEE_BPS / BPS;
    }

    /// @notice The largest maxPrizeBps the bind admits for a King of the Pool pool with these native rules that names
    ///         an integrator at `integratorBps` (the treasury's rate for it, 0 to 5,000; 0 for no integrator):
    ///         `prizeBound` on the share the protocol keeps after it, protocolShareBps x (10,000 - integratorBps) /
    ///         10,000 rounded down. The same computation the bind runs.
    function prizeBoundFor(uint16 lpBps, uint16 burnBps, uint16 protocolShareBps, uint16 integratorBps)
        public
        pure
        returns (uint256)
    {
        return prizeBound(lpBps, burnBps, _kept(protocolShareBps, integratorBps));
    }

    /// @notice The least protocolShareBps a pool binding now must have: the larger of the Rules' immutable floor
    ///         (`minProtocolShareBps`) and the governed floor of their protocol recipient's treasury, read here as the
    ///         bind reads it. Zero governed floor for a recipient without code. A later floor change moves it for new
    ///         pools only.
    function protocolShareFloor() external view delegated returns (uint16 floor) {
        floor = HookrRules(address(this)).minProtocolShareBps();
        if (protocolRecipient.code.length != 0) {
            (uint16 governed,,) = IHookrTreasury(protocolRecipient).feeTerms(address(0), false, PoolId.wrap(0));
            if (governed > floor) floor = governed;
        }
    }

    /// @dev The share the protocol keeps of `protocolShareBps` after an integrator at `integratorBps` (at most 10,000),
    ///      rounded down: never more than `protocolShareBps`, so it fits 16 bits.
    function _kept(uint16 protocolShareBps, uint256 integratorBps) private pure returns (uint16) {
        return uint16(uint256(protocolShareBps) * (BPS - integratorBps) / BPS);
    }

    /// @dev A recapture pool's config: the split sums to the whole remainder inside its bounds, and King of the Pool
    ///      (a nonzero potBps) takes every knob inside its bounds with a prize at most half the protocol fee its
    ///      winning buy leaves with the protocol recipient, after the pool's integrator rate `integratorBps`
    ///      (PrizeAboveBound beyond it); off, every King of the Pool knob is zero. The Rules check protocolShareBps
    ///      against the effective floor.
    function _validate(HookrTypes.RulesConfig memory c, HookrTypes.RecaptureConfig memory rc, uint256 integratorBps)
        private
        pure
    {
        if (
            !rc.on || rc.traderBps > MAX_TRADER_BPS || c.potBps > MAX_POT_BPS
                || uint256(rc.traderBps) + rc.lpBps + c.potBps != BPS || rc.releaseBlocks < MIN_RELEASE_BLOCKS
                || rc.releaseBlocks > MAX_RELEASE_BLOCKS
        ) revert InvalidConfig();
        if (c.potBps != 0) {
            if (
                rc.period < MIN_PERIOD || rc.period > MAX_PERIOD || rc.maxPrizeBps < MIN_PRIZE_BPS
                    || rc.potReleaseBps < MIN_POT_RELEASE_BPS || rc.potReleaseBps > MAX_POT_RELEASE_BPS
                    || rc.minBuyQuote == 0
            ) revert InvalidConfig();
            // integratorBps <= 5,000 (HookrRules._feeTerms), so the kept share fits 16 bits.
            uint256 bound = prizeBound(c.lpBps, c.burnBps, _kept(c.protocolShareBps, integratorBps));
            if (rc.maxPrizeBps > bound) revert PrizeAboveBound(rc.maxPrizeBps, bound);
        } else if (rc.period != 0 || rc.maxPrizeBps != 0 || rc.potReleaseBps != 0 || rc.minBuyQuote != 0) {
            revert InvalidConfig();
        }
    }

    /// @dev Leader tracking for one settled swap on a King of the Pool pool.
    function _track(
        HookrRules.State storage s,
        HookrTypes.SwapContext calldata x,
        HookrTypes.Settlement calldata z,
        HookrRules.Recapture storage rc
    ) private {
        PoolId id = x.id;
        HookrRules.Hill storage h = s.hills[id];
        if (!x.isBuy) {
            _tput(T_SOLD, id, 1);
            uint256 saved = _tget(T_PREV, id);
            if (saved != 0) {
                _tput(T_PREV, id, 0);
                uint64 epoch = uint64(saved >> 160);
                if (epoch == h.epochStart) {
                    address voided = h.leader;
                    address restored = address(uint160(saved));
                    h.leader = restored;
                    h.leaderAmount = uint128(_tget(T_PREV_AMOUNT, id));
                    emit CrownVoided(id, voided, restored, epoch);
                }
            }
            return;
        }
        uint256 spend = z.quoteBasis;
        if (!x.authenticated || spend < rc.minBuyQuote || spend <= h.leaderAmount || spend > type(uint128).max) {
            return;
        }
        if (_tget(T_SOLD, id) != 0 || IHookrLaneRoot(trustedRoot).sameTxLiquidityOnPath(id)) return;
        uint64 epochStart = h.epochStart;
        if (_tget(T_PREV, id) == 0) {
            // Remember the leader at the start of this transaction; bit 255 marks the word as set.
            _tput(T_PREV, id, (1 << 255) | (uint256(epochStart) << 160) | uint256(uint160(h.leader)));
            _tput(T_PREV_AMOUNT, id, h.leaderAmount);
        }
        h.leader = x.payer;
        h.leaderAmount = uint128(spend);
        emit LeaderChanged(id, x.payer, spend, epochStart);
    }

    /// @dev Closes every elapsed epoch at once, pays the first closed epoch's leader and releases potReleaseBps of
    ///      the carried pot per closed epoch to the pool's LP accrual. Liabilities are unchanged.
    function _roll(HookrRules.State storage s, PoolId id, HookrRules.Recapture storage rc) private {
        HookrRules.Hill storage h = s.hills[id];
        uint256 start = h.epochStart;
        uint256 period = rc.period;
        if (block.timestamp < start + period) return;
        uint256 closed = (block.timestamp - start) / period;
        uint256 pot = h.leader == address(0) ? h.pot : _crown(s, id, h, rc, start);
        uint256 carried = _carried(pot, rc.potReleaseBps, closed);
        if (carried != pot) {
            // The released pot is an LP share in the quote, one of the pool's two currencies.
            _lpShare(s, id, rc.quote, pot - carried, true, s.pools[id].quoteIsCurrency0);
            emit PotReleased(id, pot - carried);
        }
        h.pot = uint128(carried);
        h.epochStart = uint64(start + closed * period);
        emit EpochRolled(id, uint64(start), h.epochStart, carried);
    }

    /// @dev Credits the closed epoch's leader min(pot, leaderAmount * maxPrizeBps / 10,000) and returns the pot left.
    function _crown(
        HookrRules.State storage s,
        PoolId id,
        HookrRules.Hill storage h,
        HookrRules.Recapture storage rc,
        uint256 start
    ) private returns (uint256 pot) {
        pot = h.pot;
        address leader = h.leader;
        uint256 prize = uint256(h.leaderAmount) * rc.maxPrizeBps / BPS;
        if (prize > pot) prize = pot;
        pot -= prize;
        if (prize != 0) s.claims[rc.quote][leader] += prize;
        h.leader = address(0);
        h.leaderAmount = 0;
        emit KingCrowned(id, leader, prize, uint64(start));
    }

    /// @dev The pot left after `closed` releases of `releaseBps` each: pot * (1 - releaseBps / 10,000)^closed,
    ///      rounded down, by square-and-multiply on a 128-bit fixed-point factor. Never above `pot`; exact at 5,000,
    ///      where it is pot >> closed. From FULL_RELEASE_EPOCHS closed epochs on, nothing carries.
    function _carried(uint256 pot, uint256 releaseBps, uint256 closed) private pure returns (uint256) {
        if (closed >= FULL_RELEASE_EPOCHS || releaseBps >= BPS) return 0;
        if (pot == 0 || releaseBps == 0) return pot;
        // factor < 2^128 and kept <= 2^128, so no product below reaches 2^256; pot is at most a uint128.
        unchecked {
            uint256 factor = ((BPS - releaseBps) << 128) / BPS;
            uint256 kept = 1 << 128;
            while (true) {
                if (closed & 1 != 0) kept = kept * factor >> 128;
                closed >>= 1;
                if (closed == 0) break;
                factor = factor * factor >> 128;
            }
            return pot * kept >> 128;
        }
    }

    /// @dev One LP share of `amount` `currency`, already counted in the liabilities: a pending donation when the
    ///         currency is one of the pool's two (`poolCurrency`, `is0` for currency0) and the pool has in-range
    ///         liquidity now, else the liquidity owner's accrual. A share accrued in an earlier L2 block moves to `due`
    ///         first; a share the pending word cannot hold goes to the accrual. A pending donation stamps the L2 height
    ///         (HookrClock), so an unreadable clock reverts the push that brought it, and a King of the Pool rollover
    ///         that releases pot here (`_roll`: the first swap after an epoch ends, or settleEpoch), which then leaves
    ///         the epoch open.
    function _lpShare(
        HookrRules.State storage s,
        PoolId id,
        Currency currency,
        uint256 amount,
        bool poolCurrency,
        bool is0
    ) private {
        if (poolCurrency && poolManager.getLiquidity(id) != 0) {
            HookrRules.Pending storage p = s.pending[id];
            uint256 now_ = HookrClock.l2Block();
            uint256 freshBlock = p.freshBlock;
            if (freshBlock != now_) {
                uint256 due0 = uint256(p.due0) + p.fresh0;
                uint256 due1 = uint256(p.due1) + p.fresh1;
                // Each part stays within int128, as PoolManager.donate takes it.
                if (due0 <= uint128(type(int128).max) && due1 <= uint128(type(int128).max)) {
                    // Everything due is released from the later of the two release blocks, and its wall-time
                    // allowance counted from the later of the two marks, never earlier than either part's (a flush
                    // normally merges the fresh part first, at the swap's start).
                    if (uint256(p.fresh0) | p.fresh1 != 0) {
                        p.releasedAt = uint64(freshBlock);
                        uint256 freshMark = uint256(p.freshTime) * L2_PER_SECOND;
                        if (freshMark > p.dueMark) p.dueMark = uint64(freshMark);
                    }
                    (p.due0, p.due1, p.fresh0, p.fresh1) = (uint128(due0), uint128(due1), 0, 0);
                    (p.freshBlock, p.freshTime) = (uint64(now_), uint64(block.timestamp));
                }
            }
            if (p.freshBlock == now_) {
                uint256 fresh = (is0 ? p.fresh0 : p.fresh1) + amount;
                uint256 due = is0 ? p.due0 : p.due1;
                if (fresh + due <= uint128(type(int128).max)) {
                    if (is0) p.fresh0 = uint128(fresh);
                    else p.fresh1 = uint128(fresh);
                    return;
                }
            }
        }
        _accrue(s, id, currency, amount);
    }

    /// @dev Adds `amount` to the liquidity owner's accrual in `currency`, already counted in the liabilities.
    function _accrue(HookrRules.State storage s, PoolId id, Currency currency, uint256 amount) private {
        mapping(Currency => uint256) storage accrued = s.poolAccrued[id];
        uint256 before = accrued[currency];
        if (before == 0) {
            Currency[] storage list = s.accruedCurrencies[id];
            bool listed;
            for (uint256 i; i < list.length; ++i) {
                if (list[i] == currency) {
                    listed = true;
                    break;
                }
            }
            if (!listed) list.push(currency);
        }
        accrued[currency] = before + amount;
        emit PoolAccrued(id, currency, amount);
    }

    function _tget(bytes32 tag, PoolId id) private view returns (uint256 value) {
        bytes32 slot = keccak256(abi.encode(tag, id));
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    function _tput(bytes32 tag, PoolId id, uint256 value) private {
        bytes32 slot = keccak256(abi.encode(tag, id));
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    function _state() private pure returns (HookrRules.State storage s) {
        assembly ("memory-safe") {
            s.slot := SLOT
        }
    }
}
