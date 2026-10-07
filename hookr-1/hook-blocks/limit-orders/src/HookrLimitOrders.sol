// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHookrRegistry} from "hookr/interfaces/IHookrRegistry.sol";
import {IHookrRoot} from "hookr/interfaces/IHookrRoot.sol";
import {HookrTypes} from "hookr/types/HookrTypes.sol";
import {HookrRouter} from "hookr/periphery/HookrRouter.sol";
import {IHookrRouter} from "hookr/interfaces/IHookrRouter.sol";
import {HookrQuoter} from "hookr/lens/HookrQuoter.sol";
import {IHookrLaneRoot} from "hookr/interfaces/IHookrLaneRoot.sol";
import {IHookrSwapGate} from "hookr/interfaces/IHookrSwapGate.sol";
import {IHookrLimitOrders} from "./interfaces/IHookrLimitOrders.sol";
import {IRulesCredit} from "./interfaces/IRulesCredit.sol";

/// @title HookrLimitOrders
/// @notice Escrowed exact-input limit orders filled permissionlessly through the pinned Hookr router.
/// @dev No owner, admin, pause, upgrade, sweep or arbitrary call. Every fill is one
///      router swap funded by this book: `HookrRouter.swap`, whose payer is this book, or, on a root whose live GATE
///      admission names this book, `HookrRouter.swapGated` with the order's owner as payer, which this book vouches
///      for only while that fill is in flight. The router pulls at most the order's own input under an exact, reset
///      allowance, and the book then proves from its own balances that the whole input and nothing else left, that
///      no currency it holds for other orders moved, and that the recipient got the output.
///      Partial fills revert, which also means the root never credits a partial-fill refund to this book.
///      Supported assets must have standard, non-rebasing balances; deposits reject transfer taxes. A
///      recipient-side tax enabled later blocks fills but not cancels; a sender-side surcharge enabled later
///      blocks both until the token removes it. An asset that later confiscates or rebases the book's balance can
///      only under-collateralize orders in that asset.
contract HookrLimitOrders is IHookrLimitOrders {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    /// @dev cast index-erc7201 hookr.limitorders
    bytes32 private constant SLOT = 0x070450ab4af82e233ea5e5ff477a5a62d30198c502f3612f65d1303b34912200;
    /// @dev keccak256("hookr.limitorders.transient.lock")
    bytes32 private constant LOCK = 0xcbb4989c8e82fa9662f0d6c2f9ee113562a8c15a7a42d5daf686724c3a83aa3d;
    /// @dev keccak256("hookr.limitorders.transient.vouch"): the gated swap this book vouches for next, as
    ///      keccak256(abi.encode(payer, key, zeroForOne, amountSpecified)); zero once used.
    bytes32 private constant VOUCH = 0xaf7c99c316495c18dcc5bef32be80b2ee3dfdafeefed8606eef76d4b8e9ee08d;
    uint256 private constant MIN_LIFE = 1 minutes;
    uint256 private constant DEFAULT_LIFE = 7 days;
    uint256 private constant LIFETIME = 365 days;
    uint256 private constant MAX_IN = uint128(type(int128).max);
    uint256 private constant BPS = 10_000;
    /// @dev Keeper bounty bounds, in basis points of the order's native notional (its native input, or the native
    ///      minimum output of an order that sells into native).
    uint256 private constant MIN_BOUNTY_BPS_ = 0;
    uint256 private constant DEFAULT_BOUNTY_BPS_ = 10;
    uint256 private constant MAX_BOUNTY_BPS_ = 100;
    /// @dev Keeper bounty bounds, in native wei, for an order with no native leg (both pool currencies ERC-20).
    uint256 private constant MIN_FLAT_BOUNTY_ = 0;
    uint256 private constant DEFAULT_FLAT_BOUNTY_ = 0.0005 ether;
    uint256 private constant MAX_FLAT_BOUNTY_ = 0.01 ether;
    /// @dev Gas for each bounded read of a pool's root or Rules (lane floor, claim balance, King of the Pool state).
    uint256 private constant READ_GAS = 50_000;
    uint160 private constant MIN_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 private constant MAX_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
    Currency private constant NATIVE = Currency.wrap(address(0));
    /// @dev Where the root pays Auto Burn (HookrRoot.DEAD). A recipient here would also receive the burn inside the
    ///      fill's own swap, so the exact recipient-delta check would fail every fill.
    address private constant DEAD = address(0xdead);
    /// @dev Gas for the `router()` probe of a pool's root; the same bound `HookrRouter` uses.
    uint256 private constant ROUTER_PROBE_GAS = 10_000;
    /// @dev Per fill, at most this many recorded King of the Pool crowns are visited, and at most `CROWN_CALLS_PER_FILL`
    ///      of them cost a call to the Rules (a `hill` read, then a `settleEpoch` when a prize is due). A crown whose
    ///      recorded epoch end is still ahead costs two storage reads and no call. `settleCrowns` takes the same work in
    ///      pages of `CROWN_VISITS_PER_CALL` visits per call.
    uint256 private constant CROWN_VISITS_PER_FILL = 32;
    uint256 private constant CROWN_CALLS_PER_FILL = 8;
    uint256 private constant CROWN_VISITS_PER_CALL = 4;
    uint256 private constant MAX_CROWN_PAGE = 1_000;
    uint64 private constant NEVER = type(uint64).max;

    HookrRouter private immutable _router;
    /// @dev The router's pinned forwarder, which the router refuses as a swap recipient. Zero when it has none.
    address private immutable _forwarder;
    /// @inheritdoc IHookrLimitOrders
    bytes32 public immutable routerCodeHash;
    /// @inheritdoc IHookrLimitOrders
    IHookrRegistry public immutable registry;
    /// @inheritdoc IHookrLimitOrders
    IPoolManager public immutable poolManager;

    /// @custom:storage-location erc7201:hookr.limitorders
    struct State {
        uint256 lastOrderId;
        mapping(uint256 => Order) orders;
        mapping(Currency => uint256) liabilities;
        mapping(address => uint256) bounties;
        /// @dev Per Rules and quote, the King of the Pool pools whose epoch one of this book's fills led when it
        ///      landed. A prize can be credited to the book only for such an epoch, once elapsed, and only in that
        ///      pool's quote, so with no due one left in the fill's (Rules, quote) nothing but the fill's own share can
        ///      arrive in the claim it measures during its swap.
        mapping(address => mapping(Currency => PoolId[])) crowns;
        /// @dev Per Rules and pool, the recorded crown (`due` zero when the pool is not recorded).
        mapping(address => mapping(PoolId => Crown)) crownOf;
        /// @dev Per Rules and quote, the bounded settlement pass over `crowns`.
        mapping(address => mapping(Currency => CrownPass)) crownPass;
    }

    /// @dev `due` is a lower bound on the timestamp from which the recorded epoch can close (the epoch end read when
    ///      it was recorded or last visited; an epoch's end only moves later). `ledStart` is the start of the last
    ///      epoch at whose end one of this book's fills on the pool still led it. The Rules restore a leader only within
    ///      its own epoch and only to the leader saved at the transaction's first leading buy, so the book can lead an
    ///      epoch at the end of a transaction only if one of its fills ended leading that same epoch: the epoch
    ///      `ledStart` names.
    struct Crown {
        uint64 due;
        uint64 ledStart;
    }

    /// @dev `nextDue` is a lower bound on every recorded crown's `due` in the list, so before it no crown can be
    ///      due and a fill reads nothing more. From it on, fills (and `settleCrowns`) walk the list from the top down
    ///      in bounded steps: `cursor` is how many entries at the bottom this pass has not visited yet (0: no pass
    ///      open), and `passLow` the least `due` among the entries kept so far. A pass that reaches the bottom
    ///      sets `nextDue` to that least due date.
    struct CrownPass {
        uint64 nextDue;
        uint64 passLow;
        uint128 cursor;
    }

    /// @param router_ The Hookr router every fill goes through. Its registry and PoolManager are read from it.
    constructor(HookrRouter router_) {
        if (address(router_).code.length == 0) revert InvalidRouter(address(router_));
        IHookrRegistry registry_ = router_.registry();
        IPoolManager manager_ = router_.poolManager();
        if (address(registry_).code.length == 0 || address(manager_).code.length == 0) {
            revert InvalidRouter(address(router_));
        }
        _router = router_;
        _forwarder = router_.forwarder();
        routerCodeHash = address(router_).codehash;
        registry = registry_;
        poolManager = manager_;
    }

    modifier nonReentrant() {
        if (_locked()) revert Reentered();
        assembly ("memory-safe") { tstore(LOCK, 1) }
        _;
        assembly ("memory-safe") { tstore(LOCK, 0) }
    }

    /// @notice Accepts native currency only from the router, and only while one of this book's entry points holds
    ///         the lock. The expected case is a partial-fill refund during `fill`, which the fill then rejects.
    ///         Anything else the router pays here mid-call (for example a swap to this book made by a cancel
    ///         refund target) is a stray donation: no payout reads the book's absolute balance. Deposits arrive
    ///         through `createOrder`.
    receive() external payable {
        if (msg.sender != address(_router) || !_locked()) revert UnexpectedNativeSender(msg.sender);
    }

    /// @inheritdoc IHookrLimitOrders
    function router() external view returns (address) {
        return address(_router);
    }

    /// @inheritdoc IHookrLimitOrders
    function forwarder() external view returns (address) {
        return _forwarder;
    }

    /// @inheritdoc IHookrLimitOrders
    function MIN_LIFETIME() external pure returns (uint256) {
        return MIN_LIFE;
    }

    /// @inheritdoc IHookrLimitOrders
    function DEFAULT_LIFETIME() external pure returns (uint256) {
        return DEFAULT_LIFE;
    }

    /// @inheritdoc IHookrLimitOrders
    function MAX_LIFETIME() external pure returns (uint256) {
        return LIFETIME;
    }

    /// @inheritdoc IHookrLimitOrders
    function MIN_BOUNTY_BPS() external pure returns (uint256) {
        return MIN_BOUNTY_BPS_;
    }

    /// @inheritdoc IHookrLimitOrders
    function DEFAULT_BOUNTY_BPS() external pure returns (uint256) {
        return DEFAULT_BOUNTY_BPS_;
    }

    /// @inheritdoc IHookrLimitOrders
    function MAX_BOUNTY_BPS() external pure returns (uint256) {
        return MAX_BOUNTY_BPS_;
    }

    /// @inheritdoc IHookrLimitOrders
    function MIN_FLAT_BOUNTY() external pure returns (uint256) {
        return MIN_FLAT_BOUNTY_;
    }

    /// @inheritdoc IHookrLimitOrders
    function DEFAULT_FLAT_BOUNTY() external pure returns (uint256) {
        return DEFAULT_FLAT_BOUNTY_;
    }

    /// @inheritdoc IHookrLimitOrders
    function MAX_FLAT_BOUNTY() external pure returns (uint256) {
        return MAX_FLAT_BOUNTY_;
    }

    /// @inheritdoc IHookrLimitOrders
    function bountyBounds(PoolKey calldata key, bool zeroForOne, uint128 amountIn, uint128 minAmountOut)
        public
        pure
        returns (uint256 min, uint256 default_, uint256 max)
    {
        uint256 notional;
        if ((zeroForOne ? key.currency0 : key.currency1).isAddressZero()) notional = amountIn;
        else if ((zeroForOne ? key.currency1 : key.currency0).isAddressZero()) notional = minAmountOut;
        else return (MIN_FLAT_BOUNTY_, DEFAULT_FLAT_BOUNTY_, MAX_FLAT_BOUNTY_);
        return
            (notional * MIN_BOUNTY_BPS_ / BPS, notional * DEFAULT_BOUNTY_BPS_ / BPS, notional * MAX_BOUNTY_BPS_ / BPS);
    }

    /// @inheritdoc IHookrLimitOrders
    function fillGasFloor(uint256 orderId) external view returns (uint256) {
        Order storage o = _state().orders[orderId];
        if (o.status != Status.Open) return 0;
        (, uint256 floor) = _lane(o.key);
        return floor;
    }

    /// @inheritdoc IHookrLimitOrders
    function MAX_AMOUNT_IN() external pure returns (uint256) {
        return MAX_IN;
    }

    /// @inheritdoc IHookrLimitOrders
    function MIN_PRICE_LIMIT() external pure returns (uint160) {
        return MIN_LIMIT;
    }

    /// @inheritdoc IHookrLimitOrders
    function MAX_PRICE_LIMIT() external pure returns (uint160) {
        return MAX_LIMIT;
    }

    /// @inheritdoc IHookrLimitOrders
    function lastOrderId() external view returns (uint256) {
        return _state().lastOrderId;
    }

    /// @inheritdoc IHookrLimitOrders
    function getOrder(uint256 orderId) external view returns (Order memory) {
        return _state().orders[orderId];
    }

    /// @inheritdoc IHookrLimitOrders
    function liabilities(Currency currency) external view returns (uint256) {
        return _state().liabilities[currency];
    }

    /// @inheritdoc IHookrLimitOrders
    function bountyOf(address keeper) external view returns (uint256) {
        return _state().bounties[keeper];
    }

    /// @inheritdoc IHookrLimitOrders
    function createOrder(OrderParams calldata p) external payable nonReentrant returns (uint256 orderId) {
        PoolId poolId = p.key.toId();
        _checkPool(p.key, poolId);
        if (p.amountIn == 0 || p.amountIn > MAX_IN || p.minAmountOut == 0) revert InvalidOrder();
        uint160 limit = p.sqrtPriceLimitX96;
        if (limit == 0) limit = p.zeroForOne ? MIN_LIMIT : MAX_LIMIT;
        else if (limit < MIN_LIMIT || limit > MAX_LIMIT) revert InvalidOrder();
        _checkRecipient(p.recipient, address(p.key.hooks));
        if (p.expiry < block.timestamp + MIN_LIFE || p.expiry > block.timestamp + LIFETIME) {
            revert InvalidExpiry(p.expiry);
        }
        (,, uint256 maxBounty) = bountyBounds(p.key, p.zeroForOne, p.amountIn, p.minAmountOut);
        if (p.bounty > maxBounty) revert InvalidBounty(p.bounty, maxBounty);
        Currency input = p.zeroForOne ? p.key.currency0 : p.key.currency1;
        bool nativeIn = input.isAddressZero();
        uint256 expected = uint256(p.bounty) + (nativeIn ? p.amountIn : 0);
        if (msg.value != expected) revert InvalidNativeValue(expected, msg.value);

        State storage s = _state();
        orderId = ++s.lastOrderId;
        s.orders[orderId] = Order({
            key: p.key,
            owner: msg.sender,
            createdAt: uint40(block.timestamp),
            expiry: p.expiry,
            zeroForOne: p.zeroForOne,
            status: Status.Open,
            recipient: p.recipient,
            amountIn: p.amountIn,
            minAmountOut: p.minAmountOut,
            bounty: p.bounty,
            sqrtPriceLimitX96: limit
        });
        s.liabilities[input] += p.amountIn;
        if (p.bounty != 0) s.liabilities[NATIVE] += p.bounty;
        emit OrderCreated(
            orderId, msg.sender, poolId, p.zeroForOne, p.amountIn, p.minAmountOut, p.bounty, p.expiry, p.recipient
        );
        if (!nativeIn) {
            IERC20 token = IERC20(Currency.unwrap(input));
            uint256 held = token.balanceOf(address(this));
            token.safeTransferFrom(msg.sender, address(this), p.amountIn);
            if (token.balanceOf(address(this)) != held + p.amountIn) revert BalanceMismatch();
        }
    }

    /// @inheritdoc IHookrLimitOrders
    function fill(uint256 orderId) external nonReentrant returns (uint256 amountOut) {
        State storage s = _state();
        Order storage stored = s.orders[orderId];
        if (stored.status != Status.Open) revert OrderNotOpen(orderId, stored.status);
        if (block.timestamp > stored.expiry) revert OrderExpired(orderId, stored.expiry);
        if (address(_router).codehash != routerCodeHash) revert RouterCodeChanged();
        {
            // A lane pool's root reverts a swap that reaches its lane with less than the floor; refuse early and
            // name it. The floor is a lower bound for this call: the router, the PoolManager and the root each
            // forward 63/64 of what they hold, so a keeper's limit comes from eth_estimateGas of this call.
            (, uint256 floor) = _lane(stored.key);
            if (gasleft() < floor) revert InsufficientFillGas(gasleft(), floor);
        }
        // Effects first. A failed swap or check reverts all of them together.
        stored.status = Status.Filled;
        Order memory o = stored;
        (Currency input, Currency output) =
            o.zeroForOne ? (o.key.currency0, o.key.currency1) : (o.key.currency1, o.key.currency0);
        s.liabilities[input] -= o.amountIn;
        // The bounty stays in the book as native; it moves from the order to the keeper's pull balance.
        s.bounties[msg.sender] += o.bounty;
        // The root credits a lane arb recapture's trader share to the swap's payer as a claim in its Rules: this book
        // on a plain fill, the order's owner on a gated one (a root whose live GATE admission names this book). Close
        // the due King of the Pool epochs this book leads in these Rules and this quote (bounded work per fill), and
        // sweep any credit the book already holds there first. Code the swap runs (the recipient's receive, a token's
        // hooks) can close an elapsed epoch too, and settleEpoch is permissionless; with none left due and the block's
        // timestamp fixed, no prize can land in the claim during the swap. A plain fill's own share is what the swap
        // adds to the claim (after minus before), and it goes to the recipient when the claim was empty before the
        // swap. Otherwise none of the rise goes to the recipient: it is withheld and swept with the rest of the claim
        // to the Rules' protocol recipient. On a gated fill the rise is never the fill's own share. When the bounded
        // pass could not rule out a due epoch, the rise may hold a prize. When an older credit is still in the claim
        // (the sweep could pay it neither as tokens nor, on a pool with a recapture lane, into the protocol
        // recipient's own claim), the Rules pay the claim only whole. With HookrRules that leaves a pool without a
        // lane, whose rise is never a lane trader share.
        (address rules, Currency quote) = _rulesOf(o.key);
        PoolId id = o.key.toId();
        _settleCrown(rules, id);
        bool clear = _settleCrowns(s, rules, quote, CROWN_VISITS_PER_FILL, CROWN_CALLS_PER_FILL);
        if (_credit(rules, quote) != 0) _sweep(o.key, rules, quote);
        uint256 held = _credit(rules, quote);
        bool gated = _admitsBook(address(o.key.hooks));
        amountOut = _execute(orderId, o, input, output, gated);
        emit OrderFilled(orderId, msg.sender, o.key.toId(), o.recipient, o.amountIn, amountOut, o.bounty);
        uint256 credit = _credit(rules, quote);
        if (credit > held) {
            if (clear && held == 0 && !gated) _passCredit(orderId, rules, quote, o.recipient, credit);
            else _withholdCredit(orderId, o.key, rules, quote, credit - held);
        }
        _trackCrown(s, rules, quote, id);
    }

    /// @inheritdoc IHookrSwapGate
    /// @dev Vouches only for the swap this book asked HookrRouter for in its running fill: the order's owner as payer
    ///      and the order's pool, direction and exact input. The vouch is spent by this call.
    function beforeUnlock(
        address caller,
        address payer,
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        bytes calldata
    ) external returns (bytes4) {
        bytes32 vouch;
        assembly ("memory-safe") { vouch := tload(VOUCH) }
        if (
            msg.sender != address(_router) || caller != address(this) || vouch == bytes32(0)
                || keccak256(abi.encode(payer, key, zeroForOne, amountSpecified)) != vouch
        ) revert NotInFlightFill();
        assembly ("memory-safe") { tstore(VOUCH, 0) }
        return IHookrSwapGate.beforeUnlock.selector;
    }

    /// @inheritdoc IHookrLimitOrders
    function settleCrowns(PoolKey calldata key, uint256 maxCalls) external nonReentrant returns (bool clear) {
        _checkPool(key, key.toId());
        (address rules, Currency quote) = _rulesOf(key);
        if (maxCalls == 0 || maxCalls > MAX_CROWN_PAGE) maxCalls = MAX_CROWN_PAGE;
        clear = _settleCrowns(_state(), rules, quote, maxCalls * CROWN_VISITS_PER_CALL, maxCalls);
    }

    /// @inheritdoc IHookrLimitOrders
    function crownBacklog(address rules, Currency quote)
        external
        view
        returns (uint256 recorded, uint256 unvisited, uint256 nextDue)
    {
        State storage s = _state();
        CrownPass storage p = s.crownPass[rules][quote];
        return (s.crowns[rules][quote].length, p.cursor, p.nextDue);
    }

    /// @inheritdoc IHookrLimitOrders
    function cancel(uint256 orderId, address to) external nonReentrant {
        State storage s = _state();
        Order storage stored = s.orders[orderId];
        if (stored.status != Status.Open) revert OrderNotOpen(orderId, stored.status);
        if (msg.sender != stored.owner) revert NotOrderOwner(orderId, msg.sender);
        _checkRecipient(to, address(stored.key.hooks));
        stored.status = Status.Cancelled;
        Currency input = stored.zeroForOne ? stored.key.currency0 : stored.key.currency1;
        uint256 amountIn = stored.amountIn;
        uint256 bounty = stored.bounty;
        s.liabilities[input] -= amountIn;
        if (bounty != 0) s.liabilities[NATIVE] -= bounty;
        emit OrderCancelled(orderId, msg.sender, to, amountIn, bounty);
        if (input.isAddressZero()) {
            _sendNative(to, amountIn + bounty);
        } else {
            _sendToken(input, to, amountIn);
            _sendNative(to, bounty);
        }
    }

    /// @inheritdoc IHookrLimitOrders
    function claimBounty(address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0) || to == address(this) || to == address(_router)) revert InvalidRecipient(to);
        State storage s = _state();
        amount = s.bounties[msg.sender];
        if (amount == 0) revert NothingToClaim();
        s.bounties[msg.sender] = 0;
        s.liabilities[NATIVE] -= amount;
        emit BountyClaimed(msg.sender, to, amount);
        _sendNative(to, amount);
    }

    /// @inheritdoc IHookrLimitOrders
    function sweepCredit(PoolKey calldata key) external nonReentrant returns (uint256 amount) {
        _checkPool(key, key.toId());
        (address rules, Currency quote) = _rulesOf(key);
        amount = _credit(rules, quote);
        if (amount == 0) revert NothingToClaim();
        if (!_sweep(key, rules, quote)) revert CreditNotSwept(rules);
    }

    /// @inheritdoc IHookrLimitOrders
    function quoteFill(uint256 orderId) external returns (bool fillable, uint256 amountOut) {
        if (_locked()) revert Reentered();
        Order memory o = _state().orders[orderId];
        if (o.status != Status.Open || block.timestamp > o.expiry) return (false, 0);
        address root = address(o.key.hooks);
        address payer = _admitsBook(root) ? o.owner : address(this);
        try HookrQuoter(IHookrRoot(root).quoter()).quote(_swapParams(o, 1), payer) returns (
            HookrTypes.ExecutionReceipt memory receipt
        ) {
            amountOut = receipt.outputAmount;
            fillable = receipt.inputAmount == o.amountIn && amountOut >= o.minAmountOut;
        } catch {
            return (false, 0);
        }
    }

    /// @dev One router swap for exactly the order's terms, then the custody proofs. A gated fill records its vouch
    ///      last, right before `swapGated`: until the router asks this book, only the router runs, besides its static
    ///      read of the gate's admission from the registry, so nothing else can reach the vouch while it is live.
    function _execute(uint256 orderId, Order memory o, Currency input, Currency output, bool gated)
        private
        returns (uint256 amountOut)
    {
        bool nativeIn = input.isAddressZero();
        uint256 inputBefore = _balance(input, address(this));
        uint256 outputHeld = _balance(output, address(this));
        uint256 recipientBefore = _balance(output, o.recipient);
        if (!nativeIn) IERC20(Currency.unwrap(input)).forceApprove(address(_router), o.amountIn);
        IHookrRouter.Swap memory params = _swapParams(o, o.minAmountOut);
        uint256 value = nativeIn ? o.amountIn : 0;
        uint256 spent;
        if (gated) {
            bytes32 vouch =
                keccak256(abi.encode(o.owner, params.key, params.zeroForOne, int256(params.amountSpecified)));
            assembly ("memory-safe") { tstore(VOUCH, vouch) }
            (spent, amountOut) =
                _router.swapGated{value: value}(params, o.owner, address(this), "", address(0), new uint256[](0));
        } else {
            (spent, amountOut) = _router.swap{value: value}(params, address(0), new uint256[](0));
        }
        if (!nativeIn) IERC20(Currency.unwrap(input)).forceApprove(address(_router), 0);
        uint256 inputAfter = _balance(input, address(this));
        if (spent != o.amountIn || inputAfter > inputBefore || inputBefore - inputAfter != o.amountIn) {
            revert PartialFill(orderId, spent, o.amountIn);
        }
        if (amountOut < o.minAmountOut) revert BelowMinimum(orderId, amountOut, o.minAmountOut);
        // Escrow of other orders in the output currency must not move; the router pays the recipient directly.
        if (_balance(output, address(this)) != outputHeld) revert BalanceMismatch();
        if (!output.isAddressZero() && _balance(output, o.recipient) != recipientBefore + amountOut) {
            revert BalanceMismatch();
        }
    }

    function _swapParams(Order memory o, uint128 minimum) private view returns (IHookrRouter.Swap memory) {
        return IHookrRouter.Swap({
            key: o.key,
            zeroForOne: o.zeroForOne,
            // createOrder bounds amountIn to int128.max, so the conversion is exact.
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int128(o.amountIn),
            amountBound: minimum,
            sqrtPriceLimitX96: o.sqrtPriceLimitX96,
            recipient: o.recipient,
            deadline: block.timestamp
        });
    }

    /// @dev Whether `root` holds a live GATE admission of this book, read as HookrRouter reads it for `swapGated` (a
    ///      revoked admission, or one whose bond no longer covers it, reads as empty). Only then does a fill there run
    ///      through `swapGated` with the order's owner as payer; elsewhere it runs through `swap` with this book as
    ///      payer. The admission's pinned codehash is this book's own: the registry checks it when the ADMIT is
    ///      queued and when it executes, and this book's code never changes.
    function _admitsBook(address root) private view returns (bool) {
        IHookrRegistry.Admission memory a = registry.admission(root, address(this));
        return a.kind == IHookrRegistry.Kind.GATE && a.implementation == address(this);
    }

    /// @dev The pool's Rules and quote, from its root (a registered root that initialized the pool).
    function _rulesOf(PoolKey memory key) private view returns (address rules, Currency quote) {
        HookrTypes.PoolConfig memory c = IHookrRoot(address(key.hooks)).poolConfig(key.toId());
        return (c.rules, c.quote);
    }

    /// @dev This book's claim in `rules` in `quote`, read with a bounded static call; zero when unreadable.
    function _credit(address rules, Currency quote) private view returns (uint256 amount) {
        (bool ok, bytes memory out) =
            rules.staticcall{gas: READ_GAS}(abi.encodeCall(IRulesCredit.claimable, (quote, address(this))));
        if (ok && out.length == 32) amount = abi.decode(out, (uint256));
    }

    /// @dev The pool's lane from its root (`IHookrLaneRoot.laneOf`), read with a bounded static call: the executor it
    ///      froze, zero for a pool without a lane, and the gas floor, zero also while the lane's switch is off. Both
    ///      are zero when the root does not answer.
    function _lane(PoolKey memory key) private view returns (address executor, uint256 floor) {
        (bool ok, bytes memory out) =
            address(key.hooks).staticcall{gas: READ_GAS}(abi.encodeCall(IHookrLaneRoot.laneOf, (key.toId())));
        if (ok && out.length == 224) {
            (executor,,,,,, floor) = abi.decode(out, (address, bytes32, uint16, bytes32, bool, uint32, uint256));
        }
    }

    /// @dev On a King of the Pool pool whose elapsed epoch this book leads, closes the epoch so its prize is credited
    ///      now, before the fill measures its own share. Anything else, or a failure, does nothing.
    function _settleCrown(address rules, PoolId id) private {
        (bool ok, bytes memory out) = rules.staticcall{gas: READ_GAS}(abi.encodeCall(IRulesCredit.hill, (id)));
        if (!ok || out.length != 160) return;
        (, uint64 epochEnd, address leader,,) = abi.decode(out, (uint64, uint64, address, uint128, uint128));
        if (leader != address(this) || block.timestamp < epochEnd) return;
        try IRulesCredit(rules).settleEpoch(id) {} catch {}
    }

    /// @dev One bounded step of the settlement pass over this book's recorded crowns in (`rules`, `quote`): visits at
    ///      most `maxVisits` entries and calls the Rules for at most `maxCalls` of them. A visited crown is kept
    ///      without a call while its recorded due date is ahead. Otherwise one `hill` read decides. While the epoch is
    ///      open: keep it, due at the epoch's end, when the book leads it or one of its fills ended leading it
    ///      (`ledStart`), whoever leads it now, since an outbidder who sells in the same transaction restores the book;
    ///      drop it when the book never led this epoch, since no restore can reach the book then. Once the epoch has
    ///      elapsed no restore can reach it (a swap rolls it first): drop when another account leads it, or when its
    ///      pot is empty, because no prize can be credited for it (an elapsed epoch's pot grows only after it rolls,
    ///      and rolling it pays min(pot, ...)); else `settleEpoch`, then drop. A failed read or settlement keeps the
    ///      crown due. Returns whether no recorded crown can be due now: true only before `nextDue`, which a
    ///      pass sets when it reaches the bottom of the list.
    function _settleCrowns(State storage s, address rules, Currency quote, uint256 maxVisits, uint256 maxCalls)
        private
        returns (bool clear)
    {
        CrownPass storage p = s.crownPass[rules][quote];
        if (block.timestamp < p.nextDue) return true;
        PoolId[] storage list = s.crowns[rules][quote];
        mapping(PoolId => Crown) storage crownOf = s.crownOf[rules];
        uint256 cursor = p.cursor;
        uint256 low = p.passLow;
        if (cursor == 0) (cursor, low) = (list.length, NEVER);
        uint256 calls;
        for (uint256 visits; cursor != 0 && visits < maxVisits && calls < maxCalls; ++visits) {
            --cursor;
            PoolId id = list[cursor];
            Crown storage c = crownOf[id];
            uint256 due = c.due;
            if (block.timestamp >= due) {
                ++calls;
                bool drop;
                (bool ok, bytes memory out) = rules.staticcall{gas: READ_GAS}(abi.encodeCall(IRulesCredit.hill, (id)));
                if (ok && out.length == 160) {
                    (uint64 epochStart, uint64 epochEnd, address leader,, uint128 pot) =
                        abi.decode(out, (uint64, uint64, address, uint128, uint128));
                    if (block.timestamp < epochEnd) {
                        if (leader == address(this) || c.ledStart == epochStart) {
                            due = epochEnd;
                            c.due = epochEnd;
                        } else {
                            drop = true;
                        }
                    } else if (leader != address(this) || pot == 0) {
                        drop = true;
                    } else {
                        try IRulesCredit(rules).settleEpoch(id) {
                            drop = true;
                        } catch {}
                    }
                }
                if (drop) {
                    // Entries above the cursor are visited; the last one moves here and is not visited twice.
                    list[cursor] = list[list.length - 1];
                    list.pop();
                    delete crownOf[id];
                    continue;
                }
            }
            if (due < low) low = due;
        }
        // cursor never exceeds the list's length, and low is NEVER or a stored epoch end (a uint64), so both fit.
        // forge-lint: disable-next-line(unsafe-typecast)
        p.cursor = uint128(cursor);
        if (cursor != 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            p.passLow = uint64(low);
            return false;
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        p.nextDue = uint64(low);
        return block.timestamp < low;
    }

    /// @dev Records the fill's pool as a crown of this book in (`rules`, `quote`) when the book leads its epoch after
    ///      the swap, due at that epoch's end, and notes that epoch as one the book led (`ledStart`). A crown already
    ///      recorded keeps its earlier, lower due date and only moves `ledStart` to the epoch it now leads.
    function _trackCrown(State storage s, address rules, Currency quote, PoolId id) private {
        (bool ok, bytes memory out) = rules.staticcall{gas: READ_GAS}(abi.encodeCall(IRulesCredit.hill, (id)));
        if (!ok || out.length != 160) return;
        (uint64 epochStart, uint64 epochEnd, address leader,,) =
            abi.decode(out, (uint64, uint64, address, uint128, uint128));
        if (leader != address(this)) return;
        Crown storage c = s.crownOf[rules][id];
        if (c.due != 0) {
            if (c.ledStart != epochStart) c.ledStart = epochStart;
            return;
        }
        if (epochEnd == 0) epochEnd = 1;
        (c.due, c.ledStart) = (epochEnd, epochStart);
        s.crowns[rules][quote].push(id);
        CrownPass storage p = s.crownPass[rules][quote];
        if (epochEnd < p.nextDue) p.nextDue = epochEnd;
        // An open pass counts the new top entry as visited, so its due date joins the pass's least.
        if (p.cursor != 0 && epochEnd < p.passLow) p.passLow = epochEnd;
    }

    /// @dev The claim rose during a fill, but the rise cannot be paid to the order's recipient on its own: the fill's
    ///      bounded pass could not rule out a due King of the Pool epoch in its (Rules, quote), so the rise may hold a
    ///      prize, or an older credit the sweep could not move is still in the claim, which the Rules pay only whole,
    ///      or the fill was gated, so the Rules credited its own share to the order's owner and the rise is someone
    ///      else's credit naming the book. Nothing of it goes to the order's recipient; the whole claim is swept to the
    ///      Rules' protocol recipient (or stays with the book for a later sweep when that fails).
    function _withholdCredit(uint256 orderId, PoolKey memory key, address rules, Currency quote, uint256 amount)
        private
    {
        emit CreditWithheld(orderId, rules, quote, amount);
        _sweep(key, rules, quote);
    }

    /// @dev Pays this book's whole claim in `rules` in `quote` to that Rules' protocol recipient: as tokens (or
    ///      native), or, when that fails and the pool has a recapture lane, as the recipient's own claim in the same
    ///      Rules. That path takes the claim as PoolManager ERC-6909 claims to this book and moves them on to the
    ///      pool's root in the same call (the Rules refuse their root as a claim recipient, so the claim cannot be
    ///      paid there directly), and the root's permissionless `sweepClaims` returns every such claim the root holds
    ///      to the pool's Rules as a claim of their protocol recipient, which collects it like its other claims there
    ///      (a `HookrTreasury` through `collect`, `collectTo` or `collectAsClaims`). An ERC-6909 balance is never left
    ///      with the protocol recipient: a `HookrTreasury` has no call that moves one. Neither the move to the root
    ///      nor the root's call is caught, so when either fails the whole call reverts and the claim never stays with
    ///      this book or the root. Between fills the book's claim is a King of the Pool prize one of its fills won, a
    ///      rise a fill withheld or a third party's credit naming the book, none of which an order can be matched to
    ///      (claims are pooled per currency across pools). Returns whether it moved.
    function _sweep(PoolKey memory key, address rules, Currency quote) private returns (bool) {
        (bool ok, bytes memory out) =
            rules.staticcall{gas: READ_GAS}(abi.encodeCall(IRulesCredit.protocolRecipient, ()));
        if (!ok || out.length != 32) return false;
        address to = abi.decode(out, (address));
        try IRulesCredit(rules).claimTo(quote, to) returns (uint256 amount) {
            emit CreditSwept(rules, quote, to, amount, false);
            return true;
        } catch {}
        (address executor,) = _lane(key);
        if (executor == address(0)) return false;
        IHookrLaneRoot root = IHookrLaneRoot(address(key.hooks));
        try IRulesCredit(rules).claimAsClaims(quote, address(this)) returns (uint256 amount) {
            poolManager.transfer(address(root), quote.toId(), amount);
            root.sweepClaims(key.toId(), quote);
            emit CreditSwept(rules, quote, to, amount, true);
            return true;
        } catch {
            return false;
        }
    }

    /// @dev Pays the trader share a plain fill earned to the order's recipient: as tokens (or native), or, when the
    ///      recipient refuses them, as PoolManager ERC-6909 claims. If both fail it stays with the book.
    function _passCredit(uint256 orderId, address rules, Currency quote, address to, uint256 amount) private {
        try IRulesCredit(rules).claimTo(quote, to) {
            emit CreditPassed(orderId, to, quote, amount, false);
        } catch {
            try IRulesCredit(rules).claimAsClaims(quote, to) {
                emit CreditPassed(orderId, to, quote, amount, true);
            } catch {}
        }
    }

    /// @dev The pool must be one a registered root initialized and whose pinned router is this book's router. The
    ///      router pin is read with the same bounded probe the router applies, so a registered root without
    ///      `router()` (a factory pair root, which the router refuses) is refused here as `InvalidPool`.
    function _checkPool(PoolKey calldata key, PoolId id) private view {
        address root = address(key.hooks);
        if (
            root.code.length == 0 || !registry.isRoot(root) || !_pinsRouter(root)
                || address(IHookrRoot(root).poolManager()) != address(poolManager) || !IHookrRoot(root).knownPool(id)
        ) revert InvalidPool(id);
    }

    /// @dev Whether a static call to `root.router()` with `ROUTER_PROBE_GAS` succeeds and returns exactly one word
    ///      equal to this book's router. Reverts, other lengths and dirty high bits read as false.
    function _pinsRouter(address root) private view returns (bool pinned) {
        bytes4 selector = IHookrRoot.router.selector;
        address expected = address(_router);
        assembly ("memory-safe") {
            mstore(0, selector)
            let ok := staticcall(ROUTER_PROBE_GAS, root, 0, 4, 0, 32)
            pinned := and(and(ok, eq(returndatasize(), 32)), eq(mload(0), expected))
        }
    }

    /// @dev Order output and cancel refunds never go to an address where they would be stranded or lost, or that
    ///      the router refuses as a recipient: zero, this book, the router, the router's forwarder, the PoolManager,
    ///      the pool's root, or the Auto Burn sink. The forwarder has no receive and no sweep.
    function _checkRecipient(address to, address root) private view {
        if (
            to == address(0) || to == address(this) || to == address(_router) || to == address(poolManager)
                || to == root || to == DEAD || to == _forwarder
        ) revert InvalidRecipient(to);
    }

    function _balance(Currency currency, address account) private view returns (uint256) {
        return currency.isAddressZero() ? account.balance : IERC20(Currency.unwrap(currency)).balanceOf(account);
    }

    /// @dev The book's balance must fall by exactly `amount`, so a transfer can never draw on other orders' escrow.
    ///      The recipient's receipt is not required to match, so a recipient-side tax added later does not trap a
    ///      cancellation. A sender-side surcharge does (the book's balance would fall by more than `amount`) until
    ///      the token removes it.
    function _sendToken(Currency currency, address to, uint256 amount) private {
        if (amount == 0) return;
        IERC20 token = IERC20(Currency.unwrap(currency));
        uint256 held = token.balanceOf(address(this));
        token.safeTransfer(to, amount);
        uint256 after_ = token.balanceOf(address(this));
        if (after_ > held || held - after_ != amount) revert BalanceMismatch();
    }

    function _sendNative(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
    }

    function _locked() private view returns (bool locked) {
        assembly ("memory-safe") { locked := tload(LOCK) }
    }

    function _state() private pure returns (State storage s) {
        assembly ("memory-safe") { s.slot := SLOT }
    }
}
