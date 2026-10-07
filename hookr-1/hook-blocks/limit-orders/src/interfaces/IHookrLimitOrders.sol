// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHookrRegistry} from "hookr/interfaces/IHookrRegistry.sol";
import {IHookrSwapGate} from "hookr/interfaces/IHookrSwapGate.sol";

/// @title IHookrLimitOrders
/// @notice Escrowed exact-input limit orders on Hookr pools. A trader escrows the whole input, a net minimum
///         output and a native keeper bounty; anyone may fill the order through the pinned `HookrRouter` once the
///         pool can pay that minimum. The whole input swaps at once: a partial fill reverts.
/// @dev An off-pool sidecar that keepers drive.
///      It is in no swap path; on Hookr contracts it calls only what any account may call. On a root that has not
///      admitted it, it is a router payer like any other: the root sees the book as the authenticated payer and the
///      order's recipient as the beneficiary of every fill, and the order's owner is not visible to Rules, advisories
///      or Programs. It is also an `IHookrSwapGate`, inert until a root's governance admits it: once a timelocked
///      `ADMIT` of kind GATE naming it executes on a root (and until a brake revokes it), every fill on that root's
///      pools runs through `HookrRouter.swapGated` with the book as funder and gate and the order's owner as payer,
///      so the root's compliance checks, Rules claims (a lane arb recapture's trader share, a King of the Pool lead
///      and its prize) and receipts name the owner. The book vouches only for its own fill in flight.
interface IHookrLimitOrders is IHookrSwapGate {
    /// @notice Lifecycle of an order. `None` means the id was never created. Filled and Cancelled are final.
    enum Status {
        None,
        Open,
        Filled,
        Cancelled
    }

    /// @notice Terms a trader commits when creating an order. None can change afterwards.
    /// @param key The Hookr pool. Its hook must be a root registered in the router's registry that pins this
    ///        book's router, and the root must have initialized the pool.
    /// @param zeroForOne Swap direction: true sells currency0 for currency1.
    /// @param amountIn Exact input escrowed now and swapped in full at fill, in raw input units.
    /// @param minAmountOut Net minimum output the recipient must receive, after every Hookr fee, take and burn.
    ///        It is the order's price commitment and the only price protection. Must be nonzero.
    /// @param sqrtPriceLimitX96 Optional marginal price bound; zero means none. A fill that would cross it stops
    ///        early, which is a partial fill, so it reverts.
    /// @param recipient Receives the output directly from the router. Not zero, this book, the router, the
    ///        router's forwarder (which the router refuses as a recipient), the PoolManager or the pool's root,
    ///        where output would be stranded or every fill would revert, and not the Auto Burn sink 0xdead,
    ///        which also receives the burn inside the fill and so could never pass the exact receipt check.
    /// @param expiry Last timestamp at which the order can fill. At least MIN_LIFETIME (1 minute) and at most
    ///        MAX_LIFETIME (365 days) away.
    /// @param bounty Native amount paid to the filler's pull balance on a successful fill; refunded on cancel. At most
    ///        the `max` of `bountyBounds` for the order's terms: MAX_BOUNTY_BPS of its native notional, or
    ///        MAX_FLAT_BOUNTY when neither pool currency is native.
    struct OrderParams {
        PoolKey key;
        bool zeroForOne;
        uint128 amountIn;
        uint128 minAmountOut;
        uint160 sqrtPriceLimitX96;
        address recipient;
        uint40 expiry;
        uint128 bounty;
    }

