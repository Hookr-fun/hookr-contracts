// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {HookrRouter} from "../../../src/periphery/HookrRouter.sol";
import {IHookrRouter} from "../../../src/interfaces/IHookrRouter.sol";

/// @notice Test actor: a generic PoolManager caller (unauthenticated), a JIT liquidity provider and a router user.
contract Actor is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using TransientStateLibrary for IPoolManager;

    enum Op {
        SWAP,
        ADD,
        REMOVE,
        JIT_SWAP
    }

    struct Call {
        Op op;
        PoolKey key;
        bool zeroForOne;
        int256 amountSpecified;
        uint160 limit;
        int24 lower;
        int24 upper;
        int256 liquidity;
    }

    IPoolManager public immutable manager;
    HookrRouter public immutable router;
    int256 public lastDelta0;
    int256 public lastDelta1;

    constructor(IPoolManager _manager, HookrRouter _router) {
        manager = _manager;
        router = _router;
    }

    function approveAll(address token) external {
        IERC20(token).approve(address(router), type(uint256).max);
    }

    /// @notice Unauthenticated direct swap.
    function directSwap(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, uint160 limit) external {
        manager.unlock(abi.encode(Call(Op.SWAP, key, zeroForOne, amountSpecified, limit, 0, 0, 0)));
    }

    /// @notice Adds (positive) or removes (negative) liquidity in its own unlock.
    function modify(PoolKey calldata key, int24 lower, int24 upper, int256 liquidity) external {
        manager.unlock(abi.encode(Call(liquidity > 0 ? Op.ADD : Op.REMOVE, key, false, 0, 0, lower, upper, liquidity)));
    }

    /// @notice One unlock: add liquidity, swap, remove it.
    function jitSwap(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 limit,
        int24 lower,
        int24 upper,
        int256 liquidity
    ) external {
        manager.unlock(abi.encode(Call(Op.JIT_SWAP, key, zeroForOne, amountSpecified, limit, lower, upper, liquidity)));
    }

    /// @notice Authenticated router swap with this contract as payer and recipient.
    function routerSwap(IHookrRouter.Swap memory p, uint256 value)
        public
        returns (uint256 amountIn, uint256 amountOut)
    {
        p.recipient = address(this);
        return router.swap{value: value}(p, address(0), new uint256[](0));
    }

    /// @notice Two authenticated router swaps in one transaction.
    function routerPair(IHookrRouter.Swap memory a, uint256 va, IHookrRouter.Swap memory b, uint256 vb) external {
        routerSwap(a, va);
        routerSwap(b, vb);
    }

    /// @notice Authenticated buy, then an authenticated sell of everything it bought: one transaction.
    function routerRoundTrip(IHookrRouter.Swap memory buy, uint256 value, IHookrRouter.Swap memory sell)
        external
        returns (uint256 spent, uint256 returned)
    {
        uint256 got;
        (spent, got) = routerSwap(buy, value);
        sell.amountSpecified = -int128(int256(got));
        (, returned) = routerSwap(sell, 0);
    }

    /// @notice Rolls an elapsed epoch and buys in the same transaction (the revert-unless-win shape).
    function rollAndBuy(address rules, bytes32 id, IHookrRouter.Swap memory buy, uint256 value) external {
        (bool ok,) = rules.call(abi.encodeWithSignature("settleEpoch(bytes32)", id));
        ok;
        routerSwap(buy, value);
    }

    /// @notice Adds liquidity, makes an authenticated router swap, removes the liquidity: one transaction.
    function jitRouterSwap(IHookrRouter.Swap memory p, uint256 value, int24 lower, int24 upper, int256 liquidity)
        external
    {
        manager.unlock(abi.encode(Call(Op.ADD, p.key, false, 0, 0, lower, upper, liquidity)));
        routerSwap(p, value);
        manager.unlock(abi.encode(Call(Op.REMOVE, p.key, false, 0, 0, lower, upper, -liquidity)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager");
        Call memory c = abi.decode(data, (Call));
        if (c.op == Op.ADD || c.op == Op.JIT_SWAP) {
            manager.modifyLiquidity(c.key, ModifyLiquidityParams(c.lower, c.upper, c.liquidity, 0), "");
        }
        if (c.op == Op.REMOVE) {
            manager.modifyLiquidity(c.key, ModifyLiquidityParams(c.lower, c.upper, c.liquidity, 0), "");
        }
        if (c.op == Op.SWAP || c.op == Op.JIT_SWAP) {
            BalanceDelta d = manager.swap(c.key, SwapParams(c.zeroForOne, c.amountSpecified, c.limit), "");
            lastDelta0 = d.amount0();
            lastDelta1 = d.amount1();
        }
        if (c.op == Op.JIT_SWAP) {
            manager.modifyLiquidity(c.key, ModifyLiquidityParams(c.lower, c.upper, -c.liquidity, 0), "");
        }
        _close(c.key.currency0);
        _close(c.key.currency1);
        return "";
    }

    function _close(Currency c) internal {
        int256 d = manager.currencyDelta(address(this), c);
        if (d > 0) {
            manager.take(c, address(this), uint256(d));
        } else if (d < 0) {
            uint256 owed = uint256(-d);
            if (c.isAddressZero()) {
                manager.settle{value: owed}();
            } else {
                manager.sync(c);
                IERC20(Currency.unwrap(c)).transfer(address(manager), owed);
                manager.settle();
            }
        }
    }

    receive() external payable {}
}
