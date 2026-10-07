// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHookrRegistry} from "../interfaces/IHookrRegistry.sol";
import {IHookrRoot} from "../interfaces/IHookrRoot.sol";
import {IHookrRootRoute} from "../interfaces/IHookrRootRoute.sol";
import {IHookrRouter} from "../interfaces/IHookrRouter.sol";
import {IHookrSwapGate} from "../interfaces/IHookrSwapGate.sol";
import {IHookrFamilyRouter} from "../interfaces/IHookrFamilyRouter.sol";
import {IHookrLauncherView} from "../interfaces/IHookrLauncherView.sol";
import {IPermit2Signature} from "../interfaces/external/IPermit2Signature.sol";
import {IPermit2Transfer} from "../interfaces/external/IPermit2Transfer.sol";
import {HookrSettlement} from "../libraries/HookrSettlement.sol";
import {HookrReleased} from "../base/HookrReleased.sol";

/// @title HookrFamilyRouter
/// @notice Best-route family mode for Multi-pool launch: one trade split across the pools of a HookrLauncher family,
///         each leg's minimum and the total minimum checked on chain, all legs or none.
/// @dev Holds nothing between trades. During a trade it holds the caller's input, and on a leg that converts, the
///      member quote between its two swaps, and pays every leg's output to the recipient; every balance it touched ends
///      where it started. Every Hookr swap runs through HookrRouter.swapGated with this router as funder and gate; a
///      hookless reference pool is swapped in this router's own PoolManager unlock.
contract HookrFamilyRouter is HookrReleased, IHookrFamilyRouter, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    /// @dev The most legs a trade takes: a family has at most eight members, each named once.
    uint256 private constant MAX_LEGS = 8;

    /// @inheritdoc IHookrFamilyRouter
    IHookrRouter public immutable router;
    /// @inheritdoc IHookrFamilyRouter
    IHookrLauncherView public immutable launcher;
    /// @inheritdoc IHookrFamilyRouter
    IPoolManager public immutable poolManager;
    /// @inheritdoc IHookrFamilyRouter
    address public immutable permit2;
    /// @dev The router's registry, whose roots make a reference pool a Hookr pool.
    IHookrRegistry private immutable _registry;

    /// @dev The caller of the running trade; zero when idle. The identity this router vouches for.
    address private transient _trader;
    /// @dev The gated swap this router vouches for next: keccak256 of its key, direction and amount; zero once used.
    bytes32 private transient _expected;
    /// @dev keccak256 of the conversion this router's own unlock may run next; zero once used.
    bytes32 private transient _pending;

    /// @dev A trade's checked shape.
    struct Plan {
        bool buy;
        Currency subject;
        uint256 total;
        Currency[] quotes;
        bool[] converts;
    }

    /// @param router_ HookrRouter, whose registry and PoolManager this router uses.
    /// @param launcher_ HookrLauncher, whose families this router trades.
    /// @param permit2_ Permit2, for a trade's signature transfer.
    constructor(IHookrRouter router_, IHookrLauncherView launcher_, address permit2_) {
        if (address(router_).code.length == 0 || address(launcher_).code.length == 0 || permit2_.code.length == 0) {
            revert InvalidTrade();
        }
        IHookrRegistry registry_ = router_.registry();
        IPoolManager manager = registry_.poolManager();
        if (address(manager).code.length == 0) revert InvalidTrade();
        router = router_;
        launcher = launcher_;
        poolManager = manager;
        permit2 = permit2_;
        _registry = registry_;
    }

    /// @inheritdoc IHookrFamilyRouter
    function trade(FamilyTrade calldata request, bytes calldata permit)
        external
        payable
        returns (uint256 amountIn, uint256 amountOut)
    {
        if (_trader != address(0)) revert Reentered();
        _trader = msg.sender;
        Plan memory plan = _plan(request);
        amountIn = plan.total;
        Currency[] memory touched = _touched(request, plan);
        uint256[] memory before = new uint256[](touched.length);
        for (uint256 i; i < touched.length; ++i) {
            before[i] = HookrSettlement.balance(touched[i], address(this));
        }
        // The call's value is already in this router's balance; the trade must spend it whole.
        if (Currency.unwrap(request.input) == address(0)) before[0] -= msg.value;
        _collect(request.input, amountIn, permit);
        uint256 held;
        for (uint256 i; i < request.legs.length; ++i) {
            (uint256 out, uint256 kept) = _leg(request, plan, i);
            Leg calldata leg = request.legs[i];
            if (out < leg.minOut) revert LegBelowMinimum(i, out, leg.minOut);
            amountOut += out;
            held += kept;
            emit FamilyLeg(
                request.familyId,
                leg.key.toId(),
                plan.converts[i] ? leg.conversion.toId() : PoolId.wrap(bytes32(0)),
                leg.amountIn,
                out
            );
        }
        if (amountOut < request.minTotalOut) revert TotalBelowMinimum(amountOut, request.minTotalOut);
        HookrSettlement.send(request.output, request.recipient, held);
        for (uint256 i; i < touched.length; ++i) {
            if (HookrSettlement.balance(touched[i], address(this)) != before[i]) revert BalanceChanged(touched[i]);
        }
        _trader = address(0);
        emit FamilyTraded(
            request.familyId, msg.sender, request.recipient, request.input, request.output, amountIn, amountOut
        );
    }

    /// @inheritdoc IHookrSwapGate
    /// @dev Vouches only for the swap this router itself asked HookrRouter for, in its running trade, with the trader
    ///      as payer; the vouch is spent by this call.
    function beforeUnlock(
        address caller,
        address payer,
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        bytes calldata
    ) external returns (bytes4) {
        bytes32 expected = _expected;
        if (
            msg.sender != address(router) || caller != address(this) || payer != _trader || expected == bytes32(0)
                || keccak256(abi.encode(key, zeroForOne, amountSpecified)) != expected
        ) revert InvalidCallback();
        _expected = bytes32(0);
        return IHookrSwapGate.beforeUnlock.selector;
    }

    /// @inheritdoc IUnlockCallback
    /// @notice Runs only the conversion this router committed to: an exact-input swap on a hookless reference pool that
    ///         uses all of its input, settled from this router's balance, its output taken here.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || _trader == address(0) || keccak256(data) != _pending) {
            revert InvalidCallback();
        }
        _pending = bytes32(0);
        (PoolKey memory key, bool zeroForOne, uint256 amount, uint256 leg) =
            abi.decode(data, (PoolKey, bool, uint256, uint256));
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams(
                zeroForOne, -int256(amount), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            ""
        );
        (int128 inDelta, int128 outDelta) =
            zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        uint256 used = inDelta < 0 ? uint256(-int256(inDelta)) : 0;
        if (used != amount) revert LegPartiallyFilled(leg, used, amount);
        if (outDelta <= 0) revert InvalidTrade();
        uint256 out = uint256(int256(outDelta));
        HookrSettlement.pay(poolManager, zeroForOne ? key.currency0 : key.currency1, address(this), amount);
        HookrSettlement.take(poolManager, zeroForOne ? key.currency1 : key.currency0, out);
        return abi.encode(out);
    }

    /// @inheritdoc IHookrFamilyRouter
    function sweep(Currency currency, address to) external returns (uint256 amount) {
        if (_trader != address(0)) revert Reentered();
        if (to == address(0) || to == address(this)) revert InvalidTrade();
        _trader = address(this);
        amount = HookrSettlement.balance(currency, address(this));
        HookrSettlement.send(currency, to, amount);
        _trader = address(0);
        emit Swept(currency, to, amount);
    }

    /// @dev Native arrives only during a trade: a conversion's output from the PoolManager, a converting sell leg's
    ///      native member output from HookrRouter before its conversion, or HookrRouter's refund of a partial fill,
    ///      which the trade then refuses.
    receive() external payable {
        if (_trader == address(0) || (msg.sender != address(poolManager) && msg.sender != address(router))) {
            revert InvalidCallback();
        }
    }

    /// @dev Checks the trade's shape and every leg: the family, the direction, each member once, each member's quote
    ///      against the trade's own currency and the leg's reference pool. Returns the direction, the subject, the sum
    ///      of the inputs and each leg's member quote and whether it converts.
    function _plan(FamilyTrade calldata request) private view returns (Plan memory plan) {
        uint256 count = request.legs.length;
        address recipient = request.recipient;
        // A zero family id is refused: every pool the launcher did not launch reads as family zero.
        if (
            request.familyId == bytes32(0) || count == 0 || count > MAX_LEGS || block.timestamp > request.deadline
                || Currency.unwrap(request.input) == Currency.unwrap(request.output) || recipient == address(0)
                || recipient == address(this) || recipient == address(router) || recipient == address(poolManager)
        ) revert InvalidTrade();
        plan.quotes = new Currency[](count);
        plan.converts = new bool[](count);
        PoolId[] memory ids = new PoolId[](count);
        for (uint256 i; i < count; ++i) {
            Leg calldata leg = request.legs[i];
            uint256 campaigns = leg.campaigns.length;
            if (
                leg.amountIn == 0 || leg.amountIn > uint128(type(int128).max) || campaigns > 8
                    || (campaigns != 0 && request.engagement == address(0))
            ) revert InvalidTrade();
            plan.total += leg.amountIn;
            PoolId id = leg.key.toId();
            if (launcher.poolFamily(id) != request.familyId) revert NotFamilyMember(id);
            for (uint256 j; j < i; ++j) {
                if (PoolId.unwrap(ids[j]) == PoolId.unwrap(id)) revert DuplicatePool(id);
            }
            ids[i] = id;
            Currency quote = _quoteOf(leg.key, id);
            Currency subject =
                Currency.unwrap(leg.key.currency0) == Currency.unwrap(quote) ? leg.key.currency1 : leg.key.currency0;
            if (i == 0) {
                plan.subject = subject;
                if (Currency.unwrap(request.output) == Currency.unwrap(subject)) plan.buy = true;
                else if (Currency.unwrap(request.input) != Currency.unwrap(subject)) revert InvalidTrade();
            } else if (Currency.unwrap(subject) != Currency.unwrap(plan.subject)) {
                revert NotFamilyMember(id);
            }
            plan.quotes[i] = quote;
            // The trade's own currency on the member's quote side: the input on a buy, the output on a sell.
            Currency own = plan.buy ? request.input : request.output;
            bool converts = Currency.unwrap(quote) != Currency.unwrap(own);
            if (converts != !_empty(leg.conversion)) revert MixedCurrencies(id);
            if (converts) {
                _checkConversion(leg.conversion, own, quote);
                // A converting sell leg's member swap pays this router, so the pool's beneficiary check would see it,
                // not the recipient: such a trade pays the trader, whom the pool screens as the payer.
                if (!plan.buy && recipient != msg.sender) revert InvalidTrade();
            }
            plan.converts[i] = converts;
        }
    }

    /// @dev Refuses a reference pool whose currencies are not `own` and `quote` or whose hooks are neither absent nor a
    ///      registered root.
    function _checkConversion(PoolKey calldata ref, Currency own, Currency quote) private view {
        (address a, address b) = (Currency.unwrap(own), Currency.unwrap(quote));
        if (a > b) (a, b) = (b, a);
        address hooks = address(ref.hooks);
        if (
            Currency.unwrap(ref.currency0) != a || Currency.unwrap(ref.currency1) != b
                || (hooks != address(0) && !_registry.isRoot(hooks))
        ) revert InvalidConversion(ref.toId());
    }

    /// @dev Every currency the trade touches, the input first and the output second, then each converting leg's member
    ///      quote; all distinct, since a family's members have distinct quotes and none is the subject.
    function _touched(FamilyTrade calldata request, Plan memory plan) private pure returns (Currency[] memory touched) {
        uint256 count = 2;
        for (uint256 i; i < plan.converts.length; ++i) {
            if (plan.converts[i]) ++count;
        }
        touched = new Currency[](count);
        touched[0] = request.input;
        touched[1] = request.output;
        count = 2;
        for (uint256 i; i < plan.converts.length; ++i) {
            if (plan.converts[i]) touched[count++] = plan.quotes[i];
        }
    }

    /// @dev Takes exactly `total` of the input: the call's value for native, else a Permit2 signature transfer when
    ///      `permit` is not empty or `transferFrom` from the caller, credited by this router's balance delta.
    function _collect(Currency input, uint256 total, bytes calldata permit) private {
        if (Currency.unwrap(input) == address(0)) {
            if (permit.length != 0) revert InvalidPermit();
            if (msg.value != total) revert InvalidTrade();
            return;
        }
        if (msg.value != 0) revert InvalidTrade();
        address token = Currency.unwrap(input);
        uint256 start = IERC20(token).balanceOf(address(this));
        if (permit.length == 0) {
            IERC20(token).safeTransferFrom(msg.sender, address(this), total);
        } else {
            (IPermit2Signature.PermitTransferFrom memory p, bytes memory signature) =
                abi.decode(permit, (IPermit2Signature.PermitTransferFrom, bytes));
            if (p.permitted.token != token || p.permitted.amount < total) revert InvalidPermit();
            IPermit2Transfer(permit2)
                .permitTransferFrom(
                    p, IPermit2Signature.SignatureTransferDetails(address(this), total), msg.sender, signature
                );
        }
        uint256 received = IERC20(token).balanceOf(address(this)) - start;
        if (received != total) revert InputNotReceived(received, total);
    }

    /// @dev Runs leg `i`. Returns its output in the trade's output currency and the part of it this router holds for
    ///      the recipient (a sell's conversion through a hookless pool), paid with the rest of that at the end. Only
    ///      the member swap records the leg's campaigns.
    function _leg(FamilyTrade calldata request, Plan memory plan, uint256 i)
        private
        returns (uint256 out, uint256 kept)
    {
        Leg calldata leg = request.legs[i];
        address recipient = request.recipient;
        if (!plan.converts[i]) {
            Currency from = plan.buy ? request.input : plan.subject;
            out = _swapGated(leg.key, from, leg.amountIn, leg.minOut, recipient, request, leg.campaigns, i);
            return (out, 0);
        }
        uint256[] calldata none = leg.campaigns[0:0];
        Currency quote = plan.quotes[i];
        bool hookless = address(leg.conversion.hooks) == address(0);
        if (plan.buy) {
            uint256 converted = hookless
                ? _hookless(leg.conversion, request.input, leg.amountIn, i)
                : _swapGated(leg.conversion, request.input, leg.amountIn, 1, address(this), request, none, i);
            out = _swapGated(leg.key, quote, converted, leg.minOut, recipient, request, leg.campaigns, i);
        } else {
            uint256 received =
                _swapGated(leg.key, plan.subject, leg.amountIn, 1, address(this), request, leg.campaigns, i);
            if (hookless) {
                out = _hookless(leg.conversion, quote, received, i);
                kept = out;
            } else {
                out = _swapGated(leg.conversion, quote, received, leg.minOut, recipient, request, none, i);
            }
        }
    }

    /// @dev An exact-input swap of all of `amount` of `input` on a Hookr pool through HookrRouter.swapGated, funded by
    ///      this router and vouched for the trader, its output paid to `recipient`.
    function _swapGated(
        PoolKey calldata key,
        Currency input,
        uint256 amount,
        uint256 minOut,
        address recipient,
        FamilyTrade calldata request,
        uint256[] calldata campaigns,
        uint256 leg
    ) private returns (uint256 out) {
        if (amount > uint128(type(int128).max)) revert InvalidTrade();
        bool zeroForOne = Currency.unwrap(input) == Currency.unwrap(key.currency0);
        int128 amountSpecified = -int128(uint128(amount));
        IHookrRouter.Swap memory params = IHookrRouter.Swap({
            key: key,
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            amountBound: minOut == 0 ? 1 : uint128(minOut),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            recipient: recipient,
            deadline: request.deadline
        });
        _expected = keccak256(abi.encode(key, zeroForOne, int256(amountSpecified)));
        uint256 value;
        if (Currency.unwrap(input) == address(0)) value = amount;
        else IERC20(Currency.unwrap(input)).forceApprove(address(router), amount);
        uint256 used;
        (used, out) = router.swapGated{value: value}(
            params, _trader, address(this), "", campaigns.length == 0 ? address(0) : request.engagement, campaigns
        );
        if (used != amount) revert LegPartiallyFilled(leg, used, amount);
        _expected = bytes32(0);
        if (value == 0 && IERC20(Currency.unwrap(input)).allowance(address(this), address(router)) != 0) {
            IERC20(Currency.unwrap(input)).forceApprove(address(router), 0);
        }
    }

    /// @dev A conversion on the hookless pool `ref` of all of `amount` of `input`, in this router's own PoolManager
    ///      unlock; the output is held here.
    function _hookless(PoolKey calldata ref, Currency input, uint256 amount, uint256 leg) private returns (uint256) {
        bool zeroForOne = Currency.unwrap(input) == Currency.unwrap(ref.currency0);
        bytes memory data = abi.encode(ref, zeroForOne, amount, leg);
        _pending = keccak256(data);
        return abi.decode(poolManager.unlock(data), (uint256));
    }

    /// @dev The member pool's quote: the root's narrow read (`IHookrRootRoute.poolRoute`), or `IHookrRoot.poolConfig`
    ///      for a root without it, as HookrRouter reads it.
    function _quoteOf(PoolKey calldata key, PoolId id) private view returns (Currency) {
        address root = address(key.hooks);
        try IHookrRootRoute(root).poolRoute(id) returns (Currency quote, address) {
            return quote;
        } catch {
            return IHookrRoot(root).poolConfig(id).quote;
        }
    }

    /// @dev Whether `key` is all zero: no reference pool.
    function _empty(PoolKey calldata key) private pure returns (bool) {
        return Currency.unwrap(key.currency0) == address(0) && Currency.unwrap(key.currency1) == address(0)
            && key.fee == 0 && key.tickSpacing == 0 && address(key.hooks) == address(0);
    }
}