    /// @notice A stored order. `sqrtPriceLimitX96` holds the resolved limit (the far bound when none was given).
    struct Order {
        PoolKey key;
        address owner;
        uint40 createdAt;
        uint40 expiry;
        bool zeroForOne;
        Status status;
        address recipient;
        uint128 amountIn;
        uint128 minAmountOut;
        uint128 bounty;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Thrown when the router has no code, or the router's registry or PoolManager has no code.
    error InvalidRouter(address router);
    /// @notice Thrown when an amount or the direction's price limit is out of range.
    error InvalidOrder();
    /// @notice Thrown when the pool is not a Hookr pool of a registered root that pins this book's router. A
    ///         factory pair root (no `router()`, refused by the router) is one of these.
    error InvalidPool(PoolId id);
    /// @notice Thrown when an order recipient or a cancel refund target is zero, this book, the router, the
    ///         router's forwarder, the PoolManager, the pool's root or 0xdead, or when a bounty target is zero,
    ///         this book or the router.
    error InvalidRecipient(address recipient);
    /// @notice Thrown when the expiry is less than MIN_LIFETIME or more than MAX_LIFETIME away.
    error InvalidExpiry(uint256 expiry);
    /// @notice Thrown when the bounty is above the order's `bountyBounds` maximum.
    error InvalidBounty(uint256 bounty, uint256 max);
    /// @notice Thrown when a fill on a lane pool starts with less gas than the pool's lane floor.
    error InsufficientFillGas(uint256 available, uint256 required);
    /// @notice Thrown when `sweepCredit` can pay the book's claim to the Rules' protocol recipient neither as tokens or
    ///         native nor, through the root of a pool with a recapture lane, as the recipient's own claim in the Rules.
    ///         On a pool without a lane, a lane pool of the same Rules and quote can sweep it.
    error CreditNotSwept(address rules);
    /// @notice Thrown when msg.value is not the bounty plus, for native input, the input amount.
    error InvalidNativeValue(uint256 expected, uint256 actual);
    /// @notice Thrown when an ERC-20 transfer did not move the exact amount (transfer taxes, rebasing).
    error BalanceMismatch();
    /// @notice Thrown when the order is not open.
    error OrderNotOpen(uint256 orderId, Status status);
    /// @notice Thrown when a fill is attempted after the order's expiry.
    error OrderExpired(uint256 orderId, uint256 expiry);
    /// @notice Thrown when someone other than the order owner cancels.
    error NotOrderOwner(uint256 orderId, address caller);
    /// @notice Thrown when the router consumed less than the whole escrowed input.
    error PartialFill(uint256 orderId, uint256 spent, uint256 amountIn);
    /// @notice Thrown when the router reported less than the order's net minimum output.
    error BelowMinimum(uint256 orderId, uint256 amountOut, uint256 minAmountOut);
    /// @notice Thrown when the pinned router's runtime code no longer matches its construction-time hash.
    error RouterCodeChanged();
    /// @notice Thrown when a state-changing entry point is re-entered.
    error Reentered();
    /// @notice Thrown when native currency arrives from anyone but the router, or from the router outside a call
    ///         into this book.
    error UnexpectedNativeSender(address sender);
    /// @notice Thrown when the caller has no bounty to claim.
    error NothingToClaim();
    /// @notice Thrown when a native transfer fails.
    error NativeTransferFailed();
    /// @notice Thrown when `beforeUnlock` is asked to vouch for anything but this book's own gated fill in flight: by
    ///         anyone but the router, for a swap another account called, for another payer, pool, direction or
    ///         amount, or once that fill's vouch is spent.
    error NotInFlightFill();

