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
import {IHookrRulesState} from "../interfaces/IHookrRulesState.sol";
import {HookrRulesStorage as S} from "../libraries/HookrRulesStorage.sol";
import {HookrDelegateContext} from "../libraries/HookrDelegateContext.sol";
import {HookrClock} from "../libraries/HookrClock.sol";
import {IHookrTreasury} from "../interfaces/IHookrTreasury.sol";
import {IHookrRecaptureEvents} from "../interfaces/IHookrRecaptureEvents.sol";
import {IHookrRulesEvents} from "../interfaces/IHookrRulesEvents.sol";
import {HookrDelegation} from "../libraries/HookrDelegation.sol";

/// @title HookrRecapture
/// @notice Shared recapture split and crown module. PoolManager, protocol recipient and SELF are immutable;
/// every delegated core call carries the trusted root as its final clean word. State domains belong to S.
/// @dev The arb split, wallet-only podium, UTC round anchor, release-clock behavior and same-transaction voiding
/// remain the reviewed v2.1 behavior. Settled swaps only roll/track; slot modules book their charges afterward.
/// Caps freeze in the appended Crown namespace. Funded crowns release nothing to LPs, require a positive cap at
/// most 1,000 bps and Core's irrecoverable-charge bound, and accept only explicitly named open-round top-ups.
/// Their exact protocolRecipient cannot place or receive a podium prize, because it recovers protocol charges.
/// Arb-only crowns retain the accepted optional/no-cap whole-pot behavior and empty-round LP release policy.
/// D45's flush shortcut and lane trims remain off. Explicit arb protocol claims stay included in liabilities.
contract HookrRecapture is IHookrAdvisoryFeeCounter, IHookrRulesKnobs, IHookrRecaptureEvents, IHookrRulesEvents {
    using PoolIdLibrary for PoolKey;

    uint256 private constant BPS = 10_000;
    /// @notice Least share of an arb recapture's post-protocol remainder a pool may credit the trader.
    uint16 public constant MIN_TRADER_BPS = 0;
    /// @notice Most share of an arb recapture's post-protocol remainder a pool may credit the trader.
    uint16 public constant MAX_TRADER_BPS = 5_000;
    /// @notice The trader share the launch wizard and SDK pre-fill.
    uint16 public constant DEFAULT_TRADER_BPS = 2_500;
    /// @notice An owned companion's root did not answer `laneSource()` in one word within LANE_SOURCE_GAS (a revert, no
    ///         answer or a short one), so the bind cannot tell the deployer's opt-out (a zero answer) from a failed read
    ///         and refuses. Raised at bind by `defaultLane` (AL-1), which the core's bind checks call (not delegated),
    ///         so the root reports it inside ModuleCallReverted for the Rules' bind; declared here, not in
    ///         IHookrRecaptureEvents, so the core's sources and bytecode stay as they are.
    error LaneSourceUnanswered();
    /// @dev Gas the R4-1 `laneSource()` read of an owned root gets (`defaultLane`). The read of root v2's LANE_SOURCE
    ///      slot, cold at the bind of a pool without an advisory, costs 9,506 on Monad 143 and 3,439 on Robinhood Chain
    ///      4663 with the root and the lane warm, as at bind, and 19,506 and 5,939 with the lane cold too (AL-1, eth_call
    ///      with state overrides, lanes/fix-al.md): over twice the larger. Still a PUSH2.
    uint256 private constant LANE_SOURCE_GAS = 50_000;
    /// @notice The LP share the launch wizard and SDK pre-fill with King of the Pool off: the rest.
    uint16 public constant DEFAULT_LP_BPS = 7_500;
    /// @notice Most share of the remainder a King of the Pool pool may put in its pot (RulesConfig.potBps): all of it.
    uint16 public constant MAX_POT_BPS = 10_000;
    /// @notice The pot share the wizard pre-fills when the creator turns King of the Pool on. Off by default.
    uint16 public constant DEFAULT_POT_BPS = 2_500;
    /// @notice Historical interface bound only; this module neither parses nor books the Swap Cut.
    uint16 public constant MAX_POT_CUT_BPS = 1_000;
    /// @notice Least nonzero optional arb-only prize cap. Funded caps use MIN_FUNDED_PRIZE_CAP_BPS instead.
    uint32 public constant MIN_PRIZE_CAP_BPS = 1_000;
    /// @notice Most prize cap, in basis points of the first place's winning buy: 10x.
    uint32 public constant MAX_PRIZE_CAP_BPS = 100_000;
    uint32 public constant MIN_FUNDED_PRIZE_CAP_BPS = 1;
    uint32 public constant MAX_FUNDED_PRIZE_CAP_BPS = 1_000;
    /// @notice Historical arb-only prize-cap prefill: 1x the winning buy. Funded settings use the separately
    ///         computed D7 bound, never this default.
    uint32 public constant DEFAULT_PRIZE_CAP_BPS = 10_000;
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
    /// @notice Most minBuyQuote a pot the players or other sources fund (a cut, or no arb share) may freeze, in whole
    ///         units of the quote (10 ** its decimals(), 18 for native ETH): 1,000 ETH, WETH or USDG. Such a pot never
    ///         goes to the LPs, so the threshold keeps it winnable.
    uint256 public constant MAX_MIN_BUY_UNITS = 1_000;
    /// @notice The least maxPrizeBps a King of the Pool pool may freeze: the first place's share of the top-three
    ///         preset. The three presets are PRIZE_WINNER_TAKES_ALL, PRIZE_TOP_TWO and PRIZE_TOP_THREE.
    uint16 public constant MIN_PRIZE_BPS = 5_000;
    /// @notice maxPrizeBps of the one-winner preset: the whole pot to the first place.
    uint16 public constant PRIZE_WINNER_TAKES_ALL = 10_000;
    /// @notice maxPrizeBps of the top-two preset: 70% to the first place and 30% to the second.
    uint16 public constant PRIZE_TOP_TWO = 7_000;
    /// @notice maxPrizeBps of the top-three preset: 50% to the first place, 30% to the second, 20% to the third.
    uint16 public constant PRIZE_TOP_THREE = 5_000;
    /// @notice Kept for the interface; the bind no longer bounds the prize by a fee share.
    uint16 public constant PRIZE_SHARE_OF_FEE_BPS = 5_000;
    /// @dev The most pot addToPot fills to: half of what the pot can hold. Cuts and arb shares can fill the rest; past
    ///      uint128 they clamp (the rest stays Hookr's or the LPs') rather than revert the swap or the push.
    uint256 private constant TOP_UP_POT_CAP = type(uint128).max >> 1;
    /// @notice The protocol's cut of every arb recapture, in basis points of the profit its push reports (the push at
    ///         the pool's frozen partner share, `reportedProfit`): 25%, the same on every pool and independent of its
    ///         protocolShareBps.
    uint16 public constant RECAPTURE_PROTOCOL_BPS = 2_500;
    /// @notice Bounds and default of releaseBlocks in HookrClock ticks: L2 blocks on 4663 (about ten a second while
    ///         traffic fills every 100 ms block; an idle chain only slows release), ten timestamp ticks a second
    ///         elsewhere. The bounds are about 2 minutes, 24 hours and, by default, an hour.
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
    address private immutable self;
    constructor(IPoolManager _manager, address _protocolRecipient) {
        poolManager = _manager;
        protocolRecipient = _protocolRecipient;
        self = address(this);
    }

    /// @dev Every entry that touches state runs only as the Rules' DELEGATECALL, never on the module's own address.
    modifier delegated() {
        _onlyDelegated();
        _;
    }

    function _onlyDelegated() private view {
        if (address(this) == self) revert Unauthorized();
    }

    function _onlyRoot() private view {
        if (msg.sender != HookrDelegateContext.trustedRoot()) revert Unauthorized();
    }

    /// @notice Core-only recapture bind. Core validates canonical original data and the full D7 charge bound;
    /// this module receives the decoded config, arb pot share, cap and funded context explicitly.
    function bindRecapture(PoolKey calldata key, HookrTypes.PoolConfig calldata pc,
        HookrTypes.RecaptureConfig calldata rc, uint16 potBps, uint32 prizeCapBps, bool funded)
        external delegated returns (uint256 crown)
    {
        _onlyRoot();
        PoolId id = key.toId();
        bool crowned = _validate(rc, potBps, pc.quote, prizeCapBps, funded);
        S.State storage s = _state();
        s.recapture[id] = S.Recapture(pc.quote, true, rc.traderBps, rc.lpBps, rc.period,
            rc.maxPrizeBps, rc.potReleaseBps, rc.minBuyQuote, rc.releaseBlocks);
        if (crowned) {
            uint256 period = rc.period;
            uint256 start = block.timestamp - block.timestamp % period;
            if ((start + period - block.timestamp) * 2 < period) start += period;
            s.hills[id].epochStart = uint64(start);
            if (prizeCapBps != 0) S.crown().prizeCaps[id] = prizeCapBps;
            _updateGate(s, id, s.recapture[id]);
            crown = 1;
        }
    }

    /// @notice Roll and track before slot outflows fund the open round. Swap Cut belongs to the slot module;
    /// the preserved return word is always a zero carve. Root only.
    function settleSwap(HookrTypes.SwapContext calldata x, HookrTypes.Settlement calldata z)
        external delegated returns (uint256)
    {
        _onlyRoot();
        S.State storage s = _state();
        if (!s.pools[x.id].bound) revert UnknownPool();
        S.Recapture storage rc = s.recapture[x.id];
        if (rc.period == 0) revert NotKoth();
        _roll(s, x.id, rc);
        _track(s, x, z, rc);
        return 0;
    }

    /// @notice IHookrLaneRules.settleRecapture: splits `amount` of `currency` claims the root moved to the Rules for
    ///         one arb recapture on pool `key` (see the contract notes). The protocol takes RECAPTURE_PROTOCOL_BPS of
    ///         `reportedProfit` (the profit the push reports at the pool's frozen partner share, as the root read it
    ///         back), at most `amount`; the trader leg is paid on the remainder's part of min(amount, traderBasis) of a
    ///         push in the quote, to a key-held trader only (`_isWallet`). Root only. Returns `amount`.
    function settleRecapture(
        PoolKey calldata key,
        Currency currency,
        address trader,
        uint256 amount,
        uint256 traderBasis,
        uint256 reportedProfit
    ) external delegated returns (uint256) {
        PoolId id = key.toId();
        S.State storage s = _state();
        S.Bound storage b = s.pools[id];
        if (!b.bound) revert UnknownPool();
        _onlyRoot();
        S.Recapture storage rc = s.recapture[id];
        if (!rc.on || amount == 0) revert InvalidSettlement();
        // A funded crown (potReleaseBps zero: a block cut funds its pot) never releases its pot to the LPs, so the arb
        // share would sit in it for good: on such a crown the whole remainder is the LPs' (attack round 1, RC-1c).
        // The release is read only when the pool has a pot share: the default pool has none, and reading it would
        // touch a second recapture slot on every push.
        uint256 potBps = b.config.potBps;
        if (potBps != 0) {
            if (rc.potReleaseBps == 0) potBps = 0;
            else _roll(s, id, rc);
        }
        // Both in `currency` (the root takes the profit from the push itself); never above the push.
        uint256 protocol = FullMath.mulDiv(reportedProfit, RECAPTURE_PROTOCOL_BPS, BPS);
        if (protocol > amount) protocol = amount;
        uint256 rest = amount - protocol;
        uint256 toTrader;
        uint256 toPot;
        if (currency == rc.quote) {
            // The trader's leg goes only to a key-held account (`_isWallet`), as a King of the Pool place does: the root
            // names the authenticated payer, which may be a router-calling contract that can never pull its claim, so
            // its leg joins the LP share instead of staying in the core for good (Opus attack round, OPB-1).
            if (trader != address(0) && traderBasis != 0 && _isWallet(trader)) {
                // The trader's part of the rest: the push it accounts for, net of the protocol cut as the push is
                // (part x rest / amount, at most the rest).
                uint256 part = traderBasis < amount ? traderBasis : amount;
                toTrader = FullMath.mulDiv(part, rest, amount) * rc.traderBps / BPS;
            }
            toPot = rest * potBps / BPS;
            if (toPot != 0) {
                // The pot never passes uint128 and the push never reverts for it: what does not fit joins the LP share.
                S.Hill storage h = s.hills[id];
                uint256 pot = h.pot;
                if (toPot > type(uint128).max - pot) toPot = type(uint128).max - pot;
                h.pot = uint128(pot + toPot);
            }
        }
        uint256 toLp = rest - toTrader - toPot;
        if (toTrader != 0) s.claims[currency][trader] += toTrader;
        if (protocol != 0) s.claims[currency][protocolRecipient] += protocol;
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
        S.State storage s = _state();
        if (!s.pools[id].bound) revert UnknownPool();
        _onlyRoot();
        S.Pending storage p = s.pending[id];
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
        // amount is a uint128 pending part; age < n, and n is the frozen uint32 release duration.
        unchecked { out = (amount * age + n - 1) / n; }
    }

    /// @notice IHookrLaneRules.creditSweep: credits `amount` of `currency` claims the root just moved here to the
    ///         protocol recipient. Root only; the Rules' claims must back every liability after it.
    function creditSweep(Currency currency, uint256 amount) external delegated {
        _onlyRoot();
        S.State storage s = _state();
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
        S.State storage s = _state();
        _onlyRoot();
        if (!s.pools[id].bound) revert UnknownPool();
        S.Recapture storage rc = s.recapture[id];
        if (!rc.on || recipient == address(0) || amount == 0) revert InvalidSettlement();
        Currency quote = rc.quote;
        s.claims[quote][recipient] += amount;
        s.liabilities[quote] += amount;
        emit FeesAllocated(id, quote, 0, 0, 0, recipient, amount);
        return amount;
    }

    /// @inheritdoc IHookrAdvisoryFeeCounter
    /// @dev Served from the Rules' fallback for every pool, with recapture or not; S.settleSwap writes it.
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
        S.State storage s = _state();
        S.Bound storage b = s.pools[id];
        if (b.config.maxFeePips > b.baseFeePips) return _tempo(s.knobs[id]);
    }

    /// @inheritdoc IHookrRulesKnobs
    /// @dev Served from the Rules' fallback for every pool. The stored Knobs are nonzero exactly when the pool bound a
    ///      knob off its default (S.Knobs).
    function rulesKnobs(PoolId id) external view delegated returns (HookrTypes.RulesKnobs memory knobs) {
        S.State storage s = _state();
        S.Bound storage b = s.pools[id];
        S.Knobs storage stored = s.knobs[id];
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
    function _tempo(S.Knobs storage k)
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
    ///         pool with arb recapture is (S.bind).
    function minimumFee(PoolId id) external view delegated returns (uint16) {
        return _state().integrations[id].minFeePips;
    }

    /// @notice Closes an elapsed King of the Pool epoch. Permissionless.
    function settleEpoch(PoolId id) external delegated {
        S.State storage s = _state();
        if (!s.pools[id].bound) revert UnknownPool();
        S.Recapture storage rc = s.recapture[id];
        uint256 period = rc.period;
        if (period == 0) revert NotKoth();
        if (block.timestamp < uint256(s.hills[id].epochStart) + period) revert EpochOpen();
        _roll(s, id, rc);
    }

    error EpochMismatch(uint64 expected, uint64 actual);
    error EpochClosed(uint64 epochStart);

    /// @notice Only the named open round of a funded crown accepts a top-up. This entry never rolls to a new round.
    function addToPot(PoolId id, uint64 expectedEpochStart, uint256 amount) external delegated {
        S.State storage s = _state();
        if (!s.pools[id].bound) revert UnknownPool();
        S.Recapture storage rc = s.recapture[id];
        if (rc.period == 0) revert NotKoth();
        if (rc.potReleaseBps != 0) revert InvalidConfig();
        S.Hill storage h = s.hills[id];
        if (expectedEpochStart != h.epochStart) revert EpochMismatch(expectedEpochStart, h.epochStart);
        if (block.timestamp >= uint256(h.epochStart) + rc.period) revert EpochClosed(h.epochStart);
        if (amount == 0) revert InvalidSettlement();
        Currency quote = rc.quote;
        uint256 claimsId = quote.toId();
        uint256 held = poolManager.balanceOf(address(this), claimsId);
        poolManager.transferFrom(msg.sender, address(this), claimsId, amount);
        if (poolManager.balanceOf(address(this), claimsId) != held + amount) revert InvalidSettlement();
        uint256 pot = uint256(h.pot) + amount;
        if (pot > TOP_UP_POT_CAP) revert InvalidSettlement();
        h.pot = uint128(pot);
        s.liabilities[quote] += amount;
        emit PotToppedUp(id, msg.sender, amount, h.epochStart);
    }

    /// @notice Moves the pool's liquidity owner accrual, in every currency it holds, into `to`'s claims, payable with
    ///         claim, claimTo or claimAsClaims. Only the pool's liquidity owner can call: for a launched pool,
    ///         HookrLauncher, through claimRecapture on the family owner's behalf and with every withdraw or fee
    ///         collection of the member. Returns how many currencies moved; zero when there was nothing.
    /// @dev `to` is never zero, the Rules, their trusted root, the PoolManager or this module: none of them ever calls
    ///      claim, claimTo or claimAsClaims, so a claim credited to one could never be paid.
    function claimPool(PoolId id, address to) external delegated returns (uint256 moved) {
        S.State storage s = _state();
        S.Bound storage b = s.pools[id];
        if (!b.bound) revert UnknownPool();
        if (
            msg.sender != b.liquidityOwner || to == address(0) || to == address(this) || to == HookrDelegateContext.trustedRoot()
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

    /// @notice IHookrLaneRules.recaptureMode: 0 no recapture, 1 recapture, 2 recapture with King of the Pool (a nonzero
    ///         period), whatever funds its pot, so the root keeps the same-transaction liquidity ledger the podium
    ///         reads on every King of the Pool pool.
    function recaptureMode(PoolId id) external view delegated returns (uint256) {
        S.Recapture storage rc = _state().recapture[id];
        if (!rc.on) return 0;
        return rc.period != 0 ? 2 : 1;
    }

    /// @notice The pool's frozen recapture config and pot share. Zeros for a pool without recapture.
    /// @dev `protocolShareBps` is the pool's whole rule-fee share. A King of the Pool pool's `maxPrizeBps` is 10,000.
    function recaptureConfig(PoolId id)
        external
        view
        delegated
        returns (HookrTypes.RecaptureConfig memory rc, uint16 potBps, uint16 protocolShareBps)
    {
        S.State storage s = _state();
        S.Recapture storage r = s.recapture[id];
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
        S.State storage s = _state();
        S.Hill storage h = s.hills[id];
        epochStart = h.epochStart;
        epochEnd = epochStart + s.recapture[id].period;
        (leader, leaderAmount, pot) = (h.leader, h.leaderAmount, h.pot);
    }

    /// @notice The prize the current leader would receive if the epoch closed now (its share of the pot, at most the
    ///         pool's prize cap times its buy, zero when it is no longer a wallet), and the pot one closure would carry:
    ///         what the podium is not paid (the shares of the places nobody took or whose holder is no longer a
    ///         wallet, what the prize cap and the rate cap hold back, and the rounding; the whole pot with no leader)
    ///         after one potReleaseBps release, as `_roll` closes a won epoch and an empty one alike.
    function pendingPrize(PoolId id) external view delegated returns (address leader, uint256 prize, uint256 carried) {
        S.State storage s = _state();
        S.Hill storage h = s.hills[id];
        S.Recapture storage rc = s.recapture[id];
        uint256 pot = h.pot;
        leader = h.leader;
        uint256 paid;
        if (leader != address(0)) {
            (uint256 s1, uint256 s2, uint256 s3) = _shares(rc.maxPrizeBps);
            // As the close pays (`_crown`): a holder that is no longer a wallet is paid nothing, its share carries.
            uint256 lead = h.leaderAmount;
            uint256 first = _firstPrize(id, pot, s1, lead);
            bool funded = rc.potReleaseBps == 0;
            if (_eligibleWallet(leader, funded)) prize = first;
            paid = prize;
            if (s2 != 0) {
                S.Podium storage p = _podium(id);
                address a2 = p.second;
                address a3 = p.third;
                if (a2 != address(0) && _eligibleWallet(a2, funded)) paid += _placePrize(pot, s2, first, p.secondAmount, lead);
                if (s3 != 0 && a3 != address(0) && _eligibleWallet(a3, funded)) {
                    paid += _placePrize(pot, s3, first, p.thirdAmount, lead);
                }
            }
        }
        carried = _carried(pot - paid, rc.potReleaseBps, 1);
    }

    /// @notice The pool's podium in the open epoch, first place first: each place's payer (zero while empty), its
    ///         largest qualifying buy in gross quote spend, and the share of the pot the place is paid when the epoch
    ///         closes, in basis points (zero for a place the pool's preset does not pay). A place below the first is
    ///         paid at most the first place's prize x its buy / the first place's buy (see pendingPrize).
    function podium(PoolId id)
        external
        view
        delegated
        returns (address[3] memory accounts, uint256[3] memory amounts, uint16[3] memory sharesBps)
    {
        S.State storage s = _state();
        S.Hill storage h = s.hills[id];
        S.Podium storage p = _podium(id);
        (accounts[0], amounts[0]) = (h.leader, h.leaderAmount);
        (accounts[1], amounts[1]) = (p.second, p.secondAmount);
        (accounts[2], amounts[2]) = (p.third, p.thirdAmount);
        S.Recapture storage rc = s.recapture[id];
        if (rc.period != 0) {
            (uint256 s1, uint256 s2, uint256 s3) = _shares(rc.maxPrizeBps);
            (sharesBps[0], sharesBps[1], sharesBps[2]) = (uint16(s1), uint16(s2), uint16(s3));
        }
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
    ///         `freshBlock` is a HookrClock tick: timestamp x 10 off 4663, or an L2 height there (equal to a receipt's
    ///         blockNumber), not block.number.
    function pendingDonation(PoolId id)
        external
        view
        delegated
        returns (uint256 due0, uint256 due1, uint256 fresh0, uint256 fresh1, uint256 freshBlock)
    {
        S.Pending storage p = _state().pending[id];
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

    /// @notice R4-1 (next core 10-22): the recapture a pool whose Rules data leaves it out binds, all zero for none:
    ///         `recaptureDefaults()` while the lane source's registry lane is open (`activeLaneOf` names an executor).
    ///         The lane source is `root` itself for a core on its own root, and for an owned companion (`companion`)
    ///         root v2's `laneSource()`: the template root, or zero when the deployer opted out (no default). A root
    ///         that does not answer it in one word within LANE_SOURCE_GAS (a revert, no answer or a short one)
    ///         refuses the bind (`LaneSourceUnanswered`, AL-1): a failed read is never taken for the opt-out. A v1
    ///         owned root, which has no `laneSource()`, never binds this core: its Rules are frozen at its deploy. A
    ///         registry that does not answer `activeLaneOf` in four words gives none: the root freezes no lane for it
    ///         either (HookrLane `_freeze` refuses a recapture pool on a closed lane). Read by the core's bind checks
    ///         with a static call, which pass this revert on.
    function defaultLane(address registry, address root, bool companion)
        external
        view
        returns (HookrTypes.RecaptureConfig memory rc)
    {
        bool open;
        bytes4 unanswered = LaneSourceUnanswered.selector;
        assembly ("memory-safe") {
            let source := root
            if companion {
                mstore(0, 0x00fa163a00000000000000000000000000000000000000000000000000000000) // laneSource()
                // The call first: Yul evaluates arguments right to left, so returndatasize() must follow it.
                let ok := staticcall(LANE_SOURCE_GAS, root, 0, 4, 0, 32)
                if iszero(and(ok, eq(returndatasize(), 32))) {
                    mstore(0, unanswered)
                    revert(0, 4)
                }
                source := and(mload(0), 0xffffffffffffffffffffffffffffffffffffffff)
            }
            if source {
                let p := mload(0x40)
                mstore(p, 0xff3d3cf900000000000000000000000000000000000000000000000000000000) // activeLaneOf(address)
                mstore(add(p, 4), source)
                // The call first: Yul evaluates arguments right to left, so returndatasize() must follow it.
                let ok := staticcall(gas(), registry, p, 36, p, 128)
                if and(ok, gt(returndatasize(), 127)) { open := iszero(iszero(and(mload(p), 0xffffffffffffffffffffffffffffffffffffffff))) }
            }
        }
        if (!open) return rc;
        rc.on = true;
        rc.traderBps = DEFAULT_TRADER_BPS;
        rc.lpBps = DEFAULT_LP_BPS;
        rc.releaseBlocks = DEFAULT_RELEASE_BLOCKS;
    }

    /// @notice The release's M-1 prize bound (next core 10-22, NC20): the most an arb-only King of the Pool crown
    ///         pays per unit of its winning buy, in basis points of that buy: half (PRIZE_SHARE_OF_FEE_BPS) of the
    ///         protocol's share of LP Rewards plus its share of Auto Burn, each rounded down to whole basis points.
    ///         Zero means the rules leave no room for a prize. A funded crown is bound by its own prize cap.
    function prizeBound(uint16 lpBps, uint16 burnBps, uint16 protocolShareBps) public pure returns (uint256) {
        return (uint256(lpBps) * protocolShareBps / BPS + uint256(burnBps) * protocolShareBps / BPS)
            * PRIZE_SHARE_OF_FEE_BPS / BPS;
    }

    /// @notice `prizeBound` on the share the protocol keeps after an integrator at `integratorBps` (0 to 5,000):
    ///         protocolShareBps x (10,000 - integratorBps) / 10,000, rounded down. The bound a crown close applies.
    function prizeBoundFor(uint16 lpBps, uint16 burnBps, uint16 protocolShareBps, uint16 integratorBps)
        public
        pure
        returns (uint256)
    {
        return prizeBound(lpBps, burnBps, uint16(uint256(protocolShareBps) * (BPS - integratorBps) / BPS));
    }

    /// @notice The least protocolShareBps a pool binding now must have: the larger of the Rules' immutable floor
    ///         (`minProtocolShareBps`) and the governed floor of their protocol recipient's treasury, read here as the
    ///         bind reads it. Zero governed floor for a recipient without code. A later floor change moves it for new
    ///         pools only.
    function protocolShareFloor() external view delegated returns (uint16 floor) {
        floor = IHookrRulesState(address(this)).minProtocolShareBps();
        if (protocolRecipient.code.length != 0) {
            (uint16 governed,,) = IHookrTreasury(protocolRecipient).feeTerms(address(0), false, PoolId.wrap(0));
            if (governed > floor) floor = governed;
        }
    }

    /// @dev Funded caps are positive and at most 1,000 bps, additionally bounded by Core's irrecoverable charge
    /// calculation. Arb-only crowns preserve their optional old cap and empty-round LP release policy.
    function _validate(HookrTypes.RecaptureConfig memory rc, uint16 potBps, Currency quote,
        uint32 cap, bool funded) private view returns (bool crown)
    {
        if (!rc.on || rc.traderBps > MAX_TRADER_BPS || potBps > MAX_POT_BPS
            || uint256(rc.traderBps) + rc.lpBps + potBps != BPS || rc.releaseBlocks < MIN_RELEASE_BLOCKS
            || rc.releaseBlocks > MAX_RELEASE_BLOCKS) revert InvalidConfig();
        crown = rc.period != 0;
        if (crown) {
            if (rc.period < MIN_PERIOD || rc.period > MAX_PERIOD
                || (rc.maxPrizeBps != PRIZE_WINNER_TAKES_ALL && rc.maxPrizeBps != PRIZE_TOP_TWO
                    && rc.maxPrizeBps != PRIZE_TOP_THREE) || rc.minBuyQuote == 0
                || (funded
                    ? cap < MIN_FUNDED_PRIZE_CAP_BPS || cap > MAX_FUNDED_PRIZE_CAP_BPS
                        || rc.potReleaseBps != 0 || rc.minBuyQuote > MAX_MIN_BUY_UNITS * _unit(quote)
                    : potBps == 0 || (cap != 0 && (cap < MIN_PRIZE_CAP_BPS || cap > MAX_PRIZE_CAP_BPS))
                        || rc.potReleaseBps < MIN_POT_RELEASE_BPS || rc.potReleaseBps > MAX_POT_RELEASE_BPS)
            ) revert InvalidConfig();
        } else if (potBps != 0 || cap != 0 || funded || rc.maxPrizeBps != 0
            || rc.potReleaseBps != 0 || rc.minBuyQuote != 0) revert InvalidConfig();
    }

    /// @dev One whole unit of `quote` in raw units: 10 ** 18 for native ETH, else 10 ** its decimals(). Refuses
    ///      (InvalidConfig) a token that does not answer decimals() with one word of at most 36.
    function _unit(Currency quote) private view returns (uint256) {
        if (quote.isAddressZero()) return 1e18;
        address token = Currency.unwrap(quote);
        uint256 d = 37;
        assembly ("memory-safe") {
            // decimals()
            mstore(0, 0x313ce567)
            let ok := staticcall(gas(), token, 0x1c, 4, 0, 32)
            if and(ok, eq(returndatasize(), 32)) { d := mload(0) }
        }
        if (d > 36) revert InvalidConfig();
        return 10 ** d;
    }

    /// @dev Podium tracking for one settled swap on a King of the Pool pool. A sell restores the podium the pool had
    ///      at the start of the transaction (taken before its first placing buy), so a place taken earlier in the
    ///      transaction is voided. A qualifying buy places its payer by its gross quote spend: a payer holds one place,
    ///      its largest buy; a buy must beat a place strictly to pass it, so an equal later buy ranks below. Only a
    ///      wallet's buy places (`_isWallet`), checked after the cheap refusals, so a buy that could not place anyway
    ///      pays nothing for it; a contract's buy changes nothing and displaces no one.
    function _track(
        S.State storage s,
        HookrTypes.SwapContext calldata x,
        HookrTypes.Settlement calldata z,
        S.Recapture storage rc
    ) private {
        PoolId id = x.id;
        S.Hill storage h = s.hills[id];
        if (!x.isBuy) {
            _tput(S.T_SOLD, id, 1);
            uint256 saved = _tget(S.T_PREV, id);
            if (saved != 0) {
                _tput(S.T_PREV, id, 0);
                uint64 epoch = uint64(saved >> 160);
                if (epoch == h.epochStart) {
                    address voided = h.leader;
                    address restored = address(uint160(saved));
                    h.leader = restored;
                    h.leaderAmount = uint128(_tget(S.T_PREV_AMOUNT, id));
                    uint256 restoredPlaces = _places(rc.maxPrizeBps);
                    if (restoredPlaces > 1) {
                        // Each lower place the void moves is told with PlaceChanged, so an index follows the restore.
                        S.Podium storage p = _podium(id);
                        address a2 = address(uint160(_tget(S.T_PREV2, id)));
                        uint128 m2 = uint128(_tget(S.T_PREV2_AMOUNT, id));
                        if (p.second != a2 || p.secondAmount != m2) {
                            (p.second, p.secondAmount) = (a2, m2);
                            emit PlaceChanged(id, 2, a2, m2, epoch);
                        }
                        if (restoredPlaces > 2) {
                            address a3 = address(uint160(_tget(S.T_PREV3, id)));
                            uint128 m3 = uint128(_tget(S.T_PREV3_AMOUNT, id));
                            if (p.third != a3 || p.thirdAmount != m3) {
                                (p.third, p.thirdAmount) = (a3, m3);
                                emit PlaceChanged(id, 3, a3, m3, epoch);
                            }
                        }
                    }
                    emit CrownVoided(id, voided, restored, epoch);
                    _updateGate(s, id, rc);
                }
            }
            return;
        }
        uint256 spend = z.quoteBasis;
        if (!x.authenticated || spend < rc.minBuyQuote || spend > type(uint128).max) return;
        if (rc.potReleaseBps == 0 && x.payer == protocolRecipient) return;
        uint256 n = _places(rc.maxPrizeBps);
        if (n == 1) {
            // A one-winner pool reads and writes only the Hill, as before the podium; a buy that takes the lead also
            // pays the wallet check.
            if (spend <= h.leaderAmount || !_isWallet(x.payer)) return;
            if (_tget(S.T_SOLD, id) != 0 || IHookrLaneRoot(HookrDelegateContext.trustedRoot()).sameTxLiquidityOnPath(id)) return;
            uint64 start = h.epochStart;
            if (_tget(S.T_PREV, id) == 0) {
                // Remember the leader at the start of this transaction; bit 255 marks the word as set.
                _tput(S.T_PREV, id, (1 << 255) | (uint256(start) << 160) | uint256(uint160(h.leader)));
                _tput(S.T_PREV_AMOUNT, id, h.leaderAmount);
            }
            h.leader = x.payer;
            h.leaderAmount = uint128(spend);
            emit LeaderChanged(id, x.payer, spend, start);
            _updateGate(s, id, rc);
            return;
        }
        // The cheap refusal first: a buy that cannot pass the last place it could take changes nothing.
        S.Podium storage pd = _podium(id);
        address[3] memory acc;
        uint128[3] memory amt;
        (acc[0], amt[0]) = (h.leader, h.leaderAmount);
        (acc[1], amt[1]) = (pd.second, pd.secondAmount);
        // A top-two pool never fills the third place, so it never reads it.
        if (n > 2) (acc[2], amt[2]) = (pd.third, pd.thirdAmount);
        address payer = x.payer;
        uint256 mine = n;
        for (uint256 i; i < n; ++i) {
            if (acc[i] == payer) {
                mine = i;
                break;
            }
        }
        if (mine < n ? spend <= amt[mine] : acc[n - 1] != address(0) && spend <= amt[n - 1]) return;
        if (!_isWallet(payer)) return;
        if (_tget(S.T_SOLD, id) != 0 || IHookrLaneRoot(HookrDelegateContext.trustedRoot()).sameTxLiquidityOnPath(id)) return;
        uint64 epochStart = h.epochStart;
        if (_tget(S.T_PREV, id) == 0) {
            // Remember the podium at the start of this transaction; bit 255 marks the first word as set.
            _tput(S.T_PREV, id, (1 << 255) | (uint256(epochStart) << 160) | uint256(uint160(acc[0])));
            _tput(S.T_PREV_AMOUNT, id, amt[0]);
            _tput(S.T_PREV2, id, uint160(acc[1]));
            _tput(S.T_PREV2_AMOUNT, id, amt[1]);
            if (n > 2) {
                _tput(S.T_PREV3, id, uint160(acc[2]));
                _tput(S.T_PREV3_AMOUNT, id, amt[2]);
            }
        }
        // Copies, not aliases: the places below are compared with these after they move.
        address[3] memory was = [acc[0], acc[1], acc[2]];
        uint128[3] memory wasAmt = [amt[0], amt[1], amt[2]];
        if (mine < n) {
            // The payer leaves its place and is placed again by its larger buy.
            for (uint256 i = mine; i + 1 < n; ++i) {
                (acc[i], amt[i]) = (acc[i + 1], amt[i + 1]);
            }
            (acc[n - 1], amt[n - 1]) = (address(0), 0);
        }
        uint256 pos;
        while (pos < n && acc[pos] != address(0) && spend <= amt[pos]) ++pos;
        for (uint256 i = n - 1; i > pos; --i) {
            (acc[i], amt[i]) = (acc[i - 1], amt[i - 1]);
        }
        (acc[pos], amt[pos]) = (payer, uint128(spend));
        if (acc[0] != was[0] || amt[0] != wasAmt[0]) {
            (h.leader, h.leaderAmount) = (acc[0], amt[0]);
            emit LeaderChanged(id, acc[0], amt[0], epochStart);
        }
        if (acc[1] != was[1] || amt[1] != wasAmt[1]) {
            (pd.second, pd.secondAmount) = (acc[1], amt[1]);
            emit PlaceChanged(id, 2, acc[1], amt[1], epochStart);
        }
        if (n > 2 && (acc[2] != was[2] || amt[2] != wasAmt[2])) {
            (pd.third, pd.thirdAmount) = (acc[2], amt[2]);
            emit PlaceChanged(id, 3, acc[2], amt[2], epochStart);
        }
        _updateGate(s, id, rc);
    }

    /// @dev Closes every elapsed epoch at once. With a leader, the first closed epoch pays each taken place its share
    ///      of the pot; what the places nobody took, the prize caps and the rounding leave carries. Then every closed
    ///      epoch, the won one included, releases potReleaseBps of what carries to the pool's LP accrual (the release's
    ///      M-1 rule): an arb-only crown's capped prize (NC20) leaves most of its pot, and a won epoch that released
    ///      nothing would keep it from the LPs for as long as every epoch has a leader (attack round 1, RC-1). A funded
    ///      crown's potReleaseBps is zero, so its pot always carries whole. Liabilities are unchanged: the pot is already
    ///      counted in them, and each prize becomes its winner's claim.
    function _roll(S.State storage s, PoolId id, S.Recapture storage rc) private {
        S.Hill storage h = s.hills[id];
        uint256 start = h.epochStart;
        uint256 period = rc.period;
        if (block.timestamp < start + period) return;
        uint256 closed = (block.timestamp - start) / period;
        uint256 pot = h.pot;
        uint256 carried = pot;
        if (h.leader != address(0)) carried = pot - _crown(s, id, h, rc, start, pot);
        // At least one epoch closed here (`closed` >= 1).
        uint256 kept = _carried(carried, rc.potReleaseBps, closed);
        if (kept != carried) {
            // The released pot is an LP share in the quote, one of the pool's two currencies.
            _lpShare(s, id, rc.quote, carried - kept, true, s.pools[id].quoteIsCurrency0);
            emit PotReleased(id, carried - kept);
        }
        h.pot = uint128(kept);
        h.epochStart = uint64(start + closed * period);
        _updateGate(s, id, rc);
        emit EpochRolled(id, uint64(start), h.epochStart, kept);
    }

    /// @dev Credits the closed epoch's podium its shares of `pot`, each a claim in the quote, clears the podium and
    ///      returns what it paid. The first place's prize is KingCrowned, at most the prize cap times its buy
    ///      (`_firstPrize`), the others' PlaceCrowned; a place below the first is paid at most at the first place's
    ///      rate (`_placePrize`). Each holder is checked again: one that is no longer a wallet (`_isWallet`) is paid
    ///      nothing and told nothing, as a place nobody took, and its share carries. The other places are paid as if it
    ///      had been paid, at the same first-place rate.
    function _crown(
        S.State storage s,
        PoolId id,
        S.Hill storage h,
        S.Recapture storage rc,
        uint256 start,
        uint256 pot
    ) private returns (uint256 paid) {
        (uint256 s1, uint256 s2, uint256 s3) = _shares(rc.maxPrizeBps);
        Currency quote = rc.quote;
        address leader = h.leader;
        uint256 lead = h.leaderAmount;
        uint256 prize = _firstPrize(id, pot, s1, lead);
        bool funded = rc.potReleaseBps == 0;
        h.leader = address(0);
        h.leaderAmount = 0;
        if (_eligibleWallet(leader, funded)) {
            if (prize != 0) s.claims[quote][leader] += prize;
            paid = prize;
            emit KingCrowned(id, leader, prize, uint64(start));
        }
        if (s2 != 0) {
            S.Podium storage p = _podium(id);
            address a2 = p.second;
            if (a2 != address(0) && _eligibleWallet(a2, funded)) {
                paid += _payPlace(s, quote, id, 2, a2, _placePrize(pot, s2, prize, p.secondAmount, lead), start);
            }
            if (s3 == 0) {
                // A top-two pool: the third place is always empty.
                (p.second, p.secondAmount) = (address(0), 0);
                return paid;
            }
            address a3 = p.third;
            if (a3 != address(0) && _eligibleWallet(a3, funded)) {
                paid += _payPlace(s, quote, id, 3, a3, _placePrize(pot, s3, prize, p.thirdAmount, lead), start);
            }
            delete p.second;
            delete p.third;
            delete p.secondAmount;
            delete p.thirdAmount;
        }
    }

    /// @dev The first place's prize: its `share` of `pot`, at most its frozen Crown-namespace prize cap, in
    ///      basis points, at most MAX_PRIZE_CAP_BPS) x its winning buy `lead` / 10,000 when the pool has one. On an
    ///      arb-only crown (a nonzero potReleaseBps; a funded crown's cap is already at most half the protocol fee its
    ///      buy leaves, HookrRulesChecks.irrecoverableCap) the prize is also at most the release's M-1 bound
    ///      (`prizeBoundFor`) x `lead` / 10,000: half the protocol fee the winning buy left Hookr after the pool's
    ///      integrator, so a crown never pays more than the buy that won it cost (next core 10-22, NC20, kotp-arb
    ///      KA-1). A pool whose rules leave Hookr no fee pays no prize; its pot carries. `lead` is below 2^128, so the
    ///      products cannot overflow.
    function _firstPrize(PoolId id, uint256 pot, uint256 share, uint256 lead)
        private
        view
        returns (uint256 prize)
    {
        // pot/lead are uint128, share is a fixed preset <= BPS, and the namespace cap is uint32.
        unchecked { prize = pot * share / BPS; }
        uint256 cap = S.crown().prizeCaps[id];
        if (cap != 0) {
            uint256 most;
            unchecked { most = lead * cap / BPS; }
            if (most < prize) prize = most;
        }
        S.State storage s = _state();
        if (s.recapture[id].potReleaseBps != 0) {
            S.Bound storage b = s.pools[id];
            HookrTypes.RulesConfig storage c = b.config;
            uint16 integratorBps = b.terms & S.TERMS_INTEGRATOR != 0 ? s.integrations[id].bps : 0;
            uint256 most;
            unchecked { most = lead * prizeBoundFor(c.lpBps, c.burnBps, c.protocolShareBps, integratorBps) / BPS; }
            if (most < prize) prize = most;
        }
    }

    /// @dev The prize of a place below the first: its `share` of `pot`, at most the first place's `first` prize x the
    ///      place's buy `amount` / the first place's buy `lead`, so no place is paid more per unit of quote bought
    ///      than the first. `amount` <= `lead` (the podium is sorted) and `lead` is never zero with a leader.
    function _placePrize(uint256 pot, uint256 share, uint256 first, uint256 amount, uint256 lead)
        private
        pure
        returns (uint256 prize)
    {
        // pot is uint128 and a lower place's fixed share is at most 3,000 bps.
        unchecked { prize = pot * share / BPS; }
        uint256 cap = FullMath.mulDiv(first, amount, lead);
        if (cap < prize) prize = cap;
    }

    /// @dev Credits one taken podium place below the first its prize. Returns what it paid.
    function _payPlace(
        S.State storage s,
        Currency quote,
        PoolId id,
        uint8 place,
        address winner,
        uint256 prize,
        uint256 start
    ) private returns (uint256) {
        if (prize != 0) s.claims[quote][winner] += prize;
        emit PlaceCrowned(id, place, winner, prize, uint64(start));
        return prize;
    }

    /// @dev The shares of the pot, in basis points, that the first, second and third places of a pool freezing
    ///      `maxPrizeBps` are paid; zero for a place its preset does not pay. A pool without King of the Pool has
    ///      maxPrizeBps zero and pays none.
    function _shares(uint16 maxPrizeBps) private pure returns (uint256 s1, uint256 s2, uint256 s3) {
        if (maxPrizeBps == PRIZE_TOP_THREE) return (5_000, 3_000, 2_000);
        if (maxPrizeBps == PRIZE_TOP_TWO) return (7_000, 3_000, 0);
        return (maxPrizeBps, 0, 0);
    }

    /// @dev Whether `account` may hold a King of the Pool place: it has no code (an account held by a key), or its code
    ///      is an EIP-7702 delegation designator (HookrDelegation.isDesignator: exactly 23 bytes, 0xef0100 and the
    ///      delegate), which is still an account held by a key. Why: a prize is a claim only its holder can pull
    ///      (claim, claimTo and claimAsClaims pay the caller's own claim), and the Rules have no owner, sweep or expiry,
    ///      so a holder that can never call them would keep its share for good. The root names the payer as the caller
    ///      of HookrRouter or of the curated Universal Router (its msgSender()), so a swap proxy or smart account that
    ///      calls either one itself is the payer, and such a contract may have no way to call claim. A key-held
    ///      account always has one. A Stylus program (code starting 0xeff0) is not a designator and does not place. A
    ///      contract has no code while its constructor runs, which is why the close checks each place again. A
    ///      constructor that buys and destroys its contract in the same transaction leaves no code and passes: nothing
    ///      on chain tells it from a key-held account. EXTCODESIZE and EXTCODECOPY read the designator itself, not the
    ///      delegate's code. A payer that called the router is warm (100 gas per read); a cold one (a relayed or gated
    ///      buy, a holder at the close) pays 2,600 once.
    function _isWallet(address account) private view returns (bool) {
        return account.code.length == 0 || HookrDelegation.isDesignator(account);
    }

    /// @dev Funded rounds exclude the known exact protocol-charge recoverer even if old/malformed state names it.
    /// Common control of a different wallet and the protocol recipient is unobservable; D7 assumes independence.
    function _eligibleWallet(address account, bool funded) private view returns (bool) {
        return (!funded || account != protocolRecipient) && _isWallet(account);
    }

    /// @dev How many podium places a pool freezing `maxPrizeBps` pays: one, two or three.
    function _places(uint16 maxPrizeBps) private pure returns (uint256) {
        if (maxPrizeBps == PRIZE_TOP_THREE) return 3;
        if (maxPrizeBps == PRIZE_TOP_TWO) return 2;
        return 1;
    }

    /// @dev The current round end and cheapest strict qualifying spend. A filled last place must be outbid.
    /// A uint128-max last place keeps a saturated threshold: an equal max buy conservatively enters the module,
    /// whose existing strict tie check returns without writes. This cannot omit a state-changing call.
    function _updateGate(S.State storage s, PoolId id, S.Recapture storage rc) private {
        S.Hill storage h = s.hills[id];
        uint256 threshold = rc.minBuyQuote;
        uint256 amount;
        address account;
        uint256 n = _places(rc.maxPrizeBps);
        if (n == 1) {
            (account, amount) = (h.leader, h.leaderAmount);
        } else {
            S.Podium storage p = _podium(id);
            if (n == 2) (account, amount) = (p.second, p.secondAmount);
            else (account, amount) = (p.third, p.thirdAmount);
        }
        if (account != address(0)) {
            uint256 strict = amount < type(uint128).max ? amount + 1 : amount;
            if (strict > threshold) threshold = strict;
        }
        uint256 end = uint256(h.epochStart) + rc.period;
        if (end > type(uint64).max) revert InvalidSettlement();
        uint256 gate = S.crownGate(uint64(end), uint128(threshold));
        if (S.crown().gates[id] != gate) S.crown().gates[id] = gate;
    }

    /// @dev The pot left after `closed` releases of `releaseBps` each: pot * (1 - releaseBps / 10,000)^closed,
    ///      rounded down, by square-and-multiply on a 128-bit fixed-point factor. Never above `pot`; exact at 5,000,
    ///      where it is pot >> closed. From FULL_RELEASE_EPOCHS closed epochs on, nothing carries, unless releaseBps is
    ///      zero: then everything does.
    function _carried(uint256 pot, uint256 releaseBps, uint256 closed) private pure returns (uint256) {
        // A pot that never goes to the LPs (potReleaseBps zero: a cut or no arb share funds it) always carries whole.
        if (pot == 0 || releaseBps == 0) return pot;
        if (closed >= FULL_RELEASE_EPOCHS || releaseBps >= BPS) return 0;
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
        S.State storage s,
        PoolId id,
        Currency currency,
        uint256 amount,
        bool poolCurrency,
        bool is0
    ) private {
        if (poolCurrency && poolManager.getLiquidity(id) != 0) {
            S.Pending storage p = s.pending[id];
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
    function _accrue(S.State storage s, PoolId id, Currency currency, uint256 amount) private {
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

    function _state() private pure returns (S.State storage s) {
        return S.rules();
    }

    function _podium(PoolId id) private view returns (S.Podium storage) {
        return S.crown().podiums[id];
    }
}
