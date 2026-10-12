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
import {HookrTypes} from "hookr/types/HookrTypes.sol";
import {HookrReleased} from "hookr/base/HookrReleased.sol";
import {IHookrRoot} from "hookr/interfaces/IHookrRoot.sol";
import {IHookrRules} from "hookr/interfaces/IHookrRules.sol";
import {HookrRouter} from "hookr/periphery/HookrRouter.sol";
import {IHookrRouter} from "hookr/interfaces/IHookrRouter.sol";
import {HookrSettlement} from "hookr/libraries/HookrSettlement.sol";
import {ZapRelayTypes} from "zap-relay/types/ZapRelayTypes.sol";
import {IHookrGatedRelay} from "zap-relay/interfaces/IHookrGatedRelay.sol";
import {IHookrZapVault} from "zap-relay/interfaces/IHookrZapVault.sol";
import {ZapMath} from "zap-relay/libraries/ZapMath.sol";
import {ZapMeshTypes} from "./types/ZapMeshTypes.sol";
import {IZapMeshLeg} from "./interfaces/IZapMeshLeg.sol";
import {IHookrZapMeshVault} from "./interfaces/IHookrZapMeshVault.sol";

/// @title Zap mesh leg
/// @notice One route of a zap mesh. The target's frozen gate lists this leg as a feeder, so it is the only payer, beside
///         the target's other feeders, whose buys the target admits. It holds no quote between calls: the mesh hands it
///         quote for one run, it buys through the pinned HookrRouter (which authenticates the leg as the payer), adds
///         the bought subject as permanent full-range liquidity or sends it to the route's sink, and returns every
///         quote it then holds to the mesh in the same call.
/// @dev No owner, no admin, no rescue, no removal path: every parameter is immutable and read from the mesh when the
///      leg is made. The impact bound is the zap vault's (HookrZapVault): buys stop at a sqrt-price limit impactBps above
///      the price the first buy of the current window found, and pool-wide the reference also honours every other
///      feeder's open window, read from the gate's frozen list. The target Rules credit a partial fill's unused reserved
///      take to this leg (the payer) as a Rules claim; pull() pays it to the mesh, reporting any part that was not a
///      refund so the mesh sets Hookr's share aside on it.
contract ZapMeshLeg is HookrReleased, IZapMeshLeg, IUnlockCallback {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint8 private constant IDLE = 1;
    uint8 private constant BUSY = 2;
    uint8 private constant EXPECT_ADD = 3;
    uint8 private constant IN_CALLBACK = 4;
    uint8 private constant ADD_DONE = 5;

    /// @inheritdoc IZapMeshLeg
    address public immutable mesh;
    /// @inheritdoc IZapMeshLeg
    uint8 public immutable index;
    IPoolManager public immutable poolManager;
    /// @inheritdoc IZapMeshLeg
    address public immutable rules;
    /// @inheritdoc IZapMeshLeg
    address public immutable router;
    /// @inheritdoc IZapMeshLeg
    address public immutable root;
    /// @inheritdoc IZapMeshLeg
    address public immutable gate;
    /// @inheritdoc IZapMeshLeg
    address public immutable sink;
    /// @inheritdoc IZapMeshLeg
    Currency public immutable quote;
    /// @inheritdoc IZapMeshLeg
    Currency public immutable subject;
    /// @inheritdoc IZapMeshLeg
    PoolId public immutable targetId;
    /// @inheritdoc IZapMeshLeg
    uint8 public immutable mode;
    /// @inheritdoc IZapMeshLeg
    uint16 public immutable impactBps;
    /// @inheritdoc IZapMeshLeg
    uint32 public immutable windowBlocks;
    /// @inheritdoc IZapMeshLeg
    uint8 public immutable windowScope;
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
    /// @dev block.number of the buy that opened this leg's current impact window, and the target sqrt price it found.
    uint64 private _anchorBlock;
    uint160 private _anchorSqrtPrice;
    /// @dev Own partial-fill refunds credited back in Rules since the last pull.
    uint128 private _refunds;

    /// @param mesh_ The mesh this leg serves; it must already exist and answer legSpec(index_).
    /// @param index_ The route's position in the mesh.
    constructor(address mesh_, uint8 index_) {
        mesh = mesh_;
        index = index_;
        ZapMeshTypes.LegSpec memory s = IHookrZapMeshVault(mesh_).legSpec(index_);
        root = address(s.target.hooks);
        poolManager = IHookrRoot(root).poolManager();
        rules = s.rules;
        router = s.router;
        gate = s.gate;
        sink = s.sink;
        quote = s.quote;
        bool quoteFirst = Currency.unwrap(s.quote) == Currency.unwrap(s.target.currency0);
        subject = quoteFirst ? s.target.currency1 : s.target.currency0;
        targetId = s.target.toId();
        mode = s.mode;
        impactBps = s.impactBps;
        windowBlocks = s.windowBlocks;
        windowScope = s.windowScope;
        tickLower = TickMath.minUsableTick(s.target.tickSpacing);
        tickUpper = TickMath.maxUsableTick(s.target.tickSpacing);
        _currency0 = s.target.currency0;
        _currency1 = s.target.currency1;
        _fee = s.target.fee;
        _tickSpacing = s.target.tickSpacing;
        _quoteIsCurrency0 = quoteFirst;
    }

    modifier onlyMesh() {
        if (msg.sender != mesh) revert OnlyMesh(msg.sender);
        _;
    }

    /// @inheritdoc IZapMeshLeg
    function targetKey() public view returns (PoolKey memory) {
        return PoolKey(_currency0, _currency1, _fee, _tickSpacing, IHooks(root));
    }

    /// @inheritdoc IZapMeshLeg
    function openAnchor() external view returns (bool open, uint160 sqrtPriceX96) {
        open = _windowOpen();
        if (open) sqrtPriceX96 = _anchorSqrtPrice;
    }

    /// @inheritdoc IZapMeshLeg
    function routeLive() external view returns (bool) {
        return _targetGated();
    }

    /// @inheritdoc IZapMeshLeg
    function impactLeft() external view returns (bool) {
        if (_lock != IDLE || !_targetGated()) return false;
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(targetId);
        return _impactLeft(sqrtPriceX96, _reference(sqrtPriceX96));
    }

    /// @inheritdoc IZapMeshLeg
    function refundCredit() external view returns (uint256) {
        return _refunds;
    }

    /// @inheritdoc IZapMeshLeg
    function positionLiquidity() external view returns (uint128 liquidity) {
        (liquidity,,) = poolManager.getPositionInfo(targetId, address(this), tickLower, tickUpper, bytes32(0));
    }

    /// @inheritdoc IZapMeshLeg
    function pull() external onlyMesh returns (uint256 amount, uint256 extra) {
        if (_lock != IDLE) revert Reentered();
        if (IHookrRules(rules).claimable(quote, address(this)) == 0) return (0, 0);
        _lock = BUSY;
        amount = IHookrRules(rules).claimTo(quote, mesh);
        uint256 refunds = _refunds;
        extra = amount > refunds ? amount - refunds : 0;
        _refunds = 0;
        _lock = IDLE;
    }

    /// @inheritdoc IZapMeshLeg
    /// @dev Order: take the quote, bounded buy to this leg, refund read, add (MODE_BUY_AND_ADD) or send to the sink
    ///      (MODE_BUY), then return every quote held to the mesh. A buy that finds no room in the window reverts, so
    ///      the mesh skips the route and keeps its quote.
    function run(uint256 amount) external payable onlyMesh returns (ZapMeshTypes.LegResult memory r) {
        if (_lock != IDLE) revert Reentered();
        _lock = BUSY;
        if (!_targetGated()) revert TargetNotGated(targetId);
        if (quote.isAddressZero()) {
            if (msg.value != amount) revert BalanceMismatch();
        } else {
            if (msg.value != 0) revert BalanceMismatch();
            uint256 held = HookrSettlement.balance(quote, address(this));
            IERC20(Currency.unwrap(quote)).safeTransferFrom(mesh, address(this), amount);
            if (HookrSettlement.balance(quote, address(this)) != held + amount) revert BalanceMismatch();
        }
        bool add = mode == ZapRelayTypes.MODE_BUY_AND_ADD;
        uint256 claimBefore = IHookrRules(rules).claimable(quote, address(this));
        (r.spent, r.bought) = _buy(add ? amount / 2 : amount);
        // The target Rules credit a partial fill's unused reserved take to this leg (the payer). It is part of the
        // input the router charged, so it never exceeds `spent`; any credit above that is not a refund and is reported
        // as extra when pulled.
        uint256 credited = IHookrRules(rules).claimable(quote, address(this)) - claimBefore;
        r.refund = credited < r.spent ? credited : r.spent;
        // The refund is part of this run's buy input, which fits int128.
        // forge-lint: disable-next-line(unsafe-typecast)
        _refunds += uint128(r.refund);
        if (add) _add(r, amount - r.spent);
        else HookrSettlement.send(subject, sink, r.bought);
        uint256 back = HookrSettlement.balance(quote, address(this));
        if (back != 0) HookrSettlement.send(quote, mesh, back);
        _lock = IDLE;
    }

    /// @notice Settles only the leg's own pending position add. Only the PoolManager, only inside run().
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

    /// @notice Accepts native only mid-run, and only from the PoolManager (adds, claims) or the router (unspent input).
    receive() external payable {
        if (_lock == IDLE || (msg.sender != address(poolManager) && msg.sender != router)) {
            revert UnexpectedNative(msg.sender);
        }
    }

    /// @dev Exact-input subject buy through the pinned router, bounded by the impact window's limit. A partial fill at
    ///      the limit is fine: the router returns the unspent native input, and the target Rules credit their reserved
    ///      take's refund to this leg as a claim.
    function _buy(uint256 amountIn) private returns (uint256 spent, uint256 bought) {
        if (amountIn == 0 || amountIn > uint256(uint128(type(int128).max))) revert AmountOutOfRange(amountIn);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(targetId);
        uint160 ref = _reference(sqrtPriceX96);
        if (!_impactLeft(sqrtPriceX96, ref)) revert ImpactExhausted(ref, sqrtPriceX96);
        if (!_windowOpen()) {
            // block.number fits uint64 for the life of any chain.
            // forge-lint: disable-next-line(unsafe-typecast)
            _anchorBlock = uint64(block.number);
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
        if (
            spent > amountIn || HookrSettlement.balance(quote, address(this)) != quoteBefore - spent
                || HookrSettlement.balance(subject, address(this)) != subjectBefore + bought
        ) revert BalanceMismatch();
    }

    /// @dev Adds every subject held and up to `quoteBudget` quote to the permanent full-range position at the price the
    ///      buy left. One unit of each side is held back so the rounded-up principal never exceeds what is held. Fees
    ///      the position earned since the last add are collected by the same modifyLiquidity: quote fees go back to the
    ///      mesh with the rest of the quote, subject fees stay for the next add.
    function _add(ZapMeshTypes.LegResult memory r, uint256 quoteBudget) private {
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
        r.liquidity = liquidity;
        if (_quoteIsCurrency0) {
            // Signs checked above: principals are <= 0 and fees >= 0.
            // forge-lint: disable-next-line(unsafe-typecast)
            (r.addedQuote, r.addedSubject) = (uint256(-principal0), uint256(-principal1));
            // forge-lint: disable-next-line(unsafe-typecast)
            (r.feesQuote, r.feesSubject) = (uint256(int256(fees0)), uint256(int256(fees1)));
        } else {
            // Signs checked above: principals are <= 0 and fees >= 0.
            // forge-lint: disable-next-line(unsafe-typecast)
            (r.addedQuote, r.addedSubject) = (uint256(-principal1), uint256(-principal0));
            // forge-lint: disable-next-line(unsafe-typecast)
            (r.feesQuote, r.feesSubject) = (uint256(int256(fees1)), uint256(int256(fees0)));
        }
        if (r.addedQuote > quoteBudget || r.addedSubject > subjectHeld) revert BalanceMismatch();
    }

    /// @dev Whether this leg's current impact window is still open.
    function _windowOpen() private view returns (bool) {
        return _anchorSqrtPrice != 0 && block.number < uint256(_anchorBlock) + windowBlocks;
    }

    /// @dev The price this window's limit is measured from: the price the window's first buy found or, if a sell has
    ///      made the subject cheaper since, the current price. Pool-wide, also never above impactBps over any other
    ///      feeder's open anchor (zap vaults and other meshes' legs alike).
    function _reference(uint160 current) private view returns (uint160 ref) {
        ref = current;
        if (_windowOpen()) ref = _cheaper(ref, _anchorSqrtPrice);
        if (windowScope != ZapRelayTypes.WINDOW_POOL_WIDE) return ref;
        (,,, address[] memory feeders) = IHookrGatedRelay(gate).gateOf(root, targetId);
        for (uint256 i; i < feeders.length; ++i) {
            if (feeders[i] == address(this)) continue;
            // Every feeder is a zap vault or a mesh leg an admitted factory made; both answer openAnchor().
            (bool open, uint160 a) = IHookrZapVault(feeders[i]).openAnchor();
            if (open) ref = _cheaper(ref, a);
        }
    }

    /// @dev The sqrt price at which the subject is cheaper: higher when the quote is currency0, lower otherwise.
    function _cheaper(uint160 a, uint160 b) private view returns (uint160) {
        if (_quoteIsCurrency0) return a > b ? a : b;
        return a < b ? a : b;
    }

    /// @dev Whether a buy from `current` can still move the subject price before reaching impactBps above `ref`.
    function _impactLeft(uint160 current, uint160 ref) private view returns (bool) {
        uint160 limit = ZapMath.buyLimit(ref, _quoteIsCurrency0, impactBps);
        return _quoteIsCurrency0 ? limit < current : limit > current;
    }

    /// @dev Pays a negative delta from the leg's own balance or takes a positive one, exactly.
    function _settle(Currency currency, int128 delta) private {
        // delta < 0 here, and int128 negation fits int256.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (delta < 0) HookrSettlement.pay(poolManager, currency, address(this), uint256(-int256(delta)));
        // delta > 0 here.
        // forge-lint: disable-next-line(unsafe-typecast)
        else if (delta > 0) HookrSettlement.take(poolManager, currency, uint256(int256(delta)));
    }

    /// @dev The target is a known pool of this root whose frozen advisory is this route's gate (strict, before-swap),
    ///      whose Rules and quote are this route's, and whose gate lists this leg.
    function _targetGated() private view returns (bool) {
        IHookrRoot r = IHookrRoot(root);
        if (!r.knownPool(targetId)) return false;
        HookrTypes.PoolConfig memory c = r.poolConfig(targetId);
        return c.advisory == gate && c.rules == rules && Currency.unwrap(c.quote) == Currency.unwrap(quote)
            && !c.advisoryFailOpen && c.advisoryPhases & HookrTypes.BEFORE_SWAP != 0
            && IHookrGatedRelay(gate).isFeeder(root, targetId, address(this));
    }
}