    /// @notice Emitted when an order is created and its input and bounty are escrowed.
    event OrderCreated(
        uint256 indexed orderId,
        address indexed owner,
        PoolId indexed poolId,
        bool zeroForOne,
        uint128 amountIn,
        uint128 minAmountOut,
        uint128 bounty,
        uint40 expiry,
        address recipient
    );
    /// @notice Emitted when an order fills in full. `amountOut` is the net output the recipient received.
    event OrderFilled(
        uint256 indexed orderId,
        address indexed keeper,
        PoolId indexed poolId,
        address recipient,
        uint256 amountIn,
        uint256 amountOut,
        uint256 bounty
    );
    /// @notice Emitted when the owner cancels an open order and its escrow is returned.
    event OrderCancelled(
        uint256 indexed orderId, address indexed owner, address indexed to, uint256 inputRefund, uint256 bountyRefund
    );
    /// @notice Emitted when a keeper withdraws its bounty balance.
    event BountyClaimed(address indexed keeper, address indexed to, uint256 amount);
    /// @notice Emitted when the lane trader share a plain fill earned (credited by the Rules to this book as the swap's
    ///         payer) is paid to the order's recipient; `asClaims` when it went as PoolManager ERC-6909 claims. A gated
    ///         fill passes nothing: the Rules credit its share to the order's owner, its payer.
    event CreditPassed(
        uint256 indexed orderId, address indexed recipient, Currency indexed currency, uint256 amount, bool asClaims
    );
    /// @notice Emitted when the book's claim in a Rules (a King of the Pool prize one of its fills won, a rise a fill
    ///         withheld, or a third party's credit naming the book) is paid to that Rules' protocol recipient `to`: as
    ///         tokens or native, or, with `asRulesClaim`, as `to`'s own claim in the same Rules, credited through the
    ///         pool's root (`IHookrLaneRoot.sweepClaims`), which `to` collects like its other claims there.
    event CreditSwept(
        address indexed rules, Currency indexed currency, address indexed to, uint256 amount, bool asRulesClaim
    );
    /// @notice Emitted when a fill's rise in the book's Rules claim is not passed to the order's recipient because it
    ///         cannot be paid apart from other credit in the same claim: the fill's bounded King of the Pool pass could
    ///         not rule out a due epoch the book leads in that Rules and quote, whose prize could have landed in the
    ///         claim during the swap, or an older credit the sweep could not move was still in it (the Rules pay a
    ///         claim only whole); or because the fill was gated, so its own share went to the order's owner and the
    ///         rise is another credit naming the book. The claim is swept to the Rules' protocol recipient
    ///         (`CreditSwept`), or stays with the book for a later sweep when that fails.
    event CreditWithheld(uint256 indexed orderId, address indexed rules, Currency indexed currency, uint256 amount);

    /// @notice Returns the pinned Hookr router every fill goes through.
    function router() external view returns (address);

    /// @notice Returns the router's runtime code hash recorded at construction.
    function routerCodeHash() external view returns (bytes32);

    /// @notice Returns the Hookr registry the router checks roots against.
    function registry() external view returns (IHookrRegistry);

    /// @notice Returns the PoolManager behind the router.
    function poolManager() external view returns (IPoolManager);

    /// @notice Returns the router's forwarder, read at construction. Zero when the router has none.
    function forwarder() external view returns (address);

    /// @notice Returns the shortest order lifetime `createOrder` accepts, 1 minute.
    function MIN_LIFETIME() external view returns (uint256);

    /// @notice Returns the order lifetime an app or SDK pre-fills, 7 days. The trader may choose any lifetime from
    ///         MIN_LIFETIME to MAX_LIFETIME; nothing on chain applies this value.
    function DEFAULT_LIFETIME() external view returns (uint256);

    /// @notice Returns the longest allowed order lifetime, 365 days.
    function MAX_LIFETIME() external view returns (uint256);

    /// @notice Returns the least keeper bounty, in basis points of the order's native notional: 0.
    function MIN_BOUNTY_BPS() external view returns (uint256);

    /// @notice Returns the keeper bounty an app or SDK pre-fills, in basis points of the order's native notional: 10.
    ///         Nothing on chain applies it.
    function DEFAULT_BOUNTY_BPS() external view returns (uint256);

    /// @notice Returns the largest keeper bounty, in basis points of the order's native notional: 100.
    function MAX_BOUNTY_BPS() external view returns (uint256);

    /// @notice Returns the least keeper bounty of an order with no native leg, in wei: 0.
    function MIN_FLAT_BOUNTY() external view returns (uint256);

    /// @notice Returns the keeper bounty an app or SDK pre-fills for an order with no native leg: 0.0005 ETH.
    function DEFAULT_FLAT_BOUNTY() external view returns (uint256);

