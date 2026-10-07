// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {HookrTypes} from "hookr/types/HookrTypes.sol";
import {HookrReleased} from "hookr/base/HookrReleased.sol";
import {IHookrRoot} from "hookr/interfaces/IHookrRoot.sol";
import {IHookrRules} from "hookr/interfaces/IHookrRules.sol";
import {IHookrAdvisory} from "hookr/interfaces/IHookrAdvisory.sol";
import {HookrRouter} from "hookr/periphery/HookrRouter.sol";
import {IHookrRouter} from "hookr/interfaces/IHookrRouter.sol";
import {HookrSettlement} from "hookr/libraries/HookrSettlement.sol";
import {ZapRelayTypes} from "./types/ZapRelayTypes.sol";
import {IHookrZapVault} from "./interfaces/IHookrZapVault.sol";
import {IHookrGatedRelay} from "./interfaces/IHookrGatedRelay.sol";
import {IHookrZapAccrual} from "./interfaces/IHookrZapAccrual.sol";
import {IZapVaultDeployer} from "./interfaces/IZapVaultDeployer.sol";
import {ZapMath} from "./libraries/ZapMath.sol";
import {IZapRulesProtocol} from "./interfaces/IZapRulesProtocol.sol";

/// @title Hookr zap vault
/// @notice One route: the quote cut that source pools credit to this vault in HookrRules is claimed and spent,
///         permissionlessly, on a buy of the gated target pool's subject through the pinned HookrRouter. The router
///         authenticates this vault as the payer, which is the identity the target's HookrGatedRelay admits.
///         MODE_BUY sends every subject to a fixed sink. MODE_BUY_AND_ADD buys with half the budget and adds the bought
///         subject and the other half as permanent full-range liquidity owned by this vault ("swap-and-add in one call").
/// @dev No owner, no admin, no rescue, no removal path: every parameter is immutable. Safety rests on three facts:
///      (1) a zap only buys into a pool whose frozen advisory is this route's gate and lists this vault, so no one but a
///          feeder can raise the target's subject price and a caller cannot front-run the zap with a buy;
///      (2) the route's buys stop at a sqrt-price limit `impactBps` above the price the first zap of the current impact
///          window found (a per-zap reference would let K zaps in one transaction compound the bound to
///          (1 + impact)^K). A window spans `windowBlocks` blocks, a creator knob, so thin liquidity or a liquidity
///          pull before a zap can cost at most that premium per window and per feeder vault (the bound still compounds
///          across windows and across a target's feeders);
///      (3) nothing the caller passes steers the funds: only the reward recipient, paid `rewardBps` of the quote the zap
///          actually deployed (a reward on the whole consumed balance would let repeated partial fills re-collect
///          it on the same unspent quote).
///      With `windowScope` WINDOW_POOL_WIDE the reference also honours every other feeder's
///      open window, read from the gate's frozen list, so a target's feeders share one bound instead of compounding.
///      Hookr's share of the source cuts (`protocolShareBps`, at least the 2,000 bps release floor) is set aside on
///      every claim, excluding the vault's own partial-fill refunds, and paid to the Rules' protocol recipient by the
///      permissionless payProtocol(); a zap never spends it and a failing recipient never blocks a zap.
contract HookrZapVault is HookrReleased, IHookrZapVault, IUnlockCallback {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice Smallest per-window subject-price rise a route may allow (0.01%).
    uint16 public constant MIN_IMPACT_BPS = 1;
    /// @notice Largest per-window subject-price rise a route may allow (20%).
    uint16 public constant MAX_IMPACT_BPS = 2_000;
    /// @notice Suggested per-window subject-price rise for a new route (5%). The app's default; not enforced.
    uint16 public constant DEFAULT_IMPACT_BPS = 500;
    /// @notice Smallest caller reward a route may pay: none.
    uint16 public constant MIN_REWARD_BPS = 0;
    /// @notice Largest caller reward a route may pay (1% of deployed quote).
    uint16 public constant MAX_REWARD_BPS = 100;
    /// @notice Suggested caller reward for a new route (0.5% of deployed quote). The app's default; not enforced.
    uint16 public constant DEFAULT_REWARD_BPS = 50;
    /// @notice Smallest threshold (raw quote units), so half a zap is never zero. Threshold and maxPerZap have no
    ///         on-chain default: they are set in the quote's own units.
    uint128 public constant MIN_THRESHOLD = 1_000;
    /// @notice Shortest impact window: one block (on a Nitro chain, one parent-chain block).
    uint32 public constant MIN_WINDOW_BLOCKS = 1;
    /// @notice Longest impact window: 300 blocks (about an hour of 12-second parent-chain blocks).
    uint32 public constant MAX_WINDOW_BLOCKS = 300;
    /// @notice Suggested impact window for a new route: one block, the reviewed behaviour. The app's default; not
    ///         enforced.
    uint32 public constant DEFAULT_WINDOW_BLOCKS = 1;
    /// @notice Smallest window scope: WINDOW_PER_VAULT.
    uint8 public constant MIN_WINDOW_SCOPE = ZapRelayTypes.WINDOW_PER_VAULT;
    /// @notice Largest window scope: WINDOW_POOL_WIDE.
    uint8 public constant MAX_WINDOW_SCOPE = ZapRelayTypes.WINDOW_POOL_WIDE;
    /// @notice Suggested window scope for a new route: pool-wide. The app's default; not enforced.
    uint8 public constant DEFAULT_WINDOW_SCOPE = ZapRelayTypes.WINDOW_POOL_WIDE;

    uint256 private constant BPS = 10_000;
    uint8 private constant IDLE = 1;
    uint8 private constant BUSY = 2;
    uint8 private constant EXPECT_ADD = 3;
    uint8 private constant IN_CALLBACK = 4;
    uint8 private constant ADD_DONE = 5;

    /// @inheritdoc IHookrZapVault
    address public immutable factory;
    IPoolManager public immutable poolManager;
    /// @inheritdoc IHookrZapVault
    address public immutable rules;
    /// @inheritdoc IHookrZapVault
    address public immutable router;
    /// @inheritdoc IHookrZapVault
    address public immutable root;
    /// @inheritdoc IHookrZapVault
    address public immutable gate;
    /// @inheritdoc IHookrZapVault
    address public immutable sink;
    /// @inheritdoc IHookrZapVault
    Currency public immutable quote;
    /// @inheritdoc IHookrZapVault
    Currency public immutable subject;
    /// @inheritdoc IHookrZapVault
    PoolId public immutable targetId;
    /// @inheritdoc IHookrZapVault
    uint8 public immutable mode;
    /// @inheritdoc IHookrZapVault
    uint16 public immutable impactBps;
    /// @inheritdoc IHookrZapVault
    uint16 public immutable rewardBps;
    /// @inheritdoc IHookrZapVault
    uint128 public immutable threshold;
    /// @inheritdoc IHookrZapVault
    uint128 public immutable maxPerZap;
    /// @inheritdoc IHookrZapVault
    uint32 public immutable windowBlocks;
    /// @inheritdoc IHookrZapVault
    uint8 public immutable windowScope;
    /// @inheritdoc IHookrZapVault
    uint16 public immutable protocolShareBps;
    /// @inheritdoc IHookrZapVault
    address public immutable protocolRecipient;
    /// @notice Lower tick of the permanent full-range position (MODE_BUY_AND_ADD).
    int24 public immutable tickLower;
    /// @notice Upper tick of the permanent full-range position (MODE_BUY_AND_ADD).
    int24 public immutable tickUpper;

    Currency private immutable _currency0;
    Currency private immutable _currency1;
    uint24 private immutable _fee;
    int24 private immutable _tickSpacing;
    bool private immutable _quoteIsCurrency0;

    uint8 private _lock = IDLE;
    /// @dev block.number of the zap that opened this route's current impact window, and the target sqrt price that
    ///      zap found (zero before the first zap). Packed with `_lock` in one slot.
    uint64 private _anchorBlock;
    uint160 private _anchorSqrtPrice;
    /// @dev Own partial-fill refunds credited back in Rules since the last claim (not a cut: no protocol share), and
    ///      quote set aside for protocolRecipient. One slot.
    uint128 private _refunds;
    uint128 private _protocolOwed;

    /// @param r The route. Deployed only through HookrZapAccrual.createVault (by the accrual's ZapVaultDeployer), which
    ///        records the vault for the gate.
    constructor(ZapRelayTypes.Route memory r) {
        factory = IZapVaultDeployer(msg.sender).accrual();
        (IPoolManager manager, address pinnedRouter, bool quoteFirst) = _validate(r);
        poolManager = manager;
        rules = r.rules;
        router = pinnedRouter;
        root = address(r.target.hooks);
        gate = r.gate;
        sink = r.sink;
        quote = r.quote;
        subject = quoteFirst ? r.target.currency1 : r.target.currency0;
        targetId = r.target.toId();
        mode = r.mode;
        impactBps = r.impactBps;
        rewardBps = r.rewardBps;
        threshold = r.threshold;
        maxPerZap = r.maxPerZap;
        windowBlocks = r.windowBlocks;
        windowScope = r.windowScope;
        uint16 share = IHookrZapAccrual(factory).protocolShareBps();
        uint16 floor = IZapRulesProtocol(r.rules).minProtocolShareBps();
        protocolShareBps = share > floor ? share : floor;
        protocolRecipient = IZapRulesProtocol(r.rules).protocolRecipient();
        if (protocolRecipient == address(0) || protocolRecipient == address(this)) revert InvalidRoute(13);
        tickLower = TickMath.minUsableTick(r.target.tickSpacing);
        tickUpper = TickMath.maxUsableTick(r.target.tickSpacing);
        _currency0 = r.target.currency0;
        _currency1 = r.target.currency1;
        _fee = r.target.fee;
        _tickSpacing = r.target.tickSpacing;
        _quoteIsCurrency0 = quoteFirst;
    }

    /// @dev Route checks, run once in the constructor. Codes: 1 missing code; 2 root/Rules/PoolManager mismatch or
    ///      unregistered root; 3 not a Hookr dynamic-fee key; 4 quote not a side of the key; 5 gate schema; 6 router;
    ///      7 sink for the mode; 8 impact; 9 reward; 10 threshold/maxPerZap; 11 window length; 12 window scope; 13 the
    ///      Rules' protocol recipient (checked in the constructor).
    function _validate(ZapRelayTypes.Route memory r)
        private
        view
        returns (IPoolManager manager, address pinnedRouter, bool quoteFirst)
    {
        address rootAddress = address(r.target.hooks);
        if (rootAddress.code.length == 0 || r.rules.code.length == 0 || r.gate.code.length == 0) {
            revert InvalidRoute(1);
        }
        manager = IHookrRoot(rootAddress).poolManager();
        if (
            !IHookrRoot(rootAddress).registry().isRoot(rootAddress) || IHookrRules(r.rules).trustedRoot() != rootAddress
                || address(IHookrRules(r.rules).poolManager()) != address(manager)
        ) revert InvalidRoute(2);
        if (
            r.target.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG || r.target.tickSpacing < TickMath.MIN_TICK_SPACING
                || r.target.tickSpacing > TickMath.MAX_TICK_SPACING
                || Currency.unwrap(r.target.currency0) >= Currency.unwrap(r.target.currency1)
        ) revert InvalidRoute(3);
        quoteFirst = Currency.unwrap(r.quote) == Currency.unwrap(r.target.currency0);
        if (!quoteFirst && Currency.unwrap(r.quote) != Currency.unwrap(r.target.currency1)) revert InvalidRoute(4);
        if (IHookrAdvisory(r.gate).configSchemaHash() != ZapRelayTypes.GATE_SCHEMA) revert InvalidRoute(5);
        pinnedRouter = IHookrRoot(rootAddress).router();
        if (pinnedRouter.code.length == 0) revert InvalidRoute(6);
        if (r.mode == ZapRelayTypes.MODE_BUY) {
            // The router's pinned forwarder is refused too: the router refuses it as a swap recipient, and
            // subject sent to it would sit with whoever sweeps it rather than at a burn or treasury address.
            if (
                r.sink == address(0) || r.sink == address(this) || r.sink == pinnedRouter || r.sink == address(manager)
                    || r.sink == HookrRouter(payable(pinnedRouter)).forwarder()
            ) revert InvalidRoute(7);
        } else if (r.mode != ZapRelayTypes.MODE_BUY_AND_ADD || r.sink != address(0)) {
            revert InvalidRoute(7);
        }
        if (r.impactBps < MIN_IMPACT_BPS || r.impactBps > MAX_IMPACT_BPS) revert InvalidRoute(8);
        if (r.rewardBps > MAX_REWARD_BPS) revert InvalidRoute(9);
        if (r.threshold < MIN_THRESHOLD || (r.maxPerZap != 0 && r.maxPerZap < r.threshold)) revert InvalidRoute(10);
        if (r.windowBlocks < MIN_WINDOW_BLOCKS || r.windowBlocks > MAX_WINDOW_BLOCKS) revert InvalidRoute(11);
        if (r.windowScope > MAX_WINDOW_SCOPE) revert InvalidRoute(12);
    }

    /// @inheritdoc IHookrZapVault
    function targetKey() public view returns (PoolKey memory) {
        return PoolKey(_currency0, _currency1, _fee, _tickSpacing, IHooks(root));
    }

    /// @inheritdoc IHookrZapVault
    function pending() external view returns (uint256 claimable, uint256 idleQuote, uint256 idleSubject) {
        claimable = IHookrRules(rules).claimable(quote, address(this));
        idleQuote = _idle();
        idleSubject = HookrSettlement.balance(subject, address(this));
    }

    /// @inheritdoc IHookrZapVault
    function ready() external view returns (bool) {
        if (_lock != IDLE || !_targetGated()) return false;
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(targetId);
        if (!_impactLeft(sqrtPriceX96, _reference(sqrtPriceX96))) return false;
        return IHookrRules(rules).claimable(quote, address(this)) + _idle() >= threshold;
    }

    /// @inheritdoc IHookrZapVault
    function routeLive() external view returns (bool) {
        return _targetGated();
    }

    /// @inheritdoc IHookrZapVault
    function protocolOwed() external view returns (uint256) {
        return _protocolOwed;
    }

    /// @inheritdoc IHookrZapVault
    function refundCredit() external view returns (uint256) {
        return _refunds;
    }

    /// @inheritdoc IHookrZapVault
    function openAnchor() external view returns (bool open, uint160 sqrtPriceX96) {
        open = _windowOpen();
        if (open) sqrtPriceX96 = _anchorSqrtPrice;
    }

    /// @inheritdoc IHookrZapVault
    /// @dev Pull, not push: a recipient that refuses the transfer fails only this call, never a zap.
    function payProtocol() external returns (uint256 amount) {
        if (_lock != IDLE) revert Reentered();
        amount = _protocolOwed;
        if (amount == 0) return 0;
        _lock = BUSY;
        _protocolOwed = 0;
        HookrSettlement.send(quote, protocolRecipient, amount);
        emit ProtocolPaid(protocolRecipient, amount);
        _lock = IDLE;
    }

    /// @inheritdoc IHookrZapVault
    function positionLiquidity() external view returns (uint128 liquidity) {
        (liquidity,,) = poolManager.getPositionInfo(targetId, address(this), tickLower, tickUpper, bytes32(0));
    }

    /// @inheritdoc IHookrZapVault
    /// @dev Order: target check, threshold, claim, protocol set-aside, cap, reward
    ///      hold-back, bounded buy to this vault, refund read, add (MODE_BUY_AND_ADD) or send to the sink (MODE_BUY),
    ///      reward. The
    ///      reward is rewardBps of the quote the zap deployed (net buy spend plus quote added), never of the unspent
    ///      balance; it goes out last, after every balance check, so a hostile recipient can only fail its own call.
    function zap(address rewardTo) external returns (ZapRelayTypes.ZapResult memory z) {
        if (_lock != IDLE) revert Reentered();
        _lock = BUSY;
        if (rewardBps != 0 && (rewardTo == address(0) || rewardTo == address(this))) {
            revert InvalidRewardRecipient(rewardTo);
        }
        if (!_targetGated()) revert TargetNotGated(targetId);

        uint256 claimable = IHookrRules(rules).claimable(quote, address(this));
        uint256 idle = _idle();
        // The threshold counts the whole claim; Hookr's share comes out of it after the claim.
        if (claimable + idle < threshold) revert BelowThreshold(claimable + idle, threshold);
        if (claimable != 0) {
            uint256 held = HookrSettlement.balance(quote, address(this));
            z.claimed = IHookrRules(rules).claim(quote);
            if (HookrSettlement.balance(quote, address(this)) != held + z.claimed) revert BalanceMismatch();
            // Rules pays the whole claim, so every recorded refund is inside it; the rest is source cuts.
            z.protocolShare = _share(z.claimed);
            _refunds = 0;
            // The share is at most half the claim, a Rules balance of one currency.
            // forge-lint: disable-next-line(unsafe-typecast)
            _protocolOwed += uint128(z.protocolShare);
        }

        uint256 amount = _idle();
        if (maxPerZap != 0 && amount > maxPerZap) amount = maxPerZap;
        z.consumed = amount;
        // Hold back the largest reward this zap could owe: budget * (1 + rewardBps / BPS) <= amount.
        uint256 budget = amount * BPS / (BPS + rewardBps);
        bool add = mode == ZapRelayTypes.MODE_BUY_AND_ADD;
        uint256 claimBefore = IHookrRules(rules).claimable(quote, address(this));
        // The buy always delivers to this vault: a MODE_BUY sink is paid only after the refund is read
        // below, outside the PoolManager unlock, so sink code can no longer credit a source cut mid-buy and have it
        // booked as this vault's refund.
        (z.spent, z.bought) = _buy(add ? budget / 2 : budget);
        // A partial fill's unused reserved take comes back to this vault (the payer) as a Rules claim, not spent.
        // Only the vault can lower its own claim, so this cannot underflow. That refund is the target's reserved take
        // less its fee, and the reserved take is part of the input the router charged, so it never exceeds `spent`:
        // any credit above that is not a refund and stays a source cut that pays the protocol share next claim.
        uint256 credited = IHookrRules(rules).claimable(quote, address(this)) - claimBefore;
        uint256 refund = credited < z.spent ? credited : z.spent;
        // The refund is part of this zap's own buy input, which fits int128.
        // forge-lint: disable-next-line(unsafe-typecast)
        _refunds += uint128(refund);
        if (add) _add(z, budget - z.spent);
        else HookrSettlement.send(subject, sink, z.bought);
        // deployed <= spent + addedQuote <= budget, so the reward never exceeds the quote held back for it.
        uint256 deployed = (z.spent > refund ? z.spent - refund : 0) + z.addedQuote;
        z.reward = deployed * rewardBps / BPS;
        if (z.reward != 0) HookrSettlement.send(quote, rewardTo, z.reward);

        emit Zapped(msg.sender, rewardTo, z);
        _lock = IDLE;
    }

    /// @notice Settles only the vault's own pending position add. Only the PoolManager, only inside zap().
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || _lock != EXPECT_ADD) revert InvalidCallback();
        _lock = IN_CALLBACK;
        uint128 liquidity = abi.decode(data, (uint128));
        (BalanceDelta delta, BalanceDelta fees) = poolManager.modifyLiquidity(
            targetKey(), ModifyLiquidityParams(tickLower, tickUpper, int256(uint256(liquidity)), bytes32(0)), ""
        );
        _settle(_currency0, delta.amount0());
        _settle(_currency1, delta.amount1());
        _lock = ADD_DONE;
        return abi.encode(
            int256(delta.amount0()) - fees.amount0(),
            int256(delta.amount1()) - fees.amount1(),
            fees.amount0(),
            fees.amount1()
        );
    }

    /// @notice Accepts native only from the PoolManager (claims, adds) and the router (unspent input, native subject
    ///         bought) mid-zap.
    receive() external payable {
        if (_lock == IDLE || (msg.sender != address(poolManager) && msg.sender != router)) {
            revert UnexpectedNative(msg.sender);
        }
    }

    /// @dev Exact-input subject buy through the pinned router, bounded by the impact window's limit. A partial fill at
    ///      the limit is fine: the router returns the unspent native input, and the target Rules credit their
    ///      reserved-take refund to this vault (the authenticated payer) as a claim the next zap collects.
    ///      The subject always comes to this vault; zap() forwards a MODE_BUY buy to the sink afterwards.
    function _buy(uint256 amountIn) private returns (uint256 spent, uint256 bought) {
        if (amountIn == 0 || amountIn > uint256(uint128(type(int128).max))) revert AmountOutOfRange(amountIn);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(targetId);
        uint160 ref = _reference(sqrtPriceX96);
        if (!_impactLeft(sqrtPriceX96, ref)) revert ImpactExhausted(ref, sqrtPriceX96);
        if (!_windowOpen()) {
            // block.number fits uint64 for the life of any chain.
            // forge-lint: disable-next-line(unsafe-typecast)
            _anchorBlock = uint64(block.number);
            // Per vault, ref is the current price here; pool-wide it may be another feeder's cheaper open anchor, which
            // this window then keeps for its whole length.
            _anchorSqrtPrice = ref;
        }
        IHookrRouter.Swap memory s = IHookrRouter.Swap({
            key: targetKey(),
            zeroForOne: _quoteIsCurrency0,
            // amountIn <= int128 max, checked above.
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int128(int256(amountIn)),
            amountBound: 1,
            sqrtPriceLimitX96: ZapMath.buyLimit(ref, _quoteIsCurrency0, impactBps),
            recipient: address(this),
            deadline: block.timestamp
        });
        uint256 quoteBefore = HookrSettlement.balance(quote, address(this));
        uint256 subjectBefore = HookrSettlement.balance(subject, address(this));
        if (quote.isAddressZero()) {
            (spent, bought) = HookrRouter(payable(router)).swap{value: amountIn}(s, address(0), new uint256[](0));
        } else {
            IERC20(Currency.unwrap(quote)).forceApprove(router, amountIn);
            (spent, bought) = HookrRouter(payable(router)).swap(s, address(0), new uint256[](0));
            IERC20(Currency.unwrap(quote)).forceApprove(router, 0);
        }
        // The target Rules' Auto Burn goes to 0xdEaD inside the swap, never to this vault, so the delivery is exact.
        if (
            spent > amountIn || HookrSettlement.balance(quote, address(this)) != quoteBefore - spent
                || HookrSettlement.balance(subject, address(this)) != subjectBefore + bought
        ) revert BalanceMismatch();
    }

    /// @dev Adds every idle subject and up to `quoteBudget` quote to the permanent full-range position at the price the
    ///      buy left. One unit of each side is held back so the rounded-up principal never exceeds what is held.
    ///      Fees the position earned since the last add are collected by the same modifyLiquidity and stay idle.
    function _add(ZapRelayTypes.ZapResult memory z, uint256 quoteBudget) private {
        uint256 subjectHeld = HookrSettlement.balance(subject, address(this));
        if (quoteBudget <= 1 || subjectHeld <= 1) return;
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(targetId);
        (uint256 amount0, uint256 amount1) =
            _quoteIsCurrency0 ? (quoteBudget - 1, subjectHeld - 1) : (subjectHeld - 1, quoteBudget - 1);
        uint128 liquidity = ZapMath.liquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );
        if (liquidity == 0) return;
        _lock = EXPECT_ADD;
        bytes memory out = poolManager.unlock(abi.encode(liquidity));
        if (_lock != ADD_DONE) revert InvalidCallback();
        _lock = BUSY;
        (int256 principal0, int256 principal1, int128 fees0, int128 fees1) =
            abi.decode(out, (int256, int256, int128, int128));
        if (principal0 > 0 || principal1 > 0 || fees0 < 0 || fees1 < 0) revert BalanceMismatch();
        z.liquidity = liquidity;
        if (_quoteIsCurrency0) {
            // Signs checked above: principals are <= 0 and fees >= 0.
            // forge-lint: disable-next-line(unsafe-typecast)
            (z.addedQuote, z.addedSubject) = (uint256(-principal0), uint256(-principal1));
            // forge-lint: disable-next-line(unsafe-typecast)
            (z.feesQuote, z.feesSubject) = (uint256(int256(fees0)), uint256(int256(fees1)));
        } else {
            // Signs checked above: principals are <= 0 and fees >= 0.
            // forge-lint: disable-next-line(unsafe-typecast)
            (z.addedQuote, z.addedSubject) = (uint256(-principal1), uint256(-principal0));
            // forge-lint: disable-next-line(unsafe-typecast)
            (z.feesQuote, z.feesSubject) = (uint256(int256(fees1)), uint256(int256(fees0)));
        }
        if (z.addedQuote > quoteBudget || z.addedSubject > subjectHeld) revert BalanceMismatch();
    }

    /// @dev Whether this route's current impact window is still open: a zap opened it at `_anchorBlock` and it spans
    ///      that block and the next windowBlocks - 1. On a Nitro chain block.number is the parent-chain height, so a
    ///      one-block window spans every L2 block of that parent block.
    function _windowOpen() private view returns (bool) {
        return _anchorSqrtPrice != 0 && block.number < uint256(_anchorBlock) + windowBlocks;
    }

    /// @dev The price this window's impact limit is measured from: the price the window's first zap found or, if a
    ///      sell has made the subject cheaper since, the current price. Either way the limit is never above impactBps
    ///      over the first zap's price. The first zap of a window measures from the current price.
    ///      Pool-wide, the reference is also never above impactBps over any other feeder's open anchor.
    function _reference(uint160 current) private view returns (uint160 ref) {
        ref = current;
        if (_windowOpen()) ref = _cheaper(ref, _anchorSqrtPrice);
        if (windowScope != ZapRelayTypes.WINDOW_POOL_WIDE) return ref;
        (,,, address[] memory feeders) = IHookrGatedRelay(gate).gateOf(root, targetId);
        for (uint256 i; i < feeders.length; ++i) {
            if (feeders[i] == address(this)) continue;
            // Every feeder is a vault the admitted accrual created (the gate checked vaultRecord at bind).
            (bool open, uint160 a) = IHookrZapVault(feeders[i]).openAnchor();
            if (open) ref = _cheaper(ref, a);
        }
    }

    /// @dev The sqrt price at which the subject is cheaper: higher when the quote is currency0, lower otherwise.
    function _cheaper(uint160 a, uint160 b) private view returns (uint160) {
        if (_quoteIsCurrency0) return a > b ? a : b;
        return a < b ? a : b;
    }

    /// @dev Quote the vault holds that a zap may spend: its balance less the protocol's set-aside.
    function _idle() private view returns (uint256) {
        return HookrSettlement.balance(quote, address(this)) - _protocolOwed;
    }

    /// @dev Hookr's share of a claim of `claimed`: protocolShareBps of the part that is not the vault's own refunds.
    function _share(uint256 claimed) private view returns (uint256) {
        uint256 refunds = _refunds;
        return claimed > refunds ? (claimed - refunds) * protocolShareBps / BPS : 0;
    }

    /// @dev Whether a buy from `current` can still move the subject price before reaching impactBps above `ref`.
    function _impactLeft(uint160 current, uint160 ref) private view returns (bool) {
        uint160 limit = ZapMath.buyLimit(ref, _quoteIsCurrency0, impactBps);
        return _quoteIsCurrency0 ? limit < current : limit > current;
    }

    /// @dev Pays a negative delta from the vault's own balance or takes a positive one, exactly.
    function _settle(Currency currency, int128 delta) private {
        // delta < 0 here, and int128 negation fits int256.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (delta < 0) HookrSettlement.pay(poolManager, currency, address(this), uint256(-int256(delta)));
        // delta > 0 here.
        // forge-lint: disable-next-line(unsafe-typecast)
        else if (delta > 0) HookrSettlement.take(poolManager, currency, uint256(int256(delta)));
    }

    /// @dev The target is a known pool of this root whose frozen advisory is this route's gate (strict, before-swap),
    ///      whose Rules and quote are this route's, and whose gate lists this vault. Pool configs are frozen at
    ///      creation and the advisory was registry-admitted by code hash then, so this is a view over frozen state.
    function _targetGated() private view returns (bool) {
        IHookrRoot r = IHookrRoot(root);
        if (!r.knownPool(targetId)) return false;
        HookrTypes.PoolConfig memory c = r.poolConfig(targetId);
        return c.advisory == gate && c.rules == rules && Currency.unwrap(c.quote) == Currency.unwrap(quote)
            && !c.advisoryFailOpen && c.advisoryPhases & HookrTypes.BEFORE_SWAP != 0
            && IHookrGatedRelay(gate).isFeeder(root, targetId, address(this));
    }
}
