// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHookrLimitOrders} from "hookr-blocks/limit-orders/src/interfaces/IHookrLimitOrders.sol";
import {BenchToken} from "../src/BenchToken.sol";
import {Pools} from "./Pools.sol";

/// @notice Hookr Limit Orders (the live book at 0x0c37...02fA): an escrow book that sits outside the swap path, on a
///         fee-only Hookr pool. A maker escrows a sell and a bounty, a keeper fills it through HookrRouter once the
///         price allows, and the maker can cancel. The order sells 1,000 tokens for WETH about 1% above the market, and
///         a buyer then pushes the price about 2% so the keeper can fill. The book already holds another maker's
///         order, so its ledgers are nonzero as on a live book.
contract LimitOrdersTest is Pools {
    IHookrLimitOrders internal book = IHookrLimitOrders(LIMIT_ORDERS);

    uint128 internal constant ORDER_IN = 1e21;
    uint128 internal constant MIN_OUT = 1.009e21;
    uint128 internal constant PUSH_IN = 1.005e22;
    uint128 internal constant BOUNTY = 0.0005 ether;
    string internal constant BOOK_ROUTER = "direct call to the book, which swaps through HookrRouter";

    BenchToken internal token;
    PoolKey internal key;
    address internal maker;
    address internal keeper = makeAddr("keeper");

    /// @dev A warmed Hookr pool, a maker with an approval to the book, and another maker's order already in the book.
    function setUp() public override {
        super.setUp();
        token = _newToken();
        (, key) = _launch(token, _member(RULES), "");
        _nextBlock();
        _warm(key);
        maker = _funded("maker");
        address other = _funded("other maker");
        vm.prank(other, other);
        book.createOrder{value: BOUNTY}(_params(other));
        _nextBlock();
    }

    /// @notice A maker places an order.
    function test_place() public {
        vm.prank(maker, maker);
        book.createOrder{value: BOUNTY}(_params(maker));
        _report("place", "Limit order: place, escrowing the sell and a bounty", _lastCallGas(), DIRECT);
    }

    /// @notice A maker cancels an open order.
    function test_cancel() public {
        uint256 id = _place();
        _nextBlock();
        vm.prank(maker, maker);
        book.cancel(id, maker);
        _report("cancel", "Limit order: cancel, refunding the escrow and the bounty", _lastCallGas(), DIRECT);
    }

    /// @notice A keeper fills an order after a buyer has pushed the price past it.
    function test_fill() public {
        uint256 id = _place();
        _nextBlock();
        _swapUniversal(ROUTER_CURATED, trader, key, true, PUSH_IN);
        _nextBlock();
        uint256 before = IERC20(WETH).balanceOf(maker);
        vm.prank(keeper, keeper);
        book.fill(id);
        int256 gas = _lastCallGas();
        require(IERC20(WETH).balanceOf(maker) - before >= MIN_OUT, "order not filled");
        _report("fill", "Limit order: fill, by a keeper, with the swap included", gas, BOOK_ROUTER);
    }

    /// @notice A buy on the pool with an open order in the book, against the same buy from the same state without it.
    function test_otherSwaps() public {
        uint256 snapshot = vm.snapshotState();
        uint256 without = _swapUniversal(ROUTER_CURATED, trader, key, true, SWAP_AMOUNT);
        vm.revertToState(snapshot);
        _place();
        _nextBlock();
        uint256 with = _swapUniversal(ROUTER_CURATED, trader, key, true, SWAP_AMOUNT);
        _record(
            Figure({
                id: "limit-orders.per-swap",
                piece: "limit-orders",
                label: "Limit orders: a buy on a pool whose book holds an open order",
                action: "per-swap",
                gas: _extra(with, without),
                baseline: SAME_POOL_WITHOUT_PIECE,
                router: UR_CURATED,
                test: "bench/test/LimitOrders.t.sol:test_otherSwaps"
            })
        );
    }

    /// @dev Records the order figure `action`, an absolute transaction, named by its test.
    function _report(string memory action, string memory label, int256 gas, string memory router) private {
        _record(
            Figure({
                id: string.concat("limit-orders.", action),
                piece: "limit-orders",
                label: label,
                action: action,
                gas: gas,
                baseline: ABSOLUTE,
                router: router,
                test: string.concat("bench/test/LimitOrders.t.sol:test_", action)
            })
        );
    }

    /// @dev The maker places an order and gets its id.
    function _place() private returns (uint256 id) {
        vm.prank(maker, maker);
        id = book.createOrder{value: BOUNTY}(_params(maker));
    }

    /// @dev A sell of `ORDER_IN` tokens for at least `MIN_OUT` WETH, paid to `recipient`.
    function _params(address recipient) private view returns (IHookrLimitOrders.OrderParams memory p) {
        p.key = key;
        p.zeroForOne = false;
        p.amountIn = ORDER_IN;
        p.minAmountOut = MIN_OUT;
        p.recipient = recipient;
        p.expiry = uint40(vm.getBlockTimestamp() + 7 days);
        p.bounty = BOUNTY;
    }

    /// @dev A wallet with tokens, WETH and ETH for the bounty, that has approved the book.
    function _funded(string memory name) private returns (address who) {
        who = _wallet(name, token);
        token.transfer(who, 1e26);
        vm.deal(who, 10 ether);
        vm.prank(who);
        token.approve(address(book), type(uint256).max);
    }
}