    /// @notice Returns the largest keeper bounty of an order with no native leg: 0.01 ETH.
    function MAX_FLAT_BOUNTY() external view returns (uint256);

    /// @notice The keeper bounty bounds for an order's terms, in wei. The native notional is `amountIn` when the
    ///         input is native, `minAmountOut` when the output is native; with neither, the flat bounds apply.
    /// @return min The least bounty. @return default_ The bounty an app pre-fills. @return max The largest bounty.
    function bountyBounds(PoolKey calldata key, bool zeroForOne, uint128 amountIn, uint128 minAmountOut)
        external
        pure
        returns (uint256 min, uint256 default_, uint256 max);

    /// @notice The lane floor of an open order's pool (`IHookrLaneRoot.laneOf`): the gas its swap must carry when it
    ///         reaches the lane. Zero for a pool without a lane or with its switch off, and for an order that is not
    ///         open. `fill` refuses to start below it; a keeper's gas limit comes from `eth_estimateGas` of `fill`.
    function fillGasFloor(uint256 orderId) external view returns (uint256);

    /// @notice Returns the largest `amountIn` an order accepts, int128.max: the router takes a signed 128-bit amount.
    function MAX_AMOUNT_IN() external view returns (uint256);

    /// @notice Returns the lowest nonzero `sqrtPriceLimitX96` an order accepts, MIN_SQRT_PRICE + 1. A zero limit
    ///         resolves to this bound for zeroForOne orders.
    function MIN_PRICE_LIMIT() external view returns (uint160);

    /// @notice Returns the highest nonzero `sqrtPriceLimitX96` an order accepts, MAX_SQRT_PRICE - 1. A zero limit
    ///         resolves to this bound for oneForZero orders.
    function MAX_PRICE_LIMIT() external view returns (uint160);

    /// @notice Returns the id of the most recently created order. Ids start at 1.
    function lastOrderId() external view returns (uint256);

    /// @notice Returns a stored order. A never-created id returns an empty order with status `None`.
    function getOrder(uint256 orderId) external view returns (Order memory);

    /// @notice Returns what the book owes in `currency`: open input escrow, open bounties and unclaimed
    ///         keeper bounties. The book's balance is never lower; anything above it is a stray donation.
    function liabilities(Currency currency) external view returns (uint256);

    /// @notice Returns the native bounty balance `keeper` can claim.
    function bountyOf(address keeper) external view returns (uint256);

    /// @notice Escrows the input and bounty and opens an order. Rejects non-Hookr pools and transfer taxes.
    /// @dev msg.value must equal `bounty`, plus `amountIn` when the input is native. ERC-20 input is pulled
    ///      with `transferFrom` for exactly `amountIn`.
    /// @return orderId The new order's id.
    function createOrder(OrderParams calldata params) external payable returns (uint256 orderId);

    /// @notice Fills an open, unexpired order in full through the pinned router. Permissionless.
    /// @dev The whole input must be consumed and the recipient must net at least `minAmountOut`, or it reverts.
    ///      On success the bounty is added to the caller's pull balance. The swap is `HookrRouter.swap` with this book
    ///      as payer, or, when the pool's root holds a live GATE admission of this book, `HookrRouter.swapGated` with
    ///      the order's owner as payer, vouched for by this book's `beforeUnlock` for this fill only. On a lane pool
    ///      the call must start with at least `fillGasFloor`. On a plain fill the lane trader share the Rules credit to
    ///      this book as the swap's payer (the book's claim after the swap minus before it) is paid on to the order's
    ///      recipient in the same call (`CreditPassed`); on a gated fill the Rules credit it to the owner, who claims
    ///      it there, and a King of the Pool lead is the owner's. Before the swap it settles the elapsed King of the
    ///      Hill epochs one of its fills led in the pool's Rules and quote, so no prize can arrive during the swap and
    ///      be taken for the fill's share, and sweeps any claim the book already holds there to the Rules' protocol
    ///      recipient as `sweepCredit` does. The King of the Pool work is bounded per fill (at most 32 recorded crowns
    ///      visited and 8 calls to the Rules) whatever the number of crowns. A fill that cannot rule out a due epoch in
    ///      that bound, whose claim still holds an older credit the sweep could not move (the Rules pay a claim only
    ///      whole), or that is gated withholds the claim's rise (`CreditWithheld`) instead of passing it. The next
    ///      fills or `settleCrowns` finish an unfinished pass, and `sweepCredit` on a lane pool of the same Rules and
    ///      quote moves an older credit.
    /// @return amountOut The net output delivered to the order's recipient.
    function fill(uint256 orderId) external returns (uint256 amountOut);

    /// @notice Cancels an open order, expired or not, and returns input and bounty to `to`. Owner only.
    /// @dev `to` follows the order-recipient rules. A token that later charges the sender a surcharge blocks the
    ///      cancel (and the fill) until the token removes it; a recipient-side tax blocks only the fill.
    function cancel(uint256 orderId, address to) external;

    /// @notice Pays the book's whole claim in the pool's Rules, in the pool's quote, to that Rules' protocol
    ///         recipient. Permissionless. Fills pass their own lane trader share through as they land, so a claim the
    ///         book holds between fills is a King of the Pool prize one of its fills won, a rise a fill withheld or a
    ///         third party's credit naming the book, none of which an order can be matched to. It pays as tokens or
    ///         native; when the recipient cannot receive them and the pool has a recapture lane, it credits the claim
    ///         to the recipient in the same Rules instead, through the pool's root (`IHookrLaneRoot.sweepClaims`), and
    ///         never leaves it as an ERC-6909 balance the recipient may have no call to move (a `HookrTreasury` has
    ///         none). Reverts `NothingToClaim` when there is none and `CreditNotSwept` when neither path is open (a
    ///         lane pool of the same Rules and quote can sweep it).
    /// @return amount The amount swept.
    function sweepCredit(PoolKey calldata key) external returns (uint256 amount);

    /// @notice Runs the King of the Pool settlement pass fills run, on the book's crowns in the pool's Rules and quote,
    ///         with a caller-chosen page: at most `maxCalls` calls to the Rules (zero or above 1,000 means 1,000) and
    ///         four visited crowns per call. Permissionless; prizes it settles become the book's claim, which the next
    ///         fill or `sweepCredit` pays to the Rules' protocol recipient.
    /// @return clear Whether no crown the book leads in that Rules and quote can be due now, so the next fill there
    ///         passes its own lane trader share to its recipient.
    function settleCrowns(PoolKey calldata key, uint256 maxCalls) external returns (bool clear);

    /// @notice The book's King of the Pool crowns in `rules` and `quote`: how many are recorded, how many the open
    ///         settlement pass has not visited yet (0 when none is open), and the timestamp before which none can be
    ///         due (a lower bound; from it on fills and `settleCrowns` walk the list).
    function crownBacklog(address rules, Currency quote)
        external
        view
        returns (uint256 recorded, uint256 unvisited, uint256 nextDue);

    /// @notice Sends the caller's whole bounty balance to `to`.
    /// @return amount The native amount sent.
    function claimBounty(address to) external returns (uint256 amount);

    /// @notice Simulates a fill with the pool's pinned quoter. Not view: call it with `eth_call`.
    /// @dev Uses the same payer and terms a real fill would: the order's owner on a root whose live GATE admission names
    ///      this book, else this book. Dynamic fee state can change before the fill lands, so a keeper should simulate
    ///      `fill` itself before sending.
    /// @return fillable Whether a fill now would consume the whole input and meet the minimum.
    /// @return amountOut The simulated net output, or zero when the order is not open or the simulation failed.
    function quoteFill(uint256 orderId) external returns (bool fillable, uint256 amountOut);
}
